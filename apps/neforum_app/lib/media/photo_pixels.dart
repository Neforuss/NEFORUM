import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'photo_fitter.dart' show edgeColours;

/// A photo as straight RGBA pixels, turned upright, with what the renderers
/// need to know about it.
@immutable
class PhotoPixels {
  const PhotoPixels({required this.rgba, required this.width, required this.height, required this.luminance, required this.topColor, required this.bottomColor});
  final Uint8List rgba;
  final int width;
  final int height;

  /// Average brightness, 0 (black) to 1 (white).
  final double luminance;

  /// Dominant colours along the top and bottom edges (0xRRGGBB): the colours
  /// a colour fill uses above and below the photo.
  final int topColor;
  final int bottomColor;
}

/// The photo in [bytes] as [PhotoPixels], turned upright (phone photos carry a
/// "rotate me" tag) and at most [maxSide] on the long side. Null when it
/// cannot be read (HEIC, a broken file). Runs off the UI thread.
Future<PhotoPixels?> decodePhotoPixels(Uint8List bytes, {required int maxSide}) => compute(_decodePhotoPixels, (bytes, maxSide));

PhotoPixels? _decodePhotoPixels((Uint8List, int) a) {
  final (bytes, maxSide) = a;
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    // A broken or unknown file can make the decoder throw.
    decoded = null;
  }
  if (decoded == null) return null;
  var image = img.bakeOrientation(decoded);
  final longest = math.max(image.width, image.height);
  if (longest > maxSide) {
    final s = maxSide / longest;
    image = img.copyResize(image,
        width: math.max(1, (image.width * s).round()), height: math.max(1, (image.height * s).round()), interpolation: img.Interpolation.average);
  }
  final small = img.copyResize(image, width: math.min(64, image.width), height: math.min(64, image.height), interpolation: img.Interpolation.average);
  var sum = 0.0;
  for (final p in small) {
    sum += (0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b) / 255;
  }
  // The same colours a colour fill uses (Settings > Posting).
  final edges = edgeColours(small, vertical: true);
  final rgba = image.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
  return PhotoPixels(
    rgba: rgba,
    width: image.width,
    height: image.height,
    luminance: sum / (small.width * small.height),
    topColor: edges.start,
    bottomColor: edges.end,
  );
}

/// [px] as an image that can be drawn on a canvas.
Future<ui.Image> imageFromPixels(PhotoPixels px) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(px.rgba, px.width, px.height, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// Reads [image] back as straight RGBA bytes. Null when the engine cannot.
Future<Uint8List?> rgbaOf(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
