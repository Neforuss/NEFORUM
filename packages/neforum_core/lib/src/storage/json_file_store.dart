import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/account.dart';
import '../model/post.dart';
import 'repositories.dart';
import 'secret_store.dart';

/// JSON-file persistence: one small file per store in [directory], written
/// atomically (temp file + rename). Used by the CLI and, on desktop/mobile,
/// by the app for everything except secrets (which go to the OS keychain).
///
/// Files: `accounts.json`, `posts.json`, `quota.json`, `secrets.json`.
class JsonFileStore {
  JsonFileStore(this.directory)
      : accounts = JsonAccountRepository(JsonFile(p.join(directory, 'accounts.json'))),
        posts = JsonPostRepository(JsonFile(p.join(directory, 'posts.json'))),
        quota = JsonQuotaRepository(JsonFile(p.join(directory, 'quota.json'))),
        secrets = JsonSecretStore(JsonFile(p.join(directory, 'secrets.json')));

  final String directory;
  final JsonAccountRepository accounts;
  final JsonPostRepository posts;
  final JsonQuotaRepository quota;
  final JsonSecretStore secrets;

  void dispose() {
    accounts.dispose();
    posts.dispose();
  }
}

/// One JSON file with serialised atomic writes.
class JsonFile {
  JsonFile(this.path);

  final String path;
  Future<void> _chain = Future<void>.value();

  Future<Object?> read() async {
    final f = File(path);
    if (!await f.exists()) return null;
    final text = await f.readAsString();
    if (text.trim().isEmpty) return null;
    return jsonDecode(text);
  }

  Future<void> write(Object data) {
    final next = _chain.then((_) async {
      final target = File(path);
      await target.parent.create(recursive: true);
      final tmp = File('$path.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data), flush: true);
      await tmp.rename(target.path);
    });
    _chain = next.catchError((Object _) {});
    return next;
  }
}

class JsonAccountRepository implements AccountRepository {
  JsonAccountRepository(this._file);

  final JsonFile _file;
  Map<String, ConnectedAccount>? _cache;
  final _changes = StreamController<void>.broadcast();

  Future<Map<String, ConnectedAccount>> _load() async => _cache ??= {
        for (final j in (await _file.read() as List? ?? const []))
          (j as Map)['id'] as String: ConnectedAccount.fromJson(Map<String, dynamic>.from(j)),
      };

  Future<void> _save() async {
    await _file.write((await _load()).values.map((a) => a.toJson()).toList());
    _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<ConnectedAccount>> all() async => (await _load()).values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<ConnectedAccount?> get(String id) async => (await _load())[id];

  @override
  Future<void> upsert(ConnectedAccount account) async {
    (await _load())[account.id] = account;
    await _save();
  }

  @override
  Future<void> delete(String id) async {
    (await _load()).remove(id);
    await _save();
  }

  void dispose() => _changes.close();
}

class JsonPostRepository implements PostRepository {
  JsonPostRepository(this._file);

  final JsonFile _file;
  Map<String, Post>? _cache;
  final _changes = StreamController<void>.broadcast();

  Future<Map<String, Post>> _load() async => _cache ??= {
        for (final j in (await _file.read() as List? ?? const []))
          (j as Map)['id'] as String: Post.fromJson(Map<String, dynamic>.from(j)),
      };

  Future<void> _save() async {
    await _file.write((await _load()).values.map((x) => x.toJson()).toList());
    _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<Post>> all() async => (await _load()).values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<Post?> get(String id) async => (await _load())[id];

  @override
  Future<void> upsert(Post post) async {
    (await _load())[post.id] = post;
    await _save();
  }

  @override
  Future<void> delete(String id) async {
    (await _load()).remove(id);
    await _save();
  }

  @override
  Future<List<Post>> due(DateTime now) async => (await _load())
      .values
      .where((x) => x.status == PostStatus.scheduled && x.scheduledAt != null && !x.scheduledAt!.isAfter(now))
      .toList()
    ..sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));

  void dispose() => _changes.close();
}

class JsonQuotaRepository implements QuotaRepository {
  JsonQuotaRepository(this._file);

  final JsonFile _file;
  List<QuotaEvent>? _cache;

  Future<List<QuotaEvent>> _load() async => _cache ??= [
        for (final j in (await _file.read() as List? ?? const [])) QuotaEvent.fromJson(Map<String, dynamic>.from(j as Map)),
      ];

  Future<void> _save() async => _file.write((await _load()).map((e) => e.toJson()).toList());

  @override
  Future<void> record(QuotaEvent event) async {
    (await _load()).add(event);
    await _save();
  }

  @override
  Future<int> countSince(String accountId, String ruleId, DateTime since) async => (await _load())
      .where((e) => e.accountId == accountId && e.ruleId == ruleId && !e.at.isBefore(since))
      .fold<int>(0, (s, e) => s + e.count);

  @override
  Future<DateTime?> oldestSince(String accountId, String ruleId, DateTime since) async {
    DateTime? oldest;
    for (final e in await _load()) {
      if (e.accountId != accountId || e.ruleId != ruleId || e.at.isBefore(since)) continue;
      if (oldest == null || e.at.isBefore(oldest)) oldest = e.at;
    }
    return oldest;
  }

  @override
  Future<void> prune(DateTime before) async {
    (await _load()).removeWhere((e) => e.at.isBefore(before));
    await _save();
  }
}

/// Plain-JSON secrets. Fine for the CLI (the file lives in the user's config
/// directory); the app uses the OS keychain instead.
class JsonSecretStore extends SecretStore {
  JsonSecretStore(this._file);

  final JsonFile _file;
  Map<String, Map<String, String>>? _cache;

  Future<Map<String, Map<String, String>>> _load() async => _cache ??= {
        for (final e in (await _file.read() as Map? ?? const {}).entries)
          e.key as String: Map<String, String>.from(e.value as Map),
      };

  @override
  Future<Map<String, String>?> read(String accountId) async {
    final s = (await _load())[accountId];
    return s == null ? null : Map.unmodifiable(s);
  }

  @override
  Future<void> write(String accountId, Map<String, String> secrets) async {
    (await _load())[accountId] = Map.of(secrets);
    await _file.write(await _load());
  }

  @override
  Future<void> delete(String accountId) async {
    (await _load()).remove(accountId);
    await _file.write(await _load());
  }
}
