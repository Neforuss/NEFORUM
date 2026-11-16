// 1.4.4: on a new install the first question is whether this device joins
// an existing NEFORUM sync, with a way straight into each join flow, or
// "No, I'm new". Asked once per install, before notifications, never stacked.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/notification_access.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/ui/settings/sync_section.dart';
import 'package:neforum_app/ui/shell/first_start_sync.dart';
import 'package:neforum_app/ui/shell/notification_prompt.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

const _question = 'Do you already use NEFORUM on another device?';
const _imNew = "No, I'm new to NEFORUM";
const _answered = '2026-11-01T00:00:00.000Z';

class _MemoryStorage implements AppStorage {
  _MemoryStorage([Map<String, Object> settings = const {}]) {
    json['settings.json'] = <String, dynamic>{'updateCheck': 'off', 'themeMode': 'light', ...settings};
  }
  final Map<String, Object> json = {};

  /// Posts, accounts and the journal are files: a folder of this test's own.
  final String _dir = Directory.systemTemp.createTempSync('neforum-first-sync-').path;
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

/// What the OS says about notifications: by default nothing to ask.
class _FakeOs implements NotificationAccessPlatform {
  _FakeOs([this.facts = const NoPromptFacts()]);
  final NotificationFacts facts;
  @override
  Future<NotificationFacts> read() async => facts;
  @override
  Future<bool> request() async => false;
  @override
  Future<void> openSettings() async {}
  @override
  Future<void> openResultsChannelSettings() async {}
}

/// The OS file picker: records what was asked, picks nothing.
class _FakePicker extends FilePickerPlatform {
  final titles = <String?>[];
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    titles.add(dialogTitle);
    return const [];
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    for (var j = 0; j < 4; j++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}

/// The real app on a real workspace, its storage in memory. [prepare] runs on
/// the workspace before the first frame.
Future<(ProviderContainer, AppServices)> _pumpApp(
  WidgetTester tester, {
  _MemoryStorage? storage,
  bool demo = false,
  TargetPlatform platform = TargetPlatform.android,
  Size size = const Size(360, 640),
  NotificationAccessPlatform? os,
  Future<void> Function(AppServices s)? prepare,
}) async {
  NotificationAccessPlatform.instance = os ?? _FakeOs();
  debugDefaultTargetPlatformOverride = platform;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = (await tester.runAsync(() async {
    final s = await AppServices.create(demo: demo, storage: storage ?? _MemoryStorage());
    await prepare?.call(s);
    return s;
  }))!;
  await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
  await _settle(tester);
  return (ProviderScope.containerOf(tester.element(find.byType(MaterialApp))), services);
}

/// Leaves no scheduler timer behind and puts the platform back.
Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    debugOfferSyncAtFirstStart = true;
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
  final originalOs = NotificationAccessPlatform.instance;
  final originalPicker = FilePickerPlatform.instance;
  tearDown(() {
    debugOfferSyncAtFirstStart = false;
    NotificationAccessPlatform.instance = originalOs;
    FilePickerPlatform.instance = originalPicker;
    debugDefaultTargetPlatformOverride = null;
  });

  test('asked only on a new install of a real workspace, until answered', () {
    bool offer({bool demo = false, bool web = false, bool syncOn = false, bool hasAccounts = false, DateTime? answeredAt}) =>
        shouldOfferSyncAtFirstStart(demo: demo, web: web, syncOn: syncOn, hasAccounts: hasAccounts, answeredAt: answeredAt);
    expect(offer(), isTrue);
    expect(offer(answeredAt: DateTime.utc(2026, 11, 1)), isFalse, reason: 'once');
    expect(offer(syncOn: true), isFalse, reason: 'sync is already set up');
    expect(offer(hasAccounts: true), isFalse, reason: 'not a new install');
    expect(offer(demo: true), isFalse);
    expect(offer(web: true), isFalse);
  });

  test('each shortcut opens Set up on its own kind of storage', () {
    expect({for (final c in SyncOfferChoice.values) c: syncOfferStorage(c)}, {
      SyncOfferChoice.googleDrive: SyncBackendKind.googleDrive,
      SyncOfferChoice.folder: SyncBackendKind.folder,
      SyncOfferChoice.webdav: SyncBackendKind.webdav,
      SyncOfferChoice.s3: SyncBackendKind.s3,
      SyncOfferChoice.transferFile: null,
      SyncOfferChoice.newUser: null,
    });
  });

  test('the answer stays on the device, and is saved', () {
    expect(kDeviceOnlySettings.containsKey('syncOfferAnsweredAt'), isTrue);
    expect(kExportableSettings.contains('syncOfferAnsweredAt'), isFalse);
    final at = DateTime.utc(2026, 11, 16, 9);
    expect(AppSettings.fromJson(AppSettings(syncOfferAnsweredAt: at).toJson()).syncOfferAnsweredAt, at);
    expect(const AppSettings().toJson().containsKey('syncOfferAnsweredAt'), isFalse);
    final imported = withImportedSettings(const AppSettings(), {'syncOfferAnsweredAt': at.toIso8601String()});
    expect(imported.syncOfferAnsweredAt, isNull, reason: "another device's answer is not this one's");
    expect(syncedSettings(AppSettings(syncOfferAnsweredAt: at)).containsKey('syncOfferAnsweredAt'), isFalse, reason: 'not in the sync file');
  });

