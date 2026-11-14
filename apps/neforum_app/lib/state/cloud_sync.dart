import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:uuid/uuid.dart';

import '../platform/device_name.dart';
import '../platform/env.dart';
import '../platform/file_exists.dart';
import '../platform/files_app_folder.dart';
import '../platform/folder_access.dart';
import '../platform/storage.dart';
import 'device_transfer.dart';
import 'media_host_config.dart';
import 'settings.dart';

/// Keychain entry with the sync passphrase and the storage password or key.
const String kSyncSecretsKey = 'neforum.sync';

/// Keychain entry with this device's Google Drive sign-in (access and refresh
/// token). Kept apart from [kSyncSecretsKey] so an hourly token renewal does
/// not look like a changed setup, and never synced: each device signs in.
const String kSyncOAuthKey = 'neforum.sync.oauth';

/// What the sync settings show.
enum CloudSyncPhase { off, syncing, ok, error }

@immutable
class CloudSyncStatus {
  const CloudSyncStatus(this.phase, {this.lastSyncAt, this.message, this.devices = const {}, this.deviceId});
  final CloudSyncPhase phase;
  final DateTime? lastSyncAt;

  /// The last error, fit to show.
  final String? message;
  final Map<String, SyncDeviceInfo> devices;
  final String? deviceId;
}

/// The values the sync form collects for [providerId] (non-secret ones go
/// to [AppSettings.syncConfig], `passphrase`, `password`, `secretAccessKey`
/// and `clientSecret` to the keychain).
const Set<String> kSyncSecretFields = {'passphrase', 'password', 'secretAccessKey', 'clientSecret'};

/// The storage [settings] point at, or `null` when sync is off or the setup
/// is incomplete. On a phone or tablet ([filesApp], default: iOS and
/// Android) a folder provider is a location picked in the system file picker
/// (a folder, or the sync file itself when `target` is `file`); on a computer
/// it is a plain folder. Google Drive (direct) needs this device's sign-in
/// ([oauth], tokens as [OAuthTokens.toSecrets] stores them) and a way to keep
/// renewed tokens ([saveOAuth]).
SyncBackend? buildSyncBackend(AppSettings settings, Map<String, String> secrets, NeforumHttp http,
    {String? folderOverride, bool? filesApp, Map<String, String>? oauth, Future<void> Function(Map<String, String>)? saveOAuth}) {
  final provider = syncProviderById(settings.syncProviderId);
  if (provider == null) return null;
  final c = settings.syncConfig;
  String? v(String k) {
    final s = c[k]?.trim();
    return s == null || s.isEmpty ? null : s;
  }

  switch (provider.kind) {
    case SyncBackendKind.folder:
      if (filesApp ?? Env.isMobile) {
        final bookmark = v('bookmark');
        return bookmark == null ? null : FilesAppSyncBackend(bookmark, folderName: v('folder') ?? provider.name, isFile: v('target') == 'file');
      }
      final folder = folderOverride ?? v('folder');
      return folder == null ? null : FolderSyncBackend(folder);
    case SyncBackendKind.googleDrive:
      final clientId = v('clientId');
      if (clientId == null || oauth == null || OAuthTokens.fromSecrets(oauth) == null) return null;
      final tokens = OAuthTokenSource(
        client: OAuthTokenSource.googleDriveClient(clientId: clientId, clientSecret: secrets['clientSecret']),
        http: http,
        secrets: oauth,
        save: saveOAuth ?? (_) async {},
      );
      return GoogleDriveSyncBackend(http: http, token: tokens.accessToken);
    case SyncBackendKind.webdav:
      final url = v('url'), user = v('username'), password = secrets['password'];
      if (url == null || user == null || password == null || password.isEmpty) return null;
      return WebDavSyncBackend(http: http, folderUrl: Uri.parse(url), username: user, password: password);
    case SyncBackendKind.s3:
      final endpoint = v('endpoint'), bucket = v('bucket'), key = v('accessKeyId'), secret = secrets['secretAccessKey'];
      if (endpoint == null || bucket == null || key == null || secret == null || secret.isEmpty) return null;
      return S3SyncBackend(
        http: http,
        endpoint: Uri.parse(endpoint),
        bucket: bucket,
        accessKeyId: key,
        secretAccessKey: secret,
        region: v('region') ?? provider.region,
        folder: v('folder') ?? '',
        addressing: S3AddressingStyle.values.asNameMap()[v('addressing')?.toLowerCase()] ?? S3AddressingStyle.auto,
      );
  }
}

