import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_adapter.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_instance.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

/// A tiny router: `'GET /api/v2/instance'` → handler. Records every request.
class FakeServer {
  FakeServer(this.routes);

  final Map<String, List<http.Response> Function(http.Request r)> routes;
  final List<http.Request> calls = [];
  final Map<String, int> _hits = {};

  Future<http.Response> handle(http.Request r) async {
    calls.add(r);
    final key = '${r.method} ${r.url.path}';
    final route = routes[key];
    if (route == null) return http.Response('{"error":"Not found"}', 404, headers: jsonHeaders);
    final responses = route(r);
    final n = _hits.update(key, (v) => v + 1, ifAbsent: () => 0);
    return responses[n < responses.length ? n : responses.length - 1];
  }

  List<String> get trail => calls.map((c) => '${c.method} ${c.url.path}').toList();
}

http.Response j(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

List<http.Response> one(Object body, [int status = 200]) => [j(body, status)];

/// Form body with repeated keys preserved, in order.
List<MapEntry<String, String>> formPairs(http.Request r) => r.body.split('&').where((s) => s.isNotEmpty).map((s) {
  final i = s.indexOf('=');
  return MapEntry(Uri.decodeQueryComponent(s.substring(0, i)), Uri.decodeQueryComponent(s.substring(i + 1)));
}).toList();

Map<String, String> formMap(http.Request r) => {for (final e in formPairs(r)) e.key: e.value};

Map<String, dynamic> mastodonInstanceV2({int maxChars = 500, int maxMedia = 4}) => {
  'domain': 'mastodon.example',
  'title': 'Example',
  'version': '4.5.0',
  'source_url': 'https://github.com/mastodon/mastodon',
  'api_versions': {'mastodon': 6},
  'configuration': {
    'statuses': {'max_characters': maxChars, 'max_media_attachments': maxMedia, 'characters_reserved_per_url': 23},
    'media_attachments': {
      'supported_mime_types': ['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'video/mp4', 'video/webm'],
      'image_size_limit': 16777216,
      'video_size_limit': 103809024,
      'image_matrix_limit': 33177600,
      'video_matrix_limit': 8294400,
      'description_limit': 1500,
    },
  },
};

Map<String, dynamic> nodeinfoIndex(String host) => {
  'links': [
    {'rel': 'http://nodeinfo.diaspora.software/ns/schema/2.0', 'href': 'https://$host/nodeinfo/2.0'},
  ],
};

const mastodonConfig = <String, dynamic>{
  'instance': 'https://mastodon.example',
  'domain': 'mastodon.example',
  'software': 'mastodon',
  'maxCharacters': 500,
  'maxMediaAttachments': 4,
  'descriptionLimit': 1500,
  'tokenEndpoint': 'https://mastodon.example/oauth/token',
};

const tokenSecrets = <String, String>{
  'client_id': 'cid',
  'client_secret': 'csecret',
  'access_token': 'tok',
  'token_type': 'Bearer',
};

ConnectedAccount account([Map<String, dynamic> config = mastodonConfig, PlatformTier tier = PlatformTier.openApi]) =>
    fakeAccount('mastodon', config: config, tier: tier);

void main() {
  final adapter = MastodonAdapter(mediaPollInterval: Duration.zero, maxMediaPolls: 5);

  group('descriptor', () {
    test('matches the research numbers', () {
      final d = adapter.descriptor;
      expect(d.id, 'mastodon');
      expect(d.family, 'mastodon-api');
      expect(d.tiers, {PlatformTier.openApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.openApi);
      expect(d.text.maxLength, 500);
      expect(d.text.counting, CountingRule.codePointsWithUrlWeight);
      expect(d.text.urlWeight, 23);
      expect(d.text.mentionCountsDomain, isFalse);
      expect(d.text.supportsThreads, isTrue);
      expect(d.text.supportsContentWarning, isTrue);
      expect(d.text.titleSupported, isFalse);
      expect(d.media.maxImages, 4);
      expect(d.media.maxVideos, 1);
      expect(d.media.allowsMixedImageVideo, isFalse);
      expect(d.media.imageMaxBytes, 16777216);
      expect(d.media.videoMaxBytes, 103809024);
      expect(d.media.supportsAltText, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.serverSideScheduling, isTrue);
      expect(d.personalAccountOk, isTrue);
      expect(d.setupGuide, 'docs/platforms/mastodon.md');
      expect(d.defaultQuotas.map((q) => q.id), containsAll(['mastodon.requests_per_5min', 'mastodon.posts_per_day']));
      final q = d.defaultQuotas.firstWhere((q) => q.id == 'mastodon.requests_per_5min');
      expect(q.limit, 300);
      expect(q.window, const Duration(minutes: 5));
    });

    test('connect specs allow loopback and custom scheme redirects', () {
      final api = adapter.specFor(PlatformTier.openApi);
      expect(api.usesBrowser, isTrue);
      expect(api.loopbackRedirectOk, isTrue);
      expect(api.customSchemeRedirectOk, isTrue);
      expect(api.fields.first.key, 'instance');
      expect(api.fields.firstWhere((f) => f.key == 'client_secret').secret, isTrue);
      expect(adapter.specFor(PlatformTier.handoff).usesBrowser, isFalse);
    });

    test('normalizes instance input', () {
      String n(String s) => MastodonInstanceProfile.normalizeInstance(s).toString();
      expect(n('mastodon.social'), 'https://mastodon.social');
      expect(n(' https://Mastodon.Social/@me '), 'https://mastodon.social');
      expect(n('@alice@fosstodon.org'), 'https://fosstodon.org');
      expect(n('http://example.org'), 'https://example.org');
      expect(n('http://masto.localhost:3000'), 'http://masto.localhost:3000');
      expect(() => n(''), throwsFormatException);
    });
  });

  group('connect', () {
    test('Mastodon: registers app, PKCE authorize, token, verify_credentials', () async {
      final server = FakeServer({
        'GET /api/v2/instance': (_) => one(mastodonInstanceV2(maxChars: 1000)),
        'GET /.well-known/nodeinfo': (_) => one(nodeinfoIndex('mastodon.example')),
        'GET /nodeinfo/2.0': (_) => one({
          'software': {'name': 'mastodon', 'version': '4.5.0'},
        }),
        'GET /.well-known/oauth-authorization-server': (_) => one({
          'authorization_endpoint': 'https://mastodon.example/oauth/authorize',
          'token_endpoint': 'https://mastodon.example/oauth/token',
          'revocation_endpoint': 'https://mastodon.example/oauth/revoke',
          'scopes_supported': ['read', 'write', 'write:statuses', 'write:media', 'profile'],
          'code_challenge_methods_supported': ['S256'],
        }),
        'POST /api/v1/apps': (_) =>
            one({'client_id': 'cid', 'client_secret': 'csecret', 'client_secret_expires_at': 0}),
        'POST /oauth/token': (_) => one({
          'access_token': 'tok',
          'token_type': 'Bearer',
          'scope': MastodonAdapter.scopesModern,
          'created_at': 1,
        }),
        'GET /api/v1/accounts/verify_credentials': (_) => one({
          'id': '109',
          'username': 'alice',
          'acct': 'alice',
          'display_name': 'Alice',
          'avatar': 'https://mastodon.example/a.png',
          'url': 'https://mastodon.example/@alice',
        }),
      });
      final broker = FakeAuthBroker(code: 'the-code');
      final ctx = testContext(handler: server.handle, broker: broker);
      final r = await adapter.connect(PlatformTier.openApi, {'instance': 'mastodon.example'}, ctx);

      expect(server.trail, [
        'GET /api/v2/instance',
        'GET /.well-known/nodeinfo',
        'GET /nodeinfo/2.0',
        'GET /.well-known/oauth-authorization-server',
        'POST /api/v1/apps',
        'POST /oauth/token',
        'GET /api/v1/accounts/verify_credentials',
      ]);
      final apps = bodyOf(server.calls[4]);
      expect(apps['client_name'], 'NEFORUM');
      expect(apps['redirect_uris'], 'http://127.0.0.1:52771/callback');
      expect(apps['scopes'], 'write:statuses write:media profile');
      expect(apps['website'], isNotEmpty);

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.host, 'mastodon.example');
      expect(auth.path, '/oauth/authorize');
      expect(auth.queryParameters['response_type'], 'code');
      expect(auth.queryParameters['client_id'], 'cid');
      expect(auth.queryParameters['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(auth.queryParameters['scope'], 'write:statuses write:media profile');
      expect(auth.queryParameters['code_challenge_method'], 'S256');
      expect(auth.queryParameters['code_challenge'], isNotEmpty);

      final token = bodyOf(server.calls[5]);
      expect(token['grant_type'], 'authorization_code');
      expect(token['code'], 'the-code');
      expect(token['client_id'], 'cid');
      expect(token['client_secret'], 'csecret');
      expect(token['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(token['code_verifier'], isNotEmpty);
      expect(server.calls[6].headers['Authorization'], 'Bearer tok');

      expect(r.secrets['access_token'], 'tok');
      expect(r.secrets['client_id'], 'cid');
      expect(r.secrets['client_secret'], 'csecret');
      expect(r.secrets.containsKey('expires_at'), isFalse);
      final a = r.account;
      expect(a.platformId, 'mastodon');
      expect(a.handle, '@alice@mastodon.example');
      expect(a.displayName, 'Alice (mastodon.example)');
      expect(a.avatarUrl, 'https://mastodon.example/a.png');
      expect(a.profileUrl, 'https://mastodon.example/@alice');
      expect(a.config['instance'], 'https://mastodon.example');
      expect(a.config['software'], 'mastodon');
      expect(a.config['maxCharacters'], 1000);
      expect(a.config['supportedMimeTypes'], contains('video/webm'));
      expect(a.config.values.contains('tok'), isFalse, reason: 'tokens never go into config');
    });

    test('GoToSocial: umbrella scopes and no PKCE when not advertised', () async {
      final server = FakeServer({
        'GET /api/v2/instance': (_) => one({
          'domain': 'gts.example',
          'version': '0.20.1',
          'configuration': {
            'statuses': {'max_characters': 5000, 'max_media_attachments': 6},
            'media_attachments': {'image_size_limit': 41943040, 'video_size_limit': 41943040},
          },
        }),
        'GET /.well-known/nodeinfo': (_) => one(nodeinfoIndex('gts.example')),
        'GET /nodeinfo/2.0': (_) => one({
          'software': {'name': 'gotosocial', 'version': '0.20.1'},
        }),
        'POST /api/v1/apps': (_) => one({'client_id': 'gid', 'client_secret': 'gsecret'}),
        'POST /oauth/token': (_) => one({'access_token': 'gtok', 'token_type': 'Bearer'}),
        'GET /api/v1/accounts/verify_credentials': (_) => one({'id': '01ABC', 'username': 'bob'}),
      });
      final broker = FakeAuthBroker(redirect: Uri.parse('neforum://callback'));
      final r = await adapter.connect(PlatformTier.openApi, {
        'instance': 'https://gts.example',
      }, testContext(handler: server.handle, broker: broker));
      expect(bodyOf(server.calls.firstWhere((c) => c.url.path == '/api/v1/apps'))['scopes'], 'read write');
      expect(
        bodyOf(server.calls.firstWhere((c) => c.url.path == '/api/v1/apps'))['redirect_uris'],
        'neforum://callback',
      );
      expect(broker.lastAuthorizationUrl!.queryParameters.containsKey('code_challenge'), isFalse);
      expect(
        bodyOf(server.calls.firstWhere((c) => c.url.path == '/oauth/token')).containsKey('code_verifier'),
        isFalse,
      );
      expect(r.account.config['software'], 'gotosocial');
      expect(r.account.config['maxCharacters'], 5000);
      expect(r.account.config['maxMediaAttachments'], 6);
      expect(r.account.handle, '@bob@gts.example');
    });

    test('Pleroma: falls back to /api/v1/instance and detects software from version', () async {
      final server = FakeServer({
        'GET /api/v1/instance': (_) => one({
          'uri': 'https://pleroma.example',
          'version': '2.7.2 (compatible; Pleroma 2.6.0)',
          'max_toot_chars': 5000,
          'upload_limit': 16000000,
          'max_media_attachments': 10,
        }),
      });
      final r = await adapter.connect(PlatformTier.handoff, {
        'instance': 'pleroma.example',
      }, testContext(handler: server.handle));
      expect(server.trail.take(2), ['GET /api/v2/instance', 'GET /api/v1/instance']);
      final p = MastodonInstanceProfile.fromConfig(r.account.config);
      expect(p.software, 'pleroma');
      expect(p.softwareVersion, '2.6.0');
      expect(p.domain, 'pleroma.example');
      expect(p.maxCharacters, 5000);
      expect(p.imageSizeLimit, 16000000);
      expect(r.account.tier, PlatformTier.handoff);
      expect(r.secrets, isEmpty);
    });

    test('own client id skips registration', () async {
      final server = FakeServer({
        'GET /api/v2/instance': (_) => one(mastodonInstanceV2()),
        'POST /oauth/token': (_) => one({'access_token': 'tok', 'token_type': 'Bearer'}),
        'GET /api/v1/accounts/verify_credentials': (_) => one({'id': '1', 'username': 'alice'}),
      });
      final r = await adapter.connect(PlatformTier.openApi, {
        'instance': 'mastodon.example',
        'client_id': 'mine',
        'client_secret': 'mysecret',
      }, testContext(handler: server.handle, broker: FakeAuthBroker()));
      expect(server.trail.contains('POST /api/v1/apps'), isFalse);
      expect(r.secrets['client_id'], 'mine');
      expect(bodyOf(server.calls.firstWhere((c) => c.url.path == '/oauth/token'))['client_secret'], 'mysecret');
    });

    test('out-of-band pasted code is accepted without state', () async {
      final server = FakeServer({
        'GET /api/v2/instance': (_) => one(mastodonInstanceV2()),
        'POST /api/v1/apps': (_) => one({'client_id': 'cid', 'client_secret': 'cs'}),
        'POST /oauth/token': (_) => one({'access_token': 'tok', 'token_type': 'Bearer'}),
        'GET /api/v1/accounts/verify_credentials': (_) => one({'id': '1', 'username': 'alice'}),
      });
      final broker = PasteCodeAuthBroker(askUser: (url, redirect) async => 'PASTED');
      await adapter.connect(PlatformTier.openApi, {
        'instance': 'mastodon.example',
      }, testContext(handler: server.handle, broker: broker));
      expect(
        bodyOf(server.calls.firstWhere((c) => c.url.path == '/api/v1/apps'))['redirect_uris'],
        'urn:ietf:wg:oauth:2.0:oob',
      );
      final token = bodyOf(server.calls.firstWhere((c) => c.url.path == '/oauth/token'));
      expect(token['code'], 'PASTED');
      expect(token['redirect_uri'], 'urn:ietf:wg:oauth:2.0:oob');
    });

    test('registration throttled → readable ConnectException', () async {
      final server = FakeServer({
        'GET /api/v2/instance': (_) => one(mastodonInstanceV2()),
        'POST /api/v1/apps': (_) => one({'error': 'Too many requests'}, 429),
      });
      expect(
        () => adapter.connect(PlatformTier.openApi, {
          'instance': 'mastodon.example',
        }, testContext(handler: server.handle, broker: FakeAuthBroker())),
        throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('10 minutes'))),
      );
    });

    test('not a Mastodon server → ConnectException on the instance field', () async {
      final server = FakeServer({});
      expect(
        () => adapter.connect(PlatformTier.openApi, {
          'instance': 'example.org',
        }, testContext(handler: server.handle, broker: FakeAuthBroker())),
        throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'instance')),
      );
    });
  });

  group('validate', () {
    List<String> codes(PostVariant v, [Map<String, dynamic> config = mastodonConfig]) =>
        adapter.validate(v, account(config)).where((i) => i.isError).map((i) => i.code).toList();

    test('uses the instance character limit', () {
      final long = PostVariant(text: 'a' * 600);
      expect(codes(long), contains('text.too_long'));
      expect(codes(long, {...mastodonConfig, 'maxCharacters': 5000}), isEmpty);
    });

    test('links count as 23 and remote mention domains are free', () {
      final text = '${'a' * 470} https://example.org/${'x' * 100} @bob@very.long.example.social';
      expect(codes(PostVariant(text: text)), isEmpty);
    });

    test('content warning counts toward the limit', () {
      final v = PostVariant(text: 'a' * 490, contentWarning: 'spoiler here');
      expect(codes(v), contains('text.too_long_with_cw'));
    });

    test('instance media count and mixing', () {
      final five = PostVariant(
        text: 'x',
        media: [for (var i = 0; i < 5; i++) fakeImage(id: 'i$i')],
      );
      expect(codes(five), contains('media.too_many_images'));
      expect(codes(five, {...mastodonConfig, 'maxMediaAttachments': 6}), isEmpty);
      expect(codes(PostVariant(text: 'x', media: [fakeImage(), fakeVideo()])), contains('media.mixed'));
    });

    test('pixel matrix limit', () {
      final big = fakeImage(width: 10000, height: 5000);
      expect(
        codes(PostVariant(text: 'x', media: [big]), {...mastodonConfig, 'imageMatrixLimit': 33177600}),
        contains('media.too_many_pixels'),
      );
    });

    test('Pixelfed needs media, no direct posts, no scheduling, short CW', () {
      final pix = {...mastodonConfig, 'software': 'pixelfed'};
      expect(codes(const PostVariant(text: 'hello'), pix), contains('media.required'));
      expect(codes(PostVariant(text: 'hello', media: [fakeImage()]), pix), isEmpty);
      expect(
        codes(PostVariant(text: 'x', media: [fakeImage()], visibility: Visibility.private), pix),
        contains('visibility.unsupported'),
      );
      expect(
        codes(PostVariant(text: 'x', media: [fakeImage()], scheduledAt: testNow.add(const Duration(days: 1))), pix),
        contains('schedule.unsupported'),
      );
      expect(
        codes(PostVariant(text: 'x', media: [fakeImage()], contentWarning: 'c' * 141), pix),
        contains('cw.too_long'),
      );
    });

    test('server-side scheduled threads are refused', () {
      final v = PostVariant(
        text: 'a',
        threadParts: const ['a', 'b'],
        scheduledAt: testNow.add(const Duration(hours: 1)),
      );
      expect(codes(v), contains('schedule.thread'));
    });
  });

  group('publish', () {
    final img1 = fakeImage(id: 'img1', altText: 'First');
    final img2 = fakeImage(id: 'img2', altText: 'Second');

    test('uploads media (sync + async with polling) and posts with every field', () async {
      var upload = 0;
      final server = FakeServer({
        'POST /api/v2/media': (_) {
          upload++;
          return upload == 1 ? one({'id': 'm1', 'url': 'https://files/m1.jpg'}) : one({'id': 'm2', 'url': null}, 202);
        },
        'GET /api/v1/media/m2': (_) => [
          j({'id': 'm2', 'url': null}, 206),
          j({'id': 'm2', 'url': 'https://files/m2.jpg'}),
        ],
        'POST /api/v1/statuses': (_) => one({'id': '111', 'url': 'https://mastodon.example/@alice/111'}),
      });
      final progress = <String>[];
      final base = testContext(handler: server.handle);
      final ctx = AdapterContext(
        http: base.http,
        clock: base.now,
        log: base.log,
        onProgress: progress.add,
        readMedia: base.readMedia,
      );
      final v = PostVariant(
        text: 'Hello fediverse',
        media: [img1, img2],
        contentWarning: 'test',
        sensitive: true,
        visibility: Visibility.unlisted,
        language: 'en-GB',
        sourcePostId: 'post-1',
      );
      final r = await adapter.publish(v, account(), tokenSecrets, ctx);

      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, '111');
      expect(r.remoteUrl, 'https://mastodon.example/@alice/111');
      expect(server.trail, [
        'POST /api/v2/media',
        'POST /api/v2/media',
        'GET /api/v1/media/m2',
        'GET /api/v1/media/m2',
        'POST /api/v1/statuses',
      ]);
      final up = multipartFieldsOf(server.calls[0]);
      expect(up['file'], '<img1.jpg>');
      expect(up['description'], 'First');
      expect(server.calls[0].headers['Authorization'], 'Bearer tok');
      expect(multipartFieldsOf(server.calls[1])['description'], 'Second');

      final post = server.calls[4];
      expect(post.headers['Authorization'], 'Bearer tok');
      expect(post.headers['Idempotency-Key'], isNotEmpty);
      expect(post.headers['content-type'], startsWith('application/x-www-form-urlencoded'));
      final pairs = formPairs(post);
      expect(pairs.where((e) => e.key == 'media_ids[]').map((e) => e.value), ['m1', 'm2']);
      final f = formMap(post);
      expect(f['status'], 'Hello fediverse');
      expect(f['visibility'], 'unlisted');
      expect(f['spoiler_text'], 'test');
      expect(f['sensitive'], 'true');
      expect(f['language'], 'en');
      expect(f.containsKey('scheduled_at'), isFalse);
      expect(f.containsKey('in_reply_to_id'), isFalse);
      expect(progress, containsAll(['Uploading image 1 of 2', 'Uploading image 2 of 2']));
    });

    test('idempotency key is stable for the same post', () async {
      final keys = <String>[];
      for (var i = 0; i < 2; i++) {
        final server = FakeServer({
          'POST /api/v1/statuses': (_) => one({'id': '1'}),
        });
        await adapter.publish(
          const PostVariant(text: 'same', sourcePostId: 'p'),
          account(),
          tokenSecrets,
          testContext(handler: server.handle),
        );
        keys.add(server.calls.single.headers['Idempotency-Key']!);
      }
      expect(keys[0], keys[1]);
    });

    test('visibility mapping', () {
      expect(MastodonAdapter.mastodonVisibility(Visibility.public), 'public');
      expect(MastodonAdapter.mastodonVisibility(Visibility.unlisted), 'unlisted');
      expect(MastodonAdapter.mastodonVisibility(Visibility.followers), 'private');
      expect(MastodonAdapter.mastodonVisibility(Visibility.private), 'direct');
    });

    test('threads reply in order, media on the first part only', () async {
      var n = 0;
      final server = FakeServer({
        'POST /api/v2/media': (_) => one({'id': 'm1', 'url': 'u'}),
        'POST /api/v1/statuses': (_) {
          n++;
          return one({'id': 's$n', 'url': 'https://mastodon.example/@a/s$n'});
        },
      });
      final v = PostVariant(text: 'one', threadParts: const ['one', 'two', 'three'], media: [img1], sourcePostId: 'p');
      final r = await adapter.publish(v, account(), tokenSecrets, testContext(handler: server.handle));
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, 's1');
      expect(r.threadRemoteIds, ['s1', 's2', 's3']);
      final posts = server.calls.where((c) => c.url.path == '/api/v1/statuses').toList();
      expect(posts.map((p) => formMap(p)['status']), ['one', 'two', 'three']);
      expect(formPairs(posts[0]).where((e) => e.key == 'media_ids[]').map((e) => e.value), ['m1']);
      expect(formMap(posts[0]).containsKey('in_reply_to_id'), isFalse);
      expect(formPairs(posts[1]).any((e) => e.key == 'media_ids[]'), isFalse);
      expect(formMap(posts[1])['in_reply_to_id'], 's1');
      expect(formMap(posts[2])['in_reply_to_id'], 's2');
      final keys = posts.map((p) => p.headers['Idempotency-Key']).toSet();
      expect(keys.length, 3);
    });

    test('a thread that fails half-way reports what was posted', () async {
      var n = 0;
      final server = FakeServer({
        'POST /api/v1/statuses': (_) {
          n++;
          return n == 1
              ? one({'id': 's1'})
              : one({'error': 'Validation failed: Text character limit of 500 exceeded'}, 422);
        },
      });
      final v = PostVariant(text: 'one', threadParts: const ['one', 'two']);
      final r = await adapter.publish(v, account(), tokenSecrets, testContext(handler: server.handle));
      expect(r.success, isFalse);
      expect(r.error!.kind, PublishErrorKind.validation);
      expect(r.error!.message, contains('Only 1 of 2'));
      expect(r.error!.message, contains('s1'));
    });

    test('server-side scheduling sends scheduled_at and returns the scheduled id', () async {
      final at = testNow.add(const Duration(hours: 3));
      final server = FakeServer({
        'POST /api/v1/statuses': (_) => one({
          'id': '3221',
          'scheduled_at': at.toIso8601String(),
          'params': {'text': 'later'},
          'media_attachments': <Object>[],
        }),
      });
      final r = await adapter.publish(
        PostVariant(text: 'later', scheduledAt: at),
        account(),
        tokenSecrets,
        testContext(handler: server.handle),
      );
      expect(r.success, isTrue, reason: '${r.error}');
      expect(r.remoteId, 'scheduled:3221');
      expect(r.publishedAt, at);
      expect(formMap(server.calls.single)['scheduled_at'], '2026-10-07T15:00:00.000Z');
    });

    test('schedules less than 5 minutes ahead are pushed past the minimum; past ones post now', () async {
      final server = FakeServer({
        'POST /api/v1/statuses': (_) => one({'id': '1'}),
      });
      final ctx = testContext(handler: server.handle);
      await adapter.publish(
        PostVariant(text: 'soon', scheduledAt: testNow.add(const Duration(minutes: 1))),
        account(),
        tokenSecrets,
        ctx,
      );
      expect(formMap(server.calls.last)['scheduled_at'], '2026-10-07T12:05:30.000Z');
      await adapter.publish(
        PostVariant(text: 'late', scheduledAt: testNow.subtract(const Duration(minutes: 1))),
        account(),
        tokenSecrets,
        ctx,
      );
      expect(formMap(server.calls.last).containsKey('scheduled_at'), isFalse);
    });

    test('Pixelfed scheduling is refused before any request', () async {
      final server = FakeServer({});
      final r = await adapter.publish(
        PostVariant(text: 'x', media: [img1], scheduledAt: testNow.add(const Duration(days: 1))),
        account({...mastodonConfig, 'software': 'pixelfed'}),
        tokenSecrets,
        testContext(handler: server.handle),
      );
      expect(r.error!.kind, PublishErrorKind.unsupported);
      expect(server.calls, isEmpty);
    });

    test('Mitra gets content_type=text/plain', () async {
      final server = FakeServer({
        'POST /api/v1/statuses': (_) => one({'id': '1'}),
      });
      await adapter.publish(
        const PostVariant(text: '*literal*'),
        account({...mastodonConfig, 'software': 'mitra'}),
        tokenSecrets,
        testContext(handler: server.handle),
      );
      expect(formMap(server.calls.single)['content_type'], 'text/plain');
    });

    group('error mapping', () {
      Future<PublishResult> postWith(http.Response res, {PostVariant v = const PostVariant(text: 'hi')}) {
        final server = FakeServer({
          'POST /api/v1/statuses': (_) => [res],
          'POST /api/v2/media': (_) => [res],
        });
        return adapter.publish(v, account(), tokenSecrets, testContext(handler: server.handle));
      }

      test('401 → auth', () async {
        final r = await postWith(j({'error': 'The access token is invalid'}, 401));
        expect(r.error!.kind, PublishErrorKind.auth);
        expect(r.error!.message, contains('access token is invalid'));
      });

      test('429 → quota with retryAfter from X-RateLimit-Reset', () async {
        final r = await postWith(
          j(
            {'error': 'Too many requests'},
            429,
            {'x-ratelimit-reset': testNow.add(const Duration(minutes: 3)).toIso8601String()},
          ),
        );
        expect(r.error!.kind, PublishErrorKind.quota);
        expect(r.error!.retryAfter, const Duration(minutes: 3));
      });

      test('429 → quota with Retry-After header when present', () async {
        final r = await postWith(j({'error': 'Too many requests'}, 429, {'retry-after': '42'}));
        expect(r.error!.retryAfter, const Duration(seconds: 42));
      });

      test('422 → validation with the server message', () async {
        final r = await postWith(j({'error': "Validation failed: Text can't be blank"}, 422));
        expect(r.error!.kind, PublishErrorKind.validation);
        expect(r.error!.message, contains("Text can't be blank"));
      });

      test('422 scheduled limit → quota', () async {
        final r = await postWith(
          j({'error': 'Validation failed: You have exceeded the limit of 25 scheduled posts for today'}, 422),
        );
        expect(r.error!.kind, PublishErrorKind.quota);
      });

      test('Pixelfed 403 empty status → validation', () async {
        final r = await postWith(j({'error': 'Empty statuses are not allowed'}, 403));
        expect(r.error!.kind, PublishErrorKind.validation);
      });

      test('Pixelfed duplicate idempotency key → validation, not a retry loop', () async {
        final r = await postWith(j({'error': 'Duplicate idempotency key.'}, 400));
        expect(r.error!.kind, PublishErrorKind.validation);
        expect(r.error!.message, contains('already submitted'));
      });

      test('500 → network (retryable)', () async {
        final r = await postWith(http.Response('oops', 500));
        expect(r.error!.kind, PublishErrorKind.network);
        expect(r.error!.retryable, isTrue);
      });

      test('media 422 on upload → validation', () async {
        final r = await postWith(
          j({'error': 'File type of image/heic is not supported'}, 422),
          v: PostVariant(text: 'x', media: [img1]),
        );
        expect(r.error!.kind, PublishErrorKind.validation);
        expect(r.error!.message, contains('not supported'));
      });

      test('media processing failure while polling → validation', () async {
        final server = FakeServer({
          'POST /api/v2/media': (_) => one({'id': 'v1', 'url': null}, 202),
          'GET /api/v1/media/v1': (_) => one({'error': 'Error processing thumbnail'}, 422),
        });
        final r = await adapter.publish(
          PostVariant(text: 'x', media: [fakeVideo()]),
          account(),
          tokenSecrets,
          testContext(handler: server.handle),
        );
        expect(r.error!.kind, PublishErrorKind.validation);
        expect(server.trail.contains('POST /api/v1/statuses'), isFalse);
      });

      test('network exception → network', () async {
        final r = await adapter.publish(
          const PostVariant(text: 'x'),
          account(),
          tokenSecrets,
          testContext(handler: (_) async => throw http.ClientException('connection reset')),
        );
        expect(r.error!.kind, PublishErrorKind.network);
      });

      test('missing token → auth without any request', () async {
        final server = FakeServer({});
        final r = await adapter.publish(const PostVariant(text: 'x'), account(), const {
          'client_id': 'c',
        }, testContext(handler: server.handle));
        expect(r.error!.kind, PublishErrorKind.auth);
        expect(server.calls, isEmpty);
      });
    });
  });

  group('refreshSecrets', () {
    test('Mastodon tokens never expire → null, no request', () async {
      final server = FakeServer({});
      expect(await adapter.refreshSecrets(account(), tokenSecrets, testContext(handler: server.handle)), isNull);
      expect(server.calls, isEmpty);
    });

    test('Pleroma expiring token is refreshed with the client credentials', () async {
      final server = FakeServer({
        'POST /oauth/token': (_) =>
            one({'access_token': 'new', 'refresh_token': 'r2', 'expires_in': 3600, 'token_type': 'Bearer'}),
      });
      final secrets = {
        ...tokenSecrets,
        'refresh_token': 'r1',
        'expires_at': testNow.subtract(const Duration(minutes: 1)).toIso8601String(),
      };
      final out = await adapter.refreshSecrets(
        account({...mastodonConfig, 'software': 'pleroma'}),
        secrets,
        testContext(handler: server.handle),
      );
      final body = bodyOf(server.calls.single);
      expect(server.calls.single.url.toString(), 'https://mastodon.example/oauth/token');
      expect(body['grant_type'], 'refresh_token');
      expect(body['refresh_token'], 'r1');
      expect(body['client_id'], 'cid');
      expect(body['client_secret'], 'csecret');
      expect(out!['access_token'], 'new');
      expect(out['refresh_token'], 'r2');
      expect(out['client_id'], 'cid');
      expect(DateTime.parse(out['expires_at']!), testNow.add(const Duration(hours: 1)));
    });

    test('expired without refresh token → AdapterException(auth)', () async {
      final secrets = {...tokenSecrets, 'expires_at': testNow.subtract(const Duration(hours: 1)).toIso8601String()};
      expect(
        () => adapter.refreshSecrets(account(), secrets, testContext(handler: FakeServer({}).handle)),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)),
      );
    });
  });

  group('disconnect', () {
    test('revokes the token', () async {
      final server = FakeServer({'POST /oauth/revoke': (_) => one(<String, Object>{})});
      await adapter.disconnect(account(), tokenSecrets, testContext(handler: server.handle));
      final body = bodyOf(server.calls.single);
      expect(body, {'client_id': 'cid', 'client_secret': 'csecret', 'token': 'tok'});
    });
  });

  group('buildHandoff', () {
    test('Mastodon share URL with text and visibility', () {
      final plan = adapter.buildHandoff(
        const PostVariant(text: 'Hello world & more', visibility: Visibility.followers),
        account: account(mastodonConfig, PlatformTier.handoff),
      )!;
      final u = plan.webIntent!;
      expect(u.scheme, 'https');
      expect(u.host, 'mastodon.example');
      expect(u.path, '/share');
      expect(u.queryParameters['text'], 'Hello world & more');
      expect(u.queryParameters['visibility'], 'private');
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.clipboardText, 'Hello world & more');
      expect(plan.androidPackage, 'org.joinmastodon.android');
      expect(plan.desktopUrl, 'https://mastodon.example');
      expect(plan.instructions, contains('1.'));
    });

    test('media prefers the share sheet', () {
      final plan = adapter.buildHandoff(
        PostVariant(text: 'pic', media: [fakeImage()]),
        account: account(),
      )!;
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.shareFiles, hasLength(1));
      expect(plan.mediaNote, isNotNull);
    });

    test('GoToSocial has no share page → manual with clipboard', () {
      final plan = adapter.buildHandoff(
        const PostVariant(text: 'a', threadParts: ['a', 'b']),
        account: account({...mastodonConfig, 'software': 'gotosocial'}),
      )!;
      expect(plan.webIntent, isNull);
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.clipboardText, 'a\n\nb');
    });

    test('public posts do not send a visibility parameter', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'x'), account: account())!;
      expect(plan.webIntent!.queryParameters.containsKey('visibility'), isFalse);
    });
  });
}
