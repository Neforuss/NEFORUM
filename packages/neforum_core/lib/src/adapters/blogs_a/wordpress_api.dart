import 'dart:convert';
import 'dart:typed_data';

import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'blog_common.dart';

/// Where a WordPress site serves its REST API.
///
/// Sites with pretty permalinks use `{site}/wp-json/`; sites on "plain"
/// permalinks only answer at `{site}/?rest_route=/`. [base] is stored in the
/// account config as `restBase` so publishing does not have to rediscover it.
class WordPressRoot {
  const WordPressRoot(this.base);

  /// Either `https://example.com/wp-json/` or `https://example.com/?rest_route=/`.
  final String base;

  bool get _queryStyle => base.contains('rest_route=');

  /// URL of the REST route [route] (e.g. `wp/v2/posts`) with [query].
  Uri route(String route, [Map<String, String> query = const {}]) {
    final r = route.startsWith('/') ? route.substring(1) : route;
    final b = Uri.parse(base);
    if (_queryStyle) {
      return b.replace(queryParameters: {'rest_route': '/$r', ...query});
    }
    final path = b.path.endsWith('/') ? b.path : '${b.path}/';
    return b.replace(path: '$path$r', queryParameters: query.isEmpty ? null : query);
  }

  /// Candidate roots tried during discovery, best first.
  static List<WordPressRoot> candidates(Uri site) {
    final s = site.toString();
    return [WordPressRoot('$s/wp-json/'), WordPressRoot('$s/?rest_route=/')];
  }
}

/// Thin client for the WordPress REST API (`wp/v2`) with Application
/// Password (HTTP Basic) authentication.
class WordPressApi {
  WordPressApi(this.root, this.ctx, {required String username, required String appPassword})
      : _auth = 'Basic ${base64Encode(utf8.encode('$username:${appPassword.replaceAll(' ', '')}'))}';

  final WordPressRoot root;
  final AdapterContext ctx;
  final String _auth;

  Map<String, String> get _headers => {'Authorization': _auth, 'Accept': 'application/json'};

  Future<NeforumResponse> get(String route, [Map<String, String> query = const {}]) =>
      ctx.http.get(root.route(route, query), headers: _headers);

  Future<NeforumResponse> postJson(String route, Map<String, Object?> body) =>
      ctx.http.postJson(root.route(route), body, headers: _headers);

  Future<NeforumResponse> delete(String route, [Map<String, String> query = const {}]) =>
      ctx.http.delete(root.route(route, query), headers: _headers);

  /// `POST /wp/v2/media` with the raw file as the body and the file name in
  /// `Content-Disposition`.
  Future<NeforumResponse> uploadMedia(Uint8List bytes, {required String fileName, required String contentType}) =>
      ctx.http.putBytes(root.route('wp/v2/media'), bytes, method: 'POST', headers: {
        ..._headers,
        'Content-Type': contentType,
        'Content-Disposition': 'attachment; filename="$fileName"',
      });
}

/// Fetches the REST index of [site], trying `/wp-json/` then
/// `/?rest_route=/`. Returns the root that answered, its JSON and the site
/// address to store.
///
/// When the index reports a different home address (the user typed
/// `example.com` and the site redirects to `www.example.com`, or entered the
/// WordPress folder of a site whose address is the domain root), the API is
/// looked up again at that address: requests that only work through a
/// redirect fail later, because POSTs are not re-sent to the new location and
/// credentials are not forwarded to another host.
Future<(WordPressRoot, Map<String, dynamic>, Uri)> discoverWordPress(Uri site, AdapterContext ctx) async {
  final (root, index) = await _probeWordPress(site, ctx);
  final home = _canonicalHome(index, site);
  if (home != null) {
    try {
      final (homeRoot, homeIndex) = await _probeWordPress(home, ctx);
      ctx.log.info('WordPress: using the site address ${home.host}${home.path} reported by ${site.host}');
      return (homeRoot, homeIndex, home);
    } on ConnectException {
      // Keep the address the user typed; it answered.
    }
  }
  return (root, index, site);
}

Future<(WordPressRoot, Map<String, dynamic>)> _probeWordPress(Uri site, AdapterContext ctx) async {
  Object? lastProblem;
  for (final root in WordPressRoot.candidates(site)) {
    try {
      final r = await ctx.http.get(root.route(''), headers: {'Accept': 'application/json'}, throwOnError: false);
      final json = r.jsonMap;
      final namespaces = blogList(json['namespaces']);
      if (r.ok && namespaces.contains('wp/v2')) return (root, json);
      lastProblem = 'HTTP ${r.statusCode}';
    } on Exception catch (e) {
      lastProblem = e;
    }
  }
  final wpCom = site.host == 'wordpress.com' || site.host.endsWith('.wordpress.com')
      ? ' WordPress.com sites cannot be connected this way; use Hand-off.'
      : '';
  throw ConnectException('${site.host} does not answer like a WordPress site with the REST API enabled '
      '($lastProblem). Check the address. If it is right, a security plugin may be blocking /wp-json/.$wpCom');
}

