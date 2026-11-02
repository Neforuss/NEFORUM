import 'dart:async';

import 'package:meta/meta.dart';

import '../adapters/platform_adapter.dart';
import '../auth/oauth2_pkce.dart';
import '../backup/backup_format.dart';
import '../model/account.dart';
import '../model/post.dart';
import '../model/publish_result.dart';
import '../storage/secret_store.dart';
import '../util/logger.dart';
import 'secrets_coordinator.dart';
import 'sync_backend.dart';
import 'sync_document.dart';
import 'sync_seed.dart';
import 'sync_sources.dart';

export 'sync_seed.dart';

/// Where a device keeps what it last agreed with the sync file: the hash of
/// every record, so the next sync can tell what changed here, what changed
/// elsewhere, and what changed on both sides.
abstract class SyncStateStore {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> state);
}

class MemorySyncStateStore implements SyncStateStore {
  Map<String, dynamic>? data;
  @override
  Future<Map<String, dynamic>?> read() async => data;
  @override
  Future<void> write(Map<String, dynamic> state) async => data = state;
}

/// What one sync did.
@immutable
class SyncReport {
  const SyncReport(
      {required this.at, this.received = 0, this.sent = 0, this.conflicts = 0, this.mergedCopies = 0, this.mergedAccounts = 0, this.wrote = false});

  final DateTime at;

  /// Records changed elsewhere and applied here.
  final int received;

  /// Records changed here and written to the file.
  final int sent;

  /// Records changed on both sides (the newer one won).
  final int conflicts;

  /// Cloud-client conflict copies merged in.
  final int mergedCopies;

  /// 1.3.5: accounts connected on this device and in the file under two ids,
  /// merged into one on the first sync.
  final int mergedAccounts;
  final bool wrote;
}

/// Keeps this device's accounts, keys, posts and settings in step with one
/// encrypted file that every device reads and writes, the way KeePassXC
/// shares a database: in a synced folder (OneDrive, Google Drive, Dropbox,
/// iCloud Drive, Syncthing...), a WebDAV folder or an S3 bucket. No NEFORUM
/// server: the storage only ever sees the encrypted file.
///
/// * **Merging by record.** Each account, account's keys, post and setting is
///   a record. A sync compares this device, the file, and what both agreed
///   on last time: a change on one side wins; a change on both sides keeps
///   the newer one (a post that already went out beats an edit; the newest
///   renewed sign-in beats an older one). Deletions travel as tombstones.
/// * **A device's first sync (1.3.5).** Everything only one side has is
///   kept: nothing is deleted. Where both hold a different version of the
///   same record, the setup of the side with more accounts wins (on a tie,
///   the side with the oldest account connection; then the file):
///   [chooseSyncSeed]. One account connected on both sides under two ids
///   becomes one, under the file's id, with the newer sign-in
///   ([isSameConnectedAccount]). [preview] works all of that out without
///   doing it, for the dry run shown before a first sync.
/// * **Renewing shared sign-ins.** X and Tumblr replace the refresh token
///   every renewal, so two devices renewing on their own sign each other
///   out. Here only the device holding the account's lease renews; the
///   others wait for and use its new keys; and a device whose renewal is
///   refused re-reads the file and retries with keys another device just
///   wrote ([renew]).
/// * **Scheduled posts have one publisher.** A scheduled post is claimed by
///   the device it was scheduled on (which has its photos and videos).
///   Other devices leave it alone unless that device has been silent for
///   [ownerTimeout] and the post is that much overdue ([mayPublish]).
class SyncEngine implements SecretsCoordinator {
  SyncEngine({
    required this.backend,
    required this.cipher,
    required this.deviceId,
    required this.device,
    required List<SyncSource> sources,
    required this.state,
    this.secrets,
    Clock? clock,
    Logger? log,
    Future<void> Function(Duration)? sleep,
    this.heartbeat = const Duration(minutes: 15),
    this.ownerTimeout = const Duration(minutes: 30),
    this.leaseTime = const Duration(minutes: 2),
    this.renewalWait = const Duration(seconds: 60),
    this.tombstoneLife = const Duration(days: 90),
  })  : _sources = {for (final s in sources) s.prefix: s},
        _now = clock ?? systemClock,
        _log = log ?? Logger('sync'),
        _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final SyncBackend backend;
  final BackupCipher cipher;
  final String deviceId;

  /// This device's name, platform and version ([SyncDeviceInfo.seenAt] is
  /// set on every write).
  final SyncDeviceInfo device;
  final SyncStateStore state;

  /// The keychain, for [renew].
  final SecretStore? secrets;

  /// How often a running device marks itself as alive in the file.
  final Duration heartbeat;

  /// How long a scheduled post's owner may be silent (and the post overdue)
  /// before another device publishes it.
  final Duration ownerTimeout;

  /// How long a renewal lease lasts.
  final Duration leaseTime;

  /// How long to wait for another device's renewal.
  final Duration renewalWait;

  /// How long deletions are remembered.
  final Duration tombstoneLife;

  final Map<String, SyncSource> _sources;
  final Clock _now;
  final Logger _log;
  final Future<void> Function(Duration) _sleep;

