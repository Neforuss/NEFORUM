import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:uuid/uuid.dart';

import '../media/caption_fonts.dart';
import '../media/caption_overlay.dart';
import '../media/caption_style.dart';
import '../media/render_parameters.dart';
import '../media/text_card.dart';
import '../platform/media_files.dart';
import '../platform/video_compositor.dart';
import 'fitted_photos.dart';
import 'render_warnings.dart';
import 'services.dart';
import 'settings.dart';
import 'shrunk_videos.dart';

export '../media/render_parameters.dart' show stableHash;

/// Networks where NEFORUM can write the caption onto the first photo.
const Set<String> kCaptionPhotoPlatforms = {'instagram', 'tiktok'};

/// Marks a photo NEFORUM made with the caption written on it.
const String _captionKeyPrefix = 'caption|';

/// A copy of a photo with the caption written on it ([attachCaptionedPhotos]).
bool isCaptionedCopy(MediaAttachment m) => m.derivedFrom != null && (m.fitKey ?? '').startsWith(_captionKeyPrefix);

/// Whether this device can put a caption block above a video
/// ([VideoCompositor]).
final videoCaptionsSupportedProvider = FutureProvider<bool>((ref) => VideoCompositor.instance.isSupported());

/// Shape of the frame a video with a caption block above it is made in:
/// TikTok and Instagram (Reels and stories) show videos at 9:16.
double? videoFrameAspect(String platformId) => kCaptionPhotoPlatforms.contains(platformId) ? 9 / 16 : null;

/// Whether [platformId]'s first photo gets the caption: the post's own choice
/// ([choices]), else the Settings default.
bool captionOnPhotoFor(String platformId, AppSettings settings, Map<String, bool> choices) =>
    kCaptionPhotoPlatforms.contains(platformId) && (choices[platformId] ?? settings.captionOnPhoto(platformId));

/// The caption style of a post: its own ([postStyle], [CaptionStyle.toJson]),
/// else the Settings default.
CaptionStyle captionStyleFor(Map<String, dynamic>? postStyle, AppSettings settings) => CaptionStyle.fromJson(postStyle ?? settings.captionStyle);

