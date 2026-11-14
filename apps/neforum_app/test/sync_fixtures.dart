// Shared by the sync tests: two devices with their own storage, keychain and
// settings on one synced folder, set up with fake values only.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:neforum_app/media/font_catalog.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/platform/update_check.dart';
import 'package:neforum_app/state/cloud_sync.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/media_host_config.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class MemoryAppStorage implements AppStorage {
  final Map<String, Object> json = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => const SizedBox();
}

/// One device: its data, keychain and settings, syncing through [folder].
class SyncTestDevice {
  SyncTestDevice(this.folder, {AppSettings? settings, this.passphrase = 'a shared fake sync passphrase'})
      : settings = (settings ?? const AppSettings()).copyWith(syncProviderId: 'onedrive', syncConfig: {'folder': folder}) {
    sync = CloudSync(
      storage: storage,
      accounts: accounts,
      posts: posts,
      secrets: secrets,
      http: NeforumHttp(),
      settings: () => this.settings,
      saveSettings: (s) async => this.settings = s,
    );
  }

  final String folder;
  final String passphrase;
  final storage = MemoryAppStorage();
  final accounts = InMemoryAccountRepository();
  final posts = InMemoryPostRepository();
  final secrets = InMemorySecretStore();
  AppSettings settings;
  late final CloudSync sync;
  bool _started = false;

  /// One sync, starting sync on the first call. Fails the test on an error.
  Future<SyncReport> syncOnce() async {
    if (!_started) {
      await secrets.write(kSyncSecretsKey, {'passphrase': passphrase});
      await sync.start(background: true);
      _started = true;
    }
    final r = await sync.syncNow();
    if (r == null) throw StateError('sync failed: ${sync.status.value.message}');
    return r;
  }

  Future<void> addAccount(ConnectedAccount a, {Map<String, String>? keys}) async {
    await accounts.upsert(a);
    if (keys != null) await secrets.write(a.id, keys);
  }

  Future<void> addMediaHost(MediaHostSlot slot, String id, Map<String, String> values) async {
    settings = await storeMediaHost(settings, secrets, id, values, slot: slot);
  }

  void dispose() => sync.dispose();
}

/// A temporary synced folder, and a computer (on a phone a folder is a
/// picked location instead), for one test.
Future<String> syncFolderForTest(void Function(void Function()) addTearDown) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  final dir = await Directory.systemTemp.createTemp('neforum-sync-parity-');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir.path;
}

/// Every setting changed from its default (the values are made up). Used to
/// prove that every setting is classified and that every shared one travels.
AppSettings populatedSettings() => AppSettings(
      themeMode: ThemeMode.dark,
      accent: AccentChoice.custom,
      overflow: OverflowStrategy.truncate,
      threadNumbering: false,
      appendHashtags: false,
      appendLink: false,
      fallbackToHandoff: false,
      confirmBeforePosting: true,
      defaultVisibility: PostVisibility.unlisted,
      startAtLogin: true,
      minimizeToTray: false,
      notifyOnPublish: false,
      mediaHostId: 'catbox',
      mediaHostConfig: const {'note': 'fake'},
      fallbackMediaHostId: 'litterbox',
      fallbackMediaHostConfig: const {'time': '72h'},
      defaultTargetIds: const ['acct-1', 'acct-2'],
      onboarded: true,
      compactPreviews: true,
      textCards: false,
      textCardTheme: TextCardTheme.light,
      textCardFont: TextCardFont.arial,
      textCardPlainPlatforms: const ['x'],
      delegateSchedules: false,
      browserExtension: false,
      browserQuickPost: false,
      browserOpenInFirst: false,
      photoFit: PhotoFitMode.crop,
      fillFramePlatforms: const ['tiktok'],
      captionPhotoPlatforms: const ['instagram'],
      captionOnStory: false, // 1.4.1
      movedAccountIds: const ['moved-1'],
      movedAt: DateTime.utc(2026, 10, 1),
      syncProviderId: 'dropbox',
      syncConfig: const {'folder': '/fake/Dropbox/NEFORUM'},
      uiZoom: 1.25,
      publishedPostRetention: PublishedPostRetention.retainThirtyDays,
      timestampDisplay: TimestampDisplay.exact,
      clockFormat: ClockFormat.twentyFourHour,
      discordMentionEveryone: false,
      textCardHandleHiddenPlatforms: const ['bluesky'],
      textCardAlignment: TextCardAlignment.center,
      captionStyle: const {'size': 0.08, 'position': 'bottom'},
      cornerStyle: CornerStyle.square,
      navigationChrome: NavigationChromeStyle.transparent,
      customAccentColor: 0xFF336699,
      interfaceDensity: InterfaceDensity.compact,
      mobileTextScale: 1.2,
      collapsedSettingsSections: const ['sync'],
      targetPickerFolded: true,
      automaticHandoffPosting: true,
      automaticHandoffExcludedPlatforms: const ['snapchat'],
      advanceHandoffOnReturn: false,
      artworkMaturity: ArtworkMaturity.mature,
      artworkDisallowAiTraining: false,
      shrinkOversizedVideos: true,
      backgroundImagePath: '/fake/data/background.jpg',
      backgroundBlur: 12,
      backgroundDim: 0.6,
      updateCheck: UpdateCheckMode.off,
      fontDownloads: FontDownloadMode.on,
      emojiRecents: const ['\u{1F600}'],
      emojiSkinTone: 3,
      notificationPromptAt: DateTime.utc(2026, 11, 1),
      notificationOsAskedAt: DateTime.utc(2026, 11, 2),
      notificationHintShownAt: DateTime.utc(2026, 11, 3),
      notificationBannerClosedAt: DateTime.utc(2026, 11, 4),
      updateCheckedAt: DateTime.utc(2026, 10, 30),
      updateLatestRelease: const {'version': '9.9.9'},
      updateDismissedVersion: '9.9.8',
      textCardEveryNetwork: true,
      navigationChromeOpacity: 0.5,
      navigationChromeBlur: 8,
      navigationChromeColor: 0xFF225588, // 1.4.3: colours
      navigationChromeTint: 0xFFEEDDCC, // 1.4.3: colours
      audioTextTemplate: '{title}',
      textCardCustomFont: const {'family': 'Fake Sans', 'source': 'installed'},
      textCardDesign: const {'background': 'gradient', 'radius': 0.1},
      audioCardDesign: const {'background': 'cover'},
      cardPresets: const [
        {'name': 'Fake preset', 'design': {'background': 'solid'}},
      ],
    );

