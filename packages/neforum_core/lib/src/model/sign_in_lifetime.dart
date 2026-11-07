import 'package:meta/meta.dart';

import '../auth/oauth2_pkce.dart';

/// How long before a sign-in ends NEFORUM starts warning about it.
const Duration kSignInEndWarning = Duration(days: 14);

/// Entries in an account's secrets map that describe its sign-in. They hold
/// dates and source names, never a secret, and travel in the same sync record
/// as the keys they describe, so a date can never come from another sign-in.
///
/// Never in `account.config`: that is what `sharesRegistration` hashes, and a
/// renewal must not make two copies of an account look like two registrations.
abstract final class SignInSecretKeys {
  /// Where `expires_at` came from ([SignInDateSource.name]).
  static const String expiresAtSource = 'expires_at_source';

  /// Where `refresh_expires_at` came from ([SignInDateSource.name]).
  static const String refreshExpiresSource = 'refresh_expires_source';

  /// The last time this sign-in was made or renewed.
  static const String lastRenewedAt = 'last_renewed_at';

  /// The end of the refresh token (the name every adapter writes).
  static const String refreshExpiresAt = 'refresh_expires_at';

  /// Threads' renewal stamp.
  static const String tokenIssuedAt = 'token_issued_at';

  /// Instagram's renewal stamp.
  static const String refreshedAt = 'refreshed_at';

  /// Bluesky's app password, which signs in again when its session ends.
  static const String appPassword = 'app_password';
}

/// Where a date came from.
enum SignInDateSource {
  /// The platform said it: `expires_in`, `expires_in_ms`, a JWT `exp`, a debug
  /// or introspection endpoint.
  serverReported,

  /// NEFORUM worked it out from a documented rule. Shown as "about".
  computed,

  /// No date, or a stored date with no recorded origin (anything stored before
  /// NEFORUM 1.4). The date still shows; the next renewal records its origin.
  unknown;

  /// [name] as stored, or [unknown] for anything else: a newer version's value
  /// reaches an older device through sync without breaking it.
  static SignInDateSource parse(String? name) => switch (name) {
        'serverReported' => serverReported,
        'computed' => computed,
        _ => unknown,
      };
}

/// Why a sign-in has, or has no, date.
enum SignInLimit {
  /// The vendor documents no time limit. Only revocation ends it.
  none,

  /// A date applies.
  date,

  /// It ends after idle time, on no date anyone can know (Inkbunny).
  idleUnknown,

  /// The vendor's documentation is silent, or it depends on the server.
  undocumented;

  static SignInLimit parse(String? name) => switch (name) {
        'none' => none,
        'date' => date,
        'idleUnknown' => idleUnknown,
        _ => undocumented,
      };
}

/// What can extend a sign-in without the person.
enum SignInRenewal {
  /// There is no limit to extend.
  notNeeded,

  /// A token is renewed when NEFORUM posts. NEFORUM has no background renewal.
  onUse,

  /// A stored credential signs in again (Bluesky's app password).
  credential,

  /// Nothing stored can extend it.
  never,
}

/// Where the stored sign-in stands.
enum SignInState {
  /// Renews when NEFORUM posts and no end date is known.
  renews,

  /// Renews when NEFORUM posts, until [SignInLifetime.expiresAt].
  renewsUntil,

  /// The token renews itself when NEFORUM posts with it (Threads, Instagram);
  /// left unused, it ends at [SignInLifetime.expiresAt].
  renewsWhenUsed,

  /// Nothing stored can renew it: it ends at [SignInLifetime.expiresAt].
  endsOn,

  /// It ended at [SignInLifetime.expiresAt].
  ended,

  /// No date is known. [SignInLifetime.limit] says why.
  noDate,
}

/// The documented facts about one way of connecting to one platform. Declared
/// by every adapter ([PlatformAdapter.signInPolicyFor]), cited, and checked
/// against `docs/sign-in-lifetimes.md` by a test.
@immutable
class SignInPolicy {
  const SignInPolicy({
    required this.limit,
    required this.renewal,
    this.sourceUrl,
    this.disuseWindow,
    this.hardDeadline,
    this.earlyRevocationPossible = false,
    this.unverified = false,
    this.tokenRenewsItself = false,
    this.note,
    this.hasConnection = true,
  });

  /// No connection at all: hand-off, or Odysee's Auto through the LBRY app.
  static const SignInPolicy noConnection = SignInPolicy(limit: SignInLimit.none, renewal: SignInRenewal.notNeeded, hasConnection: false);

  final SignInLimit limit;
  final SignInRenewal renewal;

  /// The vendor page or source file the facts were read from.
  final String? sourceUrl;

