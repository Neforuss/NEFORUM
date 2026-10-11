import '../../auth/oauth2_pkce.dart';
import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../../util/logger.dart';
import '../platform_adapter.dart';

/// Host of the Threads Graph API (`graph.threads.com` is an alias since
/// 2025-06-06; both work).
const String threadsGraphHost = 'graph.threads.net';

/// Version path segment used for every Graph call except the token
/// endpoints, which are unversioned.
const String threadsApiVersion = 'v1.0';

/// Waits for [duration]. Injectable so tests do not sleep.
typedef ThreadsDelay = Future<void> Function(Duration duration);

Future<void> threadsDefaultDelay(Duration d) => Future<void>.delayed(d);

/// Waits between container-status checks. Meta recommends waiting about
/// 30 s before publishing media and polling no more than once per minute for
/// at most five minutes; the first short waits catch the common case of an
/// image that finishes within seconds. The total is 300 s.
const List<Duration> threadsPollDelays = [
  Duration(seconds: 10),
  Duration(seconds: 20),
  Duration(seconds: 30),
  Duration(seconds: 60),
  Duration(seconds: 60),
  Duration(seconds: 60),
  Duration(seconds: 60),
];

/// Status of a Threads media container (`GET /{container-id}?fields=status,error_message`).
class ThreadsContainerStatus {
  const ThreadsContainerStatus(this.status, this.errorMessage);

  /// EXPIRED, ERROR, FINISHED, IN_PROGRESS or PUBLISHED.
  final String status;
  final String? errorMessage;

  bool get isReady => status == 'FINISHED' || status == 'PUBLISHED';
}

/// Thin typed wrapper over the Threads Graph endpoints NEFORUM uses.
///
/// Every failing call is converted into an [AdapterException] carrying a
/// [PublishError] refined from Meta's error body.
class ThreadsApi {
  ThreadsApi(this._http, this._accessToken, {ThreadsDelay delay = threadsDefaultDelay, Logger? log})
      : _delay = delay,
        _log = log ?? Logger('threads');

  final NeforumHttp _http;
  final String _accessToken;
  final ThreadsDelay _delay;
  final Logger _log;

  static Uri graphUri(String path, [Map<String, String>? query]) =>
      Uri.https(threadsGraphHost, '/$threadsApiVersion/$path', query);

  /// `GET /v1.0/me?fields=id,username,threads_profile_picture_url`.
  Future<Map<String, dynamic>> me() async {
    final res = await _guard('Reading your Threads profile', () => _http.get(graphUri('me', {
          'fields': 'id,username,threads_profile_picture_url',
          'access_token': _accessToken,
        })));
    return res.jsonMap;
  }

  /// `POST /v1.0/{user-id}/threads` → container id.
  Future<String> createContainer(String userId, Map<String, String> params) async {
    final res = await _guard('Creating the Threads post',
        () => _http.postForm(graphUri('$userId/threads'), {...params, 'access_token': _accessToken}));
    return _idOf(res, 'container');
  }

  /// `POST /v1.0/{user-id}/threads_publish` → published media id.
  Future<String> publishContainer(String userId, String creationId) async {
    final res = await _guard('Publishing the Threads post',
        () => _http.postForm(graphUri('$userId/threads_publish'), {
              'creation_id': creationId,
              'access_token': _accessToken,
            }));
    return _idOf(res, 'post');
  }

  /// `GET /v1.0/{container-id}?fields=status,error_message`.
  Future<ThreadsContainerStatus> status(String containerId) async {
    final res = await _guard('Checking media processing',
        () => _http.get(graphUri(containerId, {'fields': 'status,error_message', 'access_token': _accessToken})));
    final j = res.jsonMap;
    return ThreadsContainerStatus((j['status'] as String?) ?? 'IN_PROGRESS', j['error_message'] as String?);
  }

  /// Polls [containerId] until Meta has fetched and processed its media.
  Future<void> waitUntilReady(String containerId, {void Function(String message)? onWait, String? mediaUrl}) async {
    for (var i = 0;; i++) {
      final st = await status(containerId);
      if (st.isReady) return;
      if (st.status == 'ERROR') throw AdapterException(containerError(st.errorMessage, mediaUrl: mediaUrl));
      if (st.status == 'EXPIRED') {
        throw const AdapterException(
            PublishError.platform('The Threads media container expired before it could be published', retryable: true));
      }
      if (i >= threadsPollDelays.length) {
        throw const AdapterException(PublishError.network(
            'Threads is still processing the media after 5 minutes; try again later'));
      }
      final wait = threadsPollDelays[i];
      onWait?.call('Threads is processing the media (waiting ${wait.inSeconds}s)');
      await _delay(wait);
    }
  }

