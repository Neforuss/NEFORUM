// The schedule sheet: a random time, what Confirm and Cancel do, the exact
// instant kept through a reopen, clock changes, and a time gone stale. The real
// composer screen on a phone-sized window, with a fixed clock and a seeded draw.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/account_connection.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/compose/action_bar.dart';
import 'package:neforum_app/ui/compose/schedule_notes.dart';
import 'package:neforum_app/ui/compose/schedule_sheet.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/widgets/buttons.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// Always the first minute of the range.
class _FirstMinute implements Random {
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
}

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
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF777777)));
}

/// The app's own fonts, for layouts sized for them: the test font's square
/// letters are twice as wide as real ones, which overflows the header of
/// Flutter's date range picker and the composer's action bar.
Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.view(File('assets/fonts/$f').readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Inter', ['Inter-Regular.ttf', 'Inter-Medium.ttf', 'Inter-SemiBold.ttf', 'Inter-Bold.ttf']);
  await family('Bricolage', ['BricolageGrotesque-SemiBold.ttf', 'BricolageGrotesque-Bold.ttf']);
}

/// A zone whose clocks go back an hour 30 minutes after [first], so [first] has
/// a twin an hour on. A table, not this machine's zone: on a machine with its
/// own change near that date, the two would cancel out.
LocalZone _fallsBackAfter(DateTime first) => LocalZone(wallClockOf: (ms) {
      final change = first.millisecondsSinceEpoch + const Duration(minutes: 30).inMilliseconds;
      return DateTime.fromMillisecondsSinceEpoch(ms < change ? ms : ms - const Duration(hours: 1).inMilliseconds, isUtc: true);
    });

const _seed = 20261106;
const _phone = Size(360, 640);

/// A time far enough from today that a test never meets the real clock.
final DateTime _start = DateTime(2030, 3, 1, 12, 7);

class _Harness {
  _Harness(this.services, this.container);
  final AppServices services;
  final ProviderContainer container;
  DateTime now = _start;

  ComposerState get composer => container.read(composerProvider);
  ComposerNotifier get notifier => container.read(composerProvider.notifier);
  List<ConnectedAccount> get accounts => container.read(accountListProvider);

  /// A connected account that stays on the device: no platform of its own holds posts.
  ConnectedAccount get onDevice => accounts.firstWhere((a) => a.tier.isAutomatic && a.platformId == 'bluesky');
  ConnectedAccount get second => accounts.firstWhere((a) => a.tier.isAutomatic && a.platformId != 'bluesky');
}

