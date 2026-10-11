import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../auth/oauth2_pkce.dart';
import '../../http/neforum_http.dart';
import '../../http/transient_stub.dart' if (dart.library.io) '../../http/transient_io.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../platform_adapter.dart';

/// Endpoints of the TikTok Login Kit and Content Posting API (v2).
abstract final class TikTokEndpoints {
  static final Uri authorize = Uri.parse('https://www.tiktok.com/v2/auth/authorize/');
  static final Uri token = Uri.parse('https://open.tiktokapis.com/v2/oauth/token/');
  static final Uri revoke = Uri.parse('https://open.tiktokapis.com/v2/oauth/revoke/');
  static final Uri userInfo = Uri.parse(
      'https://open.tiktokapis.com/v2/user/info/?fields=open_id,display_name,avatar_url');
  static final Uri creatorInfo = Uri.parse('https://open.tiktokapis.com/v2/post/publish/creator_info/query/');
  static final Uri videoInit = Uri.parse('https://open.tiktokapis.com/v2/post/publish/video/init/');
  static final Uri inboxVideoInit = Uri.parse('https://open.tiktokapis.com/v2/post/publish/inbox/video/init/');
  static final Uri contentInit = Uri.parse('https://open.tiktokapis.com/v2/post/publish/content/init/');
  static final Uri statusFetch = Uri.parse('https://open.tiktokapis.com/v2/post/publish/status/fetch/');
}

/// Scopes NEFORUM asks for. Photos use the same `video.*` scopes.
const tiktokScopes = ['user.info.basic', 'video.publish', 'video.upload'];

/// Secret-map keys used by the TikTok adapter on top of [OAuthTokens] keys.
abstract final class TikTokSecretKeys {
  static const clientSecret = 'client_secret';
  static const refreshExpiresAt = 'refresh_expires_at';
  static const openId = 'open_id';
}

// ---------------------------------------------------------------------------
// OAuth (Login Kit for Desktop)
// ---------------------------------------------------------------------------

/// TikTok's PKCE is non-standard: the challenge is the HEX encoding of
/// SHA-256(verifier), not base64url (Login Kit for Desktop docs).
String tiktokCodeChallenge(String verifier) => sha256.convert(ascii.encode(verifier)).toString();

/// Builds the Login Kit authorization request. TikTok names the client
/// `client_key` and separates scopes with commas, so the generic
/// [OAuth2Client] URL builder (which emits `client_id`) is not used here.
AuthorizationRequest buildTikTokAuthorizationRequest({
  required String clientKey,
  required Uri redirectUri,
  String? state,
  PkcePair? pkce,
}) {
  final s = state ?? randomState();
  final verifier = (pkce ?? PkcePair.generate()).verifier;
  final pair = PkcePair(verifier, tiktokCodeChallenge(verifier));
  final url = TikTokEndpoints.authorize.replace(queryParameters: {
    'client_key': clientKey,
    'response_type': 'code',
    'scope': tiktokScopes.join(','),
    'redirect_uri': redirectUri.toString(),
    'state': s,
    'code_challenge': pair.challenge,
    'code_challenge_method': 'S256',
  });
  return AuthorizationRequest(url, s, pair);
}

/// POSTs a form to the token endpoint and parses the token response. Throws
/// [AdapterException] with an auth error when TikTok rejects the grant.
Future<OAuthTokens> tiktokTokenRequest(AdapterContext ctx, Map<String, String> form) async {
  final NeforumResponse res;
  try {
    res = await ctx.http.postForm(TikTokEndpoints.token, form,
        headers: const {'Accept': 'application/json'}, throwOnError: false);
  } on Object catch (e) {
    final err = networkErrorFor(e, 'TikTok token request');
    if (err == null) rethrow;
    throw AdapterException(err);
  }
  final json = res.jsonMap;
  if (res.ok && json['access_token'] is String) {
    return OAuthTokens.fromTokenResponse(json, now: ctx.now());
  }
  final err = json['error']?.toString() ?? 'http_${res.statusCode}';
  final desc = json['error_description']?.toString() ?? '';
  final raw = _snippet(res.body);
  if (res.statusCode >= 500 || err == 'server_error' || err == 'temporarily_unavailable') {
    throw AdapterException(PublishError.network('TikTok token endpoint unavailable ($err)',
        raw: raw, statusCode: res.statusCode, retryAfter: res.retryAfter));
  }
  if (res.statusCode == 429) {
    throw AdapterException(PublishError.quota('TikTok token endpoint rate limited',
        raw: raw, statusCode: 429, retryAfter: res.retryAfter ?? const Duration(minutes: 1)));
  }
  throw AdapterException(PublishError.auth(
      'TikTok refused the sign-in ($err${desc.isEmpty ? '' : ': $desc'}). Reconnect the account.',
      raw: raw,
      statusCode: res.statusCode));
}

