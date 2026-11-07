import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'account_connection.dart';
import 'composer.dart';
import 'providers.dart';
import 'settings.dart';
import 'sign_in_view.dart';

// Whether a post can reach a network at its time, by the sign-in model (D14):
// the status file, never `signInExpiry` and never a keychain read per target.
// Every way a post could silently miss a network is one case here, and each
// has a line in `sign_ins_page_test.dart`.

/// Why a post might not reach one network.
enum SignInRiskKind {
  /// The sign-in has ended already.
  ended,

  /// The network refused the sign-in when last used.
  refused,

  /// Nothing can extend it, and it ends before the post's time.
  endsFirst,

  /// A post in between would renew it, and with none it ends first.
  renewalEndsFirst,

  /// The vendor retires this way of signing in before the post's time.
  deadlineFirst,

  /// The platform holds the post, so it still goes out, but NEFORUM can no
  /// longer change or take it back after the date.
  heldEndsFirst,

  /// It ends after idle time on no knowable date, and the post is far enough
  /// off that it may have.
  idle,

  /// The account is switched off: the post skips it.
  accountOff,

  /// The account was removed: the post cannot reach it.
  accountRemoved,
}

/// One network a post may miss, in words.
@immutable
class SignInRisk {
  const SignInRisk({required this.accountId, required this.platformId, required this.network, required this.kind, required this.text});
  final String accountId;
  final String? platformId;
  final String network;
  final SignInRiskKind kind;
  final String text;

  /// The post can miss the network. A held post goes out regardless.
  bool get mayMiss => kind != SignInRiskKind.heldEndsFirst;
}

/// How long a quiet Inkbunny session can be counted on: its docs say "several days".
const Duration kIdleSignInCountsFor = Duration(days: 3);

/// The risk for one target at [due] (null: right now). [heldNow]: the platform
/// already holds the copy. [willHold]: scheduling hands the copy to the platform.
SignInRisk? signInRiskFor({
  required String accountId,
  required ConnectedAccount? account,
  required String network,
  required SignInStatus? status,
  required DateTime? due,
  required DateTime now,
  bool heldNow = false,
  bool willHold = false,
}) {
  SignInRisk risk(SignInRiskKind kind, String text) => SignInRisk(accountId: accountId, platformId: account?.platformId, network: network, kind: kind, text: text);
  if (account == null) return risk(SignInRiskKind.accountRemoved, 'An account of this post was removed, so the post cannot reach it. Edit the post or connect the account again.');
  if (!account.enabled && !heldNow) return risk(SignInRiskKind.accountOff, '$network is switched off, so this post skips it.');
  final s = status;
  if (s == null || !s.hasConnection) return null;
  final at = due ?? now;
  final end = s.expiresAt;
  final words = end == null ? '' : signInEndWords(s, end, signInDay);
  final over = s.lastAuthFailure != null || s.hasEnded(now);
  final endsFirst = end != null && !at.isBefore(end);

  // What the platform already holds goes out without NEFORUM. A sign-in that
  // has already ended can no longer hand it over, so that one stays a miss.
  if (heldNow && (over || endsFirst) || (willHold && !over && endsFirst)) {
    final ending = over ? 'its sign-in has ended' : 'its sign-in ends $words';
    return risk(SignInRiskKind.heldEndsFirst, '$network holds this post, so it still goes out. But $ending, and NEFORUM cannot change or take back the post until you reconnect.');
  }
  if (s.lastAuthFailure != null) return risk(SignInRiskKind.refused, '$network refused its sign-in. Reconnect it, or it misses this post.');
  if (s.hasEnded(now)) {
    return risk(SignInRiskKind.ended, s.about ? "$network's sign-in has probably ended ($words). Reconnect it, or it may miss this post." : "$network's sign-in ended $words. Reconnect it, or it misses this post.");
  }
  if (endsFirst) {
    if (s.isHardDeadline) return risk(SignInRiskKind.deadlineFirst, '$network stops accepting these keys $words, before this post. Reconnect by browser sign-in, or it misses this post.');
    if (s.renewsItself) return risk(SignInRiskKind.renewalEndsFirst, "$network's sign-in ends $words, before this post, unless NEFORUM posts with it first. Post with it or reconnect, or it misses this post.");
    return risk(SignInRiskKind.endsFirst, "$network's sign-in ends $words, before this post. Reconnect it, or it misses this post.");
  }
  if (s.limit == SignInLimit.idleUnknown && at.difference(s.lastConfirmedAt ?? now) > kIdleSignInCountsFor) {
    return risk(SignInRiskKind.idle, '$network ends a sign-in after several days without use, on no set date. It may need a reconnect before this post.');
  }
  return null;
}

