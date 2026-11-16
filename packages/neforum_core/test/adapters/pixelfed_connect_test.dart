// NEFORUM 1.4.4, Pixelfed connect: the browser sign-in checked step by step
// against what Laravel Passport (Pixelfed 0.15.2) demands, and the personal
// access token route added for servers whose Authorize page fails.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/art/pixelfed_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

const _host = 'pixelfed.example';
const _redirect = 'http://127.0.0.1:52771/callback';

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: jsonHeaders);

/// A Passport token: a JWT whose payload carries `exp` (Pixelfed's personal
/// access tokens and OAuth tokens both are).
String _jwt(DateTime exp, {String jti = 'abc123'}) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'typ': 'JWT', 'alg': 'RS256'})}.${part({'aud': '1', 'jti': jti, 'exp': exp.millisecondsSinceEpoch ~/ 1000, 'scopes': ['read', 'write']})}.c2ln';
}

final Map<String, dynamic> _instance = {
  'uri': _host,
  'title': 'Pixelfed Example',
  'version': '3.5.3 (compatible; Pixelfed 0.15.2)',
  'configuration': {
    'statuses': {'max_characters': 2000, 'max_media_attachments': 20},
    'media_attachments': {'supported_mime_types': ['image/jpeg', 'image/png'], 'image_size_limit': 15360000},
  },
};

final Map<String, dynamic> _me = {
  'id': '77',
  'username': 'painter',
  'display_name': 'Painter',
  'url': 'https://$_host/painter',
  'avatar': 'https://$_host/a.png',
};

/// A Pixelfed 0.15.2 server as far as NEFORUM sees it: Passport's rules on
/// `/oauth/authorize` and `/oauth/token`, `/api/v1/apps`, and
/// `verify_credentials` that accepts only [validTokens].
class _Pixelfed {
  _Pixelfed({Set<String> validTokens = const {}, this.verifyStatus = 200}) : validTokens = {...validTokens};

  final Set<String> validTokens;
  final int verifyStatus;
  final List<http.Request> calls = [];

  /// Clients the server knows: id -> (secret, registered redirect).
  final Map<String, (String, String)> clients = {'own-7': ('own-secret', _redirect)};
  final Map<String, String> _codes = {};
  int _next = 0;

  List<String> get trail => calls.map((c) => '${c.method} ${c.url.path}').toList();

  Future<http.Response> handle(http.Request r) async {
    calls.add(r);
    switch ('${r.method} ${r.url.path}') {
      case 'GET /api/v1/instance':
        return _json(_instance);
      case 'POST /api/v1/apps':
        final f = Uri.splitQueryString(r.body);
        final id = 'c${++_next}';
        clients[id] = ('s$_next', f['redirect_uris']!);
        return _json({'client_id': id, 'client_secret': 's$_next', 'redirect_uri': f['redirect_uris']});
      case 'POST /oauth/token':
        final f = Uri.splitQueryString(r.body);
        final client = clients[f['client_id']];
        if (client == null || client.$1 != f['client_secret']) return _json({'error': 'invalid_client'}, 401);
        if (f['grant_type'] != 'authorization_code') return _json({'error': 'unsupported_grant_type'}, 400);
        // Passport: the code, its client and the same redirect_uri as the authorize step.
        if (_codes.remove(f['code']) != f['client_id'] || f['redirect_uri'] != client.$2) {
          return _json({'error': 'invalid_grant'}, 400);
        }
        final token = _jwt(testNow.add(const Duration(days: 365)));
        validTokens.add(token);
        return _json({'token_type': 'Bearer', 'expires_in': 31536000, 'access_token': token, 'refresh_token': 'refresh-1'});
      case 'GET /api/v1/accounts/verify_credentials':
        final auth = r.headers['authorization'] ?? '';
        if (verifyStatus != 200) return _json({'error': 'This action is unauthorized.'}, verifyStatus);
        if (!auth.startsWith('Bearer ') || !validTokens.contains(auth.substring(7))) {
          return _json({'error': 'Unauthenticated.'}, 401);
        }
        return _json(_me);
    }
    return _json({'error': 'not_found'}, 404);
  }

