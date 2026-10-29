// Settings > Appearance: square corners, navigation chrome styles, the custom
// accent, density, text size on phones and compact previews.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/brand/neforum_logo.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/text_scale.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/accounts/account_card.dart';
import 'package:neforum_app/ui/activity/target_chip.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/ui/settings/appearance_section.dart';
import 'package:neforum_app/widgets/badges.dart';
import 'package:neforum_app/widgets/layout.dart';
import 'package:neforum_app/widgets/surfaces.dart';

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

/// Ends the test cleanly: no timers left from the app.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

NfColors _nf(WidgetTester tester) => Theme.of(tester.element(find.byType(Scaffold).first)).extension<NfColors>()!;

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
  setUpAll(_loadFonts);
  tearDown(() => Radii.square = false);

  group('square corners', () {
    test('every radius is 0 with the square style', () {
      Radii.square = false;
      expect(Radii.rMd, const BorderRadius.all(Radius.circular(14)));
      expect(Radii.circular(8), BorderRadius.circular(8));
      expect(Radii.circleShape, BoxShape.circle);
      Radii.square = true;
      for (final r in [Radii.rXs, Radii.rSm, Radii.rMd, Radii.rLg, Radii.rXl, Radii.rPill, Radii.circular(12)]) {
        expect(r, BorderRadius.zero);
      }
      expect([Radii.xs, Radii.sm, Radii.md, Radii.lg, Radii.xl, Radii.pill, Radii.corner(9)], everyElement(0));
      expect(Radii.circleShape, BoxShape.rectangle);
      expect(Radii.circleBorder, isA<RoundedRectangleBorder>());
      expect(Radii.stadium, isA<RoundedRectangleBorder>());
    });

    test('the theme gives every component square shapes', () {
      final t = buildTheme(Brightness.light, AccentChoice.neforum, corners: CornerStyle.square);
      expect(Radii.square, isTrue);
      BorderRadiusGeometry radius(ShapeBorder? s) => (s! as RoundedRectangleBorder).borderRadius;
      final shapes = <String, ShapeBorder?>{
        'card': t.cardTheme.shape,
        'filled button': t.filledButtonTheme.style!.shape!.resolve({}),
        'outlined button': t.outlinedButtonTheme.style!.shape!.resolve({}),
        'text button': t.textButtonTheme.style!.shape!.resolve({}),
        'icon button': t.iconButtonTheme.style!.shape!.resolve({}),
        'chip': t.chipTheme.shape,
        'checkbox': t.checkboxTheme.shape,
        'segmented button': t.segmentedButtonTheme.style!.shape!.resolve({}),
        'list tile': t.listTileTheme.shape,
        'dialog': t.dialogTheme.shape,
        'bottom sheet': t.bottomSheetTheme.shape,
        'snack bar': t.snackBarTheme.shape,
        'popup menu': t.popupMenuTheme.shape,
        'menu': t.menuTheme.style!.shape!.resolve({}),
        'navigation indicator': t.navigationBarTheme.indicatorShape,
        'date picker': t.datePickerTheme.shape,
        'date picker day': t.datePickerTheme.dayShape!.resolve({}),
        'time picker': t.timePickerTheme.shape,
      };
      for (final e in shapes.entries) {
        expect(radius(e.value), BorderRadius.zero, reason: e.key);
      }
      expect((t.tooltipTheme.decoration! as BoxDecoration).borderRadius, BorderRadius.zero);
      expect(t.inputDecorationTheme.border, isA<OutlineInputBorder>().having((b) => b.borderRadius, 'radius', BorderRadius.zero));
      expect(t.scrollbarTheme.radius, Radius.zero);

      final rounded = buildTheme(Brightness.light, AccentChoice.neforum);
      expect(Radii.square, isFalse);
      expect(radius(rounded.cardTheme.shape), isNot(BorderRadius.zero));
      expect(rounded.navigationBarTheme.indicatorShape, isA<StadiumBorder>());
    });

    testWidgets('choosing Square in Settings squares the cards', (tester) async {
      final c = await _pumpApp(tester, size: const Size(1440, 900));
      expect(Radii.square, isFalse);
      await tester.tap(find.text('Square'));
      await _settle(tester);
      expect(c.read(settingsProvider).cornerStyle, CornerStyle.square);
      expect(Radii.square, isTrue);
      BorderRadiusGeometry? cardRadius() =>
          (tester.widget<AnimatedContainer>(find.descendant(of: find.byType(NfCard).first, matching: find.byType(AnimatedContainer)).first).decoration as BoxDecoration?)?.borderRadius;
      expect(cardRadius(), BorderRadius.zero);
      await tester.tap(find.text('Rounded'));
      await _settle(tester);
      expect(cardRadius(), Radii.rLg);
      expect(Radii.rLg, isNot(BorderRadius.zero));
      await _unmount(tester);
    });
  });

  group('navigation chrome', () {
    test('Match the theme uses the page colors and never yellow; Your accent uses the accent', () {
      for (final b in Brightness.values) {
        final brand = buildTheme(b, AccentChoice.neforum).extension<NfColors>()!;
        expect(brand.chromeAccent, Brand.yellow);
        expect(brand.chromeBorder.a, 0);

        final themed = buildTheme(b, AccentChoice.neforum, chrome: NavigationChromeStyle.theme).extension<NfColors>()!;
        expect(themed.chrome, themed.surface);
        expect(themed.onChrome, themed.text);
        expect(themed.chromeBorder, themed.border);
        expect([themed.chromeAccent, themed.chromeSelected, themed.chromeUrgent], everyElement(isNot(Brand.yellow)));
        expect(themed.chromeUrgent, themed.warning, reason: 'counts that need the user: amber, like the "Needs you" pill');

        final accent = buildTheme(b, AccentChoice.ocean, chrome: NavigationChromeStyle.accent).extension<NfColors>()!;
        expect(accent.chrome, b == Brightness.light ? AccentChoice.ocean.light : isNot(Brand.night));
      }
    });

    test('content on the chrome stays readable for every style, theme and accent', () {
      final accents = [for (final a in AccentChoice.presets) (a, null), (AccentChoice.custom, 0xFFFFEE58), (AccentChoice.custom, 0xFF0A0A0A)];
      for (final style in NavigationChromeStyle.values) {
        for (final b in Brightness.values) {
          for (final (accent, custom) in accents) {
            final c = buildTheme(b, accent, customAccent: custom, chrome: style).extension<NfColors>()!;
            final label = '$style $b $accent $custom';
            expect(contrastRatio(c.onChrome, c.chrome), greaterThanOrEqualTo(4.5), reason: 'labels: $label');
            expect(contrastRatio(c.onChromeMuted, c.chrome), greaterThanOrEqualTo(4.5), reason: 'unselected labels and icons: $label');
            expect(contrastRatio(c.onChromeAccent, c.chromeAccent), greaterThanOrEqualTo(3), reason: 'current section icon: $label');
            expect(contrastRatio(c.chromeSelected, c.chromeRaised), greaterThanOrEqualTo(3), reason: 'sidebar selection: $label');
            expect(contrastRatio(c.chromeUrgent, c.chrome), greaterThanOrEqualTo(3), reason: 'badge that needs the user: $label');
            expect(contrastRatio(c.onChromeUrgent, c.chromeUrgent), greaterThanOrEqualTo(4.5), reason: 'count on that badge: $label');
          }
        }
      }
    });

    test('unselected destinations on the accent chrome stay fainter than the selected one', () {
      for (final b in Brightness.values) {
        for (final accent in AccentChoice.presets) {
          final c = buildTheme(b, accent, chrome: NavigationChromeStyle.accent).extension<NfColors>()!;
          expect(contrastRatio(c.onChromeMuted, c.chrome), lessThan(contrastRatio(c.onChrome, c.chrome)), reason: '$b $accent');
        }
      }
      // An accent on which the faded content already passes keeps it as it was.
      final purple = buildTheme(Brightness.dark, AccentChoice.neforum, chrome: NavigationChromeStyle.accent).extension<NfColors>()!;
      expect(purple.onChromeMuted, Color.alphaBlend(purple.onChrome.withValues(alpha: 0.74), purple.chrome));
    });

    // The see-through style has its own tests: test/see_through_navigation_test.dart.
    for (final style in NavigationChromeStyle.values.where((s) => s != NavigationChromeStyle.transparent)) {
      testWidgets('${style.name}: sidebar, rail and tab bar', (tester) async {
        await _pumpApp(tester, size: const Size(1440, 900), settings: {'navigationChrome': style.name}, route: '/queue');
        final nf = _nf(tester);
        final expected = switch (style) {
          NavigationChromeStyle.brand => Brand.night,
          NavigationChromeStyle.theme => nf.surface,
          NavigationChromeStyle.accent => AccentChoice.neforum.light,
          NavigationChromeStyle.transparent => throw StateError('tested elsewhere'),
        };
        expect(nf.chrome, expected);
        BoxDecoration chromeBox(double width) => tester
            .widgetList<Container>(find.byType(Container))
            .firstWhere((c) => c.constraints == BoxConstraints.tightFor(width: width))
            .decoration! as BoxDecoration;
        final sidebar = chromeBox(264);
        expect(sidebar.color, expected);
        expect(sidebar.border != null, style == NavigationChromeStyle.theme, reason: 'a hairline only on a chrome in the page colors');
        // The demo workspace has a post that needs the user: Activity's count.
        final activityCount = find.descendant(
          of: find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Activity'),
          matching: find.byWidgetPredicate((w) => w is Container && w.constraints == const BoxConstraints(minWidth: 22)),
        );
        expect((tester.widget<Container>(activityCount).decoration! as BoxDecoration).color, nf.chromeUrgent);

        tester.view.physicalSize = const Size(1000, 800);
        await _settle(tester);
        expect(chromeBox(88).color, expected);

        tester.view.physicalSize = const Size(390, 800);
        await _settle(tester);
        expect(find.byType(NavigationBar), findsOneWidget);
        final barBox = find.ancestor(of: find.byType(NavigationBar), matching: find.byType(DecoratedBox)).first;
        final bar = tester.widget<DecoratedBox>(barBox).decoration as BoxDecoration;
        expect(bar.color, expected);
        expect(bar.border != null, style == NavigationChromeStyle.theme, reason: 'a hairline only on a chrome in the page colors');
        // The bar paints an opaque background over its whole area, so it has
        // to start below the hairline or it hides it.
        final line = bar.border?.top.width ?? 0;
        expect(tester.getTopLeft(find.byType(NavigationBar)).dy, tester.getTopLeft(barBox).dy + line);
        final badges = tester.widgetList<Badge>(find.descendant(of: find.byType(NavigationBar), matching: find.byType(Badge)));
        expect(badges.map((b) => b.backgroundColor), contains(nf.chromeUrgent));
        await _unmount(tester);
      });
    }
  });

  group('custom accent', () {
    test('shades keep text readable whatever the color', () {
      for (final color in [0xFFFFFF00, 0xFFFFFFFF, 0xFF000000, 0xFF00838F, 0xFF7CB342, 0x337D00FF]) {
        final s = accentShadesOf(Color(color));
        expect(contrastRatio(Colors.white, s.light), greaterThanOrEqualTo(4.5), reason: hexColor(color));
        expect(contrastRatio(s.dark, NfColors.darkSurface), greaterThanOrEqualTo(4.5), reason: hexColor(color));
        expect(s.light.a, 1);
      }
      // A color that already passes is used as it is.
      expect(accentShadesOf(const Color(0xFF5B3CC4)).light, const Color(0xFF5B3CC4));
    });

    test('the custom choice uses the stored color, the brand purple until one is chosen', () {
      expect(AccentChoice.presets, isNot(contains(AccentChoice.custom)));
      expect(AccentChoice.custom.shades(null).light, Brand.purple);
      expect(AccentChoice.custom.shades(0xFF00838F), accentShadesOf(const Color(0xFF00838F)));
      expect(AccentChoice.ocean.shades(0xFF00838F).light, AccentChoice.ocean.light);
      final nf = buildTheme(Brightness.light, AccentChoice.custom, customAccent: 0xFF00838F).extension<NfColors>()!;
      expect(nf.accentFill, accentShadesOf(const Color(0xFF00838F)).light);
      expect(AppSettings.fromJson(const AppSettings(accent: AccentChoice.custom).toJson()).accent, AccentChoice.custom);
    });

    test('hex codes', () {
      expect(parseHexColor('#00838F'), 0xFF00838F);
      expect(parseHexColor('00838f'), 0xFF00838F);
      expect(parseHexColor(' #f0a '), 0xFFFF00AA);
      expect(parseHexColor('#12345'), isNull);
      expect(parseHexColor('purple'), isNull);
      expect(hexColor(0xFF00838F), '#00838F');
      expect(hexColor(0x0000000A), '#00000A');
    });

    testWidgets('picked in Settings from a hex code', (tester) async {
      final c = await _pumpApp(tester, size: const Size(1440, 900));
      await tester.tap(find.byTooltip('Choose your own color'));
      await _settle(tester);
      expect(find.text('Your accent color'), findsWidgets);
      await tester.enterText(find.widgetWithText(TextField, 'Hex color'), '#12');
      await tester.pump();
      expect(find.text('Use six hex digits, like #7D00FF.'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Hex color'), '#00838F');
      await tester.pump();
      await tester.tap(find.text('Use this color'));
      await _settle(tester);
      expect(c.read(settingsProvider).accent, AccentChoice.custom);
      expect(c.read(settingsProvider).customAccentColor, 0xFF00838F);
      expect(_nf(tester).accentFill, accentShadesOf(const Color(0xFF00838F)).light);
      await _unmount(tester);
    });
  });

  group('density and text size', () {
    test('compact density tightens the theme', () {
      final compact = buildTheme(Brightness.light, AccentChoice.neforum, density: InterfaceDensity.compact);
      final comfortable = buildTheme(Brightness.light, AccentChoice.neforum);
      expect(compact.visualDensity, VisualDensity.compact);
      expect(comfortable.visualDensity, VisualDensity.standard);
      expect(compact.navigationBarTheme.height, lessThan(comfortable.navigationBarTheme.height!));
      expect(compact.inputDecorationTheme.isDense, isTrue);
    });

    testWidgets('choosing Compact in Settings', (tester) async {
      final c = await _pumpApp(tester, size: const Size(1440, 900));
      await tester.tap(find.text('Compact'));
      await _settle(tester);
      expect(c.read(settingsProvider).interfaceDensity, InterfaceDensity.compact);
      expect(Theme.of(tester.element(find.text('Make NEFORUM yours'))).visualDensity, VisualDensity.compact);
      await _unmount(tester);
    });

    test('the text scaler multiplies the system scaling', () {
      const scaler = CombinedTextScaler(TextScaler.linear(1.2), 1.25);
      expect(scaler.scale(10), closeTo(15, 1e-9));
      expect(scaler, const CombinedTextScaler(TextScaler.linear(1.2), 1.25));
      expect(validTextScale(4), 1.5);
      expect(validTextScale('x'), 1);
    });

    testWidgets('phones and tablets use the text size from Settings', (tester) async {
      // flutter_test runs as Android: a phone.
      final c = await _pumpApp(tester, size: const Size(390, 844), settings: {'mobileTextScale': 1.15});
      double scaled() => MediaQuery.textScalerOf(tester.element(find.text('Make NEFORUM yours'))).scale(10);
      expect(scaled(), closeTo(11.5, 1e-9));
      expect(find.text('Text size'), findsOneWidget);
      expect(find.text('115%'), findsOneWidget);
      await tester.ensureVisible(find.text('Text size'));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Reset'));
      await _settle(tester);
      expect(c.read(settingsProvider).mobileTextScale, 1);
      expect(scaled(), closeTo(10, 1e-9));
      await _unmount(tester);
    });

    testWidgets('the text size widget keeps the same tree at every scale', (tester) async {
      Widget app(double scale) => MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.1)),
            child: TextScale(scale: scale, child: const _Probe()),
          );
      await tester.pumpWidget(app(1));
      final state = tester.state(find.byType(_Probe));
      expect(MediaQuery.textScalerOf(tester.element(find.byType(_Probe))).scale(10), closeTo(11, 1e-9));
      await tester.pumpWidget(app(1.5));
      expect(tester.state(find.byType(_Probe)), same(state));
      expect(MediaQuery.textScalerOf(tester.element(find.byType(_Probe))).scale(10), closeTo(16.5, 1e-9));
    });
  });

  group('largest text size', () {
    /// The phone's own font size setting, under NEFORUM's text size.
    void systemTextScale(WidgetTester tester, double factor) {
      tester.platformDispatcher.textScaleFactorTestValue = factor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    final tagline = find.text('One message, every platform');

    testWidgets('the wordmark shortens its tagline only when it does not fit', (tester) async {
      Future<RenderParagraph> pump(double scale) async {
        await tester.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Material(
            child: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              // The width the sidebar leaves it.
              child: const Align(alignment: Alignment.topLeft, child: SizedBox(width: 216, child: NeforumWordmark(size: 32, showTagline: true))),
            ),
          ),
        ));
        return tester.renderObject<RenderParagraph>(tagline);
      }

      expect((await pump(1)).didExceedMaxLines, isFalse);
      expect((await pump(1.5)).didExceedMaxLines, isTrue);
      expect(tester.getRect(tagline).right, lessThanOrEqualTo(216));
    });

    testWidgets('the wordmark stays inside the tablet sidebar', (tester) async {
      await _pumpApp(tester, size: const Size(1280, 800), settings: {'mobileTextScale': 1.5}, route: '/queue');
      expect(tagline, findsOneWidget);
      final wordmark = tester.getRect(find.byType(NeforumWordmark));
      expect(tester.getRect(tagline).right, lessThanOrEqualTo(wordmark.right));
      // The sidebar is 264 wide, with 16 + 8 of padding on each side.
      expect(wordmark.right, lessThanOrEqualTo(264 - 24));
      await _unmount(tester);
    });

    testWidgets('the wordmark stays inside the About card on a phone', (tester) async {
      await _pumpApp(tester, size: const Size(360, 780), settings: {'mobileTextScale': 1.5});
      await tester.ensureVisible(tagline);
      await _settle(tester);
      expect(tester.getRect(tagline).right, lessThanOrEqualTo(tester.getRect(find.byType(NeforumWordmark)).right));
      await _unmount(tester);
    });

    testWidgets('account cards keep their badges clear of the menu on a 360-wide phone', (tester) async {
      systemTextScale(tester, 1.3);
      final c = await _pumpApp(tester, size: const Size(360, 780), settings: {'mobileTextScale': 1.5}, route: '/accounts');
      final youtube = c.read(accountListProvider).firstWhere((a) => a.platformId == 'youtube_posts');
      await tester.runAsync(() => c.read(servicesProvider).accounts.upsert(youtube.copyWith(enabled: false)));
      await _settle(tester);
      final card = find.ancestor(of: find.text('Off'), matching: find.byType(AccountCard));
      expect(card, findsOneWidget);
      final menu = tester.getRect(find.descendant(of: card, matching: find.byTooltip('More')));
      for (final pill in [find.text('Off'), find.descendant(of: card, matching: find.text(tierShortLabel(youtube.tier)))]) {
        expect(tester.getRect(pill).right, lessThanOrEqualTo(menu.left));
      }
      await _unmount(tester);
    });

    testWidgets('target chips fit an Activity card on a 360-wide phone', (tester) async {
      systemTextScale(tester, 1.3);
      await _pumpApp(tester, size: const Size(360, 780), settings: {'mobileTextScale': 1.5}, route: '/activity');
      expect(find.byType(TargetChip), findsWidgets);
      for (final chip in find.byType(TargetChip).evaluate()) {
        expect(tester.getRect(find.byWidget(chip.widget)).right, lessThanOrEqualTo(360 - 16));
      }
      await _unmount(tester);
    });
  });

  group('compact previews', () {
    testWidgets('ScaledDown draws its child smaller and taps still land', (tester) async {
      var taps = 0;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            child: ScaledDown(
              scale: 0.8,
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => taps++, child: const SizedBox(key: Key('child'), height: 100)),
            ),
          ),
        ),
      ));
      expect(tester.getSize(find.byType(ScaledDown)), const Size(400, 80));
      expect(tester.getSize(find.byKey(const Key('child'))), const Size(500, 100), reason: 'laid out 500 wide');
      expect(tester.getRect(find.byKey(const Key('child'))), const Rect.fromLTWH(0, 0, 400, 80), reason: 'drawn at 80%');
      await tester.tapAt(const Offset(390, 70));
      expect(taps, 1);
    });

    for (final compact in [false, true]) {
      testWidgets('the composer previews ${compact ? 'shrink' : 'stay full size'}', (tester) async {
        final c = await _pumpApp(tester, size: const Size(1440, 900), settings: {'compactPreviews': compact}, route: '/compose');
        c.read(composerProvider.notifier).selectAccounts(c.read(accountListProvider).map((a) => a.id));
        await _settle(tester);
        expect(find.byType(ScaledDown), compact ? findsWidgets : findsNothing);
        await _unmount(tester);
      });
    }

    testWidgets('the switch in Settings changes the setting', (tester) async {
      final c = await _pumpApp(tester, size: const Size(1440, 900));
      await tester.ensureVisible(find.text('Compact previews'));
      await tester.pump();
      await tester.tap(find.text('Compact previews'));
      await _settle(tester);
      expect(c.read(settingsProvider).compactPreviews, isTrue);
      await _unmount(tester);
    });
  });

  testWidgets('the navigation bar choice is a setting row', (tester) async {
    final c = await _pumpApp(tester, size: const Size(1440, 900));
    await tester.tap(find.text('Match the theme'));
    await _settle(tester);
    expect(c.read(settingsProvider).navigationChrome, NavigationChromeStyle.theme);
    expect(_nf(tester).chrome, _nf(tester).surface);
    expect(find.byType(AppearanceSettingsSection), findsOneWidget);
    await _unmount(tester);
  });
}

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const SizedBox();
}
