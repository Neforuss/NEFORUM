import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/caption_overlay.dart';
import '../media/text_card.dart';
import 'services.dart';
import 'settings.dart';

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

/// For Instagram and TikTok targets that want it, replaces the first photo
/// (after fitting) with a copy that has the caption written on it in the
/// network's own font ([CaptionOverlayPainter]). Videos and text cards are
/// left alone. Copies whose photo and words still match are reused; the rest
/// are deleted. Call after [attachFittedPhotos].
Future<Post> attachCaptionedPhotos(AppServices s, Post post, AppSettings settings, {Map<String, bool> choices = const {}}) async {
  final pool = {for (final m in post.media.where(isCaptionedCopy)) m.fitKey!: m};
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
    final words = captionWords(p, t);
    if (words.isEmpty) continue;

    final platform = account.platformId;
    final key = '$_captionKeyPrefix$platform|${first.id}|${stableHash(words)}';
    var copy = used[key] ?? pool[key];
    if (copy == null) {
      try {
        final out = await renderCaptionedPhoto(await s.media.read(first),
            text: words, font: TextCardFont.platform.resolve(platform), platformId: platform);
        if (out != null) {
          final made = await s.media.importBytes(out.bytes, fileName: _captionedName(first), mimeHint: 'image/jpeg');
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

/// Platform id -> whether its photo on [post] has the caption written on it,
/// for the composer when a saved post is edited again.
Map<String, bool> captionChoicesOfPost(Post post, String? Function(String accountId) platformOf) {
  final copies = {for (final m in post.media.where(isCaptionedCopy)) m.id};
  final out = <String, bool>{};
  for (final t in post.targets) {
    final platform = platformOf(t.accountId);
    if (platform == null || !kCaptionPhotoPlatforms.contains(platform)) continue;
    final ids = t.overrides.mediaIds;
    if (ids != null && ids.any(copies.contains)) out[platform] = true;
  }
  return out;
}

/// FNV-1a over the UTF-16 code units: the same on every run (unlike
/// String.hashCode), so a saved copy is found again.
@visibleForTesting
String stableHash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16);
}

String _captionedName(MediaAttachment m) {
  final name = m.fileName ?? m.id;
  final dot = name.lastIndexOf('.');
  return '${dot > 0 ? name.substring(0, dot) : name} (captioned).jpg';
}
