// 1.3.4: publishing what does not fit in one post. A network without media in
// every post of a thread gets a series of separate posts, published one after
// the other; a failure partway records what is live, and the next attempt
// posts only the rest. A thread that broke off is finished the same way by
// adapters that resume threads.

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

/// A network that records what it is asked to post, and fails the posts
/// [failOn] (1-based count of publish calls) once each.
class _Network extends PlatformAdapter {
  _Network({required this.threads, this.resumes = false, this.quota});

  /// Media in every post of a thread (else a series of separate posts).
  final bool threads;
  final bool resumes;
  final QuotaRule? quota;
  final published = <PostVariant>[];
  final failOn = <int>{};
  var calls = 0;

  @override
  PlatformDescriptor get descriptor => PlatformDescriptor(
        id: 'net',
        name: 'Net',
        tiers: const {PlatformTier.openApi},
        defaultTier: PlatformTier.openApi,
        text: TextRules(maxLength: 500, supportsThreads: threads),
        media: MediaRules(maxImages: 4, maxVideos: 1, mediaPerThreadPart: threads),
        accountRequirements: '',
        apiCostSummary: '',
        defaultQuotas: [?quota],
      );

  @override
  bool get resumesThreads => resumes;

  @override
  List<ConnectSpec> get connectSpecs => const [];

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) => throw UnimplementedError();

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    calls++;
    published.add(variant);
    final fail = failOn.remove(calls);
    if (!variant.isThread) {
      if (fail) return PublishResult.failure(const PublishError.network('connection reset', retryAfter: Duration.zero));
      return PublishResult.ok(remoteId: 'post-$calls', remoteUrl: 'https://net.example/post-$calls');
    }
    // A thread: one id per part, the parts after the live ones only.
    final ids = [...variant.postedThreadIds];
    for (var i = ids.length; i < variant.threadParts.length; i++) {
      if (fail && i == 1) {
        final e = const PublishError.network('connection reset');
        return PublishResult.partialFailure(resumes ? e.asResumableThread(postedIds: ids, total: variant.threadParts.length) : e,
            remoteId: ids.first, threadRemoteIds: ids);
      }
      ids.add('part-$calls-$i');
    }
    return PublishResult.ok(remoteId: ids.first, remoteUrl: 'https://net.example/${ids.first}', threadRemoteIds: ids);
  }
}

