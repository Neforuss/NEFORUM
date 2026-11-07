import 'dart:async';

import '../adapters/adapter_context.dart';
import '../adapters/adapter_registry.dart';
import '../model/account.dart';
import '../model/publish_result.dart';
import '../model/sign_in_lifetime.dart';
import '../util/logger.dart';
import 'repositories.dart';
import 'secret_store.dart';

/// [SignInStatus] of every account on this device, in a file of its own: read
/// by closed cards, the scheduler and warnings with no keychain prompt.
///
/// Never synced and never exported. Each device derives its own from its own
/// keys, so it cannot conflict, and unreadable data counts as no entries: the
/// next write or start fills it again.
class SignInStatusStore {
  SignInStatusStore({required Future<Object?> Function() read, required Future<void> Function(Object data) write})
      : _read = read,
        _write = write;

  /// Kept in memory only (the demo workspace, tests).
  factory SignInStatusStore.inMemory() {
    Object? data;
    return SignInStatusStore(read: () async => data, write: (d) async => data = d);
  }

  final Future<Object?> Function() _read;
  final Future<void> Function(Object data) _write;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Future<void>? _tail;

  /// Fires after every stored change made by this process.
  Stream<void> get changes => _changes.stream;

  /// Every account's status, by account id.
  Future<Map<String, SignInStatus>> all() async {
    final Object? data;
    try {
      data = await _read();
    } on Object {
      return {};
    }
    final out = <String, SignInStatus>{};
    if (data is! Map) return out;
    for (final e in data.entries) {
      try {
        out[e.key as String] = SignInStatus.fromJson(e.key as String, Map<String, dynamic>.from(e.value as Map));
      } on Object {
        // A damaged entry is left out, and the next write replaces it.
      }
    }
    return out;
  }

  Future<SignInStatus?> get(String accountId) async => (await all())[accountId];

  /// Applies [change] to [accountId]'s status as stored now, one change at a
  /// time, and stores what it returns (null removes the entry).
  Future<SignInStatus?> change(String accountId, SignInStatus? Function(SignInStatus? current) change) {
    SignInStatus? out;
    return _serial((all) {
      out = change(all[accountId]);
      if (out == null) {
        return all.remove(accountId) != null;
      }
      if (identical(out, all[accountId])) return false;
      all[accountId] = out!;
      return true;
    }).then((_) => out);
  }

  Future<void> remove(String accountId) => _serial((all) => all.remove(accountId) != null);

  /// Forgets every account (Delete everything).
  Future<void> clear() => _serial((all) {
        if (all.isEmpty) return false;
        all.clear();
        return true;
      });

  Future<void> _serial(bool Function(Map<String, SignInStatus> all) step) {
    Future<void> apply() async {
      final current = await all();
      if (!step(current)) return;
      await _write({for (final e in current.entries) e.key: e.value.toJson()});
      if (!_changes.isClosed) _changes.add(null);
    }

    final previous = _tail;
    final next = previous == null ? apply() : previous.then((_) => apply());
    _tail = next.catchError((Object _) {});
    return next;
  }

  void dispose() => unawaited(_changes.close());
}

/// What the publish service reports about a sign-in. An interface so that core
/// never needs the tracker in tests that do not care.
abstract class SignInOutcomes {
  /// A post through [account] finished: [worked] when the network took it,
  /// [refused] when it refused the sign-in ("not allowed" is neither).
  Future<void> publishFinished(ConnectedAccount account, {required bool worked, required bool refused, required AdapterContext ctx});
}

/// Keeps [SignInStatusStore] up to date: on every write of an account's keys
/// (through [SignInStatusSecretStore]), at connect, after each publish, and on
/// request. Never fails what it watches: a status that cannot be written costs
/// a line in the log, never a sign-in or a post.
class SignInStatusTracker implements SignInOutcomes {
  SignInStatusTracker({
    required this.store,
    required this.accounts,
    required this.registry,
    required this.secrets,
    Clock? clock,
    Logger? log,
    this.serverReadEvery = const Duration(days: 1),
  })  : _now = clock ?? systemClock,
        _log = log ?? Logger('sign-in');

