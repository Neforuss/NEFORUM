import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:xml/xml.dart';

import '../http/neforum_http.dart';
import '../media_hosts/media_host_support.dart';
import '../media_hosts/s3_media_host.dart' show S3AddressingStyle, S3CompatibleMediaHost;
import '../media_hosts/sigv4.dart';
import '../util/logger.dart';

/// The sync file's name in the chosen folder, WebDAV folder or bucket.
const String kSyncFileName = 'NEFORUM.neforumsync';

/// Whether [name] is a copy a cloud client made of the sync file [fileName]
/// when two devices wrote at once: "NEFORUM (Alice's conflicted copy
/// 2026-10-20).neforumsync" (Dropbox), "NEFORUM-PC.neforumsync" (OneDrive),
/// "NEFORUM (1).neforumsync" (Google Drive, iCloud Drive),
/// "NEFORUM.sync-conflict-20261020-101500-ABCDEFG.neforumsync" (Syncthing),
/// "NEFORUM (conflicted copy 2026-10-20 101500).neforumsync" (Nextcloud).
bool isSyncConflictCopyName(String name, {String fileName = kSyncFileName}) {
  final dot = fileName.lastIndexOf('.');
  final stem = dot <= 0 ? fileName : fileName.substring(0, dot);
  final ext = dot <= 0 ? '' : fileName.substring(dot);
  return name != fileName && name.startsWith(stem) && name.endsWith(ext) && !name.startsWith('.');
}

/// The sync file as read, with the version it had then.
@immutable
class SyncBlob {
  const SyncBlob(this.bytes, this.version);
  final Uint8List bytes;

  /// The server's ETag, or the file's time and size: changes whenever the
  /// file does. `null` when the backend cannot tell.
  final String? version;
}

/// Another device wrote the file after it was read: read, merge and write
/// again.
class SyncConflict implements Exception {
  const SyncConflict();
  @override
  String toString() => 'SyncConflict: the sync file changed while NEFORUM was writing it';
}

/// The backend could not be reached or refused; [message] is fit to show.
class SyncBackendException implements Exception {
  const SyncBackendException(this.message, {this.temporary = false});
  final String message;

  /// Worth trying again later (network, 5xx).
  final bool temporary;
  @override
  String toString() => 'SyncBackendException: $message';
}

