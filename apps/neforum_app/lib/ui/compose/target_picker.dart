import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/neforum_logo.dart';
import '../../brand/platform_brand.dart';
import '../../state/artwork_targets.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/surfaces.dart';
import '../root.dart';
import '../router.dart';

/// Turns artwork mode on or off.
///
/// On: the post becomes artwork with the defaults from Settings > Artwork and
/// goes to art sites only: [accountId] (added to the art sites already
/// chosen), or else the art sites included in new posts. Off: an ordinary
/// post again, for the usual accounts.
void setArtworkMode(WidgetRef ref, {required bool on, String? accountId}) {
  final notifier = ref.read(composerProvider.notifier);
  final composer = ref.read(composerProvider);
  final accounts = ref.read(accountListProvider);
  final registry = ref.read(registryProvider);
  final settings = ref.read(settingsProvider);
  if (!on) {
    notifier.setArtwork(null);
    notifier.selectAccounts(defaultPostTargets(accounts, registry, settings));
    return;
  }
  final art = {for (final a in accounts) if (isArtAccount(registry, a)) a.id};
  final targets = accountId == null
      ? defaultPostTargets(accounts, registry, settings, artwork: true)
      : {if (composer.isArtwork) ...composer.selected.where(art.contains), accountId};
  if (!composer.isArtwork) notifier.setArtwork(newArtworkDetails(settings));
  notifier.selectAccounts(targets);
}

/// "Post to" row: one chip per connected account, and the Artwork switch
/// when an art site is connected.
class TargetPicker extends ConsumerWidget {
  const TargetPicker({super.key, this.scrollable = false});

  /// Single horizontally scrolling row (phones) instead of a wrap.
  final bool scrollable;

  /// The Artwork switch, for tests.
  static const artworkSwitchKey = ValueKey('target-picker-artwork');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final accounts = ref.watch(accountListProvider);
    final selected = ref.watch(composerProvider.select((c) => c.selected));
    final artwork = ref.watch(composerProvider.select((c) => c.artwork));
    final notifier = ref.read(composerProvider.notifier);
    final registry = ref.watch(registryProvider);

    if (accounts.isEmpty) {
      // Still reading the accounts: show nothing rather than "connect your first".
      if (!ref.watch(accountsLoadedProvider)) return const SizedBox(height: 56);
      return const _NoAccounts();
    }

    // Art sites only receive artwork. In artwork mode only they are shown;
    // otherwise choosing one turns artwork mode on.
    final art = {for (final a in accounts) if (isArtAccount(registry, a)) a.id};
    final artworkMode = artwork != null;
    final shown = artworkMode ? accounts.where((a) => art.contains(a.id)).toList() : accounts;

    // Lead with the platform; add the account name only when the user has
    // several accounts on the same platform.
    final perPlatform = <String, int>{};
    for (final a in shown) {
      perPlatform[a.platformId] = (perPlatform[a.platformId] ?? 0) + 1;
    }
    final chips = [
      for (final a in shown)
        AccountChip(
          account: a,
          platformName: registry.descriptor(a.platformId)?.name ?? a.platformId,
          showAccountName: (perPlatform[a.platformId] ?? 0) > 1,
          selected: selected.contains(a.id),
          artSite: !artworkMode && art.contains(a.id),
          onTap: !a.enabled
              ? null
              : !artworkMode && art.contains(a.id)
                  ? () => setArtworkMode(ref, on: true, accountId: a.id)
                  : () => notifier.toggleAccount(a.id),
        ),
    ];

    // The quick choices never mix art sites with the others.
    final choosable = shown.where((a) => a.enabled && (artworkMode || !art.contains(a.id)));
    final auto = choosable.where((a) => a.tier != PlatformTier.handoff).map((a) => a.id);
    // Wraps onto two lines when large text or a narrow phone leaves no room.
    final header = Wrap(crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.spaceBetween, runSpacing: Space.xs, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text('Post to', style: context.text.titleSmall?.copyWith(color: nf.textMuted)),
        const SizedBox(width: Space.sm),
        Text('${shown.where((a) => selected.contains(a.id)).length} of ${shown.length}', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
      ]),
      Row(mainAxisSize: MainAxisSize.min, children: [
        _QuickFilter('All', () => notifier.selectAccounts(choosable.map((a) => a.id))),
        _QuickFilter('Automatic only', () => notifier.selectAccounts(auto)),
        _QuickFilter('None', () => notifier.selectAccounts(const [])),
      ]),
    ]);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      header,
      // Also when the last art site was removed in artwork mode, to get out of it.
      if (art.isNotEmpty || artworkMode) _ArtworkSwitch(on: artworkMode, onChanged: (v) => setArtworkMode(ref, on: v)),
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
      if (artwork != null) ...[
        const SizedBox(height: Space.md),
        _ArtworkOptions(details: artwork, onChanged: notifier.setArtwork),
      ],
    ]);
  }
}

