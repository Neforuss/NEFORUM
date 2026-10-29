import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart' show Bidi;

import '../brand/neforum_logo.dart';
import '../theme/tokens.dart';
import 'aligned_text.dart';
import 'caption_fonts.dart';
import 'card_design.dart';
import 'photo_composite.dart';
import 'photo_pixels.dart';
import 'render_parameters.dart' show stableHash;
import 'text_card_background.dart';
import 'waveform.dart';

// Draws a [CardDesign] (card_design.dart). Like every picture NEFORUM saves
// with a photo in it, the engine draws only words and shapes (the waveform,
// the text blocks, the signature) on a transparent layer
// ([rasterizeWordsLayer]); the fill, the photo, the pattern, the grain and the
// cover art are composed on the CPU in an isolate ([composeCardDesign]),
// deterministically, never as engine images. The composer's previews and
// the editor call the same [renderCardDesign] as the saved card, so a preview
// is the saved picture, byte for byte.

/// Pixels of a card of [size] per design pixel: designs are measured on a
/// card whose shorter side is 1080 (every text card is portrait or square,
/// so for them this is the width / 1080 the classic card uses).
double cardUnit(Size size) => math.min(size.width, size.height) / 1080;

/// The card's frame: the card less its margin and the network's [safe] area
/// (design pixels), where every layer is placed.
Rect cardFrameOf(Size size, EdgeInsets safe, double margin) {
  final u = cardUnit(size);
  final m = margin * u;
  final r = Rect.fromLTRB(m + safe.left * u, m + safe.top * u, size.width - m - safe.right * u, size.height - m - safe.bottom * u);
  return r.width > 0 && r.height > 0 ? r : Offset.zero & size;
}

/// A [box] placed in [frame] at [anchor] (its own same point there), moved
/// by [offsetX] and [offsetY] (fractions of the frame).
Rect placeInFrame(Rect frame, Size box, CardAnchor anchor, double offsetX, double offsetY) => Rect.fromLTWH(
      frame.left + (frame.width - box.width) * anchor.x + offsetX * frame.width,
      frame.top + (frame.height - box.height) * anchor.y + offsetY * frame.height,
      box.width,
      box.height,
    );

/// Where the cover layer goes (before its rotation).
Rect cardCoverRect(CardCoverLayer c, Rect frame) {
  final side = math.min(frame.width, frame.height) * c.size;
  return placeInFrame(frame, Size(side, side), c.anchor, c.offsetX, c.offsetY);
}

/// Where the waveform layer goes.
Rect cardWaveformRect(CardWaveformLayer w, Rect frame) =>
    placeInFrame(frame, Size(frame.width * w.width, frame.height * w.height), w.anchor, w.offsetX, w.offsetY);

/// Everything a card is drawn from.
@immutable
class CardRenderInput {
  const CardRenderInput({
    required this.design,
    required this.size,
    this.safe = EdgeInsets.zero,
    this.platformId,
    this.texts = const {},
    this.photo,
    this.photoBackground,
    this.cover,
    this.waveform,
  });

  final CardDesign design;
  final Size size;

  /// The network's buttons over a full-screen card, in pixels at 1080 wide.
  final EdgeInsets safe;

  /// The network [TextCardFont.platform] stands for.
  final String? platformId;

  /// The words of each block role. A role missing (or empty) leaves its
  /// blocks out; [CardBlockRole.signature] set to '' leaves the signature
  /// out, missing draws it.
  final Map<CardBlockRole, String> texts;

  /// The photo of a [CardFillKind.image] fill, upright.
  final PhotoPixels? photo;

  /// A text card's photo adjustments (its background, with placement,
  /// colour, blur, dimming, gradient and vignette); null for an audio card,
  /// whose photo uses the design's own [CardBackground.photoBlur] and the rest.
  final TextCardBackground? photoBackground;

  /// The picture of the cover layer, upright.
  final PhotoPixels? cover;

  /// The sound's levels (0 to 1) for the waveform layer.
  final List<double>? waveform;
}

/// Renders [input] as a JPEG (quality 92), or a PNG with [png] (for the
/// still-picture video of a sound file).
Future<Uint8List> renderCardDesign(CardRenderInput input, {bool png = false}) async {
  final width = input.size.width.round(), height = input.size.height.round();
  final words = await rasterizeWordsLayer(width, height, (canvas) {
    CardDesignPainter(design: input.design, texts: input.texts, safe: input.safe, platformId: input.platformId, waveform: input.waveform)
        .paint(canvas, input.size);
  });
  return compute(composeCardDesign, CardComposeJob.forInput(input, words, png: png));
}

