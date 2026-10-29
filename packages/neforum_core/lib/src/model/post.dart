import 'package:meta/meta.dart';

import 'artwork.dart';
import 'audio.dart';
import 'audio_tags.dart';
import 'media.dart';
import 'poll.dart';
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

  /// The user cancelled publishing before this target was posted. It can be
  /// retried.
  cancelled,
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
    this.scheduledAt,
    this.storyMediaIds,
  });

  /// Keys NEFORUM 1.2 does not know (it ignores them on load). [scheduledAt]
  /// comes back in local time, like [Post.scheduledAt].
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
        scheduledAt: json['scheduledAt'] == null ? null : DateTime.parse(json['scheduledAt'] as String).toLocal(),
        storyMediaIds: (json['storyMediaIds'] as List?)?.cast<String>(),
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

  /// This target's own due time when the post is scheduled with a different
  /// time per network; null = the post's [Post.scheduledAt]. See
  /// [Post.dueAtFor].
  final DateTime? scheduledAt;

  /// The story's own copies of the media (subset and order of the master
  /// media) when the target is placed as Post + Story; null = the story shows
  /// the feed post's media. See `PostVariant.storyMedia`.
  final List<String>? storyMediaIds;

  bool get isEmpty =>
      text == null &&
      title == null &&
      link == null &&
      mediaIds == null &&
      contentWarning == null &&
      sensitive == null &&
      visibility == null &&
      extra.isEmpty &&
      scheduledAt == null &&
      storyMediaIds == null;

  PostOverrides copyWith({
    String? text,
    String? title,
    String? link,
    List<String>? mediaIds,
    String? contentWarning,
    bool? sensitive,
    Visibility? visibility,
    Map<String, dynamic>? extra,
    DateTime? scheduledAt,
    List<String>? storyMediaIds,
    bool clearText = false,
    bool clearMediaIds = false,
    bool clearScheduledAt = false,
    bool clearStoryMediaIds = false,
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
        scheduledAt: clearScheduledAt ? null : (scheduledAt ?? this.scheduledAt),
        storyMediaIds: clearStoryMediaIds ? null : (storyMediaIds ?? this.storyMediaIds),
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
        if (scheduledAt != null) 'scheduledAt': scheduledAt!.toUtc().toIso8601String(),
        if (storyMediaIds != null) 'storyMediaIds': storyMediaIds,
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
    this.handoffNote,
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
            : DateTime.parse(json['lastAttemptAt'] as String).toLocal(),
        handoffNote: json['handoffNote'] as String?,
      );

  final String accountId;
  final PostOverrides overrides;
  final TargetStatus status;
  final PublishResult? result;
  final int attempts;
  final DateTime? lastAttemptAt;

  /// What an automatic hand-off left for the user to check, when it ended
  /// without a confirmed post ("Post was pressed on facebook.com, but the
  /// post was not seen going up."). Post may already have been pressed, so
  /// while it is set the hand-off is finished by the user only, never posted
  /// automatically again. Cleared once the target is handed off.
  final String? handoffNote;

  bool get isDone =>
      status == TargetStatus.published ||
      status == TargetStatus.handedOff ||
      status == TargetStatus.skipped;

  bool get isHeldByPlatform => status == TargetStatus.heldByPlatform;

  /// The target stopped after some of its copies went live: the feed post of
  /// a Post + Story whose story failed, or the first parts of a thread.
  /// Publishing it again would post those copies twice, so it is never
  /// retried; the rest is posted by hand.
  bool get isPartlyLive {
    final r = result;
    if (r == null || r.success) return false;
    final error = r.error;
    return r.allRemoteIds.isNotEmpty || (error != null && error.isPartialThread);
  }

  PostTarget copyWith({
    PostOverrides? overrides,
    TargetStatus? status,
    PublishResult? result,
    int? attempts,
    DateTime? lastAttemptAt,
    String? handoffNote,
    bool clearResult = false,
    bool clearHandoffNote = false,
  }) =>
      PostTarget(
        accountId: accountId,
        overrides: overrides ?? this.overrides,
        status: status ?? this.status,
        result: clearResult ? null : (result ?? this.result),
        attempts: attempts ?? this.attempts,
        lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
        handoffNote: clearHandoffNote ? null : (handoffNote ?? this.handoffNote),
      );

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'overrides': overrides.toJson(),
        'status': status.name,
        if (result != null) 'result': result!.toJson(),
        'attempts': attempts,
        if (lastAttemptAt != null)
          'lastAttemptAt': lastAttemptAt!.toUtc().toIso8601String(),
        if (handoffNote != null) 'handoffNote': handoffNote,
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
    this.poll,
    this.additionalParts = const [],
    this.artwork,
    this.audioQuality = AudioQuality.standard,
    this.audioDetails,
    this.mediaParts = const {},
  });

  /// Times are stored in UTC and come back in local time, so that day and
  /// clock formatting (which does not convert) shows the user's own time.
  factory Post.fromJson(Map<String, dynamic> json) => Post(
        id: json['id'] as String,
        text: json['text'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
        updatedAt: DateTime.parse(json['updatedAt'] as String).toLocal(),
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
            : DateTime.parse(json['scheduledAt'] as String).toLocal(),
        targets: (json['targets'] as List? ?? const [])
            .map((t) => PostTarget.fromJson(Map<String, dynamic>.from(t as Map)))
            .toList(),
        status: PostStatus.values.byName(json['status'] as String? ?? 'draft'),
        tags: (json['tags'] as List? ?? const []).cast<String>(),
        poll: json['poll'] == null ? null : PostPoll.fromJson(Map<String, dynamic>.from(json['poll'] as Map)),
        additionalParts: (json['additionalParts'] as List? ?? const []).cast<String>(),
        artwork: json['artwork'] == null
            ? null
            : ArtworkDetails.fromJson(Map<String, dynamic>.from(json['artwork'] as Map)),
        audioQuality: AudioQuality.values.asNameMap()[json['audioQuality']] ?? AudioQuality.standard,
        audioDetails: json['audioDetails'] == null ? null : AudioTags.fromJson(Map<String, dynamic>.from(json['audioDetails'] as Map)),
        mediaParts: {
          for (final e in (json['mediaParts'] as Map? ?? const {}).entries)
            if (e.value is int) '${e.key}': e.value as int,
        },
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

  /// Poll or quiz; the text is the question. Only platforms with polls get it.
  final PostPoll? poll;

  /// Thread parts the user wrote after the first one ([text]). Platforms
  /// with threads post them as replies; the others get every part joined
  /// with blank lines.
  final List<String> additionalParts;

  /// Set when the post is artwork for art portfolio sites.
  final ArtworkDetails? artwork;

  /// How the post's sound file goes out: one MP3 for everyone, or the
  /// original lossless file where a network takes it.
  final AudioQuality audioQuality;

  /// What the user set for the post's sound file (title, artist, cover...),
  /// over the tags the file carries ([MediaAttachment.audioTags]); null when
  /// the file's own tags stand.
  final AudioTags? audioDetails;

  /// The thread part (index into [parts]) that carries each attachment, by
  /// media id. Media not listed goes with the first part, so a post without
  /// the map (every post before 1.3) keeps all its media on the first part.
  /// A fitted or captioned copy of a photo ([MediaAttachment.derivedFrom])
  /// goes where its original goes. Networks without threads, or without
  /// media in every post of a thread ([MediaRules.mediaPerThreadPart]), get
  /// all the media on their one post or on the first part, as before.
  final Map<String, int> mediaParts;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isDue => scheduledAt != null && status == PostStatus.scheduled;

  /// When [target] is due: its own time ([PostOverrides.scheduledAt]) when
  /// the post has a different time per network, else the post's
  /// [scheduledAt]. Null: no schedule, the target goes out right away.
  DateTime? dueAtFor(PostTarget target) => target.overrides.scheduledAt ?? scheduledAt;

  /// "Different time per network": some target has a time of its own. The
  /// post's [scheduledAt] is then the next of those times
  /// ([withScheduleFromTargets]), so lists, sync claims and OS alarms that
  /// read it see the next moment anything is due.
  bool get schedulesEachTarget => targets.any((t) => t.overrides.scheduledAt != null);

  /// Whether [target]'s time has come at [now]. A target without a time is
  /// due right away. So is a retry ([PostTarget.attempts] above 0): it waits
  /// for its retry backoff (PublishService), not for its own time, which is
  /// still ahead when it was first tried by "Publish now".
  bool isTargetDue(PostTarget target, DateTime now) {
    if (target.attempts > 0) return true;
    final at = dueAtFor(target);
    return at == null || !at.isAfter(now);
  }

  /// The targets still waiting to be published by this device at their time
  /// (retries included; held, handed-off, failed and finished ones are not).
  Iterable<PostTarget> get upcomingTargets => targets.where((t) => t.status == TargetStatus.pending);

  /// The earliest time among [upcomingTargets]; null when none waits or none
  /// has a time. A retry counts from its last attempt ([isTargetDue]).
  DateTime? get nextDueAt {
    DateTime? next;
    for (final t in upcomingTargets) {
      final at = t.attempts > 0 ? (t.lastAttemptAt ?? dueAtFor(t)) : dueAtFor(t);
      if (at != null && (next == null || at.isBefore(next))) next = at;
    }
    return next;
  }

  /// The earliest time a platform publishes a held target
  /// ([PublishResult.scheduledFor]); null when none is held.
  DateTime? get nextHeldAt {
    DateTime? next;
    for (final t in targets) {
      if (!t.isHeldByPlatform) continue;
      final at = t.result?.scheduledFor;
      if (at != null && (next == null || at.isBefore(next))) next = at;
    }
    return next;
  }

  /// This post with [scheduledAt] set to [nextDueAt] when it has a different
  /// time per network; otherwise unchanged. When no target waits for this
  /// device but platforms still hold some, it is [nextHeldAt] instead, the
  /// moment the next held copy is to be recorded as published, so the post is
  /// not due again in the meantime.
  ///
  /// A target without a time of its own is given the post's current time
  /// first, so it keeps going out when it was meant to rather than moving
  /// along with the post's time.
  Post withScheduleFromTargets() {
    if (!schedulesEachTarget) return this;
    final next = nextDueAt ?? nextHeldAt;
    if (next == null || next == scheduledAt) return this;
    final base = scheduledAt;
    return copyWith(
      scheduledAt: next,
      targets: base == null || targets.every((t) => t.overrides.scheduledAt != null)
          ? null
          : [
              for (final t in targets)
                if (t.overrides.scheduledAt == null) t.copyWith(overrides: t.overrides.copyWith(scheduledAt: base)) else t,
            ],
    );
  }

  /// This post without a schedule: no [scheduledAt], and no target keeps a
  /// time of its own. For "Publish now".
  Post withoutSchedule() => copyWith(
        clearScheduledAt: true,
        targets: [
          for (final t in targets)
            if (t.overrides.scheduledAt != null) t.copyWith(overrides: t.overrides.copyWith(clearScheduledAt: true)) else t,
        ],
      );

  /// Some target still needs this device at the scheduled time. False when
  /// every remaining target is held by its platform's own scheduler.
  bool get needsDeviceAtSchedule => targets.any((t) => !t.isDone && !t.isHeldByPlatform && t.status != TargetStatus.failed);

  bool get hasHeldTargets => targets.any((t) => t.isHeldByPlatform);

  /// Every part of the post in order: [text], then [additionalParts].
  List<String> get parts => [text, ...additionalParts];

  /// True when the user wrote more than one part.
  bool get isThread => additionalParts.isNotEmpty;

  bool get isArtwork => artwork != null;

  /// The part [media] goes with ([mediaParts]); 0 when it is not listed.
  int partOf(MediaAttachment media) => mediaParts[media.id] ?? mediaParts[media.derivedFrom] ?? 0;

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
    PostPoll? poll,
    List<String>? additionalParts,
    ArtworkDetails? artwork,
    AudioQuality? audioQuality,
    AudioTags? audioDetails,
    bool clearAudioDetails = false,
    Map<String, int>? mediaParts,
    bool clearScheduledAt = false,
    bool clearTitle = false,
    bool clearLink = false,
    bool clearPoll = false,
    bool clearArtwork = false,
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
        poll: clearPoll ? null : (poll ?? this.poll),
        additionalParts: additionalParts ?? this.additionalParts,
        artwork: clearArtwork ? null : (artwork ?? this.artwork),
        audioQuality: audioQuality ?? this.audioQuality,
        audioDetails: clearAudioDetails ? null : (audioDetails ?? this.audioDetails),
        mediaParts: mediaParts ?? this.mediaParts,
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
        if (poll != null) 'poll': poll!.toJson(),
        if (additionalParts.isNotEmpty) 'additionalParts': additionalParts,
        if (artwork != null) 'artwork': artwork!.toJson(),
        if (audioQuality != AudioQuality.standard) 'audioQuality': audioQuality.name,
        if (audioDetails != null && !audioDetails!.isEmpty) 'audioDetails': audioDetails!.toJson(),
        if (mediaParts.isNotEmpty) 'mediaParts': mediaParts,
      };
}
