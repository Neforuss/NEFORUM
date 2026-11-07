import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';

// Phones choose where a post goes in a grid of names that fits the screen:
// every account is on screen at once, read as a word, and nothing scrolls
// sideways. One tap on a name leaves it out, and it is then struck through.
//
// The number of columns comes from the names themselves (accountGridColumns),
// so a name is never cut to fit: larger text gets fewer columns.

/// Smallest cell: room for the network's icon, the way it posts and the
/// selection mark on one line, above the name.
const double kAccountCellMinWidth = 72;

/// Every cell is at least this tall, and [kAccountCellMinWidth] is wider than
/// this, so each one clears the 48 x 48 touch target.
const double kAccountCellMinHeight = 48;

/// The fold control of the grid, open or folded.
const kTargetFoldKey = ValueKey('target-picker-fold');

const double _gap = Space.xs;
const double _cellPaddingX = Space.xs;

/// One account as the grid and its summary show it.
class AccountEntry {
  const AccountEntry({
    required this.account,
    required this.platformName,
    required this.label,
    required this.selected,
    required this.onTap,
    this.handle,
    this.artSite = false,
  });

  final ConnectedAccount account;

  /// The network's full name.
  final String platformName;

  /// The network's name as shown in the cell.
  final String label;

  /// Tells accounts on one network apart; null when the network has only one.
  final String? handle;
  final bool selected;

  /// Null when the account is disabled in Accounts.
  final VoidCallback? onTap;

  /// An art site outside artwork mode: choosing it turns artwork mode on, and
  /// until then it is neither chosen nor left out.
  final bool artSite;

  bool get disabled => onTap == null;

  /// Chosen or left out: what the count and the summary are about.
  bool get counted => !artSite;

  String get stateWords => disabled
      ? 'disabled in Accounts'
      : artSite
          ? 'art site, choosing it turns on Artwork'
          : selected
              ? 'posting'
              : 'left out';

  String get semanticLabel => [platformName, ?(account.handle ?? handle), tierShortLabel(account.tier), stateWords].join(', ');

  String get tooltip => disabled
      ? '$platformName is disabled in Accounts'
      : '$platformName · ${account.handle ?? account.displayName}\n${tierShortLabel(account.tier)}: ${tierDescription(account.tier)}'
          '${artSite ? '\nArt site: choosing it turns on Artwork' : ''}';
}

/// [accounts] in the grid's order: accounts on one network side by side, at
/// the place the network first appears, and art sites ([isArt]) last. The
/// order is otherwise the user's own.
List<ConnectedAccount> orderedForAccountGrid(List<ConnectedAccount> accounts, bool Function(ConnectedAccount) isArt) {
  List<ConnectedAccount> grouped(Iterable<ConnectedAccount> list) {
    final byPlatform = <String, List<ConnectedAccount>>{};
    for (final a in list) {
      (byPlatform[a.platformId] ??= []).add(a);
    }
    return [for (final group in byPlatform.values) ...group];
  }

  return [...grouped(accounts.where((a) => !isArt(a))), ...grouped(accounts.where(isArt))];
}

/// What tells [accounts], all on one network, apart in a narrow cell, by
/// account id: `@ana@social.example` shortens to `@ana` unless another account
/// has the same first part. No entry for a network with one account.
Map<String, String> accountGridHandles(List<ConnectedAccount> accounts) {
  if (accounts.length < 2) return const {};
  String full(ConnectedAccount a) => a.handle ?? a.displayName;
  String local(ConnectedAccount a) {
    final h = full(a);
    final at = h.indexOf('@', 1);
    return at > 0 ? h.substring(0, at) : h;
  }

  final seen = <String, int>{};
  for (final a in accounts) {
    seen[local(a)] = (seen[local(a)] ?? 0) + 1;
  }
  return {for (final a in accounts) a.id: seen[local(a)] == 1 ? local(a) : full(a)};
}

/// How many columns fit in [width] when no cell may be narrower than its
/// longest word, [widestWord] pixels at the current text size. Never below 2,
/// where a long unbroken word can still shorten, which beats one per line.
int accountGridColumns(double width, double widestWord) {
  final cell = math.max(kAccountCellMinWidth, widestWord + 2 * _cellPaddingX + 1);
  return math.max(2, ((width + _gap) / (cell + _gap)).floor());
}

/// The style of a name in a cell. Its weight stays the same when selected, so
/// the columns do not change with the selection.
TextStyle? _nameStyle(BuildContext context) => context.text.labelMedium?.copyWith(fontSize: 12, fontWeight: FontWeight.w600, height: 1.2);

/// Width of the longest word of any entry's name at the current text size.
double _widestWord(BuildContext context, List<AccountEntry> entries) {
  final style = _nameStyle(context);
  final scaler = MediaQuery.textScalerOf(context);
  final words = {for (final e in entries) ...e.label.split(' ')};
  var widest = 0.0;
  for (final word in words) {
    final painter = TextPainter(text: TextSpan(text: word, style: style), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1)..layout();
    widest = math.max(widest, painter.width);
    painter.dispose();
  }
  return widest;
}

