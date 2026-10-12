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
    image = j.mode == PhotoFitMode.crop ? _crop(image, target) : _pad(image, target);
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
