import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/tumblr/tumblr_adapter.dart';
import 'package:neforum_core/src/adapters/tumblr/tumblr_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

const _uuid = 't:AbCdEf123';

ConnectedAccount _account({Map<String, dynamic>? config, PlatformTier tier = PlatformTier.byokApi}) => fakeAccount(
      'tumblr',
      tier: tier,
      id: 'tumblr:$_uuid',
      config: config ??
          const {
            'consumerKey': 'ckey',
            'blogName': 'myblog',
            'blogUuid': _uuid,
            'redirectUri': 'http://127.0.0.1:52771/callback',
          },
    );

Map<String, String> _secrets({DateTime? expiresAt, String? refreshToken = 'RT-1'}) => {
      'consumer_secret': 'csecret',
      'access_token': 'AT-1',
      'token_type': 'bearer',
      'expires_at': (expiresAt ?? testNow.add(const Duration(minutes: 30))).toUtc().toIso8601String(),
      if (refreshToken != null) 'refresh_token': refreshToken,
    };

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

http.Response _created([String id = '1234567891234567']) => _json({
      'meta': {'status': 201, 'msg': 'Created'},
      'response': {'id': id},
    }, 201);

http.Response _error(int status, int code, String title, [Map<String, String> headers = const {}]) => _json({
      'meta': {'status': status, 'msg': title},
      'response': <Object?>[],
      'errors': [
        {'title': title, 'code': code},
      ],
    }, status, headers);

Map<String, dynamic> _userInfo() => {
      'meta': {'status': 200, 'msg': 'OK'},
      'response': {
        'user': {
          'name': 'ada',
          'blogs': [
            {'name': 'sideblog', 'uuid': 't:side999', 'url': 'https://sideblog.tumblr.com/', 'title': 'Side', 'primary': false},
            {'name': 'myblog', 'uuid': _uuid, 'url': 'https://myblog.tumblr.com/', 'title': 'My Blog', 'primary': true},
          ],
        },
      },
    };

Map<String, dynamic> _body(http.Request r) => Map<String, dynamic>.from(jsonDecode(r.body) as Map);

