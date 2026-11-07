// A run's life outside the app: what is armed and when, what the pause signal does
// on each call from the system, and that nothing outside ever holds up the run.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/publish_host.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart' show accountListProvider, accountsProvider, postsProvider, publishRunProvider, servicesProvider;
import 'package:neforum_app/state/publish_run_session.dart';
import 'package:neforum_app/state/publish_run_surface.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/activity/activity_screen.dart';
import 'package:neforum_app/ui/compose/publish_progress_sheet.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'package:neforum_app/platform/storage.dart';

class _Host implements PublishHost {
  final begins = <Map<String, Object?>>[];
  final updates = <Map<String, Object?>>[];
  final ends = <Map<String, Object?>>[];
  final controller = StreamController<PublishHostEvent>.broadcast(sync: true);

  @override
  Stream<PublishHostEvent> get events => controller.stream;

  @override
  Future<bool> begin({required String postId, required String title, required List<PublishHostNetwork> networks}) async {
    begins.add({'postId': postId, 'title': title, 'networks': [for (final n in networks) n.toJson()]});
    return true;
  }

  @override
  Future<void> update(Map<String, Object?> snapshot) async => updates.add(snapshot);

  @override
  Future<void> end({required String postId, required String summary}) async => ends.add({'postId': postId, 'summary': summary});
}

class _DeadMan implements PublishDeadMan {
  final armed = <(PublishSurfaceNotice, DateTime)>[];
  final shown = <PublishSurfaceNotice>[];
  int disarms = 0;

  @override
  Future<void> arm(String postId, PublishSurfaceNotice notice, DateTime at) async => armed.add((notice, at));

  @override
  Future<void> disarm(String postId) async => disarms++;

  @override
  Future<void> show(String postId, PublishSurfaceNotice notice) async => shown.add(notice);
}

PostProgress _progress({int posted = 1, int total = 3}) => PostProgress(
      postId: 'p',
      permille: 100,
      posted: posted,
      failed: 0,
      total: total,
      at: DateTime.utc(2026),
      targets: [
        for (var i = 0; i < total; i++)
          TargetProgress(
            accountId: 'a$i',
            name: 'N$i',
            permille: i < posted ? 1000 : 0,
            family: ProgressFamily.direct,
            stage: i == posted ? ProgressStage.uploading : null,
            label: null,
            stageStartedAt: null,
            outcome: i < posted ? TargetOutcome.published : null,
          ),
      ],
    );

