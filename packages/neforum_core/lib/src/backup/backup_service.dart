import 'package:meta/meta.dart';

import '../adapters/adapter_registry.dart';
import '../model/account.dart';
import '../model/platform_descriptor.dart';
import '../model/post.dart';
import '../storage/repositories.dart';
import '../storage/secret_store.dart';
import 'backup_format.dart';

/// Copy: both devices keep the accounts. Move: the old device switches them
/// off once exported, and removes them when the user confirms the import.
enum BackupMode { copy, move }

/// The device a backup was made on, shown in the import preview.
@immutable
class BackupDevice {
  const BackupDevice({required this.platform, required this.appVersion, this.label});
  final String platform;
  final String appVersion;
  final String? label;

  Map<String, dynamic> toJson() => {'platform': platform, 'appVersion': appVersion, if (label != null) 'label': label};
}

/// One account in a backup: the account and its keys.
@immutable
class BackupAccount {
  const BackupAccount(this.account, this.secrets);
  final ConnectedAccount account;
  final Map<String, String> secrets;
}

/// The decrypted contents of a backup, validated.
@immutable
class BackupPayload {
  const BackupPayload({
    required this.mode,
    required this.accounts,
    this.exportedAt,
    this.device,
    this.settings,
    this.mediaHosts,
    this.posts = const [],
    this.skipped = 0,
  });

  /// Reads [j] (the decrypted JSON). It is untrusted input: anything that
  /// does not parse is skipped and counted in [skipped].
  factory BackupPayload.parse(Map<String, dynamic> j) {
    if (j['app'] != 'NEFORUM') {
      throw const BackupException(BackupErrorKind.invalidContent, 'This file is not a NEFORUM backup.');
    }
    final version = j['payloadVersion'];
    if (version is! int) throw const BackupException(BackupErrorKind.invalidContent, 'The backup has no version.');
    if (version > payloadVersion) {
      throw const BackupException(BackupErrorKind.tooNew, 'This backup was made by a newer NEFORUM. Update NEFORUM here first.');
    }
    var skipped = 0;
    final accounts = <BackupAccount>[];
    for (final raw in (j['accounts'] is List ? j['accounts'] as List : const <Object?>[])) {
      try {
        final m = raw as Map;
        final account = ConnectedAccount.fromJson(Map<String, dynamic>.from(m['account'] as Map));
        final secretsRaw = m['secrets'];
        final secrets = <String, String>{
          if (secretsRaw is Map)
            for (final e in secretsRaw.entries)
              if (e.key is String && e.value is String) e.key as String: e.value as String,
        };
        if (account.id.isEmpty || account.platformId.isEmpty) throw const FormatException('empty id');
        accounts.add(BackupAccount(account, secrets));
      } on Object {
        skipped++;
      }
    }
    final posts = <Post>[];
    for (final raw in (j['posts'] is List ? j['posts'] as List : const <Object?>[])) {
      try {
        posts.add(Post.fromJson(Map<String, dynamic>.from(raw as Map)));
      } on Object {
        skipped++;
      }
    }
    Map<String, dynamic>? map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : null;
    final device = map(j['fromDevice']);
    return BackupPayload(
      mode: j['mode'] == 'move' ? BackupMode.move : BackupMode.copy,
      exportedAt: DateTime.tryParse('${j['exportedAt'] ?? ''}'),
      device: device == null
          ? null
          : BackupDevice(platform: '${device['platform'] ?? ''}', appVersion: '${device['appVersion'] ?? ''}', label: device['label'] as String?),
      accounts: accounts,
      settings: map(j['settings']),
      mediaHosts: map(j['mediaHosts']),
      posts: posts,
      skipped: skipped,
    );
  }

  static const int payloadVersion = 1;

  final BackupMode mode;
  final DateTime? exportedAt;
  final BackupDevice? device;
  final List<BackupAccount> accounts;

  /// The app's exportable settings (the app decides which keys).
  final Map<String, dynamic>? settings;

  /// `{"main": {"id", "config", "secrets"} | null, "fallback": ... }`, built
  /// and applied by the app.
  final Map<String, dynamic>? mediaHosts;

  /// Drafts, and posts that were scheduled on the old device (they become
  /// drafts on import, see [applyBackup]).
  final List<Post> posts;

  /// Entries that could not be read.
  final int skipped;
}

/// Gathers a backup's payload: [accountIds] (all when null) with their keys
/// from [secrets], drafts and device-scheduled posts when [includePosts],
/// published history when [includeHistory], plus the app's [settings] and
/// [mediaHosts] as given. Photos and videos are not included.
Future<Map<String, dynamic>> collectBackup({
  required AccountRepository accounts,
  required PostRepository posts,
  required SecretStore secrets,
  required BackupMode mode,
  required BackupDevice device,
  required DateTime now,
  Set<String>? accountIds,
  bool includePosts = true,
  bool includeHistory = false,
  Map<String, dynamic>? settings,
  Map<String, dynamic>? mediaHosts,
}) async {
  final chosen = [for (final a in await accounts.all()) if (accountIds == null || accountIds.contains(a.id)) a];
  final list = <Map<String, dynamic>>[];
  for (final a in chosen) {
    list.add({'account': a.toJson(), 'secrets': await secrets.read(a.id) ?? const <String, String>{}});
  }
  final postList = <Map<String, dynamic>>[];
  if (includePosts || includeHistory) {
    for (final p in await posts.all()) {
      final pending = p.status == PostStatus.draft || p.status == PostStatus.scheduled;
      if ((pending && includePosts) || (!pending && includeHistory)) postList.add(p.toJson());
    }
  }
  return {
    'app': 'NEFORUM',
    'payloadVersion': BackupPayload.payloadVersion,
    'exportedAt': now.toUtc().toIso8601String(),
    'fromDevice': device.toJson(),
    'mode': mode.name,
    'accounts': list,
    'mediaHosts': mediaHosts,
    'settings': settings,
    'posts': postList,
  };
}

