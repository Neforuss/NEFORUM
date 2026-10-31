import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../platform_adapter.dart';

/// Default entryway for accounts hosted by Bluesky itself.
final Uri blueskyDefaultService = Uri.parse('https://bsky.social');

/// Bluesky's video processing service (not the user's PDS).
final Uri blueskyVideoService = Uri.parse('https://video.bsky.app');

/// Lexicon limits (verified against the atproto lexicons, Oct 2026).
const int blueskyImageMaxBytes = 2000000;
const int blueskyThumbMaxBytes = 1000000;
const int blueskyVideoMaxBytes = 300000000;
const int blueskyTextMaxBytes = 3000;

/// A session as returned by `com.atproto.server.createSession` /
/// `refreshSession`.
class BlueskySession {
  const BlueskySession({
    required this.accessJwt,
    required this.refreshJwt,
    required this.did,
    required this.handle,
    this.pds,
    this.active,
    this.status,
  });

  /// Parses a session response. Throws [FormatException] when the required
  /// fields are missing.
  factory BlueskySession.fromJson(Map<String, dynamic> json) {
    final access = json['accessJwt'];
    final refresh = json['refreshJwt'];
    final did = json['did'];
    final handle = json['handle'];
    if (access is! String || refresh is! String || did is! String) {
      throw const FormatException('Session response is missing accessJwt/refreshJwt/did');
    }
    final active = json['active'];
    final status = json['status'];
    return BlueskySession(
      accessJwt: access,
      refreshJwt: refresh,
      did: did,
      handle: handle is String ? handle : did,
      pds: pdsFromDidDoc(json['didDoc']),
      active: active is bool ? active : null,
      status: status is String ? status : null,
    );
  }

  final String accessJwt;
  final String refreshJwt;
  final String did;
  final String handle;

  /// PDS endpoint from the DID document's `#atproto_pds` service entry.
  final Uri? pds;
  final bool? active;
  final String? status;
}

/// Finds the `#atproto_pds` service endpoint in a DID document.
Uri? pdsFromDidDoc(Object? doc) {
  if (doc is! Map) return null;
  final services = doc['service'];
  if (services is! List) return null;
  for (final s in services) {
    if (s is! Map) continue;
    final id = s['id'];
    final endpoint = s['serviceEndpoint'];
    if (id is String && id.endsWith('#atproto_pds') && endpoint is String) {
      final uri = Uri.tryParse(endpoint);
      if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty) return uri;
    }
  }
  return null;
}

/// Reads the `exp` claim of a JWT without verifying it (we only need to know
/// when to refresh). Returns `null` when the token is not a readable JWT.
DateTime? jwtExpiry(String jwt) {
  final parts = jwt.split('.');
  if (parts.length < 2) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    if (payload is! Map) return null;
    final exp = payload['exp'];
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch((exp * 1000).round(), isUtc: true);
  } on FormatException {
    return null;
  }
}

/// Error codes that mean the session is no longer usable.
const Set<String> _authErrors = {
  'ExpiredToken',
  'InvalidToken',
  'AuthenticationRequired',
  'AuthMissing',
  'AccountTakedown',
  'AccountDeactivated',
  'AuthFactorTokenRequired',
};

/// The XRPC `error` code of a failed response, if any.
String? xrpcErrorCode(NeforumResponse r) {
  final e = r.jsonMap['error'];
  return e is String ? e : null;
}

String? _xrpcMessage(NeforumResponse r) {
  final m = r.jsonMap['message'];
  return m is String && m.isNotEmpty ? m : null;
}

/// Time until the `ratelimit-reset` header (unix seconds), if present.
Duration? rateLimitResetIn(NeforumResponse r, DateTime now) {
  final explicit = r.retryAfter;
  if (explicit != null) return explicit;
  final reset = int.tryParse(r.headers['ratelimit-reset']?.trim() ?? '');
  if (reset == null) return null;
  final at = DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true);
  final d = at.difference(now.toUtc());
  return d.isNegative ? Duration.zero : d;
}

