import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../http/neforum_http.dart';
import '../model/media.dart';
import '../util/logger.dart';
import 'media_host.dart';
import 'media_host_support.dart';
import 'sigv4.dart';

/// How the bucket appears in object URLs.
enum S3AddressingStyle {
  /// Virtual-hosted for AWS and Backblaze endpoints (unless the bucket name
  /// contains a dot), path-style for everything else (R2, MinIO, ...).
  auto,

  /// `https://endpoint/bucket/key`
  path,

  /// `https://bucket.endpoint/key`
  virtual,
}

/// "Bring your own bucket": uploads to any S3-compatible object store (AWS
/// S3, Cloudflare R2, Backblaze B2's S3 API, MinIO, ...) with a SigV4-signed
/// `PUT Object`, and deletes with a signed `DELETE Object`.
///
/// The public link is `publicBaseUrl/key` when the bucket is public-read (the
/// recommended setup). Without a public base URL the host hands out a
/// presigned GET link instead, valid for the requested TTL (at most 7 days).
class S3CompatibleMediaHost implements MediaHost {
  S3CompatibleMediaHost({
    required NeforumHttp http,
    required Uri endpoint,
    required this.bucket,
    required String accessKeyId,
    required String secretAccessKey,
    String? region,
    this.publicBaseUrl,
    String pathPrefix = '',
    this.addressing = S3AddressingStyle.auto,
    this.defaultLinkLifetime = const Duration(hours: 24),
    Clock? clock,
    Logger? log,
    String Function()? newId,
  })  : _http = http,
        endpoint = _stripTrailingSlash(endpoint),
        pathPrefix = _normalizePrefix(pathPrefix),
        _signer = SigV4Signer(
          accessKeyId: accessKeyId,
          secretAccessKey: secretAccessKey,
          region: (region == null || region.trim().isEmpty) ? defaultRegionFor(endpoint) : region.trim(),
        ),
        _now = clock ?? systemClock,
        _log = log ?? Logger('media.s3'),
        _newId = newId ?? defaultObjectId;

  /// Builds a host from the settings form (see [s3Fields] for the keys).
  factory S3CompatibleMediaHost.fromConfig(Map<String, String> config, NeforumHttp http,
      {Clock? clock, Logger? log, String Function()? newId}) {
    const id = s3HostId;
    final publicBase = configValue(config, 'publicBaseUrl');
    return S3CompatibleMediaHost(
      http: http,
      endpoint: parseUserUrl(requireConfig(config, 'endpoint', 'Endpoint', id), 'Endpoint', id),
      bucket: requireConfig(config, 'bucket', 'Bucket', id),
      accessKeyId: requireConfig(config, 'accessKeyId', 'Access key ID', id),
      secretAccessKey: requireConfig(config, 'secretAccessKey', 'Secret access key', id),
      region: configValue(config, 'region'),
      publicBaseUrl: publicBase == null ? null : _stripTrailingSlash(parseUserUrl(publicBase, 'Public base URL', id)),
      pathPrefix: configValue(config, 'pathPrefix') ?? '',
      addressing: S3AddressingStyle.values.asNameMap()[configValue(config, 'addressing')?.toLowerCase()] ??
          S3AddressingStyle.auto,
      clock: clock,
      log: log,
      newId: newId,
    );
  }

  final NeforumHttp _http;
  final Uri endpoint;
  final String bucket;
  final Uri? publicBaseUrl;
  final String pathPrefix;
  final S3AddressingStyle addressing;

  /// Lifetime of presigned links when the caller gives no TTL.
  final Duration defaultLinkLifetime;
  final SigV4Signer _signer;
  final Clock _now;
  final Logger _log;
  final String Function() _newId;

  /// S3 presigned URLs are valid for at most 7 days (AWS and R2 docs).
  static const Duration maxPresignLifetime = Duration(days: 7);

  /// The region SigV4 is scoped to.
  String get region => _signer.region;

  @override
  String get id => s3HostId;
  @override
  String get name => 'S3-compatible bucket';
  @override
  String get description => s3Description;
  @override
  List<MediaHostField> get fields => s3Fields;

  /// Single-request PUT limit on AWS S3 (5 GB); R2 and B2 are similar.
  @override
  int? get maxBytes => 5 * 1000 * 1000 * 1000;

