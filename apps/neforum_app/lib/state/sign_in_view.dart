import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'account_connection.dart';
import 'demo.dart';
import 'providers.dart';

// What the sign-ins page, the closed account card and the banner say, as pure
// functions of the status file. No keychain, and nothing that could hold a key:
// the inputs are dates, names and the policy's own sentences.

/// The clock for everything here, replaceable in tests.
final signInClockProvider = Provider<Clock>((ref) => systemClock);

/// Ticks once a minute: a date passes with no write to the status file.
final signInMinuteProvider = StreamProvider<int>((ref) => Stream.periodic(const Duration(minutes: 1), (i) => i));

/// "3 Dec 2026": how these surfaces write a day. An end date is a day to the
/// person; the Connection section keeps the exact time.
String signInDay(DateTime t) => DateFormat('d MMM y').format(t.toLocal());

/// The three groups of the sign-ins page, in its order.
enum SignInGroup {
  mustReconnect('You must reconnect', 'NEFORUM cannot extend these. When the date comes, posts to them fail until you sign in again.'),
  renewsWhenPosting('Renews when NEFORUM posts', 'Each post renews the sign-in. A long quiet spell can still end it.'),
  noEndDate('No end date known', 'Nothing here has a date. Some last until revoked, and some networks do not say.');

  const SignInGroup(this.title, this.explanation);
  final String title;
  final String explanation;
}

/// Which group [s] belongs in at [now].
SignInGroup signInGroupOf(SignInStatus s, DateTime now) {
  if (!s.hasConnection) return SignInGroup.noEndDate;
  if (s.lastAuthFailure != null || s.hasEnded(now) || s.isHardDeadline) return SignInGroup.mustReconnect;
  if (s.renewsItself) return SignInGroup.renewsWhenPosting;
  return s.expiresAt == null ? SignInGroup.noEndDate : SignInGroup.mustReconnect;
}

/// One account on the sign-ins page.
@immutable
class SignInRow {
  const SignInRow({required this.account, required this.network, required this.status, required this.policy, required this.canCheck});
  final ConnectedAccount account;
  final String network;
  final SignInStatus status;
  final SignInPolicy policy;

  /// The platform can answer "Check now".
  final bool canCheck;
}

/// [status], or what the policy alone says while the status file has none yet.
SignInStatus signInStatusOrPolicy(ConnectedAccount account, SignInStatus? status, SignInPolicy policy, DateTime now) =>
    status ??
    SignInStatus.fromLifetime(account.id, deriveSignInLifetime(policy, const {}, now: now), hasConnection: policy.hasConnection);

/// Every account in [accounts] by group: none left out, whatever its network.
/// Soonest end first, and a refused or ended one before them all.
Map<SignInGroup, List<SignInRow>> signInRows(List<ConnectedAccount> accounts, Map<String, SignInStatus> statuses, AdapterRegistry registry, DateTime now) {
  final out = {for (final g in SignInGroup.values) g: <SignInRow>[]};
  for (final a in accounts) {
    final adapter = registry.byId(a.platformId);
    final policy = adapter?.signInPolicyFor(a) ?? SignInPolicy.noConnection;
    final status = signInStatusOrPolicy(a, statuses[a.id], policy, now);
    final real = adapter is DemoAdapter ? adapter.inner : adapter;
    out[signInGroupOf(status, now)]!.add(SignInRow(
      account: a,
      network: adapter?.descriptor.name ?? a.platformId,
      status: status,
      policy: policy,
      canCheck: real?.canReadSignIn(a) ?? false,
    ));
  }
  int rank(SignInRow r) {
    final s = r.status;
    if (s.lastAuthFailure != null || s.hasEnded(now)) return -1 << 40;
    return s.expiresAt?.difference(now).inMinutes ?? (1 << 40);
  }

  for (final rows in out.values) {
    final indexed = rows.indexed.toList()..sort((a, b) => rank(a.$2) != rank(b.$2) ? rank(a.$2).compareTo(rank(b.$2)) : a.$1 - b.$1);
    rows
      ..clear()
      ..addAll(indexed.map((e) => e.$2));
  }
  return out;
}

/// [s] as [signInText] reads it, with the state as of [now] rather than as of
/// the last write: a date passes with no write.
SignInLifetime signInLifetimeOfStatus(SignInStatus s, SignInPolicy policy, DateTime now) => SignInLifetime(
      state: s.hasEnded(now) ? SignInState.ended : s.state,
      limit: s.limit,
      source: s.source,
      renewsItself: s.renewsItself,
      expiresAt: s.expiresAt,
      about: s.about,
      endsSoon: s.endsSoon(now),
      earlyRevocationPossible: s.earlyRevocationPossible,
      unverified: s.unverified,
      isHardDeadline: s.isHardDeadline,
      disuseWindow: policy.disuseWindow,
      note: s.note,
      usesCredential: s.usesCredential,
    );

/// The sentence of a row on the sign-ins page.
String signInRowSentence(SignInRow r, DateTime now) {
  final s = r.status;
  if (!s.hasConnection) return 'NEFORUM stores no sign-in for this account, so there is nothing to end.';
  final refused = s.lastAuthFailure;
  // A refusal outranks whatever the date says: a renewal cannot fix it.
  if (refused != null) return '${r.network} refused this sign-in on ${signInDay(refused)}. Reconnect it. Posts to it fail until you do.';
  return signInText(signInLifetimeOfStatus(s, r.policy, now), signInDay);
}

/// How urgent a line is. Never shown by colour alone: the words say it too.
enum SignInUrgency { calm, soon, ended }

