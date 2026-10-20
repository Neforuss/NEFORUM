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
abstract class SyncSource {
  /// Record keys are `prefix:id`.
  String get prefix;

  /// Every item, by id.
  Future<Map<String, SyncItem>> snapshot();

  /// Stores [value] under [id], or removes the item when [value] is `null`.
  Future<void> apply(String id, Object? value);
}

/// Accounts (without device-only fields such as the last error).
class AccountsSyncSource implements SyncSource {
  AccountsSyncSource(this.accounts);
  final AccountRepository accounts;

  @override
  String get prefix => 'account';

  @override
  Future<Map<String, SyncItem>> snapshot() async => {
        for (final a in await accounts.all()) a.id: SyncItem(_shared(a)),
      };

  static Map<String, dynamic> _shared(ConnectedAccount a) => a.toJson()..remove('lastError');

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
class SecretsSyncSource implements SyncSource {
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
class PostsSyncSource implements SyncSource {
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
}

/// A source built from two functions, for app data such as settings.
class CallbackSyncSource implements SyncSource {
  CallbackSyncSource({required this.prefix, required Future<Map<String, SyncItem>> Function() snapshot, required Future<void> Function(String id, Object? value) apply})
      : _snapshot = snapshot,
        _apply = apply;

  @override
  final String prefix;
  final Future<Map<String, SyncItem>> Function() _snapshot;
  final Future<void> Function(String id, Object? value) _apply;

  @override
  Future<Map<String, SyncItem>> snapshot() => _snapshot();

  @override
  Future<void> apply(String id, Object? value) => _apply(id, value);
}
