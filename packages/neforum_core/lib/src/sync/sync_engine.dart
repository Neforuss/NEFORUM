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

    final local = <String, SyncItem>{};
    for (final s in _sources.values) {
      for (final e in (await s.snapshot()).entries) {
        local['${s.prefix}:${e.key}'] = e.value;
      }
    }

    // A device's first sync: whose version is kept where both sides hold a
    // different one (the seed rule, or the choice confirmed in the dry run),
    // and one account connected on both sides under two ids becomes one.
    final here = SyncSideSummary.ofAccounts([for (final e in local.entries) if (e.key.startsWith('account:')) e.value.value]);
    final there = SyncSideSummary.ofAccounts([
      for (final e in doc.records.entries)
        if (e.key.startsWith('account:') && !e.value.deleted) e.value.value,
    ]);
    final seed = firstJoin ? (st.seed ?? chooseSyncSeed(here: here, file: there)) : null;
    final localWins = seed == SyncSeed.thisDevice;
    final mergeEdits = <String, Object?>{};
    final forceLocal = <String>{};
    final decisions = <String, _MergeDecision>{};
    final twins = firstJoin && remote.exists ? _mergeTwins(local, doc, mergeEdits, forceLocal, st.merging, decisions) : const <String, String>{};

    // A device that joined the file since this one last synced: values kept
    // over an older NEFORUM's deletion go back into the file once, for it.
    final newDevice = !firstJoin && doc.devices.keys.any((id) => id != deviceId && !st.seen.containsKey(id));

    final localHash = {for (final e in local.entries) e.key: syncHash(e.value.value)};
    var received = 0, sent = 0, conflicts = 0;
    final toApply = <String, Object?>{};
    final removedKeys = <String>{};
    final hereBefore = <String, Object?>{};
    final sentValues = <String, Object?>{};
    final fileBefore = <String, Object?>{};
    final newBase = <String, String>{};
    // Notes a record written into the file (the caller writes it), with
    // what the file held before, for the dry run.
    void send(String key, Object? value, SyncRecord? rec) {
      fileBefore[key] = rec == null || rec.deleted ? null : rec.value;
      sentValues[key] = value;
      sent++;
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
          send(key, item.value, rec);
          newBase[key] = l!;
          continue;
        }
      }
      final bool takeRemote;
      if (rec == null) {
        // Not in the file at all (a new file, or a forgotten tombstone):
        // never a reason to delete here.
        takeRemote = false;
      } else if (forceLocal.contains(key)) {
        // A merged account whose newer sign-in is this device's.
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
            send(key, merged, rec);
          }
          if (m != l) {
            toApply[key] = merged;
            hereBefore[key] = item!.value;
            received++;
          }
          newBase[key] = m;
          continue;
        }
        takeRemote = _remoteWins(key, item, rec, now, firstJoin: firstJoin, localWins: localWins);
      }
      if (takeRemote) {
        toApply[key] = rec!.deleted ? null : rec.value;
        hereBefore[key] = local[key]?.value;
        if (rec.deleted) removedKeys.add(key);
        if (r != null) newBase[key] = r;
        received++;
      } else {
        final item = local[key];
        send(key, item?.value, rec);
        doc.records[key] =
            item == null ? SyncRecord.tombstone(at: now, by: deviceId) : SyncRecord.of(item.value, at: item.modifiedAt ?? now, by: deviceId);
        if (l != null) newBase[key] = l;
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
      mergeEdits: mergeEdits,
      toApply: toApply,
      newBase: newBase,
      received: received,
      sent: sent,
      conflicts: conflicts,
      twins: twins,
      decisions: decisions,
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
        mergedAccounts: Map.unmodifiable(twins),
        mergeEdits: Map.unmodifiable(mergeEdits),
        fromDevices: List.unmodifiable(from.keys.toList()..sort((a, b) => from[b]!.compareTo(from[a]!))),
      ),
    );
  }

  /// Does what [plan] worked out: stores the merged accounts and what came
  /// from the file here, writes the file when it changed, and remembers
  /// what both sides now agree on.
  Future<_Pass> _execute(_Plan plan) async {
    final now = plan.now, st = plan.state, remote = plan.remote, doc = plan.remote.doc, newBase = plan.newBase;
    final seed = plan.preview.seed;
    final firstJoin = plan.preview.firstJoin;

    // A first sync keeps its seed and its account merges in the sync state
    // before it changes anything here: when the file write that follows is
    // refused (another device wrote meanwhile) or never happens (offline,
    // the app closed), the next pass makes the same decisions instead of
    // working them out again from what this pass already changed, which
    // would let the file's older sign-in replace the newer one.
    if (firstJoin) {
      await state.write(_State(
        base: st.base,
        joined: false,
        lastSyncAt: st.lastSyncAt,
        claims: st.claims,
        seen: st.seen,
        preferLocal: seed == SyncSeed.thisDevice,
        preferFile: seed == SyncSeed.file,
        merging: plan.decisions,
      ).toJson());
    }

    // Merged accounts first, then what came from the file (which wins where
    // both touch the same record). Every value before any removal, so a
    // merged account is stored under the file's id before its old copy
    // goes; within each, accounts before their keys before the posts that
    // use them.
    final changes = {...plan.mergeEdits, ...plan.toApply};
    int order(String a, String b) {
      final byRemoval = (changes[a] == null ? 1 : 0).compareTo(changes[b] == null ? 1 : 0);
      return byRemoval != 0 ? byRemoval : _applyRank(a).compareTo(_applyRank(b));
    }

    void retryNextTime(String key) {
      final b = st.base[key];
      if (b == null) {
        newBase.remove(key);
      } else {
        newBase[key] = b;
      }
    }

    var failed = false, mergeUnfinished = false;
    final stored = <String, Set<String>>{};
    for (final key in changes.keys.toList()..sort(order)) {
      final value = changes[key];
      // A merged account's old copy only goes once everything else landed:
      // a failed step leaves a duplicate, never a lost account, and the
      // merge is done again on the next sync (the first sync stays open).
      if (value == null && failed && plan.mergeEdits.containsKey(key)) {
        mergeUnfinished = true;
        continue;
      }
      try {
        await _sourceOf(key)!.apply(_idOf(key), value);
        if (value != null) (stored[key.substring(0, key.indexOf(':'))] ??= {}).add(_idOf(key));
      } on Object catch (e) {
        failed = true;
        if (plan.mergeEdits.containsKey(key)) mergeUnfinished = true;
        _log.warn('Could not store $key from the sync file: $e');
        retryNextTime(key);
      }
    }
    // Agreement is only recorded for what really landed: a value this device
    // could not keep (a media host a newer NEFORUM added) is not "deleted
    // here" on the next sync, which would write a deletion over the device
    // that has it.
    for (final e in stored.entries) {
      final present = await _sources[e.key]!.snapshot();
      for (final id in e.value) {
        if (!present.containsKey(id)) {
          _log.warn('${e.key}:$id from the sync file did not land here; trying again next time');
          retryNextTime('${e.key}:$id');
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
    // The first sync completes here, unless an account merge could not be
    // finished: then its seed and merges stay for the next sync.
    final stillJoining = firstJoin && mergeUnfinished;
    await state.write(_State(
      base: newBase,
      joined: !stillJoining,
      lastSyncAt: now,
      claims: {for (final e in doc.claims.entries) e.key: e.value.by},
      seen: {for (final e in doc.devices.entries) e.key: e.value.seenAt},
      preferLocal: stillJoining && seed == SyncSeed.thisDevice,
      preferFile: stillJoining && seed == SyncSeed.file,
      merging: stillJoining ? plan.decisions : const {},
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
  bool _remoteWins(String key, SyncItem? local, SyncRecord rec, DateTime now, {required bool firstJoin, bool localWins = false}) {
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

  /// One account connected on this device and in the file under two ids
  /// (Mastodon, Pixelfed and TikTok make up a random id on each device, and
  /// so do hand-off accounts: [isDeviceMadeAccountId]) becomes one on the
  /// device's first sync, matched by its identity on the network
  /// ([naturalAccountKey]) or its handle ([isSameConnectedAccount]). It
  /// keeps the file's id, so the devices
  /// already syncing change nothing; it keeps the newer sign-in, account and
  /// keys together (a server's app registration and its token belong to each
  /// other) ([holdsNewerSignIn]); and every post and setting naming the old
  /// id follows ([SyncSource.remapAccountIds]).
  ///
  /// Works on [local] (this device's records, changed in place) and lists in
  /// [edits] what to store here; [forceLocal] gets the records whose version
  /// here must replace the file's. [pending] holds the merges an earlier,
  /// unfinished pass of this first sync decided: they are made again with
  /// the same decision, whatever that pass already changed here; [decisions]
  /// gets every merge of this pass, to keep until the first sync completes.
  /// Returns this device's id -> the file's.
  Map<String, String> _mergeTwins(Map<String, SyncItem> local, SyncDocument doc, Map<String, Object?> edits, Set<String> forceLocal,
      Map<String, _MergeDecision> pending, Map<String, _MergeDecision> decisions) {
    Map<Object?, Object?>? asMap(Object? v) => v is Map ? v : null;
    final mine = <String, Map<Object?, Object?>>{
      for (final e in local.entries)
        if (e.key.startsWith('account:') && e.value.value is Map) e.key.substring(8): e.value.value as Map<Object?, Object?>,
    };
    final theirs = <String, Map<Object?, Object?>>{
      for (final e in doc.records.entries)
        if (e.key.startsWith('account:') && !e.value.deleted && e.value.value is Map) e.key.substring(8): e.value.value as Map<Object?, Object?>,
    };
    final twins = <String, String>{
      for (final e in pending.entries)
        // Still to do, or done here already (this device then has the
        // account under the file's id).
        if (theirs.containsKey(e.value.into) || mine.containsKey(e.value.into)) e.key: e.value.into,
    };
    for (final m in mine.entries) {
      if (theirs.containsKey(m.key) || twins.containsKey(m.key) || twins.containsValue(m.key)) continue;
      for (final t in theirs.entries) {
        if (mine.containsKey(t.key) || twins.containsValue(t.key)) continue;
        if (isSameConnectedAccount(m.value, t.value)) {
          twins[m.key] = t.key;
          break;
        }
      }
    }
    if (twins.isEmpty) return twins;

    for (final e in twins.entries) {
      final hereId = e.key, fileId = e.value;
      final hereAccount = mine[hereId];
      final keysRecord = doc.records['secrets:$fileId'];
      final fileKeys = keysRecord == null || keysRecord.deleted ? null : asMap(keysRecord.value);
      if (hereAccount == null) {
        // An earlier pass already stored the merged account under the
        // file's id: keep its decision, and clear what may be left of the
        // old copy's keys.
        final decision = pending[hereId]!;
        decisions[hereId] = decision;
        // Only what this device holds wins: forcing a record it does not
        // hold would write a deletion over the file's.
        if (decision.hereNewer) forceLocal.addAll(['account:$fileId', 'secrets:$fileId'].where(local.containsKey));
        edits['secrets:$hereId'] = null;
        continue;
      }
      final hereKeys = asMap(local['secrets:$hereId']?.value);
      final fileAccount = theirs[fileId] ?? mine[fileId];
      final hereNewer = pending[hereId]?.hereNewer ??
          (fileAccount == null || holdsNewerSignIn(first: hereAccount, firstKeys: hereKeys, second: fileAccount, secondKeys: fileKeys));
      decisions[hereId] = _MergeDecision(fileId, hereNewer: hereNewer);
      final Object account = hereNewer || fileAccount == null ? {...hereAccount.cast<String, Object?>(), 'id': fileId} : fileAccount;
      final keys = hereNewer ? (hereKeys ?? fileKeys) : (fileKeys ?? hereKeys);

      local.remove('account:$hereId');
      edits['account:$hereId'] = null;
      if (local.remove('secrets:$hereId') != null) edits['secrets:$hereId'] = null;
      local['account:$fileId'] = SyncItem(account);
      edits['account:$fileId'] = account;
      if (keys != null) {
        local['secrets:$fileId'] = SyncItem(keys);
        edits['secrets:$fileId'] = keys;
      }
      if (hereNewer) forceLocal.addAll(['account:$fileId', 'secrets:$fileId'].where(local.containsKey));
      _log.info('Account $hereId is $fileId from the sync file: merged into one (${hereNewer ? "this device's" : "the file's"} sign-in kept)');
    }

    for (final e in local.entries.toList()) {
      final source = _sourceOf(e.key);
      if (source == null) continue;
      final value = source.remapAccountIds(_idOf(e.key), e.value.value, twins);
      if (identical(value, e.value.value)) continue;
      local[e.key] = SyncItem(value, modifiedAt: e.value.modifiedAt);
      edits[e.key] = value;
    }
    return twins;
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
    required this.decisions,
    required this.preview,
  });

  final DateTime now;
  final _State state;

  /// The account merges decided, to keep in the state until the first sync
  /// completes.
  final Map<String, _MergeDecision> decisions;

  /// The file as read, its document already merged (written by _execute).
  final _Remote remote;

  /// The document's hash before merging: unchanged means no write.
  final String before;

  /// This device's records after merging accounts.
  final Map<String, SyncItem> local;

  /// What merging accounts stores here (key -> value; `null` removes).
  final Map<String, Object?> mergeEdits;

  /// What comes from the file and is stored here.
  final Map<String, Object?> toApply;
  final Map<String, String> newBase;
  final int received, sent, conflicts;
  final Map<String, String> twins;
  final SyncPreview preview;
}

/// 1.3.5: a merge of two copies of one account, decided on a first sync and
/// kept in the sync state until that first sync completes, so that a retried
/// or interrupted pass makes the same decision again instead of working it
/// out anew from what the interrupted pass already changed.
class _MergeDecision {
  const _MergeDecision(this.into, {required this.hereNewer});

  static _MergeDecision? tryParse(Object? raw) =>
      raw is Map && raw['into'] is String ? _MergeDecision(raw['into'] as String, hereNewer: raw['hereNewer'] == true) : null;

  /// The file's id of the account, which the merged account keeps.
  final String into;

  /// Whether this device holds the newer sign-in (its account and keys win).
  final bool hereNewer;

  Map<String, dynamic> toJson() => {'into': into, 'hereNewer': hereNewer};
}

class _State {
  _State(
      {required this.base,
      required this.joined,
      this.lastSyncAt,
      this.claims = const {},
      this.seen = const {},
      this.preferLocal = false,
      this.preferFile = false,
      this.merging = const {}});

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
      merging: {
        if (j?['merging'] case final Map<Object?, Object?> m)
          for (final e in m.entries)
            if (e.key is String && _MergeDecision.tryParse(e.value) != null) e.key as String: _MergeDecision.tryParse(e.value)!,
      },
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

  /// 1.3.5: the account merges of a first sync that has not completed yet:
  /// this device's id -> the decision.
  final Map<String, _MergeDecision> merging;

  /// The seed and the merges hold until the first sync completes; after it
  /// they are gone.
  Map<String, dynamic> toJson() => {
        'base': base,
        'joined': joined,
        if (lastSyncAt != null) 'lastSyncAt': lastSyncAt!.toUtc().toIso8601String(),
        if (claims.isNotEmpty) 'claims': claims,
        if (seen.isNotEmpty) 'seen': {for (final e in seen.entries) e.key: e.value.toUtc().toIso8601String()},
        if (!joined && preferLocal) 'preferLocal': true,
        if (!joined && preferFile) 'preferFile': true,
        if (!joined && merging.isNotEmpty) 'merging': {for (final e in merging.entries) e.key: e.value.toJson()},
      };
}
