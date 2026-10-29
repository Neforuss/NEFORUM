import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:uuid/uuid.dart';

import '../media/render_parameters.dart';
import '../media/video_shrink.dart';
import '../platform/media_files.dart';
import '../platform/media_library.dart' show formatBytes;
import '../platform/video_compositor.dart';
import 'render_warnings.dart';
import 'services.dart';
import 'settings.dart';

// 1.3: video

/// Marks a copy of a video NEFORUM made smaller for a network's size limit.
const String _shrunkKeyPrefix = 'shrunk|';

/// A copy of a video made to fit a network's size limit
/// ([attachShrunkVideos]).
bool isShrunkCopy(MediaAttachment m) => m.derivedFrom != null && (m.fitKey ?? '').startsWith(_shrunkKeyPrefix);

/// Whether this device can make smaller copies of videos ([VideoCompositor]).
final videoShrinkingSupportedProvider = FutureProvider<bool>((ref) => VideoCompositor.instance.isSupported());

/// What the compositor reads from the video at a path: the composer checks
/// durations with it, which attached files do not carry. Null without a
/// compositor or when the file cannot be read.
final videoProbeProvider = FutureProvider.family<VideoProbe?, String>((ref, path) => VideoCompositor.instance.probe(path));

/// The video a shrunk copy was made from: the attached video, or the copy
/// with a caption block above it that a network gets in its place.
String shrunkCopySourceId(MediaAttachment copy) => copy.renderParameters?['source'] as String? ?? copy.derivedFrom!;

/// [post] with every target listing the videos its shrunk copies were made
/// from again, and without those copies.
Post withoutShrunkVideos(Post post) {
  final copies = {for (final m in post.media.where(isShrunkCopy)) m.id: shrunkCopySourceId(m)};
  if (copies.isEmpty) return post;
  return post.copyWith(
    media: [for (final m in post.media) if (!copies.containsKey(m.id)) m],
    targets: [
      for (final t in post.targets) _withSources(t, copies),
    ],
  );
}

