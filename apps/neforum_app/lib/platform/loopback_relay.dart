import 'loopback_relay_web.dart' if (dart.library.io) 'loopback_relay_io.dart' as impl;

/// A short-lived server on an OAuth loopback redirect
/// (http://127.0.0.1:52771/callback) that answers the browser with an HTTP
/// 302 to a custom-scheme address (`neforum://callback`) carrying the same
/// query (`code`, `state`, `error`, ...).
///
/// Phones and Macs show sign-in in an OS auth session
/// (ASWebAuthenticationSession, Custom Tabs) that only catches custom
/// schemes, while Google "Desktop app" clients only accept loopback
/// redirects; the relay joins the two. See AppAuthBroker.authorize.
abstract interface class LoopbackRelay {
  /// The loopback redirect this relay answers.
  Uri get redirectUri;

  /// The last sign-in return the relay passed on (the address the browser
  /// asked for, with its query), or null while the platform has not sent the
  /// user back yet.
  Uri? get received;

  /// Closes the listener and opens it again on the same address, keeping
  /// [received]: for after the app returns from the background, since iOS
  /// can take a suspended app's listening socket away. Never throws: when the
  /// port cannot be opened again the relay stops answering until the next
  /// restart. Does nothing once [close]d.
  Future<void> restart();

  /// Stops listening. Safe to call more than once.
  Future<void> close();
}

/// Opens a relay on the host, port and path of [redirectUri] that sends the
/// browser on to [callback]. It is listening when the future completes, so
/// the sign-in can start right after. Throws [LoopbackRelayUnavailable] when
/// the port cannot be opened, and [UnsupportedError] on web.
Future<LoopbackRelay> startLoopbackRelay(Uri redirectUri, {required Uri callback}) =>
    impl.startLoopbackRelay(redirectUri, callback: callback);

/// Where the relay sends the browser: [callback] with the [query] the
/// platform put on the loopback redirect.
Uri relayTarget(Uri callback, String query) => query.isEmpty ? callback : callback.replace(query: query);

/// Sent with the redirect: a link to [target] for a browser that does not
/// follow the redirect by itself.
String relayPage(Uri target) {
  final href = target.toString().replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1"><title>NEFORUM</title>'
      '<style>body{font-family:system-ui,sans-serif;display:grid;place-items:center;height:100vh;margin:0;'
      'background:#111;color:#eee}main{text-align:center;padding:2rem}a{color:#8ab4ff}</style></head>'
      '<body><main><h1>Almost done</h1><p><a href="$href">Return to NEFORUM</a> to finish signing in.</p></main>'
      '</body></html>';
}

/// The sign-in return port cannot be opened, so NEFORUM cannot receive the
/// sign-in.
class LoopbackRelayUnavailable implements Exception {
  const LoopbackRelayUnavailable(this.port, {this.errorCode});
  final int port;

  /// The system's error number, when there was one.
  final int? errorCode;

  /// The system refused the port rather than another app using it: Windows
  /// says 10013 ("access forbidden", a port Hyper-V reserved), elsewhere
  /// EACCES (13) or EPERM (1).
  bool get refused => const {10013, 13, 1}.contains(errorCode);

  @override
  String toString() {
    if (errorCode == 10013) {
      return 'Windows has reserved port $port (Hyper-V, used by WSL, Docker and Windows Sandbox, reserves random port '
          'blocks), so NEFORUM cannot receive the sign-in. Restart the computer, or reserve the port for NEFORUM, and '
          'try again.';
    }
    if (refused) return 'This device refused to open port $port (error $errorCode), so NEFORUM cannot receive the sign-in.';
    return 'Port $port is in use by another app, so NEFORUM cannot receive the sign-in. Close the other app '
        '(or another NEFORUM) and try again.';
  }
}
