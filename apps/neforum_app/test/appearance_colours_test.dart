// 1.4.3: colours. Every Appearance color can be any color, on the color
// wheel: the accent, the navigation bar ("Your own color") and the tint of
// the see-through navigation bar. Each is one named button away, and
// NEFORUM keeps the labels on it readable whatever the color.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/ui/settings/appearance_section.dart';
import 'package:neforum_app/widgets/color_swatch_field.dart';
import 'package:neforum_app/widgets/color_wheel.dart';

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

Future<ProviderContainer> _pumpSettings(WidgetTester tester, {Map<String, Object> settings = const {}, Size size = const Size(1440, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage({'themeMode': 'light', ...settings}))))!;
  await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
  await tester.pump(const Duration(milliseconds: 300));
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  container.read(routerProvider).go('/settings');
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

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settle(tester);
}

/// In the open color dialog: the wheel is there; type [hex] and use it.
Future<void> _useHex(WidgetTester tester, String hex) async {
  expect(find.byType(ColorWheel), findsOneWidget, reason: 'the color wheel is in the dialog');
  await tester.enterText(find.widgetWithText(TextField, 'Hex color'), hex);
  await tester.pump();
  await tester.tap(find.text('Use this color'));
  await _settle(tester);
}

/// Colors that test the readability adjustments at their extremes.
const _colors = [0xFFFFFFFF, 0xFF000000, 0xFFFFFF00, 0xFFFFEE58, 0xFF808080, 0xFF00FF00, 0xFF0A0A0A, 0xFF7D00FF, 0xFF225588, 0xFFF2542D];

