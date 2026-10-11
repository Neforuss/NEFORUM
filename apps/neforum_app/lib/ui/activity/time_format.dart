import 'package:intl/intl.dart';

/// "now", "5 min ago", "3 h ago", "Yesterday", "Tue 14 Oct".
String relativeTime(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = n.difference(t);
  if (d.isNegative) return inFuture(t, now: n);
  if (d.inSeconds < 60) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24 && n.day == t.day) return '${d.inHours} h ago';
  final yesterday = DateTime(n.year, n.month, n.day).subtract(const Duration(days: 1));
  if (!t.isBefore(yesterday)) return 'Yesterday, ${DateFormat.jm().format(t)}';
  if (n.difference(t).inDays < 7) return DateFormat('EEEE, ').add_jm().format(t);
  if (t.year == n.year) return DateFormat('EEE d MMM').format(t);
  return DateFormat('d MMM y').format(t);
}

/// "in 20 min", "Today, 18:00", "Tomorrow, 09:30", "Thu 16 Oct, 09:30".
String inFuture(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = t.difference(n);
  if (d.inMinutes < 1) return 'any moment';
  if (d.inMinutes < 60) return 'in ${d.inMinutes} min';
  return dayLabel(t, now: n, withTime: true);
}

/// "Today", "Tomorrow", "Thursday 16 October" (+ time).
String dayLabel(DateTime t, {DateTime? now, bool withTime = false}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = day.difference(today).inDays;
  final time = withTime ? ', ${DateFormat.jm().format(t)}' : '';
  if (diff == 0) return 'Today$time';
  if (diff == 1) return 'Tomorrow$time';
  if (diff == -1) return 'Yesterday$time';
  if (diff > 1 && diff < 7) return '${DateFormat.EEEE().format(t)}$time';
  return '${DateFormat(t.year == n.year ? 'EEE d MMM' : 'd MMM y').format(t)}$time';
}

/// Midnight of the day [t] falls on.
DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);
