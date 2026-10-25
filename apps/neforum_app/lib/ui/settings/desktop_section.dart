
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/desktop.dart';
import '../../state/providers.dart';
import '../../widgets/layout.dart';
import 'setting_row.dart';

class DesktopSettingsSection extends ConsumerStatefulWidget {
  const DesktopSettingsSection({super.key});

  @override
  ConsumerState<DesktopSettingsSection> createState() => _DesktopSettingsSectionState();
}

class _DesktopSettingsSectionState extends ConsumerState<DesktopSettingsSection> {
  bool? _login;

  @override
  void initState() {
    super.initState();
    DesktopIntegration.instance.isLaunchAtLoginEnabled().then((v) {
      if (mounted) setState(() => _login = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final supported = DesktopIntegration.instance.launchAtLoginSupported;
    return SettingsSection(title: 'Desktop', icon: Icons.desktop_windows_outlined, subtitle: 'Scheduled posts go out while NEFORUM is running.', children: [
      SettingSwitch(
        title: 'Start NEFORUM when I sign in',
        description: supported ? 'Starts minimized in the tray.' : 'Not available on this system.',
        value: _login ?? s.startAtLogin,
        onChanged: !supported
            ? null
            : (v) async {
                final ok = await DesktopIntegration.instance.setLaunchAtLogin(v);
                if (!mounted) return;
                if (ok) {
                  setState(() => _login = v);
                  await n.update((x) => x.copyWith(startAtLogin: v));
                } else {
                  showToast(this.context, 'Could not change the startup setting', icon: Icons.error_outline_rounded);
                }
              },
      ),
      SettingSwitch(
        title: 'Keep running in the tray when I close the window',
        description: 'Recommended: scheduled posts only go out while NEFORUM runs.',
        value: s.minimizeToTray,
        onChanged: (v) => n.update((x) => x.copyWith(minimizeToTray: v)),
      ),
    ]);
  }
}
