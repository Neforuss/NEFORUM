import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'env.dart';

/// Picks the right way to catch an OAuth redirect on each OS:
///
/// * Windows / Linux: a loopback server on http://127.0.0.1:52771/callback
///   (RFC 8252) and the system browser.
/// * Android / iOS / macOS: the `neforum://callback` custom scheme through
///   the OS auth session (Custom Tabs / ASWebAuthenticationSession), falling
///   back to loopback when a platform rejects custom schemes.
/// * Platforms that insist on an HTTPS redirect: open the browser, then let
///   the user paste the address they landed on.
class AppAuthBroker implements AuthBroker {
  AppAuthBroker({required this.openUrl, required this.askPaste});

  /// Opens a URL in the system browser.
  final Future<void> Function(Uri url) openUrl;

  /// Shows a dialog asking the user to paste the final redirect URL (or the
  /// code). Returns null when cancelled.
  final Future<String?> Function(Uri authorizationUrl, Uri redirectUri) askPaste;

  static const String scheme = 'neforum';
  static final Uri customSchemeRedirect = Uri.parse('$scheme://callback');
  static final Uri loopbackRedirect = Uri(scheme: 'http', host: '127.0.0.1', port: LoopbackAuthBroker.defaultPort, path: '/callback');

  @override
  Uri chooseRedirectUri({bool loopbackOk = true, bool customSchemeOk = true, Uri? fixed}) {
    if (fixed != null) return fixed;
    final preferCustom = Env.isMobile || Env.isMacOS;
    if (preferCustom && customSchemeOk) return customSchemeRedirect;
    if (loopbackOk && Env.canListenLoopback) return loopbackRedirect;
    if (customSchemeOk && !Env.isWeb) return customSchemeRedirect;
    // Nothing we can catch automatically: the user will paste it.
    return loopbackRedirect;
  }

  @override
  Future<Uri> authorize(Uri authorizationUrl, Uri redirectUri, {Duration timeout = const Duration(minutes: 5)}) async {
    final isLoopback = redirectUri.scheme == 'http' &&
        (redirectUri.host == '127.0.0.1' || redirectUri.host == 'localhost' || redirectUri.host == '[::1]');

    if (redirectUri.scheme == scheme && !Env.isWindows && !Env.isLinux && !Env.isWeb) {
      try {
        final result = await FlutterWebAuth2.authenticate(
          url: authorizationUrl.toString(),
          callbackUrlScheme: scheme,
          options: FlutterWebAuth2Options(timeout: timeout.inSeconds, preferEphemeral: false),
        );
        return Uri.parse(result);
      } on Object catch (e) {
        final msg = e.toString();
        if (msg.contains('CANCELED') || msg.contains('cancel')) throw const AuthCancelled();
        rethrow;
      }
    }

    if (isLoopback && Env.canListenLoopback) {
      final loop = LoopbackAuthBroker(
        openBrowser: openUrl,
        port: redirectUri.hasPort ? redirectUri.port : LoopbackAuthBroker.defaultPort,
        host: redirectUri.host == 'localhost' ? 'localhost' : '127.0.0.1',
        path: redirectUri.path.isEmpty ? '/' : redirectUri.path,
      );
      return loop.authorize(authorizationUrl, redirectUri, timeout: timeout);
    }

    // HTTPS-only platforms, or environments that cannot listen: open the
    // browser and ask the user to paste where they ended up.
    final paste = PasteCodeAuthBroker(
      redirectUri: redirectUri,
      askUser: (url, redirect) async {
        await openUrl(url);
        return askPaste(url, redirect);
      },
    );
    return paste.authorize(authorizationUrl, redirectUri, timeout: timeout);
  }
}