/// A copy a cloud client made when two devices wrote at the same time
/// ("NEFORUM (Alice's conflicted copy).neforumsync"); merged in, then removed.
@immutable
class SyncSideCopy {
  const SyncSideCopy(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

/// Where the sync file lives. One file, read whole and written whole.
abstract class SyncBackend {
  /// "OneDrive folder", "cloud.example.com", "my-bucket": for the settings.
  String get label;

  /// Whether [write] is refused when the file changed since it was read
  /// (WebDAV and S3 conditional writes). A synced folder cannot promise
  /// this: the cloud client uploads later and keeps both versions when two
  /// devices collide, which [conflictCopies] then picks up.
  bool get atomicWrites;

  /// The file, or `null` when there is none yet.
  Future<SyncBlob?> read();

  /// Writes [bytes] if the file is still at [ifMatch] (`null`: only if there
  /// is no file yet). Returns the new version. Throws [SyncConflict].
  Future<String?> write(Uint8List bytes, {required String? ifMatch});

  /// Copies cloud clients made of the file when two devices wrote at once.
  Future<List<SyncSideCopy>> conflictCopies() async => const [];

  /// Removes a copy once it is merged into the main file.
  Future<void> removeConflictCopy(SyncSideCopy copy) async {}

  /// Checks that the file can be read and written; throws
  /// [SyncBackendException] with the reason.
  Future<void> check();
}

/// In-memory backend for tests and previews.
class MemorySyncBackend extends SyncBackend {
  MemorySyncBackend({this.atomicWrites = true});
  Uint8List? bytes;
  int _version = 0;

  @override
  final bool atomicWrites;

  /// Number of successful writes.
  int writes = 0;

  @override
  String get label => 'memory';

  @override
  Future<SyncBlob?> read() async => bytes == null ? null : SyncBlob(Uint8List.fromList(bytes!), '$_version');

  @override
  Future<String?> write(Uint8List data, {required String? ifMatch}) async {
    if (atomicWrites) {
      final current = bytes == null ? null : '$_version';
      if (current != ifMatch) throw const SyncConflict();
    }
    bytes = Uint8List.fromList(data);
    _version++;
    writes++;
    return '$_version';
  }

  @override
  Future<void> check() async {}
}

/// The sync file in a WebDAV folder (Nextcloud, ownCloud, Koofr, kDrive,
/// pCloud, Fastmail Files, a Hetzner Storage Box, a Synology or QNAP NAS...),
/// with HTTP Basic auth (an app password). Writes are conditional
/// (`If-Match` on the ETag, `If-None-Match: *` for a new file), so two
/// devices can never overwrite each other unseen.
class WebDavSyncBackend extends SyncBackend {
  WebDavSyncBackend({
    required NeforumHttp http,
    required Uri folderUrl,
    required String username,
    required String password,
    this.fileName = kSyncFileName,
    Logger? log,
  })  : _http = http,
        folderUrl = _withTrailingSlash(folderUrl),
        _auth = basicAuth(username, password),
        _log = log ?? Logger('sync.webdav');

  final NeforumHttp _http;
  final Uri folderUrl;
  final String fileName;
  final String _auth;
  final Logger _log;

  Uri get fileUrl => folderUrl.resolve(Uri.encodeComponent(fileName));

  @override
  String get label => folderUrl.host;

  @override
  bool get atomicWrites => true;

  @override
  Future<SyncBlob?> read() async {
    final r = await _call('read the sync file', () => _http.get(fileUrl, headers: {'Authorization': _auth, 'Cache-Control': 'no-cache'}, throwOnError: false));
    if (r.statusCode == 404) return null;
    if (!r.ok) throw _error(r, 'read the sync file');
    return SyncBlob(r.bodyBytes, _strongEtag(r.headers['etag']));
  }

  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) async {
    final condition = ifMatch == null ? {'If-None-Match': '*'} : {'If-Match': ifMatch};
    Future<NeforumResponse> put() => _call('write the sync file', () => _http.putBytes(fileUrl, bytes,
        headers: {'Authorization': _auth, 'Content-Type': 'application/octet-stream', ...condition}, throwOnError: false));
    var r = await put();
    if ((r.statusCode == 404 || r.statusCode == 409) && ifMatch == null) {
      // No folder yet: create it (one level) and try again.
      _log.info('Creating WebDAV folder $folderUrl');
      final mk = await _call('create the folder', () => _http.send('MKCOL', folderUrl, headers: {'Authorization': _auth}, throwOnError: false));
      if (!mk.ok && mk.statusCode != 405) throw _error(mk, 'create the folder $folderUrl');
      r = await put();
    }
    if (r.statusCode == 412) throw const SyncConflict();
    if (!r.ok) throw _error(r, 'write the sync file');
    return _strongEtag(r.headers['etag'] ?? r.headers['oc-etag']);
  }

  @override
  Future<void> check() async {
    await read();
    final probe = folderUrl.resolve(Uri.encodeComponent('.$fileName.check'));
    var r = await _call('write a test file', () => _http.putBytes(probe, Uint8List.fromList([0x4E]), headers: {'Authorization': _auth}, throwOnError: false));
    if (r.statusCode == 404 || r.statusCode == 409) {
      final mk = await _call('create the folder', () => _http.send('MKCOL', folderUrl, headers: {'Authorization': _auth}, throwOnError: false));
      if (!mk.ok && mk.statusCode != 405) throw _error(mk, 'create the folder $folderUrl');
      r = await _call('write a test file', () => _http.putBytes(probe, Uint8List.fromList([0x4E]), headers: {'Authorization': _auth}, throwOnError: false));
    }
    if (!r.ok) throw _error(r, 'write to the folder');
    await _call('remove the test file', () => _http.delete(probe, headers: {'Authorization': _auth}, throwOnError: false));
  }

  Future<NeforumResponse> _call(String what, Future<NeforumResponse> Function() run) async {
    try {
      return await run();
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) {
        throw SyncBackendException('Could not reach ${folderUrl.host} to $what: $e', temporary: true);
      }
      rethrow;
    }
  }

