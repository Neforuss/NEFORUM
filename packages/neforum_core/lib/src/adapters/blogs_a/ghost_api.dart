import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart' show hex;
import 'package:crypto/crypto.dart';

import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'blog_common.dart';

/// Minimum Admin API version NEFORUM speaks (`Accept-Version`).
const String ghostAcceptVersion = 'v5.0';

/// Lifetime of each Admin API token. Ghost allows at most 5 minutes.
const Duration ghostTokenLifetime = Duration(minutes: 5);

/// An Admin API key (`{id}:{secret}`) from a Ghost custom integration.
class GhostAdminKey {
  const GhostAdminKey(this.id, this.secretHex);

  /// Parses `id:secret`. Throws [FormatException] when the shape is wrong.
  factory GhostAdminKey.parse(String raw) {
    final s = raw.trim();
    final i = s.indexOf(':');
    if (i <= 0 || i == s.length - 1) throw const FormatException('expected id:secret');
    final id = s.substring(0, i);
    final secret = s.substring(i + 1).toLowerCase();
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(id) || !RegExp(r'^[0-9a-f]+$').hasMatch(secret) || secret.length.isOdd) {
      throw const FormatException('id and secret must be hexadecimal');
    }
    return GhostAdminKey(id, secret);
  }

  /// The `kid` header value.
  final String id;

  /// The secret as hex; it is hex-decoded before signing.
  final String secretHex;

  /// Mints the short-lived HS256 JWT Ghost expects in
  /// `Authorization: Ghost <token>`: header `{alg, kid, typ}`, payload
  /// `{iat, exp, aud: '/admin/'}` with exp = iat + 5 minutes, signed with the
  /// hex-decoded secret.
  String token(DateTime now) {
    final iat = now.toUtc().millisecondsSinceEpoch ~/ 1000;
    final header = {'alg': 'HS256', 'kid': id, 'typ': 'JWT'};
    final payload = {'iat': iat, 'exp': iat + ghostTokenLifetime.inSeconds, 'aud': '/admin/'};
    final signingInput = '${_b64(utf8.encode(jsonEncode(header)))}.${_b64(utf8.encode(jsonEncode(payload)))}';
    final key = Uint8List.fromList(hex.decode(secretHex));
    final sig = Hmac(sha256, key).convert(ascii.encode(signingInput)).bytes;
    return '$signingInput.${_b64(sig)}';
  }

  static String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
}

/// Thin client for the Ghost Admin API at `{apiUrl}/ghost/api/admin/`.
class GhostApi {
  GhostApi(this.apiUrl, this.ctx, {this.key});

  /// The integration's "API URL" (the admin domain, maybe with a subfolder).
  final Uri apiUrl;
  final AdapterContext ctx;
  final GhostAdminKey? key;

  Uri endpoint(String path, [Map<String, String>? query]) => joinPath(apiUrl, '/ghost/api/admin/$path', query);

  Map<String, String> get _headers => {
        'Accept-Version': ghostAcceptVersion,
        'Accept': 'application/json',
        if (key != null) 'Authorization': 'Ghost ${key!.token(ctx.now())}',
      };

  Future<NeforumResponse> get(String path, [Map<String, String>? query]) =>
      ctx.http.get(endpoint(path, query), headers: _headers);

  Future<NeforumResponse> postJson(String path, Object body, [Map<String, String>? query]) =>
      ctx.http.postJson(endpoint(path, query), body, headers: _headers);

  /// `POST images/upload/` (multipart `file`, `purpose=image`, `ref`).
  Future<NeforumResponse> uploadImage(Uint8List bytes, {required String fileName, required String contentType}) =>
      ctx.http.multipart(endpoint('images/upload/'),
          headers: _headers,
          fields: {'purpose': 'image', 'ref': fileName},
          files: [HttpFilePart(field: 'file', bytes: bytes, fileName: fileName, contentType: contentType)]);
}

/// `(type, message, context)` of the first entry in Ghost's `errors` array.
(String, String?, String?) ghostErrorOf(NeforumResponse r) {
  final first = blogMap(blogList(r.jsonMap['errors']).firstOrNull);
  if (first == null) return ('', null, null);
  return (
    blogStr(first['type']) ?? blogStr(first['errorType']) ?? '',
    blogStr(first['message']),
    blogStr(first['context']),
  );
}

/// Maps a Ghost Admin API failure onto a [PublishError].
PublishError mapGhostFailure(HttpFailure f, String what) {
  final (type, message, context) = ghostErrorOf(f.response);
  final detail = [?message, ?context].join(' ');
  final suffix = detail.isEmpty ? '' : ': $detail';
  final raw = bodySnippet(f.response);
  final status = f.statusCode;
  if (status == 429 || type == 'TooManyRequestsError') {
    return PublishError.quota('$what: Ghost is rate limiting requests$suffix',
        raw: raw, statusCode: status, retryAfter: f.response.retryAfter);
  }
  if (status == 401 || type == 'UnauthorizedError' || type == 'TokenExpiredError') {
    final lower = detail.toLowerCase();
    final clock = lower.contains('token') || lower.contains('jwt')
        ? ' Make sure this device\'s clock is correct.'
        : '';
    return PublishError.auth('$what: Ghost rejected the Admin API key$suffix.$clock '
        'If you deleted or regenerated the integration key, reconnect with the new one.', raw: raw, statusCode: status);
  }
  if (status == 403 || type == 'NoPermissionError') {
    return PublishError.auth('$what: this Admin API key is not allowed to do that$suffix', raw: raw, statusCode: status);
  }
  if (status == 404 || type == 'NotFoundError') {
    return PublishError.configuration('$what: ${f.url.host} has no Ghost Admin API at ${f.url.path}$suffix. '
        'Reconnect with the API URL shown on the integration page.');
  }
  if (status == 413 || type == 'RequestEntityTooLargeError') {
    return PublishError.validation('$what: the file is too large for this Ghost site$suffix', raw: raw, statusCode: status);
  }
  if (status == 415 || status == 422 || status == 400 || type == 'ValidationError' || type == 'UnsupportedMediaTypeError') {
    return PublishError.validation('$what$suffix', raw: raw, statusCode: status);
  }
  return f.toPublishError(context: '$what$suffix');
}

/// Runs [call] and converts HTTP/network failures into [AdapterException].
Future<T> guardGhost<T>(String what, Future<T> Function() call) async {
  try {
    return await call();
  } on AdapterException {
    rethrow;
  } on HttpFailure catch (f) {
    throw AdapterException(mapGhostFailure(f, what));
  } on Exception catch (e) {
    throw AdapterException(PublishError.network('$what failed: $e', raw: '$e'));
  }
}

/// Turns a bad key into a user-facing [ConnectException].
GhostAdminKey parseGhostKeyForConnect(String raw) {
  try {
    return GhostAdminKey.parse(raw);
  } on FormatException {
    throw const ConnectException('That is not a Ghost Admin API key. Copy the "Admin API key" (it looks like '
        '`64f0…:a1b2…` with a colon in the middle) from Settings > Integrations > your custom integration.',
        field: 'adminKey');
  }
}
