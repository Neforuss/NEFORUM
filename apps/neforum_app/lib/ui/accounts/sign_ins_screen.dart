import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/providers.dart';
import '../../state/sign_in_board.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import '../router.dart';
import 'sign_in_parts.dart';

/// Which connection runs out next, and what to do about it.
///
/// A departure board: every dated row leads with how many days it has left, in
/// the largest type on the row, soonest at the top of its section, and the very
/// next one is lifted out into a card of its own with the one action it needs.
/// Reads the status file only; the keychain is asked only for a platform that
/// can answer ([PlatformAdapter.readsSignIn]) at most once a day, or on a tap.
class SignInsScreen extends ConsumerStatefulWidget {
  const SignInsScreen({super.key});

  @override
  ConsumerState<SignInsScreen> createState() => _SignInsScreenState();
}

class _SignInsScreenState extends ConsumerState<SignInsScreen> {
  /// Accounts with a renewal or a check under way.
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_readDue()));
  }

  /// A sync may have brought accounts with no status yet; platforms that can
  /// say their own date are asked, at most once a day each.
  Future<void> _readDue() async {
    final s = ref.read(servicesProvider);
    if (s.demo) return;
    try {
      await s.signInStatus.seedMissing();
      final accounts = await s.accounts.all();
      for (final a in accounts) {
        if (!mounted) return;
        if (s.registry.byId(a.platformId)?.readsSignIn(a) ?? false) await s.signInStatus.readFromServer(a, s.connectContext());
      }
    } on Object catch (e) {
      debugPrint('Could not read the sign-ins (${e.runtimeType})');
    }
  }

  Future<void> _during(String accountId, Future<void> Function() work) async {
    if (_busy.contains(accountId)) return;
    setState(() => _busy.add(accountId));
    try {
      await work();
    } finally {
      if (mounted) setState(() => _busy.remove(accountId));
    }
  }

  /// Never shows the error's own text: it can quote a server's answer.
  Future<void> _renew(SignInRow row) => _during(row.account.id, () async {
        final s = ref.read(servicesProvider);
        if (s.demo) {
          showToast(context, 'Demo workspace: nothing is renewed for real.', icon: Icons.science_rounded);
          return;
        }
        final out = await s.publisher().renewSignInNow(row.account.id);
        if (!mounted) return;
        if (out.renewed) {
          showToast(context, '${row.network} renewed.', icon: Icons.check_rounded);
        } else if (out.error == null) {
          showToast(context, '${row.network} has nothing to renew right now.', icon: Icons.info_outline_rounded);
        } else if (out.error!.kind == PublishErrorKind.auth) {
          showToast(context, '${row.network} refused the renewal. Sign in again.', icon: Icons.error_outline_rounded);
        } else {
          showToast(context, 'Could not reach ${row.network}. Nothing changed. Try again later.', icon: Icons.error_outline_rounded);
        }
      });

  Future<void> _check(SignInRow row) => _during(row.account.id, () async {
        final s = ref.read(servicesProvider);
        if (s.demo) {
          showToast(context, 'Demo workspace: nothing is checked for real.', icon: Icons.science_rounded);
          return;
        }
        final before = row.status?.serverRead?.readAt;
        final after = await s.signInStatus.readFromServer(row.account, s.connectContext(), force: true);
        if (!mounted) return;
        final read = after?.serverRead;
        if (read == null || read.readAt == before) {
          showToast(context, '${row.network} gave no answer. Nothing changed.', icon: Icons.info_outline_rounded);
        } else if (!read.isValid) {
          showToast(context, '${row.network} says this sign-in no longer works.', icon: Icons.error_outline_rounded);
        } else {
          showToast(context, after!.expiresAt == null ? '${row.network} gives no end date.' : '${row.network} says: ends ${signInDateWords(after)}.', icon: Icons.check_rounded);
        }
      });

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(signInBoardProvider);
    final now = ref.watch(signInClockProvider)();
    final next = board.next;
    final dated = board.mustReconnect.length + board.renewsWhenPosting.length;
    void reconnect(SignInRow r) => reconnectAccount(context, r.account);

    Widget tile(SignInRow r) => _Row(row: r, now: now, busy: _busy.contains(r.account.id), onRenew: () => _renew(r), onCheck: () => _check(r), onReconnect: () => reconnect(r));

    return PageBody(maxWidth: 1040, children: [
      PageHeader(
        eyebrow: 'Accounts',
        title: 'Sign-ins',
        subtitle: board.all.isEmpty
            ? 'When you connect a network, its date shows here.'
            : '$dated with a date · ${board.noEndDate.length} with no end date known',
        actions: [
          OutlinedButton.icon(onPressed: () => context.go(AppSection.accounts.path), icon: const Icon(Icons.hub_outlined, size: 18), label: const Text('All accounts')),
        ],
      ),
      const SizedBox(height: Space.xl),
      if (board.all.isEmpty)
        EmptyState(
          title: 'Nothing connected yet',
          body: 'Connect a network and this page says when its sign-in runs out.',
          action: PrimaryAction(label: 'Add an account', icon: Icons.add_rounded, onPressed: () => context.go('${AppSection.accounts.path}/add')),
        )
      else ...[
        _NextUp(board: board, now: now, busy: next != null && _busy.contains(next.account.id), onRenew: next == null ? null : () => _renew(next), onReconnect: next == null ? null : () => reconnect(next)),
        const SizedBox(height: Space.x3),
        if (board.mustReconnect.isNotEmpty)
          _Section(
            title: 'You must reconnect',
            subtitle: 'Nothing can renew these. Soonest first.',
            icon: Icons.link_off_rounded,
            children: [for (final r in board.mustReconnect) tile(r)],
          ),
        if (board.renewsWhenPosting.isNotEmpty)
          _Section(
            title: 'Renews when NEFORUM posts',
            subtitle: 'NEFORUM renews these only when it posts, so one left unused runs out. Soonest first.',
            icon: Icons.autorenew_rounded,
            children: [for (final r in board.renewsWhenPosting) tile(r)],
          ),
        if (board.noEndDate.isNotEmpty || board.noConnection.isNotEmpty)
          _Section(
            title: 'No end date known',
            subtitle: 'No date to count down to. The vendor or your server can still end these.',
            icon: Icons.all_inclusive_rounded,
            children: [
              for (final r in board.noEndDate) tile(r),
              if (board.noConnection.isNotEmpty) _HandOffRow(rows: board.noConnection),
            ],
          ),
      ],
    ]);
  }
}

