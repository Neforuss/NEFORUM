import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/threads/threads_adapter.dart';
import 'package:neforum_core/src/adapters/threads/threads_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

/// Records every request and answers from a queue of canned responses keyed
/// by `METHOD path` (falls back to the last response for that key).
class _Router {
  final List<http.Request> calls = [];
  final Map<String, List<http.Response>> _queues = {};

  void on(String method, String path, Object body, {int status = 200, Map<String, String> headers = jsonHeaders}) {
    _queues.putIfAbsent('$method $path', () => []).add(http.Response(jsonEncode(body), status, headers: headers));
  }

  Future<http.Response> handle(http.Request r) async {
    calls.add(r);
    final q = _queues['${r.method} ${r.url.path}'];
    if (q == null || q.isEmpty) return http.Response('{"error":{"message":"unexpected ${r.method} ${r.url.path}"}}', 404);
    return q.length > 1 ? q.removeAt(0) : q.first;
  }
}

ConnectedAccount _account({PlatformTier tier = PlatformTier.byokApi}) => fakeAccount(
      'threads',
      tier: tier,
      config: const {'app_id': '111', 'user_id': '123', 'redirect_uri': 'https://127.0.0.1:52771/callback'},
    );

final Map<String, String> _secrets = {
  'access_token': 'LONG',
  'expires_at': testNow.add(const Duration(days: 50)).toIso8601String(),
  'token_type': 'Bearer',
  'app_secret': 'SECRET',
  'token_issued_at': testNow.subtract(const Duration(hours: 2)).toIso8601String(),
};

