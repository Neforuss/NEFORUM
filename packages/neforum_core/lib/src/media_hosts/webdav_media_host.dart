import 'dart:convert';
import 'dart:typed_data';

import '../http/neforum_http.dart';
import '../model/media.dart';
import '../util/logger.dart';
import 'media_host.dart';
import 'media_host_support.dart';

/// Which direct-download form to build from a Nextcloud public share.
enum NextcloudLinkStyle {
  /// `{shareUrl}/download` (works on most Nextcloud and ownCloud versions).
  download,

  /// `{server}/public.php/dav/files/{token}` (what Nextcloud 31+ redirects
  /// `/download` to; skips the redirect).
  dav,
}

/// Uploads to a WebDAV folder with HTTP Basic auth (an app password).
///
/// * Nextcloud/ownCloud (the WebDAV URL contains `/remote.php/`) and no
///   public URL template: after the PUT a read-only public link share is
///   created through the OCS Share API and the direct download URL is used.
///   Delete removes the share and the file.
/// * Any other WebDAV server: the user gives a public URL template such as
///   `https://files.example.com/neforum/{name}` that maps the WebDAV folder
///   to a public web address.
///
/// A PUT that fails with HTTP 5xx, a timeout or a network error is tried once
/// more after [mediaHostRetryPause] (see [guardedUpload]).
class WebDavMediaHost implements MediaHost, DescribesVerify {
  WebDavMediaHost({
    required NeforumHttp http,
    required Uri folderUrl,
    required this.username,
    required String password,
    this.publicUrlTemplate,
    this.linkStyle = NextcloudLinkStyle.download,
    Clock? clock,
    Logger? log,
    String Function()? newId,
    MediaHostDelay? retryDelay,
  })  : _http = http,
        _retryDelay = retryDelay ?? mediaHostDefaultDelay,
        folderUrl = _withTrailingSlash(folderUrl),
        _auth = basicAuth(username, password),
        _now = clock ?? systemClock,
        _log = log ?? Logger('media.webdav'),
        _newId = newId ?? defaultObjectId {
    if (publicUrlTemplate == null && !isNextcloud) {
      throw const MediaHostException(
          'This WebDAV server is not Nextcloud/ownCloud, so NEFORUM cannot create public links on it: '
          'fill in "Public URL template" (for example https://files.example.com/neforum/{name})',
          hostId: webDavHostId);
    }
  }

  /// Builds a host from the settings form (see [webDavFields] for the keys).
  factory WebDavMediaHost.fromConfig(Map<String, String> config, NeforumHttp http,
      {Clock? clock, Logger? log, String Function()? newId, MediaHostDelay? retryDelay}) {
    const id = webDavHostId;
    return WebDavMediaHost(
      http: http,
      folderUrl: parseUserUrl(requireConfig(config, 'webdavUrl', 'WebDAV folder URL', id), 'WebDAV folder URL', id),
      username: requireConfig(config, 'username', 'Username', id),
      password: requireConfig(config, 'password', 'App password', id),
      publicUrlTemplate: configValue(config, 'publicUrlTemplate'),
      linkStyle: NextcloudLinkStyle.values.asNameMap()[configValue(config, 'linkStyle')?.toLowerCase()] ??
          NextcloudLinkStyle.download,
      clock: clock,
      log: log,
      newId: newId,
      retryDelay: retryDelay,
    );
  }

  final NeforumHttp _http;
  final MediaHostDelay _retryDelay;

  /// The WebDAV folder files are PUT into (always ends with `/`).
  final Uri folderUrl;
  final String username;

  /// `{name}` is replaced by the URL-encoded file name.
  final String? publicUrlTemplate;
  final NextcloudLinkStyle linkStyle;
  final String _auth;
  final Clock _now;
  final Logger _log;
  final String Function() _newId;

  @override
  String get id => webDavHostId;
  @override
  String get name => isNextcloud && publicUrlTemplate == null ? 'Nextcloud' : 'WebDAV server';
  @override
  String get description => webDavDescription;
  @override
  List<MediaHostField> get fields => webDavFields;

