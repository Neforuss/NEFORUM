import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../model/account.dart';
import '../model/post.dart';
import '../publish/publish_journal.dart';
import '../util/logger.dart';
import 'repositories.dart';
import 'secret_store.dart';

/// JSON-file persistence: one small file per store in [directory], written
/// atomically (temp file + rename). Used by the CLI and, on desktop/mobile,
/// by the app for everything except secrets (which go to the OS keychain).
///
/// Files: `accounts.json`, `posts.json`, `quota.json`, `secrets.json`,
/// `publish-journal.json`.
class JsonFileStore {
  JsonFileStore(this.directory)
      : accounts = JsonAccountRepository(JsonFile(p.join(directory, 'accounts.json'))),
        posts = JsonPostRepository(JsonFile(p.join(directory, 'posts.json'))),
        quota = JsonQuotaRepository(JsonFile(p.join(directory, 'quota.json'))),
        secrets = JsonSecretStore(JsonFile(p.join(directory, 'secrets.json'))),
        publishJournal = openPublishJournal(directory);

  final String directory;
  final JsonAccountRepository accounts;
  final JsonPostRepository posts;
  final JsonQuotaRepository quota;
  final JsonSecretStore secrets;

  /// The publish runs of this process and of every other isolate that
  /// opened the same directory.
  final PublishJournal publishJournal;

  /// The publish journal in [directory] as one process sees it. Every call
  /// is another owner; [owner] and [clock] let tests stand in for another
  /// process. Every read goes to the file, since other isolates write it
  /// too. A write that keeps failing gives up after a few tries: a run that
  /// is not on record is never recovered, which costs nothing else.
  static PublishJournal openPublishJournal(String directory, {String? owner, Clock? clock}) {
    final file = JsonFile(p.join(directory, 'publish-journal.json'), writeAttempts: 3);
    return PublishJournal(read: file.read, write: file.write, owner: owner, clock: clock);
  }

  void dispose() {
    accounts.dispose();
    posts.dispose();
  }
}

/// One JSON file with serialised atomic writes.
class JsonFile {
  JsonFile(this.path, {this.writeAttempts = 20});

  final String path;

  /// How often [write] tries before giving up (about 20 seconds in all).
  final int writeAttempts;
  Future<void> _chain = Future<void>.value();

  /// Antivirus, backup, sync and indexing tools can hold a file open for a
  /// moment; a read then fails with a sharing violation. Retry for about 20
  /// seconds before giving up, so a busy file is never mistaken for no data.
  Future<Object?> read() async {
    final f = File(path);
    for (var attempt = 0;; attempt++) {
      try {
        if (!await f.exists()) return null;
        final text = await f.readAsString();
        if (text.trim().isEmpty) return null;
        return jsonDecode(text);
      } on FileSystemException {
        if (attempt >= readAttempts - 1) rethrow;
        await Future<void>.delayed(Duration(milliseconds: math.min(2000, 100 * (attempt + 1))));
      }
    }
  }

  static const readAttempts = 20;

  /// Writes are retried the same way: the temp file or the rename can hit
  /// the same sharing violation. Throws when the file stays locked, and the
  /// file on disk then still holds the previous content.
  Future<void> write(Object data) {
    final text = const JsonEncoder.withIndent('  ').convert(data);
    final next = _chain.then((_) async {
      final target = File(path);
      for (var attempt = 0;; attempt++) {
        try {
          await target.parent.create(recursive: true);
          final tmp = File('$path.tmp');
          await tmp.writeAsString(text, flush: true);
          await tmp.rename(target.path);
          return;
        } on FileSystemException {
          if (attempt >= writeAttempts - 1) rethrow;
          await Future<void>.delayed(Duration(milliseconds: math.min(2000, 100 * (attempt + 1))));
        }
      }
    });
    _chain = next.catchError((Object _) {});
    return next;
  }
}

/// Puts [previous] back under [id] (or removes [id] when there was nothing)
/// unless a later change replaced the entry meanwhile: the entry must still
/// be [ifStill], the value the failed change left there.
void _restore<T>(Map<String, T> cache, String id, T? previous, {required T? ifStill}) {
  if (!identical(cache[id], ifStill)) return;
  if (previous == null) {
    cache.remove(id);
  } else {
    cache[id] = previous;
  }
}

/// Runs [save] after a change to a repository cache; when the file cannot
/// be written, [undo] takes the change back so the cache never claims
/// something the file does not hold (a deleted post would otherwise come
/// back after a restart).
Future<void> _saveOrUndo(Future<void> Function() save, void Function() undo) async {
  try {
    await save();
  } on Object {
    undo();
    rethrow;
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
    final cache = await _load();
    final previous = cache[account.id];
    cache[account.id] = account;
    await _saveOrUndo(_save, () => _restore(cache, account.id, previous, ifStill: account));
  }

  @override
  Future<void> delete(String id) async {
    final cache = await _load();
    final removed = cache.remove(id);
    await _saveOrUndo(_save, () => _restore(cache, id, removed, ifStill: null));
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
    final cache = await _load();
    final previous = cache[post.id];
    cache[post.id] = post;
    await _saveOrUndo(_save, () => _restore(cache, post.id, previous, ifStill: post));
  }

  @override
  Future<void> delete(String id) async {
    final cache = await _load();
    final removed = cache.remove(id);
    await _saveOrUndo(_save, () => _restore(cache, id, removed, ifStill: null));
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
    final cache = await _load();
    cache.add(event);
    await _saveOrUndo(_save, () => cache.remove(event));
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
    final cache = await _load();
    final previous = cache[accountId];
    final next = Map.of(secrets);
    cache[accountId] = next;
    await _saveOrUndo(() => _file.write(cache), () => _restore(cache, accountId, previous, ifStill: next));
  }

  @override
  Future<void> delete(String accountId) async {
    final cache = await _load();
    final removed = cache.remove(accountId);
    await _saveOrUndo(() => _file.write(cache), () => _restore(cache, accountId, removed, ifStill: null));
  }
}
