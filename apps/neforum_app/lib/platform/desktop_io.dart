import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nativeapi/nativeapi.dart' as native show LaunchAtLogin;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop.dart';
import 'env.dart';

final DesktopIntegration desktopIntegration = _IoDesktop();

class _IoDesktop with WindowListener implements DesktopIntegration {
  /// The Linux runner's own calls (linux/runner/desktop_channel.cc).
  static const MethodChannel _linuxChannel = MethodChannel('neforum/desktop');

  TrayIcon? _tray;
  bool _closeToTray = true;
  bool _windowReady = false;
  native.LaunchAtLogin? _launch;

  @override
  Future<void> initWindow({bool startHidden = false}) async {
    if (!Env.isDesktop) return;
    await windowManager.ensureInitialized();
    // Started at login without a tray to bring it back: show the window.
    if (startHidden && Env.isLinux && !await trayAvailable()) startHidden = false;
    // 1320 x 860 where it fits; a little inside the screen on small laptops.
    var size = const Size(1320, 860);
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    if (displays.isNotEmpty) {
      final d = displays.first;
      final screen = d.size / d.devicePixelRatio;
      if (screen.width > 0 && screen.height > 0) {
        size = Size(math.min(size.width, math.max(420, screen.width * 0.92)), math.min(size.height, math.max(560, screen.height * 0.86)));
      }
    }
    final options = WindowOptions(
      size: size,
      minimumSize: const Size(420, 560),
      center: true,
      title: 'NEFORUM',
      backgroundColor: Colors.transparent,
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      if (!startHidden) {
        await windowManager.show();
        await windowManager.focus();
      }
    });
    windowManager.addListener(this);
    await windowManager.setPreventClose(_closeToTray);
    _windowReady = true;
  }

  @override
  Future<void> initTray(void Function(TrayAction action) onAction) async {
    if (!Env.isDesktop || _tray != null) return;
    try {
      final tray = TrayIcon.create();
      if (tray == null) return;
      // Linux panels are dark or light and show tray icons in colour, so the
      // full-colour icon there; macOS tints the monochrome template.
      tray.icon = ImageAsset.fromAsset(switch (Platform.operatingSystem) {
        'windows' => 'assets/tray/tray_icon.ico',
        'linux' => 'assets/brand/notify_icon.png',
        _ => 'assets/tray/tray_icon.png',
      });
      if (Platform.isMacOS) tray.isIconTemplate = true;
      tray.setTooltip('NEFORUM');

      final menu = Menu.create();
      if (menu != null) {
        void add(String label, TrayAction action) {
          final item = MenuItem.createWithLabelAndType(label, MenuItemType.normal);
          if (item == null) return;
          item.addListener((e) {
            if (e is MenuItemClickedEvent) onAction(action);
          });
          menu.addItem(item);
        }

        add('Open NEFORUM', TrayAction.show);
        add('New post…', TrayAction.compose);
        add('Publish due posts now', TrayAction.publishDue);
        menu.addSeparator();
        add('Quit NEFORUM', TrayAction.quit);
        tray.setContextMenu(menu);
        tray.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      }
      tray.addListener((e) {
        if (e is TrayIconClickedEvent || e is TrayIconDoubleClickedEvent) onAction(TrayAction.show);
      });
      tray.setVisible(true);
      _tray = tray;
    } on Object catch (e) {
      debugPrint('Tray unavailable: $e');
    }
  }

  @override
  void setTrayStatus(String tooltip) {
    try {
      _tray?.setTooltip(tooltip);
    } on Object {
      // Ignore: tray may be gone during shutdown.
    }
  }

  @override
  Future<void> setCloseToTray(bool enabled) async {
    _closeToTray = enabled;
    if (_windowReady) await windowManager.setPreventClose(enabled);
  }

  @override
  Future<bool> trayAvailable() async {
    if (!Env.isDesktop) return false;
    if (!Env.isLinux) return true;
    try {
      return await _linuxChannel.invokeMethod<bool>('statusNotifierHostAvailable') ?? false;
    } on Object catch (e) {
      debugPrint('Could not ask the desktop about tray icons: $e');
      return false;
    }
  }

  @override
  void onWindowClose() async {
    // Asked at every close: a panel or the GNOME AppIndicator extension can
    // come and go while NEFORUM runs.
    if (_closeToTray && _tray != null && await trayAvailable()) {
      await windowManager.hide();
    } else {
      await quit();
    }
  }

  @override
  Future<void> showWindow() async {
    if (!_windowReady) return;
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> hideWindow() async {
    if (_windowReady) await windowManager.hide();
  }

  @override
  Future<void> quit() async {
    try {
      _tray?.setVisible(false);
      _tray?.dispose();
    } on Object {
      // Shutting down anyway.
    }
    if (_windowReady) {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
      if (Platform.isWindows) {
        // destroy() posts WM_QUIT: the runner then takes the window down on the
        // main thread and returns from wWinMain, which ends the process.
        // Calling exit() here raced that teardown, and hooks other programs
        // inject into every window (Windhawk mods, for one) crashed on the
        // half-exited process. Exit only if the runner has not after 5 s.
        Timer(const Duration(seconds: 5), () => exit(0));
        return;
      }
    }
    exit(0);
  }

  // ---- launch at login ---------------------------------------------------

  native.LaunchAtLogin? get _login {
    if (!Env.isDesktop) return null;
    // A Flatpak cannot write the user's ~/.config/autostart (its sandbox has
    // its own), and the Background portal is not wired up: the desktop's own
    // startup settings start it instead.
    if (Platform.isLinux && (Platform.environment['FLATPAK_ID'] ?? '').isNotEmpty) return null;
    try {
      if (!native.LaunchAtLogin.isSupported()) return null;
      return _launch ??= native.LaunchAtLogin.createWithIdAndDisplayName('org.neforum.NEFORUM', 'NEFORUM');
    } on Object {
      return null;
    }
  }

  @override
  bool get launchAtLoginSupported => _login != null;

  @override
  Future<bool> isLaunchAtLoginEnabled() async {
    try {
      return _login?.isEnabled ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> setLaunchAtLogin(bool enabled) async {
    final l = _login;
    if (l == null) return false;
    try {
      l.setProgram(_launchProgram, const ['--minimized']);
      return enabled ? l.enable() : l.disable();
    } on Object catch (e) {
      debugPrint('Launch at login failed: $e');
      return false;
    }
  }

  /// What the login entry starts. On Linux (nativeapi writes
  /// ~/.config/autostart/org.neforum.NEFORUM.desktop) an AppImage runs from
  /// a temporary mount that changes every launch, so the entry names the
  /// .AppImage file itself (the runtime sets APPIMAGE).
  String get _launchProgram {
    if (Platform.isLinux) {
      final appImage = Platform.environment['APPIMAGE'] ?? '';
      if (appImage.isNotEmpty) return appImage;
    }
    return Platform.resolvedExecutable;
  }

  @override
  String? get notificationIconPath {
    if (!Env.isWindows) return null;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final icon = File('$exeDir\\data\\flutter_assets\\assets\\brand\\notify_icon.png');
    return icon.existsSync() ? icon.path : null;
  }
}
