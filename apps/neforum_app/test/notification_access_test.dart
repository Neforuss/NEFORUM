// D8 and D9: what the OS says about notifications, the one explanation on
// first launch, the quiet line, and the reminder that stays.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/notification_access.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/platform/update_check.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/notification_state.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/publish_result_notices.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/ui/compose/publish_progress_sheet.dart';
import 'package:neforum_app/ui/compose/schedule_sheet.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/ui/settings/notifications_section.dart';
import 'package:neforum_app/ui/shell/notification_prompt.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  _MemoryStorage([Map<String, Object> settings = const {}]) {
    json['settings.json'] = <String, dynamic>{'updateCheck': 'off', 'themeMode': 'light', ...settings};
  }
  final Map<String, Object> json = {};

  /// Posts, accounts and the journal are files: a folder of this test's own.
  final String _dir = Directory.systemTemp.createTempSync('neforum-u2n-').path;
  @override
  String? get dataDir => _dir;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}

class _FakeOs implements NotificationAccessPlatform {
  _FakeOs(this.facts);
  NotificationFacts facts;
  int requests = 0;
  int settings = 0;
  int channelSettings = 0;

  /// What the OS says after its prompt.
  NotificationFacts? afterRequest;

  @override
  Future<NotificationFacts> read() async => facts;
  @override
  Future<bool> request() async {
    requests++;
    if (afterRequest != null) facts = afterRequest!;
    final f = facts;
    return f is AndroidNotificationFacts ? f.enabled : (f is DarwinNotificationFacts && f.status == 'authorized');
  }

  @override
  Future<void> openSettings() async => settings++;
  @override
  Future<void> openResultsChannelSettings() async => channelSettings++;
}

const _androidNew = AndroidNotificationFacts(sdkInt: 35, enabled: false, rationale: false);
const _androidOn = AndroidNotificationFacts(sdkInt: 35, enabled: true, rationale: false);
const _iosNew = DarwinNotificationFacts('notDetermined');
const _explanation = 'Know how your post went';

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

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The real app on a real workspace, its storage in memory.
Future<(ProviderContainer, AppServices)> _pumpApp(
  WidgetTester tester,
  _FakeOs os, {
  _MemoryStorage? storage,
  bool demo = false,
  TargetPlatform platform = TargetPlatform.android,
  Size size = const Size(360, 640),
  List<Override> overrides = const [],
}) async {
  NotificationAccessPlatform.instance = os;
  debugDefaultTargetPlatformOverride = platform;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = (await tester.runAsync(() => AppServices.create(demo: demo, storage: storage ?? _MemoryStorage())))!;
  await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services), ...overrides], child: const NeforumApp()));
  await _settle(tester);
  return (ProviderScope.containerOf(tester.element(find.byType(MaterialApp))), services);
}

