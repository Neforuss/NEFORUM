import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';

/// The smallest tile width. With [kAccountTileGap] a 328 wide column (a 360
/// wide phone less its gutters) holds 6 columns of 53, above the 48 minimum
/// for a touch target.
const double kAccountTileMinWidth = 52;

/// Space between tiles, across and down.
const double kAccountTileGap = 2;

/// Tiles grow taller with the text size, never shorter than this.
const double kAccountTileMinHeight = 56;

/// The margin inside a tile that its border is drawn over.
const double kAccountTileBorderRoom = 1;

const double _tileAvatarSize = 30;

/// The tile's one line of text. Every network's [PlatformDescriptor.compactName]
/// fits a 53 wide tile in it at the normal text size.
TextStyle accountTileLabelStyle(BuildContext context) =>
    context.text.labelSmall!.copyWith(fontSize: 10.5, fontWeight: FontWeight.w500, letterSpacing: -0.2);

/// How many tiles fit across [width].
int accountTileColumns(double width) => ((width + kAccountTileGap) / (kAccountTileMinWidth + kAccountTileGap)).floor().clamp(1, 1000);

/// [accounts] with the accounts of one network side by side, networks in the
/// order they first appear, and accounts in their own order within a network.
List<ConnectedAccount> groupedByNetwork(Iterable<ConnectedAccount> accounts) {
  final networks = <String, List<ConnectedAccount>>{};
  for (final a in accounts) {
    (networks[a.platformId] ??= []).add(a);
  }
  return [for (final group in networks.values) ...group];
}

/// A handle's start is cut when siblings share at least this many characters:
/// a tile shows about nine, so they would all read the same.
const int _sharedHandleStart = 8;

/// The word on each account's tile, by account id: the network's short name,
/// or the account's handle when one network has several accounts, because
/// those tiles have to tell them apart.
Map<String, String> accountTileLabels(Iterable<ConnectedAccount> accounts, AdapterRegistry registry) {
  final networks = <String, List<ConnectedAccount>>{};
  for (final a in accounts) {
    (networks[a.platformId] ??= []).add(a);
  }
  final labels = <String, String>{};
  for (final e in networks.entries) {
    final group = e.value;
    if (group.length == 1) {
      labels[group.single.id] = registry.descriptor(e.key)?.compactName ?? e.key;
      continue;
    }
    final handles = {for (final a in group) a.id: _withoutAt(a.handle ?? a.displayName)};
    final shared = _sharedStartLength(handles.values);
    for (final h in handles.entries) {
      labels[h.key] = shared >= _sharedHandleStart ? '…${h.value.substring(shared)}' : h.value;
    }
  }
  return labels;
}

String _withoutAt(String handle) => handle.startsWith('@') ? handle.substring(1) : handle;

/// How many characters all of [values] start with, always leaving each at
/// least one of its own.
int _sharedStartLength(Iterable<String> values) {
  final all = values.toList();
  var n = all.map((v) => v.length).reduce((a, b) => a < b ? a : b) - 1;
  for (var i = 0; i < n; i++) {
    if (all.any((v) => v[i] != all.first[i])) {
      n = i;
      break;
    }
  }
  return n < 0 ? 0 : n;
}

/// What the tile or chip of an account says when held or hovered.
String accountTargetTooltip(ConnectedAccount a, String platformName, {required bool enabled, required bool artSite}) => enabled
    ? '$platformName · ${a.handle ?? a.displayName}\n${tierShortLabel(a.tier)}: ${tierDescription(a.tier)}'
        '${artSite ? '\nArt site: choosing it turns on Artwork' : ''}'
    : '$platformName is disabled in Accounts';

/// What a screen reader says for an account's tile.
String accountTileSemantics(ConnectedAccount a, String platformName, {required bool selected, required bool enabled, required bool artSite}) {
  final state = !enabled ? 'disabled in Accounts' : (selected ? 'posting' : 'left out');
  return '$platformName, ${a.handle ?? a.displayName}, ${tierShortLabel(a.tier)}, $state${artSite ? ', art site, choosing it turns on Artwork' : ''}';
}

/// Phones: every account as a tile, all on screen, no sideways scrolling. Not
/// a scroll view of its own: the page scrolls.
class AccountTileGrid extends StatelessWidget {
  const AccountTileGrid({super.key, required this.tiles});