  /// Set by the server's PHP/web-server configuration; unknown here.
  @override
  int? get maxBytes => null;

  /// True for Nextcloud/ownCloud style URLs (`.../remote.php/...`).
  bool get isNextcloud => folderUrl.path.contains('/remote.php/');

  /// Server root (everything before `/remote.php/`).
  Uri get serverBase {
    final path = folderUrl.path;
    final i = path.indexOf('/remote.php/');
    return Uri(
        scheme: folderUrl.scheme,
        host: folderUrl.host,
        port: folderUrl.hasPort ? folderUrl.port : null,
        path: i < 0 ? '' : path.substring(0, i));
  }

  /// Folder path relative to the user's files root, as the OCS API wants it
  /// (`/NEFORUM` for `.../remote.php/dav/files/alice/NEFORUM/`).
  String get userFolderPath {
    final segs = folderUrl.pathSegments.where((s) => s.isNotEmpty).toList();
    final r = segs.indexOf('remote.php');
    if (r < 0) return '/';
    var rest = segs.sublist(r + 1);
    if (rest.length >= 3 && rest[0] == 'dav' && rest[1] == 'files') {
      rest = rest.sublist(3); // dav/files/<user>/...
    } else if (rest.isNotEmpty && rest[0] == 'webdav') {
      rest = rest.sublist(1);
    }
    return '/${rest.join('/')}';
  }

  Uri _ocs([String suffix = '']) => serverBase.replace(
      path: '${serverBase.path}/ocs/v2.php/apps/files_sharing/api/v1/shares$suffix',
      queryParameters: {'format': 'json'});

  Map<String, String> get _ocsHeaders => {
        'Authorization': _auth,
        'OCS-APIRequest': 'true',
        'Accept': 'application/json',
      };

  @override
  Future<HostedMedia> upload(MediaAttachment media, Uint8List bytes, {Duration? ttl}) async {
    checkSize(this, media, bytes.length);
    final fileName = randomObjectName(media, _newId);
    final fileUrl = folderUrl.resolve(Uri.encodeComponent(fileName));
    await _put(fileUrl, bytes, media.mimeType);

    final template = publicUrlTemplate;
    if (template != null) {
      final url = Uri.parse(template.replaceAll('{name}', Uri.encodeComponent(fileName)));
      return HostedMedia(hostId: id, url: url, deleteHandle: jsonEncode({'file': '$fileUrl'}));
    }
    try {
      final share = await _createShare('${userFolderPath == '/' ? '' : userFolderPath}/$fileName', ttl);
      return HostedMedia(
        hostId: id,
        url: share.$1,
        deleteHandle: jsonEncode({'file': '$fileUrl', 'share': share.$2}),
        expiresAt: ttl == null ? null : _now().add(ttl),
      );
    } on Object {
      try {
        await _deleteFile(fileUrl);
      } on Object catch (e) {
        _log.warn('Could not remove $fileUrl after the share failed', e);
      }
      rethrow;
    }
  }

  @override
  Future<void> delete(HostedMedia hosted) async {
    final handle = hosted.deleteHandle;
    if (handle == null) return;
    final Map<String, dynamic> h;
    try {
      h = Map<String, dynamic>.from(jsonDecode(handle) as Map);
    } on Object {
      throw MediaHostException('Unrecognised delete handle: $handle', hostId: id);
    }
    final share = h['share'];
    if (share is String && share.isNotEmpty) {
      final r = await guardedCall(id, 'remove the public link',
          () => _http.delete(_ocs('/${Uri.encodeComponent(share)}'), headers: _ocsHeaders, throwOnError: false));
      if (!r.ok && r.statusCode != 404) throw _ocsError(r, 'remove the public link');
    }
    final file = h['file'];
    if (file is String) await _deleteFile(Uri.parse(file));
  }