  /// Passport's `GET /oauth/authorize` and the Authorize button: an error
  /// redirect for anything Passport refuses, else a code.
  Uri authorize(Uri url, Uri redirect) {
    expect(url.host, _host);
    expect(url.path, '/oauth/authorize', reason: 'Pixelfed serves Passport\'s authorize page here');
    final q = url.queryParameters;
    final client = clients[q['client_id']];
    if (client == null) return redirect.replace(queryParameters: {'error': 'invalid_client'});
    if (q['response_type'] != 'code') return redirect.replace(queryParameters: {'error': 'unsupported_response_type'});
    if (q['redirect_uri'] != client.$2 || q['redirect_uri'] != redirect.toString()) {
      return redirect.replace(queryParameters: {'error': 'invalid_client', 'error_description': 'redirect_uri'});
    }
    if (q['scope'] != 'read write') return redirect.replace(queryParameters: {'error': 'invalid_scope'});
    final code = 'code-${_codes.length + 1}';
    _codes[code] = q['client_id']!;
    return redirect.replace(queryParameters: {'code': code, 'state': q['state']!});
  }
}

class _Broker implements AuthBroker {
  _Broker(this.server);
  final _Pixelfed server;
  final List<Uri> opened = [];

  @override
  Uri chooseRedirectUri({bool loopbackOk = true, bool customSchemeOk = true, Uri? fixed}) => fixed ?? Uri.parse(_redirect);

  @override
  Future<Uri> authorize(Uri authorizationUrl, Uri redirectUri, {Duration timeout = const Duration(minutes: 5)}) async {
    opened.add(authorizationUrl);
    return server.authorize(authorizationUrl, redirectUri);
  }
}

