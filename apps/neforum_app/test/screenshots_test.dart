// Renders README screenshots of the demo workspace.
//
//   flutter test test/screenshots_test.dart --update-goldens --tags screenshots
//
// Output: test/goldens/*.png (copy to docs/screenshots/). Skipped in normal
// runs because pixels differ slightly between machines.
@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/brand/platform_brand.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';

/// Storage whose images render as soft gradients (decoding real JPEGs in a
/// widget test would need real async I/O).
class _PrettyStorage implements AppStorage {
  final Map<String, Uint8List> _media = {};
  final Map<String, Object> _json = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async {
    final p = 'mem://${_media.length}-$id.$extension';
    _media[p] = bytes;
    return p;
  }

  @override
  Future<Uint8List> readMedia(String path) async => _media[path]!;
  @override
  Future<void> deleteMedia(String path) async => _media.remove(path);
  @override
  Future<int> mediaBytes() async => 0;

  static const _gradients = [
    [Color(0xFFF7B267), Color(0xFFD95D39), Color(0xFF3B2F2F)],
    [Color(0xFF8EC5FC), Color(0xFFE0C3FC), Color(0xFF2D3A5C)],
    [Color(0xFFA8E6CF), Color(0xFF2E8B57), Color(0xFF1E2B24)],
  ];

  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) {
    final i = int.tryParse(path.replaceFirst('mem://', '').split('-').first) ?? 0;
    final g = _gradients[i % _gradients.length];
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [g[0], g[1]])),
      child: Stack(children: [
        Positioned(left: 18, bottom: 22, child: _blob(g[2], 54)),
        Positioned(right: 26, bottom: 40, child: _blob(g[2], 34)),
        Positioned(left: 70, bottom: 8, child: _blob(g[2], 40)),
      ]),
    );
  }

  static Widget _blob(Color c, double s) => Container(width: s, height: s, decoration: BoxDecoration(color: c.withValues(alpha: 0.45), shape: BoxShape.circle));
}

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
  final pubCache = Platform.environment['PUB_CACHE'] ?? '${Platform.environment['LOCALAPPDATA']}\\Pub\\Cache';
  final fa = '$pubCache/hosted/pub.dev/font_awesome_flutter-11.0.0/lib/fonts';
  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-SemiBold.ttf', 'assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
  await family('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf']);
  await family('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  await family('packages/font_awesome_flutter/FontAwesomeBrands', ['$fa/Font-Awesome-7-Brands-Regular-400.otf']);
  await family('packages/font_awesome_flutter/FontAwesomeSolid', ['$fa/Font-Awesome-7-Free-Solid-900.otf']);
}

void main() {
  setUpAll(_loadFonts);

  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    required Size size,
    required Brightness brightness,
    required String route,
    Future<void> Function(WidgetTester t, ProviderContainer c)? before,
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _PrettyStorage())))!;
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
    await tester.pump(const Duration(milliseconds: 300));
    // Decode the platform icons for real, so the screens show them.
    final context = tester.element(find.byType(MaterialApp));
    await tester.runAsync(() => Future.wait([
          for (final id in platformBrands.keys)
            if (platformIconAsset(id) case final asset?) precacheImage(AssetImage(asset), context),
        ]));
    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    container.read(routerProvider).go(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    if (before != null) await before(tester, container);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> writePost(WidgetTester t, ProviderContainer c) async {
    final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
    await t.enterText(editor,
        'Shipped v2 of my split keyboard firmware! Per-key RGB is finally smooth at 1 kHz, and the whole thing is open source. Build guide: https://example.org/kb #opensource #keyboards');
    final media = c.read(postByIdProvider('demo-post-2'))?.media ?? const [];
    c.read(composerProvider.notifier).addMedia(media);
    c.read(composerProvider.notifier).selectAccounts(c
        .read(accountListProvider)
        .where((a) => const ['mastodon', 'bluesky', 'x', 'threads', 'instagram', 'linkedin', 'telegram', 'nostr'].contains(a.platformId))
        .map((a) => a.id));
  }

  const desktop = Size(1440, 900);
  const phone = Size(390, 844);

  testWidgets('compose dark', (t) => shoot(t, name: 'compose-dark', size: desktop, brightness: Brightness.dark, route: '/compose', before: writePost));
  testWidgets('compose light', (t) => shoot(t, name: 'compose-light', size: desktop, brightness: Brightness.light, route: '/compose', before: writePost));
  testWidgets('queue', (t) => shoot(t, name: 'queue-dark', size: desktop, brightness: Brightness.dark, route: '/queue'));
  testWidgets('activity', (t) => shoot(t, name: 'activity-light', size: desktop, brightness: Brightness.light, route: '/activity'));
  testWidgets('accounts', (t) => shoot(t, name: 'accounts-dark', size: desktop, brightness: Brightness.dark, route: '/accounts'));
  testWidgets('add account', (t) => shoot(t, name: 'add-account-light', size: desktop, brightness: Brightness.light, route: '/accounts/add'));
  testWidgets('settings', (t) => shoot(t, name: 'settings-dark', size: desktop, brightness: Brightness.dark, route: '/settings'));
  testWidgets('phone compose', (t) => shoot(t, name: 'phone-compose-dark', size: phone, brightness: Brightness.dark, route: '/compose', before: writePost));
  testWidgets('phone preview', (t) => shoot(t, name: 'phone-preview-light', size: phone, brightness: Brightness.light, route: '/compose', before: (tester, c) async {
        await writePost(tester, c);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.textContaining('Preview ('));
      }));
  testWidgets('phone handoff', (t) => shoot(t, name: 'phone-handoff-dark', size: phone, brightness: Brightness.dark, route: '/activity/post/demo-post-2', before: (tester, c) async {
        final b = find.text('Hand off now').first;
        await tester.ensureVisible(b);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(b);
      }));

  testWidgets('differentiation', (t) => shoot(t, name: 'differentiation-dark', size: desktop, brightness: Brightness.dark, route: '/compose', before: (tester, c) async {
        final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
        await tester.enterText(editor,
            'We rebuilt the firmware from scratch this spring. It took four months and two prototypes. Today it ships to everyone. Guide: https://example.org/kb\n\n#opensource #keyboards #diy');
        c.read(composerProvider.notifier).selectAccounts(c
            .read(accountListProvider)
            .where((a) => const ['x', 'linkedin', 'instagram', 'mastodon'].contains(a.platformId))
            .map((a) => a.id));
        c.read(composerProvider.notifier).setDifferentiate(true);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -520));
      }));

  testWidgets('text cards', (t) async {
    for (final theme in TextCardTheme.values) {
      final bytes = await t.runAsync(() => renderTextCardJpeg(
            text: 'Shipped v2 of my split keyboard firmware! Per-key RGB is finally smooth at 1 kHz, and the whole thing is open source.',
            theme: theme,
            size: textCardSize('instagram'),
            byline: '@robin.makes',
          ));
      File('test/goldens/text-card-${theme.name}.jpg')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!);
    }
  });

  // Keep the token import used (accent defaults) so the file compiles alone.
  test('tokens available', () => expect(AccentChoice.values, isNotEmpty));
}
