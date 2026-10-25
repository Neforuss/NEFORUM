
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/env.dart';
import '../../platform/notifications.dart';
import '../../state/providers.dart';
import '../../widgets/layout.dart';
import 'setting_row.dart';

class NotificationSettingsSection extends ConsumerWidget {
  const NotificationSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final how = Env.isIOS
        ? 'On iPhone and iPad, a notification at the scheduled time lets you publish with one tap.'
        : Env.isAndroid
            ? 'Android publishes scheduled posts in the background and tells you how it went.'
            : 'Hand-off networks always get a reminder when it is time to post.';
    return SettingsSection(title: 'Notifications', icon: Icons.notifications_none_rounded, children: [
      SettingRow(
        title: 'Allow notifications',
        description: how,
        stackOnCompact: true,
        trailing: OutlinedButton(
          onPressed: () async {
            final ok = await NotificationService.instance.requestPermission();
            if (context.mounted) showToast(context, ok ? 'Notifications are on' : 'Notifications are off; you can enable them in system settings', icon: ok ? Icons.check_rounded : Icons.info_outline_rounded);
          },
          child: const Text('Allow'),
        ),
      ),
      SettingSwitch(
        title: 'Tell me when scheduled posts go out',
        value: s.notifyOnPublish,
        onChanged: (v) => n.update((x) => x.copyWith(notifyOnPublish: v)),
      ),
    ]);
  }
}