  /// With no renewal for this long the sign-in ends. Gives
  /// `expiresAt = last_renewed_at + disuseWindow`, shown as "about".
  final Duration? disuseWindow;

  /// A date the vendor has announced for the end of this way of signing in.
  final DateTime? hardDeadline;

  /// Something other than the date can end it first (the person revoking the
  /// app, a password change, the vendor). A date then reads "at the latest".
  final bool earlyRevocationPossible;

  /// No vendor page read settles the lifetime. `docs/sign-in-lifetimes.md`
  /// says what would.
  final bool unverified;

  /// No refresh token: the access token itself renews when NEFORUM posts with
  /// it (Threads, Instagram).
  final bool tokenRenewsItself;

  /// One more sentence the sign-in row needs, in plain words.
  final String? note;

  /// False for [noConnection]: there is nothing that can end, and no row.
  final bool hasConnection;
}

/// What a platform itself said about a sign-in, on request. See
/// `PlatformAdapter.readSignIn`.
@immutable
class SignInServerRead {
  const SignInServerRead({required this.readAt, this.expiresAt, this.dataAccessExpiresAt, this.accessExpiresAt, this.isValid = true});

  factory SignInServerRead.fromJson(Map<String, dynamic> j) => SignInServerRead(
        readAt: DateTime.parse(j['readAt'] as String),
        expiresAt: _date(j['expiresAt']),
        dataAccessExpiresAt: _date(j['dataAccessExpiresAt']),
        accessExpiresAt: _date(j['accessExpiresAt']),
        isValid: j['isValid'] as bool? ?? true,
      );

  final DateTime readAt;

  /// When the sign-in ends, by the platform's own answer.
  final DateTime? expiresAt;

  /// Meta's `data_access_expires_at`: when the token stops reaching data.
  final DateTime? dataAccessExpiresAt;

  /// When the short-lived token ends (a JWT `exp`). Says nothing about when
  /// the person must act.
  final DateTime? accessExpiresAt;

  /// False when the platform says the token no longer works.
  final bool isValid;

  /// The earliest moment the platform names for the sign-in to stop working.
  DateTime? get earliestEnd {
    final a = expiresAt, b = dataAccessExpiresAt;
    if (a == null) return b;
    if (b == null) return a;
    return a.isBefore(b) ? a : b;
  }

  Map<String, dynamic> toJson() => {
        'readAt': readAt.toUtc().toIso8601String(),
        if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
        if (dataAccessExpiresAt != null) 'dataAccessExpiresAt': dataAccessExpiresAt!.toUtc().toIso8601String(),
        if (accessExpiresAt != null) 'accessExpiresAt': accessExpiresAt!.toUtc().toIso8601String(),
        if (!isValid) 'isValid': false,
      };
}

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// The answer for one stored sign-in.
@immutable
class SignInLifetime {
  const SignInLifetime({
    required this.state,
    required this.limit,
    required this.source,
    required this.renewsItself,
    this.expiresAt,
    this.accessExpiresAt,
    this.about = false,
    this.endsSoon = false,
    this.earlyRevocationPossible = false,
    this.unverified = false,
    this.isHardDeadline = false,
    this.disuseWindow,
    this.note,
    this.usesCredential = false,
  });

  final SignInState state;

  /// The moment the person must act if nothing else happens. Null: no date.
  final DateTime? expiresAt;
  final SignInDateSource source;
  final SignInLimit limit;

  /// NEFORUM can extend it with nothing from the person, when a post goes out.
  final bool renewsItself;

  /// Kept apart from [expiresAt]: it changes hourly and says nothing about
  /// when the person must act.
  final DateTime? accessExpiresAt;

  /// [expiresAt] is an estimate from a documented rule.
  final bool about;

  /// [expiresAt] is less than [kSignInEndWarning] away and has not passed.
  final bool endsSoon;

  /// A date reads "at the latest".
  final bool earlyRevocationPossible;
  final bool unverified;

  /// [expiresAt] is a date the vendor announced for this way of signing in.
  final bool isHardDeadline;

  /// The policy's window, for a sign-in with no date yet.
  final Duration? disuseWindow;
  final String? note;

  /// It signs in again with a stored credential (Bluesky's app password).
  final bool usesCredential;

  bool get needsReconnecting => state == SignInState.ended;

  /// The old `signInExpiry` name for [expiresAt].
  DateTime? get endsAt => expiresAt;
}

