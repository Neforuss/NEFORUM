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
  _Device(this.id, this.backend, this.clock, {List<SyncSource> extra = const [], LogSink? log, InMemoryAccountRepository? accountRepo})
      : accounts = accountRepo ?? InMemoryAccountRepository(),
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
      sources: [AccountsSyncSource(accounts), SecretsSyncSource(accounts, secrets), PostsSyncSource(posts), ...extra],
      state: stateStore,
      secrets: secrets,
      clock: () => clock.now,
      sleep: (d) async => clock.now = clock.now.add(d),
      log: log == null ? null : Logger('sync', sink: log),
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

ConnectedAccount _account(String id, String platform,
        {PlatformTier tier = PlatformTier.byokApi, String? name, String? handle, DateTime? createdAt, Map<String, dynamic> config = const {}}) =>
    ConnectedAccount(
        id: id, platformId: platform, tier: tier, displayName: name ?? id, handle: handle, createdAt: createdAt ?? DateTime.utc(2026, 10, 1), config: config);

/// Device-made ids, as Mastodon and hand-off accounts get them.
const _uuid1 = '6f1c2d3e-0000-4abc-9def-000000000001';
const _uuid2 = '6f1c2d3e-0000-4abc-9def-000000000002';
const _uuid3 = '6f1c2d3e-0000-4abc-9def-000000000003';
const _mastodonConfig = {'instance': 'https://mastodon.example', 'domain': 'mastodon.example', 'remoteAccountId': '42'};

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

    test('a device joining with fewer accounts takes what the file has, and adds what only it has', () async {
      await a.accounts.upsert(_account('m1', 'mastodon', name: 'From A'));
      await a.accounts.upsert(_account('a2', 'x'));
      await a.accounts.upsert(_account('a3', 'tumblr'));
      await a.engine.sync();
      await b.accounts.upsert(_account('m1', 'mastodon', name: 'Old name on B'));
      await b.accounts.upsert(_account('bsky', 'bluesky'));
      await b.engine.sync();
      await a.engine.sync();
      expect((await b.accounts.get('m1'))?.displayName, 'From A');
      expect(await a.accounts.get('bsky'), isNotNull);
    });

    test('a device set up to keep its own data wins where both have the same record, once', () async {
      // The phone made the file first, with its own (default) version.
      await a.accounts.upsert(_account('m1', 'mastodon', name: 'Phone default'));
      await a.engine.sync();
      // The computer holds the real data and joins keeping it.
      await b.accounts.upsert(_account('m1', 'mastodon', name: 'Computer original'));
      await b.accounts.upsert(_account('bsky', 'bluesky'));
      await b.stateStore.write(Map.of(SyncEngine.keepThisDeviceOnJoin));
      await b.engine.sync();
      expect((await b.accounts.get('m1'))?.displayName, 'Computer original');
      await a.engine.sync();
      expect((await a.accounts.get('m1'))?.displayName, 'Computer original', reason: 'the phone takes the computer\'s version');
      expect(await a.accounts.get('bsky'), isNotNull);
      // Only the first sync: later changes merge as usual.
      expect(b.stateStore.data?['preferLocal'], isNull);
      await a.accounts.upsert(_account('m1', 'mastodon', name: 'Renamed on the phone'));
      await a.engine.sync();
      await b.engine.sync();
      expect((await b.accounts.get('m1'))?.displayName, 'Renamed on the phone');
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

  Future<SyncDocument> file() async => SyncDocument.parse(await BackupCipher(_pass, params: _fast, minimum: _fast).open(backend.bytes!));

  /// Another device writes [record] into the file (a real write: a new
  /// version, so no engine reads a cached copy instead).
  Future<void> putInFile(String key, SyncRecord record) async {
    final cipher = BackupCipher(_pass, params: _fast, minimum: _fast);
    final doc = await file();
    doc.records[key] = record;
    await backend.write(await cipher.seal(doc.toJson(writtenBy: 'other', writtenAt: clock.now)), ifMatch: (await backend.read())!.version);
  }

  group('the seed rule (1.3.5)', () {
    SyncSideSummary side(int n, [DateTime? oldest]) => SyncSideSummary(accounts: n, oldestConnection: oldest);
    final older = DateTime.utc(2025, 1, 1), newer = DateTime.utc(2026, 1, 1);

    test('the side with more accounts wins, on either side', () {
      expect(chooseSyncSeed(here: side(16, newer), file: side(3, older)), SyncSeed.thisDevice);
      expect(chooseSyncSeed(here: side(3, older), file: side(16, newer)), SyncSeed.file);
      expect(chooseSyncSeed(here: side(1), file: side(0)), SyncSeed.thisDevice);
    });

    test('on a tie, the side whose oldest account connection is older wins', () {
      expect(chooseSyncSeed(here: side(4, older), file: side(4, newer)), SyncSeed.thisDevice);
      expect(chooseSyncSeed(here: side(4, newer), file: side(4, older)), SyncSeed.file);
      expect(chooseSyncSeed(here: side(4, older), file: side(4)), SyncSeed.thisDevice, reason: 'a date beats no date');
      expect(chooseSyncSeed(here: side(4), file: side(4, older)), SyncSeed.file);
    });

    test('a full tie keeps the file', () {
      expect(chooseSyncSeed(here: side(4, older), file: side(4, older)), SyncSeed.file);
      expect(chooseSyncSeed(here: side(0), file: side(0)), SyncSeed.file);
      expect(chooseSyncSeed(here: side(2), file: side(2)), SyncSeed.file);
    });

    test('a summary counts accounts and finds the oldest connection', () {
      final s = SyncSideSummary.ofAccounts([
        {'createdAt': '2026-03-01T00:00:00.000Z'},
        {'createdAt': '2025-07-04T00:00:00.000Z'},
        {'createdAt': 'not a date'},
        'not an account',
      ]);
      expect(s, SyncSideSummary(accounts: 3, oldestConnection: DateTime.utc(2025, 7, 4)));
      expect(SyncSideSummary.ofAccounts(const []), const SyncSideSummary(accounts: 0));
    });
  });

  group('first sync (1.3.5)', () {
    test('the device with more accounts keeps its version even when it joins second', () async {
      await a.accounts.upsert(_account('m1', 'mastodon', name: 'Phone default'));
      await a.engine.sync();
      await b.accounts.upsert(_account('m1', 'mastodon', name: 'Computer original'));
      await b.accounts.upsert(_account('bsky', 'bluesky'));
      await b.engine.sync();
      await a.engine.sync();
      for (final d in [a, b]) {
        expect((await d.accounts.get('m1'))?.displayName, 'Computer original');
        expect(await d.accounts.get('bsky'), isNotNull);
      }
    });

    test('on a tie, the device whose oldest account connection is older wins', () async {
      await a.accounts.upsert(_account('m1', 'mastodon', name: 'From A', createdAt: DateTime.utc(2026, 5, 1)));
      await a.accounts.upsert(_account('a2', 'x', createdAt: DateTime.utc(2026, 5, 1)));
      await a.engine.sync();
      await b.accounts.upsert(_account('m1', 'mastodon', name: 'From B', createdAt: DateTime.utc(2026, 5, 1)));
      await b.accounts.upsert(_account('b2', 'tumblr', createdAt: DateTime.utc(2024, 3, 1)));
      await b.engine.sync();
      await a.engine.sync();
      expect((await a.accounts.get('m1'))?.displayName, 'From B', reason: 'B has been in use since 2024');
    });

    test('keys of one account on both sides follow the newer sign-in, not the seed, on a first sync', () async {
      // The file's side has more accounts, so its setup wins; but this device
      // signed in to x-1 again later, and its keys do not expire.
      await a.accounts.upsert(_account('x-1', 'x', createdAt: DateTime.utc(2026, 1, 1)));
      await a.secrets.write('x-1', {'oauth_token': 'fake-old-revoked'});
      await a.accounts.upsert(_account('t-1', 'tumblr'));
      await a.engine.sync();
      await b.accounts.upsert(_account('x-1', 'x', createdAt: DateTime.utc(2026, 10, 15)));
      await b.secrets.write('x-1', {'oauth_token': 'fake-new-working'});
      expect((await b.engine.preview()).seed, SyncSeed.file);
      await b.engine.sync();
      await a.engine.sync();
      for (final d in [a, b]) {
        expect((await d.secrets.read('x-1'))?['oauth_token'], 'fake-new-working', reason: d.id);
      }
    });

    test('the choice confirmed in the dry run beats the seed rule', () async {
      await a.accounts.upsert(_account('m1', 'mastodon', name: 'In the file'));
      await a.engine.sync();
      await b.accounts.upsert(_account('m1', 'mastodon', name: 'On B'));
      await b.accounts.upsert(_account('b2', 'x'));
      await b.stateStore.write(SyncEngine.joinState(SyncSeed.file));
      expect((await b.engine.preview()).seed, SyncSeed.file);
      await b.engine.sync();
      expect((await b.accounts.get('m1'))?.displayName, 'In the file');
      expect(SyncEngine.joinState(null), isEmpty);
      expect(SyncEngine.joinState(SyncSeed.thisDevice), SyncEngine.keepThisDeviceOnJoin);
    });

    test('nothing is ever deleted on a first sync, whichever side wins', () async {
      for (final seed in [null, SyncSeed.thisDevice, SyncSeed.file]) {
        for (final bHasMore in [false, true]) {
          final store = MemorySyncBackend();
          final x = _Device('X', store, clock), y = _Device('Y', store, clock);
          await x.accounts.upsert(_account('shared', 'mastodon', name: 'X version'));
          await x.accounts.upsert(_account('only-x', 'x'));
          await x.secrets.write('only-x', {'access_token': 'fake-x'});
          await x.posts.upsert(_post('post-x'));
          await x.posts.upsert(_post('gone-later'));
          await x.engine.sync();
          // X deletes a post Y also has: a tombstone in the file.
          await x.posts.delete('gone-later');
          await x.engine.sync();
          await y.accounts.upsert(_account('shared', 'mastodon', name: 'Y version'));
          await y.accounts.upsert(_account('only-y', 'bluesky'));
          if (bHasMore) {
            await y.accounts.upsert(_account('only-y2', 'tumblr'));
            await y.accounts.upsert(_account('only-y3', 'reddit'));
          }
          await y.secrets.write('only-y', {'app_password': 'fake-y'});
          await y.posts.upsert(_post('post-y'));
          await y.posts.upsert(_post('gone-later', text: 'still wanted on Y'));
          if (seed != null) await y.stateStore.write(SyncEngine.joinState(seed));
          await y.engine.sync();
          final why = 'seed $seed, Y has more: $bHasMore';
          expect((await y.accounts.all()).map((e) => e.id).toSet(), containsAll(['shared', 'only-x', 'only-y']), reason: why);
          expect(await y.secrets.read('only-x'), isNotNull, reason: why);
          expect(await y.secrets.read('only-y'), isNotNull, reason: why);
          expect((await y.posts.all()).map((p) => p.id).toSet(), {'post-x', 'post-y', 'gone-later'}, reason: '$why: a deletion never reaches a first sync');
          final doc = SyncDocument.parse(await BackupCipher(_pass, params: _fast, minimum: _fast).open(store.bytes!));
          for (final k in ['account:only-y', 'secrets:only-y', 'post:post-y', 'account:shared', 'account:only-x', 'post:post-x']) {
            expect(doc.records[k]?.deleted, isFalse, reason: '$why: $k');
          }
        }
      }
    });
  });

  group('merged accounts (1.3.5)', () {
    test("one Mastodon account connected on both devices becomes one, under the file's id, with the newer sign-in", () async {
      for (final hereNewer in [true, false]) {
        final store = MemorySyncBackend();
        final x = _Device('X', store, clock), y = _Device('Y', store, clock);
        await x.accounts.upsert(_account(_uuid1, 'mastodon',
            tier: PlatformTier.openApi, handle: '@Alice@Mastodon.Example', createdAt: DateTime.utc(2026, hereNewer ? 8 : 10, 1), config: _mastodonConfig));
        await x.secrets.write(_uuid1, {'access_token': 'fake-token-x'});
        await x.engine.sync();
        await y.accounts.upsert(_account(_uuid2, 'mastodon',
            tier: PlatformTier.openApi, handle: 'alice@mastodon.example', createdAt: DateTime.utc(2026, hereNewer ? 10 : 8, 1), config: _mastodonConfig));
        await y.secrets.write(_uuid2, {'access_token': 'fake-token-y'});
        await y.posts.upsert(_post('py', targets: const [PostTarget(accountId: _uuid2)]));
        final r = await y.engine.sync();
        await x.engine.sync();
        expect(r.mergedAccounts, 1);
        final newer = hereNewer ? 'fake-token-y' : 'fake-token-x';
        for (final d in [x, y]) {
          expect((await d.accounts.all()).map((e) => e.id), [_uuid1], reason: "the file's id is kept (Y newer: $hereNewer)");
          expect((await d.secrets.read(_uuid1))?['access_token'], newer, reason: 'the newer sign-in (Y newer: $hereNewer)');
          expect((await d.posts.get('py'))!.targets.single.accountId, _uuid1);
        }
        expect(await y.secrets.read(_uuid2), isNull);
      }
    });

    test('the same TikTok account connected on two devices (a random id each, the same openId) becomes one', () async {
      const config = {'clientKey': 'fake-client-key', 'openId': 'fake-open-id'};
      await a.accounts.upsert(_account(_uuid1, 'tiktok', name: 'Me', config: config));
      await a.secrets.write(_uuid1, {'access_token': 'fake-tt-a'});
      await a.engine.sync();
      await b.accounts.upsert(_account(_uuid2, 'tiktok', name: 'Me', config: config));
      await b.accounts.upsert(_account(_uuid3, 'tiktok', name: 'Me', config: {...config, 'openId': 'another-open-id'}));
      final r = await b.engine.sync();
      await a.engine.sync();
      expect(r.mergedAccounts, 1);
      for (final d in [a, b]) {
        expect((await d.accounts.all()).map((x) => x.id).toSet(), {_uuid1, _uuid3}, reason: 'one account per TikTok user');
      }
    });

    test('hand-off accounts of one name on two different servers stay apart', () async {
      await a.accounts.upsert(_account(_uuid1, 'mastodon',
          tier: PlatformTier.handoff, name: 'alice (hand-off)', handle: 'alice', config: {'instance': 'https://one.example', 'domain': 'one.example'}));
      await a.engine.sync();
      await b.accounts.upsert(_account(_uuid2, 'mastodon',
          tier: PlatformTier.handoff, name: 'alice (hand-off)', handle: 'alice', config: {'instance': 'https://two.example', 'domain': 'two.example'}));
      final r = await b.engine.sync();
      expect(r.mergedAccounts, 0);
      expect((await b.accounts.all()).length, 2);
    });

    test('the same Bluesky account has the same id on both devices: nothing to merge', () async {
      await a.accounts.upsert(_account('bluesky:did:plc:fake', 'bluesky', handle: 'me.bsky.social'));
      await a.engine.sync();
      await b.accounts.upsert(_account('bluesky:did:plc:fake', 'bluesky', handle: 'me.bsky.social'));
      final r = await b.engine.sync();
      expect(r.mergedAccounts, 0);
      expect((await b.accounts.all()).map((e) => e.id), ['bluesky:did:plc:fake']);
    });

    test('two different X accounts are never merged, even under one name', () async {
      await a.accounts.upsert(_account('x-1', 'x', name: 'Me', handle: '@me_one'));
      await a.engine.sync();
      await b.accounts.upsert(_account('x-2', 'x', name: 'Me', handle: '@me_two'));
      final r = await b.engine.sync();
      await a.engine.sync();
      expect(r.mergedAccounts, 0);
      for (final d in [a, b]) {
        expect((await d.accounts.all()).map((e) => e.id).toSet(), {'x-1', 'x-2'});
      }
    });

    test('Mastodon accounts with one handle but different server ids, or of different tiers, stay apart', () async {
      await a.accounts.upsert(_account(_uuid1, 'mastodon', tier: PlatformTier.openApi, handle: '@alice@mastodon.example', config: _mastodonConfig));
      await a.accounts.upsert(_account(_uuid3, 'mastodon', tier: PlatformTier.handoff, handle: 'alice@mastodon.example', name: 'alice (hand-off)'));
      await a.engine.sync();
      await b.accounts.upsert(_account(_uuid2, 'mastodon',
          tier: PlatformTier.openApi, handle: '@alice@mastodon.example', config: {..._mastodonConfig, 'remoteAccountId': '99'}));
      final r = await b.engine.sync();
      expect(r.mergedAccounts, 0);
      expect((await b.accounts.all()).length, 3);
    });

    test('who is the same account', () {
      Map<String, Object?> acc(String id, String platform, {String tier = 'openApi', String? handle, String name = 'n', Map<String, Object?>? config}) =>
          {'id': id, 'platformId': platform, 'tier': tier, 'handle': handle, 'displayName': name, 'config': config ?? const {}};
      expect(isSameConnectedAccount(acc(_uuid1, 'mastodon', handle: '@Alice@M.Example'), acc(_uuid2, 'mastodon', handle: 'alice@m.example')), isTrue);
      expect(isSameConnectedAccount(acc(_uuid1, 'mastodon', config: _mastodonConfig), acc(_uuid2, 'mastodon', config: _mastodonConfig)), isTrue,
          reason: 'the same account id on the same server, without handles');
      expect(isSameConnectedAccount(acc(_uuid1, 'mastodon', handle: '@a@m'), acc(_uuid2, 'pixelfed', handle: '@a@m')), isFalse, reason: 'another network');
      expect(isSameConnectedAccount(acc(_uuid1, 'mastodon', handle: '@a@m'), acc(_uuid2, 'mastodon', handle: '@b@m')), isFalse);
      expect(isSameConnectedAccount(acc(_uuid1, 'mastodon'), acc(_uuid2, 'mastodon')), isFalse, reason: 'nothing to tell them apart is not a match');
      expect(isSameConnectedAccount(acc('x-1', 'x', handle: '@me'), acc('x-2', 'x', handle: '@me')), isFalse, reason: 'two natural ids are two accounts');
      expect(isSameConnectedAccount(acc(_uuid1, 'x', handle: '@me'), acc('x-2', 'x', handle: '@me')), isTrue, reason: 'one made-up id may match');
      expect(isSameConnectedAccount(acc('h-a', 'instagram', tier: 'handoff', name: 'IG'), acc('h-b', 'instagram', tier: 'handoff', name: 'IG')), isTrue);
      expect(isSameConnectedAccount(acc('h-a', 'instagram', tier: 'handoff', name: 'IG'), acc('h-b', 'instagram', tier: 'handoff', name: 'IG 2')), isFalse);
      expect(isSameConnectedAccount(acc(_uuid1, 'mastodon', handle: 'a@m'), acc(_uuid2, 'mastodon', tier: 'handoff', handle: 'a@m')), isFalse);
      expect(normalizedAccountHandle('  @@Alice@Mastodon.Social '), 'alice@mastodon.social');
      expect(normalizedAccountHandle('@'), isNull);
      expect(normalizedAccountHandle(null), isNull);
      expect(isDeviceMadeAccountId('instagram-handoff-$_uuid1'), isTrue);
      expect(isDeviceMadeAccountId('bluesky:did:plc:abc'), isFalse);
      expect(isDeviceMadeAccountId(_uuid1), isTrue, reason: 'Mastodon, TikTok');
      expect(isDeviceMadeAccountId('tumblr:handoff:$_uuid1'), isTrue);
      expect(isDeviceMadeAccountId('threads-handoff:$_uuid1'), isTrue);
      expect(isDeviceMadeAccountId('deviantart:$_uuid1'), isFalse, reason: "DeviantArt's own user id is a UUID: a natural id");
      expect(isDeviceMadeAccountId('x-$_uuid1-extra'), isFalse, reason: 'only the whole made-up forms');
    });

    group('who is the same account, adapter family by adapter family', () {
      Map<String, Object?> acc(String id, String platform, {String tier = 'openApi', String? handle, String name = 'Same name', Map<String, Object?>? config}) =>
          {'id': id, 'platformId': platform, 'tier': tier, 'handle': handle, 'displayName': name, 'config': config ?? const {}};

      test('accounts whose id comes from the account itself: two ids are two accounts, whatever the name or handle', () {
        // From each adapter's connect(): the same account gets the same id on
        // every device, so only different accounts have different ids.
        const pairs = {
          'x': ['x-111', 'x-222'],
          'bluesky': ['bluesky:did:plc:aaa', 'bluesky:did:plc:bbb'],
          'reddit': ['reddit-1', 'reddit-2'],
          'tumblr': ['tumblr:blog-a', 'tumblr:blog-b'],
          'linkedin': ['linkedin:sub-a', 'linkedin:sub-b'],
          'youtube': ['youtube:UCaaa', 'youtube:UCbbb'],
          'threads': ['threads:1', 'threads:2'],
          'instagram': ['instagram-1', 'instagram-2'],
          'facebook': ['facebook-1', 'facebook-2'],
          'pinterest': ['pinterest:1', 'pinterest:2'],
          'discord': ['discord:1', 'discord:2'],
          'telegram': ['telegram:9:1', 'telegram:9:2'],
          'matrix': ['matrix:@me:x.org:!a', 'matrix:@me:x.org:!b'],
          'lemmy': ['lemmy:me@one.example', 'lemmy:me@two.example'],
          'misskey': ['misskey:1@one.example', 'misskey:2@one.example'],
          'nostr': ['nostr-aaaa', 'nostr-bbbb'],
          'wordpress': ['wordpress:1@site.example', 'wordpress:2@site.example'],
          'ghost': ['ghost:site.example:k1', 'ghost:site.example:k2'],
          'writefreely': ['writefreely:me@w.example/a', 'writefreely:me@w.example/b'],
          'devto': ['devto:1@dev.to', 'devto:2@dev.to'],
          'hashnode': ['hashnode:p1', 'hashnode:p2'],
          'micropub': ['micropub:https://a.example/', 'micropub:https://b.example/'],
          'deviantart': ['deviantart:1', 'deviantart:2'],
          'dribbble': ['dribbble:1', 'dribbble:2'],
          'flickr': ['flickr:1', 'flickr:2'],
          'inkbunny': ['inkbunny:1', 'inkbunny:2'],
          'odysee': ['odysee:1', 'odysee:2'],
        };
        for (final e in pairs.entries) {
          expect(isSameConnectedAccount(acc(e.value[0], e.key, handle: '@same'), acc(e.value[1], e.key, handle: '@same')), isFalse, reason: e.key);
          expect(isDeviceMadeAccountId(e.value[0]), isFalse, reason: e.key);
        }
      });

      test('Mastodon and Pixelfed: the account id on its server, else the handle; another server is another account', () {
        for (final platform in ['mastodon', 'pixelfed']) {
          Map<String, Object?> on(String id, String server, String remote, {String? handle}) =>
              acc(id, platform, handle: handle, config: {'instance': 'https://$server', 'domain': server, 'remoteAccountId': remote});
          expect(isSameConnectedAccount(on(_uuid1, 'one.example', '7'), on(_uuid2, 'one.example', '7')), isTrue, reason: platform);
          expect(isSameConnectedAccount(on(_uuid1, 'one.example', '7', handle: '@old@one.example'), on(_uuid2, 'one.example', '7', handle: '@renamed@one.example')),
              isTrue,
              reason: '$platform: a renamed handle is the same account');
          expect(isSameConnectedAccount(on(_uuid1, 'one.example', '7'), on(_uuid2, 'two.example', '7')), isFalse, reason: '$platform: another server');
          expect(isSameConnectedAccount(on(_uuid1, 'one.example', '7', handle: '@a@one.example'), on(_uuid2, 'one.example', '8', handle: '@a@one.example')),
              isFalse,
              reason: '$platform: another account id, though the handle was reused');
          expect(isSameConnectedAccount(acc(_uuid1, platform, handle: '@a@one.example'), acc(_uuid2, platform, handle: '@A@One.Example')), isTrue,
              reason: '$platform: connected before the account id was recorded: the handle');
        }
        // A missing server never matches a present one (a bare host is no URL).
        final bare = acc(_uuid1, 'mastodon', handle: '@bob@one.example', config: {'instance': 'one.example', 'remoteAccountId': '7'});
        expect(accountServer(bare), isNull);
        expect(naturalAccountKey(bare), isNull);
        expect(isSameConnectedAccount(bare, acc(_uuid2, 'mastodon', handle: '@carol@two.example', config: {'instance': 'two.example', 'remoteAccountId': '7'})),
            isFalse);
      });

      test('TikTok: openId for one developer app (clientKey)', () {
        Map<String, Object?> tt(String id, String openId, String? clientKey) =>
            acc(id, 'tiktok', tier: 'byokApi', config: {'openId': openId, if (clientKey != null) 'clientKey': clientKey});
        expect(isSameConnectedAccount(tt(_uuid1, 'o1', 'k'), tt(_uuid2, 'o1', 'k')), isTrue);
        expect(isSameConnectedAccount(tt(_uuid1, 'o1', 'k'), tt(_uuid2, 'o2', 'k')), isFalse, reason: 'another TikTok user');
        expect(isSameConnectedAccount(tt(_uuid1, 'o1', 'k'), tt(_uuid2, 'o1', 'other-app')), isFalse, reason: 'openIds of two apps cannot be compared');
        expect(isSameConnectedAccount(tt(_uuid1, 'o1', null), tt(_uuid2, 'o1', null)), isFalse, reason: 'without the app, no identity');
      });

      test('hand-off accounts: one name on one server; never across servers', () {
        expect(isSameConnectedAccount(acc('instagram-handoff-$_uuid1', 'instagram', tier: 'handoff'), acc('instagram-handoff-$_uuid2', 'instagram', tier: 'handoff')),
            isTrue);
        expect(isSameConnectedAccount(acc('nostr-handoff-1761000000000000', 'nostr', tier: 'handoff'), acc('nostr-handoff-1762000000000000', 'nostr', tier: 'handoff')),
            isTrue,
            reason: 'Nostr hand-off ids are made from the clock');
        expect(isDeviceMadeAccountId('nostr-handoff-1761000000000000'), isTrue);
        Map<String, Object?> mh(String id, String server) =>
            acc(id, 'mastodon', tier: 'handoff', handle: 'alice', name: 'alice (hand-off)', config: {'instance': 'https://$server', 'domain': server});
        expect(isSameConnectedAccount(mh(_uuid1, 'one.example'), mh(_uuid2, 'one.example')), isTrue);
        expect(isSameConnectedAccount(mh(_uuid1, 'one.example'), mh(_uuid2, 'two.example')), isFalse, reason: 'another server');
        expect(
            isSameConnectedAccount(acc('lemmy-handoff:one.example', 'lemmy', tier: 'handoff', config: {'instance': 'https://one.example/'}),
                acc('lemmy-handoff:two.example', 'lemmy', tier: 'handoff', config: {'instance': 'https://two.example/'})),
            isFalse);
        expect(accountServer({'config': {'site': 'https://blog.example/'}}), 'blog.example');
        expect(accountServer({'config': {'base': 'https://dev.to'}}), 'dev.to');
        expect(accountServer({'config': {'host': 'Lemmy.Example'}}), 'lemmy.example');
      });
    });

    test('the newer sign-in: later expiry first, then the later connection; a tie is not newer', () {
      final early = {'createdAt': '2026-01-01T00:00:00.000Z'}, late = {'createdAt': '2026-06-01T00:00:00.000Z'};
      Map<String, String> keys(String expires) => {'expires_at': expires};
      expect(holdsNewerSignIn(first: late, second: early), isTrue);
      expect(holdsNewerSignIn(first: early, second: late), isFalse);
      expect(holdsNewerSignIn(first: early, firstKeys: keys('2026-12-01T00:00:00Z'), second: late, secondKeys: keys('2026-11-01T00:00:00Z')), isTrue,
          reason: 'renewed more recently beats connected more recently');
      expect(holdsNewerSignIn(first: early, second: early), isFalse);
    });
  });

  group('an interrupted first sync never loses the newer sign-in (1.3.5)', () {
    /// X holds the file: 3 accounts (its setup wins), and an old Mastodon
    /// sign-in. Y connected the same account later: the newer sign-in.
    Future<void> setUpTwins(_Device x, _Device y, {Map<String, String> yKeys = const {'access_token': 'fake-new-working'}}) async {
      await x.accounts.upsert(_account(_uuid1, 'mastodon',
          tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 1, 1), config: _mastodonConfig));
      await x.secrets.write(_uuid1, {'access_token': 'fake-old-revoked'});
      await x.accounts.upsert(_account('x-1', 'x'));
      await x.accounts.upsert(_account('t-1', 'tumblr'));
      await x.engine.sync();
      await y.accounts.upsert(_account(_uuid2, 'mastodon',
          tier: PlatformTier.openApi, handle: 'me@mastodon.example', createdAt: DateTime.utc(2026, 10, 15), config: _mastodonConfig));
      await y.secrets.write(_uuid2, yKeys);
      await y.posts.upsert(_post('py', targets: const [PostTarget(accountId: _uuid2)]));
    }

    Future<void> expectMergedWithNewerSignIn(_Device x, _Device y, {String token = 'fake-new-working'}) async {
      for (final d in [x, y]) {
        expect((await d.accounts.all()).where((a) => a.platformId == 'mastodon').map((a) => a.id), [_uuid1]);
        expect((await d.secrets.read(_uuid1))?['access_token'], token, reason: 'the newer sign-in survives on ${d.id}');
      }
      expect(await y.secrets.read(_uuid2), isNull);
      expect((await y.posts.get('py'))!.targets.single.accountId, _uuid1);
      expect(y.stateStore.data?['joined'], isTrue);
    }

    test('another device writing during the first sync: the retried pass keeps the newer sign-in', () async {
      final racy = _RacyBackend(backend);
      final x = _Device('X', backend, clock), y = _Device('Y', racy, clock);
      await setUpTwins(x, y);
      racy.beforeWrite = () async {
        racy.beforeWrite = null;
        final current = (await backend.read())!;
        await backend.write(current.bytes, ifMatch: current.version); // another device's heartbeat lands first
      };
      final r = await y.engine.sync();
      await x.engine.sync();
      expect(r.mergedAccounts, 1);
      await expectMergedWithNewerSignIn(x, y);
    });

    test('a first sync whose file write never happens: the old copy and its keys stay until a write succeeds', () async {
      final flaky = _FlakyBackend(backend);
      final x = _Device('X', backend, clock), y = _Device('Y', flaky, clock);
      await setUpTwins(x, y);
      await expectLater(y.engine.sync(), throwsA(isA<SyncBackendException>()));
      expect(await y.accounts.get(_uuid2), isNotNull, reason: 'nothing is removed before the file holds the merged account');
      expect((await y.secrets.read(_uuid2))?['access_token'], 'fake-new-working');
      expect(y.stateStore.data, isNull, reason: 'no sync state is needed to finish the merge');
      await y.engine.sync();
      await x.engine.sync();
      await expectMergedWithNewerSignIn(x, y);
    });

    test('a failed write, then Set up again (the sync state starts over): the newer sign-in still wins', () async {
      final flaky = _FlakyBackend(backend);
      final x = _Device('X', backend, clock), y = _Device('Y', flaky, clock);
      await setUpTwins(x, y);
      await expectLater(y.engine.sync(), throwsA(isA<SyncBackendException>()));
      // Turn off, Set up again (on a Mac, every Set up): the dialog writes
      // the confirmed seed over whatever the state held.
      y.stateStore.data = SyncEngine.joinState((await y.engine.preview()).seed);
      await y.engine.sync();
      await x.engine.sync();
      await expectMergedWithNewerSignIn(x, y);
    });

    test('a merge step that fails keeps the old copy and its keys, and the next sync finishes the merge', () async {
      final refusing = _RefusingAccounts(_uuid1);
      final x = _Device('X', backend, clock), y = _Device('Y', backend, clock, accountRepo: refusing);
      await setUpTwins(x, y);
      await y.engine.sync();
      expect(await y.accounts.get(_uuid2), isNotNull, reason: 'a failed step leaves a duplicate, never a lost account');
      expect((await y.secrets.read(_uuid2))?['access_token'], 'fake-new-working');
      final inFile = (await file()).records.entries.where((e) => e.key.startsWith('account:') && !e.value.deleted).map((e) => e.key).toSet();
      expect(inFile, {'account:$_uuid1', 'account:x-1', 'account:t-1'}, reason: 'the old copy never reaches the file');
      await y.engine.sync();
      await x.engine.sync();
      await expectMergedWithNewerSignIn(x, y);
    });

    test('a record this version cannot store (a newer post) holds up nothing: the merge finishes and later renewals win', () async {
      final x = _Device('X', backend, clock), y = _Device('Y', backend, clock);
      await setUpTwins(x, y, yKeys: {'access_token': 'fake-y-new', 'expires_at': '2026-11-01T00:00:00.000Z'});
      await putInFile('post:future', SyncRecord.of({
        'id': 'future',
        'text': 'from 1.3.6',
        'createdAt': '2026-10-20T00:00:00.000Z',
        'updatedAt': '2026-10-20T00:00:00.000Z',
        'status': 'queuedForReview',
        'targets': <Object?>[],
      }, at: clock.now, by: 'newer-1.3.6'));
      for (var i = 0; i < 3; i++) {
        clock.now = clock.now.add(const Duration(minutes: 5));
        await y.engine.sync();
      }
      expect((await y.accounts.all()).where((a) => a.platformId == 'mastodon').map((a) => a.id), [_uuid1]);
      expect(y.stateStore.data?['joined'], isTrue);
      await x.engine.sync();
      // X renews the sign-in: a later expiry. Y must not force its copy back.
      await x.secrets.write(_uuid1, {'access_token': 'fake-x-renewed', 'expires_at': '2026-12-01T00:00:00.000Z'});
      await x.engine.sync();
      clock.now = clock.now.add(const Duration(minutes: 5));
      await y.engine.sync();
      await x.engine.sync();
      for (final d in [x, y]) {
        expect((await d.secrets.read(_uuid1))?['access_token'], 'fake-x-renewed', reason: d.id);
      }
    });

    test('a resumed first sync after another device renewed the merged account: the later renewal wins', () async {
      final flaky = _FlakyBackend(backend)..failures = 1 << 20; // offline until it is back
      final x = _Device('X', backend, clock), y = _Device('Y', flaky, clock);
      const tt = {'clientKey': 'fake-client-key', 'openId': 'fake-open-id'};
      await x.accounts.upsert(_account(_uuid1, 'tiktok', name: 'Me', createdAt: DateTime.utc(2026, 1, 1), config: tt));
      await x.secrets.write(_uuid1, {'access_token': 'x-a', 'refresh_token': 'x-r', 'expires_at': '2026-10-20T13:00:00.000Z'});
      await x.accounts.upsert(_account('x-1', 'x'));
      await x.engine.sync();
      await y.accounts.upsert(_account(_uuid2, 'tiktok', name: 'Me', createdAt: DateTime.utc(2026, 10, 15), config: tt));
      await y.secrets.write(_uuid2, {'access_token': 'y-a', 'refresh_token': 'y-r', 'expires_at': '2026-10-21T12:00:00.000Z'});
      await expectLater(y.engine.sync(), throwsA(isA<SyncBackendException>()));
      // Y stays offline for two days; X renews meanwhile (a later expiry).
      clock.now = clock.now.add(const Duration(days: 2));
      await x.secrets.write(_uuid1, {'access_token': 'x-a2', 'refresh_token': 'x-r2', 'expires_at': '2026-10-23T12:00:00.000Z'});
      await x.engine.sync();
      flaky.failures = 0;
      await y.engine.sync();
      await x.engine.sync();
      for (final d in [x, y]) {
        expect((await d.secrets.read(_uuid1))?['access_token'], 'x-a2', reason: 'the most recently renewed sign-in wins on ${d.id}');
      }
    });

    test('the dry run of a first sync matches what it then does to the keys', () async {
      final x = _Device('X', backend, clock), y = _Device('Y', backend, clock);
      await x.accounts.upsert(_account(_uuid1, 'mastodon',
          tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 1, 1), config: _mastodonConfig));
      await x.secrets.write(_uuid1, {'access_token': 'fake-old'});
      await x.engine.sync();
      await y.accounts.upsert(_account(_uuid2, 'mastodon',
          tier: PlatformTier.openApi, handle: 'me@mastodon.example', createdAt: DateTime.utc(2026, 10, 15), config: _mastodonConfig));
      await y.secrets.write(_uuid2, {'access_token': 'fake-y-new'});
      final p = await y.engine.preview();
      expect(p.mergedAccounts, {_uuid2: _uuid1});
      expect(p.mergeEdits['secrets:$_uuid1'], {'access_token': 'fake-y-new'});
      await y.engine.sync();
      await x.engine.sync();
      expect((await x.secrets.read(_uuid1))?['access_token'], 'fake-y-new');
    });

    test('no accounts on either side and the file holds settings: the file wins, nothing is deleted', () async {
      final av = <String, Object?>{'theme': 'dark'}, bv = <String, Object?>{'theme': 'light'};
      CallbackSyncSource settings(Map<String, Object?> values) => CallbackSyncSource(
            prefix: 'setting',
            snapshot: () async => {for (final e in values.entries) e.key: SyncItem(e.value)},
            apply: (id, v) async => values[id] = v,
            appliesDeletions: false,
          );
      final x = _Device('X', backend, clock, extra: [settings(av)]), y = _Device('Y', backend, clock, extra: [settings(bv)]);
      await x.engine.sync();
      expect((await y.engine.preview()).seed, SyncSeed.file);
      await y.engine.sync();
      await x.engine.sync();
      expect([av['theme'], bv['theme']], ['dark', 'dark']);
    });

    test('two devices joining at once through a synced folder end with the account once', () async {
      final folder = _CloudFolder();
      final a = _Device('A', folder, clock), b = _Device('B', folder, clock), c = _Device('C', folder, clock);
      await a.accounts.upsert(_account('x-1', 'x'));
      await a.engine.sync();
      await b.accounts.upsert(_account(_uuid2, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig));
      await b.secrets.write(_uuid2, {'access_token': 'fake-b'});
      await c.accounts.upsert(_account(_uuid3, 'mastodon',
          tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 10, 9), config: _mastodonConfig));
      await c.secrets.write(_uuid3, {'access_token': 'fake-c-newer'});
      await c.posts.upsert(_post('pc', targets: const [PostTarget(accountId: _uuid3)]));
      folder.freeze(); // both read one version and write before the cloud app syncs
      await b.engine.sync();
      await c.engine.sync();
      folder.thaw();
      for (final d in [a, b, c, a, b, c]) {
        clock.now = clock.now.add(const Duration(minutes: 1));
        await d.engine.sync();
      }
      for (final d in [a, b, c]) {
        expect((await d.accounts.all()).where((x) => x.platformId == 'mastodon').map((x) => x.id), [_uuid2], reason: d.id);
        expect((await d.secrets.read(_uuid2))?['access_token'], 'fake-c-newer', reason: '${d.id}: the newer sign-in');
        expect((await d.posts.get('pc'))?.targets.single.accountId, _uuid2, reason: d.id);
      }
    });
  });

  group('records a version does not manage (1.3.5)', () {
    /// Settings-like records: [values] always present, deletions not taken.
    CallbackSyncSource settingsLike(Map<String, Object?> values, {Set<String>? known}) => CallbackSyncSource(
          prefix: 'setting',
          snapshot: () async => {for (final e in values.entries) e.key: SyncItem(e.value)},
          apply: (id, v) async => values[id] = v,
          handles: known?.contains,
          appliesDeletions: false,
        );

    test('a record its source does not manage stays in the file untouched', () async {
      final newer = <String, Object?>{'theme': 'dark', 'future': 'on'};
      final older = <String, Object?>{'theme': 'light'};
      final store = MemorySyncBackend();
      final n = _Device('N', store, clock, extra: [settingsLike(newer)]);
      final o = _Device('O', store, clock, extra: [settingsLike(older, known: {'theme'})]);
      await n.engine.sync();
      for (var i = 0; i < 3; i++) {
        await o.engine.sync();
        await n.engine.sync();
      }
      final doc = SyncDocument.parse(await BackupCipher(_pass, params: _fast, minimum: _fast).open(store.bytes!));
      expect(doc.records['setting:future']?.value, 'on');
      expect(older.containsKey('future'), isFalse);
      expect(newer['future'], 'on');
    });

    test('a deletion settings do not take is kept here and not sent back, and a later change still travels', () async {
      final values = <String, Object?>{'k': 'v'};
      final n = _Device('N', backend, clock, extra: [settingsLike(values)]);
      await n.engine.sync();
      // An older device that leaves defaults out wrote a deletion.
      await putInFile('setting:k', SyncRecord.tombstone(at: clock.now, by: 'old'));
      final writes = backend.writes;
      for (var i = 0; i < 3; i++) {
        await n.engine.sync();
      }
      expect(values['k'], 'v');
      expect(backend.writes, writes, reason: 'no back and forth with the older device');
      values['k'] = 'w';
      await n.engine.sync();
      expect((await file()).records['setting:k']?.value, 'w');
    });

    test("after an older NEFORUM removed a setting, a joining device does not override the file's side, and then gets its value", () async {
      final aValues = <String, Object?>{'browserQuickPost': false};
      final cValues = <String, Object?>{'browserQuickPost': true}; // the default on a new device
      final a = _Device('A', backend, clock, extra: [settingsLike(aValues)]);
      final c = _Device('C', backend, clock, extra: [settingsLike(cValues)]);
      await a.accounts.upsert(_account('x-1', 'x'));
      await a.accounts.upsert(_account('t-1', 'tumblr'));
      await a.engine.sync();
      // A 1.3.4 device removes the setting it does not know (traced from the
      // 1.3.4 engine: its second sync writes a deletion).
      await putInFile('setting:browserQuickPost', SyncRecord.tombstone(at: clock.now, by: 'old-1.3.4'));
      await a.engine.sync();
      expect(aValues['browserQuickPost'], false, reason: 'A keeps its value');
      final preview = await c.engine.preview();
      expect(preview.seed, SyncSeed.file);
      expect(preview.sent, isNot(contains('setting:browserQuickPost')), reason: 'the file has no opinion and its side wins: C sends nothing');
      await c.engine.sync();
      expect(cValues['browserQuickPost'], true, reason: 'C keeps its own until the file has a value');
      await a.engine.sync(); // A sees C for the first time: puts its value back once
      expect(aValues['browserQuickPost'], false, reason: "the file's side is never overwritten by the joining device");
      await c.engine.sync();
      expect(cValues['browserQuickPost'], false, reason: "then C gets the file side's value: the seed holds");
      final writes = backend.writes;
      for (var i = 0; i < 3; i++) {
        await a.engine.sync();
        await c.engine.sync();
      }
      expect(backend.writes, writes, reason: 'once, not back and forth');
    });

    test('when the joining device wins, its value replaces what an older NEFORUM removed', () async {
      final aValues = <String, Object?>{'browserQuickPost': false};
      final cValues = <String, Object?>{'browserQuickPost': true};
      final a = _Device('A', backend, clock, extra: [settingsLike(aValues)]);
      final c = _Device('C', backend, clock, extra: [settingsLike(cValues)]);
      await a.engine.sync();
      await putInFile('setting:browserQuickPost', SyncRecord.tombstone(at: clock.now, by: 'old-1.3.4'));
      await a.engine.sync();
      await c.accounts.upsert(_account('c-1', 'x'));
      expect((await c.engine.preview()).sent, contains('setting:browserQuickPost'));
      await c.engine.sync();
      await a.engine.sync();
      expect(aValues['browserQuickPost'], true, reason: 'C has more accounts: its setup wins');
    });

    test('a value this device cannot keep is asked for again, never deleted from the file', () async {
      final kept = <String, Object?>{};
      CallbackSyncSource hosts(Map<String, Object?> store, {bool knowsFuture = true}) => CallbackSyncSource(
            prefix: 'mediaHosts',
            snapshot: () async => {for (final e in store.entries) e.key: SyncItem(e.value)},
            apply: (id, v) async {
              if (v is Map && v['id'] == 'future-host' && !knowsFuture) return; // cannot store it: silently nothing
              if (v == null) {
                store.remove(id);
              } else {
                store[id] = v;
              }
            },
          );
      final x = _Device('X', backend, clock, extra: [hosts({'all': {'id': 'future-host'}})]);
      final y = _Device('Y', backend, clock, extra: [hosts(kept, knowsFuture: false)]);
      await x.engine.sync();
      for (var i = 0; i < 3; i++) {
        await y.engine.sync();
      }
      expect((await file()).records['mediaHosts:all']?.deleted, isFalse, reason: 'Y has none, and does not take X\'s away');
      expect(kept, isEmpty);
    });

    test('a first sync can combine both versions of a record', () async {
      final xHosts = <String, Object?>{'all': {'main': 'x-main', 'fallback': null}};
      final yHosts = <String, Object?>{'all': {'main': 'y-main', 'fallback': 'y-fallback'}};
      CallbackSyncSource hosts(Map<String, Object?> s) => CallbackSyncSource(
            prefix: 'mediaHosts',
            snapshot: () async => {for (final e in s.entries) e.key: SyncItem(e.value)},
            apply: (id, v) async => s[id] = v,
            joinMerge: (id, here, there, {required hereWins}) {
              final w = (hereWins ? here : there)! as Map, l = (hereWins ? there : here)! as Map;
              return {'main': w['main'] ?? l['main'], 'fallback': w['fallback'] ?? l['fallback']};
            },
          );
      final x = _Device('X', backend, clock, extra: [hosts(xHosts)]);
      await x.accounts.upsert(_account('one', 'x'));
      final y = _Device('Y', backend, clock, extra: [hosts(yHosts)]);
      await x.engine.sync();
      final preview = await y.engine.preview();
      expect(preview.seed, SyncSeed.file);
      expect(preview.received['mediaHosts:all'], {'main': 'x-main', 'fallback': 'y-fallback'});
      expect(preview.sent, contains('mediaHosts:all'));
      await y.engine.sync();
      await x.engine.sync();
      expect(xHosts['all'], {'main': 'x-main', 'fallback': 'y-fallback'});
      expect(yHosts['all'], {'main': 'x-main', 'fallback': 'y-fallback'});
    });
  });

  group('dry run (1.3.5)', () {
    Future<Map<String, String>> localRecords(_Device d) async => {
          for (final s in [AccountsSyncSource(d.accounts), SecretsSyncSource(d.accounts, d.secrets), PostsSyncSource(d.posts)])
            for (final e in (await s.snapshot()).entries) '${s.prefix}:${e.key}': syncHash(e.value.value),
        };
    Map<String, String> changed(Map<String, String> before, Map<String, String> after) => {
          for (final k in {...before.keys, ...after.keys})
            if (before[k] != after[k]) k: after[k] ?? 'removed',
        };

    test('the dry run says exactly what the first sync then does, and does none of it', () async {
      await a.accounts.upsert(_account(_uuid1, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig));
      await a.secrets.write(_uuid1, {'access_token': 'fake-a'});
      await a.accounts.upsert(_account('x-1', 'x'));
      await a.accounts.upsert(_account('t-1', 'tumblr'));
      await a.posts.upsert(_post('pa'));
      await a.engine.sync();
      await b.accounts.upsert(_account(_uuid2, 'mastodon',
          tier: PlatformTier.openApi, handle: 'me@mastodon.example', createdAt: DateTime.utc(2026, 10, 10), config: _mastodonConfig));
      await b.secrets.write(_uuid2, {'access_token': 'fake-b'});
      await b.accounts.upsert(_account('bsky', 'bluesky'));
      await b.posts.upsert(_post('pb', targets: const [PostTarget(accountId: _uuid2)]));

      final localBefore = await localRecords(b);
      final fileBefore = {for (final e in (await file()).records.entries) e.key: e.value.toJson().toString()};
      final writes = backend.writes;
      final preview = await b.engine.preview();
      expect(backend.writes, writes, reason: 'the dry run writes nothing');
      expect(b.stateStore.data, isNull, reason: 'nor the sync state');
      expect(await localRecords(b), localBefore, reason: 'nor anything here');

      expect(preview.firstJoin, isTrue);
      expect(preview.seed, SyncSeed.file);
      expect(preview.here, SyncSideSummary(accounts: 2, oldestConnection: DateTime.utc(2026, 10, 1)));
      expect(preview.file.accounts, 3);
      expect(preview.mergedAccounts, {_uuid2: _uuid1});
      expect(preview.fromDevices, ['A']);
      expect(preview.removed, isEmpty);

      final report = await b.engine.sync();
      final localChanges = changed(localBefore, await localRecords(b));
      final fileAfter = {for (final e in (await file()).records.entries) e.key: e.value.toJson().toString()};
      final fileChanges = {for (final k in {...fileBefore.keys, ...fileAfter.keys}) if (fileBefore[k] != fileAfter[k]) k};
      expect(localChanges.keys.toSet(), {...preview.received.keys, ...preview.mergeEdits.keys}, reason: 'what arrived here is what the dry run said');
      expect(fileChanges, preview.sent, reason: 'what went into the file is what the dry run said');
      expect(report.mergedAccounts, preview.mergedAccounts.length);
      expect(report.received, preview.received.length + preview.removed.length);
      expect(report.sent, preview.sent.length);
    });

    test('after joining, the dry run lists the next ordinary sync', () async {
      await a.posts.upsert(_post('p1'));
      await a.engine.sync();
      await b.engine.sync();
      await a.posts.upsert(_post('p1', text: 'edited', updatedAt: DateTime.utc(2026, 10, 20, 12, 30)));
      await a.engine.sync();
      final preview = await b.engine.preview();
      expect(preview.firstJoin, isFalse);
      expect(preview.seed, isNull);
      expect(preview.received.keys, ['post:p1']);
    });
  });

  test('every account field is classified once, and only device-only ones stay behind', () async {
    final full = ConnectedAccount(
      id: 'acct',
      platformId: 'mastodon',
      tier: PlatformTier.openApi,
      displayName: 'Full',
      createdAt: DateTime.utc(2026),
      handle: '@full@m.example',
      avatarUrl: 'https://m.example/a.png',
      profileUrl: 'https://m.example/@full',
      config: const {'k': 'v'},
      quotaOverrides: const {'q': 1},
      enabled: false,
      lastError: 'it failed here',
    );
    final keys = full.toJson().keys.toSet();
    expect(kSyncedAccountFields.intersection(kDeviceOnlyAccountFields.keys.toSet()), isEmpty, reason: 'in both lists');
    expect({...kSyncedAccountFields, ...kDeviceOnlyAccountFields.keys}, keys, reason: 'every field in one list, and no list entry that is not a field');
    expect(kDeviceOnlyAccountFields.values.every((why) => why.isNotEmpty), isTrue);
    await a.accounts.upsert(full);
    final shared = (await AccountsSyncSource(a.accounts).snapshot())['acct']!.value! as Map;
    expect(shared.keys.toSet(), kSyncedAccountFields);
    // The receiving device keeps its own last error.
    await b.accounts.upsert(_account('acct', 'mastodon').copyWith(lastError: 'its own problem'));
    await AccountsSyncSource(b.accounts).apply('acct', shared);
    expect((await b.accounts.get('acct'))!.lastError, 'its own problem');
  });

  test('no key ever reaches a log line', () async {
    final lines = <String>[];
    void sink(LogLevel level, String area, String message, [Object? error]) => lines.add('$area $message ${error ?? ''}');
    final store = MemorySyncBackend();
    final x = _Device('X', store, clock, log: sink), y = _Device('Y', store, clock, log: sink);
    await x.accounts.upsert(_account(_uuid1, 'mastodon', tier: PlatformTier.openApi, handle: '@me@m.example', config: _mastodonConfig));
    await x.secrets.write(_uuid1, {'access_token': 'fake-secret-one', 'refresh_token': 'fake-secret-two'});
    await x.engine.sync();
    await y.accounts.upsert(_account(_uuid2, 'mastodon', tier: PlatformTier.openApi, handle: 'me@m.example', createdAt: DateTime.utc(2026, 10, 9), config: _mastodonConfig));
    await y.secrets.write(_uuid2, {'access_token': 'fake-secret-three'});
    await y.engine.preview();
    await y.engine.sync();
    await x.engine.sync();
    expect(lines, isNotEmpty, reason: 'the merge is logged');
    for (final l in lines) {
      expect(l, isNot(contains('fake-secret')), reason: l);
    }
  });

  test('a post keeps its other targets when a merged account is renamed in it', () {
    final p = PostsSyncSource(InMemoryPostRepository());
    final value = _post('p', targets: const [PostTarget(accountId: 'old'), PostTarget(accountId: 'other')]).toJson();
    final moved = p.remapAccountIds('p', value, {'old': 'new'})! as Map;
    expect([for (final t in moved['targets'] as List) (t as Map)['accountId']], ['new', 'other']);
    expect(identical(p.remapAccountIds('p', value, {'nobody': 'x'}), value), isTrue, reason: 'unchanged posts stay the same object');
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

/// Refuses the next write as if offline (the app closed or the network gone
/// between storing and writing).
class _FlakyBackend extends SyncBackend {
  _FlakyBackend(this.inner);
  final MemorySyncBackend inner;
  int failures = 1;

  @override
  String get label => 'flaky';
  @override
  bool get atomicWrites => true;
  @override
  Future<SyncBlob?> read() => inner.read();
  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) async {
    if (failures > 0) {
      failures--;
      throw const SyncBackendException('offline', temporary: true);
    }
    return inner.write(bytes, ifMatch: ifMatch);
  }

  @override
  Future<void> check() async {}
}

/// A synced folder whose cloud app keeps both versions when two devices
/// write over the same version (a conflicted copy), as Dropbox or OneDrive
/// do.
class _CloudFolder extends SyncBackend {
  Uint8List? bytes;
  int version = 0;
  bool frozen = false;
  Uint8List? frozenBytes;
  int? frozenVersion;
  final copies = <SyncSideCopy>[];
  final pendingCopies = <SyncSideCopy>[];

  /// From now on every device reads the version of this moment (the cloud
  /// app has not delivered newer ones yet).
  void freeze() {
    frozen = true;
    frozenBytes = bytes;
    frozenVersion = version;
  }

  /// The cloud app catches up and shows the conflicted copies.
  void thaw() {
    frozen = false;
    copies.addAll(pendingCopies);
    pendingCopies.clear();
  }

  @override
  bool get atomicWrites => false;
  @override
  String get label => 'cloud folder';

  @override
  Future<SyncBlob?> read() async {
    if (frozen) return frozenBytes == null ? null : SyncBlob(Uint8List.fromList(frozenBytes!), '$frozenVersion');
    return bytes == null ? null : SyncBlob(Uint8List.fromList(bytes!), '$version');
  }

  @override
  Future<String?> write(Uint8List data, {required String? ifMatch}) async {
    if (frozen && bytes != null && version != frozenVersion) {
      pendingCopies.add(SyncSideCopy('NEFORUM (conflicted copy ${pendingCopies.length}).neforumsync', Uint8List.fromList(data)));
      return '$version';
    }
    bytes = Uint8List.fromList(data);
    version++;
    return '$version';
  }

  @override
  Future<List<SyncSideCopy>> conflictCopies() async => List.of(copies);

  @override
  Future<void> removeConflictCopy(SyncSideCopy copy) async => copies.remove(copy);

  @override
  Future<void> check() async {}
}

/// Accounts whose store refuses [failOn] once.
class _RefusingAccounts extends InMemoryAccountRepository {
  _RefusingAccounts(this.failOn);
  final String failOn;
  int failures = 1;

  @override
  Future<void> upsert(ConnectedAccount a) async {
    if (a.id == failOn && failures > 0) {
      failures--;
      throw StateError('the disk is full');
    }
    return super.upsert(a);
  }
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
