import 'dart:async';

import 'package:meta/meta.dart';

import '../model/account.dart';
import '../model/post.dart';

abstract class AccountRepository {
  Future<List<ConnectedAccount>> all();
  Future<ConnectedAccount?> get(String id);
  Future<void> upsert(ConnectedAccount account);
  Future<void> delete(String id);

  /// Emits after every change (coarse-grained; consumers re-query).
  Stream<void> get changes;
}

abstract class PostRepository {
  Future<List<Post>> all();
  Future<Post?> get(String id);
  Future<void> upsert(Post post);
  Future<void> delete(String id);

  /// Scheduled posts whose time has come (`scheduledAt <= now`).
  Future<List<Post>> due(DateTime now);
  Stream<void> get changes;
}

/// One successful (or quota-consuming) publish, used for local quota tracking.
@immutable
class QuotaEvent {
  const QuotaEvent({required this.accountId, required this.ruleId, required this.at, this.count = 1});

  factory QuotaEvent.fromJson(Map<String, dynamic> j) => QuotaEvent(
        accountId: j['accountId'] as String,
        ruleId: j['ruleId'] as String,
        at: DateTime.parse(j['at'] as String),
        count: j['count'] as int? ?? 1,
      );

  final String accountId;
  final String ruleId;
  final DateTime at;
  final int count;

  Map<String, dynamic> toJson() =>
      {'accountId': accountId, 'ruleId': ruleId, 'at': at.toUtc().toIso8601String(), 'count': count};
}

abstract class QuotaRepository {
  Future<void> record(QuotaEvent event);
  Future<int> countSince(String accountId, String ruleId, DateTime since);

  /// Oldest event still inside the window, to compute "resets at".
  Future<DateTime?> oldestSince(String accountId, String ruleId, DateTime since);
  Future<void> prune(DateTime before);
}

// ---------------------------------------------------------------------------
// In-memory implementations (tests, CLI dry runs, previews)
// ---------------------------------------------------------------------------

class InMemoryAccountRepository implements AccountRepository {
  final Map<String, ConnectedAccount> _data = {};
  final _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<ConnectedAccount>> all() async =>
      _data.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<ConnectedAccount?> get(String id) async => _data[id];

  @override
  Future<void> upsert(ConnectedAccount account) async {
    _data[account.id] = account;
    _changes.add(null);
  }

  @override
  Future<void> delete(String id) async {
    _data.remove(id);
    _changes.add(null);
  }
}

class InMemoryPostRepository implements PostRepository {
  final Map<String, Post> _data = {};
  final _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<Post>> all() async =>
      _data.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<Post?> get(String id) async => _data[id];

  @override
  Future<void> upsert(Post post) async {
    _data[post.id] = post;
    _changes.add(null);
  }

  @override
  Future<void> delete(String id) async {
    _data.remove(id);
    _changes.add(null);
  }

  @override
  Future<List<Post>> due(DateTime now) async => _data.values
      .where((p) => p.status == PostStatus.scheduled && p.scheduledAt != null && !p.scheduledAt!.isAfter(now))
      .toList()
    ..sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
}

class InMemoryQuotaRepository implements QuotaRepository {
  final List<QuotaEvent> _events = [];

  @override
  Future<void> record(QuotaEvent event) async => _events.add(event);

  @override
  Future<int> countSince(String accountId, String ruleId, DateTime since) async => _events
      .where((e) => e.accountId == accountId && e.ruleId == ruleId && !e.at.isBefore(since))
      .fold<int>(0, (sum, e) => sum + e.count);

  @override
  Future<DateTime?> oldestSince(String accountId, String ruleId, DateTime since) async {
    DateTime? oldest;
    for (final e in _events) {
      if (e.accountId != accountId || e.ruleId != ruleId || e.at.isBefore(since)) continue;
      if (oldest == null || e.at.isBefore(oldest)) oldest = e.at;
    }
    return oldest;
  }

  @override
  Future<void> prune(DateTime before) async => _events.removeWhere((e) => e.at.isBefore(before));
}
