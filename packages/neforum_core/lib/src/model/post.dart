import 'package:meta/meta.dart';

import 'media.dart';
import 'publish_result.dart';

/// Lifecycle of a master post.
enum PostStatus {
  draft,
  scheduled,
  publishing,
  published,

  /// At least one target failed or is still waiting for a hand-off.
  partial,
  failed,
  cancelled,
}

/// Lifecycle of one target (one account) inside a post.
enum TargetStatus {
  pending,
  publishing,
  published,
  failed,

  /// Hand-off prepared; waiting for the user to tap "Post" in the other app.
  awaitingHandoff,

  /// Hand-off was launched (share sheet opened); NEFORUM cannot know whether
  /// the user completed it, so the user confirms manually.
  handedOff,
  skipped,

  /// The platform accepted the post and publishes it itself at the
  /// scheduled time (server-side scheduling). The device can be off.
  heldByPlatform,
}

/// Visibility mapped onto whatever the platform supports.
enum Visibility { public, unlisted, followers, private }

/// Alias for Flutter code, where `Visibility` collides with the widget of
/// the same name: `import 'package:neforum_core/neforum_core.dart' hide Visibility;`
typedef PostVisibility = Visibility;

/// Per-target overrides of the master post. Every field is optional; `null`
/// means "use the master value".
@immutable
class PostOverrides {
  const PostOverrides({
    this.text,
    this.title,
    this.link,
    this.mediaIds,
    this.contentWarning,
    this.sensitive,
    this.visibility,
    this.extra = const {},
  });

  factory PostOverrides.fromJson(Map<String, dynamic> json) => PostOverrides(
        text: json['text'] as String?,
        title: json['title'] as String?,
        link: json['link'] as String?,
        mediaIds: (json['mediaIds'] as List?)?.cast<String>(),
        contentWarning: json['contentWarning'] as String?,
        sensitive: json['sensitive'] as bool?,
        visibility: json['visibility'] == null
            ? null
            : Visibility.values.byName(json['visibility'] as String),
        extra: Map<String, dynamic>.from(json['extra'] as Map? ?? const {}),
      );

  final String? text;
  final String? title;
  final String? link;

  /// Subset (and order) of the master media to use. `null` = all.
  final List<String>? mediaIds;
  final String? contentWarning;
  final bool? sensitive;
  final Visibility? visibility;

  /// Adapter-specific knobs: subreddit, flair, board id, community, tags, ...
  final Map<String, dynamic> extra;

  bool get isEmpty =>
      text == null &&
      title == null &&
      link == null &&
      mediaIds == null &&
      contentWarning == null &&
      sensitive == null &&
      visibility == null &&
      extra.isEmpty;

  PostOverrides copyWith({
    String? text,
    String? title,
    String? link,
    List<String>? mediaIds,
    String? contentWarning,
    bool? sensitive,
    Visibility? visibility,
    Map<String, dynamic>? extra,
    bool clearText = false,
    bool clearMediaIds = false,
  }) =>
      PostOverrides(
        text: clearText ? null : (text ?? this.text),
        title: title ?? this.title,
        link: link ?? this.link,
        mediaIds: clearMediaIds ? null : (mediaIds ?? this.mediaIds),
        contentWarning: contentWarning ?? this.contentWarning,
        sensitive: sensitive ?? this.sensitive,
        visibility: visibility ?? this.visibility,
        extra: extra ?? this.extra,
      );

  Map<String, dynamic> toJson() => {
        if (text != null) 'text': text,
        if (title != null) 'title': title,
        if (link != null) 'link': link,
        if (mediaIds != null) 'mediaIds': mediaIds,
        if (contentWarning != null) 'contentWarning': contentWarning,
        if (sensitive != null) 'sensitive': sensitive,
        if (visibility != null) 'visibility': visibility!.name,
        if (extra.isNotEmpty) 'extra': extra,
      };
}

/// One account the post goes to, plus its overrides and outcome.
@immutable
class PostTarget {
  const PostTarget({
    required this.accountId,
    this.overrides = const PostOverrides(),
    this.status = TargetStatus.pending,
    this.result,
    this.attempts = 0,
    this.lastAttemptAt,
  });

  factory PostTarget.fromJson(Map<String, dynamic> json) => PostTarget(
        accountId: json['accountId'] as String,
        overrides: PostOverrides.fromJson(
            Map<String, dynamic>.from(json['overrides'] as Map? ?? const {})),
        status: TargetStatus.values.byName(json['status'] as String? ?? 'pending'),
        result: json['result'] == null
            ? null
            : PublishResult.fromJson(Map<String, dynamic>.from(json['result'] as Map)),
        attempts: json['attempts'] as int? ?? 0,
        lastAttemptAt: json['lastAttemptAt'] == null
            ? null
            : DateTime.parse(json['lastAttemptAt'] as String),
      );

  final String accountId;
  final PostOverrides overrides;
  final TargetStatus status;
  final PublishResult? result;
  final int attempts;
  final DateTime? lastAttemptAt;

  bool get isDone =>
      status == TargetStatus.published ||
      status == TargetStatus.handedOff ||
      status == TargetStatus.skipped;

