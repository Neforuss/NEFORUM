import 'package:meta/meta.dart';

import 'artwork.dart';
import 'media.dart';
import 'poll.dart';
import 'post.dart';
import 'post_placement.dart';
import 'validation.dart';

/// The master [Post] resolved for ONE account: overrides applied, text adapted
/// to the platform's rules, media filtered to what the platform accepts.
///
/// This is what adapters receive. They should not need to look at the master
/// post at all.
@immutable
class PostVariant {
  const PostVariant({
    required this.text,
    this.threadParts = const [],
    this.title,
    this.link,
    this.media = const [],
    this.contentWarning,
    this.sensitive = false,
    this.visibility = Visibility.public,
    this.language,
    this.tags = const [],
    this.extra = const {},
    this.scheduledAt,
    this.issues = const [],
    this.sourcePostId,
    this.poll,
    this.artwork,
    this.storyMedia = const [],
  });

  /// Body text. When the post was split into a thread this is the first part.
  final String text;

  /// All parts when the post was split into a thread (`threadParts.first ==
  /// text`). Empty when not threaded.
  final List<String> threadParts;
  final String? title;
  final String? link;
  final List<MediaAttachment> media;
  final String? contentWarning;
  final bool sensitive;
  final Visibility visibility;
  final String? language;

  /// Hashtags without `#`, for platforms that take them as a separate field
  /// (Tumblr tags, YouTube tags, blog tags). Platforms without such a field
  /// already have them merged into [text] by the resolver.
  final List<String> tags;

  /// Adapter-specific knobs taken from [PostOverrides.extra] merged with
  /// the account's defaults.
  final Map<String, dynamic> extra;

  /// Set when the platform supports server-side scheduling and the user
  /// chose to delegate the schedule.
  final DateTime? scheduledAt;

  /// What the resolver changed or found. Errors mean "do not publish".
  final List<ValidationIssue> issues;
  final String? sourcePostId;

  /// The post's poll or quiz, only on platforms that have polls.
  final PostPoll? poll;

  /// The post's artwork details ([Post.artwork]); null when the post is not
  /// artwork.
  final ArtworkDetails? artwork;

  /// The story's own copies of the media when the target is placed as Post +
  /// Story (photos fitted to 9:16, a 9:16 text card); empty: the story shows
  /// [media]. See [PostPlacementOfVariant.storyFrames].
  final List<MediaAttachment> storyMedia;

  bool get isArtwork => artwork != null;

  bool get isThread => threadParts.length > 1;
  bool get hasMedia => media.isNotEmpty;
  bool get hasErrors => issues.hasErrors;

  T? extraAs<T>(String key) {
    final v = extra[key];
    return v is T ? v : null;
  }

  PostVariant copyWith({
    String? text,
    List<String>? threadParts,
    String? title,
    String? link,
    List<MediaAttachment>? media,
    String? contentWarning,
    bool? sensitive,
    Visibility? visibility,
    String? language,
    List<String>? tags,
    Map<String, dynamic>? extra,
    DateTime? scheduledAt,
    List<ValidationIssue>? issues,
    PostPoll? poll,
    bool clearPoll = false,
    List<MediaAttachment>? storyMedia,
  }) =>
      PostVariant(
        text: text ?? this.text,
        threadParts: threadParts ?? this.threadParts,
        title: title ?? this.title,
        link: link ?? this.link,
        media: media ?? this.media,
        contentWarning: contentWarning ?? this.contentWarning,
        sensitive: sensitive ?? this.sensitive,
        visibility: visibility ?? this.visibility,
        language: language ?? this.language,
        tags: tags ?? this.tags,
        extra: extra ?? this.extra,
        scheduledAt: scheduledAt ?? this.scheduledAt,
        issues: issues ?? this.issues,
        sourcePostId: sourcePostId,
        poll: clearPoll ? null : (poll ?? this.poll),
        artwork: artwork,
        storyMedia: storyMedia ?? this.storyMedia,
      );

  PostVariant addIssues(Iterable<ValidationIssue> more) =>
      copyWith(issues: [...issues, ...more]);
}
