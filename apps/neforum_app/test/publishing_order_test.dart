// 1.4.3: the user's publishing order. It is a setting that survives a restart
// and travels with sync; every run follows it, the background one included,
// with hand-offs after the automatic accounts; new accounts go to the end; it is
// edited in the composer and in Settings > Posting, and Activity and the
// progress sheet list networks in it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/publishing_order.dart';
import 'package:neforum_app/state/scheduler.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/account_selection_grid.dart';
import 'package:neforum_app/ui/compose/publishing_order_sheet.dart';
import 'package:neforum_app/ui/compose/target_picker.dart';
import 'package:neforum_app/ui/settings/posting_section.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'sync_fixtures.dart';

ConnectedAccount _account(String id, {PlatformTier tier = PlatformTier.openApi, int day = 1}) =>
    fakeAccount(id, 'mastodon', tier: tier, createdAt: DateTime.utc(2026, 9, day));

/// Demo services on [storage], whose settings.json is read as the app reads it
/// at every start (and the background task at each of its runs).
Future<AppServices> _demo(MemoryAppStorage storage) => AppServices.create(demo: true, storage: storage);

/// Three automatic demo accounts (open API: no keys to ask about) and a hand-off
/// one, oldest first.
Future<({List<String> automatic, String handoff})> _demoAccounts(AppServices s) async {
  final all = await s.accounts.all();
  final automatic = [for (final a in all) if (a.enabled && a.tier == PlatformTier.openApi) a.id].take(3).toList();
  // YouTube posts take text alone; Instagram and TikTok need a picture.
  final handoff = all.firstWhere((a) => a.enabled && a.tier == PlatformTier.handoff && a.platformId == 'youtube_posts').id;
  return (automatic: automatic, handoff: handoff);
}