/// When the sign-in in [secrets] really ends and whether NEFORUM renews it
/// first. A pure function of the policy, the stored keys' names and dates, and
/// what the server last said. Reads the presence of tokens, never their value.
///
/// Stored dates with no recorded origin (1.3.5 and earlier) read as
/// [SignInDateSource.unknown] and still show.
SignInLifetime deriveSignInLifetime(SignInPolicy policy, Map<String, String> secrets, {required DateTime now, SignInServerRead? serverRead}) {
  bool has(String k) => (secrets[k] ?? '').isNotEmpty;
  DateTime? at(String k) => DateTime.tryParse(secrets[k] ?? '');

  final access = at(OAuthTokens.keyExpiresAt);
  final refreshEnds = at(SignInSecretKeys.refreshExpiresAt);
  final refresh = has(OAuthTokens.keyRefreshToken);
  final lastRenewed = at(SignInSecretKeys.lastRenewedAt);
  final accessSource = SignInDateSource.parse(secrets[SignInSecretKeys.expiresAtSource]);
  final refreshSource = SignInDateSource.parse(secrets[SignInSecretKeys.refreshExpiresSource]);

  SignInLifetime make(
    SignInState state, {
    DateTime? end,
    SignInDateSource source = SignInDateSource.unknown,
    bool renewsItself = false,
    bool about = false,
    bool deadline = false,
    bool credential = false,
  }) =>
      SignInLifetime(
        state: state,
        expiresAt: end,
        source: source,
        limit: policy.limit,
        renewsItself: renewsItself,
        accessExpiresAt: access,
        about: about,
        endsSoon: end != null && now.isBefore(end) && end.difference(now) < kSignInEndWarning,
        earlyRevocationPossible: end != null && policy.earlyRevocationPossible,
        unverified: policy.unverified,
        isHardDeadline: deadline,
        disuseWindow: policy.disuseWindow,
        note: policy.note,
        usesCredential: credential,
      );

  /// `last renewal + window`, never before the access token itself ends. With
  /// no stamp (stored by 1.3.5) the access token's end stands in: it is at most
  /// one access lifetime after the real renewal, and its origin stays unknown.
  SignInLifetime? fromDisuse({required bool renewsItself}) {
    final window = policy.disuseWindow;
    final anchor = lastRenewed ?? at(SignInSecretKeys.refreshedAt) ?? at(SignInSecretKeys.tokenIssuedAt) ?? access;
    if (window == null || anchor == null) return null;
    var end = anchor.add(window);
    if (access != null && access.isAfter(end)) end = access;
    final source = lastRenewed != null ? SignInDateSource.computed : SignInDateSource.unknown;
    if (!now.isBefore(end)) return make(SignInState.ended, end: end, source: source, renewsItself: renewsItself, about: true);
    return make(policy.tokenRenewsItself ? SignInState.renewsWhenUsed : SignInState.renewsUntil, end: end, source: source, renewsItself: renewsItself, about: true);
  }

  SignInLifetime base() {
    if (!policy.hasConnection) return make(SignInState.noDate);
    // Bluesky signs in again with its app password whenever its session ends.
    if (has(SignInSecretKeys.appPassword) && has(OAuthTokens.keyAccessToken)) return make(SignInState.renews, renewsItself: true, credential: true);
    if (refresh && (refreshEnds == null || now.isBefore(refreshEnds))) {
      if (refreshEnds != null) return make(SignInState.renewsUntil, end: refreshEnds, source: refreshSource, renewsItself: true, about: refreshSource == SignInDateSource.computed);
      return fromDisuse(renewsItself: true) ?? make(SignInState.renews, renewsItself: true);
    }
    // Nothing can renew it (no refresh token, or one that ran out itself): the
    // sign-in ends with the last token that still works.
    DateTime? end = access;
    var source = accessSource;
    if (refresh && refreshEnds != null && (end == null || refreshEnds.isAfter(end))) {
      end = refreshEnds;
      source = refreshSource;
    }
    final selfRenewing = policy.tokenRenewsItself || has(SignInSecretKeys.tokenIssuedAt) || has(SignInSecretKeys.refreshedAt);
    if (end == null) return (selfRenewing ? fromDisuse(renewsItself: true) : null) ?? make(SignInState.noDate, renewsItself: selfRenewing);
    if (!now.isBefore(end)) return make(SignInState.ended, end: end, source: source, about: source == SignInDateSource.computed);
    return make(selfRenewing ? SignInState.renewsWhenUsed : SignInState.endsOn, end: end, source: source, renewsItself: selfRenewing, about: source == SignInDateSource.computed);
  }

  var out = base();
  if (!policy.hasConnection) return out;

  // A date the platform itself just gave beats anything stored, and beats a
  // policy of "no limit": a server that starts ending tokens needs no NEFORUM
  // change. A read from before the last renewal described the previous token.
  final read = serverRead;
  final said = read != null && (lastRenewed == null || !read.readAt.isBefore(lastRenewed)) ? read.earliestEnd : null;
  if (said != null) {
    final state = !now.isBefore(said) ? SignInState.ended : (policy.tokenRenewsItself ? SignInState.renewsWhenUsed : (out.renewsItself ? SignInState.renewsUntil : SignInState.endsOn));
    out = make(state, end: said, source: SignInDateSource.serverReported, renewsItself: out.renewsItself, credential: out.usesCredential);
  }

  // An announced end of this way of signing in comes first, whatever else is
  // stored: nothing renews past it.
  final deadline = policy.hardDeadline;
  if (deadline != null && (out.expiresAt == null || deadline.isBefore(out.expiresAt!))) {
    out = make(now.isBefore(deadline) ? SignInState.endsOn : SignInState.ended, end: deadline, source: SignInDateSource.computed, deadline: true);
  }
  return out;
}

