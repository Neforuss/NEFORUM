import 'dart:async';

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../util/logger.dart';

/// One publish run in progress on this device, as [PublishJournal] keeps it.
@immutable
class PublishJournalEntry {
  const PublishJournalEntry({required this.postId, required this.owner, required this.startedAt, required this.heartbeatAt});

  factory PublishJournalEntry.fromJson(String postId, Map<String, dynamic> json) => PublishJournalEntry(
        postId: postId,
        owner: json['owner'] as String,
        startedAt: DateTime.parse(json['startedAt'] as String),
        heartbeatAt: DateTime.parse(json['heartbeatAt'] as String),
      );

  final String postId;

  /// The [PublishJournal.owner] of the process (isolate) executing the run.
  final String owner;
  final DateTime startedAt;

  /// The last time the run showed that it was still executing.
  final DateTime heartbeatAt;

  Map<String, dynamic> toJson() => {
        'owner': owner,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'heartbeatAt': heartbeatAt.toUtc().toIso8601String(),
      };
}

/// The publish runs in progress on this device. It is kept apart from the
/// posts and never synced, so that recovery after NEFORUM closed, crashed or
/// was killed in the middle of a run can tell such an abandoned run from:
///
/// * a run another isolate is still executing. Android's WorkManager and iOS
///   background tasks publish in an isolate of their own, which keeps its
///   entry's heartbeat fresh;
/// * a post that arrived in the middle of another device's run through cloud
///   sync. It has no entry here, and that device's own result follows.
///
/// [PublishService.publish] records an entry when its run starts, refreshes
/// it every [heartbeatInterval] and releases it once the outcome is saved.
/// An entry whose heartbeat is older than [abandonedAfter] belongs to a run
/// that ended without saving its outcome.
///
/// Unreadable data counts as no entries: a run that is not on record is never
/// recovered, which is the safe side, since nothing is then posted twice.
class PublishJournal {
  PublishJournal({
    required Future<Object?> Function() read,
    required Future<void> Function(Object data) write,
    String? owner,
    Clock? clock,
    this.heartbeatInterval = const Duration(minutes: 1),
    this.abandonedAfter = const Duration(minutes: 10),
  })  : owner = owner ?? const Uuid().v4(),
        _read = read,
        _write = write,
        _now = clock ?? systemClock;

  /// A journal kept in memory only (the demo workspace, tests).
  factory PublishJournal.inMemory({String? owner, Clock? clock, Duration heartbeatInterval = const Duration(minutes: 1)}) {
    Object? data;
    return PublishJournal(read: () async => data, write: (d) async => data = d, owner: owner, clock: clock, heartbeatInterval: heartbeatInterval);
  }

  /// Identifies the runs of this process. Every isolate has its own.
  final String owner;

  /// How often a run in progress refreshes its entry.
  final Duration heartbeatInterval;

  /// How long an entry may go without a heartbeat before its run counts as
  /// abandoned. Generous, because a suspended background isolate resumes.
  final Duration abandonedAfter;

  final Future<Object?> Function() _read;
  final Future<void> Function(Object data) _write;
  final Clock _now;

  /// The last change in progress. Started by the first change, in the zone
  /// that makes it (a future made up front would belong to the zone that
  /// built the journal).
  Future<void>? _tail;

  /// Every run on record, by post id.
  Future<Map<String, PublishJournalEntry>> entries() async {
    final Object? data;
    try {
      data = await _read();
    } on Object {
      return {};
    }
    final out = <String, PublishJournalEntry>{};
    if (data is! Map) return out;
    for (final e in data.entries) {
      try {
        out[e.key as String] = PublishJournalEntry.fromJson(e.key as String, Map<String, dynamic>.from(e.value as Map));
      } on Object {
        // A damaged entry is left off the record.
      }
    }
    return out;
  }

  /// Records that this process is publishing [postId], or refreshes the
  /// heartbeat of that run.
  Future<void> record(String postId) => _change((runs) {
        final now = _now();
        final previous = runs[postId];
        runs[postId] = PublishJournalEntry(
          postId: postId,
          owner: owner,
          startedAt: previous != null && previous.owner == owner ? previous.startedAt : now,
          heartbeatAt: now,
        );
        return true;
      });

  /// Takes this process's run of [postId] off the record. An entry that
  /// another process wrote for the post meanwhile stays.
  Future<void> release(String postId) => _change((runs) {
        if (runs[postId]?.owner != owner) return false;
        runs.remove(postId);
        return true;
      });

  /// Takes the runs of [postIds] off the record, whoever wrote them
  /// (recovery, once those runs are settled).
  Future<void> remove(Iterable<String> postIds) {
    final ids = postIds.toSet();
    if (ids.isEmpty) return Future<void>.value();
    return _change((runs) {
      final before = runs.length;
      runs.removeWhere((id, _) => ids.contains(id));
      return runs.length != before;
    });
  }

  /// Whether [entry]'s run has shown no sign of life for [abandonedAfter].
  bool isAbandoned(PublishJournalEntry entry, {DateTime? now}) => (now ?? _now()).difference(entry.heartbeatAt) > abandonedAfter;

  /// Applies [change] to the entries as stored, one change at a time; the
  /// file is written only when [change] returns true.
  Future<void> _change(bool Function(Map<String, PublishJournalEntry> runs) change) {
    Future<void> apply() async {
      final runs = await entries();
      if (!change(runs)) return;
      await _write({for (final e in runs.entries) e.key: e.value.toJson()});
    }

    final previous = _tail;
    final next = previous == null ? apply() : previous.then((_) => apply());
    _tail = next.catchError((Object _) {});
    return next;
  }
}
