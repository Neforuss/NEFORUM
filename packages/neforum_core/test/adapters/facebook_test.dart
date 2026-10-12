import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/facebook/facebook_adapter.dart';
import 'package:neforum_core/src/adapters/facebook/facebook_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

const _graph = 'https://graph.facebook.com/v25.0';

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

http.Response _graphError(int code, {int? subcode, int status = 400, Map<String, String> headers = const {}}) => _json({
      'error': {
        'message': 'Something went wrong',
        'type': 'OAuthException',
        'code': code,
        if (subcode != null) 'error_subcode': subcode,
        'fbtrace_id': 'abc',
      }
    }, status, headers);

ConnectedAccount _apiAccount({Map<String, dynamic>? config}) => fakeAccount(
      'facebook',
      tier: PlatformTier.byokApi,
      config: config ?? {'page_id': '123', 'app_id': '987654321', 'page_name': 'My Page'},
    );

const _secrets = {'access_token': 'PAGE_TOKEN', 'app_secret': 'APPSECRET'};

void main() {
  final adapter = FacebookAdapter();

  group('descriptor', () {
    final d = adapter.descriptor;

    test('limits match the research / Graph reference', () {
      expect(d.id, 'facebook');
      expect(d.tiers, {PlatformTier.byokApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.handoff);
      expect(d.personalAccountOk, isFalse);
      expect(d.text.maxLength, 63206);
      expect(d.text.counting, CountingRule.utf16);
      expect(d.text.supportsThreads, isFalse);
      expect(d.text.titleSupported, isFalse);
      expect(d.media.maxImages, 10);
      expect(d.media.maxVideos, 1);
      expect(d.media.allowsMixedImageVideo, isFalse);
      expect(d.media.imageMaxBytes, 10485760);
      expect(d.media.videoMaxBytes, 1024 * 1024 * 1024);
      expect(d.media.videoMaxSeconds, 1200);
      expect(d.media.imageMimeTypes, containsAll(['image/jpeg', 'image/png', 'image/gif', 'image/bmp', 'image/tiff']));
      expect(d.media.imageMimeTypes, isNot(contains('image/webp')));
      expect(d.media.supportsAltText, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.serverSideScheduling, isTrue);
      expect(d.supportsLinkField, isTrue);
      expect(d.setupGuide, 'docs/platforms/facebook.md');
      expect(d.defaultQuotas.single.id, 'facebook.pages_calls_per_day');
      expect(d.defaultQuotas.single.limit, 4800);
      expect(d.defaultQuotas.single.window, const Duration(hours: 24));
      expect(d.defaultQuotas.single.appliesToTier, PlatformTier.byokApi);
    });

    test('connect specs use the HTTPS login_success redirect', () {
      final api = adapter.specFor(PlatformTier.byokApi);
      expect(api.usesBrowser, isTrue);
      expect(api.loopbackRedirectOk, isFalse);
      expect(api.customSchemeRedirectOk, isFalse);
      expect(api.fixedRedirectUri.toString(), 'https://www.facebook.com/connect/login_success.html');
      expect(api.fields.map((f) => f.key), containsAll(['app_id', 'app_secret', 'page', 'user_access_token', 'scopes']));
      expect(api.fields.firstWhere((f) => f.key == 'app_secret').secret, isTrue);
      final token = api.fields.firstWhere((f) => f.key == 'user_access_token');
      expect(token.secret, isTrue);
      expect(token.required, isFalse);
      expect(token.help, contains('Generate Access Token'));
      expect(api.intro, contains('pages_manage_posts'));
      expect(api.intro, contains('https://developers.facebook.com/apps/creation/'));
      expect(api.intro, contains('https://developers.facebook.com/tools/explorer/'));
      expect(api.intro, contains('`https://www.facebook.com/connect/login_success.html`'));
      final handoff = adapter.specFor(PlatformTier.handoff);
      expect(handoff.tier, PlatformTier.handoff);
      expect(handoff.usesBrowser, isFalse);
    });

    test('the Explorer token is the recommended route; login_success is never to be registered', () {
      final api = adapter.specFor(PlatformTier.byokApi);
      // Meta's dashboard refuses the address ("This can't be a Facebook URL"):
      // nothing may tell users to register it.
      for (final text in [api.intro, api.redirectNote!, for (final f in api.fields) f.help ?? '']) {
        expect(text, isNot(contains('Valid OAuth Redirect URIs under')));
        expect(text, isNot(contains('add `https://www.facebook.com/connect/login_success.html`')));
        expect(text, isNot(contains('register exactly')));
      }
      expect(api.redirectNote, contains("Meta won't let you register this address"));
      expect(api.redirectNote, contains("This can't be a Facebook URL"));
      expect(api.intro, contains("Meta won't let you register that address"));
      expect(api.intro.indexOf('Generate Access Token'), lessThan(api.intro.indexOf('Browser sign-in (not recommended)')));
      final keys = api.fields.map((f) => f.key).toList();
      expect(keys.indexOf('user_access_token'), lessThan(keys.indexOf('page')));
      expect(api.fields.firstWhere((f) => f.key == 'user_access_token').help, startsWith('**Recommended.**'));
    });

    test('intro follows the October 2026 dashboard', () {
      final intro = adapter.specFor(PlatformTier.byokApi).intro;
      // No "User Token" item exists before the first token.
      expect(intro, isNot(contains('pick **User Token**')));
      expect(intro, contains('Leave **User or Page** as it is (it may say **Get Token**)'));
      expect(intro, contains("don't pick a Page there"));
      expect(intro, contains('the Explorer remembers the last app you used'));
      expect(intro, contains("If one is missing from the Explorer's list, it isn't added to your app yet"));
      expect(intro, contains('`pages_read_engagement` (it is not there by default)'));
      expect(intro, contains('pop-up'));
      expect(intro, contains("**I don't want to connect a business portfolio yet**"));
      // Publishing needs only a privacy policy URL.
      expect(intro, contains('Meta only requires a privacy policy URL; an app icon and a data deletion URL are optional'));
      expect(intro, isNot(contains('needs an app icon')));
      final page = adapter.specFor(PlatformTier.byokApi).fields.firstWhere((f) => f.key == 'page');
      expect(page.label, 'Page name, username, ID or link');
      expect(page.help, allOf(contains('username'), contains('ID'), contains('link'), contains('examplebakery')));
    });
  });

  group('connect', () {
    Future<http.Response> Function(http.Request) connectHandler(List<http.Request> calls,
            {List<Map<String, Object>>? pages,
            List<String> granted = const ['pages_show_list', 'pages_read_engagement', 'pages_manage_posts', 'business_management']}) =>
        (req) async {
          calls.add(req);
          final path = req.url.path;
          if (path.endsWith('/oauth/access_token') && req.method == 'POST') {
            return _json({'access_token': 'EAASHORT', 'token_type': 'bearer', 'expires_in': 5183});
          }
          if (path.endsWith('/oauth/access_token')) {
            return _json({'access_token': 'EAALONG', 'token_type': 'bearer', 'expires_in': 5184000});
          }
          if (path.endsWith('/me')) return _json({'id': '42', 'name': 'Alice'});
          if (path.endsWith('/me/permissions')) {
            return _json({
              'data': [
                for (final p in granted) {'permission': p, 'status': 'granted'},
                {'permission': 'public_profile', 'status': 'granted'},
                if (!granted.contains('pages_manage_posts')) {'permission': 'pages_manage_posts', 'status': 'declined'},
              ]
            });
          }
          if (path.endsWith('/me/accounts')) {
            return _json({
              'data': pages ??
                  [
                    {'id': '111', 'name': 'Moderated Page', 'access_token': 'PT111', 'tasks': ['MODERATE']},
                    {'id': '123', 'name': 'My Page', 'access_token': 'PT123', 'tasks': ['CREATE_CONTENT', 'MANAGE']},
                    {'id': '456', 'name': 'Other Page', 'access_token': 'PT456', 'tasks': ['CREATE_CONTENT']},
                  ]
            });
          }
          return http.Response('unexpected ${req.url}', 404);
        };

    test('browser code flow: exact token requests, page selection, secrets', () async {
      final calls = <http.Request>[];
      final broker = FakeAuthBroker(code: 'CODE1');
      final ctx = testContext(handler: connectHandler(calls), broker: broker);
      final r = await adapter.connect(
          PlatformTier.byokApi, {'app_id': '987654321', 'app_secret': 'APPSECRET', 'page': ''}, ctx);

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.host, 'www.facebook.com');
      expect(auth.path, '/v25.0/dialog/oauth');
      expect(auth.queryParameters['client_id'], '987654321');
      expect(auth.queryParameters['redirect_uri'], 'https://www.facebook.com/connect/login_success.html');
      expect(auth.queryParameters['response_type'], 'token');
      expect(auth.queryParameters['scope'], 'pages_show_list,pages_read_engagement,pages_manage_posts,business_management');
      expect(auth.queryParameters['state'], isNotEmpty);
      expect(auth.queryParameters.containsKey('code_challenge'), isFalse);

      expect(calls, hasLength(5));
      // 1. code exchange
      expect(calls[0].method, 'POST');
      expect(calls[0].url.toString(), '$_graph/oauth/access_token');
      expect(bodyOf(calls[0]), {
        'grant_type': 'authorization_code',
        'code': 'CODE1',
        'redirect_uri': 'https://www.facebook.com/connect/login_success.html',
        'client_id': '987654321',
        'client_secret': 'APPSECRET',
      });
      // 2. long-lived exchange
      expect(calls[1].method, 'GET');
      expect(calls[1].url.path, '/v25.0/oauth/access_token');
      expect(calls[1].url.queryParameters, {
        'grant_type': 'fb_exchange_token',
        'client_id': '987654321',
        'client_secret': 'APPSECRET',
        'fb_exchange_token': 'EAASHORT',
      });
      // 3. /me
      expect(calls[2].url.path, '/v25.0/me');
      expect(calls[2].url.queryParameters['access_token'], 'EAALONG');
      expect(calls[2].url.queryParameters['appsecret_proof'], appSecretProof('EAALONG', 'APPSECRET'));
      // 4. granted permissions
      expect(calls[3].method, 'GET');
      expect(calls[3].url.path, '/v25.0/me/permissions');
      expect(calls[3].url.queryParameters['access_token'], 'EAALONG');
      expect(calls[3].url.queryParameters['appsecret_proof'], appSecretProof('EAALONG', 'APPSECRET'));
      // 5. /me/accounts
      expect(calls[4].url.path, '/v25.0/me/accounts');
      expect(calls[4].url.queryParameters['fields'], 'id,name,access_token,tasks,link,username');

      // First Page with CREATE_CONTENT is chosen.
      expect(r.account.id, 'facebook-123');
      expect(r.account.tier, PlatformTier.byokApi);
      expect(r.account.displayName, 'My Page');
      expect(r.account.config['page_id'], '123');
      expect(r.account.config['app_id'], '987654321');
      expect(r.account.config['user_id'], '42');
      expect((r.account.config['available_pages'] as List).length, 3);
      expect(r.secrets['access_token'], 'PT123');
      expect(r.secrets['app_secret'], 'APPSECRET');
      expect(r.secrets['user_access_token'], 'EAALONG');
      expect(r.secrets['user_token_expires_at'], isNotNull);
      expect(r.secrets.containsKey('refresh_token'), isFalse);
    });

    test('pasted login_success URL with #access_token skips the code exchange', () async {
      final calls = <http.Request>[];
      final broker = PasteCodeAuthBroker(askUser: (authUrl, redirect) async {
        final state = authUrl.queryParameters['state'];
        return 'https://www.facebook.com/connect/login_success.html#access_token=EAAFRAG&expires_in=5000&state=$state';
      });
      final ctx = testContext(handler: connectHandler(calls), broker: broker);
      final r = await adapter.connect(
          PlatformTier.byokApi, {'app_id': '987654321', 'app_secret': 'APPSECRET', 'page': 'other page'}, ctx);
      expect(calls.first.method, 'GET');
      expect(calls.first.url.queryParameters['fb_exchange_token'], 'EAAFRAG');
      expect(r.account.config['page_id'], '456');
      expect(r.secrets['access_token'], 'PT456');
    });

    test('redirectParams unwraps bare tokens and fragments', () {
      expect(FacebookAdapter.redirectParams(Uri.parse('https://x.test/cb?code=EAAxyz'))['access_token'], 'EAAxyz');
      final p = FacebookAdapter.redirectParams(Uri.parse('https://x.test/cb#access_token=T&state=S'));
      expect(p['access_token'], 'T');
      expect(p['state'], 'S');
    });

    test('pasted user token needs no browser', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: connectHandler(calls));
      final r = await adapter.connect(PlatformTier.byokApi,
          {'app_id': '987654321', 'app_secret': 'APPSECRET', 'user_access_token': 'EAAEXPLORER', 'page': '123'}, ctx);
      expect(calls.first.url.queryParameters['fb_exchange_token'], 'EAAEXPLORER');
      expect(r.account.config['page_id'], '123');
    });

    test('Graph API Explorer token: exchange, /me, permission check, Page token without expiry', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: connectHandler(calls));
      final r = await adapter.connect(PlatformTier.byokApi,
          {'app_id': '987654321', 'app_secret': 'APPSECRET', 'user_access_token': ' EAAEXPLORER '}, ctx);
      expect(calls.map((c) => '${c.method} ${c.url.path}'), [
        'GET /v25.0/oauth/access_token',
        'GET /v25.0/me',
        'GET /v25.0/me/permissions',
        'GET /v25.0/me/accounts',
      ]);
      expect(calls[0].url.queryParameters, {
        'grant_type': 'fb_exchange_token',
        'client_id': '987654321',
        'client_secret': 'APPSECRET',
        'fb_exchange_token': 'EAAEXPLORER',
      });
      expect(r.secrets['access_token'], 'PT123');
      expect(r.secrets.containsKey('expires_at'), isFalse);
      expect(r.secrets['user_access_token'], 'EAALONG');
      expect(DateTime.parse(r.secrets['user_token_expires_at']!), testNow.add(const Duration(seconds: 5184000)));
      // Page tokens never expire, so there is nothing to refresh.
      expect(await adapter.refreshSecrets(r.account, r.secrets, ctx), isNull);
      expect(calls, hasLength(4));
    });

    test('a token without pages_manage_posts is refused with a fix', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: connectHandler(calls, granted: ['pages_show_list', 'pages_read_engagement']));
      await expectLater(
          adapter.connect(PlatformTier.byokApi,
              {'app_id': '987654321', 'app_secret': 'APPSECRET', 'user_access_token': 'EAAEXPLORER'}, ctx),
          throwsA(isA<ConnectException>()
              .having((e) => e.field, 'field', 'user_access_token')
              .having((e) => e.message, 'message', contains('pages_manage_posts'))
              .having((e) => e.message, 'message', contains('Generate Access Token'))));
      expect(calls.where((c) => c.url.path.endsWith('/me/accounts')), isEmpty);
    });

    test('an unreadable permission list does not block connecting', () async {
      final calls = <http.Request>[];
      final base = connectHandler(calls);
      final ctx = testContext(
          handler: (req) async => req.url.path.endsWith('/me/permissions') ? _graphError(2, status: 500) : base(req));
      final r = await adapter.connect(PlatformTier.byokApi,
          {'app_id': '987654321', 'app_secret': 'APPSECRET', 'user_access_token': 'EAAEXPLORER'}, ctx);
      expect(r.account.config['page_id'], '123');
    });

    test('an expired or foreign pasted token points at the token field', () async {
      final ctx = testContext(handler: (req) async => _graphError(190, subcode: 463));
      await expectLater(
          adapter.connect(PlatformTier.byokApi,
              {'app_id': '987654321', 'app_secret': 'APPSECRET', 'user_access_token': 'EAAOLD'}, ctx),
          throwsA(isA<ConnectException>()
              .having((e) => e.field, 'field', 'user_access_token')
              .having((e) => e.message, 'message', contains('Meta App set to this same app'))
              .having((e) => e.message, 'message', contains('Generate Access Token'))));
    });

    test('a pasted Page token is recognised and explained', () async {
      final calls = <http.Request>[];
      final base = connectHandler(calls);
      final ctx = testContext(
          handler: (req) async => req.url.path.endsWith('/me/accounts')
              ? _json({
                  'error': {
                    'message': '(#100) Tried accessing nonexisting field (accounts) on node type (Page)',
                    'type': 'OAuthException',
                    'code': 100,
                  }
                }, 400)
              : base(req));
      await expectLater(
          adapter.connect(PlatformTier.byokApi,
              {'app_id': '987654321', 'app_secret': 'APPSECRET', 'user_access_token': 'EAAPAGE'}, ctx),
          throwsA(isA<ConnectException>()
              .having((e) => e.field, 'field', 'user_access_token')
              .having((e) => e.message, 'message', contains('Page access token'))));
    });

    test('state mismatch, unknown page, no pages and bad input are ConnectExceptions', () async {
      final calls = <http.Request>[];
      final wrongState = FakeAuthBroker(extraParams: {'state': 'forged'});
      await expectLater(
          adapter.connect(PlatformTier.byokApi, {'app_id': '987654321', 'app_secret': 'S'},
              testContext(handler: connectHandler(calls), broker: wrongState)),
          throwsA(isA<ConnectException>()));
      await expectLater(
          adapter.connect(PlatformTier.byokApi, {'app_id': '987654321', 'app_secret': 'S', 'page': 'Nope'},
              testContext(handler: connectHandler(calls), broker: FakeAuthBroker())),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('My Page'))));
      await expectLater(
          adapter.connect(PlatformTier.byokApi, {'app_id': '987654321', 'app_secret': 'S'},
              testContext(handler: connectHandler(calls, pages: []), broker: FakeAuthBroker())),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('personal profiles'))));
      await expectLater(
          adapter.connect(PlatformTier.byokApi, {'app_id': 'abc', 'app_secret': 'S'},
              testContext(handler: connectHandler(calls), broker: FakeAuthBroker())),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'app_id')));
    });

    test('Facebook error during exchange becomes a ConnectException', () async {
      for (final code in [101, 1]) {
        final ctx = testContext(handler: (req) async => _graphError(code), broker: FakeAuthBroker());
        await expectLater(
            adapter.connect(PlatformTier.byokApi,
                {'app_id': '987654321', 'app_secret': 'S', 'user_access_token': 'EAAX'}, ctx),
            throwsA(isA<ConnectException>()
                .having((e) => e.message, 'message', contains('rejected the App ID/App Secret'))
                .having((e) => e.message, 'message', contains('App settings > Basic'))),
            reason: 'code $code');
      }
    });

    group('token made for another Meta app', () {
      final wrongApp = _json({
        'error': {'message': 'The access token does not belong to application 123', 'code': 1}
      }, 400);
      const input = {'app_id': '987654321', 'app_secret': 'APPSECRET', 'user_access_token': 'EAAOTHER'};

      test('names the app debug_token reports, falling back to the token itself as caller', () async {
        final calls = <http.Request>[];
        final ctx = testContext(handler: (req) async {
          calls.add(req);
          if (req.url.path.endsWith('/oauth/access_token')) return wrongApp;
          if (req.url.path.endsWith('/debug_token')) {
            // Meta may refuse to describe another app's token to this app.
            if (req.url.queryParameters['access_token'] == '987654321|APPSECRET') {
              return _json({
                'error': {'message': '(#100) The App_id in the input_token did not match the Viewing App', 'code': 100}
              }, 400);
            }
            return _json({
              'data': {'app_id': '555000111', 'application': 'Graph API Explorer', 'type': 'USER', 'is_valid': true}
            });
          }
          return http.Response('unexpected ${req.url}', 404);
        });
        await expectLater(
            adapter.connect(PlatformTier.byokApi, input, ctx),
            throwsA(isA<ConnectException>()
                .having((e) => e.field, 'field', isNull)
                .having((e) => e.message, 'message', startsWith('This token was made for a different Meta app'))
                .having((e) => e.message, 'message', contains('"Graph API Explorer" (App ID 555000111)'))
                .having((e) => e.message, 'message', contains('The App ID you entered is 987654321'))
                .having((e) => e.message, 'message',
                    contains('set Meta App to the app whose App ID is 987654321, click Generate Access Token again'))
                .having((e) => e.message, 'message', isNot(contains('rejected')))));
        expect(calls.map((c) => c.url.path), [
          '/v25.0/oauth/access_token',
          '/v25.0/debug_token',
          '/v25.0/debug_token',
        ]);
        expect(calls[1].url.queryParameters, {'input_token': 'EAAOTHER', 'access_token': '987654321|APPSECRET'});
        expect(calls[2].url.queryParameters, {'input_token': 'EAAOTHER', 'access_token': 'EAAOTHER'});
      });

      test('without a debug_token answer the message is generic and does not blame the keys', () async {
        final calls = <http.Request>[];
        final ctx = testContext(handler: (req) async {
          calls.add(req);
          if (req.url.path.endsWith('/oauth/access_token')) return wrongApp;
          return _graphError(190, status: 400);
        });
        await expectLater(
            adapter.connect(PlatformTier.byokApi, input, ctx),
            throwsA(isA<ConnectException>()
                .having((e) => e.message, 'message', startsWith('This token was made for a different Meta app. '))
                .having((e) => e.message, 'message', contains('the app whose App ID is 987654321'))
                .having((e) => e.message, 'message', contains('Generate Access Token again'))
                .having((e) => e.message, 'message', contains('The App ID and App Secret can stay as they are'))
                .having((e) => e.message, 'message', contains('does not belong to application 123 (#1)'))
                .having((e) => e.message, 'message', isNot(contains('rejected')))));
        expect(calls.where((c) => c.url.path.endsWith('/debug_token')), hasLength(2));
        expect(calls.where((c) => c.url.path.endsWith('/me')), isEmpty);
      });

      test('a debug_token that names this same app gives the generic message', () async {
        final ctx = testContext(handler: (req) async {
          if (req.url.path.endsWith('/oauth/access_token')) return wrongApp;
          return _json({
            'data': {'app_id': '987654321', 'application': 'My NEFORUM app'}
          });
        });
        await expectLater(
            adapter.connect(PlatformTier.byokApi, input, ctx),
            throwsA(isA<ConnectException>()
                .having((e) => e.message, 'message', startsWith('This token was made for a different Meta app. '))
                .having((e) => e.message, 'message', isNot(contains('My NEFORUM app')))));
      });

      test('the same Graph error from a later call is explained too', () {
        final err = GraphError.parse({
          'error': {'message': 'The access token does not belong to application 123', 'code': 1}
        })!;
        expect(FacebookAdapter.isWrongAppError(err), isTrue);
        expect(FacebookAdapter.isWrongAppError(GraphError.parse({
          'error': {'message': 'Error validating client secret.', 'code': 1}
        })!), isFalse);
        expect(FacebookAdapter.wrongAppMessage('987654321', err, null), contains('App ID is 987654321'));
        expect(FacebookAdapter.wrongAppMessage('987654321', err, const FacebookTokenApp('42424242', null)),
            contains('a different Meta app, App ID 42424242.'));
      });
    });

    group('choosing the Page', () {
      final pages = <Map<String, Object>>[
        {'id': '111', 'name': 'Moderated Page', 'access_token': 'PT111', 'tasks': ['MODERATE']},
        {'id': '123', 'name': 'My Page', 'access_token': 'PT123', 'tasks': ['CREATE_CONTENT'], 'username': 'mypage'},
        {
          'id': '777',
          'name': 'Example Bakery',
          'access_token': 'PT777',
          'tasks': ['CREATE_CONTENT'],
          'username': 'examplebakery',
          'link': 'https://www.facebook.com/examplebakery',
        },
        {
          'id': '888',
          'name': 'Corner Shop',
          'access_token': 'PT888',
          'tasks': ['CREATE_CONTENT'],
          'link': 'https://www.facebook.com/profile.php?id=888',
        },
        {
          'id': '999',
          'name': 'Link Only',
          'access_token': 'PT999',
          'tasks': ['CREATE_CONTENT'],
          'link': 'https://www.facebook.com/linkonly',
        },
      ];

      Future<ConnectResult> connectWith(String page) => adapter.connect(
          PlatformTier.byokApi,
          {'app_id': '987654321', 'app_secret': 'APPSECRET', 'user_access_token': 'EAAEXPLORER', 'page': page},
          testContext(handler: connectHandler(<http.Request>[], pages: pages)));

      test('by name, username, ID or pasted Page address', () async {
        const expected = {
          'Example Bakery': '777',
          'example bakery': '777',
          'examplebakery': '777',
          'ExampleBakery': '777',
          '@examplebakery': '777',
          'https://www.facebook.com/examplebakery/': '777',
          'https://www.facebook.com/examplebakery': '777',
          'facebook.com/ExampleBakery?ref=bookmarks': '777',
          'http://facebook.com/examplebakery/?ref=page_internal#posts': '777',
          'm.facebook.com/examplebakery': '777',
          'https://m.facebook.com/examplebakery/posts/12345': '777',
          'https://www.facebook.com/profile.php?id=888': '888',
          'www.facebook.com/profile.php?id=888&sk=about': '888',
          'https://www.facebook.com/pages/Corner-Shop/888': '888',
          '888': '888',
          'facebook.com/linkonly': '999',
          'mypage': '123',
        };
        for (final e in expected.entries) {
          final r = await connectWith(e.key);
          expect(r.account.config['page_id'], e.value, reason: e.key);
        }
      });

      test('an unknown Page lists names, usernames and ids', () async {
        await expectLater(
            connectWith('https://www.facebook.com/nosuchpage/'),
            throwsA(isA<ConnectException>()
                .having((e) => e.field, 'field', 'page')
                .having((e) => e.message, 'message', contains('No Page matches "https://www.facebook.com/nosuchpage/"'))
                .having((e) => e.message, 'message', contains('Example Bakery (examplebakery, 777)'))
                .having((e) => e.message, 'message', contains('Corner Shop (888)'))));
      });

      test('the stored Page list includes usernames', () async {
        final r = await connectWith('examplebakery');
        expect(r.account.config['available_pages'],
            contains(equals({'id': '777', 'name': 'Example Bakery', 'username': 'examplebakery'})));
        expect(r.account.profileUrl, 'https://www.facebook.com/examplebakery');
      });

      test('facebookPageKey strips scheme, host, query and trailing slash', () {
        expect(facebookPageKey(' https://www.facebook.com/examplebakery/ '), 'examplebakery');
        expect(facebookPageKey('https://web.facebook.com/examplebakery?ref=x'), 'examplebakery');
        expect(facebookPageKey('fb.com/examplebakery'), 'examplebakery');
        expect(facebookPageKey('https://www.facebook.com/profile.php?id=100012345'), '100012345');
        expect(facebookPageKey('https://www.facebook.com/people/Example-Bakery/100012345/'), '100012345');
        expect(facebookPageKey('https://www.facebook.com/pg/examplebakery/posts/'), 'examplebakery');
        expect(facebookPageKey('@examplebakery'), 'examplebakery');
        expect(facebookPageKey('Example Bakery'), 'Example Bakery');
        expect(facebookPageKey('Facebook.com fans'), 'Facebook.com fans');
        expect(facebookPageKey('https://example.com/examplebakery'), 'https://example.com/examplebakery');
        expect(facebookPageKey('https://www.facebook.com/'), 'https://www.facebook.com/');
      });
    });

    test('hand-off tier needs no credentials', () async {
      final ctx = testContext(handler: (req) async => http.Response('', 500));
      final r = await adapter.connect(PlatformTier.handoff, {'page_url': 'https://www.facebook.com/MyPage'}, ctx);
      expect(r.account.tier, PlatformTier.handoff);
      expect(r.account.config['page_url'], 'https://www.facebook.com/MyPage');
      expect(r.secrets, isEmpty);
      await expectLater(adapter.connect(PlatformTier.handoff, {'page_url': 'https://evil.test/x'}, ctx),
          throwsA(isA<ConnectException>()));
    });
  });

  group('validate', () {
    List<String> codes(PostVariant v, ConnectedAccount a) => adapter.validate(v, a).map((i) => i.code).toList();

    test('generic rules apply', () {
      final a = _apiAccount();
      expect(codes(PostVariant(text: 'x' * 63207), a), contains('text.too_long'));
      expect(codes(PostVariant(text: 'x' * 63206), a), isNot(contains('text.too_long')));
      expect(codes(PostVariant(text: 'hi', media: [for (var i = 0; i < 11; i++) fakeImage(id: 'i$i')]), a),
          contains('media.too_many_images'));
      expect(codes(PostVariant(text: 'hi', media: [fakeImage(mimeType: 'image/webp')]), a), contains('media.image_type'));
      expect(codes(PostVariant(text: 'hi', media: [fakeImage(), fakeVideo()]), a), contains('media.mixed'));
      expect(codes(PostVariant(text: 'hi', media: [fakeImage(sizeBytes: 11 * 1024 * 1024)]), a),
          contains('media.image_too_large'));
    });

    test('platform-specific checks', () {
      expect(codes(const PostVariant(text: 'hi'), _apiAccount(config: {})), contains('account.no_page'));
      expect(codes(PostVariant(text: 'hi', link: 'https://example.com', media: [fakeImage()]), _apiAccount()),
          contains('link.in_caption'));
      expect(codes(PostVariant(text: 'hi', link: 'https://example.com', media: [fakeVideo()]), _apiAccount()),
          contains('link.in_caption'));
      expect(codes(const PostVariant(text: 'hi'), fakeAccount('facebook', tier: PlatformTier.handoff)),
          contains('handoff.paste_text'));
    });

    group('schedule window (10 min + 5 min margin .. 30 days, videos 6 months)', () {
      final now = DateTime.now();
      List<ValidationIssue> scheduleIssues(Duration ahead, {bool video = false}) => adapter
          .validate(PostVariant(text: 'hi', media: [if (video) fakeVideo()], scheduledAt: now.add(ahead)), _apiAccount())
          .where((i) => i.code.startsWith('schedule.'))
          .toList();

      test('too soon and too far are errors on the scheduledAt field', () {
        for (final ahead in [const Duration(minutes: 2), const Duration(minutes: 12)]) {
          final issue = scheduleIssues(ahead).single;
          expect(issue.code, 'schedule.too_soon');
          expect(issue.isError, isTrue);
          expect(issue.field, 'scheduledAt');
        }
        final far = scheduleIssues(const Duration(days: 31)).single;
        expect(far.code, 'schedule.too_far');
        expect(far.isError, isTrue);
        expect(far.field, 'scheduledAt');
        expect(scheduleIssues(const Duration(days: 181), video: true).single.code, 'schedule.too_far');
      });

      test('inside the window, or already due, is fine', () {
        expect(scheduleIssues(const Duration(minutes: 20)), isEmpty);
        expect(scheduleIssues(const Duration(days: 29)), isEmpty);
        expect(scheduleIssues(const Duration(days: 40), video: true), isEmpty);
        expect(scheduleIssues(const Duration(minutes: -5)), isEmpty);
      });

      test('scheduleIssue uses the clock it is given', () {
        final t = DateTime.utc(2026, 1, 1);
        expect(FacebookAdapter.scheduleIssue(t.add(const Duration(minutes: 16)), isVideo: false, now: t), isNull);
        expect(FacebookAdapter.scheduleIssue(t.add(const Duration(minutes: 14)), isVideo: false, now: t)!.code,
            'schedule.too_soon');
      });
    });
  });

  group('publish', () {
    test('text + link goes to /feed with message, link, token and appsecret_proof', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        return _json({'id': '123_789'});
      });
      final r = await adapter.publish(
          const PostVariant(text: 'Hello Facebook', link: 'https://example.com/a'), _apiAccount(), _secrets, ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, '123_789');
      expect(r.remoteUrl, 'https://www.facebook.com/123/posts/789');
      expect(calls.single.method, 'POST');
      expect(calls.single.url.toString(), '$_graph/123/feed');
      expect(bodyOf(calls.single), {
        'message': 'Hello Facebook',
        'link': 'https://example.com/a',
        'access_token': 'PAGE_TOKEN',
        'appsecret_proof': appSecretProof('PAGE_TOKEN', 'APPSECRET'),
      });
    });

    test('appsecret_proof is omitted when no app secret is stored', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        return _json({'id': '123_1'});
      });
      await adapter.publish(const PostVariant(text: 'x'), _apiAccount(), const {'access_token': 'T'}, ctx);
      expect(bodyOf(calls.single).containsKey('appsecret_proof'), isFalse);
    });

    test('single photo is a multipart /photos upload with caption and alt text', () async {
      final calls = <http.Request>[];
      final progress = <String>[];
      final base = testContext(handler: (req) async {
        calls.add(req);
        return _json({'id': '555', 'post_id': '123_556'});
      });
      final ctx = base.copyWith(onProgress: progress.add);
      final r = await adapter.publish(
          PostVariant(text: 'Look', link: 'https://example.com', media: [fakeImage(altText: 'A cat')]),
          _apiAccount(),
          _secrets,
          ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, '123_556');
      expect(calls.single.method, 'POST');
      expect(calls.single.url.toString(), '$_graph/123/photos');
      final f = multipartFieldsOf(calls.single);
      expect(f['source'], '<img1.jpg>');
      expect(f['caption'], 'Look\n\nhttps://example.com');
      expect(f['alt_text_custom'], 'A cat');
      expect(f['access_token'], 'PAGE_TOKEN');
      expect(f.containsKey('published'), isFalse);
      expect(progress, contains('Uploading image 1 of 1'));
    });

    test('multiple photos: unpublished uploads then /feed with attached_media', () async {
      final calls = <http.Request>[];
      var n = 0;
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        if (req.url.path.endsWith('/photos')) return _json({'id': 'p${++n}'});
        return _json({'id': '123_900'});
      });
      final r = await adapter.publish(
          PostVariant(text: 'Album', media: [fakeImage(id: 'a'), fakeImage(id: 'b', altText: null)]),
          _apiAccount(),
          _secrets,
          ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, '123_900');
      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'POST $_graph/123/photos',
        'POST $_graph/123/photos',
        'POST $_graph/123/feed',
      ]);
      final first = multipartFieldsOf(calls[0]);
      expect(first['published'], 'false');
      expect(first['source'], '<a.jpg>');
      expect(first['alt_text_custom'], 'A test image');
      expect(first.containsKey('temporary'), isFalse);
      expect(multipartFieldsOf(calls[1]).containsKey('alt_text_custom'), isFalse);
      final feed = bodyOf(calls[2]);
      expect(feed['message'], 'Album');
      expect(feed['attached_media[0]'], '{"media_fbid":"p1"}');
      expect(feed['attached_media[1]'], '{"media_fbid":"p2"}');
      expect(feed['access_token'], 'PAGE_TOKEN');
    });

    test('video goes to /videos with source, description and title', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        return _json({'id': 'v77'});
      });
      final r = await adapter.publish(
          PostVariant(text: 'Watch this', media: [fakeVideo()], extra: const {'videoTitle': 'My clip'}),
          _apiAccount(),
          _secrets,
          ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, 'v77');
      expect(r.remoteUrl, 'https://www.facebook.com/123/videos/v77');
      expect(calls.single.url.toString(), '$_graph/123/videos');
      final f = multipartFieldsOf(calls.single);
      expect(f['source'], '<vid1.mp4>');
      expect(f['description'], 'Watch this');
      expect(f['title'], 'My clip');
      expect(f['access_token'], 'PAGE_TOKEN');
    });

    group('server-side scheduling', () {
      final at = testNow.add(const Duration(days: 2));
      final unix = '${at.millisecondsSinceEpoch ~/ 1000}';

      test('text + link: /feed with published=false and scheduled_publish_time, held result', () async {
        final calls = <http.Request>[];
        final ctx = testContext(handler: (req) async {
          calls.add(req);
          return _json({'id': '123_901'});
        });
        final r = await adapter.publish(
            PostVariant(text: 'Later', link: 'https://example.com/l', scheduledAt: at), _apiAccount(), _secrets, ctx);
        expect(r.success, isTrue, reason: '${r.error}');
        expect(r.isHeldByPlatform, isTrue);
        expect(r.remoteId, '123_901');
        expect(r.scheduledFor, at);
        expect(r.remoteUrl, 'https://www.facebook.com/123/posts/901');
        expect(r.publishedAt, isNull);
        expect(calls.single.url.toString(), '$_graph/123/feed');
        expect(bodyOf(calls.single), {
          'message': 'Later',
          'link': 'https://example.com/l',
          'published': 'false',
          'scheduled_publish_time': unix,
          'access_token': 'PAGE_TOKEN',
          'appsecret_proof': appSecretProof('PAGE_TOKEN', 'APPSECRET'),
        });
      });

      test('single photo: /photos carries the schedule; post_id is what gets deleted', () async {
        final calls = <http.Request>[];
        final ctx = testContext(handler: (req) async {
          calls.add(req);
          return _json({'id': '555', 'post_id': '123_556'});
        });
        final r = await adapter.publish(
            PostVariant(text: 'Photo later', media: [fakeImage()], scheduledAt: at), _apiAccount(), _secrets, ctx);
        expect(r.isHeldByPlatform, isTrue, reason: '${r.error}');
        expect(r.remoteId, '123_556');
        expect(r.scheduledFor, at);
        final f = multipartFieldsOf(calls.single);
        expect(calls.single.url.toString(), '$_graph/123/photos');
        expect(f['published'], 'false');
        expect(f['scheduled_publish_time'], unix);
        expect(f['caption'], 'Photo later');
        expect(f.containsKey('temporary'), isFalse);
      });

      test('single photo without post_id falls back to the photo id', () async {
        final ctx = testContext(handler: (req) async => _json({'id': '555'}));
        final r = await adapter.publish(
            PostVariant(text: 'Photo later', media: [fakeImage()], scheduledAt: at), _apiAccount(), _secrets, ctx);
        expect(r.isHeldByPlatform, isTrue);
        expect(r.remoteId, '555');
      });

      test('multi-photo: temporary unpublished uploads, then /feed with unpublished_content_type=SCHEDULED', () async {
        final calls = <http.Request>[];
        var n = 0;
        final ctx = testContext(handler: (req) async {
          calls.add(req);
          if (req.url.path.endsWith('/photos')) return _json({'id': 'p${++n}'});
          return _json({'id': '123_902'});
        });
        final r = await adapter.publish(
            PostVariant(text: 'Later album', scheduledAt: at, media: [fakeImage(id: 'a'), fakeImage(id: 'b')]),
            _apiAccount(),
            _secrets,
            ctx);
        expect(r.isHeldByPlatform, isTrue, reason: '${r.error}');
        expect(r.remoteId, '123_902');
        for (final upload in calls.take(2)) {
          final f = multipartFieldsOf(upload);
          expect(f['published'], 'false');
          expect(f['temporary'], 'true');
          expect(f.containsKey('scheduled_publish_time'), isFalse);
        }
        final feed = bodyOf(calls[2]);
        expect(feed['attached_media[0]'], '{"media_fbid":"p1"}');
        expect(feed['published'], 'false');
        expect(feed['scheduled_publish_time'], unix);
        expect(feed['unpublished_content_type'], 'SCHEDULED');
      });

      test('video: /videos carries the schedule; video id is what gets deleted', () async {
        final calls = <http.Request>[];
        final ctx = testContext(handler: (req) async {
          calls.add(req);
          return _json({'id': 'v78'});
        });
        final videoAt = testNow.add(const Duration(days: 90));
        final r = await adapter.publish(
            PostVariant(text: 'Clip later', media: [fakeVideo()], scheduledAt: videoAt), _apiAccount(), _secrets, ctx);
        expect(r.isHeldByPlatform, isTrue, reason: '${r.error}');
        expect(r.remoteId, 'v78');
        expect(r.scheduledFor, videoAt);
        expect(r.remoteUrl, 'https://www.facebook.com/123/videos/v78');
        final f = multipartFieldsOf(calls.single);
        expect(calls.single.url.toString(), '$_graph/123/videos');
        expect(f['published'], 'false');
        expect(f['scheduled_publish_time'], '${videoAt.millisecondsSinceEpoch ~/ 1000}');
      });

      test('outside the window -> validation failure without a request; already due -> published now', () async {
        final calls = <http.Request>[];
        final ctx = testContext(handler: (req) async {
          calls.add(req);
          return _json({'id': '123_903'});
        });
        final soon = await adapter.publish(
            PostVariant(text: 'x', scheduledAt: testNow.add(const Duration(minutes: 5))), _apiAccount(), _secrets, ctx);
        expect(soon.error?.kind, PublishErrorKind.validation);
        final far = await adapter.publish(
            PostVariant(text: 'x', scheduledAt: testNow.add(const Duration(days: 31))), _apiAccount(), _secrets, ctx);
        expect(far.error?.kind, PublishErrorKind.validation);
        expect(calls, isEmpty);

        final due = await adapter.publish(
            PostVariant(text: 'x', scheduledAt: testNow.subtract(const Duration(minutes: 1))), _apiAccount(), _secrets, ctx);
        expect(due.success, isTrue);
        expect(due.isHeldByPlatform, isFalse);
        expect(bodyOf(calls.single).containsKey('published'), isFalse);
        expect(bodyOf(calls.single).containsKey('scheduled_publish_time'), isFalse);
      });
    });

    group('cancelScheduled', () {
      final held = PublishResult.scheduled(remoteId: '123_901', scheduledFor: testNow.add(const Duration(days: 2)));

      Future<void> cancel(http.Response res, {List<http.Request>? calls, Map<String, String> secrets = _secrets}) =>
          adapter.cancelScheduled(
              held,
              _apiAccount(),
              secrets,
              testContext(handler: (req) async {
                calls?.add(req);
                return res;
              }));

      Matcher failsWith(PublishErrorKind kind) =>
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', kind));

      test('DELETEs the held id with the Page token and appsecret_proof', () async {
        final calls = <http.Request>[];
        await cancel(_json({'success': true}), calls: calls);
        expect(calls.single.method, 'DELETE');
        expect(calls.single.url.path, '/v25.0/123_901');
        expect(calls.single.url.queryParameters, {
          'access_token': 'PAGE_TOKEN',
          'appsecret_proof': appSecretProof('PAGE_TOKEN', 'APPSECRET'),
        });
      });

      test('already gone (404, or 100/33 "does not exist") counts as removed', () async {
        await cancel(http.Response('', 404));
        await cancel(_graphError(100, subcode: 33));
      });

      test('failures throw AdapterException with the right kind', () async {
        await expectLater(cancel(_graphError(190, subcode: 460)), failsWith(PublishErrorKind.auth));
        await expectLater(cancel(_graphError(200, status: 403)), failsWith(PublishErrorKind.auth));
        await expectLater(cancel(_graphError(100)), failsWith(PublishErrorKind.validation));
        await expectLater(cancel(_graphError(2, status: 500)), failsWith(PublishErrorKind.network));
        await expectLater(cancel(http.Response('down', 503)), failsWith(PublishErrorKind.network));
        await expectLater(cancel(_json({'success': false})), failsWith(PublishErrorKind.platform));
        await expectLater(
            cancel(_graphError(80001, headers: {
              'x-business-use-case-usage': jsonEncode({
                '123': [
                  {'type': 'pages', 'estimated_time_to_regain_access': 3}
                ]
              })
            })),
            throwsA(isA<AdapterException>()
                .having((e) => e.error.kind, 'kind', PublishErrorKind.quota)
                .having((e) => e.error.retryAfter, 'retryAfter', const Duration(minutes: 3))));
      });

      test('network failure, missing token, missing id and hand-off tier', () async {
        final offline = testContext(handler: (req) async => throw http.ClientException('no route'));
        await expectLater(adapter.cancelScheduled(held, _apiAccount(), _secrets, offline), failsWith(PublishErrorKind.network));
        await expectLater(cancel(_json({'success': true}), secrets: const {}), failsWith(PublishErrorKind.auth));
        final ctx = testContext(handler: (req) async => fail('no HTTP expected'));
        await expectLater(
            adapter.cancelScheduled(PublishResult.ok(), _apiAccount(), _secrets, ctx), failsWith(PublishErrorKind.platform));
        await expectLater(
            adapter.cancelScheduled(held, fakeAccount('facebook', tier: PlatformTier.handoff), const {}, ctx),
            failsWith(PublishErrorKind.unsupported));
      });
    });

    test('thread parts are joined (Facebook has no threads)', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        return _json({'id': '123_2'});
      });
      await adapter.publish(const PostVariant(text: 'a', threadParts: ['a', 'b']), _apiAccount(), _secrets, ctx);
      expect(bodyOf(calls.single)['message'], 'a\n\nb');
    });

    group('error mapping', () {
      Future<PublishResult> run(http.Response res) => adapter.publish(const PostVariant(text: 'x'), _apiAccount(),
          _secrets, testContext(handler: (req) async => res));

      test('expired token (190) -> auth', () async {
        final r = await run(_graphError(190, subcode: 463));
        expect(r.success, isFalse);
        expect(r.error!.kind, PublishErrorKind.auth);
        expect(r.error!.message, contains('#190/463'));
      });

      test('HTTP 401 without body -> auth', () async {
        expect((await run(http.Response('', 401))).error!.kind, PublishErrorKind.auth);
      });

      test('missing permission (200) -> auth', () async {
        expect((await run(_graphError(200, status: 403))).error!.kind, PublishErrorKind.auth);
      });

      test('Pages throttling (80001) -> quota with BUC retry hint', () async {
        final r = await run(_graphError(80001, headers: {
          'x-business-use-case-usage': jsonEncode({
            '123': [
              {'type': 'pages', 'call_count': 100, 'total_cputime': 10, 'total_time': 10, 'estimated_time_to_regain_access': 7}
            ]
          })
        }));
        expect(r.error!.kind, PublishErrorKind.quota);
        expect(r.error!.retryAfter, const Duration(minutes: 7));
      });

      test('HTTP 429 -> quota with Retry-After', () async {
        final r = await run(http.Response('slow down', 429, headers: {'retry-after': '120'}));
        expect(r.error!.kind, PublishErrorKind.quota);
        expect(r.error!.retryAfter, const Duration(seconds: 120));
      });

      test('posting too fast (1390008) -> quota', () async {
        expect((await run(_graphError(368, subcode: 1390008))).error!.kind, PublishErrorKind.quota);
      });

      test('duplicate post (506) and bad parameter (100) -> validation', () async {
        expect((await run(_graphError(506))).error!.kind, PublishErrorKind.validation);
        expect((await run(_graphError(100))).error!.kind, PublishErrorKind.validation);
      });

      test('transient (2), video upload hiccup (6001) and 5xx -> network', () async {
        expect((await run(_graphError(2, status: 500))).error!.kind, PublishErrorKind.network);
        expect((await run(_graphError(6001))).error!.kind, PublishErrorKind.network);
        expect((await run(http.Response('oops', 503))).error!.kind, PublishErrorKind.network);
      });

      test('throttling codes 4, 17, 32, 613 -> quota; temporary block 368 -> quota', () async {
        for (final code in [4, 17, 32, 613, 368]) {
          expect((await run(_graphError(code))).error!.kind, PublishErrorKind.quota, reason: 'code $code');
        }
      });

      test('connection failure -> network result, not an exception', () async {
        final r = await adapter.publish(const PostVariant(text: 'x'), _apiAccount(), _secrets,
            testContext(handler: (req) async => throw http.ClientException('no route')));
        expect(r.error!.kind, PublishErrorKind.network);
      });
    });

    test('missing token / page / hand-off tier fail cleanly', () async {
      final ctx = testContext(handler: (req) async => _json({'id': '1'}));
      expect((await adapter.publish(const PostVariant(text: 'x'), _apiAccount(), const {}, ctx)).error!.kind,
          PublishErrorKind.auth);
      expect((await adapter.publish(const PostVariant(text: 'x'), _apiAccount(config: {}), _secrets, ctx)).error!.kind,
          PublishErrorKind.configuration);
      expect(
          (await adapter.publish(
                  const PostVariant(text: 'x'), fakeAccount('facebook', tier: PlatformTier.handoff), const {}, ctx))
              .error!
              .kind,
          PublishErrorKind.unsupported);
    });
  });

  group('refreshSecrets', () {
    test('page tokens do not expire: returns null', () async {
      final ctx = testContext(handler: (req) async => http.Response('', 500));
      expect(await adapter.refreshSecrets(_apiAccount(), _secrets, ctx), isNull);
    });

    test('no token -> auth AdapterException', () async {
      final ctx = testContext(handler: (req) async => http.Response('', 500));
      await expectLater(adapter.refreshSecrets(_apiAccount(), const {}, ctx),
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
    });
  });

  group('buildHandoff', () {
    test('link post opens sharer.php with u and quote', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Read this', link: 'https://example.com/x'))!;
      final u = plan.webIntent!;
      expect(u.scheme, 'https');
      expect(u.host, 'www.facebook.com');
      expect(u.path, '/sharer/sharer.php');
      expect(u.queryParameters['u'], 'https://example.com/x');
      expect(u.queryParameters['quote'], 'Read this');
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.clipboardText, 'Read this\n\nhttps://example.com/x');
      expect(plan.androidPackage, 'com.facebook.katana');
      expect(plan.iosScheme, 'fb://');
      expect(plan.instructions, startsWith('1. '));
    });

    test('link found in the text is used when there is no link field', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'See https://example.org/p now'))!;
      expect(plan.webIntent!.queryParameters['u'], 'https://example.org/p');
    });

    test('media prefers the share sheet with files and clipboard caption', () {
      final img = fakeImage();
      final plan = adapter.buildHandoff(PostVariant(text: 'Photo time', media: [img]))!;
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.shareFiles, [img]);
      expect(plan.clipboardText, 'Photo time');
      expect(plan.mediaNote, isNotNull);
    });

    test('plain text falls back to manual with the configured page URL', () {
      final account = fakeAccount('facebook',
          tier: PlatformTier.handoff, config: {'page_url': 'https://www.facebook.com/MyPage'});
      final plan = adapter.buildHandoff(const PostVariant(text: 'Just words'), account: account)!;
      expect(plan.webIntent, isNull);
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.desktopUrl, 'https://www.facebook.com/MyPage');
      expect(plan.clipboardText, 'Just words');
    });

    test('very long text drops the quote parameter', () {
      final plan = adapter.buildHandoff(PostVariant(text: 'y' * 5000, link: 'https://example.com'))!;
      expect(plan.webIntent!.queryParameters.containsKey('quote'), isFalse);
      expect(plan.clipboardText!.length, greaterThan(5000));
    });
  });
}
