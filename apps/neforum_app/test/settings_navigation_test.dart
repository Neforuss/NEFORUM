// Settings navigation: the pinned table of contents on wide pages, folding
// sections, and the chip bar and "Jump to" list on narrow ones.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/ui/settings/setting_row.dart';

class _MemoryStorage implements AppStorage {
  _MemoryStorage(Map<String, Object> settings) : json = {'settings.json': settings};
  final Map<String, Object> json;
  @override
  String? get dataDir => null;
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
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF888888)));
}

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

/// The Settings page of the demo workspace at [size]; [settings] are stored
/// before launch.
Future<(ProviderContainer, _MemoryStorage)> _pumpSettings(WidgetTester tester, Size size, {Map<String, Object> settings = const {}}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final storage = _MemoryStorage({'themeMode': 'light', ...settings});
  final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
  await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
  await tester.pump(const Duration(milliseconds: 300));
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  container.read(routerProvider).go('/settings');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  // Sections that read saved values settle first.
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await _settle(tester);
  return (container, storage);
}

/// Several frames, so scroll and fold animations run to the end.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

ScrollPosition _page(WidgetTester tester) => Scrollable.of(tester.element(find.text('Make NEFORUM yours'))).position;

/// The table of contents entry for [title].
Finder _entry(String title) => find.widgetWithText(TextButton, title);

/// Whether [entry] is marked as the section in view.
bool _marked(WidgetTester tester, Finder entry) =>
    find.ancestor(of: entry, matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.selected == true)).evaluate().isNotEmpty;

/// The section chip for [title] on narrow pages.
ChoiceChip _chip(WidgetTester tester, String title) => tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, title));

