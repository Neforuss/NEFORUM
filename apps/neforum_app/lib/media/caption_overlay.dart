import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show Bidi;
import 'package:neforum_core/neforum_core.dart' show PhotoFitMode;

import 'aligned_text.dart';
import 'caption_style.dart';
import 'photo_composite.dart';
import 'photo_pixels.dart';
import 'text_card.dart';

/// The caption written onto a photo for Instagram and TikTok, the way their
/// own text tools set it: by default the network's font, white on a dark
/// rounded label, centred low on the picture, clear of the network's buttons
/// when the photo fills the screen. Everything else comes from the
/// [CaptionStyle]: top, middle or bottom, size, colours, alignment, font.
/// Measurements scale with the width (1080 px reference), so the composer
/// preview and the saved photo match.
class CaptionOverlayPainter extends CustomPainter {
  const CaptionOverlayPainter({required this.text, required this.font, this.style = const CaptionStyle(), this.safe = EdgeInsets.zero});

  final String text;

  /// Already resolved for the network ([TextCardFont.resolve]).
  final TextCardFont font;
  final CaptionStyle style;

  /// Room the network's buttons take, in pixels at 1080 wide.
  final EdgeInsets safe;

  @override
  void paint(Canvas canvas, Size size) {
    final words = text.trim();
    if (words.isEmpty) return;
    final u = size.width / 1080;
    final margin = 56 * u;
    final padX = style.padding * u, padY = style.padding * 0.6 * u;
    final left = margin + safe.left * u;
    final right = size.width - margin - safe.right * u;
    final top = margin + safe.top * u;
    final bottom = size.height - margin - safe.bottom * u;
    final maxW = math.max(10.0, right - left - padX * 2);
    final maxH = size.height * (style.fixedSize ? 0.6 : 0.34);
    final direction = Bidi.detectRtlDirectionality(words) ? TextDirection.rtl : TextDirection.ltr;

    final lines = _fitWords(words, style, font, direction, u, maxW, maxH, largest: 60, smallest: 34, step: 3);
    final boxW = lines.width + padX * 2, boxH = lines.height + padY * 2;
    final boxLeft = left + (right - left - boxW) * alignmentAnchor(style.alignment, direction);
    final boxTop = switch (style.placement) {
      CaptionPlacement.top => top,
      CaptionPlacement.middle => ((size.height - boxH) / 2).clamp(top, math.max(top, bottom - boxH)).toDouble(),
      _ => bottom - boxH,
    };
    if (style.background != CaptionBackground.none) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(boxLeft, boxTop, boxW, boxH), Radius.circular(18 * u)),
        Paint()..color = style.backgroundFill,
      );
    }
    lines.paint(canvas, Offset(boxLeft + padX, boxTop + padY));
    lines.dispose();
  }

  @override
  bool shouldRepaint(CaptionOverlayPainter old) => old.text != text || old.font != font || old.style != style || old.safe != safe;
}

/// [words] laid out within [maxWidth], as large as fits in [maxHeight] (from
/// [largest] down to [smallest] pixels at 1080 wide), or at the style's fixed
/// size; cut with an ellipsis when even that is too tall.
AlignedText _fitWords(String words, CaptionStyle style, TextCardFont font, TextDirection direction, double u, double maxWidth, double maxHeight,
    {required double largest, required double smallest, required double step}) {
  AlignedText layout(double fs, {int? maxLines}) => AlignedText(
        words,
        style: style.textStyle(font, fs, unit: u),
        alignment: style.alignment,
        direction: direction,
        maxLines: maxLines,
      )..layout(maxWidth);

  var fs = style.fixedSize ? 60 * u * style.textScale! : largest * u;
  final minFs = smallest * u;
  var tp = layout(fs);
  while (!style.fixedSize && tp.height > maxHeight && fs > minFs) {
    tp.dispose();
    fs = math.max(minFs, fs - step * u);
    tp = layout(fs);
  }
  if (tp.height > maxHeight) {
    final lines = math.max(1, (maxHeight / (fs * style.lineSpacing)).floor());
    tp.dispose();
    tp = layout(fs, maxLines: lines);
  }
  return tp;
}