/// When Settings shrink videos that are too big for a network, gives every
/// target whose network takes videos only up to a size a copy of each video
/// over it, made just under that network's own limit: one copy for each
/// video and limit, shared by the networks with that limit. Targets where the
/// video fits keep it. Copies made for the same video and limit are reused;
/// the rest are deleted. Call after [attachCaptionedPhotos], so a video with
/// a caption block above it is shrunk as the network gets it.
///
/// A video over a network's length limit is left as it is: no size makes it
/// fit, and the network's own check says so. Without a compositor (a
/// background isolate, Linux) copies already made are reused, none are made.
/// [onProgress] hears, per target account, what is being made; a cancelled
/// [cancellation] stops making copies (the publish run then stops itself).
/// Copies are only made for the targets still to post, and with
/// [onlyAccountIds] for those accounts only; the others reuse what there is.
Future<Post> attachShrunkVideos(
  AppServices s,
  Post post,
  AppSettings settings, {
  void Function(String accountId, String message)? onProgress,
  CancellationSignal? cancellation,
  Set<String>? onlyAccountIds,
}) async {
  final pool = {for (final m in post.media.where(isShrunkCopy)) m.fitKey!: m};
  var p = withoutShrunkVideos(post);
  if (!settings.shrinkOversizedVideos) {
    for (final m in pool.values) {
      await s.media.discard(m);
    }
    return p;
  }
  final canMake = await VideoCompositor.instance.isSupported();
  final used = <String, MediaAttachment>{};
  // Video id and limit -> the targets that need that copy, for progress.
  final needs = <String, List<String>>{};
  // [story]: the plan is for the story list of Post + Story.
  final plans = <({PostTarget target, List<String> ids, Map<int, int> limits, bool make, bool story})>[];

  for (final t in p.targets) {
    final account = await s.accounts.get(t.accountId);
    final adapter = account == null ? null : s.registry.byId(account.platformId);
    if (account == null || adapter == null) continue;
    final rules = adapter.descriptorForAccount(account).media;
    final limit = rules.videoMaxBytes;
    if (limit == null || limit <= 0) continue;
    final done = t.status == TargetStatus.published || t.status == TargetStatus.handedOff || t.status == TargetStatus.skipped;
    final make = canMake && !done && (onlyAccountIds == null || onlyAccountIds.contains(t.accountId));
    final storyIds = t.overrides.storyMediaIds;
    for (final (ids, story) in [
      (t.overrides.mediaIds ?? [for (final m in p.media) if (!m.generated) m.id], false),
      if (storyIds != null) (storyIds, true),
    ]) {
      final limits = <int, int>{};
      for (var i = 0; i < ids.length; i++) {
        final m = p.media.where((x) => x.id == ids[i]).firstOrNull;
        if (m == null || !m.isVideo || m.sizeBytes <= limit) continue;
        final maxSeconds = rules.videoMaxSeconds;
        final durationMs = m.durationMs;
        if (maxSeconds != null && durationMs != null && durationMs > maxSeconds * 1000) continue;
        limits[i] = limit;
        final waiting = needs.putIfAbsent(_keyFor(m.id, limit), () => []);
        if (!waiting.contains(t.accountId)) waiting.add(t.accountId);
      }
      if (limits.isNotEmpty) plans.add((target: t, ids: ids, limits: limits, make: make, story: story));
    }
  }

  for (final plan in plans) {
    // The target as earlier plans left it (its feed list, then its story's).
    final t = p.targetFor(plan.target.accountId)!;
    final ids = [...plan.ids];
    var changed = false;
    for (final e in plan.limits.entries) {
      final source = p.media.where((x) => x.id == ids[e.key]).firstOrNull;
      if (source == null) continue;
      final key = _keyFor(source.id, e.value);
      var copy = used[key] ?? pool[key];
      if (copy == null && plan.make && !(cancellation?.isCancelled ?? false)) {
        final waiting = needs[key] ?? [t.accountId];
        final names = await _networkNames(s, waiting);
        copy = await _shrinkVideo(
          s,
          source,
          limitBytes: e.value,
          key: key,
          onProgress: onProgress == null
              ? null
              : (value) {
                  final message = 'Making ${source.fileName ?? 'the video'} smaller to fit ${formatBytes(e.value)} for $names… ${(value * 100).round()}%';
                  for (final id in waiting) {
                    onProgress(id, message);
                  }
                },
        );
        if (copy == null) {
          reportRenderWarning('${source.fileName ?? 'A video'} could not be made smaller than ${formatBytes(e.value)} for $names, '
              'so it goes as it is and that network may refuse it.');
        }
      }
      if (copy == null) continue;
      copy = copy.copyWith(altText: source.altText, clearAltText: source.altText == null);
      used[key] = copy;
      ids[e.key] = copy.id;
      changed = true;
    }
    if (changed) {
      p = p.withTarget(t.copyWith(overrides: plan.story ? t.overrides.copyWith(storyMediaIds: ids) : t.overrides.copyWith(mediaIds: ids)));
    }
  }

  final keep = {for (final m in used.values) m.id};
  for (final m in pool.values) {
    // Kept where no copy could be made now: a later run on a device with a
    // compositor reuses it.
    if (!keep.contains(m.id) && canMake) await s.media.discard(m);
  }
  return p.copyWith(media: [
    ...p.media,
    ...used.values,
    if (!canMake) ...pool.values.where((m) => !keep.contains(m.id)),
  ]);
}

/// [m] with the duration [probe] read, for checks against a network's length
/// limit; [m] itself when it has one or nothing was read.
MediaAttachment withProbedDuration(MediaAttachment m, VideoProbe? probe) {
  if (m.durationMs != null || probe == null || probe.durationMs <= 0) return m;
  return MediaAttachment(
    id: m.id,
    path: m.path,
    mimeType: m.mimeType,
    sizeBytes: m.sizeBytes,
    width: m.width ?? probe.displayWidth,
    height: m.height ?? probe.displayHeight,
    durationMs: probe.durationMs,
    altText: m.altText,
    fileName: m.fileName,
    generated: m.generated,
    derivedFrom: m.derivedFrom,
    fitKey: m.fitKey,
    renderParameters: m.renderParameters,
  );
}