void main() {
  final delays = <Duration>[];
  late ThreadsAdapter adapter;
  late _Router router;

  setUp(() {
    delays.clear();
    adapter = ThreadsAdapter(delay: (d) async => delays.add(d));
    router = _Router();
  });

  AdapterContext ctx({AuthBroker? broker, MediaHost? host}) =>
      testContext(handler: router.handle, broker: broker, mediaHost: host);

  group('descriptor', () {
    test('limits match the research', () {
      final d = adapter.descriptor;
      expect(d.id, 'threads');
      expect(d.tiers, {PlatformTier.byokApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.byokApi);
      expect(d.text.maxLength, 500);
      expect(d.text.counting, CountingRule.utf16);
      expect(d.text.supportsThreads, isTrue);
      expect(d.text.titleSupported, isFalse);
      expect(d.media.maxImages, 20);
      expect(d.media.maxVideos, 20);
      expect(d.media.allowsMixedImageVideo, isTrue);
      expect(d.media.imageMaxBytes, 8 * 1024 * 1024);
      expect(d.media.videoMaxBytes, 1024 * 1024 * 1024);
      expect(d.media.videoMaxSeconds, 300);
      expect(d.media.imageMimeTypes, {'image/jpeg', 'image/png'});
      expect(d.media.requiresPublicMediaUrl, isTrue);
      expect(d.media.supportsAltText, isTrue);
      expect(d.personalAccountOk, isTrue);
      expect(d.serverSideScheduling, isFalse);
      expect(d.setupGuide, 'docs/platforms/threads.md');
      final q = d.defaultQuotas.single;
      expect(q.id, 'threads.posts_per_day');
      expect(q.limit, 250);
      expect(q.window, const Duration(hours: 24));
    });

    test('connect specs: HTTPS-only redirect, secret field', () {
      final byok = adapter.specFor(PlatformTier.byokApi);
      expect(byok.usesBrowser, isTrue);
      expect(byok.loopbackRedirectOk, isFalse);
      expect(byok.customSchemeRedirectOk, isFalse);
      expect(byok.fixedRedirectUri.toString(), 'https://127.0.0.1:52771/callback');
      expect(byok.fields.firstWhere((f) => f.key == 'app_secret').secret, isTrue);
      final token = byok.fields.firstWhere((f) => f.key == 'access_token');
      expect(token.secret, isTrue);
      expect(token.required, isFalse);
      // App ID and secret are optional because a pasted token needs neither.
      expect(byok.fields.firstWhere((f) => f.key == 'app_id').required, isFalse);
      expect(byok.fields.firstWhere((f) => f.key == 'app_secret').required, isFalse);
      expect(byok.intro, contains('threads_content_publish'));
      expect(byok.intro, contains('https://developers.facebook.com/apps/creation/'));
      expect(byok.intro, contains('Threads Tester'));
      expect(byok.intro, contains('Website permissions'));
      expect(byok.intro, contains('`https://127.0.0.1:52771/callback`'));
      expect(adapter.specFor(PlatformTier.handoff).usesBrowser, isFalse);
    });
  });

  group('connect', () {
    void stubTokens() {
      router
        ..on('POST', '/oauth/access_token', {'access_token': 'SHORT', 'user_id': 123, 'token_type': 'bearer'})
        ..on('GET', '/access_token', {'access_token': 'LONG', 'token_type': 'bearer', 'expires_in': 5183944})
        ..on('GET', '/v1.0/me', {'id': '123', 'username': 'alice', 'threads_profile_picture_url': 'https://x.test/a.jpg'});
    }

    test('happy path: authorize, exchange, long-lived, profile', () async {
      stubTokens();
      final broker = FakeAuthBroker(code: 'abc123#_');
      final res = await adapter.connect(
          PlatformTier.byokApi, {'app_id': '111', 'app_secret': 'SECRET'}, ctx(broker: broker));

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.host, 'threads.com');
      expect(auth.path, '/oauth/authorize');
      expect(auth.queryParameters['client_id'], '111');
      expect(auth.queryParameters['redirect_uri'], 'https://127.0.0.1:52771/callback');
      expect(auth.queryParameters['scope'], 'threads_basic,threads_content_publish');
      expect(auth.queryParameters['response_type'], 'code');
      expect(auth.queryParameters.containsKey('code_challenge'), isFalse);

      expect(router.calls, hasLength(3));
      final exchange = router.calls[0];
      expect(exchange.method, 'POST');
      expect(exchange.url.toString(), 'https://graph.threads.net/oauth/access_token');
      expect(bodyOf(exchange), {
        'grant_type': 'authorization_code',
        'code': 'abc123',
        'redirect_uri': 'https://127.0.0.1:52771/callback',
        'client_id': '111',
        'client_secret': 'SECRET',
      });
      final longLived = router.calls[1];
      expect(longLived.method, 'GET');
      expect(longLived.url.host, 'graph.threads.net');
      expect(longLived.url.path, '/access_token');
      expect(longLived.url.queryParameters,
          {'grant_type': 'th_exchange_token', 'client_secret': 'SECRET', 'access_token': 'SHORT'});
      final me = router.calls[2];
      expect(me.url.path, '/v1.0/me');
      expect(me.url.queryParameters['fields'], 'id,username,threads_profile_picture_url');
      expect(me.url.queryParameters['access_token'], 'LONG');

      expect(res.account.id, 'threads:123');
      expect(res.account.tier, PlatformTier.byokApi);
      expect(res.account.handle, '@alice');
      expect(res.account.avatarUrl, 'https://x.test/a.jpg');
      expect(res.account.config['user_id'], '123');
      expect(res.account.config['app_id'], '111');
      expect(res.secrets['access_token'], 'LONG');
      expect(res.secrets['app_secret'], 'SECRET');
      expect(res.secrets['token_type'], 'Bearer');
      expect(DateTime.parse(res.secrets['expires_at']!), testNow.add(const Duration(seconds: 5183944)));
      expect(DateTime.parse(res.secrets['token_issued_at']!), testNow);
    });

    test('paste-code broker with a bare code (no state) works', () async {
      stubTokens();
      final broker = PasteCodeAuthBroker(askUser: (url, redirect) async => 'pasted-code#_');
      final res = await adapter.connect(PlatformTier.byokApi,
          {'app_id': '111', 'app_secret': 'SECRET', 'redirect_uri': 'https://example.org/cb/'}, ctx(broker: broker));
      expect(bodyOf(router.calls.first)['code'], 'pasted-code');
      expect(bodyOf(router.calls.first)['redirect_uri'], 'https://example.org/cb/');
      expect(res.account.config['redirect_uri'], 'https://example.org/cb/');
    });

    test('rejects bad input', () async {
      final c = ctx(broker: FakeAuthBroker());
      expect(() => adapter.connect(PlatformTier.byokApi, {'app_secret': 'S'}, c), throwsA(isA<ConnectException>()));
      expect(() => adapter.connect(PlatformTier.byokApi, {'app_id': '1', 'app_secret': 'S', 'redirect_uri': 'http://127.0.0.1/cb'}, c),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'redirect_uri')));
      expect(() => adapter.connect(PlatformTier.byokApi, {'app_id': '1', 'app_secret': 'S'}, ctx()),
          throwsA(isA<ConnectException>()));
    });

    test('state mismatch and token failure surface as ConnectException', () async {
      final mismatch = FakeAuthBroker(extraParams: {'state': 'other'});
      await expectLater(adapter.connect(PlatformTier.byokApi, {'app_id': '1', 'app_secret': 'S'}, ctx(broker: mismatch)),
          throwsA(isA<ConnectException>()));
      router.on('POST', '/oauth/access_token', {
        'error': {'message': 'Invalid redirect_uri', 'code': 36008}
      }, status: 400);
      await expectLater(adapter.connect(PlatformTier.byokApi, {'app_id': '1', 'app_secret': 'S'}, ctx(broker: FakeAuthBroker())),
          throwsA(isA<ConnectException>()));
    });

    group('pasted token', () {
      int unix(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
      void stubMe() =>
          router.on('GET', '/v1.0/me', {'id': '123', 'username': 'alice', 'threads_profile_picture_url': 'https://x.test/a.jpg'});
      void stubDebug(Duration expiresIn, {Duration age = Duration.zero, List<String>? scopes}) =>
          router.on('GET', '/v1.0/debug_token', {
            'data': {
              'type': 'USER',
              'application': 'My NEFORUM',
              'is_valid': true,
              'issued_at': unix(testNow.subtract(age)),
              'expires_at': unix(testNow.add(expiresIn)),
              'scopes': scopes ?? ['threads_basic', 'threads_content_publish'],
              'user_id': '123',
            }
          });

      test('60-day token: /me and debug_token, no exchange, no app credentials needed', () async {
        stubMe();
        stubDebug(const Duration(days: 58), age: const Duration(days: 2));
        final res = await adapter.connect(PlatformTier.byokApi, {'access_token': ' THTOKEN ', 'redirect_uri': ''}, ctx());

        expect(router.calls.map((c) => '${c.method} ${c.url.path}'), ['GET /v1.0/me', 'GET /v1.0/debug_token']);
        expect(router.calls[0].url.queryParameters['access_token'], 'THTOKEN');
        expect(router.calls[1].url.host, 'graph.threads.net');
        expect(router.calls[1].url.queryParameters, {'input_token': 'THTOKEN', 'access_token': 'THTOKEN'});

        expect(res.account.id, 'threads:123');
        expect(res.account.handle, '@alice');
        expect(res.account.config['token_source'], 'pasted');
        expect(res.account.config.containsKey('app_id'), isFalse);
        expect(res.secrets['access_token'], 'THTOKEN');
        expect(res.secrets.containsKey('app_secret'), isFalse);
        expect(DateTime.parse(res.secrets['expires_at']!), testNow.add(const Duration(days: 58)));
        expect(DateTime.parse(res.secrets['token_issued_at']!), testNow.subtract(const Duration(days: 2)));
      });

      test('a pasted token older than 24 h is renewed with th_refresh_token on the next publish', () async {
        stubMe();
        stubDebug(const Duration(days: 58), age: const Duration(days: 2));
        final res = await adapter.connect(PlatformTier.byokApi, {'access_token': 'THTOKEN'}, ctx());
        router.on('GET', '/refresh_access_token', {'access_token': 'RENEWED', 'token_type': 'bearer', 'expires_in': 5183944});
        final s = await adapter.refreshSecrets(res.account, res.secrets, ctx());
        final call = router.calls.last;
        expect(call.url.toString().split('?').first, 'https://graph.threads.net/refresh_access_token');
        expect(call.url.queryParameters, {'grant_type': 'th_refresh_token', 'access_token': 'THTOKEN'});
        expect(s!['access_token'], 'RENEWED');
        expect(DateTime.parse(s['expires_at']!), testNow.add(const Duration(seconds: 5183944)));
        expect(DateTime.parse(s['token_issued_at']!), testNow);
      });

      test('1-hour token with the app secret is exchanged for a 60-day token', () async {
        stubMe();
        stubDebug(const Duration(minutes: 50));
        router.on('GET', '/access_token', {'access_token': 'LONG', 'token_type': 'bearer', 'expires_in': 5183944});
        final res = await adapter.connect(
            PlatformTier.byokApi, {'access_token': 'SHORT', 'app_id': '111', 'app_secret': 'SECRET'}, ctx());

        final exchange = router.calls.last;
        expect(exchange.url.path, '/access_token');
        expect(exchange.url.queryParameters,
            {'grant_type': 'th_exchange_token', 'client_secret': 'SECRET', 'access_token': 'SHORT'});
        expect(res.secrets['access_token'], 'LONG');
        expect(res.secrets['app_secret'], 'SECRET');
        expect(DateTime.parse(res.secrets['expires_at']!), testNow.add(const Duration(seconds: 5183944)));
        expect(DateTime.parse(res.secrets['token_issued_at']!), testNow);
        expect(res.account.config['app_id'], '111');
      });

      test('1-hour token without the app secret asks for it', () async {
        stubMe();
        stubDebug(const Duration(minutes: 50));
        await expectLater(adapter.connect(PlatformTier.byokApi, {'access_token': 'SHORT'}, ctx()),
            throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'app_secret')));
      });

      test('a token without threads_content_publish is refused', () async {
        stubMe();
        stubDebug(const Duration(days: 50), scopes: ['threads_basic']);
        await expectLater(
            adapter.connect(PlatformTier.byokApi, {'access_token': 'T'}, ctx()),
            throwsA(isA<ConnectException>()
                .having((e) => e.field, 'field', 'access_token')
                .having((e) => e.message, 'message', contains('threads_content_publish'))));
      });

      test('an invalid token fails at /me and points at the token field', () async {
        router.on('GET', '/v1.0/me', {
          'error': {'message': 'Invalid OAuth access token', 'type': 'OAuthException', 'code': 190}
        }, status: 400);
        await expectLater(adapter.connect(PlatformTier.byokApi, {'access_token': 'BAD'}, ctx()),
            throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'access_token')));
        expect(router.calls, hasLength(1));
      });

      test('debug_token unavailable: keeps the token and renews it 24 h after connecting', () async {
        stubMe(); // debug_token is not stubbed -> 404
        final res = await adapter.connect(PlatformTier.byokApi, {'access_token': 'THTOKEN'}, ctx());
        expect(res.secrets['access_token'], 'THTOKEN');
        expect(res.secrets.containsKey('expires_at'), isFalse);
        expect(DateTime.parse(res.secrets['token_issued_at']!), testNow);
        expect(router.calls.where((c) => c.url.path == '/access_token'), isEmpty);
        // Too young to refresh: Meta only renews tokens that are 24 h old.
        expect(await adapter.refreshSecrets(res.account, res.secrets, ctx()), isNull);
      });

      test('debug_token unavailable with an app secret: tries the exchange, keeps the token if Meta refuses', () async {
        stubMe();
        router.on('GET', '/access_token', {
          'error': {'message': 'Unsupported request', 'type': 'OAuthException', 'code': 100}
        }, status: 400);
        final res = await adapter.connect(
            PlatformTier.byokApi, {'access_token': 'THTOKEN', 'app_secret': 'SECRET'}, ctx());
        expect(router.calls.where((c) => c.url.path == '/access_token'), hasLength(1));
        expect(res.secrets['access_token'], 'THTOKEN');
        expect(res.secrets['app_secret'], 'SECRET');
      });

      test('a non-numeric app id is still rejected', () async {
        await expectLater(adapter.connect(PlatformTier.byokApi, {'access_token': 'T', 'app_id': 'abc'}, ctx()),
            throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'app_id')));
        expect(router.calls, isEmpty);
      });
    });

    test('hand-off tier needs no credentials', () async {
      final res = await adapter.connect(PlatformTier.handoff, {'username': '@Alice'}, ctx());
      expect(res.account.tier, PlatformTier.handoff);
      expect(res.account.id, 'threads-handoff:alice');
      expect(res.secrets, isEmpty);
      expect(router.calls, isEmpty);
    });
  });

  group('validate', () {
    List<String> codes(PostVariant v, {PlatformTier tier = PlatformTier.byokApi}) =>
        adapter.validate(v, _account(tier: tier)).map((i) => i.code).toList();

    test('text length and empty post', () {
      expect(codes(PostVariant(text: 'a' * 500)), isNot(contains('text.too_long')));
      expect(codes(PostVariant(text: 'a' * 501)), contains('text.too_long'));
      expect(codes(const PostVariant(text: '')), contains('post.empty'));
    });

    test('emoji counted as UTF-8 bytes gives a warning', () {
      final v = PostVariant(text: '${'a' * 480}${'\u{1F600}' * 6}'); // 492 UTF-16 units, 504 Meta units
      expect(ThreadsAdapter.metaCount('\u{1F600}'), 4);
      expect(codes(v), contains('threads.emoji_bytes'));
      expect(codes(v), isNot(contains('text.too_long')));
    });

    test('media rules', () {
      final many = List.generate(21, (i) => fakeImage(id: 'i$i'));
      expect(codes(PostVariant(text: 'x', media: many)), contains('threads.too_many_items'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(width: 2200, height: 200)])), contains('threads.aspect_ratio'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(mimeType: 'image/gif')])), contains('media.image_type'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(sizeBytes: 9 * 1024 * 1024)])), contains('media.image_too_large'));
      expect(codes(PostVariant(text: 'x', media: [fakeVideo(durationMs: 301000)])), contains('media.video_too_long'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(altText: 'a' * 1001)])), contains('threads.alt_too_long'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(), fakeVideo()])), isNot(contains('media.mixed')));
    });

    test('links, topic tag and reply control', () {
      final links = List.generate(6, (i) => 'https://e$i.com').join(' ');
      expect(codes(PostVariant(text: links)), contains('threads.too_many_links'));
      expect(codes(const PostVariant(text: 'hi', extra: {'topic_tag': 'a.b'})), contains('threads.topic_tag'));
      expect(codes(const PostVariant(text: 'hi', extra: {'topic_tag': 'Dart'})), isNot(contains('threads.topic_tag')));
      expect(codes(const PostVariant(text: 'hi', extra: {'reply_control': 'nobody'})), contains('threads.reply_control'));
      expect(codes(const PostVariant(text: 'hi', extra: {'reply_control': 'followers_only'})),
          isNot(contains('threads.reply_control')));
    });
  });

  group('publish', () {
    void stubPublish({List<String> publishIds = const ['900']}) {
      for (final id in publishIds) {
        router.on('POST', '/v1.0/123/threads_publish', {'id': id});
      }
      router.on('GET', '/v1.0/${publishIds.first}', {'permalink': 'https://www.threads.com/@alice/post/ABC'});
    }

    test('text post: create container, publish, permalink', () async {
      router.on('POST', '/v1.0/123/threads', {'id': 'c1'});
      stubPublish();
      final r = await adapter.publish(
          const PostVariant(text: 'Hello Threads', extra: {'reply_control': 'followers_only', 'topic_tag': 'Dart'}),
          _account(), _secrets, ctx());
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, '900');
      expect(r.remoteUrl, 'https://www.threads.com/@alice/post/ABC');
      expect(r.threadRemoteIds, isEmpty);

      expect(router.calls.map((c) => '${c.method} ${c.url.path}'), [
        'POST /v1.0/123/threads',
        'POST /v1.0/123/threads_publish',
        'GET /v1.0/900',
      ]);
      expect(router.calls[0].url.host, 'graph.threads.net');
      expect(bodyOf(router.calls[0]), {
        'media_type': 'TEXT',
        'text': 'Hello Threads',
        'reply_control': 'followers_only',
        'topic_tag': 'Dart',
        'access_token': 'LONG',
      });
      expect(bodyOf(router.calls[1]), {'creation_id': 'c1', 'access_token': 'LONG'});
      expect(router.calls[2].url.queryParameters['fields'], 'permalink');
    });

    test('text post with a link sets link_attachment', () async {
      router.on('POST', '/v1.0/123/threads', {'id': 'c1'});
      stubPublish();
      final r = await adapter.publish(
          const PostVariant(text: 'Read this\n\nhttps://example.com/a', link: 'https://example.com/a'),
          _account(), _secrets, ctx());
      expect(r.success, isTrue);
      expect(bodyOf(router.calls[0])['link_attachment'], 'https://example.com/a');
    });

    test('single image: host upload, container, poll until FINISHED, publish, delete', () async {
      final host = FakeMediaHost();
      router
        ..on('POST', '/v1.0/123/threads', {'id': 'c1'})
        ..on('GET', '/v1.0/c1', {'status': 'IN_PROGRESS', 'id': 'c1'})
        ..on('GET', '/v1.0/c1', {'status': 'FINISHED', 'id': 'c1'});
      stubPublish();
      final progress = <String>[];
      final c = testContext(handler: router.handle, mediaHost: host).copyWith(onProgress: progress.add);
      final r = await adapter.publish(
          PostVariant(text: 'Pic', media: [fakeImage()], sensitive: true), _account(), _secrets, c);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(router.calls.map((c) => '${c.method} ${c.url.path}'), [
        'POST /v1.0/123/threads',
        'GET /v1.0/c1',
        'GET /v1.0/c1',
        'POST /v1.0/123/threads_publish',
        'GET /v1.0/900',
      ]);
      expect(bodyOf(router.calls[0]), {
        'media_type': 'IMAGE',
        'image_url': 'https://cdn.example.test/img1',
        'alt_text': 'A test image',
        'is_spoiler_media': 'true',
        'text': 'Pic',
        'access_token': 'LONG',
      });
      expect(router.calls[1].url.queryParameters['fields'], 'status,error_message');
      expect(delays, [const Duration(seconds: 10)]);
      expect(host.uploaded.single.id, 'img1');
      expect(host.deleted, hasLength(1));
      expect(progress.first, contains('Uploading image 1 of 1'));
    });

    test('carousel: children with is_carousel_item, then CAROUSEL container', () async {
      final host = FakeMediaHost();
      router
        ..on('POST', '/v1.0/123/threads', {'id': 'k1'})
        ..on('POST', '/v1.0/123/threads', {'id': 'k2'})
        ..on('POST', '/v1.0/123/threads', {'id': 'car'});
      for (final id in ['k1', 'k2', 'car']) {
        router.on('GET', '/v1.0/$id', {'status': 'FINISHED'});
      }
      stubPublish();
      final r = await adapter.publish(
          PostVariant(text: 'Two things', media: [fakeImage(id: 'a'), fakeVideo(id: 'b')]), _account(), _secrets,
          ctx(host: host));
      expect(r.success, isTrue, reason: '${r.error}');
      expect(router.calls.map((c) => '${c.method} ${c.url.path}'), [
        'POST /v1.0/123/threads',
        'GET /v1.0/k1',
        'POST /v1.0/123/threads',
        'GET /v1.0/k2',
        'POST /v1.0/123/threads',
        'GET /v1.0/car',
        'POST /v1.0/123/threads_publish',
        'GET /v1.0/900',
      ]);
      expect(bodyOf(router.calls[0]), {
        'media_type': 'IMAGE',
        'image_url': 'https://cdn.example.test/a',
        'alt_text': 'A test image',
        'is_carousel_item': 'true',
        'access_token': 'LONG',
      });
      expect(bodyOf(router.calls[2]), {
        'media_type': 'VIDEO',
        'video_url': 'https://cdn.example.test/b',
        'is_carousel_item': 'true',
        'access_token': 'LONG',
      });
      expect(bodyOf(router.calls[4]), {
        'media_type': 'CAROUSEL',
        'children': 'k1,k2',
        'text': 'Two things',
        'access_token': 'LONG',
      });
      expect(bodyOf(router.calls[6])['creation_id'], 'car');
      expect(host.deleted, hasLength(2));
    });

    test('media without a media host is a configuration error', () async {
      final r = await adapter.publish(PostVariant(text: 'x', media: [fakeImage()]), _account(), _secrets, ctx());
      expect(r.success, isFalse);
      expect(r.error!.kind, PublishErrorKind.configuration);
      expect(r.error!.message, contains('media host'));
      expect(router.calls, isEmpty);
    });

    test('thread: parts chained with reply_to_id, media on the first part', () async {
      final host = FakeMediaHost();
      router
        ..on('POST', '/v1.0/123/threads', {'id': 'c1'})
        ..on('POST', '/v1.0/123/threads', {'id': 'c2'})
        ..on('POST', '/v1.0/123/threads', {'id': 'c3'})
        ..on('GET', '/v1.0/c1', {'status': 'FINISHED'});
      stubPublish(publishIds: ['p1', 'p2', 'p3']);
      final r = await adapter.publish(
          PostVariant(text: 'one', threadParts: const ['one', 'two', 'three'], media: [fakeImage()]),
          _account(), _secrets, ctx(host: host));
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, 'p1');
      expect(r.threadRemoteIds, ['p1', 'p2', 'p3']);
      final creates = router.calls.where((c) => c.url.path == '/v1.0/123/threads').map(bodyOf).toList();
      expect(creates[0]['media_type'], 'IMAGE');
      expect(creates[0].containsKey('reply_to_id'), isFalse);
      expect(creates[1], {'media_type': 'TEXT', 'text': 'two', 'reply_to_id': 'p1', 'access_token': 'LONG'});
      expect(creates[2], {'media_type': 'TEXT', 'text': 'three', 'reply_to_id': 'p2', 'access_token': 'LONG'});
      final publishes = router.calls.where((c) => c.url.path == '/v1.0/123/threads_publish').map(bodyOf).toList();
      expect(publishes.map((b) => b['creation_id']), ['c1', 'c2', 'c3']);
    });

    test('hand-off accounts are not published through the API', () async {
      final r = await adapter.publish(const PostVariant(text: 'x'), _account(tier: PlatformTier.handoff), _secrets, ctx());
      expect(r.error!.kind, PublishErrorKind.unsupported);
    });
  });

  group('error mapping', () {
    Future<PublishError> failWith(int status, Object body, {Map<String, String> headers = jsonHeaders}) async {
      router.on('POST', '/v1.0/123/threads', body, status: status, headers: headers);
      final r = await adapter.publish(const PostVariant(text: 'x'), _account(), _secrets, ctx());
      expect(r.success, isFalse);
      return r.error!;
    }

    test('401 / code 190 -> auth', () async {
      final e = await failWith(401, {
        'error': {'message': 'Error validating access token', 'type': 'OAuthException', 'code': 190}
      });
      expect(e.kind, PublishErrorKind.auth);
      expect(e.statusCode, 401);
    });

    test('429 -> quota with retryAfter', () async {
      final e = await failWith(429, {
        'error': {'message': 'Too many calls', 'code': 4}
      }, headers: {...jsonHeaders, 'retry-after': '120'});
      expect(e.kind, PublishErrorKind.quota);
      expect(e.retryAfter, const Duration(seconds: 120));
    });

    test('400 / code 100 -> validation', () async {
      final e = await failWith(400, {
        'error': {'message': 'Invalid parameter', 'type': 'OAuthException', 'code': 100}
      });
      expect(e.kind, PublishErrorKind.validation);
      expect(e.message, contains('Invalid parameter'));
    });

    test('link limit -> validation', () async {
      final e = await failWith(400, {
        'error': {'message': 'THREADS_API__LINK_LIMIT_EXCEEDED', 'code': 1}
      });
      expect(e.kind, PublishErrorKind.validation);
    });

    test('code 10 permission -> auth; 500 -> network', () async {
      expect((await failWith(403, {
        'error': {'message': 'Permission denied', 'code': 10}
      }))
          .kind, PublishErrorKind.auth);
      router = _Router();
      expect((await failWith(500, {'error': {'message': 'oops', 'code': 2}})).kind, PublishErrorKind.network);
    });

    test('container ERROR states', () {
      expect(containerError('FAILED_DOWNLOADING_VIDEO').kind, PublishErrorKind.configuration);
      expect(containerError('INVALID_ASPEC_RATIO').kind, PublishErrorKind.validation);
      expect(containerError('UNKNOWN').kind, PublishErrorKind.platform);
    });

    test('video container that fails processing returns the mapped error and still cleans up', () async {
      final host = FakeMediaHost();
      router
        ..on('POST', '/v1.0/123/threads', {'id': 'v1'})
        ..on('GET', '/v1.0/v1', {'status': 'ERROR', 'error_message': 'FAILED_DOWNLOADING_VIDEO'});
      final r = await adapter.publish(PostVariant(text: 'x', media: [fakeVideo()]), _account(), _secrets, ctx(host: host));
      expect(r.error!.kind, PublishErrorKind.configuration);
      expect(host.deleted, hasLength(1));
    });

    test('processing timeout after 5 minutes -> network', () async {
      final host = FakeMediaHost();
      router
        ..on('POST', '/v1.0/123/threads', {'id': 'v1'})
        ..on('GET', '/v1.0/v1', {'status': 'IN_PROGRESS'});
      final r = await adapter.publish(PostVariant(text: 'x', media: [fakeVideo()]), _account(), _secrets, ctx(host: host));
      expect(r.error!.kind, PublishErrorKind.network);
      expect(delays.fold<int>(0, (a, d) => a + d.inSeconds), 300);
    });

    test('transport failure -> network', () async {
      final c = testContext(handler: (_) async => throw http.ClientException('offline'));
      final r = await adapter.publish(const PostVariant(text: 'x'), _account(), _secrets, c);
      expect(r.error!.kind, PublishErrorKind.network);
    });
  });

  group('refreshSecrets', () {
    test('token younger than 24 h: nothing to do', () async {
      expect(await adapter.refreshSecrets(_account(), _secrets, ctx()), isNull);
      expect(router.calls, isEmpty);
    });

    test('token older than 24 h is refreshed', () async {
      router.on('GET', '/refresh_access_token', {'access_token': 'NEW', 'token_type': 'bearer', 'expires_in': 5183944});
      final old = {..._secrets, 'token_issued_at': testNow.subtract(const Duration(days: 3)).toIso8601String()};
      final s = await adapter.refreshSecrets(_account(), old, ctx());
      final call = router.calls.single;
      expect(call.method, 'GET');
      expect(call.url.toString().split('?').first, 'https://graph.threads.net/refresh_access_token');
      expect(call.url.queryParameters, {'grant_type': 'th_refresh_token', 'access_token': 'LONG'});
      expect(s!['access_token'], 'NEW');
      expect(s['app_secret'], 'SECRET');
      expect(DateTime.parse(s['expires_at']!), testNow.add(const Duration(seconds: 5183944)));
      expect(DateTime.parse(s['token_issued_at']!), testNow);
    });

    test('expired token requires reconnect', () async {
      final expired = {..._secrets, 'expires_at': testNow.subtract(const Duration(minutes: 1)).toIso8601String()};
      await expectLater(adapter.refreshSecrets(_account(), expired, ctx()),
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
    });

    test('revoked token on refresh -> auth; server hiccup -> keep current token', () async {
      final old = {..._secrets, 'token_issued_at': testNow.subtract(const Duration(days: 3)).toIso8601String()};
      router.on('GET', '/refresh_access_token', {
        'error': {'message': 'Session has been invalidated', 'type': 'OAuthException', 'code': 190}
      }, status: 400);
      await expectLater(adapter.refreshSecrets(_account(), old, ctx()), throwsA(isA<AdapterException>()));
      router = _Router()..on('GET', '/refresh_access_token', {'error': {'message': 'x', 'code': 2}}, status: 500);
      expect(await adapter.refreshSecrets(_account(), old, ctx()), isNull);
    });

    test('hand-off accounts never refresh', () async {
      expect(await adapter.refreshSecrets(_account(tier: PlatformTier.handoff), const {}, ctx()), isNull);
    });
  });

  group('buildHandoff', () {
    test('text-only: web intent with percent-encoded text', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Hello world & more'))!;
      expect(plan.webIntent.toString(), 'https://www.threads.com/intent/post?text=Hello%20world%20%26%20more');
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.clipboardText, 'Hello world & more');
      expect(plan.androidPackage, 'com.instagram.barcelona');
      expect(plan.iosScheme, 'barcelona://');
      expect(plan.desktopUrl, 'https://www.threads.com/');
      expect(plan.instructions, startsWith('1.'));
    });

    test('link, tag and reply control become intent params', () {
      final plan = adapter.buildHandoff(const PostVariant(
          text: 'Hi', link: 'https://example.com/a?b=c', extra: {'topic_tag': 'Dart', 'reply_control': 'followers_only'}))!;
      final q = plan.webIntent!.queryParameters;
      expect(q['text'], 'Hi');
      expect(q['url'], 'https://example.com/a?b=c');
      expect(q['tag'], 'Dart');
      expect(q['reply_control'], 'followers_only');
    });

    test('media prefers the share sheet; threads put all parts on the clipboard', () {
      final media = adapter.buildHandoff(PostVariant(text: 'Pic', media: [fakeImage()]))!;
      expect(media.preferred, HandoffMethod.shareSheet);
      expect(media.shareFiles, hasLength(1));
      expect(media.mediaNote, isNotNull);
      final thread = adapter.buildHandoff(const PostVariant(text: 'a', threadParts: ['a', 'b']))!;
      expect(thread.clipboardText, 'a\n\nb');
      expect(thread.webIntent!.queryParameters['text'], 'a');
    });
  });
}
