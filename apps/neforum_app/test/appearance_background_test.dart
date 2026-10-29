// Settings > Appearance > Background (a picture behind the pages, blurred
// and dimmed, readable over anything), and following the system's high
// contrast and reduce motion settings.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/brand/neforum_logo.dart';
import 'package:neforum_app/platform/background_images.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/backdrop.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/ui/shell/app_backdrop.dart';

class _MemoryStorage implements AppStorage {
  _MemoryStorage(Map<String, Object> settings, {this.dataDir}) : _json = {'settings.json': settings};
  final Map<String, Object> _json;
  @override
  final String? dataDir;
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

// No bundled fonts here, on purpose: flutter_test's own font draws every
// glyph as a solid box, so the contrast guideline reads the text's real color
// (with anti-aliased letters it often reads a blend and reports nonsense).

/// [textContrastGuideline], except text in the colors that are below AA on
/// the plain page already, by design: [NfColors.textFaint] (hints, counters,
/// disabled rows, about 3.4:1) and, in the light theme, the status colors on
/// their tints (the pills, about 3:1). No picture can be held to more than
/// the page itself. The high contrast theme makes them pass, and there the
/// full guideline runs.
class _ContrastExceptFaintColors extends MinimumTextContrastGuideline {
  _ContrastExceptFaintColors(NfColors nf) : faint = {nf.textFaint, if (!nf.isDark) ...[nf.success, nf.warning, nf.danger, nf.info]};

  final Set<Color> faint;

  @override
  bool shouldSkipNode(SemanticsData data) {
    if (super.shouldSkipNode(data)) return true;
    final label = data.label.isEmpty ? data.value : data.label;
    final texts = find.text(label).evaluate().map((e) => e.widget).whereType<Text>().toList();
    return texts.isNotEmpty && texts.every((t) => faint.contains(t.style?.color));
  }
}

/// Generated test pictures: nearly white, nearly black, and random colors
/// in small blocks (the worst case for text over a picture).
///
/// The busy one is window-sized, drawn 1:1, its blocks 8 pixels wide: the
/// contrast guideline takes the most frequent colors around each text, and
/// over single-pixel noise (every color unique) that would be a blurred
/// letter edge rather than the picture.
enum _Picture {
  bright,
  dark,
  busy;

  Uint8List encode({int? width, int? height}) {
    final w = width ?? (this == _Picture.busy ? 1440 : 480);
    final h = height ?? (this == _Picture.busy ? 900 : 300);
    final image = img.Image(width: w, height: h);
    final random = math.Random(7);
    final blocks = [for (var i = 0; i < (w ~/ 8 + 1) * (h ~/ 8 + 1); i++) (random.nextInt(256), random.nextInt(256), random.nextInt(256))];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        switch (this) {
          case _Picture.bright:
            image.setPixelRgb(x, y, 255, 255 - (x * 12 ~/ w), 235 + (y * 20 ~/ h));
          case _Picture.dark:
            image.setPixelRgb(x, y, 4 + (x * 10 ~/ w), 0, 12 + (y * 14 ~/ h));
          case _Picture.busy:
            final (r, g, b) = blocks[(y ~/ 8) * (w ~/ 8 + 1) + x ~/ 8];
            image.setPixelRgb(x, y, r, g, b);
        }
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }
}

late Directory _temp;

/// [picture] written as a background file, under a data folder in [_temp].
String _pictureFile(_Picture picture) {
  final folder = Directory('${_temp.path}${Platform.pathSeparator}data${Platform.pathSeparator}appearance')..createSync(recursive: true);
  final file = File('${folder.path}${Platform.pathSeparator}${picture.name}.png');
  if (!file.existsSync()) file.writeAsBytesSync(picture.encode());
  return file.path;
}

/// NEFORUM's demo workspace at [size] with [settings], on [route]. A
/// background picture in the settings is decoded first, outside the fake
/// clock.
Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  required Size size,
  Map<String, Object> settings = const {},
  String route = '/settings',
  String? dataDir,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final picture = settings['backgroundImagePath'] as String?;
  if (picture != null) {
    await tester.runAsync(() => AppBackdrop.precache(
          picture,
          blur: validBackgroundBlur(settings['backgroundBlur']),
          physicalSize: size,
          devicePixelRatio: 1,
        ));
  }
  final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage({'themeMode': 'light', ...settings}, dataDir: dataDir))))!;
  await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
  await tester.pump(const Duration(milliseconds: 300));
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  container.read(routerProvider).go(route);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return container;
}

