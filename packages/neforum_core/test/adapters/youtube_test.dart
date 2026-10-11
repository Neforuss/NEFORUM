import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/youtube/youtube_adapter.dart';
import 'package:neforum_core/src/adapters/youtube/youtube_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200, Map<String, String> headers = jsonHeaders]) =>
    http.Response(jsonEncode(body), status, headers: headers);

http.Response _googleError(int status, String reason, [String message = 'error', Map<String, String> extra = const {}]) =>
    _json({
      'error': {
        'code': status,
        'message': message,
        'errors': [
          {'message': message, 'domain': 'youtube', 'reason': reason},
        ],
      },
    }, status, {...jsonHeaders, ...extra});

const _initUrl = 'https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status';
const _sessionUrl = 'https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&upload_id=SESSION1';

const _secrets = {
  'access_token': 'ya29.token',
  'refresh_token': '1//refresh',
  'expires_at': '2026-10-07T13:00:00.000Z',
  'token_type': 'Bearer',
  'client_secret': 'GOCSPX-secret',
};

ConnectedAccount _byok() => fakeAccount('youtube',
    tier: PlatformTier.byokApi,
    config: {'clientId': '123-abc.apps.googleusercontent.com', 'channelId': 'UC123'});

Map<String, dynamic> _videoResource({String privacy = 'public', String upload = 'uploaded'}) => {
      'kind': 'youtube#video',
      'id': 'dQw4w9WgXcQ',
      'snippet': {'title': 'My video'},
      'status': {'uploadStatus': upload, 'privacyStatus': privacy},
    };

PostVariant _variant({
  String text = 'Line one of the description\nMore text',
  String? title = 'My video',
  List<String> tags = const ['travel', 'new york'],
  List<MediaAttachment>? media,
  Map<String, dynamic> extra = const {},
  DateTime? scheduledAt,
  Visibility visibility = Visibility.public,
}) =>
    PostVariant(
      text: text,
      title: title,
      tags: tags,
      media: media ?? [fakeVideo()],
      extra: extra,
      scheduledAt: scheduledAt,
      visibility: visibility,
      language: 'en',
    );

final _videoBytes = Uint8List.fromList(List.generate(100, (i) => i));

