import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../state/scheduler.dart';
import '../../state/settings.dart';
import 'setting_row.dart';

/// What NEFORUM keeps after posting, and how times are shown.
class ActivitySettingsSection extends ConsumerWidget {
  const ActivitySettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSection(title: 'Activity and history', icon: Icons.history_rounded, children: [
      SettingChoice<PublishedPostRetention>(
        title: 'After a post is published everywhere',
        value: s.publishedPostRetention,
        onChanged: (v) async {
          await n.update((x) => x.copyWith(publishedPostRetention: v));
          // Posts the new choice no longer keeps go now, not at the next hourly check.
          await ref.read(schedulerProvider).applyRetention();
        },
        options: const [
          (PublishedPostRetention.discardOnCompletion, 'Delete it right away', 'Recommended. NEFORUM keeps no copy of the post, its text or its photos once every network has it.'),
          (PublishedPostRetention.retainSevenDays, 'Keep it for 7 days', 'Then it is deleted with its photos.'),
          (PublishedPostRetention.retainThirtyDays, 'Keep it for 30 days', 'Then it is deleted with its photos.'),
          (PublishedPostRetention.retainIndefinitely, 'Keep it', 'Published posts stay in Activity until you delete them.'),
        ],
      ),
      SettingRow(
        title: 'Times',
        description: 'In Activity, the Queue and post details. Exact shows the weekday, date and time, for example "Saturday, 24 October 2026, 14:05".',
        stackOnCompact: true,
        trailing: SegmentedButton<TimestampDisplay>(
          segments: const [
            ButtonSegment(value: TimestampDisplay.relative, label: Text('Relative')),
            ButtonSegment(value: TimestampDisplay.exact, label: Text('Exact')),
          ],
          selected: {s.timestampDisplay},
          onSelectionChanged: (v) => n.update((x) => x.copyWith(timestampDisplay: v.first)),
          showSelectedIcon: false,
        ),
      ),
      SettingRow(
        title: 'Clock',
        description: 'System follows the setting of this device.',
        stackOnCompact: true,
        trailing: SegmentedButton<ClockFormat>(
          segments: const [
            ButtonSegment(value: ClockFormat.system, label: Text('System')),
            ButtonSegment(value: ClockFormat.twelveHour, label: Text('12-hour')),
            ButtonSegment(value: ClockFormat.twentyFourHour, label: Text('24-hour')),
          ],
          selected: {s.clockFormat},
          onSelectionChanged: (v) => n.update((x) => x.copyWith(clockFormat: v.first)),
          showSelectedIcon: false,
        ),
      ),
    ]);
  }
}
