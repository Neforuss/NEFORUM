import 'package:meta/meta.dart';

import '../adapters/adapter_context.dart';
import '../adapters/adapter_registry.dart';
import '../adapters/connect_spec.dart';
import '../adapters/platform_adapter.dart';
import '../auth/auth_broker.dart';
import '../auth/oauth2_pkce.dart';
import '../http/neforum_http.dart';
import '../model/account.dart';
import '../model/platform_descriptor.dart';
import '../storage/repositories.dart';
import '../storage/secret_store.dart';
import '../storage/sign_in_status_store.dart';
import '../util/logger.dart';
import 'publish_service.dart';

// 1.4.3: automatic reconnect.
//
// Why an account ends up "needs reconnecting" (an account warning, a refused
// sign-in in the status file), as found in 1.4.2, and what each cause gets now:
//
// 1. The access token ended and was renewed, but the renewal failed for a
//    passing reason (no network, the token endpoint down, an answer that could
//    not be read). Before, a few of those counted as a refusal: any 4xx but
//    429, and an unreadable answer. Now only the platform refusing the keys
//    does; everything else is retried a few seconds later in the same attempt
//    and then with the post's own backoff, and never shows as disconnected
//    (PublishService._freshSecrets).
// 2. The network refused a token NEFORUM thought was still good: it ended
//    early, or the platform dropped the session. Nothing renewed it, because
//    its stored date had not passed. Now one forced renewal with the stored
//    keys (a refresh token, Bluesky's app password) and one more try come
//    first (PublishService._publishTargetOnce).
// 3. The keys themselves no longer work: a refresh token revoked or run out at
//    the platform (Meta's 60 days, a password change, the person removing the
//    app). That needs the person's consent in a browser, and cannot be silent.
//    It is said once, and Reconnect is one tap: [AccountReconnector] signs in
//    again with the developer app keys and settings already saved, so nothing
//    is typed. NEFORUM never stores or replays a password for an OAuth
//    platform.
// 4. Pasted keys and bot tokens that were revoked (a Telegram bot token, X's
//    OAuth 1.0a keys, a pasted Threads token): only new keys fix those, so
//    Reconnect opens the connect form.

/// What [AccountReconnector.reconnect] came to.
enum ReconnectResult {
  /// The saved keys renewed the sign-in by themselves: no browser was needed.
  renewed,

  /// Signed in again through the browser with the saved app keys.
  reconnected,

  /// Only the person can give what is missing (new keys, a token, a secret
  /// NEFORUM does not keep): the connect form is the way.
  needsForm,

  /// The browser sign-in was for another account. Nothing was changed.
  otherAccount,

  /// The person closed or declined the browser sign-in.
  cancelled,

  /// The platform could not be reached. Nothing was changed; try later.
  unreachable,

  /// The sign-in did not finish; [ReconnectOutcome.message] says why.
  failed,
}

@immutable
class ReconnectOutcome {
  const ReconnectOutcome(this.result, {this.message, this.account});

  final ReconnectResult result;

  /// What to tell the person, in plain words, where there is more to say than
  /// [result]. Never a key or a token.
  final String? message;

  /// The account as stored after [ReconnectResult.renewed] or
  /// [ReconnectResult.reconnected].
  final ConnectedAccount? account;

  bool get worked => result == ReconnectResult.renewed || result == ReconnectResult.reconnected;
}

/// One-tap Reconnect for an account whose sign-in was refused or ended: first
/// the stored keys alone ([renew], the same path a post takes), then the
/// platform's browser sign-in with the keys and settings the first sign-in
/// saved ([PlatformAdapter.reconnectInput]). Stores the result as the same
/// account, so its posts, options and switches stay as they are.
class AccountReconnector {
  AccountReconnector({
    required this.registry,
    required this.accounts,
    required this.secrets,
    required this.renew,
    this.connected,
    Clock? clock,
    Logger? log,
  })  : _now = clock ?? systemClock,
        _log = log ?? Logger('reconnect');

  final AdapterRegistry registry;
  final AccountRepository accounts;
  final SecretStore secrets;

  /// [PublishService.renewSignIn]: renews with the stored keys, through the
  /// sync coordinator on platforms whose keys rotate.
  final Future<SignInRenewalOutcome> Function(String accountId) renew;

  /// Told about a new sign-in once it is stored
  /// ([SignInStatusTracker.accountConnected]). A failure here costs a log line.
  final Future<void> Function(ConnectedAccount account, Map<String, String> secrets)? connected;
  final Clock _now;
  final Logger _log;

