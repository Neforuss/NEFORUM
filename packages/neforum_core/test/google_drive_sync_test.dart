import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

const _folderMime = 'application/vnd.google-apps.folder';

/// A revision of a file's content in [_FakeDrive].
class _Revision {
  _Revision(this.id, this.bytes);
  final String id;
  final Uint8List bytes;
  bool keepForever = false;
}

/// A file or folder in [_FakeDrive].
class _Item {
  _Item(this.id, this.name, this.mimeType, this.parent, this.created);
  final String id;
  final String name;
  final String mimeType;
  String parent;
  final DateTime created;
  int version = 1;
  bool trashed = false;
  Map<String, Object?> appProperties = const {};

  /// The content's revisions, oldest first; the last one is the head.
  /// Folders have none.
  final revisions = <_Revision>[];

  Uint8List get bytes => revisions.isEmpty ? Uint8List(0) : revisions.last.bytes;
}

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=UTF-8'});

http.Response _googleError(int status, String reason, String message) => _json({
      'error': {
        'code': status,
        'message': message,
        'errors': [
          {'message': message, 'domain': 'global', 'reason': reason},
        ],
      },
    }, status);

/// An in-memory Google Drive answering the Drive API v3 calls the backend
/// makes: files.list (searches by tag, name, parent and type), files.create
/// (folder JSON and multipart upload), files.update (media upload, and
/// moving to the trash), files.get (metadata and alt=media), files.delete,
/// revisions.list (paged), revisions.get (alt=media) and revisions.update
/// (keepForever).
class _FakeDrive {
  final items = <String, _Item>{};
  final calls = <String>[];

  /// The access token the fake accepts.
  String validToken = 'token-1';

  /// Answers instead of the fake while it returns a response.
  http.Response? Function(http.Request r)? intercept;

  /// Runs once, before the next multipart upload is stored.
  Future<void> Function()? beforeNextCreate;

  /// Runs once, before the next upload over an existing file is stored.
  Future<void> Function()? beforeNextUpdate;

  /// The most revisions one page of revisions.list holds.
  int revisionPageSize = 1000;

  var _ids = 0;
  var _revs = 0;
  var _ticks = 0;

  late final MockClient client = MockClient(_handle);

  /// Whether [i] is in the trash, on its own or with a folder it is in.
  bool inTrash(_Item i) {
    for (_Item? at = i; at != null; at = items[at.parent]) {
      if (at.trashed) return true;
    }
    return false;
  }

  /// Folders and files outside the trash.
  Iterable<_Item> get folders => items.values.where((i) => i.mimeType == _folderMime && !inTrash(i));
  Iterable<_Item> get files => items.values.where((i) => i.mimeType != _folderMime && !inTrash(i));

  /// Files in the trash.
  Iterable<_Item> get trashedFiles => items.values.where((i) => i.mimeType != _folderMime && inTrash(i));

  _Item add(String name, String parent,
      {String mimeType = 'application/octet-stream', List<int> bytes = const [], Map<String, Object?> appProperties = const {}}) {
    final item = _Item('id${++_ids}', name, mimeType, parent, DateTime.utc(2026, 10, 20).add(Duration(seconds: ++_ticks)))..appProperties = appProperties;
    if (mimeType != _folderMime) _newRevision(item, Uint8List.fromList(bytes));
    items[item.id] = item;
    return item;
  }

  /// A sync file, tagged the way the backend tags the files it creates.
  _Item addSyncFile(String parent, {List<int> bytes = const []}) => add(kSyncFileName, parent, bytes: bytes, appProperties: const {'neforum': 'sync'});

  void _newRevision(_Item item, Uint8List bytes) => item.revisions.add(_Revision('rev${++_revs}', bytes));

  static http.Response _written(_Item item) => _json({'id': item.id, 'version': '${item.version}', 'headRevisionId': item.revisions.last.id});

