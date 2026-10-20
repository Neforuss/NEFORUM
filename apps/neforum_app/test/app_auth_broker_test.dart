// How sign-in comes back on each OS: the loopback relay phones and Macs use
// for Google "Desktop app" clients (exercised over real HTTP on 127.0.0.1),
// and the broker around it, with the OS auth session stood in.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/app_auth_broker.dart';
import 'package:neforum_app/platform/loopback_relay.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// flutter_test answers every HttpClient request with 400; these tests need
/// the real client to reach the real server.
class _RealHttp extends HttpOverrides {}

HttpClient _client() => HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());

/// GETs [url] like a browser would, without following redirects.
Future<({int status, String? location, String body})> _get(HttpClient client, Uri url) async {
  final req = await client.getUrl(url);
  req.followRedirects = false;
  final res = await req.close();
  final body = await utf8.decodeStream(res);
  return (status: res.statusCode, location: res.headers.value(HttpHeaders.locationHeader), body: body);
}

/// A port nothing listens on right now.
Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// Records whether the broker restarted or closed it, and what it passed on.
class _FakeRelay implements LoopbackRelay {
  _FakeRelay(this.redirectUri);
  @override
  final Uri redirectUri;
  @override
  Uri? received;
  bool closed = false;
  int restarts = 0;
  @override
  Future<void> restart() async => restarts++;
  @override
  Future<void> close() async => closed = true;
}

final Uri _authUrl = Uri.parse('https://accounts.example/o/oauth2/auth?client_id=test&state=xyz');

AppAuthBroker _broker(
  TargetPlatform platform, {
  AuthSession? session,
  LoopbackRelayStarter? startRelay,
  ResumeWatcher? watchResume,
  Future<void> Function(Uri url)? openUrl,
  Future<String?> Function(Uri authorizationUrl, Uri redirectUri)? askPaste,
}) =>
    AppAuthBroker(
      openUrl: openUrl ?? (_) async => fail('the external browser should stay closed'),
      askPaste: askPaste ?? (_, _) async => fail('nothing should ask for a paste'),
      authSession: session ?? (_, _, _) async => fail('the auth session should stay closed'),
      startRelay: startRelay,
      // No Flutter binding in these tests: the app never leaves the front.
      watchResume: watchResume ?? (_) => () {},
      platform: platform,
    );

