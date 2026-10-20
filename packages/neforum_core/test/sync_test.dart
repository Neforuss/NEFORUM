import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

const _fast = BackupKdfParams.testing;
const _pass = 'shared sync passphrase';

/// One device on the shared file: its own data, keychain and sync state.
class _Device {
  _Device(this.id, this.backend, this.clock)
      : accounts = InMemoryAccountRepository(),
        posts = InMemoryPostRepository(),
        secrets = InMemorySecretStore(),
        stateStore = MemorySyncStateStore() {
    engine = SyncEngine(
      backend: backend,
      cipher: BackupCipher(_pass, params: _fast, minimum: _fast, derive: (p, s, k) {
        deriveCount++;
        return deriveBackupKey(p, s, k);
      }),
      deviceId: id,
      device: SyncDeviceInfo(label: id, platform: 'test', appVersion: '1.0.8', seenAt: DateTime.utc(2000)),
      sources: [AccountsSyncSource(accounts), SecretsSyncSource(accounts, secrets), PostsSyncSource(posts)],
      state: stateStore,
      secrets: secrets,
      clock: () => clock.now,
      sleep: (d) async => clock.now = clock.now.add(d),
    );
  }

  final String id;
  final SyncBackend backend;
  final _Clock clock;
  final InMemoryAccountRepository accounts;
  final InMemoryPostRepository posts;
  final InMemorySecretStore secrets;
  final MemorySyncStateStore stateStore;
  late final SyncEngine engine;
  int deriveCount = 0;
}

class _Clock {
  DateTime now = DateTime.utc(2026, 10, 20, 12);
}

ConnectedAccount _account(String id, String platform, {PlatformTier tier = PlatformTier.byokApi, String? name}) =>
    ConnectedAccount(id: id, platformId: platform, tier: tier, displayName: name ?? id, createdAt: DateTime.utc(2026, 10, 1));

Post _post(String id, {PostStatus status = PostStatus.draft, DateTime? updatedAt, DateTime? scheduledAt, String text = 'hello', List<PostTarget> targets = const []}) => Post(
      id: id,
      text: text,
      status: status,
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: updatedAt ?? DateTime.utc(2026, 10, 20, 11),
      scheduledAt: scheduledAt,
      targets: targets,
    );

Map<String, String> _tokens(String access, String refresh, DateTime expires) => {
      'access_token': access,
      'refresh_token': refresh,
      'expires_at': expires.toUtc().toIso8601String(),
      'client_secret': 'cs',
    };