/// "Artwork" switch with what it means.
class _ArtworkSwitch extends StatelessWidget {
  const _ArtworkSwitch({required this.on, required this.onChanged});
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return MergeSemantics(
      child: Row(children: [
        Icon(Icons.brush_outlined, size: 16, color: on ? nf.accent : nf.textMuted),
        const SizedBox(width: Space.xs + 2),
        Text('Artwork', style: context.text.labelMedium?.copyWith(color: on ? nf.text : nf.textMuted)),
        Transform.scale(
          scale: 0.75,
          child: Switch(key: TargetPicker.artworkSwitchKey, value: on, onChanged: onChanged),
        ),
        Expanded(
          child: Text(
            on ? 'Art sites only receive artwork: add your image, a title and tags.' : 'Post artwork to your art sites.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.text.bodySmall?.copyWith(color: nf.textFaint),
          ),
        ),
      ]),
    );
  }
}

/// What the Adult rating does, here and in Settings > Artwork. Sites that
/// refuse explicit work report an error, and one error holds up the whole
/// post, so they have to be deselected.
const String adultRatingDescription = 'Explicit. Sites that do not allow it, such as Cara and Dribbble, stop the post '
    'until you deselect them.';

/// Rating, "Made with AI" and "Ask not to train AI" of an artwork post.
class _ArtworkOptions extends StatelessWidget {
  const _ArtworkOptions({required this.details, required this.onChanged});
  final ArtworkDetails details;
  final ValueChanged<ArtworkDetails> onChanged;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Wrap(spacing: Space.sm, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text('Rating', style: context.text.labelMedium?.copyWith(color: nf.textMuted)),
        const SizedBox(width: Space.sm),
        SegmentedButton<ArtworkMaturity>(
          segments: const [
            ButtonSegment(value: ArtworkMaturity.general, label: Text('General'), tooltip: 'Suitable for everyone'),
            ButtonSegment(value: ArtworkMaturity.mature, label: Text('Mature'), tooltip: 'Suggestive themes, mild nudity or violence'),
            ButtonSegment(value: ArtworkMaturity.adult, label: Text('Adult'), tooltip: adultRatingDescription),
          ],
          selected: {details.maturity},
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onSelectionChanged: (s) => onChanged(details.copyWith(maturity: s.single)),
        ),
      ]),
      FilterChip(
        label: const Text('Made with AI'),
        tooltip: 'The work was made with generative AI. Some art sites refuse such work.',
        selected: details.aiGenerated,
        visualDensity: VisualDensity.compact,
        onSelected: (v) => onChanged(details.copyWith(aiGenerated: v)),
      ),
      FilterChip(
        label: const Text('Ask not to train AI'),
        tooltip: 'Sets the NoAI option where a site has one.',
        selected: details.disallowAiTraining,
        visualDensity: VisualDensity.compact,
        onSelected: (v) => onChanged(details.copyWith(disallowAiTraining: v)),
      ),
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
    this.artSite = false,
  });

  final ConnectedAccount account;
  final String platformName;
  final bool selected;
  final VoidCallback? onTap;

  /// Append the account name (when several accounts share a platform).
  final bool showAccountName;

  /// An art site outside artwork mode: choosing it turns artwork mode on.
  final bool artSite;

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
              '${widget.artSite ? '\nArt site: choosing it turns on Artwork' : ''}'
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
                if (widget.artSite) ...[
                  Icon(Icons.brush_outlined, size: 13, color: nf.textFaint),
                  const SizedBox(width: Space.xs),
                ],
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
