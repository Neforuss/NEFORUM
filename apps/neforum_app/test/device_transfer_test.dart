import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/media_host_config.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

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