// ---------------------------------------------------------------------------
// The words layer
// ---------------------------------------------------------------------------

/// Paints a design's waveform and text blocks (the layer the engine draws).
/// Repaints when an installed or imported font finishes loading.
class CardDesignPainter extends CustomPainter {
  CardDesignPainter({required this.design, this.texts = const {}, this.safe = EdgeInsets.zero, this.platformId, this.waveform})
      : super(repaint: captionFontsRevision);

  final CardDesign design;
  final Map<CardBlockRole, String> texts;
  final EdgeInsets safe;
  final String? platformId;
  final List<double>? waveform;

  @override
  void paint(Canvas canvas, Size size) {
    final u = cardUnit(size);
    final frame = cardFrameOf(size, safe, design.margin);
    final levels = waveform;
    if (design.waveform.visible && levels != null && levels.isNotEmpty) _paintWaveform(canvas, design.waveform, cardWaveformRect(design.waveform, frame), levels, u);
    _paintBlocks(canvas, frame, u);
  }

  /// The words of block [b]; empty leaves it out.
  String wordsOf(CardTextBlock b) {
    final words = switch (b.role) {
      CardBlockRole.custom => b.text,
      CardBlockRole.signature => texts[CardBlockRole.signature] ?? 'NEFORUM',
      _ => texts[b.role] ?? '',
    };
    final trimmed = words.trim();
    return b.uppercase ? trimmed.toUpperCase() : trimmed;
  }