/// [t] listing the source of each shrunk copy in [copies] (copy id -> source
/// id) in place of the copy, in its story list as well.
PostTarget _withSources(PostTarget t, Map<String, String> copies) {
  var o = t.overrides;
  final ids = o.mediaIds;
  if (ids != null && ids.any(copies.containsKey)) o = o.copyWith(mediaIds: [for (final id in ids) copies[id] ?? id]);
  final story = o.storyMediaIds;
  if (story != null && story.any(copies.containsKey)) o = o.copyWith(storyMediaIds: [for (final id in story) copies[id] ?? id]);
  return identical(o, t.overrides) ? t : t.copyWith(overrides: o);
}

String _keyFor(String videoId, int limitBytes) => '$_shrunkKeyPrefix$videoId|$limitBytes';

Future<String> _networkNames(AppServices s, List<String> accountIds) async {
  final names = <String>{};
  for (final id in accountIds) {
    final a = await s.accounts.get(id);
    if (a != null) names.add(s.registry.descriptor(a.platformId)?.name ?? a.platformId);
  }
  return names.isEmpty ? 'this network' : names.join(', ');
}

/// A copy of [source] under [limitBytes] ([shrinkVideoToFit]) in the media
/// folder; null when none could be made.
Future<MediaAttachment?> _shrinkVideo(
  AppServices s,
  MediaAttachment source, {
  required int limitBytes,
  required String key,
  void Function(double progress)? onProgress,
}) async {
  final compositor = VideoCompositor.instance;
  final probe = await compositor.probe(source.path);
  if (probe == null) return null;
  final id = const Uuid().v7();
  final out = newMediaFilePath(s.storage.dataDir, id, 'mp4');
  if (out == null) return null;
  final made = MediaAttachment(id: id, path: out, mimeType: 'video/mp4', sizeBytes: 0);
  try {
    final result = await shrinkVideoToFit(compositor,
        inputPath: source.path, outputPath: out, limitBytes: limitBytes, probe: probe, onProgress: onProgress);
    if (result == null) {
      await s.media.discard(made);
      return null;
    }
    final frame = shrunkFrameSize(probe.displayWidth, probe.displayHeight, result.plan.maxSide);
    return MediaAttachment(
      id: id,
      path: out,
      mimeType: 'video/mp4',
      sizeBytes: result.sizeBytes,
      width: frame.width,
      height: frame.height,
      durationMs: probe.durationMs > 0 ? probe.durationMs : source.durationMs,
      altText: source.altText,
      fileName: _shrunkName(source),
      generated: true,
      // Back to the video the user attached, through a captioned copy.
      derivedFrom: source.derivedFrom ?? source.id,
      fitKey: key,
      renderParameters: {
        'kind': RenderKind.shrunkVideo,
        'source': source.id,
        'limitBytes': limitBytes,
        'videoBitrate': result.plan.videoBitsPerSecond,
        'audioBitrate': result.plan.audioBitsPerSecond,
        'maxSide': result.plan.maxSide,
      },
    );
  } on Object catch (e) {
    debugPrint('Could not make ${source.fileName ?? source.id} smaller: $e');
    await s.media.discard(made);
    return null;
  }
}

