import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../http/neforum_http.dart';
import '../../http/transient_stub.dart' if (dart.library.io) '../../http/transient_io.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../platform_adapter.dart';

/// Endpoints of Google OAuth 2.0 and the YouTube Data API v3.
abstract final class YouTubeEndpoints {
  static final Uri authorize = Uri.parse('https://accounts.google.com/o/oauth2/v2/auth');
  static final Uri token = Uri.parse('https://oauth2.googleapis.com/token');
  static final Uri revoke = Uri.parse('https://oauth2.googleapis.com/revoke');
  static final Uri channelsMine = Uri.parse('https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true');

  /// Starts a resumable `videos.insert` session. Built from a string so the
  /// comma in `part=snippet,status` stays literal.
  static Uri uploadSession({bool notifySubscribers = true}) => Uri.parse(
      'https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status'
      '${notifySubscribers ? '' : '&notifySubscribers=false'}');

  /// `videos.delete` (HTTP 204 on success, 50 quota units).
  static Uri video(String id) => Uri.https('www.googleapis.com', '/youtube/v3/videos', {'id': id});
}

/// Scopes NEFORUM asks for: upload; read-only to show which channel is
/// connected (`channels.list mine=true`); and `youtube.force-ssl`, the
/// narrowest scope `videos.delete` accepts, so a video YouTube holds for a
/// scheduled post can be taken back when the post is edited or cancelled.
const youtubeScopes = [
  'https://www.googleapis.com/auth/youtube.upload',
  'https://www.googleapis.com/auth/youtube.readonly',
  'https://www.googleapis.com/auth/youtube.force-ssl',
];

/// Scopes that authorize `videos.delete`
/// (developers.google.com/youtube/v3/docs/videos/delete).
const youtubeDeleteScopes = {
  'https://www.googleapis.com/auth/youtube.force-ssl',
  'https://www.googleapis.com/auth/youtube',
  'https://www.googleapis.com/auth/youtubepartner',
};

/// Whether a space-separated OAuth `scope` string allows deleting videos.
bool scopesAllowDelete(String scope) => scope.split(' ').any(youtubeDeleteScopes.contains);

/// Secret-map keys on top of the `OAuthTokens` keys.
abstract final class YouTubeSecretKeys {
  static const clientSecret = 'client_secret';

  /// Set when the user granted time-limited access (`refresh_token_expires_in`).
  static const refreshExpiresAt = 'refresh_expires_at';
}

/// Non-secret config keys stored on the account.
abstract final class YouTubeConfigKeys {
  static const clientId = 'clientId';
  static const channelId = 'channelId';
  static const redirectUri = 'redirectUri';

  /// `true` when the sign-in includes a scope that allows `videos.delete`.
  /// Without it YouTube must not hold scheduled videos: NEFORUM could not
  /// take them back. Accounts connected before this key existed lack it.
  static const canDeleteVideos = 'canDeleteVideos';

  /// Set (by the app) to `true` once YouTube locked an upload of this
  /// project as private. A locked video never goes public at `publishAt`,
  /// so the schedule then stays on this device.
  static const uploadsLockedPrivate = 'uploadsLockedPrivate';
}

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

/// Reasons from Google's `error.errors[].reason` (or `error.status`) that
/// mean "the daily project quota is gone".
const _dailyQuotaReasons = {'quotaExceeded', 'dailyLimitExceeded'};
const _rateReasons = {'rateLimitExceeded', 'userRateLimitExceeded', 'RESOURCE_EXHAUSTED'};
const _validationReasons = {
  'invalidTitle',
  'invalidDescription',
  'invalidTags',
  'invalidPublishAt',
  'invalidCategoryId',
  'invalidFilename',
  'invalidVideoMetadata',
  'invalidRecordingDetails',
  'invalidVideoGameRating',
  'mediaBodyRequired',
  'forbiddenPrivacySetting',
  'forbiddenLicenseSetting',
  'defaultLanguageNotSet',
  'invalidDefaultBroadcastPrivacySetting',
  'badRequest',
};

