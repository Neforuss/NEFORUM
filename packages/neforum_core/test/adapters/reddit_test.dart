import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/reddit/reddit_adapter.dart';
import 'package:neforum_core/src/adapters/reddit/reddit_media.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

const _ua = 'cross-platform:org.neforum.app:v0.1.0 (by /u/alice)';
final _basicEmptySecret = 'Basic ${base64Encode(utf8.encode('cid-123:'))}';

ConnectedAccount _apiAccount({Map<String, dynamic>? config}) => ConnectedAccount(
      id: 'reddit-t2abc',
      platformId: 'reddit',
      tier: PlatformTier.byokApi,
      displayName: 'u/alice',
      handle: 'u/alice',
      createdAt: testNow,
      config: config ?? const {'clientId': 'cid-123', 'username': 'alice', 'userId': 'abc', 'defaultSubreddit': 'test'},
    );

Map<String, String> _secrets({DateTime? expiresAt, String? refresh = 'rt-1'}) => {
      'access_token': 'at-1',
      if (refresh != null) 'refresh_token': refresh,
      'expires_at': (expiresAt ?? testNow.add(const Duration(hours: 1))).toUtc().toIso8601String(),
      'token_type': 'bearer',
    };

Map<String, Object?> _submitOk(String id, {String sr = 'test'}) => {
      'json': {
        'errors': <Object>[],
        'data': {'url': 'https://www.reddit.com/r/$sr/comments/$id/hello/', 'id': id, 'name': 't3_$id', 'drafts_count': 0},
      },
    };

Map<String, Object?> _lease(String key, {bool video = false}) => {
      'args': {
        'action': video ? '//reddit-uploaded-video.s3-accelerate.amazonaws.com' : '//reddit-uploaded-media.s3-accelerate.amazonaws.com',
        'fields': [
          {'name': 'acl', 'value': 'private'},
          {'name': 'key', 'value': key},
          {'name': 'X-Amz-Credential', 'value': 'cred'},
          {'name': 'policy', 'value': 'pol'},
          {'name': 'X-Amz-Signature', 'value': 'sig'},
          {'name': 'success_action_status', 'value': '201'},
        ],
      },
      'asset': {
        'asset_id': 'asset-$key',
        'processing_state': 'incomplete',
        'payload': {'filepath': 'x'},
        'websocket_url': 'wss://ws.example.test/asset-$key',
      },
    };

http.Response _s3Created(String key) => http.Response(
    '<?xml version="1.0" encoding="UTF-8"?><PostResponse><Location>https://example/$key</Location><Key>$key</Key></PostResponse>',
    201,
    headers: {'content-type': 'application/xml'});

/// Names of the multipart parts in body order.
List<String> _partOrder(http.Request r) =>
    RegExp(r'(?<!file)name="([^"]+)"').allMatches(utf8.decode(r.bodyBytes, allowMalformed: true)).map((m) => m.group(1)!).toList();

PostVariant _variant({
  String text = 'Hello **Reddit**',
  String? title = 'Hello world',
  String? link,
  List<MediaAttachment> media = const [],
  Map<String, dynamic> extra = const {},
  bool sensitive = false,
  String? contentWarning,
}) =>
    PostVariant(
      text: text,
      title: title,
      link: link,
      media: media,
      extra: extra,
      sensitive: sensitive,
      contentWarning: contentWarning,
    );

