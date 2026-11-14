// 1.4.3: the user's publishing order. Automatic accounts go first and hand-offs
// after them, each group in the order the user set; an account the order does
// not list yet goes last in its group. Runs in the foreground and in the
// background follow it, and the plan the progress sheet shows lists it.

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

ConnectedAccount _account(String id, {PlatformTier tier = PlatformTier.openApi, int day = 1}) => ConnectedAccount(
      id: id,
      platformId: 'net',
      tier: tier,
      displayName: 'Account $id',
      createdAt: DateTime.utc(2026, 9, day),
    );

void main() {
  group('inPublishingOrder', () {
    final accounts = {
      'a': _account('a', day: 1),
      'b': _account('b', day: 2),
      'c': _account('c', day: 3),
      'h1': _account('h1', tier: PlatformTier.handoff, day: 4),
      'h2': _account('h2', tier: PlatformTier.handoff, day: 5),
    };
    List<String> ordered(List<String> ids, List<String>? order) =>
        inPublishingOrder(ids, accountIdOf: (id) => id, accountOf: (id) => accounts[id], order: order);

    test('each group follows the saved order', () {
      expect(ordered(['a', 'b', 'c', 'h1', 'h2'], ['c', 'a', 'b', 'h2', 'h1']), ['c', 'a', 'b', 'h2', 'h1']);
    });

    test('hand-offs come after every automatic account, wherever the order lists them', () {
      expect(ordered(['h1', 'a', 'h2', 'b'], ['h2', 'h1', 'b', 'a']), ['b', 'a', 'h2', 'h1']);
    });

    test('an account the order leaves out comes last in its group, the oldest first', () {
      // c and h2 were connected after the order was saved; b before it, but never listed.
      expect(ordered(['c', 'h2', 'a', 'b', 'h1'], ['a', 'h1']), ['a', 'b', 'c', 'h1', 'h2']);
    });

    test('an empty order is the order the accounts were connected in', () {
      expect(ordered(['c', 'h2', 'b', 'h1', 'a'], const []), ['a', 'b', 'c', 'h1', 'h2']);
    });

    test('without an order each group keeps the order of the items', () {
      expect(ordered(['c', 'h2', 'a', 'h1', 'b'], null), ['c', 'a', 'b', 'h2', 'h1']);
    });

    test('an account nobody knows goes with the automatic ones, after them', () {
      expect(ordered(['gone', 'h1', 'a'], ['gone', 'h1', 'a']), ['gone', 'a', 'h1'], reason: 'listed: its place in the order counts');
      expect(ordered(['gone', 'h1', 'b', 'a'], ['a']), ['a', 'b', 'gone', 'h1'], reason: 'unlisted: after the known ones');
    });

    test('an id listed twice counts where it is listed first', () {
      expect(ordered(['a', 'b'], ['b', 'a', 'b']), ['b', 'a']);
    });
  });

  group('a publish run', () {
    late InMemoryAccountRepository accounts;
    late InMemoryPostRepository posts;
    late _Net net;
    late List<String> saved;
    late List<String> order;

    PublishService service({bool withOrder = true}) => PublishService(
          registry: AdapterRegistry([net]),
          accounts: accounts,
          posts: posts,
          secrets: InMemorySecretStore(),
          quota: QuotaTracker(InMemoryQuotaRepository()),
          http: NeforumHttp(client: MockClient((_) async => http.Response('', 500)), maxRetries: 0),
          handoffLauncher: _Launcher((id) => order.add('sheet $id')),
          publishingOrder: withOrder ? () => saved : null,
          clock: () => testNow,
          log: Logger('test', sink: (l, a, m, [e]) {}),
        );

    Future<void> save(List<String> ids, {DateTime? scheduledAt}) => posts.upsert(Post(
          id: 'p1',
          text: 'Hello',
          createdAt: testNow,
          updatedAt: testNow,
          status: scheduledAt == null ? PostStatus.draft : PostStatus.scheduled,
          scheduledAt: scheduledAt,
          targets: [for (final id in ids) PostTarget(accountId: id)],
        ));

    setUp(() async {
      accounts = InMemoryAccountRepository();
      posts = InMemoryPostRepository();
      net = _Net();
      order = [];
      net.onStart = order.add;
      for (final a in [
        _account('a', day: 1),
        _account('b', day: 2),
        _account('c', day: 3),
        _account('h1', tier: PlatformTier.handoff, day: 4),
        _account('h2', tier: PlatformTier.handoff, day: 5),
      ]) {
        await accounts.upsert(a);
      }
      saved = ['c', 'a', 'b', 'h2', 'h1'];
    });

    test('posts in the saved order within each group, hand-offs last', () async {
      // Selected in another order, hand-offs first.
      await save(['h1', 'a', 'h2', 'b', 'c']);
      PublishRunPlan? plan;
      await service().publish('p1', onPlan: (p) => plan = p);
      expect(order, ['c', 'a', 'b', 'sheet h2', 'sheet h1']);
      expect(plan!.targets.map((t) => t.accountId), ['c', 'a', 'b', 'h2', 'h1'], reason: 'the progress sheet lists the run in its order');
    });

    test('hand-offs stay last even when the order lists them first', () async {
      saved = ['h2', 'h1', 'b', 'a', 'c'];
      await save(['a', 'b', 'c', 'h1', 'h2']);
      await service().publish('p1');
      expect(order, ['b', 'a', 'c', 'sheet h2', 'sheet h1']);
    });

    test('an account connected after the order was saved goes last in its group', () async {
      await accounts.upsert(_account('new', day: 20));
      await accounts.upsert(_account('newhand', tier: PlatformTier.handoff, day: 21));
      await save(['newhand', 'new', 'a', 'h1', 'c']);
      await service().publish('p1');
      expect(order, ['c', 'a', 'new', 'sheet h1', 'sheet newhand']);
    });

    test('the order is read as each run starts', () async {
      final publisher = service();
      await save(['a', 'b']);
      await publisher.publish('p1');
      expect(order, ['a', 'b']);
      order.clear();
      saved = ['b', 'a'];
      await save(['a', 'b']);
      await publisher.publish('p1');
      expect(order, ['b', 'a']);
    });

    test('a scheduled run in the background follows it too', () async {
      await save(['h1', 'a', 'b', 'c'], scheduledAt: testNow.subtract(const Duration(minutes: 1)));
      PublishRunPlan? plan;
      final done = await service().publish('p1', interactive: false, retryFailed: false, dueTargetsOnly: true, onPlan: (p) => plan = p);
      expect(order, ['c', 'a', 'b'], reason: 'a background run opens no sheet');
      expect(plan!.targets.map((t) => t.accountId), ['c', 'a', 'b', 'h1']);
      expect(done.targetFor('h1')!.status, TargetStatus.awaitingHandoff);
    });

    test('targetsInPublishingOrder lists the targets as a run takes them', () async {
      await save(['h1', 'b', 'gone', 'a']);
      final post = (await posts.get('p1'))!;
      expect((await service().targetsInPublishingOrder(post)).map((t) => t.accountId), ['a', 'b', 'gone', 'h1']);
    });

    test('without an order each group keeps the post\'s order, as before 1.4.3', () async {
      await save(['h1', 'b', 'c', 'a']);
      await service(withOrder: false).publish('p1');
      expect(order, ['b', 'c', 'a', 'sheet h1']);
    });
  });
}

class _Net extends PlatformAdapter {
  void Function(String id)? onStart;

  @override
  SignInPolicy signInPolicyFor(ConnectedAccount account) => SignInPolicy.noConnection;

  @override
  PlatformDescriptor get descriptor => const PlatformDescriptor(
        id: 'net',
        name: 'Net',
        tiers: {PlatformTier.openApi, PlatformTier.handoff},
        defaultTier: PlatformTier.openApi,
        text: TextRules(maxLength: 500),
        media: MediaRules(maxImages: 4),
        accountRequirements: '',
        apiCostSummary: '',
      );

  @override
  List<ConnectSpec> get connectSpecs => const [];

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) => throw UnimplementedError();

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    onStart?.call(account.id);
    return PublishResult.ok(remoteId: 'post-${account.id}');
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) => HandoffPlan(platformId: 'net', instructions: 'Tap Post', clipboardText: variant.text);
}

class _Launcher implements HandoffLauncher {
  _Launcher(this.onShown);

  final void Function(String accountId) onShown;

  @override
  Future<HandoffResult> launch(HandoffPlan plan, {required Post post, required PostTarget target, required PostVariant variant, required ConnectedAccount account}) async {
    onShown(account.id);
    return HandoffResult.launched;
  }
}
