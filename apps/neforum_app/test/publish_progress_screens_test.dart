// What the screens show of a publish run: the sheet's real bar and rows, the same
// figure in Activity and on the post's page, and no number during a wait unless the
// network sent one. Figures come through the real tracker, with an injected clock.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/publish_progress_view.dart';
import 'package:neforum_app/state/scheduler.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/publish_progress_sheet.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/widgets/publish_progress.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

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

const _mib = 1024 * 1024;
final _start = DateTime.utc(2026, 11, 7, 12);

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-SemiBold.ttf', 'assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
  await family('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf']);
}

/// A sheet with a run in it, and the clock and tracker behind the figures.
class _Sheet {
  _Sheet(this.tester, this.container, this.services);
  final WidgetTester tester;
  final ProviderContainer container;
  final AppServices services;
  late PublishProgressTracker tracker;
  DateTime now = _start;

  double? get postBar => tester.widget<LinearProgressIndicator>(find.byKey(PostProgressFigure.barKey)).value;
  double? rowBar(String id) => tester.widget<LinearProgressIndicator>(find.byKey(TargetProgressLine.barKey(id))).value;

  /// All the text on screen.
  String get words => tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').join(' | ');

  Finder row(String network) => find.ancestor(of: find.text(network), matching: find.byType(Padding)).first;
  Finder spinnerIn(String network) => find.descendant(of: row(network), matching: find.byType(CircularProgressIndicator));

  ProgressEvent bytes(int position, int total, {String slot = 'm', int attempt = 1, String label = 'Uploading image 1 of 1'}) =>
      ProgressEvent(stage: ProgressStage.uploading, label: label, at: now, slot: slot, position: position, slotTotal: total, attempt: attempt);
  ProgressEvent wait(String label, {int? percent}) => ProgressEvent(stage: ProgressStage.serverProcessing, label: label, at: now, serverPercent: percent);

  /// One thing the run reports, a second after the last, as the tracker only publishes
  /// a change of stage at once.
  Future<void> send(String id, ProgressEvent Function() event) async {
    now = now.add(const Duration(seconds: 1));
    tracker.event(id, event());
    await tester.pump();
  }

  Future<void> tick(Duration d) async {
    now = now.add(d);
    await tester.pump(d);
  }
}

PlannedTarget _bytesTarget(String id, String name, {int bytes = 4 * _mib, ProgressFamily family = ProgressFamily.direct}) =>
    PlannedTarget(accountId: id, name: name, shape: ProgressShape(family: family, slots: [ProgressSlot('m', bytes)]));
PlannedTarget _textTarget(String id, String name) => PlannedTarget(accountId: id, name: name, shape: const ProgressShape(family: ProgressFamily.textOnly));

Future<_Sheet> _open(WidgetTester tester, List<PlannedTarget> plan, {Size size = const Size(1200, 900), double textScale = 1, Brightness brightness = Brightness.light, Post? saved}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
  if (saved != null) await tester.runAsync(() => services.posts.upsert(saved));
  late _Sheet sheet;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      servicesProvider.overrideWithValue(services),
      publishClockProvider.overrideWithValue(() => sheet.now),
    ],
    child: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
      child: MaterialApp(
        theme: buildTheme(brightness, AccentChoice.neforum),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
        home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => showPublishProgress(context), child: const Text('open')))),
      ),
    ),
  ));
  final container = ProviderScope.containerOf(tester.element(find.text('open')));
  sheet = _Sheet(tester, container, services);
  container.listen(postsProvider, (_, _) {});
  container.read(publishRunProvider.notifier).start('p1', [for (final t in plan) t.accountId]);
  sheet.tracker = container.read(publishProgressProvider.notifier).begin('p1');
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(milliseconds: 400));
  sheet.tracker.plan(PublishRunPlan(postId: 'p1', targets: plan));
  await tester.pump();
  return sheet;
}

