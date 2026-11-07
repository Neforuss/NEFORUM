// The keep-alive around a publish run: it is counted, it is never in the run's way,
// and native's requests reach the run.

import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/publish_host.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/publish_run_keeper.dart';
import 'package:neforum_app/state/publish_run_surface.dart';
import 'package:neforum_app/state/scheduler.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class FakeHost implements PublishHost {
  final calls = <String>[];
  final snapshots = <Map<String, Object?>>[];
  final begun = <({String postId, String title, List<PublishHostNetwork> networks})>[];
  final ended = <({String postId, String summary})>[];
  final _signals = StreamController<PublishHostSignal>.broadcast(sync: true);
  bool beginAnswer = true;
  bool throwEverywhere = false;

  void send(PublishHostSignal signal) => _signals.add(signal);

  void _maybeThrow() {
    if (throwEverywhere) throw PlatformException(code: 'nope');
  }

  @override
  Future<bool> begin({required String postId, required String title, required List<PublishHostNetwork> networks}) async {
    calls.add('begin $postId');
    begun.add((postId: postId, title: title, networks: networks));
    _maybeThrow();
    return beginAnswer;
  }

  @override
  Future<void> update(Map<String, Object?> snapshot) async {
    calls.add('update');
    snapshots.add(snapshot);
    _maybeThrow();
  }

  @override
  Future<void> end({required String postId, required String summary}) async {
    calls.add('end $postId');
    ended.add((postId: postId, summary: summary));
    _maybeThrow();
  }

  @override
  Stream<PublishHostSignal> get signals => _signals.stream;
  @override
  void dispose() {}
}

class Harness {
  Harness({this.lifecycle = AppLifecycleState.resumed, this.beforeRelease}) {
    keeper = PublishRunKeeper(
      host: host,
      onCancel: cancelled.add,
      onOpenPost: opened.add,
      onLimitReached: (title, body, id) => limits.add('$id: $title: $body'),
      onRefused: () => refused++,
      beforeReleaseHidden: beforeRelease,
      lifecycle: () => lifecycle,
      clock: () => now,
    );
  }

