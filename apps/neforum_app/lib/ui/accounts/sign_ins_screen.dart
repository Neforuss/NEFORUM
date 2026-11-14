import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/account_connection.dart';
import '../../state/providers.dart';
import '../../state/sign_in_view.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import '../router.dart';
import 'guide_sheet.dart';

/// Every connected account by when its sign-in ends and who has to act. Reads
/// the status file only: opening this page raises no keychain prompt, apart from
/// the once-a-day read of a platform that can report its own date.
class SignInsScreen extends ConsumerStatefulWidget {
  const SignInsScreen({super.key});

  @override
  ConsumerState<SignInsScreen> createState() => _SignInsScreenState();
}

class _SignInsScreenState extends ConsumerState<SignInsScreen> {
  /// Accounts with a Renew or Check under way.
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  /// When the page opens: accounts with no status yet, and the platforms that
  /// report their own date, at most once a day each.
  void _refresh() {
    if (!mounted) return;
    final s = ref.read(servicesProvider);
    if (s.demo) return;
    unawaited(s.signInStatus.refreshForPage(ref.read(accountListProvider), s.connectContext()));
  }

  Future<void> _during(String id, Future<void> Function() job) async {
    setState(() => _busy.add(id));
    try {
      await job();
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  void _reconnect(SignInRow r) => context.go('${AppSection.accounts.path}/add?platform=${r.account.platformId}');

  Future<void> _renew(SignInRow r) => _during(r.account.id, () async {
        final s = ref.read(servicesProvider);
        if (s.demo) {
          showToast(context, 'This is the demo: nothing was renewed.', icon: Icons.info_outline_rounded);
          return;
        }
        final SignInRenewalOutcome out;
        try {
          out = await s.publisher().renewSignIn(r.account.id);
        } on Object {
          if (mounted) showToast(context, 'Could not renew ${r.network}. Nothing changed.', icon: Icons.error_outline_rounded);
          return;
        }
        if (!mounted) return;
        // By kind, never the error's text: it can quote a server.
        final (text, icon) = switch (out.error?.kind) {
          null => out.renewed
              ? ('${r.network} sign-in renewed.', Icons.check_rounded)
              : ('${r.network} had nothing to renew just now. Its sign-in is as it was.', Icons.info_outline_rounded),
          PublishErrorKind.auth => ('${r.network} refused the renewal. Reconnect it.', Icons.link_off_rounded),
          PublishErrorKind.network || PublishErrorKind.quota => ('Could not reach ${r.network}. Nothing changed. Try again later.', Icons.cloud_off_rounded),
          _ => ('Could not renew ${r.network}. Nothing changed.', Icons.error_outline_rounded),
        };
        showToast(context, text, icon: icon);
      });

  Future<void> _check(SignInRow r) => _during(r.account.id, () async {
        final s = ref.read(servicesProvider);
        if (s.demo) {
          showToast(context, 'This is the demo: nothing was checked.', icon: Icons.info_outline_rounded);
          return;
        }
        final asked = ref.read(signInClockProvider)();
        SignInStatus? after;
        try {
          after = await s.signInStatus.readFromServer(r.account, s.connectContext(), force: true);
        } on Object {
          after = null;
        }
        if (!mounted) return;
        showToast(context, signInCheckWords(r.network, asked, after), icon: Icons.fact_check_outlined);
      });

  @override
  Widget build(BuildContext context) {
    ref.watch(signInMinuteProvider);
    final accounts = ref.watch(accountListProvider);
    final statuses = ref.watch(signInStatusesProvider).value ?? const <String, SignInStatus>{};
    final registry = ref.watch(registryProvider);
    final now = ref.watch(signInClockProvider)();
    final groups = signInRows(accounts, statuses, registry, now);
    int count(SignInGroup g) => groups[g]!.length;

    return PageBody(maxWidth: 980, children: [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => context.go(AppSection.accounts.path),
          icon: const Icon(Icons.arrow_back_rounded, size: 18),
          label: const Text('Accounts'),
        ),
      ),
      const SizedBox(height: Space.xs),
      PageHeader(
        title: 'Sign-ins',
        subtitle: accounts.isEmpty
            ? 'When each connection ends, and what NEFORUM does about it.'
            : '${count(SignInGroup.mustReconnect)} need you · ${count(SignInGroup.renewsWhenPosting)} renew when NEFORUM posts · ${count(SignInGroup.noEndDate)} with no end date known',
      ),
      const SizedBox(height: Space.x3),
      if (accounts.isEmpty)
        EmptyState(
          compact: true,
          icon: Icons.key_off_rounded,
          title: 'Nothing connected yet',
          body: 'Each account you connect shows here with its end date.',
          action: TextButton(onPressed: () => context.go('${AppSection.accounts.path}/add'), child: const Text('Add an account')),
        )
      else
        for (final g in SignInGroup.values)
          if (groups[g]!.isNotEmpty) ...[
            SectionHeader(g.title, subtitle: g.explanation),
            const SizedBox(height: Space.md),
            NfCard(
              key: ValueKey('sign-in-group-${g.name}'),
              padding: EdgeInsets.zero,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final (i, r) in groups[g]!.indexed) ...[
                  if (i > 0) Divider(height: 1, color: context.nf.hairline),
                  _SignInRowView(
                    key: ValueKey('sign-in-row-${r.account.id}'),
                    row: r,
                    now: now,
                    busy: _busy.contains(r.account.id),
                    onReconnect: () => _reconnect(r),
                    onRenew: () => _renew(r),
                    onCheck: () => _check(r),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: Space.x3),
          ],
      if (accounts.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => showGuideSheet(context, 'sign-in-lifetimes', asset: 'sign-in-lifetimes.md'),
            icon: const Icon(Icons.menu_book_outlined, size: 18),
            label: const Text('How long each network keeps you signed in'),
          ),
        ),
    ]);
  }
}

