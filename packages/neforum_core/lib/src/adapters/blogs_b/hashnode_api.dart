import '../../model/publish_result.dart';
import '../adapter_context.dart';
import 'blogs_common.dart';

/// Hashnode's public GraphQL endpoint. Hashnode's official GQL skill names
/// `gql-beta.hashnode.com` as production, and `apidocs.hashnode.com`
/// redirects there; the old `gql.hashnode.com` now answers every request
/// (POST included) with a 301 to an announcement page.
final Uri hashnodeDefaultEndpoint = Uri.parse('https://gql-beta.hashnode.com');

/// The retired endpoint. Accounts or input that still name it are moved to
/// [hashnodeDefaultEndpoint].
const String hashnodeLegacyHost = 'gql.hashnode.com';

/// [endpoint], or [hashnodeDefaultEndpoint] when it is empty or the retired
/// `gql.hashnode.com`.
Uri hashnodeEndpointOrDefault(Uri? endpoint) =>
    endpoint == null || endpoint.host.isEmpty || endpoint.host == hashnodeLegacyHost ? hashnodeDefaultEndpoint : endpoint;

/// A GraphQL- or HTTP-level failure from Hashnode.
class HashnodeError implements Exception {
  const HashnodeError({required this.message, this.code, this.statusCode, this.raw, this.retryAfter});

  /// `errors[0].extensions.code`: UNAUTHENTICATED, FORBIDDEN, NOT_FOUND,
  /// BAD_USER_INPUT, GRAPHQL_VALIDATION_FAILED, INTERNAL_SERVER_ERROR, ...
  final String? code;
  final String message;
  final int? statusCode;
  final String? raw;
  final Duration? retryAfter;

  /// The publication is not on Hashnode Pro (required for API access since
  /// 2026-05-13).
  bool get isProRequired => code == 'FORBIDDEN' && message.toLowerCase().contains('pro');

  bool get isInputError =>
      code == 'BAD_USER_INPUT' || code == 'GRAPHQL_VALIDATION_FAILED' || (code == null && statusCode == 400);

  /// The endpoint answered with a redirect: Hashnode moved its API.
  bool get isMoved => code == null && statusCode != null && statusCode! >= 300 && statusCode! < 400;

  @override
  String toString() => 'HashnodeError(${code ?? statusCode}: $message)';
}

/// Maps a [HashnodeError] onto a [PublishError].
PublishError hashnodePublishError(HashnodeError e, {required String context}) {
  final msg = '$context: ${e.message}';
  if (e.isMoved) {
    return PublishError(
      kind: PublishErrorKind.configuration,
      message: '$context: ${e.message}. Reconnect the account, or set the API endpoint (advanced) to Hashnode\'s '
          'current GraphQL address.',
      raw: e.raw,
      statusCode: e.statusCode,
    );
  }
  if (e.statusCode == 429 || e.code == 'RATE_LIMITED' || e.code == 'TOO_MANY_REQUESTS') {
    return PublishError.quota('$context: Hashnode rate limit reached', raw: e.raw, statusCode: e.statusCode, retryAfter: e.retryAfter);
  }
  if (e.code == 'UNAUTHENTICATED' || e.statusCode == 401) {
    return PublishError.auth('$context: Hashnode rejected the access token; reconnect the account',
        raw: e.raw, statusCode: e.statusCode);
  }
  if (e.isProRequired) {
    return PublishError(
      kind: PublishErrorKind.configuration,
      message: '$context: Hashnode only allows API access for blogs on Hashnode Pro. Upgrade the blog '
          '(Dashboard > Billing) or use the hand-off option.',
      raw: e.raw,
      statusCode: e.statusCode,
    );
  }
  if (e.code == 'FORBIDDEN' || e.statusCode == 403) {
    return PublishError.auth('$context: this token may not post to the publication (${e.message})',
        raw: e.raw, statusCode: e.statusCode);
  }
  if (e.code == 'NOT_FOUND') {
    return PublishError(
        kind: PublishErrorKind.configuration,
        message: '$context: the publication was not found; reconnect the account',
        raw: e.raw,
        statusCode: e.statusCode);
  }
  if (e.isInputError || e.statusCode == 413) {
    return PublishError.validation(msg, raw: e.raw, statusCode: e.statusCode);
  }
  if (e.code == 'INTERNAL_SERVER_ERROR' || (e.statusCode ?? 0) >= 500) {
    return PublishError.network(msg, raw: e.raw, statusCode: e.statusCode, retryAfter: e.retryAfter);
  }
  return PublishError.platform(msg, raw: e.raw, statusCode: e.statusCode);
}

