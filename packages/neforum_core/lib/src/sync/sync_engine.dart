import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

  /// 1.3.5: what [sync] would do now: the dry run shown before a device's
  /// first sync. It runs the sync itself, the same code, on copies of this
  /// device's records, of the sync file and of the [state], and writes
  /// nothing anywhere. What it reports is the difference between the copies
  /// before and after, so it is what the sync does, by construction:
  ///
  /// * [SyncPreview.received]: the records that arrive here or change here
  ///   (a record rewritten to the same value is not a change), with what
  ///   this device held before ([SyncPreview.hereBefore]);
  /// * [SyncPreview.removed]: the ones that go;
  /// * [SyncPreview.sent]: this device's own records the file gets: ones it
  ///   held, whose version the file did not have, and that the file holds
  ///   afterwards (tombstones, merge links and the file's own records a
  ///   merge rewrites are not "from this device");
  /// * [SyncPreview.fromDevices]: the devices that last wrote the records
  ///   that arrive.
  ///
  /// Throws as [sync] does (wrong passphrase, storage out of reach).
  Future<SyncPreview> preview() => _locked(() async {
        final before = <String, SyncItem>{};
        final copies = <SyncSource>[];
        for (final s in _sources.values) {
          final items = await s.snapshot();
          for (final e in items.entries) {
            before['${s.prefix}:${e.key}'] = e.value;
          }
          copies.add(_SimulatedSource(s, items));
        }
        final blob = await backend.read();
        final dryBackend = _SimulatedBackend(blob, await backend.conflictCopies());
        final stateNow = await state.read();
        final dryState = MemorySyncStateStore()..data = stateNow == null ? null : jsonDecode(jsonEncode(stateNow)) as Map<String, dynamic>;
        final dry = SyncEngine(
          backend: dryBackend,
          cipher: cipher,
          deviceId: deviceId,
          device: device,
          sources: copies,
          state: dryState,
          clock: _now,
          log: Logger('sync.dry-run', sink: (level, area, message, [error]) {}),
          heartbeat: heartbeat,
          ownerTimeout: ownerTimeout,
          leaseTime: leaseTime,
          renewalWait: renewalWait,
          tombstoneLife: tombstoneLife,
        );
        final plan = await dry._plan();
        await dry._execute(plan);
        dry.dispose();

        final after = <String, SyncItem>{
          for (final s in copies)
            for (final e in (s as _SimulatedSource).items.entries) '${s.prefix}:${e.key}': e.value,
        };
        final fileBefore = blob == null ? SyncDocument() : SyncDocument.parse(await cipher.open(blob.bytes));
        final fileAfter = dryBackend.blob == null ? SyncDocument() : SyncDocument.parse(await cipher.open(dryBackend.blob!.bytes));
        String? hashOf(SyncItem? item) => item == null ? null : syncHash(item.value);
        SyncRecord? live(SyncDocument d, String k) => d.records[k] == null || d.records[k]!.deleted ? null : d.records[k];

        final received = <String, Object?>{}, hereBefore = <String, Object?>{};
        final removed = <String>{};
        for (final k in {...before.keys, ...after.keys}) {
          if (hashOf(before[k]) == hashOf(after[k])) continue;
          if (after.containsKey(k)) {
            received[k] = after[k]!.value;
            hereBefore[k] = before[k]?.value;
          } else {
            removed.add(k);
          }
        }
        final sentValues = <String, Object?>{}, sentBefore = <String, Object?>{};
        for (final k in fileAfter.records.keys) {
          final now = live(fileAfter, k), was = live(fileBefore, k), mine = before[k];
          if (now == null || mine == null || now.hash == was?.hash || syncHash(mine.value) == was?.hash) continue;
          sentValues[k] = now.value;
          sentBefore[k] = was?.value;
        }
        final from = <String, int>{};
        for (final k in received.keys) {
          final by = plan.original[k]?.by;
          if (by == null || by == deviceId) continue;
          final d = plan.remote.doc.devices[by];
          final name = d == null ? 'another device' : (d.label.isEmpty ? d.platform : d.label);
          from[name] = (from[name] ?? 0) + 1;
        }
        return SyncPreview(
          fileExists: blob != null,
          firstJoin: plan.firstJoin,
          seed: plan.seed,
          here: plan.here,
          file: plan.there,
          received: Map.unmodifiable(received),
          hereBefore: Map.unmodifiable(hereBefore),
          removed: Set.unmodifiable(removed),
          sent: Set.unmodifiable(sentValues.keys),
          sentValues: Map.unmodifiable(sentValues),
          fileBefore: Map.unmodifiable(sentBefore),
          mergedAccounts: Map.unmodifiable(plan.twins),
          mergedInFile: Set.unmodifiable(plan.mergedInFile),
          mergeEdits: Map.unmodifiable(plan.mergeEdits),
          fromDevices: List.unmodifiable(from.keys.toList()..sort((a, b) => from[b]!.compareTo(from[a]!))),
        );
      });

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
    final fromCopies = <String>{};
    for (final c in await backend.conflictCopies()) {
      try {
        final copy = SyncDocument.parse(await cipher.open(c.bytes));
        final mine = doc.copy();
        for (final k in copy.records.keys) {
          if (k.startsWith('account:') && mine.records[k] == null) fromCopies.add(k.substring(8));
        }
        doc.absorb(copy, prefer: (key, _, __) => key.startsWith('secrets:') ? _preferCopy(key, mine, copy) : null);
        _mergeAccountEdits(doc, mine, copy);
        copies.add(c);
      } on BackupException catch (e) {
        _log.warn('Not merging ${c.name}: ${e.message}');
      }
    }
    return _Remote(doc, blob?.version, exists: blob != null, copies: copies, fromCopies: fromCopies);
  }

  /// 1.3.5: which version of an account or its keys a cloud app's conflicted
  /// copy brings in: the newer sign-in, account and keys together
  /// ([holdsNewerSignIn]), not the later write; `null`
  /// (the later write) for everything else and for a tie.
  static bool? _preferCopy(String key, SyncDocument mine, SyncDocument copy) {
    final i = key.indexOf(':');
    if (i <= 0) return null; // not a record kind this version knows: the later write
    final prefix = key.substring(0, i), id = key.substring(i + 1);
    if (prefix != 'account' && prefix != 'secrets') return null;
    Map<Object?, Object?>? live(SyncDocument d, String k) {
      final r = d.records[k];
      return r == null || r.deleted || r.value is! Map ? null : r.value as Map<Object?, Object?>;
    }

    final a1 = live(mine, 'account:$id'), a2 = live(copy, 'account:$id');
    if (a1 == null || a2 == null) return null;
    final k1 = live(mine, 'secrets:$id'), k2 = live(copy, 'secrets:$id');
    if (holdsNewerSignIn(first: a2, firstKeys: k2, second: a1, secondKeys: k1)) return true;
    if (holdsNewerSignIn(first: a1, firstKeys: k1, second: a2, secondKeys: k2)) return false;
    return null;
  }

  /// 1.3.5: one account changed in the main file ([mine]) and in a cloud
  /// app's conflicted copy at the same moment: the parts the keys depend on
  /// (tier, app registration, ids) come from the newer sign-in, together with
  /// its keys; the user's own edits ([kUserEditedAccountFields]: switched
  /// off, renamed, quotas) follow the later write. Without a newer sign-in
  /// on either side, the later write stands whole, as [SyncDocument.absorb]
  /// left it.
  static void _mergeAccountEdits(SyncDocument doc, SyncDocument mine, SyncDocument copy) {
    for (final e in copy.records.entries) {
      if (!e.key.startsWith('account:')) continue;
      final a = mine.records[e.key], b = e.value;
      if (a == null || a.deleted || b.deleted || a.value is! Map || b.value is! Map || a.hash == b.hash) continue;
      final signIn = _preferCopy(e.key, mine, copy);
      if (signIn == null) continue;
      final later = b.at.isAfter(a.at) ? b : a, keys = signIn ? b : a;
      final merged = <String, Object?>{
        ...(keys.value! as Map).cast<String, Object?>(),
        for (final f in kUserEditedAccountFields)
          if ((later.value! as Map).containsKey(f)) f: (later.value! as Map)[f],
      };
      doc.records[e.key] = SyncRecord.of(merged, at: later.at, by: keys.by);
    }
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
    final aliases = {
      for (final e in st.aliases.entries)
        if (now.difference(e.value.at) <= tombstoneLife) e.key: e.value,
    };
    // The file's side counts each account once: two copies of one account
    // that this pass makes one (two devices that connected it at the same
    // moment) are one account, the way the dry run then says.
    final inFile = <String, Map<Object?, Object?>>{
      for (final e in doc.records.entries)
        if (e.key.startsWith('account:') && !e.value.deleted && e.value.value is Map) e.key.substring(8): e.value.value! as Map<Object?, Object?>,
    };
    final twinsInFile = _pairTwins(inFile, _recordedLinks(doc, {for (final e in aliases.entries) e.key: e.value.into}),
        inFileBefore: (_) => true, fresh: remote.fromCopies.contains, firstJoin: firstJoin, localIds: const {});
    final allInFile = SyncSideSummary.ofAccounts(inFile.values);
    final there = SyncSideSummary(accounts: allInFile.accounts - twinsInFile.length, oldestConnection: allInFile.oldestConnection);
    final seed = firstJoin ? (st.seed ?? chooseSyncSeed(here: here, file: there)) : null;
    final localWins = seed == SyncSeed.thisDevice;

    // A device that joined the file since this one last synced: values kept
    // over an older NEFORUM's deletion go back into the file once, for it.
    final newDevice = !firstJoin && doc.devices.keys.any((id) => id != deviceId && !st.seen.containsKey(id));

    final localHash = {for (final e in local.entries) e.key: syncHash(e.value.value)};
    var conflicts = 0;
    final toApply = <String, Object?>{};
    final newBase = <String, String>{};
    // The records this pass writes into the file (for the report; the dry
    // run compares whole states instead, see [preview]).
    final written = <String>{};
    void send(String key, Object? value) => written.add(key);

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
        final id = _idOf(key);
        final remoteWins = _remoteWins(key, item, rec, now,
            firstJoin: firstJoin, localWins: localWins, hereAccount: local['account:$id']?.value, fileAccount: original['account:$id']?.value);
        final merged = item == null || rec.deleted
            ? null
            : (firstJoin ? source.joinMerge(id, item.value, rec.value, hereWins: localWins) : null) ??
                (key.startsWith('account:')
                    ? _splitAccount(item.value, rec.value, local['secrets:$id']?.value, original['secrets:$id'], userEditsFromHere: !remoteWins)
                    : null);
        if (merged != null) {
          // Both versions combined (a media host in each empty slot; an
          // account's sign-in from one side, the user's edits from the
          // other): stored here and written to the file where it differs.
          final m = syncHash(merged);
          if (m != r) {
            doc.records[key] = SyncRecord.of(merged, at: now, by: deviceId);
            send(key, merged);
          }
          if (m != l) toApply[key] = merged;
          newBase[key] = m;
          continue;
        }
        takeRemote = remoteWins;
      }
      if (takeRemote) {
        toApply[key] = rec!.deleted ? null : rec.value;
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
    // now agree on ([_mergeDuplicates] says which copies, and when).
    final localIds = {for (final k in local.keys) if (k.startsWith('account:')) k.substring(8)};
    final merge = _mergeDuplicates(doc, original, now, send, written.remove,
        firstJoin: firstJoin, localIds: localIds, fromCopies: remote.fromCopies, aliases: {for (final e in aliases.entries) e.key: e.value.into});
    for (final e in merge.newAliases.entries) {
      aliases[e.key] = (into: e.value, at: now);
    }
    // Every link this device saw in the file stays here too, whatever later
    // happens to the file.
    for (final e in merge.fileLinks.entries) {
      if (now.difference(e.value.at) <= tombstoneLife) aliases.putIfAbsent(e.key, () => e.value);
    }
    for (final e in merge.edits.entries) {
      toApply.remove(e.key);
      if (e.value == null) {
        newBase.remove(e.key);
      } else {
        newBase[e.key] = syncHash(e.value);
      }
    }

    // Forget old tombstones and links, finished leases and claims.
    doc.records.removeWhere((k, rec) => (rec.deleted || k.startsWith('alias:')) && now.difference(rec.at) > tombstoneLife);
    newBase.removeWhere((k, _) => !doc.records.containsKey(k) && !local.containsKey(k));
    doc.leases.removeWhere((id, lease) => !lease.liveAt(now) || (lease.by == deviceId && !_renewing.contains(id)));
    doc.claims.removeWhere((id, _) => _postStatus(doc.records['post:$id']) != 'scheduled');
    for (final e in doc.records.entries) {
      if (!e.key.startsWith('post:') || _postStatus(e.value) != 'scheduled') continue;
      doc.claims.putIfAbsent(e.key.substring(5), () => SyncClaim(by: e.value.by, at: now));
    }

    return _Plan(
      now: now,
      state: st,
      remote: remote,
      before: before,
      original: original,
      local: local,
      mergeEdits: merge.edits,
      toApply: toApply,
      newBase: newBase,
      received: toApply.length + merge.edits.length,
      sent: written.length,
      conflicts: conflicts,
      twins: merge.twins,
      aliases: aliases,
      firstJoin: firstJoin,
      seed: seed,
      here: here,
      there: there,
      mergedInFile: {
        for (final e in merge.twins.entries)
          if (!localIds.contains(e.key) && !localIds.contains(e.value)) e.key,
      },
    );
  }

  /// 1.3.5: one account changed on both sides: everything the keys depend
  /// on (tier, app registration, ids, when it was connected) comes from the
  /// side that holds the newer sign-in ([holdsNewerSignIn], comparing each
  /// side with its own keys), the user's own edits
  /// ([kUserEditedAccountFields]) from the side the record rule picks
  /// ([userEditsFromHere]). `null` when neither sign-in is newer: then the
  /// record rule decides the whole record.
  static Map<String, Object?>? _splitAccount(Object? here, Object? file, Object? hereKeys, SyncRecord? fileKeys,
      {required bool userEditsFromHere}) {
    if (here is! Map || file is! Map) return null;
    final fk = fileKeys == null || fileKeys.deleted || fileKeys.value is! Map ? null : fileKeys.value as Map<Object?, Object?>;
    final hk = hereKeys is Map ? hereKeys : null;
    final Map<Object?, Object?> signIn;
    if (holdsNewerSignIn(first: here, firstKeys: hk, second: file, secondKeys: fk)) {
      signIn = here;
    } else if (holdsNewerSignIn(first: file, firstKeys: fk, second: here, secondKeys: hk)) {
      signIn = file;
    } else {
      return null;
    }
    final edits = userEditsFromHere ? here : file;
    return {
      ...signIn.cast<String, Object?>(),
      for (final f in kUserEditedAccountFields)
        if (edits.containsKey(f)) f: edits[f],
    };
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
      aliases: plan.aliases,
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
      // The keys of the newer sign-in by the rule the account follows
      // ([holdsNewerSignIn], each side's account with its own keys), so the
      // two always come from one sign-in, also when only the keys changed
      // on both sides and the account simply takes the side that changed
      // it. A reconnect with another app on one device beats a renewal of
      // the old sign-in on another (whose keys expire later, but belong to
      // an app the account no longer uses); through one app, the most
      // recently renewed keys are the ones the network accepts. On a first
      // sync this goes before the seed too: an old token the user replaced
      // may be revoked already.
      if (hereAccount is Map && fileAccount is Map) {
        final lk = local.value is Map ? local.value as Map<Object?, Object?> : null, rk = rec.value is Map ? rec.value as Map<Object?, Object?> : null;
        if (holdsNewerSignIn(first: fileAccount, firstKeys: rk, second: hereAccount, secondKeys: lk)) return true;
        if (holdsNewerSignIn(first: hereAccount, firstKeys: lk, second: fileAccount, secondKeys: rk)) return false;
      } else {
        final le = _expiry(local.value), re = _expiry(rec.value);
        if (le != null && re != null && le != re) return re.isAfter(le);
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
  /// make up a random id on each device, and so do most hand-off accounts:
  /// [isDeviceMadeAccountId]). It works on what both sides agree on once the
  /// records are merged ([doc]), so a pass interrupted halfway, or a reset
  /// sync state, ends the same way. Which copies may merge, and when:
  ///
  /// * Two ids taken from the accounts themselves are two accounts, always
  ///   ([isSameConnectedAccount]).
  /// * Accounts with an identity on their network on both copies (Mastodon
  ///   and Pixelfed: the account id on its server; TikTok: openId with the
  ///   app) merge on any sync, so two devices that joined at the same moment
  ///   end with one account ([naturalAccountKey]).
  /// * Other accounts matched by their handle merge only when one copy is
  ///   new to the file in this sync (made on this device, or arriving
  ///   through a cloud app's conflicted copy [fromCopies]): two copies that
  ///   both lived in the file are never merged.
  /// * Hand-off accounts merge only on this device's first sync ([firstJoin]),
  ///   a hand-off made here against one the file already had that this
  ///   device did not hold ([localIds]), as NEFORUM 1.3.4 did: never two
  ///   copies on two sites or with two handles.
  ///
  /// The id kept is the one the file already had; between two already there,
  /// an id taken from the account itself, else the smaller one, so every
  /// device picks the same. The newer sign-in wins, account and keys
  /// together ([holdsNewerSignIn]). The other id leaves the file as a
  /// tombstone that names the kept id ([SyncRecord.mergedInto]), or leaves
  /// no trace at all when it never was in the file (then [newAliases] keeps
  /// the link on this device). On every pass, posts and settings that name a
  /// merged id ([aliases], from the file and this device) move to the kept
  /// one ([SyncSource.remapAccountIds]), so a draft saved after a merge
  /// still finds its account.
  ///
  /// Changes [doc], notes every record written with [send] (and [unsend] for
  /// one taken back), and returns the merges of this pass (other id -> kept
  /// id), what to store here (`null`: remove the merged copy, which
  /// [_execute] does only after the file is written) and the new links.
  ({
    Map<String, String> twins,
    Map<String, Object?> edits,
    Map<String, String> newAliases,
    Map<String, ({String into, DateTime at})> fileLinks,
  }) _mergeDuplicates(
    SyncDocument doc,
    Map<String, SyncRecord> original,
    DateTime now,
    void Function(String key, Object? value) send,
    void Function(String key) unsend, {
    required bool firstJoin,
    required Set<String> localIds,
    required Set<String> fromCopies,
    required Map<String, String> aliases,
  }) {
    Map<Object?, Object?>? live(String key) {
      final rec = doc.records[key];
      return rec == null || rec.deleted || rec.value is! Map ? null : rec.value as Map<Object?, Object?>;
    }

    final accounts = <String, Map<Object?, Object?>>{
      for (final k in doc.records.keys)
        if (k.startsWith('account:') && live(k) != null) k.substring(8): live(k)!,
    };
    bool inFileBefore(String id) => original['account:$id']?.deleted == false;
    final twins = _pairTwins(accounts, _recordedLinks(doc, aliases),
        inFileBefore: inFileBefore, fresh: (id) => !inFileBefore(id) || fromCopies.contains(id), firstJoin: firstJoin, localIds: localIds);

    final edits = <String, Object?>{};
    final newAliases = <String, String>{};
    void put(String key, Object value, {DateTime? at}) {
      final rec = doc.records[key];
      if (rec == null || rec.deleted || rec.hash != syncHash(value)) {
        doc.records[key] = SyncRecord.of(value, at: at ?? now, by: deviceId);
        send(key, value);
      }
      edits[key] = value;
    }

    void drop(String key, {String? mergedInto}) {
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
        doc.records[key] = SyncRecord.tombstone(at: now, by: deviceId, mergedInto: mergedInto);
        send(key, null);
        if (mergedInto != null) {
          // The link also as a live record of its own: NEFORUM 1.3.4 writes
          // a tombstone back without the extra field, but leaves a record
          // of a kind it does not know as it is.
          final alias = 'alias:${_idOf(key)}';
          doc.records[alias] = SyncRecord.of({'into': mergedInto}, at: now, by: deviceId);
          send(alias, {'into': mergedInto});
        }
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
      if (!inFileBefore(other)) newAliases[other] = keep;
      drop('account:$other', mergedInto: keep);
      if (doc.records.containsKey('secrets:$other') || original.containsKey('secrets:$other')) drop('secrets:$other');
    }

    // Every merged id this pass, in the file or on this device, leads to an
    // account that still exists.
    final links = <String, String>{...aliases, ...twins};
    final fileLinks = <String, ({String into, DateTime at})>{};
    for (final e in doc.records.entries) {
      final link = _linkIn(e.key, e.value);
      if (link == null) continue;
      links[link] = e.key.startsWith('alias:') ? '${(e.value.value! as Map)['into']}' : e.value.mergedInto!;
      fileLinks[link] = (into: links[link]!, at: e.value.at);
    }
    String? resolve(String id) {
      var k = id;
      for (var hops = 0; links.containsKey(k) && hops < 16; hops++) {
        k = links[k]!;
      }
      return k != id && live('account:$k') != null ? k : null;
    }

    final moves = <String, String>{
      for (final id in links.keys)
        if (live('account:$id') == null && resolve(id) != null) id: resolve(id)!,
    };
    if (moves.isNotEmpty) {
      for (final key in doc.records.keys.toList()) {
        final rec = doc.records[key]!;
        final source = _sourceOf(key);
        if (rec.deleted || source == null || !source.handles(_idOf(key)) || key.startsWith('account:') || key.startsWith('secrets:')) continue;
        final value = source.remapAccountIds(_idOf(key), rec.value, moves);
        if (!identical(value, rec.value) && value != null) put(key, value, at: rec.at);
      }
    }
    return (twins: {for (final o in twins.keys) o: keptFor(o)}, edits: edits, newAliases: newAliases, fileLinks: fileLinks);
  }

  /// The links the file and this device record (merged-away id -> the id it
  /// was merged into): `alias:` records, tombstones that name the kept id,
  /// and [aliases] kept on this device.
  static Map<String, String> _recordedLinks(SyncDocument doc, Map<String, String> aliases) {
    final recorded = <String, String>{...aliases};
    for (final e in doc.records.entries) {
      final from = _linkIn(e.key, e.value);
      if (from != null) recorded[from] = e.key.startsWith('alias:') ? '${(e.value.value! as Map)['into']}' : e.value.mergedInto!;
    }
    return recorded;
  }

  /// Which of [accounts] (id -> account) are copies of one account, and the
  /// id each keeps (merged id -> kept id), by the rules [_mergeDuplicates]
  /// lists. [recorded] are the links already made ([_recordedLinks]): a copy
  /// brought back to life by NEFORUM 1.3.4 (it keeps an edit over a
  /// deletion) is merged into its link's account again. Also counts each
  /// account in the file once for the seed rule ([_plan]).
  static Map<String, String> _pairTwins(
    Map<String, Map<Object?, Object?>> accounts,
    Map<String, String> recorded, {
    required bool Function(String id) inFileBefore,
    required bool Function(String id) fresh,
    required bool firstJoin,
    required Set<String> localIds,
  }) {
    // Whether [from]'s links lead to [to], over every hop: an account merged
    // twice (a into b, then b into c) links a to c through b. At most 16
    // hops, and a loop ends the walk.
    bool leadsTo(String from, String to) {
      var k = from;
      for (var hops = 0; hops < 16; hops++) {
        final next = recorded[k];
        if (next == null || next == from) return false;
        if (next == to) return true;
        k = next;
      }
      return false;
    }

    final twins = <String, String>{};
    final ids = accounts.keys.toList()..sort();
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        final a = ids[i], b = ids[j];
        if (twins.containsKey(a) || twins.containsKey(b)) continue;
        final va = accounts[a]!, vb = accounts[b]!;
        if (!isSameConnectedAccount(va, vb)) continue;
        final String keep;
        final aToB = leadsTo(a, b);
        if (aToB || leadsTo(b, a)) {
          keep = aToB ? b : a;
        } else if (va['tier'] == 'handoff') {
          final here = !inFileBefore(a) && localIds.contains(a) ? a : (!inFileBefore(b) && localIds.contains(b) ? b : null);
          final there = here == a ? b : a;
          if (!firstJoin || here == null || !inFileBefore(there) || localIds.contains(there)) continue;
          keep = there;
        } else {
          final natural = naturalAccountKey(va) != null && naturalAccountKey(vb) != null;
          if (!natural && !fresh(a) && !fresh(b)) continue;
          if (inFileBefore(a) != inFileBefore(b)) {
            keep = inFileBefore(a) ? a : b;
          } else if (isDeviceMadeAccountId(a) != isDeviceMadeAccountId(b)) {
            keep = isDeviceMadeAccountId(a) ? b : a;
          } else {
            keep = a;
          }
        }
        twins[keep == a ? b : a] = keep;
      }
    }
    return twins;
  }

  /// The merged-away account id a record links from: an `alias:<id>` record
  /// (`{"into": <kept id>}`) or an account tombstone naming the kept id.
  static String? _linkIn(String key, SyncRecord rec) {
    if (key.startsWith('alias:') && !rec.deleted && rec.value is Map && (rec.value! as Map)['into'] is String) return key.substring(6);
    if (key.startsWith('account:') && rec.deleted && rec.mergedInto != null) return key.substring(8);
    return null;
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
  Future<Map<String, String>?> renew(ConnectedAccount account, Map<String, String> current, SecretsRefresh refresh, {bool Function(Map<String, String> secrets)? renewsEarly}) async {
    final store = secrets;
    bool due(Map<String, String> s) => _expired(s) || (renewsEarly?.call(s) ?? false);
    if (store == null || !due(current)) {
      final fresh = await refresh(current);
      if (fresh != null) unawaited(_pushSoon());
      return fresh;
    }
    _renewing.add(account.id);
    var shared = false;
    try {
      var latest = current;
      try {
        latest = await _awaitTurn(account, current, store, due);
      } on _AlreadyRenewed catch (done) {
        return _differs(done.secrets, current);
      } on Object catch (e) {
        // Keys that still work can wait for the file: renewing them now could
        // sign the other devices out, for nothing this post needs.
        if (!_expired(current)) {
          _log.warn('Not renewing ${account.displayName} early without the sync file (${e.runtimeType})');
          return null;
        }
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
          throw _fileMayBeBehind() ? _waitForTheFile(account, e) : e;
        }
        if (_differs(again, latest) != null) {
          if (!due(again)) {
            return _differs(again, current);
          }
          fresh = await refresh(again);
          latest = again;
        } else if (_fileMayBeBehind()) {
          throw _waitForTheFile(account, e);
        } else {
          rethrow;
        }
      }
      // 1.3.5: the refresh ran outside the sync lock, so a sync (the timer,
      // a change) may have stored other keys meanwhile: a reconnect made on
      // another device, perhaps through another app. Those stay, and this
      // renewal of the old sign-in is dropped: under the lease nothing else
      // changes the stored keys, and storing it over a reconnect would pair
      // the new app with the old keys on every device. A keychain that
      // cannot be read now never costs the renewal (the old keys are dead).
      var result = fresh ?? latest;
      final storedNow = await _readKeys(store, account);
      if (storedNow != null && _differs(storedNow, latest) != null) {
        result = storedNow;
      } else {
        await store.write(account.id, result);
      }
      _renewing.remove(account.id);
      shared = await _shareRenewal(account);
      // What this device holds once the renewal is shared, which the caller
      // stores: a reconnect that arrived in that sync wins it too, account and
      // keys together (see [holdsNewerSignIn]).
      final held = shared ? await _readKeys(store, account) : null;
      return _differs(held == null || held.isEmpty ? result : held, current);
    } finally {
      _renewing.remove(account.id);
      if (!shared) await _shareRenewal(account);
    }
  }

  /// The keys [store] holds for [account] now (none: an empty map), or
  /// `null` when the keychain cannot be read at this moment.
  Future<Map<String, String>?> _readKeys(SecretStore store, ConnectedAccount account) async {
    try {
      return await store.read(account.id) ?? const <String, String>{};
    } on Object catch (e) {
      _log.warn('Could not read the ${account.displayName} keys while renewing: $e');
      return null;
    }
  }

  /// Shares a renewal (the new keys) and gives the lease back; whether that
  /// sync went through.
  Future<bool> _shareRenewal(ConnectedAccount account) async {
    try {
      await _locked(_syncLoop);
      return true;
    } on Object catch (e) {
      _log.warn('Could not share the renewed ${account.displayName} sign-in yet: $e');
      return false;
    }
  }

  /// Syncs, then waits while another device holds the account's lease, then
  /// takes it. Returns the keys to renew; throws [_AlreadyRenewed] when
  /// another device's renewal arrived meanwhile.
  Future<Map<String, String>> _awaitTurn(ConnectedAccount account, Map<String, String> current, SecretStore store, bool Function(Map<String, String>) due) async {
    final deadline = _now().add(renewalWait);
    while (true) {
      final pass = await _locked(_syncLoop);
      final latest = await store.read(account.id) ?? current;
      if (!due(latest)) throw _AlreadyRenewed(latest);
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

  /// Whether this device's copy of the file can be older than a renewal another
  /// device has just made: storage without compare and swap (a synced folder
  /// updates its copies on its own time) and a device seen lately.
  bool _fileMayBeBehind() => !backend.atomicWrites && _otherDeviceActive();

  /// A refused renewal that is probably [_fileMayBeBehind]: it waits and is
  /// retried, without asking for a reconnect.
  AdapterException _waitForTheFile(ConnectedAccount account, AdapterException refused) => AdapterException(PublishError.network(
      '${_networkName(account)} refused the saved sign-in, probably because another device renewed it moments ago and '
      'the sync file has not arrived here yet. NEFORUM tries again shortly; if this keeps happening, reconnect the account.',
      raw: refused.error.raw,
      statusCode: refused.error.statusCode));

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
        'tiktok' => 'TikTok',
        'deviantart' => 'DeviantArt',
        'pixelfed' => 'Pixelfed',
        _ => a.platformId,
      };
}

