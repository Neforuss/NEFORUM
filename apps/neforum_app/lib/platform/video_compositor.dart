import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'env.dart';

/// What [VideoCompositor.probe] reads from a video file.
@immutable
class VideoProbe {
  const VideoProbe({required this.width, required this.height, this.rotation = 0, this.durationMs = 0, this.hasAudio = false});

  /// The stored frame size in pixels, before [rotation].
  final int width;
  final int height;

  /// Clockwise rotation in degrees (0, 90, 180 or 270) that players apply to
  /// show the video upright. Phones record portrait video this way: a
  /// landscape frame with rotation 90.
  final int rotation;

  final int durationMs;
  final bool hasAudio;

  /// The size as the video is shown, after [rotation].
  int get displayWidth => rotation % 180 == 0 ? width : height;
  int get displayHeight => rotation % 180 == 0 ? height : width;

  /// A probe from the channel's answer; null when it is not a usable one.
  static VideoProbe? fromChannel(Object? value) {
    if (value is! Map) return null;
    final width = value['width'];
    final height = value['height'];
    if (width is! int || height is! int || width <= 0 || height <= 0) return null;
    final rotation = value['rotation'];
    final duration = value['durationMs'];
    return VideoProbe(
      width: width,
      height: height,
      rotation: rotation is num ? normalizedRotation(rotation) : 0,
      durationMs: duration is num && duration > 0 ? duration.round() : 0,
      hasAudio: value['hasAudio'] == true,
    );
  }

  /// [degrees] as the nearest of 0, 90, 180 and 270 (players report -90 for
  /// 270, some files 360 for 0).
  static int normalizedRotation(num degrees) {
    if (!degrees.isFinite) return 0;
    final quarter = (degrees / 90).round() % 4;
    return quarter * 90;
  }

  @override
  bool operator ==(Object other) =>
      other is VideoProbe &&
      other.width == width &&
      other.height == height &&
      other.rotation == rotation &&
      other.durationMs == durationMs &&
      other.hasAudio == hasAudio;

  @override
  int get hashCode => Object.hash(width, height, rotation, durationMs, hasAudio);

  @override
  String toString() => 'VideoProbe(${width}x$height, rotation $rotation, ${durationMs}ms, ${hasAudio ? 'audio' : 'no audio'})';
}

/// Why a video could not be composed. The caller posts the original video
/// instead: a caption that cannot be burned in never stops a post.
class VideoCompositionException implements Exception {
  const VideoCompositionException(this.code, this.message);

  /// `unsupported` (no compositor on this device), `invalid` (a request
  /// NEFORUM should not have made), `probe` (the video could not be read),
  /// or the native side's own code (`compose`, `audio`, `cancelled`...).
  final String code;
  final String message;

  @override
  String toString() => 'VideoCompositionException($code): $message';
}

