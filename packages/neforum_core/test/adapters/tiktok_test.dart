import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/tiktok/tiktok_adapter.dart';
import 'package:neforum_core/src/adapters/tiktok/tiktok_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200, Map<String, String> headers = jsonHeaders]) =>
    http.Response(jsonEncode(body), status, headers: headers);

Map<String, dynamic> _ok(Map<String, dynamic> data) => {
      'data': data,
      'error': {'code': 'ok', 'message': '', 'log_id': 'log1'},
    };

Map<String, dynamic> _err(String code, [String message = '']) => {
      'error': {'code': code, 'message': message, 'log_id': 'log1'},
    };

final _creatorInfo = _ok({
  'creator_username': 'alice',
  'creator_nickname': 'Alice',
  'privacy_level_options': ['PUBLIC_TO_EVERYONE', 'MUTUAL_FOLLOW_FRIENDS', 'SELF_ONLY'],
  'comment_disabled': false,
  'duet_disabled': false,
  'stitch_disabled': true,
  'max_video_post_duration_sec': 300,
});

const _secrets = {
  'access_token': 'act.123',
  'refresh_token': 'rft.456',
  'expires_at': '2026-10-08T12:00:00.000Z',
  'token_type': 'Bearer',
  'refresh_expires_at': '2027-10-07T12:00:00.000Z',
  'client_secret': 'sekrit',
};

ConnectedAccount _byok() => fakeAccount('tiktok', tier: PlatformTier.byokApi, config: {'clientKey': 'ck123'});

