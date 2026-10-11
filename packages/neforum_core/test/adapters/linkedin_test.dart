import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/linkedin/linkedin_adapter.dart';
import 'package:neforum_core/src/adapters/linkedin/linkedin_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

const _postUrn = 'urn:li:share:7000000000000000001';

ConnectedAccount _account({Map<String, dynamic>? config}) => fakeAccount(
      'linkedin',
      tier: PlatformTier.byokApi,
      id: 'linkedin:abc123',
      config: config ??
          const {
            'clientId': 'cid',
            'apiVersion': '202609',
            'sub': 'abc123',
            'personUrn': 'urn:li:person:abc123',
          },
    );

Map<String, String> _secrets({DateTime? expiresAt, String? refreshToken}) => {
      'client_secret': 'csecret',
      'access_token': 'AT-1',
      'token_type': 'Bearer',
      'expires_at': (expiresAt ?? testNow.add(const Duration(days: 30))).toUtc().toIso8601String(),
      if (refreshToken != null) 'refresh_token': refreshToken,
    };

http.Response _created() => http.Response('', 201, headers: {'x-restli-id': _postUrn});

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

Map<String, dynamic> _body(http.Request r) => Map<String, dynamic>.from(jsonDecode(r.body) as Map);

void _expectRestHeaders(http.Request r) {
  expect(r.headers['Authorization'], 'Bearer AT-1');
  expect(r.headers['LinkedIn-Version'], '202609');
  expect(r.headers['X-Restli-Protocol-Version'], '2.0.0');
}