  /// `GET /v1.0/{media-id}?fields=permalink`; best effort, `null` on failure.
  Future<String?> permalink(String mediaId) async {
    try {
      final res = await _http.get(graphUri(mediaId, {'fields': 'permalink', 'access_token': _accessToken}),
          throwOnError: false);
      if (!res.ok) return null;
      return res.jsonMap['permalink'] as String?;
    } on Exception catch (e) {
      _log.debug('Could not read Threads permalink: $e');
      return null;
    }
  }

  Future<NeforumResponse> _guard(String context, Future<NeforumResponse> Function() call) async {
    try {
      return await call();
    } on HttpFailure catch (f) {
      throw AdapterException(threadsErrorFrom(f, context: context));
    }
  }

  static String _idOf(NeforumResponse res, String what) {
    final id = res.jsonMap['id'];
    if (id == null) {
      throw AdapterException(PublishError.platform('Threads returned no $what id', raw: res.body));
    }
    return '$id';
  }

  // ---- tokens ------------------------------------------------------------

  /// `GET /access_token?grant_type=th_exchange_token` → 60-day token.
  static Future<OAuthTokens> exchangeForLongLived(NeforumHttp http,
      {required String clientSecret, required String shortLivedToken, required DateTime now}) async {
    final res = await http.get(Uri.https(threadsGraphHost, '/access_token', {
      'grant_type': 'th_exchange_token',
      'client_secret': clientSecret,
      'access_token': shortLivedToken,
    }));
    return _tokensOf(res, now);
  }

  /// `GET /refresh_access_token?grant_type=th_refresh_token` → new 60-day token.
  static Future<OAuthTokens> refreshLongLived(NeforumHttp http,
      {required String longLivedToken, required DateTime now}) async {
    final res = await http.get(Uri.https(threadsGraphHost, '/refresh_access_token', {
      'grant_type': 'th_refresh_token',
      'access_token': longLivedToken,
    }));
    return _tokensOf(res, now);
  }

  /// `GET /v1.0/debug_token` with [token] as both the inspected token and
  /// the caller (Threads "Debug Access Token": the caller must be a Threads
  /// tester's token for the same app, which a token the user generated for
  /// themselves is). Best effort: `null` when Meta does not answer usefully.
  static Future<ThreadsTokenInfo?> debugToken(NeforumHttp http, String token, {Logger? log}) async {
    try {
      final res = await http.get(graphUri('debug_token', {'input_token': token, 'access_token': token}),
          throwOnError: false);
      if (!res.ok) {
        log?.debug('Threads debug_token answered HTTP ${res.statusCode}');
        return null;
      }
      final data = res.jsonMap['data'];
      return data is Map ? ThreadsTokenInfo.fromJson(Map<String, dynamic>.from(data)) : null;
    } on Exception catch (e) {
      log?.debug('Threads debug_token failed: $e');
      return null;
    }
  }

  static OAuthTokens _tokensOf(NeforumResponse res, DateTime now) {
    final j = res.jsonMap;
    if (j['access_token'] is! String) {
      throw AdapterException(PublishError.auth('Threads returned no access token', raw: res.body));
    }
    final t = OAuthTokens.fromTokenResponse(j, now: now);
    // Meta returns `bearer` in lower case; normalise for the header helper.
    return OAuthTokens(
      accessToken: t.accessToken,
      expiresAt: t.expiresAt,
      tokenType: 'Bearer',
      scope: t.scope,
      raw: t.raw,
    );
  }
}

/// What `debug_token` says about a Threads user access token.
class ThreadsTokenInfo {
  const ThreadsTokenInfo({required this.isValid, this.expiresAt, this.issuedAt, this.scopes = const [], this.userId});

  factory ThreadsTokenInfo.fromJson(Map<String, dynamic> j) {
    DateTime? time(Object? v) {
      final secs = v is int ? v : int.tryParse('${v ?? ''}');
      // 0 means "does not expire" / unknown; neither gives NEFORUM a date.
      return secs == null || secs <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);
    }

    final scopes = j['scopes'];
    return ThreadsTokenInfo(
      isValid: j['is_valid'] != false,
      expiresAt: time(j['expires_at']),
      issuedAt: time(j['issued_at']),
      scopes: scopes is List ? scopes.map((s) => '$s').toList() : const [],
      userId: j['user_id']?.toString(),
    );
  }

  final bool isValid;
  final DateTime? expiresAt;
  final DateTime? issuedAt;

  /// Granted permissions; empty when Meta did not list them.
  final List<String> scopes;
  final String? userId;
}