  /// R2 signs with region `auto`; MinIO and most others default to
  /// `us-east-1`. AWS/B2 endpoints carry the region in the host name.
  static String defaultRegionFor(Uri endpoint) {
    final host = endpoint.host.toLowerCase();
    if (host.endsWith('.r2.cloudflarestorage.com')) return 'auto';
    // s3.<region>, s3-<region> (legacy) and s3.dualstack.<region>.
    final aws = RegExp(r'^s3[.-](?:dualstack\.)?([a-z0-9-]+)\.amazonaws\.com$').firstMatch(host);
    if (aws != null && aws.group(1) != 'external-1') return aws.group(1)!;
    final b2 = RegExp(r'^s3\.([a-z0-9-]+)\.backblazeb2\.com$').firstMatch(host);
    if (b2 != null) return b2.group(1)!;
    return 'us-east-1';
  }

  /// Whether object URLs put the bucket in the host name.
  bool get usesVirtualHost {
    switch (addressing) {
      case S3AddressingStyle.path:
        return false;
      case S3AddressingStyle.virtual:
        return true;
      case S3AddressingStyle.auto:
        final host = endpoint.host.toLowerCase();
        final known = host.endsWith('amazonaws.com') || host.endsWith('backblazeb2.com');
        return known && !bucket.contains('.');
    }
  }

  /// The signed API URL of the object [key].
  Uri objectUri(String key) {
    final encodedKey = _encodeKey(key);
    final port = endpoint.hasPort ? ':${endpoint.port}' : '';
    final base = endpoint.path;
    if (usesVirtualHost) {
      return Uri.parse('${endpoint.scheme}://$bucket.${endpoint.host}$port$base/$encodedKey');
    }
    return Uri.parse('${endpoint.scheme}://${endpoint.host}$port$base/${SigV4Signer.uriEncode(bucket)}/$encodedKey');
  }

  /// The link handed to platforms when the bucket is public.
  Uri? publicUrlFor(String key) {
    final base = publicBaseUrl;
    if (base == null) return null;
    return Uri.parse('$base/${_encodeKey(key)}');
  }

  @override
  Future<HostedMedia> upload(MediaAttachment media, Uint8List bytes, {Duration? ttl}) async {
    checkSize(this, media, bytes.length);
    final key = '$pathPrefix${randomObjectName(media, _newId)}';
    await _put(key, bytes, media.mimeType);
    final public = publicUrlFor(key);
    if (public != null) {
      return HostedMedia(hostId: id, url: public, deleteHandle: key);
    }
    var lifetime = ttl ?? defaultLinkLifetime;
    if (lifetime > maxPresignLifetime) lifetime = maxPresignLifetime;
    final now = _now();
    final link = _signer.presign(method: 'GET', uri: objectUri(key), now: now, expires: lifetime);
    return HostedMedia(hostId: id, url: link, deleteHandle: key, expiresAt: now.add(lifetime));
  }

  @override
  Future<void> delete(HostedMedia hosted) async {
    final key = hosted.deleteHandle;
    if (key == null || key.isEmpty) return;
    await _delete(key);
  }

  /// Uploads a tiny probe object, checks that its public link answers, and
  /// deletes it again.
  @override
  Future<void> verify() async {
    final media = probeAttachment();
    final hosted = await upload(media, Uint8List.fromList(probeBytes()), ttl: const Duration(minutes: 5));
    try {
      final r = await guardedCall(id, 'open the public link ${hosted.url}',
          () => _http.get(hosted.url, throwOnError: false));
      if (!r.ok) {
        throw MediaHostException(
            'Upload works, but the public link answered HTTP ${r.statusCode}. '
            '${publicBaseUrl == null ? 'Check the endpoint and region.' : 'Make the bucket publicly readable and check the public base URL.'}',
            hostId: id);
      }
    } finally {
      await _delete(hosted.deleteHandle!);
    }
  }

  Future<void> _put(String key, Uint8List bytes, String contentType) async {
    final uri = objectUri(key);
    final signed = _signer.sign(
      method: 'PUT',
      uri: uri,
      now: _now(),
      headers: {'content-type': contentType},
      payloadHash: sha256Hex(bytes),
    );
    _log.debug('PUT $uri (${bytes.length} bytes)');
    final r = await guardedCall(id, 'reach ${endpoint.host}', () => _http.putBytes(uri, bytes,
        headers: {'Content-Type': contentType, ...signed.headers}, throwOnError: false));
    if (!r.ok) throw _error(r, 'upload the file');
  }

  Future<void> _delete(String key) async {
    final uri = objectUri(key);
    final signed = _signer.sign(method: 'DELETE', uri: uri, now: _now());
    final r = await guardedCall(id, 'reach ${endpoint.host}',
        () => _http.delete(uri, headers: signed.headers, throwOnError: false));
    if (!r.ok && r.statusCode != 404) throw _error(r, 'delete ${_encodeKey(key)}');
  }

