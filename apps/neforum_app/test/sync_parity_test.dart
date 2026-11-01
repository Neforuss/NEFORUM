// The repro for "sync carries the exact setup": two devices with different
// setups, separate storage and keychains, one synced folder. After syncing
// A, B, A both must hold the same accounts (but for device-only fields), the
// same keys, the same media hosts with their keys and the same settings
// (but for the reviewed device-only ones), and that setup must be the one of
// the device with the most accounts.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/media_host_config.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'sync_fixtures.dart';

/// The reviewed device-only lists, each entry with its reason
/// (device_transfer.dart, sync_sources.dart). The media host settings are on
/// it because they are not settings records; the media hosts are compared
/// on their own, with their keys.
final _deviceOnlySettings = kDeviceOnlySettings.keys.toSet();
final _deviceOnlyAccountFields = kDeviceOnlyAccountFields.keys.toSet();

const _timeout = Timeout(Duration(minutes: 3));

Future<Map<String, Object?>> _setup(SyncTestDevice d) =>
    setupOf(d, deviceOnlySettings: _deviceOnlySettings, deviceOnlyAccountFields: _deviceOnlyAccountFields);

const _uuidA = '0a1b2c3d-1111-4aaa-8bbb-000000000001';
const _uuidB = '0a1b2c3d-2222-4aaa-8bbb-000000000002';

Map<String, String> _s3(String secret) => {
      'endpoint': 'https://s3.example.com',
      'bucket': 'fake-bucket',
      'accessKeyId': 'FAKEKEYID',
      'secretAccessKey': secret,
      'publicBaseUrl': 'https://cdn.example.com',
    };

Map<String, String> _webDav(String password) => {
      'webdavUrl': 'https://dav.example.com/remote.php/dav/files/u/media',
      'username': 'fake-user',
      'password': password,
      'publicUrlTemplate': 'https://dav.example.com/s/{path}',
    };

/// The computer with the real setup: three accounts, every setting changed,
/// both media hosts.
Future<SyncTestDevice> _fullDevice(String folder) async {
  final d = SyncTestDevice(folder, settings: populatedSettings().copyWith(clearMediaHost: true, clearFallbackMediaHost: true));
  await d.addAccount(
      fakeAccount(_uuidA, 'mastodon', handle: '@alice@mastodon.social', config: const {'instance': 'https://mastodon.social', 'domain': 'mastodon.social', 'remoteAccountId': '42'}),
      keys: {'access_token': 'fake-mastodon-token-a'});
  await d.addAccount(fakeAccount('x-111', 'x', tier: PlatformTier.byokApi, handle: '@alice_x'), keys: {'access_token': 'fake-x-token'});
  await d.addAccount(fakeAccount('bluesky:did:plc:fakealice', 'bluesky', handle: 'alice.bsky.social'), keys: {'app_password': 'fake-bsky-pass'});
  await d.addMediaHost(MediaHostSlot.main, 's3', _s3('fake-s3-secret'));
  await d.addMediaHost(MediaHostSlot.fallback, 'webdav', _webDav('fake-dav-pass'));
  return d;
}