Post _savedPost(List<PostTarget> targets, {PostStatus status = PostStatus.publishing}) =>
    Post(id: 'p1', text: 'Hello', createdAt: _start, updatedAt: _start, status: status, targets: targets);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  group('the wording', () {
    TargetProgress target({
      ProgressStage? stage,
      String? label,
      int? permille = 100,
      ProgressFamily family = ProgressFamily.direct,
      DateTime? startedAt,
      DateTime? allSentAt,
      int? position,
      int? total,
      int? serverPercent,
      bool resending = false,
      Duration? eta,
      int? speed,
    }) =>
        TargetProgress(
          accountId: 'a',
          name: 'Bluesky',
          permille: permille,
          family: family,
          stage: stage,
          label: label,
          stageStartedAt: startedAt,
          allSentAt: allSentAt,
          position: position,
          slotTotal: total,
          serverPercent: serverPercent,
          resending: resending,
          eta: eta,
          bytesPerSecond: speed,
        );

    test('pending and hand-off have no spinner, no bar and no number', () {
      for (final (t, line) in [(target(), 'Waiting'), (target(stage: ProgressStage.handingOff, label: 'Waiting for you'), 'Waiting for you')]) {
        final v = targetRowView(t, _start);
        expect(v.line, line);
        expect(v.activity, isFalse);
        expect(v.bar, isNull);
        expect(v.percent, isNull);
      }
    });

    test('a wait shows its words and elapsed time, and no number the network did not send', () {
      final at = _start.add(const Duration(minutes: 1, seconds: 12));
      final plain = targetRowView(target(stage: ProgressStage.serverProcessing, label: 'Instagram is processing your Reel', startedAt: _start), at);
      expect(plain.line, 'Instagram is processing your Reel · 1:12');
      expect(plain.percent, isNull);
      expect(plain.activity, isTrue);
      expect(plain.bar, 0.1);

      final reported = targetRowView(target(stage: ProgressStage.serverProcessing, label: 'X is processing the video (45%)', startedAt: _start, serverPercent: 45), at);
      expect(reported.line, 'X is processing the video (45%) · 1:12', reason: 'the number is not said twice');
      expect(reported.percent, '45%');
      expect(targetRowView(target(stage: ProgressStage.serverProcessing, label: 'Working', startedAt: _start, serverPercent: 45), at).line, 'Working (45%) · 1:12');
    });

    test('the other stages that cannot be measured are waits too', () {
      for (final stage in [ProgressStage.renewingSignIn, ProgressStage.reading, ProgressStage.posting]) {
        final v = targetRowView(target(stage: stage, label: 'Doing it', startedAt: _start), _start.add(const Duration(seconds: 7)));
        expect(v.line, 'Doing it · 0:07', reason: stage.name);
        expect(v.percent, isNull, reason: stage.name);
      }
    });

    test('an empty label still says something', () {
      expect(targetRowView(target(stage: ProgressStage.serverProcessing, label: '', startedAt: _start), _start).line, 'Waiting for Bluesky · 0:00');
      expect(targetRowView(target(stage: ProgressStage.posting, startedAt: _start), _start).line, 'Posting · 0:00');
    });

    test('bytes say sent, never received; time left only when the meter has one', () {
      final moving = targetRowView(target(stage: ProgressStage.uploading, label: 'Uploading video', startedAt: _start, position: 3 * _mib, total: 10 * _mib, permille: 270), _start);
      expect(moving.line, 'Uploading video · Sent 3.0 MB of 10.0 MB');
      expect(moving.percent, '27%');
      expect(moving.activity, isFalse);
      expect(moving.line, isNot(contains('received')));

      final measured = targetRowView(
        target(stage: ProgressStage.uploading, label: 'Uploading video', startedAt: _start, position: 3 * _mib, total: 10 * _mib, eta: const Duration(seconds: 90), speed: _mib),
        _start,
      );
      expect(measured.line, 'Uploading video · Sent 3.0 MB of 10.0 MB · 1.0 MB/s · about 2 min left to send');
    });

    test('bytes that stopped moving have no time left', () {
      final t = target(stage: ProgressStage.uploading, label: 'Uploading video', startedAt: _start, position: 3 * _mib, total: 10 * _mib, eta: const Duration(seconds: 90), speed: _mib);
      expect(targetRowView(t, _start.add(const Duration(seconds: 19)), reportedAt: _start).line, contains('left to send'));
      final stalled = targetRowView(t, _start.add(const Duration(seconds: 21)), reportedAt: _start).line;
      expect(stalled, isNot(contains('left to send')));
      expect(stalled, isNot(contains('MB/s')));
    });

    test('all sent with no answer: what was sent, whose turn it is, and how long since', () {
      final v = targetRowView(
        target(stage: ProgressStage.uploading, label: 'Uploading', startedAt: _start, allSentAt: _start.add(const Duration(seconds: 30)), position: 3 * _mib, total: 3 * _mib, permille: 900),
        _start.add(const Duration(seconds: 42)),
      );
      expect(v.line, 'Sent 3.0 MB, waiting for Bluesky · 0:12');
      expect(v.percent, isNull);
      expect(v.activity, isTrue);
      expect(v.bar, 0.9);
    });

    test('a dropped connection says so and the figure holds', () {
      final v = targetRowView(target(stage: ProgressStage.uploading, label: 'Uploading', startedAt: _start, position: 10, total: 100, resending: true, permille: 630), _start);
      expect(v.line, 'Connection dropped, sending again');
      expect(v.bar, 0.63);
      expect(v.percent, '63%');
    });

    test('a network nothing can be measured on has words and time only', () {
      final v = targetRowView(
        target(stage: ProgressStage.uploading, label: 'Publishing on Odysee', startedAt: _start, permille: null, family: ProgressFamily.opaque),
        _start.add(const Duration(seconds: 65)),
      );
      expect(v.line, 'Publishing on Odysee · 1:05');
      expect(v.bar, isNull);
      expect(v.percent, isNull);
    });

    test('figures round down, so nothing claims more than was counted', () {
      expect(percentLabel(0), '0%');
      expect(percentLabel(999), '99%');
      expect(percentLabel(990), '99%');
      expect(percentLabel(1000), '100%');
    });

    test('time labels', () {
      expect(elapsedLabel(const Duration(seconds: 7)), '0:07');
      expect(elapsedLabel(const Duration(minutes: 12, seconds: 3)), '12:03');
      expect(elapsedLabel(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
      expect(elapsedLabel(const Duration(seconds: -5)), '0:00', reason: 'a clock that stepped back shows no minus sign');
      expect(timeLeftLabel(const Duration(seconds: 20)), 'about a minute left to send');
      expect(timeLeftLabel(const Duration(seconds: 61)), 'about 2 min left to send');
      expect(timeLeftLabel(const Duration(minutes: 70)), 'about an hour left to send');
      expect(timeLeftLabel(const Duration(minutes: 180)), 'about 3 hours left to send');
    });

    test('a finished target shows what the saved target knows', () {
      const held = PostTarget(accountId: 'a', status: TargetStatus.heldByPlatform);
      expect(statusOfOutcome(TargetOutcome.published), TargetStatus.published);
      expect(statusOfOutcome(TargetOutcome.published, saved: held), TargetStatus.heldByPlatform);
      expect(statusOfOutcome(TargetOutcome.failed), TargetStatus.failed);
      final retrying = PostTarget(accountId: 'a', result: PublishResult.failure(const PublishError.network('Offline')));
      expect(statusOfOutcome(TargetOutcome.failed, saved: retrying), TargetStatus.pending, reason: 'it goes back in the queue, as the sheet says at the end');
      expect(statusOfOutcome(TargetOutcome.awaitingUser), TargetStatus.awaitingHandoff);
    });

    test('a background run is another owner with a recent heartbeat', () {
      final journal = PublishJournal.inMemory(owner: 'ui');
      PublishJournalEntry entry(String owner, Duration age) => PublishJournalEntry(postId: 'p', owner: owner, startedAt: _start, heartbeatAt: _start.subtract(age));
      expect(isBackgroundRun(null, journal, _start), isFalse, reason: 'another device, or a run that left no record');
      expect(isBackgroundRun(entry('ui', Duration.zero), journal, _start), isFalse, reason: 'this process');
      expect(isBackgroundRun(entry('bg', const Duration(seconds: 90)), journal, _start), isTrue);
      expect(isBackgroundRun(entry('bg', const Duration(minutes: 3)), journal, _start), isFalse, reason: 'it stopped: saying it is posting would be untrue');
    });
  });

  group('the sheet', () {
    testWidgets('a run that has not moved reads 0, not the old 5% clamp', (tester) async {
      final s = await _open(tester, [_bytesTarget('a', 'Mastodon'), _bytesTarget('b', 'Bluesky')]);
      expect(s.postBar, 0);
      expect(find.text('0%'), findsOneWidget);
      expect(find.text('Posted to 0 of 2'), findsOneWidget);
    });

    testWidgets('before the plan there is no number at all', (tester) async {
      final s = await _open(tester, [_bytesTarget('a', 'Mastodon')]);
      s.container.read(publishRunProvider.notifier).prepare();
      s.container.read(publishRunProvider.notifier).start('p2', ['a']);
      await tester.pump();
      expect(s.postBar, isNull);
      expect(find.textContaining('%'), findsNothing);
      expect(s.words, contains('Waiting'));
    });

    testWidgets('the bar moves through a run, never falls, and reads 100 only when every network ended', (tester) async {
      final s = await _open(tester, [_bytesTarget('a', 'Mastodon'), _bytesTarget('b', 'Bluesky')]);
      final seen = <double>[s.postBar!];
      final rowSeen = <double>[];
      Future<void> send(String id, ProgressEvent Function() e) async {
        await s.send(id, e);
        seen.add(s.postBar!);
      }

      for (final p in [_mib, 2 * _mib, 3 * _mib]) {
        await send('a', () => s.bytes(p, 4 * _mib));
        rowSeen.add(s.rowBar('a')!);
      }
      expect(seen.last, greaterThan(seen.first), reason: 'the bar moved');
      final held = seen.last;
      // The connection drops: the same file starts over from the beginning.
      await send('a', () => s.bytes(1000, 4 * _mib, attempt: 2));
      rowSeen.add(s.rowBar('a')!);
      expect(seen.last, held, reason: 'it holds');
      expect(find.text('Connection dropped, sending again'), findsOneWidget);
      await send('a', () => s.bytes(4 * _mib, 4 * _mib, attempt: 2));
      rowSeen.add(s.rowBar('a')!);
      expect(seen.last, greaterThan(held));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]), reason: 'post bar at step $i');
      }
      for (var i = 1; i < rowSeen.length; i++) {
        expect(rowSeen[i], greaterThanOrEqualTo(rowSeen[i - 1]), reason: 'row bar at step $i');
      }

      s.tracker.outcome('a', TargetOutcome.published);
      await tester.pump();
      seen.add(s.postBar!);
      expect(s.postBar, lessThan(1), reason: 'Bluesky has not ended');
      expect(find.text('Posted to 1 of 2'), findsOneWidget);

      await s.send('b', () => s.bytes(4 * _mib, 4 * _mib));
      expect(s.postBar, lessThanOrEqualTo(0.99), reason: 'all sent is not posted');

      s.tracker.outcome('b', TargetOutcome.published);
      await tester.pump();
      expect(s.postBar, 1);
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('Posted to 2 of 2'), findsOneWidget);
    });

    testWidgets('during a wait the time moves and no number does', (tester) async {
      final s = await _open(tester, [_bytesTarget('a', 'Instagram', family: ProgressFamily.pullFromUrl)]);
      await s.send('a', () => s.bytes(4 * _mib, 4 * _mib));
      await s.send('a', () => s.wait('Instagram is processing your Reel'));
      final bar = s.postBar;
      final rowFigure = s.rowBar('a');
      expect(find.text('Instagram is processing your Reel · 0:00'), findsOneWidget);
      expect(s.spinnerIn('Instagram'), findsOneWidget, reason: 'the small indicator beside the time');
      // The only percentage on screen is the post's own held figure.
      expect(find.textContaining('%'), findsOneWidget);

      for (var i = 0; i < 80; i++) {
        await s.tick(const Duration(seconds: 1));
      }
      expect(find.text('Instagram is processing your Reel · 1:20'), findsOneWidget);
      expect(s.postBar, bar, reason: 'no fake creep');
      expect(s.rowBar('a'), rowFigure);
      expect(find.textContaining('%'), findsOneWidget);

      // Polling for the state is a real request, and still not a number.
      await s.send('a', () => ProgressEvent(stage: ProgressStage.serverProcessing, label: 'Instagram is processing your Reel', at: s.now, waitPolls: 4));
      expect(s.postBar, bar);
    });

    testWidgets('a network that sends its own number moves the bar with it', (tester) async {
      final s = await _open(tester, [_bytesTarget('a', 'X', family: ProgressFamily.waitReported)]);
      await s.send('a', () => s.bytes(4 * _mib, 4 * _mib));
      await s.send('a', () => s.wait('X is processing the video'));
      final before = s.rowBar('a')!;
      expect(find.text('45%'), findsNothing);
      await s.send('a', () => s.wait('X is processing the video (45%)', percent: 45));
      expect(find.text('45%'), findsOneWidget);
      expect(s.rowBar('a')!, greaterThan(before));
    });

    testWidgets('all sent with no answer says so, and the time starts when the bytes ended', (tester) async {
      final s = await _open(tester, [_bytesTarget('a', 'Bluesky')]);
      await s.send('a', () => s.bytes(_mib, 4 * _mib));
      expect(find.textContaining('Sent 1.0 MB of 4.0 MB'), findsOneWidget);
      await s.tick(const Duration(seconds: 30));
      await s.send('a', () => s.bytes(4 * _mib, 4 * _mib));
      for (var i = 0; i < 5; i++) {
        await s.tick(const Duration(seconds: 1));
      }
      expect(find.text('Sent 4.0 MB, waiting for Bluesky · 0:05'), findsOneWidget);
    });

    testWidgets('time left shows only after two windows agree, and never for the whole post', (tester) async {
      final s = await _open(tester, [_bytesTarget('a', 'YouTube', bytes: 1000 * _mib, family: ProgressFamily.wholeFile)]);
      var sent = 0;
      var firstAt = -1;
      for (var second = 1; second <= 40; second++) {
        await s.tick(const Duration(seconds: 1));
        sent += _mib;
        s.tracker.event('a', s.bytes(sent, 1000 * _mib, label: 'Uploading video'));
        await tester.pump();
        if (firstAt < 0 && find.textContaining('left to send').evaluate().isNotEmpty) firstAt = second;
      }
      expect(firstAt, greaterThanOrEqualTo(20), reason: 'no figure before the second window closes');
      expect(find.textContaining('left to send'), findsOneWidget, reason: 'the row only: nothing in the header');
      expect(find.descendant(of: find.byType(PostProgressFigure), matching: find.textContaining('left')), findsNothing);
    });

    testWidgets('a finished row shows its result while the run goes on; a pending one says Waiting with no spinner', (tester) async {
      final s = await _open(
        tester,
        [_textTarget('a', 'Mastodon'), _textTarget('b', 'Bluesky'), _textTarget('c', 'Threads'), _textTarget('d', 'Lemmy')],
        saved: _savedPost(const [PostTarget(accountId: 'a'), PostTarget(accountId: 'b'), PostTarget(accountId: 'c'), PostTarget(accountId: 'd')]),
      );
      expect(find.text('Waiting'), findsNWidgets(4));
      expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'pending never spins');

      await tester.runAsync(() => s.services.posts.upsert(_savedPost([
            PostTarget(accountId: 'a', status: TargetStatus.published, result: PublishResult.ok(remoteId: '1', remoteUrl: 'https://example.test/1')),
            PostTarget(accountId: 'b', status: TargetStatus.failed, result: PublishResult.failure(const PublishError.network('The server said no.'))),
            const PostTarget(accountId: 'c', status: TargetStatus.skipped),
            const PostTarget(accountId: 'd'),
          ])));
      s.tracker.outcome('a', TargetOutcome.published);
      s.tracker.outcome('b', TargetOutcome.failed);
      s.tracker.outcome('c', TargetOutcome.skipped);
      s.tracker.event('d', ProgressEvent(stage: ProgressStage.posting, label: 'Posting', at: s.now));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();

      expect(s.container.read(publishRunProvider)!.done, isFalse, reason: 'the run goes on');
      expect(find.text('Open'), findsOneWidget, reason: 'the link is there at once');
      expect(find.text('The server said no.'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Skipped'), findsWidgets);
      expect(s.spinnerIn('Skipped'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'only the network really being posted to');
      expect(find.text('Posted to 1 of 4'), findsOneWidget);
    });

    testWidgets('a network this run leaves alone has no row', (tester) async {
      final s = await _open(tester, [_textTarget('a', 'Mastodon'), _textTarget('b', 'Bluesky')]);
      s.tracker.outcome('b', TargetOutcome.notThisRun);
      await tester.pump();
      expect(find.text('Posted to 0 of 1'), findsOneWidget);
      expect(find.text('Waiting'), findsOneWidget);
    });

    testWidgets('a hand-off says Waiting for you, with no spinner and no number', (tester) async {
      final s = await _open(tester, [_textTarget('a', 'Instagram')]);
      s.tracker.event('a', ProgressEvent(stage: ProgressStage.handingOff, label: 'Waiting for you', at: s.now));
      await tester.pump();
      expect(find.text('Waiting for you'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(TargetProgressLine.barKey('a')), findsNothing);
      s.tracker.outcome('a', TargetOutcome.awaitingUser);
      await tester.pump();
      expect(find.text('Waiting for you'), findsOneWidget, reason: 'still waiting once the run has moved on');
      expect(find.text('Tap to post'), findsOneWidget);
    });

    testWidgets('a network nothing can be measured on shows no bar and no number', (tester) async {
      final s = await _open(tester, [PlannedTarget(accountId: 'a', name: 'Odysee', shape: const ProgressShape(family: ProgressFamily.opaque, slots: [ProgressSlot('m', _mib)]))]);
      s.tracker.event('a', ProgressEvent(stage: ProgressStage.uploading, label: 'Publishing on Odysee', at: s.now));
      await tester.pump();
      for (var i = 0; i < 9; i++) {
        await s.tick(const Duration(seconds: 1));
      }
      expect(find.text('Publishing on Odysee · 0:09'), findsOneWidget);
      expect(find.byKey(TargetProgressLine.barKey('a')), findsNothing);
    });

    testWidgets('semantics carry the values', (tester) async {
      final handle = tester.ensureSemantics();
      final s = await _open(tester, [_bytesTarget('a', 'Mastodon'), _bytesTarget('b', 'Bluesky')]);
      await s.send('a', () => s.bytes(2 * _mib, 4 * _mib));

      expect(find.bySemanticsLabel('Post progress, posted to 0 of 2'), findsOneWidget);
      expect(tester.getSemantics(find.bySemanticsLabel('Post progress, posted to 0 of 2')).value, '22');
      expect(find.bySemanticsLabel('Mastodon progress'), findsOneWidget);
      expect(tester.getSemantics(find.bySemanticsLabel('Mastodon progress')).value, '45');

      await s.send('a', () => s.bytes(4 * _mib, 4 * _mib));
      await s.send('a', () => s.wait('Mastodon is processing the file'));
      expect(find.bySemanticsLabel('Mastodon progress'), findsNothing, reason: 'during a wait the words say it, with no number to read out');
      expect(find.bySemanticsLabel(RegExp('Mastodon is processing the file')), findsOneWidget);
      handle.dispose();
    });

    for (final brightness in Brightness.values) {
      for (final scale in const [1.0, 1.5]) {
        testWidgets('no overflow at 360 x 640, 21 networks, text at $scale, ${brightness.name}', (tester) async {
          final s = await _open(
            tester,
            [for (var i = 0; i < 21; i++) _bytesTarget('a$i', 'A very long network name number $i', bytes: 800 * _mib)],
            size: const Size(360, 640),
            textScale: scale,
            brightness: brightness,
          );
          s.tracker.event('a0', ProgressEvent(stage: ProgressStage.uploading, label: 'Uploading a video with a very long file name that needs a lot of room.mov', at: s.now, slot: 'm', position: 90 * _mib, slotTotal: 800 * _mib));
          s.tracker.event('a1', s.wait('A very long network name number 1 is processing a video with a very long file name that needs a lot of room.mov'));
          s.tracker.event('a2', ProgressEvent(stage: ProgressStage.handingOff, label: 'Waiting for you', at: s.now));
          s.tracker.outcome('a3', TargetOutcome.published);
          s.tracker.outcome('a4', TargetOutcome.failed);
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(s.postBar, isNotNull);
          expect(find.text('Cancel'), findsOneWidget, reason: 'Cancel stays reachable');
        });
      }
    }

    testWidgets('no overflow on a phone on its side at the largest text', (tester) async {
      final s = await _open(tester, [_bytesTarget('a', 'Mastodon')], size: const Size(640, 360), textScale: 1.5);
      expect(tester.takeException(), isNull);
      expect(s.postBar, isNotNull);
    });
  });

  group('every run of this process has figures', () {
    Future<(AppServices, ProviderContainer)> demo() async {
      final services = await AppServices.create(demo: true, storage: _MemoryStorage());
      await services.saveSettings(services.settings.copyWith(publishedPostRetention: PublishedPostRetention.retainIndefinitely));
      final c = ProviderContainer(overrides: [servicesProvider.overrideWithValue(services)]);
      c.listen(postsProvider, (_, _) {});
      c.listen(accountsProvider, (_, _) {});
      await c.read(accountsProvider.future);
      return (services, c);
    }

    MediaAttachment media() => const MediaAttachment(id: 'photo', path: 'mem://photo.png', mimeType: 'image/png', sizeBytes: 2 * _mib);

    /// Outside the test clock: the demo publishes on real timers.
    void realTime(String description, Future<void> Function(AppServices services, ProviderContainer c) body) {
      testWidgets(description, (tester) async {
        await tester.runAsync(() async {
          final (services, c) = await demo();
          try {
            await body(services, c);
          } finally {
            c.dispose();
          }
        });
      }, timeout: const Timeout(Duration(minutes: 1)));
    }

    realTime('a run from the composer: the figure moves, never falls, and a finished network shows before the run ends', (services, c) async {
      final accounts = c.read(accountListProvider);
      final masto = accounts.firstWhere((a) => a.platformId == 'mastodon').id;
      final bsky = accounts.firstWhere((a) => a.platformId == 'bluesky').id;
      await services.posts.upsert(Post(
        id: 'run',
        text: 'Going out',
        createdAt: _start,
        updatedAt: _start,
        status: PostStatus.draft,
        media: [media()],
        targets: [PostTarget(accountId: masto), PostTarget(accountId: bsky)],
      ));
      final seen = <PostProgress>[];
      var doneWhenFirstFinished = true;
      c.listen<Map<String, PostProgress>>(publishProgressProvider, (_, runs) {
        final next = runs['run'];
        if (next == null) return;
        seen.add(next);
        if (next.targets.any((t) => t.finished) && !next.finished) doneWhenFirstFinished = c.read(publishRunProvider)!.done;
      });

      await c.read(postActionsProvider).publishExisting('run');

      expect(seen, isNotEmpty);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i].permille, greaterThanOrEqualTo(seen[i - 1].permille));
      }
      final middle = seen.map((p) => p.permille).where((p) => p > 0 && p < 990);
      expect(middle, isNotEmpty, reason: 'the bar really moved during the run: ${seen.map((p) => p.permille).toList()}');
      expect(doneWhenFirstFinished, isFalse, reason: 'a finished network shows while the run goes on');
      expect(seen.last.permille, 1000);
      expect(c.read(publishProgressProvider), isEmpty, reason: 'a run that ended leaves no figure');
    });

    realTime('a run the scheduler starts has figures too', (services, c) async {
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon').id;
      await services.posts.upsert(Post(
        id: 'due',
        text: 'On time',
        createdAt: _start,
        updatedAt: _start,
        status: PostStatus.scheduled,
        scheduledAt: DateTime.now().subtract(const Duration(minutes: 1)),
        targets: [PostTarget(accountId: masto)],
      ));
      final seen = <int>[];
      c.listen<Map<String, PostProgress>>(publishProgressProvider, (_, runs) {
        final next = runs['due'];
        if (next != null) seen.add(next.permille);
      });
      final done = await c.read(schedulerProvider).runDue();
      expect(done.map((p) => p.id), contains('due'));
      expect(seen, isNotEmpty);
      expect(seen.last, 1000);
      expect(c.read(publishProgressProvider), isEmpty);
    });

    realTime('a retry is a new run with a new bar, which credits what is live', (services, c) async {
      final accounts = c.read(accountListProvider);
      final masto = accounts.firstWhere((a) => a.platformId == 'mastodon').id;
      final bsky = accounts.firstWhere((a) => a.platformId == 'bluesky').id;
      await services.posts.upsert(Post(
        id: 'retry',
        text: 'Again',
        createdAt: _start,
        updatedAt: _start,
        status: PostStatus.partial,
        targets: [
          PostTarget(accountId: masto, status: TargetStatus.published, result: PublishResult.ok(remoteId: '1')),
          PostTarget(accountId: bsky, status: TargetStatus.failed, result: PublishResult.failure(const PublishError.network('Offline'))),
        ],
      ));
      PostProgress? first;
      c.listen<Map<String, PostProgress>>(publishProgressProvider, (_, runs) => first ??= runs['retry']);
      await c.read(postActionsProvider).publishExisting('retry');
      expect(first, isNotNull);
      expect(first!.posted, 1, reason: 'Mastodon has it already');
      expect(first!.total, 2);
      expect(first!.permille, 500, reason: 'two text posts, one live');
    });

    test('two runs at once keep their own figures', () {
      final c = ProviderContainer(overrides: [publishClockProvider.overrideWithValue(() => _start)]);
      addTearDown(c.dispose);
      final figures = c.read(publishProgressProvider.notifier);
      final a = figures.begin('a');
      final b = figures.begin('b');
      a.plan(PublishRunPlan(postId: 'a', targets: [_textTarget('x', 'Mastodon')]));
      b.plan(PublishRunPlan(postId: 'b', targets: [_textTarget('y', 'Bluesky')]));
      a.outcome('x', TargetOutcome.published);
      expect(c.read(publishProgressOfProvider('a'))!.permille, 1000);
      expect(c.read(publishProgressOfProvider('b'))!.permille, 0);
      figures.end('a', a);
      expect(c.read(publishProgressOfProvider('a')), isNull);
      expect(c.read(publishProgressOfProvider('b')), isNotNull);
    });

    test('a new run of one post replaces the old figure, and the old run cannot touch it', () {
      final c = ProviderContainer(overrides: [publishClockProvider.overrideWithValue(() => _start)]);
      addTearDown(c.dispose);
      final figures = c.read(publishProgressProvider.notifier);
      final old = figures.begin('p');
      old.plan(PublishRunPlan(postId: 'p', targets: [_textTarget('x', 'Mastodon')]));
      old.outcome('x', TargetOutcome.published);
      final fresh = figures.begin('p');
      expect(c.read(publishProgressOfProvider('p')), isNull, reason: 'nothing of the last run shows through');
      fresh.plan(PublishRunPlan(postId: 'p', targets: [_textTarget('x', 'Mastodon')]));
      old.outcome('x', TargetOutcome.failed);
      figures.end('p', old);
      expect(c.read(publishProgressOfProvider('p'))!.permille, 0);
    });
  });

  group('Activity and the post page', () {
    Future<(ProviderContainer, AppServices, PublishProgressTracker)> app(WidgetTester tester, {PublishJournal? journal, required List<PostTarget> Function(List<ConnectedAccount>) targets, Size size = const Size(1440, 900)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
      final accounts = (await tester.runAsync(services.accounts.all))!;
      await tester.runAsync(() => services.posts.upsert(Post(id: 'live', text: 'Going out now', createdAt: _start, updatedAt: DateTime.now(), status: PostStatus.publishing, targets: targets(accounts))));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          servicesProvider.overrideWithValue(services),
          if (journal != null) publishJournalProvider.overrideWithValue(journal),
        ],
        child: const NeforumApp(),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
      return (c, services, c.read(publishProgressProvider.notifier).begin('live'));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    List<PostTarget> two(List<ConnectedAccount> accounts) => [
          PostTarget(accountId: accounts.firstWhere((a) => a.platformId == 'mastodon').id),
          PostTarget(accountId: accounts.firstWhere((a) => a.platformId == 'bluesky').id),
        ];

    for (final size in const {'desktop': Size(1440, 900), 'phone': Size(360, 640)}.entries) {
      testWidgets('both show the figure the sheet shows for a run of this process (${size.key})', (tester) async {
        final (c, services, tracker) = await app(tester, targets: two, size: size.value);
        final accounts = (await tester.runAsync(services.accounts.all))!;
        final masto = accounts.firstWhere((a) => a.platformId == 'mastodon').id;
        final bsky = accounts.firstWhere((a) => a.platformId == 'bluesky').id;
        c.read(activePublishingProvider.notifier).begin('live', CancellationSignal());
        tracker.plan(PublishRunPlan(postId: 'live', targets: [_bytesTarget(masto, 'Mastodon'), _bytesTarget(bsky, 'Bluesky')]));
        tracker.event(masto, ProgressEvent(stage: ProgressStage.uploading, label: 'Uploading image 1 of 1', at: DateTime.now(), slot: 'm', position: 2 * _mib, slotTotal: 4 * _mib));
        final figure = percentLabel(c.read(publishProgressOfProvider('live'))!.permille);
        expect(figure, '22%');

        c.read(routerProvider).go('/activity');
        await settle(tester);
        expect(find.text(figure), findsOneWidget, reason: 'Activity');
        expect(find.text('Posted to 0 of 2'), findsOneWidget);

        c.read(routerProvider).go('/activity/post/live');
        await settle(tester);
        expect(find.text(figure), findsOneWidget, reason: 'the post page');
        expect(find.text('Posted to 0 of 2'), findsOneWidget);
        expect(find.textContaining('Sent 2.0 MB of 4.0 MB'), findsOneWidget, reason: 'its row says what it is doing');
        expect(find.text('Waiting'), findsOneWidget, reason: 'the network the run has not reached');
        expect(tester.takeException(), isNull);
        expect(find.text(kPostingInBackground), findsNothing);
        await close(tester);
      });
    }

    testWidgets('before its plan a run of this process has words and no number', (tester) async {
      final (c, _, _) = await app(tester, targets: two);
      c.read(activePublishingProvider.notifier).begin('live', CancellationSignal());
      c.read(routerProvider).go('/activity');
      await settle(tester);
      expect(find.text(kGettingReady), findsOneWidget);
      expect(find.text('Posted to 0 of 2'), findsNothing);
      await close(tester);
    });

    /// Two journals over one store, as the UI isolate and a background isolate have.
    (PublishJournal, PublishJournal) sharedJournals() {
      Object? data;
      Future<Object?> read() async => data;
      Future<void> write(Object d) async => data = d;
      return (PublishJournal(read: read, write: write, owner: 'ui'), PublishJournal(read: read, write: write, owner: 'background'));
    }

    testWidgets('a run in a background isolate says so, with no number, in both places', (tester) async {
      final (ui, background) = sharedJournals();
      await tester.runAsync(() => background.record('live'));
      final (c, _, _) = await app(tester, targets: two, journal: ui);
      c.read(routerProvider).go('/activity');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
      expect(find.text(kPostingInBackground), findsOneWidget, reason: 'Activity');
      expect(find.text('Posted to 0 of 2'), findsNothing);
      expect(find.byType(PostProgressFigure), findsNothing);

      c.read(routerProvider).go('/activity/post/live');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
      expect(find.text(kPostingInBackground), findsOneWidget, reason: 'the post page');
      expect(find.byType(PostProgressFigure), findsNothing);
      await close(tester);
    });

    testWidgets('a post another device is publishing does not claim to be posting here', (tester) async {
      final (ui, _) = sharedJournals();
      final (c, _, _) = await app(tester, targets: two, journal: ui);
      c.read(routerProvider).go('/activity');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
      expect(find.text(kPostingInBackground), findsNothing);
      await close(tester);
    });
  });
}
