// What a person reads when an upload fails on a post whose first copies are
// already live, through the real PublishService and the real adapters.
import 'dart:io';
import 'dart:typed_data';

import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_adapter.dart';
import 'package:test/test.dart';

import '../support/fault_client.dart';
import '../support/test_context.dart';

class _BrokenRead extends MastodonAdapter {
  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) =>
      throw const PathNotFoundException('i.jpg', OSError('The system cannot find the path specified', 3), 'Cannot open file');
}

void main() {
  const secretValues = {'client_id': 'c', 'client_secret': 's', 'access_token': 't', 'token_type': 'Bearer'};

  Future<PublishService> service({
    required String platformId,
    required FaultClient client,
    required Post post,
    PlatformAdapter? adapter,
    Map<String, dynamic>? config,
  }) async {
    final accounts = InMemoryAccountRepository();
    final posts = InMemoryPostRepository();
    final secrets = InMemorySecretStore();
    await accounts.upsert(fakeAccount(platformId, config: config ?? {
      'instance': 'https://server.example',
      'domain': 'server.example',
      'software': platformId,
      'maxCharacters': 500,
      'maxMediaAttachments': 2,
    }));
    await secrets.write('acct-1', secretValues);
    await posts.upsert(post);
    return PublishService(
      registry: AdapterRegistry([adapter ?? builtinAdapters().firstWhere((a) => a.descriptor.id == platformId)]),
      accounts: accounts,
      posts: posts,
      secrets: secrets,
      quota: QuotaTracker(InMemoryQuotaRepository()),
      http: NeforumHttp(client: client),
      clock: () => testNow,
      readMedia: (m) async => Uint8List(512 * 1024),
      log: Logger('test', sink: (level, area, msg, [err]) {}),
    );
  }

  Post gallery() => Post(
        id: 'p1',
        text: 'Holiday',
        artwork: const ArtworkDetails(),
        media: [for (var i = 0; i < 4; i++) fakeImage(id: 'img$i')],
        createdAt: testNow,
        updatedAt: testNow,
        targets: const [PostTarget(accountId: 'acct-1')],
      );

  group('a Pixelfed gallery published as a series', () {
    test('an upload cut off on post 2 says nothing false about post 1, and Retry posts the rest', () async {
      var media = 0;
      var cut = true;
      var statuses = 0;
      final c = FaultClient((i, r) {
        if (r.url.path.endsWith('/statuses')) {
          statuses++;
          return jsonAnswer({'id': 's$statuses', 'url': 'https://server.example/s$statuses'});
        }
        if (r.url.path.contains('instance')) return jsonAnswer({}, 404);
        media++;
        return cut && media >= 3 ? null : jsonAnswer({'id': 'm$media', 'url': 'u'});
      });
      final s = await service(platformId: 'pixelfed', client: c, post: gallery());
      final failed = (await s.publish('p1', interactive: false)).targets.single;
      final e = failed.result!.error!;
      expect(
        e.message,
        'Post 2 of 2 failed: The upload to server.example was cut off (tried 3 times). Nothing more was posted. '
        'The first 1 post(s) are live; Retry posts the rest.',
      );
      expect(e.uploadInterrupted, isTrue, reason: 'the upload advice line depends on it');
      expect(e.isPartialSeries, isTrue);
      expect(e.raw, contains('errno = 10053'));
      expect(failed.result!.allRemoteIds, ['s1']);
      expect(failed.canResume, isTrue);

      cut = false;
      final done = (await s.publish('p1', interactive: false)).targets.single;
      expect(done.status, TargetStatus.published, reason: '${done.result?.error?.message}');
      expect(statuses, 2, reason: 'post 1 is not posted again');
    });

    test('a file over the limit on post 2 says nothing more was posted', () async {
      var media = 0;
      final c = FaultClient((i, r) {
        if (r.url.path.endsWith('/statuses')) return jsonAnswer({'id': 's1', 'url': 'https://server.example/s1'});
        if (r.url.path.contains('instance')) {
          return jsonAnswer({'configuration': {'media_attachments': {'image_size_limit': 256 * 1024}}});
        }
        media++;
        return media >= 3 ? null : jsonAnswer({'id': 'm$media', 'url': 'u'});
      });
      final s = await service(platformId: 'pixelfed', client: c, post: gallery());
      final e = (await s.publish('p1', interactive: false)).targets.single.result!.error!;
      expect(
        e.message,
        'Post 2 of 2 failed: server.example takes images up to 0.3 MB, and this one is 0.5 MB. Nothing more was posted. '
        'The first 1 post(s) are live; Retry posts the rest.',
      );
      expect(e.message, isNot(contains('..')));
    });

    test('a cut on the first post still says nothing was posted', () async {
      final c = FaultClient((i, r) => r.url.path.contains('instance') ? jsonAnswer({}, 404) : null);
      final s = await service(platformId: 'pixelfed', client: c, post: gallery());
      final e = (await s.publish('p1', interactive: false)).targets.single.result!.error!;
      expect(e.message, 'The upload to server.example was cut off (tried 3 times). Nothing was posted.');
    });

    test('any wrapped message keeps one full stop, with or without its own', () {
      for (final message in ['Refused.', 'Refused']) {
        final e = PublishError.validation(message).asResumableSeries(liveCount: 2, total: 3);
        expect(e.message, 'Post 3 of 3 failed: Refused. The first 2 post(s) are live; Retry posts the rest.');
        expect(e.retryable, isFalse);
      }
    });
  });

  test('a file error nothing else caught shows no errno, and the details box keeps it', () async {
    final c = FaultClient((i, r) => jsonAnswer({}, 404));
    final s = await service(
      platformId: 'mastodon',
      client: c,
      adapter: _BrokenRead(),
      post: Post(
        id: 'p1',
        text: 'x',
        createdAt: testNow,
        updatedAt: testNow,
        targets: const [PostTarget(accountId: 'acct-1')],
      ),
    );
    final e = (await s.publish('p1', interactive: false)).targets.single.result!.error!;
    expect(e.kind, PublishErrorKind.configuration);
    expect(e.message, 'A media file for this post is missing or unreadable. Re-attach it and try again.');
    expect(e.raw, contains('errno = 3'));
  });
}