/// Maps an XRPC failure onto a [PublishError], using Bluesky's error codes
/// (`ExpiredToken` arrives as HTTP 400 but means "reconnect", etc.).
PublishError mapBlueskyFailure(HttpFailure f, {required DateTime now, String context = 'Bluesky'}) {
  final r = f.response;
  final code = xrpcErrorCode(r);
  final message = _xrpcMessage(r);
  final detail = [?code, ?message].join(': ');
  final text = detail.isEmpty ? 'HTTP ${r.statusCode}' : detail;
  final raw = r.body.length > 600 ? '${r.body.substring(0, 600)}…' : r.body;
  if (r.statusCode == 429 || code == 'RateLimitExceeded') {
    return PublishError.quota('$context rate limit reached ($text)',
        raw: raw, statusCode: r.statusCode, retryAfter: rateLimitResetIn(r, now));
  }
  if (code != null && _authErrors.contains(code)) {
    return PublishError.auth('$context sign-in is no longer valid ($text); reconnect the account', raw: raw, statusCode: r.statusCode);
  }
  if (code == 'BlobTooLarge' || code == 'PayloadTooLarge' || r.statusCode == 413) {
    return PublishError.validation('$context rejected a file as too large ($text)', raw: raw, statusCode: r.statusCode);
  }
  if (code == 'InvalidRequest' || code == 'InvalidMimeType' || code == 'InvalidSwap') {
    return PublishError.validation('$context rejected the post ($text)', raw: raw, statusCode: r.statusCode);
  }
  final base = f.toPublishError(context: context);
  return PublishError(
    kind: base.kind,
    message: detail.isEmpty ? base.message : '$context: $text (HTTP ${r.statusCode})',
    retryable: base.retryable,
    statusCode: base.statusCode,
    raw: raw,
    retryAfter: base.retryAfter,
  );
}

/// A strong reference to a record (`com.atproto.repo.strongRef`).
class StrongRef {
  const StrongRef(this.uri, this.cid);
  final String uri;
  final String cid;

  /// The record key: the last path segment of the `at://` URI.
  String get rkey => uri.split('/').last;
  Map<String, String> toJson() => {'uri': uri, 'cid': cid};
}

/// Link-card metadata scraped from a page's OpenGraph / HTML tags.
class LinkPreview {
  const LinkPreview({required this.uri, required this.title, required this.description, this.image});
  final String uri;
  final String title;
  final String description;
  final Uri? image;
}

/// Thin XRPC client for one call. Holds no state beyond the arguments.
class BlueskyApi {
  BlueskyApi(this.ctx, {required this.pds, this.accessJwt});

  final AdapterContext ctx;

  /// Where repo calls go (the account's PDS).
  final Uri pds;
  final String? accessJwt;

  static Uri xrpc(Uri host, String nsid, [Map<String, String>? query]) {
    final u = host.resolve('/xrpc/$nsid');
    return (query == null || query.isEmpty) ? u : u.replace(queryParameters: query);
  }

  Map<String, String> get _auth => {if (accessJwt != null) 'Authorization': 'Bearer $accessJwt'};

  // --- sessions --------------------------------------------------------

  static Future<BlueskySession> createSession(AdapterContext ctx, Uri service,
      {required String identifier, required String password}) async {
    final r = await ctx.http.postJson(xrpc(service, 'com.atproto.server.createSession'),
        {'identifier': identifier, 'password': password});
    return BlueskySession.fromJson(r.jsonMap);
  }

  static Future<BlueskySession> refreshSession(AdapterContext ctx, Uri service, String refreshJwt) async {
    final r = await ctx.http.send('POST', xrpc(service, 'com.atproto.server.refreshSession'),
        headers: {'Authorization': 'Bearer $refreshJwt'});
    return BlueskySession.fromJson(r.jsonMap);
  }

