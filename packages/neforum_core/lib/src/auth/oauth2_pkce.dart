import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../http/neforum_http.dart';
import 'auth_broker.dart';

/// PKCE verifier/challenge pair (RFC 7636, S256).
@immutable
class PkcePair {
  const PkcePair(this.verifier, this.challenge);

  factory PkcePair.generate([Random? rng]) {
    final r = rng ?? Random.secure();
    final bytes = List<int>.generate(64, (_) => r.nextInt(256));
    final verifier = base64UrlEncode(bytes).replaceAll('=', '');
    final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    return PkcePair(verifier, challenge);
  }

  final String verifier;
  final String challenge;
}

String randomState([int bytes = 24, Random? rng]) {
  final r = rng ?? Random.secure();
  return base64UrlEncode(List<int>.generate(bytes, (_) => r.nextInt(256))).replaceAll('=', '');
}

/// Tokens returned by an OAuth 2.0 token endpoint, plus helpers to stash
/// them in an account's secrets map.
@immutable
class OAuthTokens {
  const OAuthTokens({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.tokenType = 'Bearer',
    this.scope,
    this.raw = const {},
  });

  factory OAuthTokens.fromTokenResponse(Map<String, dynamic> json, {DateTime? now}) {
    final expiresIn = json['expires_in'];
    final secs = expiresIn is int ? expiresIn : int.tryParse('$expiresIn');
    return OAuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      expiresAt: secs == null ? null : (now ?? DateTime.now()).add(Duration(seconds: secs)),
      tokenType: (json['token_type'] as String?) ?? 'Bearer',
      scope: json['scope'] as String?,
      raw: json,
    );
  }

  /// Reads tokens previously stored with [toSecrets]. Returns `null` when
  /// there is no access token.
  static OAuthTokens? fromSecrets(Map<String, String> s) {
    final at = s[keyAccessToken];
    if (at == null || at.isEmpty) return null;
    return OAuthTokens(
      accessToken: at,
      refreshToken: s[keyRefreshToken],
      expiresAt: s[keyExpiresAt] == null ? null : DateTime.tryParse(s[keyExpiresAt]!),
      tokenType: s[keyTokenType] ?? 'Bearer',
      scope: s[keyScope],
    );
  }

  static const keyAccessToken = 'access_token';
  static const keyRefreshToken = 'refresh_token';
  static const keyExpiresAt = 'expires_at';
  static const keyTokenType = 'token_type';
  static const keyScope = 'scope';

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final String tokenType;
  final String? scope;
  final Map<String, dynamic> raw;

  bool isExpired({DateTime? now, Duration leeway = const Duration(minutes: 2)}) =>
      expiresAt != null && (now ?? DateTime.now()).add(leeway).isAfter(expiresAt!);

  Map<String, String> get authorizationHeader => {'Authorization': '$tokenType $accessToken'};

  /// Merges these tokens into [existing] (keeping any other secret keys).
  Map<String, String> toSecrets([Map<String, String> existing = const {}]) => {
        ...existing,
        keyAccessToken: accessToken,
        if (refreshToken != null) keyRefreshToken: refreshToken!,
        if (expiresAt != null) keyExpiresAt: expiresAt!.toUtc().toIso8601String(),
        keyTokenType: tokenType,
        if (scope != null) keyScope: scope!,
      };
}

/// What [OAuth2Client.buildAuthorizationUrl] hands back; keep [state] and
/// [pkce] until the redirect arrives.
@immutable
class AuthorizationRequest {
  const AuthorizationRequest(this.url, this.state, this.pkce);
  final Uri url;
  final String state;
  final PkcePair? pkce;
}

class OAuthException implements Exception {
  const OAuthException(this.message, {this.error, this.description});
  final String message;
  final String? error;
  final String? description;
  @override
  String toString() => 'OAuthException($message${error == null ? '' : ' [$error]'}${description == null ? '' : ': $description'})';
}

/// Generic OAuth 2.0 authorization-code client (with optional PKCE), enough
/// for X, LinkedIn, Reddit, Mastodon, Tumblr, Threads, Pinterest, TikTok,
/// Google, ... Platform quirks are passed in as parameters.
class OAuth2Client {
  const OAuth2Client({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.clientId,
    this.clientSecret,
    this.scopes = const [],
    this.scopeSeparator = ' ',
    this.usePkce = true,
    this.clientAuth = ClientAuth.body,
    this.extraAuthorizationParams = const {},
    this.extraTokenParams = const {},
    this.extraHeaders = const {},
  });

  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final String clientId;
  final String? clientSecret;
  final List<String> scopes;
  final String scopeSeparator;
  final bool usePkce;
  final ClientAuth clientAuth;
  final Map<String, String> extraAuthorizationParams;
  final Map<String, String> extraTokenParams;
  final Map<String, String> extraHeaders;

