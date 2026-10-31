import 'package:meta/meta.dart';

/// Why a publish attempt failed. Drives retry and fallback decisions.
enum PublishErrorKind {
  /// Token expired/revoked, wrong credentials. Needs the user to reconnect.
  auth,

  /// Platform or local quota exhausted. Candidate for hand-off fallback.
  quota,

  /// The post breaks a platform rule (too long, wrong media). Not retryable
  /// without changes.
  validation,

  /// Transient network / 5xx. Retryable.
  network,

  /// Platform returned an error we could not classify.
  platform,

  /// The adapter cannot do this (e.g. video on a text-only tier).
  unsupported,

  /// Prerequisite missing, e.g. no media host configured for Instagram.
  configuration,
  cancelled,
}

@immutable
class PublishError {
  const PublishError({
    required this.kind,
    required this.message,
    this.retryable = false,
    this.statusCode,
    this.raw,
    this.retryAfter,
  });

  factory PublishError.fromJson(Map<String, dynamic> json) => PublishError(
        kind: PublishErrorKind.values.byName(json['kind'] as String),
        message: json['message'] as String,
        retryable: json['retryable'] as bool? ?? false,
        statusCode: json['statusCode'] as int?,
        raw: json['raw'] as String?,
        retryAfter: json['retryAfterSeconds'] == null
            ? null
            : Duration(seconds: json['retryAfterSeconds'] as int),
      );

  const PublishError.auth(String message, {String? raw, int? statusCode})
      : this(kind: PublishErrorKind.auth, message: message, raw: raw, statusCode: statusCode);

  const PublishError.quota(String message, {String? raw, int? statusCode, Duration? retryAfter})
      : this(
          kind: PublishErrorKind.quota,
          message: message,
          raw: raw,
          statusCode: statusCode,
          retryAfter: retryAfter,
          retryable: true,
        );

  const PublishError.validation(String message, {String? raw, int? statusCode})
      : this(kind: PublishErrorKind.validation, message: message, raw: raw, statusCode: statusCode);

  const PublishError.network(String message, {String? raw, int? statusCode, Duration? retryAfter})
      : this(
          kind: PublishErrorKind.network,
          message: message,
          raw: raw,
          statusCode: statusCode,
          retryAfter: retryAfter,
          retryable: true,
        );

  const PublishError.platform(String message, {String? raw, int? statusCode, bool retryable = false})
      : this(
          kind: PublishErrorKind.platform,
          message: message,
          raw: raw,
          statusCode: statusCode,
          retryable: retryable,
        );

  const PublishError.unsupported(String message)
      : this(kind: PublishErrorKind.unsupported, message: message);

  const PublishError.configuration(String message)
      : this(kind: PublishErrorKind.configuration, message: message);

  final PublishErrorKind kind;
  final String message;
  final bool retryable;
  final int? statusCode;

  /// Raw response body or exception text, truncated by the caller for display.
  final String? raw;
  final Duration? retryAfter;

  /// Wraps an error that happened after some parts of a thread were already
  /// posted. Never retryable: a retry would post the earlier parts again.
  PublishError asPartialThread({required List<String> postedIds, required int total}) {
    if (postedIds.isEmpty) return this;
    return PublishError(
      kind: kind,
      message: 'Part ${postedIds.length + 1} of $total failed: $message. '
          'Parts already posted (${postedIds.join(', ')}) stay live; finish the thread by hand.',
      retryable: false,
      statusCode: statusCode,
      raw: raw,
    );
  }

  /// Like [asPartialThread], for a thread the next attempt can finish: it
  /// posts only the parts after [postedIds] ([PostVariant.postedThreadIds]).
  PublishError asResumableThread({required List<String> postedIds, required int total}) {
    if (postedIds.isEmpty) return this;
    return PublishError(
      kind: kind,
      message: 'Part ${postedIds.length + 1} of $total failed: $message. '
          'The first ${postedIds.length} part(s) are live; Retry posts the rest of the thread.',
      retryable: false,
      statusCode: statusCode,
      raw: raw,
    );
  }

