import 'package:meta/meta.dart';

import '../model/account.dart';
import '../model/post.dart';
import '../storage/repositories.dart';
import '../storage/secret_store.dart';

/// One local thing as the sync engine sees it.
@immutable
class SyncItem {
  const SyncItem(this.value, {this.modifiedAt});

  /// JSON-encodable.
  final Object? value;

  /// When it last changed, when the thing knows (posts do).
  final DateTime? modifiedAt;
}

/// A kind of local data the sync engine keeps in step: the engine asks for
/// everything, then writes back what other devices changed.
///
/// Only [prefix], [snapshot] and [apply] are required; the rest are 1.3.5
/// refinements with defaults that keep the 1.3.4 behaviour.
abstract class SyncSource {
  /// Record keys are `prefix:id`.
  String get prefix;

  /// Every item, by id.
  Future<Map<String, SyncItem>> snapshot();

  /// Stores [value] under [id], or removes the item when [value] is `null`.
  Future<void> apply(String id, Object? value);

  /// 1.3.5: whether this source manages the record [id]. A record it does not
  /// manage (a setting a newer NEFORUM added) is left in the file untouched:
  /// never applied, never deleted. Without this an older device read such a
  /// record as "deleted here" and wrote a deletion over it on its next sync.
  bool handles(String id) => true;

  /// 1.3.5: whether a deletion in the file removes the item here. Settings
  /// say no: every device always has every setting (a missing one is its
  /// default), so a deletion only comes from an older NEFORUM that leaves
  /// defaults out of the file, and is not a reason to change anything here.
  bool get appliesDeletions => true;

  /// 1.3.5: on a device's first sync, where this device and the file hold
  /// different versions of [id], the version both should keep, or `null` to
  /// keep the whole version of the side whose setup wins ([hereWins]). The
  /// media hosts use it to keep a host in a slot the winning side left empty.
  Object? joinMerge(String id, Object? here, Object? file, {required bool hereWins}) => null;

  /// 1.3.5: [value] (the item [id]) with the account ids in [ids] replaced
  /// (old id -> new id), when two copies of one account are merged into one.
  /// Returns [value] itself when nothing changes.
  Object? remapAccountIds(String id, Object? value, Map<String, String> ids) => value;
}

/// 1.3.5: the account fields that travel. With [kDeviceOnlyAccountFields] it
/// covers every key of [ConnectedAccount.toJson]; a test fails when a field
/// is in neither list or in both.
const Set<String> kSyncedAccountFields = {
  'id',
  'platformId',
  'tier',
  'displayName',
  'createdAt',
  'handle',
  'avatarUrl',
  'profileUrl',
  'config',
  'quotaOverrides',
  'enabled',
};

/// 1.3.5: the account fields the user edits in NEFORUM (switching it off,
/// renaming it, quotas). When a cloud app's conflicted copy holds the same
/// account changed on two devices, these follow the later edit, while the
/// rest (tier, app registration, ids, everything the keys depend on) travels
/// with the newer sign-in.
const Set<String> kUserEditedAccountFields = {'enabled', 'displayName', 'quotaOverrides'};

/// 1.3.5: the account fields that stay on the device, each with why.
const Map<String, String> kDeviceOnlyAccountFields = {
  'lastError': 'What went wrong the last time this device used the account: another device may have no problem at all.',
};

/// Accounts (without [kDeviceOnlyAccountFields]).
class AccountsSyncSource extends SyncSource {
  AccountsSyncSource(this.accounts);
  final AccountRepository accounts;

  @override
  String get prefix => 'account';

  @override
  Future<Map<String, SyncItem>> snapshot() async => {
        for (final a in await accounts.all()) a.id: SyncItem(sharedAccountJson(a)),
      };

  /// [a] as it travels: everything but [kDeviceOnlyAccountFields].
  static Map<String, dynamic> sharedAccountJson(ConnectedAccount a) => a.toJson()..removeWhere((k, _) => kDeviceOnlyAccountFields.containsKey(k));

  @override
  Future<void> apply(String id, Object? value) async {
    if (value == null) {
      await accounts.delete(id);
      return;
    }
    final incoming = ConnectedAccount.fromJson(Map<String, dynamic>.from(value as Map));
    final here = await accounts.get(id);
    await accounts.upsert(here?.lastError == null ? incoming : incoming.copyWith(lastError: here!.lastError));
  }
}

/// Each account's keys, from the keychain.
class SecretsSyncSource extends SyncSource {
  SecretsSyncSource(this.accounts, this.secrets);
  final AccountRepository accounts;
  final SecretStore secrets;

  @override
  String get prefix => 'secrets';

  @override
  Future<Map<String, SyncItem>> snapshot() async {
    final out = <String, SyncItem>{};
    for (final a in await accounts.all()) {
      final s = await secrets.read(a.id);
      if (s != null && s.isNotEmpty) out[a.id] = SyncItem(Map<String, String>.of(s));
    }
    return out;
  }

  @override
  Future<void> apply(String id, Object? value) async {
    if (value == null) {
      await secrets.delete(id);
      return;
    }
    await secrets.write(id, {for (final e in (value as Map).entries) '${e.key}': '${e.value}'});
  }
}

/// Posts: drafts, scheduled posts and history.
class PostsSyncSource extends SyncSource {
  PostsSyncSource(this.posts);
  final PostRepository posts;

