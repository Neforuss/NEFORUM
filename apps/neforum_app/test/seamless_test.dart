// 1.4.3: Settings > Appearance > Seamless. Surfaces lose their outlines
// (cards, sections, tiles, panels, menus, dialogs, the navigation's edge) on
// every layout, while text fields, chips, buttons, dividers between rows and
// selected or focused items keep theirs.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/selection_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/ui/settings/setting_row.dart';
import 'package:neforum_app/widgets/surfaces.dart';

import 'seamless_checks.dart';

class _MemoryStorage implements AppStorage {
  _MemoryStorage(Map<String, Object> settings) : _json = {'settings.json': settings};
  final Map<String, Object> _json;
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
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

/// NEFORUM's demo workspace at [size] with [settings], on [route].
Future<ProviderContainer> _pumpApp(WidgetTester tester, {required Size size, Map<String, Object> settings = const {}, String route = '/settings'}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage({'themeMode': 'light', ...settings}))))!;
  await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
  await tester.pump(const Duration(milliseconds: 300));
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  container.read(routerProvider).go(route);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return container;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

NfColors _nf(WidgetTester tester) => Theme.of(tester.element(find.byType(Scaffold).first)).extension<NfColors>()!;

/// [child] alone, under NEFORUM's theme.
Future<NfColors> _pumpKit(WidgetTester tester, Widget child, {bool seamless = true, Brightness brightness = Brightness.light, Size size = const Size(800, 600)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final theme = buildTheme(brightness, AccentChoice.neforum, seamless: seamless);
  await tester.pumpWidget(MaterialApp(theme: theme, home: Scaffold(body: Center(child: child))));
  await tester.pump(const Duration(milliseconds: 300));
  return theme.extension<NfColors>()!;
}

/// The box an [NfCard] draws.
BoxDecoration _cardBox(WidgetTester tester, Finder card) =>
    tester.widget<AnimatedContainer>(find.descendant(of: card, matching: find.byType(AnimatedContainer)).first).decoration! as BoxDecoration;

Color _sideColor(BoxDecoration d) => (d.border! as Border).top.color;

Color _shapeSide(ShapeBorder? s) => (s! as OutlinedBorder).side.color;

void main() {
  setUpAll(_loadFonts);
  tearDown(() => Radii.square = false);

  group('tokens', () {
    test('withSeamless takes the outline off surfaces and keeps every line that carries meaning', () {
      for (final b in Brightness.values) {
        for (final chrome in NavigationChromeStyle.values) {
          for (final highContrast in [false, true]) {
            final label = '${b.name} ${chrome.name}${highContrast ? ' high contrast' : ''}';
            final plain = buildTheme(b, AccentChoice.ocean, chrome: chrome, highContrast: highContrast).extension<NfColors>()!;
            final seamless = buildTheme(b, AccentChoice.ocean, chrome: chrome, highContrast: highContrast, seamless: true).extension<NfColors>()!;

            expect(plain.seamless, isFalse, reason: label);
            expect(plain.border, plain.hairline, reason: '$label: outside seamless mode a surface keeps its outline');
            expect(plain.border.a, 1, reason: label);
            expect(plain.borderHover, plain.borderStrong, reason: label);

            expect(seamless.seamless, isTrue, reason: label);
            expect(seamless.border.a, 0, reason: '$label: no outline around surfaces');
            expect(seamless.chromeBorder.a, 0, reason: '$label: no line between the navigation and the page');
            expect(seamless.borderHover.a, 0, reason: '$label: no outline under the pointer either');
            expect(seamless.hairline, plain.hairline, reason: '$label: dividers, fields and chips keep their line');
            expect(seamless.hairline.a, 1, reason: label);
            expect(seamless.borderStrong, plain.borderStrong, reason: '$label: control edges stay');
            expect(seamless.accent, plain.accent, reason: '$label: selected and focus outlines stay');
            expect(seamless.surface, plain.surface, reason: '$label: fills are unchanged');
            expect(seamless.chrome, plain.chrome, reason: label);
          }
        }
      }
    });

    test('the theme chrome draws its edge only outside seamless mode', () {
      for (final b in Brightness.values) {
        final themed = buildTheme(b, AccentChoice.neforum, chrome: NavigationChromeStyle.theme).extension<NfColors>()!;
        expect(themed.chromeBorder.a, 1, reason: '${b.name}: the case seamless mode must change');
        expect(themed.withSeamless().chromeBorder.a, 0);
      }
    });

    test('high contrast on top of seamless keeps surfaces outline-free and strengthens control edges', () {
      final base = NfColors.light(AccentChoice.neforum);
      final both = base.withSeamless().withHighContrast();
      expect(both.seamless, isTrue);
      expect(both.border.a, 0);
      expect(both.hairline, base.withHighContrast().hairline);
      expect(contrastRatio(both.hairline, both.surface), greaterThanOrEqualTo(3));
    });

    test('switching seamless mode animates the outline away', () {
      final plain = NfColors.dark(AccentChoice.neforum);
      final seamless = plain.withSeamless();
      final half = plain.lerp(seamless, 0.5);
      expect(half.border.a, closeTo(0.5, 0.01));
      expect(half.hairline, plain.hairline);
      expect(plain.lerp(seamless, 0.4).seamless, isFalse);
      expect(plain.lerp(seamless, 0.6).seamless, isTrue);
    });

    test('Material components: surfaces lose their side, controls keep theirs, menus float on a shadow', () {
      for (final b in Brightness.values) {
        final plain = buildTheme(b, AccentChoice.neforum);
        final t = buildTheme(b, AccentChoice.neforum, seamless: true);
        final nf = t.extension<NfColors>()!;
        final label = b.name;

        // Surfaces.
        expect(_shapeSide(t.cardTheme.shape).a, 0, reason: '$label card');
        expect(_shapeSide(t.dialogTheme.shape).a, 0, reason: '$label dialog');
        expect(_shapeSide(t.popupMenuTheme.shape).a, 0, reason: '$label popup menu');
        expect(t.menuTheme.style!.side!.resolve({})!.color.a, 0, reason: '$label menu');
        expect(_shapeSide(t.datePickerTheme.shape).a, 0, reason: '$label date picker');
        expect(_shapeSide(t.timePickerTheme.shape).a, 0, reason: '$label time picker');
        expect(t.popupMenuTheme.elevation, greaterThan(0), reason: '$label: a menu needs a shadow without its outline');
        expect(t.menuTheme.style!.elevation!.resolve({}), greaterThan(0), reason: label);

        // Controls and lines with meaning.
        final input = t.inputDecorationTheme;
        expect((input.enabledBorder! as OutlineInputBorder).borderSide.color, nf.hairline, reason: '$label text field');
        expect((input.border! as OutlineInputBorder).borderSide.color, nf.hairline, reason: label);
        expect((input.focusedBorder! as OutlineInputBorder).borderSide.color, nf.accent, reason: '$label focus');
        expect((input.errorBorder! as OutlineInputBorder).borderSide.color, nf.danger, reason: label);
        // Chips and segments keep a visible edge: the clear selected state's
        // (selection_theme.dart) when they are off, the hairline while
        // disabled, the selected fill while on.
        for (final (name, side) in [
          ('chip', (Set<WidgetState> s) => WidgetStateProperty.resolveAs<BorderSide?>(t.chipTheme.side, s)!),
          ('segmented button', (Set<WidgetState> s) => t.segmentedButtonTheme.style!.side!.resolve(s)!),
        ]) {
          expect(side({}).color, nf.unselectedBorder, reason: '$label $name');
          expect(side({WidgetState.disabled}).color, nf.hairline, reason: '$label disabled $name');
          expect(side({}).color.a, 1, reason: '$label $name');
        }
        expect(WidgetStateProperty.resolveAs<BorderSide?>(t.chipTheme.side, {WidgetState.selected})!.color, nf.selectedFill, reason: '$label chip on');
        expect(t.outlinedButtonTheme.style!.side!.resolve({})!.color, nf.hairline, reason: '$label outlined button');
        expect(t.outlinedButtonTheme.style!.side!.resolve({WidgetState.hovered})!.color, nf.borderStrong, reason: label);
        expect(t.dividerTheme.color, nf.hairline, reason: '$label divider');
        expect(t.dividerColor, nf.hairline, reason: label);
        expect(t.colorScheme.outlineVariant, nf.hairline, reason: label);
        expect(t.checkboxTheme.side!.color, nf.borderStrong, reason: label);
        for (final c in [nf.hairline, nf.borderStrong]) {
          expect(c.a, 1, reason: label);
        }

        // Outside seamless mode nothing changes.
        final p = plain.extension<NfColors>()!;
        expect(_shapeSide(plain.cardTheme.shape), p.border, reason: label);
        expect(_shapeSide(plain.dialogTheme.shape), p.border, reason: label);
        expect(plain.popupMenuTheme.elevation, 0, reason: label);
        expect(plain.menuTheme.style!.elevation!.resolve({}), 0, reason: label);
      }
    });
  });

  group('setting', () {
    test('off by default, saved, read back and shared with other devices', () {
      expect(const AppSettings().seamlessSurfaces, isFalse);
      expect(AppSettings.fromJson(const {}).seamlessSurfaces, isFalse);
      final on = const AppSettings().copyWith(seamlessSurfaces: true);
      expect(on.toJson()['seamlessSurfaces'], isTrue);
      expect(AppSettings.fromJson(on.toJson()).seamlessSurfaces, isTrue);
      expect(on.copyWith(cornerStyle: CornerStyle.square).seamlessSurfaces, isTrue);
      expect(AppSettings.fromJson(const {'seamlessSurfaces': 'yes'}).seamlessSurfaces, isFalse, reason: 'a malformed value falls back');
      expect(kExportableSettings, contains('seamlessSurfaces'));
      expect(syncedSettings(on)['seamlessSurfaces'], isTrue);
      expect(syncedSettings(const AppSettings())['seamlessSurfaces'], isFalse);
    });
  });

  group('widget kit', () {
    testWidgets('NfCard drops its outline, keeps a selected or given one', (tester) async {
      for (final seamless in [false, true]) {
        final nf = await _pumpKit(
          tester,
          seamless: seamless,
          Column(mainAxisSize: MainAxisSize.min, children: [
            const NfCard(key: Key('plain'), child: Text('Plain')),
            const NfCard(key: Key('selected'), selected: true, child: Text('Selected')),
            NfCard(key: const Key('own'), borderColor: Colors.red, child: const Text('Own')),
          ]),
        );
        final plain = _cardBox(tester, find.byKey(const Key('plain')));
        expect(_sideColor(plain).a, seamless ? 0 : 1, reason: 'seamless $seamless');
        expect(outlineShows(plain), !seamless);
        expect(_sideColor(_cardBox(tester, find.byKey(const Key('selected')))), nf.accent, reason: 'a selected card stays clear');
        expect(_sideColor(_cardBox(tester, find.byKey(const Key('own')))), Colors.red, reason: 'an outline with a meaning stays');
        expect(plain.color, nf.surface, reason: 'the fill tells the card apart');
        expect(visibleCardOutlines(tester), seamless ? isEmpty : isNotEmpty);
      }
    });

    testWidgets('an NfCard under the pointer shows no outline in seamless mode', (tester) async {
      for (final seamless in [false, true]) {
        final nf = await _pumpKit(tester, seamless: seamless, NfCard(key: const Key('tap'), onTap: () {}, child: const SizedBox(width: 200, height: 80)));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(find.byKey(const Key('tap'))));
        await tester.pump(const Duration(milliseconds: 300));
        final box = _cardBox(tester, find.byKey(const Key('tap')));
        expect(box.color, nf.surfaceHover, reason: 'hover feedback stays');
        expect(_sideColor(box), seamless ? nf.border : nf.borderStrong);
        expect(outlineShows(box), !seamless);
        await mouse.removePointer();
      }
    });

    testWidgets('NfWell drops its outline, keeps a highlighted edge', (tester) async {
      final nf = await _pumpKit(
        tester,
        const Column(mainAxisSize: MainAxisSize.min, children: [
          NfWell(key: Key('well'), child: Text('Well')),
          NfWell(key: Key('lit'), highlight: true, child: Text('Drop here')),
        ]),
      );
      BoxDecoration box(String key) => tester.widget<AnimatedContainer>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(AnimatedContainer))).decoration! as BoxDecoration;
      expect(outlineShows(box('well')), isFalse);
      expect(box('well').color, nf.surfaceSunken);
      expect(_sideColor(box('lit')), nf.accent);
    });

    testWidgets('a labelled divider and the theme divider stay', (tester) async {
      final nf = await _pumpKit(tester, const SizedBox(width: 300, child: Column(mainAxisSize: MainAxisSize.min, children: [LabeledDivider('or'), Divider(key: Key('plain'))])));
      for (final d in tester.widgetList<Divider>(find.descendant(of: find.byType(LabeledDivider), matching: find.byType(Divider)))) {
        expect(d.color, nf.hairline);
      }
      expect(DividerTheme.of(tester.element(find.byKey(const Key('plain')))).color, nf.hairline);
      expect(nf.hairline.a, 1);
    });

    testWidgets('Settings tiles at phone width: no card outline, the rows keep their dividers', (tester) async {
      for (final b in Brightness.values) {
        final nf = await _pumpKit(
          tester,
          brightness: b,
          size: const Size(360, 740),
          const SingleChildScrollView(
            child: SettingsSection(title: 'Section', icon: Icons.palette_outlined, children: [
              SettingRow(title: 'One'),
              SettingRow(title: 'Two'),
              SettingRow(title: 'Three'),
            ]),
          ),
        );
        expect(visibleCardOutlines(tester), isEmpty, reason: b.name);
        final dividers = tester.widgetList<Divider>(find.byType(Divider)).toList();
        expect(dividers, hasLength(2));
        expect(dividers.map((d) => d.color), everyElement(nf.hairline), reason: b.name);
      }
    });

    testWidgets('a text field keeps its edge and a dialog loses its own', (tester) async {
      final nf = await _pumpKit(tester, const SizedBox(width: 300, child: TextField(key: Key('field'))));
      final theme = Theme.of(tester.element(find.byKey(const Key('field'))));
      expect((theme.inputDecorationTheme.enabledBorder! as OutlineInputBorder).borderSide.color, nf.hairline);
      expect(_shapeSide(theme.dialogTheme.shape).a, 0);
    });
  });

  group('the app', () {
    testWidgets('the Seamless switch in Appearance takes the outlines off the Settings cards', (tester) async {
      final c = await _pumpApp(tester, size: const Size(1440, 900));
      expect(_nf(tester).seamless, isFalse);
      expect(visibleCardOutlines(tester), isNotEmpty, reason: 'the cards have outlines before');
      final toggle = find.byKey(const Key('seamless-surfaces'));
      await tester.ensureVisible(toggle);
      await _settle(tester);
      expect(find.descendant(of: toggle, matching: find.text('Seamless')), findsOneWidget);
      await tester.tap(find.descendant(of: toggle, matching: find.byType(Switch)));
      await _settle(tester);
      expect(c.read(settingsProvider).seamlessSurfaces, isTrue);
      expect(_nf(tester).seamless, isTrue);
      expect(visibleCardOutlines(tester), isEmpty);
      await tester.tap(find.descendant(of: toggle, matching: find.byType(Switch)));
      await _settle(tester);
      expect(c.read(settingsProvider).seamlessSurfaces, isFalse);
      expect(visibleCardOutlines(tester), isNotEmpty);
      await _unmount(tester);
    });

    for (final b in Brightness.values) {
      testWidgets('phone: the tab bar has no edge and the account cells no outline (${b.name})', (tester) async {
        for (final seamless in [false, true]) {
          await _pumpApp(
            tester,
            size: const Size(360, 740),
            route: '/compose',
            settings: {'themeMode': b.name, 'navigationChrome': 'theme', 'seamlessSurfaces': seamless},
          );
          final nf = _nf(tester);
          expect(nf.seamless, seamless);
          expect(find.byType(NavigationBar), findsOneWidget);
          expect(visibleChromeEdges(tester, nf), seamless ? isEmpty : isNotEmpty, reason: 'seamless $seamless');
          expect(visibleCardOutlines(tester), seamless ? isEmpty : anything);

          final cells = find.byWidgetPredicate((w) => w is AnimatedContainer && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('account-cell-box-'));
          expect(cells, findsWidgets);
          for (final cell in tester.widgetList<AnimatedContainer>(cells)) {
            final box = cell.decoration! as BoxDecoration;
            final side = _sideColor(box);
            if (box.color == nf.accentSoft) {
              expect(side, nf.accent.withValues(alpha: 0.45), reason: 'a chosen account stays marked');
            } else if (seamless) {
              expect(side.a, 0, reason: 'an account left out has no outline in seamless mode');
            } else {
              expect(side.a, 1);
            }
          }
          await _unmount(tester);
        }
      });

      testWidgets('desktop: the sidebar has no edge and no card an outline (${b.name})', (tester) async {
        for (final seamless in [false, true]) {
          await _pumpApp(
            tester,
            size: const Size(1440, 900),
            route: '/accounts',
            settings: {'themeMode': b.name, 'navigationChrome': 'theme', 'seamlessSurfaces': seamless},
          );
          final nf = _nf(tester);
          expect(visibleChromeEdges(tester, nf), seamless ? isEmpty : isNotEmpty, reason: 'seamless $seamless');
          expect(visibleCardOutlines(tester), seamless ? isEmpty : isNotEmpty, reason: 'seamless $seamless');
          await _unmount(tester);
        }
      });
    }

    testWidgets('a bottom sheet on a phone draws no outline around its cards', (tester) async {
      await _pumpApp(tester, size: const Size(360, 740), route: '/compose', settings: {'seamlessSurfaces': true});
      final context = tester.element(find.byType(Scaffold).first);
      showModalBottomSheet<void>(
        context: context,
        builder: (_) => const Padding(padding: EdgeInsets.all(Space.lg), child: NfCard(key: Key('in-sheet'), child: Text('In a sheet'))),
      );
      await _settle(tester);
      final sheetTheme = Theme.of(tester.element(find.byKey(const Key('in-sheet')))).bottomSheetTheme;
      expect(sheetTheme.shape, isA<RoundedRectangleBorder>().having((s) => s.side.style, 'side', BorderStyle.none));
      expect(outlineShows(_cardBox(tester, find.byKey(const Key('in-sheet')))), isFalse);
      await _unmount(tester);
    });
  });
}
