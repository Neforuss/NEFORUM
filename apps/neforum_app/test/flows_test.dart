// Drives the main user flows in the demo workspace (compose, preview,
// schedule, customize, publish, hand-off, add account) at phone and desktop
// sizes and fails on any exception or overflow.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/accounts/add_account_screen.dart';
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
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => (_media['mem://$id.$extension'] = bytes).isEmpty ? '' : 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => _media[path]!;
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

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-SemiBold.ttf', 'assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
  await family('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf']);
}

void main() {
  setUpAll(_loadFonts);

  for (final size in const {'phone': Size(360, 740), 'desktop': Size(1440, 900)}.entries) {
    testWidgets('main flows work at ${size.key}', (tester) async {
      tester.view.physicalSize = size.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
      await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
      await tester.pump(const Duration(milliseconds: 300));
      final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
      final router = container.read(routerProvider);

      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      Future<void> settle(String step) async {
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
        if (errors.isNotEmpty) {
          debugPrint('---- $step (${size.key}) ----\n${errors.first}');
          fail('$step: ${errors.first.exceptionAsString()}');
        }
      }

      try {
        // --- Compose: type a long post with entities.
        router.go('/compose');
        await settle('open compose');
        final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
        expect(editor, findsOneWidget);
        await tester.enterText(editor, 'Big news! ${'Lots of words here. ' * 30}https://example.org #launch @friend@example.social');
        await settle('type text');
        expect(container.read(composerProvider).text, contains('#launch'));
        final previews = container.read(composerPreviewsProvider);
        expect(previews, isNotEmpty);
        expect(previews.any((p) => p.variant.isThread), isTrue, reason: 'long text should thread somewhere');

        // --- Preview pane (phone has a Write/Preview switch).
        if (size.key == 'phone') {
          await tester.tap(find.textContaining('Preview ('));
          await settle('switch to preview');
        }

        // --- Customize sheet for the first preview.
        final customize = find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Customize for'));
        expect(customize, findsWidgets);
        await tester.tap(customize.first);
        await settle('open customize');
        await tester.tap(find.text('Cancel').last);
        await settle('close customize');

        // --- Schedule sheet.
        if (size.key == 'phone') {
          await tester.tap(find.text('Write'));
          await settle('back to write');
        }
        await tester.tap(size.key == 'phone' ? find.byTooltip('Schedule').first : find.text('Schedule').first);
        await settle('open schedule');
        await tester.tap(find.text('Cancel').last);
        await settle('close schedule');

        // --- Publish to automatic accounts only (no hand-off sheets).
        container.read(composerProvider.notifier).selectAccounts(
            container.read(accountListProvider).where((a) => a.tier != PlatformTier.handoff && a.platformId != 'reddit').map((a) => a.id));
        await settle('select automatic');
        final ready = container.read(composerReadinessProvider);
        expect(ready.blocked, 0, reason: 'automatic demo accounts should accept a threaded text post');
        await tester.tap(find.textContaining(RegExp(r'^Post to \d')));
        await settle('start publish');
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        await settle('publish progress');
        expect(find.text('Posted everywhere'), findsOneWidget);
        await tester.tap(find.text('Done'));
        await settle('close publish sheet');

        // --- Activity, post detail, hand-off sheet.
        router.go('/activity/post/demo-post-2');
        await settle('post detail');
        final handOff = find.text('Hand off now');
        expect(handOff, findsWidgets);
        await tester.ensureVisible(handOff.first);
        await tester.tap(handOff.first);
        await settle('open hand-off');
        expect(find.textContaining('Finish on'), findsOneWidget);
        await tester.tap(find.text('I posted it'));
        await settle('confirm hand-off');

        // --- Add account: platform → tier → connect form.
        router.go('/accounts/add');
        await settle('add account');
        // Inactive tabs stay mounted, so scope finders to this screen.
        final mastodon = find.descendant(of: find.byType(AddAccountScreen), matching: find.text('Mastodon')).first;
        await tester.ensureVisible(mastodon);
        await settle('scroll to mastodon');
        await tester.tap(mastodon);
        await settle('pick mastodon');
        if (find.text('Continue').evaluate().isEmpty) {
          final texts = find.descendant(of: find.byType(AddAccountScreen), matching: find.byType(Text)).evaluate().map((e) => (e.widget as Text).data).whereType<String>().take(25);
          debugPrint('After tapping Mastodon: ${texts.join(' | ')}');
        }
        expect(find.text('Continue'), findsOneWidget);
        await tester.ensureVisible(find.text('Continue'));
        await settle('scroll to continue');
        await tester.tap(find.text('Continue'));
        await settle('tier continue');
        expect(find.textContaining('Connect Mastodon'), findsOneWidget);

        // --- Settings: switch theme and accent.
        router.go('/settings');
        await settle('settings');
        await tester.tap(find.text('Light'));
        await settle('light theme');
        await tester.tap(find.text('Dark'));
        await settle('dark theme');
      } finally {
        FlutterError.onError = previous;
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