  Future<http.Response> _handle(http.Request r) async {
    calls.add('${r.method} ${r.url.path}');
    final injected = intercept?.call(r);
    if (injected != null) return injected;
    if (r.headers['Authorization'] != 'Bearer $validToken') return _googleError(401, 'authError', 'Invalid Credentials');
    final path = r.url.path;
    final query = r.url.queryParameters;
    if (path == '/drive/v3/files' && r.method == 'GET') return _list(query);
    if (path == '/drive/v3/files' && r.method == 'POST') {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final item = add(body['name'] as String, (body['parents'] as List).single as String,
          mimeType: body['mimeType'] as String, appProperties: Map<String, Object?>.from(body['appProperties'] as Map? ?? const <String, Object?>{}));
      return _json({'id': item.id});
    }
    if (path == '/upload/drive/v3/files' && r.method == 'POST' && query['uploadType'] == 'multipart') {
      expect(query['fields'], 'id,version,headRevisionId');
      final hook = beforeNextCreate;
      beforeNextCreate = null;
      if (hook != null) await hook();
      final (meta, bytes) = _multipart(r);
      final item = add(meta['name'] as String, (meta['parents'] as List).single as String,
          mimeType: meta['mimeType'] as String, bytes: bytes, appProperties: Map<String, Object?>.from(meta['appProperties'] as Map));
      return _written(item);
    }
    final revision = _revisionPath.firstMatch(path);
    if (revision != null) return _revision(r, items[revision.group(1)], revision.group(2));
    final item = items[path.split('/').last];
    if (item == null) return _googleError(404, 'notFound', 'File not found: ${path.split('/').last}.');
    final api = path.startsWith('/drive/v3/files/'), upload = path.startsWith('/upload/drive/v3/files/');
    if (r.method == 'GET' && api && query['alt'] == 'media') return http.Response.bytes(item.bytes, 200);
    if (r.method == 'GET' && api) {
      expect(query['fields'], 'id,trashed');
      return _json({'id': item.id, 'trashed': inTrash(item)});
    }
    if (r.method == 'PATCH' && upload && query['uploadType'] == 'media') {
      expect(r.headers['Content-Type'], 'application/octet-stream');
      expect(query['fields'], 'id,version,headRevisionId');
      final hook = beforeNextUpdate;
      beforeNextUpdate = null;
      if (hook != null) await hook();
      _newRevision(item, r.bodyBytes);
      item.version += 3; // grows, not always by one
      return _written(item);
    }
    if (r.method == 'PATCH' && api) {
      expect(jsonDecode(r.body), {'trashed': true});
      item.trashed = true;
      return _json({'id': item.id});
    }
    if (r.method == 'DELETE' && api) {
      items.remove(item.id);
      return http.Response('', 204);
    }
    return _googleError(400, 'badRequest', 'Unexpected ${r.method} ${r.url}');
  }

  static final _revisionPath = RegExp(r'^/drive/v3/files/([^/]+)/revisions(?:/([^/]+))?$');

  http.Response _revision(http.Request r, _Item? item, String? id) {
    if (item == null || item.mimeType == _folderMime) return _googleError(404, 'notFound', 'File not found.');
    final query = r.url.queryParameters;
    if (id == null && r.method == 'GET') {
      expect(query['fields'], 'revisions(id),nextPageToken');
      final start = int.parse(query['pageToken'] ?? '0');
      final page = item.revisions.skip(start).take(min(int.parse(query['pageSize']!), revisionPageSize)).toList();
      final next = start + page.length;
      return _json({
        'revisions': [
          for (final v in page) {'id': v.id},
        ],
        if (next < item.revisions.length) 'nextPageToken': '$next',
      });
    }
    final matching = item.revisions.where((v) => v.id == id);
    if (matching.isEmpty) return _googleError(404, 'notFound', 'Revision not found: $id.');
    final rev = matching.single;
    if (r.method == 'GET' && query['alt'] == 'media') return http.Response.bytes(rev.bytes, 200);
    if (r.method == 'PATCH') {
      expect(jsonDecode(r.body), {'keepForever': true});
      rev.keepForever = true;
      return _json({'id': rev.id, 'keepForever': true});
    }
    return _googleError(400, 'badRequest', 'Unexpected ${r.method} ${r.url}');
  }

  static final _literal = r"'((?:[^'\\]|\\.)*)'";

  /// One term of a files.list search; terms are joined by ` and `.
  static final _term = RegExp('(mimeType|name)=$_literal|appProperties has \\{ key=$_literal and value=$_literal \\}|$_literal in parents|trashed=false');

  static String _unescape(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);

  http.Response _list(Map<String, String> query) {
    final q = query['q']!;
    expect(query['orderBy'], 'createdTime');
    final tests = <bool Function(_Item)>[];
    var rest = q;
    while (true) {
      final m = _term.matchAsPrefix(rest);
      if (m == null) return _googleError(400, 'invalid', 'Invalid Value: $q');
      final field = m.group(1), key = m.group(3), parent = m.group(5);
      if (field != null) {
        final value = _unescape(m.group(2)!);
        tests.add((i) => (field == 'name' ? i.name : i.mimeType) == value);
      } else if (key != null) {
        final k = _unescape(key), value = _unescape(m.group(4)!);
        tests.add((i) => i.appProperties[k] == value);
      } else if (parent != null) {
        final p = _unescape(parent);
        tests.add((i) => i.parent == p);
      } else {
        tests.add((i) => !inTrash(i));
      }
      rest = rest.substring(m.end);
      if (rest.isEmpty) break;
      if (!rest.startsWith(' and ')) return _googleError(400, 'invalid', 'Invalid Value: $q');
      rest = rest.substring(5);
    }
    final folderSearch = q.startsWith("mimeType='$_folderMime'");
    expect(query['fields'], folderSearch ? 'files(id,createdTime)' : 'files(id,version,headRevisionId,createdTime,size)');
    final sorted = items.values.where((i) => tests.every((t) => t(i))).toList()..sort((a, b) => a.created.compareTo(b.created));
    return _json({
      'files': [
        for (final i in sorted)
          {
            'id': i.id,
            'createdTime': i.created.toIso8601String(),
            if (i.mimeType != _folderMime) 'version': '${i.version}',
            if (i.mimeType != _folderMime) 'headRevisionId': i.revisions.last.id,
            if (i.mimeType != _folderMime) 'size': '${i.bytes.length}',
          },
      ],
    });
  }

