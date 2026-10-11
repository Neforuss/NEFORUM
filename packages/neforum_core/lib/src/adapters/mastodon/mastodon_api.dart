import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:mime/mime.dart';

import '../../http/neforum_http.dart';
import '../../model/media.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../platform_adapter.dart';
import 'mastodon_instance.dart';

/// OAuth server metadata (RFC 8414, Mastodon 4.3+), or the classic
/// `/oauth/authorize` + `/oauth/token` defaults when the server has none.
class MastodonOAuthMetadata {
  const MastodonOAuthMetadata({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.revocationEndpoint,
    this.scopesSupported = const {},
    this.pkceS256 = false,
    this.discovered = false,
  });

  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri? revocationEndpoint;
  final Set<String> scopesSupported;
  final bool pkceS256;

  /// True when `/.well-known/oauth-authorization-server` answered.
  final bool discovered;
}

/// The client credentials `POST /api/v1/apps` hands back.
class MastodonClientCredentials {
  const MastodonClientCredentials(this.clientId, this.clientSecret);
  final String clientId;
  final String clientSecret;
}

/// Thin, stateless wrapper over the Mastodon REST endpoints NEFORUM uses.
/// Every call goes through `ctx.http`.
class MastodonApi {
  MastodonApi(
    this.ctx,
    this.base, {
    this.accessToken,
    this.pollInterval = const Duration(seconds: 2),
    this.maxPolls = 90,
  });

  final AdapterContext ctx;

  /// `https://host` of the server.
  final Uri base;
  final String? accessToken;
  final Duration pollInterval;
  final int maxPolls;

  Uri url(String path, [Map<String, String>? query]) =>
      base.replace(path: path, queryParameters: query == null || query.isEmpty ? null : query);

  Map<String, String> get _auth => {
    'Accept': 'application/json',
    if (accessToken != null) 'Authorization': 'Bearer $accessToken',
  };

  // ---------------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------------

  /// `GET /api/v2/instance`, falling back to `/api/v1/instance` (Pleroma,
  /// Akkoma, older Mastodon). Returns `null` when neither answers JSON.
  Future<MastodonInstanceProfile?> fetchInstance() async {
    for (final path in const ['/api/v2/instance', '/api/v1/instance']) {
      final res = await ctx.http.get(url(path), headers: {'Accept': 'application/json'}, throwOnError: false);
      final json = res.json;
      if (res.ok && json is Map) {
        return MastodonInstanceProfile.fromInstanceJson(Map<String, dynamic>.from(json), baseUrl: base.toString());
      }
    }
    return null;
  }

  /// Reads `software.name`/`software.version` from NodeInfo. Only follows
  /// links on the same host. Returns `null` when unavailable.
  Future<(String, String?)?> fetchNodeInfoSoftware() async {
    final res = await ctx.http.get(
      url('/.well-known/nodeinfo'),
      headers: {'Accept': 'application/json'},
      throwOnError: false,
    );
    if (!res.ok) return null;
    final links = res.jsonMap['links'];
    if (links is! List) return null;
    Uri? best;
    var bestRank = -1.0;
    for (final l in links.whereType<Map<Object?, Object?>>()) {
      final rel = l['rel'] as String? ?? '';
      final href = Uri.tryParse(l['href'] as String? ?? '');
      if (href == null || href.host != base.host || !rel.contains('nodeinfo.diaspora.software/ns/schema/')) continue;
      final rank = double.tryParse(rel.split('/').last) ?? 0;
      if (rank > bestRank) {
        bestRank = rank;
        best = href;
      }
    }
    if (best == null) return null;
    final doc = await ctx.http.get(best, headers: {'Accept': 'application/json'}, throwOnError: false);
    if (!doc.ok) return null;
    final sw = doc.jsonMap['software'];
    if (sw is! Map) return null;
    final name = (sw['name'] as String?)?.trim().toLowerCase();
    if (name == null || name.isEmpty) return null;
    return (name, sw['version'] as String?);
  }

  Future<MastodonOAuthMetadata> fetchOAuthMetadata() async {
    final fallback = MastodonOAuthMetadata(
      authorizationEndpoint: url('/oauth/authorize'),
      tokenEndpoint: url('/oauth/token'),
      revocationEndpoint: url('/oauth/revoke'),
    );
    final res = await ctx.http.get(
      url('/.well-known/oauth-authorization-server'),
      headers: {'Accept': 'application/json'},
      throwOnError: false,
    );
    final j = res.jsonMap;
    if (!res.ok || j.isEmpty) return fallback;
    Uri? sameHost(Object? v) {
      final u = v is String ? Uri.tryParse(v) : null;
      return u != null && u.host == base.host && u.scheme == base.scheme ? u : null;
    }

    final methods = (j['code_challenge_methods_supported'] as List? ?? const []).whereType<String>();
    return MastodonOAuthMetadata(
      authorizationEndpoint: sameHost(j['authorization_endpoint']) ?? fallback.authorizationEndpoint,
      tokenEndpoint: sameHost(j['token_endpoint']) ?? fallback.tokenEndpoint,
      revocationEndpoint: sameHost(j['revocation_endpoint']) ?? fallback.revocationEndpoint,
      scopesSupported: (j['scopes_supported'] as List? ?? const []).whereType<String>().toSet(),
      pkceS256: methods.contains('S256'),
      discovered: true,
    );
  }

