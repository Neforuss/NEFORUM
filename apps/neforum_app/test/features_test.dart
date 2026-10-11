// Text cards for image-only platforms and platform-held schedules, driven
// through the demo workspace.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
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
}

void main() {
  setUpAll(_loadFonts);

  Future<(AppServices, ProviderContainer)> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
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

  testWidgets('text-only posts become a NEFORUM text card where an image is required', (tester) async {
    final (services, c) = await boot(tester);
    c.read(routerProvider).go('/compose');
    await settle(tester);
    final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
    await tester.enterText(editor, 'Open source keyboards, open bench, open evenings. Come build with us. #diy');
    final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
    final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
    c.read(composerProvider.notifier).selectAccounts([ig.id, masto.id]);
    await settle(tester);

    // Preview and checks see the card; Mastodon gets plain text.
    final previews = {for (final p in c.read(composerPreviewsProvider)) p.account.platformId: p};
    expect(previews['instagram']!.variant.media.single.generated, isTrue);
    expect(previews['instagram']!.issues.where((i) => i.code == 'media.required'), isEmpty);
    expect(previews['instagram']!.issues.any((i) => i.code == 'media.text_card'), isTrue);
    expect(previews['mastodon']!.variant.media, isEmpty);
    expect(c.read(composerReadinessProvider).blocked, 0);
    expect(find.byType(TextCardView), findsOneWidget);

    // Per-post style.
    await tester.ensureVisible(find.text(TextCardTheme.light.label).first);
    await tester.tap(find.text(TextCardTheme.light.label).first);
    await settle(tester);
    expect(c.read(composerProvider).textCardTheme, TextCardTheme.light);

    // Saving renders the real JPEG and gives it to Instagram only.
    final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
    final card = post.media.singleWhere((m) => m.generated);
    expect(card.mimeType, 'image/jpeg');
    expect(card.fileName, textCardFileName(TextCardTheme.light));
    expect(card.altText, startsWith('Open source keyboards'));
    expect(post.targetFor(ig.id)!.overrides.mediaIds, [card.id]);
    expect(post.targetFor(masto.id)!.overrides.mediaIds, isNull);
    final bytes = (await tester.runAsync(() => services.media.read(card)))!;
    final decoded = img.decodeJpg(bytes)!;
    expect((decoded.width, decoded.height), (1080, 1350));
    // White card: the corner below the top rule is white.
    final px = decoded.getPixel(1070, 600);
    expect(px.r, greaterThan(240));

    // Editing hides the card again and remembers the style.
    c.read(composerProvider.notifier).load(post);
    expect(c.read(composerProvider).media, isEmpty);
    expect(c.read(composerProvider).overrides[ig.id], isNull);
    expect(c.read(composerProvider).textCardTheme, TextCardTheme.light);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  // Found on a real Windows window: with a schedule set, the composer's
  // action bar overflowed when the compose column was ~560 px wide.
  testWidgets('composer with a schedule fits at in-between window widths', (tester) async {
    final (services, c) = await boot(tester);
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
      await tester.enterText(editor, 'Checking the bar at many widths with a schedule set. #neforum');
      for (final scheduled in const [false, true]) {
        if (scheduled) c.read(composerProvider.notifier).setSchedule(DateTime(2026, 12, 24, 18, 45));
        for (final w in const [740.0, 900.0, 1000.0, 1180.0, 1230.0, 1280.0, 1366.0, 1440.0, 1600.0]) {
          tester.view.physicalSize = Size(w, 820);
          await settle(tester);
          expect(errors, isEmpty, reason: '${scheduled ? 'scheduled' : 'unscheduled'}, width $w: ${errors.map((e) => e.exceptionAsString()).join('\n')}');
        }
      }
    } finally {
      FlutterError.onError = previous;
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    services.dispose();
  });

  testWidgets('platform-held schedules are shown, taken back and handed over again', (tester) async {
    final (services, c) = await boot(tester);
    c.read(routerProvider).go('/activity/post/demo-post-3');
    await settle(tester);
    expect(find.textContaining('holds this post'), findsOneWidget);
    expect(find.text('Held by platform'), findsWidgets);

    final actions = c.read(postActionsProvider);
    final post = (await services.posts.get('demo-post-3'))!;
    final masto = post.targets.firstWhere((t) => t.isHeldByPlatform).accountId;

    // Moving it to drafts takes Mastodon's copy back.
    final draft = (await tester.runAsync(() => actions.unschedule(post)))!;
    expect(draft.status, PostStatus.draft);
    expect(draft.hasHeldTargets, isFalse);
    expect(draft.targetFor(masto)!.status, TargetStatus.pending);

    // Scheduling again hands it over again; platforms without server-side
    // scheduling stay on the device.
    final when = DateTime.now().add(const Duration(hours: 3));
    await tester.runAsync(() async {
      await actions.reschedule(draft, when);
      await actions.settle();
    });
    final again = (await services.posts.get('demo-post-3'))!;
    expect(again.targetFor(masto)!.status, TargetStatus.heldByPlatform);
    expect(again.targetFor(masto)!.result!.scheduledFor, when);
    final bluesky = c.read(accountListProvider).firstWhere((a) => a.platformId == 'bluesky');
    expect(again.targetFor(bluesky.id)!.status, TargetStatus.pending);
    expect(again.needsDeviceAtSchedule, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