  final List<AccountTile> tiles;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
        final columns = accountTileColumns(constraints.maxWidth);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          for (var row = 0; row * columns < tiles.length; row++)
            Padding(
              padding: EdgeInsets.only(top: row == 0 ? 0 : kAccountTileGap),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (var column = 0; column < columns; column++) ...[
                  if (column > 0) const SizedBox(width: kAccountTileGap),
                  Expanded(child: row * columns + column < tiles.length ? tiles[row * columns + column] : const SizedBox.shrink()),
                ],
              ]),
            ),
        ]);
      });
}

/// One account in [AccountTileGrid]. Its states read without colour: a check
/// when selected, a faded picture when not, a block sign when disabled, and
/// the tier's own glyph.
class AccountTile extends StatefulWidget {
  AccountTile({
    required this.account,
    required this.platformName,
    required this.label,
    required this.selected,
    required this.onTap,
    this.artSite = false,
  }) : super(key: keyFor(account.id));

  /// The tile of the account with [accountId], for tests.
  static Key keyFor(String accountId) => ValueKey('account-tile-$accountId');

  final ConnectedAccount account;
  final String platformName;
  final String label;
  final bool selected;

  /// `null`: the account is disabled in Accounts.
  final VoidCallback? onTap;

  /// An art site outside artwork mode: choosing it turns artwork mode on.
  final bool artSite;

  @override
  State<AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends State<AccountTile> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final a = widget.account;
    final sel = widget.selected;
    final enabled = widget.onTap != null;
    final emphasized = sel || _focused;
    return Semantics(
      container: true,
      button: true,
      selected: sel,
      enabled: enabled,
      label: accountTileSemantics(a, widget.platformName, selected: sel, enabled: enabled, artSite: widget.artSite),
      onTap: widget.onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: accountTargetTooltip(a, widget.platformName, enabled: enabled, artSite: widget.artSite),
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (v) => setState(() => _hover = v),
            onFocusChange: (v) => setState(() => _focused = v),
            mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
            borderRadius: Radii.rSm,
            child: AnimatedContainer(
              duration: context.motion(Motion.fast),
              curve: Motion.standard,
              constraints: const BoxConstraints(minHeight: kAccountTileMinHeight),
              // The border is drawn over a fixed margin, so that the label
              // does not change width with the selection.
              padding: const EdgeInsets.all(kAccountTileBorderRoom),
              decoration: BoxDecoration(
                color: sel ? nf.accentSoft : (_hover && enabled ? nf.surfaceHover : nf.surface),
                borderRadius: Radii.rSm,
              ),
              foregroundDecoration: BoxDecoration(
                borderRadius: Radii.rSm,
                border: Border.all(color: emphasized ? nf.accent : (_hover ? nf.borderStrong : nf.border), width: emphasized ? 1.5 : 1),
              ),
              child: Stack(alignment: Alignment.center, children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.xxs),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Center(child: AccountTileFace(a, dimmed: !enabled || !sel, tierColor: sel ? tierTone(a.tier).fg(nf) : nf.textFaint)),
                    const SizedBox(height: Space.xxs),
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: accountTileLabelStyle(context).copyWith(color: !enabled ? nf.textFaint : (sel ? nf.text : nf.textMuted)),
                    ),
                  ]),
                ),
                if (widget.artSite) Positioned(top: 1, left: 1, child: Icon(Icons.brush_outlined, size: 12, color: nf.textFaint)),
                if (!enabled)
                  Positioned(top: 1, right: 1, child: Icon(Icons.block_rounded, size: 14, color: nf.textMuted))
                else if (sel)
                  Positioned(top: 1, right: 1, child: Icon(Icons.check_circle_rounded, size: 14, color: nf.accent)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The picture of an account with its tier's glyph at the bottom left, the
/// same in a tile and in the folded summary.
class AccountTileFace extends StatelessWidget {
  const AccountTileFace(this.account, {super.key, required this.dimmed, required this.tierColor});

  final ConnectedAccount account;
  final bool dimmed;
  final Color tierColor;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final a = account;
    return SizedBox.square(
      dimension: _tileAvatarSize,
      child: Stack(clipBehavior: Clip.none, children: [
        // Profile photo when known; otherwise the platform's mark. The photo's
        // platform badge may reach past the square: every row stays one height.
        Positioned(
          left: 0,
          top: 0,
          child: a.avatarUrl != null && a.avatarUrl!.startsWith('http')
              ? AccountAvatar(a, size: _tileAvatarSize, dimmed: dimmed)
              : PlatformTile(a.platformId, size: _tileAvatarSize, circle: true, dimmed: dimmed),
        ),
        Positioned(
          left: -5,
          bottom: -2,
          child: Container(
            width: 15,
            height: 15,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: nf.surface, shape: Radii.circleShape, border: Border.all(color: nf.border, width: 0.5)),
            child: Icon(tierIcon(a.tier), size: 11, color: tierColor),
          ),
        ),
      ]),
    );
  }
}

