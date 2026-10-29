import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// How a video is re-encoded to bring it under a network's size limit
/// ([VideoCompositor.transcode]).
@immutable
class VideoShrinkPlan {
  const VideoShrinkPlan({required this.videoBitsPerSecond, required this.audioBitsPerSecond, required this.maxSide});

  final int videoBitsPerSecond;
  final int audioBitsPerSecond;

  /// The longest shown side of the copy, in pixels.
  final int maxSide;

  @override
  bool operator ==(Object other) =>
      other is VideoShrinkPlan &&
      other.videoBitsPerSecond == videoBitsPerSecond &&
      other.audioBitsPerSecond == audioBitsPerSecond &&
      other.maxSide == maxSide;

  @override
  int get hashCode => Object.hash(videoBitsPerSecond, audioBitsPerSecond, maxSide);

  @override
  String toString() => 'VideoShrinkPlan(video $videoBitsPerSecond bit/s, audio $audioBitsPerSecond bit/s, max side $maxSide)';
}

/// Share of the limit a copy aims at: the MP4 container and the encoder's
/// swings around its bitrate take the rest.
const double kShrinkTargetShare = 0.96;

/// Each retry, after a copy came out over the limit, aims this much lower.
const double kShrinkRetryFactor = 0.85;

/// Retries after the first copy.
const int kShrinkRetries = 3;

/// Below this many bits per pixel per frame H.264 turns to blocks; the copy
/// is made smaller instead.
const double kShrinkMinBitsPerPixel = 0.05;

/// Longest sides a copy may be scaled to, largest first.
const List<int> kShrinkSides = [1920, 1280, 960, 720, 640, 480, 360];

/// The least video bitrate worth making; a video that cannot have it within
/// the limit is too long to shrink.
const int kShrinkMinVideoBitsPerSecond = 64000;

/// The frame rate plans assume: phones record at 30, and most networks show
/// no more.
const double kShrinkAssumedFrameRate = 30;

/// AAC sound in a shrunk copy: 128 kbit/s, or the encoder's least, 96 kbit/s,
/// when the whole copy has less than 1 Mbit/s.
const int kShrinkAudioBitsPerSecond = 128000;
const int kShrinkLowAudioBitsPerSecond = 96000;

/// The plan for a copy of a [durationMs] video shown at [width] x [height]
/// that fits in [limitBytes]: the bitrate is the limit's
/// [kShrinkTargetShare] (lowered by [kShrinkRetryFactor] for each
/// [attempt] after the first) spread over the duration, less the sound's; the
/// size drops through [kShrinkSides] while that leaves fewer than
/// [kShrinkMinBitsPerPixel]. Never larger than the video. Null when the
/// video cannot be made to fit (too long for the limit) or its duration is
/// unknown.
VideoShrinkPlan? planVideoShrink({
  required int limitBytes,
  required int durationMs,
  required int width,
  required int height,
  bool hasAudio = true,
  int attempt = 0,
  double framesPerSecond = kShrinkAssumedFrameRate,
}) {
  if (limitBytes <= 0 || durationMs <= 0 || width <= 0 || height <= 0 || attempt < 0) return null;
  final seconds = durationMs / 1000;
  final budget = limitBytes * kShrinkTargetShare * math.pow(kShrinkRetryFactor, attempt) * 8;
  final total = budget / seconds;
  final audio = !hasAudio ? 0 : (total >= 1000000 ? kShrinkAudioBitsPerSecond : kShrinkLowAudioBitsPerSecond);
  final video = (total - audio).floor();
  if (video < kShrinkMinVideoBitsPerSecond) return null;

  final longest = math.max(width, height);
  final shortest = math.min(width, height);
  final fps = framesPerSecond > 0 ? framesPerSecond : kShrinkAssumedFrameRate;
  double bitsPerPixel(int side) {
    final scale = side / longest;
    return video / (longest * scale * math.max(1, shortest * scale) * fps);
  }

  var side = math.min(longest, kShrinkSides.first);
  for (final smaller in kShrinkSides) {
    if (smaller >= side) continue;
    if (bitsPerPixel(side) >= kShrinkMinBitsPerPixel) break;
    side = smaller;
  }
  return VideoShrinkPlan(videoBitsPerSecond: video, audioBitsPerSecond: audio, maxSide: side);
}

/// The frame a transcode makes of a video shown at [width] x [height] for
/// [maxSide]: scaled down (never up) so its longest side is at most
/// [maxSide], on even sides from 16 to 4096, as the runners do.
({int width, int height}) shrunkFrameSize(int width, int height, int maxSide) {
  final longest = math.max(width, height);
  final scale = longest <= 0 ? 1.0 : math.min(1.0, maxSide / longest);
  int even(double side) => ((side / 2).round() * 2).clamp(16, 4096);
  return (width: even(width * scale), height: even(height * scale));
}
