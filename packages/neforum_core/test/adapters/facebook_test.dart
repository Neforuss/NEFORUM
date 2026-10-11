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
      expect(api.intro, contains('pages_manage_posts'));
      final handoff = adapter.specFor(PlatformTier.handoff);
      expect(handoff.tier, PlatformTier.handoff);
      expect(handoff.usesBrowser, isFalse);
    });
  });

  group('connect', () {
    Future<http.Response> Function(http.Request) connectHandler(List<http.Request> calls,
            {List<Map<String, Object>>? pages}) =>
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

      expect(calls, hasLength(4));
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
      // 4. /me/accounts
      expect(calls[3].url.path, '/v25.0/me/accounts');
      expect(calls[3].url.queryParameters['fields'], 'id,name,access_token,tasks,link');

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
      final ctx = testContext(handler: (req) async => _graphError(101), broker: FakeAuthBroker());
      await expectLater(
          adapter.connect(PlatformTier.byokApi,
              {'app_id': '987654321', 'app_secret': 'S', 'user_access_token': 'EAAX'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('App ID'))));
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
      expect(codes(PostVariant(text: 'hi', scheduledAt: DateTime.now().add(const Duration(minutes: 2))), _apiAccount()),
          contains('schedule.too_soon'));
      expect(codes(PostVariant(text: 'hi', scheduledAt: DateTime.now().add(const Duration(days: 40))), _apiAccount()),
          contains('schedule.too_far'));
      expect(
          codes(PostVariant(text: 'hi', media: [fakeVideo()], scheduledAt: DateTime.now().add(const Duration(days: 40))),
              _apiAccount()),
          isNot(contains('schedule.too_far')));
      expect(codes(const PostVariant(text: 'hi'), fakeAccount('facebook', tier: PlatformTier.handoff)),
          contains('handoff.paste_text'));
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

    test('server-side scheduling sets published=false and scheduled_publish_time', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        if (req.url.path.endsWith('/photos')) return _json({'id': 'p${calls.length}'});
        return _json({'id': '123_901'});
      });
      final at = testNow.add(const Duration(days: 2));
      final unix = '${at.millisecondsSinceEpoch ~/ 1000}';
      await adapter.publish(PostVariant(text: 'Later', scheduledAt: at), _apiAccount(), _secrets, ctx);
      expect(bodyOf(calls.single)['published'], 'false');
      expect(bodyOf(calls.single)['scheduled_publish_time'], unix);

      calls.clear();
      await adapter.publish(
          PostVariant(text: 'Later album', scheduledAt: at, media: [fakeImage(id: 'a'), fakeImage(id: 'b')]),
          _apiAccount(),
          _secrets,
          ctx);
      expect(multipartFieldsOf(calls[0])['temporary'], 'true');
      final feed = bodyOf(calls[2]);
      expect(feed['published'], 'false');
      expect(feed['scheduled_publish_time'], unix);
      expect(feed['unpublished_content_type'], 'SCHEDULED');

      final soon = await adapter.publish(
          PostVariant(text: 'x', scheduledAt: testNow.add(const Duration(minutes: 5))), _apiAccount(), _secrets, ctx);
      expect(soon.error?.kind, PublishErrorKind.validation);
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

      test('transient (2) and 5xx -> network', () async {
        expect((await run(_graphError(2, status: 500))).error!.kind, PublishErrorKind.network);
        expect((await run(http.Response('oops', 503))).error!.kind, PublishErrorKind.network);
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
