import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/cloud_sync.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => const SizedBox();
}

/// One device: its data, keychain and settings, syncing through [folder].
class _Device {
  _Device(String folder, {AppSettings? settings})
      : settings = (settings ?? const AppSettings()).copyWith(syncProviderId: 'onedrive', syncConfig: {'folder': folder}) {
    sync = CloudSync(
      storage: storage,
      accounts: accounts,
      posts: posts,
      secrets: secrets,
      http: NeforumHttp(),
      settings: () => this.settings,
      saveSettings: (s) async => this.settings = s,
    );
  }

  final storage = _MemoryStorage();
  final accounts = InMemoryAccountRepository();
  final posts = InMemoryPostRepository();
  final secrets = InMemorySecretStore();
  AppSettings settings;
  late final CloudSync sync;
}

void main() {
  test('the storage settings build the right backend, and nothing when incomplete', () {
    final http = NeforumHttp();
    expect(buildSyncBackend(const AppSettings(), const {}, http), isNull);
    expect(buildSyncBackend(const AppSettings(syncProviderId: 'dropbox', syncConfig: {'folder': 'D:/Dropbox/NEFORUM'}), const {}, http), isA<FolderSyncBackend>());
    const dav = AppSettings(syncProviderId: 'nextcloud', syncConfig: {'url': 'https://cloud.example.com/remote.php/dav/files/u/NEFORUM', 'username': 'u'});
    expect(buildSyncBackend(dav, const {}, http), isNull, reason: 'no password');
    expect(buildSyncBackend(dav, const {'password': 'app'}, http), isA<WebDavSyncBackend>());
    const r2 = AppSettings(syncProviderId: 'r2', syncConfig: {'endpoint': 'https://acc.r2.cloudflarestorage.com', 'bucket': 'b', 'accessKeyId': 'k'});
    final s3 = buildSyncBackend(r2, const {'secretAccessKey': 's'}, http)! as S3SyncBackend;
    expect(s3.objectUri(s3.key).host, 'acc.r2.cloudflarestorage.com');
  });

  test('sync settings stay on the device and survive a round trip', () {
    const s = AppSettings(syncProviderId: 'koofr', syncConfig: {'url': 'https://app.koofr.net/dav/Koofr/NEFORUM', 'username': 'me@example.com'});
    final back = AppSettings.fromJson(s.toJson());
    expect(back.syncProviderId, 'koofr');
    expect(back.syncConfig['username'], 'me@example.com');
    expect(back.copyWith(clearSync: true).syncOn, isFalse);
  });

  test('two devices on one synced folder share accounts, keys, posts and settings', () async {
    final dir = await Directory.systemTemp.createTemp('neforum-cloud-sync-');
    addTearDown(() => dir.delete(recursive: true));
    final passphrase = generatePassphrase();

    final a = _Device(dir.path, settings: const AppSettings(textCardFont: TextCardFont.arial, startAtLogin: true));
    await a.secrets.write(kSyncSecretsKey, {'passphrase': passphrase});
    await a.accounts.upsert(ConnectedAccount(id: 'mastodon:1', platformId: 'mastodon', tier: PlatformTier.openApi, displayName: 'me', createdAt: DateTime(2026)));
    await a.secrets.write('mastodon:1', {'access_token': 'tok'});
    await a.posts.upsert(Post(
      id: 'sched',
      text: 'later',
      status: PostStatus.scheduled,
      scheduledAt: DateTime.now().subtract(const Duration(minutes: 1)),
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026, 10, 20),
      media: const [MediaAttachment(id: 'm', path: '/only/on/device/a.jpg', mimeType: 'image/jpeg', sizeBytes: 1)],
      targets: const [PostTarget(accountId: 'mastodon:1')],
    ));
    await a.sync.start(background: true);
    expect(a.sync.active, isTrue);
    expect(await a.sync.syncNow(), isNotNull, reason: a.sync.status.value.message);
    expect(File('${dir.path}/$kSyncFileName').existsSync(), isTrue);

    final b = _Device(dir.path);
    await b.secrets.write(kSyncSecretsKey, {'passphrase': passphrase});
    await b.sync.start(background: true);
    final r = await b.sync.syncNow();
    expect(r, isNotNull, reason: b.sync.status.value.message);
    expect((await b.accounts.get('mastodon:1'))?.displayName, 'me');
    expect(await b.secrets.read('mastodon:1'), {'access_token': 'tok'});
    expect(b.settings.textCardFont, TextCardFont.arial);
    expect(b.settings.startAtLogin, isFalse, reason: 'device-only settings stay put');
    expect(b.sync.status.value.devices.length, 2);

    // The post was scheduled on A, which has its photo: B leaves it alone.
    final onB = (await b.posts.get('sched'))!;
    expect(await b.sync.mayPublish(onB), isFalse);
    expect(await a.sync.mayPublish((await a.posts.get('sched'))!), isTrue);

    a.sync.dispose();
    b.sync.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a wrong passphrase shows a clear message', () async {
    final dir = await Directory.systemTemp.createTemp('neforum-cloud-sync-');
    addTearDown(() => dir.delete(recursive: true));
    final a = _Device(dir.path);
    await a.secrets.write(kSyncSecretsKey, {'passphrase': 'the right passphrase'});
    await a.sync.start(background: true);
    await a.sync.syncNow();
    final b = _Device(dir.path);
    await b.secrets.write(kSyncSecretsKey, {'passphrase': 'a different passphrase'});
    await b.sync.start(background: true);
    expect(await b.sync.syncNow(), isNull);
    expect(b.sync.status.value.phase, CloudSyncPhase.error);
    expect(b.sync.status.value.message, contains('passphrase'));
    a.sync.dispose();
    b.sync.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
