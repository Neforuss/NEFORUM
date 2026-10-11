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
/// large in Inter on plain black or white, and a footer with the NEFORUM
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

/// Pixel size of the card: each platform's preferred portrait frame.
Size textCardSize(String platformId) => switch (platformId) {
      'instagram' => const Size(1080, 1350),
      'pinterest' => const Size(1000, 1500),
      'tiktok' || 'snapchat' => const Size(1080, 1920),
      _ => const Size(1080, 1080),
    };

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

String textCardFileName(TextCardTheme theme, {bool branded = true}) => 'neforum-text-card-${theme.name}${branded ? '' : '-plain'}.jpg';

/// Path prefix of the composer's stand-in for a card that is rendered when
/// the post is saved.
const String kTextCardPlaceholder = 'textcard:';

bool isTextCardPlaceholder(MediaAttachment m) => m.path.startsWith(kTextCardPlaceholder);

/// What the composer's previews and checks see in place of the real card.
MediaAttachment textCardPlaceholder(String platformId, TextCardTheme theme, {bool branded = true}) {
  final s = textCardSize(platformId);
  return MediaAttachment(
    id: 'textcard-$platformId',
    path: '$kTextCardPlaceholder${theme.name}${branded ? '' : ':plain'}',
    mimeType: 'image/jpeg',
    sizeBytes: 0,
    width: s.width.round(),
    height: s.height.round(),
    fileName: textCardFileName(theme, branded: branded),
    generated: true,
  );
}

/// Whether a generated card (or placeholder) carries the NEFORUM signature.
bool textCardBrandedOf(MediaAttachment m) => !(m.path.endsWith(':plain') || (m.fileName ?? '').contains('-plain'));

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
  const TextCardPainter({required this.text, required this.theme, this.byline, this.branded = true});

  final String text;
  final TextCardTheme theme;

  /// Draw the NEFORUM signature (top rule, mark and wordmark).
  final bool branded;

  /// Author in the footer, e.g. "@ana@mastodon.social".
  final String? byline;

  static const double _lineHeight = 1.3;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 1080;
    final w = size.width;
    final h = size.height;
    final fg = theme.foreground;
    final pad = 92 * u;

    canvas.drawRect(Offset.zero & size, Paint()..color = theme.background);

    final rule = branded ? 14 * u : 0.0;
    if (branded) {
      // Signature rule: purple along the top, a yellow tab at the start.
      canvas.drawRect(Rect.fromLTWH(0, 0, w, rule), Paint()..color = Brand.purple);
      canvas.drawRect(Rect.fromLTWH(0, 0, pad + 120 * u, rule), Paint()..color = Brand.yellow);
    }

    // Footer: mark, wordmark and author; a plain card keeps only the author.
    final markSize = 60 * u;
    final footerY = h - 84 * u - markSize;
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
      final room = w - pad - authorLeft;
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
        author.paint(canvas, Offset(branded ? w - pad - author.width : pad, footerY + (markSize - author.height) / 2));
        author.dispose();
      }
    }
    final double bottom;
    if (branded) {
      final dividerY = footerY - 44 * u;
      canvas.drawLine(
        Offset(pad, dividerY),
        Offset(w - pad, dividerY),
        Paint()
          ..color = fg.withValues(alpha: 0.16)
          ..strokeWidth = 2 * u,
      );
      bottom = dividerY - 56 * u;
    } else {
      bottom = by.isEmpty ? h - pad : footerY - 40 * u;
    }

    // The words: as large as fits, never smaller than 30 px at 1080 wide.
    final top = rule + pad;    final areaW = w - pad * 2;
    final areaH = math.max(0.0, bottom - top);
    final rtl = Bidi.detectRtlDirectionality(text);
    TextPainter layout(double fs, {int? maxLines}) => TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontFamily: Fonts.body,
              fontWeight: FontWeight.w600,
              fontSize: fs,
              height: _lineHeight,
              letterSpacing: -0.012 * fs,
              color: fg,
            ),
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
  bool shouldRepaint(TextCardPainter old) => old.text != text || old.theme != theme || old.byline != byline || old.branded != branded;
}

/// Live card for previews.
class TextCardView extends StatelessWidget {
  const TextCardView({super.key, required this.text, required this.theme, required this.aspect, this.byline, this.branded = true});

  final String text;
  final TextCardTheme theme;

  /// Width / height.
  final double aspect;
  final String? byline;
  final bool branded;

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: aspect,
        child: CustomPaint(painter: TextCardPainter(text: text, theme: theme, byline: byline, branded: branded)),
      );
}

/// Renders a card to JPEG bytes (Instagram's API only takes JPEG).
Future<Uint8List> renderTextCardJpeg({required String text, required TextCardTheme theme, required Size size, String? byline, bool branded = true}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  TextCardPainter(text: text, theme: theme, byline: byline, branded: branded).paint(canvas, size);
  final picture = recorder.endRecording();
  final width = size.width.round();
  final height = size.height.round();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (data == null) throw StateError('Could not read back the rendered text card');
  final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return compute(_encodeJpeg, (rgba, width, height));
}

Uint8List _encodeJpeg((Uint8List, int, int) a) {
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
