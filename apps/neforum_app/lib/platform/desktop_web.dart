import 'desktop.dart';

final DesktopIntegration desktopIntegration = _NoDesktop();

class _NoDesktop implements DesktopIntegration {
  @override
  Future<void> initWindow({bool startHidden = false}) async {}
  @override
  Future<void> initTray(void Function(TrayAction action) onAction) async {}
  @override
  void setTrayStatus(String tooltip) {}
  @override
  Future<void> setCloseToTray(bool enabled) async {}
  @override
  Future<bool> trayAvailable() async => false;
  @override
  Future<void> showWindow() async {}
  @override
  Future<void> hideWindow() async {}
  @override
  Future<void> quit() async {}
  @override
  bool get launchAtLoginSupported => false;
  @override
  Future<bool> isLaunchAtLoginEnabled() async => false;
  @override
  Future<bool> setLaunchAtLogin(bool enabled) async => false;
  @override
  String? get notificationIconPath => null;
}
