import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nativeapi/nativeapi.dart' as native show LaunchAtLogin;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop.dart';
import 'env.dart';

final DesktopIntegration desktopIntegration = _IoDesktop();

class _IoDesktop with WindowListener implements DesktopIntegration {
  TrayIcon? _tray;
  bool _closeToTray = true;
  bool _windowReady = false;
  native.LaunchAtLogin? _launch;

  @override
  Future<void> initWindow({bool startHidden = false}) async {
    if (!Env.isDesktop) return;
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1320, 860),
      minimumSize: Size(420, 620),
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
      tray.icon = ImageAsset.fromAsset(Platform.isWindows ? 'assets/tray/tray_icon.ico' : 'assets/tray/tray_icon.png');
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
  void onWindowClose() async {
    if (_closeToTray && _tray != null) {
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
    }
    exit(0);
  }

  // ---- launch at login ---------------------------------------------------

  native.LaunchAtLogin? get _login {
    if (!Env.isDesktop) return null;
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
      l.setProgram(Platform.resolvedExecutable, const ['--minimized']);
      return enabled ? l.enable() : l.disable();
    } on Object catch (e) {
      debugPrint('Launch at login failed: $e');
      return false;
    }
  }
}
