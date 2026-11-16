import 'dart:convert';
import 'dart:io' show OSError, PathNotFoundException;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/pinterest/pinterest_adapter.dart';
import 'package:neforum_core/src/adapters/pinterest/pinterest_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

const _basic = 'Basic YXBwMTIzOnNlY3JldDQ1Ng=='; // base64('app123:secret456')

ConnectedAccount _account({Map<String, dynamic>? config, PlatformTier tier = PlatformTier.byokApi}) => fakeAccount(
      'pinterest',
      tier: tier,
      id: 'pinterest:42',
      config: config ??
          const {
            'appId': 'app123',
            'boardId': '549755885175',
            'boardName': 'Recipes',
            'username': 'ada',
            'accessLevel': 'standard',
          },
    );

Map<String, String> _secrets({DateTime? expiresAt, DateTime? refreshExpiresAt, String? refreshToken = 'pinr.old'}) => {
      'app_secret': 'secret456',
      'access_token': 'pina.AT1',
      'token_type': 'bearer',
      'expires_at': (expiresAt ?? testNow.add(const Duration(days: 20))).toUtc().toIso8601String(),
      if (refreshToken != null) 'refresh_token': refreshToken,
      'refresh_expires_at': (refreshExpiresAt ?? testNow.add(const Duration(days: 50))).toUtc().toIso8601String(),
    };

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

Map<String, dynamic> _body(http.Request r) => Map<String, dynamic>.from(jsonDecode(r.body) as Map);

const _tokenResponse = {
  'access_token': 'pina.NEW',
  'refresh_token': 'pinr.NEW',
  'response_type': 'authorization_code',
  'token_type': 'bearer',
  'expires_in': 2592000,
  'refresh_token_expires_in': 5184000,
  'refresh_token_expires_at': 1797000000,
  'scope': 'boards:read,boards:write,pins:read,pins:write,user_accounts:read',
};

