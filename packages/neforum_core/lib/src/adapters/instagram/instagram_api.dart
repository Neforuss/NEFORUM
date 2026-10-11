import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../platform_adapter.dart';

/// Graph API version used for every versioned call. The Instagram Platform
/// docs (content publishing guide, IG User Media reference and the
/// Instagram-Login "get started" guide, read 2026-10-07) all show v25.0.
const String instagramGraphVersion = 'v25.0';

/// Host of the "Instagram API with Instagram Login" flavour.
const String instagramGraphHost = 'graph.instagram.com';

/// Authorization page of Business Login for Instagram.
final Uri instagramAuthorizeUrl = Uri.parse('https://www.instagram.com/oauth/authorize');

/// Short-lived token exchange (needs the Instagram app secret).
final Uri instagramTokenUrl = Uri.parse('https://api.instagram.com/oauth/access_token');

/// Scopes NEFORUM asks for: profile basics plus content publishing.
const List<String> instagramScopes = ['instagram_business_basic', 'instagram_business_content_publish'];

/// What the token endpoint and `/me` tell us about the signed-in user.
class InstagramShortToken {
  const InstagramShortToken(this.accessToken, this.userId, this.permissions);
  final String accessToken;
  final String? userId;
  final List<String> permissions;
}

/// A long-lived (60 day) Instagram user token.
class InstagramLongToken {
  const InstagramLongToken(this.accessToken, this.expiresIn);
  final String accessToken;
  final Duration? expiresIn;
}

/// The professional account behind a token (`GET /me`).
class InstagramProfile {
  const InstagramProfile({required this.userId, required this.username, this.accountType, this.pictureUrl, this.name});
  final String userId;
  final String username;
  final String? accountType;
  final String? pictureUrl;
  final String? name;
}

/// Thin typed wrapper over the Instagram Graph endpoints NEFORUM uses.
///
/// Every failing call throws [AdapterException] with a [PublishError]
/// already classified from Meta's error body.
class InstagramApi {
  InstagramApi(this.ctx, {required this.sleep, required this.pollSchedule});

  final AdapterContext ctx;
  final Future<void> Function(Duration) sleep;

  /// Delays before each status poll. The first entry is usually zero.
  final List<Duration> pollSchedule;

  static Uri graph(String path, [Map<String, String>? query]) => Uri(
        scheme: 'https',
        host: instagramGraphHost,
        path: '/$instagramGraphVersion/$path',
        queryParameters: (query == null || query.isEmpty) ? null : query,
      );

  static Map<String, String> _auth(String token) => {'Authorization': 'Bearer $token'};

  // --- auth ---------------------------------------------------------------

  /// POST https://api.instagram.com/oauth/access_token (form). The docs show
  /// the result wrapped in `{"data": [...]}`; live responses are flat, so
  /// both shapes are accepted.
  Future<InstagramShortToken> exchangeCode({
    required String appId,
    required String appSecret,
    required Uri redirectUri,
    required String code,
  }) async {
    final res = await _guard('exchanging the authorization code', () => ctx.http.postForm(instagramTokenUrl, {
          'client_id': appId,
          'client_secret': appSecret,
          'grant_type': 'authorization_code',
          'redirect_uri': redirectUri.toString(),
          'code': code,
        }, headers: const {'Accept': 'application/json'}));
    final body = unwrapData(res.jsonMap);
    final token = body['access_token'];
    if (token is! String || token.isEmpty) {
      throw const AdapterException(PublishError.auth('Instagram did not return an access token'));
    }
    return InstagramShortToken(token, _string(body['user_id']), _permissions(body['permissions']));
  }

  /// GET /access_token?grant_type=ig_exchange_token (needs the app secret).
  Future<InstagramLongToken> exchangeLongLived(String shortToken, String appSecret) async {
    final url = Uri.https(instagramGraphHost, '/access_token', {
      'grant_type': 'ig_exchange_token',
      'client_secret': appSecret,
      'access_token': shortToken,
    });
    final res = await _guard('getting a long-lived token', () => ctx.http.get(url));
    return _longToken(res.jsonMap);
  }

