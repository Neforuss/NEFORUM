import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../platform/video_compositor.dart';

// 1.3: video

/// Longest side of a preview frame: enough for the largest thumbnail
/// (Activity's zoomed view scales it up a little).
const int kPreviewFrameMaxSide = 640;

/// Frames tried before the clearest of them is shown.
const int kPreviewFrameTries = 4;

/// A frame darker than this mean luminance (0 to 255) is taken as black: a
/// fade in, a lens cap.
const double kBlankFrameMaxMeanLuminance = 16;

/// A frame whose luminance varies less than this (variance, in luminance
/// levels squared) is taken as flat: a title card's plain background, a
/// blank wall.
const double kFlatFrameMaxVariance = 40;

/// Mean and variance of the luminance (BT.601, 0 to 255) of an image, from a
/// grid of up to 64 x 64 samples; null when [png] cannot be decoded. Top
/// level, for [compute].
({double mean, double variance})? frameLuminance(Uint8List png) {
  img.Image? image;
  try {
    image = img.decodePng(png);
  } on Object {
    return null;
  }
  if (image == null || image.width == 0 || image.height == 0) return null;
  final stepX = math.max(1, image.width ~/ 64);
  final stepY = math.max(1, image.height ~/ 64);
  var n = 0;
  var sum = 0.0;
  var squares = 0.0;
  for (var y = stepY ~/ 2; y < image.height; y += stepY) {
    for (var x = stepX ~/ 2; x < image.width; x += stepX) {
      final p = image.getPixel(x, y);
      final luma = 0.299 * p.rNormalized + 0.587 * p.gNormalized + 0.114 * p.bNormalized;
      final level = luma * 255;
      sum += level;
      squares += level * level;
      n++;
    }
  }
  if (n == 0) return null;
  final mean = sum / n;
  return (mean: mean, variance: math.max(0.0, squares / n - mean * mean));
}

/// Whether a frame with this luminance says nothing about the video: nearly
/// black, or nearly one flat shade.
bool isUninformativeFrame(double meanLuminance, double variance) =>
    meanLuminance < kBlankFrameMaxMeanLuminance || variance < kFlatFrameMaxVariance;

/// Where in a [durationMs] video to look for a preview: a random point from
/// 10% to 90% of it, past the fade in and before the credits. The start
/// when the duration is unknown.
int previewFramePosition(int durationMs, math.Random random) {
  if (durationMs <= 0) return 0;
  return (durationMs * (0.1 + 0.8 * random.nextDouble())).round();
}

/// A still of the video at [path] for its thumbnail ([VideoCompositor.frameAt]):
/// up to [kPreviewFrameTries] random points ([previewFramePosition]) are
/// tried until a frame is neither black nor flat
/// ([isUninformativeFrame]); otherwise the most varied one. Null without a
/// compositor or when no frame can be read.
Future<VideoFrame?> readPreviewFrame(VideoCompositor compositor, String path, {math.Random? random}) async {
  final rng = random ?? math.Random();
  final probe = await compositor.probe(path);
  if (probe == null) return null;
  VideoFrame? best;
  var bestVariance = -1.0;
  for (var i = 0; i < kPreviewFrameTries; i++) {
    final frame = await compositor.frameAt(path, previewFramePosition(probe.durationMs, rng), maxSide: kPreviewFrameMaxSide);
    if (frame == null) continue;
    ({double mean, double variance})? stats;
    try {
      stats = await compute(frameLuminance, frame.png);
    } on Object catch (e) {
      debugPrint('Could not measure a frame of $path: $e');
    }
    if (stats == null) continue;
    if (!isUninformativeFrame(stats.mean, stats.variance)) return frame;
    if (stats.variance > bestVariance) {
      best = frame;
      bestVariance = stats.variance;
    }
    // A video without a known length has one place to look.
    if (probe.durationMs <= 0) break;
  }
  return best;
}

/// The preview frame of a video attachment, by media id and path, for
/// [MediaThumb]. Kept in memory for this session only: it is never saved,
/// uploaded or used as the video's cover.
final videoPreviewFrameProvider = FutureProvider.family<VideoFrame?, ({String mediaId, String path})>(
  (ref, media) => readPreviewFrame(VideoCompositor.instance, media.path),
);