/// The largest thing on the page: the very next one to run out, and the one
/// thing to do about it. On a wide window, how the rest are spread over time
/// sits beside it.
class _NextUp extends StatelessWidget {
  const _NextUp({required this.board, required this.now, required this.busy, required this.onRenew, required this.onReconnect});
  final SignInBoard board;
  final DateTime now;
  final bool busy;
  final VoidCallback? onRenew;
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final card = _nextCard(context);
    if (context.isCompact) return card;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(flex: 3, child: card),
        const SizedBox(width: Space.lg),
        Expanded(flex: 2, child: _Spread(board: board, now: now)),
      ]),
    );
  }

  Widget _nextCard(BuildContext context) {
    final nf = context.nf;
    final next = board.next;
    if (next == null) {
      return NfCard(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('NEXT TO RUN OUT', style: context.text.labelSmall?.copyWith(color: nf.textMuted, letterSpacing: 1.2)),
          const SizedBox(height: Space.sm),
          Text('No date to watch', style: context.text.headlineSmall),
          const SizedBox(height: Space.xs),
          Text('Nothing connected here has a known end date. If a post is ever refused, its account shows up here.', style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
        ]),
      );
    }
    final tone = signInTone(next.urgency);
    final must = next.group == SignInGroup.mustReconnect;
    final s = next.status!;
    final action = must || !next.canRenew
        ? PrimaryAction(label: 'Reconnect ${next.network}', icon: Icons.login_rounded, onPressed: onReconnect, compact: true)
        : PrimaryAction(label: 'Renew ${next.network} now', icon: Icons.autorenew_rounded, onPressed: busy ? null : onRenew, loading: busy, compact: true);
    return Container(
      key: const ValueKey('sign-in-next'),
      padding: const EdgeInsets.all(Space.xl),
      decoration: BoxDecoration(
        color: tone == Tone.neutral ? nf.surface : tone.bg(nf),
        borderRadius: Radii.rLg,
        border: Border.all(color: tone == Tone.neutral ? nf.border : tone.fg(nf).withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('NEXT TO RUN OUT', style: context.text.labelSmall?.copyWith(color: tone == Tone.neutral ? nf.textMuted : tone.fg(nf), letterSpacing: 1.2)),
        const SizedBox(height: Space.md),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          _Days(row: next, now: now, large: true),
          const SizedBox(width: Space.lg),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                AccountAvatar(next.account, size: 24),
                const SizedBox(width: Space.sm),
                Expanded(child: Text(next.network, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleLarge)),
              ]),
              if (next.account.handle != null)
                Text(next.account.handle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
              const SizedBox(height: Space.xs),
              Text(next.refused ? 'Refused by the network' : (s.expiresAt == null ? 'No date' : _endLine(s)), style: context.text.bodyMedium?.copyWith(color: nf.text, fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
        const SizedBox(height: Space.md),
        if (next.whatToDo != null) Text(next.whatToDo!, style: context.text.bodyMedium?.copyWith(color: nf.text)),
        if (next.postsAfterEnd > 0) ...[
          const SizedBox(height: Space.xs),
          Text(_postsLine(next.postsAfterEnd), style: context.text.bodySmall?.copyWith(color: nf.text, fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: Space.md),
        action,
      ]),
    );
  }

  String _endLine(SignInStatus s) {
    final words = signInDateWords(s);
    if (s.hasEnded(now)) return s.about ? 'Probably ended, $words' : (s.earlyRevocationPossible ? 'Ended by $words' : 'Ended on $words');
    return 'Ends $words';
  }
}

String _postsLine(int n) => n == 1 ? '1 scheduled post goes out after this date.' : '$n scheduled posts go out after this date.';

/// How the dated ones are spread over time: one line per span, with the marks
/// of the networks in it.
class _Spread extends StatelessWidget {
  const _Spread({required this.board, required this.now});
  final SignInBoard board;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final rows = [...board.mustReconnect, ...board.renewsWhenPosting];
    List<String> span(bool Function(SignInRow) test) => [for (final r in rows.where(test)) r.account.platformId];
    bool over(SignInRow r) => r.urgency == SignInUrgency.now;
    final spans = <(String, List<String>, Tone)>[
      ('Ended or refused', span(over), Tone.danger),
      ('Within 7 days', span((r) => !over(r) && (r.daysLeft ?? 999) <= 7), Tone.danger),
      ('Within 14 days', span((r) => !over(r) && (r.daysLeft ?? 999) > 7 && r.daysLeft! <= 14), Tone.warning),
      ('Within 90 days', span((r) => !over(r) && (r.daysLeft ?? 999) > 14 && r.daysLeft! <= 90), Tone.neutral),
      ('Later', span((r) => !over(r) && (r.daysLeft ?? 0) > 90), Tone.neutral),
      ('No end date known', [for (final r in board.noEndDate) r.account.platformId], Tone.neutral),
    ];
    return NfCard(
      padding: const EdgeInsets.all(Space.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('WHEN THEY RUN OUT', style: context.text.labelSmall?.copyWith(color: nf.textMuted, letterSpacing: 1.2)),
        const SizedBox(height: Space.md),
        for (final (label, ids, tone) in spans)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xxs + 1),
            child: Row(children: [
              SizedBox(
                width: 22,
                child: Text('${ids.length}', style: monoStyle(context, size: 13, color: ids.isEmpty ? nf.textFaint : (tone == Tone.neutral ? nf.text : tone.fg(nf)), weight: FontWeight.w700)),
              ),
              Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: ids.isEmpty ? nf.textFaint : nf.text))),
              if (ids.isNotEmpty) PlatformStack(ids, size: 18, max: 5),
            ]),
          ),
      ]),
    );
  }
}

