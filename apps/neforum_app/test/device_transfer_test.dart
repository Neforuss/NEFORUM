import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/media_host_config.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'sync_fixtures.dart';

void main() {
  test('only shareable settings travel; device-only ones stay', () {
    const here = AppSettings(startAtLogin: true, minimizeToTray: false, browserExtension: false, onboarded: true, photoFit: PhotoFitMode.crop);
    final out = exportableSettings(here);
    expect(out['photoFit'], 'crop');
    for (final k in ['startAtLogin', 'minimizeToTray', 'browserExtension', 'onboarded', 'mediaHostId', 'movedAccountIds']) {
      expect(out.containsKey(k), isFalse, reason: k);
    }
    const there = AppSettings(startAtLogin: false, minimizeToTray: true);
    final merged = withImportedSettings(there, {...out, 'startAtLogin': true});
    expect(merged.photoFit, PhotoFitMode.crop);
    expect(merged.startAtLogin, isFalse, reason: 'a device-only key in the file is ignored');
    expect(merged.minimizeToTray, isTrue);
  });

  test('media hosts travel with their keys', () async {
    final from = InMemorySecretStore();
    var s = const AppSettings();
    s = await storeMediaHost(s, from, 'litterbox', const {});
    final hosts = await collectMediaHosts(s, from);
    expect((hosts['main'] as Map)['id'], 'litterbox');
    expect(mediaHostsIn(hosts).single.$2, 'litterbox');

    final to = InMemorySecretStore();
    final applied = await withImportedMediaHosts(const AppSettings(), to, hosts);
    expect(applied.mediaHostId, 'litterbox');
  });

  group('settings classification (1.3.5)', () {
    final defaults = const AppSettings().toJson();
    final full = populatedSettings().toJson();

    test('every setting is shared or device-only: never both, never neither, each device-only one with a reason', () {
      final keys = {...defaults.keys, ...full.keys};
      final deviceOnly = kDeviceOnlySettings.keys.toSet();
      expect(kExportableSettings.intersection(deviceOnly), isEmpty, reason: 'in both lists');
      expect(keys.difference({...kExportableSettings, ...deviceOnly}), isEmpty, reason: 'in neither list: decide whether it travels');
      expect({...kExportableSettings, ...deviceOnly}.difference(keys), isEmpty, reason: 'a listed key that is no setting');
      for (final e in kDeviceOnlySettings.entries) {
        expect(e.value.trim(), isNotEmpty, reason: '${e.key} needs its one-line reason');
      }
    });

    test('the populated fixture changes every setting, so the parity test covers each one', () {
      for (final k in full.keys) {
        expect(full[k], isNot(equals(defaults[k])), reason: k);
      }
    });

    test('sync carries every shared setting with a value, and each default puts the setting back', () {
      final synced = syncedSettings(const AppSettings());
      expect(synced.keys.toSet(), kExportableSettings);
      for (final k in kExportableSettings) {
        expect(defaults.containsKey(k) || kSettingDefaultsLeftOut.containsKey(k), isTrue, reason: '$k is left out of toJson at its default: add it to kSettingDefaultsLeftOut');
      }
      expect(kSettingDefaultsLeftOut.keys.toSet().difference(kExportableSettings), isEmpty);
      final populated = populatedSettings();
      for (final k in kExportableSettings) {
        expect(syncedSettings(withImportedSettings(populated, {k: synced[k]}))[k], synced[k], reason: '$k back to its default');
      }
      final rebuilt = withImportedSettings(const AppSettings(), syncedSettings(populated));
      expect(syncedSettings(rebuilt), syncedSettings(populated), reason: 'every shared setting survives the trip');
    });

    test('media hosts on a first sync: the winning side per slot, the other side in an empty slot', () {
      const main = {'id': 's3', 'config': {}, 'secrets': {'secretAccessKey': 'fake'}};
      const other = {'id': 'catbox', 'config': {}, 'secrets': {}};
      const fallback = {'id': 'webdav', 'config': {}, 'secrets': {'password': 'fake'}};
      expect(mergeMediaHostsOnJoin({'main': main, 'fallback': null}, {'main': other, 'fallback': fallback}, hereWins: true), {'main': main, 'fallback': fallback});
      expect(mergeMediaHostsOnJoin({'main': main, 'fallback': null}, {'main': other, 'fallback': fallback}, hereWins: false), {'main': other, 'fallback': fallback});
      expect(mergeMediaHostsOnJoin(null, {'main': other, 'fallback': null}, hereWins: true), {'main': other, 'fallback': null},
          reason: 'a device with no host takes nothing away');
      expect(mergeMediaHostsOnJoin({'main': main, 'fallback': null}, {'main': other, 'fallback': null}, hereWins: false), {'main': other, 'fallback': main},
          reason: "the losing side's host moves to the empty slot instead of being dropped");
      expect(mergeMediaHostsOnJoin({'main': other, 'fallback': null}, {'main': other, 'fallback': null}, hereWins: false), {'main': other, 'fallback': null},
          reason: 'one host is not kept twice');
    });

    test('what a first sync does to one side\'s media hosts, named exactly', () {
      const s3 = {'id': 's3', 'config': {}, 'secrets': {'secretAccessKey': 'fake'}};
      const catbox = {'id': 'catbox', 'config': {}, 'secrets': {}};
      const litterbox = {'id': 'litterbox', 'config': {'time': '72h'}, 'secrets': {}};
      final moved = mediaHostChanges({'main': s3, 'fallback': null}, {'main': catbox, 'fallback': s3});
      expect(moved.arrived, [(slot: 'main', id: 'catbox')]);
      expect(moved.moved, [(host: (slot: 'main', id: 's3'), to: 'fallback')]);
      expect(moved.removed, isEmpty);
      final replaced = mediaHostChanges({'main': s3, 'fallback': null}, {'main': catbox, 'fallback': litterbox});
      expect(replaced.arrived.map((h) => h.id), ['catbox', 'litterbox']);
      expect(replaced.removed, [(host: (slot: 'main', id: 's3'), replacedBy: 'catbox')]);
      final unchanged = mediaHostChanges({'main': s3, 'fallback': null}, {'main': s3, 'fallback': litterbox});
      expect(unchanged.arrived, [(slot: 'fallback', id: 'litterbox')], reason: 'the host this side already had does not count as arriving');
      expect(unchanged.removed, isEmpty);
    });
  });

  test('unknown media hosts in a file are ignored', () {
    expect(mediaHostsIn({'main': {'id': 'not-a-host'}, 'fallback': null}), isEmpty);
    expect(mediaHostsIn(null), isEmpty);
  });

  test('a real backup opens with the passphrase and not without it', () async {
    final payload = await collectBackup(
      accounts: InMemoryAccountRepository()..upsert(ConnectedAccount(id: 'mastodon:1', platformId: 'mastodon', tier: PlatformTier.openApi, displayName: 'me', createdAt: DateTime(2026))),
      posts: InMemoryPostRepository(),
      secrets: InMemorySecretStore()..write('mastodon:1', {'access_token': 'tok'}),
      mode: BackupMode.copy,
      device: const BackupDevice(platform: 'Windows', appVersion: 'test'),
      now: DateTime(2026, 10, 19),
    );
    final passphrase = generatePassphrase();
    final bytes = await encryptBackup(payload, passphrase);
    final opened = await openDeviceBackup(bytes, passphrase);
    expect(opened.accounts.single.secrets, {'access_token': 'tok'});
    await expectLater(openDeviceBackup(bytes, 'nope nope nope'), throwsA(isA<BackupException>()));
    expect(backupFileName(DateTime(2026, 10, 19)), endsWith('-2026-10-19.neforumbackup'));
  });
}
