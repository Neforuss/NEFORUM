import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';

// Phones choose where a post goes in a grid that fits the screen: every account
// is on screen at once and nothing scrolls sideways. One tap on an account
// leaves it out.
//
// The grid has two forms, chosen from the height there is (accountGridFormFor):
// names while they leave the text field on screen, and tiles when they do not.
// A tile holds the same marks without the word, so its size does not depend on
// the text size. The number of columns of names comes from the names themselves
// (accountGridColumns), so a name is never cut to fit: larger text gets fewer
// columns.

/// Smallest cell: room for the network's icon, the way it posts and the
/// selection mark on one line, above the name.
const double kAccountCellMinWidth = 72;

/// Every cell is at least this tall, and both minimum widths are at least
/// this, so each one clears the 48 x 48 touch target.
const double kAccountCellMinHeight = 48;

/// Smallest tile.
const double kAccountTileMinWidth = 48;

/// The fold control of the grid, open or folded.
const kTargetFoldKey = ValueKey('target-picker-fold');

/// The field that narrows the grid down, past [kTargetFilterThreshold] accounts.
const kTargetFilterKey = ValueKey('target-picker-filter');

/// The filter field appears above this many accounts.
const int kTargetFilterThreshold = 24;

/// Over the keyboard the folded summary names this many accounts at most.
/// Past it they are shown as icons, to leave the text its room.
const int kSummaryNamesOverKeyboard = 4;

const double _gap = Space.xs;
const double _cellPaddingX = Space.xs;
const double _cellPaddingY = Space.xxs;

/// A border is drawn inside the cell's box and takes this much on each side.
const double _cellBorder = 1;

/// The height of the filter field and the space under it.
const double _filterHeight = 48 + Space.sm;

/// How the grid shows its accounts.
enum AccountGridForm {
  /// Icon, marks and name in each cell.
  names,

  /// Icon and marks in each tile, whatever the text size. A handle stays, on a
  /// tile twice as wide: it is what tells two accounts on one network apart.
  /// Art sites come last with their own mark and no heading.
  tiles,

  /// Tiles with no gap between the rows, when even that is needed to keep every
  /// account on screen.
  tilesNoGap,
}

/// What the text fields need on screen under the grid: the space above the card,
/// the title that some networks ask for, and two lines of text. The title counts
/// whether it shows or not: it comes and goes with the selection, and the grid
/// must not change form under the finger that is choosing. See `EditorCard`.
double composerTextRoom(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  return Space.lg + Space.lg + scaler.scale(25) + Space.md + 2 * scaler.scale(17 * 1.55);
}

/// The form for [entries] in [width], given [room], the height from the top of
/// the picker to the action bar, of which [above] goes to the rest of the
/// picker. Names while the text field stays on screen under them, tiles
/// otherwise. A null [room] is a place with no such limit.
AccountGridForm accountGridFormFor(BuildContext context, {required List<AccountEntry> entries, required double width, required double? room, required double above}) {
  if (room == null) return AccountGridForm.names;
  if (above + accountGridHeight(context, entries, width, AccountGridForm.names) + composerTextRoom(context) <= room) return AccountGridForm.names;
  return above + accountGridHeight(context, entries, width, AccountGridForm.tiles) <= room ? AccountGridForm.tiles : AccountGridForm.tilesNoGap;
}

