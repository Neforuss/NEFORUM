import 'dart:typed_data';

import '../../http/neforum_http.dart';
import '../../model/audio.dart';
import '../../model/media.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../text/url_detector.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';

/// Helpers shared by the WordPress, Ghost and WriteFreely adapters.

/// Reads a media file, turning a missing or unreadable file into an
/// [AdapterException] so `publish` can report it instead of throwing.
Future<Uint8List> readBlogMedia(AdapterContext ctx, MediaAttachment m) async {
  try {
    return await ctx.readMedia(m);
  } on Exception catch (e) {
    throw AdapterException(PublishError.configuration('Could not read ${m.fileName ?? m.path}: $e'));
  }
}

/// Last-resort mapping for an exception that escaped an adapter's helpers,
/// so `publish` always returns a failure instead of throwing.
PublishError unexpectedBlogError(String platform, Exception e) {
  if (e is HttpFailure) return e.toPublishError(context: platform);
  if (NeforumHttp.isTransportError(e)) return PublishError.network('$platform: $e', raw: '$e');
  return PublishError.platform('$platform: $e', raw: '$e');
}

/// True when [r] is an HTML page (a proxy, firewall or theme 404) rather
/// than an answer from the blog's API.
bool isHtmlResponse(NeforumResponse r) => (r.headers['content-type'] ?? '').toLowerCase().contains('html');

/// Normalises what the user typed as a blog address into `scheme://host[/path]`
/// without a trailing slash, query or fragment.
///
/// Accepts bare hosts (`example.com`), full URLs and URLs pointing into the
/// admin area (`https://example.com/wp-admin/`, `https://x.ghost.io/ghost/#/`),
/// which are cut back to the site root. Plain `http://` is only accepted for
/// local development hosts because the credentials travel in every request.
Uri parseBlogSiteUrl(String input, {String field = 'site', String what = 'site address'}) {
  var s = input.trim();
  if (s.isEmpty) throw ConnectException('Enter your $what.', field: field);
  if (!s.contains('://')) s = 'https://$s';
  final Uri u;
  try {
    u = Uri.parse(s);
  } on FormatException {
    throw ConnectException('"$input" is not a valid web address.', field: field);
  }
  if ((u.scheme != 'https' && u.scheme != 'http') || u.host.isEmpty || !_hostLooksValid(u.host)) {
    throw ConnectException('"$input" is not a valid web address.', field: field);
  }
  if (u.scheme == 'http' && !isLocalDevHost(u.host)) {
    throw ConnectException(
        'NEFORUM only connects to blogs over https:// because your password is sent with every request. '
        'Use the https:// address of your $what.',
        field: field);
  }
  var path = u.path;
  for (final marker in const ['/wp-admin', '/wp-json', '/wp-login.php', '/ghost/', '/api/']) {
    final i = path.indexOf(marker);
    if (i >= 0) path = path.substring(0, i);
  }
  if (path.endsWith('/ghost')) path = path.substring(0, path.length - '/ghost'.length);
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return Uri(scheme: u.scheme, host: u.host.toLowerCase(), port: u.hasPort ? u.port : null, path: path);
}

bool _hostLooksValid(String host) =>
    host == 'localhost' || host.contains('.') || host.startsWith('[') || RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host);

/// Hosts where plain http is acceptable (local test installs).
bool isLocalDevHost(String host) =>
    host == 'localhost' ||
    host == '127.0.0.1' ||
    host == '[::1]' ||
    host == '::1' ||
    host.endsWith('.localhost') ||
    host.endsWith('.test') ||
    host.endsWith('.local');

/// Appends [segment] to [base]'s path (no double slashes).
Uri joinPath(Uri base, String segment, [Map<String, String>? query]) {
  final b = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
  final s = segment.startsWith('/') ? segment : '/$segment';
  return base.replace(path: '$b$s', queryParameters: query == null || query.isEmpty ? null : query);
}