/// The days left, as the largest thing on a row: the word for the day, or the
/// count over its unit, so the state is in the words and not only the colour.
class _Days extends StatelessWidget {
  const _Days({required this.row, required this.now, this.large = false});
  final SignInRow row;
  final DateTime now;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final tone = signInTone(row.urgency);
    final left = row.daysLeft;
    final color = tone == Tone.neutral ? nf.text : tone.fg(nf);
    final (big, small) = switch (left) {
      _ when row.refused => ('!', 'refused'),
      _ when row.urgency == SignInUrgency.now => ('0', 'ended'),
      null => ('–', 'no date'),
      <= 0 => ('0', 'today'),
      1 => ('1', 'day'),
      < 100 => ('$left', 'days'),
      _ => ('${(left / 30.44).round()}', 'months'),
    };
    return Semantics(
      label: left == null ? small : '$big $small',
      excludeSemantics: true,
      child: SizedBox(
        width: large ? 76 : 54,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(big, maxLines: 1, style: (large ? context.text.displaySmall : context.text.headlineSmall)?.copyWith(color: color, height: 1)),
          Text(small, maxLines: 1, overflow: TextOverflow.fade, softWrap: false, style: context.text.labelSmall?.copyWith(color: tone == Tone.neutral ? nf.textMuted : color)),
        ]),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.subtitle, required this.icon, required this.children});
  final String title;
  final String subtitle;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionHeader(title, subtitle: subtitle, icon: icon),
        const SizedBox(height: Space.md),
        NfCard(
          padding: EdgeInsets.zero,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, color: nf.border),
              children[i],
            ],
          ]),
        ),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row, required this.now, required this.busy, required this.onRenew, required this.onCheck, required this.onReconnect});
  final SignInRow row;
  final DateTime now;
  final bool busy;
  final VoidCallback onRenew;
  final VoidCallback onCheck;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final s = row.status;
    final must = row.group == SignInGroup.mustReconnect;
    final last = s?.lastConfirmedAt;
    final idle = s?.limit == SignInLimit.idleUnknown;

    final actions = <Widget>[
      if (must) FilledButton(onPressed: onReconnect, style: _tall, child: const Text('Reconnect')),
      if (row.canRenew) OutlinedButton(onPressed: busy ? null : onRenew, style: _tall, child: Text(busy ? 'Renewing' : 'Renew now')),
      if (row.canCheck) TextButton(onPressed: busy ? null : onCheck, style: _tall, child: const Text('Check now')),
    ];

    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(row.network, style: context.text.titleSmall),
        if (row.account.handle != null) Text(row.account.handle!, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
      ]),
      const SizedBox(height: 2),
      if (row.refused) ...[
        Text(row.whatToDo!, style: context.text.bodySmall?.copyWith(color: nf.text)),
        const SizedBox(height: 2),
      ],
      Text(signInRowText(row, now), style: context.text.bodySmall?.copyWith(color: nf.textMuted, height: 1.35)),
      if (row.postsAfterEnd > 0) ...[
        const SizedBox(height: 2),
        Text(_postsLine(row.postsAfterEnd), style: context.text.bodySmall?.copyWith(color: nf.text, fontWeight: FontWeight.w600)),
      ],
      if (idle) ...[
        const SizedBox(height: 2),
        Text(last == null ? 'Not used from this device yet.' : 'Last worked ${signInDay(last)}.', style: context.text.bodySmall?.copyWith(color: nf.text)),
      ],
      if (s?.unverified ?? false) ...[
        const SizedBox(height: 2),
        Text('Unverified: the vendor publishes no firm rule.', style: context.text.bodySmall?.copyWith(color: nf.textMuted, fontStyle: FontStyle.italic)),
      ],
    ]);

    final compact = context.isCompact;
    return Padding(
      key: ValueKey('sign-in-row-${row.account.id}'),
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Days(row: row, now: now),
          const SizedBox(width: Space.sm),
          if (!compact) ...[AccountAvatar(row.account, size: 32), const SizedBox(width: Space.md)],
          Expanded(child: text),
          if (!compact && actions.isNotEmpty) ...[
            const SizedBox(width: Space.md),
            Wrap(spacing: Space.sm, children: actions),
          ],
        ]),
        if (compact && actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm, left: 54 + Space.sm),
            child: Wrap(spacing: Space.sm, runSpacing: Space.xs, children: actions),
          ),
      ]),
    );
  }

  static final ButtonStyle _tall = ButtonStyle(minimumSize: WidgetStateProperty.all(const Size(48, 48)), tapTargetSize: MaterialTapTargetSize.padded);
}

/// Accounts with no sign-in: named, so none goes unlisted, and said once.
class _HandOffRow extends StatelessWidget {
  const _HandOffRow({required this.rows});
  final List<SignInRow> rows;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Padding(
      padding: const EdgeInsets.all(Space.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Nothing to run out', style: context.text.titleSmall),
        const SizedBox(height: 2),
        Text('NEFORUM holds no sign-in for these: you post in the app or website, where you are signed in.', style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
        const SizedBox(height: Space.sm),
        Wrap(spacing: Space.sm, runSpacing: Space.xs, children: [
          for (final r in rows)
            Row(mainAxisSize: MainAxisSize.min, children: [
              AccountAvatar(r.account, size: 20, showBadge: false),
              const SizedBox(width: Space.xs),
              Text(r.network, style: context.text.bodySmall?.copyWith(color: nf.text)),
            ]),
        ]),
      ]),
    );
  }
}
