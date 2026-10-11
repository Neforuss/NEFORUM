import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';

/// Image uploads can be slow on small instances; the default 60 s request
/// timeout is too short for a 20 MB file on a phone connection.
const Duration _uploadTimeout = Duration(minutes: 5);

/// Normalises what the user typed ("lemmy.world", "https://lemmy.world/c/x",
/// "@alice@lemmy.world") into the instance origin (`https://lemmy.world`).
///
/// Throws [ConnectException] when nothing usable is left.
Uri parseLemmyInstance(String raw) {
  var s = raw.trim();
  if (s.isEmpty) throw const ConnectException('Enter your instance, e.g. lemmy.world', field: 'instance');
  final acct = RegExp(r'^@?[A-Za-z0-9_.-]+@([A-Za-z0-9.-]+(?::\d+)?)$').firstMatch(s);
  if (acct != null) s = acct.group(1)!;
  if (!s.contains('://')) s = 'https://$s';
  final uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty || (uri.scheme != 'https' && uri.scheme != 'http')) {
    throw ConnectException('"$raw" is not a valid instance address', field: 'instance');
  }
  final host = uri.host.toLowerCase();
  final local = host == 'localhost' || host == '127.0.0.1' || host.endsWith('.localhost') || host.endsWith('.test');
  if (!host.contains('.') && !local) {
    throw ConnectException('"$raw" is not a valid instance address', field: 'instance');
  }
  if (uri.scheme == 'http' && !local) {
    throw const ConnectException('Use an https:// address for your instance', field: 'instance');
  }
  return Uri(scheme: uri.scheme, host: host, port: uri.hasPort ? uri.port : null);
}

final RegExp _communityName = RegExp(r'^[A-Za-z0-9_]+$');
final RegExp _hostName = RegExp(r'^[A-Za-z0-9.-]+(:\d+)?$');

/// Turns the many ways people write a community into the form
/// `GET /api/v3/community?name=` accepts: `name` for a community on the
/// home instance, `name@host` for a remote one.
///
/// Accepts `!name@host`, `name@host`, `c/name`, `/c/name`, `name` and
/// community URLs (`https://host/c/name`, `https://home/c/name@host`, Mbin's
/// `https://host/m/name`). Returns `null` when the input is not a community.
String? normalizeLemmyCommunity(String raw, {required String homeHost}) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  String? host;
  if (s.contains('://')) {
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return null;
    final segs = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    final i = segs.indexWhere((p) => p == 'c' || p == 'm');
    if (i < 0 || i + 1 >= segs.length) return null;
    s = segs[i + 1];
    host = uri.host.toLowerCase();
  } else {
    s = s.replaceFirst(RegExp(r'^[!/]+'), '');
    s = s.replaceFirst(RegExp(r'^[cm]/'), '');
  }
  final at = s.indexOf('@');
  if (at >= 0) {
    final h = s.substring(at + 1).toLowerCase();
    if (!_hostName.hasMatch(h)) return null;
    host = h;
    s = s.substring(0, at);
  }
  if (!_communityName.hasMatch(s)) return null;
  final home = homeHost.toLowerCase();
  if (host == null || host == home) return s.toLowerCase();
  return '${s.toLowerCase()}@$host';
}

/// The `error` code from a Lemmy error body (`{"error": "incorrect_login"}`,
/// optionally with a `message`). `null` when the body is not a Lemmy error.
String? lemmyErrorCode(NeforumResponse r) {
  final e = r.jsonMap['error'];
  return e is String && e.isNotEmpty ? e : null;
}

String? _errorDetail(NeforumResponse r) {
  final j = r.jsonMap;
  for (final k in const ['message', 'msg']) {
    final v = j[k];
    if (v is String && v.isNotEmpty && v != 'ok') return v;
  }
  return null;
}

/// Codes that mean the stored login no longer works.
const Set<String> _authCodes = {
  'incorrect_login',
  'not_logged_in',
  'missing_totp_token',
  'incorrect_totp_token',
  'email_not_verified',
  'registration_application_is_pending',
  'registration_denied',
};

/// Codes that mean "this post (or its target) is not acceptable".
const Set<String> _validationCodes = {
  'invalid_post_title',
  'invalid_url',
  'url_length_overflow',
  'url_without_domain',
  'invalid_body_field',
  'blocked_url',
  'language_not_allowed',
  'couldnt_find_community',
  'only_mods_can_post_in_community',
  'deleted',
  'alt_text_length_overflow',
  'invalid_url_scheme',
};