void main() {
  Future<_Harness> boot(
    WidgetTester tester, {
    Size size = _phone,
    LocalZone zone = const LocalZone(),
    ScheduleDevice device = ScheduleDevice.desktop,
    double textScale = 1,
    Random? random,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    late _Harness harness;
    await tester.pumpWidget(ProviderScope(overrides: [
      servicesProvider.overrideWithValue(services),
      scheduleClockProvider.overrideWithValue(() => harness.now),
      scheduleSheetEnvironmentProvider.overrideWithValue(ScheduleSheetEnvironment(clock: () => harness.now, random: random ?? Random(_seed), zone: zone, device: device)),
    ], child: const NeforumApp()));
    harness = _Harness(services, ProviderScope.containerOf(tester.element(find.byType(MaterialApp))));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    return harness;
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  /// Opens the sheet the way the composer's button does.
  Future<void> openSheet(WidgetTester tester, _Harness h) async {
    final bar = find.byType(ComposerActionBar);
    // A chip once a time is set, else an icon on a phone or a labelled button on
    // a wide window. Once a time is set, "Schedule" is the button that posts.
    final chip = find.descendant(of: bar, matching: find.byType(InputChip));
    final icon = find.descendant(of: bar, matching: find.byTooltip('Schedule'));
    await tester.tap(chip.evaluate().isNotEmpty
        ? chip
        : icon.evaluate().isNotEmpty
            ? icon
            : find.descendant(of: bar, matching: find.text('Schedule')));
    await tester.pumpAndSettle();
    expect(find.text('Schedule post'), findsOneWidget);
  }

  Future<void> openRandom(WidgetTester tester) async {
    final card = find.text('Pick a random time');
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pumpAndSettle();
  }

  Future<void> scheduleButton(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Schedule'));
    await tester.pumpAndSettle();
  }

  String shown(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('random-time'))).data!;

  void compose(_Harness h, {List<ConnectedAccount>? targets}) {
    h.notifier
      ..selectAccounts([for (final a in targets ?? [h.onDevice]) a.id])
      ..setText('Hello');
  }

  group('a random time', () {
    testWidgets('nothing is scheduled by opening, drawing or re-rolling; Cancel leaves the composer as it was', (tester) async {
      final h = await boot(tester);
      compose(h);
      await tester.pump();
      final before = h.composer;
      await openSheet(tester, h);
      await openRandom(tester);
      expect(identical(h.composer, before), isTrue);
      final seen = <String>{shown(tester)};
      for (var i = 0; i < 25; i++) {
        final retry = find.text('Try another');
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        await tester.pump();
        seen.add(shown(tester));
        expect(identical(h.composer, before), isTrue, reason: 'draw $i');
      }
      expect(seen.length, greaterThan(20), reason: 're-rolling really draws again');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Schedule post'), findsNothing);
      expect(identical(h.composer, before), isTrue);
      expect(h.composer.scheduledAt, isNull);
      expect(await tester.runAsync(() => h.services.posts.all()), isNot(contains(predicate<Post>((p) => p.text == 'Hello'))));
      await done(tester);
    });

    testWidgets('Choose a date goes back to what was picked before and drops the draw', (tester) async {
      final h = await boot(tester);
      compose(h);
      await tester.pump();
      h.notifier.setSchedule(DateTime(2030, 3, 5, 10));
      await tester.pump();
      await openSheet(tester, h);
      await openRandom(tester);
      await tester.tap(find.text('Choose a date'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('random-time')), findsNothing);
      await scheduleButton(tester);
      expect(h.composer.scheduledAt, DateTime(2030, 3, 5, 10));
      await done(tester);
    });

    testWidgets('Confirm stores the exact draw, the same one the seed gives, and reopening keeps it', (tester) async {
      final h = await boot(tester);
      compose(h);
      await tester.pump();
      await openSheet(tester, h);
      await openRandom(tester);
      final expected = randomMoment(randomScheduleRange(const Duration(days: 7), _start), Random(_seed))!;
      await scheduleButton(tester);
      expect(h.composer.scheduledAt, expected);
      expect(h.composer.scheduledAt!.millisecondsSinceEpoch % 60000, 0);
      // The composer's own Schedule still has to be pressed.
      expect(await tester.runAsync(() => h.services.posts.all()), isNot(contains(predicate<Post>((p) => p.text == 'Hello'))));
      // Reopened and confirmed unchanged: the same instant.
      await openSheet(tester, h);
      await scheduleButton(tester);
      expect(h.composer.scheduledAt, expected);
      await done(tester);
    });

    testWidgets('a range is stated in words and every preset draws inside it', (tester) async {
      await tester.runAsync(_loadFonts);
      final h = await boot(tester, size: const Size(1700, 1000));
      compose(h);
      await tester.pump();
      await openSheet(tester, h);
      await openRandom(tester);
      const spans = {'Next 24 hours': Duration(hours: 24), 'Next 7 days': Duration(days: 7), 'Next 30 days': Duration(days: 30), 'Next 90 days': Duration(days: 90), 'Next 365 days': Duration(days: 365)};
      expect(find.textContaining('Every minute is equally likely.'), findsOneWidget);
      expect(find.textContaining('Any minute from Fri, Mar 1, 2030, 12:22 PM'), findsOneWidget);
      for (final e in spans.entries) {
        await tester.tap(find.widgetWithText(ChoiceChip, e.key));
        await tester.pumpAndSettle();
        expect(find.textContaining('Any minute from'), findsOneWidget);
        // Primary label on a wide window: "Schedule for ...".
        await tester.tap(find.descendant(of: find.byType(ScheduleSheet), matching: find.byType(FilledButton)));
        await tester.pumpAndSettle();
        final at = h.composer.scheduledAt!;
        expect(at.difference(_start) >= kRandomScheduleMinLead, isTrue, reason: e.key);
        expect(at.difference(_start) < e.value, isTrue, reason: e.key);
        await openSheet(tester, h);
        await openRandom(tester);
      }
      await done(tester);
    });

    testWidgets('Custom asks for the days and keeps the draw inside them; backing out changes nothing', (tester) async {
      await tester.runAsync(_loadFonts);
      final h = await boot(tester);
      compose(h);
      await tester.pump();
      await openSheet(tester, h);
      await openRandom(tester);
      final chip = find.widgetWithText(ChoiceChip, 'Custom');
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.text('Pick a range'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Next 7 days')).selected, isTrue);

      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      await tester.tap(find.text('10').first);
      await tester.pump();
      await tester.tap(find.text('12').first);
      await tester.pump();
      await tester.tap(find.text('Use this range'));
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
      await scheduleButton(tester);
      final at = h.composer.scheduledAt!;
      expect(!at.isBefore(DateTime(2030, 3, 10)) && at.isBefore(DateTime(2030, 3, 13)), isTrue, reason: '$at');
      await done(tester);
    });

    testWidgets('a different time per network: one draw each, each with its own re-roll, written only at Confirm', (tester) async {
      final h = await boot(tester);
      final a = h.onDevice, b = h.second;
      compose(h, targets: [a, b]);
      await tester.pump();
      final before = h.composer;
      await openSheet(tester, h);
      await openRandom(tester);
      await tester.tap(find.text('Different time per network'));
      await tester.pumpAndSettle();
      expect(identical(h.composer, before), isTrue);
      String time(ConnectedAccount x) => tester.widget<Text>(find.byKey(ValueKey('random-time-${x.id}'))).data!;
      final a1 = time(a), b1 = time(b);
      final reroll = find.byTooltip('Another time for Bluesky');
      await tester.ensureVisible(reroll);
      await tester.tap(reroll);
      await tester.pump();
      expect(time(a), isNot(a1));
      expect(time(b), b1, reason: 'the other row stays');
      expect(identical(h.composer, before), isTrue);
      await scheduleButton(tester);
      final c = h.composer;
      expect(c.schedulesEachTarget, isTrue);
      final at = c.overrides[a.id]!.scheduledAt!, bt = c.overrides[b.id]!.scheduledAt!;
      expect(at, isNot(bt));
      expect(c.scheduledAt, at.isBefore(bt) ? at : bt);
      await done(tester);
    });

    testWidgets('a network that already went gets no draw and keeps its time', (tester) async {
      final h = await boot(tester);
      final a = h.onDevice, b = h.second;
      final past = _start.subtract(const Duration(hours: 1));
      final later = _start.add(const Duration(hours: 3));
      final saved = Post(
        id: 'partly',
        text: 'Hello',
        createdAt: past,
        updatedAt: past,
        scheduledAt: later,
        status: PostStatus.scheduled,
        targets: [
          PostTarget(accountId: a.id, overrides: PostOverrides(scheduledAt: past), status: TargetStatus.published, result: PublishResult.ok(remoteId: 'live')),
          PostTarget(accountId: b.id, overrides: PostOverrides(scheduledAt: later)),
        ],
      );
      await tester.runAsync(() => h.services.posts.upsert(saved));
      h.notifier.load(saved);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      await openSheet(tester, h);
      await openRandom(tester);
      expect(find.byKey(ValueKey('random-time-${a.id}')), findsNothing);
      expect(find.byKey(ValueKey('random-time-${b.id}')), findsOneWidget);
      await scheduleButton(tester);
      final c = h.composer;
      expect(c.overrides[a.id]!.scheduledAt, past, reason: 'its own time');
      final drawn = c.overrides[b.id]!.scheduledAt!;
      expect(drawn.isAfter(_start), isTrue);
      expect(drawn, isNot(later));
      expect(c.scheduledAt, drawn, reason: 'the next one still to go, not the one already past');
      await done(tester);
    });

    testWidgets('a draw on the second 1:30 is kept: Confirm, the saved form and a reopen all give that instant', (tester) async {
      // The second 1:30 AM of a US autumn change, on a machine in that zone. Elsewhere still one exact instant.
      final second = DateTime.utc(2030, 11, 3, 9, 30).toLocal();
      final h = await boot(tester, random: _FirstMinute());
      h.now = second.subtract(kRandomScheduleMinLead);
      compose(h);
      await tester.pump();
      await openSheet(tester, h);
      await openRandom(tester);
      await scheduleButton(tester);
      expect(h.composer.scheduledAt, second);
      final stored = h.composer.toPost(id: 'p', status: PostStatus.scheduled, now: h.now);
      expect(Post.fromJson(stored.toJson()).scheduledAt, second);
      await openSheet(tester, h);
      await scheduleButton(tester);
      expect(h.composer.scheduledAt, second);
      await done(tester);
    });

    testWidgets('a time gone stale while the sheet stayed open is refused, and a new draw fixes it', (tester) async {
      final h = await boot(tester);
      compose(h);
      await tester.pump();
      await openSheet(tester, h);
      await openRandom(tester);
      h.now = _start.add(const Duration(days: 30));
      await scheduleButton(tester);
      expect(find.text('Schedule post'), findsOneWidget, reason: 'still open');
      expect(find.textContaining('too close now'), findsOneWidget);
      expect(h.composer.scheduledAt, isNull);
      final retry = find.text('Try another');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pump();
      await scheduleButton(tester);
      expect(h.composer.scheduledAt!.isAfter(h.now), isTrue);
      await done(tester);
    });
  });

  group('warnings in the sheet', () {
    testWidgets('a sign-in that ends before the draw says so, from the status file', (tester) async {
      final h = await boot(tester);
      compose(h);
      await tester.pump();
      final end = _start.add(const Duration(minutes: 16));
      await tester.runAsync(() async {
        await h.services.signInStatusStore.change(
            h.onDevice.id, (_) => SignInStatus(accountId: h.onDevice.id, limit: SignInLimit.date, source: SignInDateSource.serverReported, renewsItself: false, state: SignInState.endsOn, expiresAt: end));
      });
      await tester.pump();
      await openSheet(tester, h);
      await openRandom(tester);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(find.textContaining("sign-in ends"), findsOneWidget);
      await done(tester);
    });

    testWidgets('a hand-off drawn at night says it needs a tap', (tester) async {
      final h = await boot(tester);
      final handoff = h.accounts.firstWhere((a) => a.tier == PlatformTier.handoff);
      compose(h, targets: [handoff]);
      await tester.pump();
      h.notifier.setSchedule(DateTime(2030, 3, 5, 3, 12));
      await tester.pump();
      await openSheet(tester, h);
      expect(find.textContaining('this lands at 3:12 AM and needs you to tap'), findsOneWidget);
      await done(tester);
    });

    testWidgets('the tray is not promised when Settings has closing the window quit NEFORUM', (tester) async {
      final h = await boot(tester);
      compose(h);
      await tester.pump();
      h.container.read(settingsProvider.notifier).update((s) => s.copyWith(minimizeToTray: false));
      await tester.pump();
      await openSheet(tester, h);
      expect(find.textContaining('window open'), findsOneWidget);
      expect(find.textContaining('stays in the tray'), findsNothing);
      await done(tester);
    });

    testWidgets('warnings never block Schedule', (tester) async {
      final h = await boot(tester);
      compose(h);
      await tester.pump();
      h.notifier.setSchedule(DateTime(2030, 9, 5, 3, 12));
      await tester.pump();
      await openSheet(tester, h);
      expect(find.textContaining('more than 30 days'), findsOneWidget);
      await scheduleButton(tester);
      expect(h.composer.scheduledAt, DateTime(2030, 9, 5, 3, 12));
      await done(tester);
    });
  });

  group('the exact instant', () {
    testWidgets('a time the wall clock cannot name again survives reopening and confirming unchanged (bug 3)', (tester) async {
      // A zone in which recomposing a wall clock lands an hour off, as the first
      // 1:30 does for a post at the second 1:30.
      final zone = LocalZone(momentOf: (y, mo, d, h, mi) => DateTime(y, mo, d, h, mi).subtract(const Duration(hours: 1)));
      final h = await boot(tester, zone: zone);
      compose(h);
      await tester.pump();
      final second = DateTime.utc(2030, 11, 3, 9, 30).toLocal();
      h.notifier.setSchedule(second);
      await tester.pump();
      await openSheet(tester, h);
      await scheduleButton(tester);
      expect(h.composer.scheduledAt, second);
      await done(tester);
    });

    testWidgets('one network left: the time just picked wins over a saved time per network', (tester) async {
      final h = await boot(tester);
      final a = h.onDevice, b = h.second;
      compose(h, targets: [a, b]);
      await tester.pump();
      h.notifier.setTargetSchedules({a.id: DateTime(2030, 3, 5, 10), b.id: DateTime(2030, 3, 6, 10)});
      h.notifier.selectAccounts([a.id]);
      await tester.pump();
      await openSheet(tester, h);
      final day = find.text('9');
      await tester.ensureVisible(day.first);
      await tester.tap(day.first);
      await tester.pumpAndSettle();
      await scheduleButton(tester);
      expect(h.composer.scheduledAt, DateTime(2030, 3, 9, 10));
      expect(h.composer.overrides[a.id]?.scheduledAt, isNull);
      await done(tester);
    });

    testWidgets('editing the day stops keeping the old instant', (tester) async {
      final h = await boot(tester);
      compose(h);
      await tester.pump();
      h.notifier.setSchedule(DateTime(2030, 3, 5, 10, 17));
      await tester.pump();
      await openSheet(tester, h);
      final day = find.text('9');
      await tester.ensureVisible(day.first);
      await tester.tap(day.first);
      await tester.pumpAndSettle();
      await scheduleButton(tester);
      expect(h.composer.scheduledAt, DateTime(2030, 3, 9, 10, 17));
      await done(tester);
    });

    testWidgets('a stale time or one past the limit opens without breaking the calendar', (tester) async {
      final h = await boot(tester);
      compose(h);
      await tester.pump();
      for (final at in [_start.subtract(const Duration(days: 300)), _start.add(const Duration(days: 500)), _start.add(kScheduleHorizon).subtract(const Duration(minutes: 1))]) {
        h.notifier.setSchedule(at);
        await tester.pump();
        await openSheet(tester, h);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      await done(tester);
    });

    testWidgets('a time the clocks skip shows the real time and says so (bug 4)', (tester) async {
      // Hour 2 does not exist: this zone resolves it to hour 3, as Windows does.
      final zone = LocalZone(momentOf: (y, mo, d, h, mi) => DateTime(y, mo, d, h == 2 ? 3 : h, mi));
      final h = await boot(tester, zone: zone);
      compose(h);
      await tester.pump();
      h.notifier.setSchedule(DateTime(2030, 3, 10, 1, 15));
      await tester.pump();
      await openSheet(tester, h);
      final time = find.text('1:15 AM');
      await tester.ensureVisible(time);
      await tester.tap(time);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Switch to text input mode'));
      await tester.pumpAndSettle();
      final fields = find.descendant(of: find.byType(TimePickerDialog), matching: find.byType(TextField));
      await tester.enterText(fields.at(0), '2');
      await tester.enterText(fields.at(1), '30');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('3:30 AM'), findsOneWidget, reason: 'the Time button shows the real time');
      expect(find.textContaining('does not exist on Mar 10'), findsOneWidget);
      expect(find.textContaining('This post goes at 3:30 AM'), findsOneWidget);
      await scheduleButton(tester);
      expect(h.composer.scheduledAt, DateTime(2030, 3, 10, 3, 30));
      await done(tester);
    });

    testWidgets('a wall clock that happens twice says which one this is', (tester) async {
      final first = DateTime(2030, 3, 5, 1, 30);
      final h = await boot(tester, zone: _fallsBackAfter(first));
      compose(h);
      await tester.pump();
      h.notifier.setSchedule(first);
      await tester.pump();
      await openSheet(tester, h);
      expect(find.textContaining('This time happens twice that day. This is the one in'), findsOneWidget);
      await done(tester);
    });
  });

  group('a wall clock that happens twice, one row per network', () {
    final first = DateTime(2030, 3, 5, 1, 30);
    final twin = _fallsBackAfter(first);

    testWidgets('a draw names its zone', (tester) async {
      final h = await boot(tester, zone: twin, random: _FirstMinute());
      h.now = first.subtract(kRandomScheduleMinLead);
      compose(h, targets: [h.onDevice, h.second]);
      await tester.pump();
      await openSheet(tester, h);
      await openRandom(tester);
      await tester.tap(find.text('Different time per network'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(ValueKey('random-time-${h.onDevice.id}'))).data, endsWith('(${first.timeZoneName})'));
      await done(tester);
    });

    testWidgets('a time set by hand names its zone, and only that row', (tester) async {
      final h = await boot(tester, zone: twin);
      h.now = first.subtract(const Duration(hours: 2));
      final a = h.onDevice, b = h.second;
      compose(h, targets: [a, b]);
      await tester.pump();
      h.notifier.setTargetSchedules({a.id: first, b.id: first.add(const Duration(days: 3))});
      await tester.pump();
      await openSheet(tester, h);
      expect(find.textContaining('(${first.timeZoneName})'), findsOneWidget);
      await done(tester);
    });
  });

  group('quick picks on the calendar (bug 2)', () {
    (String, DateTime) pick(List<(String, DateTime)> picks, String name) => picks.firstWhere((p) => p.$1 == name);

    test('tomorrow is the next calendar day at 9, across both clock changes', () {
      final spring = pick(scheduleQuickPicks(DateTime(2027, 3, 13, 23, 30)), 'Tomorrow morning').$2;
      expect((spring.month, spring.day, spring.hour), (3, 14, 9));
      final autumn = pick(scheduleQuickPicks(DateTime(2027, 11, 7, 0, 30)), 'Tomorrow morning').$2;
      expect((autumn.month, autumn.day, autumn.hour), (11, 8, 9));
      final monthEnd = pick(scheduleQuickPicks(DateTime(2028, 2, 28, 22)), 'Tomorrow morning').$2;
      expect((monthEnd.month, monthEnd.day), (2, 29));
    });

    test('next Monday is a Monday at 9, never today, across a clock change', () {
      for (final now in [DateTime(2027, 3, 8, 8), DateTime(2027, 3, 13, 23, 30), DateTime(2027, 11, 1, 8), DateTime(2027, 11, 6, 23, 30)]) {
        final monday = pick(scheduleQuickPicks(now), 'Next Monday').$2;
        expect(monday.weekday, DateTime.monday, reason: '$now');
        expect(monday.hour, 9, reason: '$now');
        expect(monday.isAfter(now), isTrue);
        expect(monday.difference(now).inDays, lessThanOrEqualTo(7));
      }
    });

    test('rounding up keeps the instant moving forward, by elapsed time', () {
      for (final t in [DateTime(2030, 1, 1, 10), DateTime(2030, 1, 1, 10, 1), DateTime(2030, 1, 1, 10, 14, 59), DateTime(2030, 1, 1, 10, 46, 1, 5), DateTime.utc(2027, 11, 7, 9, 10).toLocal()]) {
        final up = roundUpToQuarter(t);
        expect(up.isBefore(t), isFalse);
        expect(up.difference(t) < const Duration(minutes: 15), isTrue);
        expect(up.minute % 15 == 0 && up.second == 0 && up.millisecond == 0, isTrue, reason: '$t gives $up');
      }
      expect(roundUpToQuarter(DateTime(2030, 1, 1, 10, 30)), DateTime(2030, 1, 1, 10, 30));
    });
  });

  group('a time in the past is refused at Schedule (bug 5)', () {
    testWidgets('the composer button does not publish a stale schedule', (tester) async {
      final h = await boot(tester);
      compose(h);
      await tester.pump();
      final stale = _start.subtract(const Duration(days: 2));
      h.notifier.setSchedule(stale);
      await tester.pump();
      final before = (await tester.runAsync(() => h.services.posts.all()))!.length;
      await tester.tap(find.descendant(of: find.byType(ComposerActionBar), matching: find.byType(PrimaryAction)));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 100));
      final posts = (await tester.runAsync(() => h.services.posts.all()))!;
      expect(posts.length, before, reason: 'nothing saved to go out');
      expect(h.composer.text, 'Hello', reason: 'the post is still being written');
      expect(h.composer.scheduledAt, stale);
      expect(find.textContaining('That time has passed'), findsOneWidget);
      await done(tester);
    });

    testWidgets('schedule() itself refuses, for the post time and for one network\'s time', (tester) async {
      final h = await boot(tester);
      final a = h.onDevice, b = h.second;
      compose(h, targets: [a, b]);
      final actions = h.container.read(postActionsProvider);
      final soon = _start.add(const Duration(seconds: 20));
      final later = _start.add(const Duration(hours: 2));
      h.notifier.setSchedule(soon);
      Future<Object?> attempt() async {
        try {
          await actions.schedule();
          return null;
        } on Object catch (e) {
          return e;
        }
      }

      expect(await tester.runAsync(attempt), isA<SchedulePassedException>(), reason: 'under a minute ahead');
      h.notifier.setTargetSchedules({a.id: _start.subtract(const Duration(hours: 1)), b.id: later});
      expect(await tester.runAsync(attempt), isA<SchedulePassedException>(), reason: 'one network in the past');
      await done(tester);
    });

    testWidgets('a network that already went does not count: its time is its own past', (tester) async {
      final h = await boot(tester);
      final a = h.onDevice, b = h.second;
      final past = _start.subtract(const Duration(hours: 1));
      final later = _start.add(const Duration(hours: 3));
      final saved = Post(
        id: 'partly',
        text: 'Hello',
        createdAt: past,
        updatedAt: past,
        scheduledAt: later,
        status: PostStatus.scheduled,
        targets: [
          PostTarget(accountId: a.id, overrides: PostOverrides(scheduledAt: past), status: TargetStatus.published, result: PublishResult.ok(remoteId: 'live')),
          PostTarget(accountId: b.id, overrides: PostOverrides(scheduledAt: later)),
        ],
      );
      await tester.runAsync(() => h.services.posts.upsert(saved));
      h.notifier.load(saved);
      final p = (await tester.runAsync(() => h.container.read(postActionsProvider).schedule()))!;
      expect(p.targetFor(a.id)!.status, TargetStatus.published);
      expect(p.scheduledAt, later);
      await tester.runAsync(() => h.container.read(postActionsProvider).settle());
      await done(tester);
    });

    testWidgets('the sheet will not confirm a past time: the button says why', (tester) async {
      final h = await boot(tester);
      compose(h);
      await tester.pump();
      h.notifier.setSchedule(_start.subtract(const Duration(days: 1)));
      await tester.pump();
      await openSheet(tester, h);
      final button = find.widgetWithText(FilledButton, 'Pick a future time');
      expect(button, findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await done(tester);
    });
  });

  group('no overflow at 360 x 640', () {
    for (final scale in [1.0, 1.5]) {
      testWidgets('every state of the sheet at text scale $scale', (tester) async {
        final h = await boot(tester, textScale: scale);
        compose(h, targets: [h.onDevice, h.second]);
        await tester.pump();
        h.notifier.setSchedule(_start.add(const Duration(days: 40)));
        await tester.pump();
        await openSheet(tester, h);
        expect(tester.takeException(), isNull, reason: 'manual, with Remove schedule');
        await openRandom(tester);
        expect(tester.takeException(), isNull, reason: 'random panel');
        final chip = find.widgetWithText(ChoiceChip, 'Next 365 days');
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'a long range');
        await tester.ensureVisible(find.text('Different time per network'));
        await tester.tap(find.text('Different time per network'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'random, one per network');
        await tester.ensureVisible(find.text('Choose a date'));
        await tester.tap(find.text('Choose a date'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'one row per network');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await done(tester);
      });
    }

    testWidgets('every tap target in the random panel is at least 48 high', (tester) async {
      final h = await boot(tester);
      compose(h, targets: [h.onDevice, h.second]);
      await tester.pump();
      await openSheet(tester, h);
      await openRandom(tester);
      await tester.tap(find.text('Different time per network'));
      await tester.pumpAndSettle();
      final reroll = find.byTooltip('Another time for Bluesky');
      expect(tester.getSize(reroll).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(reroll).width, greaterThanOrEqualTo(48));
      await done(tester);
    });
  });
}