  bool get isHeldByPlatform => status == TargetStatus.heldByPlatform;

  PostTarget copyWith({
    PostOverrides? overrides,
    TargetStatus? status,
    PublishResult? result,
    int? attempts,
    DateTime? lastAttemptAt,
    bool clearResult = false,
  }) =>
      PostTarget(
        accountId: accountId,
        overrides: overrides ?? this.overrides,
        status: status ?? this.status,
        result: clearResult ? null : (result ?? this.result),
        attempts: attempts ?? this.attempts,
        lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      );

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'overrides': overrides.toJson(),
        'status': status.name,
        if (result != null) 'result': result!.toJson(),
        'attempts': attempts,
        if (lastAttemptAt != null)
          'lastAttemptAt': lastAttemptAt!.toUtc().toIso8601String(),
      };
}

/// The master post: written once, adapted per target.
@immutable
class Post {
  const Post({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    this.title,
    this.link,
    this.media = const [],
    this.contentWarning,
    this.sensitive = false,
    this.visibility = Visibility.public,
    this.language,
    this.scheduledAt,
    this.targets = const [],
    this.status = PostStatus.draft,
    this.tags = const [],
  });

  factory Post.fromJson(Map<String, dynamic> json) => Post(
        id: json['id'] as String,
        text: json['text'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        title: json['title'] as String?,
        link: json['link'] as String?,
        media: (json['media'] as List? ?? const [])
            .map((m) => MediaAttachment.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
        contentWarning: json['contentWarning'] as String?,
        sensitive: json['sensitive'] as bool? ?? false,
        visibility: Visibility.values.byName(json['visibility'] as String? ?? 'public'),
        language: json['language'] as String?,
        scheduledAt: json['scheduledAt'] == null
            ? null
            : DateTime.parse(json['scheduledAt'] as String),
        targets: (json['targets'] as List? ?? const [])
            .map((t) => PostTarget.fromJson(Map<String, dynamic>.from(t as Map)))
            .toList(),
        status: PostStatus.values.byName(json['status'] as String? ?? 'draft'),
        tags: (json['tags'] as List? ?? const []).cast<String>(),
      );

  final String id;
  final String text;

  /// Used by platforms with a title field (Reddit, Lemmy, YouTube, blogs).
  final String? title;

  /// Dedicated link (Reddit link post, Pinterest destination, blog canonical).
  /// Platforms without a link field get it appended to the text.
  final String? link;
  final List<MediaAttachment> media;
  final String? contentWarning;
  final bool sensitive;
  final Visibility visibility;

  /// BCP-47 language tag, e.g. `en`.
  final String? language;
  final DateTime? scheduledAt;
  final List<PostTarget> targets;
  final PostStatus status;

  /// Free-form hashtags without `#`, kept separately so each platform can
  /// decide where (and whether) to place them.
  final List<String> tags;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isDue => scheduledAt != null && status == PostStatus.scheduled;

  /// Some target still needs this device at the scheduled time. False when
  /// every remaining target is held by its platform's own scheduler.
  bool get needsDeviceAtSchedule => targets.any((t) => !t.isDone && !t.isHeldByPlatform && t.status != TargetStatus.failed);

  bool get hasHeldTargets => targets.any((t) => t.isHeldByPlatform);

  PostTarget? targetFor(String accountId) {
    for (final t in targets) {
      if (t.accountId == accountId) return t;
    }
    return null;
  }

  Post copyWith({
    String? text,
    String? title,
    String? link,
    List<MediaAttachment>? media,
    String? contentWarning,
    bool? sensitive,
    Visibility? visibility,
    String? language,
    DateTime? scheduledAt,
    List<PostTarget>? targets,
    PostStatus? status,
    List<String>? tags,
    DateTime? updatedAt,
    bool clearScheduledAt = false,
    bool clearTitle = false,
    bool clearLink = false,
  }) =>
      Post(
        id: id,
        text: text ?? this.text,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        title: clearTitle ? null : (title ?? this.title),
        link: clearLink ? null : (link ?? this.link),
        media: media ?? this.media,
        contentWarning: contentWarning ?? this.contentWarning,
        sensitive: sensitive ?? this.sensitive,
        visibility: visibility ?? this.visibility,
        language: language ?? this.language,
        scheduledAt: clearScheduledAt ? null : (scheduledAt ?? this.scheduledAt),
        targets: targets ?? this.targets,
        status: status ?? this.status,
        tags: tags ?? this.tags,
      );

  /// Replaces the target with the same account id.
  Post withTarget(PostTarget target) => copyWith(
        targets: [
          for (final t in targets)
            if (t.accountId == target.accountId) target else t,
        ],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (title != null) 'title': title,
        if (link != null) 'link': link,
        'media': media.map((m) => m.toJson()).toList(),
        if (contentWarning != null) 'contentWarning': contentWarning,
        'sensitive': sensitive,
        'visibility': visibility.name,
        if (language != null) 'language': language,
        if (scheduledAt != null) 'scheduledAt': scheduledAt!.toUtc().toIso8601String(),
        'targets': targets.map((t) => t.toJson()).toList(),
        'status': status.name,
        'tags': tags,
      };
}
