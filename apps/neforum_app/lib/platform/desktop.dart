import 'desktop_web.dart' if (dart.library.io) 'desktop_io.dart' as impl;

/// Actions the tray menu can trigger.
enum TrayAction { show, compose, publishDue, quit }

/// Window, tray and launch-at-login integration for Windows, macOS and Linux.
/// Every method is a no-op on mobile and web.
abstract class DesktopIntegration {
  static DesktopIntegration get instance => impl.desktopIntegration;

  /// Sizes and shows the main window. Call before runApp.
  Future<void> initWindow({bool startHidden = false});

  /// Installs the tray icon and its menu.
  Future<void> initTray(void Function(TrayAction action) onAction);

  /// Updates the tray tooltip ("NEFORUM: 3 scheduled").
  void setTrayStatus(String tooltip);

  /// When true, closing the window hides it to the tray instead of quitting.
  Future<void> setCloseToTray(bool enabled);

  Future<void> showWindow();
  Future<void> hideWindow();
  Future<void> quit();

  bool get launchAtLoginSupported;
  Future<bool> isLaunchAtLoginEnabled();
  Future<bool> setLaunchAtLogin(bool enabled);

  /// The NEFORUM icon file Windows shows on notifications (the bundled
  /// assets/brand/notify_icon.png), or null elsewhere or when it is missing.
  String? get notificationIconPath;
}
