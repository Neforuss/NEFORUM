import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../platform/env.dart';
import '../../state/account_connection.dart';
import '../../state/automatic_handoff.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/buttons.dart';
import '../../widgets/surfaces.dart';
import '../activity/time_format.dart';
import '../shell/notification_prompt.dart';
import 'schedule_notes.dart';

/// What the schedule sheet takes from the device. Replaced in tests: the clock,
/// a seeded draw, and a time zone Windows cannot switch to.
@immutable
class ScheduleSheetEnvironment {
  const ScheduleSheetEnvironment({required this.clock, required this.random, this.zone = const LocalZone(), this.device});
  final Clock clock;
  final Random random;
  final LocalZone zone;

  /// Null: this device.
  final ScheduleDevice? device;
}

final scheduleSheetEnvironmentProvider = Provider<ScheduleSheetEnvironment>((ref) => ScheduleSheetEnvironment(clock: ref.watch(scheduleClockProvider), random: Random.secure()));

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

/// The sheet's quick picks at [now], worked out on the calendar: a day is not
/// always 24 hours, so "tomorrow" is never now plus 24 hours.
List<(String, DateTime)> scheduleQuickPicks(DateTime now, {LocalZone zone = const LocalZone()}) {
  DateTime at(int days, int hour) => zone.momentOf(now.year, now.month, now.day + days, hour, 0);
  final daysToMonday = (DateTime.monday - now.weekday + 7) % 7;
  final picks = <(String, DateTime)>[
    ('In 1 hour', roundUpToQuarter(now.add(const Duration(hours: 1)))),
    ('This evening', at(0, 19)),
    ('Tomorrow morning', at(1, 9)),
    ('Next Monday', at(daysToMonday == 0 ? 7 : daysToMonday, 9)),
  ];
  return picks.where((p) => p.$2.isAfter(now.add(const Duration(minutes: 5)))).toList();
}

/// The next quarter of an hour at or after [t], by elapsed time: recomposing the
/// wall clock would move a time in a repeated hour to its first pass.
DateTime roundUpToQuarter(DateTime t) {
  final past = (t.minute % 15) * Duration.microsecondsPerMinute + t.second * Duration.microsecondsPerSecond + t.millisecond * 1000 + t.microsecond;
  return past == 0 ? t : t.add(Duration(microseconds: 15 * Duration.microsecondsPerMinute - past));
}

class ScheduleSheet extends ConsumerStatefulWidget {
  const ScheduleSheet({super.key, this.initial, this.post});
  final DateTime? initial;
  final Post? post;

  @override
  ConsumerState<ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends ConsumerState<ScheduleSheet> {
  static final Logger _log = Logger('schedule');

  late final ScheduleSheetEnvironment _env = ref.read(scheduleSheetEnvironmentProvider);
  DateTime get _now => _env.clock();

  late DateTime _day;
  late TimeOfDay _time;

  /// The exact moment, while the day and time have not been edited. A wall
  /// clock can name two instants, so recomposing [_day] and [_time] could move
  /// a post by an hour (the second 1:30 AM) just by opening the sheet.
  DateTime? _exact;

  /// "Different time per network" (composer only), with each account's time.
  bool _eachTarget = false;
  final Map<String, DateTime> _times = {};

  /// The random time panel. Its draws touch nothing until Schedule is pressed.
  bool _randomOpen = false;
  RandomSchedulePreset _preset = RandomSchedulePreset.next7Days;
  DateTime? _customFirst;
  DateTime? _customLast;
  RandomScheduleRange? _range;
  DateTime? _draw;
  final Map<String, DateTime> _draws = {};

  /// Time ran out while the sheet stayed open and Schedule was refused.
  bool _refused = false;

  /// Back to the top when the panel changes: the new one starts with its choices,
  /// and the old one's scroll position would land in the middle of it.
  final ScrollController _scroll = ScrollController();

  void _toTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final base = widget.initial ?? roundUpToQuarter(_now.add(const Duration(hours: 1)));
    _setMoment(base);
    if (widget.post == null) {
      final c = ref.read(composerProvider);
      _eachTarget = c.schedulesEachTarget;
      for (final id in c.selected) {
        final at = c.overrides[id]?.scheduledAt;
        if (at != null) _times[id] = at;
      }
    }
  }

