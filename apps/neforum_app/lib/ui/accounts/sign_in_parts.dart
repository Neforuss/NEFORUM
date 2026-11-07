import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/account_connection.dart';
import '../../state/providers.dart';
import '../../state/sign_in_board.dart';
import '../../state/sign_in_schedule.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../router.dart';

/// Where the sign-ins page lives.
const String kSignInsLocation = '/accounts/sign-ins';

Tone signInTone(SignInUrgency u) => switch (u) {
      SignInUrgency.now || SignInUrgency.urgent => Tone.danger,
      SignInUrgency.soon => Tone.warning,
      SignInUrgency.later => Tone.neutral,
      SignInUrgency.none => Tone.neutral,
    };

IconData signInIcon(SignInUrgency u) => switch (u) {
      SignInUrgency.now => Icons.link_off_rounded,
      SignInUrgency.urgent || SignInUrgency.soon => Icons.schedule_rounded,
      SignInUrgency.later => Icons.event_available_outlined,
      SignInUrgency.none => Icons.all_inclusive_rounded,
    };

/// One line on a closed account card: when its sign-in ends. Reads the status
/// file only, so a page of cards asks the keychain nothing.
class AccountSignInLine extends ConsumerWidget {
  const AccountSignInLine({super.key, required this.account});
  final ConnectedAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final status = ref.watch(signInStatusesProvider.select((s) => s.value?[account.id]));
    final policy = ref.watch(registryProvider).byId(account.platformId)?.signInPolicyFor(account) ?? SignInPolicy.noConnection;
    final line = signInCardLine(status, policy, ref.watch(signInClockProvider)());
    if (line == null) return const SizedBox.shrink();
    final tone = signInTone(line.urgency);
    final quiet = tone == Tone.neutral;
    return Semantics(
      button: true,
      label: 'Sign-in: ${line.text}. Opens the sign-ins page.',
      excludeSemantics: true,
      child: InkWell(
        onTap: () => context.go(kSignInsLocation),
        child: Container(
          margin: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
          padding: EdgeInsets.symmetric(horizontal: quiet ? 0 : Space.sm, vertical: quiet ? Space.xs : Space.sm),
          constraints: const BoxConstraints(minHeight: 32),
          decoration: quiet ? null : BoxDecoration(color: tone.bg(nf), borderRadius: Radii.rSm),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(signInIcon(line.urgency), size: 16, color: quiet ? nf.textFaint : tone.fg(nf)),
            const SizedBox(width: Space.sm),
            Expanded(child: Text(line.text, style: context.text.bodySmall?.copyWith(color: quiet ? nf.textMuted : nf.text))),
          ]),
        ),
      ),
    );
  }
}

/// The banner above every section while anything is at 14 days or fewer, ended
/// or refused. Closing it holds until something reaches its next threshold.
class SignInBanner extends ConsumerWidget {
  const SignInBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statuses = ref.watch(signInStatusesProvider).value;
    final ledger = ref.watch(signInWarningLedgerProvider).value;
    if (statuses == null || ledger == null) return const SizedBox.shrink();
    final now = ref.watch(signInClockProvider)();
    final accounts = ref.watch(accountListProvider);
    // A status can outlive its account for a moment; the banner speaks of accounts.
    final items = signInBannerItems(statuses.values.where((s) => accounts.any((a) => a.id == s.accountId)), ledger, now);
    if (items.isEmpty || items.every((i) => i.closed)) return const SizedBox.shrink();

    final nf = context.nf;
    final registry = ref.watch(registryProvider);
    String networkOf(SignInStatus s) {
      final a = accounts.where((x) => x.id == s.accountId).firstOrNull;
      return (a == null ? null : registry.byId(a.platformId)?.descriptorForAccount(a).name) ?? 'A connection';
    }

