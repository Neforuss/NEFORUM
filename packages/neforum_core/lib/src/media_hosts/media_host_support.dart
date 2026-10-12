import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../http/neforum_http.dart';
import '../model/media.dart';
import '../util/logger.dart';
import 'media_host.dart';

/// Shared helpers for the built-in [MediaHost] implementations.
///
/// Not exported from the package barrel; hosts use these internally.

const Map<String, String> _extensionByMime = {
  'image/jpeg': '.jpg',
  'image/png': '.png',
  'image/gif': '.gif',
  'image/webp': '.webp',
  'image/heic': '.heic',
  'image/avif': '.avif',
  'video/mp4': '.mp4',
  'video/quicktime': '.mov',
  'video/webm': '.webm',
  'text/plain': '.txt',
};

/// File extension (with dot, lower case) for [media]: from the MIME type
/// first, because that is what the host will serve, then from the file name.
String extensionFor(MediaAttachment media) {
  final known = _extensionByMime[media.mimeType.toLowerCase()];
  if (known != null) return known;
  final fromName = p.url.extension(media.fileName ?? media.path).toLowerCase();
  if (RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(fromName)) return fromName;
  final guessed = extensionFromMime(media.mimeType);
  return (guessed == null || guessed.isEmpty) ? '' : '.$guessed';
}

/// An unguessable object name like `3f2c...e1.jpg`.
String randomObjectName(MediaAttachment media, String Function() newId) => '${newId()}${extensionFor(media)}';

/// Default id generator (UUID v4 without dashes).
String defaultObjectId() => const Uuid().v4().replaceAll('-', '');

/// Fails early when [bytes] exceeds [maxBytes].
void checkSize(MediaHost host, MediaAttachment media, int length) {
  final max = host.maxBytes;
  if (max != null && length > max) {
    throw MediaHostException(
        '${media.fileName ?? 'This file'} is ${formatBytes(length)}; ${host.name} accepts at most ${formatBytes(max)}',
        hostId: host.id);
  }
}

/// "12.3 MB" style sizes for messages (decimal units).
String formatBytes(int n) {
  if (n >= 1000 * 1000 * 1000) return '${(n / 1e9).toStringAsFixed(1)} GB';
  if (n >= 1000 * 1000) return '${(n / 1e6).toStringAsFixed(1)} MB';
  if (n >= 1000) return '${(n / 1e3).toStringAsFixed(1)} kB';
  return '$n bytes';
}

/// Reads a trimmed config value, or `null` when absent/blank.
String? configValue(Map<String, String> config, String key) {
  final v = config[key]?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

/// Reads a required config value or throws a [MediaHostException] naming the
/// field the user must fill in.
String requireConfig(Map<String, String> config, String key, String label, String hostId) {
  final v = configValue(config, key);
  if (v == null) throw MediaHostException('Fill in "$label" in the media host settings', hostId: hostId);
  return v;
}

/// Parses a user-typed base URL, adding `https://` when the scheme is missing.
Uri parseUserUrl(String raw, String label, String hostId) {
  final s = raw.contains('://') ? raw : 'https://$raw';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty || (u.scheme != 'https' && u.scheme != 'http')) {
    throw MediaHostException('"$label" is not a valid web address: $raw', hostId: hostId);
  }
  return u;
}

/// `Basic base64(user:password)`.
String basicAuth(String user, String password) => 'Basic ${base64Encode(utf8.encode('$user:$password'))}';

/// Runs an HTTP call and turns transport errors (offline, DNS, timeout) into
/// a [MediaHostException] so callers see one exception type. HTTP error
/// statuses are left to the caller (use `throwOnError: false`).
Future<NeforumResponse> guardedCall(
  String hostId,
  String what,
  Future<NeforumResponse> Function() call,
) async {
  try {
    return await call();
  } on HttpFailure catch (f) {
    return f.response;
  } on MediaHostException {
    rethrow;
  } on TimeoutException {
    throw MediaHostException('Timed out while trying to $what', hostId: hostId, temporary: true);
  } on http.ClientException catch (e) {
    throw MediaHostException('Could not $what: ${e.message}', hostId: hostId, temporary: true);
  } on Object catch (e) {
    throw MediaHostException('Could not $what: $e', hostId: hostId, temporary: NeforumHttp.isTransportError(e));
  }
}

