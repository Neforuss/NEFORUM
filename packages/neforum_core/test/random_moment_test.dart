// The random schedule's sampler against zone tables: a day can have 23, 24 or
// 25 hours, can start at 01:00 or repeat its midnight, and a change can be 30
// minutes. Windows cannot switch the zone of a process, so the zones are tables
// here and real ones in random_moment_real_zone_test.dart on Linux.
//
// Tagged: a few seconds on a busy machine. `dart test -x property` leaves it out.
@Tags(['property'])
library;

import 'dart:math';

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

/// A time zone as a list of offset changes.
class ZoneTable {
  ZoneTable(this.name, this.startOffsetMinutes, List<(DateTime, int)> changes)
      : _changeMs = [for (final (at, _) in changes) at.millisecondsSinceEpoch],
        _offsetMs = [for (final (_, offset) in changes) offset * 60000];

  final String name;
  final int startOffsetMinutes;

  /// The UTC moment of each change, in order, and the offset from then on.
  final List<int> _changeMs;
  final List<int> _offsetMs;

  int offsetMsAt(int ms) {
    var offset = startOffsetMinutes * 60000;
    for (var i = 0; i < _changeMs.length; i++) {
      if (ms < _changeMs[i]) break;
      offset = _offsetMs[i];
    }
    return offset;
  }

  DateTime wallClockOf(int ms) => DateTime.fromMillisecondsSinceEpoch(ms + offsetMsAt(ms), isUtc: true);

  /// How DateTime(...) resolves a wall clock: the offset before the change.
  DateTime momentOf(int y, int mo, int d, int h, int mi) {
    final wall = DateTime.utc(y, mo, d, h, mi).millisecondsSinceEpoch;
    return DateTime.fromMillisecondsSinceEpoch(wall - offsetMsAt(wall - startOffsetMinutes * 60000));
  }

  LocalZone get zone => LocalZone(wallClockOf: wallClockOf, momentOf: momentOf);
}

// US Pacific: 02:00 PST jumps to 03:00 PDT, 02:00 PDT falls back to 01:00 PST.
final pacific = ZoneTable('Pacific', -480, [(DateTime.utc(2027, 3, 14, 10), -420), (DateTime.utc(2027, 11, 7, 9), -480), (DateTime.utc(2028, 3, 12, 10), -420)]);

// Havana: midnight jumps to 01:00, so Mar 14 has no 00:xx; 01:00 falls back to
// midnight, so Nov 7 has its 00:xx twice.
final havana = ZoneTable('Havana', -300, [(DateTime.utc(2027, 3, 14, 5), -240), (DateTime.utc(2027, 11, 7, 5), -300)]);

// A fall back at midnight itself: Saturday's 23:xx happens twice and Sunday
// starts at the second midnight (Sao Paulo until 2019).
final fallAtMidnight = ZoneTable('Midnight fall', -120, [(DateTime.utc(2027, 2, 21, 2), -180)]);

// Lord Howe: 02:00 jumps to 02:30, 02:00 falls back to 01:30.
final lordHowe = ZoneTable('Lord Howe', 660, [(DateTime.utc(2027, 4, 3, 15), 630), (DateTime.utc(2027, 10, 2, 15, 30), 660)]);

const picks = 100000;

/// Upper 5% point of chi-square with [df] degrees of freedom (Wilson-Hilferty:
/// 5.94 at 2 df against 5.99 in the tables, so slightly strict).
double chiSquareLimit(int df) {
  final a = 2 / (9 * df);
  final c = 1 - a + 1.6449 * sqrt(a);
  return df * c * c * c;
}

/// Keys are numbers, not strings: this runs millions of times in gate time.
typedef Key = int Function(DateTime wall);
int dayKey(DateTime w) => day(w.year, w.month, w.day);
int hourKey(DateTime w) => hour(w.year, w.month, w.day, w.hour);
int day(int y, int m, int d) => y * 10000 + m * 100 + d;
int hour(int y, int m, int d, int h) => day(y, m, d) * 100 + h;

