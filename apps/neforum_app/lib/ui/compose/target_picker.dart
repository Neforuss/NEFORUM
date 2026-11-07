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
import 'account_selection_grid.dart';

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

/// "Post to": every connected account, as a chip or, on phones, as a cell of
/// the [AccountSelectionGrid], and the Artwork switch when an art site is
/// connected.
class TargetPicker extends ConsumerWidget {
  const TargetPicker({super.key, this.grid = false, this.keyboardOpen = false});

  /// Phones: a grid of names that folds to a summary, instead of chips.
  final bool grid;

  /// The on-screen keyboard is showing: the grid folds to leave room for the
  /// text, unless the user opens it again.
  final bool keyboardOpen;

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
    VoidCallback? onTapOf(ConnectedAccount a) => !a.enabled
        ? null
        : !artworkMode && art.contains(a.id)
            ? () => setArtworkMode(ref, on: true, accountId: a.id)
            : () => notifier.toggleAccount(a.id);

    // The quick choices never mix art sites with the others.
    final choosable = shown.where((a) => a.enabled && (artworkMode || !art.contains(a.id)));
    final auto = choosable.where((a) => a.tier != PlatformTier.handoff).map((a) => a.id);

    if (grid) {
      final ordered = orderedForAccountGrid(shown, (a) => !artworkMode && art.contains(a.id));
      final handles = <String, String>{
        for (final platformId in perPlatform.keys) ...accountGridHandles(ordered.where((a) => a.platformId == platformId).toList()),
      };
      return _AccountGridSection(
        keyboardOpen: keyboardOpen,
        entries: [
          for (final a in ordered)
            AccountEntry(
              account: a,
              platformName: registry.descriptor(a.platformId)?.name ?? a.platformId,
              label: registry.descriptor(a.platformId)?.compactName ?? a.platformId,
              handle: handles[a.id],
              selected: selected.contains(a.id),
              artSite: !artworkMode && art.contains(a.id),
              onTap: onTapOf(a),
            ),
        ],
        selected: selected,
        onSelect: notifier.selectAccounts,
        artworkSwitch: art.isNotEmpty || artworkMode ? _ArtworkSwitch(on: artworkMode, full: true, onChanged: (v) => setArtworkMode(ref, on: v)) : null,
        artworkOptions: artwork == null ? null : _ArtworkOptions(details: artwork, onChanged: notifier.setArtwork, touch: true),
      );
    }

    final chips = [
      for (final a in shown)
        AccountChip(
          account: a,
          platformName: registry.descriptor(a.platformId)?.name ?? a.platformId,
          showAccountName: (perPlatform[a.platformId] ?? 0) > 1,
          selected: selected.contains(a.id),
          artSite: !artworkMode && art.contains(a.id),
          onTap: onTapOf(a),
        ),
    ];

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
      Wrap(spacing: Space.sm, runSpacing: Space.sm, children: chips),
      if (artwork != null) ...[
        const SizedBox(height: Space.md),
        _ArtworkOptions(details: artwork, onChanged: notifier.setArtwork),
      ],
    ]);
  }
}

/// The phone form of the picker: a header with the fold control and the quick
/// choices, then the grid or its summary.
///
/// Open or folded is the user's choice, kept on this device. While the
/// keyboard is showing the grid folds whatever that choice is, and the control
/// opens it for as long as the keyboard stays. With the grid folded over the
/// keyboard only the summary stays: the artwork controls step aside as well.
class _AccountGridSection extends ConsumerStatefulWidget {
  const _AccountGridSection({
    required this.entries,
    required this.keyboardOpen,
    required this.selected,
    required this.onSelect,
    required this.artworkSwitch,
    required this.artworkOptions,
  });

  final List<AccountEntry> entries;
  final bool keyboardOpen;

  /// Everything chosen for the post, shown here or not.
  final Set<String> selected;
  final ValueChanged<Iterable<String>> onSelect;
  final Widget? artworkSwitch;
  final Widget? artworkOptions;

  @override
  ConsumerState<_AccountGridSection> createState() => _AccountGridSectionState();
}

class _AccountGridSectionState extends ConsumerState<_AccountGridSection> {
  /// Opened by hand while the keyboard is showing.
  bool _openOverKeyboard = false;

  final _filter = TextEditingController();
  final _filterFocus = FocusNode();

  /// Shared by the fold control's two forms, so it keeps the focus across them.
  final _foldFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Typing in the filter opens the keyboard, which must not fold the field
    // away; moving on to the text field then folds as usual.
    _filterFocus.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(_AccountGridSection old) {
    super.didUpdateWidget(old);
    if (old.keyboardOpen != widget.keyboardOpen) _openOverKeyboard = false;
  }

