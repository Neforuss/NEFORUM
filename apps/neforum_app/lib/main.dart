import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

import 'platform/desktop.dart';
import 'platform/env.dart';
import 'platform/notifications.dart';
import 'platform/storage.dart';
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
      await publishDueHeadless(services);
      services.dispose();
      return true;
    } on Object catch (e) {
      debugPrint('Background publish failed: $e');
      return false;
    }
  });
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final startMinimized = args.contains('--minimized');

  await DesktopIntegration.instance.initWindow(startHidden: startMinimized);
  await NotificationService.instance.init();
  if (Env.isAndroid || Env.isIOS) {
    await Workmanager().initialize(callbackDispatcher);
  }

  final storage = await openAppStorage();
  final mode = await storage.readJson('mode.json');
  // The web build is a preview: always a demo workspace.
  final demo = Env.isWeb || (mode?['demo'] as bool? ?? false);
  final services = await AppServices.create(demo: demo, storage: storage);

  await DesktopIntegration.instance.setCloseToTray(services.settings.minimizeToTray);

  runApp(NeforumRoot(initial: services));
}