/// A new sign-in as it should be stored: [secrets] with the moment it was made
/// and where its dates came from. Empty [secrets] stay empty (hand-off and the
/// LBRY app store nothing).
Map<String, String> stampNewSignIn(Map<String, String> secrets, {required DateTime now}) =>
    secrets.isEmpty ? secrets : stampSignInRenewal(const {}, secrets, now: now);

/// [after], a renewal of [before], with the moment it happened and where its
/// new dates came from. An adapter that works a date out itself says so by
/// writing [SignInDateSource.computed]; any other date that changed came from
/// the server. A date that did not change keeps its source, so a date stored
/// by 1.3.5 stays [SignInDateSource.unknown] until it really is renewed.
Map<String, String> stampSignInRenewal(Map<String, String> before, Map<String, String> after, {required DateTime now}) {
  final out = {...after};
  void source(String dateKey, String sourceKey) {
    final date = out[dateKey];
    if (date == null || date.isEmpty) {
      out.remove(sourceKey);
    } else if (date != before[dateKey] && !out.containsKey(sourceKey)) {
      out[sourceKey] = SignInDateSource.serverReported.name;
    }
  }

  source(OAuthTokens.keyExpiresAt, SignInSecretKeys.expiresAtSource);
  source(SignInSecretKeys.refreshExpiresAt, SignInSecretKeys.refreshExpiresSource);
  out[SignInSecretKeys.lastRenewedAt] = now.toUtc().toIso8601String();
  return out;
}

/// One account's sign-in as this device last worked it out: readable with no
/// keychain prompt, by closed cards, the scheduler and warnings. Holds dates,
/// names and flags only: its [toJson] is the whole of what reaches the file,
/// and nothing in it can carry a key.
///
/// Per device and never synced: [lastConfirmedAt] changes on every post, so in
/// the synced secrets record it would turn every post into a sync write.
@immutable
class SignInStatus {
  const SignInStatus({
    required this.accountId,
    required this.limit,
    required this.source,
    required this.renewsItself,
    required this.state,
    this.expiresAt,
    this.lastConfirmedAt,
    this.lastAuthFailure,
    this.lastRenewedAt,
    this.about = false,
    this.earlyRevocationPossible = false,
    this.unverified = false,
    this.isHardDeadline = false,
    this.usesCredential = false,
    this.hasConnection = true,
    this.serverRead,
    this.serverReadAt,
    this.note,
  });

  /// [life] as stored for [accountId].
  factory SignInStatus.fromLifetime(
    String accountId,
    SignInLifetime life, {
    required bool hasConnection,
    DateTime? lastConfirmedAt,
    DateTime? lastAuthFailure,
    DateTime? lastRenewedAt,
    SignInServerRead? serverRead,
    DateTime? serverReadAt,
  }) =>
      SignInStatus(
        accountId: accountId,
        limit: life.limit,
        source: life.source,
        renewsItself: life.renewsItself,
        state: life.state,
        expiresAt: life.expiresAt,
        lastConfirmedAt: lastConfirmedAt,
        lastAuthFailure: lastAuthFailure,
        lastRenewedAt: lastRenewedAt,
        about: life.about,
        earlyRevocationPossible: life.earlyRevocationPossible,
        unverified: life.unverified,
        isHardDeadline: life.isHardDeadline,
        usesCredential: life.usesCredential,
        hasConnection: hasConnection,
        serverRead: serverRead,
        serverReadAt: serverReadAt,
        note: life.note,
      );