void main() {
  final adapter = YouTubeAdapter(resumeDelay: Duration.zero);

  group('descriptor', () {
    test('limits match the YouTube Data API docs', () {
      final d = adapter.descriptor;
      expect(d.id, 'youtube');
      expect(d.tiers, {PlatformTier.byokApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.byokApi);
      expect(d.text.maxLength, 5000);
      expect(d.text.counting, CountingRule.utf8Bytes);
      expect(d.text.titleMax, 100);
      expect(d.text.titleRequired, isTrue);
      expect(d.text.titleSupported, isTrue);
      expect(d.text.hashtagsAsField, isTrue);
      expect(d.text.supportsThreads, isFalse);
      expect(d.text.linkInText, isTrue);
      expect(d.media.maxImages, 0);
      expect(d.media.maxVideos, 1);
      expect(d.media.requiresMedia, isTrue);
      expect(d.media.videoMaxBytes, 256 * 1024 * 1024 * 1024);
      expect(d.media.videoMaxSeconds, 12 * 3600);
      expect(d.media.videoMimeTypes, containsAll(['video/mp4', 'video/quicktime', 'video/webm']));
      expect(d.media.supportsAltText, isFalse);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.personalAccountOk, isTrue);
      expect(d.serverSideScheduling, isTrue);
      expect(d.supportsLinkField, isFalse);
      expect(d.setupGuide, 'docs/platforms/youtube.md');
      expect(d.apiCostSummary, contains('PRIVATE'));
      final q = d.defaultQuotas.single;
      expect(q.id, 'youtube.uploads_per_day');
      expect(q.limit, 100);
      expect(q.window, const Duration(days: 1));
      expect(q.appliesToTier, PlatformTier.byokApi);
    });

    test('connect specs', () {
      final byok = adapter.specFor(PlatformTier.byokApi);
      expect(byok.usesBrowser, isTrue);
      expect(byok.loopbackRedirectOk, isTrue);
      expect(byok.customSchemeRedirectOk, isFalse);
      expect(byok.fields.map((f) => f.key), ['client_id', 'client_secret']);
      expect(byok.fields.last.secret, isTrue);
      expect(byok.intro, contains('Desktop app'));
      expect(byok.intro, contains('http://127.0.0.1:52771/callback'));
      expect(byok.intro, contains('youtube.upload'));
      final handoff = adapter.specFor(PlatformTier.handoff);
      expect(handoff.usesBrowser, isFalse);
    });
  });

  group('helpers', () {
    test('tag length counts commas and quotes', () {
      expect(youtubeTagsLength(['Foo-Baz']), 7);
      expect(youtubeTagsLength(['Foo Baz']), 9);
      expect(youtubeTagsLength(['a', 'b c']), 1 + 1 + 5);
      expect(cleanTags(['#Travel', 'travel', '<x>', ' ']), ['Travel', 'x']);
    });

    test('upload offset from Range header', () {
      expect(parseUploadedOffset(null), 0);
      expect(parseUploadedOffset('bytes=0-524287'), 524288);
    });

    test('quota resets at midnight Pacific', () {
      // 2026-10-07 12:00 UTC = 05:00 PDT -> midnight PDT is 07:00 UTC next day.
      expect(untilPacificMidnight(testNow), const Duration(hours: 19));
      // January: PST (UTC-8). 2026-01-10 20:00 UTC = 12:00 PST -> 12 hours.
      expect(untilPacificMidnight(DateTime.utc(2026, 1, 10, 20)), const Duration(hours: 12));
    });

    test('rfc3339 drops milliseconds', () {
      expect(rfc3339(DateTime.utc(2026, 10, 8, 15, 0, 0, 123)), '2026-10-08T15:00:00Z');
    });
  });

  group('connect', () {
    test('handoff needs nothing', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP expected'));
      final res = await adapter.connect(PlatformTier.handoff, {'display_name': 'My channel'}, ctx);
      expect(res.account.tier, PlatformTier.handoff);
      expect(res.account.displayName, 'My channel');
      expect(res.secrets, isEmpty);
    });

    test('byokApi: PKCE authorize URL, token exchange, channel lookup', () async {
      final calls = <http.Request>[];
      final broker = FakeAuthBroker(code: '4/abc');
      final ctx = testContext(
        broker: broker,
        handler: (r) async {
          calls.add(r);
          if (r.url.host == 'oauth2.googleapis.com') {
            return _json({
              'access_token': 'ya29.new',
              'expires_in': 3599,
              'refresh_token': '1//new-refresh',
              'scope': 'https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly',
              'token_type': 'Bearer',
            });
          }
          return _json({
            'items': [
              {
                'id': 'UC123',
                'snippet': {
                  'title': 'Alice Films',
                  'customUrl': '@alicefilms',
                  'thumbnails': {
                    'default': {'url': 'https://yt3.example/a.jpg'},
                  },
                },
              },
            ],
          });
        },
      );
      final res = await adapter.connect(PlatformTier.byokApi,
          {'client_id': '123-abc.apps.googleusercontent.com', 'client_secret': 'GOCSPX-secret'}, ctx);

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.origin + auth.path, 'https://accounts.google.com/o/oauth2/v2/auth');
      final q = auth.queryParameters;
      expect(q['client_id'], '123-abc.apps.googleusercontent.com');
      expect(q['response_type'], 'code');
      expect(q['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(q['scope'],
          'https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly');
      expect(q['access_type'], 'offline');
      expect(q['prompt'], 'consent');
      expect(q['code_challenge_method'], 'S256');
      expect(q['code_challenge'], isNotEmpty);
      expect(q['state'], isNotEmpty);

      expect(calls, hasLength(2));
      final token = calls[0];
      expect(token.method, 'POST');
      expect(token.url.toString(), 'https://oauth2.googleapis.com/token');
      final form = bodyOf(token);
      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], '4/abc');
      expect(form['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(form['client_id'], '123-abc.apps.googleusercontent.com');
      expect(form['client_secret'], 'GOCSPX-secret');
      expect((form['code_verifier'] as String).length, greaterThanOrEqualTo(43));

      final channel = calls[1];
      expect(channel.method, 'GET');
      expect(channel.url.toString(), 'https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true');
      expect(channel.headers['authorization'], 'Bearer ya29.new');

      final a = res.account;
      expect(a.id, 'youtube:UC123');
      expect(a.platformId, 'youtube');
      expect(a.displayName, 'Alice Films');
      expect(a.handle, '@alicefilms');
      expect(a.avatarUrl, 'https://yt3.example/a.jpg');
      expect(a.profileUrl, 'https://www.youtube.com/channel/UC123');
      expect(a.config['clientId'], '123-abc.apps.googleusercontent.com');
      expect(a.config['channelId'], 'UC123');
      expect(res.secrets['access_token'], 'ya29.new');
      expect(res.secrets['refresh_token'], '1//new-refresh');
      expect(res.secrets['client_secret'], 'GOCSPX-secret');
      expect(res.secrets['expires_at'], testNow.add(const Duration(seconds: 3599)).toIso8601String());
    });

    test('rejects a malformed client id', () {
      final ctx = testContext(broker: FakeAuthBroker(), handler: (r) async => throw StateError('no HTTP'));
      expect(adapter.connect(PlatformTier.byokApi, {'client_id': 'abc'}, ctx), throwsA(isA<ConnectException>()));
    });

    test('rejects non-loopback redirects', () {
      final ctx = testContext(
          broker: FakeAuthBroker(redirect: Uri.parse('neforum://callback')),
          handler: (r) async => throw StateError('no HTTP'));
      expect(adapter.connect(PlatformTier.byokApi, {'client_id': '1-a.apps.googleusercontent.com'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('127.0.0.1'))));
    });

    test('fails when the upload scope was not granted', () {
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (r) async => _json({
          'access_token': 'ya29.new',
          'expires_in': 3599,
          'scope': 'https://www.googleapis.com/auth/youtube.readonly',
          'token_type': 'Bearer',
        }),
      );
      expect(adapter.connect(PlatformTier.byokApi, {'client_id': '1-a.apps.googleusercontent.com'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('upload permission'))));
    });

    test('fails when the account has no channel', () {
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (r) async => r.url.host == 'oauth2.googleapis.com'
            ? _json({'access_token': 'ya29.new', 'expires_in': 3599, 'token_type': 'Bearer'})
            : _json({'items': <Object>[]}),
      );
      expect(adapter.connect(PlatformTier.byokApi, {'client_id': '1-a.apps.googleusercontent.com'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('create_channel'))));
    });
  });

  group('validate', () {
    test('a valid video post passes (apart from the private-lock info)', () {
      final issues = adapter.validate(_variant(), _byok());
      expect(issues.hasErrors, isFalse);
      expect(issues.map((i) => i.code), contains('youtube.unaudited_private'));
    });

    test('needs a video and a title', () {
      final issues = adapter.validate(_variant(title: null, media: [fakeImage()]), _byok());
      final codes = issues.map((i) => i.code);
      expect(codes, containsAll(['youtube.video_required', 'title.required', 'media.too_many_images']));
      final none = adapter.validate(_variant(media: const []), _byok()).map((i) => i.code);
      expect(none, contains('media.required'));
    });

    test('title and description limits', () {
      final longTitle = adapter.validate(_variant(title: 'x' * 101), _byok());
      expect(longTitle.map((i) => i.code), contains('title.too_long'));
      // 2000 three-byte characters = 6000 bytes > 5000.
      final longDesc = adapter.validate(_variant(text: '€' * 2000), _byok());
      expect(longDesc.map((i) => i.code), contains('text.too_long'));
      final angle = adapter.validate(_variant(title: 'a <b>', text: 'x > y'), _byok()).map((i) => i.code);
      expect(angle, containsAll(['youtube.title_angle_brackets', 'youtube.description_angle_brackets']));
    });

    test('tags over 500 characters', () {
      final tags = List.generate(60, (i) => 'tag$i-abcd');
      final issues = adapter.validate(_variant(tags: tags), _byok());
      expect(issues.map((i) => i.code), contains('youtube.tags_too_long'));
    });

    test('unknown privacy status', () {
      final issues = adapter.validate(_variant(extra: {'privacyStatus': 'friends'}), _byok());
      expect(issues.map((i) => i.code), contains('youtube.privacy_invalid'));
    });
  });

  group('publish', () {
    test('resumable upload: session POST then bytes PUT', () async {
      final calls = <http.Request>[];
      final ctx = testContext(
        mediaBytes: _videoBytes,
        handler: (r) async {
          calls.add(r);
          if (r.method == 'POST') return http.Response('', 200, headers: {'location': _sessionUrl});
          return _json(_videoResource(), 201);
        },
      );
      final res = await adapter.publish(_variant(extra: {'categoryId': 22, 'notifySubscribers': true}), _byok(), _secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, 'dQw4w9WgXcQ');
      expect(res.remoteUrl, 'https://youtu.be/dQw4w9WgXcQ');

      expect(calls, hasLength(2));
      final init = calls[0];
      expect(init.method, 'POST');
      expect(init.url.toString(), _initUrl);
      expect(init.headers['authorization'], 'Bearer ya29.token');
      expect(init.headers['content-type'], startsWith('application/json'));
      expect(init.headers['x-upload-content-length'], '100');
      expect(init.headers['x-upload-content-type'], 'video/mp4');
      final body = bodyOf(init);
      final snippet = body['snippet'] as Map;
      expect(snippet['title'], 'My video');
      expect(snippet['description'], 'Line one of the description\nMore text');
      expect(snippet['tags'], ['travel', 'new york']);
      expect(snippet['categoryId'], '22');
      expect(snippet['defaultLanguage'], 'en');
      final status = body['status'] as Map;
      expect(status['privacyStatus'], 'public');
      expect(status['selfDeclaredMadeForKids'], false);
      expect(status.containsKey('publishAt'), isFalse);

      final put = calls[1];
      expect(put.method, 'PUT');
      expect(put.url.toString(), _sessionUrl);
      expect(put.headers['authorization'], 'Bearer ya29.token');
      expect(put.headers['content-type'], 'video/mp4');
      expect(put.headers.containsKey('content-range'), isFalse);
      expect(put.bodyBytes, _videoBytes);
    });

    test('scheduled upload is private with publishAt; notifySubscribers=false', () async {
      final calls = <http.Request>[];
      final ctx = testContext(
        mediaBytes: _videoBytes,
        handler: (r) async {
          calls.add(r);
          if (r.method == 'POST') return http.Response('', 200, headers: {'location': _sessionUrl});
          return _json(_videoResource(privacy: 'private'), 201);
        },
      );
      final when = DateTime.utc(2026, 10, 8, 15);
      final res = await adapter.publish(
          _variant(scheduledAt: when, extra: {'notifySubscribers': false, 'madeForKids': false}), _byok(), _secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.publishedAt, when);
      expect(calls[0].url.toString(), '$_initUrl&notifySubscribers=false');
      final status = bodyOf(calls[0])['status'] as Map;
      expect(status['privacyStatus'], 'private');
      expect(status['publishAt'], '2026-10-08T15:00:00Z');
    });

    test('derives the title from the first line and sanitizes < >', () async {
      final calls = <http.Request>[];
      final ctx = testContext(
        mediaBytes: _videoBytes,
        handler: (r) async {
          calls.add(r);
          if (r.method == 'POST') return http.Response('', 200, headers: {'location': _sessionUrl});
          return _json(_videoResource(), 201);
        },
      );
      final res = await adapter.publish(_variant(title: null, text: '\nI <3 NYC\nsecond'), _byok(), _secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      final snippet = bodyOf(calls[0])['snippet'] as Map;
      expect(snippet['title'], 'I ‹3 NYC');
      expect(snippet['description'], '\nI ‹3 NYC\nsecond');
    });

    test('resumes after an interrupted PUT (308 + Range)', () async {
      final calls = <http.Request>[];
      var puts = 0;
      final ctx = testContext(
        mediaBytes: _videoBytes,
        handler: (r) async {
          calls.add(r);
          if (r.method == 'POST') return http.Response('', 200, headers: {'location': _sessionUrl});
          puts++;
          if (puts == 1) return http.Response('backend error', 503);
          if (puts == 2) return http.Response('', 308, headers: {'range': 'bytes=0-29'});
          return _json(_videoResource(), 200);
        },
      );
      final res = await adapter.publish(_variant(), _byok(), _secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls, hasLength(4));
      final probe = calls[2];
      expect(probe.method, 'PUT');
      expect(probe.headers['content-range'], 'bytes */100');
      expect(probe.bodyBytes, isEmpty);
      final rest = calls[3];
      expect(rest.headers['content-range'], 'bytes 30-99/100');
      expect(rest.bodyBytes, _videoBytes.sublist(30));
    });

    test('expired upload session is not resumed', () async {
      var puts = 0;
      final ctx = testContext(
        mediaBytes: _videoBytes,
        handler: (r) async {
          if (r.method == 'POST') return http.Response('', 200, headers: {'location': _sessionUrl});
          puts++;
          return http.Response('Not Found', 404);
        },
      );
      final res = await adapter.publish(_variant(), _byok(), _secrets, ctx);
      expect(res.success, isFalse);
      expect(res.error!.kind, PublishErrorKind.platform);
      expect(res.error!.retryable, isTrue);
      expect(puts, 1);
    });

    test('rejected upload maps to validation', () async {
      final ctx = testContext(
        mediaBytes: _videoBytes,
        handler: (r) async {
          if (r.method == 'POST') return http.Response('', 200, headers: {'location': _sessionUrl});
          final v = _videoResource(upload: 'rejected');
          (v['status'] as Map)['rejectionReason'] = 'duplicate';
          return _json(v, 201);
        },
      );
      final res = await adapter.publish(_variant(), _byok(), _secrets, ctx);
      expect(res.error!.kind, PublishErrorKind.validation);
      expect(res.error!.message, contains('duplicate'));
    });

    test('handoff accounts cannot publish via API', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP'));
      final res = await adapter.publish(_variant(), fakeAccount('youtube', tier: PlatformTier.handoff), _secrets, ctx);
      expect(res.error!.kind, PublishErrorKind.unsupported);
    });

    test('no video -> validation without HTTP', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP'));
      final res = await adapter.publish(_variant(media: const []), _byok(), _secrets, ctx);
      expect(res.error!.kind, PublishErrorKind.validation);
    });
  });

  group('error mapping', () {
    Future<PublishResult> publishWith(http.Response init) {
      final ctx = testContext(mediaBytes: _videoBytes, handler: (r) async => init);
      return adapter.publish(_variant(), _byok(), _secrets, ctx);
    }

    test('401 -> auth', () async {
      final res = await publishWith(_googleError(401, 'authError', 'Invalid Credentials'));
      expect(res.error!.kind, PublishErrorKind.auth);
      expect(res.error!.statusCode, 401);
    });

    test('403 quotaExceeded -> quota until midnight Pacific', () async {
      final res = await publishWith(_googleError(403, 'quotaExceeded', 'The request cannot be completed'));
      expect(res.error!.kind, PublishErrorKind.quota);
      expect(res.error!.retryAfter, const Duration(hours: 19));
    });

    test('429 -> quota with Retry-After', () async {
      final res = await publishWith(_googleError(429, 'rateLimitExceeded', 'slow down', {'retry-after': '30'}));
      expect(res.error!.kind, PublishErrorKind.quota);
      expect(res.error!.retryAfter, const Duration(seconds: 30));
    });

    test('400 uploadLimitExceeded -> quota', () async {
      final res = await publishWith(_googleError(400, 'uploadLimitExceeded'));
      expect(res.error!.kind, PublishErrorKind.quota);
    });

    test('400 invalidTitle -> validation', () async {
      final res = await publishWith(_googleError(400, 'invalidTitle', 'bad title'));
      expect(res.error!.kind, PublishErrorKind.validation);
      expect(res.error!.message, contains('invalidTitle'));
    });

    test('403 accessNotConfigured -> configuration', () async {
      final res = await publishWith(_googleError(403, 'accessNotConfigured', 'API not enabled'));
      expect(res.error!.kind, PublishErrorKind.configuration);
    });

    test('401 youtubeSignupRequired -> configuration', () async {
      final res = await publishWith(_googleError(401, 'youtubeSignupRequired'));
      expect(res.error!.kind, PublishErrorKind.configuration);
    });

    test('network failure -> network', () async {
      final ctx = testContext(handler: (r) async => throw http.ClientException('connection reset'));
      final res = await adapter.publish(_variant(), _byok(), _secrets, ctx);
      expect(res.error!.kind, PublishErrorKind.network);
    });
  });

  group('refreshSecrets', () {
    test('returns null while the token is fresh', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP'));
      final fresh = {..._secrets, 'expires_at': '2026-10-07T13:00:00.000Z'};
      expect(await adapter.refreshSecrets(_byok(), fresh, ctx), isNull);
    });

    test('refreshes an expired token and keeps the refresh token', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'access_token': 'ya29.fresh', 'expires_in': 3599, 'token_type': 'Bearer'});
      });
      final expired = {..._secrets, 'expires_at': '2026-10-07T11:00:00.000Z'};
      final out = await adapter.refreshSecrets(_byok(), expired, ctx);
      expect(calls.single.url.toString(), 'https://oauth2.googleapis.com/token');
      final form = bodyOf(calls.single);
      expect(form['grant_type'], 'refresh_token');
      expect(form['refresh_token'], '1//refresh');
      expect(form['client_id'], '123-abc.apps.googleusercontent.com');
      expect(form['client_secret'], 'GOCSPX-secret');
      expect(out!['access_token'], 'ya29.fresh');
      expect(out['refresh_token'], '1//refresh');
      expect(out['client_secret'], 'GOCSPX-secret');
      expect(out['expires_at'], testNow.add(const Duration(seconds: 3599)).toIso8601String());
    });

    test('invalid_grant -> auth (reconnect)', () async {
      final ctx = testContext(
          handler: (r) async =>
              _json({'error': 'invalid_grant', 'error_description': 'Token has been expired or revoked.'}, 400));
      final expired = {..._secrets, 'expires_at': '2026-10-07T11:00:00.000Z'};
      await expectLater(
        adapter.refreshSecrets(_byok(), expired, ctx),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)),
      );
    });

    test('missing refresh token -> auth', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no HTTP'));
      final expired = {'access_token': 'x', 'expires_at': '2026-10-07T11:00:00.000Z'};
      await expectLater(
        adapter.refreshSecrets(_byok(), expired, ctx),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)),
      );
    });
  });

  group('disconnect', () {
    test('revokes the refresh token', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return http.Response('', 200);
      });
      await adapter.disconnect(_byok(), _secrets, ctx);
      expect(calls.single.url.toString(), 'https://oauth2.googleapis.com/revoke');
      expect(bodyOf(calls.single)['token'], '1//refresh');
    });
  });

  group('handoff', () {
    test('share sheet to the YouTube app with title + description on the clipboard', () {
      final v = _variant();
      final plan = adapter.buildHandoff(v)!;
      expect(plan.platformId, 'youtube');
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.webIntent, isNull);
      expect(plan.androidPackage, 'com.google.android.youtube');
      expect(plan.iosScheme, 'youtube://');
      expect(plan.desktopUrl, 'https://www.youtube.com/upload');
      expect(plan.shareFiles, v.media);
      expect(plan.clipboardText,
          'My video\n\nLine one of the description\nMore text\n\nTags: travel, new york');
      expect(plan.instructions, startsWith('1. '));
      expect(plan.mediaNote, isNotEmpty);
    });

    test('without a video the hand-off is manual', () {
      final plan = adapter.buildHandoff(_variant(media: const []))!;
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.shareFiles, isEmpty);
    });
  });
}