/// The app's own fonts: the header's widths are measured in them.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  group('the setting', () {
    test('keeps its order through JSON, starts empty, and drops what is not an id', () {
      expect(const AppSettings().publishingOrder, isEmpty);
      final s = const AppSettings().copyWith(publishingOrder: ['b', 'a', 'c']);
      expect(AppSettings.fromJson(s.toJson()).publishingOrder, ['b', 'a', 'c']);
      expect(AppSettings.fromJson({'publishingOrder': ['a', 3, null, 'b']}).publishingOrder, ['a', 'b']);
      expect(AppSettings.fromJson(const {}).publishingOrder, isEmpty, reason: 'settings saved before 1.4.3');
    });

    test('travels with sync and Move to another device', () {
      expect(kExportableSettings, contains('publishingOrder'));
      expect(kDeviceOnlySettings.keys, isNot(contains('publishingOrder')));
      expect(syncedSettings(populatedSettings())['publishingOrder'], ['acct-2', 'acct-1']);
      expect(syncedSettings(const AppSettings())['publishingOrder'], isEmpty, reason: 'put back to the default, it still travels');
    });

    test('survives a restart: saved to settings.json and read back by the next start', () async {
      final storage = MemoryAppStorage();
      final first = await _demo(storage);
      await first.saveSettings(first.settings.copyWith(publishingOrder: ['demo-bluesky', 'demo-mastodon']));
      first.dispose();
      final next = await _demo(storage);
      addTearDown(next.dispose);
      expect(next.settings.publishingOrder, ['demo-bluesky', 'demo-mastodon']);
      expect(next.publisher().publishingOrder!(), ['demo-bluesky', 'demo-mastodon'], reason: 'every run of the next start reads it');
    });

    test('an order changed on one device arrives on the other', () async {
      final folder = await syncFolderForTest(addTearDown);
      final a = SyncTestDevice(folder), b = SyncTestDevice(folder);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      for (final d in [a, b]) {
        await d.addAccount(fakeAccount('acct-1', 'mastodon'));
        await d.addAccount(fakeAccount('acct-2', 'bluesky'));
      }
      await a.syncOnce();
      await b.syncOnce();
      await a.syncOnce();

      a.settings = a.settings.copyWith(publishingOrder: ['acct-2', 'acct-1']);
      await a.syncOnce();
      await b.syncOnce();
      expect(b.settings.publishingOrder, ['acct-2', 'acct-1']);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('moving an account', () {
    final a = _account('a', day: 1), b = _account('b', day: 2), c = _account('c', day: 3);
    final h1 = _account('h1', tier: PlatformTier.handoff, day: 4), h2 = _account('h2', tier: PlatformTier.handoff, day: 5);

    test('down, up, and to either end, within its group', () {
      List<String> move(int from, int to, {bool handoffs = false}) =>
          publishingOrderAfterMove(automatic: [a, b, c], handoffs: [h1, h2], inHandoffs: handoffs, oldIndex: from, newIndex: to);
      expect(move(0, 1), ['b', 'a', 'c', 'h1', 'h2']);
      expect(move(2, 0), ['c', 'a', 'b', 'h1', 'h2']);
      expect(move(0, 2), ['b', 'c', 'a', 'h1', 'h2']);
      expect(move(1, 1), ['a', 'b', 'c', 'h1', 'h2']);
      expect(move(1, 0, handoffs: true), ['a', 'b', 'c', 'h2', 'h1'], reason: 'the automatic accounts keep their order');
    });

    test('lists every account, and keeps the ids this device does not know at the end', () {
      expect(
        publishingOrderAfterMove(automatic: [a, b], handoffs: [h1], inHandoffs: false, oldIndex: 1, newIndex: 0, previous: ['b', 'elsewhere', 'a']),
        ['b', 'a', 'h1', 'elsewhere'],
      );
    });

    test('the moved order is the one a run then takes, new accounts after it', () {
      final saved = publishingOrderAfterMove(automatic: [a, b, c], handoffs: [h1, h2], inHandoffs: false, oldIndex: 2, newIndex: 0);
      final added = _account('added', day: 9), addedHand = _account('addedhand', tier: PlatformTier.handoff, day: 10);
      final sequence = PublishingSequence(accounts: [a, b, c, h1, h2, added, addedHand], order: saved);
      expect(sequence.accounts.map((x) => x.id), ['c', 'a', 'b', 'added', 'h1', 'h2', 'addedhand']);
    });
  });

  group('Activity and the progress sheet', () {
    test('list a post\'s networks in the publishing order, hand-offs last', () {
      final sequence = PublishingSequence(
        accounts: [_account('a', day: 1), _account('b', day: 2), _account('h', tier: PlatformTier.handoff, day: 3)],
        order: const ['b', 'h', 'a'],
      );
      const targets = [PostTarget(accountId: 'h'), PostTarget(accountId: 'a'), PostTarget(accountId: 'gone'), PostTarget(accountId: 'b')];
      expect(sequence.targets(targets).map((t) => t.accountId), ['b', 'a', 'gone', 'h']);
      expect(sequence.accountIds(['h', 'a', 'b']), ['b', 'a', 'h']);
    });
  });

  group('runs', () {
    test('a background run of a scheduled post follows the order saved before the start, hand-offs last', () async {
      final storage = MemoryAppStorage();
      final setup = await _demo(storage);
      final ids = await _demoAccounts(setup);
      final saved = [ids.handoff, ...ids.automatic.reversed];
      // Kept, so the result can be read; no notification.
      await setup.saveSettings(setup.settings.copyWith(
        publishingOrder: saved,
        publishedPostRetention: PublishedPostRetention.retainIndefinitely,
        notifyOnPublish: false,
      ));
      setup.dispose();

      // The background task starts its own services from what is on disk.
      final worker = await _demo(storage);
      addTearDown(worker.dispose);
      final at = DateTime.now().subtract(const Duration(minutes: 1));
      await worker.posts.upsert(Post(
        id: 'ordered',
        text: 'In order',
        createdAt: at,
        updatedAt: at,
        status: PostStatus.scheduled,
        scheduledAt: at,
        // Selected in the order the accounts were connected.
        targets: [for (final id in [...ids.automatic, ids.handoff]) PostTarget(accountId: id)],
      ));

      await publishDueHeadless(worker);

      final done = (await worker.posts.get('ordered'))!;
      final posted = done.targets.where((t) => t.status == TargetStatus.published).toList()..sort((x, y) => x.lastAttemptAt!.compareTo(y.lastAttemptAt!));
      expect(posted.map((t) => t.accountId), ids.automatic.reversed, reason: 'the saved order, not the order they were chosen in');
      final hand = done.targetFor(ids.handoff)!;
      expect(hand.status, TargetStatus.awaitingHandoff, reason: 'listed first, and left for the user after every automatic account');
      expect(hand.result?.error, isNull);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('targetsInPublishingOrder of the app\'s publisher puts a new account last', () async {
      final s = await _demo(MemoryAppStorage());
      addTearDown(s.dispose);
      final ids = await _demoAccounts(s);
      await s.saveSettings(s.settings.copyWith(publishingOrder: [ids.automatic[2], ids.automatic[0]]));
      final post = Post(
        id: 'p',
        text: 't',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        targets: [for (final id in [ids.handoff, ...ids.automatic]) PostTarget(accountId: id)],
      );
      expect((await s.publisher().targetsInPublishingOrder(post)).map((t) => t.accountId), [ids.automatic[2], ids.automatic[0], ids.automatic[1], ids.handoff]);
    });
  });

  group('editing it', () {
    Future<(AppServices, ProviderContainer)> pump(WidgetTester tester, Widget child, {Size size = const Size(1200, 1600)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = (await tester.runAsync(() => _demo(MemoryAppStorage())))!;
      addTearDown(services.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(theme: buildTheme(Brightness.light, AccentChoice.neforum), home: Scaffold(body: child)),
      ));
      final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
      await tester.runAsync(() => c.read(accountsProvider.future));
      await tester.pump();
      return (services, c);
    }

    double rowTop(WidgetTester tester, String id) => tester.getTopLeft(find.byKey(PublishingOrderEditor.rowKey(id))).dy;

    testWidgets('Settings > Posting opens it; dragging an account moves it and saves the whole order', (tester) async {
      final (services, c) = await pump(tester, const SingleChildScrollView(child: PostingSettingsSection()));
      expect(find.byKey(kPublishingOrderRowKey), findsOneWidget);
      expect(find.textContaining(kPublishingOrderDescription), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Change order'));
      await tester.pumpAndSettle();
      expect(find.byType(PublishingOrderEditor), findsOneWidget);
      expect(find.text('Automatic'), findsOneWidget);

      final shown = c.read(publishingSequenceProvider).accounts.map((a) => a.id).toList();
      final [first, second, third] = shown.take(3).toList();
      expect(rowTop(tester, first), lessThan(rowTop(tester, second)));

      // Drag the first account below the second.
      final handle = find.descendant(of: find.byKey(PublishingOrderEditor.rowKey(first)), matching: find.byIcon(Icons.drag_indicator_rounded));
      final rowHeight = tester.getSize(find.byKey(PublishingOrderEditor.rowKey(first))).height;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 100));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(Offset(0, rowHeight * 1.5 / 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final order = c.read(settingsProvider).publishingOrder;
      expect(order.take(3), [second, first, third]);
      expect(order.toSet(), shown.toSet(), reason: 'every account is in the saved order');
      expect(services.settings.publishingOrder, order, reason: 'saved, so the next run and the next start have it');
      expect(rowTop(tester, second), lessThan(rowTop(tester, first)));

      // Back to the order the accounts were connected in.
      await tester.tap(find.byKey(PublishingOrderEditor.resetKey));
      await tester.pumpAndSettle();
      expect(c.read(settingsProvider).publishingOrder, isEmpty);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(PublishingOrderEditor), findsNothing);
    });

    testWidgets('the composer opens it from Post to, with the post\'s accounts marked', (tester) async {
      final (services, c) = await pump(tester, const SingleChildScrollView(child: TargetPicker()));
      final ids = (await tester.runAsync(() => _demoAccounts(services)))!;
      c.read(composerProvider.notifier).selectAccounts([ids.automatic.first]);
      await tester.pump();

      await tester.tap(find.byKey(TargetPicker.publishingOrderKey));
      await tester.pumpAndSettle();
      expect(find.byType(PublishingOrderEditor), findsOneWidget);
      final marked = find.descendant(of: find.byKey(PublishingOrderEditor.rowKey(ids.automatic.first)), matching: find.byIcon(Icons.check_circle_rounded));
      expect(marked, findsOneWidget);
      expect(find.descendant(of: find.byType(PublishingOrderEditor), matching: find.byIcon(Icons.check_circle_rounded)), findsOneWidget);
    });

    testWidgets('a phone has it under the post, and the account grid\'s header stays as it was', (tester) async {
      final (services, c) = await pump(
        tester,
        const SingleChildScrollView(child: Column(children: [TargetPicker(grid: true, availableHeight: 560), PublishingOrderLink()])),
        size: const Size(360, 640),
      );
      final ids = (await tester.runAsync(() => _demoAccounts(services)))!;
      c.read(composerProvider.notifier).selectAccounts([ids.automatic[1]]);
      await tester.pump();
      expect(find.byKey(TargetPicker.publishingOrderKey), findsNothing, reason: 'the grid header keeps its room for the accounts');
      final link = find.byKey(PublishingOrderLink.linkKey);
      expect(tester.getSize(link).height, greaterThanOrEqualTo(kAccountCellMinHeight), reason: 'a whole touch target');

      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget, reason: 'a sheet on a phone');
      expect(find.byKey(PublishingOrderEditor.rowKey(ids.automatic[1])), findsOneWidget);
      expect(find.descendant(of: find.byKey(PublishingOrderEditor.rowKey(ids.automatic[1])), matching: find.byIcon(Icons.check_circle_rounded)), findsOneWidget);
    });

    testWidgets('screen readers move an account with Move down', (tester) async {
      final handle = tester.ensureSemantics();
      final (_, c) = await pump(tester, const PublishingOrderEditor());
      final shown = c.read(publishingSequenceProvider).accounts.map((a) => a.id).toList();
      final semantics = tester.getSemantics(find.descendant(of: find.byKey(PublishingOrderEditor.rowKey(shown.first)), matching: find.byType(Semantics)).first);
      final down = semantics.getSemanticsData().customSemanticsActionIds!
          .map(CustomSemanticsAction.getAction)
          .firstWhere((a) => a?.label == 'Move down');
      semantics.owner!.performAction(semantics.id, SemanticsAction.customAction, CustomSemanticsAction.getIdentifier(down!));
      await tester.pumpAndSettle();
      expect(c.read(settingsProvider).publishingOrder.take(2), [shown[1], shown[0]]);
      handle.dispose();
    });
  });
}
