import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart' show Bidi;
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../brand/neforum_logo.dart';
import '../theme/tokens.dart';

/// NEFORUM text cards: a text-only post rendered as an image for platforms
/// that refuse posts without one (Instagram, Pinterest, TikTok photo posts,
/// Snapchat).
///
/// By default every card has the same signature so people recognise it
/// anywhere: a purple rule along the top with a yellow tab, the words set
/// large (in Inter, or Times New Roman or Arial, see [TextCardFont]) on plain
/// black or white, and a footer with the NEFORUM
/// mark, the wordmark and the author. The signature is optional per network
/// (Settings > Text cards, or per post under the preview): a plain card keeps
/// only the words and the author.
enum TextCardTheme {
  dark('White on black', Color(0xFF000000), Color(0xFFFFFFFF)),
  light('Black on white', Color(0xFFFFFFFF), Color(0xFF000000));

  const TextCardTheme(this.label, this.background, this.foreground);
  final String label;
  final Color background;
  final Color foreground;
}

/// Typeface for a card's words. The NEFORUM wordmark in the signature always
/// keeps its own font.
///
/// TikTok Sans ships with NEFORUM (SIL Open Font License). Instagram Sans is
/// Instagram's own and not freely licensed: it is used when installed on the
/// device, otherwise the closest common sans. Times New Roman and Arial come
/// with Windows, macOS and iOS; elsewhere the closest installed face is used
/// (Liberation or Noto on Linux and Android).
enum TextCardFont {
  original('NEFORUM (Inter)', Fonts.body, [], FontWeight.w600, -0.012),

  /// Picks each network's own font: TikTok Sans on TikTok, Instagram Sans on
  /// Instagram, NEFORUM's elsewhere (see [resolve]).
  platform("Each network's own", Fonts.body, [], FontWeight.w600, -0.012),
  tiktokSans('TikTok Sans', 'TikTok Sans', [Fonts.body], FontWeight.w700, -0.01, [FontVariation('wght', 700)]),
  // No plain "Helvetica": on Windows that name can match a condensed face.
  instagramSans('Instagram Sans', 'Instagram Sans', ['Instagram Sans Headline', 'Helvetica Neue', 'Arial', 'Roboto'],
      FontWeight.w700, -0.01),
  timesNewRoman('Times New Roman', 'Times New Roman', ['Times', 'Liberation Serif', 'Tinos', 'Noto Serif', 'serif'], FontWeight.w400, 0),
  arial('Arial', 'Arial', ['Helvetica', 'Liberation Sans', 'Arimo', 'Roboto', 'sans-serif'], FontWeight.w700, 0);

  const TextCardFont(this.label, this.family, this.fallback, this.weight, this.tracking, [this.variations = const []]);
  final String label;
  final String family;
  final List<String> fallback;
  final FontWeight weight;

  /// Letter spacing as a fraction of the font size.
  final double tracking;

  /// Axis settings for variable fonts (TikTok Sans).
  final List<FontVariation> variations;

  /// How a card made with this font is marked in its file name and path.
  String get marker => this == original ? '' : 'font-$name';

  /// The font actually drawn on [platformId]: [platform] becomes that
  /// network's own; every other choice is itself.
  TextCardFont resolve(String? platformId) => this != platform
      ? this
      : switch (platformId) {
          'tiktok' => tiktokSans,
          'instagram' => instagramSans,
          _ => original,
        };

  TextStyle style({required double fontSize, double? height, Color? color}) => TextStyle(
        fontFamily: family,
        fontFamilyFallback: fallback,
        fontWeight: weight,
        fontVariations: variations,
        fontSize: fontSize,
        height: height,
        letterSpacing: tracking * fontSize,
        color: color,
      );
}

/// Room a network's own buttons and captions take over a full-screen (9:16)
/// photo or card, in pixels at 1080 wide: words are kept out of it so they
/// are not hidden. TikTok: the search bar on top, the like/comment/share
/// column on the right, the name, caption and sound at the bottom.
EdgeInsets fullScreenSafeArea(String platformId) => switch (platformId) {
      'tiktok' => const EdgeInsets.fromLTRB(0, 240, 150, 440),
      'instagram' => const EdgeInsets.fromLTRB(0, 220, 120, 360),
      'snapchat' => const EdgeInsets.fromLTRB(0, 200, 0, 320),
      _ => EdgeInsets.zero,
    };

/// Pixel size of the card: each platform's preferred portrait frame.
Size textCardSize(String platformId) => switch (platformId) {
      'instagram' => const Size(1080, 1350),
      'pinterest' => const Size(1000, 1500),
      'tiktok' || 'snapchat' => const Size(1080, 1920),
      _ => const Size(1080, 1080),
    };

/// The safe area of [platformId]'s card: only full-screen (9:16) cards
/// (TikTok, Snapchat) have the network's buttons over them.
EdgeInsets textCardSafeArea(String platformId) {
  final s = textCardSize(platformId);
  return s.width / s.height < 0.62 ? fullScreenSafeArea(platformId) : EdgeInsets.zero;
}

