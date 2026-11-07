// Real adapters through the real service: each family goes through its stages in
// its real order, a finished target says so before the run ends, a target the run
// skips never reads as busy, and hand-offs wait for the automatic targets.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_adapter.dart';
import 'package:neforum_core/src/adapters/misskey/misskey_adapter.dart';
import 'package:neforum_core/src/adapters/threads/threads_adapter.dart';
import 'package:neforum_core/src/adapters/video_sites/odysee_adapter.dart';
import 'package:neforum_core/src/adapters/x/x_adapter.dart';
import 'package:neforum_core/src/adapters/youtube/youtube_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: jsonHeaders);

/// One finished run of one target through a real adapter.
class _Run {
  _Run(this.events, this.outcomes, this.figures, this.post, this.progress);

  final List<ProgressEvent> events;
  final List<TargetOutcome> outcomes;
  final List<int?> figures;
  final Post post;
  final PostProgress progress;

  /// The stages in order. Reading the file is everywhere and says nothing.
  List<ProgressStage> get order {
    final out = <ProgressStage>[];
    for (final e in events) {
      if (e.stage == ProgressStage.reading) continue;
      if (out.isEmpty || out.last != e.stage) out.add(e.stage);
    }
    return out;
  }
}

Future<_Run> _publish(
  PlatformAdapter adapter,
  ConnectedAccount account,
  Map<String, String> secrets,
  Future<http.Response> Function(http.Request r) handler, {
  List<MediaAttachment> media = const [],
  String text = 'Hello',
  String? title,
  MediaHost? host,
}) async {
  final accounts = InMemoryAccountRepository();
  await accounts.upsert(account);
  final posts = InMemoryPostRepository();
  await posts.upsert(Post(id: 'p1', text: text, title: title, media: media, createdAt: testNow, updatedAt: testNow, targets: [PostTarget(accountId: account.id)]));
  final store = InMemorySecretStore();
  await store.write(account.id, secrets);
  final events = <ProgressEvent>[];
  final outcomes = <TargetOutcome>[];
  final figures = <int?>[];
  late PublishProgressTracker tracker;
  tracker = PublishProgressTracker(
    postId: 'p1',
    clock: () => testNow,
    interval: Duration.zero,
    onChange: (p) => figures.add(p.targets.isEmpty ? null : p.targets.single.permille),
  );
  final service = PublishService(
    registry: AdapterRegistry([adapter]),
    accounts: accounts,
    posts: posts,
    secrets: store,
    quota: QuotaTracker(InMemoryQuotaRepository()),
    http: NeforumHttp(client: MockClient(handler), maxRetries: 0),
    mediaHostProvider: host == null ? null : () => host,
    clock: () => testNow,
    log: Logger('test', sink: (l, a, m, [e]) {}),
    readMedia: (_) async => Uint8List(2000),
  );
  final post = await service.publish(
    'p1',
    onPlan: tracker.plan,
    onEvent: (id, e) {
      events.add(e);
      tracker.event(id, e);
    },
    onOutcome: (id, o) {
      outcomes.add(o);
      tracker.outcome(id, o);
    },
  );
  return _Run(events, outcomes, figures, post, tracker.current);
}

MediaAttachment _photo([String id = 'img1']) => fakeImage(id: id, sizeBytes: 2000);
MediaAttachment _clip() => fakeVideo(sizeBytes: 2000);

void _expectFiguresFine(_Run run) {
  final numbers = run.figures.whereType<int>().toList();
  for (var i = 1; i < numbers.length; i++) {
    expect(numbers[i], greaterThanOrEqualTo(numbers[i - 1]), reason: '$numbers');
  }
  expect(numbers.where((n) => n == 1000).length, lessThanOrEqualTo(1 + numbers.length), reason: '$numbers');
  expect(numbers.indexWhere((n) => n == 1000), anyOf(-1, numbers.length - 1), reason: '100 only with the outcome: $numbers');
}