  factory SignInStatus.fromJson(String accountId, Map<String, dynamic> j) => SignInStatus(
        accountId: accountId,
        limit: SignInLimit.parse(j['limit'] as String?),
        source: SignInDateSource.parse(j['source'] as String?),
        renewsItself: j['renewsItself'] as bool? ?? false,
        state: SignInState.values.asNameMap()[j['state']] ?? SignInState.noDate,
        expiresAt: _date(j['expiresAt']),
        lastConfirmedAt: _date(j['lastConfirmedAt']),
        lastAuthFailure: _date(j['lastAuthFailure']),
        lastRenewedAt: _date(j['lastRenewedAt']),
        about: j['about'] as bool? ?? false,
        earlyRevocationPossible: j['earlyRevocationPossible'] as bool? ?? false,
        unverified: j['unverified'] as bool? ?? false,
        isHardDeadline: j['isHardDeadline'] as bool? ?? false,
        usesCredential: j['usesCredential'] as bool? ?? false,
        hasConnection: j['hasConnection'] as bool? ?? true,
        serverRead: j['serverRead'] is Map ? SignInServerRead.fromJson(Map<String, dynamic>.from(j['serverRead'] as Map)) : null,
        serverReadAt: _date(j['serverReadAt']),
        note: j['note'] as String?,
      );

  final String accountId;
  final DateTime? expiresAt;
  final SignInDateSource source;
  final SignInLimit limit;
  final bool renewsItself;
  final SignInState state;

  /// The last time a post through this sign-in worked on this device.
  final DateTime? lastConfirmedAt;

  /// The last time the network refused this sign-in on this device, or said it
  /// no longer works. Cleared by a later success or a reconnect.
  final DateTime? lastAuthFailure;
  final DateTime? lastRenewedAt;
  final bool about;
  final bool earlyRevocationPossible;
  final bool unverified;
  final bool isHardDeadline;
  final bool usesCredential;
  final bool hasConnection;

  /// The last answer from the platform itself, kept so the once-a-day limit
  /// and the date survive a restart.
  final SignInServerRead? serverRead;

  /// The last time NEFORUM asked, whatever the answer: the once-a-day limit.
  final DateTime? serverReadAt;

  /// The policy's sentence, by way of [SignInPolicy.note]. Written in code,
  /// never from a server's answer.
  final String? note;

  /// [expiresAt] has passed at [now]. [state] is as of the last write, and a
  /// date passes with no write, so ask this rather than [state].
  bool hasEnded(DateTime now) => expiresAt != null && !now.isBefore(expiresAt!);

  /// [expiresAt] is less than [kSignInEndWarning] from [now] and has not passed.
  bool endsSoon(DateTime now) => expiresAt != null && now.isBefore(expiresAt!) && expiresAt!.difference(now) < kSignInEndWarning;

  SignInStatus copyWith({DateTime? lastConfirmedAt, DateTime? lastAuthFailure, bool clearLastAuthFailure = false}) => SignInStatus(
        accountId: accountId,
        limit: limit,
        source: source,
        renewsItself: renewsItself,
        state: state,
        expiresAt: expiresAt,
        lastConfirmedAt: lastConfirmedAt ?? this.lastConfirmedAt,
        lastAuthFailure: clearLastAuthFailure ? null : (lastAuthFailure ?? this.lastAuthFailure),
        lastRenewedAt: lastRenewedAt,
        about: about,
        earlyRevocationPossible: earlyRevocationPossible,
        unverified: unverified,
        isHardDeadline: isHardDeadline,
        usesCredential: usesCredential,
        hasConnection: hasConnection,
        serverRead: serverRead,
        serverReadAt: serverReadAt,
        note: note,
      );

  Map<String, dynamic> toJson() => {
        'limit': limit.name,
        'source': source.name,
        'renewsItself': renewsItself,
        'state': state.name,
        if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
        if (lastConfirmedAt != null) 'lastConfirmedAt': lastConfirmedAt!.toUtc().toIso8601String(),
        if (lastAuthFailure != null) 'lastAuthFailure': lastAuthFailure!.toUtc().toIso8601String(),
        if (lastRenewedAt != null) 'lastRenewedAt': lastRenewedAt!.toUtc().toIso8601String(),
        if (about) 'about': true,
        if (earlyRevocationPossible) 'earlyRevocationPossible': true,
        if (unverified) 'unverified': true,
        if (isHardDeadline) 'isHardDeadline': true,
        if (usesCredential) 'usesCredential': true,
        if (!hasConnection) 'hasConnection': false,
        if (serverRead != null) 'serverRead': serverRead!.toJson(),
        if (serverReadAt != null) 'serverReadAt': serverReadAt!.toUtc().toIso8601String(),
        if (note != null) 'note': note,
      };
}
