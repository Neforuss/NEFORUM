import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/files_app_folder.dart';
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
    expect(buildSyncBackend(const AppSettings(syncProviderId: 'dropbox', syncConfig: {'folder': 'D:/Dropbox/NEFORUM'}), const {}, http, filesApp: false),
        isA<FolderSyncBackend>());
    const dav = AppSettings(syncProviderId: 'nextcloud', syncConfig: {'url': 'https://cloud.example.com/remote.php/dav/files/u/NEFORUM', 'username': 'u'});
    expect(buildSyncBackend(dav, const {}, http), isNull, reason: 'no password');
    expect(buildSyncBackend(dav, const {'password': 'app'}, http), isA<WebDavSyncBackend>());
    const r2 = AppSettings(syncProviderId: 'r2', syncConfig: {'endpoint': 'https://acc.r2.cloudflarestorage.com', 'bucket': 'b', 'accessKeyId': 'k'});
    final s3 = buildSyncBackend(r2, const {'secretAccessKey': 's'}, http)! as S3SyncBackend;
    expect(s3.objectUri(s3.key).host, 'acc.r2.cloudflarestorage.com');
  });

  test('on an iPhone or iPad a folder is a Files-app location kept by its bookmark', () {
    final http = NeforumHttp();
    const onPhone = AppSettings(syncProviderId: 'icloud', syncConfig: {'folder': 'NEFORUM', 'bookmark': 'Ym9va21hcms='});
    final b = buildSyncBackend(onPhone, const {}, http, filesApp: true);
    expect(b, isA<FilesAppSyncBackend>());
    expect(b!.label, 'NEFORUM');
    expect(buildSyncBackend(const AppSettings(syncProviderId: 'onedrive', syncConfig: {'folder': 'NEFORUM'}), const {}, http, filesApp: true), isNull,
        reason: 'no bookmark: the folder must be picked again');
  });

  group('Files-app folder (iPhone, iPad)', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('neforum/syncfolder');
    final files = <String, Uint8List>{};
    final versions = <String, String>{};
    var tick = 0;
    final calls = <String>[];

    setUp(() {
      files.clear();
      versions.clear();
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        final a = Map<String, Object?>.from(call.arguments as Map);
        expect(a['bookmark'], 'bm');
        final name = a['name'] as String? ?? '';
        calls.add('${call.method} $name');
        switch (call.method) {
          case 'read':
            return files.containsKey(name) ? {'bytes': files[name], 'version': versions[name]} : null;
          case 'write':
            if (a['force'] != true && versions[name] != a['ifMatch']) throw PlatformException(code: 'conflict');
            files[name] = a['bytes']! as Uint8List;
            return versions[name] = 'v${++tick}';
          case 'list':
            return files.keys.toList();
          case 'delete':
            files.remove(name);
            versions.remove(name);
            return null;
        }
        return null;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    test('reads, writes only over the version it read, merges conflict copies, checks with a probe', () async {
      final b = FilesAppSyncBackend('bm', folderName: 'NEFORUM');
      expect(await b.read(), isNull);
      final v1 = await b.write(Uint8List.fromList([1]), ifMatch: null);
      await expectLater(b.write(Uint8List.fromList([2]), ifMatch: null), throwsA(isA<SyncConflict>()));
      final blob = await b.read();
      expect(blob!.bytes, [1]);
      expect(blob.version, v1);
      expect(await b.write(Uint8List.fromList([3]), ifMatch: v1), isNot(v1));

      files['NEFORUM (1).neforumsync'] = Uint8List.fromList([9]);
      files['notes.txt'] = Uint8List.fromList([0]);
      final copies = await b.conflictCopies();
      expect(copies.map((c) => c.name), ['NEFORUM (1).neforumsync']);
      await b.removeConflictCopy(copies.single);
      expect(files.containsKey('NEFORUM (1).neforumsync'), isFalse);

      await b.check();
      expect(calls, containsAllInOrder(['write .NEFORUM.neforumsync.check', 'delete .NEFORUM.neforumsync.check']));
      expect(files.keys, isNot(contains('.NEFORUM.neforumsync.check')));
    });

    test('a picked sync file (Google Drive, OneDrive): read and written in place, empty means not made yet', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        final a = Map<String, Object?>.from(call.arguments as Map);
        expect(a['file'], isTrue, reason: 'the bookmark is the file itself');
        calls.add(call.method);
        switch (call.method) {
          case 'read':
            final bytes = files['picked'];
            return bytes == null || bytes.isEmpty ? null : {'bytes': bytes, 'version': versions['picked']};
          case 'write':
            final current = (files['picked']?.isEmpty ?? true) ? null : versions['picked'];
            if (a['force'] != true && current != a['ifMatch']) throw PlatformException(code: 'conflict');
            files['picked'] = a['bytes']! as Uint8List;
            return versions['picked'] = 'v${++tick}';
          case 'list':
            return <String>[];
        }
        return null;
      });
      files['picked'] = Uint8List(0); // "Create the sync file" made an empty one
      final b = FilesAppSyncBackend('bm', folderName: 'NEFORUM.neforumsync', isFile: true);
      await b.check();
      expect(await b.read(), isNull, reason: 'an empty file is a sync file not written yet');
      final v = await b.write(Uint8List.fromList([5]), ifMatch: null);
      expect((await b.read())!.version, v);
      expect(await b.conflictCopies(), isEmpty);
      expect(calls, isNot(contains('list')), reason: 'no folder access for a picked file');
      final settings = const AppSettings(syncProviderId: 'googledrive', syncConfig: {'folder': 'NEFORUM.neforumsync', 'bookmark': 'bm', 'target': 'file'});
      expect((buildSyncBackend(settings, const {}, NeforumHttp(), filesApp: true)! as FilesAppSyncBackend).isFile, isTrue);
    });

    test('a sync file tapped in the Files app is taken once; a copy has no bookmark', () async {
      final queue = <Map<String, Object?>?>[
        {'name': 'NEFORUM.neforumsync', 'inPlace': true, 'bookmark': 'bm'},
        null,
        {'name': 'NEFORUM.neforumsync', 'inPlace': false},
      ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'takeOpened');
        return queue.removeAt(0);
      });
      final first = await FilesAppFolder.takeOpened();
      expect(first?.bookmark, 'bm');
      expect(first?.name, 'NEFORUM.neforumsync');
      expect(await FilesAppFolder.takeOpened(), isNull);
      expect((await FilesAppFolder.takeOpened())?.bookmark, isNull, reason: 'a copy cannot be synced');
    });

    test('a folder iOS no longer lets NEFORUM open asks to pick it again', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'bookmark', message: 'Choose the folder again.'));
      final b = FilesAppSyncBackend('bm', folderName: 'NEFORUM');
      await expectLater(b.read(), throwsA(isA<SyncBackendException>().having((e) => e.message, 'message', contains('again'))));
    });
  });

  test('sync settings stay on the device and survive a round trip', () {
    const s = AppSettings(syncProviderId: 'koofr', syncConfig: {'url': 'https://app.koofr.net/dav/Koofr/NEFORUM', 'username': 'me@example.com'});
    final back = AppSettings.fromJson(s.toJson());
    expect(back.syncProviderId, 'koofr');
    expect(back.syncConfig['username'], 'me@example.com');
    expect(back.copyWith(clearSync: true).syncOn, isFalse);
  });

  test('two devices on one synced folder share accounts, keys, posts and settings', () async {
    // A computer: flutter_test pretends to be Android, where a folder is a
    // picked location instead.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
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
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
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