enum _Claim { mine, take, others }

class _AlreadyRenewed implements Exception {
  _AlreadyRenewed(this.secrets);
  final Map<String, String> secrets;
}

class _Remote {
  _Remote(this.doc, this.version, {required this.exists, required this.copies, this.fromCopies = const {}});
  final SyncDocument doc;
  final String? version;
  final bool exists;
  final List<SyncSideCopy> copies;

  /// Accounts that arrived only through a cloud app's conflicted copy (a
  /// device that wrote at the same moment as another): new to the file.
  final Set<String> fromCopies;
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
    required this.aliases,
    required this.original,
    required this.firstJoin,
    required this.seed,
    required this.here,
    required this.there,
    required this.mergedInFile,
  });

  /// The file's records as read (conflicted copies folded in), before this
  /// pass merged anything into them.
  final Map<String, SyncRecord> original;
  final bool firstJoin;
  final SyncSeed? seed;
  final SyncSideSummary here, there;

  /// Merged ids this device held in neither copy.
  final Set<String> mergedInFile;

  /// Merged ids that never were in the file -> the kept id, kept on this
  /// device so a post saved later under the old id still finds its account.
  final Map<String, ({String into, DateTime at})> aliases;

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
}

/// 1.3.5: this device's records of one kind, copied for a dry run: the
/// sync stores into the copy, never into the device ([SyncEngine.preview]).
/// Everything else (which records, deletions, merges, links) is asked of the
/// real source.
class _SimulatedSource extends SyncSource {
  _SimulatedSource(this.real, Map<String, SyncItem> items) : items = Map.of(items);
  final SyncSource real;
  final Map<String, SyncItem> items;