/// The height the grid takes for [entries] in [width]. It decides the form, so
/// it has to agree with what [AccountSelectionGrid] lays out; a test holds it
/// to that.
double accountGridHeight(BuildContext context, List<AccountEntry> entries, double width, AccountGridForm form) {
  final rowGap = form == AccountGridForm.tilesNoGap ? 0.0 : _gap;
  final ordinary = entries.where((e) => !e.artSite).toList();
  final art = entries.where((e) => e.artSite).toList();

  double part(List<AccountEntry> list) {
    if (list.isEmpty) return 0;
    final columns = _columnsFor(context, list, width, form);
    final cell = _cellWidth(width, columns);
    final rows = _rowsOf(list, columns, form);
    return (rows.length - 1) * rowGap + rows.fold<double>(0, (sum, row) => sum + row.map((e) => _cellHeight(context, e, form, cell)).reduce(math.max));
  }

  if (form != AccountGridForm.names) return part(entries);
  var height = part(ordinary);
  if (art.isNotEmpty) {
    height += (ordinary.isEmpty ? 0 : Space.sm) + Space.xs + _measure(context, _artHeading, context.text.bodySmall, maxWidth: width - 13 - Space.xs).height + part(art);
  }
  return height;
}

const _artHeading = 'Art sites: choosing one turns on Artwork';

TextPainter _painter(BuildContext context, String text, TextStyle? style, {int? maxLines, double maxWidth = double.infinity}) => TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth);

Size _measure(BuildContext context, String text, TextStyle? style, {int? maxLines, double maxWidth = double.infinity}) {
  final painter = _painter(context, text, style, maxLines: maxLines, maxWidth: maxWidth);
  final size = painter.size;
  painter.dispose();
  return size;
}

int _columnsFor(BuildContext context, List<AccountEntry> part, double width, AccountGridForm form) =>
    form == AccountGridForm.names ? accountGridColumns(width, _widestWord(context, part)) : accountTileColumns(width);

double _cellWidth(double width, int columns) => (width - (columns - 1) * _gap) / columns;

/// How many columns a tile on [form] takes.
int _unitsOf(AccountEntry e, int columns, AccountGridForm form) => form != AccountGridForm.names && e.handle != null ? math.min(2, columns) : 1;

/// [entries] in rows of [columns], in their own order.
List<List<AccountEntry>> _rowsOf(List<AccountEntry> entries, int columns, AccountGridForm form) {
  final rows = <List<AccountEntry>>[];
  var used = columns;
  for (final e in entries) {
    final units = _unitsOf(e, columns, form);
    if (used + units > columns) {
      rows.add([]);
      used = 0;
    }
    rows.last.add(e);
    used += units;
  }
  return rows;
}

/// The height of [e]'s cell, as [AccountCell] lays it out in a column [cell] wide.
double _cellHeight(BuildContext context, AccountEntry e, AccountGridForm form, double cell) {
  const frame = 2 * _cellBorder + 2 * _cellPaddingY;
  final handle = e.handle == null ? 0.0 : _measure(context, e.handle!, _handleStyle(context), maxLines: 1).height;
  if (form != AccountGridForm.names) {
    return math.max(kAccountCellMinHeight, frame + (e.handle == null ? _tileFaceSize + Space.xxs + _stateIconSize : _faceSize + Space.xxs + handle));
  }
  final name = _measure(context, e.label, _nameStyle(context), maxLines: 2, maxWidth: cell - 2 * _cellPaddingX - 2 * _cellBorder).height;
  return math.max(kAccountCellMinHeight, frame + _faceSize + Space.xxs + name + handle);
}

const double _faceSize = 18;
const double _tileFaceSize = 20;
const double _tierIconSize = 13;
const double _stateIconSize = 15;

/// The header of the open grid at its fullest and at its shortest, in the width
/// its widest count takes, so that it does not change as accounts are chosen.
({double full, double tight}) _headerWidths(BuildContext context, List<AccountEntry> entries) {
  double width(String text, TextStyle? style) => _measure(context, text, style).width;
  double quick(String label, double padding) => math.max(kAccountCellMinHeight, width(label, context.text.labelMedium) + 2 * padding);
  double choices(double padding) => quick('All', padding) + quick('Automatic only', padding) + quick('None', padding);

  final n = entries.where((e) => e.counted).length;
  final title = width('Post to', context.text.titleSmall);
  final count = n == 0 ? null : width('$n of $n', context.text.bodySmall);
  return (
    full: title + (count == null ? 0 : Space.sm + count) + Space.xxs + 20 + choices(Space.sm),
    tight: (count ?? title) + 16 + choices(0) + Space.xs,
  );
}