/// 1.3.5: what tells one sync file from another for [providerId] with
/// [config] (as the sync form collects it): the folder on a computer, the
/// picked location on a phone or tablet ([filesApp]), the Google Cloud
/// client, the WebDAV address and user, the S3 endpoint, bucket and folder.
/// Two setups with the same identity reach the same file; a different one is
/// a new file, which gets a fresh dry run and a fresh sync state. A Mac's
/// saved folder bookmark is not part of it (the form never has one).
String syncStorageIdentity(String? providerId, Map<String, String> config, {required bool filesApp}) {
  final provider = syncProviderById(providerId);
  if (provider == null) return '';
  String v(String k) => (config[k] ?? '').trim();
  String url(String k) => v(k).replaceFirst(RegExp(r'/+$'), '').toLowerCase();
  final parts = switch (provider.kind) {
    SyncBackendKind.folder => filesApp ? [v('bookmark'), v('target')] : [v('folder')],
    SyncBackendKind.googleDrive => [v('clientId')],
    SyncBackendKind.webdav => [url('url'), v('username')],
    SyncBackendKind.s3 => [url('endpoint'), v('bucket'), v('folder').replaceAll(RegExp(r'^/+|/+$'), '')],
  };
  return [provider.kind.name, ...parts].join('\n');
}

/// Key stretching on a background isolate, so the window never stalls.
Future<List<int>> _deriveOffThread(String passphrase, List<int> salt, BackupKdfParams params) =>
    Isolate.run(() => deriveBackupKey(passphrase, salt, params));

/// The sync file in [bytes] opened with [passphrase] on a background
/// isolate. A top-level function on purpose: a closure written inside a
/// widget's method can carry that widget's state along, which cannot be sent
/// to another isolate ("object is unsendable").
Future<Map<String, dynamic>> openSyncFileOffThread(String passphrase, Uint8List bytes) =>
    Isolate.run(() => BackupCipher(passphrase).open(bytes));

/// How many accounts the opened sync file holds (0 if it cannot be read).
int accountsInSyncFile(Map<String, dynamic> opened) {
  try {
    return SyncDocument.parse(opened).records.entries.where((e) => e.key.startsWith('account:') && !e.value.deleted).length;
  } on Object {
    return 0;
  }
}

/// The sync file's state on this device (sync-state.json).
class _StateFile implements SyncStateStore {
  _StateFile(this.storage);
  final AppStorage storage;
  @override
  Future<Map<String, dynamic>?> read() => storage.readJson('sync-state.json');
  @override
  Future<void> write(Map<String, dynamic> state) => storage.writeJson('sync-state.json', state);
}

/// Runs NEFORUM's cloud sync on this device: builds the [SyncEngine] from
/// the settings, syncs at start, every few minutes and shortly after every
/// change, and answers the publisher's questions (may this device publish a
/// due post; renew a shared X or Tumblr sign-in in step with the others).
class CloudSync implements SecretsCoordinator {
  CloudSync({
    required this.storage,
    required this.accounts,
    required this.posts,
    required this.secrets,
    required this.http,
    required AppSettings Function() settings,
    required Future<void> Function(AppSettings) saveSettings,
    this.interval = const Duration(minutes: 5),
    this.debounce = const Duration(seconds: 8),
  })  : _currentSettings = settings,
        _storeSettings = saveSettings;

  final AppStorage storage;
  final AccountRepository accounts;
  final PostRepository posts;
  final SecretStore secrets;
  final NeforumHttp http;
  final AppSettings Function() _currentSettings;
  final Future<void> Function(AppSettings) _storeSettings;
  final Duration interval;
  final Duration debounce;

  final ValueNotifier<CloudSyncStatus> status = ValueNotifier(const CloudSyncStatus(CloudSyncPhase.off));

  SyncEngine? _engine;
  String? _engineKey;
  String? _deviceId;
  Timer? _timer;
  Timer? _soon;
  final List<StreamSubscription<void>> _subs = [];
  bool _running = false;
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Bumped whenever the engine is replaced or dropped: a sync still running
  /// in an old engine must not save a renewed Google sign-in any more.
  int _generation = 0;

