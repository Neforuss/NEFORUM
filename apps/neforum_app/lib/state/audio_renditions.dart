import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:uuid/uuid.dart';

import '../media/audio_card.dart';
import '../media/audio_plan.dart';
import '../media/render_parameters.dart';
import '../media/text_card.dart' show textCardText;
import '../platform/media_files.dart';
import '../platform/video_compositor.dart';
import 'services.dart';
import 'settings.dart';

/// The sound formats this device can write ([VideoCompositor.audioOutputFormats]).
final audioOutputFormatsProvider = FutureProvider<List<String>>((ref) => VideoCompositor.instance.audioOutputFormats());

/// A file NEFORUM made from the user's sound file: the Standard copy
/// ([RenderKind.audioTranscode]) or a still-picture video
/// ([RenderKind.audioVideo]). Like fitted photos, it lists the original in
/// [MediaAttachment.derivedFrom] and only the targets that list it get it.
bool isAudioRendition(MediaAttachment m) {
  if (!m.generated || m.derivedFrom == null) return false;
  final kind = renderKindOf(m);
  return kind == RenderKind.audioTranscode || kind == RenderKind.audioVideo;
}

/// `PostOverrides.extra` key of the file list (media ids) a target had
/// before [attachAudioRenditions] put a rendition in it: a list of ids, or
/// `true` for every file (no list of its own). [withoutAudioRenditions] puts
/// it back, so a photo that became a video's picture comes back too.
const String kAudioReplacedMediaIdsKey = 'audioReplacedMediaIds';

/// [post] with every target's file list as it was before its renditions
/// were put in ([kAudioReplacedMediaIdsKey]), and without the renditions
/// unless [keepFiles] (then they stay in its media, listed by no target, for
/// [attachAudioRenditions] to reuse or delete).
Post withoutAudioRenditions(Post post, {bool keepFiles = false}) {
  final renditions = {for (final m in post.media.where(isAudioRendition)) m.id: m.derivedFrom!};
  final hasKey = post.targets.any((t) => t.overrides.extra.containsKey(kAudioReplacedMediaIdsKey));
  if (renditions.isEmpty && !hasKey) return post;
  return post.copyWith(
    media: keepFiles ? post.media : [for (final m in post.media) if (!renditions.containsKey(m.id)) m],
    targets: [
      for (final t in post.targets)
        () {
          final o = t.overrides;
          final saved = o.extra[kAudioReplacedMediaIdsKey];
          final extra = {...o.extra}..remove(kAudioReplacedMediaIdsKey);
          if (saved == true) return t.copyWith(overrides: o.copyWith(extra: extra, clearMediaIds: true));
          if (saved is List) return t.copyWith(overrides: o.copyWith(extra: extra, mediaIds: [for (final id in saved) if (id is String) id]));
          final ids = o.mediaIds;
          if (ids == null || !ids.any(renditions.containsKey)) return t;
          return t.copyWith(overrides: o.copyWith(mediaIds: [for (final id in ids) renditions[id] ?? id]));
        }(),
    ],
  );
}

