import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

/// A network with threads and a 50-character limit, with or without media in
/// every post of a thread.
PlatformDescriptor _network({required bool perPart, int maxImages = 4}) => PlatformDescriptor(
      id: perPart ? 'perpart' : 'firstonly',
      name: perPart ? 'PerPart' : 'FirstOnly',
      tiers: const {PlatformTier.openApi},
      defaultTier: PlatformTier.openApi,
      text: const TextRules(maxLength: 50, supportsThreads: true),
      media: MediaRules(maxImages: maxImages, maxVideos: 1, supportsAltText: true, mediaPerThreadPart: perPart),
      accountRequirements: '',
      apiCostSummary: '',
    );

MediaAttachment _image(String id, {String? derivedFrom, bool generated = false}) => MediaAttachment(
      id: id,
      path: '/m/$id.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: 64,
      altText: 'alt $id',
      derivedFrom: derivedFrom,
      generated: generated,
    );

Post _post(List<String> parts, List<MediaAttachment> media, Map<String, int> mediaParts, {PostOverrides? overrides}) => Post(
      id: 'p',
      text: parts.first,
      additionalParts: parts.skip(1).toList(),
      media: media,
      mediaParts: mediaParts,
      createdAt: testNow,
      updatedAt: testNow,
      targets: [PostTarget(accountId: 'acct-1', overrides: overrides ?? const PostOverrides())],
    );

PostVariant _resolve(Post post, PlatformDescriptor d) =>
    const VariantResolver(ResolverOptions(threadNumbering: false)).resolve(post, post.targets.single, d, account: fakeAccount(d.id));