void main() {
  group('stage order per family', () {
    test('direct: Misskey uploads, then posts', () async {
      final run = await _publish(
        MisskeyAdapter(),
        fakeAccount('misskey', config: const {'instance': 'https://misskey.example', 'host': 'misskey.example', 'maxNoteTextLength': 3000}),
        const {'access_token': 't'},
        (r) async => r.url.path.endsWith('/drive/files/create') ? _json({'id': 'f1'}) : _json({'createdNote': {'id': 'n1'}}),
        media: [_photo()],
      );
      expect(run.post.targets.single.status, TargetStatus.published);
      expect(run.order, [ProgressStage.renewingSignIn, ProgressStage.uploading, ProgressStage.posting]);
      expect(run.outcomes, [TargetOutcome.published]);
      _expectFiguresFine(run);
    });

    test('wait with no number: Mastodon uploads, waits for processing, posts', () async {
      var polls = 0;
      final run = await _publish(
        MastodonAdapter(mediaPollInterval: Duration.zero, maxMediaPolls: 5, clock: () => testNow),
        fakeAccount('mastodon', config: const {'instance': 'https://mastodon.example', 'domain': 'mastodon.example', 'software': 'mastodon', 'maxCharacters': 500, 'maxMediaAttachments': 4, 'descriptionLimit': 1500}),
        const {'client_id': 'c', 'client_secret': 's', 'access_token': 't', 'token_type': 'Bearer'},
        (r) async {
          if (r.url.path == '/api/v2/media') return _json({'id': 'm1', 'url': null}, 202);
          if (r.url.path == '/api/v1/media/m1') return ++polls < 3 ? http.Response('', 206) : _json({'id': 'm1', 'url': 'https://x/m1'});
          return _json({'id': 's1', 'url': 'https://mastodon.example/@a/s1'});
        },
        media: [_clip()],
      );
      expect(run.post.targets.single.status, TargetStatus.published);
      expect(run.order, [ProgressStage.renewingSignIn, ProgressStage.uploading, ProgressStage.serverProcessing, ProgressStage.posting]);
      final waits = run.events.where((e) => e.stage == ProgressStage.serverProcessing);
      expect(waits.every((e) => e.serverPercent == null), isTrue, reason: 'no number during this wait');
      expect(waits.last.waitPolls, 3, reason: 'each request of the wait was really made');
      _expectFiguresFine(run);
    });

    test('wait with a number: X video reports the network\'s own percentage', () async {
      var checked = false;
      final run = await _publish(
        XAdapter(),
        ConnectedAccount(id: 'x-42', platformId: 'x', tier: PlatformTier.byokApi, displayName: 'A', handle: '@a', createdAt: testNow, config: const {'clientId': 'c', 'confidentialClient': false, 'userId': '42'}),
        {'access_token': 'a', 'refresh_token': 'r', 'expires_at': testNow.add(const Duration(hours: 1)).toUtc().toIso8601String(), 'token_type': 'bearer'},
        (r) async {
          final p = r.url.path;
          if (p.endsWith('/initialize')) return _json({'data': {'id': 'm1'}});
          if (p.endsWith('/append')) return _json({});
          if (p.endsWith('/finalize')) return _json({'data': {'id': 'm1', 'processing_info': {'state': 'in_progress', 'progress_percent': 40, 'check_after_secs': 0}}});
          if (r.method == 'GET') {
            checked = true;
            return _json({'data': {'processing_info': {'state': 'succeeded'}}});
          }
          return _json({'data': {'id': 'tw1'}});
        },
        media: [_clip()],
      );
      expect(run.post.targets.single.status, TargetStatus.published, reason: '${run.post.targets.single.result?.error?.message}');
      expect(checked, isTrue);
      expect(run.order, [ProgressStage.renewingSignIn, ProgressStage.uploading, ProgressStage.serverProcessing, ProgressStage.posting]);
      expect(run.events.firstWhere((e) => e.stage == ProgressStage.serverProcessing).serverPercent, 40);
      final chunk = run.events.lastWhere((e) => e.position != null);
      expect(chunk.slotTotal, 2000);
      expect(chunk.confirmed, isTrue, reason: 'a chunk the server answered for is a confirmed offset in the file');
      _expectFiguresFine(run);
    });

    test('pull from a URL: Threads hosts the file, waits for the container, publishes', () async {
      var statuses = 0;
      final host = FakeMediaHost();
      final run = await _publish(
        ThreadsAdapter(delay: (_) async {}),
        fakeAccount('threads', tier: PlatformTier.byokApi, config: const {'app_id': '111', 'user_id': '123', 'redirect_uri': 'https://127.0.0.1:52771/callback'}),
        {'access_token': 'LONG', 'expires_at': testNow.add(const Duration(days: 50)).toIso8601String(), 'token_type': 'Bearer'},
        (r) async {
          if (r.method == 'POST' && r.url.path.endsWith('/threads')) return _json({'id': 'c1'});
          if (r.method == 'POST') return _json({'id': 'p1'});
          if (r.url.queryParameters['fields'] == 'permalink') return _json({'permalink': 'https://threads.example/p1'});
          if (!r.url.path.endsWith('/c1')) return _json({});
          return _json({'status': ++statuses < 2 ? 'IN_PROGRESS' : 'FINISHED'});
        },
        media: [_photo()],
        host: host,
      );
      expect(run.post.targets.single.status, TargetStatus.published, reason: '${run.post.targets.single.result?.error?.message}');
      expect(host.uploaded, hasLength(1));
      expect(run.order, [ProgressStage.renewingSignIn, ProgressStage.uploading, ProgressStage.serverProcessing, ProgressStage.posting]);
      _expectFiguresFine(run);
    });

    test('whole file: YouTube says what it sent and is done on the answer', () async {
      final run = await _publish(
        YouTubeAdapter(resumeDelay: Duration.zero),
        fakeAccount('youtube', tier: PlatformTier.byokApi, config: const {'clientId': 'c'}),
        {'access_token': 'a', 'refresh_token': 'r', 'expires_at': testNow.add(const Duration(hours: 1)).toUtc().toIso8601String(), 'token_type': 'Bearer'},
        (r) async {
          if (r.method == 'POST') return http.Response('', 200, headers: {'location': 'https://upload.example/session1'});
          return _json({'id': 'v1', 'status': {'privacyStatus': 'public'}});
        },
        media: [_clip()],
        title: 'My video',
      );
      expect(run.post.targets.single.status, TargetStatus.published, reason: '${run.post.targets.single.result?.error?.message}');
      expect(run.order, containsAllInOrder([ProgressStage.renewingSignIn, ProgressStage.uploading, ProgressStage.posting]));
      expect(run.order, isNot(contains(ProgressStage.serverProcessing)));
      expect(run.progress.targets.single.family, ProgressFamily.wholeFile);
      _expectFiguresFine(run);
    });

    test('opaque: Odysee has no figure until its outcome', () async {
      final run = await _publish(
        OdyseeAdapter(),
        fakeAccount('odysee', config: const {'daemon': 'http://localhost:5279', 'channelId': 'c', 'bid': '0.01'}),
        const {},
        (r) async => _json({'result': {'outputs': [{'claim_id': 'abc', 'name': 'x'}]}}),
        media: [_clip()],
        title: 'My video',
      );
      expect(run.post.targets.single.status, TargetStatus.published, reason: '${run.post.targets.single.result?.error?.message}');
      expect(run.order, [ProgressStage.renewingSignIn, ProgressStage.posting]);
      expect(run.figures.sublist(0, run.figures.length - 1).every((f) => f == null), isTrue, reason: '${run.figures}');
      expect(run.figures.last, 1000);
    });

    test('text only: nothing but the post to make', () async {
      final run = await _publish(
        MastodonAdapter(clock: () => testNow),
        fakeAccount('mastodon', config: const {'instance': 'https://mastodon.example', 'domain': 'mastodon.example', 'software': 'mastodon', 'maxCharacters': 500, 'maxMediaAttachments': 4, 'descriptionLimit': 1500}),
        const {'client_id': 'c', 'client_secret': 's', 'access_token': 't', 'token_type': 'Bearer'},
        (r) async => _json({'id': 's1', 'url': 'https://mastodon.example/@a/s1'}),
      );
      expect(run.order, [ProgressStage.renewingSignIn, ProgressStage.posting]);
      expect(run.progress.targets.single.family, ProgressFamily.textOnly);
    });
  });

  group('every family\'s plan', () {
    PostVariant withMedia(List<MediaAttachment> m) => PostVariant(text: 't', media: m);
    final account = fakeAccount('any');
    test('picks the family the table names', () {
      final cases = <String, (PlatformAdapter, PostVariant, ProgressFamily)>{
        'Misskey': (MisskeyAdapter(), withMedia([_photo()]), ProgressFamily.direct),
        'Mastodon': (MastodonAdapter(), withMedia([_photo()]), ProgressFamily.waitNoNumber),
        'X image': (XAdapter(), withMedia([_photo()]), ProgressFamily.direct),
        'X video': (XAdapter(), withMedia([_clip()]), ProgressFamily.waitReported),
        'Threads': (ThreadsAdapter(), withMedia([_photo()]), ProgressFamily.pullFromUrl),
        'YouTube': (YouTubeAdapter(), withMedia([_clip()]), ProgressFamily.wholeFile),
        'Odysee': (OdyseeAdapter(), withMedia([_clip()]), ProgressFamily.opaque),
        'Text': (MisskeyAdapter(), const PostVariant(text: 't'), ProgressFamily.textOnly),
      };
      cases.forEach((name, c) => expect(c.$1.progressShape(c.$2, account).effectiveFamily, c.$3, reason: name));
    });

    test('a resumed thread plans only what is left', () {
      final v = PostVariant(
        text: 'a',
        threadParts: const ['a', 'b', 'c'],
        media: [_photo('one'), _photo('two')],
        mediaPartIndexes: const [0, 2],
        postedThreadIds: const ['p0'],
      );
      final shape = MisskeyAdapter().progressShape(v, account);
      expect(shape.slots.map((s) => s.key), ['two']);
      expect((shape.steps, shape.stepsDone), (3, 1));
    });
  });

  group('a run with several targets', () {
    late InMemoryAccountRepository accounts;
    late InMemoryPostRepository posts;
    late _Net net;

    PublishService service({HandoffLauncher? launcher}) => PublishService(
          registry: AdapterRegistry([net]),
          accounts: accounts,
          posts: posts,
          secrets: InMemorySecretStore(),
          quota: QuotaTracker(InMemoryQuotaRepository()),
          http: NeforumHttp(client: MockClient((_) async => http.Response('', 500)), maxRetries: 0),
          handoffLauncher: launcher,
          clock: () => testNow,
          log: Logger('test', sink: (l, a, m, [e]) {}),
        );

    Future<void> save(List<PostTarget> targets) => posts.upsert(Post(id: 'p1', text: 'Hello', createdAt: testNow, updatedAt: testNow, targets: targets));

    setUp(() async {
      accounts = InMemoryAccountRepository();
      posts = InMemoryPostRepository();
      net = _Net();
      await accounts.upsert(fakeAccount('net', id: 'a'));
      await accounts.upsert(fakeAccount('net', id: 'b'));
      await accounts.upsert(fakeAccount('net', id: 'off').copyWith(enabled: false));
      await accounts.upsert(fakeAccount('net', id: 'hand', tier: PlatformTier.handoff));
    });

    test('a target that finished shows its outcome while the next one is still going', () async {
      final gate = Completer<void>();
      net.onPublish['b'] = () => gate.future;
      await save(const [PostTarget(accountId: 'a'), PostTarget(accountId: 'b')]);
      final seen = <String, TargetOutcome>{};
      final tracker = PublishProgressTracker(postId: 'p1', clock: () => testNow);
      final run = service().publish('p1', onPlan: tracker.plan, onEvent: tracker.event, onOutcome: (id, o) {
        seen[id] = o;
        tracker.outcome(id, o);
      });
      while (!net.started.contains('b')) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(seen, {'a': TargetOutcome.published}, reason: 'the run has not ended yet');
      final during = tracker.current;
      expect(during.posted, 1);
      expect(during.targets.first.finished, isTrue);
      expect(during.targets.first.permille, 1000);
      expect(during.finished, isFalse);
      expect(during.permille, lessThan(1000));
      gate.complete();
      await run;
      expect(seen['b'], TargetOutcome.published);
      expect(tracker.current.permille, 1000);
    });

    test('a target the run skips never reads as busy', () async {
      await save(const [
        PostTarget(accountId: 'off'),
        PostTarget(accountId: 'b', status: TargetStatus.published),
        PostTarget(accountId: 'a'),
      ]);
      final events = <String>[];
      final outcomes = <String, TargetOutcome>{};
      final tracker = PublishProgressTracker(postId: 'p1', clock: () => testNow);
      PublishRunPlan? plan;
      await service().publish('p1',
          onPlan: (p) {
            plan = p;
            tracker.plan(p);
          },
          onEvent: (id, e) => events.add(id),
          onOutcome: (id, o) {
            outcomes[id] = o;
            tracker.outcome(id, o);
          });
      expect(events.toSet(), {'a'}, reason: 'nothing ever said these two were working');
      expect(outcomes['off'], TargetOutcome.skipped);
      expect(outcomes['b'], TargetOutcome.published, reason: 'live already: a retry credits it');
      expect(plan!.targets.firstWhere((t) => t.accountId == 'b').outcome, TargetOutcome.published);
      expect(tracker.current.targets.every((t) => t.finished), isTrue);
    });

    test('a target this run does not touch is in no figure', () async {
      await save(const [PostTarget(accountId: 'a'), PostTarget(accountId: 'b')]);
      final tracker = PublishProgressTracker(postId: 'p1', clock: () => testNow);
      final outcomes = <String, TargetOutcome>{};
      await service().publish('p1', onlyAccountIds: {'a'}, onPlan: tracker.plan, onEvent: tracker.event, onOutcome: (id, o) {
        outcomes[id] = o;
        tracker.outcome(id, o);
      });
      expect(outcomes['b'], TargetOutcome.notThisRun);
      expect(tracker.current.total, 1);
      expect(tracker.current.permille, 1000);
    });

    group('hand-offs wait for the automatic targets', () {
      test('whatever order the post lists them in', () async {
        await save(const [PostTarget(accountId: 'hand'), PostTarget(accountId: 'a'), PostTarget(accountId: 'b')]);
        final order = <String>[];
        net.onStart = order.add;
        final launcher = _Launcher((id) => order.add('sheet $id'));
        final done = await service(launcher: launcher).publish('p1');
        expect(order, ['a', 'b', 'sheet hand']);
        expect(done.targetFor('hand')!.status, TargetStatus.handedOff);
      });

      test('a sheet nobody answers holds up nothing automatic', () async {
        await save(const [PostTarget(accountId: 'hand'), PostTarget(accountId: 'a')]);
        final sheet = Completer<HandoffResult>();
        final outcomes = <String, TargetOutcome>{};
        final run = service(launcher: _Launcher((_) {}, answer: () => sheet.future)).publish('p1', onOutcome: (id, o) => outcomes[id] = o);
        while (outcomes['a'] == null) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(outcomes['a'], TargetOutcome.published);
        expect(outcomes['hand'], isNull);
        sheet.complete(HandoffResult.deferred);
        final done = await run;
        expect(done.targetFor('hand')!.status, TargetStatus.awaitingHandoff);
        expect(outcomes['hand'], TargetOutcome.awaitingUser);
      });

      test('a hidden window defers: the target waits and the run ends', () async {
        await save(const [PostTarget(accountId: 'hand')]);
        final done = await service(launcher: _Launcher((_) {}, answer: () async => HandoffResult.deferred)).publish('p1');
        expect(done.targetFor('hand')!.status, TargetStatus.awaitingHandoff);
        expect(done.status, PostStatus.partial);
      });

      test('a hand-off says it waits for the person', () async {
        await save(const [PostTarget(accountId: 'hand')]);
        final stages = <ProgressStage>[];
        await service(launcher: _Launcher((_) {})).publish('p1', onEvent: (_, e) => stages.add(e.stage));
        expect(stages, [ProgressStage.handingOff]);
      });

      test('a background run opens nothing and keeps its order', () async {
        await save(const [PostTarget(accountId: 'hand'), PostTarget(accountId: 'a')]);
        var sheets = 0;
        final done = await service(launcher: _Launcher((_) => sheets++)).publish('p1', interactive: false);
        expect(sheets, 0);
        expect(done.targetFor('hand')!.status, TargetStatus.awaitingHandoff);
      });

      test('one a quota sends this way waits too', () async {
        await save(const [PostTarget(accountId: 'b'), PostTarget(accountId: 'a')]);
        final order = <String>[];
        net.onStart = order.add;
        final launcher = _Launcher((id) => order.add('sheet $id'));
        final accountsWithQuota = PublishService(
          registry: AdapterRegistry([net]),
          accounts: accounts,
          posts: posts,
          secrets: InMemorySecretStore(),
          quota: QuotaTracker(_FullFor(accountId: 'b')),
          http: NeforumHttp(client: MockClient((_) async => http.Response('', 500)), maxRetries: 0),
          handoffLauncher: launcher,
          clock: () => testNow,
          log: Logger('test', sink: (l, a, m, [e]) {}),
        );
        final outcomes = <String, TargetOutcome>{};
        final done = await accountsWithQuota.publish('p1', onOutcome: (id, o) => outcomes[id] = o);
        expect(order, ['a', 'sheet b']);
        expect(done.targetFor('b')!.status, TargetStatus.handedOff);
        expect(outcomes['b'], TargetOutcome.handedOff, reason: 'reported once, when it is really over');
      });
    });
  });
}

