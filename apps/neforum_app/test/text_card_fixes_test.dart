// 1.3.1 fixes for text cards: any installed or imported font on a card (the
// composer's card style and the Settings default), and the card shown in
// every network's preview when the same card goes to every network.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/caption_fonts.dart';
import 'package:neforum_app/media/font_files.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  final Map<String, Uint8List> _media = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async {
    final path = 'mem://$id.$extension';
    _media[path] = bytes;
    return path;
  }

  @override
  Future<Uint8List> readMedia(String path) async => _media[path] ?? (throw StateError('No file at $path'));
  @override
  Future<void> deleteMedia(String path) async => _media.remove(path);
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

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
}

/// A font that is "installed" on this test device: JetBrains Mono from the
/// app's assets, found through the installed-font registry.
const String _monoPath = 'assets/fonts/JetBrainsMono-Regular.ttf';

void main() {
  setUpAll(_loadFonts);
  setUp(() {
    debugResetCaptionFonts();
    debugInstalledFontCatalog = InstalledFontCatalog.fromEntries([
      {'path': File(_monoPath).absolute.path, 'faces': [const FontFace(family: 'JetBrains Mono').toJson()]},
    ]);
  });
  tearDown(debugResetCaptionFonts);

  Future<(AppServices, ProviderContainer)> boot(WidgetTester tester, {double height = 900}) async {
    tester.view.physicalSize = Size(1440, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
    await tester.pump(const Duration(milliseconds: 300));
    return (services, ProviderScope.containerOf(tester.element(find.byType(MaterialApp))));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  group('bug: the every-network card shows only in Instagram\'s preview', () {
    testWidgets('Instagram, Bluesky, Mastodon and X each preview their card at their own size, with its editor', (tester) async {
      final (_, c) = await boot(tester, height: 4200);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final demo = c.read(accountListProvider);
      final byPlatform = {for (final p in ['instagram', 'bluesky', 'mastodon', 'x']) p: demo.firstWhere((a) => a.platformId == p)};
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), 'One card for every network.');
      c.read(composerProvider.notifier)
        ..selectAccounts([for (final a in byPlatform.values) a.id])
        ..setTextCardEveryNetwork(true);
      await settle(tester);

      for (final MapEntry(key: platform, value: a) in byPlatform.entries) {
        final preview = c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == a.id);
        expect(isTextCardPlaceholder(preview.variant.media.single), isTrue, reason: '$platform gets the card');
        final card = find.byKey(ValueKey('text-card-preview-$platform'));
        expect(card, findsOneWidget, reason: '$platform shows its card in the preview');
        final size = tester.getSize(card);
        final expected = textCardSize(platform);
        expect(size.width / size.height, closeTo(expected.width / expected.height, 0.01), reason: '$platform at its own shape');
        expect(find.byKey(ValueKey('text-card-style-$platform')), findsOneWidget, reason: '$platform\'s card can be edited from its preview');
      }
      await finish(tester);
    });
  });
}