  SyncBackendException _error(NeforumResponse r, String what) {
    final hint = switch (r.statusCode) {
      401 => 'the username or app password is wrong',
      403 => 'this account may not use $folderUrl',
      404 || 409 => 'the folder $folderUrl does not exist',
      405 => 'this address is not a WebDAV folder',
      423 => 'the file is locked on the server; try again in a moment',
      507 => 'the account is out of storage space',
      _ => null,
    };
    return SyncBackendException('Could not $what (HTTP ${r.statusCode})${hint == null ? '' : ': $hint'}',
        temporary: r.statusCode == 423 || isTemporaryStatus(r.statusCode) || r.statusCode == 429);
  }

  /// `If-Match` compares strongly, so a weak ETag (`W/"..."`) can never
  /// match: write without a condition then (the merge still catches up).
  static String? _strongEtag(String? etag) => etag == null || etag.startsWith('W/') ? null : etag;

  static Uri _withTrailingSlash(Uri u) =>
      Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : null, path: u.path.endsWith('/') ? u.path : '${u.path}/');
}

/// The sync file as one object in an S3-compatible bucket (Amazon S3,
/// Cloudflare R2, Backblaze B2, Wasabi, MinIO, IDrive e2, Scaleway,
/// DigitalOcean Spaces, Hetzner Object Storage, Storj...). Writes send
/// `If-Match` / `If-None-Match: *`; a store that does not support
/// conditional writes falls back to plain writes (then the merge on the next
/// sync catches up).
class S3SyncBackend extends SyncBackend {
  S3SyncBackend({
    required NeforumHttp http,
    required Uri endpoint,
    required this.bucket,
    required String accessKeyId,
    required String secretAccessKey,
    String? region,
    String folder = '',
    this.addressing = S3AddressingStyle.auto,
    this.fileName = kSyncFileName,
    Clock? clock,
    Logger? log,
  })  : _http = http,
        endpoint = Uri(scheme: endpoint.scheme, host: endpoint.host, port: endpoint.hasPort ? endpoint.port : null, path: _trimSlashes(endpoint.path)),
        folder = _normalizeFolder(folder),
        _signer = SigV4Signer(
          accessKeyId: accessKeyId,
          secretAccessKey: secretAccessKey,
          region: (region == null || region.trim().isEmpty) ? S3CompatibleMediaHost.defaultRegionFor(endpoint) : region.trim(),
        ),
        _now = clock ?? systemClock,
        _log = log ?? Logger('sync.s3');

  final NeforumHttp _http;
  final Uri endpoint;
  final String bucket;
  final String folder;
  final S3AddressingStyle addressing;
  final String fileName;
  final SigV4Signer _signer;
  final Clock _now;
  final Logger _log;
  bool _conditionalUnsupported = false;

  String get key => '$folder$fileName';

  @override
  String get label => bucket;

  @override
  bool get atomicWrites => !_conditionalUnsupported;

  bool get _virtualHost => switch (addressing) {
        S3AddressingStyle.path => false,
        S3AddressingStyle.virtual => true,
        S3AddressingStyle.auto =>
          (endpoint.host.toLowerCase().endsWith('amazonaws.com') || endpoint.host.toLowerCase().endsWith('backblazeb2.com')) && !bucket.contains('.'),
      };

  Uri objectUri(String objectKey) {
    final k = objectKey.split('/').map(SigV4Signer.uriEncode).join('/');
    final port = endpoint.hasPort ? ':${endpoint.port}' : '';
    final base = endpoint.path.isEmpty ? '' : '/${endpoint.path}';
    if (_virtualHost) return Uri.parse('${endpoint.scheme}://$bucket.${endpoint.host}$port$base/$k');
    return Uri.parse('${endpoint.scheme}://${endpoint.host}$port$base/${SigV4Signer.uriEncode(bucket)}/$k');
  }