  /// Best-effort profile lookup (display name, avatar). Never throws.
  Future<Map<String, dynamic>> getProfile(String actor) async {
    try {
      final r = await ctx.http.get(xrpc(pds, 'app.bsky.actor.getProfile', {'actor': actor}),
          headers: _auth, throwOnError: false);
      return r.ok ? r.jsonMap : const {};
    } on Exception catch (e) {
      ctx.log.debug('getProfile failed: $e');
      return const {};
    }
  }

  /// Resolves a handle to a DID, or `null` when it does not resolve.
  Future<String?> resolveHandle(String handle) async {
    try {
      final r = await ctx.http.get(xrpc(pds, 'com.atproto.identity.resolveHandle', {'handle': handle}),
          headers: _auth, throwOnError: false);
      if (!r.ok) return null;
      final did = r.jsonMap['did'];
      return did is String && did.startsWith('did:') ? did : null;
    } on Exception catch (e) {
      ctx.log.debug('resolveHandle($handle) failed: $e');
      return null;
    }
  }

  // --- repo ------------------------------------------------------------

  /// Uploads raw bytes and returns the blob object to embed.
  Future<Map<String, dynamic>> uploadBlob(Uint8List bytes, String mimeType) async {
    final r = await ctx.http.putBytes(xrpc(pds, 'com.atproto.repo.uploadBlob'), bytes,
        method: 'POST', headers: {..._auth, 'Content-Type': mimeType});
    final blob = r.jsonMap['blob'];
    if (blob is! Map) {
      throw const AdapterException(PublishError.platform('Bluesky uploadBlob returned no blob'));
    }
    return Map<String, dynamic>.from(blob);
  }

  Future<StrongRef> createPost(String repo, Map<String, dynamic> record) async {
    final r = await ctx.http.postJson(xrpc(pds, 'com.atproto.repo.createRecord'), {
      'repo': repo,
      'collection': 'app.bsky.feed.post',
      'record': record,
    }, headers: _auth);
    final j = r.jsonMap;
    final uri = j['uri'];
    final cid = j['cid'];
    if (uri is! String || cid is! String) {
      throw const AdapterException(PublishError.platform('Bluesky createRecord returned no uri/cid'));
    }
    return StrongRef(uri, cid);
  }

  /// The strong reference (uri and cid) of the post at [uri]
  /// (`com.atproto.repo.getRecord`), to reply to a post made earlier.
  Future<StrongRef> getPostRef(String uri) async {
    final path = uri.replaceFirst('at://', '').split('/');
    if (path.length != 3) throw AdapterException(PublishError.platform('Not a Bluesky post address: $uri'));
    final r = await ctx.http.get(
        xrpc(pds, 'com.atproto.repo.getRecord', {'repo': path[0], 'collection': path[1], 'rkey': path[2]}),
        headers: _auth);
    final j = r.jsonMap;
    final cid = j['cid'];
    if (cid is! String) throw AdapterException(PublishError.platform('Bluesky returned no cid for $uri'));
    return StrongRef(j['uri'] is String ? j['uri'] as String : uri, cid);
  }

  Future<void> deleteSession(Uri service, String refreshJwt) async {
    await ctx.http.send('POST', xrpc(service, 'com.atproto.server.deleteSession'),
        headers: {'Authorization': 'Bearer $refreshJwt'}, throwOnError: false);
  }

  // --- video -----------------------------------------------------------

  /// Mints a short-lived service token (`com.atproto.server.getServiceAuth`).
  Future<String> getServiceAuth({required String aud, required String lxm, required DateTime expires}) async {
    final r = await ctx.http.get(
        xrpc(pds, 'com.atproto.server.getServiceAuth', {
          'aud': aud,
          'lxm': lxm,
          'exp': '${expires.millisecondsSinceEpoch ~/ 1000}',
        }),
        headers: _auth);
    final token = r.jsonMap['token'];
    if (token is! String) {
      throw const AdapterException(PublishError.platform('Bluesky getServiceAuth returned no token'));
    }
    return token;
  }

