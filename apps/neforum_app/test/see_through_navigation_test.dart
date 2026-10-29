// Settings > Appearance > Navigation bar > See-through: the background
// picture (or the page) shows through the sidebar, rail and phone tab bar,
// with their labels readable over anything.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/ui/settings/appearance_section.dart' show hexColor;
import 'package:neforum_app/ui/shell/app_backdrop.dart';
import 'package:neforum_app/ui/shell/see_through_chrome.dart';

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

// No bundled fonts here, on purpose: flutter_test's own font draws every
// glyph as a solid box, so the contrast guideline reads the text's real color
// (with anti-aliased letters it often reads a blend and reports nonsense).

/// Text in [region] measured by [textContrastGuideline]: the semantics nodes
/// whose label is a text in the navigation (its destinations, the wordmark,
/// the version). The page's own text is checked in
/// appearance_background_test.dart.
class _NavigationContrast extends MinimumTextContrastGuideline {
  const _NavigationContrast(this.region);

  final Finder region;

  @override
  bool shouldSkipNode(SemanticsData data) {
    if (super.shouldSkipNode(data)) return true;
    final label = data.label.isEmpty ? data.value : data.label;
    return find.descendant(of: region, matching: find.text(label)).evaluate().isEmpty;
  }
}

/// The measurement of [textContrastGuideline] (the most frequent light and
/// dark colors at a text, against WCAG AA for its size) applied to every
/// Text in [region]: also the counts on the badges and the phone tab bar's
/// labels, which share a semantics node with other text and so are never
/// measured by the guideline itself.
///
/// It measures within the text's own bounds, where the guideline adds 4
/// pixels around them: a count sits on a pill hardly larger than itself,
/// and those 4 pixels would measure the pill against the page around it
/// instead of the count against the pill.
class _EveryTextContrast extends MinimumTextContrastGuideline {
  const _EveryTextContrast(this.region);

  final Finder region;

  @override
  Future<Evaluation> evaluate(WidgetTester tester) async {
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    var width = 0, height = 0;
    final pixels = (await tester.binding.runAsync<ByteData?>(() async {
      final image = await layer.toImage(view.paintBounds, pixelRatio: 1 / view.flutterView.devicePixelRatio);
      width = image.width;
      height = image.height;
      final data = await image.toByteData();
      image.dispose();
      return data;
    }))!;
    var result = const Evaluation.pass();
    var measured = 0;
    for (final element in find.descendant(of: region, matching: find.byType(Text)).evaluate()) {
      final text = element.widget as Text;
      final box = element.renderObject;
      if (box is! RenderBox || !box.hasSize || box.size.isEmpty) continue;
      final bounds = MatrixUtils.transformRect(box.getTransformTo(null), box.paintBounds.inflate(2)).intersect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
      if (bounds.isEmpty) continue;
      final style = DefaultTextStyle.of(element).style.merge(text.style);
      final target = targetContrastRatio(style.fontSize, bold: style.fontWeight == FontWeight.bold);
      final histogram = <int, int>{};
      for (var y = bounds.top.floor(); y < bounds.bottom.ceil(); y++) {
        for (var x = bounds.left.floor(); x < bounds.right.ceil(); x++) {
          histogram.update(pixels.getUint32((y * width + x) * 4), (n) => n + 1, ifAbsent: () => 1);
        }
      }
      Color color(int rgba) => Color((rgba << 24 | rgba >> 8) & 0xFFFFFFFF);
      double lightness(int rgba) => HSLColor.fromColor(color(rgba)).lightness;
      var total = 0.0, count = 0;
      histogram.forEach((rgba, n) {
        total += lightness(rgba) * n;
        count += n;
      });
      final average = total / count;
      MapEntry<int, int>? light, dark;
      for (final e in histogram.entries) {
        if (lightness(e.key) <= average) {
          if (e.value > (dark?.value ?? 0)) dark = e;
        } else if (e.value > (light?.value ?? 0)) {
          light = e;
        }
      }
      final ratio = contrastRatio(color((light ?? dark)!.key), color((dark ?? light)!.key));
      measured++;
      if (ratio < target - 0.01) {
        final common = (histogram.entries.toList()..sort((a, b) => b.value - a.value)).take(4).map((e) => '${hexColor(color(e.key).toARGB32())} x${e.value}');
        result += Evaluation.fail('"${text.data}" at $bounds: ${ratio.toStringAsFixed(2)} where $target is needed (most frequent: ${common.join(', ')}).\n');
      }
    }
    if (measured == 0) result += const Evaluation.fail('No text measured in the navigation.\n');
    return result;
  }
}