/// Which accounts the folded summary names: the left-out ones when they are
/// no more than the selected ones, otherwise the selected ones. The accounts
/// not named are in the other state, so nothing about selection is lost.
({bool leftOut, List<ConnectedAccount> accounts}) foldedAccounts(Iterable<ConnectedAccount> accounts, Set<String> selected) {
  final out = [for (final a in accounts) if (!selected.contains(a.id)) a];
  final chosen = [for (final a in accounts) if (selected.contains(a.id)) a];
  return out.length <= chosen.length ? (leftOut: true, accounts: out) : (leftOut: false, accounts: chosen);
}

/// The account tiles folded into one row: "18 of 21", then the accounts that
/// differ from the rest.
class AccountFoldSummary extends StatelessWidget {
  const AccountFoldSummary({
    super.key,
    required this.accounts,
    required this.selected,
    required this.labels,
    required this.platformName,
    required this.onExpand,
    required this.trailing,
  });

  /// The accounts the count is about, in tile order.
  final List<ConnectedAccount> accounts;
  final Set<String> selected;
  final Map<String, String> labels;
  final String Function(ConnectedAccount) platformName;
  final VoidCallback onExpand;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final count = accounts.where((a) => selected.contains(a.id)).length;
    final named = foldedAccounts(accounts, selected);
    final several = <String, int>{};
    for (final a in accounts) {
      several[a.platformId] = (several[a.platformId] ?? 0) + 1;
    }
    final String? words = accounts.isEmpty
        ? 'Only art sites connected'
        : named.accounts.isEmpty
            ? (named.leftOut ? 'All selected' : 'None selected')
            : null;
    final head = named.leftOut ? 'Left out:' : 'Only:';
    final muted = context.text.bodySmall?.copyWith(color: nf.textMuted);
    final description = StringBuffer(accounts.isEmpty ? '' : '$count of ${accounts.length} accounts selected. ');
    if (words != null) {
      description.write(words);
    } else {
      description.write('$head ${named.accounts.map((a) => '${platformName(a)} ${a.handle ?? a.displayName}').join(', ')}');
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onExpand,
          child: Semantics(
            button: true,
            label: description.toString(),
            excludeSemantics: true,
            child: ConstrainedBox(
              // Level with the 48 high button beside it when it is one line.
              constraints: const BoxConstraints(minHeight: 48),
              child: Align(
                alignment: Alignment.centerLeft,
                heightFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.xs),
                  child: Wrap(spacing: Space.sm, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    if (accounts.isNotEmpty) Text('$count of ${accounts.length}', style: context.text.titleSmall?.copyWith(color: nf.text)),
                    if (words != null)
                      Text(words, style: muted)
                    else ...[
                      Text(head, style: muted),
                      for (final a in named.accounts)
                        _FoldedAccount(
                          a,
                          leftOut: named.leftOut,
                          label: (several[a.platformId] ?? 0) > 1 ? labels[a.id] : null,
                        ),
                    ],
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
      trailing,
    ]);
  }
}

/// One account named in the folded summary. Its network's mark alone cannot
/// tell two accounts on one network apart, so those also show their handle.
class _FoldedAccount extends StatelessWidget {
  const _FoldedAccount(this.account, {required this.leftOut, this.label});

  final ConnectedAccount account;
  final bool leftOut;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final disabled = !account.enabled;
    final face = SizedBox(
      width: _tileAvatarSize + 5,
      height: _tileAvatarSize + 2,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: 5,
          top: 0,
          child: AccountTileFace(account, dimmed: leftOut || disabled, tierColor: leftOut ? nf.textFaint : tierTone(account.tier).fg(nf)),
        ),
        if (disabled) Positioned(right: -2, top: -2, child: Icon(Icons.block_rounded, size: 14, color: nf.textMuted)),
      ]),
    );
    if (label == null) return face;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      face,
      const SizedBox(width: Space.xs),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 72),
        child: Text(
          label!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: accountTileLabelStyle(context).copyWith(color: nf.textMuted),
        ),
      ),
    ]);
  }
}
