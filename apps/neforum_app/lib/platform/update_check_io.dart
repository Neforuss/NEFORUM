import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'update_check.dart';

/// Running inside a Flatpak or a Snap, whose package manager brings updates.
bool get installedByPackageManager {
  final env = Platform.environment;
  return (env['FLATPAK_ID'] ?? '').isNotEmpty || (env['SNAP_NAME'] ?? '').isNotEmpty;
}

/// latest.json is a few kilobytes; anything far larger is not it.
const int _maximumBytes = 256 * 1024;

/// The GET behind [fetchLatestRelease]. [createClient] is for tests.
///
/// What goes out is only what HTTP needs: the URL (no query), Host,
/// `User-Agent: NEFORUM update check`, `Accept: application/json` and
/// dart:io's `Accept-Encoding: gzip`. No version, operating system, device,
/// account or identifier, and no cookies: dart:io keeps none, and this
/// client is used for this one request only.
Future<LatestRelease> fetchLatestRelease({required Uri url, HttpClient Function()? createClient}) async {
  final client = (createClient ?? HttpClient.new)()
    ..userAgent = kUpdateCheckUserAgent
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(url);
    request
      ..persistentConnection = false
      ..followRedirects = true
      ..maxRedirects = 3;
    request.headers
      ..set(HttpHeaders.userAgentHeader, kUpdateCheckUserAgent)
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..removeAll(HttpHeaders.cookieHeader);
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('latest.json answered ${response.statusCode}', uri: url);
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      bytes.addAll(chunk);
      if (bytes.length > _maximumBytes) throw const FormatException('latest.json is too large');
    }
    return LatestRelease.fromJson(jsonDecode(utf8.decode(bytes)));
  } finally {
    client.close(force: true);
  }
}
