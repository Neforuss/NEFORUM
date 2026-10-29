import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show EdgeInsets, Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:uuid/uuid.dart';

import '../media/audio_card.dart';
import '../media/audio_plan.dart';
import '../media/card_design.dart';
import '../media/render_parameters.dart';
import '../media/text_card.dart' show fullScreenSafeArea, textCardText;
import '../platform/media_files.dart';
import '../platform/video_compositor.dart';
import 'card_designs.dart';
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

/// `PostOverrides.extra` key of the story's file list (Post + Story) before
/// [attachAudioRenditions] put a rendition in it, like
/// [kAudioReplacedMediaIdsKey].
const String kAudioReplacedStoryMediaIdsKey = 'audioReplacedStoryMediaIds';

/// [post] with every target's file lists as they were before its renditions
/// were put in ([kAudioReplacedMediaIdsKey], [kAudioReplacedStoryMediaIdsKey]),
/// and without the renditions unless [keepFiles] (then they stay in its
/// media, listed by no target, for [attachAudioRenditions] to reuse or
/// delete).
Post withoutAudioRenditions(Post post, {bool keepFiles = false}) {
  final renditions = {for (final m in post.media.where(isAudioRendition)) m.id: m.derivedFrom!};
  final hasKey = post.targets.any((t) =>
      t.overrides.extra.containsKey(kAudioReplacedMediaIdsKey) || t.overrides.extra.containsKey(kAudioReplacedStoryMediaIdsKey));
  if (renditions.isEmpty && !hasKey) return post;
  List<String> originals(List<String> ids) => [for (final id in ids) renditions[id] ?? id];
  return post.copyWith(
    media: keepFiles ? post.media : [for (final m in post.media) if (!renditions.containsKey(m.id)) m],
    targets: [
      for (final t in post.targets)
        () {
          var o = t.overrides;
          final saved = o.extra[kAudioReplacedMediaIdsKey];
          final savedStory = o.extra[kAudioReplacedStoryMediaIdsKey];
          if (saved != null || savedStory != null) {
            o = o.copyWith(extra: {...o.extra}..remove(kAudioReplacedMediaIdsKey)..remove(kAudioReplacedStoryMediaIdsKey));
          }
          final ids = o.mediaIds;
          if (saved == true) {
            o = o.copyWith(clearMediaIds: true);
          } else if (saved is List) {
            o = o.copyWith(mediaIds: [for (final id in saved) if (id is String) id]);
          } else if (ids != null && ids.any(renditions.containsKey)) {
            o = o.copyWith(mediaIds: originals(ids));
          }
          final story = o.storyMediaIds;
          if (savedStory is List) {
            o = o.copyWith(storyMediaIds: [for (final id in savedStory) if (id is String) id]);
          } else if (story != null && story.any(renditions.containsKey)) {
            o = o.copyWith(storyMediaIds: originals(story));
          }
          return identical(o, t.overrides) ? t : t.copyWith(overrides: o);
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
  final userIds = [for (final m in p.media) if (!m.generated) m.id];
  // 1.3.1: cards. The card designer's design of the video's picture, read
  // once, before the loop (the 1.2.1 AOT crash).
  final design = effectiveCardDesign(audioCardDesignChoiceOfPost(post), settings.audioCardDesign);

  for (final original in post.targets) {
    final t = p.targetFor(original.accountId)!;
    final account = await s.accounts.get(t.accountId);
    final adapter = account == null ? null : s.registry.byId(account.platformId);
    if (account == null || adapter == null) continue;
    final d = adapter.descriptorForAccount(account);
    final own = t.overrides.mediaIds;
    final ids = own ?? userIds;
    final story = t.overrides.storyMediaIds;
    if (!ids.any(sources.containsKey) && !(story?.any(sources.containsKey) ?? false)) continue;

    // [list] with each sound file in the form this network takes; null when
    // nothing changes. A photo that became a video's picture leaves.
    Future<List<String>?> rendered(List<String> list) async {
      final next = <String>[];
      final consumed = <String>{};
      var changed = false;
      for (final id in list) {
        final source = sources[id];
        if (source == null) {
          next.add(id);
          continue;
        }
        final route = audioRouteFor(d.media, source, post.audioQuality, standardMimeType: standardMime);
        MediaAttachment? made;
        if (route == AudioRoute.standardCopy) {
          made = await _standardCopy(s, post, source, format, pool, used, render: canRender);
        } else if (route == AudioRoute.video) {
          final picture = _pictureFor(list, byId);
          made = await _video(s, p, t, source, picture, d.id, pool, used, render: canRender, design: design);
          if (made != null && picture != null) consumed.add(picture.$1);
        }
        if (made == null) {
          next.add(id);
          continue;
        }
        next.add(made.id);
        changed = true;
      }
      return changed ? [for (final id in next) if (!consumed.contains(id)) id] : null;
    }

    final list = await rendered(ids);
    // The story of Post + Story gets the same rendition as the feed post.
    final storyList = story == null ? null : await rendered(story);
    if (list == null && storyList == null) continue;
    // The user's own files, without photos fitted for this network; true
    // when that is every file (no list of its own before fitting).
    List<String> users(List<String> ids) => [for (final id in ids) _userId(byId[id]) ?? id];
    final mine = own == null ? null : users(own);
    p = p.withTarget(t.copyWith(
      overrides: t.overrides.copyWith(
        mediaIds: list,
        storyMediaIds: storyList,
        extra: {
          ...t.overrides.extra,
          if (list != null) kAudioReplacedMediaIdsKey: mine == null || listEquals(mine, userIds) ? true : mine,
          if (storyList != null && story != null) kAudioReplacedStoryMediaIdsKey: users(story),
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

Future<MediaAttachment?> _standardCopy(AppServices s, Post post, MediaAttachment source, String? format, Map<String, MediaAttachment> pool,
    Map<String, MediaAttachment> used, {required bool render}) async {
  final pooled = [
    for (final m in pool.values)
      if (renderKindOf(m) == RenderKind.audioTranscode && m.derivedFrom == source.id) m,
  ];
  // A copy made earlier, kept (listed in [used]) so it is neither deleted
  // nor left out of the post's media, carrying the tags the track has now.
  Future<MediaAttachment?> keep(String key, MediaAttachment m) async => used[key] = await _withTags(s, post, source, m, replaceFile: false);
  Future<MediaAttachment?> earlier() async {
    final m = pooled.firstOrNull;
    return m == null ? null : keep(m.fitKey ?? m.id, m);
  }

  if (format == null) return earlier();
  final params = <String, dynamic>{'kind': RenderKind.audioTranscode, 'format': format, 'bitrate': kStandardAudioBitsPerSecond};
  final key = 'audio|${source.id}|${stableHash(jsonEncode(params))}';
  final reused = used[key] ?? pool[key];
  if (reused != null) return keep(key, reused);
  if (!render) return earlier();
  final id = const Uuid().v7();
  final out = newMediaFilePath(s.storage.dataDir, id, format);
  if (out == null) return null;
  final mime = standardAudioMimeType(format)!;
  final made = MediaAttachment(id: id, path: out, mimeType: mime, sizeBytes: 0);
  try {
    await VideoCompositor.instance.transcodeAudio(inputPath: source.path, outputPath: out, format: format, bitsPerSecond: kStandardAudioBitsPerSecond);
    final copy = MediaAttachment(
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
    // The system's encoder writes no tags: NEFORUM adds the track's own.
    return used[key] = await _withTags(s, post, source, copy, replaceFile: true);
  } on Object catch (e) {
    debugPrint('Could not convert ${source.fileName ?? source.id} to $format: $e');
    await s.media.discard(made);
    return null;
  }
}

/// `renderParameters` key of the tags written into a Standard copy: a hash
/// of the tags and the cover's file name.
const String kAudioTagsStampKey = 'tags';

/// [copy] (a Standard copy of [source]) carrying the tags the track goes out
/// with ([PostAudioTags.effectiveAudioTagsOf]) and their cover. A copy that
/// already has them is returned as it is. A new copy ([replaceFile]) is
/// rewritten in place; one kept from an earlier save is written to a new
/// file, so the old one is never half rewritten (the caller deletes the
/// copies it no longer uses). When the tags cannot be written, [copy] is
/// returned without them.
Future<MediaAttachment> _withTags(AppServices s, Post post, MediaAttachment source, MediaAttachment copy, {required bool replaceFile}) async {
  final tags = post.effectiveAudioTagsOf(source) ?? AudioTags.none;
  final coverPath = tags.coverPath;
  final stamp = audioTagsStamp(tags);
  final had = copy.renderParameters?[kAudioTagsStampKey];
  // Never tagged and nothing to say: the copy is right as it is.
  if (had == stamp || (had == null && tags.isEmpty)) return copy;
  try {
    Uint8List? cover;
    if (coverPath != null && coverPath.isNotEmpty) {
      try {
        cover = await s.storage.readMedia(coverPath);
      } on Object catch (e) {
        debugPrint('Could not read the cover $coverPath: $e');
      }
    }
    final bytes = await s.media.read(copy);
    final tagged = await compute(embedAudioTagsJob, (bytes, copy.mimeType, tags.toJson(), cover, cover == null ? null : tags.coverMimeType));
    if (tagged == null) return copy;
    final id = replaceFile ? copy.id : const Uuid().v7();
    final ext = copy.path.contains('.') ? copy.path.substring(copy.path.lastIndexOf('.') + 1) : 'bin';
    final path = await s.storage.saveMedia(id, ext, tagged);
    return MediaAttachment(
      id: id,
      path: path,
      mimeType: copy.mimeType,
      sizeBytes: tagged.length,
      durationMs: copy.durationMs,
      fileName: copy.fileName,
      generated: true,
      derivedFrom: copy.derivedFrom,
      fitKey: copy.fitKey,
      renderParameters: {...?copy.renderParameters, kAudioTagsStampKey: stamp},
      audioCodec: copy.audioCodec,
    );
  } on Object catch (e) {
    debugPrint('Could not write the tags into ${copy.path}: $e');
    return copy;
  }
}

/// A short hash of [tags] and their cover file, to tell whether a copy
/// carries them.
String audioTagsStamp(AudioTags tags) => stableHash(jsonEncode(tags.toJson()));

/// [embedAudioTags] on plain data, for [compute]: the file's bytes, its MIME
/// type, the tags as JSON, the cover's bytes and type.
Uint8List? embedAudioTagsJob((Uint8List, String, Map<String, dynamic>, Uint8List?, String?) job) {
  final (bytes, mimeType, tags, cover, coverMimeType) = job;
  return embedAudioTags(bytes, mimeType, AudioTags.fromJson(tags), cover: cover, coverMimeType: coverMimeType);
}

Future<MediaAttachment?> _video(AppServices s, Post post, PostTarget target, MediaAttachment source, (String, MediaAttachment)? picture,
    String platformId, Map<String, MediaAttachment> pool, Map<String, MediaAttachment> used,
    {required bool render, CardDesign? design}) async {
  final (width, height) = audioVideoFrame(platformId);
  final photo = picture?.$2;
  // The track's details as it goes out, with their cover, for the picture.
  final tags = post.effectiveAudioTagsOf(source);
  final coverPath = tags?.coverPath;
  final title = audioTrackTitle(source, postTitle: post.title, tags: tags);
  final words = _firstWords(textCardText(post, target), title);
  final ms = source.durationMs;
  final details = [audioFormatLabel(source), if (ms != null) formatAudioDuration(ms)].join(' · ');
  // 1.3.1: cards. A designed card is drawn from the same tags and shows their
  // cover art, else the photo.
  final texts = design == null ? null : audioCardTexts(tags ?? AudioTags.none, fallbackTitle: title);
  final params = <String, dynamic>{
    'kind': RenderKind.audioVideo,
    'width': width,
    'height': height,
    if (design != null && texts != null) ...{
      'design': design.toJson(),
      'card': stableHash(jsonEncode({for (final e in texts.entries) e.key.name: e.value})),
      'cover': ?(coverPath ?? photo?.id),
    } else if (photo != null)
      'picture': photo.id
    else
      'card': stableHash('$title|$words|$details|${tags == null ? '' : audioTagsStamp(tags)}'),
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
    final Uint8List png;
    if (design != null && texts != null) {
      final cover = (coverPath == null ? null : await decodeCardPicture(s.storage, coverPath)) ??
          (photo == null ? null : await decodeCardPicture(s.storage, photo.path));
      png = await renderDesignedAudioCard(s.storage,
          design: design,
          platformId: platformId,
          size: Size(width.toDouble(), height.toDouble()),
          safe: width / height < 0.62 ? fullScreenSafeArea(platformId) : EdgeInsets.zero,
          texts: texts,
          cover: cover,
          waveform: design.waveform.visible ? await waveformOfSound(s.storage, source) : null);
    } else {
      Uint8List? cover;
      if (photo == null && coverPath != null && coverPath.isNotEmpty) {
        try {
          cover = await s.storage.readMedia(coverPath);
        } on Object catch (e) {
          debugPrint('Could not read the cover $coverPath: $e');
        }
      }
      png = (photo == null ? null : await coverPhotoPng(await s.media.read(photo), width: width, height: height)) ??
          await renderAudioCardPng(width: width, height: height, title: title, subtitle: words, details: details, tags: tags, cover: cover);
    }
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