/// Codes where neither reconnecting nor editing the post helps.
const Set<String> _accountCodes = {
  'site_ban',
  'banned_from_community',
  'person_is_banned_from_site',
  'person_is_banned_from_community',
};

String? _friendly(String code) => switch (code) {
      'incorrect_login' => 'Lemmy no longer accepts the stored login. Reconnect the account',
      'not_logged_in' => 'The stored login was signed out (password change or logout). Reconnect the account',
      'email_not_verified' => 'Verify your email address on your instance first',
      'registration_application_is_pending' => 'Your instance has not approved your account yet',
      'registration_denied' => 'Your instance denied your registration',
      'rate_limit_error' => 'Your instance is rate limiting posts (by default 6 posts per 10 minutes)',
      'invalid_post_title' => 'Lemmy refused the title (3 to 200 characters, one line)',
      'invalid_url' => 'Lemmy refused the link',
      'url_length_overflow' => 'The link is longer than 2000 characters',
      'invalid_body_field' => 'The text is longer than Lemmy allows',
      'blocked_url' => 'Your instance blocks this link',
      'language_not_allowed' => 'The community does not allow posts in this language',
      'couldnt_find_community' => 'Your instance cannot find that community',
      'only_mods_can_post_in_community' => 'Only moderators can post in this community',
      'site_ban' || 'person_is_banned_from_site' => 'Your account is banned on this instance',
      'banned_from_community' || 'person_is_banned_from_community' => 'You are banned from this community',
      'deleted' => 'The community was deleted',
      _ => null,
    };

/// Maps a failed Lemmy API call onto a [PublishError].
///
/// Lemmy 0.19 answers almost every error with HTTP 400 and a snake_case
/// `error` code (only `incorrect_login` is 401 and "not found" is 404), so the
/// code decides the kind, not the status.
PublishError lemmyPublishError(HttpFailure f, {required String context}) {
  final r = f.response;
  final base = f.toPublishError(context: context);
  final code = lemmyErrorCode(r);
  final detail = _errorDetail(r);
  final raw = base.raw;
  String msg(String fallback) {
    final friendly = code == null ? null : _friendly(code);
    final extra = detail != null && detail != friendly ? ' ($detail)' : '';
    return '$context: ${friendly ?? fallback}$extra';
  }

  if (code == 'rate_limit_error' || r.statusCode == 429) {
    return PublishError.quota(msg('rate limited'), raw: raw, statusCode: r.statusCode, retryAfter: r.retryAfter);
  }
  if (code != null && _authCodes.contains(code)) {
    return PublishError.auth(msg(code), raw: raw, statusCode: r.statusCode);
  }
  if (code != null && _accountCodes.contains(code)) {
    return PublishError.platform(msg(code), raw: raw, statusCode: r.statusCode);
  }
  if (code != null && _validationCodes.contains(code)) {
    return PublishError.validation(msg(code), raw: raw, statusCode: r.statusCode);
  }
  if (r.statusCode == 413) {
    return PublishError.validation('$context: the file is larger than your instance accepts', raw: raw, statusCode: 413);
  }
  if (r.statusCode == 404 && code == null) {
    return PublishError.platform('$context: endpoint not found; is this a Lemmy instance?', raw: raw, statusCode: 404);
  }
  if (code != null && r.statusCode < 500) {
    // Unknown Lemmy code on a 400: the request was refused as such.
    return PublishError(
      kind: r.statusCode == 400 ? PublishErrorKind.validation : base.kind,
      message: msg(code),
      raw: raw,
      statusCode: r.statusCode,
      retryable: base.retryable,
    );
  }
  if (detail != null && r.statusCode < 500) {
    return PublishError(kind: base.kind, message: '$context: $detail', raw: raw, statusCode: r.statusCode, retryable: base.retryable);
  }
  return base;
}

