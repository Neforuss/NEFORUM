import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/caption_fonts.dart';
import 'package:neforum_app/media/font_catalog.dart';
import 'package:neforum_app/media/font_installer.dart';
import 'package:neforum_app/media/font_storage_io.dart' as files;
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/font_downloads.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/font_download_sheet.dart';
import 'package:neforum_app/ui/compose/font_picker_sheet.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/settings/data_section.dart';

import 'font_fixtures.dart';

Future<AppStorage> _tempStorage(String mode) async {
  final dir = Directory.systemTemp.createTempSync('nf-font-picker-');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // Still in use on Windows; the system cleans it up.
    }
  });
  final storage = await openAppStorage(overrideDir: dir.path);
  await storage.writeJson('settings.json', {'fontDownloads': mode, 'onboarded': true});
  return storage;
}

/// Pumps real time: font files go through isolates and the real file system.
Future<void> _until(WidgetTester tester, bool Function() done, {String why = 'it to finish'}) async {
  for (var i = 0; i < 600 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done(), isTrue, reason: 'waited for $why');
}

class _Harness {
  _Harness(this.fake, this.storage, this.services);
  final FakeFontServices fake;
  final AppStorage storage;
  final AppServices services;
  FontChoice? picked;
  bool closed = false;
  late ProviderContainer container;
}

FakeFontServices _servicesWithInter() {
  final inter = File(kInterRegular).readAsBytesSync();
  final fake = FakeFontServices();
  fake.details['inter'] = fontDetailFixture('inter', 'Inter', variants: {
    400: ['latin'],
    700: ['latin'],
    900: ['latin'],
  });
  fake.addFont('inter', '5.3.0', {
    'latin-400-normal.ttf': subsetOf(inter, isLatin),
    'latin-700-normal.ttf': subsetOf(File(kInterBold).readAsBytesSync(), isLatin),
    'latin-900-normal.ttf': subsetOf(File(kInterBold).readAsBytesSync(), isLatin),
  });
  return fake;
}

