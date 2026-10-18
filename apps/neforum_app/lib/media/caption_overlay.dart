import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart' show Bidi;

import 'text_card.dart';

/// The caption written onto a photo for Instagram and TikTok, the way their
/// own text tools set it: the network's font, white on a dark rounded label,
/// centred low on the picture, clear of the network's buttons when the photo
/// fills the screen. Measurements scale with the width (1080 px reference),
/// so the composer preview and the saved photo match.
class CaptionOverlayPainter extends CustomPainter {
  const CaptionOverlayPainter({required this.text, required this.font, this.safe = EdgeInsets.zero});

  final String text;

  /// Already resolved for the network ([TextCardFont.resolve]).
  final TextCardFont font;

  /// Room the network's buttons take, in pixels at 1080 wide.
  final EdgeInsets safe;

  @override
  void paint(Canvas canvas, Size size) {
    final words = text.trim();
    if (words.isEmpty) return;
    final u = size.width / 1080;
    final margin = 56 * u;
    final padX = 30 * u, padY = 18 * u;
    final left = margin + safe.left * u;
    final right = size.width - margin - safe.right * u;
    final bottom = size.height - margin - safe.bottom * u;
    final maxW = math.max(10.0, right - left - padX * 2);
    final maxH = size.height * 0.34;
    final rtl = Bidi.detectRtlDirectionality(words);

    TextPainter layout(double fs, {int? maxLines}) => TextPainter(
          text: TextSpan(text: words, style: font.style(fontSize: fs, height: 1.22, color: Colors.white)),
          textAlign: TextAlign.center,
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          maxLines: maxLines,
          ellipsis: maxLines == null ? null : '…',
        )..layout(maxWidth: maxW);

    var fs = 60 * u;
    final minFs = 34 * u;
    var tp = layout(fs);
    while (tp.height > maxH && fs > minFs) {
      tp.dispose();
      fs = math.max(minFs, fs - 3 * u);
      tp = layout(fs);
    }
    if (tp.height > maxH) {
      final lines = math.max(1, (maxH / (fs * 1.22)).floor());
      tp.dispose();
      tp = layout(fs, maxLines: lines);
    }
    final centre = (left + right) / 2;
    final box = RRect.fromRectAndRadius(
      Rect.fromLTRB(centre - tp.width / 2 - padX, bottom - tp.height - padY * 2, centre + tp.width / 2 + padX, bottom),
      Radius.circular(18 * u),
    );
    canvas.drawRRect(box, Paint()..color = const Color(0xA6000000));
    tp.paint(canvas, Offset(centre - tp.width / 2, box.top + padY));
    tp.dispose();
  }

  @override
  bool shouldRepaint(CaptionOverlayPainter old) => old.text != text || old.font != font || old.safe != safe;
}

/// The safe area for a caption on a photo of [aspect] (width / height) on
/// [platformId]: a full-screen (9:16) photo has the network's buttons over
/// it, a feed photo does not.
EdgeInsets captionSafeArea(String platformId, double? aspect) =>
    aspect != null && aspect < 0.62 ? fullScreenSafeArea(platformId) : EdgeInsets.zero;

/// Longest side of a captioned photo. Instagram and TikTok scale photos to
/// about 1080 x 1920 anyway.
const int kCaptionedMaxSide = 2160;

/// The photo in [bytes] with [text] written on it ([CaptionOverlayPainter]),
/// as a JPEG. Null when the photo cannot be read.
Future<({Uint8List bytes, int width, int height})?> renderCaptionedPhoto(Uint8List bytes,
    {required String text, required TextCardFont font, required String platformId}) async {
  final px = await compute(_pixelsFor, bytes);
  if (px == null) return null;
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(px.rgba, px.width, px.height, ui.PixelFormat.rgba8888, completer.complete);
  final photo = await completer.future;
  final size = Size(px.width.toDouble(), px.height.toDouble());
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  canvas.drawImage(photo, Offset.zero, Paint()..filterQuality = FilterQuality.high);
  photo.dispose();
  CaptionOverlayPainter(text: text, font: font, safe: captionSafeArea(platformId, px.width / px.height)).paint(canvas, size);
  final picture = recorder.endRecording();
  final out = await picture.toImage(px.width, px.height);
  picture.dispose();
  final data = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
  out.dispose();
  if (data == null) return null;
  final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return (bytes: await compute(encodeRgbaJpeg, (rgba, px.width, px.height)), width: px.width, height: px.height);
}

/// Straight RGBA pixels of a photo, turned upright (phone photos carry a
/// "rotate me" tag) and at most [kCaptionedMaxSide] on the long side.
({Uint8List rgba, int width, int height})? _pixelsFor(Uint8List bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    decoded = null;
  }
  if (decoded == null) return null;
  var image = img.bakeOrientation(decoded);
  final longest = math.max(image.width, image.height);
  if (longest > kCaptionedMaxSide) {
    final s = kCaptionedMaxSide / longest;
    image = img.copyResize(image,
        width: math.max(1, (image.width * s).round()), height: math.max(1, (image.height * s).round()), interpolation: img.Interpolation.average);
  }
  final rgba = image.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
  return (rgba: rgba, width: image.width, height: image.height);
}
