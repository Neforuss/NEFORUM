import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/caption_overlay.dart';
import '../media/caption_style.dart';
import '../media/render_parameters.dart';
import '../media/text_card.dart';
import 'fitted_photos.dart';
import 'services.dart';
import 'settings.dart';

export '../media/render_parameters.dart' show stableHash;

/// Networks where NEFORUM can write the caption onto the first photo.
const Set<String> kCaptionPhotoPlatforms = {'instagram', 'tiktok'};

/// Marks a photo NEFORUM made with the caption written on it.
const String _captionKeyPrefix = 'caption|';

/// A copy of a photo with the caption written on it ([attachCaptionedPhotos]).
bool isCaptionedCopy(MediaAttachment m) => m.derivedFrom != null && (m.fitKey ?? '').startsWith(_captionKeyPrefix);

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
Future<Post> attachCaptionedPhotos(AppServices s, Post post, AppSettings settings,
    {Map<String, bool> choices = const {}, Map<String, dynamic>? style}) async {
  final pool = {for (final m in post.media.where(isCaptionedCopy)) m.fitKey!: m};
  final look = captionStyleFor(style ?? captionStyleOfPost(post), settings);
  final block = look.placement == CaptionPlacement.blockAbove;
  final resolver = VariantResolver(settings.resolverOptions);
  var p = post.copyWith(media: [for (final m in post.media) if (!isCaptionedCopy(m)) m]);
  final used = <String, MediaAttachment>{};

  for (final original in post.targets) {
    final t = p.targetFor(original.accountId)!;
    final account = await s.accounts.get(t.accountId);
    if (account == null || !captionOnPhotoFor(account.platformId, settings, choices)) continue;
    final ids = t.overrides.mediaIds ?? [for (final m in p.media) if (!m.generated) m.id];
    if (ids.isEmpty) continue;
    final first = p.media.where((m) => m.id == ids.first).firstOrNull;
    if (first == null || first.kind != MediaKind.image || first.isTextCard || first.mimeType == 'image/gif') continue;
    final words = look.wordsFor(captionWords(p, t));
    if (words.isEmpty) continue;

    final platform = account.platformId;
    double? frame;
    if (block) {
      final adapter = s.registry.byId(platform);
      if (adapter != null) frame = fullFrameAspect(platform, resolver.resolve(p, t, adapter.descriptorForAccount(account), account: account));
    }
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
        );
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
      } on Object catch (e) {
        debugPrint('Could not write the caption on ${first.fileName ?? first.id}: $e');
      }
    }
    if (copy == null) continue;
    copy = copy.copyWith(altText: first.altText, clearAltText: first.altText == null);
    used[key] = copy;
    p = p.withTarget(t.copyWith(overrides: t.overrides.copyWith(mediaIds: [copy.id, ...ids.skip(1)])));
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
    final first = ids.isEmpty ? null : byId[ids.first];
    if (first == null || first.kind != MediaKind.image || first.isTextCard) continue;
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
/// again; null when there are none (or only copies made before 1.2.0, which
/// used the default style).
Map<String, dynamic>? captionStyleOfPost(Post post) {
  for (final m in post.media) {
    final p = m.renderParameters;
    if (!isCaptionedCopy(m) || p == null || p['kind'] != RenderKind.caption) continue;
    final style = p['style'];
    if (style is Map) return Map<String, dynamic>.from(style);
  }
  return null;
}

String _captionedName(MediaAttachment m) {
  final name = m.fileName ?? m.id;
  final dot = name.lastIndexOf('.');
  return '${dot > 0 ? name.substring(0, dot) : name} (captioned).jpg';
}
