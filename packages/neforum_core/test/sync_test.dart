import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/tiktok/tiktok_adapter.dart';
import 'package:neforum_core/src/adapters/tumblr/tumblr_adapter.dart';
import 'package:neforum_core/src/adapters/x/x_adapter.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_context.dart';

const _fast = BackupKdfParams.testing;
const _pass = 'shared sync passphrase';

/// One device on the shared file: its own data, keychain and sync state.
class _Device {
  _Device(this.id, this.backend, this.clock, {List<SyncSource> extra = const [], LogSink? log, InMemoryAccountRepository? accountRepo, InMemorySecretStore? secretStore})
      : accounts = accountRepo ?? InMemoryAccountRepository(),
        posts = InMemoryPostRepository(),
        secrets = secretStore ?? InMemorySecretStore(),
        stateStore = MemorySyncStateStore(),
        _extra = extra,
        _log = log {
    restart();
  }

  /// A fresh process: a new engine over the same data, keychain and state.
  void restart() {
    engine = SyncEngine(
      backend: backend,
      cipher: BackupCipher(_pass, params: _fast, minimum: _fast, derive: (p, s, k) {
        deriveCount++;
        return deriveBackupKey(p, s, k);
      }),
      deviceId: id,
      device: SyncDeviceInfo(label: id, platform: 'test', appVersion: '1.0.8', seenAt: DateTime.utc(2000)),
      sources: [AccountsSyncSource(accounts), SecretsSyncSource(accounts, secrets), PostsSyncSource(posts), ..._extra],
      state: stateStore,
      secrets: secrets,
      clock: () => clock.now,
      sleep: (d) async => clock.now = clock.now.add(d),
      log: _log == null ? null : Logger('sync', sink: _log),
    );
  }

  final String id;
  final SyncBackend backend;
  final _Clock clock;
  final InMemoryAccountRepository accounts;
  final InMemoryPostRepository posts;
  final InMemorySecretStore secrets;
  final MemorySyncStateStore stateStore;
  final List<SyncSource> _extra;
  final LogSink? _log;
  late SyncEngine engine;
  int deriveCount = 0;

  Future<List<String>> ids(String platform) async => [for (final a in await accounts.all()) if (a.platformId == platform) a.id]..sort();
}

/// The property the dry run must hold: [d]'s preview equals what its sync
/// then does, for every kind of record, here and in the file. Runs the
/// preview, checks it wrote nothing, syncs for real, and compares.
Future<SyncPreview> _expectDryRunEqualsSync(_Device d, {List<SyncSource> extra = const []}) async {
  final cipher = BackupCipher(_pass, params: _fast, minimum: _fast);
  Future<Map<String, SyncItem>> records() async => {
        for (final s in [AccountsSyncSource(d.accounts), SecretsSyncSource(d.accounts, d.secrets), PostsSyncSource(d.posts), ...extra])
          for (final e in (await s.snapshot()).entries) '${s.prefix}:${e.key}': e.value,
      };
  Future<SyncDocument> file() async {
    final blob = await d.backend.read();
    return blob == null ? SyncDocument() : SyncDocument.parse(await cipher.open(blob.bytes));
  }

  final before = await records();
  final fileBefore = await file();
  final stateBefore = d.stateStore.data == null ? null : jsonEncode(d.stateStore.data);
  final blobBefore = (await d.backend.read())?.bytes;
  final p = await d.engine.preview();
  expect((await d.backend.read())?.bytes, blobBefore, reason: '${d.id}: the dry run writes nothing into the file');
  expect(d.stateStore.data == null ? null : jsonEncode(d.stateStore.data), stateBefore, reason: '${d.id}: nor the sync state');
  expect({for (final e in (await records()).entries) e.key: syncHash(e.value.value)}, {for (final e in before.entries) e.key: syncHash(e.value.value)},
      reason: '${d.id}: nor anything here');
  await d.engine.sync();
  final after = await records();
  final fileAfter = await file();
  String? h(SyncItem? i) => i == null ? null : syncHash(i.value);
  final changed = {for (final k in {...before.keys, ...after.keys}) if (h(before[k]) != h(after[k])) k};
  final kinds = {for (final k in changed) k.substring(0, k.indexOf(':')), for (final k in p.received.keys) k.substring(0, k.indexOf(':'))};
  for (final kind in kinds) {
    bool of(String k) => k.startsWith('$kind:');
    expect(p.received.keys.where(of).toSet(), {for (final k in changed.where(of)) if (after.containsKey(k)) k}, reason: '${d.id} $kind: what arrives or changes here');
    for (final k in p.received.keys.where(of)) {
      expect(syncHash(p.received[k]), h(after[k]), reason: '${d.id} $k: the value that arrives');
    }
    expect(p.removed.where(of).toSet(), {for (final k in changed.where(of)) if (!after.containsKey(k)) k}, reason: '${d.id} $kind: what goes here');
  }
  SyncRecord? live(SyncDocument doc, String k) => doc.records[k] == null || doc.records[k]!.deleted ? null : doc.records[k];
  final sent = {
    for (final k in fileAfter.records.keys)
      if (live(fileAfter, k) != null && before[k] != null && live(fileAfter, k)!.hash != live(fileBefore, k)?.hash && h(before[k]) != live(fileBefore, k)?.hash) k,
  };
  expect(p.sent, sent, reason: "${d.id}: this device's own records the file gets");
  for (final k in sent) {
    expect(syncHash(p.sentValues[k]), live(fileAfter, k)!.hash, reason: '${d.id} $k: the value the file gets');
  }
  return p;
}

/// Each device syncs once, a minute apart, [n] times over.
Future<void> _rounds(List<_Device> devices, _Clock clock, int n) async {
  for (var i = 0; i < n; i++) {
    for (final d in devices) {
      clock.now = clock.now.add(const Duration(minutes: 1));
      await d.engine.sync();
    }
  }
}

