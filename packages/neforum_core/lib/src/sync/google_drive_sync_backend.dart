import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../http/neforum_http.dart';
import '../media_hosts/media_host_support.dart' show isTemporaryStatus;
import '../util/logger.dart';
import 'sync_backend.dart';

/// The sync file in the user's Google Drive, reached through the Google
/// Drive API v3 with the user's own Google Cloud OAuth client and the
/// `drive.file` scope (NEFORUM only ever sees what it created). Works on
/// every platform, unlike Google Drive's Files app integration on iOS, which
/// cannot pick folders and often does not hand the file over.
///
/// The sync file carries a private tag (`appProperties` neforum=sync) and is
/// found by it wherever it is: moving the file or its folder changes
/// nothing. A folder only matters for a new file: the one NEFORUM tagged as
/// its own, else one named [folderName], else a new one in the root of "My
/// Drive". Two devices that create the file at once leave two tagged files:
/// the oldest is the main file, the others are merged in as conflict copies
/// and moved to the trash.
///
/// Drive v3 has no conditional writes ([atomicWrites] is false). [write]
/// compares the file's version first, but two devices can both pass that
/// check before either uploads. Every upload makes a new revision, so after
/// uploading [write] lists the file's revisions: when the one just before
/// its own is not the one it checked, the revisions in between are other
/// devices' writes that it replaced. Their content is kept and offered first
/// by [conflictCopies], and the write ends in a [SyncConflict], so the
/// engine reads the file again (this device's write) and merges them in.
/// Nothing in Drive is deleted for good: merged duplicates go to the trash
/// and replaced revisions stay in the file's history.
class GoogleDriveSyncBackend extends SyncBackend {
  GoogleDriveSyncBackend({
    required NeforumHttp http,
    required Future<String> Function({bool forceRefresh}) token,
    this.folderName = 'NEFORUM Sync',
    this.fileName = kSyncFileName,
    Logger? log,
  })  : _http = http,
        _token = token,
        _log = log ?? Logger('sync.gdrive');

  final NeforumHttp _http;
  final Future<String> Function({bool forceRefresh}) _token;
  final Logger _log;

  /// The name of the folder NEFORUM creates in My Drive's root when there
  /// is no sync file and no folder of its own yet. A name of NEFORUM's own,
  /// so it never clashes with a folder Google Drive for desktop made (which
  /// `drive.file` could not see).
  final String folderName;
  final String fileName;

  /// The folder found or created last. Only ever the place for a new sync
  /// file (checked again before use), never a way to find the sync file.
  String? _folderId;

  /// Other devices' writes that a write of this device replaced, waiting to
  /// be merged in ([conflictCopies]).
  final _replaced = <SyncSideCopy>[];

  static const _host = 'www.googleapis.com';
  static const _folderMime = 'application/vnd.google-apps.folder';

  /// The `appProperties` key NEFORUM tags its file and its folder with, and
  /// the two values.
  static const _tagKey = 'neforum';
  static const _fileTag = 'sync';
  static const _folderTag = 'syncFolder';

  /// What a create or an update of the sync file answers with.
  static const _writtenFields = 'id,version,headRevisionId';

  /// [SyncSideCopy.name] prefix of a duplicate, followed by its file id.
  static const _copyPrefix = 'gdrive:';

  /// [SyncSideCopy.name] prefix of a replaced write, followed by
  /// `<fileId>:<revisionId>`.
  static const _revisionPrefix = 'gdrive-rev:';

  @override
  String get label => 'Google Drive';

  @override
  bool get atomicWrites => false;

