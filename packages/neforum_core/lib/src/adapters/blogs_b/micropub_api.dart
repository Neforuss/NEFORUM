import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import 'blogs_common.dart';

/// Normalises what the user typed as their site ("example.com",
/// "https://Example.com") into an IndieAuth profile URL
/// (`https://example.com/`): scheme added, host lower-cased, path at least
/// `/`, no fragment. Throws [ConnectException] when unusable.
Uri canonicalMe(String raw) {
  var s = raw.trim();
  if (s.isEmpty) throw const ConnectException('Enter your site address, e.g. alice.micro.blog', field: 'me');
  if (!s.contains('://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty || (u.scheme != 'https' && u.scheme != 'http') || u.userInfo.isNotEmpty) {
    throw ConnectException('"$raw" is not a valid site address', field: 'me');
  }
  return Uri(
    scheme: u.scheme,
    host: u.host.toLowerCase(),
    port: u.hasPort ? u.port : null,
    path: u.path.isEmpty ? '/' : u.path,
    query: u.hasQuery ? u.query : null,
  );
}

/// One `rel` target found on a page (HTTP `Link` header or HTML `<link>`).
@immutable
class RelLink {
  const RelLink(this.rel, this.href);
  final String rel;
  final Uri href;
}

/// Parses an HTTP `Link` header (RFC 8288) into rel/href pairs. A link with
/// `rel="a b"` yields one entry per rel value. Relative targets are resolved
/// against [base].
List<RelLink> parseLinkHeader(String? header, Uri base) {
  if (header == null || header.trim().isEmpty) return const [];
  final out = <RelLink>[];
  final re = RegExp(r'<([^>]*)>((?:\s*;\s*[^;,"]+=(?:"[^"]*"|[^;,]*))*)');
  for (final m in re.allMatches(header)) {
    final target = Uri.tryParse(m.group(1)!.trim());
    if (target == null) continue;
    final params = m.group(2) ?? '';
    final rel = RegExp(r'''rel\s*=\s*(?:"([^"]*)"|([^;,\s]+))''', caseSensitive: false).firstMatch(params);
    final rels = (rel?.group(1) ?? rel?.group(2) ?? '').toLowerCase().split(RegExp(r'\s+'));
    for (final r in rels.where((r) => r.isNotEmpty)) {
      out.add(RelLink(r, base.resolveUri(target)));
    }
  }
  return out;
}

/// Finds `<link rel=... href=...>` elements in [html] (document order).
List<RelLink> parseHtmlLinks(String html, Uri base) {
  final out = <RelLink>[];
  final effectiveBase = _htmlBase(html, base);
  for (final m in RegExp(r'<link\b[^>]*>', caseSensitive: false).allMatches(html)) {
    final tag = m.group(0)!;
    final rel = _attr(tag, 'rel');
    final href = _attr(tag, 'href');
    if (rel == null || href == null) continue;
    final target = Uri.tryParse(_unescapeHtml(href.trim()));
    if (target == null) continue;
    for (final r in rel.toLowerCase().split(RegExp(r'\s+')).where((r) => r.isNotEmpty)) {
      out.add(RelLink(r, effectiveBase.resolveUri(target)));
    }
  }
  return out;
}

Uri _htmlBase(String html, Uri base) {
  final m = RegExp(r'<base\b[^>]*>', caseSensitive: false).firstMatch(html);
  final href = m == null ? null : _attr(m.group(0)!, 'href');
  final u = href == null ? null : Uri.tryParse(_unescapeHtml(href.trim()));
  return u == null ? base : base.resolveUri(u);
}

String? _attr(String tag, String name) {
  final m = RegExp('\\s$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))', caseSensitive: false).firstMatch(tag);
  return m == null ? null : (m.group(1) ?? m.group(2) ?? m.group(3));
}

String _unescapeHtml(String s) =>
    s.replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&lt;', '<').replaceAll('&gt;', '>');

/// What discovery found on the user's profile URL.
@immutable
class MicropubDiscovery {
  const MicropubDiscovery({
    required this.me,
    this.metadataUrl,
    this.issuer,
    this.authorizationEndpoint,
    this.tokenEndpoint,
    this.revocationEndpoint,
    this.micropub,
    this.issParameterSupported = false,
  });

  final Uri me;
  final Uri? metadataUrl;
  final String? issuer;
  final Uri? authorizationEndpoint;
  final Uri? tokenEndpoint;
  final Uri? revocationEndpoint;
  final Uri? micropub;
  final bool issParameterSupported;
}

/// Discovers IndieAuth and Micropub endpoints for [me]: HTTP `Link` headers
/// first, then HTML `<link>` elements; `indieauth-metadata` wins over the
/// legacy `authorization_endpoint`/`token_endpoint` rels.
Future<MicropubDiscovery> discoverMicropub(Uri me, AdapterContext ctx) async {
  ctx.progress('Looking up ${me.host}');
  final NeforumResponse res;
  try {
    res = await ctx.http.get(me, headers: const {'Accept': 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.5'});
  } on HttpFailure catch (f) {
    throw ConnectException('${me.host} answered HTTP ${f.statusCode}. Check your site address.', field: 'me');
  } on Exception catch (e) {
    throw ConnectException('Could not reach ${me.host}: $e', field: 'me');
  }
  final links = <RelLink>[...parseLinkHeader(res.headers['link'], me)];
  final ct = res.headers['content-type'] ?? '';
  if (ct.contains('html') || ct.isEmpty) links.addAll(parseHtmlLinks(res.body, me));
  Uri? first(String rel) {
    for (final l in links) {
      if (l.rel == rel) return l.href;
    }
    return null;
  }

  final metadataUrl = first('indieauth-metadata');
  if (metadataUrl != null) {
    final meta = await _fetchMetadata(metadataUrl, ctx);
    return MicropubDiscovery(
      me: me,
      metadataUrl: metadataUrl,
      issuer: blogStr(meta['issuer']),
      authorizationEndpoint: _uri(meta['authorization_endpoint'], metadataUrl),
      tokenEndpoint: _uri(meta['token_endpoint'], metadataUrl),
      revocationEndpoint: _uri(meta['revocation_endpoint'], metadataUrl),
      micropub: first('micropub'),
      issParameterSupported: meta['authorization_response_iss_parameter_supported'] == true,
    );
  }
  return MicropubDiscovery(
    me: me,
    authorizationEndpoint: first('authorization_endpoint'),
    tokenEndpoint: first('token_endpoint'),
    micropub: first('micropub'),
  );
}

Future<Map<String, dynamic>> _fetchMetadata(Uri url, AdapterContext ctx) async {
  try {
    final r = await ctx.http.get(url, headers: const {'Accept': 'application/json'});
    final j = r.jsonMap;
    if (j.isEmpty) throw const FormatException('not JSON');
    return j;
  } on HttpFailure catch (f) {
    throw ConnectException('Your IndieAuth metadata at $url answered HTTP ${f.statusCode}.');
  } on FormatException {
    throw ConnectException('Your IndieAuth metadata at $url is not valid JSON.');
  } on Exception catch (e) {
    throw ConnectException('Could not read your IndieAuth metadata at $url: $e');
  }
}

Uri? _uri(Object? v, Uri base) {
  final s = blogStr(v);
  if (s == null) return null;
  final u = Uri.tryParse(s);
  return u == null ? null : base.resolveUri(u);
}

/// Encodes ordered (name, value) pairs as `application/x-www-form-urlencoded`
/// so that array properties (`category[]`) can repeat.
String encodeFormPairs(List<MapEntry<String, String>> pairs) =>
    pairs.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');

/// A file part for [encodeMultipart].
@immutable
class MultipartFile {
  const MultipartFile(this.field, this.fileName, this.contentType, this.bytes);
  final String field;
  final String fileName;
  final String contentType;
  final Uint8List bytes;
}

/// Encodes a `multipart/form-data` body with repeatable text fields. Returns
/// the body and the matching Content-Type header value.
({Uint8List body, String contentType}) encodeMultipart(
  List<MapEntry<String, String>> fields,
  List<MultipartFile> files, {
  String? boundary,
}) {
  final b = boundary ?? 'neforum-${List.generate(16, (_) => Random.secure().nextInt(16).toRadixString(16)).join()}';
  final out = BytesBuilder(copy: false);
  String q(String s) => s.replaceAll('"', '%22').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
  for (final f in fields) {
    out
      ..add(utf8.encode('--$b\r\nContent-Disposition: form-data; name="${q(f.key)}"\r\n\r\n'))
      ..add(utf8.encode(f.value))
      ..add(utf8.encode('\r\n'));
  }
  for (final f in files) {
    out
      ..add(utf8.encode('--$b\r\nContent-Disposition: form-data; name="${q(f.field)}"; filename="${q(f.fileName)}"\r\n'
          'Content-Type: ${f.contentType}\r\n\r\n'))
      ..add(f.bytes)
      ..add(utf8.encode('\r\n'));
  }
  out.add(utf8.encode('--$b--\r\n'));
  return (body: out.toBytes(), contentType: 'multipart/form-data; boundary=$b');
}

/// Maps a failed Micropub / media-endpoint call onto a [PublishError] using
/// the spec's `{error, error_description}` body.
PublishError micropubError(HttpFailure f, {required String context}) {
  final base = f.toPublishError(context: context);
  final body = f.response.jsonMap;
  final code = blogStr(body['error']);
  final desc = blogStr(body['error_description']);
  final detail = desc == null ? '' : ' ($desc)';
  final raw = base.raw;
  final status = f.statusCode;
  if (status == 429) {
    return PublishError.quota('$context: rate limited$detail', raw: raw, statusCode: status, retryAfter: f.response.retryAfter);
  }
  switch (code) {
    case 'unauthorized':
    case 'invalid_token':
      return PublishError.auth('$context: your site rejected the access token; reconnect the account$detail',
          raw: raw, statusCode: status);
    case 'insufficient_scope':
      return PublishError.auth('$context: the token lacks the needed permission (scope "create"/"media"); reconnect$detail',
          raw: raw, statusCode: status);
    case 'forbidden':
      return PublishError.auth('$context: your site says this account may not post here$detail', raw: raw, statusCode: status);
    case 'invalid_request':
      return PublishError.validation('$context: your site rejected the post$detail', raw: raw, statusCode: status);
  }
  if (desc != null && status < 500) {
    return PublishError(kind: base.kind, message: '${base.message}$detail', raw: raw, statusCode: status, retryable: base.retryable);
  }
  return base;
}
