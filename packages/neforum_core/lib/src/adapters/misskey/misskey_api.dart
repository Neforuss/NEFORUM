import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';

/// Upload timeout for Drive files. Videos on big instances can be hundreds
/// of megabytes, far beyond the default 60 s request timeout.
const Duration _uploadTimeout = Duration(minutes: 10);

/// Normalises what the user typed ("misskey.io", "https://misskey.io/notes/x",
/// "@alice@misskey.io") into the instance origin (`https://misskey.io`).
///
/// Throws [ConnectException] when nothing usable is left.
Uri parseMisskeyInstance(String raw) {
  var s = raw.trim();
  if (s.isEmpty) throw const ConnectException('Enter your instance, e.g. misskey.io', field: 'instance');
  // "@user@host" or "user@host" -> host.
  final acct = RegExp(r'^@?[A-Za-z0-9_.-]+@([A-Za-z0-9.-]+(?::\d+)?)$').firstMatch(s);
  if (acct != null) s = acct.group(1)!;
  if (!s.contains('://')) s = 'https://$s';
  final uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty || (uri.scheme != 'https' && uri.scheme != 'http')) {
    throw ConnectException('"$raw" is not a valid instance address', field: 'instance');
  }
  final local = uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host.endsWith('.localhost') || uri.host.endsWith('.test');
  if (!uri.host.contains('.') && !local) {
    throw ConnectException('"$raw" is not a valid instance address', field: 'instance');
  }
  if (uri.scheme == 'http' && !local) {
    throw const ConnectException('Use an https:// address for your instance', field: 'instance');
  }
  return Uri(scheme: uri.scheme, host: uri.host.toLowerCase(), port: uri.hasPort ? uri.port : null);
}

/// A parsed Misskey error body: `{"error": {"message", "code", "id", "kind", "info"}}`.
class MisskeyApiError {
  const MisskeyApiError({this.code, this.message, this.id, this.kind, this.info = const {}});

  static MisskeyApiError? fromResponse(NeforumResponse r) {
    final err = r.jsonMap['error'];
    if (err is! Map) return null;
    final info = err['info'];
    return MisskeyApiError(
      code: err['code'] is String ? err['code'] as String : null,
      message: err['message'] is String ? err['message'] as String : null,
      id: err['id'] is String ? err['id'] as String : null,
      kind: err['kind'] is String ? err['kind'] as String : null,
      info: info is Map ? Map<String, dynamic>.from(info) : const {},
    );
  }

  final String? code;
  final String? message;
  final String? id;
  final String? kind;
  final Map<String, dynamic> info;
}

/// Error codes that mean "the post or file itself is not acceptable".
const Set<String> _validationCodes = {
  'INVALID_PARAM',
  'MAX_FILE_SIZE_EXCEEDED',
  'NO_FREE_SPACE',
  'UNALLOWED_FILE_TYPE',
  'INAPPROPRIATE',
  'INVALID_FILE_NAME',
  'NO_SUCH_FILE',
  'CONTAINS_PROHIBITED_WORDS',
  'CONTAINS_TOO_MANY_MENTIONS',
  'NO_SUCH_REPLY_TARGET',
  'NO_SUCH_RENOTE_TARGET',
  'NO_SUCH_CHANNEL',
  'CANNOT_REPLY_TO_AN_INVISIBLE_NOTE',
  'CANNOT_REPLY_TO_A_PURE_RENOTE',
  'CANNOT_REPLY_TO_SPECIFIED_VISIBILITY_NOTE_WITH_EXTENDED_VISIBILITY',
  'CANNOT_RENOTE_DUE_TO_VISIBILITY',
  'CANNOT_RENOTE_TO_A_PURE_RENOTE',
  'CANNOT_RENOTE_OUTSIDE_OF_CHANNEL',
  'CANNOT_CREATE_ALREADY_EXPIRED_POLL',
};