/// Re-encodes the video at [inputPath] ([probe] read from it) into
/// [outputPath] at the bitrate [planVideoShrink] picks for [limitBytes],
/// checks the file is within the limit, and tries again aiming lower
/// ([kShrinkRetryFactor]) up to [kShrinkRetries] times. Returns the plan that
/// worked and the copy's size; null (and no file at [outputPath]) when no
/// copy fits. Throws [VideoCompositionException] when the compositor fails.
Future<({VideoShrinkPlan plan, int sizeBytes})?> shrinkVideoToFit(
  VideoCompositor compositor, {
  required String inputPath,
  required String outputPath,
  required int limitBytes,
  required VideoProbe probe,
  void Function(double progress)? onProgress,
}) async {
  const attempts = kShrinkRetries + 1;
  for (var attempt = 0; attempt < attempts; attempt++) {
    final plan = planVideoShrink(
      limitBytes: limitBytes,
      durationMs: probe.durationMs,
      width: probe.displayWidth,
      height: probe.displayHeight,
      hasAudio: probe.hasAudio,
      attempt: attempt,
    );
    if (plan == null) break;
    await compositor.transcode(
      inputPath: inputPath,
      outputPath: outputPath,
      videoBitsPerSecond: plan.videoBitsPerSecond,
      audioBitsPerSecond: plan.audioBitsPerSecond,
      maxSide: plan.maxSide,
      onProgress: onProgress,
    );
    final size = await mediaFileLength(outputPath);
    if (size > 0 && size <= limitBytes) return (plan: plan, sizeBytes: size);
    debugPrint('A copy of $inputPath came out at $size bytes, over $limitBytes; trying a lower bitrate.');
  }
  await deleteMediaFile(outputPath);
  return null;
}

/// "clip.mov" -> "clip (smaller).mp4".
String _shrunkName(MediaAttachment m) {
  final name = m.fileName ?? m.id;
  final dot = name.lastIndexOf('.');
  return '${dot > 0 ? name.substring(0, dot) : name} (smaller).mp4';
}

/// [issues] for a network's [variant] with advice about its videos' size and
/// length limits (lib/state/composer.dart): a video over the size limit
/// becomes information when it will be shrunk ([shrink]: the setting is on
/// and this device can), and stays an error otherwise, with the way out; a
/// video over the length limit stays an error, since shrinking cannot
/// shorten it.
List<ValidationIssue> withVideoLimitAdvice(
  List<ValidationIssue> issues,
  PostVariant variant,
  PlatformDescriptor d, {
  required bool shrink,
  required bool canShrink,
}) {
  final limit = d.media.videoMaxBytes;
  final maxSeconds = d.media.videoMaxSeconds;
  if (limit == null && maxSeconds == null) return issues;
  final out = <ValidationIssue>[];
  for (final i in issues) {
    if (i.code == 'media.video_too_long') {
      out.add(ValidationIssue.error(i.code, '${i.message}. Shrinking cannot shorten a video: trim it to post it there.', field: i.field));
    } else if (i.code != 'media.video_too_large' || !shrink) {
      out.add(i.code == 'media.video_too_large' && canShrink
          ? ValidationIssue.error(i.code, '${i.message}. Settings > Posting can shrink it for that network.', field: i.field)
          : i);
    }
  }
  if (!shrink || limit == null) return out;
  // The size errors above were left out: each video gets its own line.
  for (final m in variant.media) {
    if (!m.isVideo || m.sizeBytes <= limit) continue;
    final name = m.fileName ?? 'A video';
    final durationMs = m.durationMs;
    if (maxSeconds != null && durationMs != null && durationMs > maxSeconds * 1000) {
      // The length error says what to do; a copy would not help.
      continue;
    }
    final fits = durationMs == null ||
        planVideoShrink(limitBytes: limit, durationMs: durationMs, width: m.width ?? 1920, height: m.height ?? 1080) != null;
    out.add(fits
        ? ValidationIssue.info('media.video_shrink', '$name (${formatBytes(m.sizeBytes)}) will be shrunk to fit ${formatBytes(limit)} for ${d.name}', field: 'media')
        : ValidationIssue.error('media.video_too_large',
            '$name is too long to shrink under ${formatBytes(limit)} for ${d.name} and still be watchable: trim it to post it there.',
            field: 'media'));
  }
  return out;
}