/// Above this the words "Post to" and the padding of the quick choices go, to
/// keep the header on one line. Measured, not tied to a text size.
bool accountGridHeaderIsTight(BuildContext context, List<AccountEntry> entries, double width) => _headerWidths(context, entries).full > width;

/// The header's height: one line of touch targets, or two when even its short
/// form does not fit.
double accountGridHeaderHeight(BuildContext context, List<AccountEntry> entries, double width) =>
    _headerWidths(context, entries).tight > width ? 2 * kAccountCellMinHeight : kAccountCellMinHeight;

/// What the rest of the picker takes above and beside the grid.
double accountGridOtherHeight(BuildContext context, List<AccountEntry> entries, double width, {required bool artworkSwitch, required bool filter}) =>
    accountGridHeaderHeight(context, entries, width) + (artworkSwitch ? _artworkSwitchHeight(context, width) : 0) + (filter ? _filterHeight : 0);

/// The Artwork switch's row: a touch target, or two lines of its words beside it.
double _artworkSwitchHeight(BuildContext context, double width) {
  const icon = 16 + Space.xs + 2, control = Space.xs + 52 + Space.xs + 8;
  final label = _measure(context, 'Artwork', context.text.labelMedium).width;
  final words = _measure(context, 'Art sites only receive artwork: add your image, a title and tags.', context.text.bodySmall, maxLines: 2, maxWidth: math.max(1, width - icon - control - label)).height;
  return math.max(kAccountCellMinHeight, words);
}
/// One account as the grid and its summary show it.
class AccountEntry {
  const AccountEntry({
    required this.account,
    required this.platformName,
    required this.label,
    required this.selected,
    required this.onTap,
    this.handle,
    this.identity,
    this.artSite = false,
  });

  final ConnectedAccount account;

  /// The network's full name.
  final String platformName;

  /// The network's name as shown in the cell.
  final String label;

  /// Tells accounts on one network apart in a narrow cell; null when the
  /// network has only one. See [accountGridHandles].
  final String? handle;

  /// The same in full, for the tooltip and screen readers; null when the
  /// network has only one. See [accountGridIdentities].
  final String? identity;
  final bool selected;

  /// Null when the account is disabled in Accounts.
  final VoidCallback? onTap;

  /// An art site outside artwork mode: choosing it turns artwork mode on, and
  /// until then it is neither chosen nor left out.
  final bool artSite;

  bool get disabled => onTap == null;

  /// [query] in lower case is in anything that names this account.
  bool matches(String query) => [platformName, label, handle, account.handle, account.displayName].any((t) => t != null && t.toLowerCase().contains(query));

  /// Chosen or left out: what the count and the summary are about.
  bool get counted => !artSite;

  String get stateWords => disabled
      ? 'disabled in Accounts'
      : artSite
          ? 'art site, choosing it turns on Artwork'
          : selected
              ? 'posting'
              : 'left out';

  /// Whether this account goes out with the post. A disabled account can still
  /// be in the selection, from an old draft, and publishing skips it.
  bool get posting => selected && !disabled;

  String get semanticLabel {
    final who = identity ?? account.handle;
    return [platformName, if (who != null && who.isNotEmpty) who, tierShortLabel(account.tier), stateWords].join(', ');
  }

  String get tooltip {
    if (disabled) return identity == null ? '$platformName is disabled in Accounts' : '$platformName · $identity is disabled in Accounts';
    final who = identity ?? _nameOfAccount(account);
    return '$platformName${who.isEmpty ? '' : ' · $who'}\n${tierShortLabel(account.tier)}: ${tierDescription(account.tier)}'
        '${artSite ? '\nArt site: choosing it turns on Artwork' : ''}';
  }
}