/// Generated test pictures, as in appearance_background_test.dart, all
/// window-sized: nearly white, nearly black, random colors in 8-pixel
/// blocks, and nearly black with one small white patch under the sidebar
/// (under 0.5% of the picture: too little to strengthen the page's scrim).
enum _Picture {
  bright,
  dark,
  busy,
  patch;

  Uint8List encode() {
    const w = 1440, h = 900;
    final image = img.Image(width: w, height: h);
    final random = math.Random(11);
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
          case _Picture.patch:
            // Under the sidebar's Accounts label: 18 x 4 of the 160 x 100
            // samples, where 80 may fail.
            final white = x >= 60 && x < 222 && y >= 300 && y < 336;
            image.setPixelRgb(x, y, white ? 255 : 6, white ? 255 : 0, white ? 255 : 16);
        }
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }
}

late Directory _temp;

String _pictureFile(_Picture picture) {
  final file = File('${_temp.path}${Platform.pathSeparator}${picture.name}.png');
  if (!file.existsSync()) file.writeAsBytesSync(picture.encode());
  return file.path;
}

/// NEFORUM's demo workspace at [size] with the see-through navigation and
/// [settings], on [route]. A background picture in the settings is decoded
/// first, outside the fake clock.
Future<ProviderContainer> _pumpApp(WidgetTester tester, {Size size = const Size(1440, 900), Map<String, Object> settings = const {}, String route = '/queue'}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final picture = settings['backgroundImagePath'] as String?;
  if (picture != null) {
    await tester.runAsync(() => AppBackdrop.precache(picture, blur: 0, physicalSize: size, devicePixelRatio: 1));
  }
  final stored = {'themeMode': 'light', 'navigationChrome': 'transparent', ...settings};
  final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage(stored))))!;
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

final _chrome = find.byType(SeeThroughChrome);

/// The cover laid over what shows through the chrome.
Color _cover(WidgetTester tester) => tester.widget<ColoredBox>(find.descendant(of: _chrome, matching: find.byType(ColoredBox)).first).color;