/// Draws [count] moments and returns how often each key came up, checking each
/// one is valid on the way.
Map<int, int> draw(ZoneTable table, RandomScheduleRange range, DateTime now, Key key, {int seed = 20261106, int count = picks}) {
  final random = Random(seed);
  final counts = <int, int>{};
  final nowMs = now.millisecondsSinceEpoch, startMs = range.start.millisecondsSinceEpoch, endMs = range.end.millisecondsSinceEpoch;
  for (var i = 0; i < count; i++) {
    final ms = randomMomentMs(range, random)!;
    // Plain checks: expect() a hundred thousand times takes seconds.
    if (ms <= nowMs) fail('$ms is not in the future');
    if (ms < startMs || ms >= endMs) fail('$ms is outside the range');
    if (ms % 60000 != 0) fail('$ms is not on a whole minute');
    final wall = table.wallClockOf(ms);
    if (wall.second != 0 || wall.millisecond != 0) fail('$ms is not on a whole minute of the wall clock');
    final k = key(wall);
    counts[k] = (counts[k] ?? 0) + 1;
  }
  return counts;
}

/// The exact number of minutes per key in [range], by walking every instant.
Map<int, int> exact(ZoneTable table, RandomScheduleRange range, Key key) {
  final counts = <int, int>{};
  for (var ms = range.firstMoment.millisecondsSinceEpoch; ms <= range.lastMoment.millisecondsSinceEpoch; ms += 60000) {
    final k = key(table.wallClockOf(ms));
    counts[k] = (counts[k] ?? 0) + 1;
  }
  return counts;
}

double chiSquare(Map<int, int> got, Map<int, int> real, {int count = picks}) {
  final total = real.values.fold<int>(0, (a, b) => a + b);
  var chi = 0.0;
  for (final e in real.entries) {
    final expected = count * e.value / total;
    final g = got[e.key] ?? 0;
    chi += (g - expected) * (g - expected) / expected;
  }
  return chi;
}