/// Whether scheduling hands this copy to the platform: the same test as
/// `PublishService.canDelegate` and its thread rule.
bool signInWillHold(AppSettings settings, ConnectedAccount account, PlatformDescriptor descriptor, {required bool isThread}) =>
    settings.delegateSchedules && account.enabled && account.tier.isAutomatic && descriptor.serverSideScheduling && !isThread;

/// The risks of a saved post at [now], for the queue. Finished targets have none.
/// With [handsOver], what scheduling it under those settings would hand to a
/// platform counts as held.
List<SignInRisk> signInRisksOfPost(
  Post post, {
  required List<ConnectedAccount> accounts,
  required Map<String, SignInStatus> statuses,
  required AdapterRegistry registry,
  required DateTime now,
  AppSettings? handsOver,
}) {
  final out = <SignInRisk>[];
  for (final t in post.targets) {
    if (t.isDone || t.status == TargetStatus.cancelled || t.status == TargetStatus.awaitingHandoff || t.status == TargetStatus.publishing) continue;
    final a = accounts.where((x) => x.id == t.accountId).firstOrNull;
    final name = a == null ? 'An account' : (registry.descriptor(a.platformId)?.name ?? a.displayName);
    final descriptor = a == null ? null : registry.byId(a.platformId)?.descriptorForAccount(a);
    final r = signInRiskFor(
      accountId: t.accountId,
      account: a,
      network: name,
      status: statuses[t.accountId],
      due: post.dueAtFor(t),
      now: now,
      heldNow: t.isHeldByPlatform,
      willHold: handsOver != null && a != null && descriptor != null && signInWillHold(handsOver, a, descriptor, isThread: post.isThread),
    );
    if (r != null) out.add(r);
  }
  return out;
}

/// The risks of saved [post] if it moves to [when]: what Reschedule warns and
/// asks about. Networks still to go keep their gaps, as [rescheduledPost] does.
List<SignInRisk> signInRisksOfReschedule(
  Post post,
  DateTime when, {
  required List<ConnectedAccount> accounts,
  required Map<String, SignInStatus> statuses,
  required AdapterRegistry registry,
  required AppSettings settings,
  required DateTime now,
}) =>
    signInRisksOfPost(rescheduledPost(post, when, now), accounts: accounts, statuses: statuses, registry: registry, now: now, handsOver: settings);

/// The risks of what the composer holds, at its schedule or right now.
final composerSignInRisksProvider = Provider<List<SignInRisk>>((ref) {
  final previews = ref.watch(composerPreviewsProvider);
  if (previews.isEmpty) return const [];
  final c = ref.watch(composerProvider);
  final settings = ref.watch(settingsProvider);
  final statuses = ref.watch(signInStatusesProvider).value ?? const {};
  ref.watch(signInMinuteProvider);
  final now = ref.watch(signInClockProvider)();
  final out = <SignInRisk>[];
  for (final p in previews) {
    final due = c.overrides[p.account.id]?.scheduledAt ?? c.scheduledAt;
    final r = signInRiskFor(
      accountId: p.account.id,
      account: p.account,
      network: p.descriptor.name,
      status: statuses[p.account.id],
      due: due,
      now: now,
      willHold: due != null && signInWillHold(settings, p.account, p.descriptor, isThread: p.variant.isThread),
    );
    if (r != null) out.add(r);
  }
  return out;
});
