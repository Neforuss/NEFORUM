import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../platform_adapter.dart';

/// Graph API version used for every call. Meta's Pages API and Facebook
/// Login docs (read 2026-10-07) use v25.0 in their examples.
const String facebookGraphVersion = 'v25.0';

/// Graph API host. The Video API overview says the old
/// `graph-video.facebook.com` upload host is deprecated, so videos go here too.
final Uri facebookGraphBase = Uri.parse('https://graph.facebook.com/$facebookGraphVersion/');

/// Facebook Login dialog.
final Uri facebookAuthorizeEndpoint = Uri.parse('https://www.facebook.com/$facebookGraphVersion/dialog/oauth');

/// Token endpoint (code exchange and `fb_exchange_token`).
final Uri facebookTokenEndpoint = Uri.parse('https://graph.facebook.com/$facebookGraphVersion/oauth/access_token');

/// The Facebook-hosted redirect page Meta's manual login flow documents for
/// desktop apps. Facebook Login does not take NEFORUM's loopback listener or
/// `neforum://`, so the user copies the address of this page back into
/// NEFORUM instead.
///
/// Meta's App Dashboard refuses to register this address ("This can't be a
/// Facebook URL", in both Facebook Login for Business > Settings > Valid OAuth
/// Redirect URIs and App settings > Advanced > Authorize callback URL, seen
/// 11 October 2026). Whether the login dialog accepts it unregistered is
/// unconfirmed, so browser sign-in is the secondary route; pasting a Graph API
/// Explorer token is the documented one.
final Uri facebookLoginSuccessUri = Uri.parse('https://www.facebook.com/connect/login_success.html');

/// `appsecret_proof` = hex HMAC-SHA256 of the access token keyed with the app
/// secret (Graph API "Securing requests"). Required when the user's app has
/// "Require App Secret" switched on; harmless otherwise.
String appSecretProof(String accessToken, String appSecret) =>
    Hmac(sha256, utf8.encode(appSecret)).convert(utf8.encode(accessToken)).toString();

/// Builds `https://graph.facebook.com/v25.0/<path>` with optional query.
Uri graphUri(String path, [Map<String, String>? query]) {
  final u = facebookGraphBase.resolve(path.startsWith('/') ? path.substring(1) : path);
  return query == null || query.isEmpty ? u : u.replace(queryParameters: query);
}

/// Adds `access_token` (and `appsecret_proof` when the app secret is known)
/// to a parameter map.
Map<String, String> withToken(Map<String, String> params, String token, String? appSecret) => {
      ...params,
      'access_token': token,
      if (appSecret != null && appSecret.isNotEmpty) 'appsecret_proof': appSecretProof(token, appSecret),
    };

/// A parsed Graph API error body: `{"error":{"message","type","code","error_subcode",...}}`.
class GraphError {
  const GraphError({required this.message, this.type, this.code, this.subcode, this.userMessage, this.isTransient = false});

  /// Returns `null` when [body] carries no Graph error object.
  static GraphError? parse(Map<String, dynamic> body) {
    final e = body['error'];
    if (e is! Map) return null;
    final m = Map<String, dynamic>.from(e);
    return GraphError(
      message: m['message']?.toString() ?? 'Unknown Facebook error',
      type: m['type']?.toString(),
      code: _int(m['code']),
      subcode: _int(m['error_subcode']),
      userMessage: m['error_user_msg']?.toString(),
      isTransient: m['is_transient'] == true,
    );
  }

  final String message;
  final String? type;
  final int? code;
  final int? subcode;
  final String? userMessage;
  final bool isTransient;

  String get display {
    final tag = code == null ? '' : ' (#$code${subcode == null ? '' : '/$subcode'})';
    final user = userMessage == null || userMessage!.isEmpty ? '' : ' - $userMessage';
    return '$message$tag$user';
  }