  final host = FakeHost();
  final cancelled = <String>[];
  final opened = <String>[];
  final limits = <String>[];
  final Future<void> Function()? beforeRelease;
  int refused = 0;
  AppLifecycleState? lifecycle;
  DateTime now = DateTime.utc(2026, 11, 7, 12);
  late final PublishRunKeeper keeper;
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

PostProgress progress(String postId, {int permille = 100, String name = 'Mastodon'}) => PostProgress(
      postId: postId,
      permille: permille,
      posted: 0,
      failed: 0,
      total: 1,
      targets: [
        TargetProgress(accountId: 'a', name: name, permille: permille, family: ProgressFamily.direct, stage: ProgressStage.uploading, label: 'Sending', stageStartedAt: DateTime.utc(2026)),
      ],
      at: DateTime.utc(2026),
    );

Future<(AppServices, ProviderContainer, FakeHost)> demo() async {
  final dir = await Directory.systemTemp.createTemp('neforum-host-');
  addTearDown(() => dir.delete(recursive: true));
  final services = await AppServices.create(demo: true, storage: await openAppStorage(overrideDir: dir.path));
  final host = FakeHost();
  final container = ProviderContainer(overrides: [
    servicesProvider.overrideWithValue(services),
    publishHostProvider.overrideWithValue(host),
  ]);
  container.listen(postsProvider, (_, _) {});
  container.listen(accountsProvider, (_, _) {});
  await container.read(accountsProvider.future);
  return (services, container, host);
}

void main() {
  group('holds are counted', () {
    test('two holds on one post: one begin, and the end only at the last', () async {
      final h = Harness();
      h.keeper
        ..begin('p')
        ..begin('p');
      await settle();
      expect(h.host.calls.where((c) => c.startsWith('begin')), ['begin p']);
      expect(h.keeper.holdsOf('p'), 2);

      await h.keeper.end('p');
      expect(h.host.ended, isEmpty, reason: 'the other caller is still running');
      await h.keeper.end('p');
      expect(h.host.ended.single.postId, 'p');
      expect(h.keeper.activePosts, isEmpty);
    });

    test('two posts: ending one leaves the other kept, and the surface moves to it', () async {
      final h = Harness();
      h.keeper
        ..begin('old')
        ..begin('new');
      h.keeper.progress('old', progress('old', name: 'Mastodon'));
      expect(h.host.snapshots.last['headline'], 'Posting 2 posts');

      await h.keeper.end('old');
      expect(h.host.ended.map((e) => e.postId), ['old']);
      expect(h.keeper.activePosts, ['new']);
      expect(h.host.snapshots.last['headline'], 'Getting your post ready', reason: 'the bar is the remaining run\'s');
    });

    test('an end with no hold on record does nothing', () async {
      final h = Harness();
      await h.keeper.end('never');
      expect(h.host.calls, isEmpty);
    });

    test('native hears begin before the first update, which it takes only for a run it knows', () async {
      final h = Harness();
      h.keeper.begin('p');
      await settle();
      expect(h.host.calls.take(2), ['begin p', 'update']);
    });
  });

  group('the host is never in the way', () {
    test('a host that throws on every call: nothing reaches the caller', () async {
      final h = Harness();
      h.host.throwEverywhere = true;
      h.keeper.begin('p');
      h.keeper.progress('p', progress('p'));
      h.keeper.alive('p');
      await settle();
      await h.keeper.end('p');
      expect(h.host.calls, containsAll(['begin p', 'update', 'end p']));
      expect(h.keeper.activePosts, isEmpty);
    });

    test('Android refuses while the app shows: said once, and the hold still counts', () async {
      final h = Harness();
      h.host.beginAnswer = false;
      h.keeper.begin('p');
      await settle();
      expect(h.refused, 1);
      expect(h.keeper.holdsOf('p'), 1);
      h.keeper.planned('p', const PublishRunPlan(postId: 'p', targets: []));
      await settle();
      expect(h.refused, 1, reason: 'the plan refreshes the networks, it is not another refusal to tell');
      await h.keeper.end('p');
      expect(h.host.ended.single.postId, 'p', reason: 'a failed begin is still ended, or native keeps the engine');
    });

    test('refused with the app hidden, as a scheduler tick is: nobody is there to tell', () async {
      final h = Harness(lifecycle: AppLifecycleState.paused);
      h.host.beginAnswer = false;
      h.keeper.begin('p');
      await settle();
      expect(h.refused, 0);
    });

    test('a run goes all the way with a host that throws, and with one that refuses', () async {
      for (final setUpHost in <void Function(FakeHost)>[(h) => h.throwEverywhere = true, (h) => h.beginAnswer = false]) {
        final (services, c, host) = await demo();
        addTearDown(c.dispose);
        setUpHost(host);
        final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon').id;
        c.read(composerProvider.notifier)
          ..setText('Goes out whatever Android says')
          ..selectAccounts([masto]);
        final done = await c.read(postActionsProvider).publishNow();
        expect(done.status, PostStatus.published);
        await settle();
        expect(host.calls.last, 'end ${done.id}');
        expect(c.read(publishRunKeeperProvider).activePosts, isEmpty);
        expect(services.demo, isTrue);
      }
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('end is called when the run throws', () async {
      final (_, c, host) = await demo();
      addTearDown(c.dispose);
      await expectLater(c.read(postActionsProvider).publishExisting('missing'), throwsStateError);
      await settle();
      expect(host.ended.single.postId, 'missing');
      expect(c.read(publishRunKeeperProvider).activePosts, isEmpty);
    });

    test('a post that cannot be saved ends its hold too', () async {
      final (_, c, host) = await demo();
      addTearDown(c.dispose);
      // Nothing selected, nothing written: the save refuses or the run has no targets.
      c.read(composerProvider.notifier).setText('');
      try {
        await c.read(postActionsProvider).publishNow();
      } on Object {
        // Either way the hold has to be gone.
      }
      await settle();
      expect(c.read(publishRunKeeperProvider).activePosts, isEmpty);
      expect(host.begun.map((b) => b.postId).toSet().length, host.ended.length);
    }, timeout: const Timeout(Duration(minutes: 1)));
  });

  group('cancel routing', () {
    test('Cancel on the notification reaches the run of that post, and no other', () async {
      final h = Harness();
      h.keeper
        ..begin('a')
        ..begin('b');
      h.host.send(const PublishHostCancelRequested('b'));
      expect(h.cancelled, ['b']);
      h.host.send(const PublishHostCancelRequested('gone'));
      expect(h.cancelled, ['b'], reason: 'a stale tap on a finished run');
    });

    test('through the providers: the signal of the running post is cancelled, as Activity\'s button does', () async {
      final (_, c, host) = await demo();
      addTearDown(c.dispose);
      final signal = CancellationSignal();
      c.read(activePublishingProvider.notifier).begin('p', signal);
      c.read(publishRunKeeperProvider).begin('p');
      host.send(const PublishHostCancelRequested('p'));
      expect(signal.isCancelled, isTrue);
    });

    test('a real run stops on the notification\'s Cancel, and its networks get Retry', () async {
      final (services, c, host) = await demo();
      addTearDown(c.dispose);
      final ids = c.read(accountListProvider).where((a) => a.platformId == 'mastodon' || a.platformId == 'bluesky').map((a) => a.id).toList();
      c.read(composerProvider.notifier)
        ..setText('Wait, not yet')
        ..selectAccounts(ids);
      final draft = await c.read(postActionsProvider).saveDraft();
      final running = c.read(postActionsProvider).publishExisting(draft.id);
      host.send(PublishHostCancelRequested(draft.id));
      final done = await running;
      expect(done.status, PostStatus.cancelled);
      expect((await services.posts.get(draft.id))!.status, PostStatus.cancelled);
      await settle();
      expect(host.ended.single.postId, draft.id);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('Android\'s time limit: every run is cancelled and told how to go on', () async {
      final h = Harness();
      h.keeper
        ..begin('a')
        ..begin('b');
      h.host.send(const PublishHostTimedOut());
      expect(h.cancelled, ['a', 'b']);
      expect(h.limits, ['a: $kPublishLimitTitle: $kPublishLimitBody', 'b: $kPublishLimitTitle: $kPublishLimitBody']);
    });

    test('a tap on the notification opens the post', () {
      final h = Harness();
      h.host.send(const PublishHostOpenPost('p'));
      expect(h.opened, ['p']);
    });
  });

  group('what goes to native', () {
    test('the plan gives each network its share, a text post the same least share the bar counts', () async {
      final h = Harness();
      h.keeper.begin('p');
      await settle();
      h.keeper.planned(
        'p',
        const PublishRunPlan(postId: 'p', targets: [
          PlannedTarget(accountId: 'a', name: 'Mastodon', shape: ProgressShape(family: ProgressFamily.direct, slots: [ProgressSlot('m', 5 * 1024 * 1024)])),
          PlannedTarget(accountId: 'b', name: 'Bluesky', shape: ProgressShape(family: ProgressFamily.textOnly)),
        ]),
      );
      await settle();
      final networks = h.host.begun.last.networks;
      expect(networks.map((n) => (n.id, n.name, n.bytes)), [('a', 'Mastodon', 5 * 1024 * 1024), ('b', 'Bluesky', 1024 * 1024)]);
    });

    test('an unchanged picture is resent only to show the run lives; a silent run sends nothing', () async {
      final h = Harness();
      h.keeper.begin('p');
      h.keeper.progress('p', progress('p'));
      final sent = h.host.snapshots.length;
      h.keeper.progress('p', progress('p'));
      h.now = h.now.add(const Duration(seconds: 59));
      h.keeper.alive('p');
      expect(h.host.snapshots.length, sent, reason: 'nothing new to show');

      h.now = h.now.add(const Duration(seconds: 2));
      h.keeper.alive('p');
      expect(h.host.snapshots.length, sent + 1, reason: 'this re-arms the wake lock, during a long wait for a server');

      h.keeper.progress('p', progress('p', permille: 200));
      expect(h.host.snapshots.length, sent + 2, reason: 'a new figure goes at once; native holds it to one per 2 s');
    });

    test('a hold unknown to the keeper moves nothing', () {
      final h = Harness();
      h.keeper.progress('p', progress('p'));
      h.keeper.alive('p');
      h.keeper.planned('p', const PublishRunPlan(postId: 'p', targets: []));
      expect(h.host.calls, isEmpty);
    });

    test('the post\'s text never goes to native, on any call', () async {
      const secretWords = 'My private words for the post';
      final (_, c, host) = await demo();
      addTearDown(c.dispose);
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon').id;
      c.read(composerProvider.notifier)
        ..setText(secretWords)
        ..selectAccounts([masto]);
      await c.read(postActionsProvider).publishNow();
      await settle();
      expect(host.snapshots, isNotEmpty);
      for (final text in [...host.snapshots.map((s) => '$s'), ...host.begun.map((b) => '${b.title} ${b.networks.map((n) => n.name)}'), ...host.ended.map((e) => e.summary)]) {
        expect(text, isNot(contains('private words')));
      }
      expect(host.snapshots.last['headline'], isNotNull);
      expect(host.ended.single.summary, 'Posted to 1 network');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('the snapshots of a real run: the figure never falls and reads 100 only at the end', () async {
      final (_, c, host) = await demo();
      addTearDown(c.dispose);
      final ids = c.read(accountListProvider).where((a) => a.platformId == 'mastodon' || a.platformId == 'bluesky').map((a) => a.id).toList();
      c.read(composerProvider.notifier)
        ..setText('Counting')
        ..selectAccounts(ids);
      await c.read(postActionsProvider).publishNow();
      await settle();
      var high = 0;
      final figures = host.snapshots.map((s) => s['postPermille']).whereType<int>().toList();
      expect(figures, isNotEmpty);
      for (final f in figures) {
        expect(f, greaterThanOrEqualTo(high));
        high = f;
      }
      expect(figures.where((f) => f == 1000).length, lessThanOrEqualTo(1), reason: 'only the last picture');
      expect(host.snapshots.last['phase'], 'finished');
      expect((host.snapshots.last['networks'] as List).map((n) => (n as Map)['state']).toSet(), {'posted'});
    }, timeout: const Timeout(Duration(minutes: 1)));

    // The merge of U1-UI and U2A once gave each run two trackers, and only native's
    // heard the run: the sheet's figure never moved.
    test('the screens and native hear one tracker, from the composer and from the scheduler', () async {
      final (services, c, host) = await demo();
      addTearDown(c.dispose);
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon').id;
      final screens = <int>[];
      c.listen<Map<String, PostProgress>>(publishProgressProvider, (_, runs) {
        final p = runs['tap'] ?? runs['due2'];
        if (p != null) screens.add(p.permille);
      });
      final at = DateTime.now();
      await services.posts.upsert(Post(id: 'tap', text: 'Tapped', createdAt: at, updatedAt: at, status: PostStatus.draft, targets: [PostTarget(accountId: masto)]));
      await c.read(postActionsProvider).publishExisting('tap');
      await settle();
      expect(screens, isNotEmpty, reason: 'the sheet hears the composer run');
      expect(screens.last, 1000);
      final native = host.snapshots.map((s) => s['postPermille']).whereType<int>().toList();
      expect(native, contains(screens.last), reason: 'native hears the same figures');

      screens.clear();
      host.snapshots.clear();
      await services.posts.upsert(Post(
        id: 'due2',
        text: 'Due',
        createdAt: at,
        updatedAt: at,
        status: PostStatus.scheduled,
        scheduledAt: at.subtract(const Duration(minutes: 1)),
        targets: [PostTarget(accountId: masto)],
      ));
      await c.read(schedulerProvider).runDue();
      await settle();
      expect(screens, isNotEmpty, reason: 'the screens hear the scheduler run');
      expect(host.snapshots.map((s) => s['postPermille']).whereType<int>(), contains(screens.last));
    }, timeout: const Timeout(Duration(minutes: 1)));
  });

  group('the window', () {
    test('windowClosing holds until the app is back; the surface follows', () {
      final h = Harness(lifecycle: AppLifecycleState.detached);
      h.keeper.begin('p');
      expect(h.keeper.windowState, PublishWindowState.open);
      h.host.send(const PublishHostWindowClosing());
      expect(h.keeper.windowState, PublishWindowState.gone);
      h.lifecycle = AppLifecycleState.resumed;
      expect(h.keeper.windowState, PublishWindowState.open, reason: 'the same engine has a new Activity');
      h.lifecycle = AppLifecycleState.paused;
      expect(h.keeper.windowState, PublishWindowState.open, reason: 'Home after coming back is not a closed window');
    });

    test('a run ending hidden saves first, then releases; visible it does not wait', () async {
      final order = <String>[];
      final hidden = Harness(lifecycle: AppLifecycleState.paused, beforeRelease: () async => order.add('sync'));
      hidden.keeper.begin('p');
      await settle();
      await hidden.keeper.end('p');
      order.add(hidden.host.ended.isEmpty ? 'not ended' : 'ended');
      expect(order, ['sync', 'ended']);

      var synced = false;
      final visible = Harness(beforeRelease: () async => synced = true);
      visible.keeper.begin('p');
      await visible.keeper.end('p');
      expect(synced, isFalse);
      expect(visible.host.ended, hasLength(1));
    });

    test('a failing save does not stop the release', () async {
      final h = Harness(lifecycle: AppLifecycleState.paused, beforeRelease: () async => throw StateError('offline'));
      h.keeper.begin('p');
      await h.keeper.end('p');
      expect(h.host.ended, hasLength(1));
    });

    test('a new hold during the save keeps the run on', () async {
      final saving = Completer<void>();
      final h = Harness(lifecycle: AppLifecycleState.paused, beforeRelease: () => saving.future);
      h.keeper.begin('p');
      final ending = h.keeper.end('p');
      await settle();
      h.keeper.begin('p');
      saving.complete();
      await ending;
      expect(h.host.ended, isEmpty);
      expect(h.keeper.holdsOf('p'), 1);
    });
  });

  group('the scheduler', () {
    test('a due run holds and releases the keep-alive, with its progress', () async {
      final (services, c, host) = await demo();
      addTearDown(c.dispose);
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon').id;
      final at = DateTime.now();
      await services.posts.upsert(Post(
        id: 'due1',
        text: 'Due now',
        createdAt: at,
        updatedAt: at,
        status: PostStatus.scheduled,
        scheduledAt: at.subtract(const Duration(minutes: 1)),
        targets: [PostTarget(accountId: masto)],
      ));
      final out = await c.read(schedulerProvider).runDue();
      expect(out.single.status, PostStatus.published);
      await settle();
      expect(host.begun.first.postId, 'due1');
      expect(host.ended.single.postId, 'due1');
      expect(host.snapshots.last['phase'], 'finished');
    }, timeout: const Timeout(Duration(minutes: 1)));
  });

  group('ChannelPublishHost', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel(kPublishHostChannel);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('the contract\'s method names and arguments', () async {
      final seen = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen.add(call);
        return call.method == 'begin' ? true : null;
      });
      final host = ChannelPublishHost();
      addTearDown(host.dispose);
      expect(await host.begin(postId: 'p', title: 'T', networks: const [PublishHostNetwork(id: 'a', name: 'Mastodon', bytes: 7)]), isTrue);
      await host.update(const {'phase': 'posting'});
      await host.end(postId: 'p', summary: 'Posted');
      expect(seen.map((c) => c.method), ['begin', 'update', 'end']);
      expect(seen[0].arguments, {
        'postId': 'p',
        'title': 'T',
        'networks': [
          {'id': 'a', 'name': 'Mastodon', 'bytes': 7},
        ],
      });
      expect(seen[1].arguments, {'phase': 'posting'});
      expect(seen[2].arguments, {'postId': 'p', 'summary': 'Posted'});
    });

    test('native\'s calls become signals', () async {
      final host = ChannelPublishHost();
      addTearDown(host.dispose);
      final got = <PublishHostSignal>[];
      host.signals.listen(got.add);
      Future<void> fromNative(String method, [Object? args]) => messenger.handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
            (_) {},
          );
      await fromNative('cancelRequested', {'postId': 'p'});
      await fromNative('timedOut');
      await fromNative('windowClosing');
      await fromNative('openPost', {'postId': 'q'});
      await fromNative('somethingNew');
      await settle();
      expect(got[0], isA<PublishHostCancelRequested>().having((s) => s.postId, 'postId', 'p'));
      expect(got[1], isA<PublishHostTimedOut>());
      expect(got[2], isA<PublishHostWindowClosing>());
      expect(got[3], isA<PublishHostOpenPost>().having((s) => s.postId, 'postId', 'q'));
      expect(got, hasLength(4));
    });

    test('createPublishHost: Android has the channel; a computer and the demo have nothing to keep alive', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final android = createPublishHost(demo: false);
      addTearDown(android.dispose);
      expect(android, isA<ChannelPublishHost>());
      expect(createPublishHost(demo: true), isA<NoPublishHost>());
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(createPublishHost(demo: false), isA<NoPublishHost>());
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
