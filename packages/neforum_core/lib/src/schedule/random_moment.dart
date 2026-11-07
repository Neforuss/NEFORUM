import 'dart:math';

import 'package:meta/meta.dart';

/// The furthest ahead a post can be scheduled. One constant for the calendar
/// and the random range: a longer range would hand the calendar a day past its
/// last day when the sheet is reopened.
const Duration kScheduleHorizon = Duration(days: 365);

/// A random time is at least this far ahead. It clears the lead every network
/// that holds posts asks for, except a big Tumblr upload, which validation
/// catches. A floor for the draw, not a promise.
const Duration kRandomScheduleMinLead = Duration(minutes: 15);

/// A time closer than this, or already past, is refused at Schedule: it would
/// go out at once.
const Duration kScheduleMinLead = Duration(minutes: 1);

/// Whether a post can still be scheduled for [at].
bool scheduleTimeAccepted(DateTime at, DateTime now) => !at.isBefore(now.add(kScheduleMinLead));

/// The wall clock of an instant: `year` to `minute` and `weekday` read as the
/// clock on the wall reads. Replaced in tests, since Windows cannot switch the
/// time zone of a process: a table of offsets returns a UTC [DateTime] holding
/// the wall clock's fields.
typedef WallClockOf = DateTime Function(int millisecondsSinceEpoch);

/// The moment a wall clock reading names, as this zone resolves it.
typedef MomentOf = DateTime Function(int year, int month, int day, int hour, int minute);

/// This device's time zone, or a table of one in tests.
@immutable
class LocalZone {
  const LocalZone({this.wallClockOf = _systemWallClock, this.momentOf = _systemMoment});

  final WallClockOf wallClockOf;
  final MomentOf momentOf;

  static DateTime _systemWallClock(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);
  static DateTime _systemMoment(int y, int mo, int d, int h, int mi) => DateTime(y, mo, d, h, mi);
}

/// The ranges offered for a random time.
enum RandomSchedulePreset {
  next24Hours(Duration(hours: 24)),
  next7Days(Duration(days: 7)),
  next30Days(Duration(days: 30)),
  next90Days(Duration(days: 90)),
  next365Days(kScheduleHorizon),
  custom(null);

  const RandomSchedulePreset(this.span);

  /// How far ahead the range ends. Null: the person picks the days.
  final Duration? span;
}

/// Instants from [start], up to but not including [end].
@immutable
class RandomScheduleRange {
  const RandomScheduleRange(this.start, this.end);

  final DateTime start;
  final DateTime end;

  int get _firstMinute => (start.millisecondsSinceEpoch + 59999) ~/ Duration.millisecondsPerMinute;
  int get _lastMinute => (end.millisecondsSinceEpoch - 1) ~/ Duration.millisecondsPerMinute;

  /// How many whole minutes can be drawn. A minute is an instant, so a day
  /// with a clock change has as many as it really lasts.
  int get minutes => max(0, _lastMinute - _firstMinute + 1);

  /// The first and last moment a draw can land on.
  DateTime get firstMoment => DateTime.fromMillisecondsSinceEpoch(_firstMinute * Duration.millisecondsPerMinute);
  DateTime get lastMoment => DateTime.fromMillisecondsSinceEpoch(_lastMinute * Duration.millisecondsPerMinute);
}

/// The next [span] from [now], kept inside the allowed limits. Elapsed time,
/// never calendar days: the end is always at most [kScheduleHorizon] away.
RandomScheduleRange randomScheduleRange(Duration span, DateTime now) {
  final limit = span > kScheduleHorizon ? kScheduleHorizon : span;
  return RandomScheduleRange(now.add(kRandomScheduleMinLead), now.add(limit));
}

/// From the start of [firstDay] to the end of [lastDay], local days named by
/// their year, month and day, kept inside the allowed limits. Null when no
/// whole minute is left.
RandomScheduleRange? customRandomScheduleRange({required DateTime firstDay, required DateTime lastDay, required DateTime now, LocalZone zone = const LocalZone()}) {
  final dayStart = localDayStart(firstDay.year, firstDay.month, firstDay.day, zone: zone);
  final nextDay = DateTime.utc(lastDay.year, lastDay.month, lastDay.day + 1);
  final dayEnd = localDayStart(nextDay.year, nextDay.month, nextDay.day, zone: zone);
  final earliest = now.add(kRandomScheduleMinLead);
  final latest = now.add(kScheduleHorizon);
  final range = RandomScheduleRange(dayStart.isBefore(earliest) ? earliest : dayStart, dayEnd.isAfter(latest) ? latest : dayEnd);
  return range.minutes == 0 ? null : range;
}

/// A whole-minute moment drawn evenly from [range], or null when it holds none.
/// The draw is over instants, not wall clock fields: a skipped hour has no
/// instants, so it cannot come up, and an hour that happens twice has two
/// hours' worth of them. Feb 29 needs no special case.
DateTime? randomMoment(RandomScheduleRange range, Random random) {
  final ms = randomMomentMs(range, random);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

/// [randomMoment] as milliseconds since the epoch: the draw itself, with no
/// conversion to the local zone.
int? randomMomentMs(RandomScheduleRange range, Random random) {
  final count = range.minutes;
  if (count == 0) return null;
  // Random.nextInt takes at most 2^32, about 8000 years of minutes.
  return (range._firstMinute + random.nextInt(count)) * Duration.millisecondsPerMinute;
}

/// The first instant of a local day: not always midnight, since a clock change
/// can skip midnight or repeat it. A day the zone skipped altogether gives the
/// first instant after it.
///
/// Reads the wall clock minute by minute over the 30 hours the day can start
/// in, about 10 ms, so it is for a button press and not a loop.
DateTime localDayStart(int year, int month, int day, {LocalZone zone = const LocalZone()}) {
  final utc = DateTime.utc(year, month, day);
  final wanted = _dayNumber(utc.year, utc.month, utc.day);
  const hours = 15;
  final first = utc.millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute - hours * 60;
  for (var m = first; m <= first + 2 * hours * 60; m++) {
    final ms = m * Duration.millisecondsPerMinute;
    final wall = zone.wallClockOf(ms);
    if (_dayNumber(wall.year, wall.month, wall.day) >= wanted) return DateTime.fromMillisecondsSinceEpoch(ms);
  }
  return DateTime.fromMillisecondsSinceEpoch(utc.millisecondsSinceEpoch);
}

int _dayNumber(int year, int month, int day) => year * 10000 + month * 100 + day;

/// The other instant that reads the same on the wall clock as [at], when clocks
/// went back around it (the second 1:30 AM), else null. Such a moment needs its
/// zone name to say which one it is.
DateTime? otherMomentWithSameWallClock(DateTime at, {LocalZone zone = const LocalZone()}) {
  final ms = at.millisecondsSinceEpoch;
  int offset(int instant) {
    final w = zone.wallClockOf(instant);
    return DateTime.utc(w.year, w.month, w.day, w.hour, w.minute).millisecondsSinceEpoch - instant ~/ Duration.millisecondsPerMinute * Duration.millisecondsPerMinute;
  }

  final own = offset(ms);
  const day = Duration.millisecondsPerDay;
  for (final other in {offset(ms - day), offset(ms + day)}) {
    if (other == own) continue;
    // The instant whose wall clock would be this one under the other offset.
    final twin = ms + own - other;
    if (offset(twin) == other) return DateTime.fromMillisecondsSinceEpoch(twin);
  }
  return null;
}
