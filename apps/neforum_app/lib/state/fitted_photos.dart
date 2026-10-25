import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/photo_fitter.dart';
import 'captioned_photos.dart';
import 'services.dart';
import 'settings.dart';

/// The whole frame a network shows photos in, as width / height: TikTok
/// 9:16, Instagram 4:5 (feed and carousels) or 9:16 (stories). Null for the
/// others.
double? fullFrameAspect(String platformId, PostVariant v) => switch (platformId) {
      'tiktok' => 9 / 16,
      'instagram' => (v.extraAs<bool>('storyMode') ?? false) ? 9 / 16 : 4 / 5,
      _ => null,
    };

/// The photo rules NEFORUM fits a target's photos to: the platform's own
/// ([PlatformAdapter.photoFit]) and, when Settings fit photos to the whole
/// frame on that network, exactly its frame shape ([fullFrameAspect]), so
/// nothing is cut off or shown with black bars there.
PhotoFit? effectivePhotoFit(PlatformAdapter adapter, ConnectedAccount account, PostVariant variant, AppSettings settings) {
  final fit = adapter.photoFit(account, variant);
  final frame = settings.fillsFrame(account.platformId) ? fullFrameAspect(account.platformId, variant) : null;
  if (frame == null) return fit;
  return (fit ?? PhotoFit(label: adapter.descriptorForAccount(account).name)).copyWith(minAspect: frame, maxAspect: frame);
}

/// Gives every target whose platform does not take one of the post's photos
/// as it is (Instagram's 4:5 to 1.91:1, a file type, a size or pixel limit;
/// see [PlatformAdapter.photoFit]) a fitted copy of that photo instead, and
/// removes copies that are no longer needed. Safe to call repeatedly: a copy
/// made for the same photo and rules is kept, and two platforms with the same
/// rules share one.
///
/// Copies are media files marked [MediaAttachment.generated] with
/// [MediaAttachment.derivedFrom]; only the targets that list them in their
/// overrides receive them, in place of the original. Call after
/// [attachTextCards]. A photo that cannot be read (HEIC) is left as it is, so
/// its target still fails with the platform's own message.
Future<Post> attachFittedPhotos(AppServices s, Post post, AppSettings settings) async {
  final mode = settings.photoFit;
  // Photos with the caption written on them are managed by
  // attachCaptionedPhotos, which runs after this.
  final pool = {for (final m in post.media.where((m) => m.derivedFrom != null && !isCaptionedCopy(m))) '${m.derivedFrom}|${m.fitKey}': m};
  // Handed on untouched (no target lists them here), for attachCaptionedPhotos
  // to reuse or remove.
  final captioned = [for (final m in post.media) if (isCaptionedCopy(m)) m];
  var p = withoutFittedPhotos(post);
  if (mode == PhotoFitMode.off) {
    for (final m in pool.values) {
      await s.media.discard(m);
    }
    return p.copyWith(media: [...p.media, ...captioned]);
  }

  final resolver = VariantResolver(settings.resolverOptions);
  final userMedia = [for (final m in p.media) if (!m.generated) m];
  final used = <String, MediaAttachment>{};

  for (final original in post.targets) {
    final t = p.targetFor(original.accountId)!;
    final account = await s.accounts.get(t.accountId);
    final adapter = account == null ? null : s.registry.byId(account.platformId);
    if (account == null || adapter == null) continue;
    final variant = resolver.resolve(p, t, adapter.descriptorForAccount(account), account: account);
    final fit = effectivePhotoFit(adapter, account, variant, settings);
    if (fit == null) continue;

    final ids = t.overrides.mediaIds ?? [for (final m in userMedia) m.id];
    var changed = false;
    final next = <String>[];
    for (final id in ids) {
      final m = p.media.where((x) => x.id == id).firstOrNull;
      if (m == null || m.generated || fit.problemsOf(m).isEmpty) {
        next.add(id);
        continue;
      }
      final key = '${m.id}|${fit.keyFor(mode)}';
      var copy = used[key] ?? pool[key];
      if (copy == null) {
        try {
          final out = await fitPhoto(await s.media.read(m), m.mimeType, fit, mode);
          if (out != null) {
            final made = await s.media.importBytes(out.bytes, fileName: _fittedName(m, out.mimeType), mimeHint: out.mimeType);
            copy = MediaAttachment(
              id: made.id,
              path: made.path,
              mimeType: out.mimeType,
              sizeBytes: made.sizeBytes,
              width: out.width,
              height: out.height,
              fileName: made.fileName,
              generated: true,
              derivedFrom: m.id,
              fitKey: fit.keyFor(mode),
            );
          }
        } on Object catch (e) {
          debugPrint('Could not fit ${m.fileName ?? m.id} for ${adapter.descriptor.name}: $e');
        }
      }
      if (copy == null) {
        next.add(id);
        continue;
      }
      // The original's alt text, as it is now.
      copy = copy.copyWith(altText: m.altText, clearAltText: m.altText == null);
      used[key] = copy;
      next.add(copy.id);
      changed = true;
    }
    if (changed) p = p.withTarget(t.copyWith(overrides: t.overrides.copyWith(mediaIds: next)));
  }

  final keep = {for (final m in used.values) m.id};
  for (final m in pool.values) {
    if (!keep.contains(m.id)) await s.media.discard(m);
  }
  return p.copyWith(media: [...p.media, ...used.values, ...captioned]);
}

