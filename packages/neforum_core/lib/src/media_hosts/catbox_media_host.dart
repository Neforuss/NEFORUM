import 'dart:typed_data';

import '../http/neforum_http.dart';
import '../model/media.dart';
import '../util/logger.dart';
import 'media_host.dart';
import 'media_host_support.dart';

/// Litterbox retention choices (the only values its API accepts).
enum LitterboxTime {
  hour1('1h', Duration(hours: 1)),
  hours12('12h', Duration(hours: 12)),
  hours24('24h', Duration(hours: 24)),
  hours72('72h', Duration(hours: 72));

  const LitterboxTime(this.apiValue, this.duration);

  /// Value of the `time` form field.
  final String apiValue;
  final Duration duration;

  /// Parses `1h`/`12h`/`24h`/`72h`.
  static LitterboxTime? parse(String? v) {
    for (final t in values) {
      if (t.apiValue == v?.trim().toLowerCase()) return t;
    }
    return null;
  }

  /// Shortest option that keeps a file for at least [ttl] (capped at 72 h).
  static LitterboxTime atLeast(Duration ttl) {
    for (final t in values) {
      if (t.duration >= ttl) return t;
    }
    return hours72;
  }
}

/// The free catbox.moe hosts.
///
/// * [CatboxMediaHost.litterbox]: anonymous, temporary (1 h to 72 h), up to
///   1 GB. The zero-config default: Instagram and Threads fetch the file once
///   while the post is created, after which it simply expires.
/// * [CatboxMediaHost.catbox]: permanent, up to 200 MB, `.gif` up to 20 MB.
///   With a catbox account "userhash" files are tied to the account and are
///   deleted after posting; anonymous files cannot be deleted.
///
/// Both answer the upload with the bare file URL as plain text.
class CatboxMediaHost implements MediaHost {
  /// Permanent catbox.moe uploads, optionally tied to an account.
  CatboxMediaHost.catbox({required NeforumHttp http, String? userhash, Logger? log})
      : _http = http,
        temporary = false,
        userhash = (userhash == null || userhash.trim().isEmpty) ? null : userhash.trim(),
        minimumTime = LitterboxTime.hour1,
        _now = systemClock,
        _log = log ?? Logger('media.catbox');

  /// Temporary litterbox uploads that expire after at least [minimumTime].
  CatboxMediaHost.litterbox({
    required NeforumHttp http,
    this.minimumTime = LitterboxTime.hour1,
    Clock? clock,
    Logger? log,
  })  : _http = http,
        temporary = true,
        userhash = null,
        _now = clock ?? systemClock,
        _log = log ?? Logger('media.litterbox');

  /// Builds the permanent host from the settings form ([catboxFields]).
  factory CatboxMediaHost.catboxFromConfig(Map<String, String> config, NeforumHttp http, {Logger? log}) =>
      CatboxMediaHost.catbox(http: http, userhash: configValue(config, 'userhash'), log: log);

  /// Builds the temporary host from the settings form ([litterboxFields]).
  factory CatboxMediaHost.litterboxFromConfig(Map<String, String> config, NeforumHttp http,
      {Clock? clock, Logger? log}) {
    final raw = configValue(config, 'time');
    final time = LitterboxTime.parse(raw);
    if (raw != null && time == null) {
      throw MediaHostException('"Keep files for" must be 1h, 12h, 24h or 72h (got "$raw")', hostId: litterboxHostId);
    }
    return CatboxMediaHost.litterbox(http: http, minimumTime: time ?? LitterboxTime.hour1, clock: clock, log: log);
  }

  /// catbox.moe API endpoint (catbox.moe/tools.php).
  static final Uri catboxApi = Uri.parse('https://catbox.moe/user/api.php');

  /// Litterbox API endpoint (litterbox.catbox.moe/tools.php).
  static final Uri litterboxApi = Uri.parse('https://litterbox.catbox.moe/resources/internals/api.php');

  /// "Uploads up to 200 MB are allowed." (catbox.moe home page).
  static const int catboxMaxBytes = 200 * 1000 * 1000;

  /// "Temporary uploads up to 1 GB are allowed." (litterbox home page).
  static const int litterboxMaxBytes = 1000 * 1000 * 1000;

  /// catbox FAQ: GIFs over 20 MB are rejected.
  static const int catboxMaxGifBytes = 20 * 1000 * 1000;

  /// catbox FAQ: ".exe, .scr, .cpl, .doc*, .jar" are not allowed.
  static final RegExp catboxBannedExtension = RegExp(r'^\.(exe|scr|cpl|jar|doc.*)$');

  final NeforumHttp _http;
  final bool temporary;
  final String? userhash;

  /// Litterbox only: files are kept at least this long.
  final LitterboxTime minimumTime;
  final Clock _now;
  final Logger _log;

  @override
  String get id => temporary ? litterboxHostId : catboxHostId;
  @override
  String get name => temporary ? 'Litterbox (temporary)' : 'Catbox';
  @override
  String get description => temporary ? litterboxDescription : catboxDescription;
  @override
  List<MediaHostField> get fields => temporary ? litterboxFields : catboxFields;
  @override
  int? get maxBytes => temporary ? litterboxMaxBytes : catboxMaxBytes;