void main() {
  test('a joining device gets the exact setup of the device with more accounts', () async {
    final folder = await syncFolderForTest(addTearDown);
    final a = await _fullDevice(folder);
    final b = SyncTestDevice(folder);
    await b.addAccount(fakeAccount('bluesky:did:plc:fakebob', 'bluesky', handle: 'bob.bsky.social'), keys: {'app_password': 'fake-bob-pass'});
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final seed = await _setup(a);

    await a.syncOnce();
    await b.syncOnce();
    await a.syncOnce();

    final onA = await _setup(a), onB = await _setup(b);
    expect(onB, onA, reason: 'both devices hold the same setup; differs at ${diffPaths(onA, onB)}');
    expect(onB['settings'], seed['settings'], reason: "every shared setting is A's; differs at ${diffPaths(seed['settings'], onB['settings'])}");
    expect(onB['mediaHosts'], seed['mediaHosts'], reason: "A's media hosts arrive with their keys");
    expect((onB['accounts']! as Map).keys.toSet(), {_uuidA, 'x-111', 'bluesky:did:plc:fakealice', 'bluesky:did:plc:fakebob'},
        reason: 'nothing is deleted, nothing doubles');
  }, timeout: _timeout);

  test('the device with more accounts gives its setup even when it joins second', () async {
    final folder = await syncFolderForTest(addTearDown);
    // A new phone made the file first, with a setup of its own.
    final a = SyncTestDevice(folder, settings: otherSettings());
    await a.addAccount(fakeAccount('bluesky:did:plc:fakebob', 'bluesky', handle: 'bob.bsky.social'), keys: {'app_password': 'fake-bob-pass'});
    await a.addMediaHost(MediaHostSlot.main, 'catbox', {'userhash': 'fake-userhash'});
    final b = await _fullDevice(folder);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final seed = await _setup(b);

    await a.syncOnce();
    await b.syncOnce();
    await a.syncOnce();

    final onA = await _setup(a), onB = await _setup(b);
    expect(onA, onB, reason: 'differs at ${diffPaths(onA, onB)}');
    expect(onA['settings'], seed['settings'], reason: 'B has more accounts: its settings win; differs at ${diffPaths(seed['settings'], onA['settings'])}');
    expect(onA['mediaHosts'], seed['mediaHosts'], reason: "B's main and fallback hosts win; differs at ${diffPaths(seed['mediaHosts'], onA['mediaHosts'])}");
    expect((onA['accounts']! as Map).length, 4, reason: "A's own account is kept");
  }, timeout: _timeout);

  test('a change after joining travels, a reset to the default and a removed fallback host too', () async {
    final folder = await syncFolderForTest(addTearDown);
    final a = await _fullDevice(folder);
    final b = SyncTestDevice(folder);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await a.syncOnce();
    await b.syncOnce();
    await a.syncOnce();

    // Back to the defaults on A: settings that leave the file when they are
    // default, a setting that never does, and the fallback host.
    final reset = a.settings.toJson()
      ..remove('customAccentColor')
      ..remove('captionStyle')
      ..remove('navigationChromeOpacity')
      ..remove('cardPresets')
      ..['themeMode'] = ThemeMode.system.name;
    a.settings = await clearMediaHost(AppSettings.fromJson(reset), a.secrets, slot: MediaHostSlot.fallback);
    final changed = await _setup(a);
    await a.syncOnce();
    await b.syncOnce();
    await a.syncOnce();

    final afterA = await _setup(a), afterB = await _setup(b);
    expect(afterA, changed, reason: 'A keeps its change: B does not send its old values back; differs at ${diffPaths(changed, afterA)}');
    expect(afterB, changed, reason: "B follows A's change; differs at ${diffPaths(changed, afterB)}");
    expect(b.settings.customAccentColor, isNull);
    expect(b.settings.fallbackMediaHostId, isNull);
    expect(await b.secrets.read(MediaHostSlot.fallback.secretsKey), isNull, reason: 'the removed host takes its keys along');
  }, timeout: _timeout);

  test('the same account connected on both devices arrives once; different accounts on one network stay apart', () async {
    final folder = await syncFolderForTest(addTearDown);
    const mastodonConfig = {'instance': 'https://mastodon.social', 'domain': 'mastodon.social', 'remoteAccountId': '42'};
    final a = SyncTestDevice(folder);
    await a.addAccount(fakeAccount(_uuidA, 'mastodon', handle: '@Alice@Mastodon.Social', createdAt: DateTime.utc(2026, 9, 1), config: mastodonConfig),
        keys: {'access_token': 'fake-older-sign-in'});
    await a.addAccount(fakeAccount('x-111', 'x', tier: PlatformTier.byokApi, handle: '@alice_x'), keys: {'access_token': 'fake-x-a'});
    await a.addAccount(fakeAccount('bluesky:did:plc:fakealice', 'bluesky', handle: 'alice.bsky.social'), keys: {'app_password': 'fake-bsky'});
    // B has more accounts, so its setup wins: its default targets name its
    // own copy of the Mastodon account.
    final b = SyncTestDevice(folder, settings: const AppSettings(defaultTargetIds: [_uuidB, 'x-222']));
    await b.addAccount(fakeAccount(_uuidB, 'mastodon', handle: 'alice@mastodon.social', createdAt: DateTime.utc(2026, 10, 15), config: mastodonConfig),
        keys: {'access_token': 'fake-newer-sign-in'});
    await b.addAccount(fakeAccount('x-222', 'x', tier: PlatformTier.byokApi, handle: '@bob_x'), keys: {'access_token': 'fake-x-b'});
    await b.addAccount(fakeAccount('bluesky:did:plc:fakealice', 'bluesky', handle: 'alice.bsky.social'), keys: {'app_password': 'fake-bsky'});
    await b.addAccount(fakeAccount('tumblr:fakeblog', 'tumblr', tier: PlatformTier.byokApi, handle: 'fakeblog'), keys: {'oauth_token': 'fake-tumblr'});
    await b.posts.upsert(Post(
      id: 'draft-b',
      text: 'hello',
      createdAt: DateTime.utc(2026, 10, 20),
      updatedAt: DateTime.utc(2026, 10, 20),
      targets: const [PostTarget(accountId: _uuidB), PostTarget(accountId: 'x-222')],
    ));
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    await a.syncOnce();
    await b.syncOnce();
    await a.syncOnce();

    for (final d in [a, b]) {
      final all = await d.accounts.all();
      expect(all.map((x) => x.id).toSet(), {_uuidA, 'x-111', 'x-222', 'bluesky:did:plc:fakealice', 'tumblr:fakeblog'},
          reason: 'one Mastodon account under the id the file already had; two X accounts; one Bluesky account');
      expect((await d.secrets.read(_uuidA))?['access_token'], 'fake-newer-sign-in', reason: "the newer sign-in's keys");
      expect(d.settings.defaultTargetIds, [_uuidA, 'x-222'], reason: 'default targets follow the merged account');
      expect((await d.posts.get('draft-b'))!.targets.map((t) => t.accountId), [_uuidA, 'x-222'], reason: 'posts follow the merged account');
    }
    expect(await b.secrets.read(_uuidB), isNull, reason: "the merged copy's keys go with it");
    final onA = await _setup(a), onB = await _setup(b);
    expect(onA, onB, reason: 'differs at ${diffPaths(onA, onB)}');
  }, timeout: _timeout);

  test('media hosts: a device without one never wipes the other, and each empty slot takes the other side\'s host', () async {
    final folder = await syncFolderForTest(addTearDown);
    // A has more accounts but no media host at all.
    final a = await _fullDevice(folder);
    a.settings = a.settings.copyWith(clearMediaHost: true, clearFallbackMediaHost: true);
    await a.secrets.delete(MediaHostSlot.main.secretsKey);
    await a.secrets.delete(MediaHostSlot.fallback.secretsKey);
    final b = SyncTestDevice(folder);
    await b.addMediaHost(MediaHostSlot.main, 'catbox', {'userhash': 'fake-userhash'});
    await b.addMediaHost(MediaHostSlot.fallback, 'webdav', _webDav('fake-dav-pass'));
    final bHosts = await collectMediaHostsOf(b);
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    await a.syncOnce();
    await b.syncOnce();
    await a.syncOnce();
    expect(await collectMediaHostsOf(a), bHosts, reason: "B's hosts travel to A with their keys");
    expect(await collectMediaHostsOf(b), bHosts, reason: 'A, which has none, wipes nothing');

    // A third device seeds the main slot only: B's fallback stays.
    final folder2 = await syncFolderForTest(addTearDown);
    final c = await _fullDevice(folder2);
    c.settings = await clearMediaHost(c.settings, c.secrets, slot: MediaHostSlot.fallback);
    final d = SyncTestDevice(folder2);
    await d.addMediaHost(MediaHostSlot.main, 'catbox', {'userhash': 'fake-userhash'});
    await d.addMediaHost(MediaHostSlot.fallback, 'webdav', _webDav('fake-dav-pass'));
    addTearDown(c.dispose);
    addTearDown(d.dispose);
    await c.syncOnce();
    await d.syncOnce();
    await c.syncOnce();
    for (final x in [c, d]) {
      expect(x.settings.mediaHostId, 's3', reason: "the main slot is the seed's");
      expect(x.settings.fallbackMediaHostId, 'webdav', reason: "the seed's empty fallback slot takes the other device's host");
      expect(await x.secrets.read(MediaHostSlot.fallback.secretsKey), {'password': 'fake-dav-pass'});
    }
  }, timeout: _timeout);

  test('a setting a newer NEFORUM wrote stays in the file untouched', () async {
    final folder = await syncFolderForTest(addTearDown);
    final a = await _fullDevice(folder);
    final b = SyncTestDevice(folder);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await a.syncOnce();
    await b.syncOnce();

    await _putInFile(folder, a.passphrase, {'setting:aSettingFromTheFuture': SyncRecord.of('kept', at: DateTime.utc(2026, 11, 1), by: 'newer-device')});

    for (var i = 0; i < 3; i++) {
      await a.syncOnce();
      await b.syncOnce();
    }
    final after = SyncDocument.parse(await BackupCipher(a.passphrase).open((await FolderSyncBackend(folder).read())!.bytes));
    final rec = after.records['setting:aSettingFromTheFuture'];
    expect(rec?.deleted, isFalse, reason: 'an older device must not delete what it does not know');
    expect(rec?.value, 'kept');
  }, timeout: _timeout);

  test("an older NEFORUM removing settings from the file changes nothing here, and a joining device gets the file side's values", () async {
    final folder = await syncFolderForTest(addTearDown);
    final a = await _fullDevice(folder);
    final b = SyncTestDevice(folder);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await a.syncOnce();
    await b.syncOnce();
    final setup = await _setup(a);
    expect(a.settings.browserQuickPost, isFalse);
    // A 1.3.4 device removes the setting it does not know and one it holds
    // at its default (what its second sync writes).
    await _putInFile(folder, a.passphrase, {
      'setting:browserQuickPost': SyncRecord.tombstone(at: DateTime.utc(2026, 11, 1), by: 'old-1.3.4'),
      'setting:captionStyle': SyncRecord.tombstone(at: DateTime.utc(2026, 11, 1), by: 'old-1.3.4'),
    });
    await a.syncOnce();
    await b.syncOnce();
    expect(await _setup(a), setup, reason: 'a deletion an older device wrote resets nothing: ${diffPaths(setup, await _setup(a))}');
    expect(await _setup(b), setup, reason: 'on any 1.3.5 device: ${diffPaths(setup, await _setup(b))}');

    // A new device joins (no accounts: the file's side wins).
    final c = SyncTestDevice(folder);
    addTearDown(c.dispose);
    await c.syncOnce();
    expect(a.settings.browserQuickPost, isFalse);
    await a.syncOnce(); // A puts back, once, what the older device removed
    await c.syncOnce();
    expect(await _setup(a), setup, reason: 'the joining device overrode the file side: ${diffPaths(setup, await _setup(a))}');
    final onC = await _setup(c);
    expect(onC['settings'], setup['settings'], reason: "the seed holds: ${diffPaths(setup['settings'], onC['settings'])}");
  }, timeout: _timeout);
}

/// Another device writes [records] into the sync file in [folder].
Future<void> _putInFile(String folder, String passphrase, Map<String, SyncRecord> records) async {
  final backend = FolderSyncBackend(folder);
  final cipher = BackupCipher(passphrase);
  final blob = (await backend.read())!;
  final doc = SyncDocument.parse(await cipher.open(blob.bytes));
  doc.records.addAll(records);
  await backend.write(Uint8List.fromList(await cipher.seal(doc.toJson(writtenBy: 'other-device', writtenAt: DateTime.utc(2026, 11, 1)))), ifMatch: blob.version);
}

Future<Map<String, dynamic>> collectMediaHostsOf(SyncTestDevice d) async {
  final s = d.settings;
  Future<Map<String, Object?>?> slot(MediaHostSlot slot) async {
    final id = slot.idIn(s);
    return id == null ? null : {'id': id, 'config': slot.configIn(s), 'secrets': await d.secrets.read(slot.secretsKey)};
  }

  return {'main': await slot(MediaHostSlot.main), 'fallback': await slot(MediaHostSlot.fallback)};
}