/// The safe area for a caption on a photo of [aspect] (width / height) on
/// [platformId]: a full-screen (9:16) photo has the network's buttons over
/// it, a feed photo does not.
EdgeInsets captionSafeArea(String platformId, double? aspect) =>
    aspect != null && aspect < 0.62 ? fullScreenSafeArea(platformId) : EdgeInsets.zero;

/// Longest side of a captioned photo. Instagram and TikTok scale photos to
/// about 1080 x 1920 anyway.
const int kCaptionedMaxSide = 2160;

/// Smallest and largest share of the frame's height a caption block takes.
const double kCaptionBlockMinShare = 0.14;
const double kCaptionBlockMaxShare = 0.45;

/// Pixel size of a network frame of [aspect] (width / height): 1080 wide.
Size captionFrameSize(double aspect) => Size(1080, (1080 / aspect).roundToDouble());

/// Where a caption block and the content below it go in a frame
/// ([CaptionPlacement.blockAbove]): a band across the top, as tall as the
/// words need (between [kCaptionBlockMinShare] and [kCaptionBlockMaxShare] of
/// the frame, the words shrinking or cut to stay within it), and the rest of
/// the frame for the photo or video, which is scaled to fit there. On a
/// full-screen frame the band reaches under the network's top bar and the
/// words start below it.
class CaptionBlockLayout {
  CaptionBlockLayout._(this.frame, this.block, this.content, this._words, this._origin);

  factory CaptionBlockLayout.measure(
      {required String text, required CaptionStyle style, required TextCardFont font, required Size frame, EdgeInsets safe = EdgeInsets.zero}) {
    final u = frame.width / 1080;
    final margin = 56 * u;
    final padY = (style.padding * 0.6 + 28) * u;
    final left = margin + safe.left * u;
    final right = frame.width - margin - safe.right * u;
    final safeTop = safe.top * u;
    final maxW = math.max(10.0, right - left);
    final minBlock = frame.height * kCaptionBlockMinShare;
    final maxBlock = frame.height * kCaptionBlockMaxShare;
    final words = text.trim();
    final direction = Bidi.detectRtlDirectionality(words) ? TextDirection.rtl : TextDirection.ltr;
    final lines = _fitWords(words, style, font, direction, u, maxW, math.max(40 * u, maxBlock - safeTop - padY * 2),
        largest: 64, smallest: 34, step: 3);
    final blockH = (safeTop + padY * 2 + lines.height).clamp(minBlock, maxBlock).toDouble();
    final origin = Offset(
      left + (maxW - lines.width) * alignmentAnchor(style.alignment, direction),
      safeTop + (blockH - safeTop - lines.height) / 2,
    );
    return CaptionBlockLayout._(
      frame,
      Rect.fromLTWH(0, 0, frame.width, blockH),
      Rect.fromLTWH(0, blockH, frame.width, frame.height - blockH),
      lines,
      origin,
    );
  }

  final Size frame;

  /// The band holding the words.
  final Rect block;

  /// The rest of the frame, for the photo or video.
  final Rect content;

  final AlignedText _words;
  final Offset _origin;

  void paintWords(Canvas canvas) => _words.paint(canvas, _origin);

  void dispose() => _words.dispose();
}

/// Paints a caption block's words over a whole frame ([CaptionBlockLayout]);
/// with [paintBackground], the band's colour behind them too.
class CaptionBlockPainter extends CustomPainter {
  const CaptionBlockPainter({required this.text, required this.font, required this.style, this.safe = EdgeInsets.zero, this.paintBackground = false});

  final String text;

  /// Already resolved for the network ([TextCardFont.resolve]).
  final TextCardFont font;
  final CaptionStyle style;
  final EdgeInsets safe;
  final bool paintBackground;

  @override
  void paint(Canvas canvas, Size size) {
    final layout = CaptionBlockLayout.measure(text: text, style: style, font: font, frame: size, safe: safe);
    if (paintBackground && style.background != CaptionBackground.none) canvas.drawRect(layout.block, Paint()..color = style.backgroundFill);
    layout.paintWords(canvas);
    layout.dispose();
  }