/// The index's `home` address when it differs from [site], upgraded to
/// https when [site] uses https; `null` when it is the same or unusable.
Uri? _canonicalHome(Map<String, dynamic> index, Uri site) {
  final raw = blogStr(index['home']);
  final parsed = raw == null ? null : Uri.tryParse(raw.trim());
  if (parsed == null || parsed.host.isEmpty || (parsed.scheme != 'https' && parsed.scheme != 'http')) return null;
  // Sites behind a TLS proxy often report http:// as their home; never
  // downgrade the connection the user asked for.
  final scheme = site.scheme == 'https' ? 'https' : parsed.scheme;
  if (scheme == 'http' && !isLocalDevHost(parsed.host)) return null;
  final home = blogOrigin(parsed.replace(scheme: scheme));
  return home == blogOrigin(site) ? null : home;
}

/// The Application Passwords authorization page advertised in the REST
/// index, or `null` when Application Passwords are unavailable (no HTTPS,
/// or disabled by a plugin/host).
Uri? applicationPasswordsEndpoint(Map<String, dynamic> index) {
  final auth = blogMap(index['authentication']);
  final ap = blogMap(auth?['application-passwords']);
  final endpoints = blogMap(ap?['endpoints']);
  final url = blogStr(endpoints?['authorization']);
  return url == null ? null : Uri.tryParse(url);
}

/// WordPress REST error codes that mean the stored credentials are bad.
const Set<String> _wpAuthCodes = {
  'rest_not_logged_in',
  'incorrect_password',
  'invalid_username',
  'invalid_email',
  'application_passwords_disabled',
  'application_passwords_disabled_for_user',
  'rest_cookie_invalid_nonce',
};

/// Error codes that mean "your WordPress role is not allowed to do this".
const Set<String> _wpRoleCodes = {
  'rest_cannot_create',
  'rest_cannot_edit',
  'rest_cannot_edit_others',
  'rest_cannot_delete',
  'rest_cannot_assign_term',
  'rest_cannot_assign_sticky',
  'rest_forbidden',
};

/// Maps a WordPress REST failure (`{code, message, data: {status}}`) onto a
/// [PublishError].
PublishError mapWordPressFailure(HttpFailure f, String what) {
  final body = f.response.jsonMap;
  final code = blogStr(body['code']) ?? '';
  final message = blogStr(body['message']);
  final detail = message == null ? '' : ': $message';
  final raw = bodySnippet(f.response);
  final status = f.statusCode;
  if (status == 429) {
    return PublishError.quota('$what: the site is rate limiting requests$detail',
        raw: raw, statusCode: status, retryAfter: f.response.retryAfter);
  }
  if (_wpAuthCodes.contains(code) || status == 401) {
    return PublishError.auth(
        '$what: WordPress rejected the username or application password$detail. '
        'Create a new application password and reconnect.',
        raw: raw,
        statusCode: status);
  }
  if (code == 'rest_cannot_publish') {
    return PublishError.validation(
        '$what: your WordPress role cannot publish posts$detail. Send it as "pending" (for review) or as a draft.',
        raw: raw,
        statusCode: status);
  }
  if (code == 'rest_cannot_create' && what.toLowerCase().contains('upload')) {
    return PublishError.validation('$what: your WordPress role cannot upload files$detail', raw: raw, statusCode: status);
  }
  if (_wpRoleCodes.contains(code)) {
    return PublishError.auth('$what: your WordPress user is not allowed to do this$detail. '
        'Reconnect with an Author, Editor or Administrator account.', raw: raw, statusCode: status);
  }
  if (status == 403 && code.isEmpty) {
    return PublishError.auth(
        '$what: HTTP 403 from ${f.url.host}. A security plugin, firewall or host setting may be blocking '
        'the REST API or the Authorization header.',
        raw: raw,
        statusCode: status);
  }
  if (code.startsWith('rest_upload_') || code == 'rest_invalid_param' || code == 'rest_invalid_json' || status == 413) {
    return PublishError.validation('$what$detail', raw: raw, statusCode: status);
  }
  if (code == 'rest_no_route') {
    return PublishError.configuration('$what: the WordPress REST route is missing on ${f.url.host}$detail. '
        'Reconnect the account so NEFORUM can find the API again.');
  }
  return f.toPublishError(context: '$what$detail');
}

/// Runs [call] and converts HTTP/network failures into [AdapterException].
Future<T> guardWordPress<T>(String what, Future<T> Function() call) async {
  try {
    return await call();
  } on AdapterException {
    rethrow;
  } on HttpFailure catch (f) {
    throw AdapterException(mapWordPressFailure(f, what));
  } on Exception catch (e) {
    throw AdapterException(PublishError.network('$what failed: $e', raw: '$e'));
  }
}