  static void _paintWaveform(Canvas canvas, CardWaveformLayer w, Rect r, List<double> levels, double u) {
    final bars = resampleLevels(levels, w.bars);
    final color = Color(w.color).withValues(alpha: (Color(w.color).a * w.opacity).clamp(0.0, 1.0));
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    final step = r.width / bars.length;
    final thick = math.min(w.thickness * u, step * 0.9);
    final minimum = math.max(thick, 2 * u);
    switch (w.style) {
      case CardWaveformStyle.bars:
        for (var i = 0; i < bars.length; i++) {
          final h = math.max(minimum, bars[i] * r.height);
          final x = r.left + step * (i + 0.5);
          canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x - thick / 2, r.bottom - h, thick, h), Radius.circular(thick / 2)), paint);
        }
      case CardWaveformStyle.mirrored:
        for (var i = 0; i < bars.length; i++) {
          final h = math.max(minimum, bars[i] * r.height);
          final x = r.left + step * (i + 0.5);
          canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, r.center.dy), width: thick, height: h), Radius.circular(thick / 2)), paint);
        }
      case CardWaveformStyle.line:
        final path = Path();
        for (var i = 0; i < bars.length; i++) {
          final p = Offset(r.left + step * (i + 0.5), r.bottom - bars[i] * r.height);
          i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(
            path,
            paint
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(1, w.thickness * u)
              ..strokeJoin = StrokeJoin.round
              ..strokeCap = StrokeCap.round);
      case CardWaveformStyle.dots:
        // Columns of dots, as tall as the level.
        final dot = math.max(2 * u, thick);
        final pitch = dot * 1.6;
        for (var i = 0; i < bars.length; i++) {
          final x = r.left + step * (i + 0.5);
          final count = math.max(1, (bars[i] * r.height / pitch).round());
          for (var k = 0; k < count; k++) {
            canvas.drawCircle(Offset(x, r.bottom - dot / 2 - k * pitch), dot / 2, paint);
          }
        }
    }
  }

  TextStyle _style(CardTextBlock b, double fontSize, double u) {
    final resolved = b.font.resolve(platformId);
    final alias = registeredCaptionFontAlias(b.customFont);
    final weight = FontWeight.values[((b.weight ~/ 100) - 1).clamp(0, 8)];
    final shadows = b.shadowBlur > 0 || b.shadowOffsetY != 0
        ? [Shadow(color: Color(b.shadowColor), blurRadius: b.shadowBlur * u, offset: Offset(0, b.shadowOffsetY * u))]
        : null;
    return TextStyle(
      fontFamily: alias ?? resolved.family,
      fontFamilyFallback: alias == null ? [...resolved.fallback, ...kCaptionFontFallbacks] : [resolved.family, ...resolved.fallback, ...kCaptionFontFallbacks],
      fontWeight: weight,
      fontStyle: b.italic ? FontStyle.italic : FontStyle.normal,
      fontVariations: alias == null && resolved.variations.isNotEmpty ? [FontVariation('wght', b.weight.toDouble())] : null,
      fontSize: fontSize,
      height: b.lineHeight,
      letterSpacing: b.letterSpacing * fontSize,
      color: Color(b.color),
      shadows: shadows,
    );
  }

  void _paintBlocks(Canvas canvas, Rect frame, double u) {
    // Blocks at the same anchor stack, in their order.
    final groups = <CardAnchor, List<CardTextBlock>>{};
    for (final b in design.blocks) {
      if (b.visible && wordsOf(b).isNotEmpty) (groups[b.anchor] ??= []).add(b);
    }
    for (final MapEntry(key: anchor, value: blocks) in groups.entries) {
      final laid = <_LaidBlock>[];
      // Fixed blocks first: blocks that fit themselves get the room left.
      var fixedHeight = 0.0;
      for (final b in blocks.where((b) => !b.autoFit)) {
        final l = _layout(b, frame, u, null);
        laid.add(l);
        fixedHeight += l.height + b.gapBefore * u;
      }
      for (final b in blocks.where((b) => b.autoFit)) {
        final room = math.max(frame.height * 0.08, frame.height * b.maxHeight - fixedHeight);
        laid.add(_layout(b, frame, u, room));
      }
      laid.sort((a, b) => blocks.indexOf(a.block).compareTo(blocks.indexOf(b.block)));
      var total = 0.0;
      for (var i = 0; i < laid.length; i++) {
        total += laid[i].height + (i == 0 ? 0 : laid[i].block.gapBefore * u);
      }
      var y = frame.top + (frame.height - total) * anchor.y;
      for (var i = 0; i < laid.length; i++) {
        final l = laid[i];
        if (i > 0) y += l.block.gapBefore * u;
        final b = l.block;
        var at = Offset(frame.left + (frame.width - l.width) * anchor.x + b.offsetX * frame.width, y + b.offsetY * frame.height);
        // Kept inside the frame, so a network's buttons never cover it.
        at = Offset(
          at.dx.clamp(frame.left, math.max(frame.left, frame.right - l.width)),
          at.dy.clamp(frame.top, math.max(frame.top, frame.bottom - l.height)),
        );
        l.paint(canvas, at);
        y += l.height;
        l.dispose();
      }
    }
  }

  _LaidBlock _layout(CardTextBlock b, Rect frame, double u, double? fitHeight) {
    final words = wordsOf(b);
    final width = frame.width * b.width;
    final maxHeight = fitHeight ?? frame.height * b.maxHeight;
    final rtl = Bidi.detectRtlDirectionality(words);
    if (b.role == CardBlockRole.signature) return _LaidSignature(b, words, _style(b, b.size * u, u), u);
    AlignedText make(double fs, int? lines) => AlignedText(
          words,
          style: _style(b, fs, u),
          alignment: b.alignment,
          direction: rtl ? TextDirection.rtl : TextDirection.ltr,
          maxLines: lines,
        )..layout(width, fill: true);
    final limit = b.maxLines > 0 ? b.maxLines : null;
    var lines = limit;
    var fs = b.size * u;
    var text = make(fs, lines);
    if (b.autoFit) {
      final minFs = math.max(12 * u, b.size * u / 3);
      while (text.height > maxHeight && fs > minFs) {
        text.dispose();
        fs = math.max(minFs, fs - 3 * u);
        text = make(fs, lines);
      }
    }
    if (text.height > maxHeight) {
      final fit = math.max(1, (maxHeight / (fs * b.lineHeight)).floor());
      lines = limit == null ? fit : math.min(limit, fit);
      text.dispose();
      text = make(fs, lines);
    }
    AlignedText? outline;
    if (b.outlineWidth > 0) {
      outline = AlignedText(
        words,
        style: _style(b, fs, u).copyWith(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = b.outlineWidth * 2 * u
            ..strokeJoin = StrokeJoin.round
            ..color = Color(b.outlineColor),
          color: null,
        ),
        alignment: b.alignment,
        direction: rtl ? TextDirection.rtl : TextDirection.ltr,
        maxLines: lines,
      )..layout(width, fill: true);
    }
    return _LaidText(b, text, outline, width);
  }

  @override
  bool shouldRepaint(CardDesignPainter old) =>
      old.design != design || !mapEquals(old.texts, texts) || old.safe != safe || old.platformId != platformId || old.waveform != waveform;
}

abstract class _LaidBlock {
  _LaidBlock(this.block);
  final CardTextBlock block;
  double get width;
  double get height;
  void paint(Canvas canvas, Offset at);
  void dispose() {}
}

class _LaidText extends _LaidBlock {
  _LaidText(super.block, this.text, this.outline, this._width);
  final AlignedText text;
  final AlignedText? outline;
  final double _width;