List<Map<String, dynamic>> _content(Map<String, dynamic> body) =>
    (body['content'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

void main() {
  final adapter = TumblrAdapter();

  group('descriptor', () {
    test('limits match the research', () {
      final d = adapter.descriptor;
      expect(d.id, 'tumblr');
      expect(d.tiers, {PlatformTier.byokApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.byokApi);
      expect(d.text.maxLength, 524288);
      expect(d.text.titleSupported, isTrue);
      expect(d.text.titleRequired, isFalse);
      expect(d.text.supportsThreads, isFalse);
      expect(d.text.supportsContentWarning, isFalse);
      expect(d.text.hashtagsAsField, isTrue);
      expect(d.text.maxHashtags, 30);
      expect(d.text.linkInText, isFalse);
      expect(d.media.maxImages, 30);
      expect(d.media.maxVideos, 1);
      expect(d.media.allowsMixedImageVideo, isTrue);
      expect(d.media.imageMaxBytes, 20 * 1024 * 1024);
      expect(d.media.videoMaxBytes, 500000000);
      expect(d.media.videoMaxSeconds, 600);
      expect(d.media.imageMimeTypes, {'image/jpeg', 'image/png', 'image/webp', 'image/gif'});
      expect(d.media.videoMimeTypes, {'video/mp4', 'video/quicktime'});
      expect(d.media.supportsAltText, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.personalAccountOk, isTrue);
      expect(d.serverSideScheduling, isTrue);
      expect(d.supportsLinkField, isTrue);
      expect(d.setupGuide, 'docs/platforms/tumblr.md');
      final q = d.defaultQuotas.single;
      expect(q.id, 'tumblr.posts_per_day');
      expect(q.limit, 250);
      expect(q.window, const Duration(days: 1));
    });

    test('connect spec: browser flow, both redirect kinds, secret field', () {
      final spec = adapter.specFor(PlatformTier.byokApi);
      expect(spec.usesBrowser, isTrue);
      expect(spec.loopbackRedirectOk, isTrue);
      expect(spec.customSchemeRedirectOk, isTrue);
      expect(spec.fixedRedirectUri, isNull);
      expect(spec.intro, contains('https://www.tumblr.com/oauth/apps'));
      expect(spec.intro, contains('http://127.0.0.1:52771/callback'));
      expect(spec.intro, contains('neforum://callback/'));
      expect(spec.fields.firstWhere((f) => f.key == 'consumerSecret').secret, isTrue);
      expect(spec.fields.firstWhere((f) => f.key == 'consumerKey').secret, isFalse);
      expect(spec.fields.firstWhere((f) => f.key == 'blog').required, isFalse);
      expect(adapter.specFor(PlatformTier.handoff).usesBrowser, isFalse);
    });
  });

  group('connect', () {
    test('authorization code flow with client secret, then user/info picks the primary blog', () async {
      final calls = <http.Request>[];
      final broker = FakeAuthBroker(code: 'the-code');
      final ctx = testContext(
        broker: broker,
        handler: (r) async {
          calls.add(r);
          if (r.url.path == '/v2/oauth2/token') {
            return _json({
              'access_token': 'AT-new',
              'expires_in': 2520,
              'id_token': false,
              'refresh_token': 'RT-new',
              'scope': 'write offline_access',
              'token_type': 'bearer',
            });
          }
          return _json(_userInfo());
        },
      );
      final result = await adapter.connect(PlatformTier.byokApi, {'consumerKey': 'ckey', 'consumerSecret': 'csecret'}, ctx);

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.scheme, 'https');
      expect(auth.host, 'www.tumblr.com');
      expect(auth.path, '/oauth2/authorize');
      expect(auth.queryParameters['client_id'], 'ckey');
      expect(auth.queryParameters['response_type'], 'code');
      expect(auth.queryParameters['scope'], 'basic write offline_access');
      expect(auth.queryParameters['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(auth.queryParameters['state'], isNotEmpty);
      expect(auth.queryParameters.containsKey('code_challenge'), isFalse);

      expect(calls, hasLength(2));
      final token = calls[0];
      expect(token.method, 'POST');
      expect(token.url.toString(), 'https://api.tumblr.com/v2/oauth2/token');
      expect(token.headers['content-type'], contains('application/x-www-form-urlencoded'));
      expect(bodyOf(token), {
        'grant_type': 'authorization_code',
        'code': 'the-code',
        'redirect_uri': 'http://127.0.0.1:52771/callback',
        'client_id': 'ckey',
        'client_secret': 'csecret',
      });

      final info = calls[1];
      expect(info.method, 'GET');
      expect(info.url.toString(), 'https://api.tumblr.com/v2/user/info');
      expect(info.headers['Authorization'], 'Bearer AT-new');

      final a = result.account;
      expect(a.id, 'tumblr:$_uuid');
      expect(a.tier, PlatformTier.byokApi);
      expect(a.handle, 'myblog');
      expect(a.displayName, 'My Blog (myblog)');
      expect(a.profileUrl, 'https://myblog.tumblr.com/');
      expect(a.config['consumerKey'], 'ckey');
      expect(a.config['blogName'], 'myblog');
      expect(a.config['blogUuid'], _uuid);
      expect(a.config['blogNames'], ['sideblog', 'myblog']);
      expect(a.config['redirectUri'], 'http://127.0.0.1:52771/callback');
      expect(a.config.containsKey('consumerSecret'), isFalse);

      expect(result.secrets['consumer_secret'], 'csecret');
      expect(result.secrets['access_token'], 'AT-new');
      expect(result.secrets['refresh_token'], 'RT-new');
      expect(DateTime.parse(result.secrets['expires_at']!), testNow.add(const Duration(seconds: 2520)));
    });

    test('blog field selects another blog (accepts hostnames)', () async {
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (r) async => r.url.path == '/v2/oauth2/token'
            ? _json({'access_token': 'AT', 'expires_in': 2520, 'refresh_token': 'RT', 'token_type': 'bearer'})
            : _json(_userInfo()),
      );
      final result = await adapter.connect(
          PlatformTier.byokApi, {'consumerKey': 'k', 'consumerSecret': 's', 'blog': 'SideBlog.tumblr.com'}, ctx);
      expect(result.account.id, 'tumblr:t:side999');
      expect(result.account.config['blogName'], 'sideblog');
    });

    test('unknown blog is a ConnectException listing the blogs', () async {
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (r) async => r.url.path == '/v2/oauth2/token'
            ? _json({'access_token': 'AT', 'expires_in': 2520, 'token_type': 'bearer'})
            : _json(_userInfo()),
      );
      await expectLater(
        adapter.connect(PlatformTier.byokApi, {'consumerKey': 'k', 'consumerSecret': 's', 'blog': 'nope'}, ctx),
        throwsA(isA<ConnectException>()
            .having((e) => e.field, 'field', 'blog')
            .having((e) => e.message, 'message', contains('sideblog, myblog'))),
      );
    });

    test('custom-scheme redirect gets the trailing slash Tumblr requires', () async {
      final broker = FakeAuthBroker(redirect: Uri.parse('neforum://callback'));
      final calls = <http.Request>[];
      final ctx = testContext(
        broker: broker,
        handler: (r) async {
          calls.add(r);
          return r.url.path == '/v2/oauth2/token'
              ? _json({'access_token': 'AT', 'expires_in': 2520, 'token_type': 'bearer'})
              : _json(_userInfo());
        },
      );
      final result = await adapter.connect(PlatformTier.byokApi, {'consumerKey': 'k', 'consumerSecret': 's'}, ctx);
      expect(broker.lastAuthorizationUrl!.queryParameters['redirect_uri'], 'neforum://callback/');
      expect(bodyOf(calls.first)['redirect_uri'], 'neforum://callback/');
      expect(result.account.config['redirectUri'], 'neforum://callback/');
    });

    test('redirect override is used verbatim', () async {
      final broker = FakeAuthBroker();
      final ctx = testContext(
        broker: broker,
        handler: (r) async => r.url.path == '/v2/oauth2/token'
            ? _json({'access_token': 'AT', 'expires_in': 2520, 'token_type': 'bearer'})
            : _json(_userInfo()),
      );
      await adapter.connect(PlatformTier.byokApi,
          {'consumerKey': 'k', 'consumerSecret': 's', 'redirectUri': 'http://localhost:52771/callback'}, ctx);
      expect(broker.lastAuthorizationUrl!.queryParameters['redirect_uri'], 'http://localhost:52771/callback');
    });

    test('missing fields and refused tokens raise ConnectException', () async {
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (r) async => _json({'error': 'invalid_client', 'error_description': 'Invalid client secret'}, 401),
      );
      await expectLater(adapter.connect(PlatformTier.byokApi, {'consumerSecret': 's'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'consumerKey')));
      await expectLater(adapter.connect(PlatformTier.byokApi, {'consumerKey': 'k', 'consumerSecret': 's'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Consumer Key'))));
    });

    test('handoff tier needs nothing', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP expected'));
      final result = await adapter.connect(PlatformTier.handoff, {'displayName': 'Fan blog'}, ctx);
      expect(result.account.tier, PlatformTier.handoff);
      expect(result.account.displayName, 'Fan blog');
      expect(result.secrets, isEmpty);
    });
  });

  group('validate', () {
    List<String> codes(PostVariant v, [ConnectedAccount? a]) =>
        adapter.validate(v, a ?? _account()).map((i) => i.code).toList();

    test('a plain post is fine', () {
      expect(adapter.validate(const PostVariant(text: 'Hello Tumblr'), _account()).hasErrors, isFalse);
    });

    test('GIFs over 10 MB are refused, 20 MB static images are fine', () {
      final gif = fakeImage(mimeType: 'image/gif', sizeBytes: 11 * 1024 * 1024);
      final jpg = fakeImage(id: 'img2', sizeBytes: 19 * 1024 * 1024);
      final c = codes(PostVariant(text: 'x', media: [gif, jpg]));
      expect(c, contains('media.gif_too_large'));
      expect(c, isNot(contains('media.image_too_large')));
    });

    test('more than one video or 30 images is refused', () {
      expect(codes(PostVariant(text: 'x', media: [fakeVideo(), fakeVideo(id: 'v2')])), contains('media.too_many_videos'));
      final many = List.generate(31, (i) => fakeImage(id: 'i$i'));
      expect(codes(PostVariant(text: 'x', media: many)), contains('media.too_many_images'));
    });

    test('state, tags, visibility and missing blog', () {
      expect(codes(const PostVariant(text: 'x', extra: {'state': 'bogus'})), contains('tumblr.state'));
      expect(codes(const PostVariant(text: 'x', extra: {'state': 'queue'})), isNot(contains('tumblr.state')));
      expect(codes(const PostVariant(text: 'x', tags: ['a,b'])), contains('tags.comma'));
      expect(codes(const PostVariant(text: 'x', visibility: Visibility.followers)), contains('visibility.public'));
      expect(codes(PostVariant(text: 'x', extra: const {'state': 'draft'}, scheduledAt: testNow.add(const Duration(days: 1)))),
          contains('schedule.ignored'));
      expect(codes(const PostVariant(text: 'x'), _account(config: const {'consumerKey': 'k'})), contains('account.no_blog'));
      final tooManyTags = List.generate(31, (i) => 't$i');
      expect(codes(PostVariant(text: 'x', tags: tooManyTags)), contains('hashtags.too_many'));
    });
  });

  group('NPF helpers', () {
    test('long lines are split at spaces into 4096-code-point blocks', () {
      final word = '${'a' * 99} ';
      final line = word * 60; // 6000 code points
      final blocks = TumblrApi.textBlocks(line);
      expect(blocks.length, 2);
      for (final b in blocks) {
        expect((b['text'] as String).runes.length, lessThanOrEqualTo(4096));
      }
      expect(blocks.map((b) => b['text']).join(' ').replaceAll(' ', ''), line.replaceAll(' ', ''));
    });

    test('link formatting uses code-point offsets', () {
      final block = TumblrApi.textBlock('🌳 see https://example.com now', linkBudget: LinkBudget());
      final f = Map<String, dynamic>.from((block['formatting'] as List).single as Map);
      expect(f, {'start': 6, 'end': 25, 'type': 'link', 'url': 'https://example.com'});
    });

    test('tags become one comma-separated string', () {
      expect(TumblrApi.tagsField(['#art', 'fan art', 'a,b', 'Art']), 'art,fan art,a b');
      expect(TumblrApi.tagsField(const []), isNull);
    });
  });

  group('publish', () {
    test('text post: JSON NPF body with title, paragraphs, link card, tags and source', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _created();
      });
      const variant = PostVariant(
        text: 'First line 🌳\n\nSecond line with https://neforum.app link',
        title: 'Hello',
        link: 'https://example.com/article',
        tags: ['neforum', 'cross posting'],
      );
      final result = await adapter.publish(variant, _account(), _secrets(), ctx);

      expect(result.success, isTrue, reason: '${result.error}');
      expect(result.remoteId, '1234567891234567');
      expect(result.remoteUrl, 'https://myblog.tumblr.com/post/1234567891234567');
      expect(result.publishedAt, testNow);

      final r = calls.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://api.tumblr.com/v2/blog/t:AbCdEf123/posts');
      expect(r.headers['Authorization'], 'Bearer AT-1');
      expect(r.headers['content-type'], contains('application/json'));
      final body = _body(r);
      expect(body['state'], 'published');
      expect(body['tags'], 'neforum,cross posting');
      expect(body['source_url'], 'https://example.com/article');
      expect(body.containsKey('publish_on'), isFalse);
      final content = _content(body);
      expect(content, hasLength(4));
      expect(content[0], {'type': 'text', 'subtype': 'heading1', 'text': 'Hello'});
      expect(content[1], {'type': 'text', 'text': 'First line 🌳'});
      expect(content[2]['text'], 'Second line with https://neforum.app link');
      expect(content[2]['formatting'], [
        {'start': 17, 'end': 36, 'type': 'link', 'url': 'https://neforum.app'},
      ]);
      expect(content[3], {'type': 'link', 'url': 'https://example.com/article'});
    });

    test('media post: multipart with json part first and one file part per identifier', () async {
      final calls = <http.Request>[];
      final progress = <String>[];
      final base = testContext(handler: (r) async {
        calls.add(r);
        return _created('99');
      });
      final ctx = base.copyWith(onProgress: progress.add);
      final variant = PostVariant(
        text: 'Look',
        media: [fakeImage(altText: 'A cat'), fakeImage(id: 'img2', mimeType: 'image/png', altText: null), fakeVideo()],
      );
      final result = await adapter.publish(variant, _account(), _secrets(), ctx);
      expect(result.success, isTrue, reason: '${result.error}');
      expect(result.remoteId, '99');

      final r = calls.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://api.tumblr.com/v2/blog/t:AbCdEf123/posts');
      expect(r.headers['Authorization'], 'Bearer AT-1');
      expect(r.headers['content-type'], startsWith('multipart/form-data; boundary='));
      final raw = utf8.decode(r.bodyBytes, allowMalformed: true);
      expect(raw.indexOf('name="json"'), lessThan(raw.indexOf('name="media0"')));
      expect(raw, contains('name="json"\r\nContent-Type: application/json\r\n\r\n'));
      expect(raw, contains('name="media0"; filename="img1.jpg"\r\nContent-Type: image/jpeg'));
      expect(raw, contains('name="media1"; filename="img2.jpg"\r\nContent-Type: image/png'));
      expect(raw, contains('name="media2"; filename="vid1.mp4"\r\nContent-Type: video/mp4'));

      final fields = multipartFieldsOf(r);
      expect(fields.keys, ['json', 'media0', 'media1', 'media2']);
      final json = Map<String, dynamic>.from(jsonDecode(fields['json']!) as Map);
      final content = _content(json);
      expect(content[0], {
        'type': 'image',
        'media': [
          {'type': 'image/jpeg', 'identifier': 'media0', 'width': 1200, 'height': 800},
        ],
        'alt_text': 'A cat',
      });
      expect(content[1]['media'], [
        {'type': 'image/png', 'identifier': 'media1', 'width': 1200, 'height': 800},
      ]);
      expect(content[1].containsKey('alt_text'), isFalse);
      expect(content[2], {
        'type': 'video',
        'media': {'type': 'video/mp4', 'identifier': 'media2', 'width': 1080, 'height': 1920},
      });
      expect(content[3], {'type': 'text', 'text': 'Look'});
      expect(progress, contains('Preparing image 1 of 3'));
      expect(progress, contains('Uploading 3 files to Tumblr'));
    });

    test('scheduled post goes to the queue with publish_on', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _created();
      });
      final at = DateTime.utc(2026, 10, 9, 18, 30);
      final result = await adapter.publish(PostVariant(text: 'Later', scheduledAt: at), _account(), _secrets(), ctx);
      expect(result.success, isTrue);
      expect(result.remoteUrl, isNull);
      expect(result.publishedAt, at);
      final body = _body(calls.single);
      expect(body['state'], 'queue');
      expect(body['publish_on'], '2026-10-09T18:30:00.000Z');
    });

    test('extra state and private visibility', () async {
      final bodies = <Map<String, dynamic>>[];
      final ctx = testContext(handler: (r) async {
        bodies.add(_body(r));
        return _created();
      });
      final draft = await adapter.publish(const PostVariant(text: 'x', extra: {'state': 'draft'}), _account(), _secrets(), ctx);
      await adapter.publish(const PostVariant(text: 'x', visibility: Visibility.private), _account(), _secrets(), ctx);
      expect(bodies[0]['state'], 'draft');
      expect(draft.remoteUrl, isNull);
      expect(bodies[1]['state'], 'private');
      final bad = await adapter.publish(const PostVariant(text: 'x', extra: {'state': 'nope'}), _account(), _secrets(), ctx);
      expect(bad.error!.kind, PublishErrorKind.validation);
      expect(bodies, hasLength(2));
    });

    test('expired or missing tokens fail as auth without a request', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP expected'));
      final expired = await adapter.publish(
          const PostVariant(text: 'x'), _account(), _secrets(expiresAt: testNow.subtract(const Duration(minutes: 1))), ctx);
      expect(expired.error!.kind, PublishErrorKind.auth);
      final none = await adapter.publish(const PostVariant(text: 'x'), _account(), const {}, ctx);
      expect(none.error!.kind, PublishErrorKind.auth);
    });

    group('error mapping', () {
      Future<PublishError> errorFor(http.Response response) async {
        final ctx = testContext(handler: (r) async => response);
        final result = await adapter.publish(const PostVariant(text: 'x'), _account(), _secrets(), ctx);
        expect(result.success, isFalse);
        return result.error!;
      }

      test('401 -> auth', () async {
        final e = await errorFor(_json({'meta': {'status': 401, 'msg': 'Unauthorized'}}, 401));
        expect(e.kind, PublishErrorKind.auth);
        expect(e.statusCode, 401);
      });

      test('429 -> quota with retryAfter', () async {
        final e = await errorFor(_json({'meta': {'status': 429, 'msg': 'Limit Exceeded'}}, 429, {'retry-after': '120'}));
        expect(e.kind, PublishErrorKind.quota);
        expect(e.retryAfter, const Duration(seconds: 120));
      });

      test('429 without Retry-After uses the rate-limit headers', () async {
        final e = await errorFor(_json(
            {'meta': {'status': 429, 'msg': 'Limit Exceeded'}}, 429, {'x-ratelimit-perhour-remaining': '0'}));
        expect(e.retryAfter, const Duration(hours: 1));
      });

      test('403.8023 daily posting limit -> quota', () async {
        final e = await errorFor(_error(403, 8023, 'Daily posting limit reached'));
        expect(e.kind, PublishErrorKind.quota);
        expect(e.retryAfter, const Duration(hours: 24));
      });

      test('403.8010 video transcoding -> retryable platform error', () async {
        final e = await errorFor(_error(403, 8010, 'Video still transcoding'));
        expect(e.kind, PublishErrorKind.platform);
        expect(e.retryable, isTrue);
      });

      test('400.8001 invalid NPF -> validation', () async {
        final e = await errorFor(_error(400, 8001, 'Invalid NPF'));
        expect(e.kind, PublishErrorKind.validation);
        expect(e.message, contains('Invalid NPF'));
      });

      test('404 -> configuration, 500 -> network', () async {
        expect((await errorFor(_json({'meta': {'status': 404, 'msg': 'Not Found'}}, 404))).kind,
            PublishErrorKind.configuration);
        expect((await errorFor(http.Response('oops', 500))).kind, PublishErrorKind.network);
      });

      test('201 without id -> platform', () async {
        final e = await errorFor(_json({'meta': {'status': 201}, 'response': <String, Object?>{}}, 201));
        expect(e.kind, PublishErrorKind.platform);
      });
    });
  });

  group('refreshSecrets', () {
    test('returns null while the token is fresh', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP expected'));
      expect(await adapter.refreshSecrets(_account(), _secrets(), ctx), isNull);
    });

    test('refreshes an expiring token and stores the rotated refresh token', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'access_token': 'AT-2', 'expires_in': 2520, 'refresh_token': 'RT-2', 'token_type': 'bearer'});
      });
      final fresh = await adapter.refreshSecrets(
          _account(), _secrets(expiresAt: testNow.add(const Duration(seconds: 30))), ctx);
      final r = calls.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://api.tumblr.com/v2/oauth2/token');
      expect(bodyOf(r), {
        'grant_type': 'refresh_token',
        'refresh_token': 'RT-1',
        'client_id': 'ckey',
        'client_secret': 'csecret',
      });
      expect(fresh!['access_token'], 'AT-2');
      expect(fresh['refresh_token'], 'RT-2');
      expect(fresh['consumer_secret'], 'csecret');
      expect(DateTime.parse(fresh['expires_at']!), testNow.add(const Duration(seconds: 2520)));
    });

    test('a dead refresh token means reconnect', () async {
      final ctx = testContext(handler: (r) async => _json({'error': 'invalid_grant'}, 401));
      await expectLater(
        adapter.refreshSecrets(_account(), _secrets(expiresAt: testNow), ctx),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)),
      );
    });

    test('no refresh token means reconnect', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP expected'));
      await expectLater(
        adapter.refreshSecrets(_account(), _secrets(expiresAt: testNow, refreshToken: null), ctx),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)),
      );
    });

    test('a 5xx during refresh is a network error', () async {
      final ctx = testContext(handler: (r) async => http.Response('down', 503));
      await expectLater(
        adapter.refreshSecrets(_account(), _secrets(expiresAt: testNow), ctx),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.network)),
      );
    });
  });

  group('buildHandoff', () {
    test('text post opens the share tool with title, content and tags', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Body text', title: 'Hi', tags: ['a', 'b c']))!;
      final u = plan.webIntent!;
      expect(u.scheme, 'https');
      expect(u.host, 'www.tumblr.com');
      expect(u.path, '/widgets/share/tool');
      expect(u.queryParameters, {'posttype': 'text', 'content': 'Body text', 'title': 'Hi', 'tags': 'a,b c'});
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.clipboardText, 'Hi\n\nBody text');
      expect(plan.androidPackage, 'com.tumblr');
      expect(plan.desktopUrl, 'https://www.tumblr.com/new/text');
      expect(plan.instructions, startsWith('1. '));
    });

    test('link post uses posttype=link with the text as caption', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Read this', link: 'https://example.com/a'))!;
      expect(plan.webIntent!.queryParameters, {
        'posttype': 'link',
        'content': 'https://example.com/a',
        'caption': 'Read this',
        'canonicalUrl': 'https://example.com/a',
      });
      expect(plan.clipboardText, 'Read this\n\nhttps://example.com/a');
    });

    test('media prefers the share sheet', () {
      final img = fakeImage();
      final plan = adapter.buildHandoff(PostVariant(text: 'Pic', media: [img], tags: const ['cats']))!;
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.shareFiles, [img]);
      expect(plan.shareText, 'Pic');
      expect(plan.mediaNote, isNotNull);
      expect(plan.instructions, contains('#cats'));
    });
  });
}