  /// Litterbox time used for an upload that must survive [ttl].
  LitterboxTime timeFor(Duration? ttl) {
    if (ttl == null) return minimumTime;
    final needed = LitterboxTime.atLeast(ttl);
    return needed.duration > minimumTime.duration ? needed : minimumTime;
  }

  @override
  Future<HostedMedia> upload(MediaAttachment media, Uint8List bytes, {Duration? ttl}) async {
    checkSize(this, media, bytes.length);
    final ext = extensionFor(media);
    if (!temporary) _checkCatboxRules(media, ext, bytes.length);
    final time = timeFor(ttl);
    final fields = <String, String>{
      'reqtype': 'fileupload',
      if (temporary) 'time': time.apiValue,
      if (!temporary && userhash != null) 'userhash': userhash!,
    };
    final fileName = _uploadName(media, ext);
    final r = await guardedCall(id, 'reach ${temporary ? 'litterbox.catbox.moe' : 'catbox.moe'}',
        () => _http.multipart(temporary ? litterboxApi : catboxApi,
            fields: fields,
            files: [HttpFilePart(field: 'fileToUpload', bytes: bytes, fileName: fileName, contentType: media.mimeType)],
            throwOnError: false));
    final body = r.body.trim();
    final url = Uri.tryParse(body);
    if (!r.ok || url == null || url.scheme != 'https' || url.host.isEmpty || body.contains(RegExp(r'\s'))) {
      throw MediaHostException('$name refused the upload (HTTP ${r.statusCode}): ${bodySnippet(r)}', hostId: id);
    }
    if (temporary) {
      return HostedMedia(hostId: id, url: url, expiresAt: _now().add(time.duration));
    }
    final canDelete = userhash != null && url.pathSegments.isNotEmpty;
    return HostedMedia(hostId: id, url: url, deleteHandle: canDelete ? url.pathSegments.last : null);
  }

  /// Litterbox files expire on their own; catbox files can only be deleted
  /// when they were uploaded with a userhash.
  @override
  Future<void> delete(HostedMedia hosted) async {
    final file = hosted.deleteHandle;
    final hash = userhash;
    if (temporary || file == null || hash == null) {
      _log.debug('${hosted.url} cannot be deleted on $name; it ${temporary ? 'expires on its own' : 'stays online'}');
      return;
    }
    final r = await guardedCall(id, 'reach catbox.moe',
        () => _http.multipart(catboxApi,
            fields: {'reqtype': 'deletefiles', 'userhash': hash, 'files': file}, throwOnError: false));
    if (!r.ok) {
      throw MediaHostException('Catbox did not delete $file (HTTP ${r.statusCode}): ${bodySnippet(r)}', hostId: id);
    }
  }

  /// Checks that the service answers; uploads nothing.
  @override
  Future<void> verify() async {
    final home = temporary ? Uri.parse('https://litterbox.catbox.moe/') : Uri.parse('https://catbox.moe/');
    final r = await guardedCall(id, 'reach ${home.host}', () => _http.get(home, throwOnError: false));
    if (!r.ok) throw MediaHostException('${home.host} answered HTTP ${r.statusCode}; try again later', hostId: id);
  }

  void _checkCatboxRules(MediaAttachment media, String ext, int length) {
    if (catboxBannedExtension.hasMatch(ext)) {
      throw MediaHostException('Catbox does not accept $ext files', hostId: id);
    }
    if (media.mimeType == 'image/gif' && length > catboxMaxGifBytes) {
      throw MediaHostException('Catbox rejects GIFs over 20 MB; convert it to a video (MP4/WebM)', hostId: id);
    }
  }

  static String _uploadName(MediaAttachment media, String ext) {
    final base = (media.fileName ?? media.id).split(RegExp(r'[\\/]')).last;
    final stem = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
    final safe = stem.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '${safe.isEmpty ? 'upload' : safe}$ext';
  }
}

/// Registry id of the temporary litterbox host.
const String litterboxHostId = 'litterbox';

/// Registry id of the permanent catbox host.
const String catboxHostId = 'catbox';

/// Settings-screen description of litterbox.
const String litterboxDescription =
    'Free, no account. Files are public for 1 hour to 3 days and then deleted automatically, which is all '
    'Instagram and Threads need. Up to 1 GB per file. Run by a volunteer: no guarantees.';

/// Settings-screen description of catbox.
const String catboxDescription =
    'Free and permanent, up to 200 MB per file. Anonymous files stay online (until 2 years without views); add your '
    'catbox account hash so NEFORUM can delete files after posting. No commercial use.';

/// Form fields of the litterbox host.
const List<MediaHostField> litterboxFields = [
  MediaHostField(
    key: 'time',
    label: 'Keep files for',
    required: false,
    placeholder: '1h',
    help: '1h, 12h, 24h or 72h. NEFORUM picks a longer time automatically when a platform needs it (videos).',
  ),
];

/// Form fields of the catbox host.
const List<MediaHostField> catboxFields = [
  MediaHostField(
    key: 'userhash',
    label: 'Account hash (userhash)',
    secret: true,
    required: false,
    help: 'Optional. Log in at catbox.moe and copy the userhash shown on your account page. Without it uploads are '
        'anonymous and cannot be deleted.',
  ),
];