/// Graph API error codes NEFORUM maps explicitly.
abstract final class ThreadsErrorCodes {
  static const unknown = 1;
  static const service = 2;
  static const appRateLimit = 4;
  static const permissionDenied = 10;
  static const userRateLimit = 17;
  static const pageRateLimit = 32;
  static const invalidParameter = 100;
  static const sessionKey = 102;
  static const invalidToken = 190;
  static const blocked = 368;
  static const duplicate = 506;
  static const throttled = 613;
}

/// Converts an HTTP failure from the Threads Graph API into a [PublishError],
/// reading Meta's `{"error": {"message", "type", "code", "error_subcode"}}`
/// body where present.
PublishError threadsErrorFrom(HttpFailure f, {String? context}) {
  final base = f.toPublishError(context: context);
  final err = f.response.jsonMap['error'];
  if (err is! Map) return base;
  final code = _asInt(err['code']);
  final type = err['type'] as String?;
  final metaMsg = (err['error_user_msg'] as String?) ?? (err['message'] as String?) ?? '';
  final prefix = context == null ? '' : '$context: ';
  final msg = '$prefix${metaMsg.isEmpty ? 'HTTP ${f.statusCode}' : metaMsg}';
  final raw = base.raw;
  final status = f.statusCode;

  if (metaMsg.contains('LINK_LIMIT_EXCEEDED')) {
    return PublishError.validation('${prefix}Threads allows at most 5 links per post', raw: raw, statusCode: status);
  }
  switch (code) {
    case ThreadsErrorCodes.invalidToken:
    case ThreadsErrorCodes.sessionKey:
      return PublishError.auth('${prefix}Your Threads sign-in has expired or was revoked; reconnect the account',
          raw: raw, statusCode: status);
    case ThreadsErrorCodes.permissionDenied:
      return PublishError.auth(
          '${prefix}Threads refused the permission ($metaMsg). Reconnect and allow threads_content_publish',
          raw: raw, statusCode: status);
    case ThreadsErrorCodes.appRateLimit:
    case ThreadsErrorCodes.userRateLimit:
    case ThreadsErrorCodes.pageRateLimit:
    case ThreadsErrorCodes.throttled:
      return PublishError.quota('${prefix}Threads rate limit reached ($metaMsg)',
          raw: raw, statusCode: status, retryAfter: f.response.retryAfter);
    case ThreadsErrorCodes.unknown:
    case ThreadsErrorCodes.service:
      return PublishError.network(msg, raw: raw, statusCode: status, retryAfter: f.response.retryAfter);
    case ThreadsErrorCodes.blocked:
      return PublishError.platform('${prefix}Threads temporarily blocked this action ($metaMsg)',
          raw: raw, statusCode: status);
    case ThreadsErrorCodes.duplicate:
      return PublishError.validation('${prefix}Threads rejected this as a duplicate post', raw: raw, statusCode: status);
    case ThreadsErrorCodes.invalidParameter:
      return PublishError.validation(msg, raw: raw, statusCode: status);
  }
  if (code != null && code >= 200 && code < 300) {
    return PublishError.auth('${prefix}Missing Threads permission ($metaMsg); reconnect the account',
        raw: raw, statusCode: status);
  }
  if (status == 429) {
    return PublishError.quota('${prefix}Threads rate limit reached', raw: raw, statusCode: status, retryAfter: f.response.retryAfter);
  }
  if (type == 'OAuthException' && (status == 401 || status == 403)) {
    return PublishError.auth(msg, raw: raw, statusCode: status);
  }
  return PublishError(
    kind: base.kind,
    message: msg,
    retryable: base.retryable,
    statusCode: status,
    raw: raw,
    retryAfter: base.retryAfter,
  );
}

/// Maps a container `error_message` (status ERROR) onto a [PublishError].
PublishError containerError(String? errorMessage, {String? mediaUrl}) {
  final m = errorMessage ?? 'UNKNOWN';
  if (m.startsWith('FAILED_DOWNLOADING')) {
    return PublishError.configuration('Threads could not download the media${mediaUrl == null ? '' : ' from $mediaUrl'}. '
        'Check that your media host serves the file publicly over HTTPS without redirects or bot protection ($m).');
  }
  if (m.startsWith('INVALID_')) {
    return PublishError.validation('Threads rejected the media: ${_humanise(m)} ($m)');
  }
  return PublishError.platform('Threads could not process the media ($m)', retryable: m == 'UNKNOWN');
}

String _humanise(String code) => code.replaceFirst('INVALID_', '').replaceAll('_', ' ').toLowerCase();

int? _asInt(Object? v) => v is int ? v : int.tryParse('$v');