  @override
  String get prefix => real.prefix;
  @override
  Future<Map<String, SyncItem>> snapshot() async => Map.of(items);
  @override
  Future<void> apply(String id, Object? value) async {
    if (value == null && real.appliesDeletions) {
      items.remove(id);
    } else {
      items[id] = SyncItem(value, modifiedAt: items[id]?.modifiedAt);
    }
  }

  @override
  bool handles(String id) => real.handles(id);
  @override
  bool get appliesDeletions => real.appliesDeletions;
  @override
  Object? joinMerge(String id, Object? here, Object? file, {required bool hereWins}) => real.joinMerge(id, here, file, hereWins: hereWins);
  @override
  Object? remapAccountIds(String id, Object? value, Map<String, String> ids) => real.remapAccountIds(id, value, ids);
}

/// 1.3.5: the sync file and its conflicted copies as read, for a dry run:
/// what the sync writes stays here.
class _SimulatedBackend extends SyncBackend {
  _SimulatedBackend(this.blob, List<SyncSideCopy> copies) : copies = List.of(copies);
  SyncBlob? blob;
  final List<SyncSideCopy> copies;
  int _version = 0;

  @override
  String get label => 'dry run';
  @override
  bool get atomicWrites => true;
  @override
  Future<SyncBlob?> read() async => blob;
  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) async {
    blob = SyncBlob(bytes, 'dry-run-${++_version}');
    return blob!.version;
  }

  @override
  Future<List<SyncSideCopy>> conflictCopies() async => List.of(copies);
  @override
  Future<void> removeConflictCopy(SyncSideCopy copy) async => copies.remove(copy);
  @override
  Future<void> check() async {}
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
      this.aliases = const {}});

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
      aliases: {
        if (j?['aliases'] case final Map<Object?, Object?> m)
          for (final e in m.entries)
            if (e.key is String && e.value is Map && (e.value as Map)['into'] is String && DateTime.tryParse('${(e.value as Map)['at']}') != null)
              e.key as String: (into: (e.value as Map)['into'] as String, at: DateTime.parse('${(e.value as Map)['at']}')),
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

  /// 1.3.5: merged account ids that never were in the file -> the id kept
  /// (see [_Plan.aliases]).
  final Map<String, ({String into, DateTime at})> aliases;

  /// The confirmed seed holds until the first sync completes.
  Map<String, dynamic> toJson() => {
        'base': base,
        'joined': joined,
        if (lastSyncAt != null) 'lastSyncAt': lastSyncAt!.toUtc().toIso8601String(),
        if (claims.isNotEmpty) 'claims': claims,
        if (seen.isNotEmpty) 'seen': {for (final e in seen.entries) e.key: e.value.toUtc().toIso8601String()},
        if (!joined && preferLocal) 'preferLocal': true,
        if (!joined && preferFile) 'preferFile': true,
        if (aliases.isNotEmpty) 'aliases': {for (final e in aliases.entries) e.key: {'into': e.value.into, 'at': e.value.at.toUtc().toIso8601String()}},
      };
}
