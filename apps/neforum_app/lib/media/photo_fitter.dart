import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_core/neforum_core.dart' show PhotoFit, PhotoFitMode;

/// A photo made to fit a platform's rules.
@immutable
class FittedPhoto {
  const FittedPhoto({required this.bytes, required this.width, required this.height, required this.mimeType});
  final Uint8List bytes;
  final int width;
  final int height;
  final String mimeType;
}

/// Makes [bytes] (a photo of type [mimeType]) meet [fit] with [mode]: the
/// shape brought within its limits (borders filled with a soft blur of the
/// photo, or the edges cut), then scaled down within the pixel limits and
/// saved as the right type within the size limit. Runs off the UI thread.
/// Null when the photo cannot be read (HEIC, a broken file).
Future<FittedPhoto?> fitPhoto(Uint8List bytes, String mimeType, PhotoFit fit, PhotoFitMode mode) => compute(
      _fitPhoto,
      _FitJob(
        bytes: bytes,
        outMime: fit.mimeTypes == null || fit.mimeTypes!.contains(mimeType) ? mimeType : 'image/jpeg',
        mode: mode,
        minAspect: fit.minAspect,
        maxAspect: fit.maxAspect,
        maxBytes: fit.maxBytes,
        maxPixels: fit.maxPixels,
        maxSideSum: fit.maxSideSum,
      ),
    );

class _FitJob {
  const _FitJob({
    required this.bytes,
    required this.outMime,
    required this.mode,
    this.minAspect,
    this.maxAspect,
    this.maxBytes,
    this.maxPixels,
    this.maxSideSum,
  });
  final Uint8List bytes;
  final String outMime;
  final PhotoFitMode mode;
  final double? minAspect;
  final double? maxAspect;
  final int? maxBytes;
  final int? maxPixels;
  final int? maxSideSum;
}

FittedPhoto? _fitPhoto(_FitJob j) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(j.bytes);
  } on Object {
    // A broken or unknown file can make the decoder throw.
    decoded = null;
  }
  if (decoded == null) return null;
  // Phone photos are often stored sideways with a "rotate me" tag.
  var image = img.bakeOrientation(decoded);

  final r = image.width / image.height;
  double? target;
  if (j.minAspect != null && r < j.minAspect! - PhotoFit.aspectTolerance) target = j.minAspect;
  if (j.maxAspect != null && r > j.maxAspect! + PhotoFit.aspectTolerance) target = j.maxAspect;
  if (target != null && j.mode != PhotoFitMode.off) {
    image = switch (j.mode) {
      PhotoFitMode.crop => _crop(image, target),
      PhotoFitMode.color => _colorFill(image, target),
      _ => _pad(image, target),
    };
  }

  var scale = 1.0;
  final px = image.width * image.height;
  if (j.maxPixels != null && px >= j.maxPixels!) scale = math.min(scale, math.sqrt((j.maxPixels! - 1) / px));
  if (j.maxSideSum != null && image.width + image.height > j.maxSideSum!) scale = math.min(scale, j.maxSideSum! / (image.width + image.height));
  if (scale < 1) image = _scaled(image, scale);

  // Within the size limit: lower JPEG quality first, then smaller pixels.
  final png = j.outMime == 'image/png';
  final qualities = png ? const [0] : const [90, 82, 74, 66];
  for (var round = 0; round < 12; round++) {
    for (final q in qualities) {
      final out = png ? img.encodePng(image, level: 6) : img.encodeJpg(image, quality: q);
      if (j.maxBytes == null || out.length <= j.maxBytes!) {
        return FittedPhoto(bytes: out, width: image.width, height: image.height, mimeType: png ? 'image/png' : 'image/jpeg');
      }
    }
    image = _scaled(image, 0.85);
  }
  return null;
}

img.Image _scaled(img.Image image, double scale) => img.copyResize(
      image,
      width: math.max(1, (image.width * scale).floor()),
      height: math.max(1, (image.height * scale).floor()),
      interpolation: img.Interpolation.average,
    );

/// Cut to [target] (width / height) around the centre.
img.Image _crop(img.Image image, double target) {
  final r = image.width / image.height;
  if (r < target) {
    final h = math.max(1, (image.width / target).round());
    return img.copyCrop(image, x: 0, y: (image.height - h) ~/ 2, width: image.width, height: h);
  }
  final w = math.max(1, (image.height * target).round());
  return img.copyCrop(image, x: (image.width - w) ~/ 2, y: 0, width: w, height: image.height);
}

/// The colours a colour fill uses next to each side of a photo: the dominant
/// colour of a thin band along that edge. For a photo given borders above and
/// below, [EdgeColours.start] is the top edge and [EdgeColours.end] the
/// bottom; for borders left and right, the left and right edges.
@immutable
class EdgeColours {
  const EdgeColours(this.start, this.end);

  /// 0xRRGGBB.
  final int start;
  final int end;
}

/// [EdgeColours] of the photo in [bytes]; [vertical] = borders go above and
/// below (a wide photo in a tall frame). Null when it cannot be read. Runs off
/// the UI thread.
Future<EdgeColours?> edgeColoursOf(Uint8List bytes, {required bool vertical}) => compute(_edgeColoursJob, (bytes, vertical));