/// Gives every target the form of the post's sound file its network takes
/// ([audioRouteFor]): the original, the Standard copy (one MP3, or M4A on
/// devices without an MP3 encoder, made once for every network that gets
/// it), or a video of one still picture for networks that take only video
/// (the target's first photo, cover-fitted to the network's frame
/// [audioVideoFrame], else a card with the track's title on the NEFORUM
/// brand background). Renditions made from the same file with the same
/// settings are reused; the rest are deleted.
///
/// Call last, after [attachCaptionedPhotos], on a post whose targets list
/// the original files ([withoutAudioRenditions] with `keepFiles`, so the old
/// renditions can be reused). Without [render], only renditions the post
/// already has are used (background publishing has no compositor). A
/// rendition that cannot be made leaves the original, and the target's
/// checks say why it cannot go.
Future<Post> attachAudioRenditions(AppServices s, Post post, AppSettings settings, {bool render = true}) async {
  final pool = {for (final m in post.media.where(isAudioRendition)) m.fitKey ?? m.id: m};
  var p = post.copyWith(media: [for (final m in post.media) if (!isAudioRendition(m)) m]);
  final sources = {for (final m in p.media) if (m.isAudio && !m.generated) m.id: m};
  final used = <String, MediaAttachment>{};
  if (sources.isEmpty) {
    for (final m in pool.values) {
      await s.media.discard(m);
    }
    return p;
  }

  final compositor = VideoCompositor.instance;
  final canRender = render && await compositor.isSupported();
  final format = standardAudioFormat(canRender ? await compositor.audioOutputFormats() : const []);
  // Without a compositor, a Standard copy made earlier is still the best file.
  final standardMime = standardAudioMimeType(format) ?? _pooledStandardMime(pool.values);
  final byId = {for (final m in p.media) m.id: m};

  for (final original in post.targets) {
    final t = p.targetFor(original.accountId)!;
    final account = await s.accounts.get(t.accountId);
    final adapter = account == null ? null : s.registry.byId(account.platformId);
    if (account == null || adapter == null) continue;
    final d = adapter.descriptorForAccount(account);
    final own = t.overrides.mediaIds;
    final ids = own ?? [for (final m in p.media) if (!m.generated) m.id];
    if (!ids.any(sources.containsKey)) continue;

    final next = <String>[];
    final consumed = <String>{};
    var changed = false;
    for (final id in ids) {
      final source = sources[id];
      if (source == null) {
        next.add(id);
        continue;
      }
      final route = audioRouteFor(d.media, source, post.audioQuality, standardMimeType: standardMime);
      MediaAttachment? made;
      if (route == AudioRoute.standardCopy) {
        made = await _standardCopy(s, source, format, pool, used, render: canRender);
      } else if (route == AudioRoute.video) {
        final picture = _pictureFor(ids, byId);
        made = await _video(s, p, t, source, picture, d.id, pool, used, render: canRender);
        if (made != null && picture != null) consumed.add(picture.$1);
      }
      if (made == null) {
        next.add(id);
        continue;
      }
      next.add(made.id);
      changed = true;
    }
    if (!changed) continue;
    final list = [for (final id in next) if (!consumed.contains(id)) id];
    p = p.withTarget(t.copyWith(
      overrides: t.overrides.copyWith(
        mediaIds: list,
        extra: {
          ...t.overrides.extra,
          // The user's own files, without photos fitted for this network.
          kAudioReplacedMediaIdsKey: own == null ? true : [for (final id in own) _userId(byId[id]) ?? id],
        },
      ),
    ));
  }

  final keep = {for (final m in used.values) m.id};
  for (final m in pool.values) {
    if (!keep.contains(m.id)) await s.media.discard(m);
  }
  return p.copyWith(media: [...p.media, ...used.values]);
}

/// The user's file a generated copy was made from (a fitted or captioned
/// photo); null for the user's own files and text cards.
String? _userId(MediaAttachment? m) => m != null && m.generated ? m.derivedFrom : null;

String? _pooledStandardMime(Iterable<MediaAttachment> pool) {
  for (final m in pool) {
    if (renderKindOf(m) == RenderKind.audioTranscode) return m.mimeType;
  }
  return null;
}

/// The first photo of a target's files, as (the id listed, the user's
/// original photo): a fitted or captioned copy is read through to the photo
/// the user attached, since the video's frame is made from it.
(String, MediaAttachment)? _pictureFor(List<String> ids, Map<String, MediaAttachment> byId) {
  for (final id in ids) {
    final m = byId[id];
    if (m == null || m.kind != MediaKind.image || m.isTextCard) continue;
    final photo = m.generated ? byId[m.derivedFrom] ?? m : m;
    return (id, photo);
  }
  return null;
}

