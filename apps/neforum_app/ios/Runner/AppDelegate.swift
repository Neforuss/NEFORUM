import Flutter
import UIKit
import UserNotifications
import flutter_local_notifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Must match kPublishDueTask in lib/state/scheduler.dart and
  /// BGTaskSchedulerPermittedIdentifiers in Info.plist.
  static let publishDueTask = "org.neforum.publish_due"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Background publishing: plugins must be available in the headless
    // engine WorkManager starts for BGTaskScheduler runs.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Same for the isolate that runs "Publish now" on a due-post reminder.
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: AppDelegate.publishDueTask,
      earliestBeginInSeconds: NSNumber(value: 15 * 60)
    )
    // UIScene apps must re-register launch handlers before returning.
    WorkmanagerPlugin.registerLaunchHandlers()

    // Show "time to post" reminders even while NEFORUM is open.
    UNUserNotificationCenter.current().delegate = self

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