/// Error codes where reconnecting will not help and retrying is pointless.
const Set<String> _accountCodes = {
  'YOUR_ACCOUNT_SUSPENDED',
  'YOUR_ACCOUNT_MOVED',
  'ROLE_PERMISSION_DENIED',
  'YOU_HAVE_BEEN_BLOCKED',
  'USER_IS_DELETED',
};

/// Friendlier wording for the codes users actually hit.
String? _friendly(String code) => switch (code) {
      'MAX_FILE_SIZE_EXCEEDED' => 'The file is larger than your instance allows',
      'NO_FREE_SPACE' => 'Your Drive on this instance is full; delete some files and try again',
      'UNALLOWED_FILE_TYPE' => 'Your instance does not accept this file type',
      'INAPPROPRIATE' => 'Your instance flagged the file as inappropriate',
      'CONTAINS_PROHIBITED_WORDS' => 'Your instance rejected the note because it contains a prohibited word',
      'CONTAINS_TOO_MANY_MENTIONS' => 'The note mentions more people than your instance allows',
      'PERMISSION_DENIED' =>
        'The access token lacks a permission. Generate a new token with write:notes, write:drive and read:account and reconnect',
      'AUTHENTICATION_FAILED' => 'The access token was rejected (revoked or mistyped). Reconnect the account',
      'CREDENTIAL_REQUIRED' => 'No access token was sent. Reconnect the account',
      'YOUR_ACCOUNT_SUSPENDED' => 'Your account on this instance is suspended',
      'YOUR_ACCOUNT_MOVED' => 'This account has moved to another server and can no longer post',
      'RATE_LIMIT_EXCEEDED' => 'Rate limit reached on this instance',
      _ => null,
    };

/// Maps a failed Misskey API call onto a [PublishError].
PublishError misskeyPublishError(HttpFailure f, {required String context, DateTime? now}) {
  final r = f.response;
  final base = f.toPublishError(context: context);
  final err = MisskeyApiError.fromResponse(r);
  final code = err?.code;
  final raw = base.raw;
  final serverMsg = err?.message;
  String msg(String fallback) {
    final friendly = code == null ? null : _friendly(code);
    final detail = serverMsg != null && serverMsg != friendly ? ' ($serverMsg)' : '';
    return '$context: ${friendly ?? fallback}$detail';
  }

  if (code == 'RATE_LIMIT_EXCEEDED' || r.statusCode == 429) {
    return PublishError.quota(msg('rate limited'),
        raw: raw, statusCode: r.statusCode, retryAfter: r.retryAfter ?? _resetFromInfo(err?.info, now));
  }
  if (code == 'AUTHENTICATION_FAILED' || code == 'CREDENTIAL_REQUIRED' || code == 'PERMISSION_DENIED' || r.statusCode == 401) {
    return PublishError.auth(msg('the access token was rejected; reconnect the account'), raw: raw, statusCode: r.statusCode);
  }
  if (code != null && _accountCodes.contains(code)) {
    return PublishError.platform(msg(code), raw: raw, statusCode: r.statusCode);
  }
  if (code != null && _validationCodes.contains(code)) {
    return PublishError.validation(msg(code), raw: raw, statusCode: r.statusCode);
  }
  if (r.statusCode == 413) {
    return PublishError.validation('$context: the file is larger than this instance accepts', raw: raw, statusCode: 413);
  }
  if (r.statusCode == 404 && code == null) {
    return PublishError.platform('$context: endpoint not found; is this really a Misskey-API server (Misskey, Sharkey, Firefish)?',
        raw: raw, statusCode: 404);
  }
  if (err != null && err.kind == 'client' && r.statusCode < 500) {
    return PublishError.validation(msg('HTTP ${r.statusCode}'), raw: raw, statusCode: r.statusCode);
  }
  if (serverMsg != null && r.statusCode < 500 && base.kind != PublishErrorKind.auth) {
    return PublishError(kind: base.kind, message: msg(base.message), raw: raw, statusCode: r.statusCode, retryable: base.retryable);
  }
  return base;
}