  @override
  double get width => _width;
  @override
  double get height => text.height;

  @override
  void paint(Canvas canvas, Offset at) {
    outline?.paint(canvas, at);
    text.paint(canvas, at);
  }

  @override
  void dispose() {
    text.dispose();
    outline?.dispose();
  }
}

/// The NEFORUM mark and wordmark, in the block's colour and size.
class _LaidSignature extends _LaidBlock {
  _LaidSignature(super.block, String words, TextStyle style, this.u)
      : word = TextPainter(
          text: TextSpan(
            text: words,
            style: style.copyWith(fontFamily: block.customFont == null ? Fonts.display : style.fontFamily, fontWeight: FontWeight.w800, height: 1),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
  final TextPainter word;
  final double u;

  double get _mark => word.height * 1.7;
  double get _gap => word.height * 0.6;

  @override
  double get width => _mark + _gap + word.width;
  @override
  double get height => _mark;

  @override
  void paint(Canvas canvas, Offset at) {
    // Drawn where the block's alignment puts it in the frame's width.
    paintNeforumMark(canvas, Rect.fromLTWH(at.dx, at.dy, _mark, _mark));
    word.paint(canvas, Offset(at.dx + _mark + _gap, at.dy + (_mark - word.height) / 2));
  }

  @override
  void dispose() => word.dispose();
}

// ---------------------------------------------------------------------------
// The compositor
// ---------------------------------------------------------------------------

/// Everything [composeCardDesign] needs, sent to an isolate: plain values only.
@immutable
class CardComposeJob {
  const CardComposeJob({
    required this.width,
    required this.height,
    required this.words,
    required this.fill,
    required this.color,
    required this.colors,
    required this.angle,
    required this.centerX,
    required this.centerY,
    required this.radius,
    this.photo,
    this.photoBlur = 0,
    this.photoDimming = 0,
    this.photoZoom = 1,
    this.photoOffsetX = 0,
    this.photoOffsetY = 0,
    this.photoContain = false,
    this.photoTurns = 0,
    this.photoFlip = false,
    this.photoMatrix,
    this.photoGradientStart = 0,
    this.photoGradientEnd = 0,
    this.photoGradientAngle = 0,
    this.photoVignette = 0,
    required this.pattern,
    required this.patternColor,
    required this.patternScale,
    required this.patternThickness,
    required this.patternAngle,
    required this.grain,
    required this.vignette,
    required this.seed,
    this.cover,
    this.coverShape = 0,
    this.coverCenterX = 0,
    this.coverCenterY = 0,
    this.coverSide = 0,
    this.coverRadius = 0,
    this.coverBorder = 0,
    this.coverBorderColor = 0,
    this.coverShadow = 0,
    this.coverShadowBlur = 0,
    this.coverShadowOffsetY = 0,
    this.coverRotation = 0,
    this.coverBlank = false,
    this.png = false,
  });

  factory CardComposeJob.forInput(CardRenderInput input, Uint8List words, {bool png = false}) {
    final d = input.design;
    final bg = d.background;
    final width = input.size.width.round(), height = input.size.height.round();
    final u = cardUnit(input.size);
    final frame = cardFrameOf(input.size, input.safe, d.margin);
    final photo = bg.kind == CardFillKind.image ? input.photo : null;
    final adjust = input.photoBackground;
    final gradient = adjust?.gradientColors;
    final cover = d.cover.visible ? input.cover : null;
    final coverRect = cardCoverRect(d.cover, frame);
    return CardComposeJob(
      width: width,
      height: height,
      words: words,
      fill: bg.kind.index,
      color: bg.color,
      colors: bg.colors,
      angle: bg.angle,
      centerX: bg.centerX,
      centerY: bg.centerY,
      radius: bg.radius,
      photo: photo,
      photoBlur: (adjust?.blur ?? bg.photoBlur) * u,
      photoDimming: adjust?.dimming ?? bg.photoDimming,
      photoZoom: adjust?.zoom ?? bg.photoZoom,
      photoOffsetX: adjust?.offsetX ?? bg.photoOffsetX,
      photoOffsetY: adjust?.offsetY ?? bg.photoOffsetY,
      photoContain: adjust?.contain ?? false,
      photoTurns: adjust == null ? 0 : adjust.quarterTurns % 4,
      photoFlip: adjust?.flipHorizontal ?? false,
      photoMatrix: adjust?.colorMatrix,
      photoGradientStart: gradient?.$1 ?? 0,
      photoGradientEnd: gradient?.$2 ?? 0,
      photoGradientAngle: adjust?.gradientAngle ?? 0,
      photoVignette: adjust?.vignette ?? 0,
      pattern: bg.pattern.index,
      patternColor: bg.patternColor,
      patternScale: bg.patternScale * u,
      patternThickness: bg.patternThickness * u,
      patternAngle: bg.patternAngle,
      grain: bg.grain,
      vignette: bg.vignette,
      // stableHash, not Object.hash: the same on every run.
      seed: int.parse(stableHash('$width x $height|${d.template}|${bg.color}|${bg.grain}'), radix: 16) & 0x7FFFFFFF,
      cover: cover,
      coverShape: d.cover.shape.index,
      coverCenterX: coverRect.center.dx,
      coverCenterY: coverRect.center.dy,
      coverSide: coverRect.width,
      coverRadius: d.cover.cornerRadius * coverRect.width,
      coverBorder: d.cover.borderWidth * u,
      coverBorderColor: d.cover.borderColor,
      coverShadow: d.cover.shadow,
      coverShadowBlur: d.cover.shadowBlur * u,
      coverShadowOffsetY: d.cover.shadowOffsetY * u,
      coverRotation: d.cover.rotation * math.pi / 180,
      // A record without a picture still shows, with a plain label.
      coverBlank: d.cover.visible && cover == null && d.cover.shape == CardCoverShape.vinyl,
      png: png,
    );
  }

  final int width;
  final int height;

  /// The words layer: straight RGBA, [width] x [height].
  final Uint8List words;

  /// [CardFillKind] index, the solid colour, the gradient stops and its
  /// geometry ([CardBackground]).
  final int fill;
  final int color;
  final List<int> colors;
  final double angle;
  final double centerX;
  final double centerY;
  final double radius;

  /// A [CardFillKind.image] fill's photo and its adjustments; the blur in
  /// pixels of this picture.
  final PhotoPixels? photo;
  final double photoBlur;
  final double photoDimming;
  final double photoZoom;
  final double photoOffsetX;
  final double photoOffsetY;
  final bool photoContain;
  final int photoTurns;
  final bool photoFlip;
  final List<double>? photoMatrix;
  final int photoGradientStart;
  final int photoGradientEnd;
  final double photoGradientAngle;
  final double photoVignette;

  /// [CardPattern] index; scale and thickness in pixels of this picture.
  final int pattern;
  final int patternColor;
  final double patternScale;
  final double patternThickness;
  final double patternAngle;
  final double grain;
  final double vignette;

  /// Seeds the grain, so the same card has the same grain.
  final int seed;

  /// The cover layer's picture and geometry in pixels of this picture;
  /// rotation in radians, clockwise.
  final PhotoPixels? cover;
  final int coverShape;
  final double coverCenterX;
  final double coverCenterY;
  final double coverSide;
  final double coverRadius;
  final double coverBorder;
  final int coverBorderColor;
  final double coverShadow;
  final double coverShadowBlur;
  final double coverShadowOffsetY;
  final double coverRotation;

  /// Draws a record with a plain label when there is no [cover].
  final bool coverBlank;

  /// PNG instead of JPEG.
  final bool png;
}

/// A designed card as a JPEG (quality 92) or PNG: the fill (a colour, a
/// gradient of two or three stops, or the photo placed, adjusted, blurred and
/// dimmed), the pattern, the grain and the vignette, the cover layer with
/// its shadow and border, then the words layer. Top level, for `compute`.
Uint8List composeCardDesign(CardComposeJob j) {
  final frame = RgbFrame(j.width, j.height);
  final kind = CardFillKind.values[j.fill.clamp(0, CardFillKind.values.length - 1)];
  final photo = j.photo;
  if (kind == CardFillKind.image && photo != null) {
    _placePhoto(frame, j, photo);
  } else if (kind == CardFillKind.linear) {
    _fillLinear(frame, j.colors, j.angle);
  } else if (kind == CardFillKind.radial) {
    _fillRadial(frame, j.colors, j.centerX, j.centerY, j.radius);
  } else {
    frame.fill(j.color & 0xFFFFFF);
  }
  if (j.pattern != CardPattern.none.index && (j.patternColor >>> 24) > 0) _drawPattern(frame, j);
  if (j.grain > 0) _addGrain(frame, j.grain, j.seed);
  if (j.vignette > 0) frame.vignette(j.vignette);
  final cover = j.cover;
  if ((cover != null || j.coverBlank) && j.coverSide >= 2) _drawCover(frame, j, cover);
  frame.draw(j.words, j.width, j.height, 0, 0);
  if (!j.png) return frame.encodeJpeg();
  return img.encodePng(img.Image.fromBytes(width: j.width, height: j.height, bytes: frame.rgb.buffer, bytesOffset: frame.rgb.offsetInBytes, numChannels: 3));
}

void _placePhoto(RgbFrame frame, CardComposeJob j, PhotoPixels photo) {
  var rgba = photo.rgba;
  var w = photo.width, h = photo.height;
  if (j.photoTurns % 4 != 0 || j.photoFlip) (rgba, w, h) = orientRgba(rgba, w, h, quarterTurns: j.photoTurns, flip: j.photoFlip);
  final matrix = j.photoMatrix;
  if (matrix != null) rgba = applyColorMatrix(rgba, matrix);
  frame.placePhoto(rgba, w, h,
      sigma: j.photoBlur,
      zoom: j.photoZoom,
      offsetX: j.photoOffsetX,
      offsetY: j.photoOffsetY,
      contain: j.photoContain,
      fillRgb: j.color & 0xFFFFFF);
  if (j.photoDimming > 0) frame.blendColor((j.photoDimming * 255).round().clamp(0, 255) << 24);
  if (j.photoGradientStart != 0 || j.photoGradientEnd != 0) frame.blendLinearGradient(j.photoGradientStart, j.photoGradientEnd, j.photoGradientAngle);
  if (j.photoVignette > 0) frame.vignette(j.photoVignette);
}

/// The colour at [t] (0 to 1) along evenly spaced [stops] (ARGB; alpha
/// ignored): (r, g, b).
(int, int, int) _along(List<int> stops, double t) {
  if (stops.isEmpty) return (0, 0, 0);
  if (stops.length == 1) return (stops[0] >> 16 & 0xFF, stops[0] >> 8 & 0xFF, stops[0] & 0xFF);
  final x = t.clamp(0.0, 1.0) * (stops.length - 1);
  final i = math.min(stops.length - 2, x.floor());
  final f = x - i;
  final a = stops[i], b = stops[i + 1];
  int mix(int shift) => ((a >> shift & 0xFF) + ((b >> shift & 0xFF) - (a >> shift & 0xFF)) * f).round();
  return (mix(16), mix(8), mix(0));
}

void _fillLinear(RgbFrame frame, List<int> stops, double angle) {
  final w = frame.width, h = frame.height;
  final a = angle * math.pi / 180;
  final dx = math.sin(a), dy = math.cos(a);
  final half = math.max(1e-6, (dx.abs() * w + dy.abs() * h) / 2);
  final cx = w / 2, cy = h / 2;
  final rgb = frame.rgb;
  for (var y = 0; y < h; y++) {
    var o = y * w * 3;
    final py = (y + 0.5 - cy) * dy;
    for (var x = 0; x < w; x++, o += 3) {
      final (r, g, b) = _along(stops, (((x + 0.5 - cx) * dx + py) / half + 1) / 2);
      rgb[o] = r;
      rgb[o + 1] = g;
      rgb[o + 2] = b;
    }
  }
}

void _fillRadial(RgbFrame frame, List<int> stops, double centerX, double centerY, double radius) {
  final w = frame.width, h = frame.height;
  final cx = centerX * w, cy = centerY * h;
  final reach = math.max(1.0, radius * math.sqrt(w * w + h * h) / 2);
  final rgb = frame.rgb;
  for (var y = 0; y < h; y++) {
    var o = y * w * 3;
    final ry = y + 0.5 - cy;
    for (var x = 0; x < w; x++, o += 3) {
      final rx = x + 0.5 - cx;
      final (r, g, b) = _along(stops, math.sqrt(rx * rx + ry * ry) / reach);
      rgb[o] = r;
      rgb[o + 1] = g;
      rgb[o + 2] = b;
    }
  }
}

void _drawPattern(RgbFrame frame, CardComposeJob j) {
  final w = frame.width, h = frame.height;
  final kind = CardPattern.values[j.pattern.clamp(0, CardPattern.values.length - 1)];
  final alpha = (j.patternColor >>> 24) / 255;
  final pr = j.patternColor >> 16 & 0xFF, pg = j.patternColor >> 8 & 0xFF, pb = j.patternColor & 0xFF;
  final scale = math.max(2.0, j.patternScale);
  final half = math.max(0.5, j.patternThickness / 2);
  final a = j.patternAngle * math.pi / 180;
  final ca = math.cos(a), sa = math.sin(a);
  final rgb = frame.rgb;
  double wrap(double v) => v - (v / scale).floorToDouble() * scale;
  for (var y = 0; y < h; y++) {
    var o = y * w * 3;
    final py = y + 0.5;
    for (var x = 0; x < w; x++, o += 3) {
      final px = x + 0.5;
      double coverage;
      switch (kind) {
        case CardPattern.stripes:
          final s = wrap(px * ca + py * sa);
          coverage = (half - (s - scale / 2).abs() + 0.5).clamp(0.0, 1.0);
        case CardPattern.dots:
          final fx = wrap(px) - scale / 2, fy = wrap(py) - scale / 2;
          coverage = (half - math.sqrt(fx * fx + fy * fy) + 0.5).clamp(0.0, 1.0);
        case CardPattern.grid:
          final fx = wrap(px), fy = wrap(py);
          final dxl = math.min(fx, scale - fx), dyl = math.min(fy, scale - fy);
          coverage = math.max((half - dxl + 0.5).clamp(0.0, 1.0), (half - dyl + 0.5).clamp(0.0, 1.0));
        case CardPattern.none:
          coverage = 0;
      }
      if (coverage <= 0) continue;
      final k = alpha * coverage;
      rgb[o] = (pr * k + rgb[o] * (1 - k)).round();
      rgb[o + 1] = (pg * k + rgb[o + 1] * (1 - k)).round();
      rgb[o + 2] = (pb * k + rgb[o + 2] * (1 - k)).round();
    }
  }
}

/// Monochrome film grain: the same for the same [seed] on every run.
void _addGrain(RgbFrame frame, double amount, int seed) {
  final rgb = frame.rgb;
  final strength = amount * 48;
  for (var y = 0; y < frame.height; y++) {
    var o = y * frame.width * 3;
    for (var x = 0; x < frame.width; x++, o += 3) {
      var h = (x * 374761393 + y * 668265263 + seed * 362437) & 0xFFFFFFFF;
      h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF;
      h ^= h >> 16;
      final n = ((h & 0xFFFF) / 0xFFFF * 2 - 1) * strength;
      final d = n.round();
      rgb[o] = (rgb[o] + d).clamp(0, 255);
      rgb[o + 1] = (rgb[o + 1] + d).clamp(0, 255);
      rgb[o + 2] = (rgb[o + 2] + d).clamp(0, 255);
    }
  }
}

/// Signed distance from (x, y) (relative to the centre) to the edge of the
/// cover's shape: negative inside.
double _shapeDistance(int shape, double x, double y, double half, double radius) {
  if (shape == CardCoverShape.circle.index || shape == CardCoverShape.vinyl.index) return math.sqrt(x * x + y * y) - half;
  final r = shape == CardCoverShape.rounded.index ? radius.clamp(0.0, half) : 0.0;
  final qx = x.abs() - (half - r), qy = y.abs() - (half - r);
  final ox = math.max(qx, 0.0), oy = math.max(qy, 0.0);
  return math.sqrt(ox * ox + oy * oy) + math.min(math.max(qx, qy), 0.0) - r;
}

double _smoothstep(double a, double b, double x) {
  if (b <= a) return x < a ? 0 : 1;
  final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// The label colour of a record without a picture: NEFORUM purple.
const int _blankLabel = 0xFF7D00FF;

void _drawCover(RgbFrame frame, CardComposeJob j, PhotoPixels? cover) {
  final shape = j.coverShape;
  final vinyl = shape == CardCoverShape.vinyl.index;
  final side = j.coverSide, half = side / 2;
  // The picture: its centre square, at the size it is drawn (a record shows
  // it as its label, 42% of the record).
  final labelHalf = vinyl ? half * 0.42 : half;
  final n = math.max(2, (labelHalf * 2).ceil());
  final Uint8List picture;
  if (cover == null) {
    picture = Uint8List(n * n * 4);
    for (var i = 0; i < picture.length; i += 4) {
      picture[i] = _blankLabel >> 16 & 0xFF;
      picture[i + 1] = _blankLabel >> 8 & 0xFF;
      picture[i + 2] = _blankLabel & 0xFF;
      picture[i + 3] = 255;
    }
  } else {
    final square = math.min(cover.width, cover.height).toDouble();
    picture = resample(cover.rgba, cover.width, cover.height, 4,
        x: (cover.width - square) / 2, y: (cover.height - square) / 2, w: square, h: square, dw: n, dh: n);
  }
  final cos = math.cos(j.coverRotation), sin = math.sin(j.coverRotation);
  final blur = math.max(1.0, j.coverShadowBlur);
  final reach = half * math.sqrt2 + blur * 2 + j.coverShadowOffsetY.abs() + 2;
  final x0 = math.max(0, (j.coverCenterX - reach).floor()), x1 = math.min(frame.width, (j.coverCenterX + reach).ceil());
  final y0 = math.max(0, (j.coverCenterY - reach).floor()), y1 = math.min(frame.height, (j.coverCenterY + reach).ceil());
  final rgb = frame.rgb;
  final border = math.min(j.coverBorder, half);
  final br = j.coverBorderColor >> 16 & 0xFF, bgc = j.coverBorderColor >> 8 & 0xFF, bb = j.coverBorderColor & 0xFF;
  final hole = half * 0.035;

  // (sr, sg, sb, sa) of the picture at (u, v) in its own pixels, bilinear;
  // premultiplied.
  (double, double, double, double) sample(double u, double v) {
    final fx = (u - 0.5).clamp(0.0, n - 1.0), fy = (v - 0.5).clamp(0.0, n - 1.0);
    final ix = fx.floor(), iy = fy.floor();
    final ax = fx - ix, ay = fy - iy;
    final jx = math.min(n - 1, ix + 1), jy = math.min(n - 1, iy + 1);
    double at(int px, int py, int c) => picture[(py * n + px) * 4 + c].toDouble();
    double mix(int c) =>
        (at(ix, iy, c) * (1 - ax) + at(jx, iy, c) * ax) * (1 - ay) + (at(ix, jy, c) * (1 - ax) + at(jx, jy, c) * ax) * ay;
    return (mix(0), mix(1), mix(2), mix(3));
  }

  for (var y = y0; y < y1; y++) {
    var o = (y * frame.width + x0) * 3;
    for (var x = x0; x < x1; x++, o += 3) {
      final dx = x + 0.5 - j.coverCenterX;
      // The shadow: the shape lower down, soft over its blur.
      if (j.coverShadow > 0) {
        final sy = y + 0.5 - j.coverCenterY - j.coverShadowOffsetY;
        final sd = _shapeDistance(shape, dx * cos + sy * sin, -dx * sin + sy * cos, half, j.coverRadius);
        final k = j.coverShadow * (1 - _smoothstep(-blur * 0.5, blur, sd));
        if (k > 0.002) {
          rgb[o] = (rgb[o] * (1 - k)).round();
          rgb[o + 1] = (rgb[o + 1] * (1 - k)).round();
          rgb[o + 2] = (rgb[o + 2] * (1 - k)).round();
        }
      }
      final dy = y + 0.5 - j.coverCenterY;
      final lx = dx * cos + dy * sin, ly = -dx * sin + dy * cos;
      final d = _shapeDistance(shape, lx, ly, half, j.coverRadius);
      var coverage = (0.5 - d).clamp(0.0, 1.0);
      if (coverage <= 0) continue;
      double r, g, b;
      if (vinyl) {
        final dist = math.sqrt(lx * lx + ly * ly);
        coverage *= (dist - hole + 0.5).clamp(0.0, 1.0);
        if (coverage <= 0) continue;
        if (dist < labelHalf + 0.5) {
          final (sr, sg, sb, sa) = sample(lx + labelHalf, ly + labelHalf);
          final edge = (labelHalf - dist + 0.5).clamp(0.0, 1.0);
          // The label over the record's black.
          final k = edge * sa / 255;
          r = sr * edge + 16 * (1 - k);
          g = sg * edge + 16 * (1 - k);
          b = sb * edge + 16 * (1 - k);
        } else {
          // Grooves, and a sheen across them.
          final groove = 18 + 7 * math.sin(dist * 0.9) + 4 * math.sin(dist * 0.23);
          final angle = math.atan2(ly, lx);
          final sheen = math.pow((0.5 + 0.5 * math.cos(2 * (angle + math.pi / 4))), 6) * 46;
          r = g = b = groove + sheen;
        }
      } else {
        final (sr, sg, sb, sa) = sample(lx + half, ly + half);
        final k = sa / 255;
        // A see-through picture sits on white, like a print.
        r = sr + 255 * (1 - k);
        g = sg + 255 * (1 - k);
        b = sb + 255 * (1 - k);
      }
      if (border > 0) {
        final t = (d + border + 0.5).clamp(0.0, 1.0);
        r = r * (1 - t) + br * t;
        g = g * (1 - t) + bgc * t;
        b = b * (1 - t) + bb * t;
      }
      rgb[o] = (r * coverage + rgb[o] * (1 - coverage)).round().clamp(0, 255);
      rgb[o + 1] = (g * coverage + rgb[o + 1] * (1 - coverage)).round().clamp(0, 255);
      rgb[o + 2] = (b * coverage + rgb[o + 2] * (1 - coverage)).round().clamp(0, 255);
    }
  }
}