  Future<void> _tail = Future.value();
  SyncDocument? _cachedDoc;
  String? _cachedVersion;
  final Set<String> _renewing = {};
  final Map<String, DateTime> _notMineUntil = {};
  final _changes = StreamController<void>.broadcast();

  SyncReport? _lastReport;
  Object? _lastError;

  /// The last successful sync.
  SyncReport? get lastReport => _lastReport;

  /// Why the last sync failed, or `null` when it worked.
  Object? get lastError => _lastError;

  /// The devices in the file at the last sync.
  Map<String, SyncDeviceInfo> get devices => Map.unmodifiable(_cachedDoc?.devices ?? const {});

  /// Emits after every sync attempt.
  Stream<void> get changes => _changes.stream;

  void dispose() => unawaited(_changes.close());

  /// Reads the file, merges, writes back what changed here. Throws
  /// [SyncBackendException] or [BackupException] (wrong passphrase).
  Future<SyncReport> sync() async {
    try {
      final r = await _locked(() async => (await _syncLoop()).report);
      _lastReport = r;
      _lastError = null;
      return r;
    } on Object catch (e) {
      _lastError = e;
      rethrow;
    } finally {
      if (!_changes.isClosed) _changes.add(null);
    }
  }

  /// 1.3.5: what [sync] would do now, worked out by the same planning code
  /// without doing any of it: nothing is stored here, nothing is written to
  /// the file or to the [state]. The dry run shown before a device's first
  /// sync. Throws as [sync] does (wrong passphrase, storage out of reach).
  Future<SyncPreview> preview() => _locked(() async => (await _plan()).preview);

  // -------------------------------------------------------------------------
  // Sync passes
  // -------------------------------------------------------------------------

