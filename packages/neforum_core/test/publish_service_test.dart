import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import 'support/test_context.dart';

/// A platform that records what it was asked to do.
class _FakeAdapter extends PlatformAdapter {
  _FakeAdapter({this.scheduling = true, this.maxLength = 500});

  final bool scheduling;
  final int maxLength;
  final published = <PostVariant>[];
  final cancelled = <String>[];
  PublishResult Function(PostVariant v)? onPublish;
  Object? cancelError;

  @override
  PlatformDescriptor get descriptor => PlatformDescriptor(
        id: 'fake',
        name: 'Fake',
        tiers: const {PlatformTier.openApi, PlatformTier.handoff},
        defaultTier: PlatformTier.openApi,
        text: TextRules(maxLength: maxLength, supportsThreads: true),
        media: const MediaRules(maxImages: 4),
        accountRequirements: '',
        apiCostSummary: '',
        serverSideScheduling: scheduling,
      );

  @override
  List<ConnectSpec> get connectSpecs => const [];

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) => throw UnimplementedError();

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    published.add(variant);
    final custom = onPublish;
    if (custom != null) return custom(variant);
    final at = variant.scheduledAt;
    if (at != null) return PublishResult.scheduled(remoteId: 'held-${published.length}', scheduledFor: at);
    return PublishResult.ok(remoteId: 'post-${published.length}');
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) =>
      HandoffPlan(platformId: 'fake', instructions: 'Tap Post', clipboardText: variant.text);

  @override
  Future<void> cancelScheduled(PublishResult held, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final e = cancelError;
    if (e != null) throw e;
    cancelled.add(held.remoteId!);
  }
}

