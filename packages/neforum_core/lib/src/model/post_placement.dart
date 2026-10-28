import 'media.dart';
import 'post_variant.dart';
import 'validation.dart';

/// Where a target's post goes on a network with stories (Instagram, Facebook
/// Pages): the feed, a story, or both at once on the same account.
enum PostPlacement {
  /// A regular post in the feed (a photo, a carousel, a Reel, a Page post).
  feed,

  /// A story: one frame per photo or video, without a caption.
  story,

  /// The feed post and the story, each checked by its own rules.
  feedAndStory;

  bool get includesFeed => this != story;
  bool get includesStory => this != feed;

  /// The composer's words for it.
  String get label => switch (this) {
        feed => 'Post',
        story => 'Story',
        feedAndStory => 'Post + Story',
      };

  /// The placement stored as [raw] (its name), or null.
  static PostPlacement? tryParse(Object? raw) {
    for (final p in values) {
      if (p.name == raw) return p;
    }
    return null;
  }
}

/// `PostOverrides.extra` key of a target's [PostPlacement] (its name).
const String kPlacementKey = 'placement';

/// `PostOverrides.extra` key NEFORUM 1.2 used for "Post as a story" (bool).
/// Still read, and still written next to [kPlacementKey] for a story, so a
/// device that has not updated yet posts it the same way.
const String kStoryModeKey = 'storyMode';

/// The placement a target's extra knobs ask for: [kPlacementKey], else the
/// 1.2 flag [kStoryModeKey], else the feed.
PostPlacement placementOfExtra(Map<String, dynamic> extra) =>
    PostPlacement.tryParse(extra[kPlacementKey]) ?? (extra[kStoryModeKey] == true ? PostPlacement.story : PostPlacement.feed);

/// [extra] set to [placement], with the 1.2 flag kept in step.
Map<String, dynamic> extraWithPlacement(Map<String, dynamic> extra, PostPlacement placement) {
  final out = {...extra}
    ..remove(kPlacementKey)
    ..remove(kStoryModeKey);
  return switch (placement) {
    PostPlacement.feed => out,
    PostPlacement.story => out
      ..[kPlacementKey] = placement.name
      ..[kStoryModeKey] = true,
    PostPlacement.feedAndStory => out..[kPlacementKey] = placement.name,
  };
}

/// Checks each copy [v] stands for by its own rules: [check] runs once for a
/// feed post or a story, and for Post + Story once on the feed copy
/// ([PostPlacementOfVariant.asFeed]) and once on the story copy
/// ([PostPlacementOfVariant.asStory]), whose findings start with "Story: ".
/// A story finding the feed copy already reported is left out.
List<ValidationIssue> validatePlacements(PostVariant v, List<ValidationIssue> Function(PostVariant copy) check) {
  if (v.placement != PostPlacement.feedAndStory) return check(v);
  final feed = check(v.asFeed());
  final seen = {for (final i in feed) '${i.code}|${i.message}'};
  return [
    ...feed,
    for (final i in check(v.asStory()))
      if (!seen.contains('${i.code}|${i.message}')) ValidationIssue(severity: i.severity, code: i.code, message: 'Story: ${i.message}', field: i.field),
  ];
}

/// The two copies a [PostVariant] can stand for.
extension PostPlacementOfVariant on PostVariant {
  PostPlacement get placement => placementOfExtra(extra);

  /// What the story shows, one frame per file: [PostVariant.storyMedia] when
  /// the story has copies of its own (Post + Story), else [PostVariant.media].
  List<MediaAttachment> get storyFrames => storyMedia.isNotEmpty ? storyMedia : media;

  /// The story copy: the story frames, no caption, placed as a story.
  PostVariant asStory() => copyWith(
        text: '',
        threadParts: const [],
        media: storyFrames,
        storyMedia: const [],
        extra: extraWithPlacement(extra, PostPlacement.story),
      );

  /// The feed copy: everything but the story.
  PostVariant asFeed() => copyWith(storyMedia: const [], extra: extraWithPlacement(extra, PostPlacement.feed));
}