  Future<T> _locked<T>(Future<T> Function() run) {
    final result = _tail.then((_) => run());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// A sync pass, again when another device wrote in between.
  Future<_Pass> _syncLoop() async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _syncOnce();
      } on SyncConflict {
        if (attempt >= 4) rethrow;
        _cachedVersion = null;
        await _sleep(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
  }

  Future<_Remote> _pull() async {
    final blob = await backend.read();
    final SyncDocument doc;
    if (blob == null) {
      doc = SyncDocument();
    } else if (blob.version != null && blob.version == _cachedVersion && _cachedDoc != null) {
      doc = _cachedDoc!.copy();
    } else {
      doc = SyncDocument.parse(await cipher.open(blob.bytes));
    }
    final copies = <SyncSideCopy>[];
    for (final c in await backend.conflictCopies()) {
      try {
        doc.absorb(SyncDocument.parse(await cipher.open(c.bytes)));
        copies.add(c);
      } on BackupException catch (e) {
        _log.warn('Not merging ${c.name}: ${e.message}');
      }
    }
    return _Remote(doc, blob?.version, exists: blob != null, copies: copies);
  }

  Future<String?> _write(_Remote remote, SyncDocument doc) async {
    final now = _now();
    doc.devices[deviceId] = device.seen(now);
    final bytes = await cipher.seal(doc.toJson(writtenBy: deviceId, writtenAt: now));
    final version = await backend.write(bytes, ifMatch: remote.exists ? remote.version : null);
    _cachedDoc = doc.copy();
    _cachedVersion = version;
    for (final c in remote.copies) {
      await backend.removeConflictCopy(c);
    }
    return version;
  }

  Future<_Pass> _syncOnce() async => _execute(await _plan());

  /// Works out a sync pass without doing it: reads the file and this
  /// device's data, merges record by record into the document read (a copy
  /// of the file, which only [_execute] writes back), and lists what to
  /// store here.
  Future<_Plan> _plan() async {
    final now = _now();
    final st = _State.parse(await state.read());
    final remote = await _pull();
    final doc = remote.doc;
    final before = syncHash(doc.toJson(writtenBy: '', writtenAt: DateTime.utc(2000)));
    final firstJoin = !st.joined;
    // The file as read, before this pass merges anything into it.
    final original = Map<String, SyncRecord>.of(doc.records);

    final local = <String, SyncItem>{};
    for (final s in _sources.values) {
      for (final e in (await s.snapshot()).entries) {
        local['${s.prefix}:${e.key}'] = e.value;
      }
    }

    // A device's first sync: whose version is kept where both sides hold a
    // different one (the seed rule, or the choice confirmed in the dry run).
    final here = SyncSideSummary.ofAccounts([for (final e in local.entries) if (e.key.startsWith('account:')) e.value.value]);
    final there = SyncSideSummary.ofAccounts([
      for (final e in doc.records.entries)
        if (e.key.startsWith('account:') && !e.value.deleted) e.value.value,
    ]);
    final seed = firstJoin ? (st.seed ?? chooseSyncSeed(here: here, file: there)) : null;
    final localWins = seed == SyncSeed.thisDevice;

    // A device that joined the file since this one last synced: values kept
    // over an older NEFORUM's deletion go back into the file once, for it.
    final newDevice = !firstJoin && doc.devices.keys.any((id) => id != deviceId && !st.seen.containsKey(id));

    final localHash = {for (final e in local.entries) e.key: syncHash(e.value.value)};
    var conflicts = 0;
    final toApply = <String, Object?>{};
    final removedKeys = <String>{};
    final hereBefore = <String, Object?>{};
    final sentValues = <String, Object?>{};
    final fileBefore = <String, Object?>{};
    final newBase = <String, String>{};
    // Notes a record written into the file (the caller writes it), with
    // what the file held before this pass, for the dry run.
    void send(String key, Object? value) {
      final was = original[key];
      fileBefore.putIfAbsent(key, () => was == null || was.deleted ? null : was.value);
      sentValues[key] = value;
    }

    final keys = {...local.keys, ...doc.records.keys, ...st.base.keys};
    for (final key in keys) {
      final source = _sourceOf(key);
      // A kind of record this version does not know, or one its source does
      // not manage (a newer NEFORUM's): left in the file untouched.
      if (source == null || !source.handles(_idOf(key))) continue;
      final l = localHash[key];
      final rec = doc.records[key];
      final r = rec == null || rec.deleted ? null : rec.hash;
      final b = st.base[key];
      if (l == r) {
        if (l != null) newBase[key] = l;
        continue;
      }
      if (rec != null && rec.deleted && !source.appliesDeletions) {
        // A deletion this kind of record never takes: a setting an older
        // NEFORUM removed because it does not know it, or because it holds
        // it at its default. The file has no opinion on it then:
        // * this device did not change it since: kept here, and not sent
        //   back (the older device would only remove it again), unless a
        //   device joined since, which then gets it from the file once;
        // * this device joins and the file's side wins: kept here, not sent
        //   (the devices already syncing keep theirs, and send it once now
        //   that this device appeared);
        // * otherwise (changed here, or this device's setup wins): sent.
        if ((l == b && !newDevice) || (l != b && firstJoin && !localWins)) {
          if (l != null) newBase[key] = l;
          continue;
        }
        if (l == b) {
          final item = local[key]!;
          doc.records[key] = SyncRecord.of(item.value, at: item.modifiedAt ?? now, by: deviceId);
          send(key, item.value);
          newBase[key] = l!;
          continue;
        }
      }
      final bool takeRemote;
      if (rec == null) {
        // Not in the file at all (a new file, or a forgotten tombstone):
        // never a reason to delete here.
        takeRemote = false;
      } else if (l == b) {
        takeRemote = true;
      } else if (r == b) {
        takeRemote = false;
      } else {
        conflicts++;
        final item = local[key];
        final merged = firstJoin && item != null && !rec.deleted ? source.joinMerge(_idOf(key), item.value, rec.value, hereWins: localWins) : null;
        if (merged != null) {
          // Both versions combined (a media host in each empty slot): stored
          // here and written to the file where it differs.
          final m = syncHash(merged);
          if (m != r) {
            doc.records[key] = SyncRecord.of(merged, at: now, by: deviceId);
            send(key, merged);
          }
          if (m != l) {
            toApply[key] = merged;
            hereBefore[key] = item!.value;
          }
          newBase[key] = m;
          continue;
        }
        final id = _idOf(key);
        takeRemote = _remoteWins(key, item, rec, now,
            firstJoin: firstJoin, localWins: localWins, hereAccount: local['account:$id']?.value, fileAccount: original['account:$id']?.value);
      }
      if (takeRemote) {
        toApply[key] = rec!.deleted ? null : rec.value;
        hereBefore[key] = local[key]?.value;
        if (rec.deleted) removedKeys.add(key);
        if (r != null) newBase[key] = r;
      } else {
        final item = local[key];
        send(key, item?.value);
        doc.records[key] =
            item == null ? SyncRecord.tombstone(at: now, by: deviceId) : SyncRecord.of(item.value, at: item.modifiedAt ?? now, by: deviceId);
        if (l != null) newBase[key] = l;
      }
    }

    // One account under two ids becomes one, worked out on what both sides
    // now agree on (every pass, until none is left).
    final merge = _mergeDuplicates(doc, original, now, send, (key) {
      sentValues.remove(key);
      fileBefore.remove(key);
    });
    for (final e in merge.edits.entries) {
      toApply.remove(e.key);
      hereBefore.remove(e.key);
      removedKeys.remove(e.key);
      if (e.value == null) {
        newBase.remove(e.key);
      } else {
        newBase[e.key] = syncHash(e.value);
      }
    }

    // Forget old tombstones, finished leases and claims.
    doc.records.removeWhere((k, rec) => rec.deleted && now.difference(rec.at) > tombstoneLife);
    newBase.removeWhere((k, _) => !doc.records.containsKey(k) && !local.containsKey(k));
    doc.leases.removeWhere((id, lease) => !lease.liveAt(now) || (lease.by == deviceId && !_renewing.contains(id)));
    doc.claims.removeWhere((id, _) => _postStatus(doc.records['post:$id']) != 'scheduled');
    for (final e in doc.records.entries) {
      if (!e.key.startsWith('post:') || _postStatus(e.value) != 'scheduled') continue;
      doc.claims.putIfAbsent(e.key.substring(5), () => SyncClaim(by: e.value.by, at: now));
    }

    // The devices the received records come from, most records first.
    final from = <String, int>{};
    for (final key in toApply.keys) {
      final by = doc.records[key]?.by;
      if (by == null || by == deviceId) continue;
      final d = doc.devices[by];
      final name = d == null ? 'another device' : (d.label.isEmpty ? d.platform : d.label);
      from[name] = (from[name] ?? 0) + 1;
    }

    return _Plan(
      now: now,
      state: st,
      remote: remote,
      before: before,
      local: local,
      mergeEdits: merge.edits,
      toApply: toApply,
      newBase: newBase,
      received: toApply.length,
      sent: sentValues.length,
      conflicts: conflicts,
      twins: merge.twins,
      preview: SyncPreview(
        fileExists: remote.exists,
        firstJoin: firstJoin,
        seed: seed,
        here: here,
        file: there,
        received: Map.unmodifiable({
          for (final e in toApply.entries)
            if (!removedKeys.contains(e.key)) e.key: e.value,
        }),
        removed: Set.unmodifiable(removedKeys),
        hereBefore: Map.unmodifiable(hereBefore),
        sent: Set.unmodifiable(sentValues.keys),
        sentValues: Map.unmodifiable(sentValues),
        fileBefore: Map.unmodifiable(fileBefore),
        mergedAccounts: Map.unmodifiable(merge.twins),
        mergeEdits: Map.unmodifiable(merge.edits),
        fromDevices: List.unmodifiable(from.keys.toList()..sort((a, b) => from[b]!.compareTo(from[a]!))),
      ),
    );
  }

  /// Does what [plan] worked out: stores what came from the file and the
  /// merged accounts here, writes the file when it changed, and only then
  /// removes the merged copies here, so their keys outlive any write that
  /// fails (whatever happens to the sync state, the next pass finds the
  /// same copies and merges them the same way). Then remembers what both
  /// sides agree on.
  Future<_Pass> _execute(_Plan plan) async {
    final now = plan.now, st = plan.state, remote = plan.remote, doc = plan.remote.doc, newBase = plan.newBase;

    void retryNextTime(String key) {
      final b = st.base[key];
      if (b == null) {
        newBase.remove(key);
      } else {
        newBase[key] = b;
      }
    }

    // Values first (merged accounts win where they touch a record the file
    // sent too), accounts before their keys before the posts that use them;
    // the file's own removals after them.
    final changes = <String, Object?>{
      ...plan.toApply,
      for (final e in plan.mergeEdits.entries)
        if (e.value != null) e.key: e.value,
    };
    int order(String a, String b) {
      final byRemoval = (changes[a] == null ? 1 : 0).compareTo(changes[b] == null ? 1 : 0);
      return byRemoval != 0 ? byRemoval : _applyRank(a).compareTo(_applyRank(b));
    }

    var mergeStepFailed = false;
    final stored = <String, Set<String>>{};
    for (final key in changes.keys.toList()..sort(order)) {
      final value = changes[key];
      try {
        await _sourceOf(key)!.apply(_idOf(key), value);
        if (value != null) (stored[key.substring(0, key.indexOf(':'))] ??= {}).add(_idOf(key));
      } on Object catch (e) {
        if (plan.mergeEdits.containsKey(key)) mergeStepFailed = true;
        _log.warn('Could not store $key from the sync file: $e');
        retryNextTime(key);
      }
    }
    // Agreement is what really landed here. A value this device could not
    // keep at all is asked for again next time; one it kept only in part (a
    // media host kind a newer NEFORUM added, next to one it knows) is agreed
    // as it landed, so this device takes the file's version again instead
    // of reading its partial copy as a change and writing it over the file.
    for (final e in stored.entries) {
      final present = await _sources[e.key]!.snapshot();
      for (final id in e.value) {
        final key = '${e.key}:$id';
        final landed = present[id];
        if (landed == null) {
          _log.warn('$key from the sync file did not land here; trying again next time');
          retryNextTime(key);
        } else {
          newBase[key] = syncHash(landed.value);
        }
      }
    }

    final seen = doc.devices[deviceId]?.seenAt;
    final changed = syncHash(doc.toJson(writtenBy: '', writtenAt: DateTime.utc(2000))) != plan.before;
    final mustWrite =
        changed || remote.copies.isNotEmpty || (!remote.exists && doc.records.isNotEmpty) || seen == null || now.difference(seen) >= heartbeat;
    String? version = remote.version;
    if (mustWrite) {
      version = await _write(remote, doc);
    } else {
      _cachedDoc = doc.copy();
      _cachedVersion = remote.version;
    }

    // The file now holds the merged accounts with the newer sign-in: the
    // copies they replace can go here. Not while one of the merge's own
    // steps failed here: the copy then stays (a duplicate, never a lost
    // account), it is not agreed on, and the next pass merges it again.
    for (final e in plan.twins.entries) {
      _log.info('Account ${e.key} is ${e.value} in the sync file: merged into one');
    }
    for (final key in plan.mergeEdits.keys.where((k) => plan.mergeEdits[k] == null).toList()..sort((a, b) => _applyRank(b).compareTo(_applyRank(a)))) {
      if (mergeStepFailed) continue;
      try {
        await _sourceOf(key)!.apply(_idOf(key), null);
      } on Object catch (e) {
        _log.warn('Could not remove the merged copy $key here yet: $e');
      }
    }

    await state.write(_State(
      base: newBase,
      joined: true,
      lastSyncAt: now,
      claims: {for (final e in doc.claims.entries) e.key: e.value.by},
      seen: {for (final e in doc.devices.entries) e.key: e.value.seenAt},
    ).toJson());
    final received = plan.received, sent = plan.sent, conflicts = plan.conflicts;
    if (received > 0 || sent > 0) _log.info('Synced: $received in, $sent out${conflicts > 0 ? ', $conflicts on both sides' : ''}');
    return _Pass(
      SyncReport(
          at: now,
          received: received,
          sent: sent,
          conflicts: conflicts,
          mergedCopies: remote.copies.length,
          mergedAccounts: plan.twins.length,
          wrote: mustWrite),
      _Remote(doc, version, exists: remote.exists || mustWrite, copies: const []),
    );
  }

  SyncSource? _sourceOf(String key) {
    final i = key.indexOf(':');
    return i <= 0 ? null : _sources[key.substring(0, i)];
  }

  static String _idOf(String key) => key.substring(key.indexOf(':') + 1);

  static int _applyRank(String key) => switch (key.substring(0, key.indexOf(':'))) {
        'account' => 0,
        'secrets' => 1,
        'post' => 2,
        _ => 3,
      };

  /// The sync state to start a device's first sync with when ITS records
  /// should win over the file's where both have the same one, whatever the
  /// seed rule says. Write it to the [SyncStateStore] before the first sync;
  /// it applies once.
  static const Map<String, dynamic> keepThisDeviceOnJoin = {'preferLocal': true};

  /// 1.3.5: the same, for the file's records to win.
  static const Map<String, dynamic> keepFileOnJoin = {'preferFile': true};

  /// 1.3.5: the sync state to start a first sync with so that it keeps
  /// [seed]'s versions (the choice the user confirmed in the dry run), or
  /// lets the seed rule decide when `null`.
  static Map<String, dynamic> joinState(SyncSeed? seed) => switch (seed) {
        SyncSeed.thisDevice => Map.of(keepThisDeviceOnJoin),
        SyncSeed.file => Map.of(keepFileOnJoin),
        null => <String, dynamic>{},
      };

  /// Both sides changed [key]: whether the file's version wins.
  bool _remoteWins(String key, SyncItem? local, SyncRecord rec, DateTime now,
      {required bool firstJoin, bool localWins = false, Object? hereAccount, Object? fileAccount}) {
    if (rec.deleted) return local == null; // an edit beats a deletion
    if (local == null) return true;
    final prefix = key.substring(0, key.indexOf(':'));
    if (prefix == 'post') {
      final lr = _statusRank(local.value), rr = _statusRank(rec.value);
      if (lr != rr) return rr > lr;
      final lt = local.modifiedAt;
      return lt == null || rec.at.isAfter(lt);
    }
    if (prefix == 'secrets') {
      // The most recently renewed sign-in is the one the network accepts.
      final le = _expiry(local.value), re = _expiry(rec.value);
      if (le != null && re != null && le != re) return re.isAfter(le);
      // On a first sync, keys that do not expire follow the newer sign-in
      // too (the account connected later), never the seed: an old token the
      // user replaced may be revoked already.
      if (firstJoin && hereAccount is Map && fileAccount is Map) {
        final lc = DateTime.tryParse('${hereAccount['createdAt'] ?? ''}'), rc = DateTime.tryParse('${fileAccount['createdAt'] ?? ''}');
        if (lc != null && rc != null && lc != rc) return rc.isAfter(lc);
      }
    }
    // A device's first sync: the version of the side whose setup wins.
    if (firstJoin) return !localWins;
    return rec.at.isAfter(local.modifiedAt ?? now);
  }

  static int _statusRank(Object? postJson) => switch (postJson is Map ? postJson['status'] : null) {
        'published' => 3,
        'partial' || 'failed' || 'cancelled' => 2,
        'publishing' => 1,
        _ => 0,
      };

  static DateTime? _expiry(Object? secrets) =>
      secrets is Map ? DateTime.tryParse('${secrets[OAuthTokens.keyExpiresAt] ?? ''}') : null;

  static String? _postStatus(SyncRecord? rec) {
    if (rec == null || rec.deleted) return null;
    final v = rec.value;
    return v is Map ? v['status'] as String? : null;
  }

  /// One account under two ids becomes one (Mastodon, Pixelfed and TikTok
  /// make up a random id on each device, and so do hand-off accounts:
  /// [isDeviceMadeAccountId]), matched by its identity on the network
  /// ([naturalAccountKey]) or its handle ([isSameConnectedAccount]). It runs
  /// on every pass, on what both sides agree on once the records are merged
  /// ([doc]), so it needs no memory between passes: a copy this device
  /// connected before its first sync, two devices that joined at once through
  /// a synced folder, a pass interrupted halfway, all end the same way.
  ///
  /// * The id kept is the one the file already had ([original]); between two
  ///   already there, an id taken from the account itself, else the smaller
  ///   one, so that every device picks the same.
  /// * The newer sign-in wins, account and keys together (a server's app
  ///   registration and its token belong to each other): [holdsNewerSignIn].
  /// * Every post and setting naming the other id follows
  ///   ([SyncSource.remapAccountIds]); the other id's records leave the file.
  /// * Two hand-off accounts last written by one device are two the user
  ///   made there on purpose, never twins.
  ///
  /// Changes [doc], notes every record written with [send], and returns the
  /// merges (other id -> kept id) and what to store here (`null`: remove the
  /// merged copy, which [_execute] does only after the file is written).
  ({Map<String, String> twins, Map<String, Object?> edits}) _mergeDuplicates(
      SyncDocument doc, Map<String, SyncRecord> original, DateTime now, void Function(String key, Object? value) send, void Function(String key) unsend) {
    Map<Object?, Object?>? live(String key) {
      final rec = doc.records[key];
      return rec == null || rec.deleted || rec.value is! Map ? null : rec.value as Map<Object?, Object?>;
    }

    final accounts = <String, Map<Object?, Object?>>{
      for (final k in doc.records.keys)
        if (k.startsWith('account:') && live(k) != null) k.substring(8): live(k)!,
    };
    bool inFileBefore(String id) => original['account:$id']?.deleted == false;
    final twins = <String, String>{};
    final ids = accounts.keys.toList()..sort();
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        final a = ids[i], b = ids[j];
        if (twins.containsKey(a) || twins.containsKey(b)) continue;
        if (!isSameConnectedAccount(accounts[a]!, accounts[b]!)) continue;
        if (accounts[a]!['tier'] == 'handoff' && doc.records['account:$a']!.by == doc.records['account:$b']!.by) continue;
        final String keep;
        if (inFileBefore(a) != inFileBefore(b)) {
          keep = inFileBefore(a) ? a : b;
        } else if (isDeviceMadeAccountId(a) != isDeviceMadeAccountId(b)) {
          keep = isDeviceMadeAccountId(a) ? b : a;
        } else {
          keep = a;
        }
        twins[keep == a ? b : a] = keep;
      }
    }
    final edits = <String, Object?>{};
    if (twins.isEmpty) return (twins: twins, edits: edits);

