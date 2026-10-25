import 'dart:io';

import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/storage/json_file_store.dart' show JsonFile, JsonPostRepository;
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