  /// Reconnects [accountId]. [ctx] carries the browser broker for the sign-in.
  /// Never throws: every way it can end is a [ReconnectOutcome].
  Future<ReconnectOutcome> reconnect(String accountId, AdapterContext ctx) async {
    final account = await accounts.get(accountId);
    final adapter = account == null ? null : registry.byId(account.platformId);
    if (account == null || adapter == null) return const ReconnectOutcome(ReconnectResult.failed, message: 'This account is no longer in NEFORUM.');
    if (account.tier == PlatformTier.handoff) return const ReconnectOutcome(ReconnectResult.needsForm);
    final name = adapter.descriptor.name;

    final Map<String, String> keys;
    try {
      keys = await secrets.read(accountId) ?? const {};
    } on Object catch (e) {
      _log.warn('Could not read the keys of $accountId to reconnect it (${e.runtimeType})');
      return const ReconnectOutcome(ReconnectResult.failed, message: "Could not read this account's keys on this device. Unlock the keychain and try again.");
    }

    // 1. The stored keys alone: a refresh token, an app password.
    if (keys.isNotEmpty) {
      final SignInRenewalOutcome renewal;
      try {
        renewal = await renew(accountId);
      } on Object catch (e) {
        _log.warn('Renewing $accountId before a reconnect failed (${e.runtimeType})');
        return ReconnectOutcome(ReconnectResult.failed, message: 'Could not renew the $name sign-in.');
      }
      if (renewal.renewed) {
        final stored = await _clearWarning(accountId);
        _log.info('reconnected $accountId with its stored keys');
        return ReconnectOutcome(ReconnectResult.renewed, account: stored ?? account);
      }
      final error = renewal.error;
      if (error != null && error.retryable && !refusesSignIn(error)) {
        return ReconnectOutcome(ReconnectResult.unreachable, message: 'Could not reach $name right now. Nothing was changed. Try again in a moment.');
      }
    }

    // 2. The browser, with what the first sign-in saved.
    final broker = ctx.broker;
    ConnectSpec? spec;
    for (final s in adapter.connectSpecs) {
      if (s.tier == account.tier) {
        spec = s;
        break;
      }
    }
    if (broker == null || spec == null || !spec.usesBrowser) return const ReconnectOutcome(ReconnectResult.needsForm);
    final redirect = broker.chooseRedirectUri(loopbackOk: spec.loopbackRedirectOk, customSchemeOk: spec.customSchemeRedirectOk, fixed: spec.fixedRedirectUri);
    final input = adapter.reconnectInput(account, keys, redirect: redirect);
    if (input == null) return const ReconnectOutcome(ReconnectResult.needsForm);

    final ConnectResult result;
    try {
      result = await adapter.connect(account.tier, input, ctx);
    } on AuthCancelled {
      return const ReconnectOutcome(ReconnectResult.cancelled);
    } on ConnectException catch (e) {
      // Usually something the form has to change (an app secret that was
      // rotated): the form opens with the reason.
      return ReconnectOutcome(ReconnectResult.needsForm, message: e.message);
    } on OAuthException catch (e) {
      return ReconnectOutcome(ReconnectResult.failed, message: 'The $name sign-in failed: ${e.description ?? e.error ?? e.message}');
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) {
        return ReconnectOutcome(ReconnectResult.unreachable, message: 'Could not reach $name right now. Nothing was changed. Try again in a moment.');
      }
      // The type only: an HTTP error's text can quote an address with a token.
      _log.warn('The $name sign-in for $accountId did not finish (${e.runtimeType})');
      return ReconnectOutcome(ReconnectResult.failed, message: 'The $name sign-in did not finish (${e.runtimeType}).');
    }

    final fresh = result.account;
    if (!_sameAccount(account, fresh)) {
      // Signed in as someone else: those keys are dropped, and revoked where
      // the platform allows it, so nothing holds a sign-in nobody asked for.
      try {
        await adapter.disconnect(fresh, result.secrets, ctx);
      } on Object catch (e) {
        _log.debug('Could not revoke the sign-in for the other account (${e.runtimeType})');
      }
      final who = fresh.handle ?? fresh.displayName;
      final wanted = account.handle ?? account.displayName;
      return ReconnectOutcome(ReconnectResult.otherAccount, message: 'You signed in to $name as $who. Sign in as $wanted to reconnect this account. Nothing was changed.');
    }

    final stamped = stampNewSignIn(result.secrets, now: _now());
    final updated = account.copyWith(
      displayName: fresh.displayName,
      handle: fresh.handle,
      avatarUrl: fresh.avatarUrl,
      profileUrl: fresh.profileUrl,
      config: {...account.config, ...fresh.config},
      clearLastError: true,
    );
    await secrets.write(accountId, stamped);
    await accounts.upsert(updated);
    final tell = connected;
    if (tell != null) {
      try {
        await tell(updated, stamped);
      } on Object catch (e) {
        _log.warn('Could not note the new sign-in of $accountId (${e.runtimeType})');
      }
    }
    _log.info('reconnected $accountId through the browser with its saved app keys');
    return ReconnectOutcome(ReconnectResult.reconnected, account: updated);
  }

  /// Clears the account's "needs reconnecting" warning, on the account as
  /// stored now.
  Future<ConnectedAccount?> _clearWarning(String accountId) async {
    final stored = await accounts.get(accountId);
    if (stored == null || stored.lastError == null) return stored;
    final cleared = stored.copyWith(clearLastError: true);
    await accounts.upsert(cleared);
    return cleared;
  }

  /// [fresh] is the account [account] was: the same id, or the same handle.
  /// Platforms that give each connect a new id and no handle cannot tell, and
  /// the browser sign-in the person just made decides.
  static bool _sameAccount(ConnectedAccount account, ConnectedAccount fresh) {
    if (fresh.id == account.id) return true;
    final a = account.handle?.trim().toLowerCase() ?? '', b = fresh.handle?.trim().toLowerCase() ?? '';
    if (a.isEmpty || b.isEmpty) return a.isEmpty && b.isEmpty;
    return a == b;
  }
}
