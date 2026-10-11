import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// `x-amz-content-sha256` value for presigned URLs and streaming uploads.
const String unsignedPayload = 'UNSIGNED-PAYLOAD';

/// SHA-256 of an empty body (used for GET/DELETE requests).
const String emptyPayloadHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Lower-case hex SHA-256 of [bytes].
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// The pieces of one header-based SigV4 signature. [headers] are the headers
/// the caller must add to the request (`Authorization`, `x-amz-date`,
/// `x-amz-content-sha256`); the intermediate strings are exposed so tests can
/// compare them with the AWS documentation examples.
@immutable
class SigV4Signature {
  const SigV4Signature({
    required this.canonicalRequest,
    required this.stringToSign,
    required this.signature,
    required this.authorization,
    required this.headers,
  });

  final String canonicalRequest;
  final String stringToSign;
  final String signature;
  final String authorization;
  final Map<String, String> headers;
}

/// AWS Signature Version 4 (`AWS4-HMAC-SHA256`) for S3-compatible services.
///
/// Implements the algorithm from "Authenticating Requests: Using the
/// Authorization Header (AWS Signature Version 4)" and "Authenticating
/// Requests: Using Query Parameters" in the Amazon S3 API reference: build the
/// canonical request, hash it into the string to sign, derive the signing key
/// from the secret via the date/region/service HMAC chain, and sign.
class SigV4Signer {
  const SigV4Signer({
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.region,
    this.service = 's3',
  });

  final String accessKeyId;
  final String secretAccessKey;
  final String region;
  final String service;

  /// Signs a request with an `Authorization` header.
  ///
  /// [headers] are the request headers that should be covered by the
  /// signature (for example `content-type`); `host`, `x-amz-date` and
  /// `x-amz-content-sha256` are added automatically. [payloadHash] is the hex
  /// SHA-256 of the body, or [unsignedPayload].
  SigV4Signature sign({
    required String method,
    required Uri uri,
    required DateTime now,
    Map<String, String> headers = const {},
    String payloadHash = emptyPayloadHash,
  }) {
    final amzDate = formatAmzDate(now);
    final all = <String, String>{
      for (final e in headers.entries) e.key.toLowerCase(): e.value,
      'host': headers['host'] ?? hostHeader(uri),
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash,
    };
    final names = all.keys.toList()..sort();
    final signedHeaders = names.join(';');
    final canonicalHeaders = names.map((n) => '$n:${_trimHeader(all[n]!)}\n').join();
    final canonical = [
      method.toUpperCase(),
      canonicalUri(uri),
      canonicalQuery(uri.queryParametersAll),
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');
    final scope = _scope(amzDate);
    final toSign = _stringToSign(amzDate, scope, canonical);
    final signature = _hmacHex(signingKey(amzDate.substring(0, 8)), toSign);
    final authorization =
        'AWS4-HMAC-SHA256 Credential=$accessKeyId/$scope,SignedHeaders=$signedHeaders,Signature=$signature';
    return SigV4Signature(
      canonicalRequest: canonical,
      stringToSign: toSign,
      signature: signature,
      authorization: authorization,
      headers: {
        'Authorization': authorization,
        'x-amz-date': amzDate,
        'x-amz-content-sha256': payloadHash,
      },
    );
  }

  /// Builds a presigned URL (query-string authentication) that is valid for
  /// [expires] (S3 allows at most 7 days). Only `host` is signed and the
  /// payload is [unsignedPayload], as the S3 documentation prescribes.
  Uri presign({
    required String method,
    required Uri uri,
    required DateTime now,
    required Duration expires,
  }) {
    final amzDate = formatAmzDate(now);
    final scope = _scope(amzDate);
    final params = <String, List<String>>{
      ...uri.queryParametersAll,
      'X-Amz-Algorithm': ['AWS4-HMAC-SHA256'],
      'X-Amz-Credential': ['$accessKeyId/$scope'],
      'X-Amz-Date': [amzDate],
      'X-Amz-Expires': ['${expires.inSeconds}'],
      'X-Amz-SignedHeaders': ['host'],
    };
    final query = canonicalQuery(params);
    final canonical = [
      method.toUpperCase(),
      canonicalUri(uri),
      query,
      'host:${hostHeader(uri)}\n',
      'host',
      unsignedPayload,
    ].join('\n');
    final signature = _hmacHex(signingKey(amzDate.substring(0, 8)), _stringToSign(amzDate, scope, canonical));
    final port = uri.hasPort ? ':${uri.port}' : '';
    return Uri.parse('${uri.scheme}://${uri.host}$port${canonicalUri(uri)}?$query&X-Amz-Signature=$signature');
  }

  /// `kSigning = HMAC(HMAC(HMAC(HMAC("AWS4"+secret, date), region), service), "aws4_request")`.
  @visibleForTesting
  Uint8List signingKey(String yyyymmdd) {
    var key = _hmac(utf8.encode('AWS4$secretAccessKey'), yyyymmdd);
    key = _hmac(key, region);
    key = _hmac(key, service);
    return _hmac(key, 'aws4_request');
  }

  String _scope(String amzDate) => '${amzDate.substring(0, 8)}/$region/$service/aws4_request';

  static String _stringToSign(String amzDate, String scope, String canonical) =>
      ['AWS4-HMAC-SHA256', amzDate, scope, sha256Hex(utf8.encode(canonical))].join('\n');

  static Uint8List _hmac(List<int> key, String data) =>
      Uint8List.fromList(Hmac(sha256, key).convert(utf8.encode(data)).bytes);

  static String _hmacHex(List<int> key, String data) => Hmac(sha256, key).convert(utf8.encode(data)).toString();

  static String _trimHeader(String v) => v.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// `YYYYMMDD'T'HHMMSS'Z'` in UTC.
  static String formatAmzDate(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
  }

  /// The `Host` header value the HTTP client will send for [uri].
  static String hostHeader(Uri uri) => uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;

  /// The canonical URI: every path segment URI-encoded once ('/' kept), as S3
  /// requires (S3 does not double-encode).
  static String canonicalUri(Uri uri) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    return path.split('/').map((s) => uriEncode(_decode(s))).join('/');
  }

  /// Sorted `key=value` pairs, both URI-encoded (slashes too).
  static String canonicalQuery(Map<String, List<String>> params) {
    final pairs = <List<String>>[
      for (final e in params.entries)
        for (final v in (e.value.isEmpty ? const [''] : e.value)) [uriEncode(e.key), uriEncode(v)],
    ]..sort((a, b) {
        final c = a[0].compareTo(b[0]);
        return c != 0 ? c : a[1].compareTo(b[1]);
      });
    return pairs.map((p) => '${p[0]}=${p[1]}').join('&');
  }

  /// RFC 3986 encoding as SigV4 defines it: unreserved characters
  /// `A-Z a-z 0-9 - . _ ~` stay, everything else becomes `%XX` (upper case).
  static String uriEncode(String input) {
    final out = StringBuffer();
    for (final b in utf8.encode(input)) {
      final unreserved = (b >= 0x41 && b <= 0x5A) ||
          (b >= 0x61 && b <= 0x7A) ||
          (b >= 0x30 && b <= 0x39) ||
          b == 0x2D ||
          b == 0x2E ||
          b == 0x5F ||
          b == 0x7E;
      if (unreserved) {
        out.writeCharCode(b);
      } else {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  static String _decode(String segment) {
    try {
      return Uri.decodeComponent(segment);
    } on ArgumentError {
      return segment;
    } on FormatException {
      return segment;
    }
  }
}