void main() {
  group('a whole range across a change', () {
    // Every case: valid moments, then fair by local day and by local hour.
    final now = DateTime.utc(2027, 1, 1);
    void fair(ZoneTable table, DateTime firstDay, DateTime lastDay) {
      final range = customRandomScheduleRange(firstDay: firstDay, lastDay: lastDay, now: now, zone: table.zone)!;
      expect(range.minutes, greaterThan(0));
      final days = draw(table, range, now, dayKey);
      expect(chiSquare(days, exact(table, range, dayKey)), lessThan(chiSquareLimit(days.length - 1)), reason: 'by local day');
      final hours = draw(table, range, now, hourKey, seed: 20261107);
      final real = exact(table, range, hourKey);
      expect(chiSquare(hours, real), lessThan(chiSquareLimit(real.length - 1)), reason: 'by local hour');
      expect(hours.keys.toSet().difference(real.keys.toSet()), isEmpty, reason: 'only hours that exist');
    }

    test('spring gap: the skipped hour gets 0 picks, the short day its 23 hours', () {
      final range = customRandomScheduleRange(firstDay: DateTime(2027, 3, 13), lastDay: DateTime(2027, 3, 15), now: now, zone: pacific.zone)!;
      final real = exact(pacific, range, dayKey);
      expect(real, {day(2027, 3, 13): 1440, day(2027, 3, 14): 1380, day(2027, 3, 15): 1440});
      final hours = draw(pacific, range, now, hourKey);
      expect(hours[hour(2027, 3, 14, 2)], isNull, reason: 'no minute of the gap');
      expect(hours[hour(2027, 3, 14, 1)], isNotNull);
      expect(hours[hour(2027, 3, 14, 3)], isNotNull);
      fair(pacific, DateTime(2027, 3, 13), DateTime(2027, 3, 15));
    });

    test('autumn fold: the repeated hour gets double weight, the long day its 25 hours', () {
      final range = customRandomScheduleRange(firstDay: DateTime(2027, 11, 6), lastDay: DateTime(2027, 11, 8), now: now, zone: pacific.zone)!;
      expect(exact(pacific, range, dayKey), {day(2027, 11, 6): 1440, day(2027, 11, 7): 1500, day(2027, 11, 8): 1440});
      final hours = draw(pacific, range, now, hourKey);
      final fold = hours[hour(2027, 11, 7, 1)]!;
      final neighbour = (hours[hour(2027, 11, 7, 0)]! + hours[hour(2027, 11, 7, 2)]!) / 2;
      expect(fold / neighbour, closeTo(2, 0.2), reason: '$fold against $neighbour');
      fair(pacific, DateTime(2027, 11, 6), DateTime(2027, 11, 8));
    });

    test('Feb 29: a day like any other', () {
      final leapNow = DateTime.utc(2028, 1, 1);
      final range = customRandomScheduleRange(firstDay: DateTime(2028, 2, 28), lastDay: DateTime(2028, 3, 1), now: leapNow, zone: pacific.zone)!;
      expect(exact(pacific, range, dayKey), {day(2028, 2, 28): 1440, day(2028, 2, 29): 1440, day(2028, 3, 1): 1440});
      final days = draw(pacific, range, leapNow, dayKey);
      expect(days[day(2028, 2, 29)], closeTo(picks / 3, picks * 0.01));
      expect(chiSquare(days, exact(pacific, range, dayKey)), lessThan(chiSquareLimit(2)));
    });

    test('a year with no Feb 29 never draws one', () {
      final range = customRandomScheduleRange(firstDay: DateTime(2027, 2, 27), lastDay: DateTime(2027, 3, 1), now: now, zone: pacific.zone)!;
      final days = draw(pacific, range, now, dayKey);
      expect(days.keys.toSet(), {day(2027, 2, 27), day(2027, 2, 28), day(2027, 3, 1)});
    });

    test('a midnight that does not exist: the day starts at 01:00 and stays inside', () {
      final range = customRandomScheduleRange(firstDay: DateTime(2027, 3, 14), lastDay: DateTime(2027, 3, 14), now: now, zone: havana.zone)!;
      expect(havana.wallClockOf(range.start.millisecondsSinceEpoch).hour, 1);
      expect(exact(havana, range, dayKey), {day(2027, 3, 14): 1380});
      expect(draw(havana, range, now, hourKey).keys, isNot(contains(hour(2027, 3, 14, 0))));
      fair(havana, DateTime(2027, 3, 13), DateTime(2027, 3, 15));
    });

    test('a midnight that happens twice: both of them belong to the day', () {
      final range = customRandomScheduleRange(firstDay: DateTime(2027, 11, 7), lastDay: DateTime(2027, 11, 7), now: now, zone: havana.zone)!;
      expect(exact(havana, range, dayKey), {day(2027, 11, 7): 1500});
      final hours = draw(havana, range, now, hourKey);
      expect(hours[hour(2027, 11, 7, 0)]! / hours[hour(2027, 11, 7, 2)]!, closeTo(2, 0.2));
      fair(havana, DateTime(2027, 11, 6), DateTime(2027, 11, 8));
    });

    test('a fall back at midnight: Saturday keeps both 23:xx hours, Sunday starts after them', () {
      final range = customRandomScheduleRange(firstDay: DateTime(2027, 2, 20), lastDay: DateTime(2027, 2, 20), now: now, zone: fallAtMidnight.zone)!;
      expect(exact(fallAtMidnight, range, dayKey), {day(2027, 2, 20): 1500});
      final sunday = localDayStart(2027, 2, 21, zone: fallAtMidnight.zone);
      expect(sunday.toUtc(), DateTime.utc(2027, 2, 21, 3));
      fair(fallAtMidnight, DateTime(2027, 2, 20), DateTime(2027, 2, 22));
    });

    test('a 30-minute change, both ways', () {
      final spring = customRandomScheduleRange(firstDay: DateTime(2027, 10, 3), lastDay: DateTime(2027, 10, 3), now: now, zone: lordHowe.zone)!;
      expect(exact(lordHowe, spring, dayKey), {day(2027, 10, 3): 1410});
      final skipped = draw(lordHowe, spring, now, (w) => w.hour * 100 + w.minute);
      for (var minute = 0; minute < 30; minute++) {
        expect(skipped[200 + minute], isNull, reason: 'the skipped half hour');
      }
      final autumn = customRandomScheduleRange(firstDay: DateTime(2027, 4, 4), lastDay: DateTime(2027, 4, 4), now: now, zone: lordHowe.zone)!;
      expect(exact(lordHowe, autumn, dayKey), {day(2027, 4, 4): 1470});
      fair(lordHowe, DateTime(2027, 10, 2), DateTime(2027, 10, 4));
      fair(lordHowe, DateTime(2027, 4, 3), DateTime(2027, 4, 5));
    });
  });

  group('the check itself', () {
    final now = DateTime.utc(2027, 1, 1);
    final foldDays = customRandomScheduleRange(firstDay: DateTime(2027, 11, 6), lastDay: DateTime(2027, 11, 8), now: now, zone: pacific.zone)!;

    test('drawing wall clock fields, the obvious way, fails the same chi-square', () {
      // Evenly over day, hour and minute, then resolved by the zone: the
      // repeated hour loses its double weight.
      final random = Random(20261106);
      final counts = <int, int>{};
      for (var i = 0; i < picks; i++) {
        final at = pacific.momentOf(2027, 11, 6 + random.nextInt(3), random.nextInt(24), random.nextInt(60));
        final k = hourKey(pacific.wallClockOf(at.millisecondsSinceEpoch));
        counts[k] = (counts[k] ?? 0) + 1;
      }
      final real = exact(pacific, foldDays, hourKey);
      expect(chiSquare(counts, real), greaterThan(chiSquareLimit(real.length - 1)));
    });

    test('one seed is no luck: about 5% of seeds go over the limit, as a fair draw should', () {
      final real = exact(pacific, foldDays, hourKey);
      final limit = chiSquareLimit(real.length - 1);
      const seeds = 100, count = 2000;
      var over = 0;
      for (var seed = 1; seed <= seeds; seed++) {
        if (chiSquare(draw(pacific, foldDays, now, hourKey, seed: seed, count: count), real, count: count) > limit) over++;
      }
      expect(over, inInclusiveRange(1, 12), reason: '$over of $seeds seeds');
    });

    test('the limit agrees with the tables', () {
      expect(chiSquareLimit(2), closeTo(5.99, 0.06));
      expect(chiSquareLimit(10), closeTo(18.31, 0.05));
      expect(chiSquareLimit(71), closeTo(91.67, 0.1));
    });
  });

  group('presets', () {
    final now = DateTime.utc(2027, 3, 1, 12, 0, 20);

    test('every preset is between now + 15 minutes and now + 365 days', () {
      for (final preset in RandomSchedulePreset.values) {
        final span = preset.span;
        if (span == null) {
          expect(preset, RandomSchedulePreset.custom);
          continue;
        }
        final range = randomScheduleRange(span, now);
        expect(range.start, now.add(const Duration(minutes: 15)));
        expect(range.end, now.add(span));
        expect(range.end.difference(now) <= kScheduleHorizon, isTrue);
        final random = Random(1);
        final nowMs = now.millisecondsSinceEpoch;
        for (var i = 0; i < picks; i++) {
          final ms = randomMomentMs(range, random)!;
          if (ms - nowMs < kRandomScheduleMinLead.inMilliseconds) fail('$ms is too soon');
          if (ms - nowMs >= span.inMilliseconds) fail('$ms is too far');
          if (ms % 60000 != 0) fail('$ms is not on a whole minute');
        }
      }
    });

    test('a drawn moment is a local time on the same instant', () {
      final range = randomScheduleRange(kScheduleHorizon, now);
      final at = randomMoment(range, Random(9))!;
      expect(at.isUtc, isFalse);
      expect(at.millisecondsSinceEpoch, randomMomentMs(range, Random(9)));
    });

    test('the presets are the ones asked for', () {
      expect([for (final p in RandomSchedulePreset.values) p.span?.inHours], [24, 7 * 24, 30 * 24, 90 * 24, 365 * 24, null]);
    });

    test('a span over the limit is cut to it', () {
      expect(randomScheduleRange(const Duration(days: 900), now).end, now.add(kScheduleHorizon));
    });

    test('next 365 days: year, month, day and time are all random', () {
      final range = randomScheduleRange(kScheduleHorizon, DateTime.utc(2027, 8, 15, 9, 30));
      final random = Random(3);
      final years = <int>{}, months = <int>{}, days = <int>{}, hours = <int>{}, minutes = <int>{};
      for (var i = 0; i < picks; i++) {
        final at = DateTime.fromMillisecondsSinceEpoch(randomMomentMs(range, random)!, isUtc: true);
        years.add(at.year);
        months.add(at.month);
        days.add(at.day);
        hours.add(at.hour);
        minutes.add(at.minute);
      }
      expect(years, {2027, 2028});
      expect(months, hasLength(12));
      expect(days, hasLength(31));
      expect(hours, hasLength(24));
      expect(minutes, hasLength(60));
    });

    test('the same seed gives the same picks, another seed does not', () {
      final range = randomScheduleRange(kScheduleHorizon, now);
      List<int> run(int seed) {
        final r = Random(seed);
        return [for (var i = 0; i < picks; i++) randomMomentMs(range, r)!];
      }

      expect(run(42), run(42));
      expect(run(42), isNot(run(43)));
    });
  });

  group('custom ranges', () {
    final now = DateTime.utc(2027, 3, 1, 12);

    test('kept inside the limits', () {
      final range = customRandomScheduleRange(firstDay: DateTime(2020), lastDay: DateTime(2040), now: now, zone: pacific.zone)!;
      expect(range.start, now.add(kRandomScheduleMinLead));
      expect(range.end, now.add(kScheduleHorizon));
    });

    test('a range wholly past or too far gives nothing', () {
      expect(customRandomScheduleRange(firstDay: DateTime(2020), lastDay: DateTime(2021), now: now, zone: pacific.zone), isNull);
      expect(customRandomScheduleRange(firstDay: DateTime(2035), lastDay: DateTime(2036), now: now, zone: pacific.zone), isNull);
      expect(customRandomScheduleRange(firstDay: DateTime(2027, 5, 2), lastDay: DateTime(2027, 5, 1), now: now, zone: pacific.zone), isNull);
    });

    test('an empty range draws nothing', () {
      expect(randomMoment(RandomScheduleRange(now, now), Random(1)), isNull);
      // Inside one minute with no whole minute in it.
      final inside = RandomScheduleRange(now.add(const Duration(seconds: 1)), now.add(const Duration(seconds: 50)));
      expect(inside.minutes, 0);
      expect(randomMoment(inside, Random(1)), isNull);
    });

    test('a range ending at Feb 29 in a leap year includes that day, and month ends roll over', () {
      final leapNow = DateTime.utc(2028, 1, 1);
      final range = customRandomScheduleRange(firstDay: DateTime(2028, 2, 29), lastDay: DateTime(2028, 2, 29), now: leapNow, zone: pacific.zone)!;
      expect(exact(pacific, range, dayKey), {day(2028, 2, 29): 1440});
      final december = customRandomScheduleRange(firstDay: DateTime(2028, 12, 31), lastDay: DateTime(2028, 12, 31), now: DateTime.utc(2028, 6), zone: pacific.zone)!;
      expect(exact(pacific, december, dayKey), {day(2028, 12, 31): 1440});
    });
  });

  group('a wall clock that happens twice', () {
    test('both 1:30s know the other; other times have none', () {
      final first = DateTime.utc(2027, 11, 7, 8, 30);
      final second = DateTime.utc(2027, 11, 7, 9, 30);
      expect(pacific.wallClockOf(first.millisecondsSinceEpoch).hour, 1);
      expect(pacific.wallClockOf(second.millisecondsSinceEpoch).hour, 1);
      expect(otherMomentWithSameWallClock(first, zone: pacific.zone)!.toUtc(), second);
      expect(otherMomentWithSameWallClock(second, zone: pacific.zone)!.toUtc(), first);
      for (final other in [DateTime.utc(2027, 11, 7, 7, 30), DateTime.utc(2027, 11, 7, 10, 30), DateTime.utc(2027, 11, 6, 8, 30), DateTime.utc(2027, 11, 8, 9, 30), DateTime.utc(2027, 3, 14, 10, 30), DateTime.utc(2027, 3, 14, 9, 30), DateTime.utc(2027, 7, 1)]) {
        expect(otherMomentWithSameWallClock(other, zone: pacific.zone), isNull, reason: '$other');
      }
    });

    test('a 30-minute fold too', () {
      final first = DateTime.utc(2027, 4, 3, 14, 45);
      final second = DateTime.utc(2027, 4, 3, 15, 15);
      expect(otherMomentWithSameWallClock(first, zone: lordHowe.zone)!.toUtc(), second);
      expect(otherMomentWithSameWallClock(DateTime.utc(2027, 4, 3, 14, 15), zone: lordHowe.zone), isNull);
    });
  });

  group('whether a time can still be scheduled', () {
    final now = DateTime.utc(2027, 3, 1, 12);

    test('under a minute ahead or past: no', () {
      expect(scheduleTimeAccepted(now.subtract(const Duration(days: 3)), now), isFalse);
      expect(scheduleTimeAccepted(now, now), isFalse);
      expect(scheduleTimeAccepted(now.add(const Duration(seconds: 59)), now), isFalse);
      expect(scheduleTimeAccepted(now.add(const Duration(minutes: 1)), now), isTrue);
      expect(scheduleTimeAccepted(now.add(const Duration(days: 300)), now), isTrue);
    });
  });
}