  @override
  bool shouldRepaint(CaptionBlockPainter old) =>
      old.text != text || old.font != font || old.style != style || old.safe != safe || old.paintBackground != paintBackground;
}

/// The photo in [bytes] with [text] written on it, as a JPEG. Null when the
/// photo cannot be read.
///
/// On the photo ([CaptionPlacement.isOverlay]): the photo keeps its own size
/// and the words go over it ([CaptionOverlayPainter]). In a block above
/// ([CaptionPlacement.blockAbove], with the network's [frameAspect]): a
/// picture of the whole frame, the block at the top and the whole photo
/// scaled into the rest ([CaptionBlockLayout]); with [fit] crop the photo is
/// cut to fill the rest instead. Room the photo leaves is filled the way
/// Settings fit photos: the photo's own colours for a colour fill, a soft blur
/// of it otherwise, under the style's background colour.
///
/// The engine only rasterizes the words ([rasterizeWordsLayer]); the photo is
/// placed, blurred and composited on the CPU ([composeCaptionedPhoto]). The
/// photo never becomes an engine image: on some Windows PCs reading back a
/// picture that held one never finished (NEFORUM 1.2.0).
Future<({Uint8List bytes, int width, int height})?> renderCaptionedPhoto(Uint8List bytes,
    {required String text,
    required TextCardFont font,
    required String platformId,
    CaptionStyle style = const CaptionStyle(),
    double? frameAspect,
    PhotoFitMode fit = PhotoFitMode.pad}) async {
  final px = await decodePhotoPixels(bytes, maxSide: kCaptionedMaxSide);
  if (px == null) return null;
  final block = style.placement == CaptionPlacement.blockAbove && frameAspect != null;
  final size = block ? captionFrameSize(frameAspect) : Size(px.width.toDouble(), px.height.toDouble());
  final width = size.width.round(), height = size.height.round();
  Rect? content;
  final words = await rasterizeWordsLayer(width, height, (canvas) {
    if (block) {
      final layout = CaptionBlockLayout.measure(text: text, style: style, font: font, frame: size, safe: captionSafeArea(platformId, frameAspect));
      content = layout.content;
      layout.paintWords(canvas);
      layout.dispose();
    } else {
      CaptionOverlayPainter(text: text, font: font, style: style, safe: captionSafeArea(platformId, px.width / px.height)).paint(canvas, size);
    }
  });
  final job = CaptionComposeJob(
    photo: px.rgba,
    photoWidth: px.width,
    photoHeight: px.height,
    words: words,
    width: width,
    height: height,
    content: content,
    fit: fit,
    topColor: px.topColor,
    bottomColor: px.bottomColor,
    backgroundArgb: style.background == CaptionBackground.none ? null : style.backgroundFill.toARGB32(),
  );
  return (bytes: await compute(composeCaptionedPhoto, job), width: width, height: height);
}

/// Everything [composeCaptionedPhoto] needs, sent to an isolate.
@immutable
class CaptionComposeJob {
  const CaptionComposeJob({
    required this.photo,
    required this.photoWidth,
    required this.photoHeight,
    required this.words,
    required this.width,
    required this.height,
    this.content,
    this.fit = PhotoFitMode.pad,
    this.topColor = 0,
    this.bottomColor = 0,
    this.backgroundArgb,
  });

  /// The photo as straight RGBA, upright.
  final Uint8List photo;
  final int photoWidth;
  final int photoHeight;

  /// The words layer: straight RGBA, [width] x [height], transparent around
  /// the words (and the label behind them, on the photo).
  final Uint8List words;
  final int width;
  final int height;

  /// Where the photo goes in a frame with a caption block above it
  /// ([CaptionBlockLayout.content]); null when the words go on the photo,
  /// which then fills the picture.
  final Rect? content;
  final PhotoFitMode fit;

  /// The photo's edge colours (0xRRGGBB), for a colour fill.
  final int topColor;
  final int bottomColor;

  /// The style's background colour over the whole frame, in a block above;
  /// null for none.
  final int? backgroundArgb;
}

