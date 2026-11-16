import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_core/neforum_core.dart' show MediaAttachment, PhotoFit, PhotoFitMode;

import '../platform/media_files.dart';
import 'photo_fitter.dart';

// 1.4.4: an animated GIF becomes an MP4 for a network that takes no GIF
// (Instagram's API: JPEG photos, MP4 or MOV videos). Dart reads the GIF and
// draws each of its pictures in the video's frame (the way Settings fit
// photos); the video compositor of each runner
// ([VideoCompositor.renderFramesVideo]) encodes them as H.264 at a fixed
// frame rate, each picture held for as many frames as the GIF shows it.

/// Frames per second of a GIF's video: inside every network's 23-60 range, and
/// fine enough for GIF timing (GIF delays are in hundredths of a second).
const int kGifVideoFrameRate = 30;

/// The shortest video a GIF becomes: the GIF plays again (whole loops) until
/// the video lasts at least this long. About as long as Instagram shows a
/// photo story, and over the 3 seconds every Instagram video needs.
const int kGifVideoMinMs = 5000;

/// The longest: Instagram's story video limit (and its carousel videos'). A
/// GIF longer than this is cut there.
const int kGifVideoMaxMs = 60000;

/// The long side of a GIF's video at least (a small GIF is scaled up, so the
/// network does not show it blurred and tiny) and at most.
const int kGifVideoMinLongSide = 1280;
const int kGifVideoMaxLongSide = 1920;

/// What a GIF file says about its pictures, read without decoding them.
@immutable
class GifAnimation {
  const GifAnimation({required this.width, required this.height, required this.frameDelaysMs});

  /// The GIF's canvas.
  final int width;
  final int height;

  /// How long each picture is shown, in milliseconds, as browsers show them
  /// ([gifFrameDelayMs]).
  final List<int> frameDelaysMs;

  int get frameCount => frameDelaysMs.length;

  /// More than one picture: it moves. A one-picture GIF is a still photo.
  bool get isAnimated => frameDelaysMs.length > 1;

  /// One pass through every picture.
  int get durationMs => frameDelaysMs.fold(0, (a, b) => a + b);
}

/// How long a GIF picture with a delay of [centiseconds] is shown: as every
/// browser shows it, a delay of 0 or 1 hundredth (meant as "as fast as
/// possible" by old tools) is 100 ms.
int gifFrameDelayMs(int centiseconds) => centiseconds <= 1 ? 100 : centiseconds * 10;

/// The pictures and timing of the GIF in [bytes]; null when it is not a GIF
/// that can be read.
GifAnimation? readGifAnimation(Uint8List bytes) {
  if (!isGifBytes(bytes)) return null;
  try {
    final info = img.GifDecoder().startDecode(bytes);
    if (info == null || info.frames.isEmpty || info.width <= 0 || info.height <= 0) return null;
    return GifAnimation(
      width: info.width,
      height: info.height,
      frameDelaysMs: [for (final f in info.frames) gifFrameDelayMs(f.duration)],
    );
  } on Object {
    return null;
  }
}

/// One picture of a GIF's video: the GIF's picture [frame] held for [count]
/// video frames.
typedef GifVideoSpan = ({int frame, int count});

/// When each picture of a GIF shows in its video, at [frameRate] frames per
/// second.
@immutable
class GifVideoTimeline {
  const GifVideoTimeline({required this.spans, required this.frameRate, required this.loops});

  /// In playing order, the GIF looping [loops] times (the last loop may be cut
  /// at [kGifVideoMaxMs]).
  final List<GifVideoSpan> spans;
  final int frameRate;
  final int loops;

  /// Video frames in all.
  int get frameCount => spans.fold(0, (a, s) => a + s.count);

  /// The video's length.
  int get durationMs => (frameCount * 1000 / frameRate).round();

  /// The GIF pictures the video shows: a picture shorter than one video frame
  /// can fall between two frames and is never drawn.
  Set<int> get framesUsed => {for (final s in spans) s.frame};
}