/// Burns a caption block into a video for TikTok and Instagram: re-encodes it
/// as an H.264/AAC MP4 of a fixed frame (9:16, 4:5...) filled with a
/// background colour, with the video scaled into a content rectangle (aspect
/// kept, sound kept) and a full-frame PNG overlay (the caption block, see
/// lib/media) drawn on top for the whole duration.
///
/// The encoding happens in the "neforum/video" channel of each runner:
/// AVFoundation on iOS and macOS (ios/Runner/VideoCompositor.swift, shared by
/// the macOS project), Media3 Transformer on Android
/// (android/.../VideoCompositor.kt) and Media Foundation with Direct2D on
/// Windows (windows/runner/video_compositor.cpp). Linux and the web have none.
///
/// Every native piece stays behind [isSupported]: a missing or failing
/// compositor reports false or throws [VideoCompositionException], and the
/// caller keeps the original video.
class VideoCompositor {
  VideoCompositor({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'neforum/video';

  /// The app's compositor.
  static final VideoCompositor instance = VideoCompositor();

  /// Frame sides NEFORUM asks for. H.264 encoders take even sizes, and
  /// 4096 is the largest side every encoder on these platforms accepts.
  static const int minFrameSide = 16;
  static const int maxFrameSide = 4096;

  static final Uint8List _pngSignature = Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final MethodChannel _channel;
  Future<bool>? _supported;

  /// Compositions run one at a time: each one keeps an encoder busy.
  Future<void> _queue = Future<void>.value();
  int _lastJob = 0;
  final Map<int, void Function(double)> _progressListeners = {};
  bool _listening = false;

  /// The platforms with a compositor in their runner.
  static bool get platformHasCompositor => Env.isAndroid || Env.isIOS || Env.isMacOS || Env.isWindows;

  /// Whether videos can be composed on this device: the runner has the
  /// channel and an H.264 encoder (Windows N editions without the Media
  /// Feature Pack have none). Asked once.
  Future<bool> isSupported() => _supported ??= _askSupported();

  Future<bool> _askSupported() async {
    if (!platformHasCompositor) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') == true;
    } on MissingPluginException {
      return false;
    } on Object catch (e) {
      debugPrint('The video compositor is not available: $e');
      return false;
    }
  }

  /// The size, rotation, duration and sound of the video at [path]; null
  /// when it cannot be read or there is no compositor.
  Future<VideoProbe?> probe(String path) async {
    if (path.isEmpty || !await isSupported()) return null;
    try {
      return VideoProbe.fromChannel(await _channel.invokeMethod<Object?>('probe', {'path': path}));
    } on Object catch (e) {
      debugPrint('Could not read the video $path: $e');
      return null;
    }
  }

  /// Writes [outputPath] (an .mp4): a [frameWidth] x [frameHeight] frame of
  /// [backgroundArgb] (its alpha is ignored: video has none), the video at
  /// [inputPath] scaled to fit [contentRect] (in frame pixels) and centred in
  /// it, with its sound, and [overlayPng] stretched over the whole frame on
  /// top. [onProgress] receives values from 0 to 1, ending with 1.
  ///
  /// Throws [VideoCompositionException] when the request is not valid, there
  /// is no compositor, the video cannot be read or the encoder fails; the
  /// native side then leaves no file at [outputPath].
  Future<void> compose({
    required String inputPath,
    required String outputPath,
    required Uint8List overlayPng,
    required int frameWidth,
    required int frameHeight,
    required Rect contentRect,
    required int backgroundArgb,
    void Function(double progress)? onProgress,
  }) {
    final problem = validationProblem(
      inputPath: inputPath,
      outputPath: outputPath,
      overlayPng: overlayPng,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      contentRect: contentRect,
    );
    if (problem != null) return Future<void>.error(VideoCompositionException('invalid', problem));
    final run = _queue.then((_) => _compose(
          inputPath: inputPath,
          outputPath: outputPath,
          overlayPng: overlayPng,
          frameWidth: frameWidth,
          frameHeight: frameHeight,
          contentRect: contentRect,
          backgroundRgb: backgroundArgb & 0xFFFFFF,
          onProgress: onProgress,
        ));
    _queue = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _compose({
    required String inputPath,
    required String outputPath,
    required Uint8List overlayPng,
    required int frameWidth,
    required int frameHeight,
    required Rect contentRect,
    required int backgroundRgb,
    void Function(double progress)? onProgress,
  }) async {
    if (!await isSupported()) {
      throw const VideoCompositionException('unsupported', 'Captions cannot be added to videos on this device.');
    }
    final video = await probe(inputPath);
    if (video == null) throw const VideoCompositionException('probe', 'NEFORUM could not read this video.');
    final placed = fittedVideoRect(video, contentRect, frameWidth: frameWidth, frameHeight: frameHeight);

    final job = ++_lastJob;
    var reported = -1.0;
    void report(double value) {
      if (onProgress == null || !value.isFinite) return;
      final p = value.clamp(0.0, 1.0);
      if (p <= reported) return;
      reported = p;
      try {
        onProgress(p);
      } on Object catch (e) {
        debugPrint('Video progress listener failed: $e');
      }
    }

    _listenForProgress();
    _progressListeners[job] = report;
    try {
      report(0);
      await _channel.invokeMethod<void>('compose', {
        'id': job,
        'inputPath': inputPath,
        'outputPath': outputPath,
        'overlayPng': overlayPng,
        'frameWidth': frameWidth,
        'frameHeight': frameHeight,
        'videoLeft': placed.left.round(),
        'videoTop': placed.top.round(),
        'videoWidth': placed.width.round(),
        'videoHeight': placed.height.round(),
        'backgroundRgb': backgroundRgb,
      });
      report(1);
    } on PlatformException catch (e) {
      throw VideoCompositionException(e.code, e.message ?? 'The video could not be made.');
    } on MissingPluginException {
      throw const VideoCompositionException('unsupported', 'Captions cannot be added to videos on this device.');
    } finally {
      _progressListeners.remove(job);
    }
  }

  /// Progress arrives as "progress" calls from the runner: `{id, progress}`.
  void _listenForProgress() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'progress') return null;
      final args = call.arguments;
      if (args is Map) {
        final id = args['id'];
        final progress = args['progress'];
        if (id is int && progress is num) _progressListeners[id]?.call(progress.toDouble());
      }
      return null;
    });
  }

  /// What is wrong with a [compose] request; null when it can be sent.
  @visibleForTesting
  static String? validationProblem({
    required String inputPath,
    required String outputPath,
    required Uint8List overlayPng,
    required int frameWidth,
    required int frameHeight,
    required Rect contentRect,
  }) {
    if (inputPath.isEmpty) return 'No video was given.';
    if (outputPath.isEmpty || !outputPath.toLowerCase().endsWith('.mp4')) return 'The new video must be an .mp4 file.';
    if (outputPath == inputPath) return 'The new video cannot replace the original.';
    for (final side in [frameWidth, frameHeight]) {
      if (side < minFrameSide || side > maxFrameSide || side.isOdd) {
        return 'The frame must be an even number of pixels from $minFrameSide to $maxFrameSide on each side.';
      }
    }
    if (overlayPng.length < _pngSignature.length || !listEquals(overlayPng.sublist(0, _pngSignature.length), _pngSignature)) {
      return 'The caption must be a PNG image.';
    }
    final values = [contentRect.left, contentRect.top, contentRect.right, contentRect.bottom];
    if (values.any((v) => !v.isFinite) || contentRect.width < 1 || contentRect.height < 1) {
      return 'The video needs room in the frame.';
    }
    // Half a pixel of rounding either way is fine.
    if (contentRect.left < -0.5 ||
        contentRect.top < -0.5 ||
        contentRect.right > frameWidth + 0.5 ||
        contentRect.bottom > frameHeight + 0.5) {
      return 'The video\'s place must be inside the frame.';
    }
    return null;
  }

  /// Where the video goes: scaled to fit [contentRect] (clamped to the
  /// frame), aspect kept, centred, on whole pixels so the native side and the
  /// background meet without a seam.
  static Rect fittedVideoRect(VideoProbe video, Rect contentRect, {required int frameWidth, required int frameHeight}) {
    final frame = Rect.fromLTWH(0, 0, frameWidth.toDouble(), frameHeight.toDouble());
    var area = contentRect.intersect(frame);
    if (area.width <= 0 || area.height <= 0) area = frame;
    final w = video.displayWidth.toDouble();
    final h = video.displayHeight.toDouble();
    final scale = math.min(area.width / w, area.height / h);
    final fittedWidth = w * scale;
    final fittedHeight = h * scale;
    final left = area.left + (area.width - fittedWidth) / 2;
    final top = area.top + (area.height - fittedHeight) / 2;
    final l = left.round().clamp(0, frameWidth - 1);
    final t = top.round().clamp(0, frameHeight - 1);
    final r = (left + fittedWidth).round().clamp(l + 1, frameWidth);
    final b = (top + fittedHeight).round().clamp(t + 1, frameHeight);
    return Rect.fromLTRB(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble());
  }
}