/// The handle, or else the display name, or nothing at all: adapters can store
/// an empty one.
String _nameOfAccount(ConnectedAccount a) => (a.handle?.isNotEmpty ?? false) ? a.handle! : a.displayName;

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

/// What tells [accounts], all on one network, apart in full, by account id: the
/// handle, or the display name when the handle does not (one person's two
/// Matrix rooms or WordPress sites share one), or a number when nothing does.
/// No entry for a network with one account.
Map<String, String> accountGridIdentities(List<ConnectedAccount> accounts) {
  if (accounts.length < 2) return const {};
  final names = {for (final a in accounts) a.id: _nameOfAccount(a)};
  final displayNames = accounts.map((a) => a.displayName).toList();
  final result = <String, String>{};
  for (final a in accounts) {
    final name = names[a.id]!;
    if (name.isEmpty) {
      continue;
    }
    if (names.values.where((n) => n == name).length == 1) {
      result[a.id] = name;
    } else if (a.displayName.isNotEmpty && displayNames.where((n) => n == a.displayName).length == 1) {
      result[a.id] = a.displayName;
    }
  }
  // Nothing tells these apart but where they are in the list. The number goes
  // first, where a narrow cell cannot cut it off.
  for (final (i, a) in accounts.indexed) {
    if (result.containsKey(a.id)) continue;
    result[a.id] = names[a.id]!.isEmpty ? 'Account ${i + 1}' : '#${i + 1} ${names[a.id]}';
  }
  return result;
}

/// How many characters of a handle a narrow cell shows for sure, at any text
/// size the app offers.
const int _handleCharsShown = 9;

/// What tells [accounts], all on one network, apart in a narrow cell, by
/// account id. `@ana@social.example` shortens to `@ana` unless another account
/// has the same first part, `Family (@ana:matrix.org)` to `Family`, and two long
/// handles that start alike start from where they differ, since the cell cuts
/// off their ends. No entry for a network with one account.
Map<String, String> accountGridHandles(List<ConnectedAccount> accounts) {
  final full = accountGridIdentities(accounts);
  if (full.isEmpty) return const {};
  String local(ConnectedAccount a) {
    final h = full[a.id]!;
    // The adapters that share a handle write it after the name of the room.
    final suffix = ' (${a.handle})';
    if (h.endsWith(suffix) && h.length > suffix.length) return h.substring(0, h.length - suffix.length);
    // A numbered one keeps its handle: cutting at the @ would leave "#1 ".
    if (h != _nameOfAccount(a) && h != a.displayName) return h;
    final at = h.length < 2 ? -1 : h.indexOf('@', 1);
    return at > 0 ? h.substring(0, at) : h;
  }

  final locals = {for (final a in accounts) a.id: local(a)};
  final shortened = {for (final e in locals.entries) e.key: locals.values.where((v) => v == e.value).length == 1 ? e.value : full[e.key]!};

  int differsAt(String a, String b) {
    var i = 0;
    while (i < a.length && i < b.length && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  final shown = <String, String>{};
  for (final e in shortened.entries) {
    final at = shortened.entries.where((o) => o.key != e.key).map((o) => differsAt(e.value, o.value)).reduce(math.max);
    shown[e.key] = at <= _handleCharsShown || at >= e.value.length ? e.value : '…${e.value.substring(at)}';
  }
  return shown.values.toSet().length == shown.length ? shown : shortened;
}

/// How many columns fit in [width] when no cell may be narrower than its
/// longest word, [widestWord] pixels at the current text size. Never below 2,
/// where a long unbroken word can still shorten, which beats one per line.
int accountGridColumns(double width, double widestWord) {
  final cell = math.max(kAccountCellMinWidth, widestWord.ceilToDouble() + 2 * _cellPaddingX + 2 * _cellBorder);
  return math.max(2, ((width + _gap) / (cell + _gap)).floor());
}

/// How many tiles fit across [width].
int accountTileColumns(double width) => math.max(2, ((width + _gap) / (kAccountTileMinWidth + _gap)).floor());

/// The style of a name in a cell. Its weight stays the same when selected, so
/// the columns do not change with the selection.
TextStyle? _nameStyle(BuildContext context) => context.text.labelMedium?.copyWith(fontSize: 12, fontWeight: FontWeight.w600, height: 1.2);

TextStyle? _handleStyle(BuildContext context) => context.text.bodySmall?.copyWith(fontSize: 10.5, height: 1.2);

/// Width of the longest word of any entry's name at the current text size.
double _widestWord(BuildContext context, List<AccountEntry> entries) {
  final style = _nameStyle(context);
  final words = {for (final e in entries) ...e.label.split(' ')};
  var widest = 0.0;
  for (final word in words) {
    widest = math.max(widest, _measure(context, word, style, maxLines: 1).width);
  }
  return widest;
}

/// All the accounts. Grows downwards only.
class AccountSelectionGrid extends StatelessWidget {
  const AccountSelectionGrid({super.key, required this.entries, this.form = AccountGridForm.names});

  /// Art sites outside artwork mode come last and get a heading of their own.
  final List<AccountEntry> entries;
  final AccountGridForm form;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final ordinary = entries.where((e) => !e.artSite).toList();
    final art = entries.where((e) => e.artSite).toList();
    return LayoutBuilder(builder: (context, box) {
      // Each part by its own names: one long art site's name leaves the
      // ordinary accounts as they are.
      Widget rows(List<AccountEntry> part) => _Rows(entries: part, columns: _columnsFor(context, part, box.maxWidth, form), form: form);
      if (form != AccountGridForm.names) return rows(entries);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        rows(ordinary),
        if (art.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.only(top: ordinary.isEmpty ? 0 : Space.sm, bottom: Space.xs),
            child: Row(children: [
              Icon(Icons.brush_outlined, size: 13, color: nf.textFaint),
              const SizedBox(width: Space.xs),
              Expanded(child: Text(_artHeading, style: context.text.bodySmall?.copyWith(color: nf.textFaint))),
            ]),
          ),
          rows(art),
        ],
      ]);
    });
  }
}