void main() {
  final adapter = TikTokAdapter(pollInterval: Duration.zero, maxPolls: 3);

  group('descriptor', () {
    test('limits match the Content Posting API docs', () {
      final d = adapter.descriptor;
      expect(d.id, 'tiktok');
      expect(d.tiers, {PlatformTier.handoff, PlatformTier.byokApi});
      expect(d.defaultTier, PlatformTier.handoff);
      expect(d.text.maxLength, 2200);
      expect(d.text.counting, CountingRule.utf16);
      expect(d.text.titleMax, 90);
      expect(d.text.supportsThreads, isFalse);
      expect(d.media.maxImages, 35);
      expect(d.media.maxVideos, 1);
      expect(d.media.requiresMedia, isTrue);
      expect(d.media.imageMaxBytes, 20 * 1024 * 1024);
      expect(d.media.videoMaxBytes, 4 * 1024 * 1024 * 1024);
      expect(d.media.videoMaxSeconds, 600);
      expect(d.media.imageMimeTypes, {'image/jpeg', 'image/webp'});
      expect(d.media.videoMimeTypes, containsAll(['video/mp4', 'video/quicktime', 'video/webm']));
      expect(d.personalAccountOk, isTrue);
      expect(d.serverSideScheduling, isFalse);
      expect(d.setupGuide, 'docs/platforms/tiktok.md');
      expect(d.accountRequirements, contains('PRIVATE'));
      expect(d.apiCostSummary, contains('PRIVATE'));
      expect(d.defaultQuotas.map((q) => q.id), contains('tiktok.posts_per_day'));
      expect(d.defaultQuotas.every((q) => q.appliesToTier == PlatformTier.byokApi), isTrue);
    });

    test('connect specs', () {
      final byok = adapter.specFor(PlatformTier.byokApi);
      expect(byok.usesBrowser, isTrue);
      expect(byok.loopbackRedirectOk, isTrue);
      expect(byok.customSchemeRedirectOk, isFalse);
      expect(byok.fields.map((f) => f.key), ['client_key', 'client_secret']);
      expect(byok.fields.last.secret, isTrue);
      expect(byok.intro, contains('http://127.0.0.1:52771/callback'));
      expect(adapter.specFor(PlatformTier.handoff).usesBrowser, isFalse);
    });
  });

  group('chunk plan', () {
    test('small and medium files are one chunk', () {
      final p = planTikTokChunks(4194304);
      expect([p.chunkSize, p.totalChunkCount], [4194304, 1]);
      expect(planTikTokChunks(60000000).totalChunkCount, 1);
    });

    test('large files are split; last chunk absorbs remainder', () {
      final p = planTikTokChunks(70000000);
      expect(p.chunkSize, 16 * 1024 * 1024);
      expect(p.totalChunkCount, 4);
      expect(p.range(0), (0, 16777216));
      expect(p.range(3), (3 * 16777216, 70000000));
      final big = planTikTokChunks(4 * 1024 * 1024 * 1024);
      expect(big.totalChunkCount, lessThanOrEqualTo(1000));
      final (s, e) = big.range(big.totalChunkCount - 1);
      expect(e - s, lessThanOrEqualTo(128000000));
    });
  });

  group('connect', () {
    test('handoff needs nothing', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP expected'));
      final res = await adapter.connect(PlatformTier.handoff, {'display_name': 'Me'}, ctx);
      expect(res.account.tier, PlatformTier.handoff);
      expect(res.account.displayName, 'Me');
      expect(res.secrets, isEmpty);
    });

    test('byokApi: hex PKCE authorize URL, token exchange, user info', () async {
      final calls = <http.Request>[];
      final broker = FakeAuthBroker(code: 'code*1');
      final ctx = testContext(
        broker: broker,
        handler: (r) async {
          calls.add(r);
          if (r.url.path == '/v2/oauth/token/') {
            return _json({
              'access_token': 'act.new',
              'expires_in': 86400,
              'refresh_token': 'rft.new',
              'refresh_expires_in': 31536000,
              'open_id': 'open-1',
              'scope': 'user.info.basic,video.publish,video.upload',
              'token_type': 'Bearer',
            });
          }
          return _json(_ok({
            'user': {'open_id': 'open-1', 'display_name': 'Alice', 'avatar_url': 'https://p.example/a.jpg'},
          }));
        },
      );
      final res = await adapter.connect(PlatformTier.byokApi, {'client_key': 'ck123', 'client_secret': 'sekrit'}, ctx);

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.origin + auth.path, 'https://www.tiktok.com/v2/auth/authorize/');
      final q = auth.queryParameters;
      expect(q['client_key'], 'ck123');
      expect(q.containsKey('client_id'), isFalse);
      expect(q['response_type'], 'code');
      expect(q['scope'], 'user.info.basic,video.publish,video.upload');
      expect(q['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(q['code_challenge_method'], 'S256');

      expect(calls, hasLength(2));
      final tokenReq = calls[0];
      expect(tokenReq.method, 'POST');
      expect(tokenReq.url.toString(), 'https://open.tiktokapis.com/v2/oauth/token/');
      expect(tokenReq.headers['content-type'], contains('application/x-www-form-urlencoded'));
      final form = bodyOf(tokenReq);
      expect(form['client_key'], 'ck123');
      expect(form['client_secret'], 'sekrit');
      expect(form['code'], 'code*1');
      expect(form['grant_type'], 'authorization_code');
      expect(form['redirect_uri'], 'http://127.0.0.1:52771/callback');
      // challenge = hex(sha256(verifier))
      final verifier = form['code_verifier'] as String;
      expect(q['code_challenge'], sha256.convert(ascii.encode(verifier)).toString());
      expect(q['code_challenge'], matches(RegExp(r'^[0-9a-f]{64}$')));

      final userReq = calls[1];
      expect(userReq.method, 'GET');
      expect(userReq.url.toString(), 'https://open.tiktokapis.com/v2/user/info/?fields=open_id,display_name,avatar_url');
      expect(userReq.headers['authorization'], 'Bearer act.new');

      expect(res.account.displayName, 'Alice');
      expect(res.account.avatarUrl, 'https://p.example/a.jpg');
      expect(res.account.config, {'clientKey': 'ck123', 'openId': 'open-1'});
      expect(res.secrets['access_token'], 'act.new');
      expect(res.secrets['refresh_token'], 'rft.new');
      expect(res.secrets['client_secret'], 'sekrit');
      expect(res.secrets['expires_at'], '2026-10-08T12:00:00.000Z');
      expect(res.secrets['refresh_expires_at'], '2027-10-07T12:00:00.000Z');
    });

    test('byokApi rejects custom-scheme redirects (mobile)', () async {
      final ctx = testContext(
          broker: FakeAuthBroker(redirect: Uri.parse('neforum://callback')),
          handler: (r) async => throw StateError('no HTTP'));
      expect(adapter.connect(PlatformTier.byokApi, {'client_key': 'a', 'client_secret': 'b'}, ctx),
          throwsA(isA<ConnectException>()));
    });

    test('token error surfaces as ConnectException', () async {
      final ctx = testContext(
          broker: FakeAuthBroker(),
          handler: (r) async => _json(
              {'error': 'invalid_client', 'error_description': 'Client key does not match', 'log_id': 'x'}, 400));
      expect(
          adapter.connect(PlatformTier.byokApi, {'client_key': 'a', 'client_secret': 'b'}, ctx),
          throwsA(isA<ConnectException>()
              .having((e) => e.message, 'message', contains('invalid_client'))));
    });

    test('missing fields', () {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP'));
      expect(adapter.connect(PlatformTier.byokApi, {'client_key': ' '}, ctx), throwsA(isA<ConnectException>()));
    });
  });

  group('refreshSecrets', () {
    test('returns null while the token is fresh', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP'));
      expect(await adapter.refreshSecrets(_byok(), _secrets, ctx), isNull);
    });

    test('refreshes an expired token with client_key/client_secret', () async {
      final calls = <http.Request>[];
      final ctx = testContext(
        now: DateTime.utc(2026, 10, 8, 12),
        handler: (r) async {
          calls.add(r);
          return _json({
            'access_token': 'act.2',
            'expires_in': 86400,
            'refresh_token': 'rft.2',
            'refresh_expires_in': 31536000,
            'open_id': 'open-1',
            'token_type': 'Bearer',
          });
        },
      );
      final s = await adapter.refreshSecrets(_byok(), _secrets, ctx);
      expect(calls.single.url.toString(), 'https://open.tiktokapis.com/v2/oauth/token/');
      expect(bodyOf(calls.single), {
        'client_key': 'ck123',
        'client_secret': 'sekrit',
        'grant_type': 'refresh_token',
        'refresh_token': 'rft.456',
      });
      expect(s!['access_token'], 'act.2');
      expect(s['refresh_token'], 'rft.2');
      expect(s['client_secret'], 'sekrit');
      expect(s['expires_at'], '2026-10-09T12:00:00.000Z');
    });

    test('invalid_grant -> auth', () async {
      final ctx = testContext(
          now: DateTime.utc(2026, 10, 9),
          handler: (r) async => _json({'error': 'invalid_grant', 'error_description': 'expired'}, 400));
      expect(
          adapter.refreshSecrets(_byok(), _secrets, ctx),
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
    });

    test('expired refresh token -> auth without a request', () async {
      final ctx = testContext(now: DateTime.utc(2028), handler: (r) async => throw StateError('no HTTP'));
      expect(
          adapter.refreshSecrets(_byok(), _secrets, ctx),
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
    });
  });

  group('validate', () {
    List<String> codes(PostVariant v, [ConnectedAccount? a]) =>
        adapter.validate(v, a ?? _byok()).map((i) => i.code).toList();

    test('needs media', () {
      expect(codes(const PostVariant(text: 'hello')), contains('media.required'));
    });

    test('caption limit 2200 UTF-16', () {
      expect(codes(PostVariant(text: 'a' * 2201, media: [fakeVideo()])), contains('text.too_long'));
      expect(codes(PostVariant(text: 'a' * 2200, media: [fakeVideo()])), isNot(contains('text.too_long')));
    });

    test('GIF/PNG photos rejected, photo host warning, private-only info', () {
      final c = codes(PostVariant(text: 'x', media: [fakeImage(mimeType: 'image/png')]));
      expect(c, containsAll(['media.image_type', 'tiktok.photo_needs_host', 'tiktok.private_only']));
    });

    test('bad privacy and branded private', () {
      expect(codes(PostVariant(text: 'x', media: [fakeVideo()], extra: const {'privacyLevel': 'FRIENDS'})),
          contains('tiktok.privacy_invalid'));
      expect(codes(PostVariant(text: 'x', media: [fakeVideo()], extra: const {'brandContent': true})),
          contains('tiktok.branded_private'));
    });

    test('one video only, no mixing', () {
      expect(codes(PostVariant(text: 'x', media: [fakeVideo(), fakeVideo(id: 'v2')])),
          contains('media.too_many_videos'));
      expect(codes(PostVariant(text: 'x', media: [fakeVideo(), fakeImage()])), contains('media.mixed'));
    });

    test('handoff accounts skip API-only checks', () {
      final c = codes(PostVariant(text: 'x', media: [fakeImage()]), fakeAccount('tiktok', tier: PlatformTier.handoff));
      expect(c, isNot(contains('tiktok.photo_needs_host')));
    });
  });

  group('publish video', () {
    test('creator_info -> init -> PUT -> status poll', () async {
      final calls = <http.Request>[];
      var polls = 0;
      final bytes = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final ctx = testContext(
        mediaBytes: bytes,
        handler: (r) async {
          calls.add(r);
          switch (r.url.path) {
            case '/v2/post/publish/creator_info/query/':
              return _json(_creatorInfo);
            case '/v2/post/publish/video/init/':
              return _json(_ok({'publish_id': 'v_pub_file~1', 'upload_url': 'https://open-upload.tiktokapis.com/upload/?id=1'}));
            case '/upload/':
              return http.Response('', 201);
            case '/v2/post/publish/status/fetch/':
              polls++;
              return _json(_ok(polls == 1
                  ? {'status': 'PROCESSING_UPLOAD'}
                  : {'status': 'PUBLISH_COMPLETE', 'publicaly_available_post_id': [7123456789]}));
          }
          return http.Response('not found', 404);
        },
      );
      final res = await adapter.publish(
        PostVariant(text: 'Hello #tiktok', media: [fakeVideo()], extra: const {'allowComments': true}),
        _byok(),
        _secrets,
        ctx,
      );
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, '7123456789');
      expect(res.remoteUrl, 'https://www.tiktok.com/@alice/video/7123456789');

      expect(calls.map((c) => '${c.method} ${c.url.path}'), [
        'POST /v2/post/publish/creator_info/query/',
        'POST /v2/post/publish/video/init/',
        'PUT /upload/',
        'POST /v2/post/publish/status/fetch/',
        'POST /v2/post/publish/status/fetch/',
      ]);
      expect(calls[0].headers['authorization'], 'Bearer act.123');
      expect(calls[0].headers['content-type'], contains('application/json'));

      final init = bodyOf(calls[1]);
      expect(init['post_info'], {
        'title': 'Hello #tiktok',
        'privacy_level': 'SELF_ONLY',
        'disable_duet': true,
        'disable_comment': false,
        'disable_stitch': true,
        'brand_content_toggle': false,
        'brand_organic_toggle': false,
      });
      expect(init['source_info'], {'source': 'FILE_UPLOAD', 'video_size': 1000, 'chunk_size': 1000, 'total_chunk_count': 1});

      final put = calls[2];
      expect(put.url.toString(), 'https://open-upload.tiktokapis.com/upload/?id=1');
      expect(put.headers['content-range'], 'bytes 0-999/1000');
      expect(put.headers['content-type'], 'video/mp4');
      expect(put.bodyBytes, bytes);
      expect(put.headers.containsKey('authorization'), isFalse);

      expect(bodyOf(calls[3]), {'publish_id': 'v_pub_file~1'});
    });

    test('large video is uploaded in ordered chunks', () async {
      final ranges = <String>[];
      final sizes = <int>[];
      final bytes = Uint8List(70000000);
      final ctx = testContext(
        mediaBytes: bytes,
        handler: (r) async {
          switch (r.url.path) {
            case '/v2/post/publish/creator_info/query/':
              return _json(_creatorInfo);
            case '/v2/post/publish/video/init/':
              final si = bodyOf(r)['source_info'] as Map;
              expect(si['video_size'], 70000000);
              expect(si['chunk_size'], 16777216);
              expect(si['total_chunk_count'], 4);
              return _json(_ok({'publish_id': 'p', 'upload_url': 'https://open-upload.tiktokapis.com/upload/?id=2'}));
            case '/upload/':
              ranges.add(r.headers['content-range']!);
              sizes.add(r.bodyBytes.length);
              return http.Response('', ranges.length == 4 ? 201 : 206);
          }
          return _json(_ok({'status': 'PUBLISH_COMPLETE', 'publicaly_available_post_id': <int>[]}));
        },
      );
      final res = await adapter.publish(
          PostVariant(text: 'big', media: [fakeVideo(sizeBytes: 70000000)]), _byok(), _secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, 'p');
      expect(ranges, [
        'bytes 0-16777215/70000000',
        'bytes 16777216-33554431/70000000',
        'bytes 33554432-50331647/70000000',
        'bytes 50331648-69999999/70000000',
      ]);
      expect(sizes, [16777216, 16777216, 16777216, 19668352]);
    });

    test('draft mode uses inbox init without post_info or creator_info', () async {
      final paths = <String>[];
      Map<String, dynamic>? initBody;
      final ctx = testContext(handler: (r) async {
        paths.add(r.url.path);
        if (r.url.path == '/v2/post/publish/inbox/video/init/') {
          initBody = bodyOf(r);
          return _json(_ok({'publish_id': 'd1', 'upload_url': 'https://open-upload.tiktokapis.com/upload/?id=3'}));
        }
        if (r.url.path == '/upload/') return http.Response('', 201);
        return _json(_ok({'status': 'SEND_TO_USER_INBOX'}));
      });
      final res = await adapter.publish(
          PostVariant(text: 'x', media: [fakeVideo()], extra: const {'postMode': 'draft'}), _byok(), _secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(paths.first, '/v2/post/publish/inbox/video/init/');
      expect(initBody!.containsKey('post_info'), isFalse);
      expect((initBody!['source_info'] as Map)['source'], 'FILE_UPLOAD');
    });

    test('privacy not offered by creator_info -> validation, no init', () async {
      final paths = <String>[];
      final ctx = testContext(handler: (r) async {
        paths.add(r.url.path);
        return _json(_creatorInfo);
      });
      final res = await adapter.publish(
          PostVariant(text: 'x', media: [fakeVideo()], extra: const {'privacyLevel': 'FOLLOWER_OF_CREATOR'}),
          _byok(),
          _secrets,
          ctx);
      expect(res.error!.kind, PublishErrorKind.validation);
      expect(paths, ['/v2/post/publish/creator_info/query/']);
    });

    test('video longer than the creator max -> validation', () async {
      final ctx = testContext(handler: (r) async => _json(_creatorInfo));
      final res = await adapter.publish(
          PostVariant(text: 'x', media: [fakeVideo(durationMs: 301000)]), _byok(), _secrets, ctx);
      expect(res.error!.kind, PublishErrorKind.validation);
    });

    test('FAILED status maps fail_reason', () async {
      final ctx = testContext(handler: (r) async {
        switch (r.url.path) {
          case '/v2/post/publish/creator_info/query/':
            return _json(_creatorInfo);
          case '/v2/post/publish/video/init/':
            return _json(_ok({'publish_id': 'p', 'upload_url': 'https://open-upload.tiktokapis.com/upload/'}));
          case '/upload/':
            return http.Response('', 201);
        }
        return _json(_ok({'status': 'FAILED', 'fail_reason': 'frame_rate_check_failed'}));
      });
      final res = await adapter.publish(PostVariant(text: 'x', media: [fakeVideo()]), _byok(), _secrets, ctx);
      expect(res.error!.kind, PublishErrorKind.validation);
      expect(res.error!.message, contains('frame_rate_check_failed'));
    });

    test('still processing after maxPolls -> submitted with publish_id', () async {
      final ctx = testContext(handler: (r) async {
        switch (r.url.path) {
          case '/v2/post/publish/creator_info/query/':
            return _json(_creatorInfo);
          case '/v2/post/publish/video/init/':
            return _json(_ok({'publish_id': 'slow', 'upload_url': 'https://open-upload.tiktokapis.com/upload/'}));
          case '/upload/':
            return http.Response('', 201);
        }
        return _json(_ok({'status': 'PROCESSING_UPLOAD'}));
      });
      final res = await adapter.publish(PostVariant(text: 'x', media: [fakeVideo()]), _byok(), _secrets, ctx);
      expect(res.success, isTrue);
      expect(res.remoteId, 'slow');
    });
  });

  group('publish photos', () {
    test('without a media host -> unsupported, no request', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP expected'));
      final res = await adapter.publish(PostVariant(text: 'x', media: [fakeImage()]), _byok(), _secrets, ctx);
      expect(res.error!.kind, PublishErrorKind.unsupported);
    });

    test('PULL_FROM_URL via media host, then cleanup', () async {
      final host = FakeMediaHost();
      final calls = <http.Request>[];
      final ctx = testContext(
        mediaHost: host,
        handler: (r) async {
          calls.add(r);
          switch (r.url.path) {
            case '/v2/post/publish/creator_info/query/':
              return _json(_creatorInfo);
            case '/v2/post/publish/content/init/':
              return _json(_ok({'publish_id': 'p_pub~1'}));
          }
          return _json(_ok({'status': 'PUBLISH_COMPLETE', 'publicaly_available_post_id': [99]}));
        },
      );
      final res = await adapter.publish(
        PostVariant(
          text: 'Two pics',
          title: 'Weekend',
          media: [fakeImage(), fakeImage(id: 'img2')],
          extra: const {'privacyLevel': 'PUBLIC_TO_EVERYONE', 'photoCoverIndex': 1},
        ),
        _byok(),
        _secrets,
        ctx,
      );
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteUrl, 'https://www.tiktok.com/@alice/photo/99');
      expect(host.uploaded.map((m) => m.id), ['img1', 'img2']);
      expect(host.deleted, hasLength(2));
      expect(calls.map((c) => c.url.path), [
        '/v2/post/publish/creator_info/query/',
        '/v2/post/publish/content/init/',
        '/v2/post/publish/status/fetch/',
      ]);
      final body = bodyOf(calls[1]);
      expect(body['post_mode'], 'DIRECT_POST');
      expect(body['media_type'], 'PHOTO');
      expect(body['source_info'], {
        'source': 'PULL_FROM_URL',
        'photo_cover_index': 1,
        'photo_images': ['https://cdn.example.test/img1', 'https://cdn.example.test/img2'],
      });
      expect(body['post_info'], {
        'title': 'Weekend',
        'description': 'Two pics',
        'privacy_level': 'PUBLIC_TO_EVERYONE',
        'disable_comment': true,
        'auto_add_music': false,
        'brand_content_toggle': false,
        'brand_organic_toggle': false,
      });
    });
  });

  group('error mapping', () {
    Future<PublishResult> run(http.Response Function() response) {
      final ctx = testContext(handler: (r) async => response());
      return adapter.publish(PostVariant(text: 'x', media: [fakeVideo()]), _byok(), _secrets, ctx);
    }

    test('401 access_token_invalid -> auth', () async {
      final res = await run(() => _json(_err('access_token_invalid'), 401));
      expect(res.error!.kind, PublishErrorKind.auth);
      expect(res.error!.statusCode, 401);
    });

    test('429 -> quota with retryAfter', () async {
      final res = await run(() => _json(_err('rate_limit_exceeded'), 429, {...jsonHeaders, 'retry-after': '42'}));
      expect(res.error!.kind, PublishErrorKind.quota);
      expect(res.error!.retryAfter, const Duration(seconds: 42));
    });

    test('429 without header -> quota with default retryAfter', () async {
      final res = await run(() => _json(_err('rate_limit_exceeded'), 429));
      expect(res.error!.retryAfter, const Duration(minutes: 1));
    });

    test('400 invalid_param -> validation', () async {
      final res = await run(() => _json(_err('invalid_param', 'bad title'), 400));
      expect(res.error!.kind, PublishErrorKind.validation);
      expect(res.error!.message, contains('bad title'));
    });

    test('HTTP 200 with spam_risk_too_many_posts -> quota', () async {
      final res = await run(() => _json(_err('spam_risk_too_many_posts')));
      expect(res.error!.kind, PublishErrorKind.quota);
    });

    test('403 unaudited client -> configuration', () async {
      final ctx = testContext(handler: (r) async => r.url.path.contains('creator_info')
          ? _json(_creatorInfo)
          : _json(_err('unaudited_client_can_only_post_to_private_accounts'), 403));
      final res = await adapter.publish(PostVariant(text: 'x', media: [fakeVideo()]), _byok(), _secrets, ctx);
      expect(res.error!.kind, PublishErrorKind.configuration);
      expect(res.error!.message, contains('private'));
    });

    test('expired upload URL (403 on PUT) -> retryable platform error', () async {
      final ctx = testContext(handler: (r) async {
        switch (r.url.path) {
          case '/v2/post/publish/creator_info/query/':
            return _json(_creatorInfo);
          case '/v2/post/publish/video/init/':
            return _json(_ok({'publish_id': 'p', 'upload_url': 'https://open-upload.tiktokapis.com/upload/'}));
        }
        return http.Response('', 403);
      });
      final res = await adapter.publish(PostVariant(text: 'x', media: [fakeVideo()]), _byok(), _secrets, ctx);
      expect(res.error!.kind, PublishErrorKind.platform);
      expect(res.error!.retryable, isTrue);
    });

    test('500 -> network', () async {
      final res = await run(() => http.Response('oops', 500));
      expect(res.error!.kind, PublishErrorKind.network);
    });

    test('network exception -> network', () async {
      final ctx = testContext(handler: (r) async => throw http.ClientException('connection reset'));
      final res = await adapter.publish(PostVariant(text: 'x', media: [fakeVideo()]), _byok(), _secrets, ctx);
      expect(res.error!.kind, PublishErrorKind.network);
    });

    test('missing token -> auth; handoff tier -> unsupported', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP'));
      final a = await adapter.publish(PostVariant(text: 'x', media: [fakeVideo()]), _byok(), const {}, ctx);
      expect(a.error!.kind, PublishErrorKind.auth);
      final b = await adapter.publish(PostVariant(text: 'x', media: [fakeVideo()]),
          fakeAccount('tiktok', tier: PlatformTier.handoff), const {}, ctx);
      expect(b.error!.kind, PublishErrorKind.unsupported);
    });
  });

  group('handoff', () {
    test('share sheet with caption on clipboard', () {
      final v = PostVariant(text: 'My caption #fyp', media: [fakeVideo()]);
      final plan = adapter.buildHandoff(v)!;
      expect(plan.platformId, 'tiktok');
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.webIntent, isNull);
      expect(plan.clipboardText, 'My caption #fyp');
      expect(plan.shareText, 'My caption #fyp');
      expect(plan.shareFiles, v.media);
      expect(plan.androidPackage, 'com.zhiliaoapp.musically');
      expect(plan.iosScheme, 'snssdk1233://');
      expect(plan.desktopUrl, 'https://www.tiktok.com/tiktokstudio/upload');
      expect(plan.instructions, startsWith('1. '));
      expect(plan.mediaNote, contains('clipboard'));
    });

    test('no media -> manual', () {
      expect(adapter.buildHandoff(const PostVariant(text: 'x'))!.preferred, HandoffMethod.manual);
    });
  });
}
