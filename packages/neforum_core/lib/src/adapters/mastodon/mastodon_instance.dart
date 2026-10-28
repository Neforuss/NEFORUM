import 'package:meta/meta.dart';

import '../../model/audio.dart';

/// Server software NEFORUM knows quirks for. Anything else is treated like
/// Mastodon.
abstract final class MastodonSoftware {
  static const mastodon = 'mastodon';
  static const pleroma = 'pleroma';
  static const akkoma = 'akkoma';
  static const gotosocial = 'gotosocial';
  static const friendica = 'friendica';
  static const pixelfed = 'pixelfed';
  static const mitra = 'mitra';
}

/// What NEFORUM learned about one Mastodon-API server when the account was
/// connected: its address, its software and its real limits.
///
/// Stored (non-secret) in `ConnectedAccount.config` via [toConfig] and read
/// back with [MastodonInstanceProfile.fromConfig], so `validate()` can check
/// a post against the server's own limits instead of vanilla defaults.
@immutable
class MastodonInstanceProfile {
  const MastodonInstanceProfile({
    required this.baseUrl,
    required this.domain,
    this.software = MastodonSoftware.mastodon,
    this.softwareVersion,
    this.title,
    this.maxCharacters,
    this.maxMediaAttachments,
    this.charactersReservedPerUrl,
    this.imageSizeLimit,
    this.videoSizeLimit,
    this.imageMatrixLimit,
    this.videoMatrixLimit,
    this.descriptionLimit,
    this.supportedMimeTypes = const [],
    this.apiVersion,
  });

  /// Reads a profile saved with [toConfig]. Missing keys fall back to `null`
  /// (meaning "use the vanilla Mastodon default").
  factory MastodonInstanceProfile.fromConfig(Map<String, dynamic> c) {
    final base = c[kInstance] as String? ?? '';
    return MastodonInstanceProfile(
      baseUrl: base,
      domain: c[kDomain] as String? ?? (Uri.tryParse(base)?.host ?? ''),
      software: c[kSoftware] as String? ?? MastodonSoftware.mastodon,
      softwareVersion: c[kSoftwareVersion] as String?,
      title: c[kTitle] as String?,
      maxCharacters: _int(c[kMaxCharacters]),
      maxMediaAttachments: _int(c[kMaxMediaAttachments]),
      charactersReservedPerUrl: _int(c[kCharactersPerUrl]),
      imageSizeLimit: _int(c[kImageSizeLimit]),
      videoSizeLimit: _int(c[kVideoSizeLimit]),
      imageMatrixLimit: _int(c[kImageMatrixLimit]),
      videoMatrixLimit: _int(c[kVideoMatrixLimit]),
      descriptionLimit: _int(c[kDescriptionLimit]),
      supportedMimeTypes: _strings(c[kSupportedMimeTypes]),
      apiVersion: _int(c[kApiVersion]),
    );
  }

  /// Parses `GET /api/v2/instance` or (fallback) `GET /api/v1/instance`.
  /// Pleroma/Akkoma put their limits at the top level of the v1 response
  /// (`max_toot_chars`, `upload_limit`, `max_media_attachments`).
  factory MastodonInstanceProfile.fromInstanceJson(Map<String, dynamic> json, {required String baseUrl}) {
    final conf = _map(json['configuration']);
    final statuses = _map(conf['statuses']);
    final media = _map(conf['media_attachments']);
    final version = json['version'] as String?;
    final compat = _compatibleSoftware(version);
    final source = (json['source_url'] as String? ?? '').toLowerCase();
    return MastodonInstanceProfile(
      baseUrl: baseUrl,
      domain: _domainOf(json, baseUrl),
      software: compat?.$1 ?? (source.contains('gotosocial') ? MastodonSoftware.gotosocial : MastodonSoftware.mastodon),
      softwareVersion: compat?.$2 ?? version,
      title: json['title'] as String?,
      maxCharacters: _int(statuses['max_characters']) ?? _int(json['max_toot_chars']) ?? _int(json['max_characters']),
      maxMediaAttachments: _int(statuses['max_media_attachments']) ?? _int(json['max_media_attachments']),
      charactersReservedPerUrl: _int(statuses['characters_reserved_per_url']),
      imageSizeLimit: _int(media['image_size_limit']) ?? _int(json['upload_limit']),
      videoSizeLimit: _int(media['video_size_limit']) ?? _int(json['upload_limit']),
      imageMatrixLimit: _int(media['image_matrix_limit']),
      videoMatrixLimit: _int(media['video_matrix_limit']),
      descriptionLimit: _int(media['description_limit']) ?? _int(json['description_limit']),
      supportedMimeTypes: _strings(media['supported_mime_types']),
      apiVersion: _int(_map(json['api_versions'])['mastodon']),
    );
  }

