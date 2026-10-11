import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../platform/env.dart';
import '../../state/composer.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/surfaces.dart';

/// Picks a date and time for the post. Returns null when cancelled; a
/// `DateTime(0)` sentinel means "clear the schedule".
Future<DateTime?> showScheduleSheet(BuildContext context, {DateTime? initial}) {
  final sheet = ScheduleSheet(initial: initial);
  if (context.isCompact) {
    return showModalBottomSheet<DateTime>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => sheet);
  }
  return showDialog<DateTime>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640, maxHeight: 820), child: sheet),
    ),
  );
}

/// Sentinel returned when the user removes the schedule.
final DateTime kClearSchedule = DateTime(0);

class ScheduleSheet extends ConsumerStatefulWidget {
  const ScheduleSheet({super.key, this.initial});
  final DateTime? initial;

  @override
  ConsumerState<ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends ConsumerState<ScheduleSheet> {
  late DateTime _day;
  late TimeOfDay _time;

  @override
  void initState() {
    super.initState();
    final base = widget.initial ?? _roundUp(DateTime.now().add(const Duration(hours: 1)));
    _day = DateTime(base.year, base.month, base.day);
    _time = TimeOfDay(hour: base.hour, minute: base.minute);
  }

  static DateTime _roundUp(DateTime t) {
    final m = (t.minute / 15).ceil() * 15;
    return DateTime(t.year, t.month, t.day, t.hour).add(Duration(minutes: m));
  }

  DateTime get _when => DateTime(_day.year, _day.month, _day.day, _time.hour, _time.minute);

  List<(String, String, DateTime)> _quickPicks() {
    final now = DateTime.now();
    DateTime at(DateTime d, int h, [int m = 0]) => DateTime(d.year, d.month, d.day, h, m);
    final tomorrow = now.add(const Duration(days: 1));
    final daysToMonday = (DateTime.monday - now.weekday + 7) % 7;
    final monday = now.add(Duration(days: daysToMonday == 0 ? 7 : daysToMonday));
    final picks = <(String, String, DateTime)>[
      ('In 1 hour', DateFormat.jm().format(_roundUp(now.add(const Duration(hours: 1)))), _roundUp(now.add(const Duration(hours: 1)))),
      ('This evening', 'Today, ${DateFormat.jm().format(at(now, 19))}', at(now, 19)),
      ('Tomorrow morning', '${DateFormat.E().format(tomorrow)}, ${DateFormat.jm().format(at(tomorrow, 9))}', at(tomorrow, 9)),
      ('Next Monday', '${DateFormat.MMMd().format(monday)}, ${DateFormat.jm().format(at(monday, 9))}', at(monday, 9)),
    ];
    return picks.where((p) => p.$3.isAfter(now.add(const Duration(minutes: 5)))).toList();
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final previews = ref.watch(composerPreviewsProvider);
    final handoff = previews.where((p) => p.account.tier == PlatformTier.handoff).map((p) => p.descriptor.name).toSet();
    final past = !_when.isAfter(DateTime.now());
    final tz = DateTime.now().timeZoneName;

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.xxl, Space.sm),
        child: Text('Schedule post', style: context.text.headlineSmall),
      ),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            LayoutBuilder(builder: (context, c) {
              final cols = c.maxWidth > 480 ? 4 : 2;
              final picks = _quickPicks();
              return Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
                for (final p in picks)
                  SizedBox(
                    width: (c.maxWidth - Space.sm * (cols - 1)) / cols,
                    child: NfCard(
                      padding: const EdgeInsets.all(Space.md),
                      selected: _when == p.$3,
                      onTap: () => setState(() {
                        _day = DateTime(p.$3.year, p.$3.month, p.$3.day);
                        _time = TimeOfDay(hour: p.$3.hour, minute: p.$3.minute);
                      }),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p.$1, style: context.text.labelLarge),
                        const SizedBox(height: 2),
                        Text(p.$2, style: context.text.bodySmall),
                      ]),
                    ),
                  ),
              ]);
            }),
            const SizedBox(height: Space.lg),
            NfWell(
              padding: const EdgeInsets.all(Space.sm),
              child: CalendarDatePicker(
                initialDate: _day,
                firstDate: DateTime.now().subtract(const Duration(days: 1)),
                lastDate: DateTime.now().add(const Duration(days: 365)),
                onDateChanged: (d) => setState(() => _day = d),
              ),
            ),
            const SizedBox(height: Space.md),
            Row(children: [
              Icon(Icons.schedule_rounded, color: nf.textMuted, size: 20),
              const SizedBox(width: Space.sm),
              Text('Time', style: context.text.titleSmall),
              const Spacer(),
              OutlinedButton(
                onPressed: () async {
                  final t = await showTimePicker(context: context, initialTime: _time);
                  if (t != null) setState(() => _time = t);
                },
                child: Text(_time.format(context), style: monoStyle(context, size: 15, color: nf.text, weight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: Space.xs),
            Text('Time zone: $tz', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
            const SizedBox(height: Space.lg),
            _Note(icon: Icons.computer_rounded, text: _deviceNote()),
            if (handoff.isNotEmpty) _Note(icon: Icons.notifications_active_outlined, text: '${handoff.join(', ')} ${handoff.length == 1 ? 'is a hand-off account' : 'are hand-off accounts'}: you will get a reminder to tap Post.'),
          ]),
        ),
      ),
      Divider(height: 1, color: nf.border),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.md, Space.xxl, Space.lg),
        child: Row(children: [
          if (widget.initial != null)
            TextButton(onPressed: () => Navigator.pop(context, kClearSchedule), style: TextButton.styleFrom(foregroundColor: nf.danger), child: const Text('Remove schedule')),
          const Spacer(),
          TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
          const SizedBox(width: Space.sm),
          Flexible(
            child: FilledButton(
              onPressed: past ? null : () => Navigator.pop(context, _when),
              child: Text(
                past ? 'Pick a future time' : (context.isCompact ? 'Schedule' : 'Schedule for ${DateFormat.MMMEd().add_jm().format(_when)}'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ]),
      ),
    ]);
  }

  static String _deviceNote() {
    if (Env.isIOS) return 'At the scheduled time you will get a notification; tap it to publish.';
    if (Env.isAndroid) return 'Posts go out in the background within a few minutes of their time.';
    if (Env.isDesktop) return 'Keep NEFORUM running (it stays in the tray when you close the window) and posts go out on time.';
    return 'Scheduling works in the installed apps; the web preview only stores the time.';
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: nf.textFaint),
        const SizedBox(width: Space.sm),
        Expanded(child: Text(text, style: context.text.bodySmall)),
      ]),
    );
  }
}