void main() {
  late _Clock clock;
  late MemorySyncBackend backend;
  late _Device a;
  late _Device b;

  setUp(() {
    clock = _Clock();
    backend = MemorySyncBackend();
    a = _Device('A', backend, clock);
    b = _Device('B', backend, clock);
  });

  group('merging', () {
    test('a second device receives accounts, keys and posts', () async {
      await a.accounts.upsert(_account('m1', 'mastodon'));
      await a.secrets.write('m1', {'access_token': 'tok'});
      await a.posts.upsert(_post('p1'));
      final ra = await a.engine.sync();
      expect(ra.sent, 3);
      expect(backend.bytes, isNotNull);
      // The file is encrypted: no token in it.
      expect(String.fromCharCodes(backend.bytes!).contains('tok'), isFalse);

      final rb = await b.engine.sync();
      expect(rb.received, 3);
      expect((await b.accounts.get('m1'))?.platformId, 'mastodon');
      expect(await b.secrets.read('m1'), {'access_token': 'tok'});
      expect((await b.posts.get('p1'))?.text, 'hello');
    });

    test('changes and deletions travel both ways', () async {
      await a.posts.upsert(_post('p1'));
      await a.posts.upsert(_post('p2'));
      await a.engine.sync();
      await b.engine.sync();

      await b.posts.upsert(_post('p1', text: 'edited on B', updatedAt: DateTime.utc(2026, 10, 20, 12)));
      await b.posts.delete('p2');
      await b.engine.sync();
      await a.engine.sync();
      expect((await a.posts.get('p1'))?.text, 'edited on B');
      expect(await a.posts.get('p2'), isNull);

      // A tombstone, not a missing record: B does not get p2 back from A.
      await b.engine.sync();
      expect(await b.posts.get('p2'), isNull);
    });

    test('both sides changed: the newer edit wins, a published post beats an edit', () async {
      await a.posts.upsert(_post('p1'));
      await a.posts.upsert(_post('p2', status: PostStatus.scheduled));
      await a.engine.sync();
      await b.engine.sync();

      await a.posts.upsert(_post('p1', text: 'A, older', updatedAt: DateTime.utc(2026, 10, 20, 11, 30)));
      await b.posts.upsert(_post('p1', text: 'B, newer', updatedAt: DateTime.utc(2026, 10, 20, 11, 45)));
      await a.posts.upsert(_post('p2', status: PostStatus.published, updatedAt: DateTime.utc(2026, 10, 20, 11, 10)));
      await b.posts.upsert(_post('p2', status: PostStatus.scheduled, text: 'late edit', updatedAt: DateTime.utc(2026, 10, 20, 11, 50)));
      await a.engine.sync();
      final rb = await b.engine.sync();
      expect(rb.conflicts, 2);
      await a.engine.sync();
      for (final d in [a, b]) {
        expect((await d.posts.get('p1'))?.text, 'B, newer');
        expect((await d.posts.get('p2'))?.status, PostStatus.published);
      }
    });

    test('an edit beats a deletion', () async {
      await a.posts.upsert(_post('p1'));
      await a.engine.sync();
      await b.engine.sync();
      await a.posts.delete('p1');
      await b.posts.upsert(_post('p1', text: 'kept', updatedAt: DateTime.utc(2026, 10, 20, 11, 59)));
      await a.engine.sync();
      await b.engine.sync();
      await a.engine.sync();
      expect((await a.posts.get('p1'))?.text, 'kept');
    });

    test('the most recently renewed keys win', () async {
      await a.accounts.upsert(_account('x1', 'x'));
      await a.secrets.write('x1', _tokens('a0', 'r0', DateTime.utc(2026, 10, 20, 13)));
      await a.engine.sync();
      await b.engine.sync();
      await a.secrets.write('x1', _tokens('a-new', 'r-new', DateTime.utc(2026, 10, 20, 15)));
      await b.secrets.write('x1', _tokens('b-old', 'r-old', DateTime.utc(2026, 10, 20, 14)));
      await b.engine.sync();
      await a.engine.sync();
      await b.engine.sync();
      expect((await b.secrets.read('x1'))?['access_token'], 'a-new');
      expect((await a.secrets.read('x1'))?['access_token'], 'a-new');
    });

    test('a device joining takes what the file has, and adds what only it has', () async {
      await a.accounts.upsert(_account('m1', 'mastodon', name: 'From A'));
      await a.engine.sync();
      await b.accounts.upsert(_account('m1', 'mastodon', name: 'Old name on B'));
      await b.accounts.upsert(_account('bsky', 'bluesky'));
      await b.engine.sync();
      await a.engine.sync();
      expect((await b.accounts.get('m1'))?.displayName, 'From A');
      expect(await a.accounts.get('bsky'), isNotNull);
    });

    test('a new or emptied file never deletes anything here', () async {
      await a.posts.upsert(_post('p1'));
      await a.engine.sync();
      backend.bytes = null; // the file was removed
      await a.engine.sync();
      expect(await a.posts.get('p1'), isNotNull);
      await b.engine.sync();
      expect(await b.posts.get('p1'), isNotNull);
    });

    test('hand-off twins made before syncing become one account', () async {
      await a.accounts.upsert(_account('h-a', 'instagram', tier: PlatformTier.handoff, name: 'Instagram (hand-off)'));
      await a.engine.sync();
      await b.accounts.upsert(_account('h-b', 'instagram', tier: PlatformTier.handoff, name: 'Instagram (hand-off)'));
      await b.posts.upsert(_post('p1', targets: const [PostTarget(accountId: 'h-b')]));
      await b.engine.sync();
      expect((await b.accounts.all()).map((x) => x.id), ['h-a']);
      expect((await b.posts.get('p1'))!.targets.single.accountId, 'h-a');
    });

    test('a write that collides with another device is merged and retried', () async {
      final racy = _RacyBackend(backend);
      final c = _Device('C', racy, clock);
      await a.posts.upsert(_post('pa'));
      await a.engine.sync();
      await c.posts.upsert(_post('pc'));
      racy.beforeWrite = () async {
        racy.beforeWrite = null;
        await b.posts.upsert(_post('pb'));
        await b.engine.sync(); // B writes between C's read and C's write
      };
      await c.engine.sync();
      await a.engine.sync();
      expect((await a.posts.all()).map((p) => p.id).toSet(), {'pa', 'pb', 'pc'});
    });

    test('the key is stretched once, not on every sync', () async {
      await a.posts.upsert(_post('p1'));
      for (var i = 0; i < 4; i++) {
        await a.posts.upsert(_post('p1', text: 'v$i', updatedAt: DateTime.utc(2026, 10, 20, 12, i)));
        await a.engine.sync();
      }
      await b.engine.sync();
      await b.engine.sync();
      expect(a.deriveCount, 1);
      expect(b.deriveCount, 1);
    });

    test('a wrong passphrase is refused and nothing is written', () async {
      await a.engine.sync();
      final before = backend.writes;
      final wrong = SyncEngine(
        backend: backend,
        cipher: BackupCipher('not the passphrase', params: _fast, minimum: _fast),
        deviceId: 'W',
        device: SyncDeviceInfo(label: 'W', platform: 'test', appVersion: '1', seenAt: DateTime.utc(2000)),
        sources: [PostsSyncSource(InMemoryPostRepository())],
        state: MemorySyncStateStore(),
      );
      await expectLater(wrong.sync(), throwsA(isA<BackupException>().having((e) => e.kind, 'kind', BackupErrorKind.wrongPassphraseOrDamaged)));
      expect(backend.writes, before);
    });
  });

  group('scheduled posts', () {
    final due = DateTime.utc(2026, 10, 20, 12);

    test('only the device it was scheduled on publishes it', () async {
      await a.posts.upsert(_post('s1', status: PostStatus.scheduled, scheduledAt: due));
      await a.engine.sync();
      await b.engine.sync();
      final onB = (await b.posts.get('s1'))!;
      expect(await b.engine.mayPublish(onB), isFalse);
      expect(await a.engine.mayPublish((await a.posts.get('s1'))!), isTrue);
      // A marked it as being published.
      expect(await b.engine.mayPublish(onB), isFalse);
    });

    test('a post published elsewhere is left alone', () async {
      await b.posts.upsert(_post('s1', status: PostStatus.scheduled, scheduledAt: due));
      await b.engine.sync();
      await a.engine.sync();
      await b.posts.upsert(_post('s1', status: PostStatus.published, scheduledAt: due, updatedAt: DateTime.utc(2026, 10, 20, 12, 1)));
      await b.engine.sync();
      final stale = _post('s1', status: PostStatus.scheduled, scheduledAt: due);
      expect(await a.engine.mayPublish(stale), isFalse);
      expect((await a.posts.get('s1'))?.status, PostStatus.published);
    });

    test('another device takes over when the owner is silent and the post is well overdue', () async {
      await a.posts.upsert(_post('s1', status: PostStatus.scheduled, scheduledAt: due));
      await a.engine.sync();
      await b.engine.sync();
      final onB = (await b.posts.get('s1'))!;
      clock.now = due.add(const Duration(minutes: 20));
      expect(await b.engine.mayPublish(onB), isFalse);
      clock.now = due.add(const Duration(minutes: 45));
      expect(await b.engine.mayPublish(onB, mediaHere: false), isFalse, reason: 'B does not have the photos');
      clock.now = due.add(const Duration(minutes: 50));
      expect(await b.engine.mayPublish(onB), isTrue);
      expect(await a.engine.mayPublish((await a.posts.get('s1'))!), isFalse, reason: 'B claimed it');
    });

    test('a fresh process that cannot reach the file goes by the last synced claims', () async {
      await a.posts.upsert(_post('s1', status: PostStatus.scheduled, scheduledAt: due));
      await a.engine.sync();
      await b.engine.sync();
      // A phone's background task: a new engine, B's saved state, no file.
      SyncEngine offline() => SyncEngine(
            backend: _BrokenBackend(),
            cipher: BackupCipher(_pass, params: _fast, minimum: _fast),
            deviceId: 'B',
            device: SyncDeviceInfo(label: 'B', platform: 'test', appVersion: '1', seenAt: DateTime.utc(2000)),
            sources: [PostsSyncSource(b.posts)],
            state: b.stateStore,
            clock: () => clock.now,
          );
      final onB = (await b.posts.get('s1'))!;
      expect(await offline().mayPublish(onB), isFalse, reason: 'A scheduled it and was just seen');
      clock.now = due.add(const Duration(hours: 2));
      expect(await offline().mayPublish(onB), isTrue, reason: 'A has been silent and the post is long overdue');
    });

    test('a post only on this device is published here', () async {
      expect(await a.engine.mayPublish(_post('local', status: PostStatus.scheduled, scheduledAt: due)), isTrue);
    });
  });

  group('rotating sign-ins', () {
    final account = _account('x1', 'x');
    final expired = DateTime.utc(2026, 10, 20, 11);
    final later = DateTime.utc(2026, 10, 20, 14);

    Future<void> shareAccount() async {
      await a.accounts.upsert(account);
      await a.secrets.write('x1', _tokens('a0', 'r0', expired));
      await a.engine.sync();
      await b.engine.sync();
    }

    test('keys that are still valid are used as they are', () async {
      await a.accounts.upsert(account);
      final fresh = _tokens('a0', 'r0', later);
      var calls = 0;
      final r = await a.engine.renew(account, fresh, (s) async {
        calls++;
        return null;
      });
      expect(r, isNull);
      expect(calls, 1);
    });

    test('the renewing device shares the new keys; the other uses them without renewing', () async {
      await shareAccount();
      final renewed = await a.engine.renew(account, (await a.secrets.read('x1'))!, (s) async {
        expect(s['refresh_token'], 'r0');
        return _tokens('a1', 'r1', later);
      });
      expect(renewed?['refresh_token'], 'r1');
      var bRenewed = false;
      final onB = await b.engine.renew(account, (await b.secrets.read('x1'))!, (s) async {
        bRenewed = true;
        return null;
      });
      expect(bRenewed, isFalse, reason: 'r0 is dead at X; renewing with it would sign B out');
      expect(onB?['access_token'], 'a1');
      expect((await b.secrets.read('x1'))?['refresh_token'], 'r1');
    });

    test('a live lease held by another device makes this one wait, then use its keys', () async {
      await shareAccount();
      // Simulate A holding the lease: write it into the file directly.
      final cipher = BackupCipher(_pass, params: _fast, minimum: _fast);
      final doc = SyncDocument.parse(await cipher.open(backend.bytes!));
      doc.leases['x1'] = SyncLease(by: 'A', until: clock.now.add(const Duration(minutes: 2)));
      backend.bytes = await cipher.seal(doc.toJson(writtenBy: 'A', writtenAt: clock.now));

      var waits = 0;
      final waitingB = SyncEngine(
        backend: backend,
        cipher: BackupCipher(_pass, params: _fast, minimum: _fast),
        deviceId: 'B',
        device: SyncDeviceInfo(label: 'B', platform: 'test', appVersion: '1', seenAt: DateTime.utc(2000)),
        sources: [AccountsSyncSource(b.accounts), SecretsSyncSource(b.accounts, b.secrets)],
        state: b.stateStore,
        secrets: b.secrets,
        clock: () => clock.now,
        sleep: (d) async {
          waits++;
          clock.now = clock.now.add(d);
          if (waits == 2) {
            // A finishes renewing and shares the keys.
            await a.secrets.write('x1', _tokens('a1', 'r1', later));
            await a.engine.sync();
          }
        },
      );
      var renewedOnB = false;
      final r = await waitingB.renew(account, (await b.secrets.read('x1'))!, (s) async {
        renewedOnB = true;
        return null;
      });
      expect(renewedOnB, isFalse);
      expect(waits, greaterThanOrEqualTo(2));
      expect(r?['refresh_token'], 'r1');
    });

    test('a refused renewal re-reads the file and uses keys another device just wrote', () async {
      await shareAccount();
      var attempts = 0;
      final r = await b.engine.renew(account, (await b.secrets.read('x1'))!, (s) async {
        attempts++;
        if (s['refresh_token'] == 'r0') {
          // A renewed a moment earlier and its file arrives only now: X
          // refuses r0.
          await a.secrets.write('x1', _tokens('a1', 'r1', later));
          await a.engine.sync();
          throw const AdapterException(PublishError.auth('invalid_grant'));
        }
        return null;
      });
      expect(r?['refresh_token'], 'r1');
      expect(attempts, 1);
      expect((await b.secrets.read('x1'))?['refresh_token'], 'r1');
    });

    test('in a synced folder, a refusal while another device is active is retried later, not "reconnect"', () async {
      final folderLike = MemorySyncBackend(atomicWrites: false);
      final fa = _Device('A', folderLike, clock);
      final fb = _Device('B', folderLike, clock);
      await fa.accounts.upsert(account);
      await fa.secrets.write('x1', _tokens('a0', 'r0', expired));
      await fa.engine.sync();
      await fb.engine.sync();
      await expectLater(
        fb.engine.renew(account, (await fb.secrets.read('x1'))!, (s) async => throw const AdapterException(PublishError.auth('invalid_grant'))),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.network)),
      );
    });

    test('without the file, the device renews alone rather than not at all', () async {
      await shareAccount();
      final broken = _BrokenBackend();
      final lonely = SyncEngine(
        backend: broken,
        cipher: BackupCipher(_pass, params: _fast, minimum: _fast),
        deviceId: 'B',
        device: SyncDeviceInfo(label: 'B', platform: 'test', appVersion: '1', seenAt: DateTime.utc(2000)),
        sources: [AccountsSyncSource(b.accounts)],
        state: MemorySyncStateStore(),
        secrets: b.secrets,
        clock: () => clock.now,
      );
      final r = await lonely.renew(account, (await b.secrets.read('x1'))!, (s) async => _tokens('b1', 'rb1', later));
      expect(r?['access_token'], 'b1');
    });

    test('PublishService asks the coordinator for accounts with rotating tokens', () async {
      final registry = AdapterRegistry([_RotatingAdapter()]);
      final accounts = InMemoryAccountRepository();
      final secrets = InMemorySecretStore();
      await accounts.upsert(_account('r1', 'rot'));
      await secrets.write('r1', _tokens('a0', 'r0', expired));
      final coordinator = _RecordingCoordinator();
      final service = PublishService(
        registry: registry,
        accounts: accounts,
        posts: InMemoryPostRepository(),
        secrets: secrets,
        quota: QuotaTracker(InMemoryQuotaRepository()),
        http: NeforumHttp(client: MockClient((_) async => http.Response('', 500))),
        secretsCoordinator: coordinator,
      );
      final post = _post('p', status: PostStatus.draft, targets: const [PostTarget(accountId: 'r1')]);
      await service.posts.upsert(post);
      await service.publish('p');
      expect(coordinator.calls, ['r1']);
      expect((await secrets.read('r1'))?['access_token'], 'from-coordinator');
    });
  });

  group('backends', () {
    test('folder: writes in one rename, refuses stale writes, merges conflicted copies', () async {
      final dir = await Directory.systemTemp.createTemp('neforum-sync-');
      addTearDown(() => dir.delete(recursive: true));
      final folder = FolderSyncBackend(dir.path);
      expect(await folder.read(), isNull);
      final v1 = await folder.write(Uint8List.fromList([1, 2, 3]), ifMatch: null);
      await expectLater(folder.write(Uint8List.fromList([9]), ifMatch: null), throwsA(isA<SyncConflict>()));
      final blob = await folder.read();
      expect(blob!.bytes, [1, 2, 3]);
      expect(blob.version, v1);
      expect(dir.listSync().whereType<File>().map((f) => f.uri.pathSegments.last), [kSyncFileName]);

      expect(folder.isConflictCopyName("NEFORUM (Alice's conflicted copy 2026-10-20).neforumsync"), isTrue);
      expect(folder.isConflictCopyName('NEFORUM-DESKTOP-PC.neforumsync'), isTrue);
      expect(folder.isConflictCopyName('NEFORUM.sync-conflict-20261020-101500-ABCDEFG.neforumsync'), isTrue);
      expect(folder.isConflictCopyName(kSyncFileName), isFalse);
      expect(folder.isConflictCopyName('.NEFORUM.neforumsync.1a2b.tmp'), isFalse);
      expect(folder.isConflictCopyName('notes.txt'), isFalse);

      // Two devices wrote before the cloud app caught up: it kept both.
      final fa = _Device('A', FolderSyncBackend(dir.path), clock);
      final fb = _Device('B', FolderSyncBackend(dir.path), clock);
      File('${dir.path}/$kSyncFileName').deleteSync();
      await fa.posts.upsert(_post('from-a'));
      await fa.engine.sync();
      File('${dir.path}/$kSyncFileName').renameSync('${dir.path}/NEFORUM (conflicted copy).neforumsync');
      await fb.posts.upsert(_post('from-b'));
      await fb.engine.sync();
      expect(File('${dir.path}/NEFORUM (conflicted copy).neforumsync').existsSync(), isFalse, reason: 'merged, then removed');
      await fa.engine.sync();
      expect((await fa.posts.all()).map((p) => p.id).toSet(), {'from-a', 'from-b'});
    });

    test('folder: an empty sync file counts as no sync file yet', () async {
      final dir = await Directory.systemTemp.createTemp('neforum-sync-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/$kSyncFileName')..writeAsBytesSync(const []);
      final folder = FolderSyncBackend(dir.path);
      expect(await folder.read(), isNull);
      await expectLater(folder.write(Uint8List.fromList([9]), ifMatch: '1:0'), throwsA(isA<SyncConflict>()));
      final v = await folder.write(Uint8List.fromList([4, 5]), ifMatch: null);
      final blob = await folder.read();
      expect(blob!.bytes, [4, 5]);
      expect(blob.version, v);

      // The first device to sync fills the empty file ("Create the sync
      // file" on a phone); the next one joins it.
      file.writeAsBytesSync(const []);
      final fa = _Device('A', FolderSyncBackend(dir.path), clock);
      await fa.posts.upsert(_post('from-a'));
      await fa.engine.sync();
      expect(file.lengthSync(), greaterThan(0));
      final fb = _Device('B', FolderSyncBackend(dir.path), clock);
      await fb.engine.sync();
      expect(await fb.posts.get('from-a'), isNotNull);
    });

    test('WebDAV: conditional writes, 412 is a conflict, missing folder is created', () async {
      final calls = <String>[];
      var exists = false;
      final client = MockClient((r) async {
        calls.add('${r.method} ${r.url.path} ${r.headers['If-Match'] ?? r.headers['If-None-Match'] ?? ''}'.trim());
        expect(r.headers['Authorization'], startsWith('Basic '));
        if (r.method == 'GET') return exists ? http.Response.bytes([7], 200, headers: {'etag': '"e1"'}) : http.Response('', 404);
        if (r.method == 'MKCOL') {
          exists = true;
          return http.Response('', 201);
        }
        if (r.method == 'PUT') {
          if (!exists) return http.Response('', 409);
          if (r.headers['If-Match'] == '"stale"') return http.Response('', 412);
          return http.Response('', 201, headers: {'etag': '"e2"'});
        }
        return http.Response('', 405);
      });
      final dav = WebDavSyncBackend(
          http: NeforumHttp(client: client, maxRetries: 0), folderUrl: Uri.parse('https://cloud.example.com/remote.php/dav/files/u/NEFORUM'), username: 'u', password: 'app-pass');
      expect(await dav.read(), isNull);
      expect(await dav.write(Uint8List.fromList([1]), ifMatch: null), '"e2"');
      expect(calls, contains('MKCOL /remote.php/dav/files/u/NEFORUM/'));
      expect(calls.where((c) => c.startsWith('PUT')).last, 'PUT /remote.php/dav/files/u/NEFORUM/NEFORUM.neforumsync *');
      await expectLater(dav.write(Uint8List.fromList([1]), ifMatch: '"stale"'), throwsA(isA<SyncConflict>()));
      expect((await dav.read())!.version, '"e1"');
    });

    test('S3: signed conditional PUT, 412 is a conflict, stores without conditions fall back', () async {
      final seen = <Map<String, String>>[];
      var conditional = true;
      final client = MockClient((r) async {
        seen.add(r.headers);
        expect(r.headers['Authorization'], startsWith('AWS4-HMAC-SHA256 '));
        if (r.method == 'GET') return http.Response('<Error><Code>NoSuchKey</Code></Error>', 404);
        if (!conditional && (r.headers.containsKey('if-match') || r.headers.containsKey('if-none-match'))) {
          return http.Response('<Error><Code>NotImplemented</Code></Error>', 501);
        }
        if (r.headers['if-match'] == '"old"') return http.Response('<Error><Code>PreconditionFailed</Code></Error>', 412);
        return http.Response('', 200, headers: {'etag': '"v2"'});
      });
      final s3 = S3SyncBackend(
          http: NeforumHttp(client: client, maxRetries: 0),
          endpoint: Uri.parse('https://acc.r2.cloudflarestorage.com'),
          bucket: 'b',
          accessKeyId: 'AK',
          secretAccessKey: 'SK',
          folder: 'neforum');
      expect(s3.objectUri(s3.key).toString(), 'https://acc.r2.cloudflarestorage.com/b/neforum/NEFORUM.neforumsync');
      expect(await s3.read(), isNull);
      expect(await s3.write(Uint8List.fromList([1]), ifMatch: null), '"v2"');
      expect(seen.last['if-none-match'], '*');
      expect(seen.last['Authorization'], contains('if-none-match'));
      await expectLater(s3.write(Uint8List.fromList([1]), ifMatch: '"old"'), throwsA(isA<SyncConflict>()));
      conditional = false;
      expect(await s3.write(Uint8List.fromList([1]), ifMatch: '"v2"'), '"v2"');
      expect(s3.atomicWrites, isFalse);
    });
  });

  test('every provider has a name, a kind and a hint; ids are unique', () {
    expect(syncProviders.map((p) => p.id).toSet().length, syncProviders.length);
    for (final p in syncProviders) {
      expect(p.name, isNotEmpty);
      expect(p.hint, isNotEmpty);
      if (p.kind == SyncBackendKind.webdav || p.kind == SyncBackendKind.s3) expect(p.urlTemplate, startsWith('https://'));
    }
    final folders = syncProviders.where((p) => p.kind == SyncBackendKind.folder).toList();
    expect(folders.where((p) => p.iosHint != null).map((p) => p.id), containsAll(['icloud', 'onedrive', 'dropbox']),
        reason: 'iPhones and iPads reach these through the Files app');
    expect(syncProviderById('icloud')!.hintFor(ios: true), contains('iCloud Drive'));
    expect(syncProviderById('onedrive')!.hintFor(ios: false), contains('Always keep on this device'));
    // OneDrive cannot have its folders picked on iOS: the hint sends the user
    // to the sync file instead.
    expect(syncProviderById('onedrive')!.hintFor(ios: true), contains('Choose the sync file'));
    expect(syncProviderById('onedrive')!.hintFor(android: true), contains('Choose the sync file'));
    // Phones reach Google Drive through its API, not its Files integration.
    expect(syncProviderById('googledrive')!.availableOn(ios: true), isFalse);
    expect(syncProviderById('googledrive-direct')!.availableOn(ios: true), isTrue);
    expect(syncProviderById('icloud')!.availableOn(android: true), isFalse, reason: 'no iCloud Drive app on Android');
    expect(syncProviderById('icloud')!.availableOn(ios: true), isTrue);
    expect(syncProviders.where((p) => p.kind == SyncBackendKind.folder && p.availableOn(android: true)).length, greaterThanOrEqualTo(10));
    expect(syncProviderById('nextcloud')!.availableOn(android: true), isTrue, reason: 'WebDAV works everywhere');
    expect(isSyncConflictCopyName('NEFORUM (1).neforumsync'), isTrue);
    expect(isSyncConflictCopyName('.NEFORUM.neforumsync.check'), isFalse);
    expect(syncProviders.where((p) => p.kind == SyncBackendKind.webdav).length, greaterThanOrEqualTo(8));
    expect(syncProviders.where((p) => p.kind == SyncBackendKind.s3).length, greaterThanOrEqualTo(8));
  });
}