/// What happens to one account from a backup.
enum ImportChoice {
  /// Not on this device yet: add it.
  add,

  /// The same account is here: replace it (and its keys) with the backup's.
  replace,

  /// The same account is here: keep this device's.
  keep,
}

/// One account in the import preview.
@immutable
class ImportCandidate {
  const ImportCandidate({required this.item, this.existing, this.rotatesTokens = false});
  final BackupAccount item;

  /// The same account already on this device: same id, or for hand-off
  /// accounts (random ids) the same network and name.
  final ConnectedAccount? existing;

  /// The network renews keys one device at a time ([PlatformAdapter.rotatesRefreshTokens]).
  final bool rotatesTokens;

  ImportChoice get defaultChoice => existing == null ? ImportChoice.add : (existing!.id == item.account.id ? ImportChoice.replace : ImportChoice.keep);
}

/// The accounts in [payload] matched against [existing] (this device's).
List<ImportCandidate> previewImport(BackupPayload payload, List<ConnectedAccount> existing, {AdapterRegistry? registry}) {
  final byId = {for (final a in existing) a.id: a};
  return [
    for (final item in payload.accounts)
      ImportCandidate(
        item: item,
        existing: byId[item.account.id] ?? _sameHandoff(item.account, existing),
        // Only accounts that hold keys (a hand-off account has none).
        rotatesTokens: item.account.tier != PlatformTier.handoff &&
            item.secrets.isNotEmpty &&
            (registry?.byId(item.account.platformId)?.rotatesRefreshTokens ?? false),
      ),
  ];
}

/// Hand-off accounts get random ids, so the same one made on two devices has
/// two ids: match it by network, tier and name instead.
ConnectedAccount? _sameHandoff(ConnectedAccount a, List<ConnectedAccount> existing) {
  if (a.tier != PlatformTier.handoff) return null;
  for (final e in existing) {
    if (e.platformId == a.platformId && e.tier == a.tier && e.displayName == a.displayName) return e;
  }
  return null;
}

/// What an import did.
@immutable
class ImportReport {
  const ImportReport({required this.added, required this.replaced, required this.kept, required this.posts, this.attention = const []});
  final int added;
  final int replaced;
  final int kept;
  final int posts;

  /// Things the user should do now ("X: reconnect on one device").
  final List<String> attention;

  int get accounts => added + replaced;
}

/// Writes the accounts the user chose ([choices] by backup account id;
/// missing = the candidate's default) with their keys, and, when
/// [importPosts], the posts: posts that were scheduled on the old device
/// arrive as drafts (with their time kept) so both devices never publish
/// them, targets a platform already holds are left out (that platform
/// publishes them itself), and photos and videos (not in the backup) are
/// dropped. Posts already here are left alone.
Future<ImportReport> applyBackup(
  BackupPayload payload, {
  required List<ImportCandidate> candidates,
  required AccountRepository accounts,
  required PostRepository posts,
  required SecretStore secrets,
  Map<String, ImportChoice> choices = const {},
  Set<String>? selected,
  bool importPosts = true,
}) async {
  var added = 0, replaced = 0, kept = 0, postCount = 0;
  final attention = <String>[];
  final rotated = <String>{};
  for (final c in candidates) {
    final id = c.item.account.id;
    if (selected != null && !selected.contains(id)) continue;
    final choice = choices[id] ?? c.defaultChoice;
    if (choice == ImportChoice.keep) {
      kept++;
      continue;
    }
    // Replace keeps this device's id for a hand-off account matched by name.
    final targetId = c.existing?.id ?? id;
    final account = c.item.account.copyWith(enabled: true);
    await accounts.upsert(targetId == id ? account : _withId(account, targetId));
    if (c.item.secrets.isNotEmpty) {
      await secrets.write(targetId, c.item.secrets);
    }
    if (c.existing == null) {
      added++;
    } else {
      replaced++;
    }
    if (c.rotatesTokens && payload.mode == BackupMode.copy) rotated.add(_networkName(c.item.account));
  }
  for (final name in rotated) {
    attention.add('$name stays connected on only one device: reconnect it on the device that should keep it.');
  }

  if (importPosts) {
    for (final p in payload.posts) {
      if (await posts.get(p.id) != null) continue;
      await posts.upsert(_arrivingPost(p));
      postCount++;
    }
  }
  return ImportReport(added: added, replaced: replaced, kept: kept, posts: postCount, attention: attention);
}

Post _arrivingPost(Post p) {
  final pending = p.status == PostStatus.scheduled || p.status == PostStatus.draft;
  final targets = [
    for (final t in p.targets)
      if (!t.isHeldByPlatform) t.copyWith(overrides: t.overrides.copyWith(clearMediaIds: true)),
  ];
  return p.copyWith(
    status: pending ? PostStatus.draft : p.status,
    media: const [],
    targets: targets,
  );
}

ConnectedAccount _withId(ConnectedAccount a, String id) => ConnectedAccount.fromJson({...a.toJson(), 'id': id});

String _networkName(ConnectedAccount a) => switch (a.platformId) {
      'x' => 'X',
      'tumblr' => 'Tumblr',
      _ => a.platformId,
    };
