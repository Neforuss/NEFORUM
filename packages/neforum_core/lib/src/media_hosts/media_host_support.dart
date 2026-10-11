import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../http/neforum_http.dart';
import '../model/media.dart';
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
    throw MediaHostException('Timed out while trying to $what', hostId: hostId);
  } on http.ClientException catch (e) {
    throw MediaHostException('Could not $what: ${e.message}', hostId: hostId);
  } on Object catch (e) {
    throw MediaHostException('Could not $what: $e', hostId: hostId);
  }
}

/// First 200 characters of a response body, for error messages.
String bodySnippet(NeforumResponse r) {
  final b = r.body.trim();
  return b.length > 200 ? '${b.substring(0, 200)}…' : b;
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
