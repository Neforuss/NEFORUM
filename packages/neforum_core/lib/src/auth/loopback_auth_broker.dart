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
    final server = await HttpServer.bind(host, port, shared: true);
    _log.info('Listening for OAuth redirect on $loopbackUri');
    final completer = Completer<Uri>();
    late final StreamSubscription<HttpRequest> sub;
    sub = server.listen((req) async {
      if (req.uri.path != redirectUri.path) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final full = redirectUri.replace(query: req.uri.query, fragment: req.uri.fragment);
      req.response.headers.contentType = ContentType.html;
      req.response.write(_landingPage(full.queryParameters.containsKey('error')));
      await req.response.close();
      if (!completer.isCompleted) completer.complete(full);
    });
    try {
      await openBrowser(authorizationUrl);
      return await completer.future.timeout(timeout, onTimeout: () => throw const AuthCancelled('Timed out waiting for the browser'));
    } finally {
      await sub.cancel();
      await server.close(force: true);
    }
  }

  static String _landingPage(bool failed) => '''
<!doctype html><html><head><meta charset="utf-8"><title>NEFORUM</title>
<style>body{font-family:system-ui,sans-serif;display:grid;place-items:center;height:100vh;margin:0;background:#111;color:#eee}
main{text-align:center;max-width:32rem;padding:2rem}</style></head>
<body><main><h1>${failed ? 'Sign-in failed' : 'Signed in'}</h1>
<p>${failed ? 'The platform returned an error. Go back to NEFORUM for details.' : 'You can close this window and return to NEFORUM.'}</p></main>
<script>setTimeout(()=>window.close(),1500)</script></body></html>''';
}