  AuthorizationRequest buildAuthorizationUrl({required Uri redirectUri, String? state, PkcePair? pkce}) {
    final s = state ?? randomState();
    final p = usePkce ? (pkce ?? PkcePair.generate()) : null;
    final url = authorizationEndpoint.replace(queryParameters: {
      ...authorizationEndpoint.queryParameters,
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri.toString(),
      if (scopes.isNotEmpty) 'scope': scopes.join(scopeSeparator),
      'state': s,
      if (p != null) 'code_challenge': p.challenge,
      if (p != null) 'code_challenge_method': 'S256',
      ...extraAuthorizationParams,
    });
    return AuthorizationRequest(url, s, p);
  }

  /// Validates the redirect against [request] and returns the code.
  String extractCode(Uri redirect, AuthorizationRequest request) {
    final q = {...redirect.queryParameters};
    if (q.isEmpty && redirect.fragment.isNotEmpty) q.addAll(Uri.splitQueryString(redirect.fragment));
    if (q['error'] != null) {
      throw OAuthException('Authorization refused', error: q['error'], description: q['error_description']);
    }
    if (q['state'] != request.state) throw const OAuthException('State mismatch (possible CSRF); try again');
    final code = q['code'];
    if (code == null || code.isEmpty) throw const OAuthException('Redirect carried no authorization code');
    return code;
  }

  Future<OAuthTokens> exchangeCode(
    NeforumHttp http, {
    required String code,
    required Uri redirectUri,
    PkcePair? pkce,
    DateTime? now,
  }) =>
      _token(http, {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri.toString(),
        if (pkce != null) 'code_verifier': pkce.verifier,
        ...extraTokenParams,
      }, now: now);

  Future<OAuthTokens> refresh(NeforumHttp http, {required String refreshToken, DateTime? now}) =>
      _token(http, {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        ...extraTokenParams,
      }, now: now);

  /// Full interactive flow: build URL, send the user through [broker],
  /// verify state, exchange the code.
  Future<OAuthTokens> authorize(NeforumHttp http, AuthBroker broker, {required Uri redirectUri, Duration timeout = const Duration(minutes: 5)}) async {
    final req = buildAuthorizationUrl(redirectUri: redirectUri);
    final back = await broker.authorize(req.url, redirectUri, timeout: timeout);
    final code = extractCode(back, req);
    return exchangeCode(http, code: code, redirectUri: redirectUri, pkce: req.pkce);
  }

  Future<OAuthTokens> _token(NeforumHttp http, Map<String, String> form, {DateTime? now}) async {
    final headers = <String, String>{'Accept': 'application/json', ...extraHeaders};
    final body = {...form};
    switch (clientAuth) {
      case ClientAuth.body:
        body['client_id'] = clientId;
        if (clientSecret != null && clientSecret!.isNotEmpty) body['client_secret'] = clientSecret!;
      case ClientAuth.basic:
        headers['Authorization'] = 'Basic ${base64Encode(utf8.encode('$clientId:${clientSecret ?? ''}'))}';
      case ClientAuth.basicAndBodyClientId:
        headers['Authorization'] = 'Basic ${base64Encode(utf8.encode('$clientId:${clientSecret ?? ''}'))}';
        body['client_id'] = clientId;
    }
    final res = await http.postForm(tokenEndpoint, body, headers: headers, throwOnError: false);
    final json = res.jsonMap;
    if (!res.ok || json['access_token'] == null) {
      throw OAuthException('Token endpoint returned HTTP ${res.statusCode}',
          error: json['error']?.toString(), description: json['error_description']?.toString() ?? (res.body.length > 300 ? res.body.substring(0, 300) : res.body));
    }
    return OAuthTokens.fromTokenResponse(json, now: now);
  }
}

/// How the client authenticates at the token endpoint.
enum ClientAuth {
  /// `client_id` (and `client_secret` if any) in the form body. Public PKCE
  /// clients (Mastodon, Google desktop, Threads, TikTok, Pinterest).
  body,

  /// HTTP Basic `client_id:client_secret`. Reddit installed apps (empty
  /// secret), X when a confidential client is used.
  basic,

  /// Both — X's PKCE public clients want `client_id` in the body AND accept
  /// basic auth for confidential ones; sending both is harmless.
  basicAndBodyClientId,
}