/// For Instagram and TikTok targets that want it, replaces the first photo
/// (after fitting) with a copy that has the caption written on it in the
/// [CaptionStyle]: [style] (the composer's), else the style the post's copies
/// were made with, else the Settings default. On the photo, the copy keeps the
/// photo's size; in a block above, it is the network's whole frame made from
/// the photo the user attached ([renderCaptionedPhoto]). Videos and text
/// cards are left alone (a video's block is made by [renderCaptionBlockOverlay]
/// for the video compositor). Copies made with the same photo, words and
/// style are reused; the rest are deleted. Call after [attachFittedPhotos].
///
/// [composeVideos] false, for a saved post that is being published, only
/// reuses the video copies the post already has: a caption block goes above a
/// video when the post is saved, as its preview showed, never later from the
/// Settings of that moment.
Future<Post> attachCaptionedPhotos(AppServices s, Post post, AppSettings settings,
    {Map<String, bool> choices = const {}, Map<String, dynamic>? style, bool composeVideos = true}) async {
  final pool = {for (final m in post.media.where(isCaptionedCopy)) m.fitKey!: m};
  final look = captionStyleFor(style ?? captionStyleOfPost(post), settings);
  final block = look.placement == CaptionPlacement.blockAbove;
  final resolver = VariantResolver(settings.resolverOptions);
  var p = post.copyWith(media: [for (final m in post.media) if (!isCaptionedCopy(m)) m]);
  final used = <String, MediaAttachment>{};
  // 1.3: cards. A font installed or imported for the caption is loaded once,
  // when the first copy needs it. Where it is missing the copy is drawn in
  // the built-in font and says so in its render parameters, so it is made
  // again once the font is here.
  final customFont = look.customFont;
  Future<bool>? fontReady;
  Future<bool> fontMissing() async => customFont != null && !await (fontReady ??= prepareCaptionFontForRender(s.storage, customFont));

  /// The copy of the feed photo [first] with [words] on it for [platform]
  /// ([frame]: the network's whole frame, for a block above); null when it
  /// could not be made, and the photo then goes as it is.
  Future<MediaAttachment?> photoCopy(MediaAttachment first, String words, String platform, double? frame) async {
    // A frame is made from the photo the user attached: a fitted copy's
    // borders would only be shrunk into it.
    final source = frame == null ? first : (p.media.where((m) => m.id == first.derivedFrom).firstOrNull ?? first);
    final params = <String, dynamic>{
      'kind': RenderKind.caption,
      'platform': platform,
      'style': look.toJson(),
      'textHash': stableHash(words),
      'frameAspect': ?frame,
      if (frame != null) 'fit': settings.photoFit.name,
      if (frame != null) 'layout': kCaptionBlockLayoutVersion, // 1.4.1: the photo right under the words
      if (await fontMissing()) 'fontFallback': true, // 1.3: cards
    };
    final key = '$_captionKeyPrefix$platform|${source.id}|${stableHash(words)}|${stableHash(jsonEncode(params))}';
    var copy = used[key] ?? pool[key];
    // Copies made before 1.2.0 have the default style and no style in their
    // key; reusing them spares a scheduled post rendering in the background.
    if (copy == null && look == const CaptionStyle()) copy = pool['$_captionKeyPrefix$platform|${source.id}|${stableHash(words)}'];
    if (copy == null) {
      try {
        final out = await renderCaptionedPhoto(
          await s.media.read(source),
          text: words,
          font: look.font.resolve(platform),
          platformId: platform,
          style: look,
          frameAspect: frame,
          fit: settings.photoFit,
        ).timeout(kRenderTimeLimit);
        if (out != null) {
          final made = await s.media.importBytes(out.bytes, fileName: _captionedName(source), mimeHint: 'image/jpeg');
          copy = MediaAttachment(
            id: made.id,
            path: made.path,
            mimeType: 'image/jpeg',
            sizeBytes: made.sizeBytes,
            width: out.width,
            height: out.height,
            fileName: made.fileName,
            generated: true,
            // Back to the photo the user attached, through a fitted copy.
            derivedFrom: first.derivedFrom ?? first.id,
            fitKey: key,
            renderParameters: params,
          );
        }
      } on TimeoutException {
        // Never let a picture hold the post up: the photo goes as it is.
        reportRenderWarning('Writing the caption on the photo for ${s.registry.descriptor(platform)?.name ?? platform} took too long, '
            'so the photo goes without it. To try again, open the post and turn Caption on photo back on.');
      } on Object catch (e) {
        debugPrint('Could not write the caption on ${first.fileName ?? first.id}: $e');
      }
    }
    if (copy == null) return null;
    copy = copy.copyWith(altText: first.altText, clearAltText: first.altText == null);
    used[key] = copy;
    return copy;
  }

  /// The copy of the Instagram story frame [first] with [words] on it, in the
  /// story's 9:16 frame; null when it could not be made.
  Future<MediaAttachment?> storyCopy(MediaAttachment first, String words) async {
    const frame = 9 / 16;
    // In a block: the frame is made from the photo the user attached. On the
    // photo: the story's copy fitted to 9:16, as the story shows it.
    final source = block ? (p.media.where((m) => m.id == first.derivedFrom).firstOrNull ?? first) : first;
    final params = <String, dynamic>{
      'kind': RenderKind.caption,
      'platform': 'instagram',
      'story': true,
      'style': look.toJson(),
      'textHash': stableHash(words),
      if (block) ...{'frameAspect': frame, 'fit': settings.photoFit.name, 'layout': kCaptionBlockLayoutVersion},
      if (await fontMissing()) 'fontFallback': true,
    };
    final key = '${_captionKeyPrefix}instagram-story|${source.id}|${stableHash(words)}|${stableHash(jsonEncode(params))}';
    var copy = used[key] ?? pool[key];
    if (copy == null) {
      try {
        final out = await renderCaptionedPhoto(
          await s.media.read(source),
          text: words,
          font: look.font.resolve('instagram'),
          platformId: 'instagram',
          style: look,
          frameAspect: block ? frame : null,
          fit: settings.photoFit,
        ).timeout(kRenderTimeLimit);
        if (out != null) {
          final made = await s.media.importBytes(out.bytes, fileName: _captionedName(source), mimeHint: 'image/jpeg');
          copy = MediaAttachment(
            id: made.id,
            path: made.path,
            mimeType: 'image/jpeg',
            sizeBytes: made.sizeBytes,
            width: out.width,
            height: out.height,
            fileName: made.fileName,
            generated: true,
            derivedFrom: first.derivedFrom ?? first.id,
            fitKey: key,
            renderParameters: params,
          );
        }
      } on TimeoutException {
        reportRenderWarning('Writing the caption on the Instagram story took too long, so the story goes without it. '
            'To try again, open the post and save it again.');
      } on Object catch (e) {
        debugPrint('Could not write the caption on the story photo ${first.fileName ?? first.id}: $e');
      }
    }
    if (copy == null) return null;
    copy = copy.copyWith(altText: first.altText, clearAltText: first.altText == null);
    used[key] = copy;
    return copy;
  }

  for (final original in post.targets) {
    final t = p.targetFor(original.accountId)!;
    final account = await s.accounts.get(t.accountId);
    if (account == null || !captionOnPhotoFor(account.platformId, settings, choices)) continue;
    final ids = t.overrides.mediaIds ?? [for (final m in p.media) if (!m.generated) m.id];
    if (ids.isEmpty) continue;
    // 1.4.3: paragraphs linked to photos (Instagram): each photo that opens
    // a section of the carousel carries that section's words instead of the
    // whole caption on the first photo.
    final linked = s.registry.byId(account.platformId);
    final byParagraph =
        linked == null ? null : paragraphCaptionWords(p, t, linked.descriptorForAccount(account), [for (final id in ids) ...p.media.where((m) => m.id == id)], look);
    if (byParagraph != null) {
      final frame = block ? fullFrameAspect(account.platformId, resolver.resolve(p, t, linked!.descriptorForAccount(account), account: account)) : null;
      final next = [...ids];
      for (final e in byParagraph.entries) {
        final i = ids.indexOf(e.key);
        final photo = p.media.where((m) => m.id == e.key).firstOrNull;
        if (i < 0 || photo == null || !_takesWords(photo)) continue;
        final copy = await photoCopy(photo, e.value, account.platformId, frame);
        if (copy != null) next[i] = copy.id;
      }
      p = p.withTarget(t.copyWith(overrides: t.overrides.copyWith(mediaIds: next)));
      continue;
    }
    final first = p.media.where((m) => m.id == ids.first).firstOrNull;
    if (first == null || first.isTextCard || first.isAudio || first.mimeType == 'image/gif') continue;
    // A video gets the caption only as a block above it, made by the video
    // compositor where this device has one.
    if (first.isVideo && !block) continue;
    final words = look.wordsFor(captionWords(p, t));
    if (words.isEmpty) continue;

    final platform = account.platformId;
    double? frame;
    if (block) {
      final adapter = s.registry.byId(platform);
      if (adapter != null) frame = fullFrameAspect(platform, resolver.resolve(p, t, adapter.descriptorForAccount(account), account: account));
    }
    if (first.isVideo) {
      frame = videoFrameAspect(platform);
      if (frame == null) continue;
      Map<String, dynamic> paramsWith({required bool fontFallback, bool legacyLayout = false}) => {
            'kind': RenderKind.caption,
            'platform': platform,
            'style': look.toJson(),
            'textHash': stableHash(words),
            'frameAspect': frame,
            'video': true,
            if (fontFallback) 'fontFallback': true, // 1.3: cards
            if (!legacyLayout) 'layout': kCaptionBlockLayoutVersion, // 1.4.1: the video right under the words
          };
      String keyOf(Map<String, dynamic> params) => '$_captionKeyPrefix$platform|${first.id}|${stableHash(words)}|${stableHash(jsonEncode(params))}';
      final fallback = await fontMissing();
      final params = paramsWith(fontFallback: fallback);
      final key = keyOf(params);
      var copy = used[key] ?? pool[key];
      if (copy == null && !composeVideos) {
        // Publishing never makes the copy again, so the one the save made is
        // used whether or not the caption font was here then or is here now.
        // A video saved before 1.4.1 keeps the block it was saved with.
        for (final key in [
          keyOf(paramsWith(fontFallback: !fallback)),
          keyOf(paramsWith(fontFallback: fallback, legacyLayout: true)),
          keyOf(paramsWith(fontFallback: !fallback, legacyLayout: true)),
        ]) {
          copy ??= used[key] ?? pool[key];
        }
      }
      copy ??= composeVideos ? await _composeCaptionedVideo(s, first, words: words, style: look, platform: platform, frame: frame, key: key, params: params) : null;
      if (copy == null) continue;
      used[key] = copy;
      p = p.withTarget(t.copyWith(overrides: t.overrides.copyWith(mediaIds: [copy.id, ...ids.skip(1)])));
      continue;
    }
    final copy = await photoCopy(first, words, platform, frame);
    if (copy == null) continue;
    p = p.withTarget(t.copyWith(overrides: t.overrides.copyWith(mediaIds: [copy.id, ...ids.skip(1)])));
  }

  // 1.4.1: Instagram Post + Story. A story has no caption field, so its first
  // photo gets the caption written on it too, in the story's 9:16 frame
  // (Settings: captionOnStory, on by default), unless the caption is off for
  // Instagram on this post.
  if (settings.captionOnStory) {
    for (final original in post.targets) {
      final t = p.targetFor(original.accountId)!;
      final story = t.overrides.storyMediaIds;
      if (story == null || story.isEmpty) continue;
      final account = await s.accounts.get(t.accountId);
      if (account == null || account.platformId != 'instagram' || !captionOnPhotoFor('instagram', settings, choices)) continue;
      final adapter = s.registry.byId('instagram');
      if (adapter == null) continue;
      if (resolver.resolve(p, t, adapter.descriptorForAccount(account), account: account).placement != PostPlacement.feedAndStory) continue;
      // 1.4.3: paragraphs linked to photos: each frame that opens a section
      // carries that section's words, so the story tells the post frame by
      // frame (a paragraph about several photos is on the first of them).
      final byParagraph = paragraphCaptionWords(p, t, adapter.descriptorForAccount(account), [for (final id in story) ...p.media.where((m) => m.id == id)], look);
      if (byParagraph != null) {
        final next = [...story];
        for (final e in byParagraph.entries) {
          final i = story.indexOf(e.key);
          final frame = p.media.where((m) => m.id == e.key).firstOrNull;
          if (i < 0 || frame == null || !_takesWords(frame)) continue;
          final copy = await storyCopy(frame, e.value);
          if (copy != null) next[i] = copy.id;
        }
        p = p.withTarget(t.copyWith(overrides: t.overrides.copyWith(storyMediaIds: next)));
        continue;
      }
      final first = p.media.where((m) => m.id == story.first).firstOrNull;
      if (first == null || !_takesWords(first)) continue;
      final words = look.wordsFor(captionWords(p, t));
      if (words.isEmpty) continue;
      final copy = await storyCopy(first, words);
      if (copy == null) continue;
      p = p.withTarget(t.copyWith(overrides: t.overrides.copyWith(storyMediaIds: [copy.id, ...story.skip(1)])));
    }
  }

  final keep = {for (final m in used.values) m.id};
  for (final m in pool.values) {
    if (!keep.contains(m.id)) await s.media.discard(m);
  }
  return p.copyWith(media: [...p.media, ...used.values]);
}