void main() {
  final adapter = PixelfedAdapter(clock: () => testNow);

  group('browser sign-in, step by step as Passport checks it', () {
    test('NEFORUM registers itself, and every step carries what Passport demands', () async {
      final server = _Pixelfed();
      final broker = _Broker(server);
      final r = await adapter.connect(PlatformTier.openApi, {'instance': _host}, testContext(handler: server.handle, broker: broker));

      expect(server.trail, containsAllInOrder(['POST /api/v1/apps', 'POST /oauth/token', 'GET /api/v1/accounts/verify_credentials']));
      final app = Uri.splitQueryString(server.calls.firstWhere((c) => c.url.path == '/api/v1/apps').body);
      expect(app['redirect_uris'], _redirect, reason: 'the address registered is the one sent');
      expect(app['scopes'], 'read write');
      expect(broker.opened.single.queryParameters, containsPair('redirect_uri', _redirect));
      expect(r.account.handle, '@painter@$_host');
      expect(r.account.config['authMethod'], isNull, reason: 'a browser sign-in');
      expect(r.secrets['refresh_token'], 'refresh-1');
      expect(DateTime.parse(r.secrets['expires_at']!), testNow.add(const Duration(days: 365)));
    });

    test('the reported case: your own client ID and secret, made on the server', () async {
      final server = _Pixelfed();
      final broker = _Broker(server);
      final r = await adapter.connect(PlatformTier.openApi, {'instance': _host, 'client_id': 'own-7', 'client_secret': 'own-secret'},
          testContext(handler: server.handle, broker: broker));
      expect(server.trail, isNot(contains('POST /api/v1/apps')));
      expect(broker.opened.single.queryParameters['client_id'], 'own-7');
      final token = Uri.splitQueryString(server.calls.firstWhere((c) => c.url.path == '/oauth/token').body);
      expect(token, containsPair('redirect_uri', _redirect));
      expect(token, containsPair('client_secret', 'own-secret'));
      expect(r.secrets['client_id'], 'own-7');
    });

    test('a client registered for another address is refused with Passport\'s answer, not a hang', () async {
      final server = _Pixelfed()..clients['own-7'] = ('own-secret', 'neforum://callback');
      await expectLater(
        adapter.connect(PlatformTier.openApi, {'instance': _host, 'client_id': 'own-7', 'client_secret': 'own-secret'},
            testContext(handler: server.handle, broker: _Broker(server))),
        throwsA(isA<ConnectException>().having((e) => e.message, 'message', 'Sign-in on $_host failed: redirect_uri')),
      );
      expect(server.trail, isNot(contains('POST /oauth/token')));
    });
  });

  group('personal access token', () {
    final exp = testNow.add(const Duration(days: 365));

    test('connects with GET verify_credentials only: no app, no browser, and the token\'s own end date', () async {
      final token = _jwt(exp);
      final server = _Pixelfed(validTokens: {token});
      final broker = _Broker(server);
      final r = await adapter.connect(PlatformTier.openApi, {'instance': _host, 'access_token': '  Bearer $token\n'},
          testContext(handler: server.handle, broker: broker));

      expect(server.trail, contains('GET /api/v1/instance'));
      expect(server.trail.last, 'GET /api/v1/accounts/verify_credentials');
      expect(server.trail.where((t) => t.contains('/oauth/') || t.contains('/api/v1/apps')), isEmpty);
      expect(broker.opened, isEmpty, reason: 'no browser opens');
      expect(server.calls.last.headers['authorization'], 'Bearer $token', reason: 'the pasted "Bearer " is not doubled');
      expect(r.account.tier, PlatformTier.openApi);
      expect(r.account.handle, '@painter@$_host');
      expect(r.account.displayName, 'Painter ($_host)');
      expect(r.account.config['authMethod'], 'token');
      expect(r.account.config['software'], 'pixelfed');
      expect(r.secrets['access_token'], token);
      expect(r.secrets.containsKey('refresh_token'), isFalse);
      expect(r.secrets.containsKey('client_id'), isFalse);
      expect(DateTime.parse(r.secrets['expires_at']!), exp);
      expect(r.secrets['expires_at_source'], 'serverReported');
      expect(adapter.reconnectInput(r.account, r.secrets, redirect: Uri.parse(_redirect)), isNull,
          reason: 'a new token is something only the person can bring');
      expect(adapter.rotatesRefreshTokensFor(r.account), isFalse);
    });

    test('the end date: the earlier of the typed one and the token\'s, else one year', () {
      final token = _jwt(exp);
      final earlier = DateTime.utc(2027, 6, 1);
      expect(PixelfedAdapter.personalTokenEnd(token, earlier, now: testNow), (earlier, SignInDateSource.userEntered));
      expect(PixelfedAdapter.personalTokenEnd(token, DateTime.utc(2028), now: testNow), (exp, SignInDateSource.serverReported));
      expect(PixelfedAdapter.personalTokenEnd(token, null, now: testNow), (exp, SignInDateSource.serverReported));
      expect(PixelfedAdapter.personalTokenEnd('opaque', earlier, now: testNow), (earlier, SignInDateSource.userEntered));
      expect(PixelfedAdapter.personalTokenEnd('opaque', null, now: testNow), (testNow.add(const Duration(days: 365)), SignInDateSource.computed));
    });

    test('a typed end date is stored as the person\'s', () async {
      const token = 'opaque-token';
      final server = _Pixelfed(validTokens: {token});
      final r = await adapter.connect(
          PlatformTier.openApi, {'instance': _host, 'access_token': token, 'token_end_date': '2027-10-01'}, testContext(handler: server.handle));
      expect(r.secrets['expires_at'], '2027-10-01T00:00:00.000Z');
      expect(r.secrets['expires_at_source'], 'userEntered');
    });

    test('end dates NEFORUM cannot read are refused before any request', () async {
      for (final (typed, says) in [('next year', 'YYYY-MM-DD'), ('2027-02-30', 'YYYY-MM-DD'), ('2027-13-01', 'YYYY-MM-DD'), ('2026-10-01', 'has passed')]) {
        final server = _Pixelfed(validTokens: {'t'});
        await expectLater(
          adapter.connect(PlatformTier.openApi, {'instance': _host, 'access_token': 't', 'token_end_date': typed}, testContext(handler: server.handle)),
          throwsA(isA<ConnectException>().having((e) => (e.field, e.message.contains(says)), typed, ('token_end_date', true))),
        );
        expect(server.calls, isEmpty, reason: typed);
      }
    });

    test('a token the server refuses (401) says so on the token field', () async {
      final server = _Pixelfed(validTokens: {'good'});
      await expectLater(
        adapter.connect(PlatformTier.openApi, {'instance': _host, 'access_token': 'revoked'}, testContext(handler: server.handle)),
        throwsA(isA<ConnectException>()
            .having((e) => e.field, 'field', 'access_token')
            .having((e) => e.message, 'message', allOf(contains('HTTP 401'), contains('Personal Access Tokens')))),
      );
    });

    test('a token without read (403) asks for read and write', () async {
      final server = _Pixelfed(verifyStatus: 403);
      await expectLater(
        adapter.connect(PlatformTier.openApi, {'instance': _host, 'access_token': 't'}, testContext(handler: server.handle)),
        throwsA(isA<ConnectException>().having((e) => (e.field, e.message.contains('`read` and `write`')), 'field', ('access_token', true))),
      );
    });

    test('a Mastodon server is refused with a token too', () async {
      Future<http.Response> mastodon(http.Request r) async =>
          r.url.path == '/api/v1/instance' ? _json({'uri': 'mastodon.example', 'version': '4.5.0'}) : _json({'error': 'nope'}, 404);
      await expectLater(
        adapter.connect(PlatformTier.openApi, {'instance': 'mastodon.example', 'access_token': 't'}, testContext(handler: mastodon)),
        throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Add it as a Mastodon account'))),
      );
    });

    test('posting: the token goes as it is until its own date, then the person is told to make a new one', () async {
      final account = fakeAccount('pixelfed', config: {'instance': 'https://$_host', 'domain': _host, 'software': 'pixelfed', 'authMethod': 'token'});
      final live = {'access_token': _jwt(exp), 'expires_at': exp.toIso8601String()};
      Future<http.Response> noNetwork(http.Request r) async => fail('no request: ${r.url}');
      expect(await adapter.refreshSecrets(account, live, testContext(handler: noNetwork)), isNull);

      final after = testContext(handler: noNetwork, now: exp.add(const Duration(minutes: 1)));
      await expectLater(
        adapter.refreshSecrets(account, live, after),
        throwsA(isA<AdapterException>()
            .having((e) => e.error.kind, 'kind', PublishErrorKind.auth)
            .having((e) => e.error.message, 'message', allOf(contains('has ended'), contains(_host), contains('Personal Access Tokens')))),
      );

      // A date NEFORUM counted or the person typed is no proof: the server answers.
      final counted = {'access_token': 'opaque', 'expires_at': testNow.subtract(const Duration(days: 1)).toIso8601String()};
      expect(await adapter.refreshSecrets(account, counted, testContext(handler: noNetwork)), isNull);
    });

    test('NEFORUM warns 14 days before the token ends, and says to reconnect', () async {
      final token = _jwt(exp);
      final server = _Pixelfed(validTokens: {token});
      final r = await adapter.connect(PlatformTier.openApi, {'instance': _host, 'access_token': token}, testContext(handler: server.handle));
      final stored = stampNewSignIn(r.secrets, now: testNow);
      final policy = adapter.signInPolicyFor(r.account);
      expect((policy.limit, policy.renewal), (SignInLimit.date, SignInRenewal.never));

      SignInStatus statusAt(DateTime now) =>
          SignInStatus.fromLifetime(r.account.id, deriveSignInLifetime(policy, stored, now: now), hasConnection: policy.hasConnection);

      final atConnect = deriveSignInLifetime(policy, stored, now: testNow);
      expect((atConnect.state, atConnect.expiresAt, atConnect.source, atConnect.renewsItself, atConnect.endsSoon),
          (SignInState.endsOn, exp, SignInDateSource.serverReported, false, false));

      final first = advanceSignInWarnings(const SignInWarningLedger(), statuses: [statusAt(testNow)], now: testNow, schedulesAhead: false);
      expect(first.show, isEmpty, reason: 'a year away');

      final soon = exp.subtract(const Duration(days: 13));
      final life = deriveSignInLifetime(policy, stored, now: soon);
      expect(life.endsSoon, isTrue);
      final step = advanceSignInWarnings(first.ledger, statuses: [statusAt(soon)], now: soon, schedulesAhead: false);
      expect(step.show.map((n) => n.daysBefore), [14]);
      expect(signInWarningCaseOf(step.show.single.status), SignInWarningCase.mustReconnect);
      final text = signInWarningText(step.show.single, network: 'Pixelfed', handle: r.account.handle, now: soon, when: (d) => d.toIso8601String());
      expect(text.title, startsWith('Pixelfed sign-in ends in '));
      expect(text.body, contains('Reconnect it before then'));

      final ended = deriveSignInLifetime(policy, stored, now: exp.add(const Duration(hours: 1)));
      expect(ended.state, SignInState.ended);
    });

    test('a typed date reads back as the person\'s, also on a device that reads it again', () {
      expect(SignInDateSource.parse('userEntered'), SignInDateSource.userEntered);
      expect(SignInDateSource.parse('somethingNewer'), SignInDateSource.unknown);
    });
  });
}