  /// The metadata and the content of a `multipart/related` upload.
  static (Map<String, dynamic>, Uint8List) _multipart(http.Request r) {
    final type = r.headers['Content-Type']!;
    expect(type, startsWith('multipart/related; boundary='));
    final boundary = type.substring(type.indexOf('boundary=') + 9);
    final parts = latin1.decode(r.bodyBytes).split('--$boundary').skip(1).where((p) => !p.startsWith('--')).map((p) {
      final content = p.substring(p.indexOf('\r\n\r\n') + 4);
      return content.endsWith('\r\n') ? content.substring(0, content.length - 2) : content;
    }).toList();
    expect(parts, hasLength(2));
    final meta = jsonDecode(utf8.decode(latin1.encode(parts[0]))) as Map<String, dynamic>;
    return (meta, Uint8List.fromList(latin1.encode(parts[1])));
  }
}

GoogleDriveSyncBackend _backend(_FakeDrive drive, {String? folderName, Future<String> Function({bool forceRefresh})? token}) => GoogleDriveSyncBackend(
      http: NeforumHttp(client: drive.client, maxRetries: 0),
      token: token ?? ({bool forceRefresh = false}) async => drive.validToken,
      folderName: folderName ?? 'NEFORUM Sync',
    );

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

Matcher _syncError({required bool temporary, Object? message}) => isA<SyncBackendException>()
    .having((e) => e.temporary, 'temporary', temporary)
    .having((e) => e.message, 'message', message ?? anything);

Post _post(String id, {String text = 'hello', DateTime? updatedAt}) =>
    Post(id: id, text: text, createdAt: DateTime.utc(2026, 10, 1), updatedAt: updatedAt ?? DateTime.utc(2026, 10, 20, 11));

/// A device syncing through Google Drive.
class _Device {
  _Device(String id, _FakeDrive drive, DateTime Function() clock) {
    engine = SyncEngine(
      backend: _backend(drive),
      cipher: BackupCipher('shared sync passphrase', params: BackupKdfParams.testing, minimum: BackupKdfParams.testing),
      deviceId: id,
      device: SyncDeviceInfo(label: id, platform: 'test', appVersion: '1.0.9', seenAt: DateTime.utc(2000)),
      sources: [AccountsSyncSource(accounts), PostsSyncSource(posts)],
      state: MemorySyncStateStore(),
      clock: clock,
      sleep: (_) async {},
    );
  }

  final accounts = InMemoryAccountRepository();
  final posts = InMemoryPostRepository();
  late final SyncEngine engine;

  Future<Set<String>> postIds() async => (await posts.all()).map((p) => p.id).toSet();
}

