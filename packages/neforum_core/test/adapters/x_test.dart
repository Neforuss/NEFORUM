import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/x/x_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

ConnectedAccount _apiAccount({Map<String, dynamic>? config}) => ConnectedAccount(
      id: 'x-42',
      platformId: 'x',
      tier: PlatformTier.byokApi,
      displayName: 'Alice (@alice)',
      handle: '@alice',
      createdAt: testNow,
      config: config ?? const {'clientId': 'cid-123', 'confidentialClient': false, 'userId': '42'},
    );

Map<String, String> _secrets({DateTime? expiresAt, String? refresh = 'rt-old', String? clientSecret}) => {
      'access_token': 'at-1',
      if (refresh != null) 'refresh_token': refresh,
      'expires_at': (expiresAt ?? testNow.add(const Duration(hours: 1))).toUtc().toIso8601String(),
      'token_type': 'bearer',
      if (clientSecret != null) 'client_secret': clientSecret,
    };

void main() {
  final adapter = XAdapter();

  group('descriptor', () {
    final d = adapter.descriptor;

    test('limits match the research', () {
      expect(d.id, 'x');
      expect(d.tiers, {PlatformTier.byokApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.byokApi);
      expect(d.text.maxLength, 280);
      expect(d.text.counting, CountingRule.weightedX);
      expect(d.text.urlWeight, 23);
      expect(d.text.supportsThreads, isTrue);
      expect(d.text.titleSupported, isFalse);
      expect(d.media.maxImages, 4);
      expect(d.media.maxVideos, 1);
      expect(d.media.allowsMixedImageVideo, isFalse);
      expect(d.media.imageMaxBytes, 15 * 1024 * 1024);
      expect(d.media.videoMaxSeconds, 1200);
      expect(d.media.supportsAltText, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.serverSideScheduling, isFalse);
      expect(d.personalAccountOk, isTrue);
      expect(d.setupGuide, 'docs/platforms/x.md');
    });

    test('quotas: 100 per 15 min and a monthly cap of 500', () {
      final byId = {for (final q in d.defaultQuotas) q.id: q};
      expect(byId['x.posts_per_15min']!.limit, 100);
      expect(byId['x.posts_per_15min']!.window, const Duration(minutes: 15));
      expect(byId['x.posts_per_month']!.limit, 500);
      expect(byId['x.posts_per_month']!.window, const Duration(days: 30));
      expect(byId['x.posts_per_month']!.note, contains('Free tier'));
      expect(d.defaultQuotas.every((q) => q.appliesToTier == PlatformTier.byokApi), isTrue);
    });

    test('cost summary is honest about pay-per-use', () {
      expect(d.apiCostSummary, contains('February 2026'));
      expect(d.apiCostSummary, contains(r'$0.015'));
      expect(d.apiCostSummary, contains(r'$0.20'));
      expect(d.apiCostSummary, contains('no free tier'));
    });

    test('connect specs', () {
      final byok = adapter.specFor(PlatformTier.byokApi);
      expect(byok.usesBrowser, isTrue);
      expect(byok.loopbackRedirectOk, isTrue);
      expect(byok.customSchemeRedirectOk, isTrue);
      expect(byok.intro, contains('console.x.com'));
      expect(byok.intro, contains('Native App'));
      expect(byok.intro, contains('http://127.0.0.1:52771/callback'));
      expect(byok.intro, contains('neforum://callback'));
      expect(byok.fields.map((f) => f.key), ['client_id', 'client_secret']);
      expect(byok.fields[1].secret, isTrue);
      expect(byok.fields[1].required, isFalse);
      expect(adapter.specFor(PlatformTier.handoff).usesBrowser, isFalse);
    });
  });

  group('connect', () {
    test('public Native App client: PKCE, client_id in body, no Basic auth', () async {
      final calls = <http.Request>[];
      final broker = FakeAuthBroker();
      final ctx = testContext(
        broker: broker,
        handler: (req) async {
          calls.add(req);
          if (req.url.path == '/2/oauth2/token') {
            return _json({
              'token_type': 'bearer',
              'expires_in': 7200,
              'access_token': 'at-1',
              'scope': 'tweet.read tweet.write users.read media.write offline.access',
              'refresh_token': 'rt-1',
            });
          }
          return _json({
            'data': {'id': '42', 'name': 'Alice', 'username': 'alice', 'profile_image_url': 'https://pbs.example/a.jpg'},
          });
        },
      );

      final result = await adapter.connect(PlatformTier.byokApi, {'client_id': 'cid-123'}, ctx);

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.host, 'x.com');
      expect(auth.path, '/i/oauth2/authorize');
      expect(auth.queryParameters['client_id'], 'cid-123');
      expect(auth.queryParameters['response_type'], 'code');
      expect(auth.queryParameters['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(auth.queryParameters['scope'], 'tweet.read tweet.write users.read media.write offline.access');
      expect(auth.queryParameters['code_challenge_method'], 'S256');
      expect(auth.queryParameters['code_challenge'], isNotEmpty);

      expect(calls, hasLength(2));
      final token = calls[0];
      expect(token.method, 'POST');
      expect(token.url.toString(), 'https://api.x.com/2/oauth2/token');
      expect(token.headers.containsKey('Authorization'), isFalse);
      final form = bodyOf(token);
      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], 'test-code');
      expect(form['client_id'], 'cid-123');
      expect(form['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(form['code_verifier'], isNotEmpty);
      expect(form.containsKey('client_secret'), isFalse);

      final me = calls[1];
      expect(me.method, 'GET');
      expect(me.url.host, 'api.x.com');
      expect(me.url.path, '/2/users/me');
      expect(me.headers['Authorization'], 'Bearer at-1');

      final a = result.account;
      expect(a.id, 'x-42');
      expect(a.tier, PlatformTier.byokApi);
      expect(a.handle, '@alice');
      expect(a.displayName, 'Alice (@alice)');
      expect(a.avatarUrl, 'https://pbs.example/a.jpg');
      expect(a.config['clientId'], 'cid-123');
      expect(a.config['confidentialClient'], isFalse);
      expect(result.secrets['access_token'], 'at-1');
      expect(result.secrets['refresh_token'], 'rt-1');
      expect(DateTime.parse(result.secrets['expires_at']!), testNow.add(const Duration(hours: 2)));
      expect(result.secrets.containsKey('client_secret'), isFalse);
    });

    test('confidential client sends HTTP Basic and keeps the secret', () async {
      final calls = <http.Request>[];
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (req) async {
          calls.add(req);
          if (req.url.path == '/2/oauth2/token') {
            return _json({'token_type': 'bearer', 'expires_in': 7200, 'access_token': 'at-1', 'refresh_token': 'rt-1'});
          }
          return _json({
            'data': {'id': '42', 'name': 'Alice', 'username': 'alice'},
          });
        },
      );
      final result =
          await adapter.connect(PlatformTier.byokApi, {'client_id': 'cid', 'client_secret': 'shh'}, ctx);
      expect(calls[0].headers['Authorization'], 'Basic ${base64Encode(utf8.encode('cid:shh'))}');
      expect(bodyOf(calls[0]).containsKey('client_secret'), isFalse);
      expect(result.secrets['client_secret'], 'shh');
      expect(result.account.config['confidentialClient'], isTrue);
    });

    test('missing client id is a ConnectException', () async {
      final ctx = testContext(broker: FakeAuthBroker(), handler: (_) async => _json({}));
      expect(
        () => adapter.connect(PlatformTier.byokApi, {'client_id': ' '}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'client_id')),
      );
    });

    test('token endpoint refusal becomes a ConnectException with a hint', () async {
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (_) async => _json({'error': 'invalid_request', 'error_description': 'Value passed for the redirect uri was invalid'}, 400),
      );
      expect(
        () => adapter.connect(PlatformTier.byokApi, {'client_id': 'cid'}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Callback URLs'))),
      );
    });

    test('hand-off tier needs no network', () async {
      final ctx = testContext(handler: (_) async => throw StateError('no HTTP expected'));
      final r = await adapter.connect(PlatformTier.handoff, {'handle': '@alice'}, ctx);
      expect(r.account.tier, PlatformTier.handoff);
      expect(r.account.handle, '@alice');
      expect(r.secrets, isEmpty);
    });
  });

  group('validate', () {
    final account = _apiAccount();

    List<String> codes(PostVariant v, [ConnectedAccount? a]) =>
        adapter.validate(v, a ?? account).map((i) => i.code).toList();

    test('plain text is fine', () {
      expect(adapter.validate(const PostVariant(text: 'Hello X'), account).hasErrors, isFalse);
    });

    test('too long by weighted count', () {
      expect(codes(PostVariant(text: '漢' * 141)), contains('text.too_long'));
      expect(codes(PostVariant(text: 'a' * 280)), isNot(contains('text.too_long')));
    });

    test('GIF must be alone', () {
      final v = PostVariant(text: 'x', media: [fakeImage(), fakeImage(id: 'g', mimeType: 'image/gif')]);
      expect(codes(v), contains('x.gif_alone'));
    });

    test('photos are limited to 5 MB, GIFs to 15 MB', () {
      expect(codes(PostVariant(text: 'x', media: [fakeImage(sizeBytes: 6 * 1024 * 1024)])),
          contains('media.image_too_large'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(mimeType: 'image/gif', sizeBytes: 10 * 1024 * 1024)])),
          isNot(contains('media.image_too_large')));
    });

    test('five images and mixed media are errors', () {
      final five = [for (var i = 0; i < 5; i++) fakeImage(id: 'i$i')];
      expect(codes(PostVariant(text: 'x', media: five)), contains('media.too_many_images'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(), fakeVideo()])), contains('media.mixed'));
    });

    test('links trigger a cost notice on the API tier only', () {
      const v = PostVariant(text: 'Read https://example.com/post');
      expect(codes(v), contains('x.link_cost'));
      expect(codes(v, fakeAccount('x', tier: PlatformTier.handoff)), isNot(contains('x.link_cost')));
    });

    test('API account without client id', () {
      expect(codes(const PostVariant(text: 'hi'), _apiAccount(config: const {})), contains('account.not_configured'));
    });
  });

  group('publish', () {
    test('text-only post', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        return _json({
          'data': {'id': '1001', 'text': 'Hello'},
        }, 201);
      });
      final r = await adapter.publish(const PostVariant(text: 'Hello'), _apiAccount(), _secrets(), ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, '1001');
      expect(r.remoteUrl, 'https://x.com/alice/status/1001');
      expect(r.threadRemoteIds, isEmpty);
      expect(calls, hasLength(1));
      expect(calls[0].method, 'POST');
      expect(calls[0].url.toString(), 'https://api.x.com/2/tweets');
      expect(calls[0].headers['Authorization'], 'Bearer at-1');
      expect(bodyOf(calls[0]), {'text': 'Hello'});
    });

    test('two images: upload, alt text, upload, alt text, post', () async {
      final calls = <http.Request>[];
      var n = 0;
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        if (req.url.path == '/2/media/upload') {
          n++;
          return _json({
            'data': {'id': '50$n', 'media_key': '3_50$n', 'expires_after_secs': 86400},
          });
        }
        if (req.url.path == '/2/media/metadata') return _json({'data': {'id': 'x'}});
        return _json({
          'data': {'id': '2002'},
        }, 201);
      });
      final v = PostVariant(text: 'Pics', media: [fakeImage(id: 'a'), fakeImage(id: 'b', mimeType: 'image/png', altText: '')]);
      final r = await adapter.publish(v, _apiAccount(), _secrets(), ctx);
      expect(r.success, isTrue, reason: '${r.error}');

      expect(calls.map((c) => '${c.method} ${c.url.path}').toList(), [
        'POST /2/media/upload',
        'POST /2/media/metadata',
        'POST /2/media/upload',
        'POST /2/tweets',
      ]);
      final up = multipartFieldsOf(calls[0]);
      expect(up['media_category'], 'tweet_image');
      expect(up['media'], '<a.jpg>');
      expect(calls[0].headers['Authorization'], 'Bearer at-1');
      expect(bodyOf(calls[1]), {
        'id': '501',
        'metadata': {
          'alt_text': {'text': 'A test image'},
        },
      });
      expect(multipartFieldsOf(calls[2])['media'], '<b.jpg>');
      expect(bodyOf(calls[3]), {
        'text': 'Pics',
        'media': {
          'media_ids': ['501', '502'],
        },
      });
    });

    test('video: initialize, append, finalize, status poll, post', () async {
      final calls = <http.Request>[];
      final ctx = testContext(
        mediaBytes: Uint8List.fromList(List.filled(1000, 7)),
        handler: (req) async {
          calls.add(req);
          final p = req.url.path;
          if (p == '/2/media/upload/initialize') {
            return _json({
              'data': {'id': '900', 'media_key': '13_900', 'expires_after_secs': 86400},
            });
          }
          if (p == '/2/media/upload/900/append') return http.Response('', 204);
          if (p == '/2/media/upload/900/finalize') {
            return _json({
              'data': {
                'id': '900',
                'processing_info': {'state': 'pending', 'check_after_secs': 0},
              },
            });
          }
          if (p == '/2/media/upload' && req.method == 'GET') {
            return _json({
              'data': {
                'id': '900',
                'processing_info': {'state': 'succeeded', 'progress_percent': 100},
              },
            });
          }
          return _json({
            'data': {'id': '3003'},
          }, 201);
        },
      );
      final r = await adapter.publish(PostVariant(text: 'Clip', media: [fakeVideo()]), _apiAccount(), _secrets(), ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(calls.map((c) => '${c.method} ${c.url.path}').toList(), [
        'POST /2/media/upload/initialize',
        'POST /2/media/upload/900/append',
        'POST /2/media/upload/900/finalize',
        'GET /2/media/upload',
        'POST /2/tweets',
      ]);
      expect(bodyOf(calls[0]), {'media_type': 'video/mp4', 'total_bytes': 1000, 'media_category': 'tweet_video'});
      final append = multipartFieldsOf(calls[1]);
      expect(append['segment_index'], '0');
      expect(append['media'], '<vid1.mp4>');
      expect(calls[2].body, isEmpty);
      expect(calls[3].url.queryParameters, {'command': 'STATUS', 'media_id': '900'});
      expect(bodyOf(calls[4])['media'], {
        'media_ids': ['900'],
      });
    });

    test('failed video processing is a validation error', () async {
      final ctx = testContext(handler: (req) async {
        final p = req.url.path;
        if (p.endsWith('/initialize')) {
          return _json({
            'data': {'id': '900'},
          });
        }
        if (p.endsWith('/append')) return http.Response('', 204);
        return _json({
          'data': {
            'id': '900',
            'processing_info': {
              'state': 'failed',
              'error': {'message': 'InvalidMedia'},
            },
          },
        });
      });
      final r = await adapter.publish(PostVariant(text: 'Clip', media: [fakeVideo()]), _apiAccount(), _secrets(), ctx);
      expect(r.error!.kind, PublishErrorKind.validation);
      expect(r.error!.message, contains('InvalidMedia'));
    });

    test('thread: parts chained as replies, media on the first only', () async {
      final calls = <http.Request>[];
      var next = 10;
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        if (req.url.path == '/2/media/upload') {
          return _json({
            'data': {'id': '77'},
          });
        }
        if (req.url.path == '/2/media/metadata') return _json({'data': {'id': '77'}});
        return _json({
          'data': {'id': '${next++}'},
        }, 201);
      });
      final v = PostVariant(text: 'one 1/3', threadParts: const ['one 1/3', 'two 2/3', 'three 3/3'], media: [fakeImage()]);
      final r = await adapter.publish(v, _apiAccount(), _secrets(), ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, '10');
      expect(r.threadRemoteIds, ['10', '11', '12']);
      final posts = calls.where((c) => c.url.path == '/2/tweets').map(bodyOf).toList();
      expect(posts, [
        {
          'text': 'one 1/3',
          'media': {
            'media_ids': ['77'],
          },
        },
        {
          'text': 'two 2/3',
          'reply': {'in_reply_to_tweet_id': '10'},
        },
        {
          'text': 'three 3/3',
          'reply': {'in_reply_to_tweet_id': '11'},
        },
      ]);
    });

    test('thread failing half-way says what was posted and is not retryable', () async {
      var n = 0;
      final ctx = testContext(handler: (req) async {
        n++;
        if (n == 1) {
          return _json({
            'data': {'id': '10'},
          }, 201);
        }
        return _json({'detail': 'You are not allowed to create a Tweet with duplicate content.', 'title': 'Forbidden', 'status': 403, 'type': 'about:blank'}, 403);
      });
      final v = const PostVariant(text: 'a', threadParts: ['a', 'b']);
      final r = await adapter.publish(v, _apiAccount(), _secrets(), ctx);
      expect(r.error!.kind, PublishErrorKind.validation);
      expect(r.error!.message, contains('ids 10'));
      expect(r.error!.retryable, isFalse);
    });

    test('reply settings from extra are passed through when valid', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        return _json({
          'data': {'id': '1'},
        }, 201);
      });
      await adapter.publish(const PostVariant(text: 'hi', extra: {'replySettings': 'following'}), _apiAccount(), _secrets(), ctx);
      await adapter.publish(const PostVariant(text: 'hi', extra: {'replySettings': 'bogus'}), _apiAccount(), _secrets(), ctx);
      expect(bodyOf(calls[0])['reply_settings'], 'following');
      expect(bodyOf(calls[1]).containsKey('reply_settings'), isFalse);
    });

    group('error mapping', () {
      Future<PublishResult> failWith(http.Response res) => adapter.publish(
            const PostVariant(text: 'Hello'),
            _apiAccount(),
            _secrets(),
            testContext(handler: (_) async => res),
          );

      test('401 -> auth', () async {
        final r = await failWith(_json({'title': 'Unauthorized', 'type': 'about:blank', 'status': 401, 'detail': 'Unauthorized'}, 401));
        expect(r.error!.kind, PublishErrorKind.auth);
        expect(r.error!.statusCode, 401);
      });

      test('429 -> quota with retryAfter from x-rate-limit-reset', () async {
        final reset = testNow.millisecondsSinceEpoch ~/ 1000 + 600;
        final r = await failWith(_json({'title': 'Too Many Requests', 'detail': 'Too Many Requests', 'type': 'about:blank', 'status': 429}, 429,
            {'x-rate-limit-limit': '100', 'x-rate-limit-remaining': '0', 'x-rate-limit-reset': '$reset'}));
        expect(r.error!.kind, PublishErrorKind.quota);
        expect(r.error!.retryAfter, const Duration(minutes: 10));
      });

      test('402 CreditsDepleted -> quota', () async {
        final r = await failWith(_json({
          'account_id': '2012749439400648704',
          'title': 'CreditsDepleted',
          'detail': 'Your enrolled account [2012749439400648704] does not have any credits to fulfill this request.',
          'type': '',
        }, 402));
        expect(r.error!.kind, PublishErrorKind.quota);
        expect(r.error!.message, contains('credits'));
      });

      test('403 duplicate -> validation', () async {
        final r = await failWith(_json({
          'detail': 'You are not allowed to create a Tweet with duplicate content.',
          'type': 'about:blank',
          'title': 'Forbidden',
          'status': 403,
        }, 403));
        expect(r.error!.kind, PublishErrorKind.validation);
      });

      test('403 not permitted -> auth', () async {
        final r = await failWith(_json({
          'detail': 'You are not permitted to perform this action.',
          'type': 'about:blank',
          'title': 'Forbidden',
          'status': 403,
        }, 403));
        expect(r.error!.kind, PublishErrorKind.auth);
      });

      test('400 -> validation with X message', () async {
        final r = await failWith(_json({
          'errors': [
            {'message': 'Your media IDs are invalid.'},
          ],
          'title': 'Invalid Request',
          'type': 'https://api.twitter.com/2/problems/invalid-request',
        }, 400));
        expect(r.error!.kind, PublishErrorKind.validation);
        expect(r.error!.message, contains('Your media IDs are invalid.'));
      });

      test('503 -> network', () async {
        final r = await failWith(http.Response('upstream', 503));
        expect(r.error!.kind, PublishErrorKind.network);
      });

      test('missing tokens -> auth without any request', () async {
        final r = await adapter.publish(
            const PostVariant(text: 'Hi'), _apiAccount(), const {}, testContext(handler: (_) async => throw StateError('no')));
        expect(r.error!.kind, PublishErrorKind.auth);
      });
    });
  });

  group('refreshSecrets', () {
    test('returns null while the token is valid', () async {
      final ctx = testContext(handler: (_) async => throw StateError('no HTTP expected'));
      expect(await adapter.refreshSecrets(_apiAccount(), _secrets(), ctx), isNull);
    });

    test('refreshes an expired token and stores the rotated refresh token', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        return _json({'token_type': 'bearer', 'expires_in': 7200, 'access_token': 'at-2', 'refresh_token': 'rt-new'});
      });
      final out = await adapter.refreshSecrets(_apiAccount(), _secrets(expiresAt: testNow.subtract(const Duration(minutes: 1))), ctx);
      expect(calls, hasLength(1));
      expect(calls[0].url.toString(), 'https://api.x.com/2/oauth2/token');
      expect(calls[0].headers.containsKey('Authorization'), isFalse);
      expect(bodyOf(calls[0]), {'grant_type': 'refresh_token', 'refresh_token': 'rt-old', 'client_id': 'cid-123'});
      expect(out!['access_token'], 'at-2');
      expect(out['refresh_token'], 'rt-new');
      expect(DateTime.parse(out['expires_at']!), testNow.add(const Duration(hours: 2)));
    });

    test('confidential client refresh uses Basic auth', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        return _json({'token_type': 'bearer', 'expires_in': 7200, 'access_token': 'at-2', 'refresh_token': 'rt-new'});
      });
      final out = await adapter.refreshSecrets(
          _apiAccount(), _secrets(expiresAt: testNow.subtract(const Duration(minutes: 1)), clientSecret: 'shh'), ctx);
      expect(calls[0].headers['Authorization'], 'Basic ${base64Encode(utf8.encode('cid-123:shh'))}');
      expect(out!['client_secret'], 'shh');
    });

    test('a consumed refresh token means reconnect', () async {
      final ctx = testContext(
          handler: (_) async => _json({'error': 'invalid_request', 'error_description': 'Value passed for the token was invalid.'}, 400));
      expect(
        () => adapter.refreshSecrets(_apiAccount(), _secrets(expiresAt: testNow.subtract(const Duration(minutes: 1))), ctx),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)),
      );
    });

    test('expired without refresh token means reconnect', () async {
      final ctx = testContext(handler: (_) async => throw StateError('no HTTP expected'));
      expect(
        () => adapter.refreshSecrets(
            _apiAccount(), _secrets(expiresAt: testNow.subtract(const Duration(minutes: 1)), refresh: null), ctx),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)),
      );
    });
  });

  group('buildHandoff', () {
    test('text post prefers the web intent', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Hello world #foss'))!;
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.webIntent!.scheme, 'https');
      expect(plan.webIntent!.host, 'x.com');
      expect(plan.webIntent!.path, '/intent/tweet');
      expect(plan.webIntent!.queryParameters, {'text': 'Hello world #foss'});
      expect(plan.clipboardText, 'Hello world #foss');
      expect(plan.androidPackage, 'com.twitter.android');
      expect(plan.iosScheme, 'twitter://');
      expect(plan.instructions, startsWith('1.'));
    });

    test('link not in the text goes into the url parameter', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'New post', link: 'https://example.com/a'))!;
      expect(plan.webIntent!.queryParameters, {'text': 'New post', 'url': 'https://example.com/a'});
      expect(plan.clipboardText, 'New post\n\nhttps://example.com/a');
    });

    test('link already in the text is not repeated', () {
      final plan =
          adapter.buildHandoff(const PostVariant(text: 'New post\n\nhttps://example.com/a', link: 'https://example.com/a'))!;
      expect(plan.webIntent!.queryParameters.containsKey('url'), isFalse);
    });

    test('media prefers the share sheet', () {
      final plan = adapter.buildHandoff(PostVariant(text: 'Pic', media: [fakeImage()]))!;
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.shareFiles, hasLength(1));
      expect(plan.shareText, 'Pic');
      expect(plan.mediaNote, isNotNull);
    });

    test('threads: first part in the composer, whole thread on the clipboard', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'a 1/2', threadParts: ['a 1/2', 'b 2/2']))!;
      expect(plan.webIntent!.queryParameters['text'], 'a 1/2');
      expect(plan.clipboardText, 'a 1/2\n\nb 2/2');
    });
  });
}