/// All the accounts, by name. Grows downwards only.
class AccountSelectionGrid extends StatelessWidget {
  const AccountSelectionGrid({super.key, required this.entries});

  /// Art sites outside artwork mode come last and get a heading of their own.
  final List<AccountEntry> entries;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final ordinary = entries.where((e) => !e.artSite).toList();
    final art = entries.where((e) => e.artSite).toList();
    return LayoutBuilder(builder: (context, box) {
      // Each part by its own names: one long art site's name leaves the
      // ordinary accounts as they are.
      int columnsOf(List<AccountEntry> part) => accountGridColumns(box.maxWidth, _widestWord(context, part));
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        _Rows(entries: ordinary, columns: columnsOf(ordinary)),
        if (art.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.only(top: ordinary.isEmpty ? 0 : Space.sm, bottom: Space.xs),
            child: Row(children: [
              Icon(Icons.brush_outlined, size: 13, color: nf.textFaint),
              const SizedBox(width: Space.xs),
              Expanded(child: Text('Art sites: choosing one turns on Artwork', style: context.text.bodySmall?.copyWith(color: nf.textFaint))),
            ]),
          ),
          _Rows(entries: art, columns: columnsOf(art)),
        ],
      ]);
    });
  }
}

class _Rows extends StatelessWidget {
  const _Rows({required this.entries, required this.columns});
  final List<AccountEntry> entries;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < entries.length; i += columns) {
      if (i > 0) rows.add(const SizedBox(height: _gap));
      rows.add(IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var c = 0; c < columns; c++) ...[
            if (c > 0) const SizedBox(width: _gap),
            Expanded(child: i + c < entries.length ? AccountCell(entry: entries[i + c]) : const SizedBox.shrink()),
          ],
        ]),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: rows);
  }
}

/// One account: its network's icon, how it posts, whether it is chosen, and
/// its name. Chosen or not reads from three things that are not colour: the
/// filled mark or the empty ring, the name struck through, and the icon going
/// flat.
class AccountCell extends StatefulWidget {
  const AccountCell({super.key, required this.entry});
  final AccountEntry entry;

  @override
  State<AccountCell> createState() => _AccountCellState();
}

