import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'account_connection.dart';
import 'providers.dart';

// What the sign-ins page, the closed card, the banner and the notifications
// say. Everything here reads SignInStatus and the policies: names, dates and
// flags. No function here ever sees a key, so none can show one.

/// The clock behind the page, the card and the banner, replaceable in tests.
final signInClockProvider = Provider<Clock>((ref) => systemClock);

/// What has been warned about on this device, for the banner.
final signInWarningLedgerProvider = StreamProvider<SignInWarningLedger>((ref) async* {
  final store = ref.watch(servicesProvider).signInWarningStore;
  Future<SignInWarningLedger> read() async {
    try {
      return await store.read();
    } on Object {
      return SignInWarningLedger();
    }
  }

  yield await read();
  await for (final _ in store.changes) {
    yield await read();
  }
});

/// "4 Dec 2026": how a sign-in's date is written on screen and in a
/// notification. The day is what the person acts on; the copied setup and the
/// Connection section give the minute.
String signInDay(DateTime t) => DateFormat('d MMM y').format(t.toLocal());

/// [s]'s date with every qualifier it needs. The one place a date becomes words
/// outside [signInText], so "about" and "at the latest" cannot be forgotten.
String signInDateWords(SignInStatus s, [String Function(DateTime) when = signInDay]) {
  final end = s.expiresAt;
  if (end == null) return 'no known date';
  return '${s.about ? 'about ' : ''}${when(end)}${s.earlyRevocationPossible ? ' at the latest' : ''}';
}

/// "today", "tomorrow", "in 3 days": how far off [end] is on the calendar.
String signInDaysWords(int daysLeft) => switch (daysLeft) {
      <= 0 => 'today',
      1 => 'tomorrow',
      _ => 'in $daysLeft days',
    };

/// [signInDaysWords] for [s], qualified as [signInDateWords] is.
String signInRelativeWords(SignInStatus s, DateTime now) {
  final words = signInDaysWords(signInDaysLeft(s.expiresAt!, now));
  return '${s.about ? 'about ' : ''}$words${s.earlyRevocationPossible ? ' at the latest' : ''}';
}