/// Extracts `(reason, message)` from a Google API error body.
(String reason, String message) googleErrorReason(NeforumResponse res) {
  final json = res.jsonMap;
  final err = json['error'];
  if (err is Map) {
    final errors = err['errors'];
    var reason = '';
    if (errors is List && errors.isNotEmpty && errors.first is Map) {
      reason = ((errors.first as Map)['reason'] as String?) ?? '';
    }
    if (reason.isEmpty) reason = (err['status'] as String?) ?? '';
    return (reason, (err['message'] as String?) ?? '');
  }
  // OAuth-style bodies: {"error": "invalid_grant", "error_description": "..."}
  if (err is String) return (err, (json['error_description'] as String?) ?? '');
  return ('', '');
}

/// Maps a non-2xx YouTube Data API response onto a [PublishError].
PublishError mapYouTubeError(NeforumResponse res, {required String context, required DateTime now}) {
  final (reason, message) = googleErrorReason(res);
  final status = res.statusCode;
  final raw = snippet(res.body);
  final detail = [reason, message].where((s) => s.isNotEmpty).join(': ');
  final msg = '$context failed${detail.isEmpty ? ' (HTTP $status)' : ' ($detail)'}';

  if (_dailyQuotaReasons.contains(reason)) {
    return PublishError.quota(
        'Your Google Cloud project used up today\'s YouTube API quota; it resets at midnight Pacific time',
        raw: raw,
        statusCode: status,
        retryAfter: untilPacificMidnight(now));
  }
  if (_rateReasons.contains(reason) || status == 429) {
    return PublishError.quota('YouTube is rate limiting this project ($context)',
        raw: raw, statusCode: status, retryAfter: res.retryAfter ?? const Duration(minutes: 1));
  }
  if (reason == 'uploadLimitExceeded') {
    return PublishError.quota('This YouTube channel has reached its upload limit for now; try again later',
        raw: raw, statusCode: status, retryAfter: res.retryAfter);
  }
  if (reason == 'youtubeSignupRequired' || reason == 'channelNotFound') {
    return PublishError(
        kind: PublishErrorKind.configuration,
        message: 'This Google account has no YouTube channel yet. Create one at https://www.youtube.com/create_channel '
            'and try again.',
        raw: raw,
        statusCode: status);
  }
  if (reason == 'accessNotConfigured' || reason == 'SERVICE_DISABLED') {
    return PublishError(
        kind: PublishErrorKind.configuration,
        message: 'The YouTube Data API v3 is not enabled in your Google Cloud project. Enable it under '
            'APIs & Services > Library and try again.',
        raw: raw,
        statusCode: status);
  }
  if (reason == 'insufficientPermissions' || reason == 'ACCESS_TOKEN_SCOPE_INSUFFICIENT') {
    return PublishError.auth(
        '$context: Google did not grant NEFORUM the YouTube permission this needs; reconnect and tick every '
        'YouTube box',
        raw: raw,
        statusCode: status);
  }
  if (status == 401 || reason == 'authError' || reason == 'UNAUTHENTICATED') {
    return PublishError.auth('Your YouTube sign-in is no longer valid; reconnect the account',
        raw: raw, statusCode: status);
  }
  if (_validationReasons.contains(reason)) {
    return PublishError.validation(msg, raw: raw, statusCode: status);
  }
  if (status >= 500) {
    return PublishError.network(msg, raw: raw, statusCode: status, retryAfter: res.retryAfter);
  }
  if (status == 403) {
    // Forbidden without a known reason: most often a channel-side block.
    return PublishError.platform(msg, raw: raw, statusCode: status);
  }
  final base = HttpFailure(res).toPublishError(context: context);
  return PublishError(
      kind: base.kind,
      message: msg,
      retryable: base.retryable,
      statusCode: status,
      raw: raw,
      retryAfter: base.retryAfter);
}