class _Net extends PlatformAdapter {
  final started = <String>[];
  final onPublish = <String, Future<void> Function()>{};
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
        defaultQuotas: [QuotaRule(id: 'net.daily', limit: 5, window: Duration(days: 1), note: 'a day')],
      );

  @override
  List<ConnectSpec> get connectSpecs => const [];

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) => throw UnimplementedError();

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    started.add(account.id);
    onStart?.call(account.id);
    await ctx.creating('Posting', () async => onPublish[account.id]?.call());
    return PublishResult.ok(remoteId: 'post-${account.id}');
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) => HandoffPlan(platformId: 'net', instructions: 'Tap Post', clipboardText: variant.text);
}

class _Launcher implements HandoffLauncher {
  _Launcher(this.onShown, {this.answer});

  final void Function(String accountId) onShown;
  final Future<HandoffResult> Function()? answer;

  @override
  Future<HandoffResult> launch(HandoffPlan plan, {required Post post, required PostTarget target, required PostVariant variant, required ConnectedAccount account}) async {
    onShown(account.id);
    return answer == null ? HandoffResult.launched : answer!();
  }
}

/// A usage count that says one account's quota is used up.
class _FullFor extends InMemoryQuotaRepository {
  _FullFor({required this.accountId});

  final String accountId;

  @override
  Future<int> countSince(String accountId, String ruleId, DateTime since) async => accountId == this.accountId ? 100 : 0;
}