  MediaHostException _error(NeforumResponse r, String what) {
    final (code, message) = _parseError(r.body);
    final hint = switch (code) {
      'InvalidAccessKeyId' => 'the access key ID is not recognised',
      'SignatureDoesNotMatch' => 'the secret access key is wrong (or does not belong to this access key)',
      'RequestTimeTooSkewed' => "this device's clock is off; fix the date and time",
      'AuthorizationHeaderMalformed' => 'the region is wrong${message == null ? '' : ' ($message)'}',
      'NoSuchBucket' => 'bucket "$bucket" does not exist at ${endpoint.host}',
      'AccessDenied' => 'the key is not allowed to write to bucket "$bucket"',
      'EntityTooLarge' => 'the file is too large for this bucket',
      'PermanentRedirect' => 'the bucket lives in another region; use its regional endpoint',
      _ => null,
    };
    final detail = hint ?? [code, message].whereType<String>().join(': ');
    return MediaHostException(
        'Could not $what (HTTP ${r.statusCode})${detail.isEmpty ? '' : ': $detail'}',
        hostId: id);
  }

  static (String?, String?) _parseError(String body) {
    if (!body.trimLeft().startsWith('<')) return (null, null);
    try {
      final doc = XmlDocument.parse(body);
      String? text(String tag) {
        final e = doc.findAllElements(tag);
        return e.isEmpty ? null : e.first.innerText.trim();
      }

      return (text('Code'), text('Message'));
    } on XmlException {
      return (null, null);
    }
  }

  static String _encodeKey(String key) => key.split('/').map(SigV4Signer.uriEncode).join('/');

  static Uri _stripTrailingSlash(Uri u) {
    var path = u.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : null, path: path);
  }

  static String _normalizePrefix(String raw) {
    final cleaned = raw
        .split('/')
        .map((s) => s.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-'))
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .join('/');
    return cleaned.isEmpty ? '' : '$cleaned/';
  }
}

/// Registry id of [S3CompatibleMediaHost].
const String s3HostId = 's3';

/// Settings-screen description of [S3CompatibleMediaHost].
const String s3Description =
    'Your own bucket on Amazon S3, Cloudflare R2, Backblaze B2 or MinIO. Files are uploaded with your keys and '
    'deleted after posting. Most reliable option; Backblaze B2 and R2 have free tiers.';

/// Form fields of [S3CompatibleMediaHost].
const List<MediaHostField> s3Fields = [
  MediaHostField(
    key: 'endpoint',
    label: 'Endpoint',
    placeholder: 'https://s3.us-west-004.backblazeb2.com',
    help: 'The S3 API address. AWS: https://s3.<region>.amazonaws.com; R2: https://<account id>.r2.cloudflarestorage.com; '
        'B2: https://s3.<region>.backblazeb2.com; MinIO: your server address.',
  ),
  MediaHostField(
    key: 'region',
    label: 'Region',
    required: false,
    placeholder: 'us-east-1',
    help: 'Leave empty to guess from the endpoint (R2 uses "auto", MinIO "us-east-1").',
  ),
  MediaHostField(key: 'bucket', label: 'Bucket', placeholder: 'my-neforum-media'),
  MediaHostField(key: 'accessKeyId', label: 'Access key ID', help: 'B2 calls this the "keyID".'),
  MediaHostField(
    key: 'secretAccessKey',
    label: 'Secret access key',
    secret: true,
    help: 'B2 calls this the "applicationKey". Only needs permission to write and delete in this bucket.',
  ),
  MediaHostField(
    key: 'publicBaseUrl',
    label: 'Public base URL',
    required: false,
    placeholder: 'https://media.example.com',
    help: 'Where the bucket is publicly readable, e.g. https://<bucket>.s3.<region>.amazonaws.com, an R2 custom domain, '
        'or https://<bucket>.s3.<region>.backblazeb2.com. Leave empty for a private bucket: NEFORUM then uses '
        'time-limited signed links.',
  ),
  MediaHostField(
    key: 'pathPrefix',
    label: 'Folder in the bucket',
    required: false,
    placeholder: 'neforum/',
    help: 'Optional. Tip: add a lifecycle rule that deletes this folder\'s files after 1 day as a safety net.',
  ),
  MediaHostField(
    key: 'addressing',
    label: 'Addressing style',
    required: false,
    placeholder: 'auto',
    help: '"auto" (default), "path" (endpoint/bucket/key) or "virtual" (bucket.endpoint/key).',
  ),
];
