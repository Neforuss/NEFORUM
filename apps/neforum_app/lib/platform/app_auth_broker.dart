import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'env.dart';
import 'loopback_relay.dart';

/// Shows [url] in the OS auth session (ASWebAuthenticationSession on iOS and
/// macOS, a Custom Tab on Android) and completes with the first address that
/// uses [callbackUrlScheme]. Tests put a stand-in here.
typedef AuthSession = Future<String> Function(Uri url, String callbackUrlScheme, Duration timeout);

/// Opens a [LoopbackRelay] on [redirectUri] that sends the browser on to
/// [callback]. Tests put a stand-in here.
typedef LoopbackRelayStarter = Future<LoopbackRelay> Function(Uri redirectUri, Uri callback);

/// Calls `onReturn` each time the app comes back to the front from the
/// background (hidden or paused, not merely inactive behind a system alert)
/// until the returned function is called. Tests put a stand-in here.
typedef ResumeWatcher = VoidCallback Function(VoidCallback onReturn);

/// Picks the right way to catch an OAuth redirect on each OS:
///
/// * Windows / Linux: a loopback server on http://127.0.0.1:52771/callback
///   (RFC 8252) and the system browser.
/// * Android / iOS / macOS: the OS auth session (Custom Tabs /
///   ASWebAuthenticationSession). It catches a custom-scheme redirect
///   (`neforum://callback`; on iOS and macOS any custom scheme) by itself. A
///   loopback redirect (Google "Desktop app" clients accept nothing else)
///   goes through a [LoopbackRelay] that forwards the browser to
///   `neforum://callback`, which the session catches: an iPhone app is
///   suspended while Safari is in front, so a loopback server behind the
///   external browser would never answer. iOS can also take a suspended
///   app's listening socket away (the user approves the sign-in in the
///   Google app, say), so the relay listens afresh when the app comes back.
/// * Platforms that insist on an HTTPS redirect: open the browser, then let
///   the user paste the address they landed on.
class AppAuthBroker implements AuthBroker {
  AppAuthBroker({
    required this.openUrl,
    required this.askPaste,
    AuthSession? authSession,
    LoopbackRelayStarter? startRelay,
    ResumeWatcher? watchResume,
    this._platform,
  })  : _authSession = authSession ?? _flutterWebAuth,
        _startRelay = startRelay ?? _startLoopbackRelay,
        _watchResume = watchResume ?? _watchAppResume;

  /// Opens a URL in the system browser.
  final Future<void> Function(Uri url) openUrl;

  /// Shows a dialog asking the user to paste the final redirect URL (or the
  /// code). Returns null when cancelled.
  final Future<String?> Function(Uri authorizationUrl, Uri redirectUri) askPaste;

  final AuthSession _authSession;
  final LoopbackRelayStarter _startRelay;
  final ResumeWatcher _watchResume;

  /// Stands in for the OS in tests; null means the one NEFORUM runs on.
  final TargetPlatform? _platform;

  static const String scheme = 'neforum';
  static final Uri customSchemeRedirect = Uri.parse('$scheme://callback');
  static final Uri loopbackRedirect = Uri(scheme: 'http', host: '127.0.0.1', port: LoopbackAuthBroker.defaultPort, path: '/callback');

  /// The redirect to register with the platform, by preference:
  ///
  /// 1. [fixed], when the platform dictates one.
  /// 2. `neforum://callback` on Android, iOS and macOS, when [customSchemeOk].
  /// 3. [loopbackRedirect] (http://127.0.0.1:52771/callback), when
  ///    [loopbackOk], everywhere but web: Windows and Linux catch it with a
  ///    loopback server, Android, iOS and macOS through the relay (see
  ///    [authorize]). A Google "Desktop app" client passes
  ///    `loopbackOk: true, customSchemeOk: false` and gets this on every
  ///    device.
  /// 4. `neforum://callback` on other native platforms, when [customSchemeOk].
  /// 5. [outOfBandRedirect]: the platform shows a code the user pastes.
  @override
  Uri chooseRedirectUri({bool loopbackOk = true, bool customSchemeOk = true, Uri? fixed}) {
    if (fixed != null) return fixed;
    if (_hasAuthSession && customSchemeOk) return customSchemeRedirect;
    if (loopbackOk && Env.canListenLoopback) return loopbackRedirect;
    // Windows and Linux builds cannot receive neforum:// links.
    if (customSchemeOk && _os != null && !_isWindowsOrLinux) return customSchemeRedirect;
    // Nothing we can catch automatically: the platform shows the code (or
    // the password) and the user pastes it.
    return outOfBandRedirect;
  }

  /// RFC-style "out of band" redirect: the platform displays the result.
  static final Uri outOfBandRedirect = Uri.parse('urn:ietf:wg:oauth:2.0:oob');

  /// http://127.0.0.1 or http://localhost, on any port.
  static bool isLoopbackRedirect(Uri uri) => uri.scheme == 'http' && (uri.host == '127.0.0.1' || uri.host == 'localhost');

  static final RegExp _schemePattern = RegExp(r'^[a-z][a-z\d+.-]*$');

  /// A redirect scheme only an app can catch: not http(s), and not the `urn`
  /// of [outOfBandRedirect] (the platform shows the code instead).
  static bool isCustomScheme(String s) => _schemePattern.hasMatch(s) && !const {'http', 'https', 'urn'}.contains(s);

