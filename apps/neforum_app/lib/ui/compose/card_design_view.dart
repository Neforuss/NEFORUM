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

  /// Draws the card exactly as it is saved ([renderDesignedTextCard],
  /// [renderDesignedAudioCard]); a JPEG.
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

/// The picture of a [CardPreviewRequest], drawn by the saved card's renderer.
final cardPreviewProvider = FutureProvider.autoDispose.family<Uint8List, CardPreviewRequest>((ref, request) {
  final storage = ref.read(servicesProvider).storage;
  return request.render(storage);
});

/// A designed card as it will be saved, at [request]'s shape. Edits in quick
/// succession are drawn once they pause; the last picture stays up meanwhile.
class CardDesignView extends ConsumerStatefulWidget {
  const CardDesignView({super.key, required this.request, this.delay = const Duration(milliseconds: 180)});
  final CardPreviewRequest request;
  final Duration delay;

  @override
  ConsumerState<CardDesignView> createState() => _CardDesignViewState();
}

class _CardDesignViewState extends ConsumerState<CardDesignView> {
  late CardPreviewRequest _shown = widget.request;
  Uint8List? _last;
  Timer? _wait;

  @override
  void didUpdateWidget(CardDesignView old) {
    super.didUpdateWidget(old);
    if (widget.request == _shown) return;
    _wait?.cancel();
    _wait = Timer(widget.delay, () {
      if (mounted) setState(() => _shown = widget.request);
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
    final picture = ref.watch(cardPreviewProvider(_shown));
    final bytes = picture.value ?? _last;
    if (picture.value != null) _last = picture.value;
    final size = widget.request.size;
    return AspectRatio(
      aspectRatio: size.width / size.height,
      child: Stack(fit: StackFit.expand, children: [
        if (bytes != null)
          Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium)
        else
          ColoredBox(color: nf.surfaceSunken),
        if (picture.isLoading)
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(Space.sm),
              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: nf.textFaint)),
            ),
          ),
        if (picture.hasError && bytes == null)
          Center(child: Icon(Icons.broken_image_outlined, color: nf.textFaint)),
      ]),
    );
  }
}