/// Stores tokens plus TikTok's extra fields (`refresh_expires_in`, `open_id`).
Map<String, String> tiktokTokensToSecrets(OAuthTokens t, Map<String, String> existing, DateTime now) {
  final out = t.toSecrets(existing);
  final rexp = t.raw['refresh_expires_in'];
  final secs = rexp is int ? rexp : int.tryParse('${rexp ?? ''}');
  if (secs != null) {
    out[TikTokSecretKeys.refreshExpiresAt] = now.add(Duration(seconds: secs)).toUtc().toIso8601String();
  }
  final openId = t.raw['open_id'];
  if (openId is String && openId.isNotEmpty) out[TikTokSecretKeys.openId] = openId;
  return out;
}

// ---------------------------------------------------------------------------
// JSON API calls + error mapping
// ---------------------------------------------------------------------------

/// Calls a TikTok JSON endpoint and returns its `data` object. TikTok
/// signals some failures with HTTP 200 and `error.code != "ok"` (e.g.
/// creator_info `spam_risk_too_many_posts`), so the error object is always
/// checked.
Future<Map<String, dynamic>> tiktokCall(
  AdapterContext ctx,
  String method,
  Uri url,
  String accessToken, {
  Object? body,
  required String context,
}) async {
  final headers = {
    'Authorization': 'Bearer $accessToken',
    if (body != null) 'Content-Type': 'application/json; charset=UTF-8',
  };
  final NeforumResponse res;
  try {
    res = method == 'GET'
        ? await ctx.http.get(url, headers: headers, throwOnError: false)
        : await ctx.http.postJson(url, body ?? const <String, dynamic>{}, headers: headers, throwOnError: false);
  } on Object catch (e) {
    final err = networkErrorFor(e, context);
    if (err == null) rethrow;
    throw AdapterException(err);
  }
  final json = res.jsonMap;
  final error = json['error'] is Map ? Map<String, dynamic>.from(json['error'] as Map) : const <String, dynamic>{};
  final code = (error['code'] as String?) ?? (res.ok ? 'ok' : '');
  if (res.ok && code == 'ok') {
    return json['data'] is Map ? Map<String, dynamic>.from(json['data'] as Map) : <String, dynamic>{};
  }
  throw AdapterException(mapTikTokError(
    status: res.statusCode,
    code: code,
    message: (error['message'] as String?) ?? '',
    raw: _snippet(res.body),
    retryAfter: res.retryAfter,
    context: context,
    fallback: res.ok ? null : HttpFailure(res).toPublishError(context: context),
  ));
}

/// Maps a TikTok `error.code` onto a [PublishError].
PublishError mapTikTokError({
  required int status,
  required String code,
  String message = '',
  String? raw,
  Duration? retryAfter,
  required String context,
  PublishError? fallback,
}) {
  final detail = message.isEmpty ? code : '$code: $message';
  final msg = '$context failed ($detail)';
  switch (code) {
    case 'access_token_invalid':
      return PublishError.auth('TikTok access token is invalid or expired; reconnect the account',
          raw: raw, statusCode: status);
    case 'scope_not_authorized':
      return PublishError.auth('TikTok did not grant the video.publish / video.upload permission; reconnect and tick every permission',
          raw: raw, statusCode: status);
    case 'rate_limit_exceeded':
      return PublishError.quota('TikTok rate limit hit ($context)',
          raw: raw, statusCode: status, retryAfter: retryAfter ?? const Duration(minutes: 1));
    case 'spam_risk_too_many_posts':
      return PublishError.quota('This TikTok account reached its daily posting cap; try again tomorrow',
          raw: raw, statusCode: status, retryAfter: retryAfter);
    case 'spam_risk_too_many_pending_share':
      return PublishError.quota('TikTok allows at most 5 pending drafts per 24 hours; finish or delete some in the TikTok inbox',
          raw: raw, statusCode: status, retryAfter: retryAfter);
    case 'reached_active_user_cap':
      return PublishError.quota('Your TikTok developer app reached its daily limit of posting users',
          raw: raw, statusCode: status, retryAfter: retryAfter);
    case 'spam_risk_user_banned_from_posting':
      return PublishError.platform('TikTok has banned this account from posting', raw: raw, statusCode: status);
    case 'unaudited_client_can_only_post_to_private_accounts':
      return PublishError(
          kind: PublishErrorKind.configuration,
          message: 'Your TikTok app is not audited, so TikTok only accepts posts to a PRIVATE account. '
              'Switch the TikTok account to private (Settings > Privacy) or pass TikTok\'s Content Posting audit.',
          raw: raw,
          statusCode: status);
    case 'url_ownership_unverified':
      return PublishError(
          kind: PublishErrorKind.configuration,
          message: 'TikTok refused to fetch the photos: verify the media host\'s domain or URL prefix in your TikTok developer app',
          raw: raw,
          statusCode: status);
    case 'privacy_level_option_mismatch':
      return PublishError.validation('The chosen TikTok privacy level is not allowed for this account', raw: raw, statusCode: status);
    case 'app_version_check_failed':
      return PublishError.validation('Photo drafts need TikTok app version 31.8 or newer on your phone', raw: raw, statusCode: status);
    case 'invalid_param':
      return PublishError.validation(msg, raw: raw, statusCode: status);
    case 'internal_error':
      return PublishError.network(msg, raw: raw, statusCode: status, retryAfter: retryAfter);
  }
  if (fallback != null) return fallback;
  if (status >= 500) return PublishError.network(msg, raw: raw, statusCode: status, retryAfter: retryAfter);
  return PublishError.platform(msg, raw: raw, statusCode: status);
}