    void put(String key, Object value, {DateTime? at}) {
      final rec = doc.records[key];
      if (rec == null || rec.deleted || rec.hash != syncHash(value)) {
        doc.records[key] = SyncRecord.of(value, at: at ?? now, by: deviceId);
        send(key, value);
      }
      edits[key] = value;
    }

    void drop(String key) {
      final was = original[key];
      if (was == null || was.deleted) {
        // Never in the file as a live record (a copy only this device had):
        // it leaves no trace there.
        if (was == null) {
          doc.records.remove(key);
        } else {
          doc.records[key] = was;
        }
        unsend(key);
      } else {
        doc.records[key] = SyncRecord.tombstone(at: now, by: deviceId);
        send(key, null);
      }
      edits[key] = null;
    }

    String keptFor(String id) {
      var k = id;
      while (twins.containsKey(k)) {
        k = twins[k]!;
      }
      return k;
    }

    for (final other in twins.keys) {
      final keep = keptFor(other);
      final otherKeys = live('secrets:$other'), keepKeys = live('secrets:$keep');
      final otherNewer = holdsNewerSignIn(first: accounts[other]!, firstKeys: otherKeys, second: accounts[keep]!, secondKeys: keepKeys);
      final account = {...(otherNewer ? accounts[other]! : accounts[keep]!).cast<String, Object?>(), 'id': keep};
      final keys = otherNewer ? (otherKeys ?? keepKeys) : (keepKeys ?? otherKeys);
      accounts[keep] = account;
      put('account:$keep', account);
      if (keys != null) put('secrets:$keep', keys);
      drop('account:$other');
      if (doc.records.containsKey('secrets:$other') || original.containsKey('secrets:$other')) drop('secrets:$other');
    }
    final resolved = {for (final o in twins.keys) o: keptFor(o)};
    for (final key in doc.records.keys.toList()) {
      final rec = doc.records[key]!;
      final source = _sourceOf(key);
      if (rec.deleted || source == null || !source.handles(_idOf(key)) || key.startsWith('account:') || key.startsWith('secrets:')) continue;
      final value = source.remapAccountIds(_idOf(key), rec.value, resolved);
      if (!identical(value, rec.value) && value != null) put(key, value, at: rec.at);
    }
    return (twins: resolved, edits: edits);
  }

  // -------------------------------------------------------------------------
  // Scheduled posts: one publisher
  // -------------------------------------------------------------------------

  /// Whether this device should publish the due [post] now. Syncs first: a
  /// post another device already published, or that its owner (the device
  /// it was scheduled on) is about to publish, is left alone. The owner
  /// marks it as being published. [mediaHere] is whether this device has the
  /// post's photos and videos; another device's post is only taken over
  /// with them.
  ///
  /// Without the file (offline, storage unreachable) the last known state
  /// decides, and a post nobody claimed is published.
  Future<bool> mayPublish(Post post, {bool mediaHere = true}) async {
    final now = _now();
    final until = _notMineUntil[post.id];
    if (until != null && until.isAfter(now)) return false;
    try {
      final ok = await _locked(() async {
        for (var attempt = 0;; attempt++) {
          final pass = await _syncLoop();
          final remote = pass.remote;
          final doc = remote.doc;
          final verdict = _claimVerdict(doc, post, mediaHere: mediaHere);
          if (verdict != _Claim.take) return verdict == _Claim.mine;
          doc.claims[post.id] = SyncClaim(by: deviceId, at: _now(), publishing: true);
          try {
            await _write(remote, doc);
            return true;
          } on SyncConflict {
            if (attempt >= 3) rethrow;
          }
        }
      });
      if (!ok) _notMineUntil[post.id] = now.add(const Duration(minutes: 2));
      return ok;
    } on Object catch (e) {
      _log.warn('Could not check the sync file before publishing (${e is SyncBackendException ? e.message : e}); using the last known state');
      final doc = _cachedDoc;
      if (doc != null) return _claimVerdict(doc, post, mediaHere: mediaHere) != _Claim.others;
      // A fresh process (a phone's background task): what the last sync saw.
      final st = _State.parse(await state.read());
      final owner = st.claims[post.id];
      if (owner == null || owner == deviceId) return true;
      final seen = st.seen[owner];
      final at = post.scheduledAt;
      final quiet = seen == null || now.difference(seen) > ownerTimeout;
      final overdue = at != null && now.difference(at) > ownerTimeout;
      return quiet && overdue && mediaHere;
    }
  }

  _Claim _claimVerdict(SyncDocument doc, Post post, {required bool mediaHere}) {
    final rec = doc.records['post:${post.id}'];
    if (rec == null) return _Claim.mine; // only on this device so far
    if (rec.deleted) return _Claim.others;
    if (_postStatus(rec) != 'scheduled') return _Claim.others; // published or changed elsewhere
    final claim = doc.claims[post.id];
    final now = _now();
    if (claim == null || claim.by == deviceId) {
      return claim?.publishing == true ? _Claim.mine : _Claim.take;
    }
    final owner = doc.devices[claim.by];
    final quiet = owner == null || now.difference(owner.seenAt) > ownerTimeout;
    final at = post.scheduledAt;
    final overdue = at != null && now.difference(at) > ownerTimeout;
    final startedLately = claim.publishing && now.difference(claim.at) < ownerTimeout;
    if (quiet && overdue && mediaHere && !startedLately) return _Claim.take;
    return _Claim.others;
  }

  // -------------------------------------------------------------------------
  // Rotating sign-ins
  // -------------------------------------------------------------------------

  @override
  Future<Map<String, String>?> renew(ConnectedAccount account, Map<String, String> current, SecretsRefresh refresh) async {
    final store = secrets;
    if (store == null || !_expired(current)) {
      final fresh = await refresh(current);
      if (fresh != null) unawaited(_pushSoon());
      return fresh;
    }
    _renewing.add(account.id);
    try {
      var latest = current;
      try {
        latest = await _awaitTurn(account, current, store);
      } on _AlreadyRenewed catch (done) {
        return _differs(done.secrets, current);
      } on Object catch (e) {
        // The file is out of reach: renew alone rather than not at all.
        _log.warn('Renewing ${account.displayName} without the sync file: $e');
        return await refresh(current);
      }
      Map<String, String>? fresh;
      try {
        fresh = await refresh(latest);
      } on AdapterException catch (e) {
        if (e.error.kind != PublishErrorKind.auth) rethrow;
        // Re-read and retry: another device may have renewed a moment ago.
        final Map<String, String> again;
        try {
          await _locked(_syncLoop);
          again = await store.read(account.id) ?? latest;
        } on Object catch (syncError) {
          _log.warn('Could not re-read the sync file after the refused renewal: $syncError');
          throw e;
        }
        if (_differs(again, latest) != null) {
          if (!_expired(again)) {
            return _differs(again, current);
          }
          fresh = await refresh(again);
          latest = again;
        } else if (!backend.atomicWrites && _otherDeviceActive()) {
          throw AdapterException(PublishError.network(
              '${_networkName(account)} refused the saved sign-in, probably because another device renewed it moments ago and '
              'the sync file has not arrived here yet. NEFORUM tries again shortly; if this keeps happening, reconnect the account.',
              raw: e.error.raw,
              statusCode: e.error.statusCode));
        } else {
          rethrow;
        }
      }
      final result = fresh ?? latest;
      await store.write(account.id, result);
      return _differs(result, current);
    } finally {
      _renewing.remove(account.id);
      // Share the new keys and give the lease back.
      try {
        await _locked(_syncLoop);
      } on Object catch (e) {
        _log.warn('Could not share the renewed ${account.displayName} sign-in yet: $e');
      }
    }
  }

  /// Syncs, then waits while another device holds the account's lease, then
  /// takes it. Returns the keys to renew; throws [_AlreadyRenewed] when
  /// another device's renewal arrived meanwhile.
  Future<Map<String, String>> _awaitTurn(ConnectedAccount account, Map<String, String> current, SecretStore store) async {
    final deadline = _now().add(renewalWait);
    while (true) {
      final pass = await _locked(_syncLoop);
      final latest = await store.read(account.id) ?? current;
      if (!_expired(latest)) throw _AlreadyRenewed(latest);
      final lease = pass.remote.doc.leases[account.id];
      final now = _now();
      if (lease != null && lease.by != deviceId && lease.liveAt(now) && now.isBefore(deadline)) {
        _log.info('${account.displayName}: another device is renewing the sign-in; waiting for its keys');
        await _sleep(const Duration(seconds: 5));
        continue;
      }
      final took = await _locked(() => _takeLease(account.id));
      if (took) return latest;
      if (!_now().isBefore(deadline)) return latest;
    }
  }

  Future<bool> _takeLease(String accountId) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final remote = await _pull();
      final now = _now();
      final lease = remote.doc.leases[accountId];
      if (lease != null && lease.by != deviceId && lease.liveAt(now)) return false;
      remote.doc.leases[accountId] = SyncLease(by: deviceId, until: now.add(leaseTime));
      try {
        await _write(remote, remote.doc);
        return true;
      } on SyncConflict {
        _cachedVersion = null;
      }
    }
    return false;
  }

  bool _otherDeviceActive() {
    final doc = _cachedDoc;
    if (doc == null) return false;
    final now = _now();
    return doc.devices.entries.any((e) => e.key != deviceId && now.difference(e.value.seenAt) < ownerTimeout);
  }

  Future<void> _pushSoon() async {
    try {
      await _locked(_syncLoop);
    } on Object catch (e) {
      _log.warn('Could not share the renewed sign-in yet: $e');
    }
  }

  bool _expired(Map<String, String> s) => OAuthTokens.fromSecrets(s)?.isExpired(now: _now()) ?? false;

  static Map<String, String>? _differs(Map<String, String> s, Map<String, String> than) {
    if (s.length != than.length) return s;
    for (final e in s.entries) {
      if (than[e.key] != e.value) return s;
    }
    return null;
  }

  static String _networkName(ConnectedAccount a) => switch (a.platformId) {
        'x' => 'X',
        'tumblr' => 'Tumblr',
        _ => a.platformId,
      };
}

