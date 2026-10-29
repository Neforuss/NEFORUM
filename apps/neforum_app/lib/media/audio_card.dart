import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../brand/neforum_logo.dart';
import '../theme/tokens.dart';
import 'photo_composite.dart';

/// The still picture of a track that goes to a video-only network as a
/// video ([VideoCompositor.renderAudioVideo]) when the post has no photo: the
/// title and the post's first words on the NEFORUM brand background, with
/// the track's type and length.
class AudioCardPainter extends CustomPainter {
  const AudioCardPainter({required this.title, this.subtitle, this.details});

  final String title;

  /// The post's first words, when they say more than the title.
  final String? subtitle;

  /// "FLAC · 3:04".
  final String? details;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = Brand.markGradient.createShader(rect));
    final unit = math.min(size.width, size.height) / 1080;
    final pad = 88 * unit;
    final width = size.width - 2 * pad;

    // Sound bars: the picture says "listen" before anyone reads it.
    final bars = Paint()..color = Brand.yellow;
    const heights = [0.35, 0.7, 1.0, 0.55, 0.85, 0.4, 0.65];
    final barWidth = 22 * unit, gap = 16 * unit, tall = 150 * unit;
    for (var i = 0; i < heights.length; i++) {
      final h = tall * heights[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(pad + i * (barWidth + gap), pad + tall - h, barWidth, h), Radius.circular(barWidth / 2)),
        bars,
      );
    }

    final top = pad + tall + 64 * unit;
    final titlePainter = _text(title, 96 * unit, FontWeight.w800, Colors.white, width, maxLines: 4, family: Fonts.display);
    titlePainter.paint(canvas, Offset(pad, top));
    var y = top + titlePainter.height + 36 * unit;
    final sub = subtitle;
    if (sub != null && sub.isNotEmpty) {
      final p = _text(sub, 44 * unit, FontWeight.w500, Colors.white.withValues(alpha: 0.86), width, maxLines: 5);
      p.paint(canvas, Offset(pad, y));
      y += p.height;
    }

    // Footer: the NEFORUM mark and the track's type and length.
    final mark = 72 * unit;
    final footerY = size.height - pad - mark;
    paintNeforumMark(canvas, Rect.fromLTWH(pad, footerY, mark, mark));
    final d = details;
    if (d != null && d.isNotEmpty) {
      final p = _text(d, 40 * unit, FontWeight.w700, Brand.yellow, width - mark - 32 * unit, maxLines: 1);
      p.paint(canvas, Offset(pad + mark + 32 * unit, footerY + (mark - p.height) / 2));
    }
  }

  static TextPainter _text(String s, double size, FontWeight weight, Color color, double width, {int maxLines = 1, String family = Fonts.body}) =>
      TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontFamily: family, fontSize: size, fontWeight: weight, color: color, height: 1.15)),
        textDirection: TextDirection.ltr,
        maxLines: maxLines,
        ellipsis: '…',
      )..layout(maxWidth: width);

  @override
  bool shouldRepaint(AudioCardPainter old) => old.title != title || old.subtitle != subtitle || old.details != details;
}

/// The card ([AudioCardPainter]) as a [width] x [height] PNG.
Future<Uint8List> renderAudioCardPng({required int width, required int height, required String title, String? subtitle, String? details}) async {
  final rgba = await rasterizeWordsLayer(width, height, (canvas) {
    AudioCardPainter(title: title, subtitle: subtitle, details: details).paint(canvas, Size(width.toDouble(), height.toDouble()));
  });
  return compute(encodeRgbaPng, (rgba, width, height));
}

/// [photo] (any type the image package reads) scaled to cover a [width] x
/// [height] frame and cut to it, centred, as a PNG; null when the photo
/// cannot be read. Decoded on the CPU, in an isolate, never as an engine
/// image (see photo_composite.dart).
Future<Uint8List?> coverPhotoPng(Uint8List photo, {required int width, required int height}) =>
    compute(coverPhotoPngJob, (photo, width, height));

/// [coverPhotoPng]'s work; top level, for [compute].
Uint8List? coverPhotoPngJob((Uint8List, int, int) job) {
  final (bytes, width, height) = job;
  final decoded = img.decodeImage(bytes);
  if (decoded == null || decoded.width == 0 || decoded.height == 0) return null;
  final upright = img.bakeOrientation(decoded);
  final src = coverSource(upright.width, upright.height, width.toDouble(), height.toDouble());
  final cropped = img.copyCrop(upright, x: src.x.round(), y: src.y.round(), width: math.max(1, src.w.round()), height: math.max(1, src.h.round()));
  final scaled = img.copyResize(cropped, width: width, height: height, interpolation: img.Interpolation.average);
  return img.encodePng(scaled.convert(numChannels: 3));
}

/// PNG from straight RGBA pixels; top level, for [compute].
Uint8List encodeRgbaPng((Uint8List, int, int) job) {
  final (rgba, width, height) = job;
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodePng(image);
}
