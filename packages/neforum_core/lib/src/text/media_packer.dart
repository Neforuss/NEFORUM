import '../model/media.dart';
import '../model/platform_descriptor.dart';

/// Splits [media] into the posts a network with [rules] needs to carry all of
/// it: consecutive groups in the original order, each within one post's
/// limits (at most [MediaRules.maxImages] images and [MediaRules.maxVideos]
/// videos, and only one kind when the network does not mix them).
///
/// Each group takes as many of the next items as still fit, which gives the
/// fewest posts any split that keeps the order can have: whatever fits in a
/// post also fits with fewer items in it.
///
/// [isVideo] says which items count as videos (a sound file that goes out as
/// a video does); by default [MediaAttachment.isVideo]. Every item must be of
/// a kind the network takes: [rules] with no room for one (a video where
/// [MediaRules.maxVideos] is 0) gives that item a group of its own, so the
/// caller should leave such items out first. An empty [media] gives no
/// groups.
List<List<MediaAttachment>> packMediaIntoPosts(List<MediaAttachment> media, MediaRules rules,
    {bool Function(MediaAttachment m)? isVideo}) {
  final video = isVideo ?? (MediaAttachment m) => m.isVideo;
  final groups = <List<MediaAttachment>>[];
  var current = <MediaAttachment>[];
  var images = 0, videos = 0;
  for (final m in media) {
    final v = video(m);
    final room = v ? videos < rules.maxVideos : images < rules.maxImages;
    final sameKind = rules.allowsMixedImageVideo || current.isEmpty || video(current.first) == v;
    if (current.isNotEmpty && !(room && sameKind)) {
      groups.add(current);
      current = <MediaAttachment>[];
      images = 0;
      videos = 0;
    }
    current.add(m);
    if (v) {
      videos++;
    } else {
      images++;
    }
  }
  if (current.isNotEmpty) groups.add(current);
  return groups;
}