/// Leaves no scheduler timer behind and puts the platform back. The override
/// must be gone before the test framework checks its invariants.
Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);
  // An empty keychain for the real workspace.
  setUp(() {
    final keychain = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? const {};
        final key = args['key'] as String?;
        switch (call.method) {
          case 'read':
            return keychain[key];
          case 'write':
            keychain[key!] = args['value'] as String;
            return null;
          case 'delete':
            keychain.remove(key);
            return null;
          case 'readAll':
            return Map<String, String>.from(keychain);
          case 'containsKey':
            return keychain.containsKey(key);
        }
        return null;
      },
    );
  });
  final original = NotificationAccessPlatform.instance;
  tearDown(() {
    NotificationAccessPlatform.instance = original;
    debugDefaultTargetPlatformOverride = null;
  });

  group('the state table', () {
    NotificationAccess android(int sdk, {required bool enabled, bool rationale = false, bool asked = false}) =>
        notificationAccessFrom(AndroidNotificationFacts(sdkInt: sdk, enabled: enabled, rationale: rationale), askedBefore: asked);
    NotificationAccess darwin(String status) => notificationAccessFrom(DarwinNotificationFacts(status), askedBefore: false);

    final rows = <(String, NotificationAccess, NotificationAccess, NotificationAccessAction)>[
      ('Android 12 on', android(32, enabled: true), NotificationAccess.granted, NotificationAccessAction.none),
      ('Android 12 off', android(32, enabled: false), NotificationAccess.blocked, NotificationAccessAction.openSettings),
      ('Android 12 off, rationale means nothing there', android(32, enabled: false, rationale: true), NotificationAccess.blocked, NotificationAccessAction.openSettings),
      ('Android 13 on', android(33, enabled: true), NotificationAccess.granted, NotificationAccessAction.none),
      ('Android 13 never asked', android(33, enabled: false), NotificationAccess.notAsked, NotificationAccessAction.explainThenAsk),
      ('Android 13 refused once', android(33, enabled: false, rationale: true, asked: true), NotificationAccess.canAskAgain, NotificationAccessAction.explainThenAsk),
      ('Android 13 asked, no rationale', android(33, enabled: false, asked: true), NotificationAccess.askedUnclear, NotificationAccessAction.tryAsk),
      ('iOS not asked', darwin('notDetermined'), NotificationAccess.notAsked, NotificationAccessAction.explainThenAsk),
      ('iOS authorized', darwin('authorized'), NotificationAccess.granted, NotificationAccessAction.none),
      ('iOS ephemeral', darwin('ephemeral'), NotificationAccess.granted, NotificationAccessAction.none),
      ('iOS provisional', darwin('provisional'), NotificationAccess.quiet, NotificationAccessAction.explainThenAsk),
      ('iOS denied', darwin('denied'), NotificationAccess.blocked, NotificationAccessAction.openSettings),
      ('a status newer than this build never prompts', darwin('somethingNew'), NotificationAccess.blocked, NotificationAccessAction.openSettings),
      ('Windows and Linux', notificationAccessFrom(const NoPromptFacts(), askedBefore: true), NotificationAccess.notRequired, NotificationAccessAction.none),
      ('unreadable never prompts', notificationAccessFrom(const NoPromptFacts(readFailed: true), askedBefore: false), NotificationAccess.notRequired, NotificationAccessAction.none),
    ];
    for (final (name, got, state, action) in rows) {
      test(name, () {
        expect(got, state);
        expect(primaryActionFor(got), action);
      });
    }
  });

  group('when each thing shows', () {
    final at = DateTime(2026, 11, 7);
    const off = NotificationAccessView(access: NotificationAccess.blocked, loaded: true);

    test('the first launch prompt', () {
      bool offer({bool platformAsks = true, bool demo = false, NotificationAccess access = NotificationAccess.notAsked, DateTime? promptAt}) =>
          shouldOfferFirstLaunchPrompt(platformAsks: platformAsks, demo: demo, access: access, promptAt: promptAt);
      expect(offer(), isTrue);
      expect(offer(promptAt: at), isFalse, reason: 'once');
      expect(offer(demo: true), isFalse);
      expect(offer(platformAsks: false), isFalse);
      for (final a in NotificationAccess.values.where((a) => a != NotificationAccess.notAsked)) {
        expect(offer(access: a), isFalse, reason: a.name);
      }
    });

    test('the quiet line', () {
      bool show({DateTime? hintShownAt, NotificationAccess access = NotificationAccess.notAsked, bool demo = false, bool platformAsks = true}) =>
          shouldShowQuietLine(platformAsks: platformAsks, demo: demo, access: access, hintShownAt: hintShownAt);
      expect(show(), isTrue);
      expect(show(hintShownAt: at), isFalse);
      expect(show(demo: true), isFalse);
      expect(show(platformAsks: false), isFalse);
      expect(show(access: NotificationAccess.blocked), isFalse);
    });

    test('the banner: while off, until closed, back when a post finishes unseen or needs the reminder', () {
      bool banner(NotificationAccessView v, {bool demo = false, DateTime? closedAt, DateTime? neededAt}) =>
          notificationBannerVisible(v, demo: demo, closedAt: closedAt, reminderNeededAt: neededAt);
      expect(banner(off), isTrue);
      expect(banner(off, demo: true), isFalse);
      expect(banner(const NotificationAccessView(access: NotificationAccess.blocked)), isFalse, reason: 'before the OS has answered');
      expect(banner(const NotificationAccessView(access: NotificationAccess.granted, loaded: true)), isFalse);
      expect(banner(const NotificationAccessView(loaded: true)), isFalse, reason: 'Windows and Linux');
      expect(banner(off, closedAt: at), isFalse);
      expect(banner(NotificationAccessView(access: NotificationAccess.blocked, loaded: true, lastUnseenAt: at.subtract(const Duration(hours: 1))), closedAt: at), isFalse);
      expect(banner(NotificationAccessView(access: NotificationAccess.blocked, loaded: true, lastUnseenAt: at.add(const Duration(hours: 1))), closedAt: at), isTrue);
      expect(banner(off, closedAt: at, neededAt: at.subtract(const Duration(hours: 1))), isFalse);
      expect(banner(off, closedAt: at, neededAt: at.add(const Duration(hours: 1))), isTrue);
      expect(banner(const NotificationAccessView(access: NotificationAccess.granted, loaded: true, resultsChannelOff: true)), isTrue, reason: 'names the channel');
    });

    test('the words', () {
      expect(notificationBannerText(off, remindersAtRisk: false).action, 'Open settings');
      expect(notificationBannerText(const NotificationAccessView(access: NotificationAccess.notAsked, loaded: true), remindersAtRisk: false).action, 'Turn on');
      final risk = notificationBannerText(off, remindersAtRisk: true);
      expect(risk.urgent, isTrue);
      expect(risk.text, 'Scheduled posts will not remind you. Turn on notifications.');
      expect(notificationBannerText(const NotificationAccessView(access: NotificationAccess.granted, loaded: true, resultsChannelOff: true), remindersAtRisk: false).text, contains('Publish results'));

      ({String title, String description, String? action}) row(NotificationAccess a, {bool ios = false}) =>
          notificationRowText(NotificationAccessView(access: a, loaded: true), os: ios ? 'iOS' : 'Android', isIOS: ios);
      expect(row(NotificationAccess.granted).title, 'Notifications are on');
      expect(row(NotificationAccess.granted).action, 'Manage');
      expect(row(NotificationAccess.notAsked).title, 'Notifications are off');
      expect(row(NotificationAccess.notAsked).action, 'Turn on');
      expect(row(NotificationAccess.askedUnclear).action, 'Turn on');
      expect(row(NotificationAccess.blocked).title, 'Android is blocking notifications');
      expect(row(NotificationAccess.blocked, ios: true).title, 'iOS is blocking notifications');
      expect(row(NotificationAccess.blocked, ios: true).description, 'Scheduled posts will not remind you at their time.');
      expect(row(NotificationAccess.blocked).action, 'Open settings');
      expect(row(NotificationAccess.notRequired).action, isNull);
      expect(notificationRowText(const NotificationAccessView(readFailed: true, loaded: true), os: 'Android', isIOS: false).description, contains('could not read'));
    });
  });

  test('the settings stay on the device, and are saved', () {
    for (final key in ['notificationPromptAt', 'notificationOsAskedAt', 'notificationHintShownAt', 'notificationBannerClosedAt']) {
      expect(kDeviceOnlySettings.containsKey(key), isTrue, reason: key);
      expect(kExportableSettings.contains(key), isFalse, reason: key);
    }
    final at = DateTime.utc(2026, 11, 7, 9);
    final s = AppSettings.fromJson(AppSettings(notificationPromptAt: at, notificationOsAskedAt: at, notificationHintShownAt: at, notificationBannerClosedAt: at).toJson());
    expect((s.notificationPromptAt, s.notificationOsAskedAt, s.notificationHintShownAt, s.notificationBannerClosedAt), (at, at, at, at));
    final imported = withImportedSettings(const AppSettings(), {'notificationPromptAt': at.toIso8601String()});
    expect(imported.notificationPromptAt, isNull, reason: "another device's answer is not this one's");
  });

  group('first launch', () {
    testWidgets('the explanation comes first; Not now shows no OS prompt, and it never comes back', (tester) async {
      final os = _FakeOs(_androidNew);
      final storage = _MemoryStorage();
      final (c, _) = await _pumpApp(tester, os, storage: storage);
      expect(find.text(_explanation), findsOneWidget);
      expect(os.requests, 0, reason: 'explanation first');
      expect(c.read(settingsProvider).notificationPromptAt, isNotNull);

      await tester.tap(find.text('Not now'));
      await _settle(tester);
      expect(find.text(_explanation), findsNothing);
      expect(os.requests, 0, reason: 'Not now spends nothing');
      expect(c.read(settingsProvider).notificationOsAskedAt, isNull);
      expect(c.read(notificationAccessProvider).access, NotificationAccess.notAsked, reason: 'still unasked');
      await _finish(tester);

      final (again, _) = await _pumpApp(tester, os, storage: storage);
      expect(find.text(_explanation), findsNothing, reason: 'shown once, across a restart');
      expect(again.read(notificationAccessProvider).access, NotificationAccess.notAsked);
      expect(find.text('Notifications are off, so NEFORUM cannot tell you how a post went while you are away.'), findsOneWidget, reason: 'the reminder is what stays');
      await _finish(tester);
    });

    testWidgets('closing it by tapping outside counts as Not now', (tester) async {
      final os = _FakeOs(_androidNew);
      await _pumpApp(tester, os);
      await tester.tapAt(const Offset(180, 10));
      await _settle(tester);
      expect(find.text(_explanation), findsNothing);
      expect(os.requests, 0);
      await _finish(tester);
    });

    testWidgets('Turn on shows the OS prompt, once, and a yes clears everything', (tester) async {
      final os = _FakeOs(_androidNew)..afterRequest = _androidOn;
      final (c, _) = await _pumpApp(tester, os);
      await tester.tap(find.text('Turn on notifications'));
      await _settle(tester);
      expect(os.requests, 1);
      expect(c.read(settingsProvider).notificationOsAskedAt, isNotNull);
      expect(c.read(notificationAccessProvider).access, NotificationAccess.granted);
      expect(find.textContaining('Notifications are off'), findsNothing);
      await _finish(tester);
    });

    testWidgets('a refusal: one toast, no second screen, posting still works', (tester) async {
      final os = _FakeOs(_androidNew)..afterRequest = const AndroidNotificationFacts(sdkInt: 35, enabled: false, rationale: true);
      await _pumpApp(tester, os);
      await tester.tap(find.text('Turn on notifications'));
      await _settle(tester);
      expect(find.text('Posting still works. Open Activity to see how it went.'), findsOneWidget);
      expect(find.byType(NotificationExplanation), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      await _finish(tester);
    });

    testWidgets('iOS words, and it says iOS asks only once', (tester) async {
      final os = _FakeOs(_iosNew);
      await _pumpApp(tester, os, platform: TargetPlatform.iOS);
      expect(find.text("Don't miss a scheduled post"), findsOneWidget);
      expect(find.textContaining('iOS asks only once'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await _settle(tester);
      expect(os.requests, 0);
      await _finish(tester);
    });

    testWidgets('macOS gets the flow', (tester) async {
      final os = _FakeOs(_iosNew);
      await _pumpApp(tester, os, platform: TargetPlatform.macOS, size: const Size(1280, 800));
      expect(find.byType(NotificationExplanation), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await _settle(tester);
      await _finish(tester);
    });

    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      testWidgets('never on ${platform.name}, even if asked to believe otherwise', (tester) async {
        final os = _FakeOs(_iosNew);
        await _pumpApp(tester, os, platform: platform, size: const Size(1280, 800));
        expect(find.byType(NotificationExplanation), findsNothing);
        expect(os.requests, 0);
        await _finish(tester);
      });
    }

    testWidgets('never in the demo', (tester) async {
      final os = _FakeOs(_androidNew);
      final (c, _) = await _pumpApp(tester, os, demo: true);
      expect(find.byType(NotificationExplanation), findsNothing);
      expect(c.read(notificationAccessProvider).needsAttention, isFalse);
      expect(find.textContaining('Notifications are off'), findsNothing);
      expect(os.requests, 0);
      await _finish(tester);
    });

    testWidgets('a 1.3.x upgrader still unasked sees it once; one who said yes does not', (tester) async {
      final old = _MemoryStorage({'onboarded': true, 'notifyOnPublish': true});
      await _pumpApp(tester, _FakeOs(_androidNew), storage: old);
      expect(find.byType(NotificationExplanation), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await _settle(tester);
      await _finish(tester);

      await _pumpApp(tester, _FakeOs(_androidOn), storage: _MemoryStorage({'onboarded': true}));
      expect(find.byType(NotificationExplanation), findsNothing);
      await _finish(tester);
    });

    testWidgets('notifications come before the update question', (tester) async {
      final os = _FakeOs(_androidNew);
      final storage = _MemoryStorage();
      storage.json['settings.json'] = <String, dynamic>{'themeMode': 'light', 'updateCheck': 'ask'};
      final (c, _) = await _pumpApp(tester, os, storage: storage);
      expect(find.byType(NotificationExplanation), findsOneWidget);
      expect(find.text('Check for updates?'), findsNothing);
      await tester.tap(find.text('Not now'));
      await _settle(tester);
      expect(find.byType(NotificationExplanation), findsNothing);
      if (c.read(settingsProvider).updateCheck == UpdateCheckMode.ask && find.text('Check for updates?').evaluate().isNotEmpty) {
        await tester.tap(find.text("Don't check"));
        await _settle(tester);
      }
      await _finish(tester);
    });
  });

  group('the reminder', () {
    final closed = {'notificationPromptAt': '2026-11-01T00:00:00.000Z'};

    testWidgets('over every section, closable, and it stays closed until a post finishes unseen', (tester) async {
      final os = _FakeOs(_androidNew);
      final storage = _MemoryStorage(closed);
      final (c, services) = await _pumpApp(tester, os, storage: storage);
      const words = 'Notifications are off, so NEFORUM cannot tell you how a post went while you are away.';
      for (final path in ['/compose', '/queue', '/activity', '/accounts', '/settings']) {
        c.read(routerProvider).go(path);
        await _settle(tester);
        expect(find.text(words), findsOneWidget, reason: path);
      }
      await tester.tap(find.byTooltip('Hide this'));
      await _settle(tester);
      expect(find.text(words), findsNothing);
      expect(c.read(settingsProvider).notificationBannerClosedAt, isNotNull);

      // Back to the app, nothing new: still closed.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(find.text(words), findsNothing);

      await tester.runAsync(() => UnseenResults(services.storage).add(UnseenResult(postId: 'p', at: DateTime.now().add(const Duration(minutes: 1)), title: 'Posted to 2 networks', lines: const ['Posted to Bluesky', 'YouTube failed'])));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(find.text('While you were away'), findsOneWidget, reason: 'the OS could not tell them');
      expect(find.text('YouTube failed'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await _settle(tester);
      expect(find.text(words), findsOneWidget, reason: 'back after a post finished unseen');
      final after = (await tester.runAsync(() => UnseenResults(services.storage).read()))!;
      expect(after.entries, isEmpty, reason: 'told once');
      await _finish(tester);
    });

    testWidgets('re-read on return from settings: turned on there, gone here', (tester) async {
      final os = _FakeOs(const AndroidNotificationFacts(sdkInt: 35, enabled: false, rationale: true));
      final (c, _) = await _pumpApp(tester, os, storage: _MemoryStorage(closed));
      expect(c.read(notificationAccessProvider).access, NotificationAccess.canAskAgain);
      os.facts = _androidOn;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(c.read(notificationAccessProvider).access, NotificationAccess.granted);
      expect(find.textContaining('Notifications are off'), findsNothing);
      await _finish(tester);
    });

    for (final (platform, facts) in [
      (TargetPlatform.android, const AndroidNotificationFacts(sdkInt: 32, enabled: false, rationale: false) as NotificationFacts),
      (TargetPlatform.iOS, const DarwinNotificationFacts('denied') as NotificationFacts),
    ]) {
      testWidgets('blocked on ${platform.name}: the buttons go to the system settings, never a prompt', (tester) async {
        final os = _FakeOs(facts);
        final (c, _) = await _pumpApp(tester, os, platform: platform, storage: _MemoryStorage(closed));
        expect(find.text('Open settings'), findsOneWidget);
        await tester.tap(find.text('Open settings'));
        await _settle(tester);
        expect(os.settings, 1);
        expect(os.requests, 0);

        c.read(routerProvider).go('/settings');
        await _settle(tester);
        final title = platform == TargetPlatform.iOS ? 'iOS is blocking notifications' : 'Android is blocking notifications';
        await tester.scrollUntilVisible(find.text(title), 300, scrollable: find.byType(Scrollable).first);
        await _settle(tester);
        expect(find.text(title), findsOneWidget);
        await _finish(tester);
      });
    }

    testWidgets('asked before and Android stays quiet: tries, then points to settings without claiming what happened', (tester) async {
      final os = _FakeOs(_androidNew);
      final (c, _) = await _pumpApp(tester, os, storage: _MemoryStorage({...closed, 'notificationOsAskedAt': '2026-11-01T00:00:00.000Z'}));
      expect(c.read(notificationAccessProvider).access, NotificationAccess.askedUnclear);
      await tester.tap(find.text('Turn on'));
      await _settle(tester);
      expect(os.requests, 1);
      expect(find.textContaining('If Android did not ask'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await _finish(tester);
    });

    testWidgets('the results channel set to none names that channel and goes to its page', (tester) async {
      final os = _FakeOs(const AndroidNotificationFacts(sdkInt: 35, enabled: true, rationale: false, resultsChannelOff: true));
      final (c, _) = await _pumpApp(tester, os, storage: _MemoryStorage(closed));
      expect(c.read(notificationAccessProvider).access, NotificationAccess.granted);
      expect(find.text('Publish results notifications are off in Android settings.'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await _settle(tester);
      expect(os.channelSettings, 1);
      expect(os.settings, 0);
      await _finish(tester);
    });

    testWidgets('the pill on Activity is there while off, closed banner or not, and gone when on', (tester) async {
      final os = _FakeOs(_androidNew);
      final (c, _) = await _pumpApp(tester, os, storage: _MemoryStorage({...closed, 'notificationBannerClosedAt': '2026-11-02T00:00:00.000Z'}));
      c.read(routerProvider).go('/activity');
      await _settle(tester);
      expect(find.text('Notifications off'), findsOneWidget);
      expect(tester.getSize(find.byType(NotificationsOffPill)).height, greaterThanOrEqualTo(48));
      os.facts = _androidOn;
      await c.read(notificationAccessProvider.notifier).refresh();
      await _settle(tester);
      expect(find.text('Notifications off'), findsNothing);
      await _finish(tester);
    });

    testWidgets('on iOS, a post scheduled after closing that needs the reminder brings it back, in danger colours', (tester) async {
      final os = _FakeOs(const DarwinNotificationFacts('denied'));
      final at = DateTime.now();
      Post scheduled(String id, DateTime changed) => Post(
            id: id,
            text: 'Later',
            createdAt: changed,
            updatedAt: changed,
            status: PostStatus.scheduled,
            scheduledAt: at.add(const Duration(days: 1)),
            targets: const [PostTarget(accountId: 'a', status: TargetStatus.pending)],
          );
      final closedAt = at.subtract(const Duration(hours: 1));
      // posts.json is a real file the fake clock cannot wait for: the list the banner reads, given.
      await _pumpApp(tester, os,
          platform: TargetPlatform.iOS,
          storage: _MemoryStorage({...closed, 'notificationBannerClosedAt': closedAt.toUtc().toIso8601String()}),
          overrides: [scheduledPostsProvider.overrideWithValue([scheduled('older', closedAt.subtract(const Duration(hours: 1)))])]);
      expect(find.textContaining('Scheduled posts will not remind you'), findsNothing, reason: 'scheduled before it was closed');
      await _finish(tester);

      await _pumpApp(tester, os,
          platform: TargetPlatform.iOS,
          storage: _MemoryStorage({...closed, 'notificationBannerClosedAt': closedAt.toUtc().toIso8601String()}),
          overrides: [scheduledPostsProvider.overrideWithValue([scheduled('newer', at)])]);
      expect(find.text('Scheduled posts will not remind you. Turn on notifications.'), findsOneWidget);
      await _finish(tester);

      // Not scheduled-and-closed on Android: the iOS reminder is iOS's.
      await _pumpApp(tester, _FakeOs(const AndroidNotificationFacts(sdkInt: 32, enabled: false, rationale: false)),
          storage: _MemoryStorage({...closed, 'notificationBannerClosedAt': closedAt.toUtc().toIso8601String()}),
          overrides: [scheduledPostsProvider.overrideWithValue([scheduled('newer', at)])]);
      expect(find.textContaining('Scheduled posts will not remind you'), findsNothing);
      await _finish(tester);
    });
  });

  group('the quiet line', () {
    Future<void> openSheet(WidgetTester tester, Future<void> Function(BuildContext context) show) async {
      final context = tester.element(find.byType(Scaffold).first);
      show(context);
      await _settle(tester);
    }

    testWidgets('in the first sheet only, with Turn on, no modal; it does not hold up the sheet', (tester) async {
      final os = _FakeOs(_androidNew)..afterRequest = _androidOn;
      final (c, _) = await _pumpApp(tester, os, storage: _MemoryStorage({'notificationPromptAt': '2026-11-01T00:00:00.000Z', 'notificationBannerClosedAt': '2026-11-02T00:00:00.000Z'}));
      c.read(publishRunProvider.notifier).prepare();
      await openSheet(tester, (context) => showPublishProgress(context));
      expect(find.byType(NotificationExplanation), findsNothing, reason: 'no modal');
      expect(find.text('A notification can tell you how this goes.'), findsOneWidget);
      expect(c.read(settingsProvider).notificationHintShownAt, isNotNull);
      expect(c.read(publishSheetOpenProvider), 1, reason: 'the sheet counts as open while it shows');

      await tester.tap(find.text('Turn on'));
      await _settle(tester);
      expect(os.requests, 1);
      expect(find.text('A notification can tell you how this goes.'), findsNothing, reason: 'on now');
      await tester.pump(const Duration(seconds: 10));
      c.read(publishRunProvider.notifier).fail(null, 'x');
      await _settle(tester);
      await tester.tap(find.text('Close'));
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      expect(c.read(publishSheetOpenProvider), 0);
      await _finish(tester);
    });

    testWidgets('not a second time', (tester) async {
      final os = _FakeOs(_androidNew);
      final (c, _) = await _pumpApp(tester, os, storage: _MemoryStorage({'notificationPromptAt': '2026-11-01T00:00:00.000Z', 'notificationHintShownAt': '2026-11-02T00:00:00.000Z'}));
      c.read(publishRunProvider.notifier).prepare();
      await openSheet(tester, (context) => showPublishProgress(context));
      expect(find.text('A notification can tell you how this goes.'), findsNothing);
      c.read(publishRunProvider.notifier).fail(null, 'x');
      await _settle(tester);
      await tester.tap(find.text('Close'));
      await tester.pump(const Duration(seconds: 1));
      await _finish(tester);
    });

    testWidgets('the Schedule sheet at 360 x 640, with the words iOS needs', (tester) async {
      final os = _FakeOs(_iosNew);
      await _pumpApp(tester, os, platform: TargetPlatform.iOS, storage: _MemoryStorage({'notificationPromptAt': '2026-11-01T00:00:00.000Z'}));
      await openSheet(tester, (context) => showScheduleSheet(context));
      expect(find.text('A notification lets you post at this time.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(180, 5));
      await _settle(tester);
      await _finish(tester);
    });

    testWidgets('blocked on iOS, the Schedule sheet says no reminder will appear', (tester) async {
      final os = _FakeOs(const DarwinNotificationFacts('denied'));
      await _pumpApp(tester, os, platform: TargetPlatform.iOS, storage: _MemoryStorage({'notificationPromptAt': '2026-11-01T00:00:00.000Z', 'notificationBannerClosedAt': '2026-11-02T00:00:00.000Z'}));
      await openSheet(tester, (context) => showScheduleSheet(context));
      expect(find.text('No reminder will appear at this time.'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await _settle(tester);
      expect(os.settings, 1);
      await tester.tapAt(const Offset(180, 5));
      await _settle(tester);
      await _finish(tester);
    });
  });

  group('fits at 360 x 640', () {
    testWidgets('the explanation at text scale 1.5, on both OSes', (tester) async {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        final os = _FakeOs(platform == TargetPlatform.iOS ? _iosNew : _androidNew);
        await _pumpApp(tester, os, platform: platform, storage: _MemoryStorage({'mobileTextScale': 1.5}));
        expect(find.byType(NotificationExplanation), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Not now'));
        await _settle(tester);
        expect(tester.takeException(), isNull, reason: 'the banner too');
        await _finish(tester);
      }
    });

    testWidgets('dark, with the row in Settings', (tester) async {
      final os = _FakeOs(_androidNew);
      final (c, _) = await _pumpApp(tester, os, storage: _MemoryStorage({'themeMode': 'dark', 'notificationPromptAt': '2026-11-01T00:00:00.000Z'}));
      c.read(routerProvider).go('/settings');
      await _settle(tester);
      expect(find.byType(NotificationSettingsSection), findsWidgets);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });
}