  static int? _int(Object? v) => v is int ? v : int.tryParse('${v ?? ''}');
}

/// Turns a non-2xx Graph response into a [PublishError], refining the generic
/// HTTP mapping with Graph error codes (Graph API "Handling errors" and
/// "Rate limiting" docs).
PublishError mapGraphFailure(HttpFailure f, {String? context}) {
  final base = f.toPublishError(context: context);
  final err = GraphError.parse(f.response.jsonMap);
  if (err == null) return base;
  final prefix = context == null ? '' : '$context: ';
  final msg = '${prefix}Facebook: ${err.display}';
  final raw = base.raw;
  final status = f.statusCode;
  final code = err.code ?? 0;
  final sub = err.subcode ?? 0;

  // Token expired / revoked / checkpoint: reconnect.
  const authSubcodes = {458, 459, 460, 463, 464, 467};
  if (code == 190 || code == 102 || authSubcodes.contains(sub)) {
    return PublishError.auth('$msg. Reconnect the Facebook account.', raw: raw, statusCode: status);
  }
  // Missing permission (pages_manage_posts not granted, Page role lost).
  if (code == 10 || (code >= 200 && code <= 299)) {
    return PublishError.auth('$msg. Reconnect and grant all requested Page permissions.', raw: raw, statusCode: status);
  }
  // Throttling: app (4), user (17), Pages BUC (32 / 80001), custom (613),
  // application limit (341), "posting too fast" (1390008).
  if (const {4, 17, 32, 341, 613, 80001}.contains(code) || sub == 1390008) {
    return PublishError.quota(msg, raw: raw, statusCode: status, retryAfter: _retryAfter(f.response));
  }
  // Temporarily blocked for policy violations: wait and retry.
  if (code == 368) {
    return PublishError.quota('$msg. Facebook temporarily blocked posting from this Page.',
        raw: raw, statusCode: status, retryAfter: _retryAfter(f.response));
  }
  if (code == 506) {
    return PublishError.validation('$msg. Facebook rejects a post identical to a recent one.', raw: raw, statusCode: status);
  }
  if (code == 1609005 || sub == 1609008) {
    return PublishError.validation('$msg. Facebook would not attach this link.', raw: raw, statusCode: status);
  }
  // 1 / 2: "Temporary issue due to downtime. Wait and retry"; 6001 (/videos):
  // "There was a problem uploading your video. Please try again."
  if (code == 1 || code == 2 || code == 6001 || err.isTransient) {
    return PublishError.network(msg, raw: raw, statusCode: status, retryAfter: _retryAfter(f.response));
  }
  if (code == 100 || status == 400) {
    return PublishError.validation(msg, raw: raw, statusCode: status);
  }
  return PublishError(
    kind: base.kind,
    message: msg,
    raw: raw,
    statusCode: status,
    retryable: base.retryable,
    retryAfter: base.retryAfter,
  );
}

/// Retry hint: `Retry-After`, else the largest
/// `estimated_time_to_regain_access` (minutes) in `X-Business-Use-Case-Usage`.
Duration? _retryAfter(NeforumResponse r) {
  final ra = r.retryAfter;
  if (ra != null) return ra;
  final buc = r.headers['x-business-use-case-usage'];
  if (buc == null) return null;
  try {
    final decoded = jsonDecode(buc);
    if (decoded is! Map) return null;
    var minutes = 0;
    for (final entries in decoded.values) {
      if (entries is! List) continue;
      for (final e in entries) {
        if (e is! Map) continue;
        final v = e['estimated_time_to_regain_access'];
        final n = v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
        if (n > minutes) minutes = n;
      }
    }
    return minutes > 0 ? Duration(minutes: minutes) : null;
  } on FormatException {
    return null;
  }
}