/// Non-empty string or `null`.
String? blogStr(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

/// Integer from a JSON number or numeric string.
int? blogInt(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

/// Map view of a JSON value, or `null`.
Map<String, dynamic>? blogMap(Object? v) => v is Map ? Map<String, dynamic>.from(v) : null;

/// List view of a JSON value (empty when not a list).
List<Object?> blogList(Object? v) => v is List ? List<Object?>.from(v) : const [];

/// Truncated response body for [PublishError.raw].
String bodySnippet(NeforumResponse r) => r.body.length > 600 ? '${r.body.substring(0, 600)}…' : r.body;

// ----------------------------------------------------------------- HTML

/// Escapes text for use inside HTML element content and attribute values.
String escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

/// Decodes the handful of entities WordPress uses in term names.
String decodeBasicEntities(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#039;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

/// Converts NEFORUM's plain composer text into simple, safe HTML:
///
/// * blank lines separate paragraphs (`<p>`), single newlines become `<br>`;
/// * paragraphs whose lines all start with `- ` or `* ` become a `<ul>`;
/// * a paragraph that is a single `# `..`###### ` line becomes a heading;
/// * `http(s)://` URLs become links; everything else is HTML-escaped.
String plainTextToHtml(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (normalized.isEmpty) return '';
  final blocks = normalized.split(RegExp(r'\n[ \t]*\n+'));
  final out = <String>[];
  for (final raw in blocks) {
    final block = raw.trim();
    if (block.isEmpty) continue;
    final lines = block.split('\n').map((l) => l.trimRight()).toList();
    final heading = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(block);
    if (lines.length == 1 && heading != null) {
      final level = heading.group(1)!.length;
      out.add('<h$level>${linkifyEscaped(heading.group(2)!.trim())}</h$level>');
    } else if (lines.every((l) => RegExp(r'^\s*[-*]\s+').hasMatch(l))) {
      final items = lines.map((l) => '<li>${linkifyEscaped(l.replaceFirst(RegExp(r'^\s*[-*]\s+'), ''))}</li>');
      out.add('<ul>\n${items.join('\n')}\n</ul>');
    } else {
      out.add('<p>${lines.map(linkifyEscaped).join('<br>\n')}</p>');
    }
  }
  return out.join('\n\n');
}

/// Escapes [line] and turns `http(s)://` URLs into `<a href>` links.
String linkifyEscaped(String line) {
  final buf = StringBuffer();
  var pos = 0;
  for (final u in UrlDetector.find(line).where((u) => u.hasScheme)) {
    if (u.start < pos) continue;
    buf.write(escapeHtml(line.substring(pos, u.start)));
    final href = escapeHtml(u.text);
    buf.write('<a href="$href">$href</a>');
    pos = u.end;
  }
  buf.write(escapeHtml(line.substring(pos)));
  return buf.toString();
}

/// HTML for one uploaded media file embedded in a post body.
String mediaFigureHtml(MediaAttachment m, String url,
    {String imageClass = 'wp-block-image', String videoClass = 'wp-block-video', String audioClass = 'wp-block-audio'}) {
  final src = escapeHtml(url);
  if (m.isAudio) {
    return '<figure class="$audioClass"><audio controls src="$src"></audio></figure>';
  }
  if (m.isVideo) {
    return '<figure class="$videoClass"><video controls src="$src"></video></figure>';
  }
  final alt = escapeHtml((m.altText ?? '').trim());
  return '<figure class="$imageClass"><img src="$src" alt="$alt"/></figure>';
}

/// True when the variant asks for its text to be sent as raw HTML
/// (`extra['format'] == 'html'` or `extra['html'] == true`).
bool wantsRawHtml(PostVariant v) => v.extra['html'] == true || v.extra['format'] == 'html';

/// The post body as HTML: raw when requested, otherwise converted.
String bodyHtml(PostVariant v) => wantsRawHtml(v) ? v.text.trim() : plainTextToHtml(v.text);

/// The full text of a variant (threads joined), for clipboards.
String fullText(PostVariant v) => v.isThread ? v.threadParts.join('\n\n') : v.text;

/// File name that is safe in a `Content-Disposition` header.
String safeFileName(MediaAttachment m) {
  final raw = (m.fileName ?? '').trim();
  final base = raw.isEmpty ? '${m.id}.${extensionForMime(m.mimeType)}' : raw;
  final cleaned = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (cleaned.isEmpty || !cleaned.contains('.')) {
    return '${cleaned.isEmpty ? 'upload' : cleaned}.${extensionForMime(m.mimeType)}';
  }
  return cleaned;
}

/// A sensible file extension for a MIME type.
String extensionForMime(String mime) {
  final audio = canonicalAudioMimeType(mime);
  if (audio != null) return audioExtensionFor(audio);
  final sub = mime.split('/').last.toLowerCase();
  return switch (sub) {
    'jpeg' => 'jpg',
    'svg+xml' => 'svg',
    'quicktime' => 'mov',
    'x-m4v' => 'm4v',
    _ => sub,
  };
}

/// Normalised `scheme://host[:port][/path]` of [u] (lower-case host, no
/// trailing slash, query or fragment), for comparing blog addresses.
Uri blogOrigin(Uri u) {
  var path = u.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return Uri(scheme: u.scheme, host: u.host.toLowerCase(), port: u.hasPort ? u.port : null, path: path);
}

/// UTC timestamp formatted `YYYY-MM-DDTHH:MM:SS` (no zone suffix), as the
/// WordPress `date_gmt` field expects.
String isoSecondsUtc(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}';
}