  final SignInStatusStore store;
  final AccountRepository accounts;
  final AdapterRegistry registry;

  /// Where a server read and [seedMissing] find the keys. Set by the app once
  /// the decorated store exists; the tracker itself never stores a key.
  SecretStore? secrets;
  final Duration serverReadEvery;
  final Clock _now;
  final Logger _log;

  /// Works out the status of the keys just stored for [accountId]. Entries
  /// that belong to no account (the sync password, media host keys) are left
  /// alone.
  Future<SignInStatus?> secretsWritten(String accountId, Map<String, String> secrets) async {
    final account = await accounts.get(accountId);
    return account == null ? null : _record(account, secrets);
  }

  Future<void> secretsDeleted(String accountId) => store.remove(accountId);

  /// A new sign-in for [account], just stored as [secrets]: what the old one
  /// reported no longer applies. Reads the server's own date when it has one.
  Future<SignInStatus?> accountConnected(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    await store.remove(account.id);
    await _record(account, secrets);
    return readFromServer(account, ctx, secrets: secrets, force: true);
  }

  @override
  Future<void> publishFinished(ConnectedAccount account, {required bool worked, required bool refused, required AdapterContext ctx}) async {
    if (!worked && !refused) return;
    final now = _now();
    await store.change(account.id, (current) {
      final base = current ?? _empty(account, now);
      return worked ? base.copyWith(lastConfirmedAt: now, clearLastAuthFailure: true) : base.copyWith(lastAuthFailure: now);
    });
    await readFromServer(account, ctx);
  }

  /// Asks the platform itself ([PlatformAdapter.readSignIn]), at most once per
  /// [serverReadEvery] per account unless [force]. [secrets] saves a keychain
  /// read when they are at hand. Answers with the status as it then stands.
  Future<SignInStatus?> readFromServer(ConnectedAccount account, AdapterContext ctx, {Map<String, String>? secrets, bool force = false}) async {
    final now = _now();
    bool due(SignInStatus? s) {
      final last = s?.serverReadAt;
      return force || last == null || now.difference(last) >= serverReadEvery;
    }

    // Checked first with no keychain read: most posts come here on a day that
    // already had its read.
    final current = await store.get(account.id);
    if (!due(current)) return current;
    final adapter = registry.byId(account.platformId);
    if (adapter == null || !adapter.signInPolicyFor(account).hasConnection) return current;
    final keys = secrets ?? await this.secrets?.read(account.id);
    if (keys == null || keys.isEmpty) return current;
    // Checked again and stamped in one serial step: of two posts that finish
    // together, one asks the server and the other leaves it at that.
    var mine = false;
    final latest = await store.change(account.id, (s) {
      mine = due(s);
      return mine ? (s ?? _empty(account, now)).copyWith(serverReadAt: now) : s;
    });
    if (!mine) return latest;
    SignInServerRead? read;
    try {
      read = await adapter.readSignIn(account, keys, ctx);
    } on Object catch (e) {
      // The type only: an HTTP error's text can quote an address with a token.
      _log.debug('Could not read the ${account.platformId} sign-in from the server (${e.runtimeType})');
    }
    return _record(account, keys, read: read, readAt: now);
  }