void main() {
  final adapter = PinterestAdapter(videoPollInterval: Duration.zero, videoPollAttempts: 3);

  group('descriptor', () {
    test('limits match the research / OpenAPI', () {
      final d = adapter.descriptor;
      expect(d.id, 'pinterest');
      expect(d.tiers, {PlatformTier.byokApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.byokApi);
      expect(d.text.maxLength, 800);
      expect(d.text.titleMax, 100);
      expect(d.text.titleSupported, isTrue);
      expect(d.text.titleRequired, isFalse);
      expect(d.text.supportsThreads, isFalse);
      expect(d.text.supportsContentWarning, isFalse);
      expect(d.text.linkInText, isFalse);
      expect(d.media.requiresMedia, isTrue);
      expect(d.media.maxImages, 5);
      expect(d.media.maxVideos, 1);
      expect(d.media.allowsMixedImageVideo, isFalse);
      expect(d.media.imageMaxBytes, 20 * 1024 * 1024);
      expect(d.media.imageMimeTypes, {'image/jpeg', 'image/png'});
      expect(d.media.videoMaxSeconds, 300);
      expect(d.media.supportsAltText, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.personalAccountOk, isFalse);
      expect(d.serverSideScheduling, isFalse);
      expect(d.supportsLinkField, isTrue);
      expect(d.setupGuide, 'docs/platforms/pinterest.md');
      final writes = d.defaultQuotas.firstWhere((q) => q.id == 'pinterest.trial.writes_per_day');
      expect(writes.limit, 300);
      expect(writes.window, const Duration(days: 1));
      expect(writes.appliesToTier, PlatformTier.byokApi);
      final reads = d.defaultQuotas.firstWhere((q) => q.id == 'pinterest.trial.requests_per_day');
      expect(reads.limit, 1000);
    });

    test('connect specs: loopback only, secret field, redirect URIs in the intro', () {
      final spec = adapter.specFor(PlatformTier.byokApi);
      expect(spec.usesBrowser, isTrue);
      expect(spec.loopbackRedirectOk, isTrue);
      expect(spec.customSchemeRedirectOk, isFalse);
      expect(spec.intro, contains('http://localhost:52771/callback'));
      // 1.4.4: Pinterest accepts http only with localhost; the guide no longer
      // asks for the 127.0.0.1 address.
      expect(spec.intro, isNot(contains('http://127.0.0.1:52771/callback')));
      expect(spec.redirectNote, isNot(contains('http://127.0.0.1')));
      expect(spec.fields.firstWhere((f) => f.key == 'redirectHost').defaultValue, 'localhost');
      expect(spec.intro, contains('https://developers.pinterest.com/apps/'));
      expect(spec.fields.firstWhere((f) => f.key == 'appSecret').secret, isTrue);
      expect(spec.fields.firstWhere((f) => f.key == 'appId').secret, isFalse);
      expect(adapter.specFor(PlatformTier.handoff).usesBrowser, isFalse);
    });
  });

  group('connect', () {
    test('Standard access: authorization code with Basic auth, then user_account and boards (paginated), all production', () async {
      final calls = <http.Request>[];
      final broker = FakeAuthBroker(code: 'the-code');
      final ctx = testContext(
        broker: broker,
        handler: (r) async {
          calls.add(r);
          switch (r.url.path) {
            case '/v5/oauth/token':
              return _json(_tokenResponse);
            case '/v5/user_account':
              return _json({'id': '42', 'username': 'ada', 'account_type': 'BUSINESS', 'profile_image': 'https://i.pinimg.com/a.jpg'});
            case '/v5/boards':
              if (r.url.queryParameters['bookmark'] == null) {
                return _json({
                  'items': [
                    {'id': '111', 'name': 'Travel', 'privacy': 'PUBLIC'},
                  ],
                  'bookmark': 'page2',
                });
              }
              return _json({
                'items': [
                  {'id': '549755885175', 'name': 'Summer Recipes', 'privacy': 'PUBLIC'},
                ],
                'bookmark': null,
              });
          }
          return http.Response('unexpected', 500);
        },
      );
      final result = await adapter.connect(
          PlatformTier.byokApi, {'appId': 'app123', 'appSecret': 'secret456', 'board': 'summer-recipes', 'accessLevel': 'standard'}, ctx);

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.scheme, 'https');
      expect(auth.host, 'www.pinterest.com');
      expect(auth.path, '/oauth/');
      expect(auth.queryParameters['client_id'], 'app123');
      expect(auth.queryParameters['response_type'], 'code');
      expect(auth.queryParameters['scope'], 'boards:read,boards:write,pins:read,pins:write,user_accounts:read');
      expect(auth.queryParameters['redirect_uri'], 'http://localhost:52771/callback');
      expect(auth.queryParameters['state'], isNotEmpty);
      expect(auth.queryParameters.containsKey('code_challenge'), isFalse);

      expect(calls, hasLength(4));
      final token = calls[0];
      expect(token.method, 'POST');
      expect(token.url.toString(), 'https://api.pinterest.com/v5/oauth/token');
      expect(token.headers['Authorization'], _basic);
      expect(token.headers['content-type'], startsWith('application/x-www-form-urlencoded'));
      expect(bodyOf(token), {
        'grant_type': 'authorization_code',
        'code': 'the-code',
        'redirect_uri': 'http://localhost:52771/callback',
        // Pinterest's 60-day refresh token, renewable.
        'continuous_refresh': 'true',
      });

      expect(calls[1].method, 'GET');
      expect(calls[1].url.toString(), 'https://api.pinterest.com/v5/user_account');
      expect(calls[1].headers['Authorization'], 'Bearer pina.NEW');
      expect(calls[2].url.toString(), 'https://api.pinterest.com/v5/boards?page_size=250');
      expect(calls[3].url.queryParameters, {'page_size': '250', 'bookmark': 'page2'});

      final a = result.account;
      expect(a.id, 'pinterest:42');
      expect(a.handle, 'ada');
      expect(a.profileUrl, 'https://www.pinterest.com/ada/');
      expect(a.displayName, 'ada (Summer Recipes)');
      expect(a.config['boardId'], '549755885175');
      expect(a.config['boardName'], 'Summer Recipes');
      expect(a.config['appId'], 'app123');
      expect(a.config['accessLevel'], 'standard');
      expect(a.config['environment'], 'production');
      expect(a.config['redirectUri'], 'http://localhost:52771/callback');

      final s = result.secrets;
      expect(s['access_token'], 'pina.NEW');
      expect(s['refresh_token'], 'pinr.NEW');
      expect(s['app_secret'], 'secret456');
      expect(s['expires_at'], testNow.add(const Duration(seconds: 2592000)).toIso8601String());
      expect(s['refresh_expires_at'],
          DateTime.fromMillisecondsSinceEpoch(1797000000 * 1000, isUtc: true).toIso8601String());
    });

    test('uses 127.0.0.1 when the user registered that redirect', () async {
      final broker = FakeAuthBroker();
      String? redirect;
      final ctx = testContext(
        broker: broker,
        handler: (r) async {
          if (r.url.path == '/v5/oauth/token') {
            redirect = bodyOf(r)['redirect_uri'] as String?;
            return _json(_tokenResponse);
          }
          if (r.url.path == '/v5/user_account') return _json({'username': 'ada'});
          return _json({
            'items': [
              {'id': '7', 'name': 'Only board'},
            ],
          });
        },
      );
      final result = await adapter.connect(PlatformTier.byokApi,
          {'appId': 'app123', 'appSecret': 'secret456', 'redirectHost': '127.0.0.1', 'accessLevel': 'standard'}, ctx);
      expect(broker.lastAuthorizationUrl!.queryParameters['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(redirect, 'http://127.0.0.1:52771/callback');
      expect(result.account.config['boardId'], '7', reason: 'single board picked automatically');
      expect(result.account.config['accessLevel'], 'standard');
    });

    test('explains a pending Trial app (401 code 3)', () async {
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (r) async {
          if (r.url.path == '/v5/oauth/token') return _json(_tokenResponse);
          return _json({'code': 3, 'message': 'Your application consumer type is not supported, please contact support.'},
              401);
        },
      );
      expect(
        () => adapter.connect(PlatformTier.byokApi, {'appId': 'app123', 'appSecret': 'secret456'}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('not approved yet'))),
      );
    });

    test('token endpoint refusal becomes a readable ConnectException', () async {
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (r) async => _json({'error': 'invalid_client', 'error_description': 'Unauthorized client'}, 401),
      );
      expect(
        () => adapter.connect(PlatformTier.byokApi, {'appId': 'app123', 'appSecret': 'bad'}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('App ID / App secret key'))),
      );
    });

    test('missing fields are rejected before any request', () async {
      final ctx = testContext(broker: FakeAuthBroker(), handler: (r) async => fail('no request expected'));
      expect(() => adapter.connect(PlatformTier.byokApi, {'appSecret': 'x'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'appId')));
      expect(() => adapter.connect(PlatformTier.byokApi, {'appId': 'x'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'appSecret')));
    });

    test('board resolution by id, name, slug and board URL', () {
      const boards = [
        PinterestBoard(id: '111', name: 'Travel'),
        PinterestBoard(id: '222', name: 'Summer Recipes'),
      ];
      expect(PinterestAdapter.resolveBoard(boards, '111').id, '111');
      expect(PinterestAdapter.resolveBoard(boards, 'summer recipes').id, '222');
      expect(PinterestAdapter.resolveBoard(boards, 'summer-recipes').id, '222');
      expect(PinterestAdapter.resolveBoard(boards, 'https://www.pinterest.com/ada/summer-recipes/').id, '222');
      // Pinterest board URLs drop apostrophes: "Mom's Recipes" -> /moms-recipes/.
      expect(
          PinterestAdapter.resolveBoard(
              const [...boards, PinterestBoard(id: '333', name: 'Mom’s Recipes')], 'https://www.pinterest.com/ada/moms-recipes/').id,
          '333');
      expect(() => PinterestAdapter.resolveBoard(boards, ''),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('"Travel"'))));
      expect(() => PinterestAdapter.resolveBoard(boards, 'Cats'), throwsA(isA<ConnectException>()));
      expect(() => PinterestAdapter.resolveBoard(const [], ''), throwsA(isA<ConnectException>()));
    });

    test('hand-off tier needs no credentials', () async {
      final ctx = testContext(handler: (r) async => fail('no request expected'));
      final r = await adapter.connect(PlatformTier.handoff, {}, ctx);
      expect(r.account.tier, PlatformTier.handoff);
      expect(r.account.displayName, 'Pinterest (hand-off)');
      expect(r.secrets, isEmpty);
    });
  });

  group('validate', () {
    List<String> codes(PostVariant v, [ConnectedAccount? a]) =>
        adapter.validate(v, a ?? _account()).map((i) => i.code).toList();

    test('a Pin needs media', () {
      expect(codes(const PostVariant(text: 'Just text')), contains('media.required'));
      expect(codes(PostVariant(text: 'ok', media: [fakeImage()])), isNot(contains('media.required')));
    });

    test('JPEG/PNG only, at most 5 images, no mixing', () {
      expect(codes(PostVariant(text: 'x', media: [fakeImage(mimeType: 'image/gif')])), contains('media.image_type'));
      expect(codes(PostVariant(text: 'x', media: [for (var i = 0; i < 6; i++) fakeImage(id: 'i$i')])),
          contains('media.too_many_images'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(), fakeVideo()])), contains('media.mixed'));
    });

    test('title, description, alt text, link and video length limits', () {
      expect(codes(PostVariant(text: 'x', title: 'T' * 101, media: [fakeImage()])), contains('title.too_long'));
      expect(codes(PostVariant(text: 'd' * 801, media: [fakeImage()])), contains('text.too_long'));
      expect(codes(PostVariant(text: 'd' * 800, media: [fakeImage()])), isNot(contains('text.too_long')));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(altText: 'a' * 501)])), contains('media.alt_too_long'));
      expect(codes(PostVariant(text: 'x', link: 'ftp://example.com/x', media: [fakeImage()])), contains('link.invalid'));
      expect(codes(PostVariant(text: 'x', media: [fakeVideo(durationMs: 3000)])), contains('media.video_too_short'));
      expect(codes(PostVariant(text: 'x', media: [fakeVideo(durationMs: 301000)])), contains('media.video_too_long'));
    });

    test('board and Trial access checks', () {
      expect(codes(PostVariant(text: 'x', media: [fakeImage()]), _account(config: const {'appId': 'a'})),
          containsAll(['pinterest.no_board', 'pinterest.trial_private']));
      expect(codes(PostVariant(text: 'x', media: [fakeImage()])), isNot(contains('pinterest.trial_private')));
      expect(
          codes(PostVariant(text: 'x', media: [fakeImage()], extra: const {'pinterestBoardId': '9'}),
              _account(config: const {'appId': 'a', 'accessLevel': 'standard'})),
          isNot(contains('pinterest.no_board')));
    });

    test('board / section overrides must be numeric ids', () {
      expect(codes(PostVariant(text: 'x', media: [fakeImage()], extra: const {'pinterestBoardId': 'My recipes'})),
          contains('pinterest.bad_id'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage()], extra: const {'pinterestBoardSectionId': '12'})),
          isNot(contains('pinterest.bad_id')));
    });

    test('hand-off warns about the 500-character web description', () {
      expect(codes(PostVariant(text: 'd' * 600, media: [fakeImage()]), _account(tier: PlatformTier.handoff)),
          contains('pinterest.handoff_description'));
    });
  });

  group('publish', () {
    test('single image: inline base64 Pin with title, link and alt text', () async {
      final calls = <http.Request>[];
      final progress = <String>[];
      final base = testContext(handler: (r) async {
        calls.add(r);
        return _json({'id': '813744120000000001', 'board_id': '549755885175'}, 201);
      });
      final ctx = base.copyWith(onProgress: progress.add);
      final result = await adapter.publish(
        PostVariant(
          text: 'Lemon tart #baking',
          title: 'Easy lemon tart',
          link: 'https://example.com/tart',
          media: [fakeImage(altText: 'A lemon tart')],
        ),
        _account(),
        _secrets(),
        ctx,
      );

      expect(result.success, isTrue, reason: '${result.error}');
      expect(result.remoteId, '813744120000000001');
      expect(result.remoteUrl, 'https://www.pinterest.com/pin/813744120000000001/');
      expect(calls, hasLength(1));
      final r = calls.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://api.pinterest.com/v5/pins');
      expect(r.headers['Authorization'], 'Bearer pina.AT1');
      expect(_body(r), {
        'board_id': '549755885175',
        'title': 'Easy lemon tart',
        'description': 'Lemon tart #baking',
        'link': 'https://example.com/tart',
        'alt_text': 'A lemon tart',
        'media_source': {
          'source_type': 'image_base64',
          'content_type': 'image/jpeg',
          'data': base64Encode(fakeJpegBytes),
        },
      });
      expect(progress, containsAll(['Preparing image 1 of 1', 'Creating the Pin']));
    });

    test('carousel: multiple_image_base64 with PNG and JPEG, board override from extra', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'id': '900'}, 201);
      });
      final result = await adapter.publish(
        PostVariant(
          text: 'Two looks',
          media: [fakeImage(id: 'a'), fakeImage(id: 'b', mimeType: 'image/png')],
          extra: const {'pinterestBoardId': '333', 'pinterestBoardSectionId': '444'},
        ),
        _account(),
        _secrets(),
        ctx,
      );
      expect(result.success, isTrue, reason: '${result.error}');
      final body = _body(calls.single);
      expect(body['board_id'], '333');
      expect(body['board_section_id'], '444');
      expect(body.containsKey('alt_text'), isFalse);
      expect(body['media_source'], {
        'source_type': 'multiple_image_base64',
        'items': [
          {'content_type': 'image/jpeg', 'data': base64Encode(fakeJpegBytes)},
          {'content_type': 'image/png', 'data': base64Encode(fakeJpegBytes)},
        ],
      });
    });

    test('video: register, S3 upload, poll, then video_id Pin', () async {
      final calls = <http.Request>[];
      var polls = 0;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.host == 'pinterest-media-upload.s3-accelerate.amazonaws.com') return http.Response('', 204);
        switch ('${r.method} ${r.url.path}') {
          case 'POST /v5/media':
            return _json({
              'media_id': '12345',
              'media_type': 'video',
              'upload_url': 'https://pinterest-media-upload.s3-accelerate.amazonaws.com/',
              'upload_parameters': {
                'x-amz-date': '20261007T120000Z',
                'x-amz-signature': 'sig',
                'x-amz-security-token': 'tok',
                'x-amz-algorithm': 'AWS4-HMAC-SHA256',
                'key': 'uploads/aa/12345',
                'policy': 'cG9saWN5',
                'x-amz-credential': 'cred',
                'Content-Type': 'multipart/form-data',
              },
            }, 201);
          case 'GET /v5/media/12345':
            polls++;
            return _json({'media_id': '12345', 'media_type': 'video', 'status': polls == 1 ? 'processing' : 'succeeded'});
          case 'POST /v5/pins':
            return _json({'id': '777'}, 201);
        }
        return http.Response('unexpected ${r.url}', 500);
      });
      final result = await adapter.publish(
        PostVariant(text: 'Watch this', title: 'Clip', media: [fakeVideo()]),
        _account(),
        _secrets(),
        ctx,
      );
      expect(result.success, isTrue, reason: '${result.error}');
      expect(result.remoteId, '777');

      expect(calls.map((c) => '${c.method} ${c.url}').toList(), [
        'POST https://api.pinterest.com/v5/media',
        'POST https://pinterest-media-upload.s3-accelerate.amazonaws.com/',
        'GET https://api.pinterest.com/v5/media/12345',
        'GET https://api.pinterest.com/v5/media/12345',
        'POST https://api.pinterest.com/v5/pins',
      ]);
      expect(_body(calls[0]), {'media_type': 'video'});
      final upload = calls[1];
      expect(upload.headers['Authorization'], isNull);
      final fields = multipartFieldsOf(upload);
      expect(fields['key'], 'uploads/aa/12345');
      expect(fields['policy'], 'cG9saWN5');
      expect(fields['x-amz-signature'], 'sig');
      expect(fields['Content-Type'], 'multipart/form-data');
      expect(fields['file'], '<vid1.mp4>');
      expect(_body(calls[4]), {
        'board_id': '549755885175',
        'title': 'Clip',
        'description': 'Watch this',
        'media_source': {'source_type': 'video_id', 'media_id': '12345', 'cover_image_key_frame_time': 1},
      });
    });

    test('video with a cover image URL and failed processing', () async {
      final ctx = testContext(handler: (r) async {
        if (r.url.path == '/v5/media') {
          return _json({
            'media_id': '5',
            'media_type': 'video',
            'upload_url': 'https://pinterest-media-upload.s3-accelerate.amazonaws.com/',
            'upload_parameters': {'key': 'k'},
          });
        }
        if (r.url.host.contains('s3')) return http.Response('', 204);
        return _json({'media_id': '5', 'status': 'failed'});
      });
      final result = await adapter.publish(
          PostVariant(text: 'x', media: [fakeVideo()], extra: const {'pinterestCoverImageUrl': 'https://x.test/c.jpg'}),
          _account(),
          _secrets(),
          ctx);
      expect(result.success, isFalse);
      expect(result.error!.kind, PublishErrorKind.validation);
    });

    test('GIF is refused before any request', () async {
      final ctx = testContext(handler: (r) async => fail('no request expected'));
      final result = await adapter.publish(
          PostVariant(text: 'x', media: [fakeImage(mimeType: 'image/gif')]), _account(), _secrets(), ctx);
      expect(result.error!.kind, PublishErrorKind.validation);
    });

    test('expired token and missing board fail without a request', () async {
      final ctx = testContext(handler: (r) async => fail('no request expected'));
      final expired = await adapter.publish(PostVariant(text: 'x', media: [fakeImage()]), _account(),
          _secrets(expiresAt: testNow.subtract(const Duration(minutes: 1))), ctx);
      expect(expired.error!.kind, PublishErrorKind.auth);
      final noBoard = await adapter.publish(
          PostVariant(text: 'x', media: [fakeImage()]), _account(config: const {'appId': 'a'}), _secrets(), ctx);
      expect(noBoard.error!.kind, PublishErrorKind.configuration);
      final noMedia = await adapter.publish(const PostVariant(text: 'x'), _account(), _secrets(), ctx);
      expect(noMedia.error!.kind, PublishErrorKind.validation);
    });

    group('error mapping', () {
      Future<PublishError> errorFor(http.Response response) async {
        final ctx = testContext(handler: (r) async => response);
        final result = await adapter.publish(PostVariant(text: 'x', media: [fakeImage()]), _account(), _secrets(), ctx);
        expect(result.success, isFalse);
        return result.error!;
      }

      test('401 code 2 -> auth', () async {
        final e = await errorFor(_json({'code': 2, 'message': 'Authentication failed.'}, 401));
        expect(e.kind, PublishErrorKind.auth);
        expect(e.statusCode, 401);
      });

      test('401 code 3 -> configuration (app awaiting approval)', () async {
        final e = await errorFor(
            _json({'code': 3, 'message': 'Your application consumer type is not supported, please contact support.'}, 401));
        expect(e.kind, PublishErrorKind.configuration);
        expect(e.message, contains('not approved yet'));
      });

      test('403 missing scope -> auth', () async {
        final e = await errorFor(_json({'code': 403, 'message': 'Missing: [boards:write]'}, 403));
        expect(e.kind, PublishErrorKind.auth);
      });

      test('429 -> quota with Retry-After', () async {
        final e = await errorFor(_json({'code': 8, 'message': 'Rate limit exceeded'}, 429, {'retry-after': '30'}));
        expect(e.kind, PublishErrorKind.quota);
        expect(e.retryAfter, const Duration(seconds: 30));
      });

      test('429 -> quota with x-ratelimit-reset when Retry-After is absent', () async {
        final e = await errorFor(_json({'code': 8, 'message': 'Rate limit exceeded'}, 429, {'x-ratelimit-reset': '3600'}));
        expect(e.kind, PublishErrorKind.quota);
        expect(e.retryAfter, const Duration(hours: 1));
      });

      test('400 -> validation with Pinterest message', () async {
        final e = await errorFor(_json({'code': 1, 'message': 'Invalid parameters: link'}, 400));
        expect(e.kind, PublishErrorKind.validation);
        expect(e.message, contains('Invalid parameters: link'));
      });

      test('404 -> configuration (board gone)', () async {
        final e = await errorFor(_json({'code': 40, 'message': 'Board not found.'}, 404));
        expect(e.kind, PublishErrorKind.configuration);
      });

      test('500 -> network', () async {
        final e = await errorFor(http.Response('oops', 500));
        expect(e.kind, PublishErrorKind.network);
        expect(e.retryable, isTrue);
      });

      test('connection failure -> network', () async {
        final ctx = testContext(handler: (r) async => throw http.ClientException('connection reset'));
        final result = await adapter.publish(PostVariant(text: 'x', media: [fakeImage()]), _account(), _secrets(), ctx);
        expect(result.error!.kind, PublishErrorKind.network);
      });

      test('a missing image file -> configuration, not a retryable network error', () async {
        final ctx = AdapterContext(
          http: NeforumHttp(client: MockClient((r) async => fail('no request expected')), maxRetries: 0),
          clock: () => testNow,
          readMedia: (m) async => throw PathNotFoundException(m.path, const OSError('No such file', 2)),
        );
        final result = await adapter.publish(PostVariant(text: 'x', media: [fakeImage()]), _account(), _secrets(), ctx);
        expect(result.error!.kind, PublishErrorKind.configuration);
        expect(result.error!.retryable, isFalse);
      });
    });
  });

  group('refreshSecrets', () {
    test('returns null while the token is fresh', () async {
      final ctx = testContext(handler: (r) async => fail('no request expected'));
      expect(await adapter.refreshSecrets(_account(), _secrets(), ctx), isNull);
    });

    test('refreshes with Basic auth within the leeway and stores the new tokens', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({
          'access_token': 'pina.R2',
          'refresh_token': 'pinr.R2',
          'token_type': 'bearer',
          'expires_in': 2592000,
          'refresh_token_expires_in': 5184000,
          'scope': 'boards:read',
        });
      });
      final fresh = await adapter.refreshSecrets(
          _account(), _secrets(expiresAt: testNow.add(const Duration(days: 1))), ctx);
      expect(calls, hasLength(1));
      expect(calls.single.url.toString(), 'https://api.pinterest.com/v5/oauth/token');
      expect(calls.single.headers['Authorization'], _basic);
      expect(bodyOf(calls.single), {'grant_type': 'refresh_token', 'refresh_token': 'pinr.old'});
      expect(fresh!['access_token'], 'pina.R2');
      expect(fresh['refresh_token'], 'pinr.R2');
      expect(fresh['app_secret'], 'secret456');
      expect(fresh['refresh_expires_at'], testNow.add(const Duration(seconds: 5184000)).toIso8601String());
    });

    test('refused refresh -> auth (reconnect)', () async {
      final ctx = testContext(handler: (r) async => _json({'error': 'invalid_grant'}, 400));
      expect(
        () => adapter.refreshSecrets(_account(), _secrets(expiresAt: testNow), ctx),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)),
      );
    });

    test('429 or an outage while renewing are retried later, not "reconnect"', () async {
      await expectLater(
        adapter.refreshSecrets(_account(), _secrets(expiresAt: testNow),
            testContext(handler: (r) async => _json({'code': 8, 'message': 'Rate limit exceeded'}, 429))),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.quota)),
      );
      await expectLater(
        adapter.refreshSecrets(_account(), _secrets(expiresAt: testNow),
            testContext(handler: (r) async => _json({'code': 1, 'message': 'Service unavailable'}, 503))),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.network)),
      );
    });

    test('expired refresh token -> auth without a request', () async {
      final ctx = testContext(handler: (r) async => fail('no request expected'));
      expect(
        () => adapter.refreshSecrets(_account(),
            _secrets(expiresAt: testNow, refreshExpiresAt: testNow.subtract(const Duration(days: 1))), ctx),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)),
      );
    });
  });

  group('API Sandbox (Trial access, 1.4.4)', () {
    // Pinterest's answer to a Trial app creating a Pin in production.
    final code29 = _json({
      'code': 29,
      'message': 'Apps with Trial access may not create Pins in production https://api.pinterest.com - use API Sandbox '
          'https://api-sandbox.pinterest.com instead.',
    }, 403);

    ConnectedAccount sandboxAccount({bool pasted = false}) => _account(config: {
          'appId': 'app123',
          'boardId': '7001',
          'boardName': 'NEFORUM',
          'username': 'ada',
          'accessLevel': 'trial',
          'environment': 'sandbox',
          if (pasted) 'authMethod': 'token',
        });

    /// A fake sandbox: answers only on api-sandbox.pinterest.com, and records
    /// every call. Board pages come back empty with a bookmark first, as the
    /// sandbox page warns they can.
    Future<http.Response> Function(http.Request) sandboxServer(List<http.Request> calls, {List<Map<String, Object?>> boards = const []}) =>
        (r) async {
          calls.add(r);
          if (r.url.host != 'api-sandbox.pinterest.com') return http.Response('production host called: ${r.url}', 500);
          switch ('${r.method} ${r.url.path}') {
            case 'POST /v5/oauth/token':
              return _json(_tokenResponse);
            case 'GET /v5/user_account':
              return _json({'id': '42', 'username': 'ada', 'account_type': 'BUSINESS'});
            case 'GET /v5/boards':
              if (r.url.queryParameters['bookmark'] == null) return _json({'items': <Object>[], 'bookmark': 'b2'});
              return _json({'items': boards, 'bookmark': null});
            case 'POST /v5/boards':
              return _json({'id': '7001', 'name': _body(r)['name'], 'privacy': 'PUBLIC'}, 201);
            case 'POST /v5/pins':
              return _json({'id': '5550001'}, 201);
          }
          return http.Response('unexpected ${r.method} ${r.url}', 500);
        };

    test('code 29 on a Trial account: a clear message that offers Reconnect to the sandbox, not the raw error', () async {
      final ctx = testContext(handler: (r) async => code29);
      final result = await adapter.publish(PostVariant(text: 'x', media: [fakeImage()]),
          _account(config: const {'appId': 'app123', 'boardId': '1', 'accessLevel': 'trial'}), _secrets(), ctx);
      final e = result.error!;
      expect(e.kind, PublishErrorKind.auth, reason: 'auth offers "Reconnect and retry"');
      expect(refusesSignIn(e), isTrue);
      expect(e.message, contains('API Sandbox'));
      expect(e.message, contains('Reconnect Pinterest'));
      expect(e.message, contains('test Pins'));
      expect(e.message, contains('Standard access'));
      expect(e.message, isNot(startsWith('Apps with Trial access')));
      expect(e.raw, contains('"code":29'), reason: 'the raw answer stays in the details');
    });

    test('code 29 on an account added as Standard: says the access level is wrong (Reconnect would not help)', () async {
      final ctx = testContext(handler: (r) async => code29);
      final result = await adapter.publish(PostVariant(text: 'x', media: [fakeImage()]), _account(), _secrets(), ctx);
      expect(result.error!.kind, PublishErrorKind.configuration);
      expect(result.error!.message, contains('added as Standard access'));
      expect(result.error!.message, contains('"trial"'));
    });

    test('code 29 is recognised by its message as well as its code', () {
      HttpFailure f(Map<String, Object?> body) =>
          HttpFailure(NeforumResponse(403, const {}, utf8.encode(jsonEncode(body)), Uri.parse('https://api.pinterest.com/v5/pins')));
      expect(PinterestApi.isTrialProductionRefusal(f({'code': 29, 'message': ''})), isTrue);
      expect(PinterestApi.isTrialProductionRefusal(f({'message': 'use API Sandbox https://api-sandbox.pinterest.com instead.'})), isTrue);
      expect(PinterestApi.isTrialProductionRefusal(f({'code': 3, 'message': 'Your application consumer type is not supported'})), isFalse);
    });

    test('Trial browser sign-in: the code goes to the sandbox token endpoint and every call to the sandbox; a board is made there', () async {
      final calls = <http.Request>[];
      final broker = FakeAuthBroker(code: 'c');
      final result = await adapter.connect(PlatformTier.byokApi, {'appId': 'app123', 'appSecret': 'secret456', 'board': 'Summer Recipes'},
          testContext(broker: broker, handler: sandboxServer(calls)));

      expect(broker.lastAuthorizationUrl!.host, 'www.pinterest.com', reason: 'one consent page for both hosts');
      expect(broker.lastAuthorizationUrl!.queryParameters['redirect_uri'], 'http://localhost:52771/callback');
      expect(calls.map((c) => '${c.method} ${c.url}').toList(), [
        'POST https://api-sandbox.pinterest.com/v5/oauth/token',
        'GET https://api-sandbox.pinterest.com/v5/user_account',
        'GET https://api-sandbox.pinterest.com/v5/boards?page_size=250',
        'GET https://api-sandbox.pinterest.com/v5/boards?page_size=250&bookmark=b2',
        'POST https://api-sandbox.pinterest.com/v5/boards',
      ]);
      expect(calls.first.headers['Authorization'], _basic);
      expect(_body(calls.last)['name'], 'Summer Recipes');
      final a = result.account;
      expect(a.config['environment'], 'sandbox');
      expect(a.config['accessLevel'], 'trial');
      expect(a.config['boardId'], '7001');
      expect(a.config.containsKey('authMethod'), isFalse, reason: 'a browser sign-in reconnects through the browser');
      expect(result.secrets['refresh_token'], 'pinr.NEW');
    });

    test('a sandbox board that exists is used, not made again; an id or address names no sandbox board', () async {
      final calls = <http.Request>[];
      final result = await adapter.connect(PlatformTier.byokApi, {'appId': 'app123', 'appSecret': 'secret456', 'board': 'summer recipes'},
          testContext(broker: FakeAuthBroker(), handler: sandboxServer(calls, boards: [{'id': '8002', 'name': 'Summer Recipes'}])));
      expect(result.account.config['boardId'], '8002');
      expect(calls.where((c) => c.method == 'POST' && c.url.path == '/v5/boards'), isEmpty);
      expect(PinterestAdapter.sandboxBoardNameFor(''), 'NEFORUM');
      expect(PinterestAdapter.sandboxBoardNameFor('549755885175'), 'NEFORUM');
      expect(PinterestAdapter.sandboxBoardNameFor('https://www.pinterest.com/ada/recipes/'), 'NEFORUM');
      expect(PinterestAdapter.sandboxBoardNameFor('Recipes'), 'Recipes');
    });

    test('after switching, every call goes to the sandbox: boards, Pins and the token renewal', () async {
      final calls = <http.Request>[];
      final server = sandboxServer(calls);
      // 1. A Trial account from 1.4.3 (production) is refused with code 29.
      final old = _account(config: const {
        'appId': 'app123',
        'boardId': '549755885175',
        'boardName': 'Recipes',
        'username': 'ada',
        'accessLevel': 'trial',
        'redirectUri': 'http://localhost:52771/callback',
      });
      final refused = await adapter.publish(PostVariant(text: 'x', media: [fakeImage()]), old, _secrets(), testContext(handler: (r) async => code29));
      expect(refused.error!.kind, PublishErrorKind.auth);

      // 2. Reconnect: renewing the production token would keep it there.
      await expectLater(adapter.renewSignInNow(old, _secrets(), testContext(handler: (r) async => fail('no renewal request'))),
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
      final input = adapter.reconnectInput(old, _secrets())!;
      expect(input['accessLevel'], 'trial');
      expect(input['board'], 'Recipes', reason: 'a production board id means nothing in the sandbox');
      expect(input['redirectHost'], 'localhost');
      final reconnected = await adapter.connect(PlatformTier.byokApi, input, testContext(broker: FakeAuthBroker(), handler: server));
      final account = reconnected.account;
      expect(PinterestAdapter.isSandbox(account), isTrue);
      expect(PinterestAdapter.movesToSandbox(account), isFalse);

      // 3. Publish and renew with the new account.
      final posted = await adapter.publish(PostVariant(text: 'Lemon tart', media: [fakeImage()]), account, reconnected.secrets, testContext(handler: server));
      expect(posted.success, isTrue, reason: '${posted.error}');
      expect(posted.remoteId, '5550001');
      final renewed = await adapter.refreshSecrets(account, {...reconnected.secrets, 'expires_at': testNow.toIso8601String()}, testContext(handler: server));
      expect(renewed!['access_token'], 'pina.NEW');

      expect(calls, isNotEmpty);
      for (final c in calls) {
        expect(c.url.host, 'api-sandbox.pinterest.com', reason: '${c.method} ${c.url}');
      }
      expect(calls.map((c) => '${c.method} ${c.url.path}'),
          containsAll(['GET /v5/boards', 'POST /v5/boards', 'POST /v5/pins', 'POST /v5/oauth/token']));
      expect(_body(calls.lastWhere((c) => c.url.path == '/v5/pins'))['board_id'], '7001');
    });

    test('Standard accounts and accounts saved before 1.4.4 as Standard stay on production', () async {
      expect(PinterestAdapter.isSandbox(_account()), isFalse);
      expect(PinterestAdapter.movesToSandbox(_account()), isFalse);
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'access_token': 'pina.R', 'refresh_token': 'pinr.R', 'expires_in': 2592000});
      });
      await adapter.renewSignInNow(_account(), _secrets(), ctx);
      expect(calls.single.url.toString(), 'https://api.pinterest.com/v5/oauth/token');
    });

    test('the sandbox cannot make video Pins: refused before any request, and flagged in the composer', () async {
      final result = await adapter.publish(PostVariant(text: 'x', media: [fakeVideo()]), sandboxAccount(), _secrets(),
          testContext(handler: (r) async => fail('no request expected')));
      expect(result.error!.kind, PublishErrorKind.validation);
      expect(result.error!.message, contains('video Pins'));
      final issues = adapter.validate(PostVariant(text: 'x', media: [fakeVideo()]), sandboxAccount());
      expect(issues.map((i) => i.code), containsAll(['pinterest.sandbox_video', 'pinterest.trial_private']));
    });

    test('the composer says plainly: test Pins only you can see; public Pins need Standard access', () {
      final warning = adapter.validate(PostVariant(text: 'x', media: [fakeImage()]), sandboxAccount()).singleWhere((i) => i.code == 'pinterest.trial_private');
      expect(warning.message, contains('API Sandbox'));
      expect(warning.message, contains('test Pins'));
      expect(warning.message, contains('only you can see'));
      expect(warning.message, contains('Standard access'));
      expect(warning.message, contains('Upgrade'));
      expect(adapter.validate(PostVariant(text: 'x', media: [fakeImage()]), _account()).map((i) => i.code), isNot(contains('pinterest.trial_private')));
    });

    group('a pasted sandbox token', () {
      test('connects without a browser or app secret, all calls to the sandbox, and records its 30-day end', () async {
        final calls = <http.Request>[];
        final result = await adapter.connect(
            PlatformTier.byokApi, {'appId': 'app123', 'sandboxToken': ' pina.SANDBOX ', 'board': ''}, testContext(handler: sandboxServer(calls)));
        expect(calls.map((c) => '${c.method} ${c.url.host}${c.url.path}').toSet(), {
          'GET api-sandbox.pinterest.com/v5/user_account',
          'GET api-sandbox.pinterest.com/v5/boards',
          'POST api-sandbox.pinterest.com/v5/boards',
        });
        expect(calls.first.headers['Authorization'], 'Bearer pina.SANDBOX');
        expect(_body(calls.last)['name'], 'NEFORUM');
        final a = result.account;
        expect(a.config['environment'], 'sandbox');
        expect(a.config['authMethod'], 'token');
        expect(result.secrets['access_token'], 'pina.SANDBOX');
        expect(result.secrets['expires_at'], testNow.add(const Duration(days: 30)).toIso8601String());
        expect(result.secrets['expires_at_source'], 'computed');
        expect(result.secrets.containsKey('refresh_token'), isFalse);
        expect(result.secrets.containsKey('app_secret'), isFalse);
        // A new token is something only the person can bring.
        expect(adapter.reconnectInput(a, result.secrets), isNull);
      });

      test('a refused token says how to make a sandbox one', () async {
        final ctx = testContext(handler: (r) async => _json({'code': 2, 'message': 'Authentication failed.'}, 401));
        await expectLater(
          adapter.connect(PlatformTier.byokApi, {'appId': 'app123', 'sandboxToken': 'pina.PROD'}, ctx),
          throwsA(isA<ConnectException>()
              .having((e) => e.field, 'field', 'sandboxToken')
              .having((e) => e.message, 'message', allOf(contains('Generate access token'), contains('Sandbox')))),
        );
      });

      test('the sign-in ends 30 days on, cannot renew, and is warned about like any must-reconnect sign-in', () async {
        final result = await adapter.connect(PlatformTier.byokApi, {'appId': 'app123', 'sandboxToken': 'pina.S'}, testContext(handler: sandboxServer([])));
        final policy = adapter.signInPolicyFor(result.account);
        expect(policy, same(SignInPolicies.pinterestSandboxToken));
        expect((policy.limit, policy.renewal), (SignInLimit.date, SignInRenewal.never));
        final stored = stampNewSignIn(result.secrets, now: testNow);

        final early = deriveSignInLifetime(policy, stored, now: testNow.add(const Duration(days: 1)));
        expect(early.state, SignInState.endsOn);
        expect(early.expiresAt, testNow.add(const Duration(days: 30)));
        expect(early.about, isTrue, reason: 'counted from the connect, so shown as "about"');
        expect(early.endsSoon, isFalse);
        expect(early.renewsItself, isFalse);

        final late = deriveSignInLifetime(policy, stored, now: testNow.add(const Duration(days: 20)));
        expect(late.endsSoon, isTrue, reason: '10 days left: inside the 14-day warning');
        final status = SignInStatus.fromLifetime(result.account.id, late, hasConnection: true);
        expect(signInWarningCaseOf(status), SignInWarningCase.mustReconnect);
        expect(kSignInWarningDays[SignInWarningCase.mustReconnect], [14, 7, 3, 1, 0]);

        final over = deriveSignInLifetime(policy, stored, now: testNow.add(const Duration(days: 31)));
        expect(over.state, SignInState.ended);
      });

      test('no renewal request before the end; after it, a message about making a new token', () async {
        final noCalls = testContext(handler: (r) async => fail('no request expected'));
        final fresh = {'access_token': 'pina.S', 'expires_at': testNow.add(const Duration(days: 2)).toIso8601String()};
        expect(await adapter.refreshSecrets(sandboxAccount(pasted: true), fresh, noCalls), isNull,
            reason: 'not renewed 3 days early, as a browser sign-in would be: there is nothing to renew it with');
        final ended = {'access_token': 'pina.S', 'expires_at': testNow.subtract(const Duration(minutes: 1)).toIso8601String()};
        await expectLater(
          adapter.refreshSecrets(sandboxAccount(pasted: true), ended, noCalls),
          throwsA(isA<AdapterException>().having((e) => e.error.message, 'message', contains('Generate access token'))),
        );
        final post = await adapter.publish(PostVariant(text: 'x', media: [fakeImage()]), sandboxAccount(pasted: true), ended, noCalls);
        expect(post.error!.kind, PublishErrorKind.auth);
        expect(post.error!.message, contains('sandbox token'));
      });
    });
  });

  group('redirect URI mismatch (1.4.4)', () {
    Future<ConnectException> refused(String host) async {
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (r) async => _json({'error': 'invalid_request', 'error_description': 'The provided redirect URI does not match the with the registered URI'}, 400),
      );
      try {
        await adapter.connect(PlatformTier.byokApi, {'appId': 'app123', 'appSecret': 'secret456', 'redirectHost': host}, ctx);
      } on ConnectException catch (e) {
        return e;
      }
      fail('expected a ConnectException');
    }

    test('names what NEFORUM sent and the http vs https mismatch', () async {
      final e = await refused('localhost');
      expect(e.message, contains('http://localhost:52771/callback'));
      expect(e.message, contains('https://localhost:52771/callback (https instead of http)'));
      expect(e.message, contains('Redirect URIs'));
    });

    test('with 127.0.0.1 it points to the localhost address Pinterest accepts', () async {
      final e = await refused('127.0.0.1');
      expect(e.message, contains('NEFORUM sent exactly http://127.0.0.1:52771/callback'));
      expect(e.message, contains('add http://localhost:52771/callback there'));
      expect(e.message, contains('choose "localhost"'));
    });
  });

  group('hand-off', () {
    test('web intent with link, public media URL and description', () {
      final plan = adapter.buildHandoff(PostVariant(
        text: 'Lemon tart & more',
        link: 'https://example.com/tart',
        media: [fakeImage()],
        extra: const {'pinterestMediaUrl': 'https://cdn.example.test/img1.jpg'},
      ))!;
      expect(plan.webIntent.toString(),
          'https://www.pinterest.com/pin/create/button/?url=https%3A%2F%2Fexample.com%2Ftart'
          '&media=https%3A%2F%2Fcdn.example.test%2Fimg1.jpg&description=Lemon%20tart%20%26%20more');
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.clipboardText, 'Lemon tart & more');
      expect(plan.androidPackage, 'com.pinterest');
      expect(plan.iosScheme, 'pinterest://');
      expect(plan.shareFiles, hasLength(1));
      expect(plan.instructions, startsWith('1.'));
    });

    test('local media only: share sheet preferred, media omitted, description capped at 500', () {
      final long = 'w' * 600;
      final plan = adapter.buildHandoff(PostVariant(text: long, media: [fakeImage()]))!;
      expect(plan.preferred, HandoffMethod.shareSheet);
      final q = plan.webIntent!.queryParameters;
      expect(q.containsKey('media'), isFalse);
      expect(q.containsKey('url'), isFalse);
      expect(q['description']!.length, 500);
      expect(plan.clipboardText, long);
      expect(plan.mediaNote, contains('already online'));
      expect(plan.desktopUrl, 'https://www.pinterest.com/pin-creation-tool/');
    });
  });
}