void main() {
  final adapter = RedditAdapter(socketReader: (url, timeout) async => null);

  group('descriptor', () {
    final d = adapter.descriptor;

    test('limits match the research', () {
      expect(d.id, 'reddit');
      expect(d.tiers, {PlatformTier.byokApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.byokApi);
      expect(d.text.maxLength, 40000);
      expect(d.text.titleMax, 300);
      expect(d.text.titleRequired, isTrue);
      expect(d.text.titleSupported, isTrue);
      expect(d.text.supportsThreads, isFalse);
      expect(d.text.supportsMarkdown, isTrue);
      expect(d.text.supportsHashtags, isFalse);
      expect(d.text.linkInText, isFalse);
      expect(d.media.maxImages, 20);
      expect(d.media.maxVideos, 1);
      expect(d.media.allowsMixedImageVideo, isFalse);
      expect(d.media.imageMaxBytes, 20 * 1024 * 1024);
      expect(d.media.imageMimeTypes, {'image/jpeg', 'image/png', 'image/gif'});
      expect(d.media.videoMimeTypes, {'video/mp4', 'video/quicktime'});
      expect(d.media.supportsAltText, isFalse);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.supportsLinkField, isTrue);
      expect(d.serverSideScheduling, isFalse);
      expect(d.personalAccountOk, isTrue);
      expect(d.setupGuide, 'docs/platforms/reddit.md');
    });

    test('quota: 100 requests per minute per client id', () {
      final q = d.defaultQuotas.single;
      expect(q.id, 'reddit.requests_per_minute');
      expect(q.limit, 100);
      expect(q.window, const Duration(minutes: 1));
      expect(q.appliesToTier, PlatformTier.byokApi);
    });

    test('summary is honest about the approval requirement', () {
      expect(d.accountRequirements, contains('November 2025'));
      expect(d.apiCostSummary, contains('free'));
    });

    test('connect specs', () {
      final api = adapter.specFor(PlatformTier.byokApi);
      expect(api.usesBrowser, isTrue);
      expect(api.loopbackRedirectOk, isTrue);
      expect(api.customSchemeRedirectOk, isTrue);
      expect(api.intro, contains('https://www.reddit.com/prefs/apps'));
      expect(api.intro, contains('installed app'));
      expect(api.intro, contains('http://127.0.0.1:52771/callback'));
      expect(api.intro, contains('neforum://callback'));
      expect(api.intro, contains('Responsible Builder Policy'));
      expect(api.fields.map((f) => f.key), ['client_id', 'default_subreddit']);
      expect(api.fields.every((f) => !f.secret), isTrue);
      // The openApi tier is accepted as an alias.
      expect(adapter.specFor(PlatformTier.openApi).tier, PlatformTier.byokApi);
      expect(adapter.specFor(PlatformTier.handoff).usesBrowser, isFalse);
    });

    test('user agent follows the API rules', () {
      expect(RedditAdapter.userAgent(username: 'alice'), _ua);
      expect(RedditAdapter.userAgent(username: 'bob', platform: 'android'), 'android:org.neforum.app:v0.1.0 (by /u/bob)');
      expect(RedditAdapter.userAgent(), 'cross-platform:org.neforum.app:v0.1.0');
    });
  });

  group('connect', () {
    test('installed app: Basic auth with empty secret, no PKCE, duration=permanent, User-Agent', () async {
      final calls = <http.Request>[];
      final broker = FakeAuthBroker();
      final ctx = testContext(
        broker: broker,
        handler: (req) async {
          calls.add(req);
          if (req.url.path == '/api/v1/access_token') {
            return _json({
              'access_token': 'at-1',
              'token_type': 'bearer',
              'expires_in': 3600,
              'scope': 'identity submit read mysubreddits flair',
              'refresh_token': 'rt-1',
            });
          }
          return _json({'name': 'alice', 'id': 'abc', 'icon_img': 'https://styles.redditmedia.com/a.png?w=256&amp;s=1'});
        },
      );

      final result = await adapter.connect(PlatformTier.byokApi, {'client_id': ' cid-123 ', 'default_subreddit': 'r/test'}, ctx);

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.scheme, 'https');
      expect(auth.host, 'www.reddit.com');
      expect(auth.path, '/api/v1/authorize');
      expect(auth.queryParameters['client_id'], 'cid-123');
      expect(auth.queryParameters['response_type'], 'code');
      expect(auth.queryParameters['duration'], 'permanent');
      expect(auth.queryParameters['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(auth.queryParameters['scope'], 'identity submit read mysubreddits flair');
      expect(auth.queryParameters['state'], isNotEmpty);
      expect(auth.queryParameters.containsKey('code_challenge'), isFalse);

      expect(calls, hasLength(2));
      final token = calls[0];
      expect(token.method, 'POST');
      expect(token.url.toString(), 'https://www.reddit.com/api/v1/access_token');
      expect(token.headers['Authorization'], _basicEmptySecret);
      expect(token.headers['User-Agent'], 'cross-platform:org.neforum.app:v0.1.0');
      expect(bodyOf(token), {
        'grant_type': 'authorization_code',
        'code': 'test-code',
        'redirect_uri': 'http://127.0.0.1:52771/callback',
      });

      final me = calls[1];
      expect(me.method, 'GET');
      expect(me.url.toString(), 'https://oauth.reddit.com/api/v1/me');
      expect(me.headers['Authorization'], 'bearer at-1');
      expect(me.headers['User-Agent'], startsWith('cross-platform:org.neforum.app:v0.1.0'));

      final a = result.account;
      expect(a.id, 'reddit-abc');
      expect(a.tier, PlatformTier.byokApi);
      expect(a.displayName, 'u/alice');
      expect(a.profileUrl, 'https://www.reddit.com/user/alice');
      expect(a.avatarUrl, 'https://styles.redditmedia.com/a.png?w=256&s=1');
      expect(a.config, {'clientId': 'cid-123', 'username': 'alice', 'userId': 'abc', 'defaultSubreddit': 'test'});
      expect(result.secrets['access_token'], 'at-1');
      expect(result.secrets['refresh_token'], 'rt-1');
      expect(result.secrets['expires_at'], testNow.add(const Duration(hours: 1)).toIso8601String());
    });

    test('phones use the compact consent page and neforum://callback', () async {
      final broker = FakeAuthBroker(redirect: Uri.parse('neforum://callback'));
      final ctx = testContext(
        broker: broker,
        handler: (req) async => req.url.path == '/api/v1/access_token'
            ? _json({'access_token': 'at', 'token_type': 'bearer', 'expires_in': 3600, 'refresh_token': 'rt'})
            : _json({'name': 'alice', 'id': 'abc'}),
      );
      await adapter.connect(PlatformTier.openApi, {'client_id': 'cid-123'}, ctx);
      expect(broker.lastAuthorizationUrl!.path, '/api/v1/authorize.compact');
      expect(broker.lastAuthorizationUrl!.queryParameters['redirect_uri'], 'neforum://callback');
    });

    test('bad client id becomes a readable ConnectException', () async {
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (req) async => http.Response('{"message": "Unauthorized", "error": 401}', 401, headers: jsonHeaders),
      );
      expect(
        () => adapter.connect(PlatformTier.byokApi, {'client_id': 'nope'}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('installed app'))),
      );
    });

    test('missing client id and bad subreddit are refused', () async {
      final ctx = testContext(broker: FakeAuthBroker(), handler: (req) async => _json({}));
      expect(() => adapter.connect(PlatformTier.byokApi, {}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'client_id')));
      expect(() => adapter.connect(PlatformTier.byokApi, {'client_id': 'x', 'default_subreddit': 'no spaces!'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'default_subreddit')));
    });

    test('hand-off needs nothing', () async {
      final ctx = testContext(handler: (req) async => fail('no HTTP expected'));
      final r = await adapter.connect(PlatformTier.handoff, {'username': 'u/alice', 'default_subreddit': 'u/alice'}, ctx);
      expect(r.account.tier, PlatformTier.handoff);
      expect(r.account.displayName, 'u/alice (hand-off)');
      expect(r.account.config['defaultSubreddit'], 'u_alice');
      expect(r.secrets, isEmpty);
    });
  });

  group('validate', () {
    final account = _apiAccount();
    List<String> codes(PostVariant v, [ConnectedAccount? a]) => adapter.validate(v, a ?? account).map((i) => i.code).toList();

    test('a plain text post with the default subreddit is fine', () {
      expect(adapter.validate(_variant(), account).where((i) => i.severity == IssueSeverity.error), isEmpty);
    });

    test('subreddit is required for API posts', () {
      final noDefault = _apiAccount(config: const {'clientId': 'cid-123', 'username': 'alice'});
      expect(codes(_variant(), noDefault), contains('reddit.subreddit_required'));
      expect(codes(_variant(extra: {'subreddit': 'r/pics'}), noDefault), isNot(contains('reddit.subreddit_required')));
      expect(codes(_variant(extra: {'subreddit': 'bad name'})), contains('reddit.subreddit_invalid'));
    });

    test('title is required and limited to 300', () {
      expect(codes(_variant(title: null)), contains('title.required'));
      expect(codes(_variant(title: 'x' * 301)), contains('title.too_long'));
    });

    test('media rules: no WebP, no mixing, body becomes a comment on media posts', () {
      expect(codes(_variant(media: [fakeImage(mimeType: 'image/webp')])), contains('media.image_type'));
      expect(codes(_variant(media: [fakeImage(), fakeVideo()])), contains('media.mixed'));
      final img = codes(_variant(media: [fakeImage()], link: 'https://example.com'));
      expect(img, containsAll(['reddit.body_as_comment', 'reddit.link_in_body']));
      expect(codes(_variant(media: [fakeVideo()])), contains('reddit.video_poster'));
      expect(codes(_variant(link: 'https://example.com', text: 'x' * 10001)), contains('reddit.comment_too_long'));
      expect(codes(_variant(link: 'https://example.com', extra: {'bodyAsComment': false})), contains('reddit.body_dropped'));
    });

    test('flair limits', () {
      expect(codes(_variant(extra: {'flairId': 'x' * 37})), contains('reddit.flair_id'));
      expect(codes(_variant(extra: {'flairText': 'x' * 65})), contains('reddit.flair_text'));
    });
  });

  group('publish', () {
    test('self post: form fields and User-Agent', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        return _json(_submitOk('abc123'));
      });
      final r = await adapter.publish(
        _variant(sensitive: true, contentWarning: 'plot', extra: {'flairId': 'f1', 'sendReplies': false}),
        _apiAccount(),
        _secrets(),
        ctx,
      );
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, 'abc123');
      expect(r.remoteUrl, 'https://www.reddit.com/r/test/comments/abc123/hello/');
      final req = calls.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), 'https://oauth.reddit.com/api/submit');
      expect(req.headers['Authorization'], 'bearer at-1');
      expect(req.headers['User-Agent'], _ua);
      expect(bodyOf(req), {
        'api_type': 'json',
        'sr': 'test',
        'title': 'Hello world',
        'nsfw': 'true',
        'spoiler': 'true',
        'sendreplies': 'false',
        'resubmit': 'true',
        'validate_on_submit': 'true',
        'flair_id': 'f1',
        'kind': 'self',
        'text': 'Hello **Reddit**',
      });
    });

    test('link post, then the body as the first comment', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        if (req.url.path == '/api/comment') {
          return _json({
            'json': {
              'errors': <Object>[],
              'data': {
                'things': [
                  {'kind': 't1', 'data': {'id': 'c1'}},
                ],
              },
            },
          });
        }
        return _json(_submitOk('lnk1', sr: 'pics'));
      });
      final r = await adapter.publish(
          _variant(link: 'https://example.com/a', extra: {'subreddit': '/r/pics/'}), _apiAccount(), _secrets(), ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, 'lnk1');
      expect(calls.map((c) => c.url.path), ['/api/submit', '/api/comment']);
      final submit = bodyOf(calls[0]);
      expect(submit['kind'], 'link');
      expect(submit['sr'], 'pics');
      expect(submit['url'], 'https://example.com/a');
      expect(submit.containsKey('text'), isFalse);
      expect(bodyOf(calls[1]), {'api_type': 'json', 'thing_id': 't3_lnk1', 'text': 'Hello **Reddit**'});
    });

    test('image post: lease, S3 upload with fields in order and file last, submit kind=image, websocket', () async {
      final calls = <http.Request>[];
      Uri? socketUrl;
      final withSocket = RedditAdapter(socketReader: (url, timeout) async {
        socketUrl = url;
        return jsonEncode({
          'type': 'success',
          'payload': {'redirect': 'https://www.reddit.com/r/test/comments/img9/hello_world/'},
        });
      });
      final progress = <String>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        if (req.url.path == '/api/media/asset.json') return _json(_lease('k1'));
        if (req.url.host.contains('s3-accelerate')) return _s3Created('k1');
        return _json({
          'json': {
            'errors': <Object>[],
            'data': {'user_submitted_page': 'https://www.reddit.com/user/alice/submitted/', 'websocket_url': 'wss://ws.example.test/post'},
          },
        });
      }).copyWith(onProgress: progress.add);

      final r = await withSocket.publish(_variant(text: '', media: [fakeImage()]), _apiAccount(), _secrets(), ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, 'img9');
      expect(r.remoteUrl, 'https://www.reddit.com/r/test/comments/img9/hello_world/');
      expect(socketUrl.toString(), 'wss://ws.example.test/post');
      expect(calls, hasLength(3));

      final lease = calls[0];
      expect(lease.method, 'POST');
      expect(lease.url.toString(), 'https://oauth.reddit.com/api/media/asset.json');
      expect(lease.headers['User-Agent'], _ua);
      expect(bodyOf(lease), {'filepath': 'img1.jpg', 'mimetype': 'image/jpeg'});

      final s3 = calls[1];
      expect(s3.method, 'POST');
      expect(s3.url.toString(), 'https://reddit-uploaded-media.s3-accelerate.amazonaws.com');
      expect(s3.headers.containsKey('Authorization'), isFalse);
      expect(_partOrder(s3), ['acl', 'key', 'X-Amz-Credential', 'policy', 'X-Amz-Signature', 'success_action_status', 'file']);
      expect(multipartFieldsOf(s3)['key'], 'k1');
      expect(multipartFieldsOf(s3)['file'], '<img1.jpg>');

      final submit = bodyOf(calls[2]);
      expect(calls[2].url.toString(), 'https://oauth.reddit.com/api/submit');
      expect(submit['kind'], 'image');
      expect(submit['url'], 'https://reddit-uploaded-media.s3-accelerate.amazonaws.com/k1');
      expect(progress, containsAll(['Uploading image 1 of 1', 'Waiting for Reddit to process the media']));
    });

    test('image post without a websocket answer still succeeds (probably posted)', () async {
      final ctx = testContext(handler: (req) async {
        if (req.url.path == '/api/media/asset.json') return _json(_lease('k1'));
        if (req.url.host.contains('s3-accelerate')) return _s3Created('k1');
        return _json({
          'json': {
            'errors': <Object>[],
            'data': {'user_submitted_page': 'https://www.reddit.com/user/alice/submitted/', 'websocket_url': 'wss://x/y'},
          },
        });
      });
      final failing = RedditAdapter(socketReader: (url, timeout) async => throw const FormatException('socket down'));
      final r = await failing.publish(_variant(media: [fakeImage()]), _apiAccount(), _secrets(), ctx);
      expect(r.success, isTrue);
      expect(r.remoteId, isNull);
      expect(r.remoteUrl, 'https://www.reddit.com/user/alice/submitted/');
    });

    test('media processing failure is reported', () async {
      final ctx = testContext(handler: (req) async {
        if (req.url.path == '/api/media/asset.json') return _json(_lease('k1'));
        if (req.url.host.contains('s3-accelerate')) return _s3Created('k1');
        return _json({
          'json': {
            'errors': <Object>[],
            'data': {'websocket_url': 'wss://x/y'},
          },
        });
      });
      final failed = RedditAdapter(socketReader: (url, timeout) async => '{"type":"failed","payload":{"message":"bad"}}');
      final r = await failed.publish(_variant(media: [fakeImage()]), _apiAccount(), _secrets(), ctx);
      expect(r.error!.kind, PublishErrorKind.validation);
      expect(r.error!.message, contains('could not process'));
    });

    test('gallery: two uploads, then JSON to submit_gallery_post.json with media ids', () async {
      final calls = <http.Request>[];
      var leaseNo = 0;
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        if (req.url.path == '/api/media/asset.json') return _json(_lease('g${++leaseNo}'));
        if (req.url.host.contains('s3-accelerate')) return _s3Created('g$leaseNo');
        return _json(_submitOk('gal1'));
      });
      final r = await adapter.publish(
          _variant(media: [fakeImage(id: 'a'), fakeImage(id: 'b', mimeType: 'image/png')]), _apiAccount(), _secrets(), ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, 'gal1');
      expect(calls.map((c) => '${c.method} ${c.url.host}${c.url.path}'), [
        'POST oauth.reddit.com/api/media/asset.json',
        'POST reddit-uploaded-media.s3-accelerate.amazonaws.com',
        'POST oauth.reddit.com/api/media/asset.json',
        'POST reddit-uploaded-media.s3-accelerate.amazonaws.com',
        'POST oauth.reddit.com/api/submit_gallery_post.json',
      ]);
      expect(bodyOf(calls[2]), {'filepath': 'b.png', 'mimetype': 'image/png'});
      final body = bodyOf(calls[4]);
      expect(calls[4].headers['content-type'], contains('application/json'));
      expect(body['api_type'], 'json');
      expect(body['sr'], 'test');
      expect(body['title'], 'Hello world');
      expect(body['text'], 'Hello **Reddit**');
      expect(body['nsfw'], false);
      expect(body['sendreplies'], true);
      expect(body['items'], [
        {'media_id': 'asset-g1', 'caption': '', 'outbound_url': ''},
        {'media_id': 'asset-g2', 'caption': '', 'outbound_url': ''},
      ]);
    });

    test('video: video lease + poster lease, submit kind=video with video_poster_url', () async {
      final calls = <http.Request>[];
      var leaseNo = 0;
      final withSocket = RedditAdapter(
        socketReader: (url, timeout) async =>
            '{"type":"success","payload":{"redirect":"https://www.reddit.com/r/test/comments/vid7/x/"}}',
      );
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        if (req.url.path == '/api/media/asset.json') {
          leaseNo++;
          return _json(_lease('v$leaseNo', video: bodyOf(req)['mimetype'] == 'video/mp4'));
        }
        if (req.url.host.contains('s3-accelerate')) return _s3Created('v$leaseNo');
        if (req.url.path == '/api/comment') return _json({'json': {'errors': <Object>[]}});
        return _json({
          'json': {
            'errors': <Object>[],
            'data': {'websocket_url': 'wss://ws.example.test/v'},
          },
        });
      });
      final r = await withSocket.publish(_variant(media: [fakeVideo()]), _apiAccount(), _secrets(), ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, 'vid7');
      expect(bodyOf(calls[0]), {'filepath': 'vid1.mp4', 'mimetype': 'video/mp4'});
      expect(calls[1].url.host, 'reddit-uploaded-video.s3-accelerate.amazonaws.com');
      expect(bodyOf(calls[2]), {'filepath': 'poster.png', 'mimetype': 'image/png'});
      expect(calls[3].url.host, 'reddit-uploaded-media.s3-accelerate.amazonaws.com');
      final submit = bodyOf(calls[4]);
      expect(submit['kind'], 'video');
      expect(submit['url'], 'https://reddit-uploaded-video.s3-accelerate.amazonaws.com/v1');
      expect(submit['video_poster_url'], 'https://reddit-uploaded-media.s3-accelerate.amazonaws.com/v2');
      expect(calls[5].url.path, '/api/comment');
      expect(bodyOf(calls[5])['thing_id'], 't3_vid7');
    });

    test('S3 EntityTooLarge -> validation', () async {
      final ctx = testContext(handler: (req) async {
        if (req.url.path == '/api/media/asset.json') return _json(_lease('k1'));
        return http.Response(
            '<Error><Code>EntityTooLarge</Code><Message>Your proposed upload exceeds the maximum allowed size</Message>'
            '<ProposedSize>30000000</ProposedSize><MaxSizeAllowed>20971520</MaxSizeAllowed></Error>',
            400);
      });
      final r = await adapter.publish(_variant(media: [fakeImage()]), _apiAccount(), _secrets(), ctx);
      expect(r.error!.kind, PublishErrorKind.validation);
      expect(r.error!.message, contains('20 MB'));
    });
  });

  group('error mapping', () {
    Future<PublishResult> run(http.Response res, {PostVariant? v}) => adapter.publish(
        v ?? _variant(), _apiAccount(), _secrets(), testContext(handler: (req) async => res));

    test('401 -> auth', () async {
      final r = await run(http.Response('{"message": "Unauthorized", "error": 401}', 401, headers: jsonHeaders));
      expect(r.error!.kind, PublishErrorKind.auth);
      expect(r.error!.statusCode, 401);
    });

    test('429 -> quota with retryAfter from X-Ratelimit-Reset', () async {
      final r = await run(http.Response('Too Many Requests', 429, headers: {'x-ratelimit-reset': '42', 'x-ratelimit-remaining': '0'}));
      expect(r.error!.kind, PublishErrorKind.quota);
      expect(r.error!.retryAfter, const Duration(seconds: 42));
    });

    test('json RATELIMIT -> quota with retryAfter from the message', () async {
      final r = await run(_json({
        'json': {
          'errors': [
            ['RATELIMIT', 'you are doing that too much. try again in 9 minutes.', 'ratelimit'],
          ],
        },
      }));
      expect(r.error!.kind, PublishErrorKind.quota);
      expect(r.error!.retryAfter, const Duration(minutes: 9));
    });

    test('json RATELIMIT with ratelimit seconds', () async {
      final r = await run(_json({
        'json': {
          'ratelimit': 61.5,
          'errors': [
            ['RATELIMIT', 'Take a break', 'ratelimit'],
          ],
        },
      }));
      expect(r.error!.retryAfter, const Duration(seconds: 62));
    });

    test('subreddit and content errors -> validation', () async {
      for (final code in ['SUBREDDIT_NOEXIST', 'SUBREDDIT_NOTALLOWED', 'NO_SELFS', 'TOO_LONG', 'SUBMIT_VALIDATION_FLAIR_REQUIRED']) {
        final r = await run(_json({
          'json': {
            'errors': [
              [code, 'nope', 'sr'],
            ],
          },
        }));
        expect(r.error!.kind, PublishErrorKind.validation, reason: code);
        expect(r.error!.message, contains('nope'));
      }
    });

    test('CAPTCHA -> platform, USER_REQUIRED -> auth', () async {
      final captcha = await run(_json({
        'json': {
          'errors': [
            ['BAD_CAPTCHA', 'care to try these again?', 'captcha'],
          ],
        },
      }));
      expect(captcha.error!.kind, PublishErrorKind.platform);
      final user = await run(_json({
        'json': {
          'errors': [
            ['USER_REQUIRED', 'Please log in to do that.', null],
          ],
        },
      }));
      expect(user.error!.kind, PublishErrorKind.auth);
    });

    test('400 -> validation, 503 -> network', () async {
      expect((await run(http.Response('{"message":"Bad Request"}', 400, headers: jsonHeaders))).error!.kind,
          PublishErrorKind.validation);
      expect((await run(http.Response('busy', 503))).error!.kind, PublishErrorKind.network);
    });

    test('no subreddit / no title / hand-off account / no tokens', () async {
      final ctx = testContext(handler: (req) async => fail('no HTTP expected'));
      final noSr = await adapter.publish(_variant(), _apiAccount(config: const {'clientId': 'c'}), _secrets(), ctx);
      expect(noSr.error!.kind, PublishErrorKind.validation);
      final noTitle = await adapter.publish(_variant(title: ' '), _apiAccount(), _secrets(), ctx);
      expect(noTitle.error!.kind, PublishErrorKind.validation);
      final handoff = await adapter.publish(_variant(), fakeAccount('reddit', tier: PlatformTier.handoff), const {}, ctx);
      expect(handoff.error!.kind, PublishErrorKind.unsupported);
      final noTokens = await adapter.publish(_variant(), _apiAccount(), const {}, ctx);
      expect(noTokens.error!.kind, PublishErrorKind.auth);
    });
  });

  group('refreshSecrets / disconnect', () {
    test('valid token: nothing to do', () async {
      final ctx = testContext(handler: (req) async => fail('no HTTP expected'));
      expect(await adapter.refreshSecrets(_apiAccount(), _secrets(), ctx), isNull);
    });

    test('expired token: refresh with Basic auth, keep the refresh token', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        return _json({'access_token': 'at-2', 'token_type': 'bearer', 'expires_in': 3600, 'scope': 'identity submit'});
      });
      final fresh = await adapter.refreshSecrets(
          _apiAccount(), _secrets(expiresAt: testNow.subtract(const Duration(minutes: 1))), ctx);
      expect(fresh!['access_token'], 'at-2');
      expect(fresh['refresh_token'], 'rt-1');
      expect(fresh['expires_at'], testNow.add(const Duration(hours: 1)).toIso8601String());
      final req = calls.single;
      expect(req.url.toString(), 'https://www.reddit.com/api/v1/access_token');
      expect(req.headers['Authorization'], _basicEmptySecret);
      expect(req.headers['User-Agent'], _ua);
      expect(bodyOf(req), {'grant_type': 'refresh_token', 'refresh_token': 'rt-1'});
    });

    test('revoked refresh token -> auth', () async {
      final ctx = testContext(handler: (req) async => _json({'error': 'invalid_grant'}, 400));
      expect(
        () => adapter.refreshSecrets(_apiAccount(), _secrets(expiresAt: testNow.subtract(const Duration(hours: 2))), ctx),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)),
      );
    });

    test('disconnect revokes the refresh token', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        return http.Response('', 204);
      });
      await adapter.disconnect(_apiAccount(), _secrets(), ctx);
      expect(calls.single.url.toString(), 'https://www.reddit.com/api/v1/revoke_token');
      expect(calls.single.headers['Authorization'], _basicEmptySecret);
      expect(bodyOf(calls.single), {'token': 'rt-1', 'token_type_hint': 'refresh_token'});
    });
  });

  group('hand-off', () {
    test('text post to the default subreddit', () {
      final plan = adapter.buildHandoff(_variant(), account: _apiAccount())!;
      expect(plan.webIntent.toString(), 'https://www.reddit.com/r/test/submit?title=Hello+world&text=Hello+%2A%2AReddit%2A%2A');
      expect(plan.webIntent!.queryParameters, {'title': 'Hello world', 'text': 'Hello **Reddit**'});
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.clipboardText, 'Hello **Reddit**');
      expect(plan.androidPackage, 'com.reddit.frontpage');
      expect(plan.desktopUrl, plan.webIntent.toString());
      expect(plan.instructions, startsWith('1. '));
    });

    test('link post without a subreddit uses /submit?url=', () {
      final plan = adapter.buildHandoff(_variant(link: 'https://example.com/a'))!;
      expect(plan.webIntent!.path, '/submit');
      expect(plan.webIntent!.queryParameters, {'title': 'Hello world', 'url': 'https://example.com/a'});
      expect(plan.instructions, contains('Choose the community'));
    });

    test('media goes through the share sheet', () {
      final plan = adapter.buildHandoff(_variant(media: [fakeImage()], extra: {'subreddit': 'pics'}))!;
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.shareFiles, hasLength(1));
      expect(plan.mediaNote, isNotNull);
      expect(plan.webIntent!.path, '/r/pics/submit');
    });
  });

  test('placeholder poster is a valid 320x180 RGB PNG', () {
    final png = placeholderPosterPng();
    expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    final bd = ByteData.sublistView(png);
    expect(ascii.decode(png.sublist(12, 16)), 'IHDR');
    expect(bd.getUint32(16), 320);
    expect(bd.getUint32(20), 180);
    final idatLen = bd.getUint32(33);
    expect(ascii.decode(png.sublist(37, 41)), 'IDAT');
    final raw = ZLibCodec().decode(png.sublist(41, 41 + idatLen));
    expect(raw.length, 180 * (1 + 320 * 3));
    expect(ascii.decode(png.sublist(png.length - 8, png.length - 4)), 'IEND');
  });
}