/// The timeline of a GIF whose pictures last [delaysMs]: played again until
/// it lasts at least [minMs] (whole loops), cut at [maxMs]. Each picture
/// keeps its time: it starts on the video frame nearest its start in the GIF,
/// so rounding never adds up over a long GIF.
GifVideoTimeline gifVideoTimeline(List<int> delaysMs,
    {int frameRate = kGifVideoFrameRate, int minMs = kGifVideoMinMs, int maxMs = kGifVideoMaxMs}) {
  if (delaysMs.isEmpty) throw ArgumentError('A GIF has at least one picture');
  final pass = delaysMs.fold<int>(0, (a, b) => a + math.max<int>(1, b));
  final loops = math.max(1, (minMs / pass).ceil());
  final spans = <GifVideoSpan>[];
  var start = 0;
  var written = 0;
  outer:
  for (var loop = 0; loop < loops; loop++) {
    for (var i = 0; i < delaysMs.length; i++) {
      if (start >= maxMs) break outer;
      final end = math.min<int>(maxMs, start + math.max<int>(1, delaysMs[i]));
      start = end;
      final upTo = (end * frameRate / 1000).round();
      final count = upTo - written;
      if (count <= 0) continue;
      written = upTo;
      // The same picture twice in a row (a one-picture GIF) is one span.
      if (spans.isNotEmpty && spans.last.frame == i) {
        spans[spans.length - 1] = (frame: i, count: spans.last.count + count);
      } else {
        spans.add((frame: i, count: count));
      }
    }
  }
  return GifVideoTimeline(spans: spans, frameRate: frameRate, loops: loops);
}

/// The pixel size of the video a [width] x [height] GIF becomes under
/// [rules] with [mode]: the shape the rules give a photo (borders to 4:5 for
/// Instagram's feed, 9:16 for a story that fills the frame, its own shape
/// for a story that does not), its long side scaled into
/// [kGifVideoMinLongSide]..[kGifVideoMaxLongSide], on even sides the encoders
/// take.
({int width, int height}) gifVideoFrameSize(int width, int height, PhotoFit rules, PhotoFitMode mode) {
  final shaped = rules.fittedSize(
          MediaAttachment(id: 'gif', path: '', mimeType: 'image/gif', sizeBytes: 0, width: math.max(1, width), height: math.max(1, height)),
          mode) ??
      (width: math.max(1, width), height: math.max(1, height));
  // The shape: exactly the rules' one where they allow only one (a frame
  // to fill), so a small GIF's rounding does not show at 1280 pixels.
  final exact = rules.minAspect != null && rules.minAspect == rules.maxAspect && mode != PhotoFitMode.off;
  final ratio = exact ? rules.minAspect! : shaped.width / shaped.height;
  final long = math.max(shaped.width, shaped.height).clamp(kGifVideoMinLongSide, kGifVideoMaxLongSide).toDouble();
  final w = ratio >= 1 ? long : long * ratio;
  final h = ratio >= 1 ? long / ratio : long;
  int even(double side) => ((side / 2).round() * 2).clamp(16, 4096);
  return (width: even(w), height: even(h));
}

/// The bytes a GIF's video takes, near enough for the checks before it is
/// made: about 2.5 Mbit/s of H.264 at this size, and a little for the silent
/// sound.
int gifVideoSizeEstimate(int durationMs) => (durationMs * (2500000 + 64000) / 8000).round();

/// Draws the GIF pictures [frames] of [bytes] in a [width] x [height] frame
/// ([frameImage], with [mode]) and writes each as a PNG to the path at the
/// same place in [outPaths]. Returns false when the GIF cannot be read. For
/// [compute]: top level, plain data in and out. Each picture is the GIF's
/// canvas as it shows at that time (earlier pictures under it, as the GIF's
/// disposal says), transparent parts black.
bool renderGifFramesJob((Uint8List, int, int, PhotoFitMode, List<int>, List<String>) job) {
  final (bytes, width, height, mode, frames, outPaths) = job;
  img.Image? decoded;
  try {
    decoded = img.GifDecoder().decode(bytes);
  } on Object {
    decoded = null;
  }
  if (decoded == null || decoded.width == 0 || decoded.height == 0) return false;
  final pictures = decoded.frames;
  for (var k = 0; k < frames.length; k++) {
    final i = frames[k];
    if (i < 0 || i >= pictures.length) return false;
    final framed = frameImage(opaqueFrame(pictures[i]), width: width, height: height, mode: mode);
    // Fast compression: the files live only until the encoder has read them.
    writeMediaFileSync(outPaths[k], img.encodePng(framed, level: 1));
  }
  return true;
}
