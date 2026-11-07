// The sampler's helpers against this machine's real time zone. CI runs this
// file again under TZ=America/Havana and TZ=Australia/Lord_Howe, the two kinds
// of change a Windows PC cannot switch to: midnight and 30 minutes.

import 'dart:io';
import 'dart:math';

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

void main() {
  final start = DateTime.utc(2027, 1, 1);
  const hours = 24 * 365;

  test('the zone asked for by TZ really is in use', () {
    final offsets = {for (var h = 0; h < hours; h += 24) start.add(Duration(hours: h)).toLocal().timeZoneOffset};
    switch (Platform.environment['TZ']) {
      case 'America/Havana':
        expect(offsets, hasLength(2));
      case 'Australia/Lord_Howe':
        expect(offsets, hasLength(2));
        expect((offsets.first - offsets.last).abs(), const Duration(minutes: 30));
    }
  }, testOn: 'linux');

  test('every local day starts at its first instant and nothing of it comes before', () {
    var previous = localDayStart(2026, 12, 31);
    for (var i = 0; i < 365; i++) {
      final utc = DateTime.utc(2027, 1, 1 + i);
      final day = localDayStart(utc.year, utc.month, utc.day);
      final wall = day.toLocal();
      expect((wall.year, wall.month, wall.day), (utc.year, utc.month, utc.day), reason: '$utc');
      final before = day.subtract(const Duration(minutes: 1)).toLocal();
      expect(before.day == wall.day && before.isBefore(wall) && before.month == wall.month, isFalse, reason: '$utc');
      expect(day.isAfter(previous), isTrue);
      previous = day;
    }
  });

  test('a real year: no draw names a time the clock skipped, and the twin of a time reads the same', () {
    final range = randomScheduleRange(kScheduleHorizon, start);
    final random = Random(20261106);
    var twins = 0;
    for (var i = 0; i < 2000; i++) {
      final at = randomMoment(range, random)!;
      expect(at.isUtc, isFalse);
      expect(at.second + at.millisecond, 0);
      final twin = otherMomentWithSameWallClock(at);
      if (twin != null) {
        twins++;
        expect((twin.day, twin.hour, twin.minute), (at.day, at.hour, at.minute));
        expect(twin, isNot(at));
      }
    }
    // At most one hour of a year repeats: about 1 in 8760 draws.
    expect(twins, lessThan(20));
  });

  test('every half hour of a real year: a repeated wall clock is found, and only then', () {
    final seen = <(int, int, int, int), int>{};
    (int, int, int, int) wall(DateTime at) => (at.month, at.day, at.hour, at.minute);
    for (var i = 0; i < hours * 2; i++) {
      final at = start.add(Duration(minutes: i * 30)).toLocal();
      seen[wall(at)] = (seen[wall(at)] ?? 0) + 1;
    }
    for (var i = 2; i < hours * 2 - 2; i++) {
      final at = start.add(Duration(minutes: i * 30)).toLocal();
      expect(otherMomentWithSameWallClock(at) != null, seen[wall(at)] == 2, reason: '$at');
    }
  });
}