void main() {
  group('settings', () {
    test('the navigation bar color and the see-through tint round-trip, travel and clear', () {
      const s = AppSettings(navigationChrome: NavigationChromeStyle.custom, navigationChromeColor: 0xFF225588, navigationChromeTint: 0xFFEEDDCC);
      final back = AppSettings.fromJson(s.toJson());
      expect(back.navigationChrome, NavigationChromeStyle.custom);
      expect(back.navigationChromeColor, 0xFF225588);
      expect(back.navigationChromeTint, 0xFFEEDDCC);
      expect(back.copyWith(clearNavigationChromeTint: true).navigationChromeTint, isNull);
      expect(back.copyWith(navigationChrome: NavigationChromeStyle.brand).navigationChromeColor, 0xFF225588, reason: 'kept for when it is chosen again');
      // Left out while unset, like the custom accent.
      expect(const AppSettings().toJson().keys, isNot(anyOf(contains('navigationChromeColor'), contains('navigationChromeTint'))));
      // Shared with other devices, with their default when left out.
      for (final key in ['navigationChromeColor', 'navigationChromeTint']) {
        expect(kExportableSettings, contains(key));
        expect(kSettingDefaultsLeftOut, containsPair(key, null));
      }
    });

    test('stored colors are made opaque; anything else is no color', () {
      expect(validOpaqueColor(0x00225588), 0xFF225588);
      expect(validOpaqueColor(0xFF225588), 0xFF225588);
      expect(validOpaqueColor('#225588'), isNull);
      expect(validOpaqueColor(null), isNull);
      expect(AppSettings.fromJson({'navigationChromeColor': 'red', 'navigationChromeTint': 1.5}).navigationChromeColor, isNull);
    });
  });

  group('theme', () {
    test('Your own color: the chrome is the color, with readable labels, in both themes', () {
      for (final b in Brightness.values) {
        for (final highContrast in [false, true]) {
          for (final color in _colors) {
            final c = buildTheme(b, AccentChoice.neforum, chrome: NavigationChromeStyle.custom, chromeColor: color, highContrast: highContrast)
                .extension<NfColors>()!;
            final label = '$b ${hexColor(color)} highContrast $highContrast';
            expect(contrastRatio(c.onChrome, c.chrome), greaterThanOrEqualTo(4.5), reason: 'labels: $label');
            expect(contrastRatio(c.onChromeMuted, c.chrome), greaterThanOrEqualTo(4.5), reason: 'unselected labels: $label');
            expect(contrastRatio(c.onChromeAccent, c.chromeAccent), greaterThanOrEqualTo(3), reason: 'current section: $label');
            expect(contrastRatio(c.onChromeUrgent, c.chromeUrgent), greaterThanOrEqualTo(4.5), reason: 'count: $label');
            expect(c.chrome.a, 1);
          }
        }
      }
      // A color that already reads is used exactly, the same in both themes.
      for (final b in Brightness.values) {
        expect(buildTheme(b, AccentChoice.neforum, chrome: NavigationChromeStyle.custom, chromeColor: 0xFF225588).extension<NfColors>()!.chrome,
            const Color(0xFF225588));
      }
      // No color picked yet: NEFORUM purple.
      expect(buildTheme(Brightness.light, AccentChoice.neforum, chrome: NavigationChromeStyle.custom).extension<NfColors>()!.chrome, Brand.night);
    });

    test('the see-through tint keeps the labels readable on it and on every mix with the page', () {
      for (final b in Brightness.values) {
        for (final highContrast in [false, true]) {
          for (final color in _colors) {
            final c = buildTheme(b, AccentChoice.neforum, chrome: NavigationChromeStyle.transparent, chromeTint: color, highContrast: highContrast)
                .extension<NfColors>()!;
            final cover = c.chrome.withValues(alpha: 1);
            expect(c.chrome.a, 0, reason: 'what lies behind shows through');
            for (var mix = 0; mix <= 20; mix++) {
              final shown = Color.lerp(c.bg, cover, mix / 20)!;
              final label = '$b ${hexColor(color)} highContrast $highContrast at ${mix * 5}%';
              expect(contrastRatio(c.onChrome, shown), greaterThanOrEqualTo(4.5), reason: label);
              expect(contrastRatio(c.onChromeMuted, shown), greaterThanOrEqualTo(4.5), reason: label);
            }
          }
        }
      }
      // A tint that already reads is used exactly; none is the surface.
      final light = buildTheme(Brightness.light, AccentChoice.neforum).extension<NfColors>()!;
      expect(light.seeThroughTint(const Color(0xFFFFE0F0)), const Color(0xFFFFE0F0));
      expect(buildTheme(Brightness.light, AccentChoice.neforum, chrome: NavigationChromeStyle.transparent).extension<NfColors>()!.chrome,
          light.surface.withValues(alpha: 0));
      // A dark tint in the light theme is moved toward the surface.
      expect(contrastRatio(light.text, light.seeThroughTint(const Color(0xFF000000))), greaterThanOrEqualTo(4.5));
    });
  });

  group('reachable from Settings > Appearance', () {
    testWidgets('accent: "Custom color…" opens the wheel; the color picked stays one tap away', (tester) async {
      final c = await _pumpSettings(tester);
      expect(find.byTooltip('Choose your own color'), findsNothing, reason: 'no unnamed rainbow swatch any more');
      await _tap(tester, find.byKey(const Key('accent-custom-color')));
      expect(find.text('Your accent color'), findsWidgets);
      await _useHex(tester, '#00838F');
      expect(c.read(settingsProvider).accent, AccentChoice.custom);
      expect(c.read(settingsProvider).customAccentColor, 0xFF00838F);

      // Another accent, then back to the own color with its swatch: no dialog.
      await _tap(tester, find.byTooltip('Ocean'));
      expect(c.read(settingsProvider).accent, AccentChoice.ocean);
      await _tap(tester, find.byTooltip('Your color (#00838F)'));
      expect(find.byType(ColorWheel), findsNothing);
      expect(c.read(settingsProvider).accent, AccentChoice.custom);
      await _unmount(tester);
    });

    testWidgets('navigation bar: "Your own color" asks for a color on the wheel, and can change it', (tester) async {
      final c = await _pumpSettings(tester);
      await _tap(tester, find.text('Your own color'));
      expect(find.text('Navigation bar color'), findsWidgets);
      // Cancelled: the style stays as it was.
      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(c.read(settingsProvider).navigationChrome, NavigationChromeStyle.brand);

      await _tap(tester, find.text('Your own color'));
      await _useHex(tester, '#225588');
      expect(c.read(settingsProvider).navigationChrome, NavigationChromeStyle.custom);
      expect(c.read(settingsProvider).navigationChromeColor, 0xFF225588);
      expect(_nf(tester).chrome, const Color(0xFF225588));

      // The row under the choice changes it.
      expect(find.text('#225588'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('navigation-custom-color')));
      expect(find.byKey(const Key('chrome-preview')), findsOneWidget, reason: 'a preview of the bar and its labels');
      await _useHex(tester, '#FFEE58');
      expect(c.read(settingsProvider).navigationChromeColor, 0xFFFFEE58);
      expect(contrastRatio(_nf(tester).onChrome, _nf(tester).chrome), greaterThanOrEqualTo(4.5));
      await _unmount(tester);
    });

    testWidgets('see-through: the tint is picked on the wheel and goes back to the page color', (tester) async {
      final c = await _pumpSettings(tester, settings: {'navigationChrome': 'transparent'});
      expect(find.text('Page color'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('see-through-custom-color')));
      expect(find.text('See-through tint'), findsWidgets);
      expect(find.byKey(const Key('color-choice-reset')), findsNothing, reason: 'nothing to reset yet');
      await _useHex(tester, '#FFE0F0');
      expect(c.read(settingsProvider).navigationChromeTint, 0xFFFFE0F0);
      expect(_nf(tester).chrome.withValues(alpha: 1), const Color(0xFFFFE0F0));
      expect(find.text('#FFE0F0'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('see-through-custom-color')));
      await tester.tap(find.byKey(const Key('color-choice-reset')));
      await _settle(tester);
      expect(c.read(settingsProvider).navigationChromeTint, isNull);
      expect(_nf(tester).chrome.withValues(alpha: 1), _nf(tester).surface);
      await _unmount(tester);
    });

    testWidgets('card colours: the swatch field names its way to the wheel', (tester) async {
      int? picked;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(body: ColorSwatchField(value: 0xFFFFFFFF, label: 'Tint', onChanged: (c) => picked = c)),
      ));
      await tester.tap(find.text('Custom colour'));
      await tester.pumpAndSettle();
      expect(find.byType(ColorWheel), findsOneWidget);
      await tester.tap(find.text('Use this colour'));
      await tester.pumpAndSettle();
      expect(picked, 0xFFFFFFFF);
      // The swatch in use carries a check, not only a ring.
      expect(find.byKey(const Key('swatch-check')), findsOneWidget);
    });
  });
}