  @override
  void dispose() {
    _filter.dispose();
    _filterFocus.dispose();
    _foldFocus.dispose();
    super.dispose();
  }

  void _toggle(bool folded) {
    if (widget.keyboardOpen && !_filterFocus.hasFocus) {
      setState(() => _openOverKeyboard = folded);
    } else {
      // Folding takes the filter away, and the keyboard goes with it: what
      // stands then is the user's own choice. Set even when that choice does
      // not change: it may have been opened by hand over the keyboard.
      setState(() => _openOverKeyboard = false);
      ref.read(settingsProvider.notifier).update((s) => s.copyWith(targetPickerFolded: !folded));
    }
  }

  /// Fades, but takes its new height within the frame. The text field scrolls
  /// its caret into view right after the frame in which the keyboard opens: a
  /// height still changing then would move the caret out of view again.
  Widget _fade(BuildContext context, Widget child) => AnimatedSwitcher(
        duration: context.motion(Motion.fast),
        switchInCurve: Motion.standard,
        layoutBuilder: (current, _) => current ?? const SizedBox.shrink(),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final userFolded = ref.watch(settingsProvider.select((s) => s.targetPickerFolded));
    final bool folded;
    if (!widget.keyboardOpen) {
      folded = userFolded;
    } else if (_filterFocus.hasFocus) {
      folded = userFolded && !_openOverKeyboard;
    } else {
      folded = !_openOverKeyboard;
    }
    final entries = widget.entries;
    final count = accountCountLabel(entries);
    final tight = accountGridIsTight(context);

    // Past [kTargetFilterThreshold] the grid can be narrowed down. The count
    // and the summary stay about all the accounts.
    final filterable = entries.length > kTargetFilterThreshold;
    final query = filterable ? _filter.text.trim().toLowerCase() : '';
    final filtering = query.isNotEmpty;
    final shown = filtering ? entries.where((e) => e.matches(query)).toList() : entries;

    // The quick choices never mix art sites with the others. While filtering
    // they act on the matches and leave the other accounts as they are.
    final choosable = shown.where((e) => e.counted && !e.disabled);
    void pick(Iterable<String> ids) {
      final matched = {for (final e in shown) if (e.counted) e.account.id};
      widget.onSelect(filtering ? {...widget.selected.difference(matched), ...ids} : ids);
    }

    // Wraps onto two lines when the choices leave no room.
    final openHeader = Wrap(key: const ValueKey('target-picker-open'), crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.spaceBetween, children: [
      InkWell(
        key: kTargetFoldKey,
        focusNode: _foldFocus,
        onTap: () => _toggle(false),
        child: Semantics(
          button: true,
          expanded: true,
          excludeSemantics: true,
          label: '${count == null ? 'Post to' : 'Post to, $count'}. Fold the accounts',
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: kAccountCellMinHeight, minHeight: kAccountCellMinHeight),
            child: AccountCountLabel(entries: entries, folded: false, showTitle: !tight),
          ),
        ),
      ),
      Row(mainAxisSize: MainAxisSize.min, children: [
        _QuickFilter('All', () => pick(choosable.map((e) => e.account.id)), tight: tight),
        _QuickFilter('Automatic only', () => pick(choosable.where((e) => e.account.tier != PlatformTier.handoff).map((e) => e.account.id)), tight: tight),
        // Its label starts at its own edge when tight.
        if (tight) const SizedBox(width: Space.xs),
        _QuickFilter('None', () => pick(const []), tight: tight),
      ]),
    ]);

    final grid = Column(key: const ValueKey('target-picker-grid'), crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (filterable)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.sm),
          child: _TargetFilter(controller: _filter, focusNode: _filterFocus, matching: filtering ? shown.length : null, onChanged: _rebuild),
        ),
      if (filtering && shown.isEmpty)
        Text('No account matches.', style: context.text.bodySmall?.copyWith(color: context.nf.textMuted))
      else
        AccountSelectionGrid(entries: shown),
    ]);

    final extras = !(folded && widget.keyboardOpen);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      _fade(
        context,
        folded
            ? AccountSelectionSummary(
                key: const ValueKey('target-picker-summary'),
                entries: entries,
                focusNode: _foldFocus,
                overKeyboard: widget.keyboardOpen,
                onOpen: () => _toggle(true),
              )
            : openHeader,
      ),
      if (extras) ?widget.artworkSwitch,
      _fade(context, folded ? const SizedBox.shrink(key: ValueKey('target-picker-no-grid')) : grid),
      if (extras && widget.artworkOptions != null) ...[
        const SizedBox(height: Space.md),
        widget.artworkOptions!,
      ],
    ]);
  }
}