/// One account. Wide: identity, then the date, then the actions, in columns that
/// line up from row to row, with the sentence under them. Narrow: the same in
/// one column. State is in words and a pill, never colour alone.
class _SignInRowView extends StatelessWidget {
  const _SignInRowView({
    super.key,
    required this.row,
    required this.now,
    required this.busy,
    required this.onReconnect,
    required this.onRenew,
    required this.onCheck,
  });

  final SignInRow row;
  final DateTime now;
  final bool busy;
  final VoidCallback onReconnect;
  final VoidCallback onRenew;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final s = row.status;
    final a = row.account;
    final urgency = signInUrgencyOf(s, now);
    final group = signInGroupOf(s, now);
    final countdown = signInCountdown(s, now);
    final end = s.expiresAt;
    final tone = switch (urgency) {
      SignInUrgency.ended => Tone.danger,
      SignInUrgency.soon => Tone.warning,
      SignInUrgency.calm => Tone.neutral,
    };
    final muted = context.text.bodySmall?.copyWith(color: nf.textMuted);

    final identity = Row(children: [
      AccountAvatar(a, size: 36, dimmed: !a.enabled),
      const SizedBox(width: Space.md),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(a.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleSmall),
          Text(
            [row.network, if (a.handle != null) a.handle!].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.bodySmall?.copyWith(color: nf.textFaint),
          ),
        ]),
      ),
    ]);

    final when = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (end != null)
        Text(
          // The date alone would be bare: it carries its "about" and "at the latest".
          '${s.about ? 'About ' : ''}${signInDateWords(s, end, signInDay)}',
          style: context.text.titleSmall?.copyWith(color: urgency == SignInUrgency.ended ? nf.danger : nf.text),
        )
      else
        Text(s.hasConnection ? _noDateTitle(s) : 'No sign-in stored', style: context.text.titleSmall?.copyWith(color: nf.textMuted)),
      const SizedBox(height: Space.xs),
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        if (countdown != null)
          StatusPill(countdown, tone: tone, icon: urgency == SignInUrgency.calm ? Icons.event_rounded : (urgency == SignInUrgency.soon ? Icons.schedule_rounded : Icons.link_off_rounded), dense: true),
        if (s.isHardDeadline) const StatusPill('Announced date', tone: Tone.info, icon: Icons.campaign_outlined, dense: true),
        if (s.unverified) const StatusPill('Not confirmed', tone: Tone.neutral, icon: Icons.help_outline_rounded, dense: true),
        if (!a.enabled) const StatusPill('Off', dense: true),
      ]),
    ]);

    final mustAct = group == SignInGroup.mustReconnect;
    final canRenew = s.renewsItself && !s.hasEnded(now) && s.lastAuthFailure == null;
    // A finger's width on a phone; the mouse's on a computer.
    final target = ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(48, context.isCompact ? 48 : 36)));
    final actions = busy
        ? const SizedBox(width: 48, height: 48, child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))))
        : Wrap(spacing: Space.xs, runSpacing: Space.xs, alignment: WrapAlignment.end, children: [
            if (mustAct && urgency == SignInUrgency.calm) OutlinedButton(onPressed: onReconnect, style: target, child: const Text('Reconnect')),
            if (mustAct && urgency != SignInUrgency.calm) FilledButton(onPressed: onReconnect, style: target, child: const Text('Reconnect')),
            if (canRenew) OutlinedButton(onPressed: onRenew, style: target, child: const Text('Renew now')),
            if (row.canCheck && s.hasConnection) TextButton(onPressed: onCheck, style: target, child: const Text('Check now')),
          ]);
    final hasActions = busy || mustAct || canRenew || (row.canCheck && s.hasConnection);

    // One line of small print: where the date came from, when it last worked, and what is not settled.
    final meta = [
      ?signInSourceWords(row),
      if (s.lastConfirmedAt != null) 'Last worked ${signInDay(s.lastConfirmedAt!)}.',
      if (s.unverified) signInUnverifiedWords(row.network),
    ].join(' ');
    final words = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(signInRowSentence(row, now), style: context.text.bodySmall?.copyWith(color: nf.text, height: 1.35)),
      if (meta.isNotEmpty) ...[const SizedBox(height: 2), Text(meta, style: muted)],
    ]);

    return Padding(
      padding: const EdgeInsets.all(Space.lg),
      child: LayoutBuilder(builder: (context, box) {
        if (box.maxWidth < 620) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            identity,
            const SizedBox(height: Space.md),
            when,
            const SizedBox(height: Space.sm),
            words,
            if (hasActions) ...[const SizedBox(height: Space.sm), Align(alignment: Alignment.centerLeft, child: actions)],
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 4, child: identity),
            const SizedBox(width: Space.lg),
            Expanded(flex: 4, child: when),
            const SizedBox(width: Space.lg),
            Expanded(flex: 4, child: hasActions ? Align(alignment: Alignment.topRight, child: actions) : const SizedBox.shrink()),
          ]),
          const SizedBox(height: Space.sm),
          Padding(padding: const EdgeInsets.only(left: 36 + Space.md), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: words)),
        ]);
      }),
    );
  }

  static String _noDateTitle(SignInStatus s) {
    if (s.renewsItself) return 'No end date known';
    return switch (s.limit) {
      SignInLimit.none => 'No end date',
      SignInLimit.idleUnknown => 'No date can be known',
      SignInLimit.date => 'No date known yet',
      SignInLimit.undocumented => 'No published end date',
    };
  }
}