/// A WordPress hand-off as WordPressAdapter connects one: a natural id with
/// the site's path, a name with its host only.
ConnectedAccount _wordPressHandoff(String siteUrl, DateTime at) {
  final site = Uri.parse(siteUrl);
  return ConnectedAccount(
      id: 'wordpress-handoff:${site.host}${site.path}',
      platformId: 'wordpress',
      tier: PlatformTier.handoff,
      displayName: '${site.host} (hand-off)',
      profileUrl: site.toString(),
      createdAt: at,
      config: {'site': site.toString()});
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
      await a.accounts.upsert(_account('instagram-handoff-$_uuid1', 'instagram', tier: PlatformTier.handoff, name: 'Instagram (hand-off)'));
      await a.engine.sync();
      await b.accounts.upsert(_account('instagram-handoff-$_uuid2', 'instagram', tier: PlatformTier.handoff, name: 'Instagram (hand-off)'));
      await b.posts.upsert(_post('p1', targets: [const PostTarget(accountId: 'instagram-handoff-$_uuid2')]));
      await b.engine.sync();
      expect((await b.accounts.all()).map((x) => x.id), ['instagram-handoff-$_uuid1']);
      expect((await b.posts.get('p1'))!.targets.single.accountId, 'instagram-handoff-$_uuid1');
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

    test('the file counts an account it holds twice (two devices connected it at the same moment) once', () async {
      await a.accounts.upsert(_account('m1', 'mastodon', name: 'From A', createdAt: DateTime.utc(2026, 5, 1)));
      await a.engine.sync();
      for (final id in [_uuid2, _uuid3]) {
        await putInFile('account:$id',
            SyncRecord.of(_account(id, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig, createdAt: DateTime.utc(2026, 5, 1)).toJson(), at: clock.now, by: 'O'));
      }
      // B has two accounts, one of them older: the file holds two accounts
      // too, under three ids, so the oldest connection decides, for B.
      await b.accounts.upsert(_account('m1', 'mastodon', name: 'From B', createdAt: DateTime.utc(2026, 5, 1)));
      await b.accounts.upsert(_account('b2', 'tumblr', createdAt: DateTime.utc(2024, 3, 1)));
      final p = await b.engine.preview();
      expect(p.file.accounts, 2, reason: 'm1, and the Mastodon account held twice, counted once');
      expect(p.here.accounts, 2);
      expect(p.mergedInFile, hasLength(1));
      expect(p.seed, SyncSeed.thisDevice, reason: 'a tie on accounts, and B has been in use since 2024');
      await b.engine.sync();
      expect((await b.accounts.get('m1'))?.displayName, 'From B');
      expect(await b.ids('mastodon'), hasLength(2), reason: 'm1 and the merged copy');
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
      expect(isSameConnectedAccount(acc('instagram-handoff-$_uuid1', 'instagram', tier: 'handoff', name: 'IG'), acc('instagram-handoff-$_uuid2', 'instagram', tier: 'handoff', name: 'IG')), isTrue);
      expect(isSameConnectedAccount(acc('instagram-handoff-$_uuid1', 'instagram', tier: 'handoff', name: 'IG'), acc('instagram-handoff-$_uuid2', 'instagram', tier: 'handoff', name: 'IG 2')), isFalse);
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

    test('the newer sign-in: through two apps the later connection, then the later expiry; through one app the reverse; a tie is not newer', () {
      Map<String, Object?> acc(String created, String app) =>
          {'platformId': 'tiktok', 'tier': 'byokApi', 'createdAt': created, 'config': {'clientKey': app}, 'displayName': 'Me $app'};
      final early = acc('2026-01-01T00:00:00.000Z', 'ck-old'), late = acc('2026-06-01T00:00:00.000Z', 'ck-new');
      final lateSameApp = {...acc('2026-06-01T00:00:00.000Z', 'ck-old'), 'displayName': 'renamed', 'handle': '@other-profile'};
      Map<String, String> keys(String expires) => {'expires_at': expires};
      expect(holdsNewerSignIn(first: late, second: early), isTrue);
      expect(holdsNewerSignIn(first: early, second: late), isFalse);
      // Two apps: a renewal of the older connection never beats a reconnect.
      expect(holdsNewerSignIn(first: early, firstKeys: keys('2026-12-01T00:00:00Z'), second: late, secondKeys: keys('2026-11-01T00:00:00Z')), isFalse,
          reason: 'a renewal of the old app never beats a reconnect with another');
      expect(holdsNewerSignIn(first: late, firstKeys: keys('2026-11-01T00:00:00Z'), second: early, secondKeys: keys('2026-12-01T00:00:00Z')), isTrue);
      // One app (profile details and the user's edits aside): renewed more recently wins.
      expect(sharesRegistration(early, lateSameApp), isTrue);
      expect(sharesRegistration(early, late), isFalse);
      expect(holdsNewerSignIn(first: early, firstKeys: keys('2026-12-01T00:00:00Z'), second: lateSameApp, secondKeys: keys('2026-11-01T00:00:00Z')), isTrue,
          reason: 'one app: the renewal that worked last');
      expect(holdsNewerSignIn(first: lateSameApp, firstKeys: keys('2026-11-01T00:00:00Z'), second: early, secondKeys: keys('2026-12-01T00:00:00Z')), isFalse);
      expect(holdsNewerSignIn(first: lateSameApp, second: early), isTrue, reason: 'one app, no expiry: the later connection');
      expect(holdsNewerSignIn(first: early, firstKeys: keys('2026-12-01T00:00:00Z'), second: early, secondKeys: keys('2026-11-01T00:00:00Z')), isTrue,
          reason: 'one connection: renewed more recently wins');
      expect(holdsNewerSignIn(first: early, firstKeys: keys('2026-11-01T00:00:00Z'), second: early, secondKeys: keys('2026-12-01T00:00:00Z')), isFalse);
      expect(holdsNewerSignIn(first: early, second: early), isFalse);
      expect(holdsNewerSignIn(first: early, firstKeys: keys('2026-12-01T00:00:00Z'), second: early, secondKeys: keys('2026-12-01T00:00:00Z')), isFalse);
      expect(holdsNewerSignIn(first: const {}, firstKeys: keys('2026-12-01T00:00:00Z'), second: late, secondKeys: keys('2026-11-01T00:00:00Z')), isTrue,
          reason: 'no readable connection time on one side: the expiry decides');
      expect(sharesRegistration(const {}, const {}), isFalse, reason: 'no network named: never one registration');
      expect(sharesRegistration({...early, 'tier': 'openApi'}, early), isFalse);
      expect(compareConnections(late, early), greaterThan(0));
      expect(compareConnections(early, late), lessThan(0));
      expect(compareConnections(early, {'createdAt': 'not a date'}), 0);
      expect(compareConnections(null, early), 0);
    });
  });

  group('an interrupted first sync never loses the newer sign-in (1.3.5)', () {
    /// X holds the file: 3 accounts (its setup wins), and an old Mastodon
    /// sign-in. Y connected the same account later: the newer sign-in.
    Future<void> setUpTwins(_Device x, _Device y, {Map<String, String> yKeys = const {'access_token': 'fake-new-working'}}) async {
      await x.accounts.upsert(_account(_uuid1, 'mastodon',
          tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 1, 1), config: {..._mastodonConfig, 'scopes': 'old app'}));
      await x.secrets.write(_uuid1, {'access_token': 'fake-old-revoked'});
      await x.accounts.upsert(_account('x-1', 'x'));
      await x.accounts.upsert(_account('t-1', 'tumblr'));
      await x.engine.sync();
      await y.accounts.upsert(_account(_uuid2, 'mastodon',
          tier: PlatformTier.openApi, handle: 'me@mastodon.example', createdAt: DateTime.utc(2026, 10, 15), config: {..._mastodonConfig, 'scopes': 'new app'}));
      await y.secrets.write(_uuid2, yKeys);
      await y.posts.upsert(_post('py', targets: const [PostTarget(accountId: _uuid2)]));
    }

    Future<void> expectMergedWithNewerSignIn(_Device x, _Device y, {String token = 'fake-new-working'}) async {
      for (final d in [x, y]) {
        expect((await d.accounts.all()).where((a) => a.platformId == 'mastodon').map((a) => a.id), [_uuid1]);
        expect((await d.secrets.read(_uuid1))?['access_token'], token, reason: 'the newer sign-in survives on ${d.id}');
        expect((await d.accounts.get(_uuid1))!.config['scopes'], 'new app',
            reason: "${d.id}: the account's details come with its keys (an app registration and its token belong together)");
      }
      final doc = await file();
      expect(doc.records.containsKey('account:$_uuid2'), isFalse, reason: 'a copy that never was in the file leaves no trace there');
      expect(doc.records.containsKey('secrets:$_uuid2'), isFalse);
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

    test('a resumed first sync after another device renewed the merged account (one app on both copies): the later renewal wins', () async {
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
        expect((await d.accounts.get(_uuid1))!.createdAt, DateTime.utc(2026, 1, 1), reason: '${d.id}: the account comes with its keys');
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

  group('different accounts are never merged, and a merge leaves nothing dangling (1.3.5)', () {
    test('two blogs of one WordPress multisite made on two joined devices stay two', () async {
      await a.accounts.upsert(_wordPressHandoff('https://example.com/blog-one', DateTime.utc(2026, 5, 1)));
      await a.engine.sync();
      await b.engine.sync(); // B joins with nothing
      await b.accounts.upsert(_wordPressHandoff('https://example.com/blog-two', DateTime.utc(2026, 6, 1)));
      await b.posts.upsert(_post('p-two', targets: const [PostTarget(accountId: 'wordpress-handoff:example.com/blog-two')]));
      await _rounds([b, a, b, a], clock, 1);
      expect(await a.ids('wordpress'), hasLength(2), reason: 'two natural ids are two blogs');
      expect((await a.posts.get('p-two'))!.targets.single.accountId, 'wordpress-handoff:example.com/blog-two');
    });

    test('switching one of two blogs off on another device does not make them twins, and a post to both keeps both', () async {
      await a.accounts.upsert(_wordPressHandoff('https://example.com/blog-one', DateTime.utc(2026, 5, 1)));
      await a.accounts.upsert(_wordPressHandoff('https://example.com/blog-two', DateTime.utc(2026, 6, 1)));
      await a.posts.upsert(_post('p-both', targets: const [
        PostTarget(accountId: 'wordpress-handoff:example.com/blog-one'),
        PostTarget(accountId: 'wordpress-handoff:example.com/blog-two'),
      ]));
      await a.engine.sync();
      await b.engine.sync();
      final two = await b.accounts.get('wordpress-handoff:example.com/blog-two');
      await b.accounts.upsert(two!.copyWith(enabled: false));
      await _rounds([b, a, b, a], clock, 1);
      expect(await a.ids('wordpress'), hasLength(2));
      expect((await a.posts.get('p-both'))!.targets.map((t) => t.accountId), ['wordpress-handoff:example.com/blog-one', 'wordpress-handoff:example.com/blog-two']);
    });

    test('hand-off copies that both live in the file are never merged later; only a first sync merges a hand-off', () async {
      // Made on two devices that were already syncing, under one name.
      await a.engine.sync();
      await b.engine.sync();
      await a.accounts.upsert(_account('instagram-handoff-$_uuid1', 'instagram', tier: PlatformTier.handoff, name: 'Instagram (hand-off)'));
      await a.engine.sync();
      await b.accounts.upsert(_account('instagram-handoff-$_uuid2', 'instagram', tier: PlatformTier.handoff, name: 'Instagram (hand-off)'));
      await _rounds([b, a, b, a], clock, 1);
      expect(await a.ids('instagram'), hasLength(2), reason: 'two hand-off accounts the user made on purpose');
    });

    test('a hand-off on another site, or with another handle, is never a twin', () {
      Map<String, Object?> h(String id, {String? site, String? handle}) => {
            'id': id,
            'platformId': 'wordpress',
            'tier': 'handoff',
            'displayName': 'example.com (hand-off)',
            'handle': handle,
            'config': {'site': ?site},
          };
      expect(isSameConnectedAccount(h(_uuid1, site: 'https://example.com/blog-one'), h(_uuid2, site: 'https://example.com/blog-two')), isFalse);
      expect(isSameConnectedAccount(h(_uuid1, site: 'https://example.com/blog-one/'), h(_uuid2, site: 'https://Example.com/blog-one')), isTrue);
      expect(isSameConnectedAccount(h(_uuid1, handle: 'alice'), h(_uuid2, handle: 'bob')), isFalse);
      expect(isSameConnectedAccount(h('wordpress-handoff:example.com/a', site: 'https://example.com/a'), h('wordpress-handoff:example.com/a2', site: 'https://example.com/a')),
          isFalse,
          reason: 'two natural ids, whatever the tier');
      expect(handoffSite({'config': {'site': 'https://Example.com/blog-one/'}}), 'example.com/blog-one');
    });

    test('accounts matched by a handle alone are never the same on two servers', () {
      Map<String, Object?> m(String id, String server) =>
          {'id': id, 'platformId': 'mastodon', 'tier': 'openApi', 'handle': 'alice', 'displayName': 'alice', 'config': {'domain': server}};
      expect(isSameConnectedAccount(m(_uuid1, 'one.example'), m(_uuid2, 'two.example')), isFalse);
      expect(isSameConnectedAccount(m(_uuid1, 'one.example'), m(_uuid2, 'one.example')), isTrue);
    });

    test('accounts matched by their handle, joining at once through a cloud folder, become one', () async {
      final folder = _CloudFolder();
      final x = _Device('X', folder, clock), y = _Device('Y', folder, clock), z = _Device('Z', folder, clock);
      const config = {'instance': 'https://mastodon.example', 'domain': 'mastodon.example'}; // connected before the account id was recorded
      await x.accounts.upsert(_account('x-1', 'x'));
      await x.engine.sync();
      await y.accounts.upsert(_account(_uuid2, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: config));
      await z.accounts.upsert(_account(_uuid3, 'mastodon', tier: PlatformTier.openApi, handle: '@Me@Mastodon.Example', config: config));
      folder.freeze();
      await y.engine.sync();
      await z.engine.sync();
      folder.thaw();
      await _rounds([x, y, z], clock, 2);
      for (final d in [x, y, z]) {
        expect(await d.ids('mastodon'), [_uuid2], reason: '${d.id}: the copy that arrived through the conflicted copy is new to the file');
      }
    });

    test('two copies matched by their handle alone that both already were in the file are left apart', () async {
      await a.engine.sync();
      const config = {'instance': 'https://mastodon.example', 'domain': 'mastodon.example'};
      for (final id in [_uuid1, _uuid2]) {
        await putInFile('account:$id', SyncRecord.of(_account(id, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: config).toJson(), at: clock.now, by: 'other'));
      }
      await _rounds([a, b], clock, 2);
      expect(await a.ids('mastodon'), [_uuid1, _uuid2], reason: 'without an identity on the network, only a copy new to the file merges');
    });

    test('a post to both copies of a merged account keeps one target', () {
      final p = PostsSyncSource(InMemoryPostRepository());
      final value = _post('p', targets: const [PostTarget(accountId: 'old'), PostTarget(accountId: 'kept'), PostTarget(accountId: 'other')]).toJson();
      final moved = p.remapAccountIds('p', value, {'old': 'kept'})! as Map;
      expect([for (final t in moved['targets'] as List) (t as Map)['accountId']], ['kept', 'other']);
    });

    test('three devices, TikTok twins joining at once through a cloud folder: the sign-in that expires last survives', () async {
      final folder = _CloudFolder();
      final x = _Device('X', folder, clock), y = _Device('Y', folder, clock), z = _Device('Z', folder, clock);
      const tt = {'clientKey': 'fake-client-key', 'openId': 'fake-open-id'};
      await x.accounts.upsert(_account(_uuid3, 'tiktok', name: 'Me', createdAt: DateTime.utc(2026, 1, 1), config: tt));
      await x.secrets.write(_uuid3, {'access_token': 'x-a', 'refresh_token': 'x-r', 'expires_at': '2026-10-20T13:00:00.000Z'});
      await x.accounts.upsert(_account('x-1', 'x'));
      await x.engine.sync();
      await y.accounts.upsert(_account(_uuid1, 'tiktok', name: 'Me', createdAt: DateTime.utc(2026, 10, 18), config: tt));
      await y.secrets.write(_uuid1, {'access_token': 'y-a', 'refresh_token': 'y-r', 'expires_at': '2026-10-21T12:00:00.000Z'});
      await z.accounts.upsert(_account(_uuid2, 'tiktok', name: 'Me', createdAt: DateTime.utc(2026, 10, 10), config: tt));
      await z.secrets.write(_uuid2, {'access_token': 'z-a', 'refresh_token': 'z-r', 'expires_at': '2026-10-20T18:00:00.000Z'});
      for (final d in [x, y, z]) {
        await d.posts.upsert(_post('p-${d.id}', targets: [PostTarget(accountId: (await d.ids('tiktok')).single)]));
      }
      folder.freeze();
      await y.engine.sync();
      clock.now = clock.now.add(const Duration(seconds: 30));
      await z.engine.sync(); // the cloud app keeps Z's write as a conflicted copy
      folder.thaw();
      await _rounds([x, y, z], clock, 4);
      for (final d in [x, y, z]) {
        expect(await d.ids('tiktok'), [_uuid3], reason: d.id);
        expect((await d.secrets.read(_uuid3))?['access_token'], 'y-a', reason: '${d.id}: the later expiry');
        for (final p in ['p-X', 'p-Y', 'p-Z']) {
          expect((await d.posts.get(p))?.targets.single.accountId, _uuid3, reason: '${d.id} $p');
        }
      }
    });

    test('a crash between the file write and the removal of the merged copy: the restarted app converges', () async {
      final crashing = _CrashAfterWrite(backend);
      final x = _Device('X', backend, clock), y = _Device('Y', crashing, clock);
      await x.accounts.upsert(_account(_uuid1, 'mastodon',
          tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 1, 1), config: _mastodonConfig));
      await x.secrets.write(_uuid1, {'access_token': 'fake-old-revoked'});
      await x.accounts.upsert(_account('x-1', 'x'));
      await x.engine.sync();
      await y.accounts.upsert(_account(_uuid2, 'mastodon',
          tier: PlatformTier.openApi, handle: 'me@mastodon.example', createdAt: DateTime.utc(2026, 10, 15), config: _mastodonConfig));
      await y.secrets.write(_uuid2, {'access_token': 'fake-new-working'});
      await y.posts.upsert(_post('p-y', targets: const [PostTarget(accountId: _uuid2)]));
      crashing.crashNext = true;
      await expectLater(y.engine.sync(), throwsA(isA<_Killed>()));
      y.restart();
      await _rounds([y, x, y, x], clock, 1);
      expect(await y.ids('mastodon'), [_uuid1]);
      expect(await y.secrets.read(_uuid2), isNull);
      expect((await x.secrets.read(_uuid1))?['access_token'], 'fake-new-working');
      expect((await x.posts.get('p-y'))?.targets.single.accountId, _uuid1);
    });

    test('three devices through a cloud folder: the kept id and keys never flip', () async {
      final folder = _CloudFolder();
      final x = _Device('X', folder, clock), y = _Device('Y', folder, clock), z = _Device('Z', folder, clock);
      await x.accounts.upsert(_account('x-1', 'x'));
      await x.engine.sync();
      await y.accounts.upsert(_account(_uuid3, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 10, 2), config: _mastodonConfig));
      await y.secrets.write(_uuid3, {'access_token': 'fake-y'});
      await z.accounts.upsert(_account(_uuid1, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 10, 9), config: _mastodonConfig));
      await z.secrets.write(_uuid1, {'access_token': 'fake-z'});
      folder.freeze();
      await y.engine.sync();
      await z.engine.sync();
      folder.thaw();
      final seen = <String>{};
      for (var i = 0; i < 5; i++) {
        for (final d in [z, y, x]) {
          clock.now = clock.now.add(const Duration(minutes: 1));
          await d.engine.sync();
          if (i > 0) seen.add('${(await d.ids('mastodon')).join(',')}:${(await d.secrets.read(_uuid1))?['access_token']}');
        }
      }
      expect(seen, {'$_uuid1:fake-z'}, reason: 'the smaller id, with the newer sign-in, everywhere and for good');
    });

    test('a draft saved under the old id after a merge on a joined device still finds its account', () async {
      await a.accounts.upsert(_account('x-1', 'x'));
      await a.engine.sync();
      await b.engine.sync(); // both joined
      await b.accounts.upsert(_account(_uuid2, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 10, 18), config: _mastodonConfig));
      await b.secrets.write(_uuid2, {'access_token': 'fake-b'});
      await b.engine.sync();
      await a.accounts.upsert(_account(_uuid1, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 10, 19), config: _mastodonConfig));
      await a.secrets.write(_uuid1, {'access_token': 'fake-a'});
      final draft = _post('draft', targets: const [PostTarget(accountId: _uuid1)], updatedAt: DateTime.utc(2026, 10, 20, 11));
      await a.posts.upsert(draft);
      clock.now = clock.now.add(const Duration(minutes: 5));
      await a.engine.sync(); // merges _uuid1 into the file's _uuid2
      expect(await a.ids('mastodon'), [_uuid2]);
      // The composer, still holding the old draft, saves it.
      await a.posts.upsert(_post('draft', text: 'edited', targets: const [PostTarget(accountId: _uuid1)], updatedAt: clock.now.add(const Duration(minutes: 1))));
      await _rounds([a, b, a, b], clock, 1);
      for (final d in [a, b]) {
        final target = (await d.posts.get('draft'))!.targets.single.accountId;
        expect(target, _uuid2, reason: d.id);
        expect((await d.posts.get('draft'))!.text, 'edited');
      }
    });

    test('a merged copy that already was in the file leaves a tombstone naming the kept account; a remapped post keeps its time', () async {
      final folder = _CloudFolder();
      final x = _Device('X', folder, clock), y = _Device('Y', folder, clock), z = _Device('Z', folder, clock);
      await x.accounts.upsert(_account('x-1', 'x'));
      await x.engine.sync();
      await y.accounts.upsert(_account(_uuid2, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig));
      await z.accounts.upsert(_account(_uuid3, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig));
      final postTime = DateTime.utc(2026, 10, 19, 8);
      await z.posts.upsert(_post('pz', targets: const [PostTarget(accountId: _uuid3)], updatedAt: postTime));
      folder.freeze();
      await y.engine.sync();
      await z.engine.sync();
      folder.thaw();
      await x.engine.sync(); // absorbs the conflicted copy and merges
      final doc = SyncDocument.parse(await BackupCipher(_pass, params: _fast, minimum: _fast).open((await folder.read())!.bytes));
      expect(doc.records['account:$_uuid3']?.deleted, isTrue);
      expect(doc.records['account:$_uuid3']?.mergedInto, _uuid2);
      expect(doc.records['post:pz']?.at, postTime, reason: 'the remap keeps the post\'s own time, which decides its conflicts');
      expect([for (final t in (doc.records['post:pz']?.value as Map)['targets'] as List) (t as Map)['accountId']], [_uuid2]);
    });

    test("between two copies already in the file, the account's own id is kept over a made-up one", () async {
      await a.engine.sync();
      const natural = 'mastodon:42@mastodon.example';
      for (final id in [natural, _uuid1]) {
        await putInFile('account:$id', SyncRecord.of(_account(id, 'mastodon', tier: PlatformTier.openApi, config: _mastodonConfig).toJson(), at: clock.now, by: 'other'));
      }
      await a.engine.sync();
      expect(await a.ids('mastodon'), [natural]);
      final doc = await file();
      expect(doc.records['account:$_uuid1']?.mergedInto, natural);
    });
  });

  group('merges in a mixed-version file, conflicted copies, dry run counts (1.3.5)', () {
    final cipher = BackupCipher(_pass, params: _fast, minimum: _fast);

    /// What NEFORUM 1.3.4 does to the file on any write (its heartbeat writes
    /// every 15 minutes), from origin/main's sync_document.dart: every record
    /// goes through its SyncRecord.tryParse and toJson. A live record keeps
    /// {v, at, by}, of whatever kind; a tombstone keeps {deleted, at, by}
    /// only; a record it cannot read is dropped.
    Future<void> olderDeviceRewrites(SyncBackend store) async {
      final blob = (await store.read())!;
      final j = await cipher.open(blob.bytes);
      final records = (j['records'] as Map).cast<String, Object?>();
      for (final e in records.entries.toList()) {
        final r = e.value;
        if (r is! Map || DateTime.tryParse('${r['at'] ?? ''}') == null || r['by'] is! String) {
          records.remove(e.key);
        } else if (r['deleted'] == true) {
          records[e.key] = {'deleted': true, 'at': r['at'], 'by': r['by']};
        } else if (r.containsKey('v')) {
          records[e.key] = {'v': r['v'], 'at': r['at'], 'by': r['by']};
        } else {
          records.remove(e.key);
        }
      }
      await store.write(await cipher.seal(j), ifMatch: blob.version);
    }

    /// X joined; Y and Z join at once through a cloud folder with one
    /// Mastodon account; Z's post pz names Z's copy. X absorbs and merges.
    Future<({_CloudFolder folder, _Device x, _Device y, _Device z, Post pz})> twinsInFile() async {
      final folder = _CloudFolder();
      final x = _Device('X', folder, clock), y = _Device('Y', folder, clock), z = _Device('Z', folder, clock);
      await x.accounts.upsert(_account('x-1', 'x'));
      await x.engine.sync();
      await y.accounts.upsert(_account(_uuid2, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 10, 2), config: _mastodonConfig));
      await y.secrets.write(_uuid2, {'access_token': 'fake-y'});
      await z.accounts.upsert(_account(_uuid3, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 10, 3), config: _mastodonConfig));
      await z.secrets.write(_uuid3, {'access_token': 'fake-z'});
      final pz = _post('pz', targets: const [PostTarget(accountId: _uuid3)], updatedAt: DateTime.utc(2026, 10, 19, 8));
      await z.posts.upsert(pz);
      folder.freeze();
      await y.engine.sync();
      await z.engine.sync();
      folder.thaw();
      await _rounds([x, y, z, x], clock, 1);
      return (folder: folder, x: x, y: y, z: z, pz: pz);
    }

    Future<void> saveLate(_Device d, Post p) =>
        d.posts.upsert(Post.fromJson({...p.toJson(), 'text': 'edited later', 'updatedAt': clock.now.add(const Duration(minutes: 1)).toIso8601String()}));

    test('a merge link survives a NEFORUM 1.3.4 device writing the file; a draft saved later still finds its account', () async {
      final t = await twinsInFile();
      expect((await t.folder.read()) != null, isTrue);
      await olderDeviceRewrites(t.folder);
      final doc = SyncDocument.parse(await cipher.open((await t.folder.read())!.bytes));
      expect(doc.records['account:$_uuid3']?.mergedInto, isNull, reason: '1.3.4 writes the tombstone back without the link');
      expect(doc.records['alias:$_uuid3']?.value, {'into': _uuid2}, reason: 'the link of its own, a kind 1.3.4 leaves as it is');
      await saveLate(t.z, t.pz);
      await _rounds([t.z, t.x, t.y], clock, 3);
      for (final d in [t.x, t.y, t.z]) {
        expect((await d.posts.get('pz'))!.targets.single.accountId, _uuid2, reason: d.id);
      }
    });

    test('every device that saw the merge keeps the link, even when the file loses it', () async {
      final t = await twinsInFile();
      // Worst case: the file loses every trace of the link.
      final blob = (await t.folder.read())!;
      final j = await cipher.open(blob.bytes);
      final records = (j['records'] as Map).cast<String, Object?>()
        ..remove('alias:$_uuid3')
        ..['account:$_uuid3'] = {'deleted': true, 'at': clock.now.toUtc().toIso8601String(), 'by': 'old'};
      j['records'] = records;
      await t.folder.write(await cipher.seal(j), ifMatch: blob.version);
      await saveLate(t.z, t.pz);
      await _rounds([t.z, t.x, t.y], clock, 2);
      for (final d in [t.x, t.y, t.z]) {
        expect((await d.posts.get('pz'))!.targets.single.accountId, _uuid2, reason: d.id);
      }
    });

    test('links: a chain is followed, a cycle, a self-link or a link to a deleted account changes nothing, and nothing churns', () async {
      await a.accounts.upsert(_account('x-1', 'x'));
      await a.engine.sync();
      final at = clock.now;
      final doc = await file();
      doc.records['account:$_uuid3'] = SyncRecord.of(_account(_uuid3, 'mastodon', tier: PlatformTier.openApi, config: _mastodonConfig).toJson(), at: at, by: 'o');
      doc.records['account:$_uuid1'] = SyncRecord.tombstone(at: at, by: 'o', mergedInto: _uuid2);
      doc.records['alias:$_uuid2'] = SyncRecord.of({'into': _uuid3}, at: at, by: 'o'); // chain via both kinds of link
      doc.records['alias:c1'] = SyncRecord.of({'into': 'c2'}, at: at, by: 'o');
      doc.records['alias:c2'] = SyncRecord.of({'into': 'c1'}, at: at, by: 'o');
      doc.records['alias:self'] = SyncRecord.of({'into': 'self'}, at: at, by: 'o');
      doc.records['alias:gone-1'] = SyncRecord.of({'into': 'gone-2'}, at: at, by: 'o');
      doc.records['account:gone-2'] = SyncRecord.tombstone(at: at, by: 'o');
      for (final p in {'chain': [_uuid1], 'both': [_uuid1, _uuid2, _uuid3], 'cycle': ['c1'], 'self': ['self'], 'gone': ['gone-1']}.entries) {
        doc.records['post:${p.key}'] = SyncRecord.of(_post(p.key, targets: [for (final id in p.value) PostTarget(accountId: id)]).toJson(), at: at, by: 'o');
      }
      await backend.write(await cipher.seal(doc.toJson(writtenBy: 'o', writtenAt: at)), ifMatch: (await backend.read())!.version);
      await a.engine.sync();
      final writes = backend.writes;
      await _rounds([a], clock, 3);
      Future<List<String>> targets(String id) async => [for (final t in (await a.posts.get(id))!.targets) t.accountId];
      expect(await targets('chain'), [_uuid3]);
      expect(await targets('both'), [_uuid3]);
      expect(await targets('cycle'), ['c1']);
      expect(await targets('self'), ['self']);
      expect(await targets('gone'), ['gone-1'], reason: 'a link to an account deleted since moves nothing');
      expect(backend.writes, writes, reason: 'no churn');
    });

    test('a link never moves a post away from an account that lives again, and links on this device expire after 90 days', () async {
      await a.accounts.upsert(_account(_uuid1, 'mastodon', tier: PlatformTier.openApi, config: _mastodonConfig));
      await a.accounts.upsert(_account(_uuid2, 'tiktok', config: const {'clientKey': 'k', 'openId': 'o'}));
      await a.posts.upsert(_post('live', targets: const [PostTarget(accountId: _uuid1)]));
      await a.posts.upsert(_post('old', targets: const [PostTarget(accountId: 'merged-long-ago')]));
      await a.engine.sync();
      a.stateStore.data = {
        ...a.stateStore.data!,
        'aliases': {
          _uuid1: {'into': _uuid2, 'at': clock.now.toUtc().toIso8601String()}, // a stale link: _uuid1 lives
          'merged-long-ago': {'into': _uuid2, 'at': clock.now.subtract(const Duration(days: 91)).toUtc().toIso8601String()},
        },
      };
      await _rounds([a], clock, 2);
      expect((await a.posts.get('live'))!.targets.single.accountId, _uuid1);
      expect((await a.posts.get('old'))!.targets.single.accountId, 'merged-long-ago', reason: 'the link expired with the tombstones');
      expect((a.stateStore.data!['aliases'] as Map).containsKey('merged-long-ago'), isFalse);
    });

    test('a post that went to both copies keeps the target that went live, with every live id', () async {
      final t = await twinsInFile();
      final published = {
        'accountId': _uuid3,
        'status': 'published',
        'result': PublishResult.ok(remoteId: '111', remoteUrl: 'https://mastodon.example/@me/111').toJson(),
      };
      final failed = {'accountId': _uuid2, 'status': 'failed', 'attempts': 3};
      final doc = SyncDocument.parse(await cipher.open((await t.folder.read())!.bytes));
      final post = Post.fromJson({..._post('both').toJson(), 'status': 'partial', 'targets': [failed, published]});
      doc.records['post:both'] = SyncRecord.of(post.toJson(), at: clock.now, by: 'O');
      await t.folder.write(await cipher.seal(doc.toJson(writtenBy: 'O', writtenAt: clock.now)), ifMatch: (await t.folder.read())!.version);
      clock.now = clock.now.add(const Duration(minutes: 1));
      await t.x.engine.sync();
      final target = (await t.x.posts.get('both'))!.targets.single;
      expect(target.accountId, _uuid2);
      expect(target.status, TargetStatus.published, reason: 'a retry would post it twice');
      expect(target.result?.remoteUrl, 'https://mastodon.example/@me/111');
    });

    test('two targets for one account become one: the furthest status, the live ids of both', () {
      Map<String, Object?> target(String status, [List<String> ids = const []]) => {
            'accountId': 'a',
            'status': status,
            if (ids.isNotEmpty) 'result': PublishResult.ok(remoteId: ids.first, additionalRemoteIds: ids.sublist(1)).toJson(),
          };
      expect(PostsSyncSource.mergeTargets(target('failed'), target('published', ['1']))['status'], 'published');
      expect(PostsSyncSource.mergeTargets(target('heldByPlatform', ['1']), target('publishing'))['status'], 'heldByPlatform');
      expect(PostsSyncSource.mergeTargets(target('publishing'), target('pending'))['status'], 'publishing');
      expect(PostsSyncSource.mergeTargets(target('failed'), target('pending'))['status'], 'pending');
      final both = PostsSyncSource.mergeTargets(target('published', ['1', '2']), target('published', ['3']));
      expect(PublishResult.fromJson((both['result']! as Map).cast<String, dynamic>()).allRemoteIds, ['1', '2', '3'], reason: 'never lose a live post\'s ids');
    });

    test('a conflicted copy: the user switching an account off survives a renewal made at the same moment, and the newer keys stay', () async {
      final folder = _CloudFolder();
      final x = _Device('X', folder, clock), y = _Device('Y', folder, clock);
      final tk = _account(_uuid1, 'tiktok', handle: '@me', config: const {'clientKey': 'app', 'openId': 'o1'});
      await x.accounts.upsert(tk);
      await x.secrets.write(_uuid1, {'access_token': 'fake-a', 'expires_at': '2026-10-21T12:00:00.000Z'});
      await x.engine.sync();
      await y.engine.sync();
      folder.freeze();
      await x.secrets.write(_uuid1, {'access_token': 'fake-b', 'expires_at': '2026-10-22T12:00:00.000Z'}); // X renews
      await x.engine.sync();
      clock.now = clock.now.add(const Duration(minutes: 1));
      await y.accounts.upsert(tk.copyWith(enabled: false, displayName: 'Renamed on Y')); // Y switches it off a minute later
      await y.engine.sync();
      folder.thaw();
      await _rounds([x, y, x, y], clock, 1);
      for (final d in [x, y]) {
        final acc = (await d.accounts.get(_uuid1))!;
        expect([acc.enabled, acc.displayName], [false, 'Renamed on Y'], reason: '${d.id}: the later edit');
        expect((await d.secrets.read(_uuid1))?['access_token'], 'fake-b', reason: '${d.id}: the newer keys');
      }
    });

    test('a conflicted copy holding the newer sign-in brings in its keys and the app registration with them', () async {
      final folder = _CloudFolder();
      final x = _Device('X', folder, clock), y = _Device('Y', folder, clock);
      final tk = _account(_uuid1, 'tiktok', config: const {'clientKey': 'app', 'openId': 'o1', 'scopes': 'old'});
      await x.accounts.upsert(tk);
      await x.secrets.write(_uuid1, {'access_token': 'fake-a', 'expires_at': '2026-10-21T12:00:00.000Z'});
      await x.engine.sync();
      await y.engine.sync();
      folder.freeze();
      // X saves a draft and writes first (the main file); Y reconnects the
      // account a minute later (newer keys, a new app registration) and its
      // write becomes the conflicted copy.
      await x.posts.upsert(_post('px'));
      await x.engine.sync();
      clock.now = clock.now.add(const Duration(minutes: 1));
      await y.accounts.upsert(_account(_uuid1, 'tiktok', createdAt: DateTime.utc(2026, 10, 20), config: const {'clientKey': 'app', 'openId': 'o1', 'scopes': 'new'}));
      await y.secrets.write(_uuid1, {'access_token': 'fake-y-new', 'expires_at': '2026-10-25T12:00:00.000Z'});
      await y.engine.sync();
      folder.thaw();
      await _rounds([x, y, x, y], clock, 1);
      for (final d in [x, y]) {
        final acc = (await d.accounts.get(_uuid1))!;
        expect(acc.config['scopes'], 'new', reason: '${d.id}: the registration goes with the newer keys');
        expect((await d.secrets.read(_uuid1))?['access_token'], 'fake-y-new', reason: d.id);
        expect(await d.posts.get('px'), isNotNull);
      }
    });

    test('a conflicted copy with a later edit but the older sign-in: the edit is taken, the registration stays with the newer keys', () async {
      final folder = _CloudFolder();
      final x = _Device('X', folder, clock), y = _Device('Y', folder, clock);
      final tk = _account(_uuid1, 'tiktok', config: const {'clientKey': 'app', 'openId': 'o1', 'scopes': 'old'});
      await x.accounts.upsert(tk);
      await x.secrets.write(_uuid1, {'access_token': 'fake-a', 'expires_at': '2026-10-21T12:00:00.000Z'});
      await x.engine.sync();
      await y.engine.sync();
      folder.freeze();
      // Y reconnects (newer keys, a new registration) and writes first: the main file.
      await y.accounts.upsert(_account(_uuid1, 'tiktok', createdAt: DateTime.utc(2026, 10, 20), config: const {'clientKey': 'app', 'openId': 'o1', 'scopes': 'new'}));
      await y.secrets.write(_uuid1, {'access_token': 'fake-y-new', 'expires_at': '2026-10-25T12:00:00.000Z'});
      await y.engine.sync();
      // X switches the account off a minute later: the conflicted copy.
      clock.now = clock.now.add(const Duration(minutes: 1));
      await x.accounts.upsert(tk.copyWith(enabled: false));
      await x.engine.sync();
      folder.thaw();
      clock.now = clock.now.add(const Duration(minutes: 1));
      await y.engine.sync(); // Y reads both
      final onY = (await y.accounts.get(_uuid1))!;
      expect(onY.config['scopes'], 'new', reason: 'the registration of the newer sign-in');
      expect(onY.enabled, isFalse, reason: "X's later switch");
      expect((await y.secrets.read(_uuid1))?['access_token'], 'fake-y-new');
    });

    test('links in the file leave it with the tombstones, after 90 days', () async {
      await a.accounts.upsert(_account('x-1', 'x'));
      await a.engine.sync();
      await putInFile('alias:old', SyncRecord.of({'into': 'x-1'}, at: clock.now.subtract(const Duration(days: 91)), by: 'o'));
      await putInFile('alias:recent', SyncRecord.of({'into': 'x-1'}, at: clock.now.subtract(const Duration(days: 10)), by: 'o'));
      await a.engine.sync();
      final doc = await file();
      expect(doc.records.containsKey('alias:old'), isFalse);
      expect(doc.records.containsKey('alias:recent'), isTrue);
    });

    test('a record key without a colon, in the file and in a conflicted copy, stops nothing', () async {
      final folder = _CloudFolder();
      final d = _Device('D', folder, clock);
      final doc = SyncDocument()..records['future'] = SyncRecord.of('a', at: clock.now, by: 'N');
      folder.bytes = await cipher.seal(doc.toJson(writtenBy: 'N', writtenAt: clock.now));
      folder.version = 1;
      final copy = SyncDocument()..records['future'] = SyncRecord.of('b', at: clock.now.add(const Duration(seconds: 1)), by: 'M');
      folder.copies.add(SyncSideCopy('NEFORUM (conflicted copy).neforumsync', await cipher.seal(copy.toJson(writtenBy: 'M', writtenAt: clock.now))));
      await d.engine.sync();
      expect((SyncDocument.parse(await cipher.open((await folder.read())!.bytes))).records['future']?.value, 'b');
    });

    test('a hand-off held here in both copies (made here twice) is never merged, not even on a first sync', () async {
      await a.accounts.upsert(_account('instagram-handoff-$_uuid1', 'instagram', tier: PlatformTier.handoff, name: 'Instagram (hand-off)'));
      await a.engine.sync();
      // Turned off and on again (a fresh state: a first sync again), with a second hand-off of the same name made here.
      await a.accounts.upsert(_account('instagram-handoff-$_uuid2', 'instagram', tier: PlatformTier.handoff, name: 'Instagram (hand-off)'));
      a.stateStore.data = null;
      await a.engine.sync();
      expect(await a.ids('instagram'), hasLength(2));
    });

    group('the dry run counts what the sync then does, record kind by record kind', () {
      Future<void> expectMatches(_Device d) => _expectDryRunEqualsSync(d);

      test('a plain first sync', () async {
        await a.accounts.upsert(_account('x-1', 'x'));
        await a.secrets.write('x-1', {'k': 'fake'});
        await a.posts.upsert(_post('pa'));
        await a.engine.sync();
        await b.accounts.upsert(_account('bsky', 'bluesky'));
        await expectMatches(b);
      });

      test('a first sync merging an account connected on both', () async {
        await a.accounts.upsert(_account(_uuid1, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig));
        await a.secrets.write(_uuid1, {'k': 'fake-a'});
        await a.engine.sync();
        await b.accounts.upsert(_account(_uuid2, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 10, 9), config: _mastodonConfig));
        await b.secrets.write(_uuid2, {'k': 'fake-b'});
        await b.posts.upsert(_post('pb', targets: const [PostTarget(accountId: _uuid2)]));
        await expectMatches(b);
      });

      test('a fresh device and a file holding one account twice, with posts for both copies', () async {
        final folder = _CloudFolder();
        final x = _Device('X', folder, clock), y = _Device('Y', folder, clock), z = _Device('Z', folder, clock), fresh = _Device('F', folder, clock);
        await x.accounts.upsert(_account('x-1', 'x'));
        await x.engine.sync();
        await y.accounts.upsert(_account(_uuid2, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig));
        await y.posts.upsert(_post('py', targets: const [PostTarget(accountId: _uuid2)]));
        await z.accounts.upsert(_account(_uuid3, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig));
        await z.posts.upsert(_post('pz', targets: const [PostTarget(accountId: _uuid3)]));
        folder.freeze();
        await y.engine.sync();
        await z.engine.sync();
        folder.thaw();
        await expectMatches(fresh);
      });

      test('a fresh device and a post in the file still naming a merged copy', () async {
        final t = await twinsInFile();
        final doc = SyncDocument.parse(await cipher.open((await t.folder.read())!.bytes));
        doc.records['post:late'] = SyncRecord.of(_post('late', targets: const [PostTarget(accountId: _uuid3)]).toJson(), at: clock.now, by: 'W');
        await t.folder.write(await cipher.seal(doc.toJson(writtenBy: 'W', writtenAt: clock.now)), ifMatch: (await t.folder.read())!.version);
        await expectMatches(_Device('F', t.folder, clock));
      });

      test('a setting a merge rewrites (default targets naming a merged copy) is counted, from the device that wrote it', () async {
        await a.accounts.upsert(_account('x-1', 'x'));
        await a.engine.sync();
        final at = clock.now;
        await putInFile('account:$_uuid2', SyncRecord.of(_account(_uuid2, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig).toJson(), at: at, by: 'A'));
        await putInFile('account:$_uuid3', SyncRecord.tombstone(at: at, by: 'A', mergedInto: _uuid2));
        await putInFile('alias:$_uuid3', SyncRecord.of({'into': _uuid2}, at: at, by: 'A'));
        await putInFile('setting:defaultTargetIds', SyncRecord.of([_uuid3, 'x-1'], at: at, by: 'A'));
        final values = <String, Object?>{'defaultTargetIds': <Object?>[]};
        final settings = CallbackSyncSource(
          prefix: 'setting',
          snapshot: () async => {for (final e in values.entries) e.key: SyncItem(e.value)},
          apply: (k, v) async => values[k] = v,
          appliesDeletions: false,
          remapAccountIds: (key, value, ids) => value is List && value.any(ids.containsKey) ? [...{for (final id in value) ids[id] ?? id}] : value,
        );
        final f = _Device('F', backend, clock, extra: [settings]);
        final p = await _expectDryRunEqualsSync(f, extra: [settings]);
        expect(p.receivedOf('setting'), 1);
        expect(values['defaultTargetIds'], [_uuid2, 'x-1']);
        expect(p.fromDevices, ['A'], reason: 'the device that wrote the records that arrive');
      });

      test('an account arriving through a merge still names the device it came from', () async {
        final folder = _CloudFolder();
        final x = _Device('X', folder, clock), y = _Device('Y', folder, clock), z = _Device('Z', folder, clock);
        await x.accounts.upsert(_account('x-1', 'x'));
        await x.engine.sync();
        folder.freeze();
        await y.accounts.upsert(_account(_uuid2, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig));
        // Z's sign-in is newer: the merge rewrites the kept record with it.
        await z.accounts.upsert(_account(_uuid3, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', createdAt: DateTime.utc(2026, 10, 9), config: _mastodonConfig));
        await y.engine.sync();
        await z.engine.sync();
        folder.thaw();
        final p = await _expectDryRunEqualsSync(_Device('F', folder, clock));
        expect(p.received.keys, containsAll(['account:x-1', 'account:$_uuid2']));
        expect(p.fromDevices, containsAll(['X', 'Y']), reason: "the merged account is Y's record, rewritten by the merge");
      });

      test('a setting put back to its default (an explicit null) arrives as a change', () async {
        final aValues = <String, Object?>{'accent': 0xFF112233};
        CallbackSyncSource settings(Map<String, Object?> values) => CallbackSyncSource(
              prefix: 'setting',
              snapshot: () async => {for (final e in values.entries) e.key: SyncItem(e.value)},
              apply: (k, v) async => values[k] = v,
              appliesDeletions: false,
            );
        final aSource = settings(aValues);
        final x = _Device('X', backend, clock, extra: [aSource]);
        await x.engine.sync();
        final bValues = <String, Object?>{'accent': 0xFF112233};
        final bSource = settings(bValues);
        final y = _Device('Y', backend, clock, extra: [bSource]);
        await y.engine.sync();
        aValues['accent'] = null; // put back to its default on X
        await x.engine.sync();
        final p = await _expectDryRunEqualsSync(y, extra: [bSource]);
        expect(p.received, {'setting:accent': null});
        expect(bValues.containsKey('accent'), isTrue);
      });

      test('a conflicted copy with an edit and a renewal', () async {
        final folder = _CloudFolder();
        final x = _Device('X', folder, clock), y = _Device('Y', folder, clock);
        final tk = _account(_uuid1, 'tiktok', config: const {'clientKey': 'app', 'openId': 'o1'});
        await x.accounts.upsert(tk);
        await x.secrets.write(_uuid1, {'access_token': 'fake-a', 'expires_at': '2026-10-21T12:00:00.000Z'});
        await x.engine.sync();
        await y.engine.sync();
        folder.freeze();
        await x.secrets.write(_uuid1, {'access_token': 'fake-b', 'expires_at': '2026-10-22T12:00:00.000Z'});
        await x.engine.sync();
        clock.now = clock.now.add(const Duration(minutes: 1));
        await y.accounts.upsert(tk.copyWith(enabled: false));
        await y.engine.sync();
        folder.thaw();
        await _expectDryRunEqualsSync(x);
        await _expectDryRunEqualsSync(y);
      });

      test('a copy a 1.3.4 device brought back, merged again', () async {
        await a.accounts.upsert(_account('x-1', 'x'));
        await a.engine.sync();
        const mk = {'instance': 'https://mk.example'};
        final at = clock.now;
        await putInFile('account:$_uuid2', SyncRecord.of(_account(_uuid2, 'misskey', tier: PlatformTier.openApi, handle: '@me@mk.example', config: mk).toJson(), at: at, by: 'O'));
        await putInFile('alias:$_uuid3', SyncRecord.of({'into': _uuid2}, at: at, by: 'O'));
        await putInFile('account:$_uuid3', SyncRecord.of(_account(_uuid3, 'misskey', tier: PlatformTier.openApi, handle: '@me@mk.example', config: mk).toJson(), at: at, by: 'P134'));
        await _expectDryRunEqualsSync(a);
      });

      test("a first sync where this device's setup wins, with a hand-off twin and a post", () async {
        await a.accounts.upsert(_account('instagram-handoff-$_uuid1', 'instagram', tier: PlatformTier.handoff, name: 'Instagram (hand-off)'));
        await a.engine.sync();
        await b.accounts.upsert(_account('instagram-handoff-$_uuid2', 'instagram', tier: PlatformTier.handoff, name: 'Instagram (hand-off)'));
        await b.accounts.upsert(_account('x-2', 'x'));
        await b.posts.upsert(_post('pb', targets: [PostTarget(accountId: 'instagram-handoff-$_uuid2')]));
        await _expectDryRunEqualsSync(b);
      });

      test('a first sync combining both versions of a record', () async {
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
        await x.engine.sync();
        final ySource = hosts(yHosts);
        final y = _Device('Y', backend, clock, extra: [ySource]);
        final p = await _expectDryRunEqualsSync(y, extra: [ySource]);
        expect(p.received['mediaHosts:all'], {'main': 'x-main', 'fallback': 'y-fallback'});
      });

      test('an ordinary sync after joining, with edits and a deletion elsewhere', () async {
        await a.posts.upsert(_post('p1'));
        await a.posts.upsert(_post('p2'));
        await a.engine.sync();
        await b.engine.sync();
        await a.posts.upsert(_post('p1', text: 'edited', updatedAt: DateTime.utc(2026, 10, 20, 12, 30)));
        await a.posts.delete('p2');
        await a.accounts.upsert(_account('t-1', 'tumblr'));
        await a.engine.sync();
        await expectMatches(b);
      });
    });
  });

  group('an account and its keys come from one sign-in; targets keep every live part; links bring copies back (1.3.5)', () {
    ConnectedAccount tiktok({required String app, required DateTime createdAt, bool enabled = true}) => ConnectedAccount(
          id: _uuid1,
          platformId: 'tiktok',
          tier: PlatformTier.byokApi,
          displayName: 'Me on TikTok',
          handle: '@me',
          createdAt: createdAt,
          config: {'clientKey': app, 'openId': 'open-$app'},
          enabled: enabled,
        );
    Map<String, String> tiktokKeys(String app, DateTime expires) => {
          'access_token': 'act-$app-fake',
          'refresh_token': 'rft-$app-fake',
          'expires_at': expires.toUtc().toIso8601String(),
          'refresh_expires_at': '2027-10-20T12:00:00.000Z',
          'token_type': 'Bearer',
          'client_secret': 'cs-$app-fake',
        };

    /// TikTok's token endpoint: a renewal works only when the client key (on
    /// the account), the client secret and the refresh token (in the keys)
    /// all belong to one developer app.
    Future<String> renewal(ConnectedAccount account, Map<String, String> keys) async {
      final ctx = testContext(
        now: DateTime.utc(2026, 10, 25),
        handler: (r) async {
          final body = Uri.splitQueryString(r.body);
          final app = body['client_key'];
          final ok = body['client_secret'] == 'cs-$app-fake' && body['refresh_token'] == 'rft-$app-fake';
          return ok
              ? http.Response(jsonEncode({'access_token': 'act-x', 'expires_in': 86400, 'refresh_token': 'rft-x', 'refresh_expires_in': 31536000, 'open_id': 'o', 'token_type': 'Bearer'}), 200,
                  headers: jsonHeaders)
              : http.Response(jsonEncode({'error': 'invalid_client', 'error_description': 'Client key does not match', 'log_id': 'x'}), 400, headers: jsonHeaders);
        },
      );
      try {
        await TikTokAdapter().refreshSecrets(account, keys, ctx);
        return 'renewed';
      } on AdapterException catch (e) {
        return 'refused (${e.error.kind.name})';
      }
    }

    for (final variant in ['the edit after the reconnect', 'the edit before the reconnect', 'no edit', 'a conflicted copy']) {
      test('a reconnect with another TikTok app on X while Y switches the account off ($variant): the renewal works on both', () async {
        final store = variant == 'a conflicted copy' ? _CloudFolder() : MemorySyncBackend();
        final x = _Device('X', store, clock), y = _Device('Y', store, clock);
        final old = tiktok(app: 'ck-old', createdAt: DateTime.utc(2026, 10, 1));
        await x.accounts.upsert(old);
        await x.secrets.write(_uuid1, tiktokKeys('ck-old', DateTime.utc(2026, 10, 21)));
        await x.engine.sync();
        await y.engine.sync();
        if (store is _CloudFolder) store.freeze();
        if (variant.contains('before')) await y.accounts.upsert(old.copyWith(enabled: false));
        clock.now = clock.now.add(const Duration(minutes: 1));
        await x.accounts.upsert(tiktok(app: 'ck-new', createdAt: clock.now));
        await x.secrets.write(_uuid1, tiktokKeys('ck-new', DateTime.utc(2026, 10, 21, 13)));
        await x.engine.sync();
        clock.now = clock.now.add(const Duration(minutes: 1));
        if (variant.contains('after') || variant.contains('copy')) await y.accounts.upsert(old.copyWith(enabled: false));
        await y.engine.sync();
        if (store is _CloudFolder) store.thaw();
        await _rounds([x, y, x, y], clock, 1);
        for (final d in [x, y]) {
          final account = (await d.accounts.get(_uuid1))!;
          expect(await renewal(account, (await d.secrets.read(_uuid1))!), 'renewed', reason: '${d.id}: the account and its keys come from one sign-in');
          expect(account.configString('clientKey'), 'ck-new');
          expect(account.enabled, variant == 'no edit', reason: "${d.id}: Y's switch is kept");
        }
      });
    }

    test('this device reconnected with another TikTok app while the other switched the account off and synced first: the renewal works on both', () async {
      final x = _Device('X', backend, clock), y = _Device('Y', backend, clock);
      final old = tiktok(app: 'ck-old', createdAt: DateTime.utc(2026, 10, 1));
      await x.accounts.upsert(old);
      await x.secrets.write(_uuid1, tiktokKeys('ck-old', DateTime.utc(2026, 10, 21)));
      await x.engine.sync();
      await y.engine.sync();
      clock.now = clock.now.add(const Duration(minutes: 1));
      await y.accounts.upsert(old.copyWith(enabled: false));
      await y.engine.sync(); // Y's switch reaches the file first
      clock.now = clock.now.add(const Duration(minutes: 1));
      await x.accounts.upsert(tiktok(app: 'ck-new', createdAt: clock.now)); // X reconnects, not synced yet
      await x.secrets.write(_uuid1, tiktokKeys('ck-new', DateTime.utc(2026, 10, 21, 13)));
      await _rounds([x, y, x, y], clock, 1);
      for (final d in [x, y]) {
        final account = (await d.accounts.get(_uuid1))!;
        expect(account.configString('clientKey'), 'ck-new', reason: "${d.id}: this device's newer sign-in brings its registration");
        expect(await renewal(account, (await d.secrets.read(_uuid1))!), 'renewed', reason: d.id);
      }
    });

    // Only the keys changed on both sides: Y renews the old sign-in (keys
    // that expire later than X's) while X reconnects with another app. The
    // account record changed on X alone, so it simply comes from X; the keys
    // must come with it, by the connection, not by the expiry.
    for (final variant in ['the renewal in flight while X reconnects', 'Y renews while the file is out of reach', 'a conflicted copy']) {
      test('Y renews the old sign-in while X reconnects with another TikTok app ($variant): one sign-in on both, and it renews', () async {
        final folder = variant == 'a conflicted copy' ? _CloudFolder() : null;
        final flaky = _FlakyBackend(backend)..failures = 0;
        final SyncBackend store = folder ?? flaky;
        final x = _Device('X', store, clock), y = _Device('Y', store, clock);
        await x.accounts.upsert(tiktok(app: 'ck-old', createdAt: DateTime.utc(2026, 10, 1)));
        await x.secrets.write(_uuid1, tiktokKeys('ck-old', clock.now.add(const Duration(minutes: 30))));
        await x.engine.sync();
        await y.engine.sync();

        Future<void> xReconnects() async {
          await x.accounts.upsert(tiktok(app: 'ck-new', createdAt: clock.now));
          await x.secrets.write(_uuid1, tiktokKeys('ck-new', clock.now.add(const Duration(hours: 24))));
          await x.engine.sync();
        }

        // Y renews through the engine's renew(), the path the publish service
        // takes for rotating keys (X, Tumblr, DeviantArt), and stores whatever
        // comes back, as the publish service does. TikTok itself does not
        // rotate and renews without renew(): that path is the publish-service
        // test further down. The network answers with keys of the old app
        // that expire after X's.
        Future<void> yRenews({Future<void> Function()? meanwhile}) async {
          final fresh = await y.engine.renew((await y.accounts.get(_uuid1))!, (await y.secrets.read(_uuid1))!, (current) async {
            await meanwhile?.call();
            clock.now = clock.now.add(const Duration(seconds: 2));
            return tiktokKeys('ck-old', clock.now.add(const Duration(hours: 24)));
          });
          if (fresh != null) await y.secrets.write(_uuid1, fresh);
        }

        clock.now = clock.now.add(const Duration(minutes: 31)); // Y's keys have expired
        if (variant.contains('in flight')) {
          await yRenews(meanwhile: xReconnects);
        } else if (folder != null) {
          folder.freeze();
          await xReconnects();
          clock.now = clock.now.add(const Duration(minutes: 1));
          await yRenews();
          folder.thaw();
          expect(folder.copies, isNotEmpty, reason: "Y's writes became conflicted copies");
        } else {
          await xReconnects();
          clock.now = clock.now.add(const Duration(minutes: 1));
          flaky.down = true;
          await yRenews();
          flaky.down = false;
          expect((await y.secrets.read(_uuid1))!['client_secret'], 'cs-ck-old-fake', reason: 'Y renewed alone');
        }
        await _rounds([y, x, y, x], clock, 1);
        for (final d in [x, y]) {
          final account = (await d.accounts.get(_uuid1))!;
          final keys = (await d.secrets.read(_uuid1))!;
          expect(account.configString('clientKey'), 'ck-new', reason: '${d.id}: the reconnect is the newer sign-in');
          expect(keys['client_secret'], 'cs-ck-new-fake', reason: "${d.id}: the account's keys come with it");
          expect(await renewal(account, keys), 'renewed', reason: '${d.id}: an account and its keys always from one sign-in');
        }
      });
    }

    test('Y renews while X reconnects through the same TikTok app: the keys renewed last win, and they fit the account', () async {
      final x = _Device('X', backend, clock), y = _Device('Y', backend, clock);
      await x.accounts.upsert(tiktok(app: 'ck-old', createdAt: DateTime.utc(2026, 10, 1)));
      await x.secrets.write(_uuid1, tiktokKeys('ck-old', clock.now.add(const Duration(minutes: 30))));
      await x.engine.sync();
      await y.engine.sync();
      clock.now = clock.now.add(const Duration(minutes: 31));
      await x.accounts.upsert(tiktok(app: 'ck-old', createdAt: clock.now));
      await x.secrets.write(_uuid1, tiktokKeys('ck-old', clock.now.add(const Duration(hours: 24))));
      await x.engine.sync();
      clock.now = clock.now.add(const Duration(minutes: 1));
      final renewed = tiktokKeys('ck-old', clock.now.add(const Duration(hours: 24)));
      await y.secrets.write(_uuid1, renewed); // Y renewed the first sign-in a minute later
      await _rounds([y, x, y, x], clock, 1);
      for (final d in [x, y]) {
        final account = (await d.accounts.get(_uuid1))!;
        final keys = (await d.secrets.read(_uuid1))!;
        expect(keys['expires_at'], renewed['expires_at'], reason: '${d.id}: through one app, the renewal that worked last');
        expect(await renewal(account, keys), 'renewed', reason: d.id);
      }
    });

    test('a renewal of the old sign-in with an edit on Y, against a reconnect on X (expiry and connection time disagree): the connection decides', () async {
      final x = _Device('X', backend, clock), y = _Device('Y', backend, clock);
      final old = tiktok(app: 'ck-old', createdAt: DateTime.utc(2026, 10, 1));
      await x.accounts.upsert(old);
      await x.secrets.write(_uuid1, tiktokKeys('ck-old', clock.now.add(const Duration(minutes: 30))));
      await x.engine.sync();
      await y.engine.sync();
      clock.now = clock.now.add(const Duration(minutes: 31));
      await x.accounts.upsert(tiktok(app: 'ck-new', createdAt: clock.now));
      await x.secrets.write(_uuid1, tiktokKeys('ck-new', clock.now.add(const Duration(hours: 24))));
      await x.engine.sync();
      // Y, not synced yet, renews the old sign-in (its keys expire after X's)
      // and renames the account: both of Y's records conflict with X's.
      clock.now = clock.now.add(const Duration(minutes: 1));
      await y.secrets.write(_uuid1, tiktokKeys('ck-old', clock.now.add(const Duration(hours: 24))));
      await y.accounts.upsert(old.copyWith(displayName: 'Renamed on Y'));
      await _rounds([y, x, y, x], clock, 1);
      for (final d in [x, y]) {
        final account = (await d.accounts.get(_uuid1))!;
        final keys = (await d.secrets.read(_uuid1))!;
        expect(account.configString('clientKey'), 'ck-new', reason: '${d.id}: the later connection, not the later expiry');
        expect(keys['client_secret'], 'cs-ck-new-fake', reason: d.id);
        expect(await renewal(account, keys), 'renewed', reason: d.id);
        expect(account.displayName, 'Renamed on Y', reason: "${d.id}: the user's own edit is kept (Y synced second)");
      }
    });

    test('one connection changed on both devices: the sign-in comes from the keys renewed last, the edit from the device that syncs second', () async {
      final x = _Device('X', backend, clock), y = _Device('Y', backend, clock);
      final acc = tiktok(app: 'ck-old', createdAt: DateTime.utc(2026, 10, 1));
      await x.accounts.upsert(acc);
      await x.secrets.write(_uuid1, tiktokKeys('ck-old', clock.now.add(const Duration(minutes: 30))));
      await x.engine.sync();
      await y.engine.sync();
      // Y renews the same connection, and the renewal brings a wider grant
      // onto the account (a sign-in field); Y syncs first.
      clock.now = clock.now.add(const Duration(minutes: 31));
      await y.secrets.write(_uuid1, tiktokKeys('ck-old', clock.now.add(const Duration(hours: 24))));
      await y.accounts.upsert(acc.copyWith(config: {...acc.config, 'scopes': 'video.publish'}));
      await y.engine.sync();
      // X, not synced since, renames the account, then syncs: the two
      // accounts are one connection (same createdAt), so the keys decide.
      clock.now = clock.now.add(const Duration(minutes: 1));
      await x.accounts.upsert(acc.copyWith(displayName: 'Renamed on X'));
      await _rounds([x, y, x, y], clock, 1);
      for (final d in [x, y]) {
        final account = (await d.accounts.get(_uuid1))!;
        expect(account.configString('scopes'), 'video.publish', reason: "${d.id}: the sign-in fields of the keys renewed last (Y's)");
        expect(account.displayName, 'Renamed on X', reason: "${d.id}: X's edit (X synced second)");
        expect(await renewal(account, (await d.secrets.read(_uuid1))!), 'renewed', reason: d.id);
      }
    });

    // The publish service, the other writer of accounts and keys: a sync can
    // land while it waits on the network (an upload, a token call).
    http.Response tokenAnswer(http.Request r) {
      final body = Uri.splitQueryString(r.body);
      final app = body['client_key'];
      final ok = body['client_secret'] == 'cs-$app-fake' && body['refresh_token'] == 'rft-$app-fake';
      return ok
          ? http.Response(
              jsonEncode({'access_token': 'act-$app-fake', 'expires_in': 86400, 'refresh_token': 'rft-$app-fake', 'refresh_expires_in': 31536000, 'open_id': 'open-$app', 'token_type': 'Bearer'}),
              200,
              headers: jsonHeaders)
          : http.Response(jsonEncode({'error': 'invalid_client', 'error_description': 'Client key does not match', 'log_id': 'x'}), 400, headers: jsonHeaders);
    }

    PublishService publisher(_Device d, PlatformAdapter adapter, Future<http.Response> Function(http.Request) handler) => PublishService(
          registry: AdapterRegistry([adapter]),
          accounts: d.accounts,
          posts: d.posts,
          secrets: d.secrets,
          quota: QuotaTracker(InMemoryQuotaRepository()),
          http: NeforumHttp(client: MockClient(handler), maxRetries: 0),
          clock: () => clock.now,
        );

    Future<(_Device, _Device)> joinedOnTikTok() async {
      final x = _Device('X', backend, clock), y = _Device('Y', backend, clock);
      await x.accounts.upsert(tiktok(app: 'ck-old', createdAt: DateTime.utc(2026, 10, 1)));
      await x.secrets.write(_uuid1, tiktokKeys('ck-old', clock.now.add(const Duration(minutes: 30))));
      await x.engine.sync();
      await y.engine.sync();
      return (x, y);
    }

    Future<void> xReconnectsAndBothSync(_Device x, _Device y) async {
      await x.accounts.upsert(tiktok(app: 'ck-new', createdAt: clock.now));
      await x.secrets.write(_uuid1, tiktokKeys('ck-new', clock.now.add(const Duration(hours: 24))));
      await x.engine.sync();
      await y.engine.sync();
    }

    Future<void> expectOneSignIn(List<_Device> devices, {String app = 'ck-new'}) async {
      for (final d in devices) {
        final account = (await d.accounts.get(_uuid1))!;
        final keys = (await d.secrets.read(_uuid1))!;
        expect(account.configString('clientKey'), app, reason: '${d.id}: the reconnect stays');
        expect(keys['client_secret'], 'cs-$app-fake', reason: "${d.id}: the account's keys come with it");
        expect(await renewal(account, keys), 'renewed', reason: '${d.id}: an account and its keys always from one sign-in');
      }
    }

    test('the publish service renews TikTok (no coordinator) while a sync brings a reconnect through another app: the reconnect is kept, not the renewal', () async {
      final (x, y) = await joinedOnTikTok();
      clock.now = clock.now.add(const Duration(minutes: 31)); // Y's keys have expired
      await y.posts.upsert(_post('p', targets: const [PostTarget(accountId: _uuid1)]));
      var tokenCalls = 0;
      final used = <Map<String, String>>[];
      final service = publisher(y, _TikTokPublishing(() async => PublishResult.ok(remoteId: 'v1'), used: used), (r) async {
        if (r.url.path.contains('/oauth/token/')) {
          tokenCalls++;
          // While TikTok answers, X reconnects and syncs, and Y's timer sync runs.
          await xReconnectsAndBothSync(x, y);
          clock.now = clock.now.add(const Duration(seconds: 2));
          return tokenAnswer(r);
        }
        return http.Response('{}', 200, headers: jsonHeaders);
      });
      await service.publish('p');
      expect(tokenCalls, 1, reason: 'the renewal ran, on the path TikTok takes');
      expect((await y.secrets.read(_uuid1))!['client_secret'], 'cs-ck-new-fake', reason: 'the renewal of the old sign-in was dropped');
      expect(used.single['client_secret'], 'cs-ck-new-fake', reason: 'the upload runs with the keys that are stored, not the ones it started from');
      await _rounds([y, x, y, x], clock, 1);
      await expectOneSignIn([x, y]);
    });

    test('a renewal carries when it happened and where its dates came from, in the keys record; the registration stays one', () async {
      final (x, y) = await joinedOnTikTok();
      final before = (await x.accounts.get(_uuid1))!.toJson();
      clock.now = clock.now.add(const Duration(minutes: 31));
      await y.posts.upsert(_post('p', targets: const [PostTarget(accountId: _uuid1)]));
      final service = publisher(y, _TikTokPublishing(() async => PublishResult.ok(remoteId: 'v1')), (r) async => r.url.path.contains('/oauth/token/') ? tokenAnswer(r) : http.Response('{}', 200, headers: jsonHeaders));
      await service.publish('p');
      final renewedAt = clock.now.toUtc().toIso8601String();
      await y.engine.sync();
      await x.engine.sync();
      for (final d in [x, y]) {
        final keys = (await d.secrets.read(_uuid1))!;
        expect(keys[StoredSecretKeys.lastRenewedAt], renewedAt, reason: d.id);
        expect(keys[StoredSecretKeys.expiresAtSource], 'serverReported', reason: d.id);
        expect(keys[StoredSecretKeys.refreshExpiresSource], 'serverReported', reason: d.id);
        expect(DateTime.parse(keys[OAuthTokens.keyExpiresAt]!).isAfter(clock.now), isTrue, reason: '${d.id}: the renewed date came along');
      }
      final after = (await x.accounts.get(_uuid1))!.toJson();
      expect(after['config'], before['config'], reason: 'nothing in config');
      expect(sharesRegistration(before, after), isTrue, reason: 'a renewal never makes it another registration');
    });

    for (final outcome in ['a success clears an old warning', 'an auth failure saves a warning']) {
      test('the publish service changes only the warning, on the account as stored now ($outcome): a reconnect that arrived by sync mid-upload stays', () async {
        final (x, y) = await joinedOnTikTok();
        clock.now = clock.now.add(const Duration(minutes: 5)); // Y's keys are still valid
        final success = outcome.contains('success');
        if (success) {
          await y.accounts.upsert(tiktok(app: 'ck-old', createdAt: DateTime.utc(2026, 10, 1)).copyWith(lastError: 'TikTok sign-in expired; reconnect the account'));
        }
        await y.posts.upsert(_post('p', targets: const [PostTarget(accountId: _uuid1)]));
        final service = publisher(y, _TikTokPublishing(() async {
          // The upload takes a while: the sync a post change schedules brings
          // X's reconnect in meanwhile.
          await xReconnectsAndBothSync(x, y);
          return success ? PublishResult.ok(remoteId: 'v1') : PublishResult.failure(const PublishError.auth('access_token_invalid'));
        }), (r) async => tokenAnswer(r));
        await service.publish('p');
        await Future<void>.delayed(const Duration(milliseconds: 20)); // the warning is saved without waiting
        final warning = (await y.accounts.get(_uuid1))!.lastError;
        expect(warning, success ? isNull : isNotNull, reason: 'the warning itself still changes');
        await _rounds([y, x, y, x], clock, 1);
        await expectOneSignIn([x, y]);
        expect((await x.accounts.get(_uuid1))!.lastError, isNull, reason: "a warning is this device's own");
      });
    }

    for (final reverse in [false, true]) {
      test(
          reverse
              ? "real folders and a cloud client: X's reconnect is the conflicted copy (Y's renewal reached the cloud first), and still wins"
              : "real folders and a cloud client: Y's renewal of the old sign-in is the conflicted copy, and the reconnect wins",
          () async {
        final root = await Directory.systemTemp.createTemp('neforum-cloud');
        addTearDown(() => root.delete(recursive: true));
        final cloud = _CloudClient(root);
        final x = _Device('X', cloud.folder('X'), clock), y = _Device('Y', cloud.folder('Y'), clock);
        Future<void> run(_Device d) async {
          await cloud.sync(d.id);
          clock.now = clock.now.add(const Duration(minutes: 1));
          await d.engine.sync();
          await cloud.sync(d.id);
        }

        await x.accounts.upsert(tiktok(app: 'ck-old', createdAt: DateTime.utc(2026, 10, 1)));
        await x.secrets.write(_uuid1, tiktokKeys('ck-old', clock.now.add(const Duration(minutes: 30))));
        await run(x);
        await run(y);
        await run(x);
        clock.now = clock.now.add(const Duration(minutes: 31));
        await x.accounts.upsert(tiktok(app: 'ck-new', createdAt: clock.now));
        await x.secrets.write(_uuid1, tiktokKeys('ck-new', clock.now.add(const Duration(hours: 24))));
        if (reverse) {
          // X's cloud client is offline: X syncs into its own folder only.
          clock.now = clock.now.add(const Duration(minutes: 1));
          await x.engine.sync();
        } else {
          await run(x);
        }
        // Y's client is offline: Y renews the old sign-in on its stale folder.
        clock.now = clock.now.add(const Duration(minutes: 1));
        final fresh = await y.engine.renew((await y.accounts.get(_uuid1))!, (await y.secrets.read(_uuid1))!,
            (current) async => tiktokKeys('ck-old', clock.now.add(const Duration(hours: 24))));
        if (fresh != null) await y.secrets.write(_uuid1, fresh);
        await cloud.sync('Y');
        if (reverse) await cloud.sync('X'); // X's write becomes the copy
        expect(cloud.serverCopies, isNotEmpty, reason: 'the race goes through a conflicted copy');
        for (final d in [y, x, y, x]) {
          await run(d);
        }
        expect(cloud.serverCopies, isEmpty, reason: 'merged and removed');
        await expectOneSignIn([x, y]);
      });
    }

    test('a thread that broke off partway keeps its live parts and its resume state when two targets become one', () {
      final partial = {
        'accountId': _uuid3,
        'status': 'failed',
        'result': PublishResult.partialFailure(const PublishError.network('connection reset'), remoteId: 'p1', threadRemoteIds: ['p1', 'p2'], resumable: true).toJson(),
      };
      final plainFailed = {'accountId': _uuid2, 'status': 'failed', 'result': PublishResult.failure(const PublishError.auth('revoked')).toJson()};
      final published = {'accountId': _uuid2, 'status': 'published', 'result': PublishResult.ok(remoteId: '111').toJson()};
      final src = PostsSyncSource(InMemoryPostRepository());
      PostTarget collapse(List<Object> targets) => Post.fromJson(Map<String, dynamic>.from(src.remapAccountIds(
              'p', Post.fromJson({..._post('p').toJson(), 'status': 'partial', 'targets': targets}).toJson(), {_uuid3: _uuid2})! as Map))
          .targets
          .single;
      final a = collapse([plainFailed, partial]);
      expect(a.result?.allRemoteIds, ['p1', 'p2'], reason: 'a retry must not post the live parts again');
      expect(a.result?.resumable, isTrue);
      final b = collapse([published, partial]);
      expect(b.status, TargetStatus.published);
      expect(b.result?.allRemoteIds, containsAll(['111', 'p1', 'p2']), reason: 'no live post is forgotten');
      // A winner without a result takes the other's whole.
      final pending = {'accountId': _uuid2, 'status': 'pending'};
      final handedOff = {'accountId': _uuid3, 'status': 'failed', 'result': PublishResult.handedOff(remoteUrl: 'https://example.com/p').toJson()};
      final c = collapse([pending, handedOff]);
      expect(c.status, TargetStatus.pending);
      expect(c.result?.remoteUrl, 'https://example.com/p');
    });

    test('a copy a 1.3.4 device brought back (an edit beats a deletion) is merged again into the account its link names', () async {
      await a.accounts.upsert(_account('x-1', 'x'));
      await a.engine.sync();
      const mk = {'instance': 'https://mk.example'};
      final cipher = BackupCipher(_pass, params: _fast, minimum: _fast);
      final doc = await file();
      doc.records['account:$_uuid2'] = SyncRecord.of(_account(_uuid2, 'misskey', tier: PlatformTier.openApi, handle: '@me@mk.example', config: mk).toJson(), at: clock.now, by: 'O');
      doc.records['account:$_uuid3'] = SyncRecord.tombstone(at: clock.now, by: 'O', mergedInto: _uuid2);
      doc.records['alias:$_uuid3'] = SyncRecord.of({'into': _uuid2}, at: clock.now, by: 'O');
      await backend.write(await cipher.seal(doc.toJson(writtenBy: 'O', writtenAt: clock.now)), ifMatch: (await backend.read())!.version);
      await _rounds([a], clock, 1);
      // The 1.3.4 phone had switched its copy off before it pulled the merge.
      final doc2 = await file();
      doc2.records['account:$_uuid3'] = SyncRecord.of(
          _account(_uuid3, 'misskey', tier: PlatformTier.openApi, handle: '@me@mk.example', config: mk).copyWith(enabled: false).toJson(),
          at: clock.now,
          by: 'P134');
      await backend.write(await cipher.seal(doc2.toJson(writtenBy: 'P134', writtenAt: clock.now)), ifMatch: (await backend.read())!.version);
      await _rounds([a], clock, 2);
      expect(await a.ids('misskey'), [_uuid2]);
      expect((await file()).records['account:$_uuid3']?.deleted, isTrue);
    });

    test('a copy 1.3.4 brought back after two merges in a row (a into b, then b into c) is merged into the end of the chain; a loop of links stops nothing', () async {
      await a.accounts.upsert(_account('x-1', 'x'));
      await a.engine.sync();
      const mk = {'instance': 'https://mk.example'};
      const u4 = '6f1c2d3e-0000-4abc-9def-000000000004', l1 = '6f1c2d3e-0000-4abc-9def-0000000000a1', l2 = '6f1c2d3e-0000-4abc-9def-0000000000a2';
      final at = clock.now;
      for (final e in {
        'account:$u4': SyncRecord.of(_account(u4, 'misskey', tier: PlatformTier.openApi, handle: '@me@mk.example', config: mk).toJson(), at: at, by: 'O'),
        'account:$_uuid3': SyncRecord.tombstone(at: at, by: 'O', mergedInto: u4),
        'alias:$_uuid3': SyncRecord.of({'into': u4}, at: at, by: 'O'),
        'alias:$_uuid2': SyncRecord.of({'into': _uuid3}, at: at, by: 'O'),
        // 1.3.4 brought the first copy back (an edit beats the tombstone it
        // rewrote without the link).
        'account:$_uuid2':
            SyncRecord.of(_account(_uuid2, 'misskey', tier: PlatformTier.openApi, handle: '@me@mk.example', config: mk).copyWith(enabled: false).toJson(), at: at, by: 'P134'),
        // Two links that point at each other, neither to a live account.
        'alias:$l1': SyncRecord.of({'into': l2}, at: at, by: 'O'),
        'alias:$l2': SyncRecord.of({'into': l1}, at: at, by: 'O'),
      }.entries) {
        await putInFile(e.key, e.value);
      }
      await _rounds([a], clock, 2);
      expect(await a.ids('misskey'), [u4], reason: 'the link chain leads from the first copy to the account it ended in');
      final doc = await file();
      expect(doc.records['account:$_uuid2']?.deleted, isTrue);
      expect((doc.records['alias:$_uuid2']?.value as Map?)?['into'], u4);
    });

    test('two copies whose links point at each other become one, the same one on every device', () async {
      await a.accounts.upsert(_account('x-1', 'x'));
      await a.engine.sync();
      const mk = {'instance': 'https://mk.example'};
      final at = clock.now;
      for (final e in {
        'account:$_uuid2': SyncRecord.of(_account(_uuid2, 'misskey', tier: PlatformTier.openApi, handle: '@me@mk.example', config: mk).toJson(), at: at, by: 'O'),
        'account:$_uuid3': SyncRecord.of(_account(_uuid3, 'misskey', tier: PlatformTier.openApi, handle: '@me@mk.example', config: mk).toJson(), at: at, by: 'O'),
        'alias:$_uuid2': SyncRecord.of({'into': _uuid3}, at: at, by: 'O'),
        'alias:$_uuid3': SyncRecord.of({'into': _uuid2}, at: at, by: 'O'),
      }.entries) {
        await putInFile(e.key, e.value);
      }
      await _rounds([a], clock, 2);
      expect(await a.ids('misskey'), [_uuid3], reason: 'the first link followed (the smaller id merges into the other)');
    });

    test('malformed links and keys stop nothing', () async {
      await a.accounts.upsert(_account(_uuid2, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig));
      await a.posts.upsert(_post('p', targets: const [PostTarget(accountId: _uuid3)]));
      await a.engine.sync();
      final at = clock.now;
      for (final e in {
        'alias:': SyncRecord.of({'into': _uuid2}, at: at, by: 'O'),
        'alias:a': SyncRecord.of({'into': 5}, at: at, by: 'O'),
        'alias:b': SyncRecord.of('not a map', at: at, by: 'O'),
        'alias:c': SyncRecord.of(null, at: at, by: 'O'),
        'alias:$_uuid3': SyncRecord.of({'into': _uuid2, 'extra': [1, 2]}, at: at, by: 'O'),
        'alias:loop': SyncRecord.of({'into': 'loop'}, at: at, by: 'O'),
        ':x': SyncRecord.of(1, at: at, by: 'O'),
        'account:': SyncRecord.tombstone(at: at, by: 'O', mergedInto: _uuid2),
      }.entries) {
        await putInFile(e.key, e.value);
      }
      await _rounds([a], clock, 1);
      await a.engine.preview();
      expect((await a.posts.get('p'))!.targets.single.accountId, _uuid2);
    });
  });

  group('renewals and syncs that cross: the publish service with the engine as coordinator (1.3.5)', () {
    const id = '6f1c2d3e-0000-4abc-9def-0000000000aa';

    ConnectedAccount rotating(String network, String app, DateTime createdAt) => ConnectedAccount(
          id: id,
          platformId: network,
          tier: PlatformTier.byokApi,
          displayName: 'Me',
          handle: '@me',
          createdAt: createdAt,
          config: network == 'x'
              ? {XAdapter.cfgClientId: app, XAdapter.cfgUserId: '42'}
              : {TumblrAdapter.cfgConsumerKey: app, TumblrAdapter.cfgAuthMode: TumblrAdapter.authOAuth2},
        );

    PublishService publisher(_Device d, PlatformAdapter adapter, Future<http.Response> Function(http.Request) handler, {bool coordinated = true}) =>
        PublishService(
          registry: AdapterRegistry([adapter]),
          accounts: d.accounts,
          posts: d.posts,
          secrets: d.secrets,
          quota: QuotaTracker(InMemoryQuotaRepository()),
          http: NeforumHttp(client: MockClient(handler), maxRetries: 0),
          clock: () => clock.now,
          secretsCoordinator: coordinated ? d.engine : null,
        );

    Post draft() => _post('p', targets: const [PostTarget(accountId: id)]);

    for (final network in ['x', 'tumblr']) {
      test('$network: B renews the old sign-in while A reconnects through another app, and B\'s timer sync lands during the token call: the reconnect stays', () async {
        final server = _RotatingTokenServer(network);
        final a = _Device('A', backend, clock), b = _Device('B', backend, clock);
        await a.accounts.upsert(rotating(network, 'app-old', DateTime.utc(2026, 10, 1)));
        await a.secrets.write(id, server.issue('app-old', clock.now.add(const Duration(minutes: 30))));
        await a.engine.sync();
        await b.engine.sync();
        clock.now = clock.now.add(const Duration(minutes: 31)); // B's keys have expired
        await b.posts.upsert(draft());
        server.during = () async {
          await a.accounts.upsert(rotating(network, 'app-new', clock.now));
          await a.secrets.write(id, server.issue('app-new', clock.now.add(const Duration(hours: 2))));
          await a.engine.sync();
          await b.engine.sync(); // B's timer: it takes A's reconnect while the token call runs
        };
        await publisher(b, _RotatingPublishing.of(network), server.handle).publish('p');
        expect(server.calls, 1, reason: 'the renewal ran, through renew()');
        await _rounds([b, a, b, a], clock, 1);
        for (final d in [a, b]) {
          expect(server.verdict((await d.accounts.get(id))!, await d.secrets.read(id)), 'account app=app-new; keys of app app-new; renewable', reason: d.id);
        }
      });

      test('$network: a renewal through the coordinator shares its stamps with the keys, and the account stays one registration', () async {
        final server = _RotatingTokenServer(network);
        final a = _Device('A', backend, clock), b = _Device('B', backend, clock);
        await a.accounts.upsert(rotating(network, 'app-old', DateTime.utc(2026, 10, 1)));
        await a.secrets.write(id, server.issue('app-old', clock.now.add(const Duration(minutes: 30))));
        await a.engine.sync();
        await b.engine.sync();
        final before = (await a.accounts.get(id))!.toJson();
        clock.now = clock.now.add(const Duration(minutes: 31));
        await b.posts.upsert(draft());
        await publisher(b, _RotatingPublishing.of(network, now: () => clock.now), server.handle).publish('p');
        expect(server.calls, 1);
        await _rounds([b, a], clock, 1);
        final keys = (await a.secrets.read(id))!;
        expect(DateTime.tryParse(keys[StoredSecretKeys.lastRenewedAt] ?? ''), isNotNull, reason: 'it reached the other device');
        expect(keys[StoredSecretKeys.expiresAtSource], 'serverReported');
        expect(sharesRegistration(before, (await a.accounts.get(id))!.toJson()), isTrue);
      });

      test('$network: the keychain cannot be re-read after the renewal: the rotating renewal is still stored (the old keys are dead)', () async {
        final server = _RotatingTokenServer(network);
        final store = _ThrowingSecrets();
        final b = _Device('B', backend, clock, secretStore: store);
        await b.accounts.upsert(rotating(network, 'app-old', DateTime.utc(2026, 10, 1)));
        await b.secrets.write(id, server.issue('app-old', clock.now.add(const Duration(minutes: 30))));
        clock.now = clock.now.add(const Duration(minutes: 31));
        await b.posts.upsert(draft());
        store
          ..reads = 0
          ..failReadsAfter = 1; // the first read works, the re-read throws
        await publisher(b, _RotatingPublishing.of(network), server.handle, coordinated: false).publish('p');
        store.failReadsAfter = 1 << 30;
        expect(server.verdict((await b.accounts.get(id))!, await b.secrets.read(id)), 'account app=app-old; keys of app app-old; renewable');
        expect((await b.posts.get('p'))!.targets.single.status, TargetStatus.published);
      });

      for (final atomic in [true, false]) {
        test('$network (${atomic ? 'atomic' : 'folder-like'} storage): A reconnected through another app long ago and those keys expired too; B publishes before syncing: renew() renews them with the account as stored now', () async {
          final server = _RotatingTokenServer(network);
          final store = MemorySyncBackend(atomicWrites: atomic);
          final a = _Device('A', store, clock), b = _Device('B', store, clock);
          await a.accounts.upsert(rotating(network, 'app-old', DateTime.utc(2026, 10, 1)));
          await a.secrets.write(id, server.issue('app-old', clock.now.add(const Duration(minutes: 30))));
          await a.engine.sync();
          await b.engine.sync();
          clock.now = clock.now.add(const Duration(hours: 1));
          await a.accounts.upsert(rotating(network, 'app-new', clock.now));
          await a.secrets.write(id, server.issue('app-new', clock.now.add(const Duration(hours: 2))));
          await a.engine.sync();
          clock.now = clock.now.add(const Duration(hours: 3)); // both sign-ins' access tokens have expired
          await b.posts.upsert(draft());
          await publisher(b, _RotatingPublishing.of(network, now: () => clock.now), server.handle).publish('p');
          expect(server.calls, 1);
          expect((await b.posts.get('p'))!.targets.single.status, TargetStatus.published, reason: 'no false "reconnect the account"');
          expect((await b.accounts.get(id))!.lastError, isNull);
          await _rounds([b, a, b, a], clock, 1);
          for (final d in [a, b]) {
            expect(server.verdict((await d.accounts.get(id))!, await d.secrets.read(id)), 'account app=app-new; keys of app app-new; renewable', reason: d.id);
          }
        });
      }

      test('$network: the keys renew() starts from came in its own sync (A renewed while B was offline, and that expired too): the renewal is stored', () async {
        final server = _RotatingTokenServer(network);
        final a = _Device('A', backend, clock), b = _Device('B', backend, clock);
        await a.accounts.upsert(rotating(network, 'app-old', DateTime.utc(2026, 10, 1)));
        await a.secrets.write(id, server.issue('app-old', clock.now.add(const Duration(minutes: 30))));
        await a.engine.sync();
        await b.engine.sync();
        clock.now = clock.now.add(const Duration(minutes: 31));
        await a.secrets.write(id, server.issue('app-old', clock.now.add(const Duration(hours: 2)))); // A renews the same sign-in
        await a.engine.sync();
        clock.now = clock.now.add(const Duration(hours: 3)); // A's renewal has expired as well; B never synced
        await b.posts.upsert(draft());
        await publisher(b, _RotatingPublishing.of(network, now: () => clock.now), server.handle).publish('p');
        expect((await b.posts.get('p'))!.targets.single.status, TargetStatus.published);
        await _rounds([b, a, b, a], clock, 1);
        for (final d in [a, b]) {
          expect(server.verdict((await d.accounts.get(id))!, await d.secrets.read(id)), 'account app=app-old; keys of app app-old; renewable',
              reason: '${d.id}: a renewal of the keys that arrived is the only live key, and is kept');
        }
      });

      test('$network: the keychain locks while renew() waits on the network: the rotating renewal is still stored', () async {
        final server = _RotatingTokenServer(network);
        final store = _ThrowingSecrets();
        final a = _Device('A', backend, clock), b = _Device('B', backend, clock, secretStore: store);
        await a.accounts.upsert(rotating(network, 'app-old', DateTime.utc(2026, 10, 1)));
        await a.secrets.write(id, server.issue('app-old', clock.now.add(const Duration(minutes: 30))));
        await a.engine.sync();
        await b.engine.sync();
        clock.now = clock.now.add(const Duration(minutes: 31));
        await b.posts.upsert(draft());
        server.during = () async => store.locked = true; // locked from the token call until after the publish
        await publisher(b, _RotatingPublishing.of(network), server.handle).publish('p');
        store.locked = false;
        expect(server.verdict((await b.accounts.get(id))!, await b.secrets.read(id)), 'account app=app-old; keys of app app-old; renewable');
        await _rounds([b, a], clock, 1);
        expect(server.verdict((await a.accounts.get(id))!, await a.secrets.read(id)), 'account app=app-old; keys of app app-old; renewable', reason: 'and it is shared');
      });
    }

    test('an account removed by a sync during the token call gets no keys back here', () async {
      final a = _Device('A', backend, clock), b = _Device('B', backend, clock);
      ConnectedAccount tiktok() => ConnectedAccount(
          id: id, platformId: 'tiktok', tier: PlatformTier.byokApi, displayName: 'Me', createdAt: DateTime.utc(2026, 10, 1), config: const {'clientKey': 'ck', 'openId': 'o'});
      Map<String, String> keys(DateTime exp) =>
          {'access_token': 'act-fake', 'refresh_token': 'rft-fake', 'expires_at': exp.toUtc().toIso8601String(), 'client_secret': 'cs-fake', 'token_type': 'Bearer'};
      await a.accounts.upsert(tiktok());
      await a.secrets.write(id, keys(clock.now.add(const Duration(minutes: 30))));
      await a.engine.sync();
      await b.engine.sync();
      clock.now = clock.now.add(const Duration(minutes: 31));
      await b.posts.upsert(draft());
      await publisher(b, _TikTokPublishing(() async => PublishResult.ok(remoteId: 'v')), (r) async {
        if (r.url.path.contains('/oauth/token/')) {
          await a.secrets.delete(id);
          await a.accounts.delete(id); // removed on A
          await a.engine.sync();
          await b.engine.sync();
          return http.Response(
              jsonEncode({'access_token': 'act-fake-2', 'expires_in': 86400, 'refresh_token': 'rft-fake-2', 'refresh_expires_in': 31536000, 'open_id': 'o', 'token_type': 'Bearer'}), 200,
              headers: jsonHeaders);
        }
        return http.Response('{}', 200, headers: jsonHeaders);
      }, coordinated: false)
          .publish('p');
      expect(await b.accounts.get(id), isNull);
      expect(await b.secrets.read(id), isNull, reason: 'no orphan keys for an account that is gone');
    });

    test('keys that arrived by sync during the renewal and are expired themselves are renewed once, with the account as stored now', () async {
      final a = _Device('A', backend, clock), b = _Device('B', backend, clock);
      ConnectedAccount tiktok(String app, DateTime at) => ConnectedAccount(
          id: id, platformId: 'tiktok', tier: PlatformTier.byokApi, displayName: 'Me', handle: '@me', createdAt: at, config: {'clientKey': app, 'openId': 'o'});
      Map<String, String> keys(String app, DateTime exp) => {
            'access_token': 'act-$app-fake',
            'refresh_token': 'rft-$app-fake',
            'expires_at': exp.toUtc().toIso8601String(),
            'refresh_expires_at': '2027-10-20T12:00:00.000Z',
            'token_type': 'Bearer',
            'client_secret': 'cs-$app-fake',
          };
      await a.accounts.upsert(tiktok('ck-old', DateTime.utc(2026, 10, 1)));
      await a.secrets.write(id, keys('ck-old', clock.now.add(const Duration(minutes: 30))));
      await a.engine.sync();
      await b.engine.sync();
      // A reconnects through ck-new (24-hour keys) while B is offline for a day.
      clock.now = clock.now.add(const Duration(hours: 1));
      await a.accounts.upsert(tiktok('ck-new', clock.now));
      await a.secrets.write(id, keys('ck-new', clock.now.add(const Duration(hours: 24))));
      await a.engine.sync();
      clock.now = clock.now.add(const Duration(hours: 26)); // both sign-ins' access tokens have expired
      await b.posts.upsert(draft());
      final apps = <String?>[];
      final used = <Map<String, String>>[];
      await publisher(b, _TikTokPublishing(() async => PublishResult.ok(remoteId: 'v'), used: used), (r) async {
        if (r.url.path.contains('/oauth/token/')) {
          final body = Uri.splitQueryString(r.body);
          final app = body['client_key'];
          apps.add(app);
          if (apps.length == 1) await b.engine.sync(); // B's start-up sync lands during the first token call
          final ok = body['client_secret'] == 'cs-$app-fake' && body['refresh_token'] == 'rft-$app-fake';
          return ok
              ? http.Response(
                  jsonEncode({'access_token': 'act-$app-renewed', 'expires_in': 86400, 'refresh_token': 'rft-$app-fake', 'refresh_expires_in': 31536000, 'open_id': 'o', 'token_type': 'Bearer'}),
                  200,
                  headers: jsonHeaders)
              : http.Response(jsonEncode({'error': 'invalid_client', 'error_description': 'Client key does not match', 'log_id': 'x'}), 400, headers: jsonHeaders);
        }
        return http.Response('{}', 200, headers: jsonHeaders);
      }, coordinated: false)
          .publish('p');
      expect(apps, ['ck-old', 'ck-new'], reason: 'the old renewal dropped, the arrived sign-in renewed with its own app');
      expect(used.single['access_token'], 'act-ck-new-renewed', reason: 'never an expired token');
      expect((await b.secrets.read(id))!['access_token'], 'act-ck-new-renewed');
      expect((await b.posts.get('p'))!.targets.single.status, TargetStatus.published);
      expect((await b.accounts.get(id))!.lastError, isNull, reason: 'no false "needs reconnecting"');
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

      final writes = backend.writes;
      final preview = await _expectDryRunEqualsSync(b);
      expect(backend.writes, writes + 1, reason: 'only the real sync writes');
      expect(preview.firstJoin, isTrue);
      expect(preview.seed, SyncSeed.file);
      expect(preview.here, SyncSideSummary(accounts: 2, oldestConnection: DateTime.utc(2026, 10, 1)));
      expect(preview.file.accounts, 3);
      expect(preview.mergedAccounts, {_uuid2: _uuid1});
      expect(preview.fromDevices, ['A']);
      expect(preview.removed, {'account:$_uuid2', 'secrets:$_uuid2'}, reason: 'the merged copy goes');
      expect(preview.sent, containsAll(['account:bsky', 'post:pb']), reason: "this device's own records");
      expect(preview.sent, isNot(contains('account:$_uuid1')), reason: 'a merge rewrite is not "from this device"');
    });

    test('a file that holds one account twice: the joining device is told what really arrives', () async {
      final folder = _CloudFolder();
      final x = _Device('X', folder, clock), y = _Device('Y', folder, clock), z = _Device('Z', folder, clock), fresh = _Device('D', folder, clock);
      await x.accounts.upsert(_account('x-1', 'x'));
      await x.engine.sync();
      await y.accounts.upsert(_account(_uuid2, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig));
      await z.accounts.upsert(_account(_uuid3, 'mastodon', tier: PlatformTier.openApi, handle: '@me@mastodon.example', config: _mastodonConfig));
      folder.freeze();
      await y.engine.sync();
      await z.engine.sync();
      folder.thaw();
      final p = await fresh.engine.preview();
      await fresh.engine.sync();
      expect(p.receivedOf('account'), (await fresh.accounts.all()).length, reason: 'the dry run counts what arrives');
      expect(p.mergedInFile, {_uuid3}, reason: 'this device had neither copy');
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

  /// Out of reach altogether (a folder not mounted yet, a server down):
  /// reads fail too.
  bool down = false;

  @override
  String get label => 'flaky';
  @override
  bool get atomicWrites => true;
  @override
  Future<SyncBlob?> read() async {
    if (down) throw const SyncBackendException('offline', temporary: true);
    return inner.read();
  }
  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) async {
    if (down || failures > 0) {
      if (!down) failures--;
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
      // The version of the file this device wrote, as a folder reports it
      // (its time and size): never the version of the other device's file
      // that the cloud app puts in its place later.
      return 'copy ${pendingCopies.length}';
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

/// TikTok as the publish service sees it, with an upload the test controls;
/// everything else, the renewal included, is the real adapter.
class _TikTokPublishing extends TikTokAdapter {
  _TikTokPublishing(this.onPublish, {this.used});
  final Future<PublishResult> Function() onPublish;

  /// The keys each upload ran with.
  final List<Map<String, String>>? used;
  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) => const [];
  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) {
    used?.add(Map.of(secrets));
    return onPublish();
  }
}

/// A cloud client over real [FolderSyncBackend]s, one folder per device, as
/// the critic built it in round 7: it uploads a changed main file, downloads
/// a newer one, and when both changed keeps the server's as the main file and
/// turns the device's into a conflicted copy (a file of its own, with its own
/// time and size, in every folder). Unlike [_CloudFolder], a device's reads
/// see its own writes, and the version it holds is its own file's.
class _CloudClient {
  _CloudClient(this.root);
  final Directory root;
  Uint8List? server;
  final serverCopies = <String, Uint8List>{};
  final _known = <String, String?>{}; // device -> hash of the main file at its last cloud sync
  final _seenCopies = <String, Set<String>>{};
  final _dirs = <String, Directory>{};
  int _conflicts = 0;

  FolderSyncBackend folder(String device) {
    final d = Directory(p.join(root.path, device))..createSync(recursive: true);
    _dirs[device] = d;
    _known[device] = null;
    _seenCopies[device] = {};
    return FolderSyncBackend(d.path);
  }

  static String? _hash(Uint8List? b) => b == null ? null : crypto.sha256.convert(b).toString();

  Future<void> sync(String device) async {
    final dir = _dirs[device]!;
    final main = File(p.join(dir.path, kSyncFileName));
    final local = main.existsSync() ? main.readAsBytesSync() : null;
    final known = _known[device];
    final lh = _hash(local), sh = _hash(server);
    if (lh != known && sh != known && lh != sh) {
      _conflicts++;
      serverCopies['NEFORUM ($device conflicted copy $_conflicts).neforumsync'] = local!;
      main.writeAsBytesSync(server!, flush: true);
    } else if (lh != known) {
      server = local;
    } else if (sh != known) {
      main.writeAsBytesSync(server!, flush: true);
    }
    _known[device] = _hash(server);
    // A copy removed on a device that had it is removed everywhere; a new
    // one on the server is downloaded.
    final here = {
      for (final f in dir.listSync().whereType<File>())
        if (p.basename(f.path).contains('conflicted copy')) p.basename(f.path),
    };
    for (final gone in _seenCopies[device]!.difference(here)) {
      serverCopies.remove(gone);
    }
    for (final e in serverCopies.entries) {
      if (!here.contains(e.key)) File(p.join(dir.path, e.key)).writeAsBytesSync(e.value, flush: true);
    }
    _seenCopies[device] = serverCopies.keys.toSet();
    await Future<void>.delayed(const Duration(milliseconds: 5)); // distinct file times
  }
}

/// A keychain that throws on reads after [failReadsAfter] of them.
class _ThrowingSecrets extends InMemorySecretStore {
  int failReadsAfter = 1 << 30;
  int reads = 0;

  /// Every read throws while set.
  bool locked = false;
  @override
  Future<Map<String, String>?> read(String key) async {
    reads++;
    if (locked || reads > failReadsAfter) throw StateError('keychain locked');
    return super.read(key);
  }
}

/// X and Tumblr with an upload that always works; the renewal is the real
/// adapter's.
class _RotatingPublishing {
  /// With [now], an upload made with an expired access token fails, as the
  /// network would refuse it.
  static PlatformAdapter of(String network, {DateTime Function()? now}) => network == 'x' ? _XPublishing(now) : _TumblrPublishing(now);

  static PublishResult upload(Map<String, String> secrets, DateTime Function()? now) {
    final exp = DateTime.tryParse(secrets['expires_at'] ?? '');
    if (now != null && exp != null && !exp.isAfter(now())) return PublishResult.failure(const PublishError.auth('access token expired'));
    return PublishResult.ok(remoteId: 'r1');
  }
}

class _XPublishing extends XAdapter {
  _XPublishing(this.now);
  final DateTime Function()? now;
  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) => const [];
  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async =>
      _RotatingPublishing.upload(secrets, now);
}

class _TumblrPublishing extends TumblrAdapter {
  _TumblrPublishing(this.now);
  final DateTime Function()? now;
  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) => const [];
  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async =>
      _RotatingPublishing.upload(secrets, now);
}

/// An OAuth 2.0 token server that rotates refresh tokens, as X and Tumblr
/// do, for several developer apps: a refresh token works once, and only with
/// the app that issued it (the critic's round-8 server).
class _RotatingTokenServer {
  _RotatingTokenServer(this.network);
  final String network; // 'x' or 'tumblr'
  final valid = <String, String>{}; // app -> the one refresh token that works
  final _issued = <String, int>{};
  int calls = 0;

  /// Runs once, while the next token call is in flight.
  Future<void> Function()? during;

  String get _secretKey => network == 'x' ? XAdapter.secretClientSecret : TumblrAdapter.secretConsumerSecret;

  Map<String, String> issue(String app, DateTime expires) {
    final n = (_issued[app] ?? 0) + 1;
    _issued[app] = n;
    valid[app] = 'rft-$app-$n-fake';
    return {
      'access_token': 'act-$app-$n-fake',
      'refresh_token': 'rft-$app-$n-fake',
      'expires_at': expires.toUtc().toIso8601String(),
      'token_type': 'Bearer',
      _secretKey: 'cs-$app-fake',
    };
  }

  Future<http.Response> handle(http.Request r) async {
    if (!r.url.path.contains('oauth2/token')) return http.Response('{}', 200, headers: jsonHeaders);
    calls++;
    final hook = during;
    during = null;
    if (hook != null) await hook();
    final body = Uri.splitQueryString(r.body);
    final app = body['client_id'];
    var secret = body['client_secret'];
    final auth = r.headers['authorization'] ?? r.headers['Authorization'];
    if (auth != null && auth.startsWith('Basic ')) secret = utf8.decode(base64Decode(auth.substring(6))).split(':').skip(1).join(':');
    if (app == null || secret != 'cs-$app-fake' || body['refresh_token'] != valid[app]) {
      return http.Response(jsonEncode({'error': 'invalid_grant', 'error_description': 'refresh token invalid'}), 400, headers: jsonHeaders);
    }
    final n = (_issued[app] ?? 0) + 1;
    _issued[app] = n;
    valid[app] = 'rft-$app-$n-fake';
    return http.Response(jsonEncode({'access_token': 'act-$app-$n-fake', 'refresh_token': 'rft-$app-$n-fake', 'expires_in': 7200, 'token_type': 'bearer'}), 200,
        headers: jsonHeaders);
  }

  /// Which app the account and its keys belong to, and whether the keys can
  /// still be renewed.
  String verdict(ConnectedAccount a, Map<String, String>? k) {
    final app = a.configString(network == 'x' ? XAdapter.cfgClientId : TumblrAdapter.cfgConsumerKey);
    final keyApp = (k?[_secretKey] ?? '?').replaceAll('cs-', '').replaceAll('-fake', '');
    final live = k != null && k['refresh_token'] == valid[app] && keyApp == app;
    return 'account app=$app; keys of app $keyApp; ${live ? 'renewable' : 'DEAD'}';
  }
}

class _Killed implements Exception {}

/// The write reaches the storage, then the app dies before anything else.
class _CrashAfterWrite extends SyncBackend {
  _CrashAfterWrite(this.inner);
  final MemorySyncBackend inner;
  bool crashNext = false;
  @override
  bool get atomicWrites => true;
  @override
  String get label => 'crash after write';
  @override
  Future<SyncBlob?> read() => inner.read();
  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) async {
    final v = await inner.write(bytes, ifMatch: ifMatch);
    if (crashNext) {
      crashNext = false;
      throw _Killed();
    }
    return v;
  }

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
  SignInPolicy signInPolicyFor(ConnectedAccount account) => SignInPolicy.noConnection;

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
