import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/neforum_logo.dart';
import '../../brand/platform_brand.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/surfaces.dart';
import '../root.dart';
import '../router.dart';

/// "Post to" row: one chip per connected account.
class TargetPicker extends ConsumerWidget {
  const TargetPicker({super.key, this.scrollable = false});

  /// Single horizontally scrolling row (phones) instead of a wrap.
  final bool scrollable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final accounts = ref.watch(accountListProvider);
    final selected = ref.watch(composerProvider.select((c) => c.selected));
    final notifier = ref.read(composerProvider.notifier);
    final registry = ref.watch(registryProvider);

    if (accounts.isEmpty) return const _NoAccounts();

    // Lead with the platform; add the account name only when the user has
    // several accounts on the same platform.
    final perPlatform = <String, int>{};
    for (final a in accounts) {
      perPlatform[a.platformId] = (perPlatform[a.platformId] ?? 0) + 1;
    }
    final chips = [
      for (final a in accounts)
        AccountChip(
          account: a,
          platformName: registry.descriptor(a.platformId)?.name ?? a.platformId,
          showAccountName: (perPlatform[a.platformId] ?? 0) > 1,
          selected: selected.contains(a.id),
          onTap: a.enabled ? () => notifier.toggleAccount(a.id) : null,
        ),
    ];

    final auto = accounts.where((a) => a.enabled && a.tier != PlatformTier.handoff).map((a) => a.id);
    final header = Row(children: [
      Text('Post to', style: context.text.titleSmall?.copyWith(color: nf.textMuted)),
      const SizedBox(width: Space.sm),
      Text('${selected.length} of ${accounts.length}', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
      const Spacer(),
      _QuickFilter('All', () => notifier.selectAccounts(accounts.where((a) => a.enabled).map((a) => a.id))),
      _QuickFilter('Automatic only', () => notifier.selectAccounts(auto)),
      _QuickFilter('None', () => notifier.selectAccounts(const [])),
    ]);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      header,
      const SizedBox(height: Space.sm + 2),
      if (scrollable)
        SizedBox(
          height: 42,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: chips.length,
            separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
            itemBuilder: (_, i) => chips[i],
          ),
        )
      else
        Wrap(spacing: Space.sm, runSpacing: Space.sm, children: chips),
    ]);
  }
}

class _QuickFilter extends StatelessWidget {
  const _QuickFilter(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: context.nf.textMuted,
          padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
          minimumSize: const Size(0, 30),
          textStyle: context.text.labelMedium,
        ),
        child: Text(label),
      );
}

/// Selectable account chip: avatar, name, tier glyph.
class AccountChip extends StatefulWidget {
  const AccountChip({
    super.key,
    required this.account,
    required this.platformName,
    required this.selected,
    required this.onTap,
    this.showAccountName = false,
  });

  final ConnectedAccount account;
  final String platformName;
  final bool selected;
  final VoidCallback? onTap;

  /// Append the account name (when several accounts share a platform).
  final bool showAccountName;

  @override
  State<AccountChip> createState() => _AccountChipState();
}

class _AccountChipState extends State<AccountChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final a = widget.account;
    final sel = widget.selected;
    final enabled = widget.onTap != null;
    final tone = tierTone(a.tier);
    return Tooltip(
      message: enabled
          ? '${widget.platformName} · ${a.handle ?? a.displayName}\n${tierShortLabel(a.tier)}: ${tierDescription(a.tier)}'
          : '${widget.platformName} is disabled in Accounts',
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Semantics(
            button: true,
            selected: sel,
            label: '${widget.platformName} ${a.displayName}',
            child: AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.standard,
              height: 40,
              padding: const EdgeInsets.only(left: 5, right: Space.md),
              decoration: BoxDecoration(
                color: sel ? nf.accentSoft : (_hover && enabled ? nf.surfaceHover : nf.surface),
                borderRadius: Radii.rPill,
                border: Border.all(color: sel ? nf.accent : (_hover ? nf.borderStrong : nf.border), width: sel ? 1.5 : 1),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                // Profile photo when known; otherwise the platform's mark is
                // clearer than initials (the label already names it).
                if (a.avatarUrl != null && a.avatarUrl!.startsWith('http'))
                  AccountAvatar(a, size: 28, dimmed: !enabled || !sel)
                else
                  PlatformTile(a.platformId, size: 28, circle: true, dimmed: !enabled || !sel),
                const SizedBox(width: Space.sm),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 190),
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: widget.platformName),
                      if (widget.showAccountName)
                        TextSpan(text: ' · ${a.handle ?? a.displayName}', style: TextStyle(color: nf.textFaint, fontWeight: FontWeight.w500)),
                    ]),
                    overflow: TextOverflow.ellipsis,
                    style: context.text.labelMedium?.copyWith(color: sel ? nf.text : nf.textMuted),
                  ),
                ),
                const SizedBox(width: Space.xs + 2),
                Icon(tierIcon(a.tier), size: 13, color: sel ? tone.fg(nf) : nf.textFaint),
                AnimatedSize(
                  duration: Motion.fast,
                  child: sel
                      ? Padding(
                          padding: const EdgeInsets.only(left: Space.xs + 2),
                          child: Icon(Icons.check_circle_rounded, size: 16, color: nf.accent),
                        )
                      : const SizedBox.shrink(),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _NoAccounts extends ConsumerWidget {
  const _NoAccounts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final demo = ref.watch(isDemoProvider);
    return NfCard(
      padding: const EdgeInsets.all(Space.xl),
      child: Row(children: [
        const NeforumMark(size: 44),
        const SizedBox(width: Space.lg),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Connect your first network', style: context.text.titleLarge),
            const SizedBox(height: 2),
            Text(
              'Mastodon and Bluesky take a minute. Instagram and TikTok work with any account through hand-off.',
              style: context.text.bodySmall?.copyWith(color: nf.textMuted),
            ),
            const SizedBox(height: Space.md),
            Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
              PrimaryAction(
                label: 'Add an account',
                icon: Icons.add_rounded,
                compact: true,
                onPressed: () => context.go('${AppSection.accounts.path}/add'),
              ),
              if (!demo)
                OutlinedButton(
                  onPressed: () => NeforumRoot.of(context).setDemo(true),
                  child: const Text('Try the demo workspace'),
                ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