  group('first start', () {
    testWidgets("a new install asks; No, I'm new opens nothing and is never asked again, even after a restart", (tester) async {
      final storage = _MemoryStorage();
      final (c, _) = await _pumpApp(tester, storage: storage);
      expect(find.text(_question), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget, reason: 'a sheet on a phone');
      expect(c.read(settingsProvider).syncOfferAnsweredAt, isNull, reason: 'recorded when answered');
      expect(tester.takeException(), isNull);

      await tester.tap(find.text(_imNew));
      await _settle(tester);
      expect(find.text(_question), findsNothing);
      expect(find.byType(SyncSetupDialog), findsNothing);
      expect(c.read(settingsProvider).syncOfferAnsweredAt, isNotNull);
      expect(c.read(settingsProvider).syncOn, isFalse);
      await _finish(tester);

      await _pumpApp(tester, storage: storage);
      expect(find.text(_question), findsNothing, reason: 'answered on this install');
      await _finish(tester);
    });

    testWidgets('closing it by tapping outside counts as an answer', (tester) async {
      final storage = _MemoryStorage();
      const wide = Size(1280, 800);
      final (c, _) = await _pumpApp(tester, storage: storage, size: wide);
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);
      expect(find.text(_question), findsNothing);
      expect(c.read(settingsProvider).syncOfferAnsweredAt, isNotNull);
      await _finish(tester);
      await _pumpApp(tester, storage: storage, size: wide);
      expect(find.text(_question), findsNothing);
      await _finish(tester);
    });

    testWidgets('not asked when sync is already set up', (tester) async {
      await _pumpApp(tester, storage: _MemoryStorage({'syncProviderId': 'webdav', 'syncConfig': <String, String>{'url': 'https://dav.example.test/neforum'}}));
      expect(find.text(_question), findsNothing);
      await _finish(tester);
    });

    testWidgets('not asked when this install already has accounts', (tester) async {
      await _pumpApp(tester, prepare: (s) => s.accounts.upsert(ConnectedAccount(
            id: 'fake-mastodon',
            platformId: 'mastodon',
            tier: PlatformTier.openApi,
            displayName: 'Fake',
            createdAt: DateTime.utc(2026, 11, 1),
            config: const {'instance': 'https://mastodon.example.test'},
          )));
      expect(find.text(_question), findsNothing);
      await _finish(tester);
    });

    testWidgets('not asked in the demo workspace', (tester) async {
      await _pumpApp(tester, demo: true);
      expect(find.text(_question), findsNothing);
      await _finish(tester);
    });
  });

  /// Scrolls the question to [label] and taps it, as a thumb would.
  Future<void> tapChoice(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pump();
    await tester.tap(find.text(label));
  }