/// The words written on the photo: the network's caption without trailing
/// lines that are only hashtags or links (those stay in the caption).
String captionWords(Post post, PostTarget target) => textCardText(post, target);

/// A photo that can carry words: a still photo the user attached (or a copy
/// of one), not a GIF, a video or a text card.
bool _takesWords(MediaAttachment m) => m.kind == MediaKind.image && !m.isTextCard && m.mimeType != 'image/gif';

/// 1.4.3: when [post]'s paragraphs are linked to its photos and the network
/// [d] shows the links, the words each of [media] (a target's feed photos or
/// story frames) carries: by media id, the words of the section the photo
/// opens ([ParagraphMedia.wordsByMedia], in the order the network gets the
/// files), without trailing lines that are only hashtags or links. Null when
/// the links do not apply: no links, a thread, the network's own version of
/// the words, words of the caption style's own, or a network that ignores
/// them. The caption then goes on the first photo as before.
Map<String, String>? paragraphCaptionWords(Post post, PostTarget target, PlatformDescriptor d, List<MediaAttachment> media, CaptionStyle look) {
  if (!post.hasParagraphMedia || target.overrides.text != null || (look.text ?? '').trim().isNotEmpty) return null;
  if (d.media.paragraphMedia == ParagraphMediaStyle.none) return null;
  final links = ParagraphMedia.normalized(post.paragraphMedia, paragraphs: ParagraphMedia.split(post.text).length);
  final words = {
    for (final e in ParagraphMedia.wordsByMedia(post.text, links, ParagraphMedia.ordered(media, links)).entries)
      if (withoutTrailingTagsAndLinks(e.value) case final w when w.isNotEmpty) e.key: w,
  };
  return words.isEmpty ? null : words;
}

