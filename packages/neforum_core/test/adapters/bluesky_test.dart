import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/bluesky/bluesky_adapter.dart';
import 'package:neforum_core/src/adapters/bluesky/bluesky_richtext.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

const did = 'did:plc:abc123';
const pdsHost = 'puffball.us-east.host.bsky.network';
const pds = 'https://$pdsHost';

String fakeJwt(DateTime exp, [String sub = did]) {
  String seg(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${seg({'alg': 'ES256K', 'typ': 'at+jwt'})}.${seg({'sub': sub, 'exp': exp.millisecondsSinceEpoch ~/ 1000})}.sig';
}

Map<String, dynamic> sessionJson({String access = 'A1', String refresh = 'R1', bool withDidDoc = true}) => {
      'accessJwt': access,
      'refreshJwt': refresh,
      'handle': 'alice.bsky.social',
      'did': did,
      if (withDidDoc)
        'didDoc': {
          'id': did,
          'alsoKnownAs': ['at://alice.bsky.social'],
          'service': [
            {'id': '#atproto_pds', 'type': 'AtprotoPersonalDataServer', 'serviceEndpoint': pds},
          ],
        },
      'active': true,
    };

http.Response jsonRes(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

ConnectedAccount blueskyAccount() => fakeAccount('bluesky', config: {
      'did': did,
      'handle': 'alice.bsky.social',
      'pds': pds,
      'service': 'https://bsky.social',
    });

final accessJwt = fakeJwt(testNow.add(const Duration(hours: 2)));
Map<String, String> get goodSecrets => {
      'access_token': accessJwt,
      'refresh_token': 'R1',
      'token_type': 'Bearer',
      'expires_at': testNow.add(const Duration(hours: 2)).toIso8601String(),
      'app_password': 'abcd-efgh-ijkl-mnop',
    };

Map<String, dynamic> blob(String cid, [String mime = 'image/jpeg', int size = 64]) => {
      r'$type': 'blob',
      'ref': {r'$link': cid},
      'mimeType': mime,
      'size': size,
    };

/// Records every request and answers with the first matching route.
class Router {
  final List<http.Request> calls = [];
  final List<(bool Function(http.Request), http.Response Function(http.Request))> _routes = [];
  int _posts = 0;

  void on(String method, String pathSuffix, http.Response Function(http.Request) respond) =>
      _routes.add(((r) => r.method == method && r.url.path.endsWith(pathSuffix), respond));

  /// createRecord answers with successive rkeys p1, p2, ...
  void createRecordOk() => on('POST', '/com.atproto.repo.createRecord', (r) {
        _posts++;
        return jsonRes({'uri': 'at://$did/app.bsky.feed.post/p$_posts', 'cid': 'cid$_posts'});
      });

  Future<http.Response> call(http.Request r) async {
    calls.add(r);
    for (final route in _routes) {
      if (route.$1(r)) return route.$2(r);
    }
    return http.Response('no route for ${r.method} ${r.url}', 599);
  }

  Map<String, dynamic> recordOf(http.Request r) => bodyOf(r)['record'] as Map<String, dynamic>;
  List<http.Request> where(String suffix) => calls.where((c) => c.url.path.endsWith(suffix)).toList();
}

void main() {
  final adapter = BlueskyAdapter(videoPollInterval: Duration.zero);

  group('descriptor', () {
    final d = adapter.descriptor;
    test('text limits match the post lexicon', () {
      expect(d.id, 'bluesky');
      expect(d.text.maxLength, 300);
      expect(d.text.counting, CountingRule.graphemes);
      expect(d.text.supportsThreads, isTrue);
      expect(d.text.titleSupported, isFalse);
      expect(d.text.supportsContentWarning, isFalse);
      expect(d.text.linkInText, isTrue);
    });
    test('media limits match the embed lexicons', () {
      expect(d.media.maxImages, 4);
      expect(d.media.imageMaxBytes, 2000000);
      expect(d.media.maxVideos, 1);
      expect(d.media.videoMaxBytes, 300000000);
      expect(d.media.videoMaxSeconds, 600);
      expect(d.media.videoMimeTypes, {'video/mp4'});
      expect(d.media.supportsAltText, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.media.allowsMixedImageVideo, isFalse);
    });
    test('tiers, quotas and docs', () {
      expect(d.tiers, {PlatformTier.openApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.openApi);
      expect(d.personalAccountOk, isTrue);
      expect(d.serverSideScheduling, isFalse);
      expect(d.setupGuide, 'docs/platforms/bluesky.md');
      expect(d.defaultQuotas.map((q) => q.id), ['bluesky.posts_per_hour', 'bluesky.posts_per_day']);
      expect(d.defaultQuotas.first.limit, 1666);
      expect(d.defaultQuotas.last.limit, 11666);
      final spec = adapter.specFor(PlatformTier.openApi);
      expect(spec.usesBrowser, isFalse);
      expect(spec.fields.map((f) => f.key), ['identifier', 'app_password', 'service']);
      expect(spec.fields[1].secret, isTrue);
      expect(spec.intro, contains('bsky.app/settings/app-passwords'));
    });
  });

  group('connect', () {
    test('creates a session, takes the PDS from the DID document and stores tokens', () async {
      final router = Router()
        ..on('POST', '/com.atproto.server.createSession', (_) => jsonRes(sessionJson(access: accessJwt)))
        ..on('GET', '/app.bsky.actor.getProfile',
            (_) => jsonRes({'did': did, 'displayName': 'Alice', 'avatar': 'https://cdn.bsky.app/a.jpg'}));
      final ctx = testContext(handler: router.call);
      final res = await adapter.connect(
          PlatformTier.openApi, {'identifier': '@Alice.bsky.social', 'app_password': 'abcd-efgh-ijkl-mnop'}, ctx);

      expect(router.calls, hasLength(2));
      final login = router.calls[0];
      expect(login.method, 'POST');
      expect(login.url.toString(), 'https://bsky.social/xrpc/com.atproto.server.createSession');
      expect(bodyOf(login), {'identifier': 'alice.bsky.social', 'password': 'abcd-efgh-ijkl-mnop'});
      final profile = router.calls[1];
      expect(profile.url.toString(), '$pds/xrpc/app.bsky.actor.getProfile?actor=did%3Aplc%3Aabc123');
      expect(profile.headers['authorization'], 'Bearer $accessJwt');

      expect(res.account.id, 'bluesky:$did');
      expect(res.account.displayName, 'Alice (@alice.bsky.social)');
      expect(res.account.config, {'did': did, 'handle': 'alice.bsky.social', 'pds': pds, 'service': 'https://bsky.social'});
      expect(res.secrets['access_token'], accessJwt);
      expect(res.secrets['refresh_token'], 'R1');
      expect(res.secrets['app_password'], 'abcd-efgh-ijkl-mnop');
      expect(DateTime.parse(res.secrets['expires_at']!), testNow.add(const Duration(hours: 2)));
    });

    test('custom server without DID document uses the server as PDS', () async {
      final router = Router()
        ..on('POST', '/com.atproto.server.createSession', (_) => jsonRes(sessionJson(withDidDoc: false)))
        ..on('GET', '/app.bsky.actor.getProfile', (_) => jsonRes({}, 404));
      final res = await adapter.connect(
          PlatformTier.openApi,
          {'identifier': 'alice.example.org', 'app_password': 'abcd-efgh-ijkl-mnop', 'service': 'pds.example.org/'},
          testContext(handler: router.call));
      expect(router.calls.first.url.toString(), 'https://pds.example.org/xrpc/com.atproto.server.createSession');
      expect(res.account.config['pds'], 'https://pds.example.org');
      expect(res.account.displayName, '@alice.bsky.social');
    });

    test('refuses something that is not an app password', () {
      final ctx = testContext(handler: (_) async => http.Response('', 500));
      expect(adapter.connect(PlatformTier.openApi, {'identifier': 'a.bsky.social', 'app_password': 'hunter2'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'app_password')));
    });

    test('wrong credentials and 2FA become readable errors', () async {
      Future<ConnectException> attempt(http.Response r) async {
        final ctx = testContext(handler: (_) async => r);
        try {
          await adapter.connect(PlatformTier.openApi, {'identifier': 'a.bsky.social', 'app_password': 'abcd-efgh-ijkl-mnop'}, ctx);
        } on ConnectException catch (e) {
          return e;
        }
        fail('expected ConnectException');
      }

      final wrong = await attempt(jsonRes({'error': 'AuthenticationRequired', 'message': 'Invalid identifier or password'}, 401));
      expect(wrong.message, contains('did not accept'));
      final twoFa = await attempt(jsonRes({'error': 'AuthFactorTokenRequired', 'message': 'A sign in code has been sent'}, 401));
      expect(twoFa.message, contains('app password'));
      final limited = await attempt(jsonRes({'error': 'RateLimitExceeded'}, 429));
      expect(limited.message, contains('Too many'));
    });

    test('hand-off tier needs no network', () async {
      final res = await adapter.connect(
          PlatformTier.handoff, {'handle': '@bob.bsky.social'}, testContext(handler: (_) async => throw StateError('no')));
      expect(res.account.tier, PlatformTier.handoff);
      expect(res.account.handle, '@bob.bsky.social');
      expect(res.secrets, isEmpty);
    });
  });

  group('rich text facets', () {
    test('links use UTF-8 byte offsets', () {
      const text = '🦋 café https://example.com/a?b=1.';
      final f = BlueskyRichText.facets(text);
      expect(f, hasLength(1));
      // 🦋 = 4 bytes, space, "café" = 5 bytes, space -> link starts at byte 11.
      expect(f.single['index'], {'byteStart': 11, 'byteEnd': 11 + 'https://example.com/a?b=1'.length});
      expect((f.single['features'] as List).single, {r'$type': 'app.bsky.richtext.facet#link', 'uri': 'https://example.com/a?b=1'});
    });

    test('bare domains get https://', () {
      final f = BlueskyRichText.facets('see example.org/x');
      expect(((f.single['features'] as List).single as Map)['uri'], 'https://example.org/x');
    });

    test('mentions need a resolved DID; tags drop trailing punctuation', () {
      const text = 'hi @bob.example.com and @nobody.example.com! #Flutter, #2026 #a1 url https://x.com/#frag';
      final spans = BlueskyRichText.detect(text);
      expect(spans.map((s) => '${s.kind.name}:${s.value}'), [
        'mention:bob.example.com',
        'mention:nobody.example.com',
        'tag:Flutter',
        'tag:a1',
        'link:https://x.com/#frag',
      ]);
      final f = BlueskyRichText.facets(text, didsByHandle: {'bob.example.com': 'did:plc:bob'});
      expect(f, hasLength(4));
      expect(f.first['index'], {'byteStart': 3, 'byteEnd': 19});
      expect((f.first['features'] as List).single, {r'$type': 'app.bsky.richtext.facet#mention', 'did': 'did:plc:bob'});
      final tag = f[1];
      final start = utf8.encode(text.substring(0, text.indexOf('#Flutter'))).length;
      expect(tag['index'], {'byteStart': start, 'byteEnd': start + '#Flutter'.length});
      expect((tag['features'] as List).single, {r'$type': 'app.bsky.richtext.facet#tag', 'tag': 'Flutter'});
    });

    test('email addresses are not mentions', () {
      expect(BlueskyRichText.detect('mail bob@example.com').where((s) => s.kind == BlueskySpanKind.mention), isEmpty);
    });
  });

  group('validate', () {
    final account = blueskyAccount();
    List<String> codes(PostVariant v) => adapter.validate(v, account).map((i) => i.code).toList();

    test('300 graphemes ok, 301 too long', () {
      expect(codes(PostVariant(text: '👍🏽' * 300)), isNot(contains('text.too_long')));
      expect(codes(PostVariant(text: 'a' * 301)), contains('text.too_long'));
    });

    test('3,000-byte limit is enforced on top of graphemes', () {
      const family = '👨‍👩‍👧‍👦'; // one grapheme, 25 bytes
      expect(codes(PostVariant(text: family * 150)), contains('bluesky.text_bytes'));
    });

    test('media rules', () {
      expect(codes(PostVariant(text: 'x', media: [for (var i = 0; i < 5; i++) fakeImage(id: 'i$i')])),
          contains('media.too_many_images'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(sizeBytes: 2500000)])), contains('media.image_too_large'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage(), fakeVideo()])), contains('media.mixed'));
      expect(codes(PostVariant(text: 'x', media: [fakeVideo(mimeType: 'video/quicktime')])), contains('media.video_type'));
      expect(codes(PostVariant(text: 'x', media: [fakeVideo(durationMs: 601000)])), contains('media.video_too_long'));
    });

    test('platform notices', () {
      expect(codes(const PostVariant(text: 'x', visibility: Visibility.followers)), contains('bluesky.always_public'));
      expect(codes(const PostVariant(text: 'x', contentWarning: 'spoilers')), contains('bluesky.no_cw'));
      expect(codes(PostVariant(text: 'x https://a.com', media: [fakeImage()])), contains('bluesky.no_link_card'));
      expect(codes(PostVariant(text: 'x', media: [fakeImage()], extra: const {'bluesky.selfLabel': 'nsfw'})),
          contains('bluesky.bad_label'));
      expect(codes(PostVariant(text: '#${'a' * 70} hi')), contains('bluesky.tag_too_long'));
    });
  });

  group('publish', () {
    test('images: uploadBlob each, resolve mention, createRecord with facets and embed', () async {
      final router = Router()
        ..on('POST', '/com.atproto.repo.uploadBlob', (r) => jsonRes({'blob': blob('blob${r.bodyBytes.length}')}))
        ..on('GET', '/com.atproto.identity.resolveHandle', (_) => jsonRes({'did': 'did:plc:bob'}))
        ..createRecordOk();
      final progress = <String>[];
      final base = testContext(handler: router.call);
      final ctx = base.copyWith(onProgress: progress.add);
      final variant = PostVariant(
        text: 'Hello @bob.bsky.social #dart',
        language: 'en',
        media: [fakeImage(id: 'a'), fakeImage(id: 'b', width: null, altText: null)],
      );
      final res = await adapter.publish(variant, blueskyAccount(), goodSecrets, ctx);

      expect(res.success, isTrue, reason: '${res.error}');
      expect(router.calls.map((c) => '${c.method} ${c.url.path}'), [
        'POST /xrpc/com.atproto.repo.uploadBlob',
        'POST /xrpc/com.atproto.repo.uploadBlob',
        'GET /xrpc/com.atproto.identity.resolveHandle',
        'POST /xrpc/com.atproto.repo.createRecord',
      ]);
      final up = router.calls.first;
      expect(up.url.toString(), '$pds/xrpc/com.atproto.repo.uploadBlob');
      expect(up.headers['content-type'], 'image/jpeg');
      expect(up.headers['authorization'], 'Bearer $accessJwt');
      expect(up.bodyBytes, fakeJpegBytes);
      expect(router.calls[2].url.queryParameters['handle'], 'bob.bsky.social');

      final create = router.calls.last;
      expect(create.url.toString(), '$pds/xrpc/com.atproto.repo.createRecord');
      final body = bodyOf(create);
      expect(body['repo'], did);
      expect(body['collection'], 'app.bsky.feed.post');
      final record = router.recordOf(create);
      expect(record[r'$type'], 'app.bsky.feed.post');
      expect(record['text'], 'Hello @bob.bsky.social #dart');
      expect(record['createdAt'], '2026-10-07T12:00:00.000Z');
      expect(record['langs'], ['en']);
      expect(record['facets'], [
        {
          'index': {'byteStart': 6, 'byteEnd': 22},
          'features': [
            {r'$type': 'app.bsky.richtext.facet#mention', 'did': 'did:plc:bob'},
          ],
        },
        {
          'index': {'byteStart': 23, 'byteEnd': 28},
          'features': [
            {r'$type': 'app.bsky.richtext.facet#tag', 'tag': 'dart'},
          ],
        },
      ]);
      expect(record['embed'], {
        r'$type': 'app.bsky.embed.images',
        'images': [
          {
            'alt': 'A test image',
            'image': blob('blob${fakeJpegBytes.length}'),
            'aspectRatio': {'width': 1200, 'height': 800},
          },
          {'alt': '', 'image': blob('blob${fakeJpegBytes.length}')},
        ],
      });
      expect(record.containsKey('reply'), isFalse);
      expect(res.remoteId, 'at://$did/app.bsky.feed.post/p1');
      expect(res.remoteUrl, 'https://bsky.app/profile/alice.bsky.social/post/p1');
      expect(res.threadRemoteIds, isEmpty);
      expect(progress, ['Uploading image 1 of 2 to Bluesky', 'Uploading image 2 of 2 to Bluesky']);
    });

    test('image whose real bytes exceed 2,000,000 fails before uploading', () async {
      final router = Router();
      final ctx = testContext(handler: router.call, mediaBytes: Uint8List(2000001));
      final res = await adapter.publish(PostVariant(text: 'big', media: [fakeImage()]), blueskyAccount(), goodSecrets, ctx);
      expect(res.error!.kind, PublishErrorKind.validation);
      expect(res.error!.message, contains('2000000'));
      expect(router.calls, isEmpty);
    });

    test('thread: replies carry root and parent strong refs; media on the first part', () async {
      final router = Router()
        ..on('POST', '/com.atproto.repo.uploadBlob', (_) => jsonRes({'blob': blob('b1')}))
        ..createRecordOk();
      final res = await adapter.publish(
        PostVariant(text: 'one', threadParts: const ['one', 'two', 'three'], media: [fakeImage()]),
        blueskyAccount(),
        goodSecrets,
        testContext(handler: router.call),
      );
      expect(res.success, isTrue, reason: '${res.error}');
      final records = router.where('createRecord').map(router.recordOf).toList();
      expect(records.map((r) => r['text']), ['one', 'two', 'three']);
      expect(records[0].containsKey('reply'), isFalse);
      expect((records[0]['embed'] as Map)[r'$type'], 'app.bsky.embed.images');
      expect(records[1].containsKey('embed'), isFalse);
      expect(records[1]['reply'], {
        'root': {'uri': 'at://$did/app.bsky.feed.post/p1', 'cid': 'cid1'},
        'parent': {'uri': 'at://$did/app.bsky.feed.post/p1', 'cid': 'cid1'},
      });
      expect(records[2]['reply'], {
        'root': {'uri': 'at://$did/app.bsky.feed.post/p1', 'cid': 'cid1'},
        'parent': {'uri': 'at://$did/app.bsky.feed.post/p2', 'cid': 'cid2'},
      });
      expect(res.threadRemoteIds, [for (var i = 1; i <= 3; i++) 'at://$did/app.bsky.feed.post/p$i']);
      expect(res.remoteId, res.threadRemoteIds.first);
    });

    test('a thread that broke off goes on after its live posts, with their strong refs read back (1.3.4)', () async {
      final router = Router()
        ..on('GET', '/com.atproto.repo.getRecord', (r) {
          final rkey = r.url.queryParameters['rkey'];
          return jsonRes({'uri': 'at://$did/app.bsky.feed.post/$rkey', 'cid': 'cid-$rkey'});
        })
        ..on('POST', '/com.atproto.repo.createRecord', (_) => jsonRes({'uri': 'at://$did/app.bsky.feed.post/new', 'cid': 'cid-new'}));
      final res = await adapter.publish(
        PostVariant(
          text: 'one',
          threadParts: const ['one', 'two', 'three'],
          postedThreadIds: ['at://$did/app.bsky.feed.post/old1', 'at://$did/app.bsky.feed.post/old2'],
        ),
        blueskyAccount(),
        goodSecrets,
        testContext(handler: router.call),
      );
      expect(res.success, isTrue, reason: '${res.error}');
      final records = router.where('createRecord').map(router.recordOf).toList();
      expect(records.map((r) => r['text']), ['three'], reason: 'only part 3 is posted');
      expect(records.single['reply'], {
        'root': {'uri': 'at://$did/app.bsky.feed.post/old1', 'cid': 'cid-old1'},
        'parent': {'uri': 'at://$did/app.bsky.feed.post/old2', 'cid': 'cid-old2'},
      });
      expect(res.threadRemoteIds, ['at://$did/app.bsky.feed.post/old1', 'at://$did/app.bsky.feed.post/old2', 'at://$did/app.bsky.feed.post/new']);
    });

    test('a thread failing on part 2 records part 1 and can be finished (1.3.4)', () async {
      var n = 0;
      final router = Router()
        ..on('POST', '/com.atproto.repo.createRecord', (_) {
          n++;
          return n == 1
              ? jsonRes({'uri': 'at://$did/app.bsky.feed.post/p1', 'cid': 'cid1'})
              : jsonRes({'error': 'InternalServerError', 'message': 'boom'}, 500);
        });
      final res = await adapter.publish(
          PostVariant(text: 'one', threadParts: const ['one', 'two']), blueskyAccount(), goodSecrets, testContext(handler: router.call));
      expect(res.success, isFalse);
      expect(res.error!.retryable, isFalse);
      expect(res.error!.message, contains('Part 2 of 2 failed'));
      expect(res.threadRemoteIds, ['at://$did/app.bsky.feed.post/p1']);
    });

    test('link card: fetch page, upload thumbnail, embed external', () async {
      const html = '<html><head><title>Fallback</title>'
          '<meta property="og:title" content="Rock &amp; Roll">'
          "<meta name='description' content='All about it'>"
          '<meta property="og:image" content="/img/card.png"></head></html>';
      final router = Router()
        ..on('GET', '/article', (_) => http.Response(html, 200, headers: {'content-type': 'text/html; charset=utf-8'}))
        ..on('GET', '/img/card.png', (_) => http.Response.bytes([1, 2, 3], 200, headers: {'content-type': 'image/png'}))
        ..on('POST', '/com.atproto.repo.uploadBlob', (_) => jsonRes({'blob': blob('thumb', 'image/png', 3)}))
        ..createRecordOk();
      final res = await adapter.publish(const PostVariant(text: 'Read https://news.example.com/article'),
          blueskyAccount(), goodSecrets, testContext(handler: router.call));
      expect(res.success, isTrue, reason: '${res.error}');
      expect(router.calls.map((c) => '${c.method} ${c.url}'), [
        'GET https://news.example.com/article',
        'GET https://news.example.com/img/card.png',
        'POST $pds/xrpc/com.atproto.repo.uploadBlob',
        'POST $pds/xrpc/com.atproto.repo.createRecord',
      ]);
      expect(router.calls[2].headers['content-type'], 'image/png');
      final record = router.recordOf(router.calls.last);
      expect(record['embed'], {
        r'$type': 'app.bsky.embed.external',
        'external': {
          'uri': 'https://news.example.com/article',
          'title': 'Rock & Roll',
          'description': 'All about it',
          'thumb': blob('thumb', 'image/png', 3),
        },
      });
      expect((record['facets'] as List).single, {
        'index': {'byteStart': 5, 'byteEnd': 37},
        'features': [
          {r'$type': 'app.bsky.richtext.facet#link', 'uri': 'https://news.example.com/article'},
        ],
      });
    });

    test('link card is skipped when the page cannot be read', () async {
      final router = Router()
        ..on('GET', '/missing', (_) => http.Response('nope', 404))
        ..createRecordOk();
      final res = await adapter.publish(const PostVariant(text: 'x', link: 'https://example.com/missing'),
          blueskyAccount(), goodSecrets, testContext(handler: router.call));
      expect(res.success, isTrue);
      expect(router.recordOf(router.calls.last).containsKey('embed'), isFalse);
    });

    test('video: service auth, upload to video.bsky.app, poll, embed video', () async {
      var polls = 0;
      final router = Router()
        ..on('GET', '/com.atproto.server.getServiceAuth', (_) => jsonRes({'token': 'SVC'}))
        ..on('POST', '/app.bsky.video.uploadVideo',
            (_) => jsonRes({'jobStatus': {'jobId': 'job1', 'did': did, 'state': 'JOB_STATE_CREATED'}}))
        ..on('GET', '/app.bsky.video.getJobStatus', (_) {
          polls++;
          return jsonRes({
            'jobStatus': polls < 2
                ? {'jobId': 'job1', 'did': did, 'state': 'JOB_STATE_ENCODING', 'progress': 50}
                : {'jobId': 'job1', 'did': did, 'state': 'JOB_STATE_COMPLETED', 'blob': blob('vid', 'video/mp4', 5)},
          });
        })
        ..createRecordOk();
      final res = await adapter.publish(PostVariant(text: 'clip', media: [fakeVideo()]), blueskyAccount(), goodSecrets,
          testContext(handler: router.call));
      expect(res.success, isTrue, reason: '${res.error}');
      expect(router.calls.map((c) => '${c.method} ${c.url.host}${c.url.path}'), [
        'GET $pdsHost/xrpc/com.atproto.server.getServiceAuth',
        'POST video.bsky.app/xrpc/app.bsky.video.uploadVideo',
        'GET video.bsky.app/xrpc/app.bsky.video.getJobStatus',
        'GET video.bsky.app/xrpc/app.bsky.video.getJobStatus',
        'POST $pdsHost/xrpc/com.atproto.repo.createRecord',
      ]);
      final auth = router.calls[0].url.queryParameters;
      expect(auth['aud'], 'did:web:$pdsHost');
      expect(auth['lxm'], 'com.atproto.repo.uploadBlob');
      expect(int.parse(auth['exp']!), testNow.millisecondsSinceEpoch ~/ 1000 + 1800);
      final up = router.calls[1];
      expect(up.url.queryParameters, {'did': did, 'name': 'vid1.mp4'});
      expect(up.headers['authorization'], 'Bearer SVC');
      expect(up.headers['content-type'], 'video/mp4');
      expect(router.calls[2].url.queryParameters['jobId'], 'job1');
      expect(router.calls[2].headers.containsKey('authorization'), isFalse);
      expect(router.recordOf(router.calls.last)['embed'], {
        r'$type': 'app.bsky.embed.video',
        'video': blob('vid', 'video/mp4', 5),
        'aspectRatio': {'width': 1080, 'height': 1920},
      });
    });

    test('video already processed returns its blob immediately', () async {
      final router = Router()
        ..on('GET', '/com.atproto.server.getServiceAuth', (_) => jsonRes({'token': 'SVC'}))
        ..on('POST', '/app.bsky.video.uploadVideo',
            (_) => jsonRes({'jobId': 'j', 'error': 'already_exists', 'blob': blob('vid', 'video/mp4')}, 409))
        ..createRecordOk();
      final res = await adapter.publish(PostVariant(text: 'clip', media: [fakeVideo()]), blueskyAccount(), goodSecrets,
          testContext(handler: router.call));
      expect(res.success, isTrue, reason: '${res.error}');
      expect(router.where('getJobStatus'), isEmpty);
    });

    test('video upload refused for unverified email is a configuration error', () async {
      final router = Router()
        ..on('GET', '/com.atproto.server.getServiceAuth', (_) => jsonRes({'token': 'SVC'}))
        ..on('POST', '/app.bsky.video.uploadVideo',
            (_) => jsonRes({'error': 'Unauthorized', 'message': 'You must verify your email before uploading videos'}, 401));
      final res = await adapter.publish(PostVariant(text: 'clip', media: [fakeVideo()]), blueskyAccount(), goodSecrets,
          testContext(handler: router.call));
      expect(res.error!.kind, PublishErrorKind.configuration);
    });

    group('error mapping', () {
      Future<PublishError> failWith(http.Response r) async {
        final router = Router()..on('POST', '/com.atproto.repo.createRecord', (_) => r);
        final res = await adapter.publish(
            const PostVariant(text: 'hi'), blueskyAccount(), goodSecrets, testContext(handler: router.call));
        expect(res.success, isFalse);
        return res.error!;
      }

      test('401 -> auth', () async {
        expect((await failWith(jsonRes({'error': 'AuthenticationRequired'}, 401))).kind, PublishErrorKind.auth);
      });
      test('400 ExpiredToken -> auth', () async {
        expect((await failWith(jsonRes({'error': 'ExpiredToken', 'message': 'Token has expired'}, 400))).kind,
            PublishErrorKind.auth);
      });
      test('429 -> quota with retryAfter from ratelimit-reset', () async {
        final reset = testNow.millisecondsSinceEpoch ~/ 1000 + 120;
        final e = await failWith(jsonRes({'error': 'RateLimitExceeded', 'message': 'Rate Limit Exceeded'}, 429,
            {'ratelimit-reset': '$reset', 'ratelimit-policy': '5000;w=3600'}));
        expect(e.kind, PublishErrorKind.quota);
        expect(e.retryAfter, const Duration(seconds: 120));
      });
      test('400 InvalidRequest -> validation', () async {
        final e = await failWith(jsonRes({'error': 'InvalidRequest', 'message': 'Invalid app.bsky.feed.post record'}, 400));
        expect(e.kind, PublishErrorKind.validation);
        expect(e.message, contains('Invalid app.bsky.feed.post record'));
      });
      test('502 -> network', () async {
        expect((await failWith(http.Response('bad gateway', 502))).kind, PublishErrorKind.network);
      });
      test('missing config -> configuration; missing token -> auth', () async {
        final ctx = testContext(handler: (_) async => http.Response('', 500));
        final noCfg = await adapter.publish(const PostVariant(text: 'x'), fakeAccount('bluesky'), goodSecrets, ctx);
        expect(noCfg.error!.kind, PublishErrorKind.configuration);
        final noTok = await adapter.publish(const PostVariant(text: 'x'), blueskyAccount(), const {}, ctx);
        expect(noTok.error!.kind, PublishErrorKind.auth);
      });
      test('hand-off accounts cannot publish via API', () async {
        final res = await adapter.publish(const PostVariant(text: 'x'), fakeAccount('bluesky', tier: PlatformTier.handoff),
            const {}, testContext(handler: (_) async => http.Response('', 500)));
        expect(res.error!.kind, PublishErrorKind.unsupported);
      });
    });
  });

  group('refreshSecrets', () {
    final expired = {
      ...goodSecrets,
      'access_token': fakeJwt(testNow.subtract(const Duration(minutes: 1))),
      'expires_at': testNow.subtract(const Duration(minutes: 1)).toIso8601String(),
    };

    test('fresh token -> null, no requests', () async {
      final router = Router();
      expect(await adapter.refreshSecrets(blueskyAccount(), goodSecrets, testContext(handler: router.call)), isNull);
      expect(router.calls, isEmpty);
    });

    test('expired token -> refreshSession at the entryway with the refresh JWT', () async {
      final newAccess = fakeJwt(testNow.add(const Duration(hours: 2)));
      final router = Router()
        ..on('POST', '/com.atproto.server.refreshSession', (_) => jsonRes(sessionJson(access: newAccess, refresh: 'R2')));
      final out = await adapter.refreshSecrets(blueskyAccount(), expired, testContext(handler: router.call));
      expect(router.calls.single.url.toString(), 'https://bsky.social/xrpc/com.atproto.server.refreshSession');
      expect(router.calls.single.headers['authorization'], 'Bearer R1');
      expect(out!['access_token'], newAccess);
      expect(out['refresh_token'], 'R2');
      expect(out['app_password'], 'abcd-efgh-ijkl-mnop');
    });

    test('rejected refresh token -> new session from the stored app password', () async {
      final router = Router()
        ..on('POST', '/com.atproto.server.refreshSession', (_) => jsonRes({'error': 'ExpiredToken'}, 400))
        ..on('POST', '/com.atproto.server.createSession', (_) => jsonRes(sessionJson(access: 'A3', refresh: 'R3')));
      final out = await adapter.refreshSecrets(blueskyAccount(), expired, testContext(handler: router.call));
      expect(bodyOf(router.calls.last), {'identifier': did, 'password': 'abcd-efgh-ijkl-mnop'});
      expect(out!['refresh_token'], 'R3');
    });

    test('revoked app password -> AdapterException(auth)', () async {
      final router = Router()
        ..on('POST', '/com.atproto.server.refreshSession', (_) => jsonRes({'error': 'ExpiredToken'}, 400))
        ..on('POST', '/com.atproto.server.createSession', (_) => jsonRes({'error': 'AuthenticationRequired'}, 401));
      await expectLater(adapter.refreshSecrets(blueskyAccount(), expired, testContext(handler: router.call)),
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
    });

    test('no app password and rejected refresh -> auth', () async {
      final router = Router()..on('POST', '/com.atproto.server.refreshSession', (_) => jsonRes({'error': 'InvalidToken'}, 400));
      final noPw = Map<String, String>.from(expired)..remove('app_password');
      await expectLater(adapter.refreshSecrets(blueskyAccount(), noPw, testContext(handler: router.call)),
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
    });
  });

  group('buildHandoff', () {
    test('text-only uses the compose intent', () {
      final plan = adapter.buildHandoff(const PostVariant(text: "I'm here!\nhttps://example.com"))!;
      expect(plan.webIntent.toString(),
          'https://bsky.app/intent/compose?text=I\'m%20here!%0Ahttps%3A%2F%2Fexample.com');
      expect(plan.webIntent!.queryParameters['text'], "I'm here!\nhttps://example.com");
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.clipboardText, "I'm here!\nhttps://example.com");
      expect(plan.androidPackage, 'xyz.blueskyweb.app');
      expect(plan.mediaNote, isNull);
    });

    test('media prefers the share sheet; threads put everything on the clipboard', () {
      final plan = adapter.buildHandoff(
          PostVariant(text: 'one', threadParts: const ['one', 'two'], media: [fakeImage()]))!;
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.shareFiles, hasLength(1));
      expect(plan.clipboardText, 'one\n\ntwo');
      expect(plan.webIntent!.queryParameters['text'], 'one');
      expect(plan.mediaNote, isNotNull);
    });
  });
}
