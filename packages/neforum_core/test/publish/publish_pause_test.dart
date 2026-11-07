// iOS can freeze a backgrounded app at any moment. While a run is paused for that,
// no request that makes a post starts, and nothing that was only held back spends an
// attempt: a held target that is killed reads as never tried.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

/// A network with an upload and a post.
class _Net extends PlatformAdapter {
  _Net(this.key);

  final String key;
  int uploads = 0;
  int posts = 0;

  @override
  SignInPolicy signInPolicyFor(ConnectedAccount account) => SignInPolicy.noConnection;

  @override
  PlatformDescriptor get descriptor => PlatformDescriptor(
        id: key,
        name: key,
        tiers: const {PlatformTier.openApi},
        defaultTier: PlatformTier.openApi,
        text: const TextRules(maxLength: 500),
        media: const MediaRules(maxImages: 4),
        accountRequirements: '',
        apiCostSummary: '',
      );

  @override
  List<ConnectSpec> get connectSpecs => const [];

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) => throw UnimplementedError();

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    uploads++;
    await ctx.http.postJson(Uri.parse('https://$key.test/upload'), {'bytes': 'x'});
    await ctx.creating('Posting', () async {
      posts++;
    });
    return PublishResult.ok(remoteId: 'post-$posts');
  }
}

void main() {
  late InMemoryPostRepository posts;
  late InMemoryAccountRepository accounts;
  late List<String> requests;

  Future<PublishService> service(List<_Net> nets) async {
    for (final n in nets) {
      await accounts.upsert(fakeAccount(n.key, id: n.key));
    }
    return PublishService(
      registry: AdapterRegistry(nets),
      accounts: accounts,
      posts: posts,
      secrets: InMemorySecretStore(),
      quota: QuotaTracker(InMemoryQuotaRepository()),
      http: NeforumHttp(
          client: MockClient((r) async {
            requests.add(r.url.toString());
            return http.Response(jsonEncode({'ok': true}), 200);
          }),
          maxRetries: 0),
    );
  }

  Future<void> savePost(List<String> ids) => posts.upsert(Post(
        id: 'p1',
        text: 'hello',
        createdAt: testNow,
        updatedAt: testNow,
        status: PostStatus.publishing,
        targets: [for (final id in ids) PostTarget(accountId: id)],
      ));

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  setUp(() {
    posts = InMemoryPostRepository();
    accounts = InMemoryAccountRepository();
    requests = [];
  });

  test('no creating call starts after a pause, and uploads go on', () async {
    final net = _Net('a');
    final s = await service([net]);
    await savePost(['a']);
    final pause = PublishPauseSignal()..pause();
    final run = s.publish('p1', pause: pause);
    await settle();
    expect(net.uploads, 1);
    expect(requests, ['https://a.test/upload'], reason: 'a file sent twice costs time, a post sent twice is what must not happen');
    expect(net.posts, 0);
    pause.resume();
    final done = await run;
    expect(net.posts, 1);
    expect(done.targets.single.status, TargetStatus.published);
  });

  test('a pause between two networks: the first stands, the second waits', () async {
    final a = _Net('a');
    final b = _Net('b');
    final s = await service([a, b]);
    await savePost(['a', 'b']);
    final pause = PublishPauseSignal();
    // Paused the moment the first network has its post.
    final run = s.publish('p1', pause: pause, onOutcome: (id, _) {
      if (id == 'a') pause.pause();
    });
    await settle();
    expect((a.posts, b.uploads, b.posts), (1, 1, 0));
    final saved = (await posts.get('p1'))!;
    expect(saved.targetFor('a')!.status, TargetStatus.published);
    expect(saved.targetFor('b')!.attempts, 0);
    pause.resume();
    final done = await run;
    expect((a.posts, b.posts), (1, 1));
    expect(done.targets.map((t) => t.status), everyElement(TargetStatus.published));
    expect(done.targets.map((t) => t.attempts), everyElement(1));
  });

  test('held back, a target has spent no attempt on disk', () async {
    final net = _Net('a');
    final s = await service([net]);
    await savePost(['a']);
    final pause = PublishPauseSignal()..pause();
    final run = s.publish('p1', pause: pause);
    await settle();
    final saved = (await posts.get('p1'))!.targets.single;
    expect(saved.attempts, 0, reason: 'a kill right now must read as never tried');
    expect(saved.status, TargetStatus.pending);
    expect(saved.result, isNull);
    pause.resume();
    final done = await run;
    expect(done.targets.single.attempts, 1, reason: 'one attempt, for the one post');
  });

  test('a long pause and many resumes change neither attempts nor the number of posts', () async {
    final net = _Net('a');
    final s = await service([net]);
    await savePost(['a']);
    final pause = PublishPauseSignal()..pause();
    final run = s.publish('p1', pause: pause);
    for (var i = 0; i < 5; i++) {
      await settle();
      pause.resume();
      pause.pause();
    }
    pause.resume();
    final done = await run;
    expect(net.posts, 1);
    expect(done.targets.single.attempts, 1);
  });

  test('Cancel ends the wait, and the target is cancelled with nothing posted', () async {
    final net = _Net('a');
    final s = await service([net]);
    await savePost(['a']);
    final pause = PublishPauseSignal()..pause();
    final signal = CancellationSignal();
    final run = s.publish('p1', pause: pause, cancellation: signal);
    await settle();
    signal.cancel();
    final done = await run;
    expect(net.posts, 0);
    expect(done.targets.single.status, TargetStatus.cancelled);
    expect(done.targets.single.result?.error?.outcomeUnknown, isNot(isTrue), reason: 'nothing went out, so nothing needs checking');
  });

  test('the signal itself', () async {
    final pause = PublishPauseSignal();
    expect(pause.isPaused, isFalse);
    await pause.whenResumed;
    pause.pause();
    pause.pause();
    expect(pause.isPaused, isTrue);
    var woke = false;
    unawaited(pause.whenResumed.then((_) => woke = true));
    await settle();
    expect(woke, isFalse);
    pause.resume();
    await settle();
    expect(woke, isTrue);
    expect(pause.isPaused, isFalse);
    pause.resume();
  });
}