/// Platform id -> whether its first photo on [post] has the caption written
/// on it, for the composer when a saved post is edited again and for
/// publishing a saved post. A network whose first item is a photo without the
/// caption reads as off, so a post saved with the caption off stays that way
/// when the Settings default changes; a network without a photo yet is left
/// to the default.
Map<String, bool> captionChoicesOfPost(Post post, String? Function(String accountId) platformOf) {
  final byId = {for (final m in post.media) m.id: m};
  final out = <String, bool>{};
  for (final t in post.targets) {
    final platform = platformOf(t.accountId);
    if (platform == null || !kCaptionPhotoPlatforms.contains(platform)) continue;
    final ids = t.overrides.mediaIds ?? [for (final m in post.media) if (!m.generated) m.id];
    // 1.4.3: with paragraphs linked to photos the words go on the photo that
    // opens each section, which need not be the first.
    if (post.hasParagraphMedia && ids.any((id) => byId[id] != null && isCaptionedCopy(byId[id]!))) {
      out[platform] = true;
      continue;
    }
    var first = ids.isEmpty ? null : byId[ids.first];
    // 1.3: video. A smaller copy stands for the video it was made from.
    if (first != null && isShrunkCopy(first)) first = byId[shrunkCopySourceId(first)] ?? first;
    if (first == null || first.isTextCard || first.isAudio || first.mimeType == 'image/gif') continue;
    // A video without a caption block may be on a device without a video
    // compositor, so only a captioned one counts as a choice.
    if (first.isVideo) {
      if (isCaptionedCopy(first)) out[platform] = true;
      continue;
    }
    out[platform] = (out[platform] ?? false) || isCaptionedCopy(first);
  }
  return out;
}

