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
import 'account_tile_grid.dart';

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

/// The filter field over the account tiles appears above this many accounts,
/// when they no longer fit 4 rows on a 360 wide phone.
const int kTargetFilterThreshold = 24;

/// "Post to": the accounts to post to, and the Artwork switch when an art
/// site is connected. One chip per account in a wrap on wider windows,
/// [AccountTileGrid] on phones.
class TargetPicker extends ConsumerStatefulWidget {
  const TargetPicker({super.key, this.tileGrid = false, this.keyboardOpen = false});

  /// Phones: [AccountTileGrid], foldable into [AccountFoldSummary], instead of
  /// the chips.
  final bool tileGrid;

  /// The on-screen keyboard is showing: the tiles fold by themselves to leave
  /// the text field room, until the fold button says otherwise.
  final bool keyboardOpen;

  /// The Artwork switch, for tests.
  static const artworkSwitchKey = ValueKey('target-picker-artwork');

  /// The button that folds and unfolds the tiles, for tests.
  static const foldKey = ValueKey('target-picker-fold');

  /// The filter field, for tests.
  static const filterKey = ValueKey('target-picker-filter');

  @override
  ConsumerState<TargetPicker> createState() => _TargetPickerState();
}

class _TargetPickerState extends ConsumerState<TargetPicker> {
  final _filter = TextEditingController();
  final _filterFocus = FocusNode();