Duration? _resetFromInfo(Map<String, dynamic>? info, DateTime? now) {
  final reset = info?['resetMs'];
  if (reset is! num) return null;
  final at = DateTime.fromMillisecondsSinceEpoch(reset.toInt(), isUtc: true);
  final d = at.difference((now ?? DateTime.now()).toUtc());
  return d.isNegative ? Duration.zero : Duration(seconds: (d.inMilliseconds / 1000).ceil());
}

/// Thin client for one Misskey-API instance. Every endpoint is
/// `POST {instance}/api/{endpoint}` with a JSON body; the token travels in the
/// body as `i` (works on every Misskey generation, including Firefish and
/// Iceshrimp-JS which predate the Bearer header support).
class MisskeyApi {
  MisskeyApi(this.instance, this.ctx, {this.token});

  final Uri instance;
  final AdapterContext ctx;
  final String? token;

  Uri endpoint(String name) => instance.replace(path: '/api/$name');

  /// Calls an endpoint and returns the decoded JSON (a map, list or null).
  /// Throws [HttpFailure] on non-2xx.
  Future<Object?> call(String name, [Map<String, Object?> body = const {}]) async {
    final r = await ctx.http.postJson(endpoint(name), {
      ...body,
      if (token != null) 'i': token,
    });
    return r.json as Object?;
  }

  Future<Map<String, dynamic>> callMap(String name, [Map<String, Object?> body = const {}]) async {
    final j = await call(name, body);
    return j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};
  }

  /// `POST /api/drive/files/create` (multipart). Text fields go first: the
  /// server only sees fields that precede the file part.
  Future<Map<String, dynamic>> uploadDriveFile({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
    String? comment,
    bool isSensitive = false,
  }) async {
    final r = await ctx.http.send(
      'POST',
      endpoint('drive/files/create'),
      fields: {
        if (token != null) 'i': token!,
        'name': fileName,
        if (comment != null && comment.isNotEmpty) 'comment': comment,
        'isSensitive': isSensitive ? 'true' : 'false',
        // With force=false Misskey returns an existing identical Drive file
        // and silently drops the new alt text / sensitive flag.
        'force': 'true',
      },
      files: [HttpFilePart(field: 'file', bytes: bytes, fileName: fileName, contentType: contentType)],
      timeout: _uploadTimeout,
    );
    return r.jsonMap;
  }

  /// `POST /api/miauth/{session}/check` - no auth, returns the token once.
  Future<Map<String, dynamic>> miauthCheck(String session) async {
    final r = await ctx.http.postJson(instance.replace(path: '/api/miauth/$session/check'), const <String, Object?>{});
    return r.jsonMap;
  }
}

/// Runs [body] and turns every expected failure into an [AdapterException].
Future<T> guardMisskey<T>(String context, AdapterContext ctx, Future<T> Function() body) async {
  try {
    return await body();
  } on AdapterException {
    rethrow;
  } on HttpFailure catch (f) {
    throw AdapterException(misskeyPublishError(f, context: context, now: ctx.now()));
  } on TimeoutException catch (e) {
    throw AdapterException(PublishError.network('$context: timed out', raw: '$e'));
  } on http.ClientException catch (e) {
    throw AdapterException(PublishError.network('$context: network error', raw: e.message));
  } on FormatException catch (e) {
    throw AdapterException(PublishError.platform('$context: unexpected response', raw: e.message));
  }
}

/// Whether [mime] matches one of Misskey's `uploadableFileTypes` patterns
/// (`image/*`, `*/*`, `video/mp4`).
bool misskeyMimeAllowed(String mime, List<String> patterns) {
  for (final p in patterns) {
    if (p == '*/*' || p == '*') return true;
    if (p.endsWith('/*') && mime.startsWith(p.substring(0, p.length - 1))) return true;
    if (p == mime) return true;
  }
  return false;
}