/// [captionChoicesOfPost] for a saved post, outside the composer (scheduled
/// and background publishing).
Future<Map<String, bool>> captionChoicesOfSavedPost(AppServices s, Post post) async {
  final platforms = <String, String>{};
  for (final t in post.targets) {
    final a = await s.accounts.get(t.accountId);
    if (a != null) platforms[t.accountId] = a.platformId;
  }
  return captionChoicesOfPost(post, (id) => platforms[id]);
}

/// The caption style the copies on [post] were made with
/// ([CaptionStyle.toJson]), for the composer when a saved post is edited
/// again and for publishing a saved post; null when there are none. Copies
/// made before 1.2.0 carry no style: they were made in the default style, so
/// they are kept (not made again in a style chosen later in Settings).
Map<String, dynamic>? captionStyleOfPost(Post post) {
  var legacyCopy = false;
  for (final m in post.media) {
    if (!isCaptionedCopy(m)) continue;
    final p = m.renderParameters;
    if (p == null || p['kind'] != RenderKind.caption) {
      legacyCopy = true;
      continue;
    }
    final style = p['style'];
    if (style is Map) return Map<String, dynamic>.from(style);
  }
  return legacyCopy ? const CaptionStyle().toJson() : null;
}

/// A copy of [video] in the network's whole frame of [frame] aspect, with the
/// caption block above it ([renderCaptionBlockOverlay], [VideoCompositor]);
/// null when this device cannot compose videos or composing fails, and the
/// original video then goes out unchanged.
Future<MediaAttachment?> _composeCaptionedVideo(AppServices s, MediaAttachment video,
    {required String words,
    required CaptionStyle style,
    required String platform,
    required double frame,
    required String key,
    required Map<String, dynamic> params}) async {
  final compositor = VideoCompositor.instance;
  if (!await compositor.isSupported()) return null;
  final id = const Uuid().v7();
  final out = newMediaFilePath(s.storage.dataDir, id, 'mp4');
  if (out == null) return null;
  final made = MediaAttachment(id: id, path: out, mimeType: 'video/mp4', sizeBytes: 0);
  try {
    final overlay = await renderCaptionBlockOverlay(text: words, style: style, platformId: platform, frameAspect: frame, videoAspect: video.aspectRatio);
    await compositor.compose(
      inputPath: video.path,
      outputPath: out,
      overlayPng: overlay.png,
      frameWidth: overlay.frameWidth,
      frameHeight: overlay.frameHeight,
      contentRect: overlay.contentRect,
      backgroundArgb: overlay.backgroundArgb,
    );
    return MediaAttachment(
      id: id,
      path: out,
      mimeType: 'video/mp4',
      sizeBytes: await mediaFileLength(out),
      width: overlay.frameWidth,
      height: overlay.frameHeight,
      durationMs: video.durationMs,
      altText: video.altText,
      fileName: _captionedVideoName(video),
      generated: true,
      derivedFrom: video.id,
      fitKey: key,
      renderParameters: params,
    );
  } on Object catch (e) {
    debugPrint('Could not put the caption above ${video.fileName ?? video.id}: $e');
    await s.media.discard(made);
    return null;
  }
}

String _captionedVideoName(MediaAttachment m) {
  final name = m.fileName ?? m.id;
  final dot = name.lastIndexOf('.');
  return '${dot > 0 ? name.substring(0, dot) : name} (captioned).mp4';
}

String _captionedName(MediaAttachment m) {
  final name = m.fileName ?? m.id;
  final dot = name.lastIndexOf('.');
  return '${dot > 0 ? name.substring(0, dot) : name} (captioned).jpg';
}