/// [s] as [SignInLifetime], for [signInText]: as of [now], since a date passes
/// with no write to the status file. [policy] adds what the file does not hold.
SignInLifetime signInLifetimeOf(SignInStatus s, SignInPolicy policy, DateTime now) => SignInLifetime(
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

/// The sections of the sign-ins page.
enum SignInGroup {
  /// Nothing stored can renew it, or it has ended or been refused.
  mustReconnect,

  /// A post, or Renew now, moves its date.
  renewsWhenPosting,

  /// No date can be shown, for the reason its row gives.
  noEndDate,

  /// No sign-in at all (hand-off): nothing to run out.
  noConnection,
}

SignInGroup signInGroupOf(SignInStatus? s, SignInPolicy policy, DateTime now) {
  if (!policy.hasConnection) return SignInGroup.noConnection;
  if (s == null) return SignInGroup.noEndDate;
  if (s.lastAuthFailure != null) return SignInGroup.mustReconnect;
  if (s.expiresAt == null) return SignInGroup.noEndDate;
  if (s.hasEnded(now) || s.isHardDeadline || !s.renewsItself) return SignInGroup.mustReconnect;
  return SignInGroup.renewsWhenPosting;
}

/// How soon someone has to act on a row.
enum SignInUrgency {
  /// Refused, or the date has passed.
  now,

  /// 3 days or fewer.
  urgent,

  /// 14 days or fewer.
  soon,

  /// Further off.
  later,

  /// No date.
  none,
}

/// One connected account on the page.
@immutable
class SignInRow {
  const SignInRow({required this.account, required this.network, required this.policy, required this.status, required this.group, required this.urgency, required this.daysLeft, required this.canCheck, required this.postsAfterEnd});

  final ConnectedAccount account;
  final String network;
  final SignInPolicy policy;

  /// Null until this device has read the account's keys once.
  final SignInStatus? status;
  final SignInGroup group;
  final SignInUrgency urgency;

  /// Calendar days to the date. Null with no date.
  final int? daysLeft;

  /// The platform can be asked for this date ([PlatformAdapter.readsSignIn]).
  final bool canCheck;

  /// Scheduled posts through this account whose time is after the date.
  final int postsAfterEnd;

  bool get refused => status?.lastAuthFailure != null;

  /// A renewal can extend it. Not a stored credential (Bluesky signs itself in
  /// again), and not past a date the vendor announced.
  bool get canRenew => status != null && status!.renewsItself && !status!.usesCredential && !status!.isHardDeadline;

  /// What to do about it, in one sentence. Null when nothing is needed.
  String? get whatToDo {
    final s = status;
    if (s == null) return null;
    if (refused) return 'The network refused this sign-in. Sign in again, then retry any failed post.';
    if (urgency == SignInUrgency.now) return 'Sign in again. Posts to it fail until you do.';
    return switch (group) {
      SignInGroup.mustReconnect when s.isHardDeadline => 'Sign in again by browser before then.',
      SignInGroup.mustReconnect => 'Sign in again before then. Nothing can renew it.',
      SignInGroup.renewsWhenPosting => 'A post renews it. So does Renew now.',
      _ => null,
    };
  }
}

/// The whole page, worked out from what is stored. Pure: no keychain, no clock.
@immutable
class SignInBoard {
  const SignInBoard({required this.mustReconnect, required this.renewsWhenPosting, required this.noEndDate, required this.noConnection});

  final List<SignInRow> mustReconnect;
  final List<SignInRow> renewsWhenPosting;
  final List<SignInRow> noEndDate;
  final List<SignInRow> noConnection;

  List<SignInRow> get all => [...mustReconnect, ...renewsWhenPosting, ...noEndDate, ...noConnection];

  /// What runs out next: anything refused or ended first, then the soonest date.
  SignInRow? get next {
    final dated = [...mustReconnect, ...renewsWhenPosting];
    if (dated.isEmpty) return null;
    return ([...dated]..sort(_soonestFirst)).first;
  }
}

int _soonestFirst(SignInRow a, SignInRow b) {
  final byRefusal = (a.refused ? 0 : 1).compareTo(b.refused ? 0 : 1);
  if (byRefusal != 0) return byRefusal;
  final x = a.status?.expiresAt, y = b.status?.expiresAt;
  if (x != null && y != null) return x.compareTo(y);
  if (x == null && y == null) return a.network.compareTo(b.network);
  return x == null ? -1 : 1;
}

int _byName(SignInRow a, SignInRow b) {
  final n = a.network.compareTo(b.network);
  return n != 0 ? n : a.account.displayName.compareTo(b.account.displayName);
}

/// Scheduled posts in [posts] going out through [accountId] after [end].
int signInPostsAfter(String accountId, DateTime? end, List<Post> posts) {
  if (end == null) return 0;
  var n = 0;
  for (final p in posts) {
    if (p.status != PostStatus.scheduled) continue;
    for (final t in p.targets) {
      if (t.accountId != accountId || t.isDone) continue;
      final due = p.dueAtFor(t);
      if (due != null && due.isAfter(end)) n++;
    }
  }
  return n;
}

/// Every account in [accounts] in exactly one section: none is ever left out,
/// hand-off and unread ones included.
SignInBoard buildSignInBoard(List<ConnectedAccount> accounts, Map<String, SignInStatus> statuses, AdapterRegistry registry, DateTime now, {List<Post> posts = const []}) {
  final rows = <SignInRow>[];
  for (final a in accounts) {
    final adapter = registry.byId(a.platformId);
    final policy = adapter?.signInPolicyFor(a) ?? SignInPolicy.noConnection;
    final s = statuses[a.id];
    final end = s?.expiresAt;
    final left = end == null ? null : signInDaysLeft(end, now);
    final SignInUrgency urgency;
    if (s?.lastAuthFailure != null || (s?.hasEnded(now) ?? false)) {
      urgency = SignInUrgency.now;
    } else if (left == null) {
      urgency = SignInUrgency.none;
    } else if (left <= 3) {
      urgency = SignInUrgency.urgent;
    } else if (left <= kSignInBannerDays) {
      urgency = SignInUrgency.soon;
    } else {
      urgency = SignInUrgency.later;
    }
    rows.add(SignInRow(
      account: a,
      network: adapter?.descriptorForAccount(a).name ?? a.platformId,
      policy: policy,
      status: s,
      group: signInGroupOf(s, policy, now),
      urgency: urgency,
      daysLeft: left,
      canCheck: adapter?.readsSignIn(a) ?? false,
      postsAfterEnd: signInPostsAfter(a.id, end, posts),
    ));
  }
  List<SignInRow> of(SignInGroup g, int Function(SignInRow, SignInRow) order) => rows.where((r) => r.group == g).toList()..sort(order);
  return SignInBoard(
    mustReconnect: of(SignInGroup.mustReconnect, _soonestFirst),
    renewsWhenPosting: of(SignInGroup.renewsWhenPosting, _soonestFirst),
    noEndDate: of(SignInGroup.noEndDate, _byName),
    noConnection: of(SignInGroup.noConnection, _byName),
  );
}

/// The board as stored now.
final signInBoardProvider = Provider<SignInBoard>((ref) {
  final accounts = ref.watch(accountListProvider);
  final statuses = ref.watch(signInStatusesProvider).value ?? const <String, SignInStatus>{};
  final posts = ref.watch(scheduledPostsProvider);
  return buildSignInBoard(accounts, statuses, ref.watch(registryProvider), ref.watch(signInClockProvider)(), posts: posts);
});

/// The sentence of a row: [signInText] with what the status alone knows.
String signInRowText(SignInRow row, DateTime now) {
  final s = row.status;
  if (s == null) return "NEFORUM has not read this account's date yet.";
  return signInText(signInLifetimeOf(s, row.policy, now), signInDay);
}

/// A closed account card's one line, or null when the card should stay as it
/// was (hand-off, or nothing read yet).
///
/// [SignInUrgency.none] says so too: "no known date" is an answer, and a card
/// that says nothing cannot be told from a card that was not checked.
({String text, SignInUrgency urgency})? signInCardLine(SignInStatus? s, SignInPolicy policy, DateTime now) {
  if (s == null || !policy.hasConnection || !s.hasConnection) return null;
  if (s.lastAuthFailure != null) return (text: 'Sign-in refused. Reconnect it.', urgency: SignInUrgency.now);
  final end = s.expiresAt;
  if (end == null) {
    if (s.limit == SignInLimit.idleUnknown) return (text: 'Ends after idle time. No date can be known.', urgency: SignInUrgency.none);
    if (s.limit == SignInLimit.none) return (text: 'No end date', urgency: SignInUrgency.none);
    return (text: s.renewsItself ? 'Renews when NEFORUM posts. No end date known.' : 'No end date known', urgency: SignInUrgency.none);
  }
  final date = signInDateWords(s);
  if (s.hasEnded(now)) {
    return (text: s.about ? 'Probably ended, about ${signInDay(end)}${s.earlyRevocationPossible ? ' at the latest' : ''}. Reconnect it.' : 'Ended ${s.earlyRevocationPossible ? 'by $date' : 'on $date'}. Reconnect it.', urgency: SignInUrgency.now);
  }
  final left = signInDaysLeft(end, now);
  final urgency = left <= 3 ? SignInUrgency.urgent : (left <= kSignInBannerDays ? SignInUrgency.soon : SignInUrgency.later);
  final when = left <= kSignInBannerDays ? ' (${signInDaysWords(left)})' : '';
  if (s.isHardDeadline) return (text: 'Reconnect by $date$when', urgency: urgency);
  return (text: s.renewsItself ? 'Renews when NEFORUM posts. Unused, ends $date$when' : 'Reconnect by $date$when', urgency: urgency);
}

/// A warning in words. The days are as of the moment it shows: one that goes
/// out late says what is true then, and one handed to the OS says what will be.
SignInWarningNotice signInWarningNoticeFor(SignInWarningStep step, SignInStatus s, {required String network, required String who, required DateTime now}) {
  final payload = 'signin:${step.accountId}';
  ({String title, String body}) words() {
    if (step.refused) {
      return (title: '$network refused the sign-in', body: '$who: sign in again in NEFORUM, then retry any failed post.');
    }
    if (step.days == 0) {
      return s.about
          ? (title: '$network sign-in has probably ended', body: '$who: posts to it fail until you sign in again.')
          : (title: '$network sign-in has ended', body: '$who: posts to it fail until you sign in again.');
    }
    final left = step.moment.isAfter(now) ? step.days : signInDaysLeft(s.expiresAt!, now);
    final days = signInDaysWords(left);
    final date = signInDateWords(s);
    return switch (step.kind) {
      SignInWarningCase.hardDeadline => (title: '$network stops these keys $days', body: '$who: $network stops accepting these keys on $date. Sign in by browser before then.'),
      SignInWarningCase.mustReconnect => (title: '$network sign-in ends $days', body: '$who: ends $date. Sign in again in NEFORUM to keep posting.'),
      SignInWarningCase.renewsWhenPosting => (title: '$network sign-in ends $days if unused', body: '$who: ends $date unless a post renews it. Post with it, or use Renew now in Accounts.'),
    };
  }

  final w = words();
  return SignInWarningNotice(key: step.key, title: w.title, body: w.body, payload: payload);
}

/// What the banner says about [items], soonest first.
String signInBannerText(List<SignInBannerItem> items, String Function(SignInStatus) networkOf, DateTime now) {
  final first = items.first.status;
  final name = networkOf(first);
  final String what;
  if (first.lastAuthFailure != null) {
    what = '$name refused its sign-in';
  } else if (first.hasEnded(now)) {
    what = first.about ? '$name sign-in has probably ended' : '$name sign-in has ended';
  } else {
    what = '$name sign-in ends ${signInRelativeWords(first, now)}';
  }
  if (items.length == 1) return '$what.';
  return '${items.length} sign-ins need you. First: $what.';
}