SignInUrgency signInUrgencyOf(SignInStatus s, DateTime now) {
  if (s.lastAuthFailure != null || s.hasEnded(now)) return SignInUrgency.ended;
  return s.endsSoon(now) ? SignInUrgency.soon : SignInUrgency.calm;
}

/// "5 days left", "Ended", "Refused": the row's pill. Null with no date.
String? signInCountdown(SignInStatus s, DateTime now) {
  if (s.lastAuthFailure != null) return 'Refused';
  final end = s.expiresAt;
  if (end == null) return null;
  if (s.hasEnded(now)) return s.about ? 'Probably ended' : 'Ended';
  final left = signInCalendarDays(now, end);
  final about = s.about ? 'About ' : '';
  if (left <= 0) return s.about ? 'About today' : 'Ends today';
  return '$about$left ${left == 1 ? 'day' : 'days'} left';
}

/// The one line on a closed account card. Null where there is no connection,
/// as hand-off accounts have none.
String? signInCardLine(SignInStatus s, SignInPolicy policy, DateTime now) {
  if (!s.hasConnection) return null;
  if (s.lastAuthFailure != null) return 'Sign-in refused. Reconnect it.';
  final end = s.expiresAt;
  if (end != null) {
    final words = signInEndWords(s, end, signInDay);
    if (s.hasEnded(now)) return s.about ? 'Sign-in probably ended $words' : 'Sign-in ended $words';
    if (s.isHardDeadline) return 'Keys stop working $words';
    if (s.renewsItself) return 'Renews when NEFORUM posts. Unused, ends $words';
    return 'Sign-in ends $words';
  }
  if (s.renewsItself) {
    if (s.usesCredential) return 'Renews automatically';
    final days = policy.disuseWindow?.inDays;
    return days == null ? 'Renews when NEFORUM posts. No end date known' : 'Renews when NEFORUM posts. Ends if unused for about $days days';
  }
  return switch (s.limit) {
    SignInLimit.none => 'No end date',
    SignInLimit.idleUnknown => 'Ends after idle time, on no set date',
    SignInLimit.date => 'No end date known yet',
    SignInLimit.undocumented => 'No published end date',
  };
}

/// Where a date came from, for a row. Null with no date.
String? signInSourceWords(SignInRow r) {
  final s = r.status;
  if (s.expiresAt == null) return null;
  if (s.isHardDeadline) return "From ${r.network}'s announcement.";
  return switch (s.source) {
    SignInDateSource.serverReported => 'Date from ${r.network}.',
    SignInDateSource.computed => "Worked out by NEFORUM from ${r.network}'s published rule.",
    SignInDateSource.unknown => 'Stored before NEFORUM 1.4. Where it came from was not recorded.',
  };
}

/// What a row says when the policy is unverified.
String signInUnverifiedWords(String network) => "Not confirmed: $network's own documentation does not settle this.";

/// What "Check now" found, in words. [after] is the status once it ran, null if
/// it failed. A read older than [asked] is an earlier one: this one got nothing.
/// Bluesky and Lemmy read their own token with no request, so only a platform's
/// refusal is worded as something it said.
String signInCheckWords(String network, DateTime asked, SignInStatus? after) {
  final read = after?.serverRead;
  if (after == null || read == null || read.readAt.isBefore(asked.subtract(const Duration(minutes: 1)))) return 'Could not check $network. Nothing changed.';
  if (!read.isValid) return '$network says this sign-in no longer works. Reconnect it.';
  final end = after.expiresAt;
  if (end == null) return 'Checked $network: no end date known.';
  return '$network sign-in: ends ${signInEndWords(after, end, signInDay)}.';
}

/// One line of the banner when it covers one sign-in. No bare date: it goes
/// through [signInEndWords].
String signInBannerLine(SignInBannerItem i, String network) {
  if (i.refused) return '$network refused its sign-in. Reconnect it so posts keep going out.';
  final s = i.status;
  final end = s.expiresAt!;
  final words = signInEndWords(s, end, signInDay);
  if (i.ended) return s.about ? '$network: the sign-in has probably ended ($words).' : '$network: the sign-in ended $words.';
  final left = i.daysLeft ?? 0;
  final when = left <= 0 ? 'today' : (left == 1 ? 'tomorrow' : 'in $left days');
  if (s.isHardDeadline) return '$network: these keys stop working $when, $words.';
  if (s.renewsItself) return '$network: the sign-in ends $when, $words, unless NEFORUM posts with it.';
  return '$network: the sign-in ends $when, $words.';
}

/// The banner's line for [items] together.
String signInBannerSummary(List<SignInBannerItem> items, String Function(SignInBannerItem) networkOf) {
  if (items.length == 1) return signInBannerLine(items.single, networkOf(items.single));
  final over = items.where((i) => i.ended || i.refused).length;
  final soon = items.length - over;
  final parts = [
    if (over > 0) '$over ended',
    if (soon > 0) '$soon ${soon == 1 ? 'ends' : 'end'} within $kSignInBannerDays days',
  ];
  return '${items.length} sign-ins need you: ${parts.join(', ')}.';
}

/// What this device closed of the banner: read from the warnings file.
final signInLedgerProvider = StreamProvider<SignInWarningLedger>((ref) async* {
  final store = ref.watch(servicesProvider).signInWarningStore;
  yield await store.read();
  await for (final _ in store.changes) {
    yield await store.read();
  }
});

/// Keys of a [SignInStatus] that the warnings and page may treat as this
/// device's own: enabled accounts with a connection.
List<SignInStatus> signInStatusesToWatch(List<ConnectedAccount> accounts, Map<String, SignInStatus> statuses) => [
      for (final a in accounts)
        if (a.enabled && (statuses[a.id]?.hasConnection ?? false)) statuses[a.id]!,
    ];
