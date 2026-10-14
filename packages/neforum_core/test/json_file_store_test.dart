import 'dart:io';

import 'package:neforum_core/neforum_core.dart';
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
}
