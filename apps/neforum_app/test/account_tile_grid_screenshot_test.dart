// Renders the phone composer's account tiles at 360 x 640 with the real fonts
// and icons, 21 accounts, to look at:
//
//   $env:NEFORUM_SHOT_DIR = "C:\some\folder"
//   flutter test test/account_tile_grid_screenshot_test.dart --tags screenshots
//
// Without NEFORUM_SHOT_DIR the files go to build/screenshots. Skipped in normal
// runs because it needs the Flutter SDK's and the pub cache's icon fonts.
@Tags(['screenshots'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/brand/platform_brand.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/compose/account_tile_grid.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

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
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF777777)));
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

List<ConnectedAccount> _accounts() {
  const networks = [
    ('mastodon', PlatformTier.openApi),
    ('bluesky', PlatformTier.openApi),
    ('x', PlatformTier.byokApi),
    ('threads', PlatformTier.byokApi),
    ('linkedin', PlatformTier.byokApi),
    ('facebook', PlatformTier.handoff),
    ('instagram', PlatformTier.handoff),
    ('tiktok', PlatformTier.handoff),
    ('youtube', PlatformTier.byokApi),
    ('reddit', PlatformTier.byokApi),
    ('pinterest', PlatformTier.byokApi),
    ('tumblr', PlatformTier.byokApi),
    ('telegram', PlatformTier.openApi),
    ('discord', PlatformTier.openApi),
    ('lemmy', PlatformTier.openApi),
    ('misskey', PlatformTier.openApi),
    ('nostr', PlatformTier.openApi),
    ('matrix', PlatformTier.openApi),
    ('wordpress', PlatformTier.openApi),
    ('substack', PlatformTier.handoff),
    ('whatsapp', PlatformTier.handoff),
  ];
  return [
    for (final (i, n) in networks.indexed)
      ConnectedAccount(
        id: n.$1,
        platformId: n.$1,
        tier: n.$2,
        displayName: n.$1,
        createdAt: DateTime.utc(2026, 10, 1).add(Duration(minutes: i)),
        // One account switched off in Accounts, to show the block sign.
        enabled: n.$1 != 'linkedin',
      ),
  ];
}

void main() {
  setUpAll(_loadFonts);

  final dir = Platform.environment['NEFORUM_SHOT_DIR'] ?? 'build/screenshots';

  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    Brightness brightness = Brightness.light,
    double textScale = 1,
    Map<String, Object> settings = const {},
    double keyboard = 0,
    bool leaveOut = true,
  }) async {
    const pixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 640) * pixelRatio;
    tester.view.devicePixelRatio = pixelRatio;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final services = (await tester.runAsync(() async {
      final s = await AppServices.create(demo: true, storage: _MemoryStorage({'mobileTextScale': textScale, ...settings}));
      for (final a in await s.accounts.all()) {
        await s.accounts.delete(a.id);
      }
      for (final a in _accounts()) {
        await s.accounts.upsert(a);
      }
      return s;
    }))!;
    final boundary = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: RepaintBoundary(key: boundary, child: const NeforumApp()),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    final context = tester.element(find.byType(MaterialApp));
    await tester.runAsync(() => Future.wait([
          for (final id in platformBrands.keys)
            if (platformIconAsset(id) case final asset?) precacheImage(AssetImage(asset), context),
        ]));
    final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    c.read(composerProvider.notifier).reset(keepTargets: false);
    c.read(routerProvider).go('/compose');
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (leaveOut) {
      for (final id in const ['bluesky', 'tiktok', 'discord']) {
        c.read(composerProvider.notifier).toggleAccount(id);
      }
    }
    if (keyboard > 0) tester.view.viewInsets = FakeViewPadding(bottom: keyboard * pixelRatio);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(AccountTile).evaluate().isNotEmpty || settings.isNotEmpty || keyboard > 0, isTrue);

    final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = (await tester.runAsync(() async {
      final image = await render.toImage(pixelRatio: pixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;
    final file = File('$dir/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    // ignore: avoid_print
    print('Wrote ${file.path} (${bytes.length} bytes)');

    tester.view.resetViewInsets();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('open, 3 left out', (t) => shoot(t, name: 'a'));
  testWidgets('open, dark', (t) => shoot(t, name: 'a-dark', brightness: Brightness.dark));
  testWidgets('open, largest text', (t) => shoot(t, name: 'a-text-1.5', textScale: 1.5));
  testWidgets('folded by choice', (t) => shoot(t, name: 'a-folded', settings: const {'composerTargetsFolded': true}));
  testWidgets('keyboard open', (t) => shoot(t, name: 'a-keyboard', keyboard: 280));
}