  @override
  String get prefix => 'post';

  @override
  Future<Map<String, SyncItem>> snapshot() async => {
        for (final p in await posts.all()) p.id: SyncItem(p.toJson(), modifiedAt: p.updatedAt),
      };

  @override
  Future<void> apply(String id, Object? value) async {
    if (value == null) {
      await posts.delete(id);
      return;
    }
    await posts.upsert(Post.fromJson(Map<String, dynamic>.from(value as Map)));
  }

  /// The post's targets follow a merged account. A post that went to both
  /// copies keeps one target for the account, so it is never published to
  /// one account twice: the one that got furthest ([mergeTargets]), with
  /// every remote id of both.
  @override
  Object? remapAccountIds(String id, Object? value, Map<String, String> ids) {
    if (value is! Map || value['targets'] is! List) return value;
    final targets = value['targets'] as List;
    if (!targets.any((t) => t is Map && ids.containsKey(t['accountId']))) return value;
    final out = <Object?>[];
    final at = <Object?, int>{};
    for (final t in targets) {
      if (t is! Map) {
        out.add(t);
        continue;
      }
      final account = ids[t['accountId']] ?? t['accountId'];
      final moved = <String, Object?>{...t.cast<String, Object?>(), 'accountId': account};
      final i = at[account];
      if (i == null) {
        at[account] = out.length;
        out.add(moved);
      } else {
        out[i] = mergeTargets(out[i]! as Map, moved);
      }
    }
    return {...value.cast<String, Object?>(), 'targets': out};
  }

  static int _progress(Map<Object?, Object?> target) {
    final result = target['result'];
    return switch (target['status']) {
      'published' => 6,
      'heldByPlatform' || 'handedOff' => 5,
      'publishing' => 4,
      'awaitingHandoff' => 3,
      'pending' => 2,
      // A thread or series that broke off partway, with its live parts
      // recorded: it got further than a plain failure.
      _ when result is Map && result['resumable'] == true => 1,
      _ => 0, // failed, cancelled, skipped
    };
  }

  static List<String> _liveIds(Object? result) => result is! Map
      ? const []
      : <Object?>[result['remoteId'], ...?(result['threadRemoteIds'] as List?), ...?(result['additionalRemoteIds'] as List?), ...?(result['seriesRemoteIds'] as List?)]
          .whereType<String>()
          .toList();

  /// 1.3.5: two targets of one post that name the same account (after its
  /// two copies were merged) as one: the one that got furthest (published,
  /// then held by the platform or handed off, then publishing, then waiting,
  /// then a thread that broke off partway, then failed), with every live
  /// post id of the other (a partial failure's too) added to its result, so
  /// no live post is forgotten and none is posted again. A winner without a
  /// result takes the other's whole, with its resume state. Target JSON.
  static Map<String, Object?> mergeTargets(Map<Object?, Object?> first, Map<Object?, Object?> second) {
    final keepFirst = _progress(first) >= _progress(second);
    final winner = (keepFirst ? first : second).cast<String, Object?>(), other = keepFirst ? second : first;
    final otherResult = other['result'];
    final mine = winner['result'];
    if (otherResult is Map && mine is! Map) return {...winner, 'result': otherResult};
    final ids = _liveIds(otherResult);
    if (ids.isEmpty || mine is! Map) return winner;
    final kept = _liveIds(mine).toSet();
    final added = [for (final x in ids) if (!kept.contains(x)) x];
    if (added.isEmpty) return winner;
    return {
      ...winner,
      'result': {
        ...mine.cast<String, Object?>(),
        'additionalRemoteIds': [...?(mine['additionalRemoteIds'] as List?), ...added],
      },
    };
  }
}

/// A source built from functions, for app data such as settings and media
/// hosts. The optional functions are the 1.3.5 refinements of [SyncSource].
class CallbackSyncSource extends SyncSource {
  CallbackSyncSource({
    required this.prefix,
    required Future<Map<String, SyncItem>> Function() snapshot,
    required Future<void> Function(String id, Object? value) apply,
    bool Function(String id)? handles,
    this.appliesDeletions = true,
    Object? Function(String id, Object? here, Object? file, {required bool hereWins})? joinMerge,
    Object? Function(String id, Object? value, Map<String, String> ids)? remapAccountIds,
  })  : _snapshot = snapshot,
        _apply = apply,
        _handles = handles,
        _joinMerge = joinMerge,
        _remap = remapAccountIds;

  @override
  final String prefix;
  @override
  final bool appliesDeletions;
  final Future<Map<String, SyncItem>> Function() _snapshot;
  final Future<void> Function(String id, Object? value) _apply;
  final bool Function(String id)? _handles;
  final Object? Function(String id, Object? here, Object? file, {required bool hereWins})? _joinMerge;
  final Object? Function(String id, Object? value, Map<String, String> ids)? _remap;

  @override
  Future<Map<String, SyncItem>> snapshot() => _snapshot();

  @override
  Future<void> apply(String id, Object? value) => _apply(id, value);

  @override
  bool handles(String id) => _handles?.call(id) ?? true;

  @override
  Object? joinMerge(String id, Object? here, Object? file, {required bool hereWins}) => _joinMerge?.call(id, here, file, hereWins: hereWins);

  @override
  Object? remapAccountIds(String id, Object? value, Map<String, String> ids) => _remap == null ? value : _remap(id, value, ids);
}
