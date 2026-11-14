import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:neforum_core/neforum_core.dart' show PostStatus;
import 'package:workmanager/workmanager.dart';

import 'platform/desktop.dart';
import 'platform/env.dart';
import 'platform/notifications.dart';
import 'platform/publish_host.dart';
import 'platform/storage.dart';
import 'state/character_catalog.dart';
import 'state/fitted_photos.dart';
import 'state/publish_result_notices.dart';
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
      await runBackgroundPublish(services);
      services.dispose();
      return true;
    } on Object catch (e) {
      debugPrint('Background publish failed: $e');
      return false;
    }
  });
}

/// "Publish now" on a due-post reminder of a text post, pressed while NEFORUM is
/// not open. iOS runs this in a background isolate for a few seconds. AppDelegate
/// takes a background assertion before the notification plugin's early completion
/// handler, and the host's `end` gives it back.
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
      final done = await services.publisher().publish(postId, interactive: false, retryFailed: false, dueTargetsOnly: true);
      final discarded = await services.discardIfComplete(postId);
      await announcePublishResult(services, done, discarded: discarded, onlyAccountIds: targetsChangedByRun(post, done));
      await planNextReminders(services, done);
      // A renewal in this run moved a date, and a warning planned for the old one
      // would say something no longer true: no status stream reaches this isolate.
      await services.signInWarnings.run();
      await services.cloudSync.syncNow();
    }
    services.dispose();
  } on Object catch (e) {
    debugPrint('Background publish from a notification failed: $e');
  } finally {
    // Gives back the assertion AppDelegate took for this action (iOS only).
    if (Env.isIOS) {
      try {
        await ChannelPublishHost().end(postId: postId, summary: 'Finished');
      } on Object catch (e) {
        debugPrint('Could not end the background action: ${e.runtimeType}');
      }
    }
  }
}

Future<void> main(List<String> args) => runNeforum(args);

/// Starts the app. [prepare] runs on the workspace before the UI exists: only the
/// background posting probe (integration_test/android_background_probe.dart) uses it.
Future<void> runNeforum(List<String> args, {Future<void> Function(AppServices services)? prepare}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final startMinimized = args.contains('--minimized');
  registerCharacterDataLicense();

  await DesktopIntegration.instance.initWindow(startHidden: startMinimized);
  NotificationService.instance.backgroundHandler = notificationBackgroundHandler;
  await NotificationService.instance.init();
  if (Env.isAndroid || Env.isIOS) {
    await Workmanager().initialize(callbackDispatcher);
  }

  final services = await openWorkspace(await openAppStorage(), prepare: prepare);

  await DesktopIntegration.instance.setCloseToTray(services.settings.minimizeToTray);
  unawaited(services.startBrowserBridge());
  unawaited(services.startCloudSync());

  runApp(NeforumRoot(initial: services));
}

/// What [runNeforum] does with [storage] before the UI exists: the workspace it
/// names, the reason the last run ended, the startup housekeeping, then [prepare].
/// Tests run it as the app does.
@visibleForTesting
Future<AppServices> openWorkspace(AppStorage storage, {Future<void> Function(AppServices services)? prepare}) async {
  final mode = await storage.readJson('mode.json');
  // The web build is a preview: always a demo workspace.
  final demo = Env.isWeb || (mode?['demo'] as bool? ?? false);
  final services = await AppServices.create(demo: demo, storage: storage);
  if (kExitReasonsByUser.contains(await readLastExitReason())) services.interruptionMessage = AppServices.stoppedByUserMessage;
  // Before the UI exists, so no run of this process is mistaken for one a
  // closed NEFORUM left behind, and no file being attached is swept away.
  await services.performStartupMaintenance();
  await prepare?.call(services);
  return services;
}