/// Lets real file work started under the fake clock finish.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

NfColors _nf(WidgetTester tester) => Theme.of(tester.element(find.byType(Scaffold).last)).extension<NfColors>()!;

/// The scrim drawn over the picture.
ColoredBox _scrim(WidgetTester tester) => tester.widget<ColoredBox>(
      find.descendant(of: find.byType(AppBackdrop), matching: find.byType(ColoredBox)).at(1),
    );

void main() {
  setUpAll(() => _temp = Directory.systemTemp.createTempSync('neforum_background_test'));
  tearDownAll(() => _temp.deleteSync(recursive: true));

  group('settings', () {
    test('the background round-trips through settings.json', () {
      const s = AppSettings(backgroundImagePath: '/data/neforum/appearance/background-1.png', backgroundBlur: 12, backgroundDim: 0.65);
      final back = AppSettings.fromJson(s.toJson());
      expect(back.backgroundImagePath, s.backgroundImagePath);
      expect(back.backgroundBlur, 12);
      expect(back.backgroundDim, 0.65);
      expect(back.copyWith(clearBackgroundImage: true).backgroundImagePath, isNull);
      expect(back.copyWith(backgroundBlur: 3).backgroundImagePath, s.backgroundImagePath, reason: 'other changes keep the picture');
    });

    test('defaults write nothing, and stored values are kept in range', () {
      final json = const AppSettings().toJson();
      expect(json.keys, isNot(anyOf(contains('backgroundImagePath'), contains('backgroundBlur'), contains('backgroundDim'))));
      final odd = AppSettings.fromJson({'backgroundBlur': 400, 'backgroundDim': -2});
      expect(odd.backgroundBlur, kMaxBackgroundBlur);
      expect(odd.backgroundDim, 0);
      final junk = AppSettings.fromJson({'backgroundBlur': 'lots', 'backgroundDim': double.nan, 'backgroundImagePath': null});
      expect(junk.backgroundBlur, 0);
      expect(junk.backgroundDim, kDefaultBackgroundDim);
      expect(junk.backgroundImagePath, isNull);
    });

    test('a settings.json from 1.2 loads unchanged, with no background', () {
      final legacy = <String, dynamic>{
        'themeMode': 'dark',
        'accent': 'custom',
        'customAccentColor': 0xFF00838F,
        'cornerStyle': 'square',
        'navigationChrome': 'theme',
        'interfaceDensity': 'compact',
        'uiZoom': 1.25,
        'compactPreviews': true,
        'defaultTargetIds': ['a', 'b'],
        'onboarded': true,
      };
      final s = AppSettings.fromJson(legacy);
      expect(s.themeMode, ThemeMode.dark);
      expect(s.accent, AccentChoice.custom);
      expect(s.customAccentColor, 0xFF00838F);
      expect(s.cornerStyle, CornerStyle.square);
      expect(s.uiZoom, 1.25);
      expect(s.defaultTargetIds, ['a', 'b']);
      expect(s.backgroundImagePath, isNull);
      expect(s.backgroundBlur, 0);
      expect(s.backgroundDim, kDefaultBackgroundDim);
      // Written back, it gains nothing it did not have.
      expect(s.toJson()..removeWhere((k, _) => !legacy.containsKey(k)), legacy);
    });

    test('the background is device-only: never moved to another device or synced', () {
      const s = AppSettings(backgroundImagePath: '/somewhere/background.png', backgroundBlur: 8, backgroundDim: 0.8);
      for (final key in ['backgroundImagePath', 'backgroundBlur', 'backgroundDim']) {
        expect(kExportableSettings, isNot(contains(key)), reason: 'cloud sync and Move use this allowlist');
        expect(exportableSettings(s).containsKey(key), isFalse);
      }
      final imported = withImportedSettings(const AppSettings(), {'backgroundImagePath': '/other/device.png', 'backgroundBlur': 20, 'backgroundDim': 1});
      expect(imported.backgroundImagePath, isNull);
      expect(imported.backgroundBlur, 0);
      expect(imported.backgroundDim, kDefaultBackgroundDim);
      // And a backup coming in keeps this device's own background.
      expect(withImportedSettings(s, const {'themeMode': 'dark'}).backgroundImagePath, s.backgroundImagePath);
    });
  });

  group('legibility', () {
    final light = NfColors.light(AccentChoice.neforum);
    final dark = NfColors.dark(AccentChoice.neforum);

    Uint8List samples(List<Color> colors) => Uint8List.fromList([
          for (final c in colors) ...[(c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round(), 255],
        ]);

    Color blend(Color scrim, double opacity, Color under) => Color.alphaBlend(scrim.withValues(alpha: opacity), under);

    test('the scrim is just strong enough for every text color on the worst part of the picture', () {
      for (final (nf, worst) in [(dark, Colors.white), (light, Colors.black), (dark, const Color(0xFFFFFF00)), (light, const Color(0xFF2000AA))]) {
        final opacity = legibleScrimOpacity(samples([worst]), nf.bg, [nf.text, nf.textMuted, nf.accent]);
        expect(opacity, greaterThan(0));
        for (final text in [nf.text, nf.textMuted]) {
          expect(contrastRatio(text, blend(nf.bg, opacity, worst)), greaterThanOrEqualTo(4.45), reason: '$worst under ${nf.isDark}');
          expect(contrastRatio(text, blend(nf.bg, opacity - 0.05, worst)), lessThan(contrastRatio(text, blend(nf.bg, opacity, worst))));
        }
      }
    });

    test('a picture already like the page needs no scrim; high contrast needs more', () {
      expect(legibleScrimOpacity(samples([dark.bg, dark.bg]), dark.bg, [dark.text, dark.textMuted]), 0);
      final gray = samples([const Color(0xFF777777)]);
      final aa = legibleScrimOpacity(gray, dark.bg, [dark.text, dark.textMuted]);
      final aaa = legibleScrimOpacity(gray, dark.bg, [dark.text, dark.textMuted], ratio: 7);
      expect(aaa, greaterThan(aa));
    });

    test('a few stray pixels do not darken the whole picture; many do', () {
      final mostlyDark = [for (var i = 0; i < 999; i++) dark.bg, Colors.white];
      expect(legibleScrimOpacity(samples(mostlyDark), dark.bg, [dark.textMuted]), 0);
      final speckled = [for (var i = 0; i < 900; i++) dark.bg, for (var i = 0; i < 100; i++) Colors.white];
      expect(legibleScrimOpacity(samples(speckled), dark.bg, [dark.textMuted]), greaterThan(0.5));
    });

    test('accent text right on the page reads wherever muted text reads', () {
      for (final b in Brightness.values) {
        for (final accent in [...AccentChoice.presets, AccentChoice.custom]) {
          final nf = b == Brightness.dark ? NfColors.dark(accent, customAccent: 0xFF101010) : NfColors.light(accent, customAccent: 0xFFFFEE58);
          final shade = legibleOverBackdrop(nf.accent, nf);
          // The worst page a scrim allows: muted text exactly at 4.5:1.
          for (final under in [Colors.white, Colors.black, const Color(0xFF808080)]) {
            final opacity = legibleScrimOpacity(samples([under]), nf.bg, [nf.textMuted]);
            final page = blend(nf.bg, opacity, under);
            expect(contrastRatio(shade, page), greaterThanOrEqualTo(contrastRatio(nf.textMuted, page) - 0.05), reason: '$b $accent $under');
          }
        }
        // An accent that already stands out is left alone.
        final light = NfColors.light(AccentChoice.neforum);
        if (b == Brightness.light) expect(legibleOverBackdrop(light.text, light), light.text);
      }
    });

    test('a weak accent never asks for more than covering the picture', () {
      final weak = NfColors.light(AccentChoice.custom, customAccent: 0xFFFFEE58);
      final opacity = legibleScrimOpacity(samples([Colors.black]), weak.bg, [weak.text, weak.textMuted, weak.accent]);
      expect(opacity, lessThanOrEqualTo(1));
    });
  });

  group('preparing the picture', () {
    testWidgets('decoded at window size, blurred once, sampled', (tester) async {
      final bytes = _Picture.busy.encode(width: 1600, height: 1000);
      final sharp = (await tester.runAsync(() => prepareBackdrop(bytes, target: const Size(800, 600), blurSigma: 0)))!;
      // Covers 800 x 600 without decoding the full 1600 x 1000.
      expect(sharp.image.width, 960);
      expect(sharp.image.height, 600);
      expect(sharp.samples.length, 160 * 100 * 4);
      final blurred = (await tester.runAsync(() => prepareBackdrop(bytes, target: const Size(800, 600), blurSigma: 40)))!;
      expect(blurred.image.width, 480, reason: 'a strong blur decodes at half size');
      // Blurred noise is far calmer: the samples spread much less.
      double spread(Uint8List s) {
        var low = 255, high = 0;
        for (var i = 0; i < s.length; i += 4) {
          low = math.min(low, s[i]);
          high = math.max(high, s[i]);
        }
        return (high - low).toDouble();
      }

      expect(spread(blurred.samples), lessThan(spread(sharp.samples) / 2));
      // A small picture is never enlarged in memory.
      final small = (await tester.runAsync(() => prepareBackdrop(_Picture.dark.encode(width: 200, height: 100), target: const Size(800, 600), blurSigma: 0)))!;
      expect(small.image.width, 200);
      for (final p in [sharp, blurred, small]) {
        p.dispose();
      }
      expect(await tester.runAsync(() => isDecodablePicture(Uint8List.fromList(utf8Bytes('not a picture')))), isFalse);
      expect(await tester.runAsync(() => isDecodablePicture(bytes)), isTrue);
    });

    test('background files live in their own folder, and only those are deleted', () async {
      final dataDir = Directory('${_temp.path}${Platform.pathSeparator}store')..createSync();
      final path = (await saveBackgroundImage(dataDir.path, _Picture.dark.encode(width: 8, height: 8), 'PNG'))!;
      expect(path, contains('appearance'));
      expect(path, endsWith('.png'));
      expect(await readBackgroundImage(path), isNotNull);
      final outside = File('${dataDir.path}${Platform.pathSeparator}settings.json')..writeAsStringSync('{}');
      await deleteBackgroundImage(dataDir.path, outside.path);
      expect(outside.existsSync(), isTrue, reason: 'nothing outside the background folder');
      await deleteBackgroundImage(dataDir.path, path);
      expect(File(path).existsSync(), isFalse);
      expect(await readBackgroundImage(path), isNull);
    });
  });

  group('readable over any picture', () {
    const routes = ['/queue', '/activity', '/accounts', '/settings', '/compose'];
    for (final highContrast in [false, true]) {
      for (final theme in ['light', 'dark']) {
        for (final picture in _Picture.values) {
          final label = '${picture.name} picture, $theme${highContrast ? ', high contrast' : ''}';
          testWidgets('key screens over a $label', (tester) async {
            final handle = tester.ensureSemantics();
            if (highContrast) {
              tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(highContrast: true);
              addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
            }
            final path = _pictureFile(picture);
            final c = await _pumpApp(tester, size: const Size(1440, 900), settings: {'themeMode': theme, 'backgroundImagePath': path}, route: routes.first);
            expect(find.byType(RawImage), findsOneWidget, reason: 'the picture is painted');
            final contrast = highContrast ? textContrastGuideline : _ContrastExceptFaintColors(_nf(tester));
            for (final route in routes) {
              c.read(routerProvider).go(route);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 600));
              await expectLater(tester, meetsGuideline(contrast), reason: route);
              // Accounts (its switches) and Settings (its radio buttons) have
              // unlabelled controls with or without a picture.
              if (!{'/accounts', '/settings'}.contains(route)) {
                await expectLater(tester, meetsGuideline(labeledTapTargetGuideline), reason: route);
              }
            }
            handle.dispose();
            await _unmount(tester);
          });
        }
      }
    }

    testWidgets('a blurred busy picture needs less dimming than a sharp one, and the Dim setting adds to it', (tester) async {
      final path = _pictureFile(_Picture.busy);
      await _pumpApp(tester, size: const Size(1440, 900), settings: {'themeMode': 'dark', 'backgroundImagePath': path, 'backgroundDim': 0}, route: '/queue');
      final sharp = _scrim(tester).color.a;
      expect(sharp, greaterThan(0.5), reason: 'sharp noise has white pixels under the text');
      await _unmount(tester);

      await _pumpApp(tester, size: const Size(1440, 900), settings: {'themeMode': 'dark', 'backgroundImagePath': path, 'backgroundDim': 0, 'backgroundBlur': 20}, route: '/queue');
      final blurred = _scrim(tester).color.a;
      expect(blurred, lessThan(sharp));
      await _unmount(tester);

      final more = math.min(1.0, blurred + 0.1);
      await _pumpApp(tester, size: const Size(1440, 900), settings: {'themeMode': 'dark', 'backgroundImagePath': path, 'backgroundDim': more, 'backgroundBlur': 20}, route: '/queue');
      expect(_scrim(tester).color.a, closeTo(more, 0.01), reason: 'more than legibility needs, as the user asked');
      await _unmount(tester);
    });

    testWidgets('pages over the picture are see-through; cards keep their surface', (tester) async {
      final path = _pictureFile(_Picture.bright);
      await _pumpApp(tester, size: const Size(1440, 900), settings: {'backgroundImagePath': path}, route: '/activity/post/demo-post-2');
      final scaffolds = tester.widgetList<Scaffold>(find.byType(Scaffold));
      expect(scaffolds.map((s) => s.backgroundColor), everyElement(Colors.transparent));
      await _unmount(tester);
    });

    testWidgets('turning the picture off keeps the page where it was', (tester) async {
      final path = _pictureFile(_Picture.dark);
      final c = await _pumpApp(tester, size: const Size(1440, 900), settings: {'backgroundImagePath': path}, route: '/queue');
      final state = tester.state(find.byType(Navigator).last);
      await c.read(settingsProvider.notifier).update((x) => x.copyWith(clearBackgroundImage: true));
      await tester.pump();
      expect(find.byType(RawImage), findsNothing);
      expect(tester.state(find.byType(Navigator).last), same(state));
      expect(tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor, _nf(tester).bg);
      await _unmount(tester);
    });
  });

  group('Settings > Appearance > Background', () {
    testWidgets('Remove deletes the copy and goes back to none', (tester) async {
      final dataDir = '${_temp.path}${Platform.pathSeparator}data';
      final path = _pictureFile(_Picture.dark);
      final copy = File(path).copySync('$path.copy.png').path;
      final c = await _pumpApp(tester, size: const Size(1440, 900), settings: {'backgroundImagePath': copy}, dataDir: dataDir);
      await tester.ensureVisible(find.text('Background'));
      await tester.pump();
      expect(find.text('Blur'), findsOneWidget);
      expect(find.text('Dim'), findsOneWidget);
      expect(find.text('40%'), findsOneWidget, reason: 'the default dim');
      await tester.ensureVisible(find.text('Remove'));
      await tester.pump();
      await tester.tap(find.text('Remove'));
      await _drain(tester);
      expect(c.read(settingsProvider).backgroundImagePath, isNull);
      expect(File(copy).existsSync(), isFalse);
      expect(find.text('Blur'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('the Dim slider changes the setting; Image is off without a data folder', (tester) async {
      final path = _pictureFile(_Picture.bright);
      final c = await _pumpApp(tester, size: const Size(1440, 900), settings: {'backgroundImagePath': path}, dataDir: '${_temp.path}${Platform.pathSeparator}data');
      final dim = find.descendant(of: find.ancestor(of: find.text('Dim'), matching: find.byType(Row)).first, matching: find.byType(Slider));
      await tester.ensureVisible(dim);
      await tester.pump();
      final track = tester.getRect(dim);
      await tester.tapAt(Offset(track.right - 30, track.center.dy));
      await _drain(tester);
      expect(c.read(settingsProvider).backgroundDim, greaterThan(0.85));
      await _unmount(tester);

      await _pumpApp(tester, size: const Size(1440, 900));
      await tester.ensureVisible(find.text('Background'));
      await tester.pump();
      expect(find.text('A picture behind the pages needs the installed app.'), findsOneWidget);
      final segmented = tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>));
      expect(segmented.onSelectionChanged, isNull);
      await _unmount(tester);
    });
  });

  group('following the system', () {
    testWidgets('high contrast: stronger text and borders, still readable', (tester) async {
      final handle = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(highContrast: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      for (final theme in ['light', 'dark']) {
        await _pumpApp(tester, size: const Size(1440, 900), settings: {'themeMode': theme}, route: '/queue');
        final nf = _nf(tester);
        final plain = theme == 'light' ? NfColors.light(AccentChoice.neforum) : NfColors.dark(AccentChoice.neforum);
        expect(nf.textMuted, plain.withHighContrast().textMuted);
        expect(contrastRatio(nf.textMuted, nf.bg), greaterThanOrEqualTo(7));
        expect(contrastRatio(nf.textMuted, nf.surface), greaterThanOrEqualTo(7));
        expect(contrastRatio(nf.textFaint, nf.surface), greaterThanOrEqualTo(4.5));
        expect(contrastRatio(nf.border, nf.surface), greaterThanOrEqualTo(3));
        expect(contrastRatio(nf.text, nf.bg), greaterThan(contrastRatio(plain.text, plain.bg)));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await _unmount(tester);
      }
      handle.dispose();
    });

    test('high contrast keeps every chrome style readable', () {
      for (final style in NavigationChromeStyle.values) {
        for (final b in Brightness.values) {
          final c = buildTheme(b, AccentChoice.ocean, chrome: style, highContrast: true).extension<NfColors>()!;
          expect(contrastRatio(c.onChrome, c.chrome), greaterThanOrEqualTo(4.5));
          expect(contrastRatio(c.onChromeMuted, c.chrome), greaterThanOrEqualTo(4.5));
        }
      }
    });

    testWidgets('reduce motion: no page transitions and no decorative animation', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final c = await _pumpApp(tester, size: const Size(1440, 900), route: '/activity');
      final theme = Theme.of(tester.element(find.text('Activity').last));
      expect(theme.pageTransitionsTheme.builders.values, everyElement(isA<ImmediatePageTransitionsBuilder>()));
      expect(const ImmediatePageTransitionsBuilder().transitionDuration, Duration.zero);
      // A post opens at once, with nothing left animating.
      c.read(routerProvider).go('/activity/post/demo-post-2');
      await tester.pump();
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      await _unmount(tester);

      // The publishing mark stays still.
      await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light, AccentChoice.neforum), home: const Scaffold(body: NeforumMark(animate: true))));
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('without reduce motion the transitions and the mark stay', (tester) async {
      await _pumpApp(tester, size: const Size(1440, 900), route: '/activity');
      final theme = Theme.of(tester.element(find.text('Activity').last));
      expect(theme.pageTransitionsTheme.builders.values, everyElement(isNot(isA<ImmediatePageTransitionsBuilder>())));
      await _unmount(tester);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light, AccentChoice.neforum), home: const Scaffold(body: NeforumMark(animate: true))));
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

List<int> utf8Bytes(String s) => s.codeUnits;