Future<MediaAttachment?> _standardCopy(AppServices s, MediaAttachment source, String? format, Map<String, MediaAttachment> pool,
    Map<String, MediaAttachment> used, {required bool render}) async {
  final pooled = [
    for (final m in pool.values)
      if (renderKindOf(m) == RenderKind.audioTranscode && m.derivedFrom == source.id) m,
  ];
  if (format == null) return pooled.firstOrNull;
  final params = <String, dynamic>{'kind': RenderKind.audioTranscode, 'format': format, 'bitrate': kStandardAudioBitsPerSecond};
  final key = 'audio|${source.id}|${stableHash(jsonEncode(params))}';
  final reused = used[key] ?? pool[key];
  if (reused != null) return used[key] = reused;
  if (!render) return pooled.firstOrNull;
  final id = const Uuid().v7();
  final out = newMediaFilePath(s.storage.dataDir, id, format);
  if (out == null) return null;
  final mime = standardAudioMimeType(format)!;
  final made = MediaAttachment(id: id, path: out, mimeType: mime, sizeBytes: 0);
  try {
    await VideoCompositor.instance.transcodeAudio(inputPath: source.path, outputPath: out, format: format, bitsPerSecond: kStandardAudioBitsPerSecond);
    return used[key] = MediaAttachment(
      id: id,
      path: out,
      mimeType: mime,
      sizeBytes: await mediaFileLength(out),
      durationMs: source.durationMs,
      fileName: '${audioTrackTitle(source)}.$format',
      generated: true,
      derivedFrom: source.id,
      fitKey: key,
      renderParameters: params,
      audioCodec: format == 'mp3' ? AudioCodecs.mp3 : AudioCodecs.aac,
    );
  } on Object catch (e) {
    debugPrint('Could not convert ${source.fileName ?? source.id} to $format: $e');
    await s.media.discard(made);
    return null;
  }
}

Future<MediaAttachment?> _video(AppServices s, Post post, PostTarget target, MediaAttachment source, (String, MediaAttachment)? picture,
    String platformId, Map<String, MediaAttachment> pool, Map<String, MediaAttachment> used,
    {required bool render}) async {
  final (width, height) = audioVideoFrame(platformId);
  final photo = picture?.$2;
  final title = audioTrackTitle(source, postTitle: post.title);
  final words = _firstWords(textCardText(post, target), title);
  final ms = source.durationMs;
  final details = [audioFormatLabel(source), if (ms != null) formatAudioDuration(ms)].join(' · ');
  final params = <String, dynamic>{
    'kind': RenderKind.audioVideo,
    'width': width,
    'height': height,
    if (photo != null) 'picture': photo.id else 'card': stableHash('$title|$words|$details'),
  };
  final key = 'audio|${source.id}|${stableHash(jsonEncode(params))}';
  final reused = used[key] ?? pool[key];
  if (reused != null) return used[key] = reused;
  if (!render) return null;
  final id = const Uuid().v7();
  final out = newMediaFilePath(s.storage.dataDir, id, 'mp4');
  if (out == null) return null;
  final made = MediaAttachment(id: id, path: out, mimeType: 'video/mp4', sizeBytes: 0);
  try {
    final png = (photo == null ? null : await coverPhotoPng(await s.media.read(photo), width: width, height: height)) ??
        await renderAudioCardPng(width: width, height: height, title: title, subtitle: words, details: details);
    await VideoCompositor.instance.renderAudioVideo(audioPath: source.path, outputPath: out, imagePng: png, frameWidth: width, frameHeight: height);
    return used[key] = MediaAttachment(
      id: id,
      path: out,
      mimeType: 'video/mp4',
      sizeBytes: await mediaFileLength(out),
      width: width,
      height: height,
      durationMs: source.durationMs,
      altText: photo?.altText,
      fileName: '$title (video).mp4',
      generated: true,
      derivedFrom: source.id,
      fitKey: key,
      renderParameters: params,
    );
  } on Object catch (e) {
    debugPrint('Could not make a video of ${source.fileName ?? source.id} for $platformId: $e');
    await s.media.discard(made);
    return null;
  }
}

/// The post's first words for the card, when they say more than [title].
String? _firstWords(String text, String title) {
  final line = text.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
  if (line.isEmpty || line == title) return null;
  return line.length > 160 ? '${line.substring(0, 159)}…' : line;
}