/// Pause before the single retry of a failed upload.
const Duration mediaHostRetryPause = Duration(seconds: 3);

/// HTTP statuses that mean "the host has a problem right now": every 5xx
/// except the ones that never go away by waiting (501 Not Implemented, 505
/// HTTP Version Not Supported, 507 Insufficient Storage).
bool isTemporaryStatus(int status) => status >= 500 && status <= 599 && status != 501 && status != 505 && status != 507;

/// [guardedCall] for the call that stores a file: an HTTP 5xx answer (see
/// [isTemporaryStatus]), a timeout or a network error is tried once more
/// after [pause]. 4xx answers are not retried: they will not change. Returns
/// the last response; transport errors of the second try are thrown as a
/// [MediaHostException] with `temporary: true`.
Future<NeforumResponse> guardedUpload(
  String hostId,
  String what,
  Future<NeforumResponse> Function() call, {
  MediaHostDelay delay = mediaHostDefaultDelay,
  Duration pause = mediaHostRetryPause,
  Logger? log,
}) async {
  try {
    final first = await guardedCall(hostId, what, call);
    if (!isTemporaryStatus(first.statusCode)) return first;
    log?.warn('HTTP ${first.statusCode} from ${first.url.host}; trying once more in ${pause.inSeconds}s');
  } on MediaHostException catch (e) {
    if (!e.temporary) rethrow;
    log?.warn('${e.message}; trying once more in ${pause.inSeconds}s');
  }
  await delay(pause);
  try {
    return await guardedCall(hostId, what, call);
  } on MediaHostException catch (e) {
    if (!e.temporary) rethrow;
    throw MediaHostException(
        '${e.message} (tried twice). Check your internet connection, then try again later or choose another media '
        'host in Settings.',
        hostId: e.hostId,
        temporary: true);
  }
}

/// A short, readable version of a response body for error messages: for an
/// HTML page its `<title>` (or "an error page" without one), otherwise the
/// first 200 characters.
String bodySnippet(NeforumResponse r) {
  final b = r.body.trim();
  if (looksLikeHtml(b)) return _clip(htmlTitle(b) ?? 'an error page');
  return _clip(b);
}

String _clip(String s) => s.length > 200 ? '${s.substring(0, 200)}…' : s;

/// Whether [body] is an HTML page (error pages of servers and proxies)
/// rather than text, JSON or XML.
bool looksLikeHtml(String body) {
  final t = body.trimLeft();
  final head = (t.length > 512 ? t.substring(0, 512) : t).toLowerCase();
  if (head.startsWith('<!doctype') || head.startsWith('<html')) return true;
  return head.startsWith('<?xml') && RegExp(r'<(?:!doctype\s+html|html)[\s>]').hasMatch(head);
}

/// The `<title>` of an HTML page, entity-decoded, with whitespace collapsed;
/// `null` when there is none or it is empty.
String? htmlTitle(String html) {
  final m = RegExp(r'<title(?:\s[^>]*)?>([\s\S]*?)</title\s*>', caseSensitive: false).firstMatch(html);
  if (m == null) return null;
  final title = decodeHtmlEntities(m.group(1)!).replaceAll(RegExp(r'\s+'), ' ').trim();
  return title.isEmpty ? null : title;
}

const Map<String, String> _namedEntities = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ', 'ndash': '–', 'mdash': '—',
  'hellip': '…', 'middot': '·', 'bull': '•', 'laquo': '«', 'raquo': '»', 'copy': '©',
};

