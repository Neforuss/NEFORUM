import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../state/providers.dart';
import '../../state/settings.dart';

/// "14:05" or "2:05 PM". Explicit patterns: intl's own 12-hour pattern puts
/// a narrow no-break space before AM/PM.
DateFormat clockFormat({required bool use24Hour}) => DateFormat(use24Hour ? 'HH:mm' : 'h:mm a');

/// "now", "5 min ago", "3 h ago", "Yesterday, 14:05", "Tuesday, 14:05",
/// "Tue 14 Oct". Times are shown in local time whatever [t] holds.
String relativeTime(DateTime t, {DateTime? now, bool use24Hour = false}) {
  t = t.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  final d = n.difference(t);
  if (d.isNegative) return inFuture(t, now: n, use24Hour: use24Hour);
  if (d.inSeconds < 60) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24 && n.day == t.day) return '${d.inHours} h ago';
  final clock = clockFormat(use24Hour: use24Hour);
  final yesterday = DateTime(n.year, n.month, n.day).subtract(const Duration(days: 1));
  if (!t.isBefore(yesterday)) return 'Yesterday, ${clock.format(t)}';
  if (n.difference(t).inDays < 7) return '${DateFormat.EEEE().format(t)}, ${clock.format(t)}';
  if (t.year == n.year) return DateFormat('EEE d MMM').format(t);
  return DateFormat('d MMM y').format(t);
}

/// "in 20 min", "Today, 18:00", "Tomorrow, 09:30", "Thu 16 Oct, 09:30".
String inFuture(DateTime t, {DateTime? now, bool use24Hour = false}) {
  t = t.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  final d = t.difference(n);
  if (d.inMinutes < 1) return 'any moment';
  if (d.inMinutes < 60) return 'in ${d.inMinutes} min';
  return dayLabel(t, now: n, withTime: true, use24Hour: use24Hour);
}

/// "Today", "Tomorrow", "Thursday 16 October" (+ time).
String dayLabel(DateTime t, {DateTime? now, bool withTime = false, bool use24Hour = false}) {
  t = t.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = day.difference(today).inDays;
  final time = withTime ? ', ${clockFormat(use24Hour: use24Hour).format(t)}' : '';
  if (diff == 0) return 'Today$time';
  if (diff == 1) return 'Tomorrow$time';
  if (diff == -1) return 'Yesterday$time';
  if (diff > 1 && diff < 7) return '${DateFormat.EEEE().format(t)}$time';
  return '${DateFormat(t.year == n.year ? 'EEE d MMM' : 'd MMM y').format(t)}$time';
}

/// Midnight of the (local) day [t] falls on.
DateTime dayOf(DateTime t) {
  t = t.toLocal();
  return DateTime(t.year, t.month, t.day);
}

/// How Activity, the Queue and post details write times: relative or exact
/// (Settings > Activity and history > Times), on a 12- or 24-hour clock.
@immutable
class TimeFormatting {
  const TimeFormatting({this.exact = false, this.use24Hour = false});

  /// From the settings, rebuilding when they change (for build methods).
  factory TimeFormatting.of(BuildContext context, WidgetRef ref) => TimeFormatting.from(ref.watch(settingsProvider), context);

  /// From [s]; the System clock follows the device's own choice.
  factory TimeFormatting.from(AppSettings s, BuildContext context) => TimeFormatting(
        exact: s.timestampDisplay == TimestampDisplay.exact,
        use24Hour: switch (s.clockFormat) {
          ClockFormat.twelveHour => false,
          ClockFormat.twentyFourHour => true,
          ClockFormat.system => MediaQuery.alwaysUse24HourFormatOf(context),
        },
      );

  final bool exact;
  final bool use24Hour;

  /// "14:05" or "2:05 PM".
  String clock(DateTime t) => clockFormat(use24Hour: use24Hour).format(t.toLocal());

  /// "Saturday, 24 October 2026".
  String date(DateTime t) => DateFormat('EEEE, d MMMM y').format(t.toLocal());

  /// "Saturday, 24 October 2026, 14:05", whatever the setting.
  String exactTime(DateTime t) => '${date(t)}, ${clock(t)}';

  /// A moment in the past (or future): relative or exact.
  String moment(DateTime t, {DateTime? now}) => exact ? exactTime(t) : relativeTime(t, now: now, use24Hour: use24Hour);

  /// A scheduled moment: "Tomorrow, 09:30", or exact.
  String scheduled(DateTime t, {DateTime? now}) => exact ? exactTime(t) : dayLabel(t, now: now, withTime: true, use24Hour: use24Hour);

  /// A day heading: "Tomorrow", or "Saturday, 24 October 2026".
  String day(DateTime t, {DateTime? now}) => exact ? date(t) : dayLabel(t, now: now);
}