  /// GET /refresh_access_token?grant_type=ig_refresh_token. Works once the
  /// token is at least 24 hours old and not yet expired.
  Future<InstagramLongToken> refresh(String longToken) async {
    final url = Uri.https(instagramGraphHost, '/refresh_access_token', {
      'grant_type': 'ig_refresh_token',
      'access_token': longToken,
    });
    final res = await _guard('refreshing the token', () => ctx.http.get(url));
    return _longToken(res.jsonMap);
  }

  /// GET /v25.0/me?fields=user_id,username,... — `user_id` is the
  /// professional account id used in publishing paths.
  Future<InstagramProfile> me(String token) async {
    final res = await _guard('reading your profile', () => ctx.http.get(
          graph('me', {'fields': 'user_id,username,name,account_type,profile_picture_url'}),
          headers: _auth(token),
        ));
    final body = unwrapData(res.jsonMap);
    final userId = _string(body['user_id']) ?? _string(body['id']);
    final username = _string(body['username']);
    if (userId == null || username == null) {
      throw const AdapterException(PublishError.platform('Instagram did not return your account id'));
    }
    return InstagramProfile(
      userId: userId,
      username: username,
      accountType: _string(body['account_type']),
      pictureUrl: _string(body['profile_picture_url']),
      name: _string(body['name']),
    );
  }

  // --- publishing -----------------------------------------------------------

  /// POST /{ig-user-id}/media → container id.
  Future<String> createContainer(String igUserId, String token, Map<String, String> fields, {String? label}) async {
    final res = await _guard('creating ${label ?? 'the media container'}',
        () => ctx.http.postForm(graph('$igUserId/media'), fields, headers: _auth(token)));
    final id = _string(res.jsonMap['id']);
    if (id == null) throw const AdapterException(PublishError.platform('Instagram returned no container id'));
    return id;
  }

  /// How often a status poll may answer "does not exist" (24 / 2207008)
  /// before NEFORUM gives up. Meta calls it temporary: "retry 1-2 times over
  /// 30 seconds to 2 minutes".
  static const int maxNotYetAvailable = 5;

  /// Polls GET /{container-id}?fields=status_code,status until FINISHED.
  Future<void> waitUntilFinished(String containerId, String token, {String? label}) async {
    String? lastStatus;
    var notYetAvailable = 0;
    final what = 'checking ${label ?? 'the media'}';
    for (var i = 0; i < pollSchedule.length; i++) {
      final delay = pollSchedule[i];
      if (delay > Duration.zero) {
        ctx.progress('Instagram is processing ${label ?? 'your media'}…');
        await sleep(delay);
      }
      final NeforumResponse res;
      try {
        res = await ctx.http.get(graph(containerId, {'fields': 'status_code,status'}), headers: _auth(token));
      } on HttpFailure catch (f) {
        final err = f.response.jsonMap['error'];
        final sub = err is Map ? _int(err['error_subcode']) : null;
        if (sub == 2207008 && ++notYetAvailable <= maxNotYetAvailable && i < pollSchedule.length - 1) continue;
        throw AdapterException(mapHttpFailure(f, context: what));
      } on TimeoutException {
        throw AdapterException(PublishError.network('Timed out while $what'));
      } on http.ClientException catch (e) {
        throw AdapterException(PublishError.network('Network error while $what: ${e.message}'));
      }
      final body = res.jsonMap;
      final code = _string(body['status_code']) ?? 'IN_PROGRESS';
      lastStatus = _string(body['status']);
      switch (code) {
        case 'FINISHED':
        case 'PUBLISHED':
          return;
        case 'IN_PROGRESS':
          continue;
        case 'EXPIRED':
          throw const AdapterException(PublishError.network(
              'The Instagram container expired (not published within 24 hours); try again'));
        default:
          throw AdapterException(containerStatusError(lastStatus));
      }
    }
    throw AdapterException(PublishError.network(
        'Instagram is still processing ${label ?? 'the media'} after ${_total(pollSchedule).inMinutes} minutes; try again later',
        raw: lastStatus));
  }

  /// POST /{ig-user-id}/media_publish → published media id.
  Future<String> publish(String igUserId, String token, String containerId) async {
    final res = await _guard('publishing the post',
        () => ctx.http.postForm(graph('$igUserId/media_publish'), {'creation_id': containerId}, headers: _auth(token)));
    final id = _string(res.jsonMap['id']);
    if (id == null) throw const AdapterException(PublishError.platform('Instagram returned no media id'));
    return id;
  }

