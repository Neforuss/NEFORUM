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
import 'sync_sources.dart';

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
  const SyncReport({required this.at, this.received = 0, this.sent = 0, this.conflicts = 0, this.mergedCopies = 0, this.wrote = false});

  final DateTime at;

  /// Records changed elsewhere and applied here.
  final int received;

  /// Records changed here and written to the file.
  final int sent;

  /// Records changed on both sides (the newer one won).
  final int conflicts;

  /// Cloud-client conflict copies merged in.
  final int mergedCopies;
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

  Future<_Pass> _syncOnce() async {
    final now = _now();
    final st = _State.parse(await state.read());
    final remote = await _pull();
    final doc = remote.doc;
    final before = syncHash(doc.toJson(writtenBy: '', writtenAt: DateTime.utc(2000)));
    final firstJoin = !st.joined;

    if (firstJoin && remote.exists) await _adoptHandoffTwins(doc);

    final local = <String, SyncItem>{};
    for (final s in _sources.values) {
      for (final e in (await s.snapshot()).entries) {
        local['${s.prefix}:${e.key}'] = e.value;
      }
    }
    final localHash = {for (final e in local.entries) e.key: syncHash(e.value.value)};

    var received = 0, sent = 0, conflicts = 0;
    final toApply = <String, Object?>{};
    final newBase = <String, String>{};
    final keys = {...local.keys, ...doc.records.keys, ...st.base.keys};
    for (final key in keys) {
      if (_sourceOf(key) == null) {
        // A kind of record this version does not know (a newer NEFORUM):
        // left in the file untouched.
        continue;
      }
      final l = localHash[key];
      final rec = doc.records[key];
      final r = rec == null || rec.deleted ? null : rec.hash;
      final b = st.base[key];
      if (l == r) {
        if (l != null) newBase[key] = l;
        continue;
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
        takeRemote = _remoteWins(key, local[key], rec, now, firstJoin: firstJoin);
      }
      if (takeRemote) {
        toApply[key] = rec!.deleted ? null : rec.value;
        if (r != null) newBase[key] = r;
        received++;
      } else {
        final item = local[key];
        doc.records[key] =
            item == null ? SyncRecord.tombstone(at: now, by: deviceId) : SyncRecord.of(item.value, at: item.modifiedAt ?? now, by: deviceId);
        if (l != null) newBase[key] = l;
        sent++;
      }
    }

    // Accounts before their keys before the posts that use them.
    final ordered = toApply.keys.toList()..sort((a, b) => _applyRank(a).compareTo(_applyRank(b)));
    for (final key in ordered) {
      try {
        await _sourceOf(key)!.apply(_idOf(key), toApply[key]);
      } on Object catch (e) {
        _log.warn('Could not apply $key from the sync file: $e');
        // Try again next time.
        final b = st.base[key];
        if (b == null) {
          newBase.remove(key);
        } else {
          newBase[key] = b;
        }
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

    final seen = doc.devices[deviceId]?.seenAt;
    final changed = syncHash(doc.toJson(writtenBy: '', writtenAt: DateTime.utc(2000))) != before;
    final mustWrite =
        changed || remote.copies.isNotEmpty || (!remote.exists && doc.records.isNotEmpty) || seen == null || now.difference(seen) >= heartbeat;
    String? version = remote.version;
    if (mustWrite) {
      version = await _write(remote, doc);
    } else {
      _cachedDoc = doc.copy();
      _cachedVersion = remote.version;
    }
    await state.write(_State(
      base: newBase,
      joined: true,
      lastSyncAt: now,
      claims: {for (final e in doc.claims.entries) e.key: e.value.by},
      seen: {for (final e in doc.devices.entries) e.key: e.value.seenAt},
    ).toJson());
    if (received > 0 || sent > 0) _log.info('Synced: $received in, $sent out${conflicts > 0 ? ', $conflicts on both sides' : ''}');
    return _Pass(
      SyncReport(at: now, received: received, sent: sent, conflicts: conflicts, mergedCopies: remote.copies.length, wrote: mustWrite),
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

  /// Both sides changed [key]: whether the file's version wins.
  bool _remoteWins(String key, SyncItem? local, SyncRecord rec, DateTime now, {required bool firstJoin}) {
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
    // A device joining the file takes what is already there.
    if (firstJoin) return true;
    return rec.at.isAfter(local.modifiedAt ?? now);
  }

  static int _statusRank(Object? postJson) => switch (postJson is Map ? postJson['status'] : null) {
        'published' => 3,
        'partial' || 'failed' => 2,
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

  /// Hand-off accounts get random ids, so the same one set up on two
  /// devices before they shared a file has two ids. On a device's first
  /// sync its twin takes the file's id, and its posts follow.
  Future<void> _adoptHandoffTwins(SyncDocument doc) async {
    final accounts = _sources['account'];
    if (accounts == null) return;
    final mine = await accounts.snapshot();
    final remoteAccounts = <String, Map<Object?, Object?>>{
      for (final e in doc.records.entries)
        if (e.key.startsWith('account:') && !e.value.deleted && e.value.value is Map) e.key.substring(8): e.value.value as Map<Object?, Object?>,
    };
    final twins = <String, String>{};
    for (final e in mine.entries) {
      final a = e.value.value;
      if (a is! Map || a['tier'] != 'handoff' || remoteAccounts.containsKey(e.key)) continue;
      for (final r in remoteAccounts.entries) {
        if (mine.containsKey(r.key) || twins.containsValue(r.key)) continue;
        final v = r.value;
        if (v['tier'] == 'handoff' && v['platformId'] == a['platformId'] && v['displayName'] == a['displayName']) {
          twins[e.key] = r.key;
          break;
        }
      }
    }
    if (twins.isEmpty) return;
    final posts = _sources['post'];
    if (posts != null) {
      for (final e in (await posts.snapshot()).entries) {
        final p = e.value.value;
        if (p is! Map || p['targets'] is! List) continue;
        final targets = p['targets'] as List;
        if (!targets.any((t) => t is Map && twins.containsKey(t['accountId']))) continue;
        await posts.apply(e.key, {
          ...p.cast<String, Object?>(),
          'targets': [
            for (final t in targets)
              if (t is Map && twins.containsKey(t['accountId'])) {...t.cast<String, Object?>(), 'accountId': twins[t['accountId']]} else t,
          ],
        });
      }
    }
    for (final e in twins.entries) {
      await accounts.apply(e.value, remoteAccounts[e.value]);
      await accounts.apply(e.key, null);
      _log.info('Matched hand-off account ${e.key} to ${e.value} from the sync file');
    }
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

class _State {
  _State({required this.base, required this.joined, this.lastSyncAt, this.claims = const {}, this.seen = const {}});

  factory _State.parse(Map<String, dynamic>? j) {
    final raw = j?['base'];
    return _State(
      base: {
        if (raw is Map)
          for (final e in raw.entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
      joined: j?['joined'] == true,
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
  final DateTime? lastSyncAt;

  /// Scheduled post id -> the device that publishes it, as last seen, for
  /// when the file cannot be read (a phone's background task).
  final Map<String, String> claims;

  /// Device id -> its last heartbeat, as last seen.
  final Map<String, DateTime> seen;

  Map<String, dynamic> toJson() => {
        'base': base,
        'joined': joined,
        if (lastSyncAt != null) 'lastSyncAt': lastSyncAt!.toUtc().toIso8601String(),
        if (claims.isNotEmpty) 'claims': claims,
        if (seen.isNotEmpty) 'seen': {for (final e in seen.entries) e.key: e.value.toUtc().toIso8601String()},
      };
}