/// True when [d] cannot take a text-only post but accepts a JPEG, and the
/// variant has words and no media: exactly when a card helps.
bool qualifiesForTextCard(PlatformDescriptor d, PostVariant v) {
  final m = d.media;
  return m.requiresMedia && m.maxImages > 0 && m.imageMimeTypes.contains('image/jpeg') && v.media.isEmpty && v.text.trim().isNotEmpty;
}

/// The words on the card: the post as written (or the network's own version),
/// without trailing lines that are only hashtags or links; those belong in
/// the caption.
String textCardText(Post post, PostTarget target) {
  final lines = (target.overrides.text ?? post.text).trim().split('\n');
  final tagOrLink = RegExp(r'^(\s*(#[\p{L}\p{N}_]+|https?://\S+)\s*)+$', unicode: true);
  while (lines.length > 1 && (lines.last.trim().isEmpty || tagOrLink.hasMatch(lines.last))) {
    lines.removeLast();
  }
  return lines.join('\n').trim();
}

/// Alt text for a card: the card's own words (platform alt limits are
/// around 1,000 characters).
String textCardAltText(String text) => text.length <= 1000 ? text : '${text.substring(0, 999)}…';

/// [safe]: the card keeps clear of a network's buttons ([fullScreenSafeArea]).
String textCardFileName(TextCardTheme theme, {bool branded = true, TextCardFont font = TextCardFont.original, bool safe = false}) =>
    'neforum-text-card-${theme.name}${branded ? '' : '-plain'}${font.marker.isEmpty ? '' : '-${font.marker}'}${safe ? '-safe' : ''}.jpg';

/// Whether a generated card was laid out clear of a network's buttons.
bool textCardSafeOf(MediaAttachment m) => (m.fileName ?? '').contains('-safe');

/// Path prefix of the composer's stand-in for a card that is rendered when
/// the post is saved.
const String kTextCardPlaceholder = 'textcard:';

bool isTextCardPlaceholder(MediaAttachment m) => m.path.startsWith(kTextCardPlaceholder);

/// What the composer's previews and checks see in place of the real card.
MediaAttachment textCardPlaceholder(String platformId, TextCardTheme theme,
    {bool branded = true, TextCardFont font = TextCardFont.original}) {
  final s = textCardSize(platformId);
  return MediaAttachment(
    id: 'textcard-$platformId',
    path: '$kTextCardPlaceholder${theme.name}${branded ? '' : ':plain'}${font.marker.isEmpty ? '' : ':${font.marker}'}',
    mimeType: 'image/jpeg',
    sizeBytes: 0,
    width: s.width.round(),
    height: s.height.round(),
    fileName: textCardFileName(theme, branded: branded, font: font),
    generated: true,
  );
}

/// Whether a generated card (or placeholder) carries the NEFORUM signature.
bool textCardBrandedOf(MediaAttachment m) => !(m.path.contains(':plain') || (m.fileName ?? '').contains('-plain'));

/// The font a generated card (or placeholder) was made with.
TextCardFont textCardFontOf(MediaAttachment m) {
  final name = '${m.fileName ?? ''} ${m.path}';
  for (final f in TextCardFont.values) {
    if (f.marker.isNotEmpty && name.contains(f.marker)) return f;
  }
  return TextCardFont.original;
}

/// The theme a generated card (or placeholder) was made with.
TextCardTheme? textCardThemeOf(MediaAttachment m) {
  final name = '${m.fileName ?? ''} ${m.path}';
  for (final t in TextCardTheme.values) {
    if (name.contains('text-card-${t.name}') || name.contains('$kTextCardPlaceholder${t.name}')) return t;
  }
  return null;
}

/// Paints a card at any size; all measurements scale with the width, so
/// the composer preview and the 1080-pixel export look the same.
class TextCardPainter extends CustomPainter {
  const TextCardPainter(
      {required this.text, required this.theme, this.byline, this.branded = true, this.font = TextCardFont.original, this.safe = EdgeInsets.zero});

  final String text;
  final TextCardTheme theme;

  /// Typeface of the words.
  final TextCardFont font;

  /// Draw the NEFORUM signature (top rule, mark and wordmark).
  final bool branded;

  /// Author in the footer, e.g. "@ana@mastodon.social".
  final String? byline;

  /// Room the network's own buttons take, in pixels at 1080 wide
  /// ([fullScreenSafeArea]): the words and footer stay out of it.
  final EdgeInsets safe;

  static const double _lineHeight = 1.3;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 1080;
    final w = size.width;
    final h = size.height;
    final fg = theme.foreground;
    final pad = 92 * u;
    final safeTop = safe.top * u, safeRight = safe.right * u, safeBottom = safe.bottom * u;

    canvas.drawRect(Offset.zero & size, Paint()..color = theme.background);

    final rule = branded ? 14 * u : 0.0;
    if (branded) {
      // Signature rule: purple along the top, a yellow tab at the start.
      canvas.drawRect(Rect.fromLTWH(0, 0, w, rule), Paint()..color = Brand.purple);
      canvas.drawRect(Rect.fromLTWH(0, 0, pad + 120 * u, rule), Paint()..color = Brand.yellow);
    }