  /// Uploads a video to video.bsky.app, waits for processing and returns the
  /// blob to embed. Follows the official video tutorial: service token with
  /// `aud=did:web:<PDS host>` and `lxm=com.atproto.repo.uploadBlob`, then
  /// unauthenticated `getJobStatus` polling.
  Future<Map<String, dynamic>> uploadVideo({
    required String did,
    required String name,
    required Uint8List bytes,
    required Duration pollInterval,
    required Duration maxWait,
  }) async {
    final token = await getServiceAuth(
      aud: 'did:web:${pds.host}',
      lxm: 'com.atproto.repo.uploadBlob',
      expires: ctx.now().toUtc().add(const Duration(minutes: 30)),
    );
    final r = await ctx.http.putBytes(
      xrpc(blueskyVideoService, 'app.bsky.video.uploadVideo', {'did': did, 'name': name}),
      bytes,
      method: 'POST',
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'video/mp4'},
      throwOnError: false,
    );
    var status = _jobStatus(r.jsonMap);
    final early = _blobOf(status);
    if (early != null) return early;
    final jobId = status['jobId'];
    if (jobId is! String) {
      if (!r.ok) throw AdapterException(_videoUploadError(r));
      throw AdapterException(PublishError.platform('Bluesky video service returned no job id', raw: r.body));
    }
    final deadline = ctx.now().add(maxWait);
    var lastProgress = -1;
    while (true) {
      final blob = _blobOf(status);
      if (blob != null) return blob;
      final state = status['state'];
      if (state == 'JOB_STATE_FAILED') {
        final why = status['message'] ?? status['error'] ?? 'unknown reason';
        throw AdapterException(PublishError.validation('Bluesky could not process the video: $why'));
      }
      if (ctx.now().isAfter(deadline)) {
        throw const AdapterException(PublishError.network('Bluesky is still processing the video; try again later'));
      }
      final progress = status['progress'];
      if (progress is int && progress != lastProgress) {
        lastProgress = progress;
        ctx.progress('Bluesky is processing the video ($progress%)');
      }
      await Future<void>.delayed(pollInterval);
      final s = await ctx.http.get(xrpc(blueskyVideoService, 'app.bsky.video.getJobStatus', {'jobId': jobId}),
          throwOnError: false);
      if (!s.ok && _blobOf(_jobStatus(s.jsonMap)) == null) {
        // `already_exists` comes back as an error that still carries the blob.
        throw AdapterException(mapBlueskyFailure(HttpFailure(s), now: ctx.now(), context: 'Bluesky video'));
      }
      status = _jobStatus(s.jsonMap);
    }
  }

  PublishError _videoUploadError(NeforumResponse r) {
    final err = mapBlueskyFailure(HttpFailure(r), now: ctx.now(), context: 'Bluesky video upload');
    final msg = '${_xrpcMessage(r) ?? ''} ${xrpcErrorCode(r) ?? ''}'.toLowerCase();
    if (msg.contains('email')) {
      return const PublishError.configuration(
          'Bluesky only accepts video from accounts with a verified email address. Verify it in Bluesky > Settings > Account, then try again.');
    }
    if (msg.contains('limit') && err.kind != PublishErrorKind.quota) {
      return PublishError.quota('Bluesky daily video upload limit reached: ${_xrpcMessage(r) ?? 'try again tomorrow'}',
          statusCode: r.statusCode, raw: r.body);
    }
    return err;
  }

  static Map<String, dynamic> _jobStatus(Map<String, dynamic> body) {
    final js = body['jobStatus'];
    return js is Map ? Map<String, dynamic>.from(js) : body;
  }

  static Map<String, dynamic>? _blobOf(Map<String, dynamic> status) {
    final b = status['blob'];
    return b is Map ? Map<String, dynamic>.from(b) : null;
  }

  // --- link cards --------------------------------------------------------

  /// Fetches [url] and reads its title/description/image. Returns `null`
  /// when the page cannot be read. Never throws.
  Future<LinkPreview?> fetchLinkPreview(Uri url) async {
    try {
      final r = await ctx.http.get(url, headers: {'Accept': 'text/html,application/xhtml+xml'}, throwOnError: false);
      if (!r.ok) return null;
      final ct = r.headers['content-type'] ?? 'text/html';
      if (!ct.contains('html')) return null;
      return parseLinkPreview(url, r.body);
    } on Exception catch (e) {
      ctx.log.debug('Link preview for $url failed: $e');
      return null;
    }
  }

  /// Downloads a card thumbnail and uploads it as a blob when it fits the
  /// 1,000,000-byte thumb limit. Returns `null` otherwise. Never throws for
  /// remote problems.
  Future<Map<String, dynamic>?> uploadThumb(Uri image) async {
    NeforumResponse r;
    try {
      r = await ctx.http.get(image, throwOnError: false);
    } on Exception catch (e) {
      ctx.log.debug('Thumbnail download failed: $e');
      return null;
    }
    final mime = (r.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
    if (!r.ok || !mime.startsWith('image/')) return null;
    if (r.bodyBytes.length > blueskyThumbMaxBytes) {
      ctx.log.info('Link-card image is ${r.bodyBytes.length} bytes (> $blueskyThumbMaxBytes); posting the card without it');
      return null;
    }
    return uploadBlob(r.bodyBytes, mime);
  }
}