class _AccountCellState extends State<AccountCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final e = widget.entry;
    final enabled = !e.disabled;
    final sel = e.selected && enabled;
    final leftOut = enabled && !sel && !e.artSite;
    return Tooltip(
      message: e.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: e.onTap,
          child: Semantics(
            button: true,
            selected: sel,
            enabled: enabled,
            excludeSemantics: true,
            label: e.semanticLabel,
            child: AnimatedContainer(
              key: ValueKey('account-cell-box-${e.account.id}'),
              duration: context.motion(Motion.fast),
              curve: Motion.standard,
              constraints: const BoxConstraints(minHeight: kAccountCellMinHeight),
              padding: const EdgeInsets.symmetric(horizontal: _cellPaddingX, vertical: Space.xs),
              decoration: BoxDecoration(
                color: !enabled
                    ? nf.surfaceSunken
                    : sel
                        ? nf.accentSoft
                        : (_hover ? nf.surfaceHover : nf.surface),
                borderRadius: Radii.rXs,
                // Mostly chosen is the usual picture: chosen cells stay quiet,
                // so the ones left out are what the eye finds.
                border: Border.all(color: sel ? nf.accent.withValues(alpha: 0.45) : (_hover && enabled ? nf.borderStrong : nf.border)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  PlatformTile(e.account.platformId, size: 18, dimmed: !sel),
                  const Spacer(),
                  Icon(tierIcon(e.account.tier), size: 13, color: sel ? tierTone(e.account.tier).fg(nf) : nf.textFaint),
                  const SizedBox(width: Space.xxs),
                  // A different shape for each state.
                  Icon(
                    !enabled
                        ? Icons.block_rounded
                        : sel
                            ? Icons.check_circle_rounded
                            : e.artSite
                                ? Icons.brush_outlined
                                : Icons.radio_button_unchecked_rounded,
                    size: 15,
                    color: sel ? nf.accent : nf.textFaint,
                  ),
                ]),
                const SizedBox(height: Space.xxs),
                Text(
                  e.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: _nameStyle(context)?.copyWith(
                    color: !enabled
                        ? nf.textFaint
                        : sel
                            ? nf.text
                            : nf.textMuted,
                    decoration: leftOut ? TextDecoration.lineThrough : null,
                    decorationColor: nf.textMuted,
                  ),
                ),
                if (e.handle != null)
                  Text(
                    e.handle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall?.copyWith(fontSize: 10.5, height: 1.2, color: sel ? nf.textMuted : nf.textFaint),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tiers of the chosen accounts, each as its glyph and a count.
class AccountTierCounts extends StatelessWidget {
  const AccountTierCounts({super.key, required this.entries});
  final List<AccountEntry> entries;

  /// How many chosen accounts post each way.
  static Map<PlatformTier, int> of(List<AccountEntry> entries) {
    final counts = <PlatformTier, int>{};
    for (final e in entries.where((e) => e.counted && e.selected)) {
      counts[e.account.tier] = (counts[e.account.tier] ?? 0) + 1;
    }
    return counts;
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final counts = of(entries);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final t in PlatformTier.values)
        if (counts[t] != null) ...[
          const SizedBox(width: Space.sm),
          Icon(tierIcon(t), size: 14, color: tierTone(t).fg(nf)),
          const SizedBox(width: Space.xxs),
          Text('${counts[t]}', style: context.text.bodySmall?.copyWith(color: nf.textMuted, fontWeight: FontWeight.w600)),
        ],
    ]);
  }
}

/// The grid folded, all one target that opens it: how many are chosen, how
/// they post, and the shorter of what is left out and what is chosen, each
/// with how it posts. No account's state is lost, and with everything chosen
/// it takes one line.
class AccountSelectionSummary extends StatelessWidget {
  const AccountSelectionSummary({super.key, required this.entries, required this.onOpen});
  final List<AccountEntry> entries;
  final VoidCallback onOpen;

  /// The accounts the summary names, and the word in front of them: `null`
  /// when everything or nothing is chosen, which the count already says.
  static (String, List<AccountEntry>)? named(List<AccountEntry> entries) {
    final counted = entries.where((e) => e.counted).toList();
    final chosen = counted.where((e) => e.selected).toList();
    final left = counted.where((e) => !e.selected).toList();
    if (left.isEmpty || chosen.isEmpty) return null;
    return left.length <= chosen.length ? ('Left out', left) : ('Only', chosen);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final counts = AccountTierCounts.of(entries);
    final list = named(entries);
    final words = [
      'Post to, ${accountCountLabel(entries)}',
      for (final t in PlatformTier.values)
        if (counts[t] != null) '${counts[t]} ${tierShortLabel(t)}',
      if (list != null) '${list.$1} ${list.$2.map((e) => '${_nameOf(e)}${e.disabled ? ' disabled' : ''}').join(', ')}',
      'Show all accounts',
    ];
    // The detector outside: excluded semantics would take its tap action away.
    return GestureDetector(
      key: kTargetFoldKey,
      behavior: HitTestBehavior.opaque,
      onTap: onOpen,
      child: Semantics(
        button: true,
        expanded: false,
        excludeSemantics: true,
        label: words.join('. '),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kAccountCellMinHeight),
            child: Row(children: [
              AccountCountLabel(entries: entries, folded: true),
              Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: AccountTierCounts(entries: entries))),
            ]),
          ),
          if (list != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.xs),
              child: Wrap(spacing: Space.sm, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('${list.$1}:', style: context.text.bodySmall?.copyWith(color: nf.textMuted, fontWeight: FontWeight.w600)),
                for (final e in list.$2) _SummaryItem(e),
              ]),
            ),
        ]),
      ),
    );
  }

  static String _nameOf(AccountEntry e) => e.handle == null ? e.label : '${e.label} ${e.handle}';
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem(this.entry);
  final AccountEntry entry;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      PlatformTile(entry.account.platformId, size: 15, dimmed: !entry.selected),
      const SizedBox(width: Space.xs),
      Flexible(
        child: Text(
          AccountSelectionSummary._nameOf(entry),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.text.bodySmall?.copyWith(color: nf.text, fontWeight: FontWeight.w500),
        ),
      ),
      const SizedBox(width: Space.xxs),
      Icon(tierIcon(entry.account.tier), size: 12, color: nf.textMuted),
      if (entry.disabled) ...[
        const SizedBox(width: Space.xxs),
        Icon(Icons.block_rounded, size: 12, color: nf.textMuted),
      ],
    ]);
  }
}

/// "18 of 21": chosen of the accounts that can be chosen for this post.
String accountCountLabel(List<AccountEntry> entries) {
  final counted = entries.where((e) => e.counted);
  return '${counted.where((e) => e.selected).length} of ${counted.length}';
}

/// "Post to 18 of 21" with the fold chevron.
class AccountCountLabel extends StatelessWidget {
  const AccountCountLabel({super.key, required this.entries, required this.folded});
  final List<AccountEntry> entries;
  final bool folded;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('Post to', style: context.text.titleSmall?.copyWith(color: nf.textMuted)),
      const SizedBox(width: Space.sm),
      Text(accountCountLabel(entries), style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
      const SizedBox(width: Space.xxs),
      Icon(folded ? Icons.expand_more_rounded : Icons.expand_less_rounded, size: 20, color: nf.textMuted),
    ]);
  }
}