  /// The user opened the tiles while the keyboard is showing. Only for as
  /// long as it shows; the setting is about the page without a keyboard.
  bool _openOverKeyboard = false;

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
  void didUpdateWidget(TargetPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.keyboardOpen) _openOverKeyboard = false;
  }

  @override
  void dispose() {
    _filter.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  void _toggleFold({required bool folded}) {
    if (widget.keyboardOpen && !_filterFocus.hasFocus) {
      setState(() => _openOverKeyboard = folded);
    } else {
      ref.read(settingsProvider.notifier).update((s) => s.copyWith(composerTargetsFolded: !folded));
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final accounts = ref.watch(accountListProvider);
    final selected = ref.watch(composerProvider.select((c) => c.selected));
    final artwork = ref.watch(composerProvider.select((c) => c.artwork));
    final notifier = ref.read(composerProvider.notifier);
    final registry = ref.watch(registryProvider);
    final tileGrid = widget.tileGrid;
    final foldedByChoice = ref.watch(settingsProvider.select((s) => s.composerTargetsFolded));

    if (accounts.isEmpty) {
      // Still reading the accounts: show nothing rather than "connect your first".
      if (!ref.watch(accountsLoadedProvider)) return const SizedBox(height: 56);
      return const _NoAccounts();
    }

    // Art sites only receive artwork. In artwork mode only they are shown;
    // otherwise choosing one turns artwork mode on.
    final art = {for (final a in accounts) if (isArtAccount(registry, a)) a.id};
    final artworkMode = artwork != null;
    final unordered = artworkMode ? accounts.where((a) => art.contains(a.id)).toList() : accounts;
    // On a phone two accounts on one network sit side by side.
    final shown = tileGrid ? groupedByNetwork(unordered) : unordered;

    String platformName(ConnectedAccount a) => registry.descriptor(a.platformId)?.name ?? a.platformId;
    VoidCallback? tapOf(ConnectedAccount a) => !a.enabled
        ? null
        : !artworkMode && art.contains(a.id)
            ? () => setArtworkMode(ref, on: true, accountId: a.id)
            : () => notifier.toggleAccount(a.id);

    // What the quick choices and the count are about. Without Artwork that
    // leaves out art sites: they can never be selected for an ordinary post.
    final eligible = artworkMode ? shown : shown.where((a) => !art.contains(a.id)).toList();

    // The filter field: past [kTargetFilterThreshold] only.
    final filterable = tileGrid && shown.length > kTargetFilterThreshold;
    final query = filterable ? _filter.text.trim().toLowerCase() : '';
    final filtering = query.isNotEmpty;
    bool matches(ConnectedAccount a) {
      final descriptor = registry.descriptor(a.platformId);
      return [descriptor?.name, descriptor?.shortName, a.handle, a.displayName].any((t) => t != null && t.toLowerCase().contains(query));
    }

    final visible = filtering ? shown.where(matches).toList() : shown;
    final visibleEligible = filtering ? eligible.where(matches).toList() : eligible;

    // The quick choices never mix art sites with the others. While filtering
    // they act on the matching accounts and leave the others as they are.
    final choosable = visibleEligible.where((a) => a.enabled);
    final auto = choosable.where((a) => a.tier != PlatformTier.handoff).map((a) => a.id);
    void pick(Iterable<String> ids) => notifier.selectAccounts(filtering ? {...selected.difference(visibleEligible.map((a) => a.id).toSet()), ...ids} : ids);

    final count = eligible.isEmpty ? null : '${eligible.where((a) => selected.contains(a.id)).length} of ${eligible.length}';
    final filters = [
      _QuickFilter('All', () => pick(choosable.map((a) => a.id)), touch: tileGrid),
      _QuickFilter('Automatic only', () => pick(auto), touch: tileGrid),
      _QuickFilter('None', () => pick(const []), touch: tileGrid),
    ];

    final artworkSwitch = _ArtworkSwitch(on: artworkMode, touch: tileGrid, onChanged: (v) => setArtworkMode(ref, on: v));
    // Also when the last art site was removed in artwork mode, to get out of it.
    final showArtworkSwitch = art.isNotEmpty || artworkMode;

    if (!tileGrid) {
      // Lead with the platform; add the account name only when the user has
      // several accounts on the same platform.
      final perPlatform = <String, int>{};
      for (final a in shown) {
        perPlatform[a.platformId] = (perPlatform[a.platformId] ?? 0) + 1;
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        // Wraps onto two lines when large text or a narrow window leaves no room.
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.spaceBetween, runSpacing: Space.xs, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Post to', style: context.text.titleSmall?.copyWith(color: nf.textMuted)),
            if (count != null) ...[
              const SizedBox(width: Space.sm),
              Text(count, style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
            ],
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: filters),
        ]),
        if (showArtworkSwitch) artworkSwitch,
        const SizedBox(height: Space.sm + 2),
        Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          for (final a in shown)
            AccountChip(
              account: a,
              platformName: platformName(a),
              showAccountName: (perPlatform[a.platformId] ?? 0) > 1,
              selected: selected.contains(a.id),
              artSite: !artworkMode && art.contains(a.id),
              onTap: tapOf(a),
            ),
        ]),
        if (artwork != null) ...[
          const SizedBox(height: Space.md),
          _ArtworkOptions(details: artwork, onChanged: notifier.setArtwork),
        ],
      ]);
    }

    // The keyboard folds the tiles, unless the user is typing in the filter
    // or opened them; otherwise the user's own choice stands.
    final overKeyboard = widget.keyboardOpen && !_filterFocus.hasFocus;
    final folded = overKeyboard ? !_openOverKeyboard : foldedByChoice;
    final foldButton = ToolButton(
      key: TargetPicker.foldKey,
      icon: folded ? Icons.expand_more_rounded : Icons.expand_less_rounded,
      tooltip: folded ? 'Show all accounts' : 'Fold accounts',
      size: 48,
      onPressed: () => _toggleFold(folded: folded),
    );
    final labels = accountTileLabels(shown, registry);
    AccountTile tile(ConnectedAccount a) => AccountTile(
          account: a,
          platformName: platformName(a),
          label: labels[a.id] ?? a.platformId,
          selected: selected.contains(a.id),
          artSite: !artworkMode && art.contains(a.id),
          onTap: tapOf(a),
        );
    final ordinaryTiles = [for (final a in visible) if (artworkMode || !art.contains(a.id)) tile(a)];
    final artTiles = artworkMode ? const <AccountTile>[] : [for (final a in visible) if (art.contains(a.id)) tile(a)];

    final Widget picker;
    if (folded) {
      picker = AccountFoldSummary(
        key: const ValueKey('target-picker-summary'),
        accounts: eligible,
        selected: selected,
        labels: labels,
        platformName: platformName,
        onExpand: () => _toggleFold(folded: true),
        trailing: foldButton,
      );
    } else {
      picker = Column(key: const ValueKey('target-picker-tiles'), crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        _TileGridHeader(count: count, filters: filters, foldButton: foldButton),
        if (filterable) ...[
          const SizedBox(height: Space.xs),
          _TargetFilter(
            controller: _filter,
            focusNode: _filterFocus,
            matching: filtering ? visible.length : null,
            onChanged: _rebuild,
          ),
          const SizedBox(height: Space.sm),
        ] else
          const SizedBox(height: Space.xs),
        if (ordinaryTiles.isNotEmpty) AccountTileGrid(tiles: ordinaryTiles),
        if (artTiles.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: Space.sm, bottom: Space.xs),
            child: Text('Art sites', style: context.text.labelSmall?.copyWith(color: nf.textFaint)),
          ),
          AccountTileGrid(tiles: artTiles),
        ],
        if (filtering && visible.isEmpty) Text('No account matches.', style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
      ]);
    }

    // Over the keyboard every line counts: only the summary stays. The
    // summary alone is still all of the selection.
    final extras = !(folded && overKeyboard);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      // Fades, but takes its new height within the frame. The text field
      // scrolls its caret into view right after the frame in which the
      // keyboard opens: a height still changing then would move the caret out
      // of view again.
      AnimatedSwitcher(
        duration: context.motion(Motion.fast),
        switchInCurve: Motion.standard,
        layoutBuilder: (current, _) => current ?? const SizedBox.shrink(),
        child: picker,
      ),
      if (extras && showArtworkSwitch) artworkSwitch,
      if (extras && artwork != null) ...[
        const SizedBox(height: Space.sm),
        _ArtworkOptions(details: artwork, touch: true, onChanged: notifier.setArtwork),
      ],
    ]);
  }
}