  /// Fills in accounts with no status yet: every account on the first start
  /// after an update, and accounts a sync brought before their keys. Stops at
  /// the first keychain that does not answer in [timeout], so a stuck keychain
  /// costs one wait, and tries again next start.
  Future<void> seedMissing({Duration timeout = const Duration(seconds: 15)}) async {
    final keychain = secrets;
    if (keychain == null) return;
    final known = await store.all();
    for (final account in await accounts.all()) {
      if (known.containsKey(account.id)) continue;
      final adapter = registry.byId(account.platformId);
      if (adapter == null || !adapter.signInPolicyFor(account).hasConnection) continue;
      try {
        await _record(account, await keychain.read(account.id).timeout(timeout) ?? const {});
      } on TimeoutException {
        _log.warn('The keychain did not answer; sign-in dates are filled in next time');
        return;
      } on Object catch (e) {
        _log.warn('Could not read the keys of ${account.id} for their sign-in date (${e.runtimeType})');
      }
    }
  }

  SignInStatus _empty(ConnectedAccount account, DateTime now) {
    final policy = registry.byId(account.platformId)?.signInPolicyFor(account) ?? SignInPolicy.noConnection;
    return SignInStatus.fromLifetime(account.id, deriveSignInLifetime(policy, const {}, now: now), hasConnection: policy.hasConnection);
  }

  Future<SignInStatus?> _record(ConnectedAccount account, Map<String, String> secrets, {SignInServerRead? read, DateTime? readAt}) async {
    final adapter = registry.byId(account.platformId);
    if (adapter == null) return null;
    final policy = adapter.signInPolicyFor(account);
    final now = _now();
    final renewed = DateTime.tryParse(secrets[SignInSecretKeys.lastRenewedAt] ?? '');
    SignInStatus? before;
    final after = await store.change(account.id, (current) {
      before = current;
      final serverRead = read ?? current?.serverRead;
      final life = deriveSignInLifetime(policy, secrets, now: now, serverRead: serverRead);
      final newSignIn = renewed != null && renewed != current?.lastRenewedAt;
      final saysInvalid = read != null && !read.isValid;
      return SignInStatus.fromLifetime(
        account.id,
        life,
        hasConnection: policy.hasConnection,
        lastConfirmedAt: current?.lastConfirmedAt,
        lastAuthFailure: saysInvalid ? now : (newSignIn ? null : current?.lastAuthFailure),
        lastRenewedAt: renewed,
        serverRead: serverRead,
        serverReadAt: readAt ?? current?.serverReadAt,
      );
    });
    if (after != null && (before?.expiresAt != after.expiresAt || before?.source != after.source)) {
      // The trace: dates and source names only.
      final end = after.expiresAt;
      _log.info(end == null ? 'sign-in ${account.id} has no date (${after.limit.name})' : 'sign-in ${account.id} ends ${end.toUtc().toIso8601String()} (${after.source.name})');
    }
    return after;
  }
}

/// [SecretStore] that keeps the [SignInStatusTracker] up to date on every write
/// and delete, whoever makes it: a renewal, a connect, a sync, a restored
/// backup. Everything else passes straight through to the store it wraps.
class SignInStatusSecretStore extends SecretStore {
  SignInStatusSecretStore(this._inner, this._tracker, {Logger? log}) : _log = log ?? Logger('sign-in');

  final SecretStore _inner;
  final SignInStatusTracker _tracker;
  final Logger _log;

  @override
  Future<Map<String, String>?> read(String accountId) => _inner.read(accountId);

  @override
  Future<void> write(String accountId, Map<String, String> secrets) async {
    await _inner.write(accountId, secrets);
    try {
      await _tracker.secretsWritten(accountId, secrets);
    } on Object catch (e) {
      _log.warn('Could not note the sign-in date of $accountId (${e.runtimeType})');
    }
  }

  @override
  Future<void> delete(String accountId) async {
    await _inner.delete(accountId);
    try {
      await _tracker.secretsDeleted(accountId);
    } on Object catch (e) {
      _log.warn('Could not remove the sign-in date of $accountId (${e.runtimeType})');
    }
  }
}

/// Whether a failed [error] means the network refused the sign-in itself:
/// `auth`, and not the "not allowed" kind a reconnect would not fix.
bool refusesSignIn(PublishError? error) => error != null && error.kind == PublishErrorKind.auth && error.notAllowed != true;