  /// The wording of [asPartialThread] and [asResumableThread].
  static final _partialThread = RegExp(r'^Part \d+ of \d+ failed: ');

  /// Made by [asPartialThread]: the first parts of the thread are live.
  bool get isPartialThread => !retryable && _partialThread.hasMatch(message);

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'message': message,
        'retryable': retryable,
        if (statusCode != null) 'statusCode': statusCode,
        if (raw != null) 'raw': raw,
        if (retryAfter != null) 'retryAfterSeconds': retryAfter!.inSeconds,
      };

  @override
  String toString() => 'PublishError(${kind.name}: $message)';
}

/// Outcome of publishing one [PostVariant] to one account.
@immutable
class PublishResult {
  const PublishResult._({
    required this.success,
    this.remoteId,
    this.remoteUrl,
    this.error,
    this.threadRemoteIds = const [],
    this.handedOff = false,
    this.publishedAt,
    this.scheduledFor,
    this.additionalRemoteIds = const [],
    this.seriesRemoteIds = const [],
    this.resumable = false,
  });

  factory PublishResult.ok({
    String? remoteId,
    String? remoteUrl,
    List<String> threadRemoteIds = const [],
    DateTime? publishedAt,
    List<String> additionalRemoteIds = const [],
    List<String> seriesRemoteIds = const [],
  }) =>
      PublishResult._(
        success: true,
        remoteId: remoteId,
        remoteUrl: remoteUrl,
        threadRemoteIds: threadRemoteIds,
        publishedAt: publishedAt,
        additionalRemoteIds: additionalRemoteIds,
        seriesRemoteIds: seriesRemoteIds,
      );

  /// The platform accepted the post and holds it until [scheduledFor]
  /// (server-side scheduling). [remoteId] must be whatever
  /// [PlatformAdapter.cancelScheduled] needs to remove it again.
  factory PublishResult.scheduled({
    required String remoteId,
    required DateTime scheduledFor,
    String? remoteUrl,
  }) =>
      PublishResult._(
        success: true,
        remoteId: remoteId,
        remoteUrl: remoteUrl,
        scheduledFor: scheduledFor,
      );

  factory PublishResult.failure(PublishError error) =>
      PublishResult._(success: false, error: error);

  /// A target that failed after some of its copies went live (the feed post
  /// before its story, the first frames of a story, the first parts of a
  /// thread, the first posts of a series). [remoteId], [threadRemoteIds],
  /// [additionalRemoteIds] and [seriesRemoteIds] record those copies so they
  /// are never forgotten; [error] should not be retryable, since a plain
  /// retry would post them again. [resumable]: the next attempt posts only
  /// what is still missing ([PostTarget.canResume]).
  factory PublishResult.partialFailure(
    PublishError error, {
    String? remoteId,
    String? remoteUrl,
    List<String> threadRemoteIds = const [],
    List<String> additionalRemoteIds = const [],
    List<String> seriesRemoteIds = const [],
    DateTime? publishedAt,
    bool resumable = false,
  }) =>
      PublishResult._(
        success: false,
        error: error,
        remoteId: remoteId,
        remoteUrl: remoteUrl,
        threadRemoteIds: threadRemoteIds,
        additionalRemoteIds: additionalRemoteIds,
        seriesRemoteIds: seriesRemoteIds,
        publishedAt: publishedAt,
        resumable: resumable,
      );

  /// The target was handed to the user (share sheet / web intent opened).
  factory PublishResult.handedOff({String? remoteUrl}) =>
      PublishResult._(success: true, handedOff: true, remoteUrl: remoteUrl);