EdgeColours? _edgeColoursJob((Uint8List, bool) a) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(a.$1);
  } on Object {
    decoded = null;
  }
  if (decoded == null) return null;
  var image = img.bakeOrientation(decoded);
  if (image.width > 400 || image.height > 400) {
    final s = 400 / math.max(image.width, image.height);
    image = _scaled(image, s);
  }
  return edgeColours(image, vertical: a.$2);
}

/// See [edgeColoursOf].
@visibleForTesting
EdgeColours edgeColours(img.Image image, {required bool vertical}) {
  final band = math.max(1, ((vertical ? image.height : image.width) * 0.06).round());
  if (vertical) {
    return EdgeColours(_dominant(image, 0, 0, image.width, band), _dominant(image, 0, image.height - band, image.width, band));
  }
  return EdgeColours(_dominant(image, 0, 0, band, image.height), _dominant(image, image.width - band, 0, band, image.height));
}

/// The most common colour in a rectangle: pixels grouped into coarse buckets
/// (16 levels per channel), the fullest bucket's average. Ignores
/// transparent pixels.
int _dominant(img.Image image, int x0, int y0, int w, int h) {
  final counts = <int, int>{};
  final sums = <int, List<int>>{};
  final step = math.max(1, math.sqrt(w * h / 4000).floor());
  for (var y = y0; y < y0 + h; y += step) {
    for (var x = x0; x < x0 + w; x += step) {
      final p = image.getPixel(x, y);
      if (p.a < 128) continue;
      final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
      final key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4);
      counts[key] = (counts[key] ?? 0) + 1;
      final s = sums.putIfAbsent(key, () => [0, 0, 0]);
      s[0] += r;
      s[1] += g;
      s[2] += b;
    }
  }
  if (counts.isEmpty) return 0x000000;
  final best = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
  final s = sums[best.key]!;
  final n = best.value;
  return (s[0] ~/ n) << 16 | (s[1] ~/ n) << 8 | (s[2] ~/ n);
}

/// Borders up to [target] (width / height) in the photo's own dominant
/// colours, one flowing into the other across the frame, like Instagram
/// stories: a wide photo in a tall frame gets its top edge's colour above and
/// its bottom edge's colour below.
img.Image _colorFill(img.Image image, double target) {
  final r = image.width / image.height;
  final vertical = r > target; // too wide: borders above and below
  final w = vertical ? image.width : math.max(image.width, (image.height * target).round());
  final h = vertical ? math.max(image.height, (image.width / target).round()) : image.height;
  final edges = edgeColours(image, vertical: vertical);
  final canvas = img.Image(width: w, height: h, numChannels: 3);
  final length = vertical ? h : w;
  final s = edges.start, e = edges.end;
  for (var i = 0; i < length; i++) {
    final t = length <= 1 ? 0.0 : i / (length - 1);
    final cr = ((s >> 16 & 0xFF) * (1 - t) + (e >> 16 & 0xFF) * t).round();
    final cg = ((s >> 8 & 0xFF) * (1 - t) + (e >> 8 & 0xFF) * t).round();
    final cb = ((s & 0xFF) * (1 - t) + (e & 0xFF) * t).round();
    if (vertical) {
      img.drawLine(canvas, x1: 0, y1: i, x2: w - 1, y2: i, color: img.ColorRgb8(cr, cg, cb));
    } else {
      img.drawLine(canvas, x1: i, y1: 0, x2: i, y2: h - 1, color: img.ColorRgb8(cr, cg, cb));
    }
  }
  return img.compositeImage(canvas, image, dstX: (w - image.width) ~/ 2, dstY: (h - image.height) ~/ 2);
}

/// Borders up to [target] (width / height), filled with the photo itself,
/// enlarged and blurred, so the photo sits on its own colours.
img.Image _pad(img.Image image, double target) {
  final r = image.width / image.height;
  final w = r < target ? math.max(image.width, (image.height * target).round()) : image.width;
  final h = r < target ? image.height : math.max(image.height, (image.width / target).round());

  // A tiny copy covering the new shape, blurred, then stretched back up:
  // smooth and cheap even for large photos.
  const sw = 48;
  final sh = math.max(1, (sw * h / w).round());
  final cover = math.max(sw / image.width, sh / image.height);
  var small = img.copyResize(
    image,
    width: math.max(sw, (image.width * cover).ceil()),
    height: math.max(sh, (image.height * cover).ceil()),
    interpolation: img.Interpolation.average,
  );
  small = img.copyCrop(small, x: (small.width - sw) ~/ 2, y: (small.height - sh) ~/ 2, width: sw, height: sh);
  small = img.gaussianBlur(small, radius: 3);
  final canvas = img.copyResize(small, width: w, height: h, interpolation: img.Interpolation.linear);
  return img.compositeImage(canvas, image, dstX: (w - image.width) ~/ 2, dstY: (h - image.height) ~/ 2);
}
