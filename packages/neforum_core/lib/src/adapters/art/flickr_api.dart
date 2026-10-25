import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../../auth/oauth1.dart';
import '../../http/neforum_http.dart';
import '../../model/media.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../platform_adapter.dart';
import 'art_api_common.dart';

/// A temporary token from `request_token`, kept until the user comes back
/// from Flickr's authorization page.
class FlickrRequestToken {
  const FlickrRequestToken(this.token, this.secret);
  final String token;
  final String secret;
}

/// What `access_token` hands back: the user's permanent token and who they
/// are.
class FlickrAccess {
  const FlickrAccess({required this.token, required this.secret, required this.userNsid, this.username, this.fullName});
  final String token;
  final String secret;
  final String userNsid;
  final String? username;
  final String? fullName;
}

/// A failure Flickr reported in its own format: `oauth_problem` from the
/// token endpoints, `<err code msg>` from the upload API.
class FlickrException implements Exception {
  const FlickrException(this.message, {this.code, this.statusCode});
  final String message;
  final int? code;
  final int? statusCode;

  @override
  String toString() => 'FlickrException(${code ?? statusCode}: $message)';
}

/// Flickr's OAuth 1.0a sign-in and upload API, signed with the user's own API
/// key and secret.
///
/// Flickr documents its OAuth parameters in the query string of the token
/// requests and in the form fields of an upload, and signs every upload field
/// except the photo itself (flickr.com/services/api/auth.oauth.html,
/// upload.api.html; read 2026-10-25). [OAuth1.baseString] and
/// [OAuth1.signature] do the RFC 5849 work.
class FlickrApi {
  FlickrApi(
    this.ctx, {
    required this.consumerKey,
    required this.consumerSecret,
    this.token,
    this.tokenSecret = '',
    String Function()? nonce,
  }) : _nonce = nonce ?? OAuth1.randomNonce;

  static final Uri requestTokenEndpoint = Uri.parse('https://www.flickr.com/services/oauth/request_token');
  static final Uri authorizeEndpoint = Uri.parse('https://www.flickr.com/services/oauth/authorize');
  static final Uri accessTokenEndpoint = Uri.parse('https://www.flickr.com/services/oauth/access_token');
  static final Uri uploadEndpoint = Uri.parse('https://up.flickr.com/services/upload/');

  final AdapterContext ctx;
  final String consumerKey;
  final String consumerSecret;
  final String? token;
  final String tokenSecret;
  final String Function() _nonce;

  /// Public address of a photo.
  static String photoUrl(String userNsid, String photoId) => 'https://www.flickr.com/photos/$userNsid/$photoId/';

  /// [params] plus the OAuth parameters and the signature over all of them
  /// (and [url]'s own query).
  Map<String, String> signedParams(String method, Uri url, Map<String, String> params) {
    final all = <String, String>{
      ...params,
      'oauth_consumer_key': consumerKey,
      'oauth_nonce': _nonce(),
      'oauth_signature_method': OAuth1.signatureMethod,
      'oauth_timestamp': '${ctx.now().millisecondsSinceEpoch ~/ 1000}',
      'oauth_version': OAuth1.version,
      if (token != null && token!.isNotEmpty) 'oauth_token': token!,
    };
    final base = OAuth1.baseString(method, url, [
      for (final q in url.queryParametersAll.entries)
        for (final v in q.value) MapEntry(q.key, v),
      ...all.entries,
    ]);
    return {...all, 'oauth_signature': OAuth1.signature(base, consumerSecret, tokenSecret)};
  }

  /// Step 1: a request token for [callback], where Flickr sends the browser
  /// back with `oauth_verifier`.
  Future<FlickrRequestToken> requestToken(Uri callback) async {
    final values = await _tokenCall(requestTokenEndpoint, {'oauth_callback': callback.toString()});
    final t = values['oauth_token'] ?? '';
    final s = values['oauth_token_secret'] ?? '';
    if (t.isEmpty || s.isEmpty) throw const FlickrException('Flickr returned no request token');
    return FlickrRequestToken(t, s);
  }

  /// Step 2: the page where the user allows NEFORUM to upload (`perms=write`).
  static Uri authorizationUrl(String requestToken) =>
      authorizeEndpoint.replace(queryParameters: {'oauth_token': requestToken, 'perms': 'write'});