class _Rows extends StatelessWidget {
  const _Rows({required this.entries, required this.columns, required this.form});
  final List<AccountEntry> entries;
  final int columns;
  final AccountGridForm form;

  @override
  Widget build(BuildContext context) {
    final rowGap = form == AccountGridForm.tilesNoGap ? 0.0 : _gap;
    final tile = form != AccountGridForm.names;
    return LayoutBuilder(builder: (context, box) {
      final cell = _cellWidth(box.maxWidth, columns);
      final rows = <Widget>[];
      for (final (i, row) in _rowsOf(entries, columns, form).indexed) {
        if (i > 0 && rowGap > 0) rows.add(SizedBox(height: rowGap));
        rows.add(IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (c, e) in row.indexed) ...[
              if (c > 0) const SizedBox(width: _gap),
              // Sized from the column, so a wide tile lines up with two others.
              SizedBox(width: () {
                final units = _unitsOf(e, columns, form);
                return units * cell + (units - 1) * _gap;
              }(), child: AccountCell(entry: e, tile: tile)),
            ],
          ]),
        ));
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: rows);
    });
  }
}

/// One account: its network's icon, how it posts, whether it is chosen, and
/// its name. Chosen or not reads from things that are not colour: the filled
/// mark or the empty ring, the name struck through, and the icon going flat.
/// A [tile] has everything but the name, which its tooltip and screen readers
/// still have, and a handle where its network has several accounts.
class AccountCell extends StatefulWidget {
  const AccountCell({super.key, required this.entry, this.tile = false});
  final AccountEntry entry;
  final bool tile;

  @override
  State<AccountCell> createState() => _AccountCellState();
}