  static const kInstance = 'instance';
  static const kDomain = 'domain';
  static const kSoftware = 'software';
  static const kSoftwareVersion = 'softwareVersion';
  static const kTitle = 'instanceTitle';
  static const kMaxCharacters = 'maxCharacters';
  static const kMaxMediaAttachments = 'maxMediaAttachments';
  static const kCharactersPerUrl = 'charactersReservedPerUrl';
  static const kImageSizeLimit = 'imageSizeLimit';
  static const kVideoSizeLimit = 'videoSizeLimit';
  static const kImageMatrixLimit = 'imageMatrixLimit';
  static const kVideoMatrixLimit = 'videoMatrixLimit';
  static const kDescriptionLimit = 'descriptionLimit';
  static const kSupportedMimeTypes = 'supportedMimeTypes';
  static const kApiVersion = 'apiVersion';

  /// `https://mastodon.social` (no trailing slash).
  final String baseUrl;

  /// WebFinger domain used in handles (`@alice@domain`).
  final String domain;

  /// Lower-case software name from NodeInfo (`mastodon`, `gotosocial`, ...).
  final String software;
  final String? softwareVersion;
  final String? title;
  final int? maxCharacters;
  final int? maxMediaAttachments;
  final int? charactersReservedPerUrl;
  final int? imageSizeLimit;
  final int? videoSizeLimit;
  final int? imageMatrixLimit;
  final int? videoMatrixLimit;
  final int? descriptionLimit;
  final List<String> supportedMimeTypes;

  /// `api_versions.mastodon` (Mastodon 4.3+), `null` elsewhere.
  final int? apiVersion;

  Uri get base => Uri.parse(baseUrl);

  Uri endpoint(String path) => base.replace(path: path);

  bool get isMastodon => software == MastodonSoftware.mastodon;
  bool get isPixelfed => software == MastodonSoftware.pixelfed;

  /// Pixelfed refuses top-level posts without media.
  bool get requiresMedia => isPixelfed;

  /// The server holds `scheduled_at` posts itself and lets NEFORUM remove them
  /// again with `DELETE /api/v1/scheduled_statuses/:id`: Mastodon (2.7+),
  /// Pleroma, Akkoma, Friendica and GoToSocial 0.20+ (older GoToSocial
  /// answers 501). Pixelfed and Mitra have no scheduled statuses, and unknown
  /// software is not trusted with them: a server that ignored `scheduled_at`
  /// would publish the post immediately.
  bool get supportsScheduling => switch (software) {
    MastodonSoftware.mastodon ||
    MastodonSoftware.pleroma ||
    MastodonSoftware.akkoma ||
    MastodonSoftware.friendica => true,
    MastodonSoftware.gotosocial => versionAtLeast(softwareVersion, const [0, 20]),
    _ => false,
  };

  /// Why [supportsScheduling] is false, for the composer.
  String get schedulingUnsupportedReason => switch (software) {
    MastodonSoftware.gotosocial => 'GoToSocial before 0.20 cannot hold scheduled posts',
    MastodonSoftware.pixelfed || MastodonSoftware.mitra => '$softwareLabel cannot hold scheduled posts',
    _ => '$softwareLabel is not known to hold scheduled posts',
  };

  /// `true` when [version] (`0.20.1`, `0.20.0-rc1+git-abc`) is at least
  /// [minimum]. Unknown versions count as too old.
  static bool versionAtLeast(String? version, List<int> minimum) {
    final m = RegExp(r'^v?(\d+(?:\.\d+)*)').firstMatch(version?.trim() ?? '');
    if (m == null) return false;
    final parts = m.group(1)!.split('.').map(int.parse).toList();
    for (var i = 0; i < minimum.length; i++) {
      final have = i < parts.length ? parts[i] : 0;
      if (have != minimum[i]) return have > minimum[i];
    }
    return true;
  }

  /// Pixelfed rejects `visibility=direct`.
  bool get supportsDirectVisibility => !isPixelfed;

  /// Pixelfed caps `spoiler_text` at 140 characters.
  int? get spoilerTextMax => isPixelfed ? 140 : null;

  /// Only the vanilla Mastodon `/share` page can prefill a composer.
  bool get hasSharePage => isMastodon;

  /// Mitra defaults to Markdown; send `content_type=text/plain` so the text
  /// is published literally.
  bool get needsPlainContentType => software == MastodonSoftware.mitra;

  /// Shown in the UI: `Mastodon 4.5.0`, `GoToSocial 0.20.1`.
  String get softwareLabel {
    final name = switch (software) {
      MastodonSoftware.mastodon => 'Mastodon',
      MastodonSoftware.pleroma => 'Pleroma',
      MastodonSoftware.akkoma => 'Akkoma',
      MastodonSoftware.gotosocial => 'GoToSocial',
      MastodonSoftware.friendica => 'Friendica',
      MastodonSoftware.pixelfed => 'Pixelfed',
      MastodonSoftware.mitra => 'Mitra',
      _ => software,
    };
    return softwareVersion == null ? name : '$name $softwareVersion';
  }

