import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/instagram/instagram_adapter.dart';
import 'package:neforum_core/src/adapters/instagram/instagram_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

http.Response _graphError(int code, {int? subcode, String message = 'boom', String type = 'OAuthException', int status = 400}) =>
    _json({
      'error': {
        'message': message,
        'type': type,
        'code': code,
        if (subcode != null) 'error_subcode': subcode,
        'fbtrace_id': 'trace',
      }
    }, status);

const _base = 'https://graph.instagram.com/v25.0';

void main() {
  final slept = <Duration>[];
  late InstagramAdapter adapter;

  setUp(() {
    slept.clear();
    adapter = InstagramAdapter(sleep: (d) async => slept.add(d));
  });

  ConnectedAccount apiAccount() => fakeAccount('instagram',
      tier: PlatformTier.byokApi, config: {'igUserId': '1784100', 'username': 'neforum_test'});

  final apiSecrets = {
    'access_token': 'LONG',
    'token_type': 'Bearer',
    'expires_at': testNow.add(const Duration(days: 50)).toIso8601String(),
    'refreshed_at': testNow.subtract(const Duration(days: 1)).toIso8601String(),
  };

  group('descriptor', () {
    test('limits match the Instagram docs/research', () {
      final d = adapter.descriptor;
      expect(d.id, 'instagram');
      expect(d.tiers, {PlatformTier.handoff, PlatformTier.byokApi});
      expect(d.defaultTier, PlatformTier.handoff);
      expect(d.personalAccountOk, isFalse);
      expect(d.accountRequirements, contains('personal accounts cannot use the API'));
      expect(d.text.maxLength, 2200);
      expect(d.text.counting, CountingRule.utf16);
      expect(d.text.maxHashtags, 30);
      expect(d.text.supportsThreads, isFalse);
      expect(d.text.titleSupported, isFalse);
      expect(d.text.linkInText, isFalse);
      expect(d.media.requiresMedia, isTrue);
      expect(d.media.requiresPublicMediaUrl, isTrue);
      expect(d.media.maxImages, 10);
      expect(d.media.maxVideos, 10);
      expect(d.media.allowsMixedImageVideo, isTrue);
      expect(d.media.imageMaxBytes, 8 * 1024 * 1024);
      expect(d.media.videoMaxBytes, 300 * 1024 * 1024);
      expect(d.media.videoMaxSeconds, 900);
      expect(d.media.imageMimeTypes, {'image/jpeg'});
      expect(d.media.supportsAltText, isTrue);
      expect(d.serverSideScheduling, isFalse);
      expect(d.setupGuide, 'docs/platforms/instagram.md');
      final q = d.defaultQuotas.single;
      expect(q.id, 'instagram.posts_per_day');
      expect(q.limit, 100);
      expect(q.window, const Duration(hours: 24));
      expect(q.appliesToTier, PlatformTier.byokApi);
    });

    test('connect specs: HTTPS-only redirect for the API tier', () {
      final api = adapter.specFor(PlatformTier.byokApi);
      expect(api.usesBrowser, isTrue);
      expect(api.loopbackRedirectOk, isFalse);
      expect(api.customSchemeRedirectOk, isFalse);
      expect(api.fixedRedirectUri.toString(), 'https://localhost:52771/callback');
      expect(api.fields.where((f) => f.secret).map((f) => f.key), containsAll(['app_secret', 'access_token']));
      expect(api.intro, contains('developers.facebook.com/apps'));
      expect(api.intro, contains('instagram_business_content_publish'));
      final handoff = adapter.specFor(PlatformTier.handoff);
      expect(handoff.usesBrowser, isFalse);
    });
  });

  group('connect', () {
    test('OAuth: authorize URL, code exchange, long-lived exchange, /me', () async {
      final calls = <http.Request>[];
      final broker = FakeAuthBroker(code: 'CODE123#_', redirect: Uri.parse('http://127.0.0.1:52771/callback'));
      final ctx = testContext(
        broker: broker,
        handler: (r) async {
          calls.add(r);
          if (r.url.host == 'api.instagram.com') {
            return _json({
              'data': [
                {'access_token': 'SHORT', 'user_id': 1784100, 'permissions': 'instagram_business_basic,instagram_business_content_publish'}
              ]
            });
          }
          if (r.url.path == '/access_token') {
            return _json({'access_token': 'LONG', 'token_type': 'bearer', 'expires_in': 5183944});
          }
          return _json({
            'data': [
              {'user_id': '1784100', 'username': 'neforum_test', 'name': 'Neforum', 'account_type': 'MEDIA_CREATOR', 'id': 'app-scoped'}
            ]
          });
        },
      );
      final res = await adapter.connect(PlatformTier.byokApi, {'app_id': 'APPID', 'app_secret': 'SECRET'}, ctx);

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.origin + auth.path, 'https://www.instagram.com/oauth/authorize');
      expect(auth.queryParameters['client_id'], 'APPID');
      expect(auth.queryParameters['redirect_uri'], 'https://localhost:52771/callback');
      expect(auth.queryParameters['response_type'], 'code');
      expect(auth.queryParameters['scope'], 'instagram_business_basic,instagram_business_content_publish');
      expect(auth.queryParameters.containsKey('code_challenge'), isFalse);

      expect(calls, hasLength(3));
      expect(calls[0].method, 'POST');
      expect(calls[0].url.toString(), 'https://api.instagram.com/oauth/access_token');
      expect(bodyOf(calls[0]), {
        'client_id': 'APPID',
        'client_secret': 'SECRET',
        'grant_type': 'authorization_code',
        'redirect_uri': 'https://localhost:52771/callback',
        'code': 'CODE123',
      });
      expect(calls[1].method, 'GET');
      expect(calls[1].url.host, 'graph.instagram.com');
      expect(calls[1].url.path, '/access_token');
      expect(calls[1].url.queryParameters,
          {'grant_type': 'ig_exchange_token', 'client_secret': 'SECRET', 'access_token': 'SHORT'});
      expect(calls[2].url.path, '/v25.0/me');
      expect(calls[2].url.queryParameters['fields'], contains('user_id'));
      expect(calls[2].headers['Authorization'], 'Bearer LONG');

      expect(res.secrets['access_token'], 'LONG');
      expect(DateTime.parse(res.secrets['expires_at']!), testNow.add(const Duration(seconds: 5183944)));
      expect(res.secrets['refreshed_at'], isNotNull);
      expect(res.secrets.containsKey('app_secret'), isFalse);
      expect(res.account.tier, PlatformTier.byokApi);
      expect(res.account.config['igUserId'], '1784100');
      expect(res.account.config['appId'], 'APPID');
      expect(res.account.handle, '@neforum_test');
      expect(res.account.profileUrl, 'https://www.instagram.com/neforum_test/');
    });

    test('pasted dashboard token only calls /me', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'user_id': '42', 'username': 'shop', 'account_type': 'BUSINESS'});
      });
      final res = await adapter.connect(PlatformTier.byokApi, {'access_token': ' PASTED '}, ctx);
      expect(calls.single.url.path, '/v25.0/me');
      expect(calls.single.headers['Authorization'], 'Bearer PASTED');
      expect(res.secrets['access_token'], 'PASTED');
      expect(res.secrets.containsKey('expires_at'), isFalse);
      expect(res.account.config['igUserId'], '42');
      expect(res.account.config['tokenSource'], 'dashboard');
    });

    test('missing app id, http redirect and denied consent are reported', () async {
      final ctx = testContext(broker: FakeAuthBroker(), handler: (r) async => _json({}));
      expect(() => adapter.connect(PlatformTier.byokApi, {}, ctx), throwsA(isA<ConnectException>()));
      expect(
          () => adapter.connect(PlatformTier.byokApi,
              {'app_id': 'a', 'app_secret': 'b', 'redirect_uri': 'http://127.0.0.1:52771/callback'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'redirect_uri')));
      final denied = testContext(
        broker: FakeAuthBroker(extraParams: {'error': 'access_denied', 'error_reason': 'user_denied'}),
        handler: (r) async => _json({}),
      );
      expect(() => adapter.connect(PlatformTier.byokApi, {'app_id': 'a', 'app_secret': 'b'}, denied),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('declined'))));
    });

    test('a bare pasted code without state is accepted; wrong state is not', () {
      expect(InstagramAdapter.extractCode(Uri.parse('https://localhost:52771/callback?code=abc%23_'), 's'), 'abc');
      expect(InstagramAdapter.extractCode(Uri.parse('https://localhost:52771/callback?code=abc&state=s#_'), 's'), 'abc');
      expect(() => InstagramAdapter.extractCode(Uri.parse('https://x/cb?code=abc&state=other'), 's'),
          throwsA(isA<ConnectException>()));
    });

    test('personal accounts are refused with a hint', () async {
      final ctx = testContext(handler: (r) async => _json({'user_id': '1', 'username': 'me', 'account_type': 'PERSONAL'}));
      expect(() => adapter.connect(PlatformTier.byokApi, {'access_token': 't'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Hand-off'))));
    });

    test('expired token at connect becomes a ConnectException', () async {
      final ctx = testContext(handler: (r) async => _graphError(190, subcode: 463, message: 'Session has expired'));
      expect(() => adapter.connect(PlatformTier.byokApi, {'access_token': 't'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('expired'))));
    });

    test('hand-off connect needs nothing', () async {
      final ctx = testContext(handler: (r) async => fail('no HTTP expected'));
      final res = await adapter.connect(PlatformTier.handoff, {'username': '@me'}, ctx);
      expect(res.account.tier, PlatformTier.handoff);
      expect(res.account.handle, '@me');
      expect(res.secrets, isEmpty);
    });
  });

  group('validate', () {
    final api = apiAccount();
    final handoff = fakeAccount('instagram', tier: PlatformTier.handoff);
    List<String> codes(PostVariant v, ConnectedAccount a) =>
        adapter.validate(v, a).where((i) => i.isError).map((i) => i.code).toList();

    test('media is required', () {
      expect(codes(const PostVariant(text: 'hello'), api), contains('media.required'));
      expect(codes(const PostVariant(text: 'hello'), handoff), contains('media.required'));
    });

    test('API takes JPEG only; hand-off also takes PNG', () {
      final v = PostVariant(text: 'x', media: [fakeImage(mimeType: 'image/png')]);
      expect(codes(v, api), contains('media.image_type'));
      expect(codes(v, handoff), isNot(contains('media.image_type')));
      final webp = PostVariant(text: 'x', media: [fakeImage(mimeType: 'image/webp')]);
      expect(codes(webp, handoff), contains('media.image_type'));
    });

    test('feed aspect ratio 4:5 to 1.91:1', () {
      expect(codes(PostVariant(text: 'x', media: [fakeImage(width: 1080, height: 1350)]), api), isEmpty);
      expect(codes(PostVariant(text: 'x', media: [fakeImage(width: 1910, height: 1000)]), api), isEmpty);
      expect(codes(PostVariant(text: 'x', media: [fakeImage(width: 1080, height: 1920)]), api),
          contains('instagram.aspect_ratio'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(width: 3000, height: 1000)]), api),
          contains('instagram.aspect_ratio'));
      // Stories are 9:16 by design.
      expect(
          codes(PostVariant(text: '', media: [fakeImage(width: 1080, height: 1920)], extra: const {'storyMode': true}), api),
          isEmpty);
    });

    test('hashtags, mentions and alt text limits', () {
      final tags = List.generate(31, (i) => '#t$i').join(' ');
      expect(codes(PostVariant(text: tags, media: [fakeImage()]), api), contains('hashtags.too_many'));
      final mentions = List.generate(21, (i) => '@u$i').join(' ');
      expect(codes(PostVariant(text: mentions, media: [fakeImage()]), api), contains('instagram.too_many_mentions'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(altText: 'a' * 1001)]), api), contains('instagram.alt_too_long'));
      expect(codes(PostVariant(text: 'x' * 2201, media: [fakeImage()]), api), contains('text.too_long'));
    });

    test('carousel at most 10 items; stories take one file up to 60 s', () {
      final eleven = [for (var i = 0; i < 6; i++) fakeImage(id: 'i$i'), for (var i = 0; i < 5; i++) fakeVideo(id: 'v$i')];
      expect(codes(PostVariant(text: 'x', media: eleven), api), contains('instagram.carousel_too_big'));
      final story = {'storyMode': true};
      expect(codes(PostVariant(text: '', media: [fakeImage(id: 'a'), fakeImage(id: 'b')], extra: story), api),
          contains('instagram.story_single'));
      expect(codes(PostVariant(text: '', media: [fakeVideo(durationMs: 61000)], extra: story), api),
          contains('instagram.story_video_too_long'));
      expect(codes(PostVariant(text: 'x', media: [fakeVideo(durationMs: 2000)]), api), contains('instagram.video_too_short'));
      expect(codes(PostVariant(text: 'x', media: [fakeVideo(durationMs: 61000)]), api), isEmpty);
    });
  });

  group('publish', () {
    test('single image: host, create, poll, publish, permalink, cleanup', () async {
      final calls = <http.Request>[];
      final host = FakeMediaHost();
      final ctx = testContext(
        mediaHost: host,
        handler: (r) async {
          calls.add(r);
          final p = r.url.path;
          if (p == '/v25.0/1784100/media') return _json({'id': 'C1'});
          if (p == '/v25.0/C1') return _json({'status_code': 'FINISHED', 'id': 'C1'});
          if (p == '/v25.0/1784100/media_publish') return _json({'id': 'M1'});
          if (p == '/v25.0/M1') return _json({'permalink': 'https://www.instagram.com/p/abc/', 'id': 'M1'});
          return _json({}, 404);
        },
      );
      final v = PostVariant(text: 'Hello #neforum', media: [fakeImage(width: 1080, height: 1080)]);
      final res = await adapter.publish(v, apiAccount(), apiSecrets, ctx);

      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, 'M1');
      expect(res.remoteUrl, 'https://www.instagram.com/p/abc/');
      expect(host.uploaded.single.id, 'img1');
      expect(host.deleted.single.deleteHandle, 'img1');

      expect(calls.map((c) => '${c.method} ${c.url.path}'), [
        'POST /v25.0/1784100/media',
        'GET /v25.0/C1',
        'POST /v25.0/1784100/media_publish',
        'GET /v25.0/M1',
      ]);
      expect(calls[0].headers['Authorization'], 'Bearer LONG');
      expect(bodyOf(calls[0]), {
        'image_url': 'https://cdn.example.test/img1',
        'caption': 'Hello #neforum',
        'alt_text': 'A test image',
      });
      expect(calls[1].url.queryParameters['fields'], 'status_code,status');
      expect(bodyOf(calls[2]), {'creation_id': 'C1'});
      expect(calls[3].url.queryParameters['fields'], 'permalink');
    });

    test('carousel of image + video: children, polling, parent, publish', () async {
      final calls = <http.Request>[];
      var videoPolls = 0;
      var created = 0;
      final ctx = testContext(
        mediaHost: FakeMediaHost(),
        handler: (r) async {
          calls.add(r);
          final p = r.url.path;
          if (p == '/v25.0/1784100/media') {
            created++;
            return _json({'id': created == 3 ? 'PARENT' : 'CH$created'});
          }
          if (p == '/v25.0/CH2') {
            videoPolls++;
            return _json({'status_code': videoPolls < 3 ? 'IN_PROGRESS' : 'FINISHED'});
          }
          if (p.startsWith('/v25.0/CH') || p == '/v25.0/PARENT') return _json({'status_code': 'FINISHED'});
          if (p == '/v25.0/1784100/media_publish') return _json({'id': 'M9'});
          return _json({'permalink': 'https://www.instagram.com/p/xyz/'});
        },
      );
      final v = PostVariant(
          text: 'Two things',
          media: [fakeImage(width: 1080, height: 1350), fakeVideo(durationMs: 20000)]);
      final res = await adapter.publish(v, apiAccount(), apiSecrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, 'M9');

      final posts = calls.where((c) => c.method == 'POST').toList();
      expect(bodyOf(posts[0]), {'is_carousel_item': 'true', 'image_url': 'https://cdn.example.test/img1', 'alt_text': 'A test image'});
      expect(bodyOf(posts[1]), {'is_carousel_item': 'true', 'media_type': 'VIDEO', 'video_url': 'https://cdn.example.test/vid1'});
      expect(bodyOf(posts[2]), {'media_type': 'CAROUSEL', 'children': 'CH1,CH2', 'caption': 'Two things'});
      expect(bodyOf(posts[3]), {'creation_id': 'PARENT'});
      expect(posts[3].url.path, '/v25.0/1784100/media_publish');
      expect(videoPolls, 3);
      expect(slept, [const Duration(seconds: 3), const Duration(seconds: 5)]);
    });

    test('single video becomes a Reel; story mode sends STORIES without caption', () async {
      final bodies = <Map<String, dynamic>>[];
      Future<http.Response> handler(http.Request r) async {
        if (r.url.path.endsWith('/media')) {
          bodies.add(bodyOf(r));
          return _json({'id': 'C'});
        }
        if (r.url.path.endsWith('/media_publish')) return _json({'id': 'M'});
        return _json({'status_code': 'FINISHED'});
      }

      final ctx = testContext(mediaHost: FakeMediaHost(), handler: handler);
      final reel = PostVariant(text: 'Reel time', media: [fakeVideo()], extra: const {'shareToFeed': true});
      expect((await adapter.publish(reel, apiAccount(), apiSecrets, ctx)).success, isTrue);
      expect(bodies.last, {
        'media_type': 'REELS',
        'video_url': 'https://cdn.example.test/vid1',
        'caption': 'Reel time',
        'share_to_feed': 'true',
      });

      final story = PostVariant(text: '', media: [fakeImage(width: 1080, height: 1920)], extra: const {'storyMode': true});
      expect((await adapter.publish(story, apiAccount(), apiSecrets, ctx)).success, isTrue);
      expect(bodies.last, {'media_type': 'STORIES', 'image_url': 'https://cdn.example.test/img1'});
    });

    test('no media host -> configuration error, no HTTP', () async {
      final ctx = testContext(handler: (r) async => fail('no HTTP expected'));
      final res = await adapter.publish(PostVariant(text: 'x', media: [fakeImage()]), apiAccount(), apiSecrets, ctx);
      expect(res.error!.kind, PublishErrorKind.configuration);
    });

    test('invalid post -> validation error before any upload', () async {
      final host = FakeMediaHost();
      final ctx = testContext(mediaHost: host, handler: (r) async => fail('no HTTP expected'));
      final res = await adapter.publish(const PostVariant(text: 'no media'), apiAccount(), apiSecrets, ctx);
      expect(res.error!.kind, PublishErrorKind.validation);
      expect(host.uploaded, isEmpty);
    });

    test('hand-off accounts cannot publish through the API', () async {
      final ctx = testContext(handler: (r) async => fail('no HTTP expected'));
      final res = await adapter.publish(PostVariant(text: 'x', media: [fakeImage()]),
          fakeAccount('instagram', tier: PlatformTier.handoff), const {}, ctx);
      expect(res.error!.kind, PublishErrorKind.unsupported);
    });

    group('error mapping', () {
      Future<PublishResult> publishWith(http.Response Function(http.Request) onCreate, {FakeMediaHost? host}) {
        final ctx = testContext(
          mediaHost: host ?? FakeMediaHost(),
          handler: (r) async => onCreate(r),
        );
        return adapter.publish(PostVariant(text: 'x', media: [fakeImage()]), apiAccount(), apiSecrets, ctx);
      }

      test('expired token (HTTP 400, code 190) -> auth', () async {
        final res = await publishWith((_) => _graphError(190, subcode: 463, message: 'Error validating access token'));
        expect(res.error!.kind, PublishErrorKind.auth);
      });

      test('HTTP 401 -> auth', () async {
        final res = await publishWith((_) => http.Response('nope', 401));
        expect(res.error!.kind, PublishErrorKind.auth);
      });

      test('HTTP 429 -> quota with retryAfter', () async {
        final res = await publishWith((_) => _json({'error': {'message': 'slow down'}}, 429, {'retry-after': '120'}));
        expect(res.error!.kind, PublishErrorKind.quota);
        expect(res.error!.retryAfter, const Duration(seconds: 120));
      });

      test('throttling code 4 -> quota with BUC estimated time', () async {
        final buc = jsonEncode({
          '1784100': [
            {'type': 'instagram', 'call_count': 100, 'estimated_time_to_regain_access': 15}
          ]
        });
        final res = await publishWith((_) => http.Response(
            jsonEncode({'error': {'message': 'Application request limit reached', 'code': 4}}), 400,
            headers: {...jsonHeaders, 'x-business-use-case-usage': buc}));
        expect(res.error!.kind, PublishErrorKind.quota);
        expect(res.error!.retryAfter, const Duration(minutes: 15));
      });

      test('daily publishing limit (9 / 2207042) -> quota', () async {
        final res = await publishWith((_) => _graphError(9, subcode: 2207042));
        expect(res.error!.kind, PublishErrorKind.quota);
      });

      test('aspect ratio (36003 / 2207009) -> validation', () async {
        final res = await publishWith((_) => _graphError(36003, subcode: 2207009));
        expect(res.error!.kind, PublishErrorKind.validation);
      });

      test('media not fetchable (9004 / 2207052) -> configuration, hosted file still deleted', () async {
        final host = FakeMediaHost();
        final res = await publishWith((_) => _graphError(9004, subcode: 2207052), host: host);
        expect(res.error!.kind, PublishErrorKind.configuration);
        expect(host.deleted, hasLength(1));
      });

      test('spam flag (4 / 2207051) -> platform, not retryable', () async {
        final res = await publishWith((_) => _graphError(4, subcode: 2207051));
        expect(res.error!.kind, PublishErrorKind.platform);
        expect(res.error!.retryable, isFalse);
      });

      test('container status ERROR -> classified by embedded subcode', () async {
        final res = await publishWith((r) => r.url.path.endsWith('/media')
            ? _json({'id': 'C1'})
            : _json({'status_code': 'ERROR', 'status': 'Error: Media upload has failed with error code 2207026'}));
        expect(res.error!.kind, PublishErrorKind.validation);
      });

      test('5xx -> network', () async {
        final res = await publishWith((_) => http.Response('oops', 500));
        expect(res.error!.kind, PublishErrorKind.network);
      });
    });
  });

  group('refreshSecrets', () {
    test('fresh token -> null without HTTP', () async {
      final ctx = testContext(handler: (r) async => fail('no HTTP expected'));
      expect(await adapter.refreshSecrets(apiAccount(), apiSecrets, ctx), isNull);
    });

    test('week-old token is refreshed via ig_refresh_token', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'access_token': 'NEW', 'token_type': 'bearer', 'expires_in': 5183944});
      });
      final old = {
        ...apiSecrets,
        'refreshed_at': testNow.subtract(const Duration(days: 8)).toIso8601String(),
      };
      final out = await adapter.refreshSecrets(apiAccount(), old, ctx);
      expect(calls.single.method, 'GET');
      expect(calls.single.url.toString(),
          'https://graph.instagram.com/refresh_access_token?grant_type=ig_refresh_token&access_token=LONG');
      expect(out!['access_token'], 'NEW');
      expect(DateTime.parse(out['expires_at']!), testNow.add(const Duration(seconds: 5183944)));
      expect(DateTime.parse(out['refreshed_at']!), testNow);
    });

    test('expired token -> AdapterException(auth)', () async {
      final ctx = testContext(handler: (r) async => fail('no HTTP expected'));
      final expired = {...apiSecrets, 'expires_at': testNow.subtract(const Duration(minutes: 1)).toIso8601String()};
      expect(
          () => adapter.refreshSecrets(apiAccount(), expired, ctx),
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
    });

    test('revoked token on refresh -> auth; transient failure -> keep token', () async {
      final old = {...apiSecrets, 'refreshed_at': testNow.subtract(const Duration(days: 10)).toIso8601String()};
      final revoked = testContext(handler: (r) async => _graphError(190, message: 'Invalid OAuth access token'));
      expect(
          () => adapter.refreshSecrets(apiAccount(), old, revoked),
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
      final flaky = testContext(handler: (r) async => http.Response('down', 503));
      expect(await adapter.refreshSecrets(apiAccount(), old, flaky), isNull);
    });
  });

  group('hand-off', () {
    test('share sheet with caption on the clipboard', () {
      final v = PostVariant(text: 'Sunset #nofilter', media: [fakeImage()]);
      final plan = adapter.buildHandoff(v);
      expect(plan.platformId, 'instagram');
      expect(plan.webIntent, isNull);
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.clipboardText, 'Sunset #nofilter');
      expect(plan.shareFiles.single.id, 'img1');
      expect(plan.androidPackage, 'com.instagram.android');
      expect(plan.iosScheme, 'instagram://');
      expect(plan.desktopUrl, 'https://www.instagram.com/');
      expect(plan.mediaNote, contains('clipboard'));
      expect(plan.instructions, startsWith('1. '));
      expect(plan.instructions, contains('Paste'));
    });

    test('story hand-off has no caption step', () {
      final plan = adapter.buildHandoff(
          PostVariant(text: 'ignored', media: [fakeImage()], extra: const {'storyMode': true}));
      expect(plan.clipboardText, isNull);
      expect(plan.instructions, contains('Story'));
    });
  });

  test('graph helper builds versioned URLs', () {
    expect(InstagramApi.graph('me', {'fields': 'user_id'}).toString(), '$_base/me?fields=user_id');
  });
}