/// The app's picker behind a button, on the fake services.
Future<_Harness> _pump(WidgetTester tester, {String mode = 'ask', CaptionFont? current, Size size = const Size(1200, 900), Brightness brightness = Brightness.light, FakeFontServices? services}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = services ?? _servicesWithInter();
  final storage = (await tester.runAsync(() => _tempStorage(mode)))!;
  final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
  debugInstalledFontCatalog = InstalledFontCatalog.empty;
  final h = _Harness(fake, storage, s);
  await tester.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(s), fontDownloadClientProvider.overrideWithValue(fake.client)],
    child: MaterialApp(
      theme: buildTheme(brightness, AccentChoice.neforum),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            h.container = ProviderScope.containerOf(context);
            return TextButton(
              onPressed: () async {
                h.picked = await showFontChoiceSheet(context, current: FontChoice(TextCardFont.original, current), platformId: 'instagram');
                h.closed = true;
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return h;
}

/// Lets the picker read the list.
Future<void> _listRead(WidgetTester tester, _Harness h) => _until(tester, () => h.container.read(fontDownloadsProvider).catalog != null, why: 'the list');

/// A test on a computer: phones have no installed fonts and other wording.
void _desktop(String description, WidgetTesterCallback body) => testWidgets(description, body, variant: TargetPlatformVariant.only(TargetPlatform.windows));

void main() {
  tearDown(debugResetCaptionFonts);

  group('consent', () {
    _desktop('opening the picker and searching send nothing; the question explains; Not now changes nothing', (tester) async {
      final h = await _pump(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Download'), findsNothing, reason: 'no section before the answer');
      await tester.enterText(find.byKey(const Key('font-search')), 'inter');
      await tester.pump(const Duration(seconds: 1));
      expect(h.fake.requests, isEmpty);

      await tester.tap(find.byKey(const Key('font-find-more')));
      await tester.pumpAndSettle();
      expect(find.textContaining('api.fontsource.org and cdn.jsdelivr.net'), findsOneWidget);
      expect(find.textContaining('your IP address and the font names you look up, never your posts'), findsOneWidget);
      expect(find.textContaining('No key or account'), findsOneWidget);
      await tester.tap(find.byKey(const Key('font-consent-not-now')));
      await tester.pumpAndSettle();
      expect(h.fake.requests, isEmpty, reason: 'nothing went out');
      expect(h.container.read(settingsProvider).fontDownloads, FontDownloadMode.ask, reason: 'asked again next time');
      expect(find.byKey(const Key('font-find-more')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('Allow turns it on for this device and reads the list; only then', (tester) async {
      final h = await _pump(tester);
      await tester.tap(find.byKey(const Key('font-find-more')));
      await tester.pumpAndSettle();
      expect(h.fake.requests, isEmpty, reason: 'not while the question is up');
      await tester.tap(find.byKey(const Key('font-consent-allow')));
      await tester.pump();
      await _listRead(tester, h);
      expect(h.container.read(settingsProvider).fontDownloads, FontDownloadMode.on);
      expect(h.fake.paths, ['/v1/fonts']);
      await tester.pump();
      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Built in'), findsNothing, reason: 'only the list, until asked otherwise');
      expect(find.text('42dot Sans'), findsOneWidget);
      await tester.tap(find.byKey(const Key('font-find-more')));
      await tester.pump();
      expect(find.text('Built in'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('turned off: no button, no section, no requests', (tester) async {
      final h = await _pump(tester, mode: 'off');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('font-find-more')), findsNothing);
      expect(find.text('Download'), findsNothing);
      expect(h.fake.requests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('search and one tap', () {
    _desktop('finds a font in the picker; one tap installs it, draws it and returns it', (tester) async {
      final h = await _pump(tester, mode: 'on');
      await _listRead(tester, h);
      await tester.enterText(find.byKey(const Key('font-search')), 'inter');
      await tester.pump();
      expect(find.text('OFL 1.1 · Sans serif'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('font-catalog-inter')));
      await tester.pump();
      await _until(tester, () => h.closed, why: 'the picker to close with the font');
      final font = h.picked!.customFont!;
      expect(font.family, 'Inter');
      expect(font.source!.id, 'inter');
      expect(font.source!.version, '5.3.0');
      expect(font.source!.sizeBytes, greaterThan(1000));
      expect(registeredCaptionFontAlias(font), font.alias, reason: 'ready to draw');
      expect(File('${files.catalogFontsDirectory(h.storage.dataDir)}/inter@5.3.0/LICENSE').existsSync(), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('a downloaded font is listed as such, not as imported, and leaves the list', (tester) async {
      final h = await _pump(tester, mode: 'on');
      await tester.runAsync(() async {
        final installer = FontInstaller(client: h.fake.client, dataDir: h.storage.dataDir);
        await installer.install(await installer.plan('inter'));
      });
      h.container.invalidate(downloadedFontsProvider);
      await tester.pump();
      await _listRead(tester, h);
      await _until(tester, () => h.container.read(downloadedFontsProvider).hasValue);
      await tester.pump();
      expect(find.text('Downloaded'), findsOneWidget);
      expect(find.text('Imported'), findsNothing);
      expect(find.text('OFL 1.1 · 2 weights'), findsOneWidget);
      expect(find.text('OFL 1.1 · Sans serif'), findsNothing, reason: 'no longer offered');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('Add more weights, the licence, and Remove are on its row', (tester) async {
      final h = await _pump(tester, mode: 'on');
      await tester.runAsync(() async {
        final installer = FontInstaller(client: h.fake.client, dataDir: h.storage.dataDir);
        await installer.install(await installer.plan('inter'));
      });
      h.container.invalidate(downloadedFontsProvider);
      await _listRead(tester, h);
      await _until(tester, () => h.container.read(downloadedFontsProvider).hasValue);
      await tester.pump();

      await tester.tap(find.byKey(const Key('font-menu-inter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Licence'));
      await _until(tester, () => find.textContaining('SIL Open Font License').evaluate().isNotEmpty, why: 'the licence text');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('font-menu-inter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add more weights…'));
      await _until(tester, () => find.byKey(const Key('font-weight-900')).evaluate().isNotEmpty, why: 'the weights');
      await tester.tap(find.byKey(const Key('font-weight-900')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('font-weights-add')));
      await tester.pump();
      await _until(tester, () => find.text('OFL 1.1 · 3 weights').evaluate().isNotEmpty, why: 'the new weight');
      expect(File('${files.catalogFontsDirectory(h.storage.dataDir)}/inter@5.3.0/latin-900-normal.ttf').existsSync(), isTrue);

      await tester.tap(find.byKey(const Key('font-menu-inter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from this device'));
      await _until(tester, () => find.text('Downloaded').evaluate().isEmpty, why: 'the font to go');
      expect(Directory('${files.catalogFontsDirectory(h.storage.dataDir)}/inter@5.3.0').existsSync(), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('a big font says its size first, and Cancel fetches nothing', (tester) async {
      final fake = _servicesWithInter();
      fake.details['noto-sans-jp'] = fontDetailFixture('noto-sans-jp', 'Noto Sans JP', variants: {400: ['japanese'], 700: ['japanese']});
      fake.etags['noto-sans-jp@5.3.0/japanese-400-normal.ttf'] = 'W/"299ea4-a"';
      fake.etags['noto-sans-jp@5.3.0/japanese-700-normal.ttf'] = 'W/"299ea4-b"';
      fake.addFont('noto-sans-jp', '5.3.0', {'japanese-400-normal.ttf': Uint8List(4), 'japanese-700-normal.ttf': Uint8List(4)});
      final h = await _pump(tester, mode: 'on', services: fake);
      await _listRead(tester, h);
      await tester.enterText(find.byKey(const Key('font-search')), 'noto sans jp');
      await tester.pump();
      await tester.tap(find.text('Noto Sans JP'));
      await tester.pump();
      await _until(tester, () => find.textContaining('about 5.2 MB').evaluate().isNotEmpty, why: 'the question about the size');
      expect(fake.requests.where((r) => r.method == 'GET' && r.url.path.endsWith('.ttf')), isEmpty);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(fake.requests.where((r) => r.method == 'GET' && r.url.path.endsWith('.ttf')), isEmpty, reason: 'still nothing fetched');
      expect(h.closed, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('a failure says what happened in plain words, and the picker stays', (tester) async {
      final h = await _pump(tester, mode: 'on');
      await _listRead(tester, h);
      h.fake.files.clear();
      await tester.enterText(find.byKey(const Key('font-search')), 'inter');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('font-catalog-inter')));
      await tester.pump();
      await _until(tester, () => find.textContaining('no longer has this file').evaluate().isNotEmpty, why: 'the message');
      expect(h.closed, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('no list and no network: the picker still works, says so, and offers to try again', (tester) async {
      final fake = _servicesWithInter()..offline = true;
      final h = await _pump(tester, mode: 'on', services: fake);
      await _until(tester, () => h.container.read(fontDownloadsProvider).catalogProblem != null, why: 'the problem');
      await tester.pump();
      expect(find.text('Built in'), findsOneWidget);
      expect(find.byKey(const Key('font-catalog-problem')), findsOneWidget);
      fake.offline = false;
      await tester.dragUntilVisible(find.byKey(const Key('font-catalog-retry')), find.byType(ListView), const Offset(0, -200));
      await tester.tap(find.byKey(const Key('font-catalog-retry')));
      await tester.pump();
      await _listRead(tester, h);
      await tester.pump();
      expect(find.byKey(const Key('font-catalog-problem')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('searching works from the saved list with the network gone', (tester) async {
      final fake = _servicesWithInter();
      final storage = (await tester.runAsync(() => _tempStorage('on')))!;
      await tester.runAsync(() => loadFontCatalog(storage, fake.client));
      fake
        ..requests.clear()
        ..offline = true;
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      debugInstalledFontCatalog = InstalledFontCatalog.empty;
      late ProviderContainer container;
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(s), fontDownloadClientProvider.overrideWithValue(fake.client)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Scaffold(body: Builder(builder: (context) {
            container = ProviderScope.containerOf(context);
            return const FontPickerSheet(current: FontChoice(TextCardFont.original), platformId: 'instagram');
          })),
        ),
      ));
      await _until(tester, () => container.read(fontDownloadsProvider).catalog != null, why: 'the saved list');
      expect(fake.requests, isEmpty, reason: 'a fresh copy is not read again');
      await tester.enterText(find.byKey(const Key('font-search')), 'lobster');
      await tester.pump();
      expect(find.text('OFL 1.1 · Display'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('previews', () {
    _desktop('a row at rest asks for one file after 300 ms; a scroll in progress asks for none', (tester) async {
      final fake = _servicesWithInter();
      for (final e in fontListFixture()) {
        fake.files['${e['id']}@latest/latin-400-normal.ttf'] = fake.files['inter@5.3.0/latin-400-normal.ttf']!;
      }
      final h = await _pump(tester, mode: 'on', services: fake, size: const Size(1200, 500));
      await _listRead(tester, h);
      await tester.tap(find.byKey(const Key('font-find-more')));
      await tester.pump();
      List<String> asked() => [for (final r in fake.requests) if (r.url.path.contains('@latest/')) r.url.path];

      await tester.pump(const Duration(milliseconds: 200));
      expect(asked(), isEmpty, reason: 'not yet');
      final gesture = await tester.startGesture(tester.getCenter(find.byType(ListView)));
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(asked(), isEmpty, reason: 'the list is moving');
      await gesture.up();
      await tester.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 400));
      await _until(tester, () => asked().isNotEmpty, why: 'the rows at rest to ask');
      expect(asked().every((p) => p.endsWith('/latin-400-normal.ttf')), isTrue, reason: 'one small file each');
      expect(asked().toSet().length, asked().length);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('a style naming a font this device does not have', () {
    const missing = CaptionFont(family: 'Inter', source: CatalogFontSource(id: 'inter', version: '5.3.0', sizeBytes: 481216));

    _desktop('the picker offers it first, with its size, without asking anyone', (tester) async {
      final h = await _pump(tester, current: missing);
      await _until(tester, () => find.text('Not on this device').evaluate().isNotEmpty, why: 'the offer');
      expect(find.text('Download Inter (470 KB)'), findsOneWidget);
      expect(h.fake.requests, isEmpty, reason: 'the size came with the style');

      // Asking first, then one tap is all.
      await tester.tap(find.byKey(const Key('font-picker-missing')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('font-consent-allow')));
      await tester.pump();
      await _until(tester, () => h.closed, why: 'the picker to close with the font');
      expect(h.picked!.customFont!.source!.id, 'inter');
      expect(registeredCaptionFontAlias(missing), missing.alias);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('no offer when downloads are off, or for a font not from the list', (tester) async {
      final h = await _pump(tester, mode: 'off', current: missing);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Not on this device'), findsNothing);
      expect(h.fake.requests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());

      final other = await _pump(tester, current: const CaptionFont(family: 'Own Font', fileId: 'gone.ttf'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Not on this device'), findsNothing);
      expect(other.fake.requests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('the button under a missing font: fetches it, and is gone when off', (tester) async {
      final fake = _servicesWithInter();
      final storage = (await tester.runAsync(() => _tempStorage('on')))!;
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(s), fontDownloadClientProvider.overrideWithValue(fake.client)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: const Scaffold(body: MissingFontDownloadButton(font: missing)),
        ),
      ));
      expect(find.text('Download Inter (470 KB)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('font-missing-download')));
      await tester.pump();
      await _until(tester, () => registeredCaptionFontAlias(missing) != null, why: 'the font');
      await _until(tester, () => find.text('Download Inter (470 KB)').evaluate().isNotEmpty, why: 'the download to end');
      await tester.pumpWidget(const SizedBox.shrink());

      final none = ProviderScope(
        overrides: [servicesProvider.overrideWithValue(s), fontDownloadClientProvider.overrideWithValue(fake.client)],
        child: MaterialApp(theme: buildTheme(Brightness.light, AccentChoice.neforum), home: const Scaffold(body: MissingFontDownloadButton(font: CaptionFont(family: 'Own')))),
      );
      await tester.pumpWidget(none);
      expect(find.byKey(const Key('font-missing-download')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('saving a card without it brings a banner with one tap to fetch it; the banner goes when it is here', (tester) async {
      final fake = _servicesWithInter();
      final storage = (await tester.runAsync(() => _tempStorage('ask')))!;
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      debugInstalledFontCatalog = InstalledFontCatalog.empty;
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(s), fontDownloadClientProvider.overrideWithValue(fake.client)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          builder: (context, child) => RenderWarningBanner(child: child!),
          home: const Scaffold(body: Text('page')),
        ),
      ));
      await tester.runAsync(() => prepareCaptionFontForRender(storage, missing, usage: 'the text card'));
      await tester.pumpAndSettle();
      expect(find.textContaining('The font Inter is not on this device, so the text card uses the default font.'), findsOneWidget);
      expect(find.text('Download Inter (470 KB)'), findsOneWidget);
      expect(fake.requests, isEmpty);

      await tester.tap(find.byKey(const Key('font-offer-inter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('font-consent-allow')));
      await tester.pump();
      await _until(tester, () => registeredCaptionFontAlias(missing) != null, why: 'the font');
      await _until(tester, () => find.text('Download Inter (470 KB)').evaluate().isEmpty, why: 'the banner to go');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('with downloads off the banner only says how to get the font', (tester) async {
      final storage = (await tester.runAsync(() => _tempStorage('off')))!;
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      debugInstalledFontCatalog = InstalledFontCatalog.empty;
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(s)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          builder: (context, child) => RenderWarningBanner(child: child!),
          home: const Scaffold(body: Text('page')),
        ),
      ));
      await tester.runAsync(() => prepareCaptionFontForRender(storage, missing, usage: 'the text card'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Install or import Inter here'), findsOneWidget);
      expect(find.byKey(const Key('font-offer-inter')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('Settings > Data and privacy', () {
    Future<(FakeFontServices, AppStorage, ProviderContainer)> pumpSection(WidgetTester tester, String mode) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fake = _servicesWithInter();
      final storage = (await tester.runAsync(() => _tempStorage(mode)))!;
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      late ProviderContainer container;
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(s), fontDownloadClientProvider.overrideWithValue(fake.client)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Builder(builder: (context) {
                container = ProviderScope.containerOf(context);
                return const DataSettingsSection();
              }),
            ),
          ),
        ),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      return (fake, storage, container);
    }

    _desktop('the switch reads and sets the choice, and says who is contacted', (tester) async {
      final (fake, _, container) = await pumpSection(tester, 'ask');
      expect(find.textContaining('api.fontsource.org and cdn.jsdelivr.net'), findsOneWidget);
      expect(find.textContaining('No fonts downloaded.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('font-downloads-setting')));
      await tester.pump();
      expect(container.read(settingsProvider).fontDownloads, FontDownloadMode.on);
      await tester.tap(find.byKey(const Key('font-downloads-setting')));
      await tester.pump();
      expect(container.read(settingsProvider).fontDownloads, FontDownloadMode.off);
      expect(fake.requests, isEmpty, reason: 'turning it on fetches nothing by itself');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    _desktop('Delete everything takes the fonts, the list and the previews, and the yes', (tester) async {
      final (fake, storage, container) = await pumpSection(tester, 'on');
      await tester.runAsync(() async {
        final n = container.read(fontDownloadsProvider.notifier);
        await n.openCatalog();
        await n.install(await n.plan('inter'));
        await files.saveFontPreview(storage.dataDir, 'lobster', fake.files['inter@5.3.0/latin-400-normal.ttf']!);
      });
      await tester.pump();
      final data = storage.dataDir!;
      expect(Directory(files.catalogFontsDirectory(data)!).listSync(), isNotEmpty);

      await tester.ensureVisible(find.text('Delete…'));
      await tester.pump();
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
      expect(find.textContaining('downloaded font'), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete everything'));
      await tester.pump();
      await _until(tester, () => !File('$data/$kFontCatalogFile').existsSync() && !Directory(files.catalogFontsDirectory(data)!).existsSync(), why: 'the files to go');
      await _until(tester, () => container.read(settingsProvider).fontDownloads == FontDownloadMode.ask, why: 'the setting');
      expect(Directory(files.fontPreviewsDirectory(data)!).existsSync(), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('at phone size', () {
    for (final (name, brightness) in const [('light', Brightness.light), ('dark', Brightness.dark)]) {
      testWidgets('360 x 640 with every section has no overflow ($name)', (tester) async {
        final h = await _pump(tester, mode: 'on', size: const Size(360, 640), brightness: brightness);
        await _listRead(tester, h);
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('font-find-more')));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('Download'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }
  });
}