void main() {
  late InMemoryAccountRepository accounts;
  late InMemoryPostRepository posts;
  late InMemoryQuotaRepository quotas;

  PublishService service(PlatformAdapter adapter) => PublishService(
        registry: AdapterRegistry([adapter]),
        accounts: accounts,
        posts: posts,
        secrets: InMemorySecretStore(),
        quota: QuotaTracker(quotas),
        http: NeforumHttp(client: MockClient((_) async => http.Response('', 500)), maxRetries: 0),
        clock: () => testNow,
        log: Logger('test', sink: (level, area, msg, [err]) {}),
      );

  Future<void> savePost(int photos) => posts.upsert(Post(
        id: 'p1',
        text: 'Holiday',
        media: [for (var i = 0; i < photos; i++) fakeImage(id: 'img$i')],
        createdAt: testNow,
        updatedAt: testNow,
        targets: const [PostTarget(accountId: 'acct-1')],
      ));

  setUp(() async {
    accounts = InMemoryAccountRepository();
    posts = InMemoryPostRepository();
    quotas = InMemoryQuotaRepository();
    await accounts.upsert(fakeAccount('net'));
  });

  group('a series of separate posts', () {
    test('ten photos with four per post: three posts in order, every one recorded and counted', () async {
      final net = _Network(threads: false, quota: const QuotaRule(id: 'net.daily', limit: 100, window: Duration(days: 1), note: 'posts a day'));
      await savePost(10);
      final p = await service(net).publish('p1');
      final t = p.targets.single;
      expect(t.status, TargetStatus.published);
      expect(net.published.map((v) => v.media.map((m) => m.id).join(',')), [
        'img0,img1,img2,img3',
        'img4,img5,img6,img7',
        'img8,img9',
      ]);
      expect(net.published.map((v) => v.text), ['Holiday (1/3)', '(2/3)', '(3/3)']);
      expect(t.result!.remoteId, 'post-1');
      expect(t.result!.seriesRemoteIds, ['post-2', 'post-3']);
      expect(t.result!.allRemoteIds, ['post-1', 'post-2', 'post-3']);
      expect(await quotas.countSince('acct-1', 'net.daily', testNow.subtract(const Duration(days: 1))), 3);
    });

    test('a failure on post 2 keeps post 1 recorded; the next attempt posts only posts 2 and 3', () async {
      final net = _Network(threads: false)..failOn.add(2);
      await savePost(10);
      var p = await service(net).publish('p1');
      var t = p.targets.single;
      expect(t.status, TargetStatus.failed);
      expect(t.isPartlyLive, isTrue);
      expect(t.canResume, isTrue);
      expect(t.result!.remoteId, 'post-1');
      expect(t.result!.seriesRemoteIds, isEmpty);
      expect(t.result!.error!.message, allOf(contains('Post 2 of 3 failed'), contains('Retry posts the rest')));

      net.published.clear();
      p = await service(net).publish('p1');
      t = p.targets.single;
      expect(t.status, TargetStatus.published);
      expect(net.published.map((v) => v.text), ['(2/3)', '(3/3)'], reason: 'post 1 is not posted again');
      expect(t.result!.remoteId, 'post-1');
      expect(t.result!.remoteUrl, 'https://net.example/post-1');
      expect(t.result!.seriesRemoteIds, hasLength(2));
    });

    test('an attempt to finish that fails before anything more goes live still remembers what is live', () async {
      final net = _Network(threads: false)..failOn.addAll({2, 3});
      await savePost(10);
      await service(net).publish('p1');
      final p = await service(net).publish('p1');
      final t = p.targets.single;
      expect(t.status, TargetStatus.failed);
      expect(t.result!.remoteId, 'post-1', reason: 'never forgotten, so never posted twice');
      expect(t.canResume, isTrue);
    });

    test('more posts than the network allows in a while: refused before anything goes out', () async {
      final net = _Network(threads: false, quota: const QuotaRule(id: 'net.posts', limit: 2, window: Duration(minutes: 10), note: 'posts per 10 minutes'));
      await savePost(10);
      final p = await service(net).publish('p1');
      // Waits for the window to pass (a quota is retried), with nothing live.
      expect(p.targets.single.result!.error!.kind, PublishErrorKind.quota);
      expect(p.targets.single.isPartlyLive, isFalse);
      expect(net.published, isEmpty);
    });
  });

  group('a thread with media in every post', () {
    test('ten photos: a thread of three, posted by the adapter in one go', () async {
      final net = _Network(threads: true);
      await savePost(10);
      final p = await service(net).publish('p1');
      final v = net.published.single;
      expect(v.threadParts, ['Holiday (1/3)', '(2/3)', '(3/3)']);
      expect([for (var i = 0; i < 3; i++) v.mediaOfPart(i).length], [4, 4, 2]);
      expect(p.targets.single.result!.threadRemoteIds, hasLength(3));
    });

    test('a thread that broke off is finished from its live parts by an adapter that resumes threads', () async {
      final net = _Network(threads: true, resumes: true)..failOn.add(1);
      await savePost(10);
      var p = await service(net).publish('p1');
      var t = p.targets.single;
      expect(t.status, TargetStatus.failed);
      expect(t.canResume, isTrue);
      expect(t.result!.threadRemoteIds, ['part-1-0']);

      p = await service(net).publish('p1');
      t = p.targets.single;
      expect(t.status, TargetStatus.published);
      expect(net.published.last.postedThreadIds, ['part-1-0'], reason: 'the adapter is told what is live');
      expect(t.result!.threadRemoteIds, ['part-1-0', 'part-2-1', 'part-2-2']);
    });

    test('an adapter that cannot resume leaves a broken thread to be finished by hand, never posted again', () async {
      final net = _Network(threads: true)..failOn.add(1);
      await savePost(10);
      var p = await service(net).publish('p1');
      expect(p.targets.single.isPartlyLive, isTrue);
      expect(p.targets.single.canResume, isFalse);
      p = await service(net).publish('p1');
      expect(net.calls, 1, reason: 'not retried');
    });
  });
}