/// Classifies transport-level exceptions (after [NeforumHttp]'s own retries).
/// Returns `null` for anything that is not a network problem.
PublishError? youtubeNetworkError(Object e, String context, DateTime now) {
  if (e is AdapterException) return e.error;
  if (e is HttpFailure) return mapYouTubeError(e.response, context: context, now: now);
  if (e is http.ClientException || e is TimeoutException || isTransientIoError(e)) {
    return PublishError.network('$context: network error ($e)');
  }
  return null;
}

bool isNetworkException(Object e) => e is http.ClientException || e is TimeoutException || isTransientIoError(e);

/// YouTube quotas reset at midnight Pacific time. Returns the time from
/// [now] until the next Pacific midnight (US daylight-saving rules).
Duration untilPacificMidnight(DateTime now) {
  final utc = now.toUtc();
  var offset = _pacificOffset(utc);
  final local = utc.add(offset);
  final nextLocalMidnight = DateTime.utc(local.year, local.month, local.day + 1);
  var resetUtc = nextLocalMidnight.subtract(offset);
  // The offset at the reset instant may differ when DST switched in between.
  final offsetAtReset = _pacificOffset(resetUtc);
  if (offsetAtReset != offset) {
    offset = offsetAtReset;
    resetUtc = nextLocalMidnight.subtract(offset);
  }
  return resetUtc.difference(utc);
}

/// UTC-7 between the second Sunday of March 02:00 PST and the first Sunday
/// of November 02:00 PDT, else UTC-8.
Duration _pacificOffset(DateTime utc) {
  final y = utc.year;
  final dstStart = _nthSunday(y, 3, 2).add(const Duration(hours: 10)); // 02:00 PST = 10:00 UTC
  final dstEnd = _nthSunday(y, 11, 1).add(const Duration(hours: 9)); // 02:00 PDT = 09:00 UTC
  final dst = !utc.isBefore(dstStart) && utc.isBefore(dstEnd);
  return Duration(hours: dst ? -7 : -8);
}

DateTime _nthSunday(int year, int month, int n) {
  final first = DateTime.utc(year, month);
  final toSunday = (DateTime.sunday - first.weekday) % 7;
  return DateTime.utc(year, month, 1 + toSunday + 7 * (n - 1));
}

String snippet(String body) => body.length > 600 ? '${body.substring(0, 600)}…' : body;

// ---------------------------------------------------------------------------
// Resumable upload (videos.insert, uploadType=resumable)
// ---------------------------------------------------------------------------

/// Runs Google's resumable upload protocol: open a session with the video
/// metadata, PUT the bytes to the session URI, and on interruption ask the
/// server how much arrived (`Content-Range: bytes */TOTAL` -> 308 + `Range`)
/// and send the rest.
class YouTubeResumableUpload {
  YouTubeResumableUpload({
    required this.ctx,
    required this.accessToken,
    this.maxResumes = 3,
    this.resumeDelay = const Duration(seconds: 2),
  });

  final AdapterContext ctx;
  final String accessToken;

  /// How many times an interrupted upload is resumed before giving up.
  final int maxResumes;
  final Duration resumeDelay;

  Map<String, String> get _auth => {'Authorization': 'Bearer $accessToken'};

  /// Uploads [bytes] with [metadata] and returns the created video resource.
  Future<Map<String, dynamic>> upload({
    required Map<String, dynamic> metadata,
    required Uint8List bytes,
    required String mimeType,
    bool notifySubscribers = true,
  }) async {
    final session = await _openSession(metadata, bytes.length, mimeType, notifySubscribers);
    return _sendBytes(session, bytes, mimeType);
  }

  Future<Uri> _openSession(Map<String, dynamic> metadata, int length, String mimeType, bool notify) async {
    ctx.progress('Starting YouTube upload');
    final res = await ctx.http.postJson(
      YouTubeEndpoints.uploadSession(notifySubscribers: notify),
      metadata,
      headers: {
        ..._auth,
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Length': '$length',
        'X-Upload-Content-Type': mimeType,
      },
      throwOnError: false,
    );
    if (!res.ok) throw AdapterException(mapYouTubeError(res, context: 'YouTube upload start', now: ctx.now()));
    final location = Uri.tryParse(res.headers['location'] ?? '');
    if (location == null || !location.hasScheme) {
      throw const AdapterException(PublishError.platform('YouTube did not return an upload session URL'));
    }
    return location;
  }

