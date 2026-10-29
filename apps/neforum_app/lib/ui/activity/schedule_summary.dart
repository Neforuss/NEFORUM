import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'time_format.dart';

/// What is still to come for a scheduled post with a different time per
/// network, or one whose first networks already went out: "1 published ·
/// Instagram at 18:00", "Mastodon at 10:00 · 2 more later". Null for a post
/// with one time for all and nothing published yet (its time says it all),
/// and for posts that are not scheduled.
///
/// [networkOf] names a target's network (null for a removed account).
/// [format] writes the due time: the clock alone today, with the day
/// otherwise ("Tomorrow, 18:00"), as of [now].
String? scheduleSummary(
  Post p, {
  required String? Function(String accountId) networkOf,
  required TimeFormatting format,
  DateTime? now,
}) {
  if (p.status != PostStatus.scheduled) return null;
  final published = p.targets.where((t) => t.status == TargetStatus.published || t.status == TargetStatus.handedOff).length;
  if (published == 0 && !p.schedulesEachTarget) return null;
  final at = now ?? DateTime.now();
  // The networks still waiting, by due time.
  final byTime = <DateTime, List<String>>{};
  for (final t in p.upcomingTargets) {
    final due = p.dueAtFor(t);
    if (due == null) continue;
    byTime.putIfAbsent(due, () => []).add(networkOf(t.accountId) ?? 'A removed account');
  }
  final times = byTime.keys.toList()..sort();
  final parts = <String>[if (published > 0) '$published published'];
  if (times.isNotEmpty) {
    final first = times.first;
    final names = byTime[first]!;
    final when = dayOf(first) == dayOf(at) ? format.clock(first) : format.scheduled(first, now: at);
    parts.add('${names.join(', ')} at $when');
    final later = times.skip(1).fold<int>(0, (n, t) => n + byTime[t]!.length);
    if (later > 0) parts.add('$later more later');
  }
  return parts.isEmpty ? null : parts.join(' · ');
}