/// Reads a string field from a decoded Graph JSON object, or throws a
/// platform error when it is missing.
String requireString(Map<String, dynamic> json, String key, String what) {
  final v = json[key];
  if (v is String && v.isNotEmpty) return v;
  if (v is num) return v.toString();
  throw AdapterException(PublishError.platform('Facebook did not return $what', raw: jsonEncode(json)));
}

/// Optional string field.
String? optString(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is String && v.isNotEmpty) return v;
  if (v is num) return v.toString();
  return null;
}

/// A Page from `GET /me/accounts`.
class FacebookPage {
  const FacebookPage(
      {required this.id, required this.name, required this.accessToken, this.tasks, this.link, this.username});

  static FacebookPage? fromJson(Object? json) {
    if (json is! Map) return null;
    final m = Map<String, dynamic>.from(json);
    final id = optString(m, 'id');
    final token = optString(m, 'access_token');
    if (id == null || token == null) return null;
    final tasks = m['tasks'];
    return FacebookPage(
      id: id,
      name: optString(m, 'name') ?? id,
      accessToken: token,
      tasks: tasks is List ? tasks.map((t) => '$t').toList() : null,
      link: optString(m, 'link'),
      username: optString(m, 'username'),
    );
  }

  final String id;
  final String name;
  final String accessToken;

  /// `CREATE_CONTENT`, `MANAGE`, ... `null` when Facebook did not say.
  final List<String>? tasks;
  final String? link;

  /// The Page's username, the `<x>` in `facebook.com/<x>`. `null` for Pages
  /// without one (their address uses the id).
  final String? username;

  bool get canCreateContent => tasks == null || tasks!.contains('CREATE_CONTENT');

  Map<String, String> toSummary() => {'id': id, 'name': name, if (username != null) 'username': username!};
}

/// The Meta app an access token belongs to, from `GET /debug_token`
/// (`data.app_id` and `data.application`).
class FacebookTokenApp {
  const FacebookTokenApp(this.appId, this.name);

  final String appId;

  /// The app's display name, e.g. "Graph API Explorer". `null` when Facebook
  /// did not say.
  final String? name;
}

/// Reduces what someone typed in the Page field to something comparable with
/// a Page's id or username. A pasted Page address loses its scheme, host,
/// query and trailing slash: `https://www.facebook.com/examplebakery/?ref=x`,
/// `facebook.com/examplebakery` and `m.facebook.com/examplebakery` all give
/// `examplebakery`; `facebook.com/profile.php?id=123` gives `123`, as do the
/// older `facebook.com/pages/<name>/123` and `facebook.com/people/<name>/123`
/// forms. A leading `@` is dropped. Anything else comes back trimmed.
String facebookPageKey(String input) {
  final s = input.trim();
  if (s.startsWith('@')) return s.substring(1);
  final lower = s.toLowerCase();
  final looksLikeUrl =
      lower.contains('://') || RegExp(r'^(?:[a-z0-9-]+\.)*(?:facebook|fb)\.com(?:[/?#]|$)').hasMatch(lower);
  if (!looksLikeUrl) return s;
  final u = Uri.tryParse(s.contains('://') ? s : 'https://$s');
  if (u == null) return s;
  final host = u.host.toLowerCase();
  final isFacebook = host == 'facebook.com' || host.endsWith('.facebook.com') || host == 'fb.com' || host.endsWith('.fb.com');
  if (!isFacebook) return s;
  final segments = u.pathSegments.where((x) => x.isNotEmpty).toList();
  if (segments.isEmpty) return s;
  final first = segments.first.toLowerCase();
  final digits = RegExp(r'^\d+$');
  if (first == 'profile.php') {
    final id = u.queryParameters['id'] ?? '';
    return digits.hasMatch(id) ? id : s;
  }
  if ((first == 'pages' || first == 'people') && segments.length > 1 && digits.hasMatch(segments.last)) {
    return segments.last;
  }
  if ((first == 'pages' || first == 'people' || first == 'pg') && segments.length > 1) return segments[1];
  return segments.first;
}