/// Maps a `status/fetch` `fail_reason` onto a [PublishError].
PublishError mapFailReason(String reason) {
  final msg = 'TikTok could not publish the post ($reason)';
  if (reason == 'auth_removed') {
    return PublishError.auth('TikTok access was removed while publishing; reconnect the account', raw: reason);
  }
  if (reason.startsWith('spam_risk')) return PublishError.quota(msg, raw: reason);
  if (reason == 'internal') return PublishError.network(msg, raw: reason);
  if (reason.endsWith('_check_failed') || reason.endsWith('_pull_failed') || reason.contains('size')) {
    return PublishError.validation(msg, raw: reason);
  }
  return PublishError.platform(msg, raw: reason);
}

/// Classifies transport-level exceptions (after [NeforumHttp] retries).
/// Returns `null` for anything that is not a network problem.
PublishError? networkErrorFor(Object e, String context) {
  if (e is AdapterException) return e.error;
  if (e is HttpFailure) return e.toPublishError(context: context);
  if (e is http.ClientException || e is TimeoutException || isTransientIoError(e)) {
    return PublishError.network('$context: network error ($e)');
  }
  return null;
}

// ---------------------------------------------------------------------------
// FILE_UPLOAD chunking
// ---------------------------------------------------------------------------

/// How a video is split for `source_info.FILE_UPLOAD`.
@immutable
class TikTokChunkPlan {
  const TikTokChunkPlan(this.videoSize, this.chunkSize, this.totalChunkCount);

  final int videoSize;
  final int chunkSize;
  final int totalChunkCount;

  /// Byte range `[start, end)` of chunk [i]. The last chunk absorbs the
  /// remainder (TikTok allows it to be up to 128 MB).
  (int, int) range(int i) {
    final start = i * chunkSize;
    final end = i == totalChunkCount - 1 ? videoSize : start + chunkSize;
    return (start, end);
  }

  Map<String, dynamic> toSourceInfo() => {
        'source': 'FILE_UPLOAD',
        'video_size': videoSize,
        'chunk_size': chunkSize,
        'total_chunk_count': totalChunkCount,
      };
}

/// Single-chunk ceiling. 64,000,000 is below both readings of "64 MB".
const tiktokSingleChunkMax = 64000000;

/// Chunk size for big files: 16 MiB is inside 5-64 MB under either
/// definition of MB, keeps the last chunk below 32 MiB (limit 128 MB) and
/// needs at most 256 chunks for a 4 GiB file (limit 1000).
const tiktokChunkSize = 16 * 1024 * 1024;

/// Media transfer guide: files under 5 MB go in one chunk whose size equals
/// the file; chunks are 5-64 MB; total_chunk_count = floor(size/chunk_size)
/// and the trailing bytes merge into the last chunk.
TikTokChunkPlan planTikTokChunks(int size) {
  if (size <= 0) throw ArgumentError.value(size, 'size', 'empty video');
  if (size <= tiktokSingleChunkMax) return TikTokChunkPlan(size, size, 1);
  return TikTokChunkPlan(size, tiktokChunkSize, size ~/ tiktokChunkSize);
}

/// Maps a failed chunk PUT onto a [PublishError] (media transfer guide).
PublishError chunkUploadError(NeforumResponse res, int index, int total) {
  final raw = _snippet(res.body);
  final where = 'TikTok video upload (chunk ${index + 1} of $total)';
  return switch (res.statusCode) {
    403 => PublishError.platform('$where: the upload link expired (1 hour limit); try again',
        raw: raw, statusCode: 403, retryable: true),
    404 => PublishError.platform('$where: TikTok has no upload task for this link', raw: raw, statusCode: 404),
    416 => PublishError.platform('$where: byte range out of step with TikTok', raw: raw, statusCode: 416),
    400 => PublishError.validation('$where: TikTok rejected the chunk headers', raw: raw, statusCode: 400),
    _ => HttpFailure(res).toPublishError(context: where),
  };
}

String _snippet(String body) => body.length > 600 ? '${body.substring(0, 600)}…' : body;