  void _setMoment(DateTime at) {
    _day = DateTime(at.year, at.month, at.day);
    _time = TimeOfDay(hour: at.hour, minute: at.minute);
    _exact = at;
  }

  /// The day and time as picked.
  DateTime get _picked => _exact ?? _env.zone.momentOf(_day.year, _day.month, _day.day, _time.hour, _time.minute);

  DateTime get _when => _randomOpen ? (_draw ?? _picked) : _picked;

  /// Networks that already have an edited post. They keep their outcome and
  /// their time, so no draw is made for them.
  Set<String> _done = const {};

  DateTime _timeOf(String accountId) => _randomOpen && !_done.contains(accountId) ? (_draws[accountId] ?? _when) : (_times[accountId] ?? _picked);

  /// The first and last day the calendars offer. The day already picked always
  /// fits: a stale schedule, or one from a device with another clock, must not
  /// break the calendar.
  DateTime _firstDay(DateTime current) {
    final first = _now.subtract(const Duration(days: 1));
    return current.isBefore(first) ? current : first;
  }

  DateTime _lastDay(DateTime current) {
    final last = _now.add(kScheduleHorizon);
    return current.isAfter(last) ? current : last;
  }

  /// [_eachTarget] on or off. On, every network starts at the time picked so
  /// far; off, the post goes at the earliest of the networks' times.
  void _setEachTarget(bool on, List<ConnectedAccount> accounts) => setState(() {
        _eachTarget = on;
        if (_randomOpen) {
          _drawAgain(accounts);
          return;
        }
        if (on) {
          for (final a in accounts) {
            _times.putIfAbsent(a.id, () => _picked);
          }
          return;
        }
        final times = [for (final a in accounts) ?_times[a.id]];
        if (times.isEmpty) return;
        _setMoment(times.reduce((a, b) => a.isBefore(b) ? a : b));
      });