  // ---------------------------------------------------------------------------
  // OAuth app registration and account
  // ---------------------------------------------------------------------------

  /// `POST /api/v1/apps`. `redirect_uris` is sent as a single string, which
  /// every implementation accepts (arrays only work on Mastodon 4.3+).
  Future<MastodonClientCredentials> registerApp({
    required Uri redirectUri,
    required String scopes,
    String clientName = 'NEFORUM',
    String website = 'https://github.com/neforum-app/neforum',
  }) async {
    final res = await ctx.http.postForm(
      url('/api/v1/apps'),
      {'client_name': clientName, 'redirect_uris': redirectUri.toString(), 'scopes': scopes, 'website': website},
      headers: {'Accept': 'application/json'},
      throwOnError: false,
    );
    final j = res.jsonMap;
    if (!res.ok || j['client_id'] == null || j['client_secret'] == null) throw HttpFailure(res);
    return MastodonClientCredentials('${j['client_id']}', '${j['client_secret']}');
  }

  /// `GET /api/v1/accounts/verify_credentials`.
  Future<Map<String, dynamic>> verifyCredentials() async {
    final res = await ctx.http.get(url('/api/v1/accounts/verify_credentials'), headers: _auth);
    return res.jsonMap;
  }

  /// `POST /oauth/revoke` (best effort).
  Future<void> revoke(
    Uri endpoint, {
    required String clientId,
    required String clientSecret,
    required String token,
  }) async {
    await ctx.http.postForm(
      endpoint,
      {'client_id': clientId, 'client_secret': clientSecret, 'token': token},
      headers: {'Accept': 'application/json'},
      throwOnError: false,
    );
  }

  // ---------------------------------------------------------------------------
  // Media
  // ---------------------------------------------------------------------------

  /// Uploads one file with `POST /api/v2/media` (falling back to the old
  /// synchronous `/api/v1/media` on servers without v2) and waits until the
  /// server has processed it. Returns the attachment id.
  Future<String> uploadMedia(MediaAttachment media, Uint8List bytes, {int? descriptionLimit}) async {
    final alt = _truncate(media.altText?.trim() ?? '', descriptionLimit);
    final fields = <String, String>{if (alt.isNotEmpty) 'description': alt};
    final file = HttpFilePart(
      field: 'file',
      bytes: bytes,
      fileName: media.fileName ?? 'upload.${extensionFromMime(media.mimeType) ?? 'bin'}',
      contentType: media.mimeType,
    );
    var res = await ctx.http.multipart(
      url('/api/v2/media'),
      fields: fields,
      files: [file],
      headers: _auth,
      throwOnError: false,
    );
    if (res.statusCode == 404) {
      res = await ctx.http.multipart(
        url('/api/v1/media'),
        fields: fields,
        files: [file],
        headers: _auth,
        throwOnError: false,
      );
    }
    if (!res.ok) throw HttpFailure(res);
    final j = res.jsonMap;
    final id = j['id'];
    if (id == null) {
      throw AdapterException(
        PublishError.platform('The server accepted the upload but returned no media id', raw: res.body),
      );
    }
    final mediaId = '$id';
    final ready = (j['url'] as String? ?? '').isNotEmpty;
    if (res.statusCode == 202 && !ready) await _waitForProcessing(mediaId, media);
    return mediaId;
  }