void main() {
  final adapter = LinkedInAdapter(videoPollInterval: Duration.zero, videoPollAttempts: 3);

  group('descriptor', () {
    test('limits match the research', () {
      final d = adapter.descriptor;
      expect(d.id, 'linkedin');
      expect(d.tiers, {PlatformTier.byokApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.byokApi);
      expect(d.text.maxLength, 3000);
      expect(d.text.counting, CountingRule.utf16);
      expect(d.text.supportsThreads, isFalse);
      expect(d.text.supportsContentWarning, isFalse);
      expect(d.media.maxImages, 20);
      expect(d.media.maxVideos, 1);
      expect(d.media.allowsMixedImageVideo, isFalse);
      expect(d.media.videoMaxSeconds, 1800);
      expect(d.media.videoMaxBytes, 500000000);
      expect(d.media.imageMimeTypes, {'image/jpeg', 'image/png', 'image/gif'});
      expect(d.media.videoMimeTypes, {'video/mp4'});
      expect(d.media.supportsAltText, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.personalAccountOk, isTrue);
      expect(d.serverSideScheduling, isFalse);
      expect(d.supportsLinkField, isTrue);
      expect(d.setupGuide, 'docs/platforms/linkedin.md');
      final q = d.defaultQuotas.single;
      expect(q.id, 'linkedin.requests_per_day');
      expect(q.limit, 150);
      expect(q.window, const Duration(days: 1));
      expect(q.appliesToTier, PlatformTier.byokApi);
    });

    test('connect specs: loopback only, client secret is secret', () {
      final spec = adapter.specFor(PlatformTier.byokApi);
      expect(spec.usesBrowser, isTrue);
      expect(spec.loopbackRedirectOk, isTrue);
      expect(spec.customSchemeRedirectOk, isFalse);
      expect(spec.intro, contains('http://127.0.0.1:52771/callback'));
      expect(spec.intro, contains('Share on LinkedIn'));
      expect(spec.fields.firstWhere((f) => f.key == 'clientSecret').secret, isTrue);
      expect(adapter.specFor(PlatformTier.handoff).usesBrowser, isFalse);
    });
  });

  group('connect', () {
    test('runs the authorization-code flow with client secret and reads userinfo', () async {
      final calls = <http.Request>[];
      final broker = FakeAuthBroker(code: 'the-code');
      final ctx = testContext(
        broker: broker,
        handler: (r) async {
          calls.add(r);
          if (r.url.path == '/oauth/v2/accessToken') {
            return _json({'access_token': 'AT-new', 'expires_in': 5184000, 'scope': 'openid,profile,w_member_social'});
          }
          return _json({'sub': 'abc123', 'name': 'Ada Lovelace', 'picture': 'https://media.licdn.com/p.jpg'});
        },
      );
      final result = await adapter.connect(
          PlatformTier.byokApi, {'clientId': 'cid', 'clientSecret': 'csecret', 'apiVersion': ''}, ctx);

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.host, 'www.linkedin.com');
      expect(auth.path, '/oauth/v2/authorization');
      expect(auth.queryParameters['client_id'], 'cid');
      expect(auth.queryParameters['response_type'], 'code');
      expect(auth.queryParameters['scope'], 'openid profile w_member_social');
      expect(auth.queryParameters['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(auth.queryParameters.containsKey('code_challenge'), isFalse);

      expect(calls, hasLength(2));
      final token = calls[0];
      expect(token.method, 'POST');
      expect(token.url.toString(), 'https://www.linkedin.com/oauth/v2/accessToken');
      expect(bodyOf(token), {
        'grant_type': 'authorization_code',
        'code': 'the-code',
        'redirect_uri': 'http://127.0.0.1:52771/callback',
        'client_id': 'cid',
        'client_secret': 'csecret',
      });
      final info = calls[1];
      expect(info.method, 'GET');
      expect(info.url.toString(), 'https://api.linkedin.com/v2/userinfo');
      expect(info.headers['Authorization'], 'Bearer AT-new');

      final a = result.account;
      expect(a.id, 'linkedin:abc123');
      expect(a.displayName, 'Ada Lovelace');
      expect(a.avatarUrl, 'https://media.licdn.com/p.jpg');
      expect(a.config['personUrn'], 'urn:li:person:abc123');
      expect(a.config['apiVersion'], LinkedInApi.defaultVersion);
      expect(a.config.containsKey('clientSecret'), isFalse);
      expect(result.secrets['client_secret'], 'csecret');
      expect(result.secrets['access_token'], 'AT-new');
      expect(DateTime.parse(result.secrets['expires_at']!), testNow.add(const Duration(days: 60)));
    });

    test('rejects missing secret and bad version', () async {
      final ctx = testContext(broker: FakeAuthBroker(), handler: (_) async => http.Response('', 500));
      expect(() => adapter.connect(PlatformTier.byokApi, {'clientId': 'cid'}, ctx), throwsA(isA<ConnectException>()));
      expect(
          () => adapter.connect(
              PlatformTier.byokApi, {'clientId': 'cid', 'clientSecret': 's', 'apiVersion': 'latest'}, ctx),
          throwsA(isA<ConnectException>()));
    });

    test('maps a redirect_uri error to a helpful message', () async {
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (_) async => _json({'error': 'invalid_redirect_uri', 'error_description': 'Unable to retrieve access token'}, 400),
      );
      await expectLater(
        adapter.connect(PlatformTier.byokApi, {'clientId': 'cid', 'clientSecret': 's'}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('127.0.0.1:52771/callback'))),
      );
    });

    test('hand-off tier needs no network', () async {
      final ctx = testContext(handler: (_) async => throw StateError('no network expected'));
      final r = await adapter.connect(PlatformTier.handoff, {}, ctx);
      expect(r.account.tier, PlatformTier.handoff);
      expect(r.account.id, startsWith('linkedin:handoff:'));
      expect(r.secrets, isEmpty);
    });
  });

  group('little text', () {
    test('escapes reserved characters and keeps hashtags', () {
      expect(LittleText.escape(r'Hi (all) [x] {y} <z> @bob a|b ~c_d *e* back\slash'),
          r'Hi \(all\) \[x\] \{y\} \<z\> \@bob a\|b \~c\_d \*e\* back\\slash');
      expect(LittleText.escape('Ship it #flutter #Dart3 now'), 'Ship it #flutter #Dart3 now');
      expect(LittleText.escape('C# and # alone and x#y'), r'C\# and \# alone and x\#y');
      expect(LittleText.escape('#München'), '#München');
    });
  });

  group('validate', () {
    final account = _account();

    test('accepts a normal post', () {
      final issues = adapter.validate(const PostVariant(text: 'Hello LinkedIn'), account);
      expect(issues.hasErrors, isFalse);
    });

    test('flags threads, too-large images and too-short videos', () {
      expect(
          adapter
              .validate(const PostVariant(text: 'a', threadParts: ['a', 'b']), account)
              .map((i) => i.code),
          contains('thread.unsupported'));
      final big = fakeImage(width: 8000, height: 5000);
      expect(adapter.validate(PostVariant(text: 'x', media: [big]), account).map((i) => i.code),
          contains('media.image_pixels'));
      final shortVid = fakeVideo(durationMs: 1500, sizeBytes: 50 * 1000);
      final codes = adapter.validate(PostVariant(text: 'x', media: [shortVid]), account).map((i) => i.code);
      expect(codes, containsAll(['media.video_too_short', 'media.video_too_small']));
      final webp = fakeImage(mimeType: 'image/webp');
      expect(adapter.validate(PostVariant(text: 'x', media: [webp]), account).map((i) => i.code),
          contains('media.image_type'));
    });

    test('counts the link that gets appended to media posts', () {
      final text = 'a' * 2990;
      final v = PostVariant(text: text, link: 'https://example.org/some/long/path', media: [fakeImage()]);
      expect(adapter.validate(v, account).map((i) => i.code), contains('text.too_long'));
    });

    test('warns when escaping may exceed the limit, and about visibility/title', () {
      final v = PostVariant(text: '(${'a' * 2997})', title: 'Unused', visibility: Visibility.private);
      final codes = adapter.validate(v, account).map((i) => i.code).toList();
      expect(codes, containsAll(['text.escape_budget', 'visibility.private', 'title.unused']));
      expect(adapter.validate(v, account).hasErrors, isFalse);
    });

    test('requires a connected member id', () {
      final bare = _account(config: const {'clientId': 'cid'});
      expect(adapter.validate(const PostVariant(text: 'x'), bare).map((i) => i.code), contains('account.not_connected'));
    });
  });

  group('publish', () {
    test('text post: POST /rest/posts with versioned headers and escaped commentary', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _created();
      });
      final r = await adapter.publish(
          const PostVariant(text: 'Hello (world) #dart', visibility: Visibility.followers), _account(), _secrets(), ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, _postUrn);
      expect(r.remoteUrl, 'https://www.linkedin.com/feed/update/$_postUrn/');
      expect(calls, hasLength(1));
      final c = calls.single;
      expect(c.method, 'POST');
      expect(c.url.toString(), 'https://api.linkedin.com/rest/posts');
      _expectRestHeaders(c);
      expect(_body(c), {
        'author': 'urn:li:person:abc123',
        'commentary': r'Hello \(world\) #dart',
        'visibility': 'CONNECTIONS',
        'distribution': {'feedDistribution': 'MAIN_FEED', 'targetEntities': <Object?>[], 'thirdPartyDistributionChannels': <Object?>[]},
        'lifecycleState': 'PUBLISHED',
        'isReshareDisabledByAuthor': false,
      });
    });

    test('single image: initializeUpload, PUT with bearer, content.media with alt text', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/rest/images') {
          return _json({
            'value': {
              'uploadUrlExpiresAt': 1650567510704,
              'uploadUrl': 'https://www.linkedin.com/dms-uploads/IMG1/uploaded-image/0?ut=x',
              'image': 'urn:li:image:IMG1',
            }
          });
        }
        if (r.url.path.startsWith('/dms-uploads/')) return http.Response('', 201);
        return _created();
      });
      final r = await adapter.publish(
          PostVariant(text: 'Look', media: [fakeImage(altText: 'A cat')]), _account(), _secrets(), ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(calls.map((c) => '${c.method} ${c.url.host}${c.url.path}'), [
        'POST api.linkedin.com/rest/images',
        'PUT www.linkedin.com/dms-uploads/IMG1/uploaded-image/0',
        'POST api.linkedin.com/rest/posts',
      ]);
      expect(calls[0].url.queryParameters['action'], 'initializeUpload');
      _expectRestHeaders(calls[0]);
      expect(_body(calls[0]), {
        'initializeUploadRequest': {'owner': 'urn:li:person:abc123'}
      });
      expect(calls[1].headers['Authorization'], 'Bearer AT-1');
      expect(calls[1].headers['Content-Type'], startsWith('image/jpeg'));
      expect(calls[1].bodyBytes, fakeJpegBytes);
      expect(_body(calls[2])['content'], {
        'media': {'id': 'urn:li:image:IMG1', 'altText': 'A cat'}
      });
    });

    test('several images become a multiImage post', () async {
      var n = 0;
      final posts = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        if (r.url.path == '/rest/images') {
          n++;
          return _json({
            'value': {'uploadUrl': 'https://www.linkedin.com/dms-uploads/I$n/up', 'image': 'urn:li:image:I$n'}
          });
        }
        if (r.url.path.startsWith('/dms-uploads/')) return http.Response('', 201);
        posts.add(r);
        return _created();
      });
      final r = await adapter.publish(
        PostVariant(text: 'Album', media: [fakeImage(id: 'a', altText: 'one'), fakeImage(id: 'b', altText: null)]),
        _account(),
        _secrets(),
        ctx,
      );
      expect(r.success, isTrue, reason: '${r.error}');
      expect(_body(posts.single)['content'], {
        'multiImage': {
          'images': [
            {'id': 'urn:li:image:I1', 'altText': 'one'},
            {'id': 'urn:li:image:I2'},
          ]
        }
      });
    });

    test('video: init, part PUTs without auth, finalize with ETags, status poll, post', () async {
      final bytes = Uint8List.fromList(List<int>.generate(10, (i) => i));
      final calls = <http.Request>[];
      final progress = <String>[];
      final base = testContext(mediaBytes: bytes, handler: (r) async {
        calls.add(r);
        final p = r.url.path;
        if (p == '/rest/videos' && r.url.queryParameters['action'] == 'initializeUpload') {
          return _json({
            'value': {
              'video': 'urn:li:video:V1',
              'uploadToken': 'tok',
              'uploadInstructions': [
                {'uploadUrl': 'https://www.linkedin.com/dms-uploads/V1/part0', 'firstByte': 0, 'lastByte': 5},
                {'uploadUrl': 'https://www.linkedin.com/dms-uploads/V1/part1', 'firstByte': 6, 'lastByte': 9},
              ],
            }
          });
        }
        if (p.startsWith('/dms-uploads/')) {
          return http.Response('', 200, headers: {'etag': p.endsWith('part0') ? '"etag-0"' : 'etag-1'});
        }
        if (p == '/rest/videos') return http.Response('', 200);
        if (p.startsWith('/rest/videos/')) return _json({'id': 'urn:li:video:V1', 'status': 'AVAILABLE'});
        return _created();
      });
      final ctx = base.copyWith(onProgress: progress.add);
      final r = await adapter.publish(
          PostVariant(text: 'Clip', title: 'My clip', media: [fakeVideo()]), _account(), _secrets(), ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(calls.map((c) => '${c.method} ${c.url.path}'), [
        'POST /rest/videos',
        'PUT /dms-uploads/V1/part0',
        'PUT /dms-uploads/V1/part1',
        'POST /rest/videos',
        'GET /rest/videos/urn%3Ali%3Avideo%3AV1',
        'POST /rest/posts',
      ]);
      expect(_body(calls[0]), {
        'initializeUploadRequest': {
          'owner': 'urn:li:person:abc123',
          'fileSizeBytes': 10,
          'uploadCaptions': false,
          'uploadThumbnail': false,
        }
      });
      expect(calls[1].headers.containsKey('Authorization'), isFalse);
      expect(calls[1].headers['Content-Type'], startsWith('application/octet-stream'));
      expect(calls[1].bodyBytes, [0, 1, 2, 3, 4, 5]);
      expect(calls[2].bodyBytes, [6, 7, 8, 9]);
      expect(calls[3].url.queryParameters['action'], 'finalizeUpload');
      expect(_body(calls[3]), {
        'finalizeUploadRequest': {
          'video': 'urn:li:video:V1',
          'uploadToken': 'tok',
          'uploadedPartIds': ['etag-0', 'etag-1'],
        }
      });
      expect(calls[4].url.toString(), 'https://api.linkedin.com/rest/videos/urn%3Ali%3Avideo%3AV1');
      expect(_body(calls[5])['content'], {
        'media': {'id': 'urn:li:video:V1', 'title': 'My clip'}
      });
      expect(progress, containsAll(['Uploading video', 'Uploading video part 1 of 2', 'Publishing to LinkedIn']));
    });

    test('video processing failure is a validation error', () async {
      final ctx = testContext(handler: (r) async {
        final p = r.url.path;
        if (p == '/rest/videos' && r.url.queryParameters['action'] == 'initializeUpload') {
          return _json({
            'value': {
              'video': 'urn:li:video:V2',
              'uploadInstructions': [
                {'uploadUrl': 'https://www.linkedin.com/dms-uploads/V2/p', 'firstByte': 0, 'lastByte': 100},
              ],
            }
          });
        }
        if (p.startsWith('/dms-uploads/')) return http.Response('', 200, headers: {'etag': 'e'});
        if (p == '/rest/videos') return http.Response('', 200);
        return _json({'status': 'PROCESSING_FAILED', 'processingFailureReason': 'Unsupported codec'});
      });
      final r = await adapter.publish(PostVariant(text: 'x', media: [fakeVideo()]), _account(), _secrets(), ctx);
      expect(r.error?.kind, PublishErrorKind.validation);
      expect(r.error?.message, contains('Unsupported codec'));
    });

    test('link without media becomes an article; link with media is appended to the text', () async {
      final posts = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        if (r.url.path == '/rest/images') {
          return _json({
            'value': {'uploadUrl': 'https://www.linkedin.com/dms-uploads/I/up', 'image': 'urn:li:image:I'}
          });
        }
        if (r.url.path.startsWith('/dms-uploads/')) return http.Response('', 201);
        posts.add(r);
        return _created();
      });
      await adapter.publish(
        const PostVariant(text: 'Read this', link: 'https://www.example.org/post', extra: {'linkDescription': 'Desc'}),
        _account(),
        _secrets(),
        ctx,
      );
      final article = _body(posts[0]);
      expect(article['commentary'], 'Read this');
      expect(article['content'], {
        'article': {'source': 'https://www.example.org/post', 'title': 'example.org', 'description': 'Desc'}
      });

      await adapter.publish(
        PostVariant(text: 'With pic', link: 'https://example.org/a_b', media: [fakeImage()]),
        _account(),
        _secrets(),
        ctx,
      );
      final withMedia = _body(posts[1]);
      expect(withMedia['commentary'], 'With pic\n\nhttps://example.org/a\\_b');
      expect((withMedia['content'] as Map).containsKey('media'), isTrue);
    });

    test('expired token fails with a reconnect message without calling LinkedIn', () async {
      final ctx = testContext(handler: (_) async => throw StateError('no request expected'));
      final r = await adapter.publish(const PostVariant(text: 'x'), _account(),
          _secrets(expiresAt: testNow.subtract(const Duration(minutes: 1))), ctx);
      expect(r.error?.kind, PublishErrorKind.auth);
      expect(r.error?.message, contains('60 days'));
    });

    Future<PublishError> failWith(http.Response response) async {
      final ctx = testContext(handler: (_) async => response);
      final r = await adapter.publish(const PostVariant(text: 'x'), _account(), _secrets(), ctx);
      expect(r.success, isFalse);
      return r.error!;
    }

    test('401 maps to auth with the 60-day hint', () async {
      final e = await failWith(
          _json({'status': 401, 'serviceErrorCode': 65600, 'code': 'INVALID_ACCESS_TOKEN', 'message': 'Invalid access token'}, 401));
      expect(e.kind, PublishErrorKind.auth);
      expect(e.message, contains('Reconnect LinkedIn'));
      expect(e.message, contains('60 days'));
      expect(e.statusCode, 401);
    });

    test('403 maps to auth about the Share on LinkedIn product', () async {
      final e = await failWith(_json({'status': 403, 'code': 'ACCESS_DENIED', 'message': 'Not enough permissions'}, 403));
      expect(e.kind, PublishErrorKind.auth);
      expect(e.message, contains('Share on LinkedIn'));
    });

    test('429 maps to quota with Retry-After, or the next UTC midnight', () async {
      final e1 = await failWith(_json({'status': 429, 'code': 'TOO_MANY_REQUESTS'}, 429, {'retry-after': '120'}));
      expect(e1.kind, PublishErrorKind.quota);
      expect(e1.retryAfter, const Duration(seconds: 120));
      final e2 = await failWith(_json({'status': 429, 'message': 'Resource level throttle limit'}, 429));
      expect(e2.kind, PublishErrorKind.quota);
      expect(e2.retryAfter, const Duration(hours: 12)); // testNow is 12:00 UTC
    });

    test('4xx bodies map to validation / configuration', () async {
      final tooLong = await failWith(_json({
        'status': 400,
        'message': 'Field length too long',
        'errorDetails': {
          'inputErrors': [
            {'code': 'FIELD_LENGTH_TOO_LONG', 'description': 'commentary length exceeds 3000', 'input': <String, Object?>{}}
          ]
        }
      }, 400));
      expect(tooLong.kind, PublishErrorKind.validation);
      expect(tooLong.message, contains('commentary length exceeds 3000'));

      final dup = await failWith(_json({'status': 422, 'message': 'Content is a duplicate of urn:li:share:123'}, 422));
      expect(dup.kind, PublishErrorKind.validation);
      expect(dup.message, contains('duplicate'));

      final version = await failWith(_json({'status': 426, 'code': 'NONEXISTENT_VERSION', 'message': 'Requested version 202410 is not active'}, 426));
      expect(version.kind, PublishErrorKind.configuration);

      final server = await failWith(_json({'status': 500, 'message': 'Internal error'}, 500));
      expect(server.kind, PublishErrorKind.network);
      expect(server.retryable, isTrue);
    });

    test('missing x-restli-id is a platform error', () async {
      final e = await failWith(http.Response('', 201));
      expect(e.kind, PublishErrorKind.platform);
    });
  });

  group('refreshSecrets', () {
    test('returns null while the token is valid', () async {
      final ctx = testContext(handler: (_) async => throw StateError('no request expected'));
      expect(await adapter.refreshSecrets(_account(), _secrets(), ctx), isNull);
    });

    test('expired token without refresh token asks the user to reconnect', () async {
      final ctx = testContext(handler: (_) async => throw StateError('no request expected'));
      await expectLater(
        adapter.refreshSecrets(_account(), _secrets(expiresAt: testNow.subtract(const Duration(days: 1))), ctx),
        throwsA(isA<AdapterException>()
            .having((e) => e.error.kind, 'kind', PublishErrorKind.auth)
            .having((e) => e.error.message, 'message', contains('60 days'))),
      );
    });

    test('partner apps with a refresh token are refreshed', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'access_token': 'AT-2', 'expires_in': 5184000, 'refresh_token': 'RT-2'});
      });
      final out = await adapter.refreshSecrets(
          _account(), _secrets(expiresAt: testNow.subtract(const Duration(days: 1)), refreshToken: 'RT-1'), ctx);
      expect(calls.single.url.toString(), 'https://www.linkedin.com/oauth/v2/accessToken');
      expect(bodyOf(calls.single), {
        'grant_type': 'refresh_token',
        'refresh_token': 'RT-1',
        'client_id': 'cid',
        'client_secret': 'csecret',
      });
      expect(out!['access_token'], 'AT-2');
      expect(out['refresh_token'], 'RT-2');
      expect(out['client_secret'], 'csecret');
    });
  });

  group('buildHandoff', () {
    test('text only: prefilled feed composer plus clipboard', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Hello world & co'))!;
      expect(plan.webIntent.toString(), 'https://www.linkedin.com/feed/?shareActive=true&text=Hello%20world%20%26%20co');
      expect(plan.clipboardText, 'Hello world & co');
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.androidPackage, 'com.linkedin.android');
      expect(plan.iosScheme, 'linkedin://');
      expect(plan.desktopUrl, 'https://www.linkedin.com/feed/');
      expect(plan.instructions, startsWith('1. '));
    });

    test('link: share-offsite with the URL, text on the clipboard', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Worth a read', link: 'https://example.org/a?b=1'))!;
      expect(plan.webIntent.toString(),
          'https://www.linkedin.com/sharing/share-offsite/?url=https%3A%2F%2Fexample.org%2Fa%3Fb%3D1');
      expect(plan.clipboardText, 'Worth a read');
      expect(plan.shareText, 'Worth a read\n\nhttps://example.org/a?b=1');
    });

    test('media: share sheet with files', () {
      final img = fakeImage();
      final plan = adapter.buildHandoff(PostVariant(text: 'Pic', media: [img]))!;
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.shareFiles, [img]);
      expect(plan.mediaNote, isNotNull);
      expect(plan.clipboardText, 'Pic');
    });
  });
}