  Future<Map<String, dynamic>> _sendBytes(Uri session, Uint8List bytes, String mimeType) async {
    final total = bytes.length;
    var offset = 0;
    PublishError? lastError;
    for (var attempt = 0; attempt <= maxResumes; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(resumeDelay);
        ctx.progress('Resuming YouTube upload (attempt ${attempt + 1})');
        final probe = await _probe(session, total);
        if (probe.done != null) return probe.done!;
        if (probe.error != null) {
          lastError = probe.error;
          if (!probe.error!.retryable || probe.fatal) throw AdapterException(probe.error!);
          continue;
        }
        offset = probe.offset!;
      }
      final NeforumResponse res;
      try {
        ctx.progress(offset == 0
            ? 'Uploading video to YouTube (${_mb(total)})'
            : 'Uploading the remaining ${_mb(total - offset)} to YouTube');
        res = await ctx.http.putBytes(
          session,
          offset == 0 ? bytes : Uint8List.sublistView(bytes, offset),
          headers: {
            ..._auth,
            'Content-Type': mimeType,
            if (offset > 0) 'Content-Range': 'bytes $offset-${total - 1}/$total',
          },
          throwOnError: false,
        );
      } on Object catch (e) {
        if (!isNetworkException(e)) rethrow;
        ctx.log.warn('YouTube upload interrupted: $e');
        lastError = PublishError.network('YouTube upload interrupted ($e)');
        continue;
      }
      if (res.statusCode == 200 || res.statusCode == 201) return res.jsonMap;
      if (res.statusCode == 308) {
        lastError = const PublishError.network('YouTube upload incomplete');
        continue;
      }
      final err = _sessionError(res);
      if (!err.retryable || _expired(res)) throw AdapterException(err);
      lastError = err;
    }
    throw AdapterException(lastError ?? const PublishError.network('YouTube upload failed'));
  }

  /// Asks the session how many bytes arrived.
  Future<_Probe> _probe(Uri session, int total) async {
    final NeforumResponse res;
    try {
      res = await ctx.http.putBytes(session, Uint8List(0),
          headers: {..._auth, 'Content-Range': 'bytes */$total'}, throwOnError: false);
    } on Object catch (e) {
      if (!isNetworkException(e)) rethrow;
      return _Probe.error(PublishError.network('YouTube upload status check failed ($e)'));
    }
    if (res.statusCode == 200 || res.statusCode == 201) return _Probe.done(res.jsonMap);
    if (res.statusCode == 308) return _Probe.offset(parseUploadedOffset(res.headers['range']));
    return _Probe.error(_sessionError(res), fatal: _expired(res));
  }

  static bool _expired(NeforumResponse res) => res.statusCode == 404 || res.statusCode == 410;

  PublishError _sessionError(NeforumResponse res) {
    if (_expired(res)) {
      return PublishError.platform('The YouTube upload session expired; publish again to start over',
          raw: snippet(res.body), statusCode: res.statusCode, retryable: true);
    }
    return mapYouTubeError(res, context: 'YouTube video upload', now: ctx.now());
  }

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Parses a `Range: bytes=0-N` header from a 308 into the next byte to
/// send (N + 1). No header means nothing arrived yet.
int parseUploadedOffset(String? range) {
  if (range == null) return 0;
  final m = RegExp(r'bytes=\d+-(\d+)').firstMatch(range);
  return m == null ? 0 : int.parse(m.group(1)!) + 1;
}

class _Probe {
  _Probe.done(Map<String, dynamic> this.done)
      : offset = null,
        error = null,
        fatal = false;
  _Probe.offset(int this.offset)
      : done = null,
        error = null,
        fatal = false;
  _Probe.error(PublishError this.error, {this.fatal = false})
      : done = null,
        offset = null;

  final Map<String, dynamic>? done;
  final int? offset;
  final PublishError? error;

  /// The session is gone; resuming cannot help.
  final bool fatal;
}