/// Extracts OpenGraph / Twitter-card / `<title>` metadata from HTML.
LinkPreview? parseLinkPreview(Uri pageUrl, String html) {
  final meta = <String, String>{};
  for (final m in RegExp(r'<meta\s[^>]*>', caseSensitive: false).allMatches(html)) {
    final attrs = <String, String>{};
    for (final a in RegExp(r'''([a-zA-Z:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''').allMatches(m.group(0)!)) {
      attrs[a.group(1)!.toLowerCase()] = a.group(2) ?? a.group(3) ?? '';
    }
    final key = (attrs['property'] ?? attrs['name'])?.toLowerCase();
    final content = attrs['content'];
    if (key != null && content != null) meta.putIfAbsent(key, () => _decodeEntities(content).trim());
  }
  final titleTag = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(html)?.group(1);
  final title = meta['og:title'] ?? meta['twitter:title'] ?? (titleTag == null ? null : _decodeEntities(titleTag).trim());
  final description = meta['og:description'] ?? meta['twitter:description'] ?? meta['description'] ?? '';
  if ((title == null || title.isEmpty) && description.isEmpty) return null;
  final imageRaw = meta['og:image'] ?? meta['og:image:url'] ?? meta['twitter:image'];
  Uri? image;
  if (imageRaw != null && imageRaw.isNotEmpty) {
    final resolved = Uri.tryParse(imageRaw);
    if (resolved != null) {
      image = pageUrl.resolveUri(resolved);
      if (image.scheme != 'https' && image.scheme != 'http') image = null;
    }
  }
  return LinkPreview(
    uri: pageUrl.toString(),
    title: _clip(title ?? '', 300),
    description: _clip(description, 1000),
    image: image,
  );
}

String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max - 1)}…';

String _decodeEntities(String s) => s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos|nbsp|#39);'), (m) {
      final e = m.group(1)!;
      switch (e) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
        case '#39':
          return "'";
        case 'nbsp':
          return ' ';
      }
      final code = e.startsWith('#x') ? int.tryParse(e.substring(2), radix: 16) : int.tryParse(e.substring(1));
      return (code == null || code > 0x10FFFF) ? m.group(0)! : String.fromCharCode(code);
    });