class _AccountCellState extends State<AccountCell> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final e = widget.entry;
    final enabled = !e.disabled;
    final sel = e.selected && enabled;
    final leftOut = enabled && !sel && !e.artSite;
    // On the sunken fill of a disabled cell the faint shade is too pale to read.
    final quiet = enabled ? nf.textFaint : nf.textMuted;
    final tierMark = Icon(tierIcon(e.account.tier), size: _tierIconSize, color: sel ? tierTone(e.account.tier).fg(nf) : quiet);
    // A different shape for each state.
    final stateMark = Icon(
      !enabled
          ? Icons.block_rounded
          : sel
              ? Icons.check_circle_rounded
              : e.artSite
                  ? Icons.brush_outlined
                  : Icons.radio_button_unchecked_rounded,
      size: _stateIconSize,
      color: sel ? nf.accent : quiet,
    );
    final handle = e.handle == null
        ? null
        : Text(
            e.handle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _handleStyle(context)?.copyWith(color: sel || !enabled ? nf.textMuted : nf.textFaint),
          );
    return Tooltip(
      message: e.tooltip,
      child: Material(
        type: MaterialType.transparency,
        // A desktop window narrowed to this width gets the grid too, so the
        // Tab key reaches every cell that can be chosen.
        child: InkWell(
          onTap: e.onTap,
          onHover: (v) => setState(() => _hover = v),
          onFocusChange: (v) => setState(() => _focused = v),
          mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
          borderRadius: Radii.rXs,
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
              padding: const EdgeInsets.symmetric(horizontal: _cellPaddingX, vertical: _cellPaddingY),
              decoration: BoxDecoration(
                color: !enabled
                    ? nf.surfaceSunken
                    : sel
                        ? nf.accentSoft
                        : (_hover ? nf.surfaceHover : nf.surface),
                borderRadius: Radii.rXs,
                // Mostly chosen is the usual picture: chosen cells stay quiet,
                // so the ones left out are what the eye finds.
                border: Border.all(width: _cellBorder, color: sel ? nf.accent.withValues(alpha: 0.45) : (_hover && enabled ? nf.borderStrong : nf.border)),
              ),
              // Drawn over the cell, so that the name does not move.
              foregroundDecoration: _focused ? BoxDecoration(borderRadius: Radii.rXs, border: Border.all(color: nf.accent, width: 2)) : null,
              child: widget.tile && handle == null
                  ? Column(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                      _AccountFace(e, size: _tileFaceSize, dimmed: !sel),
                      const SizedBox(height: Space.xxs),
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [tierMark, const SizedBox(width: Space.xxs), stateMark]),
                    ])
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        _AccountFace(e, size: _faceSize, dimmed: !sel),
                        const Spacer(),
                        tierMark,
                        const SizedBox(width: Space.xxs),
                        stateMark,
                      ]),
                      const SizedBox(height: Space.xxs),
                      if (!widget.tile)
                        Text(
                          e.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: _nameStyle(context)?.copyWith(
                            color: !enabled
                                ? nf.textMuted
                                : sel
                                    ? nf.text
                                    : nf.textMuted,
                            decoration: leftOut ? TextDecoration.lineThrough : null,
                            decorationColor: nf.textMuted,
                          ),
                        ),
                      ?handle,
                    ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The account's photo when its network has several accounts, which the
/// network's mark alone cannot tell apart; otherwise the mark.
class _AccountFace extends StatelessWidget {
  const _AccountFace(this.entry, {required this.size, required this.dimmed});
  final AccountEntry entry;
  final double size;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final a = entry.account;
    final url = a.avatarUrl;
    if (entry.handle != null && url != null && url.startsWith('http')) {
      // No badge: the cell names the network, and at this size it would cover
      // the photo.
      return AccountAvatar(a, size: size, showBadge: false, dimmed: dimmed);
    }
    return PlatformTile(a.platformId, size: size, dimmed: dimmed);
  }
}