  group('each shortcut opens its join flow', () {
    Future<ProviderContainer> choose(WidgetTester tester, String label) async {
      final (c, _) = await _pumpApp(tester);
      await tapChoice(tester, label);
      await _settle(tester);
      expect(find.text(_question), findsNothing);
      expect(c.read(settingsProvider).syncOfferAnsweredAt, isNotNull, reason: 'choosing a way in is an answer');
      return c;
    }

    testWidgets('Google Drive, directly: its form, ready for the Client ID', (tester) async {
      await choose(tester, 'Google Drive, directly');
      expect(find.byType(SyncSetupDialog), findsOneWidget);
      expect(find.text('Sync with Google Drive (direct)'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Client ID'), findsOneWidget);
      expect(find.text('Turn on sync'), findsOneWidget);
      // Back: a list of one is no choice, so every kind is listed.
      await tester.tap(find.text('Back'));
      await _settle(tester);
      expect(find.text('Where should the sync file go?'), findsOneWidget);
      expect(find.text('WebDAV'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('a cloud app or a synced folder: only the folder storage, and Other storage lists the rest', (tester) async {
      await choose(tester, 'A cloud app or a synced folder');
      expect(find.text('Where is your sync file?'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'OneDrive'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Nextcloud'), findsNothing, reason: 'that is WebDAV');
      await tester.tap(find.widgetWithText(ActionChip, 'OneDrive'));
      await _settle(tester);
      expect(find.text('Sync with OneDrive'), findsOneWidget);
      expect(find.text('Choose the sync file…'), findsOneWidget, reason: 'the Files app path on a phone');
      await tester.tap(find.text('Back'));
      await _settle(tester);
      expect(find.text('Where is your sync file?'), findsOneWidget, reason: 'back to the folder storage');
      await tapChoice(tester, 'Other storage');
      await _settle(tester);
      expect(find.text('Where should the sync file go?'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Nextcloud'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('WebDAV: only the WebDAV servers', (tester) async {
      await choose(tester, 'WebDAV');
      expect(find.text('Where is your sync file?'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Nextcloud'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Cloudflare R2'), findsNothing);
      await tester.tap(find.widgetWithText(ActionChip, 'Nextcloud'));
      await _settle(tester);
      expect(find.widgetWithText(TextField, 'WebDAV folder address'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('S3-compatible storage: only the buckets', (tester) async {
      await choose(tester, 'S3-compatible storage');
      expect(find.widgetWithText(ActionChip, 'Cloudflare R2'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'OneDrive'), findsNothing);
      await tester.tap(find.widgetWithText(ActionChip, 'Cloudflare R2'));
      await _settle(tester);
      expect(find.widgetWithText(TextField, 'Bucket'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('a transfer file: the Import picker of Move to another device', (tester) async {
      final picker = _FakePicker();
      FilePickerPlatform.instance = picker;
      await choose(tester, 'A transfer file');
      expect(picker.titles, ['Open a NEFORUM backup']);
      expect(find.byType(SyncSetupDialog), findsNothing);
      await _finish(tester);
    });

    testWidgets('on iPhone the folder way says iCloud Drive and the Files app', (tester) async {
      await _pumpApp(tester, platform: TargetPlatform.iOS);
      await tapChoice(tester, 'iCloud Drive or the Files app');
      await _settle(tester);
      expect(find.widgetWithText(ActionChip, 'iCloud Drive'), findsOneWidget);
      await _finish(tester);
    });
  });

  group('one question at a time', () {
    const androidNew = AndroidNotificationFacts(sdkInt: 35, enabled: false, rationale: false);

    testWidgets('sync first; the notifications explanation comes after the answer', (tester) async {
      await _pumpApp(tester, os: _FakeOs(androidNew));
      expect(find.text(_question), findsOneWidget);
      expect(find.byType(NotificationExplanation), findsNothing, reason: 'not stacked');
      await tester.tap(find.text(_imNew));
      await _settle(tester);
      expect(find.text(_question), findsNothing);
      expect(find.byType(NotificationExplanation), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await _settle(tester);
      await _finish(tester);
    });

    testWidgets('a join flow finishes before the notifications explanation', (tester) async {
      await _pumpApp(tester, os: _FakeOs(androidNew));
      await tapChoice(tester, 'WebDAV');
      await _settle(tester);
      expect(find.byType(SyncSetupDialog), findsOneWidget);
      expect(find.byType(NotificationExplanation), findsNothing, reason: 'while joining');
      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(find.byType(SyncSetupDialog), findsNothing);
      expect(find.byType(NotificationExplanation), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await _settle(tester);
      await _finish(tester);
    });

    testWidgets('an install that answered gets the notifications explanation straight away', (tester) async {
      await _pumpApp(tester, os: _FakeOs(androidNew), storage: _MemoryStorage({'syncOfferAnsweredAt': _answered}));
      expect(find.text(_question), findsNothing);
      expect(find.byType(NotificationExplanation), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await _settle(tester);
      await _finish(tester);
    });
  });

  group('layouts', () {
    for (final dark in [false, true]) {
      for (final seamless in [false, true]) {
        final name = '${dark ? 'dark' : 'light'}, seamless ${seamless ? 'on' : 'off'}';
        testWidgets('phone 360 x 640 at text scale 1.5, $name', (tester) async {
          await _pumpApp(tester,
              storage: _MemoryStorage({'themeMode': dark ? 'dark' : 'light', 'seamlessSurfaces': seamless, 'mobileTextScale': 1.5}));
          expect(find.byType(SyncOffer), findsOneWidget);
          expect(tester.takeException(), isNull);
          // In view without scrolling: the answer most people give.
          await tester.tap(find.text(_imNew));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          await _finish(tester);
        });

        testWidgets('wide window 1280 x 800, a dialog, $name', (tester) async {
          await _pumpApp(tester,
              size: const Size(1280, 800), storage: _MemoryStorage({'themeMode': dark ? 'dark' : 'light', 'seamlessSurfaces': seamless}));
          expect(find.descendant(of: find.byType(Dialog), matching: find.byType(SyncOffer)), findsOneWidget);
          expect(tester.getSize(find.byType(SyncOffer)).width, lessThanOrEqualTo(520));
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(_imNew));
          await _settle(tester);
          await _finish(tester);
        });
      }
    }
  });

  testWidgets('reachable later from Settings > Sync, with every kind of storage', (tester) async {
    final (c, _) = await _pumpApp(tester, size: const Size(1280, 800));
    await tester.tap(find.text(_imNew));
    await _settle(tester);
    c.read(routerProvider).go('/settings');
    await _settle(tester);
    final setUp = find.text('Set up…');
    await tester.runAsync(() => Scrollable.ensureVisible(tester.element(setUp), alignment: 0.5));
    await _settle(tester);
    expect(find.text('Sync between devices'), findsOneWidget);
    await tester.tap(setUp);
    await _settle(tester);
    expect(find.text('Where should the sync file go?'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Google Drive (direct)'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Nextcloud'), findsOneWidget);
    expect(find.text('Other storage'), findsNothing, reason: 'nothing to widen');
    await _finish(tester);
  });
}
