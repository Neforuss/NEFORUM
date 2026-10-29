import 'dart:isolate';
import 'dart:typed_data';

import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../platform/env.dart';
import 'media_host_config.dart';
import 'services.dart';
import 'settings.dart';

/// "Move to another device": the app side of NEFORUM's encrypted backup
/// (`neforum_core` `backup/`). The file carries accounts with their keys,
/// media hosts with theirs, settings and drafts, locked with a passphrase;
/// it is moved by hand (USB, LocalSend, Nearby Share, AirDrop). No cloud.

/// Settings that travel. An explicit allowlist: device-only ones (start at
/// sign-in, tray, browser extension, media hosts which travel separately,
/// first-run state, a pending Move, zoom and text size, the background
/// picture with its blur and dim) stay where they are.
const Set<String> kExportableSettings = {
  'themeMode',
  'accent',
  'overflow',
  'threadNumbering',
  'appendHashtags',
  'appendLink',
  'fallbackToHandoff',
  'confirmBeforePosting',
  'defaultVisibility',
  'notifyOnPublish',
  'compactPreviews',
  'textCards',
  'textCardTheme',
  'textCardFont',
  'textCardPlainPlatforms',
  'delegateSchedules',
  'photoFit',
  'fillFramePlatforms',
  'captionPhotoPlatforms',
  'defaultTargetIds',
  'publishedPostRetention',
  'timestampDisplay',
  'clockFormat',
  'discordMentionEveryone',
  'textCardHandleHiddenPlatforms',
  'textCardAlignment',
  'captionStyle',
  'cornerStyle',
  'navigationChrome',
  'customAccentColor',
  'interfaceDensity',
  'advanceHandoffOnReturn',
  'artworkMaturity',
  'artworkDisallowAiTraining',
  // 1.3: video
  'shrinkOversizedVideos',
  'textCardEveryNetwork', // 1.3: cards
  'textCardCustomFont', // 1.3.1: cards
};

Map<String, dynamic> exportableSettings(AppSettings s) => {
      for (final e in s.toJson().entries)
        if (kExportableSettings.contains(e.key)) e.key: e.value,
    };

/// [current] with [imported]'s allowed settings on top.
AppSettings withImportedSettings(AppSettings current, Map<String, dynamic> imported) => AppSettings.fromJson({
      ...current.toJson(),
      for (final e in imported.entries)
        if (kExportableSettings.contains(e.key)) e.key: e.value,
    });

/// Both media hosts with their secrets: `{"main": ..., "fallback": ...}`.
Future<Map<String, dynamic>> collectMediaHosts(AppSettings s, SecretStore secrets) async {
  Future<Map<String, dynamic>?> slot(MediaHostSlot slot) async {
    final id = slot.idIn(s);
    if (id == null) return null;
    return {'id': id, 'config': slot.configIn(s), 'secrets': await secrets.read(slot.secretsKey) ?? const <String, String>{}};
  }

  return {'main': await slot(MediaHostSlot.main), 'fallback': await slot(MediaHostSlot.fallback)};
}

/// The media hosts in a backup that this NEFORUM knows.
List<(MediaHostSlot, String)> mediaHostsIn(Map<String, dynamic>? hosts) => [
      for (final slot in MediaHostSlot.values)
        if (hosts?[slot.name] case {'id': final String id} when mediaHostRegistry.contains(id)) (slot, id),
    ];

/// Stores the backup's media hosts (main and fallback) with their secrets.
Future<AppSettings> withImportedMediaHosts(AppSettings current, SecretStore secrets, Map<String, dynamic> hosts) async {
  var s = current;
  for (final (slot, id) in mediaHostsIn(hosts)) {
    final h = hosts[slot.name] as Map;
    String str(Object? v) => v is String ? v : '$v';
    final values = <String, String>{
      if (h['config'] is Map) for (final e in (h['config'] as Map).entries) '${e.key}': str(e.value),
      if (h['secrets'] is Map) for (final e in (h['secrets'] as Map).entries) '${e.key}': str(e.value),
    };
    s = await storeMediaHost(s, secrets, id, values, slot: slot);
  }
  return s;
}

/// What goes into an export.
class ExportOptions {
  const ExportOptions({
    required this.mode,
    this.accounts = true,
    this.mediaHosts = true,
    this.settings = true,
    this.posts = true,
    this.history = false,
  });
  final BackupMode mode;
  final bool accounts;
  final bool mediaHosts;
  final bool settings;
  final bool posts;
  final bool history;
}

/// The encrypted backup file's bytes. Key stretching runs off the UI thread.
Future<Uint8List> buildDeviceBackup(AppServices s, AppSettings settings, ExportOptions o, String passphrase) async {
  final payload = await collectBackup(
    accounts: s.accounts,
    posts: s.posts,
    secrets: s.secrets,
    mode: o.mode,
    device: BackupDevice(platform: Env.platformName, appVersion: kAppVersion, label: Env.platformName),
    now: DateTime.now(),
    accountIds: o.accounts ? null : const {},
    includePosts: o.posts,
    includeHistory: o.history,
    settings: o.settings ? exportableSettings(settings) : null,
    mediaHosts: o.mediaHosts ? await collectMediaHosts(settings, s.secrets) : null,
  );
  return Isolate.run(() => encryptBackup(payload, passphrase));
}

/// The backup in [bytes], opened with [passphrase] off the UI thread.
Future<BackupPayload> openDeviceBackup(Uint8List bytes, String passphrase) async =>
    BackupPayload.parse(await Isolate.run(() => decryptBackup(bytes, passphrase)));

/// `neforum-windows-2026-10-19.neforumbackup`.
String backupFileName(DateTime now) =>
    'neforum-${Env.platformName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}-'
    '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.${BackupFormat.extension}';
