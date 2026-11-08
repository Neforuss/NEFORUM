import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/storage/json_file_store.dart'
    show JsonAccountRepository, JsonFile, JsonPostRepository, JsonQuotaRepository, JsonSecretStore;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('neforum-store-'));
  tearDown(() async => dir.delete(recursive: true));

  test('a file held by another program for a moment is waited for, not read as empty', () async {
    final store = JsonFileStore(dir.path);
    await store.accounts.upsert(ConnectedAccount(
      id: 'a1',
      platformId: 'mastodon',
      tier: PlatformTier.openApi,
      displayName: 'Me',
      handle: '@me@example.social',
      createdAt: DateTime.utc(2026, 10, 1),
    ));

    // Lock the whole file the way antivirus or backup tools do (on Windows a
    // locked range cannot be read through another handle), release it later.
    final held = await File(p.join(dir.path, 'accounts.json')).open(mode: FileMode.append);
    await held.lock(FileLock.blockingExclusive);
    Future<void>.delayed(const Duration(milliseconds: 600), () async {
      await held.unlock();
      await held.close();
    });

    final fresh = JsonFileStore(dir.path);
    final accounts = await fresh.accounts.all();
    expect(accounts.map((a) => a.id), ['a1']);
  });

  Post post(String id) => Post(id: id, text: 'Post $id', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1));

  test('a write held up by another program for a moment is retried, not lost', () async {
    final path = p.join(dir.path, 'posts.json');
    // Hold the temp file the write goes through, then let go.
    final held = await File('$path.tmp').open(mode: FileMode.append);
    await held.lock(FileLock.blockingExclusive);
    Future<void>.delayed(const Duration(milliseconds: 600), () async {
      await held.unlock();
      await held.close();
    });

    final store = JsonFileStore(dir.path);
    await store.posts.upsert(post('p1'));
    expect((await JsonFileStore(dir.path).posts.all()).map((x) => x.id), ['p1']);
  });

  test('a write that fails leaves the cache as the file is: a deletion does not vanish until a restart', () async {
    final path = p.join(dir.path, 'posts.json');
    final posts = JsonPostRepository(JsonFile(path, writeAttempts: 1));
    await posts.upsert(post('p1'));
    // From now on the temp file cannot be written.
    await Directory('$path.tmp').create();

    await expectLater(posts.delete('p1'), throwsA(isA<FileSystemException>()));
    expect((await posts.get('p1'))?.id, 'p1', reason: 'the file still has it, so the cache must too');

    await expectLater(posts.upsert(post('p2')), throwsA(isA<FileSystemException>()));
    expect(await posts.get('p2'), isNull);

    await expectLater(posts.upsert(post('p1').copyWith(text: 'edited')), throwsA(isA<FileSystemException>()));
    expect((await posts.get('p1'))!.text, 'Post p1');
  });

  test('what another process saves is seen before the cache is used, and never written over', () async {
    final ui = JsonFileStore(dir.path).posts;
    final background = JsonFileStore(dir.path).posts;
    await ui.upsert(post('p1').copyWith(status: PostStatus.publishing));
    await ui.upsert(post('p2'));
    var changes = 0;
    final listening = ui.changes.listen((_) => changes++);
    addTearDown(listening.cancel);

    // The background isolate publishes p1, deletes p2 and adds p3.
    await background.upsert((await background.get('p1'))!.copyWith(status: PostStatus.published));
    await background.delete('p2');
    await background.upsert(post('p3'));

    expect((await ui.get('p1'))!.status, PostStatus.published);
    await pumpEventQueue();
    expect(changes, 1, reason: 'whoever shows the posts reads them again');
    expect((await ui.all()).map((x) => x.id), unorderedEquals(['p1', 'p3']));
    await ui.reload();
    await pumpEventQueue();
    expect(changes, 1, reason: 'an unchanged file read again announces nothing, so cloud sync does not run for it');

    // Another change from the background isolate, then one from the UI.
    await background.upsert((await background.get('p3'))!.copyWith(text: 'edited'));
    await ui.upsert(post('p4'));
    final onDisk = await JsonFileStore(dir.path).posts.all();
    expect(onDisk.map((x) => x.id), unorderedEquals(['p1', 'p3', 'p4']));
    expect(onDisk.firstWhere((x) => x.id == 'p1').status, PostStatus.published);
    expect(onDisk.firstWhere((x) => x.id == 'p3').text, 'edited');
  });

  test('reload reads the file again even when its size and change time stayed the same', () async {
    final path = p.join(dir.path, 'posts.json');
    final ui = JsonFileStore(dir.path).posts;
    await ui.upsert(post('p1').copyWith(text: 'Draft A'));
    final before = File(path).statSync();

    // Same length, and the change time put back: the stamp cannot tell.
    await JsonFileStore(dir.path).posts.upsert(post('p1').copyWith(text: 'Draft B'));
    File(path).setLastModifiedSync(before.modified);
    expect(File(path).statSync().size, before.size);
    expect((await ui.get('p1'))!.text, 'Draft A');

    await ui.reload();
    expect((await ui.get('p1'))!.text, 'Draft B');
  });

  test('the publish journal is shared by every process that opens the folder, and each owns its runs', () async {
    final background = JsonFileStore(dir.path).publishJournal;
    final ui = JsonFileStore(dir.path).publishJournal;
    expect(ui.owner, isNot(background.owner));
    await background.record('p1');
    await ui.record('p2');
    expect((await background.entries()).keys, unorderedEquals(['p1', 'p2']), reason: 'read from the file, never from a cache');
    await ui.release('p1');
    expect((await background.entries())['p1']!.owner, background.owner);

    await File(p.join(dir.path, 'publish-journal.json')).writeAsString('{"p1": {"owner": ');
    expect(await ui.entries(), isEmpty, reason: 'a damaged journal recovers nothing');
    await ui.record('p3');
    expect((await background.entries()).keys, ['p3']);
  });

  group('the publish journal across processes', () {
    final t0 = DateTime.utc(2026, 11, 7, 12);
    PublishJournal open({required String? process, DateTime? at}) =>
        JsonFileStore.openPublishJournal(dir.path, process: process, clock: () => at ?? t0);

    test('an entry from another process is abandoned at once', () async {
      await open(process: 'old').record('p1');
      final entry = (await open(process: 'new').entries())['p1']!;
      expect(entry.process, 'old');
      expect(open(process: 'new').isAbandoned(entry), isTrue, reason: 'its heartbeat is this moment, and nothing can be running it');
    });

    test('another isolate of this process with a fresh beat is not, until it falls silent', () async {
      await open(process: 'same').record('p1');
      final entry = (await open(process: 'same').entries())['p1']!;
      final other = open(process: 'same');
      expect(other.owner, isNot(entry.owner));
      expect(other.isAbandoned(entry), isFalse);
      expect(other.isAbandoned(entry, now: t0.add(const Duration(minutes: 10))), isFalse);
      expect(other.isAbandoned(entry, now: t0.add(const Duration(minutes: 10, seconds: 1))), isTrue);
    });

    test('a computer names no process: only heartbeats tell, since a second live NEFORUM may share the folder', () async {
      await open(process: 'old').record('p1');
      await open(process: null).record('p2');
      final entries = await open(process: null).entries();
      expect(open(process: null).isAbandoned(entries['p1']!), isFalse);
      expect(open(process: 'new').isAbandoned(entries['p2']!), isFalse, reason: 'that entry names no process, so it proves nothing');
    });

    test('an entry from 1.3.5 has no process and reads as before; the marks keep the process', () async {
      await File(p.join(dir.path, 'publish-journal.json'))
          .writeAsString(jsonEncode({'p1': {'owner': 'x', 'startedAt': t0.toIso8601String(), 'heartbeatAt': t0.toIso8601String()}}));
      expect((await open(process: 'new').entries())['p1']!.process, isNull);

      final mine = open(process: 'me');
      await mine.record('p2');
      await mine.beginCreate('p2', 'a');
      await mine.endCreate('p2', 'a', mayBeLive: true);
      final after = (await mine.entries())['p2']!;
      expect(after.process, 'me');
      expect(after.createdUnsaved, {'a'});
    });
  });

  group('two first reads at once', () {
    // The app's start: the sign-in dates (unawaited) list the accounts while the
    // Android probe's prepare hook stores one. If each caller had its own read, the
    // writer's read would end first and the lister's, holding the file from before
    // the write, would end last and replace the cache: what the CI emulator showed
    // as "This account was removed". Each test lets the newest read end first.
    ConnectedAccount account(String id) =>
        ConnectedAccount(id: id, platformId: 'mastodon', tier: PlatformTier.openApi, displayName: id, createdAt: DateTime.utc(2026, 11, 7));

    test('accounts: what one stores while another is still reading stays, in memory and on disk', () async {
      final file = _HeldReads(p.join(dir.path, 'accounts.json'));
      final accounts = JsonAccountRepository(file);
      final listing = accounts.all();
      final storing = accounts.upsert(account('probe'));
      await file.taken();
      file.releaseNewest();
      await storing;
      file.releaseAll();
      await listing;

      expect((await accounts.get('probe'))?.id, 'probe', reason: 'a late read must not replace what was stored');
      await accounts.upsert(account('second'));
      expect((await JsonFileStore(dir.path).accounts.all()).map((a) => a.id), unorderedEquals(['probe', 'second']),
          reason: 'and the next write must not drop it from the file');
      expect(file.reads, 1, reason: 'both first callers wait for one read');
    });

    test('quota: an event recorded while another is still reading is still counted and saved', () async {
      final file = _HeldReads(p.join(dir.path, 'quota.json'));
      final quota = JsonQuotaRepository(file);
      final at = DateTime.utc(2026, 11, 7, 12);
      final counting = quota.countSince('a', 'posts', at);
      final recording = quota.record(QuotaEvent(accountId: 'a', ruleId: 'posts', at: at));
      await file.taken();
      file.releaseNewest();
      await recording;
      file.releaseAll();
      await counting;

      expect(await quota.countSince('a', 'posts', at), 1);
      await quota.record(QuotaEvent(accountId: 'a', ruleId: 'posts', at: at));
      expect(await JsonFileStore(dir.path).quota.countSince('a', 'posts', at), 2);
    });

    test('secrets: keys written while another is still reading are still there', () async {
      final file = _HeldReads(p.join(dir.path, 'secrets.json'));
      final secrets = JsonSecretStore(file);
      final reading = secrets.read('other');
      final writing = secrets.write('probe', const {'access_token': 't'});
      await file.taken();
      file.releaseNewest();
      await writing;
      file.releaseAll();
      await reading;

      expect(await secrets.read('probe'), {'access_token': 't'});
    });

    test('a first read that fails fails every caller waiting on it, and the next caller reads again', () async {
      final file = _HeldReads(p.join(dir.path, 'accounts.json'), failFirst: true);
      final accounts = JsonAccountRepository(file);
      final first = accounts.all();
      final second = accounts.get('probe');
      await file.taken();
      file.releaseAll();
      await expectLater(first, throwsA(isA<FileSystemException>()));
      await expectLater(second, throwsA(isA<FileSystemException>()));

      final third = accounts.upsert(account('probe'));
      await file.taken();
      file.releaseAll();
      await third;
      expect((await accounts.get('probe'))?.id, 'probe');
      expect(file.reads, 2, reason: 'one read per attempt, however many callers wait on it');
    });
  });

  test('posts come back with local times, the same moments that were saved', () async {
    final saved = Post(
      id: 'p1',
      text: 'hi',
      createdAt: DateTime.utc(2026, 10, 1, 8),
      updatedAt: DateTime.utc(2026, 10, 2, 9, 30),
      scheduledAt: DateTime.utc(2026, 10, 3, 23, 45),
      status: PostStatus.scheduled,
      targets: [PostTarget(accountId: 'a', lastAttemptAt: DateTime.utc(2026, 10, 2, 9, 29))],
    );
    await JsonFileStore(dir.path).posts.upsert(saved);
    final back = (await JsonFileStore(dir.path).posts.get('p1'))!;
    expect(back.createdAt.isUtc, isFalse);
    expect(back.scheduledAt!.isUtc, isFalse);
    expect(back.targets.single.lastAttemptAt!.isUtc, isFalse);
    expect(back.createdAt.isAtSameMomentAs(saved.createdAt), isTrue);
    expect(back.updatedAt.isAtSameMomentAs(saved.updatedAt), isTrue);
    expect(back.scheduledAt!.isAtSameMomentAs(saved.scheduledAt!), isTrue);
    expect(back.targets.single.lastAttemptAt!.isAtSameMomentAs(saved.targets.single.lastAttemptAt!), isTrue);
    // The local hour is what the user sees (intl formats fields as they are).
    expect(back.scheduledAt!.hour, saved.scheduledAt!.toLocal().hour);
    // Still due at the same moment, compared with a UTC or a local clock.
    final repo = JsonFileStore(dir.path).posts;
    expect(await repo.due(DateTime.utc(2026, 10, 3, 23, 44)), isEmpty);
    expect((await repo.due(DateTime.utc(2026, 10, 3, 23, 45).toLocal())).single.id, 'p1');
    expect(back.toJson()['scheduledAt'], '2026-10-03T23:45:00.000Z');
  });
}

/// A [JsonFile] whose reads take the file as it is when asked, then wait until the
/// test releases them, so two first reads can finish in either order.
class _HeldReads extends JsonFile {
  _HeldReads(super.path, {this.failFirst = false});

  final bool failFirst;
  final List<Completer<void>> _gates = [];
  int _taken = 0;
  int get reads => _gates.length;

  @override
  Future<Object?> read() async {
    final gate = Completer<void>();
    _gates.add(gate);
    final index = _gates.length - 1;
    final content = await super.read();
    _taken++;
    await gate.future;
    if (failFirst && index == 0) throw FileSystemException('held by another program', path);
    return content;
  }

  /// Waits until every read started so far has taken the file. A repository asks
  /// for its read synchronously, so the reads are all started once the callers are.
  Future<void> taken() async {
    for (var i = 0; i < 400 && _taken < reads; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(_taken, reads, reason: 'every started read took the file');
  }

  /// Ends the newest read still held.
  void releaseNewest() => _gates.lastWhere((g) => !g.isCompleted).complete();

  void releaseAll() {
    for (final g in _gates) {
      if (!g.isCompleted) g.complete();
    }
  }
}