/// Decodes `&amp;`, `&#39;`, `&#x2014;` and a few other common entities.
/// Unknown or invalid entities are left as they are.
String decodeHtmlEntities(String s) =>
    s.replaceAllMapped(RegExp(r'&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]+);'), (m) {
      final e = m.group(1)!;
      if (!e.startsWith('#')) return _namedEntities[e] ?? m.group(0)!;
      final hex = e.length > 1 && (e[1] == 'x' || e[1] == 'X');
      final code = int.tryParse(e.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
      if (code == null || code <= 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return m.group(0)!;
      return String.fromCharCode(code);
    });

const Map<int, String> _reasonPhrases = {
  400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 405: 'Method Not Allowed',
  408: 'Request Timeout', 409: 'Conflict', 411: 'Length Required', 412: 'Precondition Failed',
  413: 'Content Too Large', 415: 'Unsupported Media Type', 422: 'Unprocessable Content', 429: 'Too Many Requests',
  500: 'Internal Server Error', 501: 'Not Implemented', 502: 'Bad Gateway', 503: 'Service Unavailable',
  504: 'Gateway Timeout', 507: 'Insufficient Storage', 520: 'Unknown Error', 521: 'Web Server Is Down',
  522: 'Connection Timed Out', 523: 'Origin Is Unreachable', 524: 'A Timeout Occurred',
};

/// Short name of an HTTP error answer, e.g. "Internal Server Error": the
/// title of an HTML error page without its leading status code, else the
/// standard reason phrase; `null` when neither is known.
String? statusReason(NeforumResponse r) {
  final b = r.body.trim();
  final title = looksLikeHtml(b) ? htmlTitle(b) : null;
  if (title != null) {
    final rest = title
        .replaceFirst(RegExp('^(?:http\\s*)?(?:error\\s*)?${r.statusCode}(?![0-9])\\s*[|:\\-–—]?\\s*', caseSensitive: false), '')
        .trim();
    if (rest.isNotEmpty) return _clip(rest);
  }
  return _reasonPhrases[r.statusCode];
}

/// A readable message for an HTTP error answer from a media host, such as
/// "Litterbox couldn't store the file: its server answered HTTP 500 (Internal
/// Server Error). This is a problem on Litterbox's side; try again later or
/// choose another media host in Settings."
///
/// 5xx answers are blamed on the host ([side], default "[host]'s"); 4xx
/// answers say that trying again unchanged won't help. [action] is what
/// NEFORUM tried. [detail] replaces what the body says (for example an S3
/// error code); by default a text body follows the status after a colon and
/// an HTML page is reduced to its title.
String hostHttpFailure(String host, NeforumResponse r, {String action = 'store the file', String? side, String? detail}) {
  final code = r.statusCode;
  final body = r.body.trim();
  final html = looksLikeHtml(body);
  final reason = statusReason(r);
  var said = detail ?? (html || body.isEmpty ? null : bodySnippet(r));
  if (said != null) {
    said = said.trim().replaceFirst(RegExp(r'\.+$'), '');
    if (said.isEmpty || said == reason) said = null;
  }
  final status = StringBuffer('HTTP $code');
  if (reason != null) {
    status.write(' ($reason)');
  } else if (html) {
    status.write(' with an error page');
  }
  if (said != null) status.write(': $said');
  if (code >= 500) {
    return "$host couldn't $action: its server answered $status. This is a problem on ${side ?? "$host's"} side; "
        'try again later or choose another media host in Settings.';
  }
  if (code >= 400) {
    final advice = switch (code) {
      413 => 'The file is too large for $host.',
      429 => '$host is limiting uploads right now; wait a few minutes before trying again.',
      _ => "Trying again unchanged won't help; check the file's type and size and the media host settings.",
    };
    return '$host refused to $action: it answered $status. $advice';
  }
  return "$host couldn't $action: it answered $status.";
}

/// A throwaway attachment used by `verify()` probes.
MediaAttachment probeAttachment() => const MediaAttachment(
      id: 'neforum-probe',
      path: 'neforum-probe.txt',
      mimeType: 'text/plain',
      sizeBytes: 23,
      fileName: 'neforum-probe.txt',
    );

/// Body of the probe file.
List<int> probeBytes() => utf8.encode('NEFORUM media host test');