void main() {
  late _FakeAdapter adapter;
  late InMemoryAccountRepository accounts;
  late InMemoryPostRepository posts;
  late DateTime now;
  final at = testNow.add(const Duration(hours: 2));

  PublishService service() => PublishService(
        registry: AdapterRegistry([adapter]),
        accounts: accounts,
        posts: posts,
        secrets: InMemorySecretStore(),
        quota: QuotaTracker(InMemoryQuotaRepository()),
        http: NeforumHttp(client: MockClient((_) async => http.Response('', 500)), maxRetries: 0),
        clock: () => now,
        log: Logger('test', sink: (level, area, msg, [err]) {}),
      );

  Future<Post> scheduled({String text = 'Hello there', DateTime? when}) async {
    final p = Post(
      id: 'p1',
      text: text,
      createdAt: testNow,
      updatedAt: testNow,
      scheduledAt: when ?? at,
      status: PostStatus.scheduled,
      targets: const [PostTarget(accountId: 'acct-1')],
    );
    await posts.upsert(p);
    return p;
  }

  setUp(() async {
    adapter = _FakeAdapter();
    accounts = InMemoryAccountRepository();
    posts = InMemoryPostRepository();
    now = testNow;
    await accounts.upsert(fakeAccount('fake'));
  });

  group('delegateSchedules', () {
    test('hands the post to a platform that can hold it', () async {
      await scheduled();
      final p = await service().delegateSchedules('p1');
      final t = p.targets.single;
      expect(t.status, TargetStatus.heldByPlatform);
      expect(t.result!.isHeldByPlatform, isTrue);
      expect(t.result!.scheduledFor, at);
      expect(adapter.published.single.scheduledAt, at);
      expect(p.status, PostStatus.scheduled);
      expect(p.needsDeviceAtSchedule, isFalse);
      expect((await posts.get('p1'))!.targets.single.status, TargetStatus.heldByPlatform);
    });

    test('keeps threads on the device: replies need the first part', () async {
      adapter = _FakeAdapter(maxLength: 20);
      await scheduled(text: 'This text is far too long for twenty characters, so it becomes a thread.');
      final p = await service().delegateSchedules('p1');
      expect(p.targets.single.status, TargetStatus.pending);
      expect(adapter.published, isEmpty);
      expect(p.needsDeviceAtSchedule, isTrue);
    });

    test('keeps platforms without server-side scheduling on the device', () async {
      adapter = _FakeAdapter(scheduling: false);
      await scheduled();
      final p = await service().delegateSchedules('p1');
      expect(p.targets.single.status, TargetStatus.pending);
      expect(adapter.published, isEmpty);
    });

    test('does nothing for a schedule that has already passed', () async {
      await scheduled(when: testNow.subtract(const Duration(minutes: 1)));
      final p = await service().delegateSchedules('p1');
      expect(p.targets.single.status, TargetStatus.pending);
      expect(adapter.published, isEmpty);
    });

    test('a platform error leaves the target for the local scheduler', () async {
      adapter.onPublish = (_) => PublishResult.failure(const PublishError.network('offline'));
      await scheduled();
      final p = await service().delegateSchedules('p1');
      final t = p.targets.single;
      expect(t.status, TargetStatus.pending);
      expect(t.attempts, 0);
      expect(t.result, isNull);
    });

    test('a server that ignores the schedule counts as published', () async {
      adapter.onPublish = (_) => PublishResult.ok(remoteId: 'now');
      await scheduled();
      final p = await service().delegateSchedules('p1');
      expect(p.targets.single.status, TargetStatus.published);
    });
  });

  group('held posts at their time', () {
    test('are recorded as published without posting again', () async {
      await scheduled();
      await service().delegateSchedules('p1');
      now = at.add(const Duration(minutes: 1));
      final p = await service().publish('p1', interactive: false, retryFailed: false);
      expect(p.targets.single.status, TargetStatus.published);
      expect(p.targets.single.result!.isHeldByPlatform, isFalse);
      expect(p.targets.single.result!.publishedAt, at);
      expect(p.status, PostStatus.published);
      expect(adapter.published, hasLength(1), reason: 'only the hand-over');
    });

    test('are left alone by an early run', () async {
      await scheduled();
      await service().delegateSchedules('p1');
      final p = await service().publish('p1', interactive: false, retryFailed: false);
      expect(p.targets.single.status, TargetStatus.heldByPlatform);
      expect(p.status, PostStatus.scheduled);
      expect(adapter.published, hasLength(1));
    });
  });

  group('releaseSchedules', () {
    test('takes the copy back and returns the target to pending', () async {
      await scheduled();
      await service().delegateSchedules('p1');
      final out = await service().releaseSchedules('p1');
      expect(out.ok, isTrue);
      expect(adapter.cancelled, ['held-1']);
      expect(out.post.targets.single.status, TargetStatus.pending);
      expect(out.post.targets.single.result, isNull);
      expect((await posts.get('p1'))!.hasHeldTargets, isFalse);
    });

    test('a failed cancel keeps the target held and says why', () async {
      await scheduled();
      await service().delegateSchedules('p1');
      adapter.cancelError = const AdapterException(PublishError.network('offline'));
      final out = await service().releaseSchedules('p1');
      expect(out.ok, isFalse);
      expect(out.failed['acct-1']!.message, 'offline');
      expect(out.post.targets.single.status, TargetStatus.heldByPlatform);
    });

    test('never races a copy that is about to go out', () async {
      await scheduled();
      await service().delegateSchedules('p1');
      now = at.subtract(const Duration(minutes: 1));
      final out = await service().releaseSchedules('p1');
      expect(out.ok, isFalse);
      expect(adapter.cancelled, isEmpty);
      expect(out.post.targets.single.status, TargetStatus.heldByPlatform);
    });

    test('a copy whose time has passed is live, not cancelled', () async {
      await scheduled();
      await service().delegateSchedules('p1');
      now = at.add(const Duration(minutes: 3));
      final out = await service().releaseSchedules('p1');
      expect(out.ok, isTrue);
      expect(out.alreadyLive, {'acct-1'});
      expect(adapter.cancelled, isEmpty);
      expect(out.post.targets.single.status, TargetStatus.published);
    });
  });

  test('a normal publish never hands the schedule over, even when the account asks', () async {
    await accounts.upsert(fakeAccount('fake', config: const {
      'postDefaults': {'delegateSchedule': true},
    }));
    await scheduled();
    final p = await service().publish('p1');
    expect(adapter.published.single.scheduledAt, isNull);
    expect(p.targets.single.status, TargetStatus.published);
  });

  test('a quota error after part of a thread went out is not handed off', () async {
    adapter.onPublish = (_) => PublishResult.failure(const PublishError.quota('Monthly cap').asPartialThread(postedIds: ['a'], total: 3));
    await scheduled(when: testNow);
    final p = await service().publish('p1', interactive: false);
    expect(p.targets.single.status, TargetStatus.failed);
    expect(p.targets.single.result!.error!.retryable, isFalse);
  });

  test('generated media only reaches the targets that list it', () {
    final card = MediaAttachment(id: 'card', path: '/tmp/card.jpg', mimeType: 'image/jpeg', sizeBytes: 10, generated: true);
    final photo = fakeImage();
    final post = Post(id: 'x', text: 'hi', createdAt: testNow, updatedAt: testNow, media: [photo, card], targets: const [
      PostTarget(accountId: 'a'),
      PostTarget(accountId: 'b', overrides: PostOverrides(mediaIds: ['card'])),
    ]);
    const resolver = VariantResolver();
    final d = adapter.descriptor;
    expect(resolver.resolve(post, post.targets[0], d).media.map((m) => m.id), ['img1']);
    expect(resolver.resolve(post, post.targets[1], d).media.map((m) => m.id), ['card']);
    final json = MediaAttachment.fromJson(card.toJson());
    expect(json.generated, isTrue);
  });

  test('held results survive a JSON round trip', () {
    final r = PublishResult.scheduled(remoteId: 'h1', scheduledFor: at, remoteUrl: 'https://example.test');
    final back = PublishResult.fromJson(r.toJson());
    expect(back.isHeldByPlatform, isTrue);
    expect(back.scheduledFor, at);
    expect(back.asReleased().isHeldByPlatform, isFalse);
    expect(TargetStatus.values.byName(TargetStatus.heldByPlatform.name), TargetStatus.heldByPlatform);
  });
}