enum _Claim { mine, take, others }

class _AlreadyRenewed implements Exception {
  _AlreadyRenewed(this.secrets);
  final Map<String, String> secrets;
}

class _Remote {
  _Remote(this.doc, this.version, {required this.exists, required this.copies});
  final SyncDocument doc;
  final String? version;
  final bool exists;
  final List<SyncSideCopy> copies;
}

class _Pass {
  _Pass(this.report, this.remote);
  final SyncReport report;
  final _Remote remote;
}

/// A sync pass worked out but not done yet ([SyncEngine._plan]).
class _Plan {
  _Plan({
    required this.now,
    required this.state,
    required this.remote,
    required this.before,
    required this.local,
    required this.mergeEdits,
    required this.toApply,
    required this.newBase,
    required this.received,
    required this.sent,
    required this.conflicts,
    required this.twins,
    required this.preview,
  });

  final DateTime now;
  final _State state;

  /// The file as read, its document already merged (written by _execute).
  final _Remote remote;

  /// The document's hash before merging: unchanged means no write.
  final String before;

  /// This device's records.
  final Map<String, SyncItem> local;

  /// What merging accounts stores here (key -> value; `null`: a merged copy,
  /// removed once the file is written).
  final Map<String, Object?> mergeEdits;

  /// What comes from the file and is stored here.
  final Map<String, Object?> toApply;
  final Map<String, String> newBase;
  final int received, sent, conflicts;
  final Map<String, String> twins;
  final SyncPreview preview;
}