  /// Whether sync is set up and working on this device.
  bool get active => _engine != null;

  SyncEngine? get engine => _engine;

  /// Builds (or rebuilds after a settings change) the engine and starts the
  /// timers. [background] runs (phone background tasks) sync once, no timers.
  Future<void> start({bool background = false}) async {
    await _rebuild();
    if (_engine == null || background) return;
    _timer ??= Timer.periodic(interval, (_) => unawaited(syncNow()));
    if (_subs.isEmpty) {
      _subs
        ..add(accounts.changes.listen((_) => _changed()))
        ..add(posts.changes.listen((_) => _changed()));
    }
    unawaited(syncNow());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _soon?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
  }

  /// Call after settings were saved: picks up a new storage or passphrase,
  /// and syncs settings that travel.
  Future<void> settingsChanged() async {
    final key = await _configKey();
    if (key != _engineKey) {
      stop();
      await start();
    } else {
      _changed();
    }
  }

  /// Drops the engine now, before the Sync settings write or delete the
  /// keychain entries, so a sync still in flight cannot save a renewed
  /// Google sign-in over them. The next [settingsChanged] always rebuilds.
  void detach() {
    _generation++;
    stop();
    _engine?.dispose();
    _engine = null;
    _engineKey = null;
  }

  void _changed() {
    if (_engine == null || _running || DateTime.now().isBefore(_quietUntil)) return;
    _soon?.cancel();
    _soon = Timer(debounce, () => unawaited(syncNow()));
  }

  Future<String> _configKey() async {
    final s = _currentSettings();
    final secret = await secrets.read(kSyncSecretsKey) ?? const <String, String>{};
    // A new Google sign-in changes the refresh token; the hourly renewal of
    // the access token does not, so it does not rebuild the engine.
    final refresh = (await secrets.read(kSyncOAuthKey))?['refresh_token'];
    return syncHash({'provider': s.syncProviderId, 'config': s.syncConfig, 'secrets': secret, 'signIn': ?refresh});
  }

  Future<void> _rebuild() async {
    final generation = ++_generation;
    _engine?.dispose();
    _engine = null;
    final s = _currentSettings();
    _engineKey = await _configKey();
    if (!s.syncOn) {
      status.value = const CloudSyncStatus(CloudSyncPhase.off);
      return;
    }
    final secret = await secrets.read(kSyncSecretsKey) ?? const <String, String>{};
    final passphrase = secret['passphrase'];
    String? folder;
    final bookmark = s.syncConfig['bookmark'];
    if (bookmark != null && bookmark.isNotEmpty && Env.isMacOS) folder = await FolderAccess.reopen(bookmark);
    final oauth = await secrets.read(kSyncOAuthKey);
    final backend = buildSyncBackend(s, secret, http, folderOverride: folder, oauth: oauth, saveOAuth: (m) async {
      // An engine that was replaced, dropped or turned off keeps nothing.
      if (generation == _generation) await secrets.write(kSyncOAuthKey, m);
    });
    if (backend == null || passphrase == null || passphrase.isEmpty) {
      status.value = const CloudSyncStatus(CloudSyncPhase.error, message: 'Sync is not fully set up: open Settings > Sync.');
      return;
    }
    final id = await deviceId();
    _engine = _engineFor(backend, passphrase, id, _StateFile(storage));
    status.value = CloudSyncStatus(CloudSyncPhase.ok, deviceId: id);
  }

  /// The engine for [backend] with every source this device syncs: one
  /// recipe for syncing and for the dry run, so the dry run sees exactly
  /// what the sync will.
  SyncEngine _engineFor(SyncBackend backend, String passphrase, String id, SyncStateStore state) {
    final host = deviceHostName();
    return SyncEngine(
      backend: backend,
      cipher: BackupCipher(passphrase, derive: _deriveOffThread),
      deviceId: id,
      device: SyncDeviceInfo(
        label: host.isEmpty ? Env.platformName : '$host (${Env.platformName})',
        platform: Env.platformName,
        appVersion: kAppVersion,
        seenAt: DateTime.now(),
      ),
      sources: [
        AccountsSyncSource(accounts),
        SecretsSyncSource(accounts, secrets),
        PostsSyncSource(posts),
        _settingsSource(),
        _mediaHostsSource(),
      ],
      state: state,
      secrets: secrets,
    );
  }