/// A second setup, different from both the defaults and [populatedSettings]
/// in every shared setting it touches.
AppSettings otherSettings() => const AppSettings(
      themeMode: ThemeMode.light,
      accent: AccentChoice.jade,
      overflow: OverflowStrategy.error,
      confirmBeforePosting: true,
      defaultVisibility: PostVisibility.followers,
      textCardFont: TextCardFont.timesNewRoman,
      photoFit: PhotoFitMode.color,
      captionStyle: {'size': 0.05},
      customAccentColor: 0xFF00AA55,
      navigationChromeOpacity: 0.25,
      cardPresets: [
        {'name': 'Other preset'},
      ],
      textCardDesign: {'background': 'solid'},
      browserQuickPost: false,
    );

ConnectedAccount fakeAccount(String id, String platform,
        {PlatformTier tier = PlatformTier.openApi, String? handle, String? name, DateTime? createdAt, Map<String, dynamic> config = const {}}) =>
    ConnectedAccount(
      id: id,
      platformId: platform,
      tier: tier,
      displayName: name ?? '$platform $id',
      handle: handle,
      createdAt: createdAt ?? DateTime.utc(2026, 9, 1),
      config: config,
    );

/// Every path where [a] and [b] differ (`settings.captionStyle`,
/// `accounts.<id>`), for failure messages that list every gap at once
/// instead of the first one. Values are left out: they may be keys.
List<String> diffPaths(Object? a, Object? b, [String at = '']) {
  if (a is Map && b is Map) {
    return [
      for (final k in {...a.keys, ...b.keys})
        if (!a.containsKey(k) || !b.containsKey(k)) '${at.isEmpty ? '' : '$at.'}$k (only on one side)' else ...diffPaths(a[k], b[k], at.isEmpty ? '$k' : '$at.$k'),
    ];
  }
  if (a is List && b is List && a.length == b.length) {
    return [for (var i = 0; i < a.length; i++) ...diffPaths(a[i], b[i], '$at[$i]')];
  }
  return '$a' == '$b' ? const [] : [at];
}

/// What a device's setup is, normalized for comparing two devices: every
/// account (without [deviceOnlyAccountFields]), every account's keys, both
/// media hosts with their keys, and every setting outside [deviceOnlySettings].
Future<Map<String, Object?>> setupOf(SyncTestDevice d, {required Set<String> deviceOnlySettings, required Set<String> deviceOnlyAccountFields}) async {
  final accounts = await d.accounts.all();
  return {
    'accounts': {
      for (final a in accounts) a.id: {for (final e in a.toJson().entries) if (!deviceOnlyAccountFields.contains(e.key)) e.key: e.value},
    },
    'keys': {for (final a in accounts) a.id: await d.secrets.read(a.id)},
    'mediaHosts': await collectMediaHosts(d.settings, d.secrets),
    'settings': {for (final e in d.settings.toJson().entries) if (!deviceOnlySettings.contains(e.key)) e.key: e.value},
  };
}
