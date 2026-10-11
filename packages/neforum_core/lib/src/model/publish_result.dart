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
  });

  factory PublishResult.ok({
    String? remoteId,
    String? remoteUrl,
    List<String> threadRemoteIds = const [],
    DateTime? publishedAt,
  }) =>
      PublishResult._(
        success: true,
        remoteId: remoteId,
        remoteUrl: remoteUrl,
        threadRemoteIds: threadRemoteIds,
        publishedAt: publishedAt,
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
      };

  @override
  String toString() => success
      ? 'PublishResult.${scheduledFor != null ? 'scheduled' : 'ok'}(${handedOff ? 'handed off' : remoteId ?? remoteUrl ?? ''})'
      : 'PublishResult.failure($error)';
}