void main() {
  final perPart = _network(perPart: true);
  final firstOnly = _network(perPart: false);

  group('Post.mediaParts', () {
    test('survives JSON and is left out when empty, so older posts read unchanged', () {
      final post = _post(['One', 'Two'], [_image('a'), _image('b')], {'b': 1});
      final back = Post.fromJson(post.toJson());
      expect(back.mediaParts, {'b': 1});
      expect(back.partOf(_image('b')), 1);
      expect(back.partOf(_image('a')), 0);
      final plain = _post(['One'], [_image('a')], const {});
      expect(plain.toJson().containsKey('mediaParts'), isFalse);
      expect(Post.fromJson(plain.toJson()).mediaParts, isEmpty);
    });

    test('a fitted copy goes where its original goes', () {
      final post = _post(['One', 'Two'], [_image('a')], {'a': 1});
      expect(post.partOf(_image('fit', derivedFrom: 'a', generated: true)), 1);
    });
  });

  group('the resolver places media per part', () {
    test('each image goes with the first post made from its part', () {
      final post = _post(['First part', 'Second part', 'Third part'], [_image('a'), _image('b'), _image('c')], {'b': 1, 'c': 2});
      final v = _resolve(post, perPart);
      expect(v.threadParts, ['First part', 'Second part', 'Third part']);
      expect(v.mediaOfPart(0).map((m) => m.id), ['a']);
      expect(v.mediaOfPart(1).map((m) => m.id), ['b']);
      expect(v.mediaOfPart(2).map((m) => m.id), ['c']);
      expect(v.media.map((m) => m.id), ['a', 'b', 'c']);
      expect(v.mediaGroups, hasLength(3));
    });

    test('a part split for the limit carries its media on its first piece', () {
      final long = List.filled(14, 'word').join(' '); // 69 characters: two posts
      final post = _post(['Intro', long, 'End'], [_image('a'), _image('b')], {'a': 1, 'b': 2});
      final v = _resolve(post, perPart);
      expect(v.threadParts, hasLength(4));
      expect(v.mediaOfPart(0), isEmpty);
      expect(v.mediaOfPart(1).map((m) => m.id), ['a']);
      expect(v.mediaOfPart(2), isEmpty);
      expect(v.mediaOfPart(3).map((m) => m.id), ['b']);
    });

    test('an empty part hands its media to the part before it', () {
      final post = _post(['One', '', 'Three'], [_image('a'), _image('b')], {'a': 1, 'b': 2});
      final v = _resolve(post, perPart);
      expect(v.threadParts, ['One', 'Three']);
      expect(v.mediaOfPart(0).map((m) => m.id), ['a']);
      expect(v.mediaOfPart(1).map((m) => m.id), ['b']);
    });

    test('limits apply per post: eight images over two parts all go', () {
      final media = [for (var i = 0; i < 8; i++) _image('m$i')];
      final post = _post(['One', 'Two'], media, {for (var i = 4; i < 8; i++) 'm$i': 1});
      final v = _resolve(post, perPart);
      expect(v.media, hasLength(8));
      expect(v.issues.where((i) => i.code == 'media.dropped'), isEmpty);
      expect(RulesValidator.validate(v, perPart).where((i) => i.code == 'media.too_many_images'), isEmpty);
    });

    test('too many for one part go on in a post of media only right after it (1.3.4)', () {
      final media = [for (var i = 0; i < 6; i++) _image('m$i')];
      final post = _post(['One', 'Two', 'Three'], media, {for (var i = 0; i < 6; i++) 'm$i': 1});
      final v = _resolve(post, perPart);
      expect(v.threadParts, ['One', 'Two', '', 'Three']);
      expect(v.mediaOfPart(1).map((m) => m.id), ['m0', 'm1', 'm2', 'm3']);
      expect(v.mediaOfPart(2).map((m) => m.id), ['m4', 'm5']);
      expect(v.mediaOfPart(3), isEmpty);
      expect(v.issues.where((i) => i.code == 'media.dropped'), isEmpty);
      expect(v.issues.map((i) => i.code), contains('media.threaded'));
    });

    test('networks without media in every post keep it all on the first post, as before', () {
      final post = _post(['One', 'Two'], [_image('a'), _image('b')], {'b': 1});
      final v = _resolve(post, firstOnly);
      expect(v.mediaPartIndexes, isEmpty);
      expect(v.mediaOfPart(0).map((m) => m.id), ['a', 'b']);
      expect(v.mediaOfPart(1), isEmpty);
    });

    test('networks without threads get every image on the one post', () {
      final single = PlatformDescriptor(
        id: 'single',
        name: 'Single',
        tiers: const {PlatformTier.openApi},
        defaultTier: PlatformTier.openApi,
        text: const TextRules(maxLength: 500),
        media: const MediaRules(maxImages: 4, mediaPerThreadPart: true),
        accountRequirements: '',
        apiCostSummary: '',
      );
      final post = _post(['One', 'Two'], [_image('a'), _image('b')], {'b': 1});
      final v = _resolve(post, single);
      expect(v.isThread, isFalse);
      expect(v.media.map((m) => m.id), ['a', 'b']);
      expect(v.mediaPartIndexes, isEmpty);
    });

    test('a per-network version is one post with all the media', () {
      final post = _post(['One', 'Two'], [_image('a'), _image('b')], {'b': 1}, overrides: const PostOverrides(text: 'Own words'));
      final v = _resolve(post, perPart);
      expect(v.isThread, isFalse);
      expect(v.mediaOfPart(0).map((m) => m.id), ['a', 'b']);
    });

    test('replacing media item for item keeps the parts; another list goes first', () {
      final post = _post(['One', 'Two'], [_image('a'), _image('b')], {'b': 1});
      final v = _resolve(post, perPart);
      final swapped = v.copyWith(media: [v.media[0], _image('b2')]);
      expect(swapped.mediaOfPart(1).map((m) => m.id), ['b2']);
      final card = v.copyWith(media: [_image('card')]);
      expect(card.mediaOfPart(0).map((m) => m.id), ['card']);
      expect(card.hasMediaInLaterParts, isFalse);
    });
  });

  group('adapters post each part with its own media', () {
    test('X uploads every part first, then attaches each part its ids', () async {
      final adapter = builtinRegistry().byId('x')!;
      final account = ConnectedAccount(
        id: 'x-42',
        platformId: 'x',
        tier: PlatformTier.byokApi,
        displayName: 'Alice',
        handle: '@alice',
        createdAt: testNow,
        config: const {'clientId': 'cid-123', 'confidentialClient': false, 'userId': '42'},
      );
      final post = _post(['One', 'Two', 'Three'], [_image('a'), _image('c')], {'c': 2});
      final v = const VariantResolver(ResolverOptions(threadNumbering: false)).resolve(post, post.targets.single, adapter.descriptor, account: account);
      expect(v.mediaPartIndexes, [0, 2]);
      final calls = <http.Request>[];
      var media = 0;
      var tweets = 0;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/2/media/upload') {
          media++;
          return http.Response('{"data":{"id":"M$media","media_key":"3_M$media"}}', 200, headers: jsonHeaders);
        }
        if (r.url.path == '/2/media/metadata') return http.Response('{"data":{"id":"x"}}', 200, headers: jsonHeaders);
        tweets++;
        return http.Response('{"data":{"id":"T$tweets"}}', 201, headers: jsonHeaders);
      });
      final secrets = {
        'access_token': 'at-1',
        'refresh_token': 'rt',
        'expires_at': testNow.add(const Duration(hours: 1)).toIso8601String(),
        'token_type': 'bearer',
      };
      final res = await adapter.publish(v, account, secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      final posts = calls.where((r) => r.url.path == '/2/tweets').map(bodyOf).toList();
      expect(posts, hasLength(3));
      expect((posts[0]['media'] as Map)['media_ids'], ['M1']);
      expect(posts[1].containsKey('media'), isFalse);
      expect((posts[2]['media'] as Map)['media_ids'], ['M2']);
      // Both uploads happen before the first post.
      final firstPost = calls.indexWhere((r) => r.url.path == '/2/tweets');
      expect(calls.lastIndexWhere((r) => r.url.path == '/2/media/upload'), lessThan(firstPost));
    });

    test('Bluesky embeds each part its own images', () async {
      final adapter = builtinRegistry().byId('bluesky')!;
      final account = fakeAccount('bluesky', config: {
        'did': 'did:plc:abc',
        'handle': 'alice.bsky.social',
        'pds': 'https://pds.example',
        'service': 'https://bsky.social',
      });
      final post = _post(['One', 'Two'], [_image('a'), _image('b'), _image('c')], {'b': 1, 'c': 1});
      final v = const VariantResolver(ResolverOptions(threadNumbering: false)).resolve(post, post.targets.single, adapter.descriptor, account: account);
      var blobs = 0;
      var records = 0;
      final created = <Map<String, dynamic>>[];
      final ctx = testContext(handler: (r) async {
        if (r.url.path.endsWith('uploadBlob')) {
          blobs++;
          return http.Response('{"blob":{"\$type":"blob","ref":{"\$link":"b$blobs"},"mimeType":"image/jpeg","size":64}}', 200, headers: jsonHeaders);
        }
        records++;
        created.add(bodyOf(r)['record'] as Map<String, dynamic>);
        return http.Response('{"uri":"at://did:plc:abc/app.bsky.feed.post/p$records","cid":"c$records"}', 200, headers: jsonHeaders);
      });
      final res = await adapter.publish(v, account, {'access_token': 'A1', 'refresh_token': 'R1'}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(created, hasLength(2));
      expect(((created[0]['embed'] as Map)['images'] as List), hasLength(1));
      expect(((created[1]['embed'] as Map)['images'] as List), hasLength(2));
    });
  });
}
