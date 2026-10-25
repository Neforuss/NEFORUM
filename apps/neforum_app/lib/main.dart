import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:neforum_core/neforum_core.dart' show PostStatus;
import 'package:workmanager/workmanager.dart';

import 'platform/desktop.dart';
import 'platform/env.dart';
import 'platform/notifications.dart';
import 'platform/storage.dart';
import 'state/fitted_photos.dart';
import 'state/scheduler.dart';
import 'state/services.dart';
import 'ui/root.dart';

/// Background entry point (Android WorkManager / iOS BGTaskScheduler):
/// publishes every due post without UI and notifies about the outcome.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    try {
      await NotificationService.instance.init();
      final services = await AppServices.create(demo: false);
      await services.startCloudSync(background: true);
      await publishDueHeadless(services);
      await services.cloudSync.syncNow();
      services.dispose();
      return true;
    } on Object catch (e) {
      debugPrint('Background publish failed: $e');
      return false;
    }
  });
}

/// "Publish now" on a due-post reminder, pressed while NEFORUM is not open
/// (iOS runs this in a background isolate for a few seconds).
@pragma('vm:entry-point')
void notificationBackgroundHandler(NotificationResponse response) {
  final intent = NotificationIntent.parse(response.payload);
  if (response.actionId != kPublishAction || intent is! PublishDueIntent) return;
  unawaited(_publishInBackground(intent.postId));
}

Future<void> _publishInBackground(String postId) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  try {
    await NotificationService.instance.init();
    final services = await AppServices.create(demo: false);
    await services.startCloudSync(background: true);
    final post = await services.posts.get(postId);
    if (post != null && post.status == PostStatus.scheduled && await services.cloudSync.mayPublish(post)) {
      await fitPhotosOfSavedPost(services, postId);
      final done = await services.publisher().publish(postId, interactive: false, retryFailed: false);
      final discarded = await services.discardIfComplete(postId);
      await announcePublishResult(services, done, discarded: discarded);
      await services.cloudSync.syncNow();
    }
    services.dispose();
  } on Object catch (e) {
    debugPrint('Background publish from a notification failed: $e');
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final startMinimized = args.contains('--minimized');

  await DesktopIntegration.instance.initWindow(startHidden: startMinimized);
  NotificationService.instance.backgroundHandler = notificationBackgroundHandler;
  await NotificationService.instance.init();
  if (Env.isAndroid || Env.isIOS) {
    await Workmanager().initialize(callbackDispatcher);
  }

  final storage = await openAppStorage();
  final mode = await storage.readJson('mode.json');
  // The web build is a preview: always a demo workspace.
  final demo = Env.isWeb || (mode?['demo'] as bool? ?? false);
  final services = await AppServices.create(demo: demo, storage: storage);
  // Before the UI exists, so no run of this process is mistaken for one a
  // closed NEFORUM left behind, and no file being attached is swept away.
  await services.performStartupMaintenance();

  await DesktopIntegration.instance.setCloseToTray(services.settings.minimizeToTray);
  unawaited(services.startBrowserBridge());
  unawaited(services.startCloudSync());

  runApp(NeforumRoot(initial: services));
}