  /// Completes with the redirect the platform sent the user back to. On
  /// Android, iOS and macOS a loopback redirect comes back as [redirectUri]
  /// itself with the query the platform added (`code`, `state` or `error`),
  /// exactly as the Windows loopback server returns it, so
  /// OAuth2Client.extractCode and its state check work unchanged.
  ///
  /// Throws [AuthCancelled] when the user closes the sign-in, or when
  /// [timeout] passes, except in the OS auth session on Android, iOS and
  /// macOS, which waits, however long, until the redirect comes back or the
  /// user closes it. Throws [LoopbackRelayUnavailable] when a phone or Mac
  /// cannot open the redirect's port.
  @override
  Future<Uri> authorize(Uri authorizationUrl, Uri redirectUri, {Duration timeout = const Duration(minutes: 5)}) async {
    if (_sessionCatches(redirectUri.scheme)) {
      return Uri.parse(await _runSession(authorizationUrl, redirectUri.scheme, timeout));
    }

    final isLoopback = isLoopbackRedirect(redirectUri);
    if (isLoopback && _hasAuthSession) return _authorizeThroughRelay(authorizationUrl, redirectUri, timeout);

    if (isLoopback && Env.canListenLoopback) {
      final loop = LoopbackAuthBroker(
        openBrowser: openUrl,
        port: redirectUri.hasPort ? redirectUri.port : LoopbackAuthBroker.defaultPort,
        host: redirectUri.host,
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

  /// The platform redirects the browser to [redirectUri], where the relay
  /// answers with a redirect to `neforum://callback` and the same query; the
  /// auth session catches that and hands it back.
  Future<Uri> _authorizeThroughRelay(Uri authorizationUrl, Uri redirectUri, Duration timeout) async {
    // Listening before the session opens: a signed-in user comes back within
    // a second.
    final relay = await _startRelay(redirectUri, customSchemeRedirect);
    VoidCallback? stopWatching;
    try {
      // Back from the background (the user approved the sign-in in the
      // Google app, say), iOS may have taken the socket: listen afresh.
      stopWatching = _watchResume(() => unawaited(relay.restart()));
      final back = Uri.parse(await _runSession(authorizationUrl, scheme, timeout));
      return _withAnswer(redirectUri, back);
    } on AuthCancelled {
      // The browser reached the relay but did not open neforum:// (one that
      // asks first, and the user closed it or let it wait instead): the
      // answer is here all the same.
      final seen = relay.received;
      if (seen != null) return _withAnswer(redirectUri, seen);
      rethrow;
    } finally {
      // Only once the session has ended: the sheet may still be open until
      // then, and the browser in it may yet come back to the relay.
      stopWatching?.call();
      await relay.close();
    }
  }

  /// Runs the auth session until it catches the redirect or the user closes
  /// it, which becomes [AuthCancelled]. No deadline of its own: the session
  /// ignores [timeout] on Android, iOS and macOS, and giving up here would
  /// leave the sheet open with nobody waiting for it.
  Future<String> _runSession(Uri url, String callbackUrlScheme, Duration timeout) async {
    try {
      return await _authSession(url, callbackUrlScheme, timeout);
    } on AuthCancelled {
      rethrow;
    } on Object catch (e) {
      final msg = e.toString();
      if (msg.contains('CANCELED') || msg.contains('cancel')) throw const AuthCancelled();
      rethrow;
    }
  }

  /// [redirectUri] carrying the query (and fragment) of [back].
  static Uri _withAnswer(Uri redirectUri, Uri back) => redirectUri.replace(
        query: back.query.isEmpty ? null : back.query,
        fragment: back.fragment.isEmpty ? null : back.fragment,
      );

  static Future<String> _flutterWebAuth(Uri url, String callbackUrlScheme, Duration timeout) =>
      FlutterWebAuth2.authenticate(
        url: url.toString(),
        callbackUrlScheme: callbackUrlScheme,
        options: FlutterWebAuth2Options(timeout: timeout.inSeconds, preferEphemeral: false),
      );

  static Future<LoopbackRelay> _startLoopbackRelay(Uri redirectUri, Uri callback) =>
      startLoopbackRelay(redirectUri, callback: callback);

  /// Back from hidden or paused counts as a return; back from inactive alone
  /// (a system alert, such as "NEFORUM wants to use google.com to sign in")
  /// does not, since nothing was suspended.
  static VoidCallback _watchAppResume(VoidCallback onReturn) {
    var away = false;
    final listener = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.resumed) {
          if (away) onReturn();
          away = false;
        } else if (state != AppLifecycleState.inactive) {
          away = true;
        }
      },
    );
    return listener.dispose;
  }

  /// The OS, or null on web.
  TargetPlatform? get _os => _platform ?? (Env.isWeb ? null : defaultTargetPlatform);

  bool get _isApple => _os == TargetPlatform.iOS || _os == TargetPlatform.macOS;

  bool get _isWindowsOrLinux => _os == TargetPlatform.windows || _os == TargetPlatform.linux;

  /// Android, iOS and macOS show sign-in in an OS auth session.
  bool get _hasAuthSession => _isApple || _os == TargetPlatform.android;

  /// Can the OS auth session catch a redirect to [s] by itself? On iOS and
  /// macOS, ASWebAuthenticationSession catches any custom scheme, registered
  /// or not; on Android only `neforum`, the one scheme flutter_web_auth_2's
  /// CallbackActivity declares in AndroidManifest.xml.
  bool _sessionCatches(String s) {
    if (_os == null || _isWindowsOrLinux) return false;
    if (_isApple) return isCustomScheme(s);
    return s == scheme;
  }
}