/// Runs [body] and turns every expected failure into an [AdapterException].
Future<T> guardLemmy<T>(String context, Future<T> Function() body) async {
  try {
    return await body();
  } on AdapterException {
    rethrow;
  } on HttpFailure catch (f) {
    throw AdapterException(lemmyPublishError(f, context: context));
  } on TimeoutException catch (e) {
    throw AdapterException(PublishError.network('$context: timed out', raw: '$e'));
  } on http.ClientException catch (e) {
    throw AdapterException(PublishError.network('$context: network error', raw: e.message));
  } on FormatException catch (e) {
    throw AdapterException(PublishError.platform('$context: unexpected response', raw: e.message));
  }
}

/// Thin client for one Lemmy instance (HTTP API v3, served by Lemmy 0.19.x
/// and kept for compatibility by Lemmy 1.0). The login JWT travels as
/// `Authorization: Bearer`.
class LemmyApi {
  LemmyApi(this.instance, this.ctx, {this.jwt});

  final Uri instance;
  final AdapterContext ctx;
  final String? jwt;

  Uri endpoint(String path, [Map<String, String>? query]) =>
      instance.replace(path: '/api/v3/$path', queryParameters: query == null || query.isEmpty ? null : query);

  Map<String, String> get _auth => jwt == null ? const {} : {'Authorization': 'Bearer $jwt'};

  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) async =>
      (await ctx.http.get(endpoint(path, query), headers: _auth)).jsonMap;

  Future<Map<String, dynamic>> post(String path, Map<String, Object?> body) async =>
      (await ctx.http.postJson(endpoint(path), body, headers: _auth)).jsonMap;

  /// `POST /api/v3/user/login`. Returns the raw response map (`jwt` may be
  /// null while the account awaits approval or email verification).
  Future<Map<String, dynamic>> login(String usernameOrEmail, String password, {String? totp}) => post('user/login', {
        'username_or_email': usernameOrEmail,
        'password': password,
        if (totp != null && totp.isNotEmpty) 'totp_2fa_token': totp,
      });

  /// `GET /api/v3/community?name=...` -> `community_view.community`.
  Future<Map<String, dynamic>> getCommunity(String name) async {
    final res = await get('community', {'name': name});
    return _communityOf(res['community_view']);
  }

  /// `GET /api/v3/resolve_object?q=!name@host`: makes the home instance fetch
  /// a remote community it has not seen yet. Needs a login.
  Future<Map<String, dynamic>> resolveCommunity(String nameAtHost) async {
    final res = await get('resolve_object', {'q': '!$nameAtHost'});
    return _communityOf(res['community']);
  }

  /// `POST {instance}/pictrs/image` (multipart `images[]`) and returns the
  /// public URL of the stored image.
  Future<Uri> uploadImage({required Uint8List bytes, required String fileName, required String contentType}) async {
    final r = await ctx.http.send(
      'POST',
      instance.replace(path: '/pictrs/image'),
      headers: {
        ..._auth,
        // Older 0.19 pict-rs proxies read the session cookie lemmy-ui sets.
        if (jwt != null) 'Cookie': 'jwt=$jwt',
      },
      fields: const {},
      files: [HttpFilePart(field: 'images[]', bytes: bytes, fileName: fileName, contentType: contentType)],
      timeout: _uploadTimeout,
    );
    final j = r.jsonMap;
    // Lemmy 1.0 style response.
    final direct = j['image_url'];
    if (direct is String && direct.isNotEmpty) return Uri.parse(direct);
    final files = j['files'];
    final first = files is List && files.isNotEmpty ? files.first : null;
    final file = first is Map ? first['file'] : null;
    if (j['msg'] != 'ok' || file is! String || file.isEmpty) {
      final msg = j['msg'];
      throw AdapterException(PublishError.validation(
          'Your instance did not accept the image${msg is String && msg.isNotEmpty ? ' ($msg)' : ''}',
          raw: r.body.length > 600 ? r.body.substring(0, 600) : r.body,
          statusCode: r.statusCode));
    }
    return instance.replace(path: '/pictrs/image/$file');
  }

  /// `POST /api/v3/user/logout`: invalidates the JWT on the server.
  Future<void> logout() async {
    await ctx.http.postJson(endpoint('user/logout'), const <String, Object?>{}, headers: _auth);
  }
}

Map<String, dynamic> _communityOf(Object? view) {
  final c = view is Map ? view['community'] : null;
  if (c is! Map || c['id'] is! num) throw const FormatException('no community in the response');
  return Map<String, dynamic>.from(c);
}
