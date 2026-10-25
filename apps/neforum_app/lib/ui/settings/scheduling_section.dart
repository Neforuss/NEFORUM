
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/env.dart';
import '../../state/providers.dart';
import 'setting_row.dart';

class SchedulingSettingsSection extends ConsumerWidget {
  const SchedulingSettingsSection({super.key});

  static String _deviceText() {
    if (Env.isIOS) {
      return 'iOS does not let apps post on a timer. At the scheduled time you get a notification; its Publish now button posts without opening NEFORUM.';
    }
    if (Env.isAndroid) return 'Android posts them in the background within a few minutes of their time.';
    if (Env.isDesktop) return 'NEFORUM posts them on time while it runs. Closing the window keeps it in the tray; it can also start when you sign in.';
    return 'The installed apps post them on time; this web preview only stores the time.';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSection(title: 'Scheduling', icon: Icons.event_available_outlined, subtitle: 'No NEFORUM server: platforms or this device publish on time.', children: [
      SettingSwitch(
        title: 'Let platforms hold scheduled posts',
        description: 'Mastodon, Facebook Pages, YouTube, Tumblr, WordPress and Ghost can publish a scheduled post themselves, even when this device is off. '
            'Editing, rescheduling or deleting the post in NEFORUM takes their copy back first.',
        value: s.delegateSchedules,
        onChanged: (v) => n.update((x) => x.copyWith(delegateSchedules: v)),
      ),
      SettingRow(title: 'Every other network', description: _deviceText()),
    ]);
  }
}
