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

/// Settings that travel, with "Move to another device" and with Sync. An
/// explicit allowlist: every other setting is in [kDeviceOnlySettings], and a
/// test fails when a setting is in neither or in both.
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
  // 1.3.1: sidebar
  'navigationChromeOpacity',
  'navigationChromeBlur',
  'textCardCustomFont', // 1.3.1: cards
  'textCardDesign', // 1.3.1: cards
  'audioCardDesign', // 1.3.1: cards
  'cardPresets', // 1.3.1: cards
  'audioTextTemplate', // 1.3.1: audio tags
  // 1.3.5: how the browser extension behaves once it filled a page in. A
  // preference, not a pairing: phones ignore it.
  'browserQuickPost',
  'browserOpenInFirst',
};

/// 1.3.5: the settings that stay on the device, each with why. Together with
/// [kExportableSettings] it covers every key of AppSettings.toJson.
const Map<String, String> kDeviceOnlySettings = {
  'startAtLogin': "Registers NEFORUM with this computer's sign-in; phones have none.",
  'minimizeToTray': 'Whether this computer keeps NEFORUM running in its tray when the window closes: each computer decides for itself.',
  'onboarded': 'The first-run tour of this install.',
  'browserExtension': 'Opens a server on 127.0.0.1 on this computer for the browsers paired with it.',
  'movedAccountIds': 'A Move in progress from this device: accounts switched off here until the other device has them.',
  'movedAt': 'When that Move started on this device.',
  'syncProviderId': 'How this device reaches the sync file; another device reaches it its own way.',
  'syncConfig': "This device's folder, bookmark or address of the sync file.",
  'uiZoom': 'How big this screen draws everything.',
  'mobileTextScale': "This phone's or tablet's text size.",
  'collapsedSettingsSections': 'Which Settings sections are folded away in this window.',
  'targetPickerFolded': "Whether this phone's composer shows the account grid or its one-line summary.",
  'automaticHandoffPosting': 'Lets the browser extension on this computer press Post by itself: switched on per computer, never by another device.',
  'automaticHandoffExcludedPlatforms': 'Goes with automaticHandoffPosting on this computer.',
  'backgroundImagePath': "A picture file in this device's data folder.",
  'backgroundBlur': 'Goes with the background picture, which stays on this device.',
  'backgroundDim': 'Goes with the background picture, which stays on this device.',
  'updateCheck': 'Each install updates its own way (a store build never checks).',
  'updateCheckedAt': 'When this install last asked for updates.',
  'updateLatestRelease': "This install's copy of the last answer about updates.",
  'updateDismissedVersion': 'The update banner this install closed.',
  'fontDownloads': 'Agreeing to contact the font services is per device, like the update check; a font style that syncs never turns it on.',
  // Not settings records, but not device-only either: the media hosts travel
  // as one record with their keys (mediaHosts:all), so a host never arrives
  // without the keys it needs.
  'mediaHostId': 'Travels with its keys in the media hosts record, not as a setting.',
  'mediaHostConfig': 'Travels with its keys in the media hosts record, not as a setting.',
  'fallbackMediaHostId': 'Travels with its keys in the media hosts record, not as a setting.',
  'fallbackMediaHostConfig': 'Travels with its keys in the media hosts record, not as a setting.',
};

/// 1.3.5: the shared settings AppSettings.toJson leaves out while they have
/// their default, with that default. Sync carries every shared setting with
/// its value ([syncedSettings]), so that a setting put back to its default
/// travels like any other change and the setup that wins a first sync wins
/// whole. A test fails when a shared setting is missing from both toJson and
/// this map.
const Map<String, Object?> kSettingDefaultsLeftOut = {
  'captionStyle': <String, Object?>{},
  'customAccentColor': null,
  'navigationChromeOpacity': 0.0,
  'navigationChromeBlur': 0.0,
  'textCardCustomFont': <String, Object?>{},
  'textCardDesign': <String, Object?>{},
  'audioCardDesign': <String, Object?>{},
  'cardPresets': <Object?>[],
};

