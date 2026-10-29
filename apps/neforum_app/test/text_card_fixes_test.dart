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
import 'package:neforum_app/state/render_warnings.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/text_cards.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

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

  group('bug: text cards take only the built-in fonts', () {
    testWidgets('the composer\'s card style opens the font picker and the card is drawn in the installed font', (tester) async {
      final (s, c) = await boot(tester, height: 1800);
      final font = CaptionFont(family: 'JetBrains Mono', path: File(_monoPath).absolute.path);
      // Loaded for real first: file reads do not finish inside the test's
      // fake clock, where the previews would start the loading.
      expect((await tester.runAsync(() => prepareCaptionFont(s.storage, font)))!, isTrue);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), 'In my own font.');
      c.read(composerProvider.notifier).selectAccounts([ig.id]);
      await settle(tester);

      await tester.ensureVisible(find.byKey(const Key('text-card-font-more')));
      await tester.tap(find.byKey(const Key('text-card-font-more')));
      await settle(tester);
      expect(find.text('Text card font'), findsOneWidget);
      expect(find.text('On this device'), findsOneWidget);
      await tester.tap(find.text('JetBrains Mono'));
      await settle(tester);

      expect(CaptionFont.tryParse(c.read(composerProvider).textCardCustomFont), font);
      final placeholder = c.read(composerPreviewsProvider).single.variant.media.single;
      expect(textCardCustomFontOf(placeholder), font, reason: 'the preview stands in for a card in that font');

      // Saved: the font is loaded, the card records it and is drawn in it.
      final now = DateTime(2026, 10, 29);
      final written = Post(id: 'p-font', text: 'In my own font.', targets: [PostTarget(accountId: ig.id)], createdAt: now, updatedAt: now);
      // Picking the font made it the Settings default too.
      expect(c.read(settingsProvider).textCardCustomFontChoice, font);
      final plain = (await tester.runAsync(() => attachTextCards(s, written, s.settings.copyWith(textCardCustomFont: const {}))))!;
      final mine = (await tester.runAsync(() => attachTextCards(s, written, s.settings, customFont: font.toJson())))!;
      final card = mine.media.singleWhere(isRenderedTextCard);
      expect(registeredCaptionFontAlias(font), font.alias, reason: 'loaded before rendering');
      expect(textCardCustomFontOf(card), font);
      expect(card.renderParameters!.containsKey('customFontFallback'), isFalse);
      final plainBytes = (await tester.runAsync(() => s.media.read(plain.media.singleWhere(isRenderedTextCard))))!;
      final mineBytes = (await tester.runAsync(() => s.media.read(card)))!;
      expect(mineBytes, isNot(plainBytes), reason: 'a different typeface draws a different card');

      // Edited again: the composer gets the font back from the card.
      c.read(composerProvider.notifier).load(mine);
      expect(CaptionFont.tryParse(c.read(composerProvider).textCardCustomFont), font);
      await finish(tester);
    });

    testWidgets('Settings > Text cards picks the default font from the same picker', (tester) async {
      final (_, c) = await boot(tester, height: 2400);
      c.read(routerProvider).go('/settings');
      await settle(tester);
      await tester.ensureVisible(find.byKey(const Key('text-card-font-more-setting')));
      await tester.tap(find.byKey(const Key('text-card-font-more-setting')));
      await settle(tester);
      expect(find.text('Text card font'), findsOneWidget);
      await tester.tap(find.text('JetBrains Mono'));
      await settle(tester);
      expect(c.read(settingsProvider).textCardCustomFontChoice?.family, 'JetBrains Mono');
      await finish(tester);
    });

    testWidgets('a card whose font is missing on this device uses the built-in font, says so, and is made again once it is here', (tester) async {
      final (s, c) = await boot(tester);
      debugInstalledFontCatalog = InstalledFontCatalog.empty;
      final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
      final warnings = <String>[];
      final sub = renderWarnings.listen(warnings.add);
      addTearDown(sub.cancel);
      const font = CaptionFont(family: 'Nowhere Sans', path: '/no/such.ttf');
      final now = DateTime(2026, 10, 29);
      final written = Post(id: 'p-missing', text: 'Missing font.', targets: [PostTarget(accountId: ig.id)], createdAt: now, updatedAt: now);
      final post = (await tester.runAsync(() async {
        final p = await attachTextCards(s, written, s.settings, customFont: font.toJson());
        await Future<void>.delayed(Duration.zero);
        return p;
      }))!;
      final card = post.media.singleWhere(isRenderedTextCard);
      expect(card.renderParameters!['customFontFallback'], isTrue);
      expect(textCardCustomFontOf(card), font, reason: 'the choice is kept for the device that has the font');
      expect(warnings.where((w) => w.contains('Nowhere Sans') && w.contains('text card')), hasLength(1));

      // The composer says so under the preview too.
      c.read(composerProvider.notifier)
        ..selectAccounts([ig.id])
        ..prefill('Missing font.')
        ..setTextCardCustomFont(font);
      await settle(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
      expect(c.read(composerPreviewsProvider).single.issues.map((i) => i.code), contains('media.text_card_font_missing'));
      await finish(tester);
    });
  });
}