  Future<void> _pickTargetTime(String accountId) async {
    final current = _times[accountId] ?? _picked;
    final day = await showDatePicker(context: context, initialDate: current, firstDate: _firstDay(current), lastDate: _lastDay(current));
    if (day == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (time == null || !mounted) return;
    setState(() {
      _refused = false;
      _times[accountId] = _env.zone.momentOf(day.year, day.month, day.day, time.hour, time.minute);
    });
  }

  RandomScheduleRange? _rangeNow() {
    final span = _preset.span;
    if (span != null) return randomScheduleRange(span, _now);
    final first = _customFirst, last = _customLast;
    if (first == null || last == null) return null;
    return customRandomScheduleRange(firstDay: first, lastDay: last, now: _now, zone: _env.zone);
  }

  /// A new draw for the whole post, or one per account.
  void _drawAgain(List<ConnectedAccount> accounts) {
    _refused = false;
    final range = _rangeNow();
    _range = range;
    _draw = null;
    _draws.clear();
    if (range == null) return;
    if (_eachTarget && accounts.length > 1) {
      for (final a in accounts) {
        if (_done.contains(a.id)) continue;
        final at = randomMoment(range, _env.random);
        if (at != null) _draws[a.id] = at;
      }
      if (_draws.isNotEmpty) _draw = _earliest(_draws.values);
    } else {
      _draw = randomMoment(range, _env.random);
    }
    // The trace: the range and how it was drawn, never an account.
    _log.debug('random time: ${range.minutes} minutes, ${_preset.name}, ${_draws.isEmpty ? 'one time' : '${_draws.length} times'}');
  }

  void _drawAgainFor(String accountId) {
    final range = _rangeNow();
    final at = range == null ? null : randomMoment(range, _env.random);
    if (at == null) return;
    _refused = false;
    _range = range;
    _draws[accountId] = at;
    _draw = _earliest(_draws.values);
  }

  static DateTime _earliest(Iterable<DateTime> times) => times.reduce((a, b) => a.isBefore(b) ? a : b);

  Future<void> _choosePreset(RandomSchedulePreset preset, List<ConnectedAccount> accounts) async {
    if (preset == RandomSchedulePreset.custom) {
      final now = _now;
      final first = DateTime(now.year, now.month, now.day);
      final last = now.add(kScheduleHorizon);
      final from = _customFirst, to = _customLast;
      final picked = await showDateRangePicker(
        context: context,
        firstDate: first,
        lastDate: last,
        currentDate: now,
        initialDateRange: from == null || to == null || from.isBefore(first) || to.isAfter(last) ? null : DateTimeRange(start: from, end: to),
        helpText: 'Pick a range',
        saveText: 'Use this range',
      );
      if (picked == null || !mounted) return;
      _customFirst = picked.start;
      _customLast = picked.end;
    }
    setState(() {
      _preset = preset;
      _drawAgain(accounts);
    });
  }

  /// Confirms the sheet. In the composer, the times per network (or none)
  /// are written to the post first; the sheet returns the earliest time.
  /// The only place anything leaves the sheet: Cancel and every draw before
  /// this leave the composer as it was.
  void _confirm(List<ConnectedAccount> accounts, Set<String> done, bool each) {
    // Checked again: the time was fine when the button was drawn, but the sheet
    // may have stayed open for a long while since.
    if (_tooClose(accounts, done, each)) {
      _log.debug('schedule refused: the time is under ${kScheduleMinLead.inSeconds} s ahead');
      setState(() => _refused = true);
      return;
    }
    if (widget.post != null) {
      Navigator.pop(context, _when);
      return;
    }
    final notifier = ref.read(composerProvider.notifier);
    // What the sheet shows decides, not the switch's last state: with one network
    // left the times per network are gone from the screen, so a saved one must
    // not replace the time just picked.
    if (!each || accounts.isEmpty) {
      notifier.setTargetSchedules(null);
      Navigator.pop(context, _when);
      return;
    }
    final times = {for (final a in accounts) a.id: _timeOf(a.id)};
    notifier.setTargetSchedules(times);
    // The post's time is the next one still to go, never one already past.
    final ahead = [for (final e in times.entries) if (!done.contains(e.key)) e.value];
    Navigator.pop(context, _earliest(ahead.isEmpty ? times.values : ahead));
  }

  bool _tooClose(List<ConnectedAccount> accounts, Set<String> done, bool each) {
    final now = _now;
    if (each) return accounts.any((a) => !done.contains(a.id) && !scheduleTimeAccepted(_timeOf(a.id), now));
    return !scheduleTimeAccepted(_when, now);
  }

  /// The post as it would be saved for the times on screen, for the same
  /// decision the hand-over makes.
  Post _postAtTheseTimes(ComposerState? composing, Post? existing, bool each, DateTime now) {
    final saved = widget.post;
    if (saved != null) {
      // Rescheduling takes back what platforms hold, then hands it over anew.
      final released = saved.copyWith(targets: [
        for (final t in saved.targets) t.isHeldByPlatform ? t.copyWith(status: TargetStatus.pending, clearResult: true) : t,
      ]);
      return rescheduledPost(released, _when, now);
    }
    final post = composing!.toPost(id: composing.editingPostId ?? 'preview', status: PostStatus.scheduled, now: now);
    PostTarget kept(PostTarget t) {
      final old = existing?.targetFor(t.accountId);
      return old != null && old.isDone ? old : t;
    }

    return post.copyWith(scheduledAt: _when, targets: [
      for (final t in post.targets)
        kept(t).copyWith(overrides: each ? t.overrides.copyWith(scheduledAt: _timeOf(t.accountId)) : t.overrides.copyWith(clearScheduledAt: true)),
    ]);
  }

  /// "Thu, Dec 3, 2026, 4:17 PM".
  String _moment(DateTime t, TimeFormatting format) => '${DateFormat('EEE, MMM d, y').format(t)}, ${format.clock(t)}';

  String _rangeWords(RandomScheduleRange r, TimeFormatting format) {
    final first = r.firstMoment, last = r.lastMoment;
    final zone = first.timeZoneName == last.timeZoneName ? first.timeZoneName : 'local time';
    return 'Any minute from ${_moment(first, format)} to ${_moment(last, format)}, $zone. Every minute is equally likely.';
  }

  /// Names the zone and, when the wall clock reads the same twice, which of the
  /// two this is.
  String _zoneWords(DateTime at) {
    final name = at.timeZoneName;
    return otherMomentWithSameWallClock(at, zone: _env.zone) == null ? 'Time zone: $name' : 'This time happens twice that day. This is the one in $name.';
  }

  /// The zone name, only when the wall clock reads the same twice that day: a
  /// row per network has no room for a sentence.
  String _whichOfTwo(DateTime at) => otherMomentWithSameWallClock(at, zone: _env.zone) == null ? '' : ' (${at.timeZoneName})';

  static String _presetLabel(RandomSchedulePreset p) => switch (p) {
        RandomSchedulePreset.next24Hours => 'Next 24 hours',
        RandomSchedulePreset.next7Days => 'Next 7 days',
        RandomSchedulePreset.next30Days => 'Next 30 days',
        RandomSchedulePreset.next90Days => 'Next 90 days',
        RandomSchedulePreset.next365Days => 'Next 365 days',
        RandomSchedulePreset.custom => 'Custom',
      };

  Widget _randomPanel(List<(ConnectedAccount, String)> rows, List<ConnectedAccount> accounts, bool each, TimeFormatting format) {
    final nf = context.nf;
    final range = _range;
    final draw = _draw;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(Icons.casino_outlined, color: nf.textMuted, size: 20),
        const SizedBox(width: Space.sm),
        Expanded(child: Text('Pick a random time', style: context.text.titleSmall)),
        TextButton(
          onPressed: () {
            setState(() {
              _randomOpen = false;
              _refused = false;
            });
            _toTop();
          },
          child: const Text('Choose a date'),
        ),
      ]),
      const SizedBox(height: Space.sm),
      Wrap(spacing: Space.sm, runSpacing: Space.xs, children: [
        for (final p in RandomSchedulePreset.values)
          ChoiceChip(label: Text(_presetLabel(p)), selected: _preset == p, onSelected: (_) => _choosePreset(p, accounts)),
      ]),
      const SizedBox(height: Space.md),
      if (range != null)
        Text(_rangeWords(range, format), style: context.text.bodySmall)
      else
        Text('No time fits this range. Choose another one.', style: context.text.bodySmall?.copyWith(color: nf.danger)),
      const SizedBox(height: Space.md),
      if (draw != null && !each)
        NfWell(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_moment(draw, format), key: const ValueKey('random-time'), style: context.text.titleLarge),
            const SizedBox(height: Space.xs),
            Text(_zoneWords(draw), style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
          ]),
        ),
      if (each)
        for (final (a, name) in rows.where((r) => !_done.contains(r.$1.id)))
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Row(children: [
              AccountAvatar(a, size: 28),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: context.text.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (_draws[a.id] case final at?) Text('${_moment(at, format)}${_whichOfTwo(at)}', key: ValueKey('random-time-${a.id}'), style: context.text.bodySmall),
                ]),
              ),
              ToolButton(
                icon: Icons.casino_outlined,
                size: 48,
                tooltip: 'Another time for $name',
                onPressed: range == null ? null : () => setState(() => _drawAgainFor(a.id)),
              ),
            ]),
          ),
      const SizedBox(height: Space.sm),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          onPressed: () => setState(() => _drawAgain(accounts)),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Try another'),
        ),
      ),
      if (_refused) ...[
        const SizedBox(height: Space.sm),
        Text('That time is too close now. Try another.', style: context.text.bodySmall?.copyWith(color: nf.danger)),
      ],
      const SizedBox(height: Space.lg),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final settings = ref.watch(settingsProvider);
    final registry = ref.watch(registryProvider);
    final services = ref.watch(servicesProvider);
    final allAccounts = ref.watch(accountListProvider);
    final statuses = ref.watch(signInStatusesProvider).value ?? const <String, SignInStatus>{};
    final now = _now;

    // (account, the network's name) for every target of the post.
    final rows = <(ConnectedAccount, String)>[];
    ComposerState? composing;
    Post? existing;
    if (widget.post == null) {
      final c = ref.watch(composerProvider);
      composing = c;
      final editing = c.editingPostId;
      existing = editing == null ? null : ref.watch(postByIdProvider(editing));
      for (final p in ref.watch(composerPreviewsProvider)) {
        rows.add((p.account, p.descriptor.name));
      }
    } else {
      for (final t in widget.post!.targets) {
        final a = ref.watch(accountByIdProvider(t.accountId));
        final d = a == null ? null : registry.byId(a.platformId)?.descriptorForAccount(a);
        if (a != null && d != null) rows.add((a, d.name));
      }
    }
    final accounts = [for (final r in rows) r.$1];
    // Networks that already have an edited post keep their outcome and time.
    final done = {
      if (existing != null)
        for (final t in existing.targets)
          if (t.isDone) t.accountId,
    };
    _done = done;
    // A different time per network: only while composing, for two or more.
    final canEach = widget.post == null && rows.length > 1;
    final each = canEach && _eachTarget;
    final tooClose = _tooClose(accounts, done, each);
    final format = TimeFormatting.of(context, ref);

    final notes = scheduleNotes(
      scheduleNoteTargets(
        post: _postAtTheseTimes(composing, existing, each, now),
        accounts: allAccounts,
        registry: registry,
        resolver: VariantResolver(settings.resolverOptions),
        statuses: statuses,
        delegateSchedules: settings.delegateSchedules,
        now: now,
        automaticHandoff: (a) => automaticPostingAppliesTo(services, a, allAccounts),
      ),
      now: now,
      device: _env.device ?? ScheduleDevice.current,
      // Linux has a tray only while a panel offers one, which takes a question to ask.
      closeKeepsRunning: settings.minimizeToTray && !Env.isLinux,
      clock: format.clock,
    );

    final picked = _picked;
    // The clock has no such time on that day: the post goes at the real one.
    final moved = _exact == null && (picked.hour != _time.hour || picked.minute != _time.minute);

    final randomCard = NfCard(
      padding: const EdgeInsets.all(Space.md),
      onTap: () {
        setState(() {
          _randomOpen = true;
          _drawAgain(accounts);
        });
        _toTop();
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Pick a random time', style: context.text.labelLarge),
        const SizedBox(height: 2),
        Text('Any minute in a range', style: context.text.bodySmall),
      ]),
    );

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.xxl, Space.sm),
        child: Text('Schedule post', style: context.text.headlineSmall),
      ),
      const NotificationHintLine(scheduling: true),
      Flexible(
        child: SingleChildScrollView(
          controller: _scroll,
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
            if (_randomOpen)
              _randomPanel(rows, accounts, each, format)
            else if (each) ...[
              randomCard,
              const SizedBox(height: Space.md),
              for (final (a, name) in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.sm),
                  child: Row(children: [
                    AccountAvatar(a, size: 28),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(name, style: context.text.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(a.handle ?? a.displayName,
                            style: context.text.bodySmall?.copyWith(color: nf.textFaint), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    const SizedBox(width: Space.sm),
                    Flexible(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickTargetTime(a.id),
                        icon: const Icon(Icons.schedule_rounded, size: 16),
                        label: Text(
                          '${format.scheduled(_timeOf(a.id))}${_whichOfTwo(_timeOf(a.id))}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: _timeOf(a.id).isAfter(now) ? nf.text : nf.danger),
                        ),
                      ),
                    ),
                  ]),
                ),
              const SizedBox(height: Space.xs),
              Text('Time zone: ${_timeOf(accounts.first.id).timeZoneName}', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
              if (_refused) ...[
                const SizedBox(height: Space.xs),
                Text('A time is too close now. Pick a later one.', style: context.text.bodySmall?.copyWith(color: nf.danger)),
              ],
              const SizedBox(height: Space.lg),
            ] else ...[
              LayoutBuilder(builder: (context, c) {
                final cols = c.maxWidth > 480 ? 4 : 2;
                final width = (c.maxWidth - Space.sm * (cols - 1)) / cols;
                return Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
                  for (final p in scheduleQuickPicks(now, zone: _env.zone))
                    SizedBox(
                      width: width,
                      child: NfCard(
                        padding: const EdgeInsets.all(Space.md),
                        selected: picked == p.$2,
                        onTap: () => setState(() {
                          _refused = false;
                          _setMoment(p.$2);
                        }),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(p.$1, style: context.text.labelLarge),
                          const SizedBox(height: 2),
                          Text(_quickPickWhen(p), style: context.text.bodySmall),
                        ]),
                      ),
                    ),
                  SizedBox(width: width, child: randomCard),
                ]);
              }),
              const SizedBox(height: Space.lg),
              NfWell(
                padding: const EdgeInsets.all(Space.sm),
                child: CalendarDatePicker(
                  initialDate: _day,
                  firstDate: _firstDay(_day),
                  lastDate: _lastDay(_day),
                  onDateChanged: (d) => setState(() {
                    _refused = false;
                    _day = d;
                    _exact = null;
                  }),
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
                    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(picked));
                    if (t != null && mounted) {
                      setState(() {
                        _refused = false;
                        _time = t;
                        _exact = null;
                      });
                    }
                  },
                  // The time this post really goes at, whatever was typed in.
                  child: Text(TimeOfDay.fromDateTime(picked).format(context), style: monoStyle(context, size: 15, color: nf.text, weight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: Space.xs),
              if (moved) ...[
                Text(
                  '${_time.format(context)} does not exist on ${DateFormat.MMMd().format(picked)}: the clocks skip it. This post goes at ${format.clock(picked)}.',
                  style: context.text.bodySmall?.copyWith(color: nf.warning),
                ),
                const SizedBox(height: Space.xs),
              ],
              Text(_zoneWords(picked), style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
              if (_refused) ...[
                const SizedBox(height: Space.xs),
                Text('That time is too close now. Pick a later one.', style: context.text.bodySmall?.copyWith(color: nf.danger)),
              ],
              const SizedBox(height: Space.lg),
            ],
            for (final note in notes) _Note(note: note),
          ]),
        ),
      ),
      Divider(height: 1, color: nf.border),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.md, Space.xxl, Space.lg),
        // Stacks rather than overflows with a large text size on a phone.
        child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: Space.sm, runSpacing: Space.xs, children: [
          if (widget.initial != null)
            TextButton(onPressed: () => Navigator.pop(context, kClearSchedule), style: TextButton.styleFrom(foregroundColor: nf.danger), child: const Text('Remove schedule')),
          TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
          FilledButton(
            onPressed: tooClose || (_randomOpen && _draw == null) ? null : () => _confirm(accounts, done, each),
            child: Text(
              _randomOpen && tooClose
                  ? 'Try another first'
                  : tooClose
                      ? (each ? 'Pick future times' : 'Pick a future time')
                      : (context.isCompact || each ? 'Schedule' : 'Schedule for ${DateFormat.MMMEd().add_jm().format(_when)}'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      ),
    ]);
  }

  static String _quickPickWhen((String, DateTime) pick) {
    final at = pick.$2;
    final clock = DateFormat.jm().format(at);
    return switch (pick.$1) {
      'In 1 hour' => clock,
      'This evening' => 'Today, $clock',
      'Tomorrow morning' => '${DateFormat.E().format(at)}, $clock',
      _ => '${DateFormat.MMMd().format(at)}, $clock',
    };
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.note});
  final ScheduleNote note;

  static IconData _icon(ScheduleNoteKind kind) => switch (kind) {
        ScheduleNoteKind.signInEnded ||
        ScheduleNoteKind.signInRefused ||
        ScheduleNoteKind.signInEndsFirst ||
        ScheduleNoteKind.signInRenewsFirst ||
        ScheduleNoteKind.signInDeadlineFirst =>
          Icons.key_off_rounded,
        ScheduleNoteKind.turnedOff => Icons.block_rounded,
        ScheduleNoteKind.nightTimeTap => Icons.bedtime_outlined,
        ScheduleNoteKind.farAwayOnDevice => Icons.event_outlined,
        ScheduleNoteKind.beyondHold => Icons.info_outline_rounded,
        ScheduleNoteKind.heldByPlatform => Icons.cloud_done_outlined,
        ScheduleNoteKind.deviceOn => Icons.computer_rounded,
        ScheduleNoteKind.handoff || ScheduleNoteKind.automaticHandoff => Icons.notifications_active_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final color = switch (note.tone) {
      ScheduleNoteTone.danger => nf.danger,
      ScheduleNoteTone.warning => nf.warning,
      ScheduleNoteTone.info => nf.textFaint,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(_icon(note.kind), size: 16, color: color),
        const SizedBox(width: Space.sm),
        Expanded(child: Text(note.text, style: context.text.bodySmall)),
      ]),
    );
  }
}