void main() {
  setUpAll(_loadFonts);

  group('wide page', () {
    testWidgets('the table of contents stays put and marks the section in view', (tester) async {
      await _pumpSettings(tester, const Size(1440, 900));
      expect(find.text('ON THIS PAGE'), findsOneWidget);
      expect(find.text('Jump to'), findsNothing);
      final label = tester.getTopLeft(find.text('ON THIS PAGE'));
      expect(_marked(tester, _entry('Appearance')), isTrue);

      await tester.tap(_entry('Sync'));
      await _settle(tester);
      expect(_page(tester).pixels, greaterThan(0));
      expect(tester.getTopLeft(find.text('ON THIS PAGE')), label, reason: 'pinned');
      expect(_marked(tester, _entry('Sync')), isTrue);
      expect(_marked(tester, _entry('Appearance')), isFalse);
      expect(tester.getTopLeft(find.text('Sync between devices')).dy, lessThan(300), reason: 'scrolled to the top of the page');

      // Scrolling marks the section in view.
      _page(tester).jumpTo(0);
      await tester.pump();
      expect(_marked(tester, _entry('Appearance')), isTrue);
      _page(tester).jumpTo(_page(tester).maxScrollExtent);
      await tester.pump();
      expect(_marked(tester, _entry('About')), isTrue);
      await _unmount(tester);
    });

    testWidgets('sections fold and stay folded; Expand all and Collapse all', (tester) async {
      final (container, storage) = await _pumpSettings(tester, const Size(1440, 900));
      List<String> folded() => container.read(settingsProvider).collapsedSettingsSections;

      expect(find.text('Theme'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Collapse Appearance'));
      await _settle(tester);
      expect(find.text('Theme'), findsNothing);
      expect(folded(), ['Appearance']);
      expect((storage.json['settings.json']! as Map)['collapsedSettingsSections'], ['Appearance'], reason: 'kept for the next launch');
      expect(find.bySemanticsLabel('Expand Appearance'), findsOneWidget);

      await tester.tap(find.text('Collapse all'));
      await _settle(tester);
      expect(folded(), containsAll(['Appearance', 'Posting', 'Sync', 'About']));
      expect(find.text('Sync between devices'), findsNothing);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Collapse all')).onPressed, isNull);

      // Picking a folded section opens it and goes there.
      await tester.tap(_entry('Sync'));
      await _settle(tester);
      expect(folded(), isNot(contains('Sync')));
      expect(find.text('Sync between devices'), findsOneWidget);
      expect(_marked(tester, _entry('Sync')), isTrue);

      await tester.tap(find.text('Expand all'));
      await _settle(tester);
      expect(folded(), isEmpty);
      expect(find.text('Theme'), findsOneWidget);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Expand all')).onPressed, isNull);
      await _unmount(tester);
    });

    testWidgets('folded sections are folded again after a restart', (tester) async {
      await _pumpSettings(tester, const Size(1440, 900), settings: {
        'collapsedSettingsSections': ['Appearance', 'Posting'],
      });
      expect(find.text('Theme'), findsNothing);
      expect(find.bySemanticsLabel('Expand Appearance'), findsOneWidget);
      expect(find.bySemanticsLabel('Expand Posting'), findsOneWidget);
      expect(find.bySemanticsLabel('Collapse Scheduling'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('the table of contents also shows beside the rail when it fits', (tester) async {
      await _pumpSettings(tester, const Size(1000, 760));
      expect(find.text('ON THIS PAGE'), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('narrow page', () {
    testWidgets('the chip bar follows the page and Jump to lists every section', (tester) async {
      await _pumpSettings(tester, const Size(360, 740));
      expect(find.text('ON THIS PAGE'), findsNothing);
      expect(_chip(tester, 'Appearance').selected, isTrue);
      final bar = tester.getTopLeft(find.text('Jump to'));

      await tester.tap(find.text('Jump to'));
      await _settle(tester);
      final appearance = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Appearance'));
      expect(appearance.selected, isTrue, reason: 'the section in view is marked');
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Notifications')).selected, isFalse);

      await tester.tap(find.widgetWithText(ListTile, 'Notifications'));
      await _settle(tester);
      expect(find.byType(ListTile), findsNothing, reason: 'the list closes');
      expect(_chip(tester, 'Notifications').selected, isTrue);
      expect(_chip(tester, 'Appearance').selected, isFalse);
      expect(tester.getTopLeft(find.text('Tell me when scheduled posts go out')).dy, lessThan(400));
      expect(tester.getTopLeft(find.text('Jump to')), bar, reason: 'pinned');

      _page(tester).jumpTo(0);
      await tester.pump();
      expect(_chip(tester, 'Appearance').selected, isTrue);
      // The bar scrolls back to show that chip.
      await _settle(tester);
      expect(tester.getTopLeft(find.widgetWithText(ChoiceChip, 'Appearance')).dx, greaterThanOrEqualTo(0));

      await tester.tap(find.widgetWithText(ChoiceChip, 'Posting'));
      await _settle(tester);
      expect(_chip(tester, 'Posting').selected, isTrue);
      expect(_page(tester).pixels, greaterThan(0));
      await _unmount(tester);
    });

    testWidgets('Jump to offers Expand all and Collapse all and marks folded sections', (tester) async {
      final (container, _) = await _pumpSettings(tester, const Size(360, 740));
      await tester.tap(find.text('Jump to'));
      await _settle(tester);
      await tester.tap(find.text('Collapse all'));
      await _settle(tester);
      expect(find.text('Collapsed'), findsWidgets);
      expect(container.read(settingsProvider).collapsedSettingsSections, contains('Data & privacy'));
      await tester.tap(find.text('Expand all'));
      await _settle(tester);
      expect(find.text('Collapsed'), findsNothing);
      expect(container.read(settingsProvider).collapsedSettingsSections, isEmpty);
      await _unmount(tester);
    });

    testWidgets('a tablet-sized page uses the chip bar', (tester) async {
      await _pumpSettings(tester, const Size(900, 700));
      expect(find.text('Jump to'), findsOneWidget);
      expect(find.text('ON THIS PAGE'), findsNothing);
      await _unmount(tester);
    });
  });

  testWidgets('a section shown on its own does not fold', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light, AccentChoice.neforum),
      home: const Scaffold(body: SettingsSection(title: 'Alone', icon: Icons.info_outline, children: [Text('Row')])),
    ));
    expect(find.text('Row'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
    await tester.tap(find.text('Alone'));
    await tester.pump();
    expect(find.text('Row'), findsOneWidget);
  });
}