/// The captioned photo of [job] as a JPEG (quality 92), composed on the CPU:
/// in a block above, the room around the photo (a blur of it, or its colours
/// for a colour fill), the style's background colour, the photo fitted (or
/// cut, for crop) into the content rectangle; then the words over it all.
/// Run with [compute].
Uint8List composeCaptionedPhoto(CaptionComposeJob job) {
  final frame = RgbFrame(job.width, job.height);
  final content = job.content;
  if (content == null) {
    frame.draw(job.photo, job.photoWidth, job.photoHeight, 0, 0);
  } else {
    if (job.fit == PhotoFitMode.color) {
      frame.fillVerticalGradient(job.topColor, job.bottomColor);
    } else {
      frame.coverWith(job.photo, job.photoWidth, job.photoHeight, sigma: 48 * job.width / 1080);
    }
    if (job.backgroundArgb != null) frame.blendColor(job.backgroundArgb!);
    final x = content.left.round(), y = content.top.round();
    final ({double x, double y, double w, double h}) src;
    final int w, h, dx, dy;
    if (job.fit == PhotoFitMode.crop) {
      w = content.right.round() - x;
      h = content.bottom.round() - y;
      src = coverSource(job.photoWidth, job.photoHeight, w.toDouble(), h.toDouble());
      dx = x;
      dy = y;
    } else {
      final scale = math.min(content.width / job.photoWidth, content.height / job.photoHeight);
      w = math.max(1, (job.photoWidth * scale).round());
      h = math.max(1, (job.photoHeight * scale).round());
      src = (x: 0, y: 0, w: job.photoWidth.toDouble(), h: job.photoHeight.toDouble());
      dx = (content.left + (content.width - w) / 2).round();
      dy = (content.top + (content.height - h) / 2).round();
    }
    if (w > 0 && h > 0) {
      final placed = resample(job.photo, job.photoWidth, job.photoHeight, 4, x: src.x, y: src.y, w: src.w, h: src.h, dw: w, dh: h);
      frame.draw(placed, w, h, dx, dy, premultiplied: true);
    }
  }
  frame.draw(job.words, job.width, job.height, 0, 0);
  return frame.encodeJpeg();
}

/// A caption block for a video, ready for the video compositor: a picture of
/// the whole frame that is transparent except for the block (its colour and
/// the words), the rectangle the video is scaled into, and the colour the
/// frame is filled with around the video.
@immutable
class CaptionBlockOverlay {
  const CaptionBlockOverlay({required this.png, required this.frameWidth, required this.frameHeight, required this.contentRect, required this.backgroundArgb});

  /// PNG with transparency, [frameWidth] x [frameHeight].
  final Uint8List png;
  final int frameWidth;
  final int frameHeight;

  /// Where the video goes (aspect kept, centred), in frame pixels.
  final Rect contentRect;

  /// Opaque ARGB filling the frame behind the video.
  final int backgroundArgb;
}

/// Renders the caption block for a video in a frame of [frameAspect] (TikTok
/// 9:16, Instagram 4:5, stories 9:16) on [platformId]: see
/// [CaptionBlockOverlay]. The block is drawn in [CaptionBlockOverlay.backgroundArgb],
/// so it matches the frame around the video; a style without a background
/// gets black.
Future<CaptionBlockOverlay> renderCaptionBlockOverlay(
    {required String text, required CaptionStyle style, required String platformId, required double frameAspect}) async {
  final size = captionFrameSize(frameAspect);
  final layout = CaptionBlockLayout.measure(
    text: text,
    style: style,
    font: style.font.resolve(platformId),
    frame: size,
    safe: captionSafeArea(platformId, frameAspect),
  );
  final background = style.opaqueBackgroundArgb;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  canvas.drawRect(layout.block, Paint()..color = Color(background));
  layout.paintWords(canvas);
  final content = layout.content;
  layout.dispose();
  final picture = recorder.endRecording();
  final width = size.width.round(), height = size.height.round();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (data == null) throw StateError('Could not read back the caption block');
  return CaptionBlockOverlay(
    png: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    frameWidth: width,
    frameHeight: height,
    contentRect: content,
    backgroundArgb: background,
  );
}