    // Footer: mark, wordmark and author; a plain card keeps only the author.
    final markSize = 60 * u;
    final footerY = h - safeBottom - 84 * u - markSize;
    final by = byline?.trim() ?? '';
    var authorLeft = pad;
    if (branded) {
      paintNeforumMark(canvas, Rect.fromLTWH(pad, footerY, markSize, markSize));
      final word = TextPainter(
        text: TextSpan(
          text: 'NEFORUM',
          style: TextStyle(fontFamily: Fonts.display, fontWeight: FontWeight.w800, fontSize: 30 * u, letterSpacing: 1.6 * u, color: fg, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final wordX = pad + markSize + 20 * u;
      word.paint(canvas, Offset(wordX, footerY + (markSize - word.height) / 2));
      authorLeft = wordX + word.width + 32 * u;
      word.dispose();
    }
    if (by.isNotEmpty) {
      final room = w - pad - safeRight - authorLeft;
      if (room > 40 * u) {
        final author = TextPainter(
          text: TextSpan(
            text: by,
            style: TextStyle(fontFamily: Fonts.body, fontWeight: FontWeight.w500, fontSize: 26 * u, color: fg.withValues(alpha: 0.62), height: 1.1),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: room);
        author.paint(canvas, Offset(branded ? w - pad - safeRight - author.width : pad, footerY + (markSize - author.height) / 2));
        author.dispose();
      }
    }
    final double bottom;
    if (branded) {
      final dividerY = footerY - 44 * u;
      canvas.drawLine(
        Offset(pad, dividerY),
        Offset(w - pad - safeRight, dividerY),
        Paint()
          ..color = fg.withValues(alpha: 0.16)
          ..strokeWidth = 2 * u,
      );
      bottom = dividerY - 56 * u;
    } else {
      bottom = by.isEmpty ? h - pad - safeBottom : footerY - 40 * u;
    }

    // The words: as large as fits, never smaller than 30 px at 1080 wide.
    final top = rule + pad + safeTop;
    final areaW = w - pad * 2 - safeRight;
    final areaH = math.max(0.0, bottom - top);
    final rtl = Bidi.detectRtlDirectionality(text);
    TextPainter layout(double fs, {int? maxLines}) => TextPainter(
          text: TextSpan(
            text: text,
            style: font.style(fontSize: fs, height: _lineHeight, color: fg),
          ),
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          textAlign: TextAlign.start,
          maxLines: maxLines,
          ellipsis: maxLines == null ? null : '…',
        )..layout(maxWidth: areaW);

    var fs = 104 * u;
    final minFs = 30 * u;
    var tp = layout(fs);
    while (tp.height > areaH && fs > minFs) {
      tp.dispose();
      fs = math.max(minFs, fs - 4 * u);
      tp = layout(fs);
    }
    if (tp.height > areaH) {
      final lines = math.max(1, (areaH / (fs * _lineHeight)).floor());
      tp.dispose();
      tp = layout(fs, maxLines: lines);
    }
    final dx = rtl ? pad + areaW - tp.width : pad;
    tp.paint(canvas, Offset(dx, top + (areaH - tp.height) / 2));
    tp.dispose();
  }

  @override
  bool shouldRepaint(TextCardPainter old) =>
      old.text != text || old.theme != theme || old.byline != byline || old.branded != branded || old.font != font || old.safe != safe;
}

/// Live card for previews.
class TextCardView extends StatelessWidget {
  const TextCardView(
      {super.key,
      required this.text,
      required this.theme,
      required this.aspect,
      this.byline,
      this.branded = true,
      this.font = TextCardFont.original,
      this.safe = EdgeInsets.zero});

  final String text;
  final TextCardTheme theme;
  final TextCardFont font;
  final EdgeInsets safe;

  /// Width / height.
  final double aspect;
  final String? byline;
  final bool branded;

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: aspect,
        child: CustomPaint(painter: TextCardPainter(text: text, theme: theme, byline: byline, branded: branded, font: font, safe: safe)),
      );
}

/// Renders a card to JPEG bytes (Instagram's API only takes JPEG).
Future<Uint8List> renderTextCardJpeg(
    {required String text,
    required TextCardTheme theme,
    required Size size,
    String? byline,
    bool branded = true,
    TextCardFont font = TextCardFont.original,
    EdgeInsets safe = EdgeInsets.zero}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  TextCardPainter(text: text, theme: theme, byline: byline, branded: branded, font: font, safe: safe).paint(canvas, size);
  final picture = recorder.endRecording();
  final width = size.width.round();
  final height = size.height.round();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (data == null) throw StateError('Could not read back the rendered text card');
  final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return compute(encodeRgbaJpeg, (rgba, width, height));
}

/// JPEG (quality 92) from straight RGBA pixels; run with [compute].
Uint8List encodeRgbaJpeg((Uint8List, int, int) a) {
  final (rgba, width, height) = a;
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodeJpg(image, quality: 92);
}
