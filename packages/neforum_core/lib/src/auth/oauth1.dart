import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../util/logger.dart';

/// The four OAuth 1.0a keys of one user on one developer app: the app's
/// consumer key and secret (X: "API Key and Secret") plus the user's access
/// token and token secret.
///
/// Why NEFORUM offers them next to OAuth 2.0: X and Tumblr hand out a new
/// OAuth 2.0 refresh token on every renewal and kill the old one, so an
/// account used on several devices stays signed in on only one of them.
/// OAuth 1.0a user tokens never expire and never change (until the user
/// revokes or regenerates them), so every device can share the same keys.
@immutable
class OAuth1Credentials {
  const OAuth1Credentials({
    required this.consumerKey,
    required this.consumerSecret,
    required this.token,
    required this.tokenSecret,
  });

  /// Reads keys stored with [toSecrets]. Null unless all four are there: a
  /// half-stored set cannot sign anything.
  static OAuth1Credentials? fromSecrets(Map<String, String> s) {
    final ck = s[keyConsumerKey] ?? '';
    final cs = s[keyConsumerSecret] ?? '';
    final t = s[keyToken] ?? '';
    final ts = s[keyTokenSecret] ?? '';
    if (ck.isEmpty || cs.isEmpty || t.isEmpty || ts.isEmpty) return null;
    return OAuth1Credentials(consumerKey: ck, consumerSecret: cs, token: t, tokenSecret: ts);
  }

  // Secret-store keys. Distinct from OAuthTokens' `access_token`, so an
  // OAuth 1.0a account is never mistaken for an OAuth 2.0 one.
  static const keyConsumerKey = 'oauth1_consumer_key';
  static const keyConsumerSecret = 'oauth1_consumer_secret';
  static const keyToken = 'oauth1_token';
  static const keyTokenSecret = 'oauth1_token_secret';

  final String consumerKey;
  final String consumerSecret;
  final String token;
  final String tokenSecret;

  /// Merges these keys into [existing] (keeping any other secret keys).
  Map<String, String> toSecrets([Map<String, String> existing = const {}]) => {
        ...existing,
        keyConsumerKey: consumerKey,
        keyConsumerSecret: consumerSecret,
        keyToken: token,
        keyTokenSecret: tokenSecret,
      };

  /// Never prints the keys.
  @override
  String toString() => 'OAuth1Credentials(****)';
}

/// Signs requests with OAuth 1.0a (RFC 5849), HMAC-SHA1 only, the one method
/// both X and Tumblr accept, sent in the `Authorization` header.
///
/// What goes into the signature: the method, the URL without its query, the
/// query parameters, and the body parameters only when the body is
/// `application/x-www-form-urlencoded` (pass them as `form`). JSON and
/// multipart bodies are not signed (RFC 5849 section 3.4.1.3.1), which is
/// what X's and Tumblr's servers expect.
class OAuth1Signer {
  /// [clock] gives the timestamp (the AdapterContext clock, so tests are
  /// deterministic); [nonce] replaces the random nonce in tests.
  OAuth1Signer(this.credentials, {required Clock clock, String Function()? nonce})
      : _clock = clock,
        _nonce = nonce ?? OAuth1.randomNonce;

  final OAuth1Credentials credentials;
  final Clock _clock;
  final String Function() _nonce;

  /// The `Authorization` header value for one request. Every call makes a
  /// new nonce, so call it again for a retry.
  String authorization(String method, Uri url, {Map<String, String> form = const {}}) => OAuth1.authorizationHeader(
        method: method,
        url: url,
        consumerKey: credentials.consumerKey,
        consumerSecret: credentials.consumerSecret,
        token: credentials.token,
        tokenSecret: credentials.tokenSecret,
        form: form,
        nonce: _nonce(),
        timestamp: _clock().millisecondsSinceEpoch ~/ 1000,
      );

  /// `{'Authorization': ...}` for [authorization].
  Map<String, String> headers(String method, Uri url, {Map<String, String> form = const {}}) =>
      {'Authorization': authorization(method, url, form: form)};
}

/// The pieces of RFC 5849 signing, public so tests can check each step
/// against published examples.
class OAuth1 {
  OAuth1._();

  static const String signatureMethod = 'HMAC-SHA1';
  static const String version = '1.0';

