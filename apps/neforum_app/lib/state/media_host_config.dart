import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'settings.dart';

/// Secret-store key holding the media host's secret fields (keys, passwords).
const String kMediaHostSecretsKey = 'neforum.mediahost';

/// Secret-store key for the fallback host's secret fields.
const String kFallbackMediaHostSecretsKey = 'neforum.mediahost.fallback';

/// Every media host kind NEFORUM ships with.
final MediaHostRegistry mediaHostRegistry = MediaHostRegistry.builtIn();

/// Hosts the settings screen offers, recommended first.
List<MediaHostDescriptor> mediaHostOptions() => mediaHostRegistry.descriptors;

/// The main media host, or the optional fallback tried when it fails.
enum MediaHostSlot {
  main(kMediaHostSecretsKey),
  fallback(kFallbackMediaHostSecretsKey);

  const MediaHostSlot(this.secretsKey);
  final String secretsKey;

  String? idIn(AppSettings s) => this == main ? s.mediaHostId : s.fallbackMediaHostId;
  Map<String, String> configIn(AppSettings s) => this == main ? s.mediaHostConfig : s.fallbackMediaHostConfig;
}

/// Hosts that can be the fallback for [mainId]. A second copy of the same
/// account-free host (Litterbox, Catbox, "My own links") adds nothing; two
/// buckets or two servers do.
List<MediaHostDescriptor> fallbackOptions(String? mainId) =>
    [for (final d in mediaHostRegistry.descriptors) if (d.id != mainId || d.needsAccount) d];

/// Builds the configured public media host, or null when none is set (or
/// its settings are incomplete). With a fallback host configured, uploads
/// that fail on the main host go there; [onFallback] hears about each one.
Future<MediaHost?> buildMediaHost(AppSettings settings, SecretStore secrets, NeforumHttp http, {void Function(String message)? onFallback}) async {
  final main = await _build(MediaHostSlot.main, settings, secrets, http);
  final fallback = await _build(MediaHostSlot.fallback, settings, secrets, http);
  if (main == null || fallback == null) return main ?? fallback;
  return FallbackMediaHost(main, fallback, onFallback: onFallback);
}

Future<MediaHost?> _build(MediaHostSlot slot, AppSettings settings, SecretStore secrets, NeforumHttp http) async {
  final id = slot.idIn(settings);
  if (id == null || !mediaHostRegistry.contains(id)) return null;
  final secret = await secrets.read(slot.secretsKey) ?? const <String, String>{};
  try {
    return mediaHostRegistry.create(id, {...slot.configIn(settings), ...secret}, http);
  } on MediaHostException {
    return null;
  }
}

/// Creates a host from values the user is still editing (for "Test").
MediaHost createMediaHostFrom(String id, Map<String, String> values, NeforumHttp http) =>
    mediaHostRegistry.create(id, values, http);

/// Splits [values] into settings (plain) and keychain (secret) parts and
/// stores the secret part. Returns the settings to save.
Future<AppSettings> storeMediaHost(AppSettings current, SecretStore secrets, String id, Map<String, String> values,
    {MediaHostSlot slot = MediaHostSlot.main}) async {
  final parts = mediaHostRegistry.split(id, values);
  await secrets.write(slot.secretsKey, parts.secrets);
  return slot == MediaHostSlot.main
      ? current.copyWith(mediaHostId: id, mediaHostConfig: parts.plain)
      : current.copyWith(fallbackMediaHostId: id, fallbackMediaHostConfig: parts.plain);
}

/// Removes a host and its secrets. Removing the main host while a fallback
/// is set makes the fallback the main host.
Future<AppSettings> clearMediaHost(AppSettings current, SecretStore secrets, {MediaHostSlot slot = MediaHostSlot.main}) async {
  if (slot == MediaHostSlot.fallback) {
    await secrets.delete(kFallbackMediaHostSecretsKey);
    return current.copyWith(clearFallbackMediaHost: true);
  }
  final promoted = current.fallbackMediaHostId;
  if (promoted == null) {
    await secrets.delete(kMediaHostSecretsKey);
    return current.copyWith(clearMediaHost: true);
  }
  final secret = await secrets.read(kFallbackMediaHostSecretsKey) ?? const <String, String>{};
  await secrets.write(kMediaHostSecretsKey, secret);
  await secrets.delete(kFallbackMediaHostSecretsKey);
  return current.copyWith(mediaHostId: promoted, mediaHostConfig: current.fallbackMediaHostConfig, clearFallbackMediaHost: true);
}

/// Current values for the settings form (plain + secret).
Future<Map<String, String>> mediaHostValues(AppSettings settings, SecretStore secrets, {MediaHostSlot slot = MediaHostSlot.main}) async {
  final secret = await secrets.read(slot.secretsKey) ?? const <String, String>{};
  return {...slot.configIn(settings), ...secret};
}