/// Thin GraphQL client. The Personal Access Token goes in `Authorization`
/// as-is (Hashnode accepts it with or without a `Bearer ` prefix).
class HashnodeApi {
  HashnodeApi(this.ctx, {required this.token, Uri? endpoint}) : endpoint = hashnodeEndpointOrDefault(endpoint);

  final AdapterContext ctx;
  final String token;
  final Uri endpoint;

  /// Runs [document] and returns `data`. Throws [HashnodeError] when the
  /// response carries `errors` or is not 2xx (GraphQL errors often come with
  /// HTTP 200).
  Future<Map<String, dynamic>> call(String document, [Map<String, Object?> variables = const {}]) async {
    final res = await ctx.http.postJson(
      endpoint,
      {'query': document, if (variables.isNotEmpty) 'variables': variables},
      headers: {'Authorization': token, 'Accept': 'application/json'},
      throwOnError: false,
    );
    if (res.statusCode >= 300 && res.statusCode < 400) {
      // POST redirects are not followed, so a moved API shows up here.
      final to = res.headers['location'];
      throw HashnodeError(
        message: 'Hashnode\'s API at ${endpoint.host} answered HTTP ${res.statusCode}'
            '${to == null || to.isEmpty ? '' : ' (moved to $to)'}',
        statusCode: res.statusCode,
        raw: blogSnippet(res.body),
      );
    }
    final json = res.jsonMap;
    final errors = blogList(json['errors']);
    if (errors.isNotEmpty) {
      final first = blogMap(errors.first);
      throw HashnodeError(
        code: blogStr(blogMap(first['extensions'])['code']),
        message: errors.map((e) => blogStr(blogMap(e)['message'])).whereType<String>().join('; '),
        statusCode: res.statusCode,
        raw: blogSnippet(res.body),
        retryAfter: res.retryAfter,
      );
    }
    if (!res.ok) {
      throw HashnodeError(
          message: 'HTTP ${res.statusCode} from ${endpoint.host}',
          statusCode: res.statusCode,
          raw: blogSnippet(res.body),
          retryAfter: res.retryAfter);
    }
    if (!json.containsKey('data')) {
      throw HashnodeError(
          message: '${endpoint.host} did not answer with GraphQL (HTTP ${res.statusCode})',
          statusCode: res.statusCode,
          raw: blogSnippet(res.body));
    }
    return blogMap(json['data']);
  }
}

/// GraphQL documents used by the adapter.
abstract final class HashnodeDocs {
  static const me = 'query NeforumMe { me { id username name profilePicture '
      'publications(first: 20) { edges { node { id title url } } } } }';

  static const publicationByHost = 'query NeforumPublication(\$host: String!) { publication(host: \$host) { id title url } }';

  static const publicationById = 'query NeforumPublication(\$id: ObjectId!) { publication(id: \$id) { id title url } }';

  static const publishPost =
      'mutation PublishPost(\$input: PublishPostInput!) { publishPost(input: \$input) { post { id slug url } } }';

  static const createImageUpload = 'mutation CreateImageUpload(\$input: CreateImageUploadInput!) '
      '{ createImageUploadURL(input: \$input) { presignedPut { url cdnUrl key } } }';

  static const confirmImageUpload = 'mutation ConfirmImageUpload(\$input: ConfirmImageUploadInput!) '
      '{ confirmImageUpload(input: \$input) { ok cdnUrl } }';
}