/// 1.3.5: every shared setting of [s] with its value, defaults included, as
/// the sync file carries them.
Map<String, Object?> syncedSettings(AppSettings s) {
  final j = s.toJson();
  return {for (final k in kExportableSettings) k: j.containsKey(k) ? j[k] : kSettingDefaultsLeftOut[k]};
}

Map<String, dynamic> exportableSettings(AppSettings s) => {
      for (final e in s.toJson().entries)
        if (kExportableSettings.contains(e.key)) e.key: e.value,
    };

/// [current] with [imported]'s allowed settings on top. A `null` value puts
/// that setting back to its default.
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

/// 1.3.5: the media hosts both devices keep after a first sync where both
/// had some ([collectMediaHosts] records). The winning side keeps its hosts
/// in their slots. Every host of the other side that the winning side does
/// not have goes into a slot left empty: its own slot when that one is free,
/// otherwise the other one. A host is only dropped when both slots are
/// taken, and the dry run names it ([mediaHostChanges]).
Map<String, Object?> mergeMediaHostsOnJoin(Object? here, Object? file, {required bool hereWins}) {
  final first = hereWins ? here : file, second = hereWins ? file : here;
  final slots = [for (final s in MediaHostSlot.values) s.name];
  final merged = <String, Object?>{for (final s in slots) s: _hostIn(first, s)};
  bool kept(Map<Object?, Object?> host) => merged.values.any((h) => _sameHost(h, host));
  for (final s in slots) {
    final host = _hostIn(second, s);
    if (host != null && merged[s] == null && !kept(host)) merged[s] = host;
  }
  for (final s in slots) {
    final host = _hostIn(second, s);
    if (host == null || kept(host)) continue;
    final free = slots.where((n) => merged[n] == null).firstOrNull;
    if (free != null) merged[free] = host;
  }
  return merged;
}

Map<Object?, Object?>? _hostIn(Object? hosts, String slot) => hosts is Map && hosts[slot] is Map ? hosts[slot] as Map<Object?, Object?> : null;

bool _sameHost(Object? a, Object? b) => a != null && b != null && syncHash(a) == syncHash(b);

/// 1.3.5: one media host as a dry run names it: its slot (`main`,
/// `fallback`) and its kind (a [MediaHostDescriptor] id).
typedef MediaHostPlace = ({String slot, String id});

/// 1.3.5: what happens to one side's media hosts when [before] becomes
/// [after] ([collectMediaHosts] records): the hosts that arrive, the ones
/// that are removed (with what takes their slot, if anything), and the ones
/// that move to the other slot. Hosts are compared whole (kind, settings,
/// keys).
({List<MediaHostPlace> arrived, List<({MediaHostPlace host, String? replacedBy})> removed, List<({MediaHostPlace host, String to})> moved})
    mediaHostChanges(Object? before, Object? after) {
  String? slotOf(Object? hosts, Object? host) => MediaHostSlot.values.map((s) => s.name).where((n) => _sameHost(_hostIn(hosts, n), host)).firstOrNull;
  MediaHostPlace place(String slot, Map<Object?, Object?> h) => (slot: slot, id: '${h['id']}');
  final arrived = <MediaHostPlace>[];
  final removed = <({MediaHostPlace host, String? replacedBy})>[];
  final moved = <({MediaHostPlace host, String to})>[];
  for (final s in MediaHostSlot.values.map((x) => x.name)) {
    final now = _hostIn(after, s), was = _hostIn(before, s);
    if (now != null && slotOf(before, now) == null) arrived.add(place(s, now));
    if (was == null) continue;
    final to = slotOf(after, was);
    if (to == null) {
      removed.add((host: place(s, was), replacedBy: now == null ? null : '${now['id']}'));
    } else if (to != s) {
      moved.add((host: place(s, was), to: to));
    }
  }
  return (arrived: arrived, removed: removed, moved: moved);
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
