import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:uuid/uuid.dart';

import '../media/gif_video.dart';
import '../media/render_parameters.dart';
import '../platform/media_files.dart';
import '../platform/video_compositor.dart';
import 'providers.dart';
import 'services.dart';

// 1.4.4: an animated GIF on Instagram's API becomes an MP4 (PhotoFit.gifAsVideo).
// The video is one of the fitted copies attachFittedPhotos manages: made
// from the GIF (derivedFrom), for one set of rules (fitKey), listed by the
// targets that get it, reused while the GIF and the rules stay the same.

/// Start of the `fitKey` of a GIF's video; the rest is the photo rules' key
/// ([PhotoFit.keyFor]) the video's frame was worked out from.
const String kGifVideoKeyPrefix = 'gifVideo|';

/// The `fitKey` of the video a GIF becomes under [rules] with [mode]. "v1":
/// the way it is made; a change there makes every video again.
String gifVideoFitKey(PhotoFit rules, PhotoFitMode mode) => '$kGifVideoKeyPrefix${rules.keyFor(mode)}|v1';

/// A video NEFORUM made of a GIF.
bool isGifVideo(MediaAttachment m) => m.derivedFrom != null && (m.fitKey ?? '').startsWith(kGifVideoKeyPrefix);

/// The animation of the GIF at a path, for the composer's checks; null when
/// it cannot be read. Read once per file.
final gifAnimationProvider = FutureProvider.family<GifAnimation?, String>((ref, path) async {
  try {
    return readGifAnimation(await ref.read(servicesProvider).storage.readMedia(path));
  } on Object {
    return null;
  }
});

/// What the composer checks for an animated [gif] that becomes a video, before
/// it is made: an MP4 of the frame and length it will have. It keeps the
/// GIF's id and path (the preview shows the GIF) and lists it as its source.
MediaAttachment gifVideoStandIn(MediaAttachment gif, GifAnimation animation, PhotoFit rules, PhotoFitMode mode) {
  final size = gifVideoFrameSize(gif.width ?? animation.width, gif.height ?? animation.height, rules, mode);
  final timeline = gifVideoTimeline(animation.frameDelaysMs);
  return MediaAttachment(
    id: gif.id,
    path: gif.path,
    mimeType: 'video/mp4',
    sizeBytes: gifVideoSizeEstimate(timeline.durationMs),
    width: size.width,
    height: size.height,
    durationMs: timeline.durationMs,
    altText: gif.altText,
    fileName: gifVideoFileName(gif),
    derivedFrom: gif.id,
  );
}

/// "party.gif" -> "party (video).mp4".
String gifVideoFileName(MediaAttachment gif) {
  final name = gif.fileName ?? gif.id;
  final dot = name.lastIndexOf('.');
  return '${dot > 0 ? name.substring(0, dot) : name} (video).mp4';
}

/// Makes the MP4 [gif] (whose file holds [bytes]) becomes under [rules] with
/// [mode]: its frame from [gifVideoFrameSize], its timing from
/// [gifVideoTimeline], every picture drawn off the UI thread into a PNG next
/// to the media files, then encoded by the runner's compositor. The PNGs are
/// deleted afterwards. Null when the GIF is not animated, cannot be read, or
/// the video cannot be made (the caller then fits a still picture).
Future<MediaAttachment?> makeGifVideo(AppServices s, MediaAttachment gif, Uint8List bytes, PhotoFit rules, PhotoFitMode mode,
    {VideoCompositor? compositor}) async {
  final animation = readGifAnimation(bytes);
  if (animation == null || !animation.isAnimated) return null;
  final size = gifVideoFrameSize(animation.width, animation.height, rules, mode);
  final timeline = gifVideoTimeline(animation.frameDelaysMs);
  final id = const Uuid().v7();
  final out = newMediaFilePath(s.storage.dataDir, id, 'mp4');
  if (out == null) return null;
  final used = timeline.framesUsed.toList()..sort();
  final pngs = [for (final i in used) newMediaFilePath(s.storage.dataDir, '$id-frame-$i', 'png')!];
  final pngOf = {for (var k = 0; k < used.length; k++) used[k]: pngs[k]};
  try {
    final drawn = await compute(renderGifFramesJob, (bytes, size.width, size.height, mode, used, pngs));
    if (!drawn) return null;
    await (compositor ?? VideoCompositor.instance).renderFramesVideo(
      framePaths: [for (final span in timeline.spans) pngOf[span.frame]!],
      frameCounts: [for (final span in timeline.spans) span.count],
      outputPath: out,
      frameWidth: size.width,
      frameHeight: size.height,
      frameRate: timeline.frameRate,
    );
    return MediaAttachment(
      id: id,
      path: out,
      mimeType: 'video/mp4',
      sizeBytes: await mediaFileLength(out),
      width: size.width,
      height: size.height,
      durationMs: timeline.durationMs,
      altText: gif.altText,
      fileName: gifVideoFileName(gif),
      generated: true,
      derivedFrom: gif.id,
      fitKey: gifVideoFitKey(rules, mode),
      renderParameters: {
        'kind': RenderKind.gifVideo,
        'width': size.width,
        'height': size.height,
        'fps': timeline.frameRate,
        'loops': timeline.loops,
        'frames': animation.frameCount,
      },
    );
  } on Object catch (e) {
    debugPrint('Could not make a video of ${gif.fileName ?? gif.id}: $e');
    await deleteMediaFile(out);
    return null;
  } finally {
    for (final p in pngs) {
      await deleteMediaFile(p);
    }
  }
}