/// The field that narrows the grid down, past [kTargetFilterThreshold] accounts.
class _TargetFilter extends StatelessWidget {
  const _TargetFilter({required this.controller, required this.focusNode, required this.matching, required this.onChanged});
  final TextEditingController controller;
  final FocusNode focusNode;

  /// How many accounts match, while there is something to match.
  final int? matching;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TextField(
        key: kTargetFilterKey,
        controller: controller,
        focusNode: focusNode,
        onChanged: (_) => onChanged(),
        decoration: InputDecoration(
          hintText: 'Find an account',
          prefixIcon: const Icon(Icons.search_rounded, size: 18),
          helperText: matching == null ? null : 'All, Automatic only and None act on the $matching shown',
          suffixIcon: matching == null
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () {
                    controller.clear();
                    onChanged();
                  },
                ),
        ),
      );
}

/// "Artwork" switch with what it means.
class _ArtworkSwitch extends StatelessWidget {
  const _ArtworkSwitch({required this.on, required this.onChanged, this.full = false});
  final bool on;
  final ValueChanged<bool> onChanged;

  /// Phones: the switch at its full size, a whole touch target.
  final bool full;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final control = Switch(key: TargetPicker.artworkSwitchKey, value: on, onChanged: onChanged);
    return MergeSemantics(
      child: Row(children: [
        Icon(Icons.brush_outlined, size: 16, color: on ? nf.accent : nf.textMuted),
        const SizedBox(width: Space.xs + 2),
        Text('Artwork', style: context.text.labelMedium?.copyWith(color: on ? nf.text : nf.textMuted)),
        if (full) ...[
          const SizedBox(width: Space.xs),
          control,
          const SizedBox(width: Space.xs),
        ] else
          Transform.scale(scale: 0.75, child: control),
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
  const _ArtworkOptions({required this.details, required this.onChanged, this.touch = false});
  final ArtworkDetails details;
  final ValueChanged<ArtworkDetails> onChanged;

  /// Phones: each control a whole touch target.
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final targetSize = touch ? MaterialTapTargetSize.padded : null;
    // Compact density would take 8 px off the padded target.
    final density = touch ? VisualDensity.standard : VisualDensity.compact;
    return Wrap(spacing: Space.sm, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text('Rating', style: context.text.labelMedium?.copyWith(color: nf.textMuted)),
        const SizedBox(width: Space.sm),
        Flexible(
          child: SegmentedButton<ArtworkMaturity>(
            segments: const [
              ButtonSegment(value: ArtworkMaturity.general, label: Text('General'), tooltip: 'Suitable for everyone'),
              ButtonSegment(value: ArtworkMaturity.mature, label: Text('Mature'), tooltip: 'Suggestive themes, mild nudity or violence'),
              ButtonSegment(value: ArtworkMaturity.adult, label: Text('Adult'), tooltip: adultRatingDescription),
            ],
            selected: {details.maturity},
            showSelectedIcon: false,
            style: ButtonStyle(visualDensity: density, tapTargetSize: targetSize ?? MaterialTapTargetSize.shrinkWrap),
            onSelectionChanged: (s) => onChanged(details.copyWith(maturity: s.single)),
          ),
        ),
      ]),
      FilterChip(
        label: const Text('Made with AI'),
        tooltip: 'The work was made with generative AI. Some art sites refuse such work.',
        selected: details.aiGenerated,
        visualDensity: density,
        materialTapTargetSize: targetSize,
        onSelected: (v) => onChanged(details.copyWith(aiGenerated: v)),
      ),
      FilterChip(
        label: const Text('Ask not to train AI'),
        tooltip: 'Sets the NoAI option where a site has one.',
        selected: details.disallowAiTraining,
        visualDensity: density,
        materialTapTargetSize: targetSize,
        onSelected: (v) => onChanged(details.copyWith(disallowAiTraining: v)),
      ),
    ]);
  }
}

class _QuickFilter extends StatelessWidget {
  const _QuickFilter(this.label, this.onTap, {this.tight = false});
  final String label;
  final VoidCallback onTap;

  /// No room to spare beside the label. The touch target stays whole.
  final bool tight;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: context.nf.textMuted,
          padding: EdgeInsets.symmetric(horizontal: tight ? 0 : Space.sm, vertical: Space.xs),
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