  /// 1.3.5: the dry run before this device's first sync with the file in
  /// [backend]: what joining would bring here and send there, without doing
  /// any of it. The returned planner stretches the passphrase once and can
  /// be asked again with the other side's setup winning.
  Future<SyncJoinPlanner> joinPlanner(SyncBackend backend, String passphrase) async {
    final st = MemorySyncStateStore();
    return SyncJoinPlanner._(_engineFor(backend, passphrase, await deviceId(), st), st);
  }

  /// This device's id in the sync file, made once.
  Future<String> deviceId() async {
    if (_deviceId != null) return _deviceId!;
    final j = await storage.readJson('sync-device.json');
    var id = j?['id'] as String?;
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await storage.writeJson('sync-device.json', {'id': id});
    }
    return _deviceId = id;
  }

  /// Settings that travel (the same allowlist as "Move to another device"),
  /// one record each. 1.3.5: every shared setting is always there with its
  /// value, defaults included ([syncedSettings]), so a setting put back to
  /// its default travels, and the setup that wins a first sync wins whole.
  /// Settings this version does not share (a newer NEFORUM's) are left in
  /// the file, and a deletion (an older NEFORUM leaves defaults out) changes
  /// nothing here.
  SyncSource _settingsSource() => CallbackSyncSource(
        prefix: 'setting',
        snapshot: () async => {for (final e in syncedSettings(_currentSettings()).entries) e.key: SyncItem(e.value)},
        apply: (key, value) async {
          if (!kExportableSettings.contains(key)) return;
          await _storeSettings(withImportedSettings(_currentSettings(), {key: value}));
        },
        handles: kExportableSettings.contains,
        appliesDeletions: false,
        remapAccountIds: (key, value, ids) => remapSettingAccountIds(key, value, ids),
      );

  /// Both media hosts with their keys, as one record (so a host never
  /// arrives without its keys). On a first sync where both sides have
  /// hosts, each slot the winning side left empty keeps the other side's
  /// host ([mergeMediaHostsOnJoin]): a device without a media host never
  /// takes another device's away.
  SyncSource _mediaHostsSource() => CallbackSyncSource(
        prefix: 'mediaHosts',
        snapshot: () async {
          final s = _currentSettings();
          if (s.mediaHostId == null && s.fallbackMediaHostId == null) return const {};
          return {'all': SyncItem(await collectMediaHosts(s, secrets))};
        },
        apply: (_, value) async {
          var s = _currentSettings().copyWith(clearMediaHost: true, clearFallbackMediaHost: true);
          await secrets.delete(MediaHostSlot.main.secretsKey);
          await secrets.delete(MediaHostSlot.fallback.secretsKey);
          if (value is Map) s = await withImportedMediaHosts(s, secrets, Map<String, dynamic>.from(value));
          await _storeSettings(s);
        },
        handles: (id) => id == 'all',
        joinMerge: (_, here, file, {required hereWins}) => mergeMediaHostsOnJoin(here, file, hereWins: hereWins),
      );

  /// Syncs now; errors land in [status].
  Future<SyncReport?> syncNow() async {
    final engine = _engine;
    if (engine == null || _running) return null;
    _running = true;
    final id = _deviceId;
    status.value = CloudSyncStatus(CloudSyncPhase.syncing, lastSyncAt: status.value.lastSyncAt, devices: status.value.devices, deviceId: id);
    try {
      final r = await engine.sync();
      status.value = CloudSyncStatus(CloudSyncPhase.ok, lastSyncAt: r.at, devices: engine.devices, deviceId: id);
      return r;
    } on Object catch (e) {
      status.value = CloudSyncStatus(CloudSyncPhase.error,
          lastSyncAt: status.value.lastSyncAt, message: describeSyncError(e), devices: engine.devices, deviceId: id);
      return null;
    } finally {
      _running = false;
      // Changes the sync itself applied should not set off another sync.
      _quietUntil = DateTime.now().add(const Duration(seconds: 2));
    }
  }

  /// Whether this device publishes the due [post] (see [SyncEngine.mayPublish]).
  Future<bool> mayPublish(Post post) async {
    final engine = _engine;
    if (engine == null) return true;
    return engine.mayPublish(post, mediaHere: await filesExist(post.media.map((m) => m.path)));
  }

  @override
  Future<Map<String, String>?> renew(ConnectedAccount account, Map<String, String> current, SecretsRefresh refresh, {bool Function(Map<String, String> secrets)? renewsEarly}) {
    final engine = _engine;
    return engine == null ? refresh(current) : engine.renew(account, current, refresh, renewsEarly: renewsEarly);
  }

  void dispose() {
    stop();
    _engine?.dispose();
    status.dispose();
  }
}