  Set<String>? get imageMimeTypes {
    final s = supportedMimeTypes.where((m) => m.startsWith('image/')).toSet();
    return s.isEmpty ? null : s;
  }

  Set<String>? get videoMimeTypes {
    final s = supportedMimeTypes.where((m) => m.startsWith('video/')).toSet();
    return s.isEmpty ? null : s;
  }

  /// The sound types the server lists, canonical ([canonicalAudioMimeType]);
  /// empty when it lists types but no sound, null when it lists none.
  Set<String>? get audioMimeTypes {
    if (supportedMimeTypes.isEmpty) return null;
    return {for (final m in supportedMimeTypes) ?canonicalAudioMimeType(m)};
  }

  MastodonInstanceProfile withSoftware(String name, String? version) => MastodonInstanceProfile(
    baseUrl: baseUrl,
    domain: domain,
    software: name,
    softwareVersion: version ?? softwareVersion,
    title: title,
    maxCharacters: maxCharacters,
    maxMediaAttachments: maxMediaAttachments,
    charactersReservedPerUrl: charactersReservedPerUrl,
    imageSizeLimit: imageSizeLimit,
    videoSizeLimit: videoSizeLimit,
    imageMatrixLimit: imageMatrixLimit,
    videoMatrixLimit: videoMatrixLimit,
    descriptionLimit: descriptionLimit,
    supportedMimeTypes: supportedMimeTypes,
    apiVersion: apiVersion,
  );

  Map<String, dynamic> toConfig() => {
    kInstance: baseUrl,
    kDomain: domain,
    kSoftware: software,
    if (softwareVersion != null) kSoftwareVersion: softwareVersion,
    if (title != null) kTitle: title,
    if (maxCharacters != null) kMaxCharacters: maxCharacters,
    if (maxMediaAttachments != null) kMaxMediaAttachments: maxMediaAttachments,
    if (charactersReservedPerUrl != null) kCharactersPerUrl: charactersReservedPerUrl,
    if (imageSizeLimit != null) kImageSizeLimit: imageSizeLimit,
    if (videoSizeLimit != null) kVideoSizeLimit: videoSizeLimit,
    if (imageMatrixLimit != null) kImageMatrixLimit: imageMatrixLimit,
    if (videoMatrixLimit != null) kVideoMatrixLimit: videoMatrixLimit,
    if (descriptionLimit != null) kDescriptionLimit: descriptionLimit,
    if (supportedMimeTypes.isNotEmpty) kSupportedMimeTypes: supportedMimeTypes,
    if (apiVersion != null) kApiVersion: apiVersion,
  };

  /// Turns what the user typed (`mastodon.social`, `@me@mastodon.social`,
  /// `https://mastodon.social/@me`) into `https://mastodon.social`.
  /// Plain `http` is kept only for local development hosts.
  static Uri normalizeInstance(String raw) {
    var s = raw.trim();
    if (s.isEmpty) throw const FormatException('Enter the address of your server, e.g. mastodon.social');
    if (!s.contains('://')) {
      final handle = RegExp(r'^@?[^@\s/]+@([^@\s/]+)$').firstMatch(s);
      if (handle != null) s = handle.group(1)!;
      s = 'https://$s';
    }
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty || (u.scheme != 'https' && u.scheme != 'http')) {
      throw FormatException('"$raw" does not look like a server address');
    }
    final host = u.host.toLowerCase();
    final scheme = u.scheme == 'http' && _isLocalHost(host) ? 'http' : 'https';
    return Uri(scheme: scheme, host: host, port: u.hasPort ? u.port : null);
  }

  static bool _isLocalHost(String host) =>
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host.endsWith('.localhost') ||
      host.endsWith('.test');

  /// `"4.0.0 (compatible; Pixelfed 0.12.4)"` → `('pixelfed', '0.12.4')`.
  static (String, String?)? _compatibleSoftware(String? version) {
    if (version == null) return null;
    final m = RegExp(r'\(compatible;\s*([A-Za-z][\w.]*)(?:[ /]([^)\s]+))?').firstMatch(version);
    if (m == null) return null;
    return (m.group(1)!.toLowerCase(), m.group(2));
  }

  static String _domainOf(Map<String, dynamic> json, String baseUrl) {
    final d = json['domain'];
    if (d is String && d.isNotEmpty) return d;
    final uri = json['uri'];
    if (uri is String && uri.isNotEmpty) {
      return uri.contains('://') ? (Uri.tryParse(uri)?.host ?? uri) : uri;
    }
    return Uri.tryParse(baseUrl)?.host ?? baseUrl;
  }
}

Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

List<String> _strings(Object? v) => v is List ? v.whereType<String>().toList(growable: false) : const <String>[];