    final first = items.first.status;
    final pressing = first.lastAuthFailure != null || first.hasEnded(now) || signInDaysLeft(first.expiresAt!, now) <= 3;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.only(left: Space.lg, right: Space.xs),
        decoration: BoxDecoration(color: pressing ? nf.dangerSoft : nf.warningSoft, border: Border(bottom: BorderSide(color: nf.border))),
        child: Row(children: [
          Icon(pressing ? Icons.link_off_rounded : Icons.schedule_rounded, size: 16, color: pressing ? nf.danger : nf.warning),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              child: Text(signInBannerText(items, networkOf, now), maxLines: 3, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.text)),
            ),
          ),
          TextButton(
            onPressed: () => context.go(kSignInsLocation),
            style: TextButton.styleFrom(foregroundColor: nf.text, minimumSize: const Size(48, 48)),
            child: const Text('Sign-ins'),
          ),
          ToolButton(
            icon: Icons.close_rounded,
            tooltip: 'Close until the next warning',
            size: 48,
            onPressed: () => ref.read(servicesProvider).signInWarningStore.change((l) => closeSignInBanner(items, l, now)),
          ),
        ]),
      ),
    );
  }
}

/// Warnings under a schedule: which networks a post may miss, and why.
class SignInScheduleNotesView extends StatelessWidget {
  const SignInScheduleNotesView({super.key, required this.notes, this.showLink = true});
  final List<SignInScheduleNote> notes;

  /// Offers the sign-ins page. Off in the schedule sheet, which sits over the
  /// page it would open.
  final bool showLink;

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) return const SizedBox.shrink();
    final nf = context.nf;
    final misses = notes.any((n) => n.misses);
    return Container(
      key: const ValueKey('sign-in-schedule-notes'),
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.sm, Space.sm),
      decoration: BoxDecoration(color: misses ? nf.dangerSoft : nf.warningSoft, borderRadius: Radii.rSm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final n in notes)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xxs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(n.misses ? Icons.link_off_rounded : Icons.schedule_rounded, size: 16, color: n.misses ? nf.danger : nf.warning),
              const SizedBox(width: Space.sm),
              Expanded(child: Text(n.text, style: context.text.bodySmall?.copyWith(color: nf.text))),
            ]),
          ),
        if (showLink)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => context.go(kSignInsLocation),
              style: TextButton.styleFrom(foregroundColor: nf.text, minimumSize: const Size(48, 40)),
              child: const Text('Open sign-ins'),
            ),
          ),
      ]),
    );
  }
}

/// The composer's warnings once the post has a time.
class ComposerSignInNotes extends ConsumerWidget {
  const ComposerSignInNotes({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(signInComposerNotesProvider);
    if (notes.isEmpty) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(top: Space.lg), child: SignInScheduleNotesView(notes: notes));
  }
}

/// Keeps the Accounts page's way in: what runs out next, in one row.
class NextSignInRow extends ConsumerWidget {
  const NextSignInRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final board = ref.watch(signInBoardProvider);
    if (board.all.every((r) => r.group == SignInGroup.noConnection)) return const SizedBox.shrink();
    final next = board.next;
    final now = ref.watch(signInClockProvider)();
    final String text;
    if (next == null) {
      text = 'Nothing here has a known end date.';
    } else if (next.refused) {
      text = '${next.network} refused its sign-in.';
    } else if (next.status!.hasEnded(now)) {
      text = '${next.network} sign-in has ended.';
    } else {
      text = 'Next to run out: ${next.network}, ${signInRelativeWords(next.status!, now)}.';
    }
    final tone = next == null ? Tone.neutral : signInTone(next.urgency);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xl),
      child: Material(
        color: tone == Tone.neutral ? nf.surface : tone.bg(nf),
        shape: RoundedRectangleBorder(borderRadius: Radii.rMd, side: BorderSide(color: nf.border)),
        child: InkWell(
          borderRadius: Radii.rMd,
          onTap: () => context.go(kSignInsLocation),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md),
            child: Row(children: [
              Icon(next == null ? Icons.all_inclusive_rounded : signInIcon(next.urgency), size: 18, color: tone == Tone.neutral ? nf.textMuted : tone.fg(nf)),
              const SizedBox(width: Space.md),
              Expanded(child: Text(text, style: context.text.bodyMedium?.copyWith(color: nf.text))),
              const SizedBox(width: Space.sm),
              Text('Sign-ins', style: context.text.labelLarge?.copyWith(color: nf.text)),
              Icon(Icons.chevron_right_rounded, size: 20, color: nf.textMuted),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Goes to the connect flow for [account], which replaces its sign-in and keeps
/// the posts pointing at it.
void reconnectAccount(BuildContext context, ConnectedAccount account) => context.go('${AppSection.accounts.path}/add?platform=${account.platformId}');