  /// Puts a probe file, shares it (Nextcloud), checks that its public link
  /// answers without a login, and deletes it again.
  @override
  Future<void> verify() async {
    final hosted = await upload(probeAttachment(), Uint8List.fromList(probeBytes()), ttl: const Duration(hours: 1));
    try {
      final r = await guardedCall(id, 'open the public link ${hosted.url}', () => _http.get(hosted.url, throwOnError: false));
      if (!r.ok) {
        throw MediaHostException(
            'Upload works, but the public link ${hosted.url} answered HTTP ${r.statusCode}. '
            '${publicUrlTemplate != null ? 'Check the public URL template.' : 'Check that public link sharing is allowed without a password.'}',
            hostId: id);
      }
    } finally {
      await delete(hosted);
    }
  }

  @override
  String get verifiedMessage => 'Upload works: a tiny test file was uploaded, opened through its public link without a '
      'login and deleted again.';

  /// The server as the subject of a sentence in error messages.
  String get _service => isNextcloud && publicUrlTemplate == null ? 'Nextcloud' : 'Your WebDAV host';

  Future<void> _put(Uri fileUrl, Uint8List bytes, String contentType) async {
    Future<NeforumResponse> put() => guardedUpload(id, 'reach ${folderUrl.host}', () => _http.putBytes(fileUrl, bytes,
        headers: {'Authorization': _auth, 'Content-Type': contentType}, throwOnError: false), delay: _retryDelay, log: _log);
    var r = await put();
    if (r.statusCode == 404 || r.statusCode == 409) {
      // The folder does not exist yet: create it (one level) and retry.
      _log.info('Creating WebDAV folder $folderUrl');
      final mk = await guardedCall(id, 'create the folder',
          () => _http.send('MKCOL', folderUrl, headers: {'Authorization': _auth}, throwOnError: false));
      if (!mk.ok && mk.statusCode != 405) throw _davError(mk, 'create the folder $folderUrl');
      r = await put();
    }
    if (!r.ok) throw _davError(r, 'upload the file', action: 'store the file');
  }

  Future<void> _deleteFile(Uri fileUrl) async {
    final r = await guardedCall(id, 'reach ${folderUrl.host}',
        () => _http.delete(fileUrl, headers: {'Authorization': _auth}, throwOnError: false));
    if (!r.ok && r.statusCode != 404) throw _davError(r, 'delete the file');
  }

  /// Returns (direct link, share id).
  Future<(Uri, String)> _createShare(String path, Duration? ttl) async {
    final form = <String, String>{
      'path': path,
      'shareType': '3',
      'permissions': '1',
      if (ttl != null) 'expireDate': _expireDate(ttl),
    };
    final r = await guardedCall(id, 'create a public link',
        () => _http.postForm(_ocs(), form, headers: _ocsHeaders, throwOnError: false));
    final data = _ocsData(r);
    if (data == null) throw _ocsError(r, 'create a public link');
    final shareId = '${data['id'] ?? ''}';
    final url = data['url'];
    final token = data['token'];
    if (shareId.isEmpty || url is! String || url.isEmpty) {
      throw MediaHostException('Nextcloud created the share but returned no link: ${bodySnippet(r)}', hostId: id);
    }
    final shareUrl = Uri.parse(url.endsWith('/') ? url.substring(0, url.length - 1) : url);
    if (linkStyle == NextcloudLinkStyle.dav && token is String && token.isNotEmpty) {
      return (serverBase.replace(path: '${serverBase.path}/public.php/dav/files/$token'), shareId);
    }
    return (shareUrl.replace(path: '${shareUrl.path}/download'), shareId);
  }