  /// RFC 3986 percent-encoding as RFC 5849 section 3.6 requires: only
  /// `A-Z a-z 0-9 - . _ ~` stay as they are, everything else becomes `%XX`
  /// (upper-case hex) of its UTF-8 bytes. Stricter than `Uri.encodeComponent`,
  /// which leaves `!*'()` alone, and unlike form encoding a space is `%20`.
  static String percentEncode(String s) {
    final out = StringBuffer();
    for (final b in utf8.encode(s)) {
      final unreserved = (b >= 0x30 && b <= 0x39) || // 0-9
          (b >= 0x41 && b <= 0x5A) || // A-Z
          (b >= 0x61 && b <= 0x7A) || // a-z
          b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E; // - . _ ~
      if (unreserved) {
        out.writeCharCode(b);
      } else {
        out
          ..write('%')
          ..write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return out.toString();
  }

  /// The base string URI (section 3.4.1.2): lower-case scheme and host, the
  /// port only when it is not the scheme's default, the path, no query.
  static String baseUri(Uri url) {
    final scheme = url.scheme.toLowerCase();
    final host = url.host.toLowerCase();
    final defaultPort = (scheme == 'http' && url.port == 80) || (scheme == 'https' && url.port == 443);
    final port = !url.hasPort || defaultPort ? '' : ':${url.port}';
    final path = url.path.isEmpty ? '/' : url.path;
    return '$scheme://$host$port$path';
  }

  /// The signature base string (section 3.4.1): method, base URI and the
  /// normalized parameters (each name and value encoded, sorted by name then
  /// value, joined with `=` and `&`), each of the three encoded again.
  static String baseString(String method, Uri url, Iterable<MapEntry<String, String>> params) {
    final encoded = [for (final p in params) MapEntry(percentEncode(p.key), percentEncode(p.value))]
      ..sort((a, b) {
        final byName = a.key.compareTo(b.key);
        return byName != 0 ? byName : a.value.compareTo(b.value);
      });
    final normalized = encoded.map((p) => '${p.key}=${p.value}').join('&');
    return '${method.toUpperCase()}&${percentEncode(baseUri(url))}&${percentEncode(normalized)}';
  }

  /// HMAC-SHA1 of [baseString] keyed with `consumerSecret&tokenSecret` (both
  /// encoded; an empty token secret still keeps the `&`), base64.
  static String signature(String baseString, String consumerSecret, [String tokenSecret = '']) {
    final key = '${percentEncode(consumerSecret)}&${percentEncode(tokenSecret)}';
    return base64Encode(Hmac(sha1, utf8.encode(key)).convert(utf8.encode(baseString)).bytes);
  }

  /// The complete `Authorization` header value: `OAuth ` and the protocol
  /// parameters, signature included, as `name="value"` pairs (encoded,
  /// sorted, separated by `, `). [form] are the parameters of an
  /// `application/x-www-form-urlencoded` body; never pass JSON or multipart
  /// fields. Query parameters are taken from [url].
  static String authorizationHeader({
    required String method,
    required Uri url,
    required String consumerKey,
    required String consumerSecret,
    String? token,
    String tokenSecret = '',
    Map<String, String> form = const {},
    required String nonce,
    required int timestamp,
  }) {
    final oauth = <String, String>{
      'oauth_consumer_key': consumerKey,
      'oauth_nonce': nonce,
      'oauth_signature_method': signatureMethod,
      'oauth_timestamp': '$timestamp',
      if (token != null && token.isNotEmpty) 'oauth_token': token,
      'oauth_version': version,
    };
    final params = <MapEntry<String, String>>[
      // Query parameters are form-decoded (`+` is a space), section 3.4.1.3.1.
      for (final q in url.queryParametersAll.entries)
        for (final v in q.value) MapEntry(q.key, v),
      ...form.entries,
      ...oauth.entries,
    ];
    oauth['oauth_signature'] = signature(baseString(method, url, params), consumerSecret, tokenSecret);
    final names = oauth.keys.toList()..sort();
    return 'OAuth ${names.map((n) => '${percentEncode(n)}="${percentEncode(oauth[n]!)}"').join(', ')}';
  }

  static const String _nonceAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  /// 32 random letters and digits: unique per request, as X and Tumblr use
  /// the nonce to refuse a request they have already seen.
  static String randomNonce() {
    final r = Random.secure();
    return String.fromCharCodes(List.generate(32, (_) => _nonceAlphabet.codeUnitAt(r.nextInt(_nonceAlphabet.length))));
  }

  /// Splits an `Authorization: OAuth ...` value back into its parameters
  /// (decoded). For tests and diagnostics; null when it is not OAuth.
  static Map<String, String>? parseAuthorization(String? header) {
    if (header == null || !header.startsWith('OAuth ')) return null;
    final out = <String, String>{};
    for (final m in RegExp(r'([A-Za-z0-9_\-.~%]+)="([^"]*)"').allMatches(header.substring(6))) {
      out[Uri.decodeComponent(m.group(1)!)] = Uri.decodeComponent(m.group(2)!);
    }
    return out;
  }
}
