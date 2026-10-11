import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'settings.dart';

/// Secret-store key holding the media host's secret fields (keys, passwords).
const String kMediaHostSecretsKey = 'neforum.mediahost';

/// Every media host kind NEFORUM ships with.
final MediaHostRegistry mediaHostRegistry = MediaHostRegistry.builtIn();

/// Hosts the settings screen offers, recommended first.
List<MediaHostDescriptor> mediaHostOptions() => mediaHostRegistry.descriptors;

/// Builds the configured public media host, or null when none is set (or
/// its settings are incomplete).
Future<MediaHost?> buildMediaHost(AppSettings settings, SecretStore secrets, NeforumHttp http) async {
  final id = settings.mediaHostId;
  if (id == null || !mediaHostRegistry.contains(id)) return null;
  final secret = await secrets.read(kMediaHostSecretsKey) ?? const <String, String>{};
  try {
    return mediaHostRegistry.create(id, {...settings.mediaHostConfig, ...secret}, http);
  } on MediaHostException {
    return null;
  }
}

/// Creates a host from values the user is still editing (for "Test").
MediaHost createMediaHostFrom(String id, Map<String, String> values, NeforumHttp http) =>
    mediaHostRegistry.create(id, values, http);

/// Splits [values] into settings (plain) and keychain (secret) parts and
/// stores the secret part. Returns the settings to save.
Future<AppSettings> storeMediaHost(AppSettings current, SecretStore secrets, String id, Map<String, String> values) async {
  final parts = mediaHostRegistry.split(id, values);
  await secrets.write(kMediaHostSecretsKey, parts.secrets);
  return current.copyWith(mediaHostId: id, mediaHostConfig: parts.plain);
}

/// Removes the configured host and its secrets.
Future<AppSettings> clearMediaHost(AppSettings current, SecretStore secrets) async {
  await secrets.delete(kMediaHostSecretsKey);
  return current.copyWith(clearMediaHost: true);
}

/// Current values for the settings form (plain + secret).
Future<Map<String, String>> mediaHostValues(AppSettings settings, SecretStore secrets) async {
  final secret = await secrets.read(kMediaHostSecretsKey) ?? const <String, String>{};
  return {...settings.mediaHostConfig, ...secret};
}