  factory PublishResult.fromJson(Map<String, dynamic> json) => PublishResult._(
        success: json['success'] as bool,
        remoteId: json['remoteId'] as String?,
        remoteUrl: json['remoteUrl'] as String?,
        error: json['error'] == null
            ? null
            : PublishError.fromJson(Map<String, dynamic>.from(json['error'] as Map)),
        threadRemoteIds: (json['threadRemoteIds'] as List? ?? const []).cast<String>(),
        handedOff: json['handedOff'] as bool? ?? false,
        publishedAt: json['publishedAt'] == null
            ? null
            : DateTime.parse(json['publishedAt'] as String),
        scheduledFor: json['scheduledFor'] == null
            ? null
            : DateTime.parse(json['scheduledFor'] as String),
        additionalRemoteIds: (json['additionalRemoteIds'] as List? ?? const []).cast<String>(),
        seriesRemoteIds: (json['seriesRemoteIds'] as List? ?? const []).cast<String>(),
        resumable: json['resumable'] as bool? ?? false,
      );

  final bool success;
  final String? remoteId;
  final String? remoteUrl;
  final PublishError? error;

  /// Remote ids of every part when a long post was published as a thread.
  final List<String> threadRemoteIds;
  final bool handedOff;
  final DateTime? publishedAt;

  /// Set when the platform holds the post and publishes it itself at this
  /// time (see [PublishResult.scheduled]).
  final DateTime? scheduledFor;

  /// Remote ids of the further copies published for the same target besides
  /// [remoteId]: the frames of a story next to a feed post (Post + Story), or
  /// the frames after the first of a story of several photos. Kept so status,
  /// removal and quota cover every copy.
  final List<String> additionalRemoteIds;

  /// The remote id of each further post of a series
  /// ([PostVariant.seriesPosts]) that is live, in order; [remoteId] is the
  /// first post's.
  final List<String> seriesRemoteIds;

  /// A failed target whose live copies are recorded well enough that the
  /// next attempt posts only what is missing (the rest of a thread, the
  /// remaining posts of a series) instead of everything again.
  final bool resumable;

  /// Every remote id this result stands for: [remoteId], the parts of a
  /// thread, [additionalRemoteIds] and the posts of a series, without
  /// repeats.
  List<String> get allRemoteIds => {
        ?remoteId,
        ...threadRemoteIds,
        ...additionalRemoteIds,
        ...seriesRemoteIds,
      }.toList();

  bool get isFailure => !success;

  /// The post is waiting on the platform's own scheduler.
  bool get isHeldByPlatform => success && scheduledFor != null;

  /// The same result once the platform's scheduled time has passed.
  PublishResult asReleased() => PublishResult._(
        success: true,
        remoteId: remoteId,
        remoteUrl: remoteUrl,
        threadRemoteIds: threadRemoteIds,
        publishedAt: scheduledFor ?? publishedAt,
        additionalRemoteIds: additionalRemoteIds,
        seriesRemoteIds: seriesRemoteIds,
      );

  Map<String, dynamic> toJson() => {
        'success': success,
        if (remoteId != null) 'remoteId': remoteId,
        if (remoteUrl != null) 'remoteUrl': remoteUrl,
        if (error != null) 'error': error!.toJson(),
        if (threadRemoteIds.isNotEmpty) 'threadRemoteIds': threadRemoteIds,
        'handedOff': handedOff,
        if (publishedAt != null) 'publishedAt': publishedAt!.toUtc().toIso8601String(),
        if (scheduledFor != null) 'scheduledFor': scheduledFor!.toUtc().toIso8601String(),
        if (additionalRemoteIds.isNotEmpty) 'additionalRemoteIds': additionalRemoteIds,
        if (seriesRemoteIds.isNotEmpty) 'seriesRemoteIds': seriesRemoteIds,
        if (resumable) 'resumable': true,
      };

  @override
  String toString() => success
      ? 'PublishResult.${scheduledFor != null ? 'scheduled' : 'ok'}(${handedOff ? 'handed off' : remoteId ?? remoteUrl ?? ''})'
      : 'PublishResult.failure($error)';
}
