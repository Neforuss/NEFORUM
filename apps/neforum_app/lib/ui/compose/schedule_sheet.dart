import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../platform/env.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/surfaces.dart';
import '../activity/time_format.dart';

/// Picks a date and time for the post. Returns null when cancelled; a
/// `DateTime(0)` sentinel means "clear the schedule". Pass [post] when
/// rescheduling an existing post (otherwise the composer's targets are used).
Future<DateTime?> showScheduleSheet(BuildContext context, {DateTime? initial, Post? post}) {
  final sheet = ScheduleSheet(initial: initial, post: post);
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
  const ScheduleSheet({super.key, this.initial, this.post});
  final DateTime? initial;
  final Post? post;

  @override
  ConsumerState<ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends ConsumerState<ScheduleSheet> {
  late DateTime _day;
  late TimeOfDay _time;

  /// "Different time per network" (composer only), with each account's time.
  bool _eachTarget = false;
  final Map<String, DateTime> _times = {};

  @override
  void initState() {
    super.initState();
    final base = widget.initial ?? _roundUp(DateTime.now().add(const Duration(hours: 1)));
    _day = DateTime(base.year, base.month, base.day);
    _time = TimeOfDay(hour: base.hour, minute: base.minute);
    if (widget.post == null) {
      final c = ref.read(composerProvider);
      _eachTarget = c.schedulesEachTarget;
      for (final id in c.selected) {
        final at = c.overrides[id]?.scheduledAt;
        if (at != null) _times[id] = at;
      }
    }
  }

  /// [_eachTarget] on or off. On, every network starts at the time picked so
  /// far; off, the post goes at the earliest of the networks' times.
  void _setEachTarget(bool on, List<ConnectedAccount> accounts) => setState(() {
        _eachTarget = on;
        if (on) {
          for (final a in accounts) {
            _times.putIfAbsent(a.id, () => _when);
          }
          return;
        }
        final times = [for (final a in accounts) ?_times[a.id]];
        if (times.isEmpty) return;
        final first = times.reduce((a, b) => a.isBefore(b) ? a : b);
        _day = DateTime(first.year, first.month, first.day);
        _time = TimeOfDay(hour: first.hour, minute: first.minute);
      });

  Future<void> _pickTargetTime(String accountId) async {
    final current = _times[accountId] ?? _when;
    final day = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (time == null || !mounted) return;
    setState(() => _times[accountId] = DateTime(day.year, day.month, day.day, time.hour, time.minute));
  }

  /// Confirms the sheet. In the composer, the times per network (or none)
  /// are written to the post first; the sheet returns the earliest time.
  void _confirm(List<ConnectedAccount> accounts) {
    if (widget.post != null) {
      Navigator.pop(context, _when);
      return;
    }
    final notifier = ref.read(composerProvider.notifier);
    if (!_eachTarget || accounts.isEmpty) {
      notifier.setTargetSchedules(null);
      Navigator.pop(context, _when);
      return;
    }
    final times = {for (final a in accounts) a.id: _times[a.id] ?? _when};
    notifier.setTargetSchedules(times);
    Navigator.pop(context, times.values.reduce((a, b) => a.isBefore(b) ? a : b));
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
    final settings = ref.watch(settingsProvider);
    final registry = ref.watch(registryProvider);
    // (account, platform, is a thread) for every target of the post.
    final targets = <(ConnectedAccount, PlatformDescriptor, bool)>[];
    if (widget.post == null) {
      for (final p in ref.watch(composerPreviewsProvider)) {
        targets.add((p.account, p.descriptor, p.variant.isThread));
      }
    } else {
      for (final t in widget.post!.targets) {
        final a = ref.watch(accountByIdProvider(t.accountId));
        final d = a == null ? null : registry.byId(a.platformId)?.descriptorForAccount(a);
        if (a != null && d != null) targets.add((a, d, false));
      }
    }
    final handoff = {for (final t in targets) if (t.$1.tier == PlatformTier.handoff) t.$2.name};
    final held = {
      for (final t in targets)
        if (settings.delegateSchedules && t.$1.tier.isAutomatic && t.$2.serverSideScheduling && !t.$3) t.$2.name,
    };
    final onDevice = {for (final t in targets) if (t.$1.tier.isAutomatic && !held.contains(t.$2.name)) t.$2.name};
    final accounts = [for (final t in targets) t.$1];
    // A different time per network: only while composing, for two or more.
    final canEach = widget.post == null && targets.length > 1;
    final each = canEach && _eachTarget;
    final now = DateTime.now();
    final past = each ? accounts.any((a) => !(_times[a.id] ?? _when).isAfter(now)) : !_when.isAfter(now);
    final tz = DateTime.now().timeZoneName;
    final format = TimeFormatting.of(context, ref);

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.xxl, Space.sm),
        child: Text('Schedule post', style: context.text.headlineSmall),
      ),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (canEach) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Different time per network', style: context.text.titleSmall),
                // NEFORUM 1.2 knows only the post's time, which is the earliest.
                subtitle: Text(
                    each
                        ? 'Each network goes out at its own time. A synced device with NEFORUM 1.2 would post to every network at the earliest time.'
                        : 'Same time for all networks.',
                    style: context.text.bodySmall),
                value: each,
                onChanged: (on) => _setEachTarget(on, accounts),
              ),
              const SizedBox(height: Space.sm),
            ],
            if (each) ...[
              for (final t in targets)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.sm),
                  child: Row(children: [
                    AccountAvatar(t.$1, size: 28),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t.$2.name, style: context.text.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(t.$1.handle ?? t.$1.displayName,
                            style: context.text.bodySmall?.copyWith(color: nf.textFaint), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    const SizedBox(width: Space.sm),
                    Flexible(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickTargetTime(t.$1.id),
                        icon: const Icon(Icons.schedule_rounded, size: 16),
                        label: Text(
                          format.scheduled(_times[t.$1.id] ?? _when),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: (_times[t.$1.id] ?? _when).isAfter(now) ? nf.text : nf.danger),
                        ),
                      ),
                    ),
                  ]),
                ),
              const SizedBox(height: Space.xs),
              Text('Time zone: $tz', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
              const SizedBox(height: Space.lg),
            ] else ...[
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
            ],
            if (held.isNotEmpty)
              _Note(
                icon: Icons.cloud_done_outlined,
                text: '${_join(held)} will hold this post and publish it ${held.length == 1 ? 'itself' : 'themselves'}, even if this device is off.',
              ),
            if (onDevice.isNotEmpty || targets.isEmpty) _Note(icon: Icons.computer_rounded, text: onDevice.isEmpty ? _cap(_deviceNote()) : '${_join(onDevice)}: ${_deviceNote()}'),
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
              onPressed: past ? null : () => _confirm(accounts),
              child: Text(
                past
                    ? (each ? 'Pick future times' : 'Pick a future time')
                    : (context.isCompact || each ? 'Schedule' : 'Schedule for ${DateFormat.MMMEd().add_jm().format(_when)}'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ]),
      ),
    ]);
  }

  static String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  static String _join(Set<String> names) {
    final l = names.toList();
    if (l.length == 1) return l.first;
    return '${l.sublist(0, l.length - 1).join(', ')} and ${l.last}';
  }

  static String _deviceNote() {
    if (Env.isIOS) return 'at the scheduled time you get a notification with a Publish now button (iOS does not let apps post on a timer).';
    if (Env.isAndroid) return 'goes out in the background within a few minutes of its time.';
    if (Env.isDesktop) return 'keep NEFORUM running (it stays in the tray when you close the window) and it goes out on time.';
    return 'scheduling works in the installed apps; the web preview only stores the time.';
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