/// Fits the photos of the saved post [postId] (see [attachFittedPhotos]) before
/// it is published in the background (scheduled posts, Publish now on a
/// reminder): posts saved before photos were fitted, or before a setting
/// changed. The caption stays written on the photos it was written on when
/// the post was saved, in the same style ([attachCaptionedPhotos]), and is
/// left off where it was off. Best effort; the post is left as it is on any
/// problem.
Future<void> fitPhotosOfSavedPost(AppServices s, String postId) async {
  try {
    final post = await s.posts.get(postId);
    if (post == null || !post.media.any((m) => !m.generated)) return;
    // Read first: fitting lists the original photos on the targets again.
    final choices = await captionChoicesOfSavedPost(s, post);
    final fitted = await attachFittedPhotos(s, post, s.settings);
    await s.posts.upsert(await attachCaptionedPhotos(s, fitted, s.settings, choices: choices));
  } on Object catch (e) {
    debugPrint('Could not fit the photos of $postId: $e');
  }
}

/// [post] without fitted copies (captioned copies included): each target lists
/// the original photos again (and no list at all when that is every photo, as
/// before fitting).
Post withoutFittedPhotos(Post post) {
  final fitted = {for (final m in post.media.where((m) => m.derivedFrom != null)) m.id: m.derivedFrom!};
  if (fitted.isEmpty) return post;
  final media = [for (final m in post.media) if (!fitted.containsKey(m.id)) m];
  final all = [for (final m in media) if (!m.generated) m.id];
  return post.copyWith(
    media: media,
    targets: [
      for (final t in post.targets)
        if (t.overrides.mediaIds == null || !t.overrides.mediaIds!.any(fitted.containsKey))
          t
        else
          () {
            final ids = [for (final id in t.overrides.mediaIds!) fitted[id] ?? id];
            return t.copyWith(overrides: listEquals(ids, all) ? t.overrides.copyWith(clearMediaIds: true) : t.overrides.copyWith(mediaIds: ids));
          }(),
    ],
  );
}

/// "cat.jpg" -> "cat (fitted).jpg"; a JPEG made from a PNG gets ".jpg".
String _fittedName(MediaAttachment m, String mimeType) {
  final name = m.fileName ?? m.id;
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final ext = mimeType == 'image/png' ? 'png' : 'jpg';
  return '$base (fitted).$ext';
}