class _State {
  _State(
      {required this.base,
      required this.joined,
      this.lastSyncAt,
      this.claims = const {},
      this.seen = const {},
      this.preferLocal = false,
      this.preferFile = false});

  factory _State.parse(Map<String, dynamic>? j) {
    final raw = j?['base'];
    return _State(
      base: {
        if (raw is Map)
          for (final e in raw.entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
      joined: j?['joined'] == true,
      preferLocal: j?['preferLocal'] == true,
      preferFile: j?['preferFile'] == true,
      lastSyncAt: DateTime.tryParse('${j?['lastSyncAt'] ?? ''}'),
      claims: {
        if (j?['claims'] case final Map<Object?, Object?> m)
          for (final e in m.entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
      seen: {
        if (j?['seen'] case final Map<Object?, Object?> m)
          for (final e in m.entries)
            if (e.key is String && DateTime.tryParse('${e.value}') != null) e.key as String: DateTime.parse('${e.value}'),
      },
    );
  }

  final Map<String, String> base;
  final bool joined;

  /// The first sync keeps this device's records over the file's.
  final bool preferLocal;

  /// 1.3.5: the first sync keeps the file's records over this device's.
  final bool preferFile;

  /// The seed the first sync was set up with, or `null` for the seed rule.
  SyncSeed? get seed => preferLocal ? SyncSeed.thisDevice : (preferFile ? SyncSeed.file : null);
  final DateTime? lastSyncAt;

  /// Scheduled post id -> the device that publishes it, as last seen, for
  /// when the file cannot be read (a phone's background task).
  final Map<String, String> claims;

  /// Device id -> its last heartbeat, as last seen.
  final Map<String, DateTime> seen;

  /// The confirmed seed holds until the first sync completes.
  Map<String, dynamic> toJson() => {
        'base': base,
        'joined': joined,
        if (lastSyncAt != null) 'lastSyncAt': lastSyncAt!.toUtc().toIso8601String(),
        if (claims.isNotEmpty) 'claims': claims,
        if (seen.isNotEmpty) 'seen': {for (final e in seen.entries) e.key: e.value.toUtc().toIso8601String()},
        if (!joined && preferLocal) 'preferLocal': true,
        if (!joined && preferFile) 'preferFile': true,
      };
}
