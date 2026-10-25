import 'dart:async';
import 'dart:convert';

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

/// Publishing that only ends when the user cancels.
class _AwaitingAdapter extends _FakeAdapter {
  _AwaitingAdapter(this.signal);
  final CancellationSignal signal;

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    published.add(variant);
    Future<void>.delayed(const Duration(milliseconds: 20), signal.cancel);
    await ctx.cancellation!.whenCancelled;
    ctx.throwIfCancelled();
    return PublishResult.ok(remoteId: 'never');
  }
}

/// Posts through the context's HTTP client, as real adapters do.
class _HttpAdapter extends _FakeAdapter {
  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final res = await ctx.http.postJson(Uri.parse('https://fake.example.test/posts'), {'text': variant.text});
    return PublishResult.ok(remoteId: res.jsonMap['id'] as String?);
  }
}

/// Renews its sign-in through the context's HTTP client, and the network
/// retires the old refresh token as it answers (X, Tumblr, DeviantArt).
class _RenewingAdapter extends _FakeAdapter {
  @override
  bool rotatesRefreshTokensFor(ConnectedAccount account) => true;

  @override
  Future<Map<String, String>?> refreshSecrets(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final res = await ctx.http.postJson(Uri.parse('https://fake.example.test/token'), {'refresh_token': secrets['refresh']});
    return {'refresh': res.jsonMap['refresh'] as String};
  }
}

/// Takes a while to upload, and looks around while it does.
class _SlowAdapter extends _FakeAdapter {
  _SlowAdapter(this.whileUploading);
  final Future<void> Function() whileUploading;

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    published.add(variant);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await whileUploading();
    return PublishResult.ok(remoteId: 'slow');
  }
}

/// A platform whose checks break instead of returning issues.
class _BrokenCheckAdapter extends _FakeAdapter {
  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) => throw StateError('rules table missing');
}

/// Answers the token request only when the test lets it.
class _GatedClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final answer = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    await answer.future;
    return http.StreamedResponse(Stream.value(utf8.encode('{"refresh":"new-token"}')), 200,
        headers: const {'content-type': 'application/json'}, request: request);
  }
}

/// Posts whose writes fail while [fails] says so, the way a posts.json held
/// by a backup program does.
class _UnwritablePostRepository extends InMemoryPostRepository {
  bool Function(Post post) fails = (_) => false;

  @override
  Future<void> upsert(Post post) async {
    if (fails(post)) throw StateError('posts.json is locked');
    await super.upsert(post);
  }
}

/// A usage count that cannot be written.
class _UnwritableQuotaRepository extends InMemoryQuotaRepository {
  @override
  Future<void> record(QuotaEvent event) async => throw StateError('quota.json is locked');
}