  /// Best effort: the public URL of a published media object.
  Future<String?> permalink(String mediaId, String token) async {
    try {
      final res = await ctx.http.get(graph(mediaId, {'fields': 'permalink'}), headers: _auth(token));
      return _string(res.jsonMap['permalink']);
    } on Object catch (e) {
      ctx.log.warn('Could not read the Instagram permalink for $mediaId', e);
      return null;
    }
  }

  // --- helpers --------------------------------------------------------------

  Future<NeforumResponse> _guard(String what, Future<NeforumResponse> Function() call) async {
    try {
      return await call();
    } on HttpFailure catch (f) {
      throw AdapterException(mapHttpFailure(f, context: what));
    } on TimeoutException {
      throw AdapterException(PublishError.network('Timed out while $what'));
    } on http.ClientException catch (e) {
      throw AdapterException(PublishError.network('Network error while $what: ${e.message}'));
    }
  }

  InstagramLongToken _longToken(Map<String, dynamic> json) {
    final token = json['access_token'];
    if (token is! String || token.isEmpty) {
      throw const AdapterException(PublishError.auth('Instagram did not return a long-lived token'));
    }
    final secs = json['expires_in'];
    final n = secs is int ? secs : int.tryParse('$secs');
    return InstagramLongToken(token, n == null ? null : Duration(seconds: n));
  }

  static Duration _total(List<Duration> l) => l.fold(Duration.zero, (a, b) => a + b);

  /// Takes the first element of `{"data": [...]}` when present.
  static Map<String, dynamic> unwrapData(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is List && data.isNotEmpty && data.first is Map) {
      return Map<String, dynamic>.from(data.first as Map);
    }
    return json;
  }

  static String? _string(Object? v) => switch (v) {
        null => null,
        final String s => s.isEmpty ? null : s,
        final num n => n.toString(),
        _ => v.toString(),
      };

  static List<String> _permissions(Object? v) {
    if (v is String) return v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (v is List) return v.map((e) => '$e'.trim()).toList();
    return const [];
  }
}

// --- error mapping ------------------------------------------------------------

/// Turns a non-2xx Graph response into a classified [PublishError].
///
/// Meta returns most errors (including expired tokens) as HTTP 400 with
/// `{"error": {"message", "type", "code", "error_subcode", ...}}`, so the
/// status code alone is not enough.
PublishError mapHttpFailure(HttpFailure f, {String? context}) {
  final base = f.toPublishError(context: context);
  final body = f.response.jsonMap;
  final raw = base.raw;
  final status = f.statusCode;
  final prefix = context == null ? '' : 'Instagram refused $context: ';
  final err = body['error'];
  if (err is! Map) {
    // api.instagram.com/oauth/access_token answers with a flat body:
    // {"error_type": "OAuthException", "code": 400, "error_message": "..."}.
    final flat = _text(body['error_message']);
    if (flat == null) return base;
    if (_text(body['error_type']) == 'OAuthException' && status < 500) {
      return PublishError.auth('$prefix$flat', raw: raw, statusCode: status);
    }
    return PublishError(
        kind: base.kind, message: '$prefix$flat', raw: raw, statusCode: status, retryable: base.retryable, retryAfter: base.retryAfter);
  }
  final e = Map<String, dynamic>.from(err);
  final code = _int(e['code']);
  final sub = _int(e['error_subcode']);
  final type = _text(e['type']);
  final metaMsg = _text(e['error_user_msg']) ?? _text(e['message']) ?? 'Instagram error';
  final msg = '$prefix$metaMsg';

  final bySub = sub == null ? null : _subcodeError(sub, msg, raw, status);
  if (bySub != null) return bySub;

  switch (code) {
    case 190: // invalid / expired / revoked token
    case 102: // session error
    case 10: // permission not granted
    case 200: // permission error
      return PublishError.auth('$msg (reconnect your Instagram account)', raw: raw, statusCode: status);
    case 4: // app-level throttling
    case 17: // user-level throttling
    case 32:
    case 613:
    case 341:
    case 80002: // Instagram Business Use Case rate limit (Graph rate-limiting doc)
      return PublishError.quota('$msg (Instagram rate limit)',
          raw: raw, statusCode: status, retryAfter: f.response.retryAfter ?? _bucRetryAfter(f.response.headers));
    case 1:
    case 2:
      return PublishError.network(msg, raw: raw, statusCode: status);
    case 100:
      return PublishError.validation(msg, raw: raw, statusCode: status);
  }
  if (type == 'OAuthException' && (status == 401 || status == 403)) {
    return PublishError.auth(msg, raw: raw, statusCode: status);
  }
  if (status == 429) {
    return PublishError.quota(msg, raw: raw, statusCode: status, retryAfter: base.retryAfter ?? _bucRetryAfter(f.response.headers));
  }
  return PublishError(
    kind: base.kind,
    message: msg,
    raw: raw,
    statusCode: status,
    retryable: base.retryable,
    retryAfter: base.retryAfter,
  );
}