  @override
  Future<SyncBlob?> read() async {
    final uri = objectUri(key);
    final r = await _call('read the sync file', () {
      final signed = _signer.sign(method: 'GET', uri: uri, now: _now());
      return _http.get(uri, headers: signed.headers, throwOnError: false);
    });
    if (r.statusCode == 404) return null;
    if (!r.ok) throw _error(r, 'read the sync file');
    return SyncBlob(r.bodyBytes, r.headers['etag']);
  }

  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) async {
    final uri = objectUri(key);
    Future<NeforumResponse> put({required bool conditional}) => _call('write the sync file', () {
          final extra = <String, String>{
            'content-type': 'application/octet-stream',
            if (conditional && ifMatch == null) 'if-none-match': '*',
            if (conditional && ifMatch != null) 'if-match': ifMatch,
          };
          final signed = _signer.sign(method: 'PUT', uri: uri, now: _now(), headers: extra, payloadHash: sha256Hex(bytes));
          return _http.putBytes(uri, bytes, headers: {...extra, ...signed.headers}, throwOnError: false);
        });
    var r = await put(conditional: !_conditionalUnsupported);
    if (r.statusCode == 412 || (r.statusCode == 409 && _code(r) == 'ConditionalRequestConflict')) throw const SyncConflict();
    if ((r.statusCode == 501 || r.statusCode == 400) && !_conditionalUnsupported && _code(r) != 'InvalidAccessKeyId') {
      // Stores without conditional writes answer NotImplemented (or a 400
      // about the header): write plainly from now on.
      _log.info('This store does not support conditional writes (${_code(r) ?? r.statusCode}); writing plainly');
      _conditionalUnsupported = true;
      r = await put(conditional: false);
    }
    if (!r.ok) throw _error(r, 'write the sync file');
    return r.headers['etag'];
  }

  @override
  Future<void> check() async {
    await read();
    final uri = objectUri('$folder.$fileName.check');
    final body = Uint8List.fromList([0x4E]);
    final put = await _call('write a test file', () {
      final signed = _signer.sign(method: 'PUT', uri: uri, now: _now(), payloadHash: sha256Hex(body));
      return _http.putBytes(uri, body, headers: signed.headers, throwOnError: false);
    });
    if (!put.ok) throw _error(put, 'write to the bucket');
    await _call('remove the test file', () {
      final signed = _signer.sign(method: 'DELETE', uri: uri, now: _now());
      return _http.delete(uri, headers: signed.headers, throwOnError: false);
    });
  }

  Future<NeforumResponse> _call(String what, Future<NeforumResponse> Function() run) async {
    try {
      return await run();
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) {
        throw SyncBackendException('Could not reach ${endpoint.host} to $what: $e', temporary: true);
      }
      rethrow;
    }
  }

  static String? _code(NeforumResponse r) {
    final body = r.body;
    if (!body.trimLeft().startsWith('<')) return null;
    try {
      final e = XmlDocument.parse(body).findAllElements('Code');
      return e.isEmpty ? null : e.first.innerText.trim();
    } on XmlException {
      return null;
    }
  }

  SyncBackendException _error(NeforumResponse r, String what) {
    final code = _code(r);
    final hint = switch (code) {
      'InvalidAccessKeyId' => 'the access key ID is not recognised',
      'SignatureDoesNotMatch' => 'the secret access key is wrong',
      'RequestTimeTooSkewed' => "this device's clock is off; fix the date and time",
      'AuthorizationHeaderMalformed' => 'the region is wrong',
      'NoSuchBucket' => 'bucket "$bucket" does not exist at ${endpoint.host}',
      'AccessDenied' => 'the key may not read and write in bucket "$bucket"',
      'PermanentRedirect' => 'the bucket lives in another region; use its regional endpoint',
      _ => code,
    };
    return SyncBackendException('Could not $what (HTTP ${r.statusCode})${hint == null ? '' : ': $hint'}',
        temporary: isTemporaryStatus(r.statusCode) || r.statusCode == 429);
  }

  static String _trimSlashes(String p) => p.replaceAll(RegExp(r'^/+|/+$'), '');

  static String _normalizeFolder(String raw) {
    final cleaned = raw
        .split('/')
        .map((s) => s.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-'))
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .join('/');
    return cleaned.isEmpty ? '' : '$cleaned/';
  }
}