/// 1.3.5: the dry run of this device's first sync with one sync file
/// ([CloudSync.joinPlanner]). Reads only: nothing is stored or written.
class SyncJoinPlanner {
  SyncJoinPlanner._(this._engine, this._state);
  final SyncEngine _engine;
  final MemorySyncStateStore _state;

  /// What joining would do with [seed]'s setup winning where both sides
  /// differ, or with the seed rule's choice when `null`.
  Future<SyncPreview> preview({SyncSeed? seed}) {
    _state.data = SyncEngine.joinState(seed);
    return _engine.preview();
  }

  void dispose() => _engine.dispose();
}

/// 1.3.5: a dry run in words, for the dialog before a first sync.
@immutable
class SyncJoinSummary {
  const SyncJoinSummary({required this.headline, required this.details, required this.swapLabel});

  /// "This device gets 16 accounts, 2 media hosts and 41 settings from
  /// DESKTOP-X (Windows)." or "This device's setup will be used (...)."
  final String headline;
  final List<String> details;

  /// The button that makes the other side's setup win instead.
  final String swapLabel;
}

String _count(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';

/// "a", "a and b", "a, b and c".
String _listed(List<String> parts) => switch (parts.length) {
      0 => '',
      1 => parts.single,
      _ => '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}',
    };

/// A media host kind as a dry run names it: "S3-compatible bucket", "Catbox".
String _hostName(String id) => (mediaHostRegistry.descriptor(id)?.name ?? id).split(' (').first;

/// "replaced by Catbox and removed"; when both are one kind, says that the
/// one that stays is the other side's own, with its own settings and keys.
String _replacement(String id, String? by, String whose) {
  if (by == null) return 'removed';
  if (by == id) return "replaced by $whose own ${_hostName(by)} (other settings and keys) and removed";
  return "replaced by $whose ${_hostName(by)} and removed";
}

/// 1.3.5: [p] in words. [chosen]: the user picked whose setup wins instead
/// of the seed rule. Media hosts are counted and named exactly: the ones
/// that arrive, move to the other slot or are removed, on each side.
SyncJoinSummary describeJoinPreview(SyncPreview p, {bool chosen = false}) {
  final from = p.fromDevices;
  final source = from.isEmpty ? null : (from.length == 1 ? from.single : '${from.first} and ${_count(from.length - 1, 'other device')}');
  const hostsKey = 'mediaHosts:all';
  final here = p.received.containsKey(hostsKey) ? mediaHostChanges(p.hereBefore[hostsKey], p.received[hostsKey]) : null;
  final there = p.sent.contains(hostsKey) ? mediaHostChanges(p.fileBefore[hostsKey], p.sentValues[hostsKey]) : null;
  final hostsArriving = here?.arrived.length ?? 0, hostsSent = there?.arrived.length ?? 0;
  final arriving = _listed([
    if (p.receivedOf('account') > 0) _count(p.receivedOf('account'), 'account'),
    if (hostsArriving > 0) _count(hostsArriving, 'media host'),
    if (p.receivedOf('setting') > 0) _count(p.receivedOf('setting'), 'setting'),
    if (p.receivedOf('post') > 0) _count(p.receivedOf('post'), 'post'),
  ]);
  final sending = _listed([
    if (p.sentOf('account') > 0) _count(p.sentOf('account'), 'account'),
    if (hostsSent > 0) _count(hostsSent, 'media host'),
    if (p.sentOf('setting') > 0) _count(p.sentOf('setting'), 'setting'),
    if (p.sentOf('post') > 0) _count(p.sentOf('post'), 'post'),
  ]);
  final hostLines = [
    for (final m in here?.moved ?? const <({MediaHostPlace host, String to})>[])
      "This device's ${m.host.slot} media host (${_hostName(m.host.id)}) moves to the ${m.to} slot.",
    for (final r in here?.removed ?? const <({MediaHostPlace host, String? replacedBy})>[])
      "This device's ${r.host.slot} media host (${_hostName(r.host.id)}) is ${_replacement(r.host.id, r.replacedBy, "the sync file's")}: both slots are taken.",
    for (final m in there?.moved ?? const <({MediaHostPlace host, String to})>[])
      "Your other devices' ${m.host.slot} media host (${_hostName(m.host.id)}) moves to the ${m.to} slot.",
    for (final r in there?.removed ?? const <({MediaHostPlace host, String? replacedBy})>[])
      "Your other devices' ${r.host.slot} media host (${_hostName(r.host.id)}) is ${_replacement(r.host.id, r.replacedBy, "this device's")}: both slots are taken.",
  ];
  final hostsRemoved = (here?.removed.isNotEmpty ?? false) || (there?.removed.isNotEmpty ?? false);
  final mine = p.seed == SyncSeed.thisDevice;
  final h = p.here.accounts, f = p.file.accounts;
  final String why;
  if (chosen) {
    why = 'as you chose';
  } else if (h != f) {
    why = mine ? 'it has more accounts: $h against $f in the sync file' : 'it has more accounts: $f against $h on this device';
  } else if (p.here.oldestConnection != p.file.oldestConnection && (p.here.oldestConnection != null || p.file.oldestConnection != null)) {
    why = 'both have ${_count(h, 'account')}, and its oldest connection is older';
  } else {
    why = 'both have ${_count(h, 'account')}, so the sync file stays as it is';
  }
  final fromPart = source == null ? '' : ' from $source';
  final headline = mine
      ? "This device's setup will be used ($why)."
      : (arriving.isEmpty ? 'This device already has everything the sync file has.' : 'This device gets $arriving$fromPart.');
  return SyncJoinSummary(
    headline: headline,
    details: [
      if (!mine) "Where the two differ, the sync file's setup wins ($why).",
      if (mine && arriving.isNotEmpty) 'This device also gets $arriving$fromPart.',
      if (sending.isNotEmpty) 'The sync file gets $sending from this device.',
      if (p.mergedAccounts.length > p.mergedInFile.length)
        '${_count(p.mergedAccounts.length - p.mergedInFile.length, 'account')} connected on both ${p.mergedAccounts.length - p.mergedInFile.length == 1 ? 'becomes' : 'become'} one, with the newer sign-in.',
      if (p.mergedInFile.isNotEmpty)
        'The sync file holds ${_count(p.mergedInFile.length, 'account')} twice (two devices connected ${p.mergedInFile.length == 1 ? 'it' : 'them'} at the same moment): ${p.mergedInFile.length == 1 ? 'it becomes' : 'each becomes'} one, with the newer sign-in.',
      ...hostLines,
      hostsRemoved ? 'Apart from that, nothing is deleted: what only one side has is kept.' : 'Nothing is deleted: what only one side has is kept.',
    ],
    swapLabel: mine ? "Use the sync file's setup instead" : "Use this device's setup instead",
  );
}

/// [e] as a sentence for the sync settings.
String describeSyncError(Object e) => switch (e) {
      SyncBackendException(:final message) => message,
      BackupException(kind: BackupErrorKind.wrongPassphraseOrDamaged) =>
        'The sync passphrase does not open the sync file (or the file is damaged). Use the passphrase you chose on your first device.',
      BackupException(:final message) => message,
      AuthCancelled() => 'The Google sign-in was cancelled.',
      OAuthException() => 'Google refused the sign-in: $e. Check the Client ID and secret (a "Desktop app" client), and that the Google Drive API is enabled.',
      _ => 'Sync failed: ${_firstLine(e)}',
    };

/// The first line of [e], at most 240 characters: some errors carry pages of
/// internal detail that mean nothing to the reader.
String _firstLine(Object e) {
  final line = '$e'.split('\n').first.trim();
  return line.length > 240 ? '${line.substring(0, 240)}…' : line;
}