/// "Post to", the count, the quick choices and the fold button above the
/// account tiles: one 48 high line, or under large text a line of words over
/// that. The tiles start as high as they can, so that all 21 stay on screen.
class _TileGridHeader extends StatelessWidget {
  const _TileGridHeader({required this.count, required this.filters, required this.foldButton});
  final String? count;
  final List<Widget> filters;
  final Widget foldButton;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final title = Text('Post to', style: context.text.titleSmall?.copyWith(color: nf.textMuted));
    final counted = count == null ? null : Text(count!, style: context.text.bodySmall?.copyWith(color: nf.textFaint));
    final controls = Row(children: [
      Expanded(child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, children: filters)),
      foldButton,
    ]);
    // The words and the controls no longer share a line on a 360 wide phone
    // past this text size.
    if (MediaQuery.textScalerOf(context).scale(10) > 12.5) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          title,
          if (counted != null) ...[const SizedBox(width: Space.sm), counted],
        ]),
        controls,
      ]);
    }
    return Row(children: [
      Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [title, ?counted]),
      Expanded(child: controls),
    ]);
  }
}

/// The field that narrows the account tiles down, past
/// [kTargetFilterThreshold] accounts.
class _TargetFilter extends StatelessWidget {
  const _TargetFilter({required this.controller, required this.focusNode, required this.matching, required this.onChanged});
  final TextEditingController controller;
  final FocusNode focusNode;

  /// How many accounts match, while there is something to match.
  final int? matching;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TextField(
        key: TargetPicker.filterKey,
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
  const _ArtworkSwitch({required this.on, required this.onChanged, this.touch = false});
  final bool on;
  final ValueChanged<bool> onChanged;

  /// A full size touch target (phones) instead of the small switch.
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final toggle = Switch(key: TargetPicker.artworkSwitchKey, value: on, onChanged: onChanged);
    return MergeSemantics(
      child: Row(children: [
        Icon(Icons.brush_outlined, size: 16, color: on ? nf.accent : nf.textMuted),
        const SizedBox(width: Space.xs + 2),
        Text('Artwork', style: context.text.labelMedium?.copyWith(color: on ? nf.text : nf.textMuted)),
        if (touch) toggle else Transform.scale(scale: 0.75, child: toggle),
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

  /// Full size touch targets (phones) instead of the small controls.
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final density = touch ? VisualDensity.standard : VisualDensity.compact;
    final targetSize = touch ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap;
    final label = Text('Rating', style: context.text.labelMedium?.copyWith(color: nf.textMuted));
    final rating = SegmentedButton<ArtworkMaturity>(
      segments: const [
        ButtonSegment(value: ArtworkMaturity.general, label: Text('General'), tooltip: 'Suitable for everyone'),
        ButtonSegment(value: ArtworkMaturity.mature, label: Text('Mature'), tooltip: 'Suggestive themes, mild nudity or violence'),
        ButtonSegment(value: ArtworkMaturity.adult, label: Text('Adult'), tooltip: adultRatingDescription),
      ],
      selected: {details.maturity},
      showSelectedIcon: false,
      // Across the whole column on a phone, whatever the text size.
      expandedInsets: touch ? EdgeInsets.zero : null,
      style: ButtonStyle(visualDensity: density, tapTargetSize: targetSize),
      onSelectionChanged: (s) => onChanged(details.copyWith(maturity: s.single)),
    );
    return Wrap(spacing: Space.sm, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (touch)
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [label, const SizedBox(height: Space.xs), rating])
      else
        Row(mainAxisSize: MainAxisSize.min, children: [label, const SizedBox(width: Space.sm), rating]),
      FilterChip(
        label: const Text('Made with AI'),
        tooltip: 'The work was made with generative AI. Some art sites refuse such work.',
        selected: details.aiGenerated,
        visualDensity: density,
        materialTapTargetSize: touch ? targetSize : null,
        onSelected: (v) => onChanged(details.copyWith(aiGenerated: v)),
      ),
      FilterChip(
        label: const Text('Ask not to train AI'),
        tooltip: 'Sets the NoAI option where a site has one.',
        selected: details.disallowAiTraining,
        visualDensity: density,
        materialTapTargetSize: touch ? targetSize : null,
        onSelected: (v) => onChanged(details.copyWith(disallowAiTraining: v)),
      ),
    ]);
  }
}

class _QuickFilter extends StatelessWidget {
  const _QuickFilter(this.label, this.onTap, {this.touch = false});
  final String label;
  final VoidCallback onTap;

  /// A 48 x 48 touch target (phones) around the same label.
  final bool touch;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: context.nf.textMuted,
          padding: EdgeInsets.symmetric(horizontal: touch ? Space.xs : Space.sm, vertical: Space.xs),
          minimumSize: touch ? const Size(48, 48) : const Size(0, 30),
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
      message: accountTargetTooltip(a, widget.platformName, enabled: enabled, artSite: widget.artSite),
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