void main() {
  late _Host host;
  late _DeadMan deadMan;
  late DateTime now;
  var cancels = 0;
  late PublishRunSession session;

  void advance(int seconds) => now = now.add(Duration(seconds: seconds));

  setUp(() {
    host = _Host();
    deadMan = _DeadMan();
    now = DateTime.utc(2026, 11, 7, 12);
    cancels = 0;
    session = PublishRunSession(
      postId: 'p',
      host: host,
      deadMan: deadMan,
      platform: PublishSurfacePlatform.ios,
      onCancel: () => cancels++,
      clock: () => now,
    );
  });

  tearDown(() => session.dispose());

  group('the dead-man notification', () {
    test('is armed on leaving, 45 s ahead, not before', () {
      session.progress(_progress());
      expect(deadMan.armed, isEmpty);
      session.windowChanged(visible: false);
      expect(deadMan.armed.single.$2, now.add(const Duration(seconds: 45)));
      expect(deadMan.armed.single.$1.text, 'Posting paused by iOS. 1 of 3 posted, 2 to go. Open NEFORUM to finish.');
      expect(deadMan.shown, isEmpty, reason: 'armed, not shown');
    });

    test('each heartbeat pushes it back, so only a stopped process lets it fire', () {
      session.progress(_progress());
      session.windowChanged(visible: false);
      advance(15);
      session.beat();
      advance(15);
      session.beat();
      expect(deadMan.armed, hasLength(3));
      expect(deadMan.armed.last.$2, now.add(const Duration(seconds: 45)));
    });

    test('a new count changes its words right away', () {
      session.progress(_progress());
      session.windowChanged(visible: false);
      session.progress(_progress(posted: 2));
      expect(deadMan.armed.last.$1.body, startsWith('2 of 3 posted, 1 to go'));
      session.progress(_progress(posted: 2));
      expect(deadMan.armed, hasLength(2), reason: 'the same words need no new one');
    });

    test('coming back cancels it', () {
      session.progress(_progress());
      session.windowChanged(visible: false);
      session.windowChanged(visible: true);
      expect(deadMan.disarms, 1);
    });

    test('the end of the run cancels it', () async {
      session.progress(_progress());
      session.windowChanged(visible: false);
      await session.finish(_progress(posted: 3));
      expect(deadMan.disarms, 1);
    });

    test('a run still getting ready has none, as the table says', () {
      session.windowChanged(visible: false);
      expect(deadMan.armed, isEmpty);
    });
  });

  group('what the system says', () {
    test('windowClosing holds back the next post, and the Live Activity says so', () {
      session.progress(_progress());
      session.windowChanged(visible: false);
      host.controller.add(const PublishHostWindowClosing());
      expect(session.pause.isPaused, isTrue);
      expect(session.state.phase, PublishSurfacePhase.paused);
      expect(host.updates.last['activityLabel'], startsWith('Paused by iOS'));
    });

    test('windowClosing with the window in front means nothing', () {
      session.progress(_progress());
      host.controller.add(const PublishHostWindowClosing());
      expect(session.pause.isPaused, isFalse);
    });

    test('coming back from a hold goes on by itself', () {
      session.progress(_progress());
      session.windowChanged(visible: false);
      host.controller.add(const PublishHostWindowClosing());
      session.windowChanged(visible: true);
      expect(session.pause.isPaused, isFalse);
      expect(session.state.phase, PublishSurfacePhase.posting);
      expect(host.updates.last['activityLabel'], 'Posting 2 of 3');
    });

    test('timedOut stops the run until the person answers, and coming back is no answer', () {
      session.progress(_progress());
      session.windowChanged(visible: false);
      host.controller.add(const PublishHostTimedOut());
      expect(session.pause.isPaused, isTrue);
      expect(session.state.phase, PublishSurfacePhase.stopped);
      expect(deadMan.shown.single.text, 'Stopped. Open NEFORUM to continue.');
      expect(host.updates.last['activityLabel'], isNull, reason: 'the Live Activity ends');
      session.windowChanged(visible: true);
      expect(session.pause.isPaused, isTrue);
      expect(session.state.actions, [PublishSurfaceAction.continueRun, PublishSurfaceAction.cancelRest]);
    });

    test('the stopped notification comes once, not with every heartbeat', () {
      session.progress(_progress());
      session.windowChanged(visible: false);
      host.controller.add(const PublishHostTimedOut());
      session.beat();
      session.beat();
      expect(deadMan.shown, hasLength(1));
    });

    test('Continue is a tap, so the host is asked for new time', () {
      session.begin(title: 't', networks: const []);
      session.progress(_progress());
      host.controller.add(const PublishHostTimedOut());
      session.continueRun();
      expect(session.pause.isPaused, isFalse);
      expect(session.state.phase, PublishSurfacePhase.posting);
      expect(host.begins, hasLength(2));
    });

    test('Continue does nothing unless the run stopped', () {
      session.begin(title: 't', networks: const []);
      session.progress(_progress());
      session.continueRun();
      expect(host.begins, hasLength(1));
    });

    test('cancelRequested routes to this run only', () {
      host.controller.add(const PublishHostCancelRequested('other'));
      expect(cancels, 0);
      host.controller.add(const PublishHostCancelRequested('p'));
      expect(cancels, 1);
    });
  });

  group('coming back after iOS froze the app', () {
    test('a heartbeat gap says so, briefly, then the words go back', () {
      session.progress(_progress());
      session.windowChanged(visible: false);
      advance(120);
      session.windowChanged(visible: true);
      expect(session.state.inAppNotice, 'iOS paused NEFORUM. Continuing.');
      advance(5);
      session.beat();
      expect(session.state.inAppNotice, 'If you leave, iOS may pause this.');
    });

    test('a timer that fires first does not hide the freeze', () {
      session.progress(_progress());
      session.windowChanged(visible: false);
      advance(120);
      session.beat();
      advance(1);
      session.windowChanged(visible: true);
      expect(session.state.inAppNotice, 'iOS paused NEFORUM. Continuing.');
    });

    test('a short time away is no pause', () {
      session.progress(_progress());
      session.windowChanged(visible: false);
      advance(10);
      session.windowChanged(visible: true);
      expect(session.state.inAppNotice, 'If you leave, iOS may pause this.');
    });
  });

  group('the host never holds up a run', () {
    test('a host that fails to begin changes nothing', () async {
      session.dispose();
      session = PublishRunSession(postId: 'p', host: const NoopPublishHost(), deadMan: deadMan, platform: PublishSurfacePlatform.ios, onCancel: () {}, clock: () => now);
      session.begin(title: 't', networks: const []);
      session.progress(_progress());
      expect(session.pause.isPaused, isFalse);
      await session.finish(_progress(posted: 3));
    });

    testWidgets('a channel nobody answers is no surface, not an error', (tester) async {
      await tester.runAsync(() async {
        final channel = ChannelPublishHost(channel: const MethodChannel('test/none'));
        expect(await channel.begin(postId: 'p', title: 't', networks: const []), isFalse);
        await channel.update(const {'phase': 'posting'});
        await channel.end(postId: 'p', summary: 's');
      });
    });

    testWidgets('native calls become events', (tester) async {
      expect(ChannelPublishHost.eventOf(const MethodCall('cancelRequested', {'postId': 'p'})), isA<PublishHostCancelRequested>());
      expect(ChannelPublishHost.eventOf(const MethodCall('timedOut')), isA<PublishHostTimedOut>());
      expect(ChannelPublishHost.eventOf(const MethodCall('windowClosing')), isA<PublishHostWindowClosing>());
      expect(ChannelPublishHost.eventOf(const MethodCall('anything')), isNull);
    });

    testWidgets('the channel sends the contract\'s methods and arguments', (tester) async {
      const name = MethodChannel('test/host');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(name, (c) async {
        calls.add(c);
        return c.method == 'begin' ? true : null;
      });
      await tester.runAsync(() async {
        final channel = ChannelPublishHost(channel: name);
        expect(
          await channel.begin(postId: 'p', title: 'Posting to 1 network', networks: const [PublishHostNetwork(id: 'a', name: 'X', bytes: 3)]),
          isTrue,
        );
        await channel.update(const {'phase': 'posting'});
        await channel.end(postId: 'p', summary: 'Posted to 1 of 1');
        expect(calls.map((c) => c.method), ['begin', 'update', 'end']);
        expect(calls.first.arguments, {
          'postId': 'p',
          'title': 'Posting to 1 network',
          'networks': [
            {'id': 'a', 'name': 'X', 'bytes': 3}
          ],
        });
      });
      expect(calls.last.arguments, {'postId': 'p', 'summary': 'Posted to 1 of 1'});
    });
  });

  group('the end of a run', () {
    test('tells the host how it went, and lets anything still held go', () async {
      session.progress(_progress());
      session.windowChanged(visible: false);
      host.controller.add(const PublishHostWindowClosing());
      await session.finish(_progress(posted: 3));
      expect(session.pause.isPaused, isFalse);
      expect(host.ends.single, {'postId': 'p', 'summary': 'Posted to 3 of 3'});
    });

    test('an error says it stopped, never that it went out', () async {
      await session.finish(null, error: 'boom');
      expect(host.ends.single['summary'], 'Posting stopped');
    });

    test('leaves one local line: what kept it, freezes, and how it ended, nothing else', () async {
      final lines = <String>[];
      session.dispose();
      session = PublishRunSession(
        postId: 'p',
        host: host,
        deadMan: deadMan,
        platform: PublishSurfacePlatform.ios,
        onCancel: () {},
        clock: () => now,
        log: Logger('t', sink: (l, a, m, [e]) => lines.add(m)),
      );
      session.begin(title: 't', networks: const []);
      await Future<void>.delayed(Duration.zero);
      session.progress(_progress());
      session.windowChanged(visible: false);
      advance(120);
      session.windowChanged(visible: true);
      await session.finish(_progress(posted: 3));
      expect(lines.single, 'Run p: keeper took it, freezes 1, closings 0, stops 0, ended done');
    });

    test('nothing happens after it', () async {
      await session.finish(_progress(posted: 3));
      final updates = host.updates.length;
      session.progress(_progress());
      session.beat();
      session.windowChanged(visible: false);
      expect(host.updates, hasLength(updates));
    });
  });

  group('a real run through the composer', () {
    Future<(AppServices, ProviderContainer, _Host)> setUpRun() async {
      final services = await AppServices.create(demo: true, storage: await openAppStorageForTest());
      final fake = _Host();
      final container = ProviderContainer(overrides: [
        servicesProvider.overrideWithValue(services),
        publishHostProvider.overrideWithValue(fake),
        publishDeadManProvider.overrideWithValue(_DeadMan()),
      ]);
      container.listen(postsProvider, (_, _) {});
      container.listen(accountsProvider, (_, _) {});
      await container.read(accountsProvider.future);
      return (services, container, fake);
    }

    test('starts the host at the tap, feeds it, ends it, and never sends the words of the post', () async {
      const secret = 'words nobody may read on a Lock Screen';
      final (services, c, fake) = await setUpRun();
      addTearDown(c.dispose);
      addTearDown(services.dispose);
      final account = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon').id;
      c.read(composerProvider.notifier)
        ..setText(secret)
        ..selectAccounts([account]);
      await c.read(postActionsProvider).publishNow();
      expect(fake.begins, hasLength(1));
      expect(fake.begins.single['title'], 'Posting to 1 network');
      expect(fake.updates, isNotEmpty);
      expect(fake.ends, hasLength(1));
      for (final m in [...fake.begins, ...fake.updates, ...fake.ends]) {
        expect('$m', isNot(contains(secret)));
      }
    });
  });

  group('the sheet line', () {
    testWidgets('a stopped run offers Continue and Cancel the rest, and Continue goes on', (tester) async {
      final services = await AppServices.create(demo: true, storage: await openAppStorageForTest());
      final fake = _Host();
      final container = ProviderContainer(overrides: [
        servicesProvider.overrideWithValue(services),
        publishHostProvider.overrideWithValue(fake),
        publishDeadManProvider.overrideWithValue(_DeadMan()),
      ]);
      addTearDown(container.dispose);
      addTearDown(services.dispose);
      container.read(publishRunProvider.notifier)
        ..prepare()
        ..start('p', const ['a0']);
      final run = container.read(publishSurfaceProvider.notifier).start('p', title: 't', networks: const []);
      run.progress(_progress());
      fake.controller.add(const PublishHostTimedOut());
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: buildTheme(Brightness.light, AccentChoice.values.first), home: const Scaffold(body: PublishSurfaceLine())),
      ));
      expect(find.text('Stopped. 1 of 3 posted.'), findsOneWidget);
      expect(find.text('Cancel the rest'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(run.pause.isPaused, isFalse);
      expect(find.text('Continue'), findsNothing);
      run.dispose();
    });
  });

  group('the Activity banner after a closed run', () {
    Post closed(List<(TargetStatus, String?)> targets) => Post(
          id: 'c',
          text: 'hello',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          status: PostStatus.failed,
          targets: [
            for (var i = 0; i < targets.length; i++)
              PostTarget(
                accountId: 'a$i',
                status: targets[i].$1,
                result: targets[i].$2 == null ? null : PublishResult.failure(PublishError(kind: PublishErrorKind.network, message: targets[i].$2!)),
              ),
          ],
        );

    test('counts what went out, in words that name neither iOS nor the person', () {
      final p = closed([(TargetStatus.published, null), (TargetStatus.published, null), (TargetStatus.failed, AppServices.interruptedMessage)]);
      expect(closedRunSurface(p, DateTime.utc(2026)).inAppNotice, 'NEFORUM was closed before this finished. 2 of 3 posted.');
      expect(AppServices.interruptedMessage, isNot(contains('iOS')));
    });

    test('Continue covers only what was left behind, never a post that may be live', () {
      final p = closed([
        (TargetStatus.published, null),
        (TargetStatus.failed, AppServices.interruptedMessage),
        (TargetStatus.failed, PublishError.unconfirmedMessage('Threads')),
        (TargetStatus.failed, 'Refused'),
      ]);
      expect(closedRunAccounts(p), {'a1'});
    });

    testWidgets('shows on iOS with a Continue button', (tester) async {
      final p = closed([(TargetStatus.published, null), (TargetStatus.failed, AppServices.interruptedMessage)]);
      final services = await AppServices.create(demo: true, storage: await openAppStorageForTest());
      final container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(services)]);
      addTearDown(container.dispose);
      addTearDown(services.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: buildTheme(Brightness.light, AccentChoice.values.first), home: Scaffold(body: ClosedRunBanner(post: p))),
      ));
      expect(find.text('NEFORUM was closed before this finished. 1 of 2 posted.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
    });
  });

  group('the result notification', () {
    test('a post that may be live comes first in its words', () {
      final p = Post(
        id: 'p',
        text: 'hello',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        status: PostStatus.failed,
        targets: [
          PostTarget(accountId: 'a', status: TargetStatus.failed, result: PublishResult.failure(const PublishError.network('plain'))),
          PostTarget(
            accountId: 'b',
            status: TargetStatus.failed,
            result: PublishResult.failure(PublishError(kind: PublishErrorKind.network, message: PublishError.unconfirmedMessage('Threads'), outcomeUnknown: true)),
          ),
        ],
      );
      expect(PostActions.publishResultBody(p), 'NEFORUM could not confirm this. Check Threads before retrying.');
    });
  });

  testWidgets('the window listener tells a running session', (tester) async {
    final services = await AppServices.create(demo: true, storage: await openAppStorageForTest());
    final fake = _Host();
    final container = ProviderContainer(overrides: [
      servicesProvider.overrideWithValue(services),
      publishHostProvider.overrideWithValue(fake),
      publishDeadManProvider.overrideWithValue(_DeadMan()),
    ]);
    addTearDown(container.dispose);
    addTearDown(services.dispose);
    late AppLifecycleListener listener;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: Consumer(builder: (context, ref, _) {
        listener = publishWindowListener(ref);
        return const SizedBox();
      }),
    ));
    addTearDown(() => listener.dispose());
    final run = container.read(publishSurfaceProvider.notifier).start('p', title: 't', networks: const []);
    run.progress(_progress());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(run.state.backgrounded, isFalse, reason: 'still in front');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(run.state.backgrounded, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(run.state.backgrounded, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    run.dispose();
  });
}

Future<AppStorage> openAppStorageForTest() async => _MemoryStorage();

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  final Map<String, Uint8List> _media = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async {
    final path = 'mem://$id.$extension';
    _media[path] = bytes;
    return path;
  }

  @override
  Future<Uint8List> readMedia(String path) async => _media[path]!;
  @override
  Future<void> deleteMedia(String path) async => _media.remove(path);
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}
