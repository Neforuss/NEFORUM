import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../media/card_design.dart';
import '../../media/text_card_background.dart';
import '../../platform/storage.dart';
import '../../state/card_designs.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';

/// What a card preview draws: a text card or an audio card from a design, at
/// one network's size. Two equal requests draw the same picture, so the
/// preview of a request is cached while it is shown.
@immutable
class CardPreviewRequest {
  /// A text card: the post's [text], the @handle [byline] (null leaves it
  /// out), the signature when [signed], over [background].
  const CardPreviewRequest.text({
    required this.design,
    required this.platformId,
    required this.size,
    this.safe = EdgeInsets.zero,
    required String this.text,
    this.byline,
    this.signed = true,
    this.background,
  })  : texts = null,
        coverPath = null,
        sound = null;

  /// An audio card: [texts] from [audioCardTexts], the picture at
  /// [coverPath] (the cover art or the post's photo), the levels of [sound].
  const CardPreviewRequest.audio({
    required this.design,
    required this.platformId,
    required this.size,
    this.safe = EdgeInsets.zero,
    required Map<CardBlockRole, String> this.texts,
    this.coverPath,
    this.sound,
  })  : text = null,
        byline = null,
        signed = true,
        background = null;

  final CardDesign design;
  final String platformId;
  final Size size;
  final EdgeInsets safe;
  final String? text;
  final String? byline;
  final bool signed;
  final TextCardBackground? background;
  final Map<CardBlockRole, String>? texts;
  final String? coverPath;
  final MediaAttachment? sound;

  /// Everything the picture depends on, as one string.
  String get identity => jsonEncode([
        design.toJson(),
        platformId,
        size.width,
        size.height,
        [safe.left, safe.top, safe.right, safe.bottom],
        text,
        byline,
        signed,
        background?.toJson(),
        texts?.map((k, v) => MapEntry(k.name, v)),
        coverPath,
        sound?.path,
      ]);

  /// This request at no more than [maxSide] pixels on its longest side (as it
  /// is when already that small): the same card, since every length in it
  /// is in units of the card's size ([safe] too).
  CardPreviewRequest scaledToFit(int maxSide) {
    final longest = size.longestSide;
    if (longest <= maxSide) return this;
    final scale = maxSide / longest;
    final smaller = Size((size.width * scale).roundToDouble(), (size.height * scale).roundToDouble());
    final words = texts;
    return words == null
        ? CardPreviewRequest.text(
            design: design, platformId: platformId, size: smaller, safe: safe, text: text ?? '', byline: byline, signed: signed, background: background)
        : CardPreviewRequest.audio(design: design, platformId: platformId, size: smaller, safe: safe, texts: words, coverPath: coverPath, sound: sound);
  }

  /// Draws the card exactly as it is saved ([renderDesignedTextCard],
  /// [renderDesignedAudioCard]) at [size]; a JPEG. [CardDesignView] draws a
  /// smaller copy ([scaledToFit]); a card that is saved or exported is drawn
  /// at its full size.
  Future<Uint8List> render(AppStorage storage) async {
    final words = texts;
    if (words == null) {
      final bg = background;
      final backdrop = bg == null ? null : await decodeTextCardBackdrop(await storage.readMedia(bg.photo.path), bg);
      return renderDesignedTextCard(storage,
          design: design, platformId: platformId, size: size, safe: safe, text: text ?? '', byline: byline, signed: signed, backdrop: backdrop);
    }
    final path = coverPath;
    final s = sound;
    return renderDesignedAudioCard(storage,
        design: design,
        platformId: platformId,
        size: size,
        safe: safe,
        texts: words,
        cover: path == null ? null : await decodeCardPicture(storage, path),
        waveform: s == null || !design.waveform.visible ? null : await waveformOfSound(storage, s),
        png: false);
  }

  @override
  bool operator ==(Object other) => other is CardPreviewRequest && other.identity == identity;

  @override
  int get hashCode => identity.hashCode;
}

/// The longest side, in pixels, a [CardDesignView] draws its card at: sharp
/// at the size previews are shown, and a fraction of the work of a
/// full-size 1080 x 1920 card.
const int kCardPreviewMaxSide = 720;

/// A designed card as it will be saved, at [request]'s shape, drawn by the
/// saved card's renderer at no more than [maxSide] pixels.
///
/// Edits in quick succession are drawn once they pause, and one picture is
/// drawn at a time: while it is drawn, newer edits wait, and a picture that
/// an edit made out of date by the time it is done is dropped for the latest
/// edit's. The last picture stays up meanwhile.
class CardDesignView extends ConsumerStatefulWidget {
  const CardDesignView({
    super.key,
    required this.request,
    this.delay = const Duration(milliseconds: 180),
    this.maxSide = kCardPreviewMaxSide,
    this.draw,
  });
  final CardPreviewRequest request;
  final Duration delay;
  final int maxSide;

  /// Draws a request in place of [CardPreviewRequest.render], for tests.
  @visibleForTesting
  final Future<Uint8List> Function(CardPreviewRequest request)? draw;

  @override
  ConsumerState<CardDesignView> createState() => _CardDesignViewState();
}

class _CardDesignViewState extends ConsumerState<CardDesignView> {
  /// The latest request, once edits pause.
  late CardPreviewRequest _wanted = widget.request;

  /// The request being drawn; null when none is.
  CardPreviewRequest? _drawing;

  /// The request [_picture] shows.
  CardPreviewRequest? _drawn;
  Uint8List? _picture;
  bool _failed = false;
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    _drawNext();
  }

  @override
  void didUpdateWidget(CardDesignView old) {
    super.didUpdateWidget(old);
    if (widget.request == _wanted) return;
    _wait?.cancel();
    _wait = Timer(widget.delay, () {
      if (!mounted) return;
      setState(() => _wanted = widget.request);
      _drawNext();
    });
  }

  /// Draws [_wanted] unless a picture is being drawn (it is drawn when that
  /// one is done) or it is already shown.
  void _drawNext() {
    if (_drawing != null || _wanted == _drawn) return;
    final request = _wanted;
    _drawing = request;
    final small = request.scaledToFit(widget.maxSide);
    final draw = widget.draw;
    final picture = draw != null ? draw(small) : small.render(ref.read(servicesProvider).storage);
    picture.then((bytes) => _done(request, bytes), onError: (Object e) {
      debugPrint('Could not draw the card preview: $e');
      _done(request, null);
    });
  }

  void _done(CardPreviewRequest request, Uint8List? bytes) {
    if (!mounted) return;
    _drawing = null;
    if (request != _wanted) {
      // Out of date: dropped, and the latest edit drawn instead.
      setState(_drawNext);
      return;
    }
    setState(() {
      _drawn = request;
      if (bytes != null) _picture = bytes;
      _failed = bytes == null;
    });
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final bytes = _picture;
    final size = widget.request.size;
    return AspectRatio(
      aspectRatio: size.width / size.height,
      child: Stack(fit: StackFit.expand, children: [
        if (bytes != null)
          Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium)
        else
          ColoredBox(color: nf.surfaceSunken),
        if (_drawing != null)
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(Space.sm),
              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: nf.textFaint)),
            ),
          ),
        if (_failed && bytes == null)
          Center(child: Icon(Icons.broken_image_outlined, color: nf.textFaint)),
      ]),
    );
  }
}
