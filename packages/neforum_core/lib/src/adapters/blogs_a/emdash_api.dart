import 'dart:typed_data';

import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'blog_common.dart';

/// Where EmDash serves its REST API on a site (EmDash 1.5).
const String emdashApiBase = '/_emdash/api';

/// Where its admin lives on a site.
const String emdashAdminBase = '/_emdash/admin';

/// The prefix of an EmDash personal access token.
const String emdashTokenPrefix = 'ec_pat_';

/// The collection NEFORUM writes blog posts to: the blog template's `posts`,
/// with its `/posts/{slug}` address.
const String emdashPostsCollection = 'posts';

/// The taxonomy NEFORUM puts tags in (the blog template's `tag`).
const String emdashTagTaxonomy = 'tag';

/// EmDash's default upload limit (`DEFAULT_MAX_UPLOAD_SIZE`, 50 MB). A site
/// can set another.
const int emdashDefaultMaxUpload = 50 * 1024 * 1024;

/// Thin client for EmDash's REST API at `{site}/_emdash/api/`, with a
/// personal access token sent as `Authorization: Bearer`.
///
/// Every answer is `{success, data}` or `{success: false, error: {code,
/// message}}` (`emdash/src/api/error.ts`).
class EmDashApi {
  EmDashApi(this.site, this.ctx, {this.token});

  /// The site's public address (scheme, host, maybe a path).
  final Uri site;
  final AdapterContext ctx;
  final String? token;

  Uri endpoint(String path, [Map<String, String>? query]) => joinPath(site, '$emdashApiBase/$path', query);

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<NeforumResponse> get(String path, [Map<String, String>? query]) => ctx.http.get(endpoint(path, query), headers: _headers);

  Future<NeforumResponse> postJson(String path, Object body) => ctx.http.postJson(endpoint(path), body, headers: _headers);

  /// `POST media` (multipart `file`, `alt`, `width`, `height`). EmDash keeps
  /// one copy of the same bytes (`deduplicate` defaults to true) and answers
  /// with the copy it has, so a re-sent upload adds no second file.
  Future<NeforumResponse> uploadMedia(Uint8List bytes,
          {required String fileName, required String contentType, String? alt, int? width, int? height}) =>
      ctx.http.multipart(endpoint('media'),
          headers: _headers,
          fields: {
            'deduplicate': 'true',
            if (alt != null && alt.isNotEmpty) 'alt': alt,
            if (width != null && width > 0 && height != null && height > 0) 'width': '$width',
            if (width != null && width > 0 && height != null && height > 0) 'height': '$height',
          },
          files: [HttpFilePart(field: 'file', bytes: bytes, fileName: fileName, contentType: contentType)],
          retrySafe: true);
}

/// The `data` object of an EmDash answer (empty when there is none).
Map<String, dynamic> emdashData(NeforumResponse r) => blogMap(r.jsonMap['data']) ?? const {};

/// `(code, message)` of an EmDash error answer; empty code when the body is
/// not one (a proxy page, an empty 409).
(String, String?) emdashErrorOf(NeforumResponse r) {
  final error = blogMap(r.jsonMap['error']);
  return (blogStr(error?['code']) ?? '', blogStr(error?['message']));
}

/// Maps an EmDash API failure onto a [PublishError].
PublishError mapEmDashFailure(HttpFailure f, String what) {
  final (code, message) = emdashErrorOf(f.response);
  final suffix = message == null ? '' : ': $message';
  final raw = bodySnippet(f.response);
  final status = f.statusCode;
  if (status == 429 || code == 'RATE_LIMITED') {
    return PublishError.quota('$what: EmDash is limiting requests$suffix', raw: raw, statusCode: status, retryAfter: f.response.retryAfter);
  }
  if (status == 401 || code == 'INVALID_TOKEN' || code == 'UNAUTHORIZED' || code == 'NOT_AUTHENTICATED') {
    return PublishError.auth('$what: EmDash did not accept the API token. It may have expired or been revoked; '
        'make a new one in Settings > API Tokens and reconnect.', raw: raw, statusCode: status);
  }
  if (code == 'INSUFFICIENT_SCOPE') {
    return PublishError.auth('$what: the API token is missing a permission$suffix. Make a token with Content Read, '
        'Content Write and Media Write and reconnect.', raw: raw, statusCode: status, notAllowed: true);
  }
  if (status == 403 || code == 'FORBIDDEN') {
    return PublishError.auth('$what: your EmDash role is not allowed to do that$suffix', raw: raw, statusCode: status, notAllowed: true);
  }
  if (code == 'COLLECTION_NOT_FOUND') {
    return PublishError.configuration('$what: this EmDash site has no "$emdashPostsCollection" collection$suffix. '
        'NEFORUM posts to the blog template\'s Posts.', raw: raw);
  }
  if (status == 404 && code.isEmpty) {
    return PublishError.configuration('$what: ${f.url.host} has no EmDash API at ${f.url.path}. Reconnect with the '
        'address of your EmDash site.', raw: raw);
  }
  if (status == 413 || code == 'PAYLOAD_TOO_LARGE') {
    return PublishError.validation('$what: the file is too large for this EmDash site$suffix', raw: raw, statusCode: status);
  }
  if (status == 400 || status == 409 || status == 422) {
    return PublishError.validation('$what$suffix', raw: raw, statusCode: status);
  }
  return f.toPublishError(context: '$what$suffix');
}

/// Runs [call] and turns HTTP and network failures into [AdapterException].
Future<T> guardEmDash<T>(String what, Future<T> Function() call) async {
  try {
    return await call();
  } on AdapterException {
    rethrow;
  } on HttpFailure catch (f) {
    throw AdapterException(mapEmDashFailure(f, what));
  } on Exception catch (e) {
    throw AdapterException(PublishError.network('$what failed: ${NeforumHttp.transportMessage(e)}', raw: NeforumHttp.transportDetails(e)));
  }
}

/// The site address the user typed, normalised like other blogs, and cut
/// back to the site when it points into EmDash (`/_emdash/admin/...`).
Uri parseEmDashSite(String input) {
  final raw = input.trim();
  final cut = raw.indexOf('/_emdash');
  return parseBlogSiteUrl(cut < 0 ? raw : raw.substring(0, cut), what: 'EmDash site address');
}

/// The token the user pasted, or a [ConnectException] saying what it should
/// look like.
String parseEmDashToken(String input) {
  final t = input.trim().replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');
  if (!t.startsWith(emdashTokenPrefix) || t.length < emdashTokenPrefix.length + 16 || t.contains(RegExp(r'\s'))) {
    throw const ConnectException('That is not an EmDash API token. It starts with ec_pat_ and is shown once, when you '
        'make it in Settings > API Tokens.', field: 'token');
  }
  return t;
}