  /// Step 3: swaps the request token (this client's [token] and
  /// [tokenSecret]) and [verifier] for the user's permanent token.
  Future<FlickrAccess> accessToken(String verifier) async {
    final values = await _tokenCall(accessTokenEndpoint, {'oauth_verifier': verifier});
    final t = values['oauth_token'] ?? '';
    final s = values['oauth_token_secret'] ?? '';
    final nsid = values['user_nsid'] ?? '';
    if (t.isEmpty || s.isEmpty || nsid.isEmpty) throw const FlickrException('Flickr returned no access token');
    String? nonEmpty(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
    return FlickrAccess(
      token: t,
      secret: s,
      userNsid: nsid,
      username: nonEmpty(values['username']),
      fullName: nonEmpty(values['fullname']),
    );
  }

  Future<Map<String, String>> _tokenCall(Uri endpoint, Map<String, String> params) async {
    final url = endpoint.replace(queryParameters: signedParams('GET', endpoint, params));
    final res = await ctx.http.get(url, throwOnError: false);
    final values = Uri.splitQueryString(res.body.trim());
    if (!res.ok) {
      final problem = values['oauth_problem'];
      throw FlickrException(problem ?? 'HTTP ${res.statusCode}', statusCode: res.statusCode);
    }
    return values;
  }

  /// `POST /services/upload/` for one file. Returns the photo id.
  Future<String> upload(MediaAttachment media, Uint8List bytes, Map<String, String> fields) async {
    final signed = signedParams('POST', uploadEndpoint, fields);
    final body = MultipartBody();
    for (final e in signed.entries) {
      body.field(e.key, e.value);
    }
    body.file('photo', bytes, fileName: media.fileName ?? 'photo', contentType: media.mimeType);
    final res = await ctx.http.send(
      'POST',
      uploadEndpoint,
      headers: {'Content-Type': body.contentType},
      bytes: body.bytes,
      throwOnError: false,
    );
    return photoIdFrom(res);
  }

  /// Reads `<rsp stat="ok"><photoid>…</photoid></rsp>`; throws
  /// [FlickrException] for `<rsp stat="fail"><err code msg/></rsp>` and for
  /// an answer that is not the upload API's XML.
  static String photoIdFrom(NeforumResponse res) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(res.body);
    } on XmlException {
      throw FlickrException('Flickr answered HTTP ${res.statusCode} without its usual reply', statusCode: res.statusCode);
    }
    final rsp = doc.findAllElements('rsp').firstOrNull;
    if (rsp?.getAttribute('stat') == 'ok') {
      final id = rsp!.findElements('photoid').firstOrNull?.innerText.trim() ?? '';
      if (id.isNotEmpty) return id;
    }
    final err = doc.findAllElements('err').firstOrNull;
    throw FlickrException(
      err?.getAttribute('msg') ?? 'Flickr did not return a photo id',
      code: int.tryParse(err?.getAttribute('code') ?? ''),
      statusCode: res.statusCode,
    );
  }

  /// The [PublishError] for an upload failure, by the error codes of the
  /// upload API.
  static PublishError mapUploadError(FlickrException e, {String? context}) {
    final prefix = context == null ? '' : '$context: ';
    final raw = e.toString();
    return switch (e.code) {
      96 || 97 || 98 || 100 => PublishError.auth(
          '${prefix}Flickr refused the sign-in (${e.message}). Reconnect Flickr in Accounts.',
          raw: raw,
          statusCode: e.statusCode),
      99 => PublishError.auth(
          '${prefix}Flickr says NEFORUM may not upload for you (${e.message}). Reconnect Flickr and allow it to upload.',
          raw: raw,
          statusCode: e.statusCode),
      6 => PublishError.quota('${prefix}Your Flickr account reached its upload limit (${e.message})',
          raw: raw, statusCode: e.statusCode),
      2 || 4 || 5 => PublishError.validation('$prefix${e.message}', raw: raw, statusCode: e.statusCode),
      3 || 105 || 106 => PublishError.network('${prefix}Flickr could not take the upload right now (${e.message}); '
          'NEFORUM tries again later', raw: raw, statusCode: e.statusCode),
      _ => (e.statusCode ?? 0) >= 500
          ? PublishError.network('${prefix}Flickr had a problem (${e.message}); NEFORUM tries again later',
              raw: raw, statusCode: e.statusCode)
          : PublishError.platform('$prefix${e.message}', raw: raw, statusCode: e.statusCode),
    };
  }

  /// Wraps [mapUploadError] for adapter helpers that throw.
  static AdapterException uploadFailure(FlickrException e, {String? context}) =>
      AdapterException(mapUploadError(e, context: context));
}
