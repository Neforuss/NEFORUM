import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'account_connection.dart';
import 'composer.dart';
import 'providers.dart';
import 'sign_in_board.dart';

// Warns when a scheduled post goes out after a sign-in ends. Reads the status
// file only: no keychain read per target, and never the old date guess.

/// One network of a post that is, or is about to be, scheduled.
@immutable
class SignInScheduledTarget {
  const SignInScheduledTarget({required this.account, required this.network, required this.policy, required this.dueAt, this.held = false});
  final ConnectedAccount account;
  final String network;
  final SignInPolicy policy;

  /// When this network's copy goes out.
  final DateTime dueAt;

  /// The platform holds the copy and publishes it itself.
  final bool held;
}

/// Why a post may not reach a network.
enum SignInScheduleRisk {
  /// The network refused the sign-in.
  refused,

  /// The sign-in has already ended.
  ended,

  /// Nothing can renew it, and it ends before the post.
  endsFirst,

  /// A date the vendor announced comes before the post.
  deadline,

  /// It ends before the post unless a post or Renew now moves the date.
  renewalNeeded,

  /// The platform holds the copy, which still goes out, but out of reach after
  /// the date.
  heldPastEnd,

  /// It can end with no date (Inkbunny).
  idle,

  /// This device has not read the sign-in yet, so nothing vouches for it.
  notRead,
}

/// One warning under a schedule.
@immutable
class SignInScheduleNote {
  const SignInScheduleNote({required this.accountId, required this.risk, required this.text});
  final String accountId;
  final SignInScheduleRisk risk;
  final String text;

  /// The post will not reach the network as things stand.
  bool get misses => risk == SignInScheduleRisk.refused || risk == SignInScheduleRisk.ended || risk == SignInScheduleRisk.endsFirst || risk == SignInScheduleRisk.deadline;
}

/// A warning for every target of [targets] at risk, in their order. A network
/// with no sign-in, or one whose date is after its time, gets none.
List<SignInScheduleNote> signInScheduleNotes(List<SignInScheduledTarget> targets, Map<String, SignInStatus> statuses, DateTime now) {
  final out = <SignInScheduleNote>[];
  for (final t in targets) {
    if (!t.policy.hasConnection) continue;
    final s = statuses[t.account.id];
    SignInScheduleNote note(SignInScheduleRisk risk, String text) => SignInScheduleNote(accountId: t.account.id, risk: risk, text: text);
    if (s == null) {
      out.add(note(SignInScheduleRisk.notRead, "NEFORUM has not read the ${t.network} sign-in yet, so it cannot say this post will reach it. Open Accounts > Sign-ins to check."));
      continue;
    }
    if (s.lastAuthFailure != null) {
      out.add(note(SignInScheduleRisk.refused, '${t.network} refused its sign-in. This post will not reach ${t.network} until you reconnect it.'));
      continue;
    }
    final end = s.expiresAt;
    if (end == null) {
      if (s.limit == SignInLimit.idleUnknown) {
        out.add(note(SignInScheduleRisk.idle, '${t.network} can end its sign-in after several days without use, on no date anyone can know. If this post fails, reconnect and retry.'));
      }
      continue;
    }
    final date = signInDateWords(s);
    if (s.hasEnded(now)) {
      out.add(note(SignInScheduleRisk.ended, '${t.network}: the sign-in ${s.about ? 'has probably ended' : 'has ended'}, ${s.about ? '' : 'by '}$date. This post will not reach ${t.network} until you reconnect it.'));
      continue;
    }
    if (!t.dueAt.isAfter(end)) continue;
    if (t.held) {
      out.add(note(SignInScheduleRisk.heldPastEnd, '${t.network} holds this post and still publishes it, but its sign-in ends $date, before the post goes out. After that NEFORUM cannot change or remove it there.'));
    } else if (s.isHardDeadline) {
      out.add(note(SignInScheduleRisk.deadline, '${t.network} stops accepting these keys on $date, before this post goes out. Sign in by browser first, or it will not reach ${t.network}.'));
    } else if (s.renewsItself) {
      out.add(note(SignInScheduleRisk.renewalNeeded, '${t.network}: the sign-in ends $date, before this post goes out, unless a post or Renew now renews it first.'));
    } else {
      out.add(note(SignInScheduleRisk.endsFirst, '${t.network}: the sign-in ends $date, before this post goes out. Reconnect it first, or this post will not reach ${t.network}.'));
    }
  }
  return out;
}

/// The not-yet-finished targets of a saved [post] as [signInScheduleNotes] takes
/// them.
List<SignInScheduledTarget> signInTargetsOfPost(Post post, List<ConnectedAccount> accounts, AdapterRegistry registry) {
  final out = <SignInScheduledTarget>[];
  for (final t in post.targets) {
    if (t.isDone) continue;
    final a = accounts.where((x) => x.id == t.accountId).firstOrNull;
    final due = post.dueAtFor(t);
    final adapter = a == null ? null : registry.byId(a.platformId);
    if (a == null || due == null || adapter == null) continue;
    out.add(SignInScheduledTarget(account: a, network: adapter.descriptorForAccount(a).name, policy: adapter.signInPolicyFor(a), dueAt: due, held: t.isHeldByPlatform));
  }
  return out;
}

/// The warnings for a post in the queue.
final signInPostNotesProvider = Provider.autoDispose.family<List<SignInScheduleNote>, Post>((ref, post) {
  final statuses = ref.watch(signInStatusesProvider).value;
  // Not loaded yet says nothing either way.
  if (statuses == null || post.status != PostStatus.scheduled) return const [];
  return signInScheduleNotes(signInTargetsOfPost(post, ref.watch(accountListProvider), ref.watch(registryProvider)), statuses, ref.watch(signInClockProvider)());
});

/// The warnings for the post being written, once it has a time.
final signInComposerNotesProvider = Provider<List<SignInScheduleNote>>((ref) {
  final c = ref.watch(composerProvider);
  final when = c.scheduledAt;
  final statuses = ref.watch(signInStatusesProvider).value;
  if (when == null || statuses == null) return const [];
  final registry = ref.watch(registryProvider);
  final hold = ref.watch(settingsProvider.select((s) => s.delegateSchedules));
  final targets = <SignInScheduledTarget>[
    for (final p in ref.watch(composerPreviewsProvider))
      if (registry.byId(p.account.platformId) case final adapter?)
        SignInScheduledTarget(
          account: p.account,
          network: p.descriptor.name,
          policy: adapter.signInPolicyFor(p.account),
          dueAt: c.overrides[p.account.id]?.scheduledAt ?? when,
          held: signInWillBeHeld(p.account, p.descriptor, isThread: p.variant.isThread, delegateSchedules: hold),
        ),
  ];
  return signInScheduleNotes(targets, statuses, ref.watch(signInClockProvider)());
});

/// The platform would hold this copy if it were scheduled now: the same test
/// the schedule sheet's own note makes.
bool signInWillBeHeld(ConnectedAccount a, PlatformDescriptor d, {required bool isThread, required bool delegateSchedules}) =>
    delegateSchedules && a.tier.isAutomatic && d.serverSideScheduling && !isThread;
