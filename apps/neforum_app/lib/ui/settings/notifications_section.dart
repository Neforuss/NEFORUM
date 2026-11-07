
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/env.dart';
import '../../platform/notification_access.dart';
import '../../state/notification_state.dart';
import '../../state/providers.dart';
import '../shell/notification_prompt.dart';
import 'setting_row.dart';

class NotificationSettingsSection extends ConsumerWidget {
  const NotificationSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final row = notificationRowText(ref.watch(notificationAccessProvider), os: notificationOsName, isIOS: Env.isIOS);
    final action = row.action;
    return SettingsSection(title: 'Notifications', icon: Icons.notifications_none_rounded, children: [
      SettingRow(
        title: row.title,
        description: row.description,
        stackOnCompact: true,
        trailing: action == null ? null : OutlinedButton(onPressed: () => turnOnNotifications(context, ref), child: Text(action)),
      ),
      SettingSwitch(
        title: 'Tell me how each post went',
        value: s.notifyOnPublish,
        onChanged: (v) => n.update((x) => x.copyWith(notifyOnPublish: v)),
      ),
    ]);
  }
}