  @override
  Future<SyncBlob?> read() async {
    final files = await _syncFiles();
    if (files.isEmpty) return null;
    final main = files.first;
    if (main.size == 0) return null;
    final bytes = await _download(main.id, 'read the sync file');
    if (bytes == null || bytes.isEmpty) return null;
    return SyncBlob(bytes, main.tag);
  }

  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) async {
    final files = await _syncFiles();
    final main = files.isEmpty ? null : files.first;
    final current = main == null || main.size == 0 ? null : main.tag;
    if (current != ifMatch) throw const SyncConflict();
    final NeforumResponse r;
    if (main == null) {
      final folderId = await _parent();
      _log.info('Creating $fileName in Google Drive');
      final boundary = _boundary();
      final metadata = jsonEncode({
        'name': fileName,
        'parents': [folderId],
        'mimeType': 'application/octet-stream',
        'appProperties': {_tagKey: _fileTag},
      });
      final body = BytesBuilder(copy: false)
        ..add(utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n'
            '--$boundary\r\nContent-Type: application/octet-stream\r\n\r\n'))
        ..add(bytes)
        ..add(utf8.encode('\r\n--$boundary--\r\n'));
      final payload = body.takeBytes();
      r = await _send(
          'create the sync file',
          (auth) => _http.send('POST', _api('/upload/drive/v3/files', {'uploadType': 'multipart', 'fields': _writtenFields}),
              headers: {...auth, 'Content-Type': 'multipart/related; boundary=$boundary'}, bytes: payload, throwOnError: false));
    } else {
      r = await _send(
          'write the sync file',
          (auth) => _http.putBytes(_api('/upload/drive/v3/files/${main.id}', {'uploadType': 'media', 'fields': _writtenFields}), bytes,
              headers: {...auth, 'Content-Type': 'application/octet-stream'}, method: 'PATCH', throwOnError: false));
    }
    if (!r.ok) throw _error(r, 'write the sync file');
    final json = r.jsonMap;
    final id = json['id'] is String ? json['id'] as String : main?.id;
    final version = json['version'];
    final head = json['headRevisionId'];
    // The head revision when the version was checked: when the revision
    // just before this write's is another one, other devices wrote between
    // the check and the upload.
    final checked = main?.head;
    if (main != null && checked != null && head is String && head != checked) {
      await _recoverReplaced(main.id, checked: checked, ours: head);
    }
    return id == null || version == null ? null : _DriveFile(id: id, version: '$version').tag;
  }

  @override
  Future<List<SyncSideCopy>> conflictCopies() async {
    // Writes this device replaced first, then duplicate files.
    final copies = <SyncSideCopy>[..._replaced];
    final files = await _syncFiles();
    for (final f in files.skip(1)) {
      if (f.size == 0) continue; // nothing to merge
      final bytes = await _download(f.id, 'read a copy of the sync file');
      if (bytes == null || bytes.isEmpty) continue;
      copies.add(SyncSideCopy('$_copyPrefix${f.id}', bytes));
    }
    return copies;
  }

  @override
  Future<void> removeConflictCopy(SyncSideCopy copy) async {
    if (copy.name.startsWith(_revisionPrefix)) {
      // Merged: forget it. The revision itself stays in the file's history.
      _replaced.removeWhere((c) => c.name == copy.name);
      return;
    }
    if (!copy.name.startsWith(_copyPrefix)) return;
    final id = copy.name.substring(_copyPrefix.length);
    if (id.isEmpty) return;
    const what = 'move a merged copy of the sync file to the trash';
    final r = await _send(
        what,
        (auth) => _http.postJson(_api('/drive/v3/files/$id', {'fields': 'id'}), {'trashed': true},
            headers: auth, method: 'PATCH', throwOnError: false));
    if (!r.ok && r.statusCode != 404) throw _error(r, what);
    _log.info('Moved a merged duplicate of $fileName to the Google Drive trash');
  }

  /// Proves the sign-in works and the sync file can be found: looks for it
  /// and, when there is none yet, finds or creates the folder for it. Never
  /// writes the sync file.
  @override
  Future<void> check() async {
    if ((await _syncFiles()).isEmpty) await _parent();
  }

  // -------------------------------------------------------------------------
  // Files and folder
  // -------------------------------------------------------------------------

  /// Every sync file, wherever it is, oldest first: the first is the main
  /// file, the others are duplicates.
  Future<List<_DriveFile>> _syncFiles() => _query('look for the sync file',
      "appProperties has { key='$_tagKey' and value='$_fileTag' } and trashed=false", 'files(id,version,headRevisionId,createdTime,size)');

  /// The folder for a new sync file: the remembered one while it is still
  /// there (a search right after creating it may not show it yet), else
  /// [_folder].
  Future<String> _parent() async {
    final known = _folderId;
    if (known != null && await _usableFolder(known)) return known;
    return _folder();
  }

  /// Whether the folder [id] still exists outside the trash.
  Future<bool> _usableFolder(String id) async {
    const what = 'look for the sync folder';
    final r = await _send(what, (auth) => _http.get(_api('/drive/v3/files/$id', {'fields': 'id,trashed'}), headers: auth, throwOnError: false));
    if (r.statusCode == 404) return false;
    if (!r.ok) throw _error(r, what);
    return r.jsonMap['trashed'] != true;
  }

  /// The folder NEFORUM tagged as its own, else a folder named [folderName]
  /// anywhere (an earlier version made it untagged), else a new one in My
  /// Drive's root; the oldest of each.
  Future<String> _folder() async {
    _folderId = null;
    var found = await _taggedFolders();
    if (found.isEmpty) {
      found = await _query('find the folder "$folderName"', "mimeType='$_folderMime' and name='${_escape(folderName)}' and trashed=false",
          'files(id,createdTime)');
    }
    if (found.isNotEmpty) return _folderId = found.first.id;
    _log.info('Creating the folder "$folderName" in Google Drive');
    final r = await _send(
        'create the folder "$folderName"',
        (auth) => _http.postJson(
            _api('/drive/v3/files', {'fields': 'id'}),
            {
              'name': folderName,
              'mimeType': _folderMime,
              'parents': ['root'],
              'appProperties': {_tagKey: _folderTag},
            },
            headers: auth,
            throwOnError: false));
    if (!r.ok) throw _error(r, 'create the folder "$folderName"');
    final created = r.jsonMap['id'];
    if (created is! String || created.isEmpty) {
      throw SyncBackendException('Google Drive did not say which folder it created for "$folderName"; try again', temporary: true);
    }
    // Another device may have created one at the same moment: everyone
    // uses the oldest.
    found = await _taggedFolders();
    return _folderId = found.isEmpty ? created : found.first.id;
  }

  Future<List<_DriveFile>> _taggedFolders() => _query('find the folder "$folderName"',
      "mimeType='$_folderMime' and appProperties has { key='$_tagKey' and value='$_folderTag' } and trashed=false", 'files(id,createdTime)');

  /// The files matching the Drive search [q], oldest first.
  Future<List<_DriveFile>> _query(String what, String q, String fields) async {
    final r = await _send(
        what,
        (auth) => _http.get(
            _api('/drive/v3/files', {
              'q': q,
              'fields': fields,
              'orderBy': 'createdTime',
              'pageSize': '100',
            }),
            headers: auth,
            throwOnError: false));
    if (!r.ok) throw _error(r, what);
    return _parseFiles(r);
  }

  /// The file's content, or `null` when it is gone.
  Future<Uint8List?> _download(String id, String what) async {
    final r = await _send(what, (auth) => _http.get(_api('/drive/v3/files/$id', {'alt': 'media'}), headers: {...auth, 'Cache-Control': 'no-cache'}, throwOnError: false));
    if (r.statusCode == 404) return null;
    if (!r.ok) throw _error(r, what);
    return r.bodyBytes;
  }

  static List<_DriveFile> _parseFiles(NeforumResponse r) {
    final raw = r.jsonMap['files'];
    final files = <_DriveFile>[
      if (raw is List)
        for (final f in raw)
          if (f is Map && f['id'] is String)
            _DriveFile(
              id: f['id'] as String,
              version: f['version'] == null ? null : '${f['version']}',
              head: f['headRevisionId'] is String ? f['headRevisionId'] as String : null,
              size: int.tryParse('${f['size'] ?? ''}'),
              created: DateTime.tryParse('${f['createdTime'] ?? ''}'),
            ),
    ];
    // Drive already orders by createdTime; ties go by id so that every
    // device picks the same main file.
    files.sort((a, b) {
      final ac = a.created, bc = b.created;
      final byTime = ac == null || bc == null ? (ac == null ? (bc == null ? 0 : 1) : -1) : ac.compareTo(bc);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return files;
  }

  // -------------------------------------------------------------------------
  // Writes that crossed
  // -------------------------------------------------------------------------

  /// After this device's write made [ours] the head revision of [fileId]:
  /// the revisions between [checked] (the head when the version was
  /// checked) and [ours] are other devices' writes that this one replaced,
  /// or, when [checked] is no longer listed, the one revision just before
  /// [ours]. Keeps their content for [conflictCopies] and throws
  /// [SyncConflict], so that the engine reads the file again and merges
  /// them in.
  Future<void> _recoverReplaced(String fileId, {required String checked, required String ours}) async {
    final revisions = await _revisions(fileId);
    final at = revisions.lastIndexOf(ours);
    if (at < 0) {
      _log.warn("Google Drive did not list the revision of $fileName NEFORUM just wrote; cannot tell whether it replaced another device's write");
      return;
    }
    if (at == 0 || revisions[at - 1] == checked) return;
    final from = revisions.lastIndexOf(checked);
    final replaced = from >= 0 && from < at ? revisions.sublist(from + 1, at) : [revisions[at - 1]];
    _log.info('Another device wrote $fileName on Google Drive at the same moment; merging in '
        '${replaced.length == 1 ? 'the write' : '${replaced.length} writes'} this one replaced');
    for (final rev in replaced) {
      final bytes = await _revisionContent(fileId, rev);
      if (bytes == null || bytes.isEmpty) continue;
      final name = '$_revisionPrefix$fileId:$rev';
      _replaced
        ..removeWhere((c) => c.name == name)
        ..add(SyncSideCopy(name, bytes));
    }
    throw const SyncConflict();
  }

  /// The ids of the revisions of [fileId], oldest first. The file gone is a
  /// [SyncConflict] (another file may be the main one now); any other
  /// failure is worth another try.
  Future<List<String>> _revisions(String fileId) async {
    const what = 'list the revisions of the sync file';
    final ids = <String>[];
    String? page;
    do {
      final token = page;
      final r = await _send(
          what,
          (auth) => _http.get(
              _api('/drive/v3/files/$fileId/revisions', {
                'fields': 'revisions(id),nextPageToken',
                'pageSize': '1000',
                if (token != null) 'pageToken': token,
              }),
              headers: auth,
              throwOnError: false));
      if (r.statusCode == 404) throw const SyncConflict();
      if (!r.ok) throw SyncBackendException(_error(r, what).message, temporary: true);
      final json = r.jsonMap;
      final raw = json['revisions'];
      if (raw is List) {
        for (final rev in raw) {
          if (rev is Map && rev['id'] is String) ids.add(rev['id'] as String);
        }
      }
      final next = json['nextPageToken'];
      page = next is String && next.isNotEmpty ? next : null;
    } while (page != null);
    return ids;
  }

  /// The content of revision [rev] of [fileId]. When Drive does not hand it
  /// over, the revision is marked to be kept forever and asked for once
  /// more; `null` (logged) when that fails too.
  Future<Uint8List?> _revisionContent(String fileId, String rev) async {
    const what = "read another device's write of the sync file";
    Future<(Uint8List?, String)> fetch() async {
      try {
        final r = await _send(
            what,
            (auth) => _http.get(_api('/drive/v3/files/$fileId/revisions/$rev', {'alt': 'media'}),
                headers: {...auth, 'Cache-Control': 'no-cache'}, throwOnError: false));
        return r.ok ? (r.bodyBytes, '') : (null, _error(r, what).message);
      } on SyncBackendException catch (e) {
        return (null, e.message);
      }
    }

    final (first, _) = await fetch();
    if (first != null) return first;
    try {
      await _send(
          "keep another device's write of the sync file",
          (auth) => _http.postJson(_api('/drive/v3/files/$fileId/revisions/$rev'), {'keepForever': true},
              headers: auth, method: 'PATCH', throwOnError: false));
    } on SyncBackendException {
      // The second attempt below tells.
    }
    final (second, why) = await fetch();
    if (second != null) return second;
    _log.warn('Could not read revision $rev of $fileName, which another device wrote; its changes may be lost: $why');
    return null;
  }

  // -------------------------------------------------------------------------
  // Requests
  // -------------------------------------------------------------------------

  /// Runs [run] with the access token; a refused token (401) is renewed and
  /// the request sent once more.
  Future<NeforumResponse> _send(String what, Future<NeforumResponse> Function(Map<String, String> auth) run) async {
    final first = await _call(what, () async => run({'Authorization': 'Bearer ${await _token()}'}));
    if (first.statusCode != 401) return first;
    _log.info('Google Drive refused the access token; renewing it');
    final fresh = await _token(forceRefresh: true);
    return _call(what, () => run({'Authorization': 'Bearer $fresh'}));
  }

  Future<NeforumResponse> _call(String what, Future<NeforumResponse> Function() run) async {
    try {
      return await run();
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) {
        throw SyncBackendException('Could not reach Google Drive to $what: $e', temporary: true);
      }
      rethrow;
    }
  }

  SyncBackendException _error(NeforumResponse r, String what) {
    final (reasons, message) = _googleError(r);
    final status = r.statusCode;
    final rateLimited = status == 429 || (status == 403 && (reasons.contains('rateLimitExceeded') || reasons.contains('userRateLimitExceeded')));
    final String? hint;
    if (rateLimited) {
      hint = 'Google Drive is rate limiting NEFORUM; it tries again shortly';
    } else if (reasons.contains('accessNotConfigured') || reasons.contains('SERVICE_DISABLED')) {
      hint = 'the Google Drive API is not enabled in your Google Cloud project. Enable the Google Drive API there '
          '(APIs & Services > Library), wait a few minutes and try again';
    } else if (reasons.contains('insufficientPermissions') || reasons.contains('ACCESS_TOKEN_SCOPE_INSUFFICIENT')) {
      hint = 'the Google sign-in does not let NEFORUM use its files in Google Drive: sign in again in Settings > Sync and allow access';
    } else if (reasons.contains('storageQuotaExceeded')) {
      hint = 'your Google Drive storage is full';
    } else if (reasons.contains('domainPolicy')) {
      hint = 'your Google Workspace administrator does not allow this app to use Google Drive';
    } else if (status == 401) {
      hint = 'Google did not accept the sign-in: sign in again in Settings > Sync';
    } else if (status == 404) {
      hint = 'the folder or the file is gone from Google Drive';
    } else {
      hint = message;
    }
    return SyncBackendException('Could not $what on Google Drive (HTTP $status)${hint == null || hint.isEmpty ? '' : ': $hint'}',
        temporary: rateLimited || isTemporaryStatus(status));
  }

  /// The `reason`s and the message of a Google API error body.
  static (Set<String>, String?) _googleError(NeforumResponse r) {
    final e = r.jsonMap['error'];
    if (e is! Map) return (const <String>{}, null);
    final reasons = <String>{
      for (final key in const ['errors', 'details'])
        if (e[key] is List)
          for (final item in e[key] as List)
            if (item is Map && item['reason'] is String) item['reason'] as String,
    };
    final message = e['message'];
    return (reasons, message is String ? message : null);
  }

  /// An address on the Drive API (`/drive/v3/...`) or its upload endpoint
  /// (`/upload/drive/v3/...`).
  static Uri _api(String path, [Map<String, String>? query]) => Uri.https(_host, path, query);

  /// A Drive query string literal: `'` and `\` escaped with a backslash.
  static String _escape(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  static String _boundary() {
    final rng = Random.secure();
    return 'neforum-${List.generate(24, (_) => rng.nextInt(16).toRadixString(16)).join()}';
  }
}

class _DriveFile {
  const _DriveFile({required this.id, this.version, this.head, this.size, this.created});
  final String id;

  /// Drive's version number: grows with every change.
  final String? version;

  /// The id of the head revision (the latest upload).
  final String? head;
  final int? size;
  final DateTime? created;

  /// The file's [SyncBlob.version]: the version number with the file's id,
  /// because a file made anew (or another file becoming the main one)
  /// starts counting again, and the engine must not mistake it for the file
  /// it read before.
  String? get tag => version == null ? null : '$id:$version';
}