void main() {
  group('loopback relay', () {
    test('answers the sign-in return with a redirect to neforum://callback carrying the same query', () async {
      final port = await _freePort();
      final relay = await startLoopbackRelay(Uri.parse('http://127.0.0.1:$port/callback'), callback: AppAuthBroker.customSchemeRedirect);
      addTearDown(relay.close);
      final client = _client();
      addTearDown(() => client.close(force: true));

      expect(relay.received, isNull);
      final res = await _get(client, Uri.parse('http://127.0.0.1:$port/callback?code=abc&state=xyz'));
      expect(res.status, HttpStatus.found);
      expect(res.location, 'neforum://callback?code=abc&state=xyz');
      // A browser that does not follow the redirect shows a link instead.
      expect(res.body, contains('href="neforum://callback?code=abc&amp;state=xyz"'));
      expect(relay.received?.queryParameters, {'code': 'abc', 'state': 'xyz'});

      // An error from the platform travels the same way.
      final denied = await _get(client, Uri.parse('http://127.0.0.1:$port/callback?error=access_denied&state=xyz'));
      expect(denied.location, 'neforum://callback?error=access_denied&state=xyz');
    });

    test('answers other paths with 404', () async {
      final port = await _freePort();
      final relay = await startLoopbackRelay(Uri.parse('http://127.0.0.1:$port/callback'), callback: AppAuthBroker.customSchemeRedirect);
      addTearDown(relay.close);
      final client = _client();
      addTearDown(() => client.close(force: true));

      expect((await _get(client, Uri.parse('http://127.0.0.1:$port/favicon.ico'))).status, HttpStatus.notFound);
      expect((await _get(client, Uri.parse('http://127.0.0.1:$port/callback/extra?code=abc'))).status, HttpStatus.notFound);
      expect(relay.received, isNull);
    });

    test('on localhost, answers over 127.0.0.1 too', () async {
      final port = await _freePort();
      final relay = await startLoopbackRelay(Uri.parse('http://localhost:$port/callback'), callback: AppAuthBroker.customSchemeRedirect);
      addTearDown(relay.close);
      final client = _client();
      addTearDown(() => client.close(force: true));

      final res = await _get(client, Uri.parse('http://127.0.0.1:$port/callback?code=abc&state=xyz'));
      expect(res.location, 'neforum://callback?code=abc&state=xyz');
    });

    test('lets go of the port when closed', () async {
      final port = await _freePort();
      final redirect = Uri.parse('http://127.0.0.1:$port/callback');
      final relay = await startLoopbackRelay(redirect, callback: AppAuthBroker.customSchemeRedirect);
      final client = _client();
      expect((await _get(client, Uri.parse('$redirect?code=abc&state=xyz'))).status, HttpStatus.found);
      client.close(force: true);

      await relay.close();
      await relay.close(); // twice is fine
      final after = _client();
      addTearDown(() => after.close(force: true));
      await expectLater(_get(after, Uri.parse('$redirect?code=abc')), throwsA(isA<SocketException>()));
      // The next sign-in can open it again.
      final next = await startLoopbackRelay(redirect, callback: AppAuthBroker.customSchemeRedirect);
      await next.close();
    });

    test('a restart keeps what it passed on and answers on the same port again', () async {
      final port = await _freePort();
      final redirect = Uri.parse('http://127.0.0.1:$port/callback');
      final relay = await startLoopbackRelay(redirect, callback: AppAuthBroker.customSchemeRedirect);
      addTearDown(relay.close);
      final before = _client();
      expect((await _get(before, Uri.parse('$redirect?code=abc&state=xyz'))).status, HttpStatus.found);
      before.close(force: true);

      await relay.restart();
      expect(relay.received?.queryParameters, {'code': 'abc', 'state': 'xyz'});
      // Two at once (a return from the background and a lost socket) are fine.
      await Future.wait([relay.restart(), relay.restart()]);
      expect(relay.received?.queryParameters, {'code': 'abc', 'state': 'xyz'});

      final after = _client();
      addTearDown(() => after.close(force: true));
      final res = await _get(after, Uri.parse('$redirect?code=def&state=xyz'));
      expect(res.status, HttpStatus.found);
      expect(res.location, 'neforum://callback?code=def&state=xyz');
      expect(relay.received?.queryParameters, {'code': 'def', 'state': 'xyz'});
    });

    test('on localhost, a restart answers over 127.0.0.1 again', () async {
      final port = await _freePort();
      final relay = await startLoopbackRelay(Uri.parse('http://localhost:$port/callback'), callback: AppAuthBroker.customSchemeRedirect);
      addTearDown(relay.close);
      await relay.restart();
      final client = _client();
      addTearDown(() => client.close(force: true));

      final res = await _get(client, Uri.parse('http://127.0.0.1:$port/callback?code=abc&state=xyz'));
      expect(res.location, 'neforum://callback?code=abc&state=xyz');
    });

    test('restarting a closed relay does nothing', () async {
      final port = await _freePort();
      final redirect = Uri.parse('http://127.0.0.1:$port/callback');
      final relay = await startLoopbackRelay(redirect, callback: AppAuthBroker.customSchemeRedirect);
      await relay.close();
      await relay.restart();

      final client = _client();
      addTearDown(() => client.close(force: true));
      await expectLater(_get(client, Uri.parse('$redirect?code=abc')), throwsA(isA<SocketException>()));
      final next = await startLoopbackRelay(redirect, callback: AppAuthBroker.customSchemeRedirect);
      await next.close();
    });

    test('closing during a restart still lets go of the port', () async {
      final port = await _freePort();
      final redirect = Uri.parse('http://127.0.0.1:$port/callback');
      final relay = await startLoopbackRelay(redirect, callback: AppAuthBroker.customSchemeRedirect);
      final restarting = relay.restart();
      await relay.close();
      await restarting;

      final client = _client();
      addTearDown(() => client.close(force: true));
      await expectLater(_get(client, Uri.parse('$redirect?code=abc')), throwsA(isA<SocketException>()));
      final next = await startLoopbackRelay(redirect, callback: AppAuthBroker.customSchemeRedirect);
      await next.close();
    });

    test('says clearly when the port is taken', () async {
      final holder = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(holder.close);
      final error = await startLoopbackRelay(Uri.parse('http://127.0.0.1:${holder.port}/callback'), callback: AppAuthBroker.customSchemeRedirect)
          .then<Object?>((r) async {
        await r.close();
        return null;
      }, onError: (Object e) => e);
      expect(error, isA<LoopbackRelayUnavailable>());
      expect('$error', contains('${holder.port}'));
      expect('$error', contains('cannot receive the sign-in'));
    });

    test('explains reserved and refused ports', () {
      expect('${const LoopbackRelayUnavailable(52771, errorCode: 10013)}', contains('Windows has reserved port 52771'));
      expect('${const LoopbackRelayUnavailable(52771, errorCode: 13)}', contains('refused to open port 52771'));
      expect('${const LoopbackRelayUnavailable(52771, errorCode: 48)}', contains('in use by another app'));
    });
  });

  group('AppAuthBroker on phones and Macs', () {
    test('a loopback redirect goes through the relay and comes back as the loopback address', () async {
      final port = await _freePort();
      final redirect = Uri.parse('http://127.0.0.1:$port/callback');
      final client = _client();
      addTearDown(() => client.close(force: true));
      final calls = <(Uri, String)>[];
      final broker = _broker(TargetPlatform.iOS, session: (url, callbackScheme, timeout) async {
        calls.add((url, callbackScheme));
        // The browser: Google sends it to the loopback address, the relay
        // (already listening) sends it on to neforum://callback, and the
        // session catches that.
        final res = await _get(client, Uri.parse('$redirect?code=abc&state=xyz'));
        expect(res.status, HttpStatus.found);
        client.close(force: true);
        return res.location!;
      });

      final back = await broker.authorize(_authUrl, redirect);
      expect(back, Uri.parse('$redirect?code=abc&state=xyz'));
      expect(calls, [(_authUrl, 'neforum')]);

      // The relay is gone: the next sign-in can listen there again.
      final next = await startLoopbackRelay(redirect, callback: AppAuthBroker.customSchemeRedirect);
      await next.close();
    });

    test('returns the original redirect with the callback query, so the state check passes', () async {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS]) {
        _FakeRelay? relay;
        final broker = _broker(
          platform,
          startRelay: (redirectUri, callback) async {
            expect(callback, AppAuthBroker.customSchemeRedirect);
            return relay = _FakeRelay(redirectUri);
          },
          session: (url, callbackScheme, timeout) async {
            expect(relay, isNotNull, reason: 'the relay listens before the session opens');
            expect(callbackScheme, 'neforum');
            return 'neforum://callback?code=abc&state=xyz';
          },
        );

        final redirect = AppAuthBroker.loopbackRedirect;
        final back = await broker.authorize(_authUrl, redirect);
        expect(back, Uri.parse('http://127.0.0.1:52771/callback?code=abc&state=xyz'), reason: '$platform');
        expect(relay!.redirectUri, redirect);
        expect(relay!.closed, isTrue, reason: '$platform');

        final client = OAuth2Client(
          authorizationEndpoint: Uri.parse('https://accounts.example/o/oauth2/auth'),
          tokenEndpoint: Uri.parse('https://accounts.example/token'),
          clientId: 'test',
        );
        final request = AuthorizationRequest(_authUrl, 'xyz', null);
        expect(client.extractCode(back, request), 'abc');
      }
    });

    test('the session has no deadline of its own, and the relay listens until it ends', () async {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS]) {
        final relay = _FakeRelay(AppAuthBroker.loopbackRedirect);
        final broker = _broker(
          platform,
          startRelay: (_, _) async => relay,
          session: (_, _, timeout) async {
            // The user takes longer than the timeout to sign in; nothing on
            // the Dart side can close the sheet, so nothing gives up on it.
            await Future<void>.delayed(timeout * 4);
            expect(relay.closed, isFalse, reason: 'the browser may yet come back to the relay ($platform)');
            return 'neforum://callback?code=abc&state=xyz';
          },
        );

        final back = await broker.authorize(_authUrl, AppAuthBroker.loopbackRedirect, timeout: const Duration(milliseconds: 20));
        expect(back, Uri.parse('http://127.0.0.1:52771/callback?code=abc&state=xyz'), reason: '$platform');
        expect(relay.closed, isTrue, reason: '$platform');
      }
    });

    test('a neforum:// sign-in has no deadline either', () async {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS]) {
        final broker = _broker(platform, session: (_, _, timeout) async {
          await Future<void>.delayed(timeout * 4);
          return 'neforum://callback?code=abc&state=xyz';
        });

        final back = await broker.authorize(_authUrl, AppAuthBroker.customSchemeRedirect, timeout: const Duration(milliseconds: 20));
        expect(back, Uri.parse('neforum://callback?code=abc&state=xyz'), reason: '$platform');
      }
    });

    test('back from the background, the relay listens afresh while the session runs', () async {
      final relay = _FakeRelay(AppAuthBroker.loopbackRedirect);
      void Function()? onReturn;
      var watching = false;
      final broker = _broker(
        TargetPlatform.iOS,
        startRelay: (_, _) async => relay,
        watchResume: (callback) {
          onReturn = callback;
          watching = true;
          return () => watching = false;
        },
        session: (_, _, _) async {
          expect(watching, isTrue);
          // The user approved the sign-in in the Google app and came back.
          onReturn!();
          expect(relay.restarts, 1);
          expect(relay.closed, isFalse);
          return 'neforum://callback?code=abc&state=xyz';
        },
      );

      final back = await broker.authorize(_authUrl, AppAuthBroker.loopbackRedirect);
      expect(back.queryParameters, {'code': 'abc', 'state': 'xyz'});
      expect(watching, isFalse, reason: 'stops watching once the session ends');
      expect(relay.closed, isTrue);
    });

    test('a cancelled sign-in stops watching the app too', () async {
      final relay = _FakeRelay(AppAuthBroker.loopbackRedirect);
      var watching = false;
      final broker = _broker(
        TargetPlatform.android,
        startRelay: (_, _) async => relay,
        watchResume: (_) {
          watching = true;
          return () => watching = false;
        },
        session: (_, _, _) async => throw PlatformException(code: 'CANCELED'),
      );

      await expectLater(broker.authorize(_authUrl, AppAuthBroker.loopbackRedirect), throwsA(isA<AuthCancelled>()));
      expect(watching, isFalse);
      expect(relay.closed, isTrue);
    });

    test('only a return from the background restarts the relay, not one from a system alert', () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      void go(List<AppLifecycleState> states) {
        for (final s in states) {
          binding.handleAppLifecycleStateChanged(s);
        }
      }

      go([AppLifecycleState.resumed]);
      final relay = _FakeRelay(AppAuthBroker.loopbackRedirect);
      final opened = Completer<void>();
      final finish = Completer<String>();
      // The real lifecycle watcher, not a stand-in.
      final broker = AppAuthBroker(
        openUrl: (_) async => fail('the external browser should stay closed'),
        askPaste: (_, _) async => fail('nothing should ask for a paste'),
        authSession: (_, _, _) {
          opened.complete();
          return finish.future;
        },
        startRelay: (_, _) async => relay,
        platform: TargetPlatform.iOS,
      );
      final back = broker.authorize(_authUrl, AppAuthBroker.loopbackRedirect);
      await opened.future;

      // "NEFORUM wants to use google.com to sign in": inactive, then back.
      go([AppLifecycleState.inactive, AppLifecycleState.resumed]);
      expect(relay.restarts, 0);

      // Off to the Google app to approve the sign-in, then back.
      final away = [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ];
      go(away);
      expect(relay.restarts, 1);
      go([AppLifecycleState.inactive, AppLifecycleState.resumed]);
      expect(relay.restarts, 1);

      finish.complete('neforum://callback?code=abc&state=xyz');
      expect((await back).queryParameters, {'code': 'abc', 'state': 'xyz'});
      expect(relay.closed, isTrue);

      // The session is over: the app coming back no longer touches the relay.
      go(away);
      expect(relay.restarts, 1);
    });

    test('closing the sign-in becomes AuthCancelled and closes the relay', () async {
      final relay = _FakeRelay(AppAuthBroker.loopbackRedirect);
      final broker = _broker(
        TargetPlatform.android,
        startRelay: (_, _) async => relay,
        session: (_, _, _) async => throw PlatformException(code: 'CANCELED', message: 'User canceled login'),
      );

      await expectLater(broker.authorize(_authUrl, AppAuthBroker.loopbackRedirect), throwsA(isA<AuthCancelled>()));
      expect(relay.closed, isTrue);
    });

    test('an answer the relay already passed on survives a closed sign-in', () async {
      final relay = _FakeRelay(AppAuthBroker.loopbackRedirect)
        ..received = Uri.parse('http://127.0.0.1:52771/callback?code=abc&state=xyz');
      final broker = _broker(
        TargetPlatform.android,
        startRelay: (_, _) async => relay,
        session: (_, _, _) async => throw PlatformException(code: 'CANCELED'),
      );

      expect(await broker.authorize(_authUrl, AppAuthBroker.loopbackRedirect), Uri.parse('http://127.0.0.1:52771/callback?code=abc&state=xyz'));
      expect(relay.closed, isTrue);
    });

    test('other errors pass through and still close the relay', () async {
      final relay = _FakeRelay(AppAuthBroker.loopbackRedirect);
      final broker = _broker(
        TargetPlatform.android,
        startRelay: (_, _) async => relay,
        session: (_, _, _) async => throw PlatformException(code: 'NO_BROWSER', message: 'No valid browser available'),
      );

      await expectLater(broker.authorize(_authUrl, AppAuthBroker.loopbackRedirect), throwsA(isA<PlatformException>()));
      expect(relay.closed, isTrue);
    });

    test('a port that cannot be opened stops before the session opens', () async {
      final broker = _broker(
        TargetPlatform.iOS,
        startRelay: (_, _) async => throw const LoopbackRelayUnavailable(52771, errorCode: 48),
      );

      await expectLater(broker.authorize(_authUrl, AppAuthBroker.loopbackRedirect), throwsA(isA<LoopbackRelayUnavailable>()));
    });

    test('the session catches custom schemes: any on iOS and macOS, only neforum on Android', () async {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        String? caught;
        final broker = _broker(platform, session: (url, callbackScheme, timeout) async {
          caught = callbackScheme;
          return 'com.example.app:/oauth2redirect?code=abc&state=xyz';
        });
        final back = await broker.authorize(_authUrl, Uri.parse('com.example.app:/oauth2redirect'));
        expect(caught, 'com.example.app', reason: '$platform');
        expect(back.queryParameters['code'], 'abc');
      }

      final android = _broker(TargetPlatform.android, session: (url, callbackScheme, timeout) async {
        expect(callbackScheme, 'neforum');
        return 'neforum://callback?code=abc&state=xyz';
      });
      expect(await android.authorize(_authUrl, AppAuthBroker.customSchemeRedirect), Uri.parse('neforum://callback?code=abc&state=xyz'));

      // CallbackActivity only declares neforum://: anything else is pasted.
      final opened = <Uri>[];
      final other = _broker(
        TargetPlatform.android,
        openUrl: (url) async => opened.add(url),
        askPaste: (_, _) async => 'com.example.app:/oauth2redirect?code=abc&state=xyz',
      );
      expect((await other.authorize(_authUrl, Uri.parse('com.example.app:/oauth2redirect'))).queryParameters['code'], 'abc');
      expect(opened, [_authUrl]);
    });

    test('an out-of-band redirect is pasted, not given to the session', () async {
      final broker = _broker(
        TargetPlatform.iOS,
        openUrl: (_) async {},
        askPaste: (_, _) async => 'the-code',
      );
      final back = await broker.authorize(_authUrl, AppAuthBroker.outOfBandRedirect);
      expect(back.queryParameters['code'], 'the-code');
    });
  });

  group('AppAuthBroker on Windows and Linux', () {
    test('a loopback redirect still uses the loopback server and the system browser', () async {
      final port = await _freePort();
      final redirect = Uri.parse('http://127.0.0.1:$port/callback');
      final client = _client();
      addTearDown(() => client.close(force: true));
      final opened = <Uri>[];
      final broker = _broker(TargetPlatform.windows, openUrl: (url) async {
        opened.add(url);
        // The browser comes back to the loopback server.
        final res = await _get(client, Uri.parse('$redirect?code=abc&state=xyz'));
        expect(res.status, HttpStatus.ok);
      });

      final back = await broker.authorize(_authUrl, redirect);
      expect('$back', startsWith('$redirect?'));
      expect(back.queryParameters, {'code': 'abc', 'state': 'xyz'});
      expect(opened, [_authUrl]);
    });

    test('neforum:// is not given to the session', () async {
      final broker = _broker(TargetPlatform.linux, openUrl: (_) async {}, askPaste: (_, _) async => 'the-code');
      final back = await broker.authorize(_authUrl, AppAuthBroker.customSchemeRedirect);
      expect(back.queryParameters['code'], 'the-code');
    });
  });

  group('chooseRedirectUri', () {
    test('a Google "Desktop app" client gets the loopback address on every device', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
        final broker = _broker(platform);
        expect(broker.chooseRedirectUri(loopbackOk: true, customSchemeOk: false), Uri.parse('http://127.0.0.1:52771/callback'),
            reason: '$platform');
      }
    });

    test('phones and Macs prefer neforum://callback when the platform allows it', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS]) {
        expect(_broker(platform).chooseRedirectUri(), AppAuthBroker.customSchemeRedirect, reason: '$platform');
      }
      expect(_broker(TargetPlatform.windows).chooseRedirectUri(), AppAuthBroker.loopbackRedirect);
      expect(_broker(TargetPlatform.windows).chooseRedirectUri(loopbackOk: false), AppAuthBroker.outOfBandRedirect);
      final fixed = Uri.parse('https://example.com/done');
      expect(_broker(TargetPlatform.iOS).chooseRedirectUri(fixed: fixed), fixed);
    });
  });
}
