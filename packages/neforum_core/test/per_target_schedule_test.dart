import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import 'support/test_context.dart';

/// A platform that records what it was asked to publish.
class _Platform extends PlatformAdapter {
  _Platform(this.platformId, {this.scheduling = false, this.stories = false});

  final String platformId;
  final bool scheduling;
  final bool stories;
  final published = <PostVariant>[];
  PublishResult Function(PostVariant v)? onPublish;

  @override
  PlatformDescriptor get descriptor => PlatformDescriptor(
        id: platformId,
        name: platformId == 'gram' ? 'Instagram' : 'Mastodon',
        tiers: const {PlatformTier.openApi},
        defaultTier: PlatformTier.openApi,
        text: const TextRules(maxLength: 500),
        media: const MediaRules(maxImages: 4),
        accountRequirements: '',
        apiCostSummary: '',
        serverSideScheduling: scheduling,
      );

  @override
  bool supportsStories(ConnectedAccount account) => stories;

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
    if (at != null) return PublishResult.scheduled(remoteId: 'held-$platformId', scheduledFor: at);
    return PublishResult.ok(remoteId: '$platformId-${published.length}');
  }
}

void main() {
  late _Platform mastodon;
  late _Platform gram;
  late InMemoryAccountRepository accounts;
  late InMemoryPostRepository posts;
  late InMemoryQuotaRepository quota;
  late DateTime now;
  final ten = testNow.add(const Duration(hours: 1));
  final six = testNow.add(const Duration(hours: 6));

  PublishService service() => PublishService(
        registry: AdapterRegistry([mastodon, gram]),
        accounts: accounts,
        posts: posts,
        secrets: InMemorySecretStore(),
        quota: QuotaTracker(quota),
        http: NeforumHttp(client: MockClient((_) async => http.Response('', 500)), maxRetries: 0),
        clock: () => now,
        log: Logger('test', sink: (level, area, msg, [err]) {}),
      );

  Post perTarget({Map<String, dynamic> gramExtra = const {}}) => Post(
        id: 'p1',
        text: 'Hello',
        createdAt: testNow,
        updatedAt: testNow,
        scheduledAt: ten,
        status: PostStatus.scheduled,
        targets: [
          PostTarget(accountId: 'masto', overrides: PostOverrides(scheduledAt: ten)),
          PostTarget(accountId: 'gram', overrides: PostOverrides(scheduledAt: six, extra: gramExtra)),
        ],
      );

  setUp(() async {
    mastodon = _Platform('masto');
    gram = _Platform('gram', stories: true);
    accounts = InMemoryAccountRepository();
    posts = InMemoryPostRepository();
    quota = InMemoryQuotaRepository();
    now = testNow;
    await accounts.upsert(fakeAccount('masto', id: 'masto'));
    await accounts.upsert(fakeAccount('gram', id: 'gram'));
  });

  group('due times', () {
    test('a target without a time of its own follows the post; one with its own time uses it', () {
      final p = perTarget().copyWith(targets: [
        const PostTarget(accountId: 'masto'),
        PostTarget(accountId: 'gram', overrides: PostOverrides(scheduledAt: six)),
      ]);
      expect(p.dueAtFor(p.targets[0]), ten);
      expect(p.dueAtFor(p.targets[1]), six);
      expect(p.schedulesEachTarget, isTrue);
      expect(p.isTargetDue(p.targets[0], ten), isTrue);
      expect(p.isTargetDue(p.targets[1], ten), isFalse);
      expect(p.isTargetDue(p.targets[1], six), isTrue);
    });

    test('the next due time is the earliest target still waiting; the post schedule follows it', () {
      final p = perTarget().copyWith(scheduledAt: six);
      expect(p.nextDueAt, ten);
      expect(p.withScheduleFromTargets().scheduledAt, ten);
      final half = p.withTarget(p.targets[0].copyWith(status: TargetStatus.published));
      expect(half.nextDueAt, six);
      expect(half.withScheduleFromTargets().scheduledAt, six);
      final done = half.withTarget(half.targets[1].copyWith(status: TargetStatus.published));
      expect(done.nextDueAt, isNull);
      expect(done.withScheduleFromTargets().scheduledAt, six, reason: 'nothing waits: the schedule stays as it was');
    });

    test('a post with one time for all is left alone', () {
      final p = perTarget().copyWith(targets: const [PostTarget(accountId: 'masto'), PostTarget(accountId: 'gram')]);
      expect(p.schedulesEachTarget, isFalse);
      expect(identical(p.withScheduleFromTargets(), p), isTrue);
    });
  });

  group('scheduler runs', () {
    test('publishes each target at its own time, and the post waits for the next one in between', () async {
      await posts.upsert(perTarget());
      final engine = ScheduleEngine(posts: posts, publisher: service(), clock: () => now);

      now = ten;
      final first = (await engine.runDue()).single;
      expect(mastodon.published, hasLength(1));
      expect(gram.published, isEmpty);
      expect(first.status, PostStatus.scheduled);
      expect(first.scheduledAt, six, reason: 'the queue and OS alarms read the next due time');
      expect(first.targetFor('masto')!.status, TargetStatus.published);
      expect(first.targetFor('gram')!.status, TargetStatus.pending);
      expect(await engine.nextDue(), six);

      now = ten.add(const Duration(minutes: 30));
      expect(await engine.runDue(), isEmpty, reason: 'nothing is due before 6');

      now = six;
      final last = (await engine.runDue()).single;
      expect(gram.published, hasLength(1));
      expect(mastodon.published, hasLength(1), reason: 'never posted twice');
      expect(last.status, PostStatus.published);
    });

    test('Publish now ignores the times and posts every target', () async {
      await posts.upsert(perTarget());
      final p = await service().publish('p1');
      expect(p.status, PostStatus.published);
      expect(mastodon.published, hasLength(1));
      expect(gram.published, hasLength(1));
    });

    test('cancelling the early run leaves the later target waiting', () async {
      await posts.upsert(perTarget());
      now = ten;
      final signal = CancellationSignal()..cancel();
      final p = await service().publish('p1', dueTargetsOnly: true, retryFailed: false, cancellation: signal);
      expect(p.targetFor('masto')!.status, TargetStatus.cancelled);
      expect(p.targetFor('gram')!.status, TargetStatus.pending);
      expect(p.status, PostStatus.scheduled);
      expect(p.scheduledAt, six);
    });

    test('platforms that hold posts get their own target time', () async {
      mastodon = _Platform('masto', scheduling: true);
      await posts.upsert(perTarget());
      final p = await service().delegateSchedules('p1');
      expect(mastodon.published.single.scheduledAt, ten);
      expect(p.targetFor('masto')!.status, TargetStatus.heldByPlatform);
      expect(p.scheduledAt, six, reason: 'the device only waits for the target it still has to post');

      // Swapped: the held target is the later one.
      mastodon = _Platform('masto', scheduling: true);
      await posts.upsert(perTarget().copyWith(targets: [
        PostTarget(accountId: 'masto', overrides: PostOverrides(scheduledAt: six)),
        PostTarget(accountId: 'gram', overrides: PostOverrides(scheduledAt: ten)),
      ]));
      final q = await service().delegateSchedules('p1');
      expect(mastodon.published.single.scheduledAt, six);
      expect(q.scheduledAt, ten);
    });
  });

  group('copies of one target', () {
    test('a story that fails after the feed post keeps the live ids, fails without retry, and counts both posts', () async {
      await posts.upsert(perTarget(gramExtra: const {kPlacementKey: 'feedAndStory'}));
      gram.onPublish = (_) => PublishResult.partialFailure(const PublishError.network('story timed out'),
          remoteId: 'feed-1', additionalRemoteIds: const ['story-1']);
      now = six;
      final p = await service().publish('p1', dueTargetsOnly: true, retryFailed: false);
      final t = p.targetFor('gram')!;
      expect(t.status, TargetStatus.failed, reason: 'a retry would post the feed post again');
      expect(t.result!.allRemoteIds, ['feed-1', 'story-1']);
      expect(t.result!.error!.retryable, isFalse);
      expect(p.status, PostStatus.partial);
    });

    test('quota needs one post for the feed and one per story frame', () async {
      final limited = _Limited('gram');
      mastodon = _Platform('masto');
      gram = limited;
      await posts.upsert(perTarget(gramExtra: const {kPlacementKey: 'feedAndStory'}).copyWith(media: [fakeImage(id: 'a'), fakeImage(id: 'b')]));
      now = six;
      final p = await service().publish('p1');
      // Feed post + 2 frames = 3 > the limit of 2: waits for the quota.
      expect(p.targetFor('gram')!.status, TargetStatus.pending);
      expect(p.targetFor('gram')!.result!.error!.kind, PublishErrorKind.quota);
      expect(limited.published, isEmpty);
    });
  });

  group('saved posts', () {
    test('per-target times and story copies survive a JSON round trip', () {
      final p = perTarget().copyWith(targets: [
        PostTarget(accountId: 'gram', overrides: PostOverrides(scheduledAt: six, storyMediaIds: const ['s1'], extra: const {kPlacementKey: 'feedAndStory'})),
      ]);
      final back = Post.fromJson(p.toJson());
      final o = back.targets.single.overrides;
      expect(o.scheduledAt, six.toLocal());
      expect(o.storyMediaIds, ['s1']);
      expect(o.isEmpty, isFalse);
      expect(back.dueAtFor(back.targets.single), six.toLocal());
    });

    test('a post saved by 1.2 loads unchanged: one time for all, no story copies', () {
      final json = {
        'id': 'old',
        'text': 'From 1.2',
        'createdAt': '2026-10-01T10:00:00.000Z',
        'updatedAt': '2026-10-01T10:00:00.000Z',
        'media': <Object>[],
        'sensitive': false,
        'visibility': 'public',
        'scheduledAt': '2026-10-20T18:00:00.000Z',
        'targets': [
          {
            'accountId': 'gram',
            'overrides': {
              'extra': {'storyMode': true}
            },
            'status': 'pending',
            'attempts': 0,
          }
        ],
        'status': 'scheduled',
        'tags': <Object>[],
      };
      final p = Post.fromJson(json);
      final t = p.targets.single;
      expect(t.overrides.scheduledAt, isNull);
      expect(t.overrides.storyMediaIds, isNull);
      expect(p.schedulesEachTarget, isFalse);
      expect(p.dueAtFor(t), DateTime.parse('2026-10-20T18:00:00.000Z').toLocal());
      expect(placementOfExtra(t.overrides.extra), PostPlacement.story);
      // Nothing new is written for it, so a 1.2 device reads it back the same.
      expect(t.overrides.toJson(), {
        'extra': {'storyMode': true}
      });
    });
  });
}

/// A platform allowing two posts a day.
class _Limited extends _Platform {
  _Limited(super.platformId) : super(stories: true);

  @override
  PlatformDescriptor get descriptor => PlatformDescriptor(
        id: platformId,
        name: 'Instagram',
        tiers: const {PlatformTier.openApi},
        defaultTier: PlatformTier.openApi,
        text: const TextRules(maxLength: 500),
        media: const MediaRules(maxImages: 4),
        accountRequirements: '',
        apiCostSummary: '',
        defaultQuotas: const [QuotaRule(id: 'gram.posts', limit: 2, window: Duration(hours: 24), note: 'posts a day')],
      );
}