/// Error for a container whose `status_code` is ERROR. The human-readable
/// `status` usually embeds the 2207xxx subcode.
PublishError containerStatusError(String? status) {
  final sub = int.tryParse(RegExp(r'22070\d\d').firstMatch(status ?? '')?.group(0) ?? '');
  final msg = 'Instagram could not process the media${status == null ? '' : ': $status'}';
  return (sub == null ? null : _subcodeError(sub, msg, status, null)) ??
      PublishError.platform(msg, raw: status);
}

/// Subcodes from the Instagram error-codes reference (read 2026-10-07).
PublishError? _subcodeError(int sub, String msg, String? raw, int? status) {
  switch (sub) {
    case 2207042: // daily publishing limit reached
      return PublishError.quota('$msg (Instagram allows a limited number of API posts per 24 hours)',
          raw: raw, statusCode: status);
    case 2207051: // spam / automation flag
      return PublishError.platform(
          '$msg (Instagram flagged this as suspicious activity; wait before posting again)',
          raw: raw, statusCode: status);
    case 2207050: // account restricted
      return PublishError.auth('$msg (open the Instagram app and complete the requested steps)',
          raw: raw, statusCode: status);
    case 2207052: // media could not be fetched
      return PublishError(
          kind: PublishErrorKind.configuration,
          message: '$msg (Instagram could not download the file from your media host: check that the link is '
              'public, not expired, not a redirect and returns the file itself)',
          raw: raw,
          statusCode: status);
    case 2207003: // download took too long
    case 2207001: // server error
    case 2207032: // create media failed
    case 2207053: // unknown upload error
    case 2207020: // container expired
    case 2207008: // container does not exist yet
    case 2207027: // not ready
      return PublishError.network(msg, raw: raw, statusCode: status);
    case 2207004: // image too large
    case 2207005: // unsupported image format
    case 2207009: // aspect ratio
    case 2207010: // caption too long / too many hashtags
    case 2207023: // unknown media type
    case 2207026: // unsupported video format
    case 2207028: // carousel item count
    case 2207040: // too many @ tags
    case 2207057: // thumbnail offset
      return PublishError.validation(msg, raw: raw, statusCode: status);
    case 2207006: // media not found: missing permission or expired token
    case 458: // app not installed / access removed (Graph OAuth subcodes)
    case 460: // password changed
    case 463: // token expired
    case 467: // token invalid
      return PublishError.auth(msg, raw: raw, statusCode: status);
  }
  return null;
}

/// Reads `estimated_time_to_regain_access` (minutes) from Meta's
/// X-Business-Use-Case-Usage header.
Duration? _bucRetryAfter(Map<String, String> headers) {
  final h = headers['x-business-use-case-usage'];
  if (h == null) return null;
  try {
    final decoded = jsonDecode(h);
    if (decoded is! Map) return null;
    var minutes = 0;
    for (final entries in decoded.values) {
      if (entries is! List) continue;
      for (final entry in entries) {
        if (entry is! Map) continue;
        final m = _int(entry['estimated_time_to_regain_access']) ?? 0;
        if (m > minutes) minutes = m;
      }
    }
    return minutes > 0 ? Duration(minutes: minutes) : null;
  } on FormatException {
    return null;
  }
}

int? _int(Object? v) => v is int ? v : int.tryParse('${v ?? ''}');

String? _text(Object? v) {
  if (v == null) return null;
  final s = '$v';
  return s.isEmpty ? null : s;
}