  /// Polls `GET /api/v1/media/:id`: 200 = ready, 206 = still processing,
  /// 422 = processing failed.
  Future<void> _waitForProcessing(String id, MediaAttachment media) async {
    for (var i = 0; i < maxPolls; i++) {
      await Future<void>.delayed(pollInterval);
      final res = await ctx.http.get(url('/api/v1/media/$id'), headers: _auth, throwOnError: false);
      if (res.statusCode == 200) return;
      if (res.statusCode == 206) continue;
      if (res.statusCode == 404) {
        // Some servers (Pixelfed) cannot be polled; their media is usable.
        ctx.log.warn('Cannot poll media $id (HTTP 404); assuming it is ready');
        return;
      }
      if (res.statusCode == 422) {
        throw AdapterException(
          PublishError.validation(
            'The server could not process ${media.fileName ?? 'the media file'}: ${errorText(res) ?? 'unknown error'}',
            raw: res.body,
            statusCode: 422,
          ),
        );
      }
      throw HttpFailure(res);
    }
    final secs = (pollInterval * maxPolls).inSeconds;
    throw AdapterException(
      PublishError.network(
        '${media.fileName ?? 'Media'} was still processing on the server after $secs s; try again later',
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Statuses
  // ---------------------------------------------------------------------------

  /// `POST /api/v1/statuses`, form-encoded so that `media_ids[]` repeats
  /// (understood by Mastodon, Pleroma, GoToSocial, Pixelfed and Friendica).
  Future<Map<String, dynamic>> postStatus(List<MapEntry<String, String>> form, {String? idempotencyKey}) async {
    final res = await ctx.http.send(
      'POST',
      url('/api/v1/statuses'),
      headers: {
        ..._auth,
        'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
        if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
      },
      bytes: encodeForm(form),
    );
    return res.jsonMap;
  }

  static Uint8List encodeForm(List<MapEntry<String, String>> pairs) => Uint8List.fromList(
    utf8.encode(pairs.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&')),
  );

  static String _truncate(String s, int? limit) {
    if (limit == null || limit <= 0) return s;
    final c = s.characters;
    return c.length <= limit ? s : c.take(limit).toString();
  }

  // ---------------------------------------------------------------------------
  // Errors
  // ---------------------------------------------------------------------------

  /// The human-readable error a Mastodon-API server put in its body
  /// (`error`, `error_description` or Laravel's `message`).
  static String? errorText(NeforumResponse r) {
    final j = r.jsonMap;
    for (final k in const ['error_description', 'error', 'message']) {
      final v = j[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  /// Refines [HttpFailure.toPublishError] with what Mastodon-API servers
  /// actually return.
  static PublishError mapFailure(HttpFailure f, {DateTime? now, String? context}) {
    final base = f.toPublishError(context: context);
    final r = f.response;
    final text = errorText(r);
    final lower = (text ?? '').toLowerCase();
    final prefix = context == null ? '' : '$context: ';
    final detail = text ?? 'HTTP ${f.statusCode}';
    final raw = base.raw;
    switch (f.statusCode) {
      case 401:
        return PublishError.auth(
          '${prefix}The server rejected the access token ($detail). Reconnect the account.',
          raw: raw,
          statusCode: 401,
        );
      case 403:
        if (lower.contains('empty status')) {
          return PublishError.validation(
            '${prefix}This server (Pixelfed) only accepts posts with at least one image',
            raw: raw,
            statusCode: 403,
          );
        }
        return PublishError.auth(
          '$prefix$detail. The app may lack permission or the account is restricted; try reconnecting.',
          raw: raw,
          statusCode: 403,
        );
      case 429:
        return PublishError.quota(
          '${prefix}Rate limited by ${f.url.host}: $detail',
          raw: raw,
          statusCode: 429,
          retryAfter: r.retryAfter ?? _rateLimitReset(r, now),
        );
      case 422:
        if (lower.contains('scheduled') && (lower.contains('limit') || lower.contains('exceeded'))) {
          return PublishError.quota('$prefix$detail', raw: raw, statusCode: 422);
        }
        return PublishError.validation('$prefix$detail', raw: raw, statusCode: 422);
      case 400:
        if (lower.contains('idempotency')) {
          return PublishError.validation(
            '${prefix}The server says this post was already submitted in the last hour. Check your profile before retrying.',
            raw: raw,
            statusCode: 400,
          );
        }
        return PublishError.validation('$prefix$detail', raw: raw, statusCode: 400);
      case 404:
        return PublishError.platform(
          '$prefix${f.url.path} does not exist on ${f.url.host} ($detail)',
          raw: raw,
          statusCode: 404,
        );
      case 413:
        return PublishError.validation(
          '${prefix}The file is larger than the server accepts',
          raw: raw,
          statusCode: 413,
        );
      default:
        return text == null
            ? base
            : PublishError(
                kind: base.kind,
                message: '$prefix$text',
                retryable: base.retryable,
                statusCode: base.statusCode,
                raw: raw,
                retryAfter: base.retryAfter,
              );
    }
  }

  /// Mastodon sends `X-RateLimit-Reset` as an ISO 8601 timestamp and no
  /// `Retry-After`.
  static Duration? _rateLimitReset(NeforumResponse r, DateTime? now) {
    final reset = DateTime.tryParse(r.headers['x-ratelimit-reset'] ?? '');
    if (reset == null) return null;
    final d = reset.difference(now ?? DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }
}
