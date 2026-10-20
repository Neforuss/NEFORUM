import 'dart:async';
import 'dart:io';

import '../util/logger.dart';
import 'auth_broker.dart';

/// Desktop / CLI broker: listens on `http://127.0.0.1:[port][path]`, opens the
/// system browser and resolves with the redirect the platform sends back.
///
/// The port is fixed (default 52771) because most platforms require the exact
/// redirect URI to be pre-registered in the developer app.
class LoopbackAuthBroker implements AuthBroker {
  LoopbackAuthBroker({
    required this.openBrowser,
    this.port = defaultPort,
    this.host = '127.0.0.1',
    this.path = '/callback',
    this.customScheme = 'neforum',
    Logger? log,
  }) : _log = log ?? Logger('auth/loopback');

  static const int defaultPort = 52771;

  /// Opens a URL in the user's browser (url_launcher in the app, `start`/
  /// `open`/`xdg-open` in the CLI).
  final Future<void> Function(Uri url) openBrowser;
  final int port;
  final String host;
  final String path;
  final String customScheme;
  final Logger _log;

  Uri get loopbackUri => Uri(scheme: 'http', host: host, port: port, path: path);

  @override
  Uri chooseRedirectUri({bool loopbackOk = true, bool customSchemeOk = true, Uri? fixed}) {
    if (fixed != null) return fixed;
    if (loopbackOk) return loopbackUri;
    // A custom scheme on desktop would need OS registration; the loopback
    // server cannot catch it. Callers should fall back to PasteCodeAuthBroker.
    return Uri(scheme: customScheme, host: 'callback');
  }

  @override
  Future<Uri> authorize(Uri authorizationUrl, Uri redirectUri,
      {Duration timeout = const Duration(minutes: 5)}) async {
    if (redirectUri.scheme != 'http' || redirectUri.port != port) {
      throw ArgumentError('LoopbackAuthBroker can only catch $loopbackUri, got $redirectUri');
    }
    final servers = await _bind();
    _log.info('Listening for OAuth redirect on $loopbackUri');
    final completer = Completer<Uri>();
    Future<void> handle(HttpRequest req) async {
      if (req.uri.path != redirectUri.path) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final full = redirectUri.replace(query: req.uri.query, fragment: req.uri.fragment);
      final q = full.queryParameters;
      req.response.headers.contentType = ContentType.html;
      req.response.write(q.containsKey('error') ? failurePage(q['error']!, q['error_description']) : _successPage);
      await req.response.close();
      if (!completer.isCompleted) completer.complete(full);
    }

    final subs = [for (final s in servers) s.listen(handle)];
    try {
      await openBrowser(authorizationUrl);
      return await completer.future.timeout(timeout, onTimeout: () => throw const AuthCancelled('Timed out waiting for the browser'));
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      for (final s in servers) {
        await s.close(force: true);
      }
    }
  }

  /// `localhost` can reach this computer over IPv4 (127.0.0.1) or IPv6 (::1),
  /// whichever the browser tries first, so listen on both. Binding the name
  /// itself would pick just one of them.
  Future<List<HttpServer>> _bind() async {
    try {
      return await _bindAll();
    } on SocketException catch (e) {
      throw LoopbackPortUnavailable(port, reserved: e.osError?.errorCode == 10013);
    }
  }

  Future<List<HttpServer>> _bindAll() async {
    if (host != 'localhost') return [await HttpServer.bind(host, port, shared: true)];
    final servers = [await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: true)];
    try {
      servers.add(await HttpServer.bind(InternetAddress.loopbackIPv6, port, v6Only: true, shared: true));
    } on SocketException {
      // No IPv6 on this computer: browsers then use 127.0.0.1.
    }
    return servers;
  }

  static const String _style = '<style>body{font-family:system-ui,sans-serif;display:grid;place-items:center;'
      'height:100vh;margin:0;background:#111;color:#eee}main{text-align:center;max-width:36rem;padding:2rem}'
      'code{background:#222;padding:.1em .35em;border-radius:4px;word-break:break-word}</style>';

  static const String _successPage = '''
<!doctype html><html><head><meta charset="utf-8"><title>NEFORUM</title>$_style</head>
<body><main><h1>Signed in</h1><p>You can close this window and return to NEFORUM.</p></main>
<script>setTimeout(()=>window.close(),1500)</script></body></html>''';

  /// What the platform sent back, so the reason is visible here too.
  static String failurePage(String error, String? description) {
    final what = [error, if (description != null && description.isNotEmpty) description].map(_escape).join(': ');
    return '''
<!doctype html><html><head><meta charset="utf-8"><title>NEFORUM</title>$_style</head>
<body><main><h1>Sign-in failed</h1><p>The platform answered: <code>$what</code></p>
<p>NEFORUM shows what to change. You can close this window.</p></main></body></html>''';
  }

  static String _escape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}

/// The sign-in return port cannot be opened. On Windows, Hyper-V (used by
/// WSL, Docker and Windows Sandbox) reserves random blocks of ports at
/// start-up ("access forbidden", 10013); the message says how to free it.
class LoopbackPortUnavailable implements Exception {
  const LoopbackPortUnavailable(this.port, {required this.reserved});
  final int port;

  /// Reserved by the system rather than used by another program.
  final bool reserved;

  @override
  String toString() => reserved
      ? 'Windows has reserved port $port (Hyper-V, used by WSL, Docker and Windows Sandbox, reserves random port blocks), '
          'so NEFORUM cannot receive the sign-in. In an administrator terminal run: net stop winnat, then '
          'netsh int ipv4 add excludedportrange protocol=tcp startport=52771 numberofports=9 store=persistent, '
          'then net start winnat. Then try again.'
      : 'Port $port is in use by another program, so NEFORUM cannot receive the sign-in. Close it (or another NEFORUM) and try again.';
}