/// The tiers of the accounts going out, or of those left out with [leftOut],
/// each as its glyph and a count.
class AccountTierCounts extends StatelessWidget {
  const AccountTierCounts({super.key, required this.entries, this.leftOut = false});
  final List<AccountEntry> entries;
  final bool leftOut;

  /// How many of the accounts going out post each way.
  static Map<PlatformTier, int> of(List<AccountEntry> entries, {bool leftOut = false}) {
    final counts = <PlatformTier, int>{};
    for (final e in entries.where((e) => e.counted && !e.disabled && e.selected != leftOut)) {
      counts[e.account.tier] = (counts[e.account.tier] ?? 0) + 1;
    }
    return counts;
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final counts = of(entries, leftOut: leftOut);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final t in PlatformTier.values)
        if (counts[t] != null) ...[
          const SizedBox(width: Space.sm),
          Icon(tierIcon(t), size: 14, color: leftOut ? nf.textMuted : tierTone(t).fg(nf)),
          const SizedBox(width: Space.xxs),
          Text('${counts[t]}', style: context.text.bodySmall?.copyWith(color: nf.textMuted, fontWeight: FontWeight.w600)),
        ],
    ]);
  }
}

/// The grid folded, all one target that opens it. It says how many are going
/// out and how they post, and names the shorter of what is left out and what is
/// going out, each with how it posts. Left-out accounts it does not name are
/// counted per tier. Disabled accounts and art sites, which the count is not
/// about, are named whatever else is. No account's state is lost, and with
/// everything chosen it takes one line.
class AccountSelectionSummary extends StatelessWidget {
  const AccountSelectionSummary({super.key, required this.entries, required this.onOpen, this.focusNode, this.overKeyboard = false});
  final List<AccountEntry> entries;
  final VoidCallback onOpen;

  /// The fold control's focus, kept when it opens and folds.
  final FocusNode? focusNode;

  /// The keyboard is showing: a long list of names becomes icons.
  final bool overKeyboard;

  /// The accounts the summary names, and the word in front of them: `null`
  /// when everything or nothing is chosen, which the count already says.
  /// Disabled accounts are neither: [groups] names them on their own.
  static (String, List<AccountEntry>)? named(List<AccountEntry> entries) {
    final counted = entries.where((e) => e.counted && !e.disabled).toList();
    final chosen = counted.where((e) => e.selected).toList();
    final left = counted.where((e) => !e.selected).toList();
    if (left.isEmpty || chosen.isEmpty) return null;
    return left.length <= chosen.length ? ('Left out', left) : ('Only', chosen);
  }

