import 'package:meta/meta.dart';

import '../http/neforum_http.dart';
import '../util/logger.dart';
import 'catbox_media_host.dart';
import 'manual_url_media_host.dart';
import 'media_host.dart';
import 'media_host_support.dart';
import 's3_media_host.dart';
import 'webdav_media_host.dart';

/// Builds a configured [MediaHost]. [config] holds every field value, secret
/// ones included (the app merges settings and keychain before calling).
typedef MediaHostFactory = MediaHost Function(Map<String, String> config, NeforumHttp http,
    {Clock? clock, Logger? log});

/// What the settings screen shows for one kind of media host.
@immutable
class MediaHostDescriptor {
  const MediaHostDescriptor({
    required this.id,
    required this.name,
    required this.description,
    required this.fields,
    this.temporary = false,
    this.needsAccount = true,
    this.thirdParty = false,
    this.canDelete = true,
    this.maxBytes,
    this.setupGuide = 'docs/media-hosts.md',
  });

  final String id;
  final String name;

  /// One or two plain sentences for non-developers.
  final String description;
  final List<MediaHostField> fields;

  /// Files vanish on their own after a while.
  final bool temporary;

  /// The user must create an account/server first.
  final bool needsAccount;

  /// Files go to a service the user does not control: show a notice.
  final bool thirdParty;

  /// NEFORUM can remove files after posting.
  final bool canDelete;
  final int? maxBytes;
  final String setupGuide;

  Iterable<MediaHostField> get secretFields => fields.where((f) => f.secret);
}

/// Lookup table of media host kinds: id -> descriptor + factory.
class MediaHostRegistry {
  MediaHostRegistry();

  /// All hosts shipped with NEFORUM.
  factory MediaHostRegistry.builtIn() => MediaHostRegistry()
    ..register(litterboxDescriptor, (c, http, {clock, log}) =>
        CatboxMediaHost.litterboxFromConfig(c, http, clock: clock, log: log))
    ..register(s3Descriptor, (c, http, {clock, log}) => S3CompatibleMediaHost.fromConfig(c, http, clock: clock, log: log))
    ..register(webDavDescriptor, (c, http, {clock, log}) => WebDavMediaHost.fromConfig(c, http, clock: clock, log: log))
    ..register(catboxDescriptor, (c, http, {clock, log}) => CatboxMediaHost.catboxFromConfig(c, http, log: log))
    ..register(manualDescriptor, (c, http, {clock, log}) => const ManualUrlMediaHost());

  /// Zero-configuration default (temporary, anonymous).
  static const String defaultHostId = litterboxHostId;

  final Map<String, (MediaHostDescriptor, MediaHostFactory)> _byId = {};

  void register(MediaHostDescriptor descriptor, MediaHostFactory factory) {
    if (_byId.containsKey(descriptor.id)) {
      throw StateError('Media host "${descriptor.id}" registered twice');
    }
    _byId[descriptor.id] = (descriptor, factory);
  }

  /// Descriptors in registration order (recommended first).
  List<MediaHostDescriptor> get descriptors => [for (final e in _byId.values) e.$1];

  MediaHostDescriptor? descriptor(String id) => _byId[id]?.$1;

  bool contains(String id) => _byId.containsKey(id);

  /// Labels of required fields that are empty in [config].
  List<String> missingFields(String id, Map<String, String> config) => [
        for (final f in descriptor(id)?.fields ?? const <MediaHostField>[])
          if (f.required && configValue(config, f.key) == null) f.label,
      ];

  /// Splits [config] into values for settings.json and values for the
  /// keychain, according to the host's field definitions.
  ({Map<String, String> plain, Map<String, String> secrets}) split(String id, Map<String, String> config) {
    final secretKeys = {for (final f in descriptor(id)?.secretFields ?? const <MediaHostField>[]) f.key};
    return (
      plain: {for (final e in config.entries) if (!secretKeys.contains(e.key)) e.key: e.value},
      secrets: {for (final e in config.entries) if (secretKeys.contains(e.key)) e.key: e.value},
    );
  }

  /// Creates the host [id] from [config]. Throws [MediaHostException] for
  /// unknown ids, missing required fields or invalid values.
  MediaHost create(String id, Map<String, String> config, NeforumHttp http, {Clock? clock, Logger? log}) {
    final entry = _byId[id];
    if (entry == null) throw MediaHostException('Unknown media host "$id"', hostId: id);
    final missing = missingFields(id, config);
    if (missing.isNotEmpty) {
      throw MediaHostException('Fill in ${missing.map((m) => '"$m"').join(', ')} in the media host settings', hostId: id);
    }
    return entry.$2(config, http, clock: clock, log: log);
  }
}

/// Litterbox: anonymous, temporary.
const MediaHostDescriptor litterboxDescriptor = MediaHostDescriptor(
  id: litterboxHostId,
  name: 'Litterbox (temporary, free)',
  description: litterboxDescription,
  fields: litterboxFields,
  temporary: true,
  needsAccount: false,
  thirdParty: true,
  canDelete: false,
  maxBytes: CatboxMediaHost.litterboxMaxBytes,
  setupGuide: 'docs/media-hosts.md#litterbox-and-catbox',
);

/// User-owned S3-compatible bucket.
const MediaHostDescriptor s3Descriptor = MediaHostDescriptor(
  id: s3HostId,
  name: 'S3-compatible bucket (AWS, R2, B2, MinIO)',
  description: s3Description,
  fields: s3Fields,
  maxBytes: 5 * 1000 * 1000 * 1000,
  setupGuide: 'docs/media-hosts.md#s3-compatible-bucket',
);

/// Nextcloud / ownCloud / WebDAV.
const MediaHostDescriptor webDavDescriptor = MediaHostDescriptor(
  id: webDavHostId,
  name: 'Nextcloud / WebDAV',
  description: webDavDescription,
  fields: webDavFields,
  setupGuide: 'docs/media-hosts.md#nextcloud-owncloud-webdav',
);

/// Catbox: permanent, optional account.
const MediaHostDescriptor catboxDescriptor = MediaHostDescriptor(
  id: catboxHostId,
  name: 'Catbox (permanent, free)',
  description: catboxDescription,
  fields: catboxFields,
  needsAccount: false,
  thirdParty: true,
  maxBytes: CatboxMediaHost.catboxMaxBytes,
  setupGuide: 'docs/media-hosts.md#litterbox-and-catbox',
);

/// Links pasted by the user.
const MediaHostDescriptor manualDescriptor = MediaHostDescriptor(
  id: manualHostId,
  name: 'My own links',
  description: manualDescription,
  fields: [],
  needsAccount: false,
  canDelete: false,
  setupGuide: 'docs/media-hosts.md#my-own-links',
);
