// Runs the real desktop build (native window, tray, keychain storage,
// notifications, file system) against a throwaway data folder.
//
//   flutter test integration_test -d windows
//
// Nothing is posted anywhere: the flows after the first-run checks use the
// demo workspace.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/desktop.dart';
import 'package:neforum_app/platform/notifications.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('first run and the main flows on the real desktop build', (tester) async {
    final dir = await Directory.systemTemp.createTemp('neforum-it-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file open; the OS cleans temp later.
      }
    });
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (d) {
      errors.add(d);
      previous?.call(d);
    };
    addTearDown(() => FlutterError.onError = previous);
    void noErrors(String step) => expect(errors, isEmpty, reason: '$step: ${errors.map((e) => e.exceptionAsString()).join('\n')}');

    Future<void> pumpFor(int ms) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // --- Start exactly like main() does, minus the real data folder.
    await DesktopIntegration.instance.initWindow();
    await NotificationService.instance.init();
    final storage = await openAppStorage(overrideDir: dir.path);
    final services = await AppServices.create(demo: false, storage: storage);
    await tester.pumpWidget(NeforumRoot(initial: services));
    await pumpFor(2000);

    // --- First run: an empty workspace that points the way.
    expect(find.text('Connect your first network'), findsOneWidget);
    expect(find.text('Try the demo workspace'), findsOneWidget);
    noErrors('first frame');

    for (final section in ['Queue', 'Activity', 'Accounts', 'Settings', 'Compose']) {
      await tester.tap(find.text(section).first);
      await pumpFor(900);
      noErrors('open $section');
    }

    // --- The OS keychain (DPAPI on Windows) through the real plugin.
    await services.secrets.write('integration-probe', {'token': 'not-a-real-token'});
    expect(await services.secrets.read('integration-probe'), {'token': 'not-a-real-token'});
    await services.secrets.delete('integration-probe');
    expect(await services.secrets.read('integration-probe'), isNull);

    // --- Demo workspace.
    await tester.tap(find.text('Try the demo workspace'));
    await pumpFor(4000);
    expect(find.textContaining('Demo workspace'), findsOneWidget);
    noErrors('enter demo');
    final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first));
    final demo = c.read(servicesProvider);
    expect(demo.demo, isTrue);

    // Text-only post to Instagram (needs an image) and Mastodon (can hold
    // scheduled posts), scheduled for later.
    final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
    await tester.enterText(editor, 'Windows test: one message, every platform. #neforum');
    final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
    final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
    c.read(composerProvider.notifier).selectAccounts([ig.id, masto.id]);
    c.read(composerProvider.notifier).setSchedule(DateTime.now().add(const Duration(hours: 2)));
    await pumpFor(1000);
    expect(find.byType(TextCardView), findsOneWidget);
    noErrors('compose');

    final actions = c.read(postActionsProvider);
    final post = await actions.schedule();
    await actions.settle();
    await pumpFor(1000);

    final card = post.media.singleWhere((m) => m.generated);
    final file = File(card.path);
    expect(file.existsSync(), isTrue, reason: 'card written into the media folder');
    expect(card.path, startsWith(storage.dataDir!));
    final decoded = img.decodeJpg(file.readAsBytesSync())!;
    expect((decoded.width, decoded.height), (textCardSize('instagram').width.round(), textCardSize('instagram').height.round()));

    final saved = (await demo.posts.get(post.id))!;
    expect(saved.targetFor(masto.id)!.status, TargetStatus.heldByPlatform);
    expect(saved.targetFor(ig.id)!.overrides.mediaIds, [card.id]);

    // The queue shows it.
    await tester.tap(find.text('Queue').first);
    await pumpFor(1200);
    expect(find.textContaining('Windows test'), findsWidgets);
    noErrors('queue');

    // --- Back to the real (empty) workspace.
    await tester.state<NeforumRootState>(find.byType(NeforumRoot)).setDemo(false);
    await pumpFor(3000);
    await tester.tap(find.text('Compose').first);
    await pumpFor(900);
    expect(find.text('Connect your first network'), findsOneWidget);
    noErrors('leave demo');
  });
}