  /// All the accounts the summary names, each list with the word in front of it.
  static List<(String, List<AccountEntry>)> groups(List<AccountEntry> entries) {
    final list = named(entries);
    final disabled = entries.where((e) => e.disabled).toList();
    final art = entries.where((e) => e.artSite && !e.disabled).toList();
    return [?list, if (disabled.isNotEmpty) ('Disabled', disabled), if (art.isNotEmpty) ('Art sites', art)];
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final counts = AccountTierCounts.of(entries);
    final leftCounts = AccountTierCounts.of(entries, leftOut: true);
    final groups = AccountSelectionSummary.groups(entries);
    // Left-out accounts are not named when "Only" is, or when nothing is chosen.
    final leftUnnamed = leftCounts.isNotEmpty && named(entries)?.$1 != 'Left out';
    final leftTotal = leftCounts.values.fold(0, (a, b) => a + b);
    final count = accountCountLabel(entries);
    // With nothing to count, the count would read "0 of 0".
    final note = count != null ? null : (entries.isEmpty ? 'No art sites connected' : 'Only art sites connected');
    final iconsOnly = overKeyboard && groups.fold(0, (n, g) => n + g.$2.length) > kSummaryNamesOverKeyboard;
    final labelStyle = context.text.bodySmall?.copyWith(color: nf.textMuted, fontWeight: FontWeight.w600);
    final words = [
      count == null ? 'Post to' : 'Post to, $count',
      ?note,
      for (final t in PlatformTier.values)
        if (counts[t] != null) '${counts[t]} ${tierShortLabel(t)}',
      for (final (word, list) in groups) '$word ${list.map((e) => _spokenName(e)).join(', ')}',
      if (leftUnnamed) 'Left out $leftTotal: ${[for (final t in PlatformTier.values) if (leftCounts[t] != null) '${leftCounts[t]} ${tierShortLabel(t)}'].join(', ')}',
      'Show all accounts',
    ];
    // The well outside: excluded semantics would take its tap action away.
    return InkWell(
      key: kTargetFoldKey,
      focusNode: focusNode,
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
              Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: AccountCountLabel(entries: entries, folded: true))),
              Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: AccountTierCounts(entries: entries))),
            ]),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.xs),
              child: Text(note, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
            ),
          if (groups.isNotEmpty || leftUnnamed)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.xs),
              child: Wrap(spacing: iconsOnly ? Space.xs : Space.sm, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                for (final (word, list) in groups) ...[
                  Padding(
                    padding: EdgeInsets.only(right: iconsOnly ? Space.xs : 0),
                    child: Text('$word:', style: labelStyle),
                  ),
                  for (final e in list) _SummaryItem(e, iconOnly: iconsOnly),
                ],
                if (leftUnnamed)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(child: Text('Left out $leftTotal:', style: labelStyle)),
                    Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: AccountTierCounts(entries: entries, leftOut: true))),
                  ]),
              ]),
            ),
        ]),
      ),
    );
  }

  static String _nameOf(AccountEntry e) => e.handle == null ? e.label : '${e.label} ${e.handle}';

  static String _spokenName(AccountEntry e) => (e.identity ?? e.handle) == null ? e.label : '${e.label} ${e.identity ?? e.handle}';
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem(this.entry, {this.iconOnly = false});
  final AccountEntry entry;

  /// The network's name goes. A handle stays: it is the only thing that tells
  /// two accounts on one network apart.
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final name = iconOnly ? entry.handle : AccountSelectionSummary._nameOf(entry);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _AccountFace(entry, size: iconOnly ? 18 : 15, dimmed: !entry.posting),
      if (name != null) ...[
        const SizedBox(width: Space.xs),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.bodySmall?.copyWith(color: nf.text, fontWeight: FontWeight.w500),
          ),
        ),
      ],
      const SizedBox(width: Space.xxs),
      Icon(tierIcon(entry.account.tier), size: 12, color: nf.textMuted),
      if (entry.disabled) ...[
        const SizedBox(width: Space.xxs),
        Icon(Icons.block_rounded, size: 12, color: nf.textMuted),
      ],
    ]);
  }
}

/// "18 of 21": going out of the accounts that could go out with this post. `null`
/// when none can, as with only art sites connected.
String? accountCountLabel(List<AccountEntry> entries) {
  final counted = entries.where((e) => e.counted);
  return counted.isEmpty ? null : '${counted.where((e) => e.posting).length} of ${counted.length}';
}

/// "Post to 18 of 21" with the fold chevron. Without [showTitle] the words
/// "Post to" go, as long as there is a count to show.
class AccountCountLabel extends StatelessWidget {
  const AccountCountLabel({super.key, required this.entries, required this.folded, this.showTitle = true});
  final List<AccountEntry> entries;
  final bool folded;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final count = accountCountLabel(entries);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (showTitle || count == null) Text('Post to', style: context.text.titleSmall?.copyWith(color: nf.textMuted)),
      if (showTitle && count != null) const SizedBox(width: Space.sm),
      if (count != null) Text(count, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
      if (showTitle) const SizedBox(width: Space.xxs),
      Icon(folded ? Icons.expand_more_rounded : Icons.expand_less_rounded, size: showTitle ? 20 : 16, color: nf.textMuted),
    ]);
  }
}
