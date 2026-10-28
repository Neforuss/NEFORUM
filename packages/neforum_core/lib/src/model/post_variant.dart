import 'package:meta/meta.dart';

import 'artwork.dart';
import 'media.dart';
import 'poll.dart';
import 'post.dart';
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
    this.mediaPartIndexes = const [],
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

  /// For each item of [media], the index of the [threadParts] post that
  /// carries it. Empty (the usual case) means every item goes with the first
  /// post. Only set for networks with [MediaRules.mediaPerThreadPart] when the
  /// post places media in later parts ([Post.mediaParts]).
  final List<int> mediaPartIndexes;

  bool get isArtwork => artwork != null;

  /// True when media goes with more than the first post of the thread.
  bool get hasMediaInLaterParts => mediaPartIndexes.any((i) => i > 0);

  /// The media of thread post [part] (0 is the first post, or the only one).
  List<MediaAttachment> mediaOfPart(int part) {
    if (!hasMediaInLaterParts) return part == 0 ? media : const [];
    return [
      for (var i = 0; i < media.length; i++)
        if ((i < mediaPartIndexes.length ? mediaPartIndexes[i] : 0) == part) media[i],
    ];
  }

  /// The media of each post that carries some, in thread order: one group
  /// ([media]) unless media goes with later parts. Per-post limits apply to
  /// each group.
  List<List<MediaAttachment>> get mediaGroups {
    if (!hasMediaInLaterParts) return [media];
    final count = threadParts.isEmpty ? 1 : threadParts.length;
    return [
      for (var p = 0; p < count; p++)
        if (mediaOfPart(p) case final group when group.isNotEmpty) group,
    ];
  }

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
    List<int>? mediaPartIndexes,
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
        // Replacing media item for item (a fitted stand-in for a photo) keeps
        // each item in its part; a different list goes with the first post.
        mediaPartIndexes: mediaPartIndexes ??
            (media == null || media.length == this.media.length ? this.mediaPartIndexes : const []),
      );

  PostVariant addIssues(Iterable<ValidationIssue> more) =>
      copyWith(issues: [...issues, ...more]);
}