void main() {
  setUpAll(() => _temp = Directory.systemTemp.createTempSync('neforum_see_through_test'));
  tearDownAll(() => _temp.deleteSync(recursive: true));

  group('settings', () {
    test('the see-through navigation round-trips through settings.json', () {
      const s = AppSettings(navigationChrome: NavigationChromeStyle.transparent, navigationChromeOpacity: 0.35, navigationChromeBlur: 12);
      final back = AppSettings.fromJson(s.toJson());
      expect(back.navigationChrome, NavigationChromeStyle.transparent);
      expect(back.navigationChromeOpacity, 0.35);
      expect(back.navigationChromeBlur, 12);
      final other = back.copyWith(navigationChrome: NavigationChromeStyle.brand);
      expect((other.navigationChromeOpacity, other.navigationChromeBlur), (0.35, 12.0), reason: 'kept for when it is chosen again');
    });

    test('defaults write nothing, and stored values are kept in range', () {
      final json = const AppSettings().toJson();
      expect(json.keys, isNot(anyOf(contains('navigationChromeOpacity'), contains('navigationChromeBlur'))));
      final odd = AppSettings.fromJson({'navigationChromeOpacity': 3, 'navigationChromeBlur': 500});
      expect(odd.navigationChromeOpacity, 1);
      expect(odd.navigationChromeBlur, kMaxNavigationChromeBlur);
      final junk = AppSettings.fromJson({'navigationChromeOpacity': 'half', 'navigationChromeBlur': double.infinity});
      expect(junk.navigationChromeOpacity, 0);
      expect(junk.navigationChromeBlur, 0);
      expect(AppSettings.fromJson({'navigationChromeOpacity': -1}).navigationChromeOpacity, 0);
    });

    test('a settings.json from 1.3.0 loads unchanged, with the navigation as it was', () {
      final legacy = <String, dynamic>{
        'themeMode': 'dark',
        'navigationChrome': 'accent',
        'cornerStyle': 'square',
        'backgroundImagePath': '/data/neforum/appearance/background-1.png',
        'backgroundBlur': 12.0,
        'textCardEveryNetwork': true,
        'onboarded': true,
      };
      final s = AppSettings.fromJson(legacy);
      expect(s.navigationChrome, NavigationChromeStyle.accent);
      expect(s.navigationChromeOpacity, 0);
      expect(s.navigationChromeBlur, 0);
      expect(s.backgroundImagePath, legacy['backgroundImagePath']);
      // Written back, it gains nothing it did not have.
      expect(s.toJson()..removeWhere((k, _) => !legacy.containsKey(k)), legacy);
      expect(s.toJson().keys, isNot(anyOf(contains('navigationChromeOpacity'), contains('navigationChromeBlur'))));
    });

    test('a style this NEFORUM does not know (from a newer one) loads as NEFORUM purple', () {
      // 1.3.0 reads "transparent" the same way.
      expect(AppSettings.fromJson({'navigationChrome': 'holographic'}).navigationChrome, NavigationChromeStyle.brand);
    });

    test('the opacity and blur move and sync with the style', () {
      for (final key in ['navigationChrome', 'navigationChromeOpacity', 'navigationChromeBlur']) {
        expect(kExportableSettings, contains(key));
      }
      final imported = withImportedSettings(const AppSettings(), {'navigationChrome': 'transparent', 'navigationChromeOpacity': 0.5, 'navigationChromeBlur': 8});
      expect(imported.navigationChrome, NavigationChromeStyle.transparent);
      expect(imported.navigationChromeOpacity, 0.5);
      expect(imported.navigationChromeBlur, 8);
    });
  });

  group('theme', () {
    test('the see-through chrome has no color of its own and the page\'s text colors', () {
      for (final b in Brightness.values) {
        for (final highContrast in [false, true]) {
          final page = buildTheme(b, AccentChoice.ocean, highContrast: highContrast).extension<NfColors>()!;
          final c = buildTheme(b, AccentChoice.ocean, chrome: NavigationChromeStyle.transparent, highContrast: highContrast).extension<NfColors>()!;
          final label = '$b${highContrast ? ' high contrast' : ''}';
          expect(c.chrome.a, 0, reason: label);
          expect(c.chrome.withValues(alpha: 1), page.surface, reason: label);
          expect(c.onChrome, page.text, reason: 'the stronger text with high contrast: $label');
          expect(c.onChromeMuted, page.textMuted, reason: label);
          expect(c.chromeBorder, page.border, reason: 'a hairline divider: $label');
          for (final fill in [c.chromeRaised, c.chromeAccent, c.chromeUrgent]) {
            expect(fill.a, 1, reason: 'the selection and counts are on opaque fills: $label');
          }
          expect([c.chromeAccent, c.chromeSelected, c.chromeUrgent], everyElement(isNot(Brand.yellow)), reason: label);
          expect(contrastRatio(c.onChromeAccent, c.chromeAccent), greaterThanOrEqualTo(3), reason: label);
          expect(contrastRatio(c.onChromeUrgent, c.chromeUrgent), greaterThanOrEqualTo(4.5), reason: label);
          expect(contrastRatio(c.onChrome, c.chromeRaised), greaterThanOrEqualTo(4.5), reason: 'the selected row: $label');
        }
      }
    });
  });

  group('measuring the picture under the chrome', () {
    // A grid 4 x 2: the left column white, the rest black.
    final sampling = BackdropSampling(
      samples: Uint8List.fromList([
        for (var y = 0; y < 2; y++)
          for (var x = 0; x < 4; x++) ...(x == 0 ? [255, 255, 255, 255] : [0, 0, 0, 255]),
      ]),
      samplesWidth: 4,
      scrim: Colors.black,
      scrimOpacity: 0.5,
    );

    test('the samples under a region, under the page scrim', () {
      // A window 400 x 100: the picture covers it 400 x 200, cut top and bottom.
      final left = sampling.under(const Rect.fromLTWH(0, 0, 100, 100), const Size(400, 100));
      expect(left.length, 2 * 4, reason: 'one column, both rows');
      expect(left.sublist(0, 4), [128, 128, 128, 255]);
      final bottom = sampling.under(const Rect.fromLTWH(0, 80, 400, 20), const Size(400, 100));
      expect(bottom.length, 4 * 4, reason: 'the lower row, all four columns');
      expect([for (var i = 0; i < bottom.length; i += 4) bottom[i]], [128, 0, 0, 0]);
      expect(sampling.under(const Rect.fromLTWH(500, 0, 50, 100), const Size(400, 100)), isEmpty, reason: 'outside the window');
    });

    testWidgets('a bright patch under the sidebar gets a cover the rest of the page does not need', (tester) async {
      await _pumpApp(tester, settings: {'themeMode': 'dark', 'backgroundImagePath': _pictureFile(_Picture.dark), 'backgroundDim': 0});
      expect(_cover(tester).a, 0, reason: 'a dark picture needs nothing under light labels');
      await _unmount(tester);

      await _pumpApp(tester, settings: {'themeMode': 'dark', 'backgroundImagePath': _pictureFile(_Picture.patch), 'backgroundDim': 0});
      final page = tester.widget<ColoredBox>(find.descendant(of: find.byType(AppBackdrop), matching: find.byType(ColoredBox)).at(1)).color.a;
      expect(page, lessThan(0.05), reason: 'the patch is too small to strengthen the page scrim');
      await expectLater(tester, meetsGuideline(_EveryTextContrast(_chrome)));
      expect(_cover(tester).a, greaterThan(0.5), reason: 'it is under the sidebar');
      expect(_cover(tester).withValues(alpha: 1), _nf(tester).surface);
      await _unmount(tester);
    });

    testWidgets('the opacity is the least cover; without a picture the page color shows, with a hairline', (tester) async {
      await _pumpApp(tester, settings: {'navigationChromeOpacity': 0.35, 'navigationChromeBlur': 12});
      final nf = _nf(tester);
      expect(_cover(tester), nf.surface.withValues(alpha: 0.35));
      expect(find.descendant(of: _chrome, matching: find.byType(BackdropFilter)), findsNothing, reason: 'no blur over the plain page');
      final sidebar = tester.widgetList<Container>(find.descendant(of: _chrome, matching: find.byType(Container))).firstWhere((c) => c.constraints == BoxConstraints.tightFor(width: 264));
      final box = sidebar.decoration! as BoxDecoration;
      expect(box.color!.a, 0, reason: 'the sidebar paints no color of its own');
      expect(box.border, Border(right: BorderSide(color: nf.border)));
      await _unmount(tester);

      await _pumpApp(tester, settings: {'navigationChromeOpacity': 0.35, 'navigationChromeBlur': 12, 'backgroundImagePath': _pictureFile(_Picture.dark)});
      expect(_cover(tester).a, closeTo(0.35, 0.001), reason: 'the page scrim already keeps the labels readable there');
      final filter = tester.widget<BackdropFilter>(find.descendant(of: _chrome, matching: find.byType(BackdropFilter)));
      expect(filter.filter, ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12));
      await _unmount(tester);
    });
  });

  group('readable over any picture', () {
    for (final (theme, highContrast) in [('light', false), ('dark', false), ('light', true), ('dark', true)]) {
      for (final picture in [null, _Picture.bright, _Picture.dark, _Picture.busy]) {
        // High contrast: the hardest picture only.
        if (highContrast && picture != _Picture.busy) continue;
        final label = '${picture == null ? 'no' : 'a ${picture.name}'} picture, $theme${highContrast ? ', high contrast' : ''}';
        testWidgets('sidebar, rail and tab bar over $label', (tester) async {
          final handle = tester.ensureSemantics();
          if (highContrast) {
            tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(highContrast: true);
            addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
          }
          await _pumpApp(tester, settings: {'themeMode': theme, if (picture != null) 'backgroundImagePath': _pictureFile(picture)});
          expect(find.byType(RawImage), picture == null ? findsNothing : findsOneWidget);
          for (final (layout, size) in [('sidebar', const Size(1440, 900)), ('rail', const Size(1000, 800)), ('tab bar', const Size(390, 800))]) {
            tester.view.physicalSize = size;
            await _settle(tester);
            expect(_chrome, findsOneWidget, reason: layout);
            await expectLater(tester, meetsGuideline(_NavigationContrast(_chrome)), reason: layout);
            await expectLater(tester, meetsGuideline(_EveryTextContrast(_chrome)), reason: layout);
          }
          handle.dispose();
          await _unmount(tester);
        });
      }
    }
  });

  group('Settings > Appearance > Navigation bar', () {
    testWidgets('See-through shows its opacity; the blur only with a background picture', (tester) async {
      final c = await _pumpApp(tester, settings: {'navigationChrome': 'brand'}, route: '/settings');
      expect(find.text('See-through navigation'), findsNothing);
      await tester.ensureVisible(find.text('See-through'));
      await tester.pump();
      await tester.tap(find.text('See-through'));
      await _settle(tester);
      expect(c.read(settingsProvider).navigationChrome, NavigationChromeStyle.transparent);
      expect(_chrome, findsOneWidget, reason: 'the sidebar is see-through at once');
      expect(find.text('See-through navigation'), findsOneWidget);
      expect(find.text('Opacity'), findsOneWidget);
      expect(find.text('Blur'), findsNothing, reason: 'nothing to blur without a picture');
      final opacity = find.descendant(of: find.ancestor(of: find.text('Opacity'), matching: find.byType(Row)).first, matching: find.byType(Slider));
      await tester.ensureVisible(opacity);
      await tester.pump();
      final track = tester.getRect(opacity);
      await tester.tapAt(Offset(track.right - 30, track.center.dy));
      await _settle(tester);
      expect(c.read(settingsProvider).navigationChromeOpacity, greaterThan(0.85));
      await _unmount(tester);

      await _pumpApp(tester, settings: {'backgroundImagePath': _pictureFile(_Picture.bright)}, route: '/settings');
      await tester.ensureVisible(find.text('See-through navigation'));
      await tester.pump();
      final blur = find.descendant(of: find.ancestor(of: find.text('Opacity'), matching: find.byType(Column)).first, matching: find.text('Blur'));
      expect(blur, findsOneWidget);
      await _unmount(tester);
    });
  });
}