class _RacyBackend extends SyncBackend {
  _RacyBackend(this.inner);
  final MemorySyncBackend inner;
  Future<void> Function()? beforeWrite;

  @override
  String get label => 'racy';
  @override
  bool get atomicWrites => true;
  @override
  Future<SyncBlob?> read() => inner.read();
  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) async {
    await beforeWrite?.call();
    return inner.write(bytes, ifMatch: ifMatch);
  }

  @override
  Future<void> check() async {}
}

class _BrokenBackend extends SyncBackend {
  @override
  String get label => 'broken';
  @override
  bool get atomicWrites => true;
  @override
  Future<SyncBlob?> read() async => throw const SyncBackendException('offline', temporary: true);
  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) async => throw const SyncBackendException('offline', temporary: true);
  @override
  Future<void> check() async {}
}

class _RecordingCoordinator implements SecretsCoordinator {
  final calls = <String>[];
  @override
  Future<Map<String, String>?> renew(ConnectedAccount account, Map<String, String> current, SecretsRefresh refresh) async {
    calls.add(account.id);
    return {...current, 'access_token': 'from-coordinator'};
  }
}

class _RotatingAdapter extends PlatformAdapter {
  @override
  PlatformDescriptor get descriptor => const PlatformDescriptor(
        id: 'rot',
        name: 'Rotating',
        tiers: {PlatformTier.byokApi},
        defaultTier: PlatformTier.byokApi,
        text: TextRules(maxLength: 280),
        media: MediaRules(maxImages: 4),
        accountRequirements: '',
        apiCostSummary: '',
      );

  @override
  bool get rotatesRefreshTokens => true;

  @override
  List<ConnectSpec> get connectSpecs => const [];

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) => throw UnimplementedError();

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async =>
      PublishResult.ok(remoteId: '1');

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) => null;
}