/// Holds every request until it is aborted.
class _HangingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final aborted = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final trigger = request is http.Abortable ? request.abortTrigger : null;
    if (trigger == null) return Completer<http.StreamedResponse>().future;
    await trigger;
    aborted.add(request.url);
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  late _FakeAdapter adapter;
  late InMemoryAccountRepository accounts;
  late InMemoryPostRepository posts;
  late DateTime now;
  final at = testNow.add(const Duration(hours: 2));

  PublishService service({SecretStore? secrets, NeforumHttp? network, QuotaRepository? quotaRepo, PublishJournal? journal}) => PublishService(
        registry: AdapterRegistry([adapter]),
        accounts: accounts,
        posts: posts,
        secrets: secrets ?? InMemorySecretStore(),
        quota: QuotaTracker(quotaRepo ?? InMemoryQuotaRepository()),
        http: network ?? NeforumHttp(client: MockClient((_) async => http.Response('', 500)), maxRetries: 0),
        journal: journal,
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

  group('cancelling', () {
    Future<void> twoTargets() async {
      await accounts.upsert(fakeAccount('fake', id: 'acct-2'));
      await posts.upsert(Post(
        id: 'p1',
        text: 'Hello there',
        createdAt: testNow,
        updatedAt: testNow,
        status: PostStatus.publishing,
        targets: const [PostTarget(accountId: 'acct-1'), PostTarget(accountId: 'acct-2')],
      ));
    }

    test('before the run: nothing is posted, every target is cancelled', () async {
      await twoTargets();
      final signal = CancellationSignal()..cancel();
      final p = await service().publish('p1', cancellation: signal);
      expect(adapter.published, isEmpty);
      expect(p.targets.map((t) => t.status), [TargetStatus.cancelled, TargetStatus.cancelled]);
      expect(p.targets.first.result!.error!.kind, PublishErrorKind.cancelled);
      expect(p.status, PostStatus.cancelled);
      expect((await posts.get('p1'))!.status, PostStatus.cancelled);
    });

    test('during a target: it and the rest are cancelled, nothing is retried later', () async {
      await twoTargets();
      final signal = CancellationSignal();
      adapter = _AwaitingAdapter(signal);
      final p = await service().publish('p1', cancellation: signal, interactive: false);
      expect(p.targets.map((t) => t.status), [TargetStatus.cancelled, TargetStatus.cancelled]);
      expect(p.targets.first.attempts, 1);
      expect(p.targets.last.attempts, 0);
      expect(p.status, PostStatus.cancelled, reason: 'not scheduled: the scheduler must not post it again');
      expect(await posts.due(testNow.add(const Duration(days: 1))), isEmpty);
    });

    test('after the first target: what went out stays published', () async {
      await twoTargets();
      final signal = CancellationSignal();
      adapter.onPublish = (v) {
        signal.cancel();
        return PublishResult.ok(remoteId: 'live');
      };
      final p = await service().publish('p1', cancellation: signal);
      expect(p.targets.first.status, TargetStatus.published);
      expect(p.targets.last.status, TargetStatus.cancelled);
      expect(adapter.published, hasLength(1));
      expect(p.status, PostStatus.partial);
    });

    test('cancelled targets wait for the user: skipped by unattended runs, posted by a retry', () async {
      await twoTargets();
      await service().publish('p1', cancellation: CancellationSignal()..cancel());
      final unattended = await service().publish('p1', interactive: false, retryFailed: false);
      expect(unattended.targets.map((t) => t.status), [TargetStatus.cancelled, TargetStatus.cancelled]);
      expect(adapter.published, isEmpty);
      final retried = await service().publish('p1', onlyAccountIds: {'acct-2'});
      expect(retried.targets.last.status, TargetStatus.published);
      expect(retried.targets.first.status, TargetStatus.cancelled);
      expect(retried.status, PostStatus.partial);
    });

    test('a thread cut off halfway says which parts are live', () async {
      await twoTargets();
      final signal = CancellationSignal();
      adapter.onPublish = (v) {
        signal.cancel();
        return PublishResult.failure(const PublishError.network('aborted').asPartialThread(postedIds: ['a'], total: 3));
      };
      final p = await service().publish('p1', cancellation: signal);
      final t = p.targets.first;
      expect(t.status, TargetStatus.cancelled);
      expect(t.result!.error!.kind, PublishErrorKind.cancelled);
      expect(t.result!.error!.message, contains('Parts already posted (a)'));
    });

    test('the adapter\'s request is aborted', () async {
      final client = _HangingClient();
      final signal = CancellationSignal();
      adapter = _HttpAdapter();
      final svc = PublishService(
        registry: AdapterRegistry([adapter]),
        accounts: accounts,
        posts: posts,
        secrets: InMemorySecretStore(),
        quota: QuotaTracker(InMemoryQuotaRepository()),
        http: NeforumHttp(client: client, maxRetries: 0),
        clock: () => now,
        log: Logger('test', sink: (level, area, msg, [err]) {}),
      );
      await scheduled(when: testNow);
      final run = svc.publish('p1', cancellation: signal);
      while (client.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      signal.cancel();
      final p = await run;
      expect(client.aborted, hasLength(1));
      expect(p.targets.single.status, TargetStatus.cancelled);
      expect(p.status, PostStatus.cancelled);
    });

    test('a sign-in renewal under way finishes and keeps its new keys; then the run stops', () async {
      final client = _GatedClient();
      final secrets = InMemorySecretStore();
      await secrets.write('acct-1', const {'refresh': 'old-token'});
      adapter = _RenewingAdapter();
      final svc = service(secrets: secrets, network: NeforumHttp(client: client, maxRetries: 0));
      await scheduled(when: testNow);
      final signal = CancellationSignal();
      final run = svc.publish('p1', cancellation: signal);
      while (client.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // The network has retired the old token; its answer is on the way.
      signal.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      client.answer.complete();
      final p = await run;
      expect((await secrets.read('acct-1'))!['refresh'], 'new-token', reason: 'the old refresh token no longer works');
      expect(p.targets.single.status, TargetStatus.cancelled);
      expect(adapter.published, isEmpty);
    });

    test('rollUpStatus matches what a run leaves', () {
      final base = Post(id: 'x', text: 'hi', createdAt: testNow, updatedAt: testNow, status: PostStatus.failed);
      PostStatus of(List<TargetStatus> s) =>
          service().rollUpStatus(base.copyWith(targets: [for (var i = 0; i < s.length; i++) PostTarget(accountId: 'a$i', status: s[i])])).status;
      expect(of([TargetStatus.published, TargetStatus.skipped]), PostStatus.published);
      expect(of([TargetStatus.published, TargetStatus.failed]), PostStatus.partial);
      expect(of([TargetStatus.published, TargetStatus.cancelled]), PostStatus.partial);
      expect(of([TargetStatus.failed, TargetStatus.cancelled]), PostStatus.cancelled);
      expect(of([TargetStatus.failed]), PostStatus.failed);
      expect(of([TargetStatus.awaitingHandoff, TargetStatus.cancelled]), PostStatus.partial);
    });
  });

  group('a run never leaves the post looking busy', () {
    Future<void> twoTargets() async {
      await accounts.upsert(fakeAccount('fake', id: 'acct-2'));
      await posts.upsert(Post(
        id: 'p1',
        text: 'Hello there',
        createdAt: testNow,
        updatedAt: testNow,
        status: PostStatus.publishing,
        targets: const [PostTarget(accountId: 'acct-1'), PostTarget(accountId: 'acct-2')],
      ));
    }

    test('a check that breaks fails its target with Retry instead of ending the run', () async {
      adapter = _BrokenCheckAdapter();
      await scheduled(when: testNow);
      final p = await service().publish('p1');
      final t = p.targets.single;
      expect(t.status, TargetStatus.failed);
      expect(t.result!.error!.message, contains('rules table missing'));
      expect(p.status, PostStatus.failed);
      expect((await posts.get('p1'))!.status, PostStatus.failed);
      expect(adapter.published, isEmpty);
    });

    test('progress that cannot be saved is kept and saved with the next write', () async {
      final repo = posts = _UnwritablePostRepository();
      await twoTargets();
      // Every write during the run fails; the final one works.
      repo.fails = (p) => p.status == PostStatus.publishing && p.targets.first.status == TargetStatus.published;
      final p = await service().publish('p1');
      expect(adapter.published, hasLength(2));
      expect((await posts.get('p1'))!.targets.map((t) => t.status), [TargetStatus.published, TargetStatus.published]);
      expect(p.status, PostStatus.published);
    });

    test('an outcome that cannot be saved comes with the error and stays on record', () async {
      final repo = posts = _UnwritablePostRepository();
      await twoTargets();
      final journal = PublishJournal.inMemory();
      repo.fails = (p) => p.status != PostStatus.publishing;
      final error = await service(journal: journal).publish('p1').then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<PublishOutcomeNotSaved>());
      final outcome = (error! as PublishOutcomeNotSaved).post;
      expect(outcome.targets.map((t) => t.status), [TargetStatus.published, TargetStatus.published], reason: 'which networks have it');
      expect(outcome.status, PostStatus.published);
      expect((await journal.entries()).keys, ['p1'], reason: 'recovery finds the run once its heartbeat stops');
    });

    test('a usage count that cannot be written never turns a post back into an unposted one', () async {
      await scheduled(when: testNow);
      final p = await service(quotaRepo: _UnwritableQuotaRepository()).publish('p1');
      expect(p.targets.single.status, TargetStatus.published);
      expect(p.status, PostStatus.published);
    });
  });

  test('a switched-off account is skipped with a reason, and nothing is posted to it', () async {
    await accounts.upsert(fakeAccount('fake').copyWith(enabled: false));
    await scheduled(when: testNow);
    final p = await service().publish('p1', interactive: false);
    final t = p.targets.single;
    expect(t.status, TargetStatus.skipped);
    expect(t.result!.error!.message, contains('switched off'));
    expect(adapter.published, isEmpty);
  });

  group('publish journal', () {
    test('a run is on record while it goes, with a heartbeat, and off it once its outcome is saved', () async {
      final journal = PublishJournal.inMemory(heartbeatInterval: const Duration(milliseconds: 5));
      final seen = <PublishJournalEntry>[];
      adapter = _SlowAdapter(() async => seen.addAll((await journal.entries()).values));
      await scheduled(when: testNow);
      await service(journal: journal).publish('p1');
      final entry = seen.single;
      expect(entry.postId, 'p1');
      expect(entry.owner, journal.owner);
      expect(entry.heartbeatAt.isAfter(entry.startedAt), isTrue, reason: 'refreshed during the upload');
      expect(await journal.entries(), isEmpty);
    });

    test('each process releases only its own runs; a silent run counts as abandoned', () async {
      Object? shared;
      PublishJournal process(String owner, DateTime at) =>
          PublishJournal(read: () async => shared, write: (d) async => shared = d, owner: owner, clock: () => at);
      final background = process('background', testNow);
      final ui = process('ui', testNow.add(const Duration(minutes: 5)));
      await background.record('p1');
      await ui.release('p1');
      final entry = (await ui.entries())['p1']!;
      expect(entry.owner, 'background');
      expect(ui.isAbandoned(entry), isFalse, reason: 'five minutes without a heartbeat may be a suspended isolate');
      expect(ui.isAbandoned(entry, now: testNow.add(const Duration(minutes: 11))), isTrue);
      await background.release('p1');
      expect(await ui.entries(), isEmpty);

      shared = 'not a journal';
      expect(await ui.entries(), isEmpty, reason: 'unreadable data recovers nothing');
    });
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