  /// `YYYY-MM-DD`, one day after now+ttl so the link outlives the TTL.
  String _expireDate(Duration ttl) {
    final d = _now().toUtc().add(ttl).add(const Duration(days: 1));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  /// `ocs.data` when `ocs.meta.statuscode` says success (100 on v1, 200 on v2).
  static Map<String, dynamic>? _ocsData(NeforumResponse r) {
    final ocs = r.jsonMap['ocs'];
    if (ocs is! Map) return null;
    final meta = ocs['meta'];
    final code = meta is Map ? meta['statuscode'] : null;
    final ok = r.ok && (code == 100 || code == 200 || code == '100' || code == '200');
    final data = ocs['data'];
    return ok && data is Map ? Map<String, dynamic>.from(data) : null;
  }

  MediaHostException _ocsError(NeforumResponse r, String what) {
    final ocs = r.jsonMap['ocs'];
    final meta = ocs is Map ? ocs['meta'] : null;
    final msg = meta is Map ? meta['message'] : null;
    if (r.statusCode == 401) return MediaHostException('Could not $what: username or app password is wrong', hostId: id);
    final detail = msg is String && msg.isNotEmpty ? msg : null;
    if (r.statusCode >= 500) return _serverError(r, what, detail: detail);
    return MediaHostException('Could not $what (HTTP ${r.statusCode}): ${detail ?? bodySnippet(r)}', hostId: id);
  }

  /// [what] completes "Could not ..."; [action] is used for 5xx answers
  /// ("Nextcloud couldn't [action]"), defaulting to [what].
  MediaHostException _davError(NeforumResponse r, String what, {String? action}) {
    final hint = switch (r.statusCode) {
      401 => 'username or app password is wrong',
      403 => 'this account may not write to $folderUrl',
      404 || 409 => 'the folder $folderUrl does not exist',
      413 => 'the server refused a file this large',
      507 => 'the account is out of storage space',
      _ => null,
    };
    if (hint == null && r.statusCode >= 500) return _serverError(r, action ?? what);
    return MediaHostException('Could not $what (HTTP ${r.statusCode}): ${hint ?? bodySnippet(r)}', hostId: id);
  }

  MediaHostException _serverError(NeforumResponse r, String action, {String? detail}) => MediaHostException(
      hostHttpFailure(_service, r, action: action, side: "your server's", detail: detail),
      hostId: id,
      temporary: isTemporaryStatus(r.statusCode));

  static Uri _withTrailingSlash(Uri u) => Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: u.path.endsWith('/') ? u.path : '${u.path}/');
}

/// Registry id of [WebDavMediaHost].
const String webDavHostId = 'webdav';

/// Settings-screen description of [WebDavMediaHost].
const String webDavDescription =
    'A folder on your own Nextcloud, ownCloud or other WebDAV server. On Nextcloud NEFORUM creates a public link '
    'for each file and removes it after posting.';

/// Form fields of [WebDavMediaHost].
const List<MediaHostField> webDavFields = [
  MediaHostField(
    key: 'webdavUrl',
    label: 'WebDAV folder URL',
    placeholder: 'https://cloud.example.com/remote.php/dav/files/alice/NEFORUM',
    help: 'Nextcloud: Files > Settings (bottom left) shows the WebDAV address; add a folder name such as /NEFORUM.',
  ),
  MediaHostField(key: 'username', label: 'Username', help: 'Your login name (Nextcloud: the user ID).'),
  MediaHostField(
    key: 'password',
    label: 'App password',
    secret: true,
    help: 'Nextcloud: Settings > Security > Devices & sessions > "Create new app password". Do not use your main password.',
  ),
  MediaHostField(
    key: 'publicUrlTemplate',
    label: 'Public URL template',
    required: false,
    placeholder: 'https://files.example.com/neforum/{name}',
    help: 'Only for plain WebDAV servers: the public web address of the folder, with {name} where the file name goes. '
        'Leave empty on Nextcloud/ownCloud.',
  ),
  MediaHostField(
    key: 'linkStyle',
    label: 'Nextcloud link style',
    required: false,
    placeholder: 'download',
    help: '"download" (default: <share link>/download) or "dav" (<server>/public.php/dav/files/<token>, '
        'avoids a redirect on Nextcloud 31 and newer).',
  ),
];