void main() {
  group('Google Drive backend', () {
    test('nothing there yet: read is null and nothing is created', () async {
      final drive = _FakeDrive();
      final gd = _backend(drive);
      expect(gd.label, 'Google Drive');
      expect(gd.atomicWrites, isFalse);
      expect(await gd.read(), isNull);
      expect(await gd.conflictCopies(), isEmpty);
      expect(drive.items, isEmpty);
      expect(drive.calls.where((c) => !c.startsWith('GET ')), isEmpty);
    });

    test('the first write creates the folder and the file; read returns the bytes and the version', () async {
      final drive = _FakeDrive();
      const name = r"Bob's \ NEFORUM";
      final gd = _backend(drive, folderName: name);
      final v1 = await gd.write(_bytes([1, 2, 3]), ifMatch: null);

      final folder = drive.folders.single;
      expect(folder.name, name, reason: 'quotes and backslashes are escaped in the search by name');
      expect(folder.parent, 'root');
      expect(folder.appProperties, {'neforum': 'syncFolder'});
      final file = drive.files.single;
      expect(file.name, kSyncFileName);
      expect(file.parent, folder.id);
      expect(file.mimeType, 'application/octet-stream');
      expect(file.appProperties, {'neforum': 'sync'});
      expect(file.bytes, [1, 2, 3]);
      expect(v1, isNotNull);
      expect(v1, contains('${file.version}'));

      final blob = await gd.read();
      expect(blob!.bytes, [1, 2, 3]);
      expect(blob.version, v1);

      // Another device finds the same file by its tag.
      final other = _backend(drive, folderName: name);
      expect((await other.read())!.version, v1);
      expect(drive.folders, hasLength(1));
    });

    test('a stale version is a conflict; the current one updates the file in place', () async {
      final drive = _FakeDrive();
      final gd = _backend(drive);
      final v1 = await gd.write(_bytes([1]), ifMatch: null);
      await expectLater(gd.write(_bytes([2]), ifMatch: null), throwsA(isA<SyncConflict>()));
      await expectLater(gd.write(_bytes([2]), ifMatch: 'stale'), throwsA(isA<SyncConflict>()));

      final v2 = await gd.write(_bytes([4, 5]), ifMatch: v1);
      expect(v2, isNot(v1));
      expect(drive.files, hasLength(1));
      expect(drive.calls, contains('PATCH /upload/drive/v3/files/${drive.files.single.id}'));
      expect(drive.calls, contains('GET /drive/v3/files/${drive.files.single.id}/revisions'), reason: 'every update checks what it replaced');
      final blob = await gd.read();
      expect(blob!.bytes, [4, 5]);
      expect(blob.version, v2);
      await expectLater(gd.write(_bytes([6]), ifMatch: v1), throwsA(isA<SyncConflict>()));
      expect(await gd.conflictCopies(), isEmpty, reason: 'nobody else wrote');
    });

    test('an empty file counts as no file and is written over', () async {
      final drive = _FakeDrive();
      final folder = drive.add('NEFORUM Sync', 'root', mimeType: _folderMime);
      final empty = drive.addSyncFile(folder.id);
      final gd = _backend(drive);
      expect(await gd.read(), isNull);
      final v = await gd.write(_bytes([7]), ifMatch: null);
      expect(drive.files.single.id, empty.id);
      expect((await gd.read())!.version, v);
    });

    test('duplicates: the oldest sync file is the main one wherever the others are; merged ones go to the trash', () async {
      final drive = _FakeDrive();
      final folder = drive.add('NEFORUM Sync', 'root', mimeType: _folderMime);
      final elsewhere = drive.add('Elsewhere', 'root', mimeType: _folderMime);
      final main = drive.addSyncFile(folder.id, bytes: [1]);
      final dup = drive.addSyncFile(elsewhere.id, bytes: [2]);
      final untagged = drive.add(kSyncFileName, folder.id, bytes: [3]);
      drive.add('NEFORUM (1).neforumsync', folder.id, bytes: [4]);
      final gd = _backend(drive);

      final blob = await gd.read();
      expect(blob!.bytes, [1]);
      expect(blob.version, contains(main.id));
      final copies = await gd.conflictCopies();
      expect(copies.map((c) => c.name), ['gdrive:${dup.id}'], reason: 'only tagged files are sync files');
      expect(copies.single.bytes, [2]);

      // Only its own copies are touched, and nothing is deleted for good.
      await gd.removeConflictCopy(SyncSideCopy('NEFORUM (1).neforumsync', _bytes([4])));
      expect(drive.calls.where((c) => !c.startsWith('GET ')), isEmpty);
      await gd.removeConflictCopy(copies.single);
      expect(drive.calls.where((c) => !c.startsWith('GET ')), ['PATCH /drive/v3/files/${dup.id}']);
      expect(drive.items[dup.id]!.trashed, isTrue);
      expect(drive.trashedFiles.map((i) => i.id), [dup.id]);
      expect(drive.files.map((i) => i.id), containsAll([main.id, untagged.id]));
      expect(await gd.conflictCopies(), isEmpty);
      // Gone meanwhile (the trash was emptied): fine.
      drive.items.remove(dup.id);
      await gd.removeConflictCopy(copies.single);
      expect(drive.calls.where((c) => c.startsWith('DELETE')), isEmpty);
    });

    test('the sync file is found by its tag wherever it is moved; no second file is made', () async {
      final drive = _FakeDrive();
      final gd = _backend(drive);
      final v1 = await gd.write(_bytes([1]), ifMatch: null);
      final folder = drive.folders.single;
      final file = drive.files.single;

      // The folder moved out of My Drive's root, into another folder.
      final projects = drive.add('Projects', 'root', mimeType: _folderMime);
      folder.parent = projects.id;
      expect((await gd.read())!.version, v1);
      final other = _backend(drive);
      expect((await other.read())!.bytes, [1], reason: 'a device that never saw the folder finds the file too');
      final v2 = await other.write(_bytes([2]), ifMatch: v1);

      // The file moved out of the folder on its own.
      file.parent = projects.id;
      final v3 = await gd.write(_bytes([3]), ifMatch: v2);
      expect((await _backend(drive).read())!.version, v3);
      await gd.check();

      expect(drive.files.single.id, file.id);
      expect(drive.files.single.bytes, [3]);
      expect(drive.folders.map((f) => f.id), unorderedEquals([folder.id, projects.id]));
      expect(drive.calls.where((c) => c.startsWith('POST ')), ['POST /drive/v3/files', 'POST /upload/drive/v3/files'],
          reason: 'one folder and one file, made once');
    });

    test('a new sync file goes into the tagged folder, else a folder with the name anywhere', () async {
      // An earlier version's untagged folder, moved into another folder.
      var drive = _FakeDrive();
      final legacy = drive.add('NEFORUM Sync', drive.add('Projects', 'root', mimeType: _folderMime).id, mimeType: _folderMime);
      await _backend(drive).write(_bytes([1]), ifMatch: null);
      expect(drive.files.single.parent, legacy.id);
      expect(drive.folders, hasLength(2), reason: 'no folder made');

      // NEFORUM's tagged folder wins over a folder with the name, whatever it is called now.
      drive = _FakeDrive();
      drive.add('NEFORUM Sync', 'root', mimeType: _folderMime);
      final tagged = drive.add('Renamed', 'root', mimeType: _folderMime, appProperties: const {'neforum': 'syncFolder'});
      await _backend(drive).write(_bytes([1]), ifMatch: null);
      expect(drive.files.single.parent, tagged.id);
      expect(drive.folders, hasLength(2), reason: 'no folder made');
    });

    test("another device's write replaced unseen is offered before duplicates, then forgotten without touching Drive", () async {
      final drive = _FakeDrive()..revisionPageSize = 2;
      final folder = drive.add('NEFORUM Sync', 'root', mimeType: _folderMime);
      final main = drive.addSyncFile(folder.id, bytes: [1]);
      final dup = drive.addSyncFile(folder.id, bytes: [2]);
      final gd = _backend(drive);
      final other = _backend(drive);
      final v1 = (await gd.read())!.version;

      // Both devices pass the check at v1; the other device's upload lands first.
      drive.beforeNextUpdate = () async => other.write(_bytes([5]), ifMatch: v1);
      await expectLater(gd.write(_bytes([6]), ifMatch: v1), throwsA(isA<SyncConflict>()));
      expect(main.bytes, [6], reason: 'the write itself went through');
      final replaced = main.revisions[main.revisions.length - 2];
      expect(replaced.bytes, [5]);
      expect(replaced.keepForever, isFalse, reason: 'it could be read straight away');

      final copies = await gd.conflictCopies();
      expect(copies.map((c) => c.name), ['gdrive-rev:${main.id}:${replaced.id}', 'gdrive:${dup.id}']);
      expect(copies.first.bytes, [5]);
      expect(copies.last.bytes, [2]);
      expect((await gd.read())!.bytes, [6], reason: "read again, the file is this device's write");
      expect((await other.conflictCopies()).map((c) => c.name), ['gdrive:${dup.id}'], reason: 'the device that wrote first saw nothing wrong');

      drive.calls.clear();
      await gd.removeConflictCopy(copies.first);
      expect(drive.calls, isEmpty, reason: 'merged revisions are only forgotten');
      expect(main.revisions.map((v) => v.id), contains(replaced.id));
      expect((await gd.conflictCopies()).map((c) => c.name), ['gdrive:${dup.id}']);
    });

    test('every write between the checked revision and ours is merged in; without the checked one, the one just before ours', () async {
      final drive = _FakeDrive();
      final main = drive.addSyncFile(drive.add('NEFORUM Sync', 'root', mimeType: _folderMime).id, bytes: [1]);
      final gd = _backend(drive), b = _backend(drive), c = _backend(drive);

      var v = (await gd.read())!.version;
      drive.beforeNextUpdate = () async {
        final vb = await b.write(_bytes([2]), ifMatch: v);
        await c.write(_bytes([3]), ifMatch: vb);
      };
      await expectLater(gd.write(_bytes([4]), ifMatch: v), throwsA(isA<SyncConflict>()));
      var revs = main.revisions.map((r) => r.id).toList();
      expect(revs, hasLength(4));
      var copies = await gd.conflictCopies();
      expect(copies.map((x) => x.name), ['gdrive-rev:${main.id}:${revs[1]}', 'gdrive-rev:${main.id}:${revs[2]}']);
      expect(copies.map((x) => x.bytes), [
        [2],
        [3],
      ]);
      for (final copy in copies) {
        await gd.removeConflictCopy(copy);
      }
      expect(await gd.conflictCopies(), isEmpty);

      // Drive no longer lists the revision that was checked.
      v = (await gd.read())!.version;
      final checked = main.revisions.last.id;
      drive.beforeNextUpdate = () async {
        await b.write(_bytes([5]), ifMatch: v);
        main.revisions.removeWhere((r) => r.id == checked);
      };
      await expectLater(gd.write(_bytes([6]), ifMatch: v), throwsA(isA<SyncConflict>()));
      revs = main.revisions.map((r) => r.id).toList();
      copies = await gd.conflictCopies();
      expect(copies.map((x) => x.name), ['gdrive-rev:${main.id}:${revs[revs.length - 2]}']);
      expect(copies.single.bytes, [5]);
    });

    test('a replaced revision Drive does not hand over is kept forever and asked for again; revision listing errors', () async {
      final drive = _FakeDrive();
      final main = drive.addSyncFile(drive.add('NEFORUM Sync', 'root', mimeType: _folderMime).id, bytes: [1]);
      final gd = _backend(drive);
      final other = _backend(drive);

      // Refused once: kept forever, then handed over.
      var v = (await gd.read())!.version;
      var refusals = 1;
      drive.intercept = (r) => r.method == 'GET' && r.url.path.contains('/revisions/') && refusals-- > 0
          ? _googleError(403, 'forbidden', 'Only revisions kept forever can be downloaded.')
          : null;
      drive.beforeNextUpdate = () async => other.write(_bytes([5]), ifMatch: v);
      await expectLater(gd.write(_bytes([6]), ifMatch: v), throwsA(isA<SyncConflict>()));
      var replaced = main.revisions[main.revisions.length - 2];
      expect(replaced.keepForever, isTrue);
      expect(drive.calls, contains('PATCH /drive/v3/files/${main.id}/revisions/${replaced.id}'));
      final copy = (await gd.conflictCopies()).single;
      expect(copy.bytes, [5]);
      await gd.removeConflictCopy(copy);

      // Refused for good: logged, nothing to merge, but still read again.
      v = (await gd.read())!.version;
      drive.intercept = (r) => r.method == 'GET' && r.url.path.contains('/revisions/') ? _googleError(404, 'notFound', 'Revision not found.') : null;
      drive.beforeNextUpdate = () async => other.write(_bytes([7]), ifMatch: v);
      await expectLater(gd.write(_bytes([8]), ifMatch: v), throwsA(isA<SyncConflict>()));
      replaced = main.revisions[main.revisions.length - 2];
      expect(replaced.keepForever, isTrue);
      expect(await gd.conflictCopies(), isEmpty);
      expect(main.bytes, [8]);

      // Listing the revisions fails: worth another try, whatever Drive said.
      v = (await gd.read())!.version;
      drive.intercept =
          (r) => r.method == 'GET' && r.url.path.endsWith('/revisions') ? _googleError(403, 'forbidden', 'The user does not have sufficient permissions.') : null;
      await expectLater(gd.write(_bytes([9]), ifMatch: v), throwsA(_syncError(temporary: true, message: contains('revisions'))));

      // The file is gone: read again.
      v = (await gd.read())!.version;
      drive.intercept = (r) => r.method == 'GET' && r.url.path.endsWith('/revisions') ? _googleError(404, 'notFound', 'File not found.') : null;
      await expectLater(gd.write(_bytes([10]), ifMatch: v), throwsA(isA<SyncConflict>()));
      drive.intercept = null;
      expect(await gd.conflictCopies(), isEmpty);
    });

    test('a refused token is renewed once and the request sent again', () async {
      final drive = _FakeDrive()..validToken = 'fresh';
      var forced = 0;
      final gd = _backend(drive, token: ({bool forceRefresh = false}) async {
        if (forceRefresh) forced++;
        return forced > 0 ? 'fresh' : 'expired';
      });
      expect(await gd.read(), isNull);
      expect(forced, 1);
      expect(drive.calls, ['GET /drive/v3/files', 'GET /drive/v3/files']);

      // Still refused after renewing: an error, not a loop.
      drive.validToken = 'something else';
      drive.calls.clear();
      await expectLater(gd.read(), throwsA(_syncError(temporary: false, message: contains('sign in again'))));
      expect(forced, 2);
      expect(drive.calls, hasLength(2));
    });

    test('errors: Drive API not enabled, rate limits, outages, network', () async {
      final drive = _FakeDrive();
      final gd = _backend(drive);

      drive.intercept = (_) => _googleError(403, 'accessNotConfigured',
          'Google Drive API has not been used in project 1234 before or it is disabled. Enable it by visiting the API console, then retry.');
      await expectLater(gd.read(), throwsA(_syncError(temporary: false, message: contains('Enable the Google Drive API'))));

      drive.intercept = (_) => _googleError(403, 'userRateLimitExceeded', 'User rate limit exceeded.');
      await expectLater(gd.read(), throwsA(_syncError(temporary: true)));
      drive.intercept = (_) => _googleError(403, 'rateLimitExceeded', 'Rate limit exceeded.');
      await expectLater(gd.read(), throwsA(_syncError(temporary: true)));
      drive.intercept = (_) => _googleError(429, 'rateLimitExceeded', 'Too many requests.');
      await expectLater(gd.read(), throwsA(_syncError(temporary: true)));
      drive.intercept = (_) => http.Response('Backend Error', 503);
      await expectLater(gd.write(_bytes([1]), ifMatch: null), throwsA(_syncError(temporary: true)));
      drive.intercept = (_) => throw http.ClientException('Connection reset by peer');
      await expectLater(gd.check(), throwsA(_syncError(temporary: true, message: contains('Could not reach Google Drive'))));

      drive.intercept = (_) => _googleError(403, 'storageQuotaExceeded', 'The user has exceeded their Drive storage quota.');
      await expectLater(gd.write(_bytes([1]), ifMatch: null), throwsA(_syncError(temporary: false, message: contains('full'))));
      drive.intercept = (_) => _googleError(403, 'forbidden', 'The user does not have sufficient permissions for this file.');
      await expectLater(gd.read(), throwsA(_syncError(temporary: false, message: contains('sufficient permissions'))));
    });

    test('check finds or creates the folder and never writes the sync file', () async {
      final drive = _FakeDrive();
      final gd = _backend(drive);
      await gd.check();
      final folder = drive.folders.single;
      expect(folder.name, 'NEFORUM Sync');
      expect(drive.files, isEmpty);
      await gd.check();
      await _backend(drive).check();
      expect(drive.folders, hasLength(1));

      // The first write uses that folder.
      await gd.write(_bytes([1]), ifMatch: null);
      expect(drive.files.single.parent, folder.id);
      expect(drive.folders, hasLength(1));
    });

    test('a folder deleted or trashed meanwhile is not used for a new file', () async {
      final drive = _FakeDrive();
      final gd = _backend(drive);
      await gd.write(_bytes([1]), ifMatch: null);
      final old = drive.folders.single;
      drive.items.removeWhere((_, i) => i.id == old.id || i.parent == old.id);

      expect(await gd.read(), isNull);
      await gd.write(_bytes([2]), ifMatch: null);
      final folder = drive.folders.single;
      expect(folder.id, isNot(old.id));
      expect(drive.files.single.parent, folder.id);

      // Trashed with the file in it: the file counts as gone too.
      folder.trashed = true;
      expect(await gd.read(), isNull);
      await gd.write(_bytes([3]), ifMatch: null);
      expect(drive.folders.single.id, isNot(folder.id));
      expect(drive.files.single.parent, drive.folders.single.id);
      expect(drive.files.single.bytes, [3]);
    });
  });

  group('OAuthTokenSource', () {
    final now = DateTime.utc(2026, 10, 20, 12);
    final client = OAuthTokenSource.googleDriveClient(clientId: 'client-id.apps.googleusercontent.com', clientSecret: 'client-secret');

    Map<String, String> stored(DateTime expires) => {
          'access_token': 'old',
          'refresh_token': 'refresh-1',
          'expires_at': expires.toIso8601String(),
          'token_type': 'Bearer',
          'client_secret': 'client-secret',
        };

    http.Response renewed() => _json({'access_token': 'new', 'expires_in': 3599, 'token_type': 'Bearer', 'scope': googleDriveScope});

    test('a valid token is handed out without renewing', () async {
      final source = OAuthTokenSource(
        client: client,
        http: NeforumHttp(client: MockClient((r) async => fail('no renewal expected: ${r.url}')), maxRetries: 0),
        secrets: stored(now.add(const Duration(hours: 1))),
        save: (_) async => fail('nothing to save'),
        clock: () => now,
      );
      expect(await source.accessToken(), 'old');
    });

    test('a token about to expire is renewed and the merged secrets saved', () async {
      final requests = <http.Request>[];
      final saved = <Map<String, String>>[];
      final source = OAuthTokenSource(
        client: client,
        http: NeforumHttp(
            client: MockClient((r) async {
              requests.add(r);
              return renewed();
            }),
            maxRetries: 0),
        secrets: stored(now.add(const Duration(minutes: 4))),
        save: (s) async => saved.add(s),
        clock: () => now,
      );
      expect(await source.accessToken(), 'new');
      expect(requests.single.url.toString(), 'https://oauth2.googleapis.com/token');
      expect(requests.single.bodyFields, {
        'grant_type': 'refresh_token',
        'refresh_token': 'refresh-1',
        'client_id': 'client-id.apps.googleusercontent.com',
        'client_secret': 'client-secret',
      });
      expect(saved.single, {
        'access_token': 'new',
        'refresh_token': 'refresh-1',
        'expires_at': now.add(const Duration(seconds: 3599)).toIso8601String(),
        'token_type': 'Bearer',
        'scope': googleDriveScope,
        'client_secret': 'client-secret',
      });
      expect(source.secrets['access_token'], 'new');

      // Valid now: no second renewal; a forced one renews anyway.
      expect(await source.accessToken(), 'new');
      expect(requests, hasLength(1));
      expect(await source.accessToken(forceRefresh: true), 'new');
      expect(requests, hasLength(2));
    });

    test('callers arriving during a renewal share it', () async {
      final gate = Completer<void>();
      var renewals = 0;
      final saved = <Map<String, String>>[];
      final source = OAuthTokenSource(
        client: client,
        http: NeforumHttp(
            client: MockClient((r) async {
              renewals++;
              await gate.future;
              return renewed();
            }),
            maxRetries: 0),
        secrets: stored(now.subtract(const Duration(minutes: 1))),
        save: (s) async => saved.add(s),
        clock: () => now,
      );
      final first = source.accessToken();
      final second = source.accessToken(forceRefresh: true);
      final third = source.accessToken();
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      expect(await Future.wait([first, second, third]), ['new', 'new', 'new']);
      expect(renewals, 1);
      expect(saved, hasLength(1));
    });

    test('a revoked sign-in asks to sign in again; outages and network errors are temporary', () async {
      var answer = () => _json({'error': 'invalid_grant', 'error_description': 'Token has been expired or revoked.'}, 400);
      final saved = <Map<String, String>>[];
      final source = OAuthTokenSource(
        client: client,
        http: NeforumHttp(client: MockClient((r) async => answer()), maxRetries: 0),
        secrets: stored(now.subtract(const Duration(minutes: 1))),
        save: (s) async => saved.add(s),
        clock: () => now,
      );
      await expectLater(
          source.accessToken(), throwsA(_syncError(temporary: false, message: 'The Google sign-in expired or was revoked: sign in again in Settings > Sync.')));

      answer = () => http.Response('Service Unavailable', 503);
      await expectLater(source.accessToken(), throwsA(_syncError(temporary: true)));
      answer = () => _json({'error': 'rate_limit_exceeded'}, 429);
      await expectLater(source.accessToken(), throwsA(_syncError(temporary: true)));
      answer = () => throw http.ClientException('Network is unreachable');
      await expectLater(source.accessToken(), throwsA(_syncError(temporary: true)));
      expect(saved, isEmpty);

      final signedOut = OAuthTokenSource(
        client: client,
        http: NeforumHttp(client: MockClient((r) async => fail('no refresh token to send')), maxRetries: 0),
        secrets: const {},
        save: (_) async {},
        clock: () => now,
      );
      await expectLater(signedOut.accessToken(), throwsA(_syncError(temporary: false, message: contains('sign in again'))));
    });

    test('the Google Drive client asks for an offline drive.file sign-in with PKCE', () {
      final request = client.buildAuthorizationUrl(redirectUri: Uri.parse('http://127.0.0.1:53682'));
      expect(request.url.origin, 'https://accounts.google.com');
      expect(request.url.path, '/o/oauth2/v2/auth');
      final q = request.url.queryParameters;
      expect(q['scope'], googleDriveScope);
      expect(q['client_id'], 'client-id.apps.googleusercontent.com');
      expect(q['access_type'], 'offline');
      expect(q['prompt'], 'consent');
      expect(q['code_challenge_method'], 'S256');
      expect(client.tokenEndpoint.toString(), 'https://oauth2.googleapis.com/token');
      expect(client.clientAuth, ClientAuth.body);
      expect(client.clientSecret, 'client-secret');
      expect(OAuthTokenSource.googleDriveClient(clientId: 'x.apps.googleusercontent.com', clientSecret: ' ').clientSecret, isNull);
    });
  });

  test('provider: Google Drive (direct) on every device, the Google Drive folder on computers only', () {
    final direct = syncProviderById('googledrive-direct')!;
    expect(direct.kind, SyncBackendKind.googleDrive);
    expect(direct.name, 'Google Drive (direct)');
    for (final (ios, android) in const [(false, false), (true, false), (false, true)]) {
      expect(direct.availableOn(ios: ios, android: android), isTrue);
    }
    expect(direct.hint, allOf(contains('Google Drive API'), contains('drive.file'), contains('Publish app'), contains('Desktop app'), contains('every device')));

    final folder = syncProviderById('googledrive')!;
    expect(folder.availableOn(), isTrue);
    expect(folder.availableOn(ios: true), isFalse);
    expect(folder.availableOn(android: true), isFalse);
    expect(folder.hint, contains('Google Drive (direct)'));

    final ids = syncProviders.map((p) => p.id).toList();
    expect(ids.indexOf('googledrive-direct'), lessThan(syncProviders.indexWhere((p) => p.kind == SyncBackendKind.webdav)));
  });

  group('end to end', () {
    late _FakeDrive drive;
    late DateTime now;
    late _Device a;
    late _Device b;

    setUp(() {
      drive = _FakeDrive();
      now = DateTime.utc(2026, 10, 20, 12);
      a = _Device('A', drive, () => now);
      b = _Device('B', drive, () => now);
    });

    test('two devices share posts through Google Drive', () async {
      await a.posts.upsert(_post('p1', text: 'hello from A'));
      expect((await a.engine.sync()).sent, 1);
      expect(drive.folders.single.name, 'NEFORUM Sync');
      expect(drive.files.single.name, kSyncFileName);
      expect(latin1.decode(drive.files.single.bytes).contains('hello from A'), isFalse, reason: 'the file is encrypted');

      expect((await b.engine.sync()).received, 1);
      expect((await b.posts.get('p1'))?.text, 'hello from A');

      now = now.add(const Duration(minutes: 5));
      await b.posts.upsert(_post('p1', text: 'edited on B', updatedAt: now));
      await b.engine.sync();
      expect((await a.engine.sync()).received, 1);
      expect((await a.posts.get('p1'))?.text, 'edited on B');
      expect(drive.files, hasLength(1));
    });

    test('two devices that create the file at once end up with one merged file', () async {
      await a.posts.upsert(_post('from-a'));
      await b.posts.upsert(_post('from-b'));
      // B creates the file while A's upload of its own new file is on the way.
      drive.beforeNextCreate = () async => b.engine.sync();
      await a.engine.sync();
      expect(drive.files, hasLength(2), reason: 'both devices created a file');

      final r = await a.engine.sync();
      expect(r.mergedCopies, 1);
      expect(drive.files, hasLength(1), reason: 'the merged duplicate is moved to the trash');
      expect(drive.trashedFiles, hasLength(1));
      await b.engine.sync();
      expect(await a.postIds(), {'from-a', 'from-b'});
      expect(await b.postIds(), {'from-a', 'from-b'});
    });

    test('two devices that both pass the version check: the second upload merges in the first one it replaced', () async {
      await a.posts.upsert(_post('p0', text: 'original'));
      await a.engine.sync();
      await b.engine.sync();
      expect((await b.posts.get('p0'))?.text, 'original');
      final file = drive.files.single;

      now = now.add(const Duration(minutes: 5));
      await b.posts.upsert(_post('p0', text: 'edited on B', updatedAt: now));
      await b.posts.upsert(_post('from-b', updatedAt: now));
      await a.posts.upsert(_post('from-a', updatedAt: now));
      // A has checked the version and is uploading; B checks the same
      // version and its upload lands first.
      drive.beforeNextUpdate = () async {
        final rb = await b.engine.sync();
        expect(rb.sent, 2);
        expect(rb.mergedCopies, 0);
      };
      final before = file.revisions.length;
      final r = await a.engine.sync();
      expect(file.revisions.length, before + 3, reason: "B's upload, A's upload that replaced it, and A's merged one");
      expect(r.mergedCopies, 1, reason: "A merged in B's replaced upload");
      expect(r.received, 2);
      expect(drive.calls, anyElement(startsWith('GET /drive/v3/files/${file.id}/revisions/')));
      expect(drive.files, hasLength(1));
      expect(drive.trashedFiles, isEmpty);
      expect(drive.calls.where((c) => c.startsWith('DELETE')), isEmpty);
      expect(await a.engine.backend.conflictCopies(), isEmpty, reason: 'the merged revision is forgotten');
      expect((await a.posts.get('p0'))?.text, 'edited on B');

      await b.engine.sync();
      expect((await b.posts.get('p0'))?.text, 'edited on B', reason: "B's edit survived A's upload");
      expect(await a.postIds(), {'p0', 'from-a', 'from-b'});
      expect(await b.postIds(), {'p0', 'from-a', 'from-b'});
    });
  });
}
