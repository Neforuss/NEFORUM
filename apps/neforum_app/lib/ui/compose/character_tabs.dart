import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../media/glyph_support.dart';
import '../../platform/env.dart';
import '../../state/character_catalog.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

// 1.4.3: symbols. The Symbols, Kaomoji and Text styles tabs of the character
// panel (emoji_sheet.dart). Each inserts at the cursor of the text field the
// panel writes to, through the panel's callbacks, and never takes its focus.

/// Forgets the groups the tabs opened on last, for tests (through
/// `debugResetCharacterPanel`).
void debugResetCharacterTabs() {
  _SymbolsTabState._lastGroup = null;
  _KaomojiTabState._lastGroup = null;
}

/// Puts [text] in the starred set, or takes it out.
void toggleCharacterFavourite(WidgetRef ref, String text) =>
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(characterFavourites: withFavouriteToggled(s.characterFavourites, text)));

/// The style a cell of the panel draws its character in: also the style the
/// device check draws it in, so what is hidden is exactly what would be a box.
TextStyle characterCellStyle(BuildContext context, {double size = 22}) =>
    DefaultTextStyle.of(context).style.merge(TextStyle(fontSize: size, height: 1.2, color: context.nf.text));

/// Code points that draw only on a base character: left out of the device
/// check of a kaomoji, which draws them on their base.
bool _isCombining(int r) =>
    (r >= 0x0300 && r <= 0x036F) ||
    (r >= 0x1AB0 && r <= 0x1AFF) ||
    (r >= 0x1DC0 && r <= 0x1DFF) ||
    (r >= 0x20D0 && r <= 0x20FF) ||
    (r >= 0xFE00 && r <= 0xFE2F) ||
    r == 0x200D ||
    (r >= 0x0E31 && r <= 0x0E3A && r != 0x0E32 && r != 0x0E33) ||
    (r >= 0x0E47 && r <= 0x0E4E);

/// The characters of [texts] a device check tries: each code point that draws
/// on its own.
Set<String> _drawnParts(Iterable<String> texts) => {
      for (final t in texts)
        for (final r in t.runes)
          if (!_isCombining(r) && r > 0x20) String.fromCharCode(r),
    };

/// The device check, for a tab: asks once per character, and repaints when
/// the answers come.
mixin _GlyphChecks<T extends StatefulWidget> on State<T> {
  final Set<String> _asked = {};

  /// Starts trying those of [texts] nobody asked about yet, drawn in [style].
  void ensureChecked(Iterable<String> texts, TextStyle style) {
    final fresh = [for (final t in texts) if (GlyphSupport.known(t) == null && _asked.add(t)) t];
    if (fresh.isEmpty) return;
    GlyphSupport.probe(fresh, style: style).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Every one of [texts] has an answer.
  bool checked(Iterable<String> texts) => texts.every((t) => GlyphSupport.known(t) != null);

  /// This device draws [text]; false while unknown.
  bool drawn(String text) => GlyphSupport.known(text) ?? false;

  /// This device draws every part of [text] ([_drawnParts]).
  bool drawsAll(String text) => _drawnParts([text]).every(drawn);
}

/// A chip of a tab's group row.
class _GroupChip extends StatelessWidget {
  const _GroupChip({super.key, required this.label, required this.selected, required this.onTap, this.icon});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Padding(
      padding: const EdgeInsets.only(right: Space.xs),
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: selected ? nf.accentSoft : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: Radii.rPill, side: BorderSide(color: selected ? nf.accent : nf.hairline)),
          child: InkWell(
            customBorder: Radii.stadium,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.xs + 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, size: 15, color: selected ? nf.accent : nf.textMuted), const SizedBox(width: Space.xs)],
                Text(label, style: context.text.labelMedium?.copyWith(color: selected ? nf.accent : nf.textMuted)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of group chips that scrolls sideways, by touch or by dragging with
/// a mouse, with an optional [trailing] widget that stays put (the menu of
/// every group, for a mouse or a keyboard).
class _GroupRow extends StatelessWidget {
  const _GroupRow({required this.children, this.trailing});
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 40,
        child: Row(children: [
          Expanded(
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(dragDevices: PointerDeviceKind.values.toSet(), scrollbars: false),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
                children: children,
              ),
            ),
          ),
          if (trailing != null) Padding(padding: const EdgeInsets.only(right: Space.xs), child: trailing!),
        ]),
      );
}

/// The menu of every group of a tab, beside its chips.
class _GroupMenu extends StatelessWidget {
  const _GroupMenu({super.key, required this.groups, required this.selected, required this.onSelected, this.dividerBefore});
  final List<CharacterGroup> groups;
  final String selected;
  final ValueChanged<String> onSelected;

  /// A line in the menu before this group (the first Unicode block).
  final String? dividerBefore;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return PopupMenuButton<String>(
      tooltip: 'All groups',
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final g in groups) ...[
          if (g.id == dividerBefore) const PopupMenuDivider(),
          PopupMenuItem(value: g.id, child: Text(g.title, style: context.text.bodyMedium?.copyWith(fontWeight: g.id == selected ? FontWeight.w700 : null))),
        ],
      ],
      child: Padding(
        padding: const EdgeInsets.all(Space.xs),
        child: Icon(Icons.expand_more_rounded, size: 22, color: nf.textMuted),
      ),
    );
  }
}

/// A note under a tab's content.
class _Note extends StatelessWidget {
  const _Note(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.md, Space.xs),
        child: Text(text, style: context.text.bodySmall?.copyWith(color: context.nf.textMuted)),
      );
}

/// Empty content: a short line in the middle.
class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Text(text, textAlign: TextAlign.center, style: context.text.bodyMedium?.copyWith(color: context.nf.textFaint)),
        ),
      );
}

/// One symbol: a square that inserts it, with its name as tooltip and for
/// screen readers. Long press or right click stars it; a star marks the
/// starred ones.
class SymbolCell extends StatelessWidget {
  const SymbolCell({super.key, required this.entry, required this.drawn, required this.favourite, required this.onPick, required this.onToggleFavourite, this.onShow});
  final CharacterEntry entry;
  final bool drawn;
  final bool favourite;
  final ValueChanged<String> onPick;
  final VoidCallback onToggleFavourite;

  /// Hover or keyboard focus: the details bar shows this one.
  final ValueChanged<CharacterEntry>? onShow;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final star = favourite ? 'Remove from favourites' : 'Add to favourites';
    return Tooltip(
      message: entry.name,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        button: true,
        label: entry.name,
        excludeSemantics: true,
        customSemanticsActions: {CustomSemanticsAction(label: star): onToggleFavourite},
        child: InkWell(
          key: ValueKey('symbol-${entry.text}'),
          borderRadius: Radii.rSm,
          onTap: () => onPick(entry.text),
          onLongPress: onToggleFavourite,
          onSecondaryTap: onToggleFavourite,
          onHover: (inside) {
            if (inside) onShow?.call(entry);
          },
          onFocusChange: (focused) {
            if (focused) onShow?.call(entry);
          },
          child: Stack(children: [
            Center(
              child: drawn
                  ? Text(entry.text, maxLines: 1, softWrap: false, overflow: TextOverflow.visible, textScaler: TextScaler.noScaling, style: characterCellStyle(context))
                  : Icon(Icons.image_not_supported_outlined, size: 20, color: nf.textFaint),
            ),
            if (favourite) Positioned(right: 2, top: 2, child: Icon(Icons.star_rounded, size: 10, color: nf.accent)),
          ]),
        ),
      ),
    );
  }
}

/// A grid of [entries] under an optional [title].
class _SymbolGridSliver extends StatelessWidget {
  const _SymbolGridSliver({required this.entries, required this.cell});
  final List<CharacterEntry> entries;
  final Widget Function(CharacterEntry e) cell;

  @override
  Widget build(BuildContext context) => SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xs),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 44, mainAxisExtent: 44),
          delegate: SliverChildBuilderDelegate((context, i) => cell(entries[i]), childCount: entries.length),
        ),
      );
}

/// The Symbols tab: the user's recent and starred characters, NEFORUM's sets
/// (Popular, Hearts, Arrows...), then every chosen Unicode block from a menu.
/// Characters this device cannot draw are left out of the grid; search still
/// finds them, as a plain icon.
class SymbolsTab extends ConsumerStatefulWidget {
  const SymbolsTab({super.key, required this.catalog, required this.query, required this.onPick});
  final CharacterCatalog catalog;
  final String query;
  final ValueChanged<String> onPick;

  @override
  ConsumerState<SymbolsTab> createState() => _SymbolsTabState();
}

class _SymbolsTabState extends ConsumerState<SymbolsTab> with _GlyphChecks {
  static String? _lastGroup;

  /// 'recent', 'favourites', or a [CharacterGroup.id].
  late String _group;
  late final List<String> _recents;
  CharacterEntry? _shown;

  @override
  void initState() {
    super.initState();
    _recents = ref.read(settingsProvider).emojiRecents;
    _group = _lastGroup ?? (_recents.isNotEmpty ? 'recent' : 'popular');
  }

  List<CharacterGroup> get _groups => widget.catalog.groups(CharacterTab.symbols);

  List<CharacterEntry> _entriesOf(String group, List<String> favourites) => switch (group) {
        'recent' => [for (final t in _recents) widget.catalog.entryFor(t) ?? CharacterEntry(t, 'Recent')],
        'favourites' => [for (final t in favourites) widget.catalog.entryFor(t) ?? CharacterEntry(t, 'Favourite')],
        _ => _groups.where((g) => g.id == group).firstOrNull?.entries.toList() ?? const [],
      };

  void _select(String group) => setState(() {
        _group = group;
        _lastGroup = group;
      });

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final favourites = ref.watch(settingsProvider.select((s) => s.characterFavourites));
    final searching = widget.query.trim().isNotEmpty;
    final entries = searching ? widget.catalog.search(widget.query, CharacterTab.symbols) : _entriesOf(_group, favourites);
    final texts = [for (final e in entries) e.text];
    ensureChecked(texts, characterCellStyle(context));
    final settled = checked(texts);
    // Browsing hides what this device cannot draw; search and the user's own
    // lists keep it, as a plain icon, since it still goes out in the post.
    final keepUndrawn = searching || _group == 'recent' || _group == 'favourites';
    final shown = [for (final e in entries) if (keepUndrawn || drawn(e.text)) e];
    final anyUndrawn = settled && shown.any((e) => !drawn(e.text));
    final block = _groups.where((g) => g.id == _group && g.isBlock).firstOrNull;

    Widget cell(CharacterEntry e) => SymbolCell(
          entry: e,
          drawn: drawn(e.text),
          favourite: favourites.contains(e.text),
          onPick: widget.onPick,
          onToggleFavourite: () => toggleCharacterFavourite(ref, e.text),
          onShow: (e) => setState(() => _shown = e),
        );

    final slivers = <Widget>[];
    if (!searching && block != null) {
      for (final s in block.sections) {
        final visible = [for (final e in s.entries) if (drawn(e.text)) e];
        if (visible.isEmpty) continue;
        if (block.sections.length > 1) {
          slivers.add(SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.xxs),
              child: Text(s.title, style: context.text.labelMedium?.copyWith(color: nf.textMuted)),
            ),
          ));
        }
        slivers.add(_SymbolGridSliver(entries: visible, cell: cell));
      }
    } else {
      slivers.add(_SymbolGridSliver(entries: shown, cell: cell));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!searching)
        _GroupRow(
          trailing: _GroupMenu(
            key: const Key('symbols-groups'),
            groups: _groups,
            selected: _group,
            onSelected: _select,
            dividerBefore: _groups.where((g) => g.isBlock).firstOrNull?.id,
          ),
          children: [
            if (_recents.isNotEmpty) _GroupChip(key: const Key('symbols-group-recent'), label: 'Recent', icon: Icons.history_rounded, selected: _group == 'recent', onTap: () => _select('recent')),
            _GroupChip(key: const Key('symbols-group-favourites'), label: 'Favourites', icon: Icons.star_outline_rounded, selected: _group == 'favourites', onTap: () => _select('favourites')),
            // A block chosen from the menu shows as the chip after them.
            if (block != null) _GroupChip(key: Key('symbols-group-${block.id}'), label: block.title, selected: true, onTap: () {}),
            for (final g in _groups.where((g) => !g.isBlock)) _GroupChip(key: Key('symbols-group-${g.id}'), label: g.title, selected: _group == g.id, onTap: () => _select(g.id)),
          ],
        ),
      Divider(height: 1, color: nf.hairline),
      Expanded(
        child: !settled && !keepUndrawn
            ? const SizedBox.shrink()
            : shown.isEmpty
                ? _Empty(searching
                    ? 'No symbols found'
                    : _group == 'favourites'
                        ? 'Long press or right-click a character to add it to your favourites.'
                        : 'Nothing here yet.')
                : CustomScrollView(key: PageStorageKey('symbols-$_group-$searching'), slivers: [...slivers, const SliverToBoxAdapter(child: SizedBox(height: Space.xs))]),
      ),
      if (anyUndrawn) const _Note('This device cannot show the characters marked with a plain icon. They still go out in your post, and show on devices that have them.'),
      _DetailsBar(entry: _shown, favourite: _shown != null && favourites.contains(_shown!.text), onToggle: _shown == null ? null : () => toggleCharacterFavourite(ref, _shown!.text)),
    ]);
  }
}


/// Under the Symbols grid: the name of the character under the pointer or the
/// keyboard, its code point, its Alt code on Windows and its HTML code, and a
/// star to keep it.
class _DetailsBar extends StatelessWidget {
  const _DetailsBar({required this.entry, required this.favourite, required this.onToggle});
  final CharacterEntry? entry;
  final bool favourite;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final e = entry;
    final codes = e == null
        ? 'Point at a character to see its name. Long press or right-click to add it to your favourites.'
        : [
            e.codePoints,
            if (e.altCode != null && Env.isWindows) 'Alt+${e.altCode}',
            e.htmlCode,
          ].join('  ·  ');
    return Container(
      key: const Key('symbols-details'),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: nf.hairline))),
      padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.xs, Space.xs),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (e != null) Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelMedium),
            Text(codes, maxLines: e == null ? 2 : 1, overflow: TextOverflow.ellipsis, style: e == null ? context.text.bodySmall?.copyWith(color: nf.textFaint) : monoStyle(context, size: 11, color: nf.textMuted)),
          ]),
        ),
        if (e != null)
          IconButton(
            key: const Key('symbols-details-star'),
            tooltip: favourite ? 'Remove from favourites' : 'Add to favourites',
            onPressed: onToggle,
            icon: Icon(favourite ? Icons.star_rounded : Icons.star_outline_rounded, size: 20, color: favourite ? nf.accent : nf.textMuted),
          ),
      ]),
    );
  }
}

/// One kaomoji (or any recent or starred text): a button as wide as it is.
class TextCell extends StatelessWidget {
  const TextCell({super.key, required this.text, required this.label, required this.drawn, required this.favourite, required this.onPick, required this.onToggleFavourite});
  final String text;
  final String label;
  final bool drawn;
  final bool favourite;
  final ValueChanged<String> onPick;
  final VoidCallback onToggleFavourite;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final star = favourite ? 'Remove from favourites' : 'Add to favourites';
    return Semantics(
      button: true,
      label: '$label: $text',
      excludeSemantics: true,
      customSemanticsActions: {CustomSemanticsAction(label: star): onToggleFavourite},
      child: Tooltip(
        message: favourite ? '$label. Long press or right-click to remove from favourites' : '$label. Long press or right-click to add to favourites',
        waitDuration: const Duration(milliseconds: 800),
        child: Material(
          color: nf.surfaceSunken,
          shape: RoundedRectangleBorder(borderRadius: Radii.rSm, side: BorderSide(color: favourite ? nf.accent : nf.border)),
          child: InkWell(
            key: ValueKey('text-cell-$text'),
            borderRadius: Radii.rSm,
            onTap: () => onPick(text),
            onLongPress: onToggleFavourite,
            onSecondaryTap: onToggleFavourite,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs + 2),
              child: drawn
                  ? Text(text, maxLines: 1, softWrap: false, overflow: TextOverflow.fade, textScaler: TextScaler.noScaling, style: characterCellStyle(context, size: 16))
                  : Icon(Icons.image_not_supported_outlined, size: 18, color: nf.textFaint),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Kaomoji tab: NEFORUM's own set by feeling, recent and starred ones,
/// and a builder where the user picks arms, face, eyes and mouth.
class KaomojiTab extends ConsumerStatefulWidget {
  const KaomojiTab({super.key, required this.catalog, required this.query, required this.onPick});
  final CharacterCatalog catalog;
  final String query;
  final ValueChanged<String> onPick;

  @override
  ConsumerState<KaomojiTab> createState() => _KaomojiTabState();
}

class _KaomojiTabState extends ConsumerState<KaomojiTab> with _GlyphChecks {
  static String? _lastGroup;
  late String _group;
  late final List<String> _recents;

  // The builder's choices.
  int _arm = 1, _edge = 0, _eye = 0, _mouth = 0;

  @override
  void initState() {
    super.initState();
    _recents = ref.read(settingsProvider).emojiRecents;
    _group = _lastGroup ?? (_recents.isNotEmpty ? 'recent' : 'kaomoji:${kKaomojiGroups.first.id}');
  }

  List<CharacterGroup> get _groups => widget.catalog.groups(CharacterTab.kaomoji);

  void _select(String group) => setState(() {
        _group = group;
        _lastGroup = group;
      });

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final favourites = ref.watch(settingsProvider.select((s) => s.characterFavourites));
    final searching = widget.query.trim().isNotEmpty;
    final building = !searching && _group == 'build';
    final List<({String text, String label})> items = searching
        ? [for (final e in widget.catalog.search(widget.query, CharacterTab.kaomoji)) (text: e.text, label: e.name)]
        : switch (_group) {
            'recent' => [for (final t in _recents) (text: t, label: widget.catalog.entryFor(t)?.name ?? 'Recent')],
            'favourites' => [for (final t in favourites) (text: t, label: widget.catalog.entryFor(t)?.name ?? 'Favourite')],
            'build' => const [],
            _ => [for (final e in _groups.where((g) => g.id == _group).firstOrNull?.entries ?? const <CharacterEntry>[]) (text: e.text, label: e.name)],
          };
    final builderParts = [
      for (final p in [...KaomojiBuilder.arms, ...KaomojiBuilder.edges, ...KaomojiBuilder.eyes]) ...[p.left, p.right],
      ...KaomojiBuilder.mouths,
    ];
    final parts = _drawnParts(building ? builderParts : items.map((i) => i.text));
    ensureChecked(parts, characterCellStyle(context, size: 16));
    final settled = checked(parts);
    final keepUndrawn = searching || _group == 'recent' || _group == 'favourites';
    final shown = [for (final i in items) if (keepUndrawn || drawsAll(i.text)) i];
    final anyUndrawn = settled && shown.any((i) => !drawsAll(i.text));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!searching)
        _GroupRow(
          trailing: _GroupMenu(key: const Key('kaomoji-groups'), groups: _groups, selected: _group, onSelected: _select),
          children: [
            if (_recents.isNotEmpty) _GroupChip(key: const Key('kaomoji-group-recent'), label: 'Recent', icon: Icons.history_rounded, selected: _group == 'recent', onTap: () => _select('recent')),
            _GroupChip(key: const Key('kaomoji-group-favourites'), label: 'Favourites', icon: Icons.star_outline_rounded, selected: _group == 'favourites', onTap: () => _select('favourites')),
            _GroupChip(key: const Key('kaomoji-group-build'), label: 'Build your own', icon: Icons.construction_rounded, selected: building, onTap: () => _select('build')),
            for (final g in _groups) _GroupChip(key: Key('kaomoji-group-${g.id}'), label: g.title, selected: _group == g.id, onTap: () => _select(g.id)),
          ],
        ),
      Divider(height: 1, color: nf.hairline),
      Expanded(
        child: !settled
            ? const SizedBox.shrink()
            : building
                ? _builder(context)
                : shown.isEmpty
                    ? _Empty(searching
                        ? 'No kaomoji found'
                        : _group == 'favourites'
                            ? 'Long press or right-click a kaomoji to add it to your favourites.'
                            : 'Nothing here yet.')
                    : SingleChildScrollView(
                        key: PageStorageKey('kaomoji-$_group-$searching'),
                        padding: const EdgeInsets.all(Space.sm),
                        child: Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
                          for (final i in shown)
                            TextCell(
                              text: i.text,
                              label: i.label,
                              drawn: drawsAll(i.text),
                              favourite: favourites.contains(i.text),
                              onPick: widget.onPick,
                              onToggleFavourite: () => toggleCharacterFavourite(ref, i.text),
                            ),
                        ]),
                      ),
      ),
      if (anyUndrawn) const _Note('This device cannot show the kaomoji marked with a plain icon. They still go out in your post.'),
    ]);
  }

  Widget _builder(BuildContext context) {
    final nf = context.nf;
    bool ok(String s) => s.isEmpty || drawsAll(s);
    final arms = [for (var i = 0; i < KaomojiBuilder.arms.length; i++) if (ok(KaomojiBuilder.arms[i].left) && ok(KaomojiBuilder.arms[i].right)) i];
    final edges = [for (var i = 0; i < KaomojiBuilder.edges.length; i++) if (ok(KaomojiBuilder.edges[i].left) && ok(KaomojiBuilder.edges[i].right)) i];
    final eyes = [for (var i = 0; i < KaomojiBuilder.eyes.length; i++) if (ok(KaomojiBuilder.eyes[i].left) && ok(KaomojiBuilder.eyes[i].right)) i];
    final mouths = [for (var i = 0; i < KaomojiBuilder.mouths.length; i++) if (ok(KaomojiBuilder.mouths[i])) i];
    final made = KaomojiBuilder.build(arm: KaomojiBuilder.arms[_arm], edge: KaomojiBuilder.edges[_edge], eye: KaomojiBuilder.eyes[_eye], mouth: KaomojiBuilder.mouths[_mouth]);

    Widget row(String title, List<int> options, int value, String Function(int i) label, ValueChanged<int> pick) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, 0), child: Text(title, style: context.text.labelMedium?.copyWith(color: nf.textMuted))),
          _GroupRow(children: [
            for (final i in options)
              _GroupChip(key: Key('kaomoji-build-$title-$i'), label: label(i).isEmpty ? 'None' : label(i), selected: value == i, onTap: () => setState(() => pick(i))),
          ]),
        ]);

    return ListView(padding: const EdgeInsets.only(bottom: Space.sm), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.md, Space.xs),
        child: Row(children: [
          Expanded(
            child: Text(made, key: const Key('kaomoji-build-preview'), maxLines: 1, overflow: TextOverflow.fade, softWrap: false, style: characterCellStyle(context, size: 26)),
          ),
          const SizedBox(width: Space.sm),
          OutlinedButton.icon(key: const Key('kaomoji-build-insert'), onPressed: () => widget.onPick(made), icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Insert')),
        ]),
      ),
      row('Arms', arms, _arm, (i) => '${KaomojiBuilder.arms[i].left}  ${KaomojiBuilder.arms[i].right}'.trim(), (i) => _arm = i),
      row('Face', edges, _edge, (i) => '${KaomojiBuilder.edges[i].left}  ${KaomojiBuilder.edges[i].right}'.trim(), (i) => _edge = i),
      row('Eyes', eyes, _eye, (i) => '${KaomojiBuilder.eyes[i].left}  ${KaomojiBuilder.eyes[i].right}', (i) => _eye = i),
      row('Mouth', mouths, _mouth, (i) => KaomojiBuilder.mouths[i], (i) => _mouth = i),
    ]);
  }
}

/// The Text styles tab: the selected text (or text typed here) in each
/// style, with what it costs on each chosen network. A tap puts the styled
/// text in place of the selection, or at the cursor. Nothing is styled
/// unless the user taps a style.
class TextStylesTab extends ConsumerStatefulWidget {
  const TextStylesTab({super.key, required this.catalog, required this.query, required this.selection, required this.onStyle, this.showCosts = false});
  final CharacterCatalog catalog;
  final String query;

  /// The text selected in the field the panel writes to, or ''.
  final String Function() selection;

  /// Puts the styled text in place of the selection (or at the cursor).
  final ValueChanged<String> onStyle;

  /// Shows each style's length on the composer's chosen networks.
  final bool showCosts;

  @override
  ConsumerState<TextStylesTab> createState() => _TextStylesTabState();
}

class _TextStylesTabState extends ConsumerState<TextStylesTab> with _GlyphChecks {
  final TextEditingController _own = TextEditingController();

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  static const String _sample = 'Your text 123';

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final ts = widget.catalog.textStyles;
    final selected = widget.selection();
    final source = selected.isNotEmpty ? selected : _own.text;
    final usable = source.trim().isNotEmpty;
    final kinds = [for (final k in TextStyleKind.values) if (k.matches(widget.query) || widget.query.trim().isEmpty) k];
    // Each style tried on this device by its letters and digits: a style
    // the fonts here cannot draw is not offered.
    final samples = {for (final k in kinds) k: ts.apply(k, 'AaZz09')};
    final parts = _drawnParts(samples.values);
    ensureChecked(parts, characterCellStyle(context, size: 16));
    final settled = checked(parts);
    final offered = [for (final k in kinds) if (drawsAll(samples[k]!)) k];
    final networks = widget.showCosts ? _distinctRules(ref.watch(composerPreviewsProvider)) : const <({String name, TextRules rules})>[];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _Note('Screen readers may spell styled letters one by one or skip them. Use them for a word or two, not a whole post.', key: Key('text-styles-note')),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.md, Space.sm),
        child: selected.isNotEmpty
            ? Text('Styles your selection: "${cutToCharacters(selected, 40)}"',
                key: const Key('text-styles-selection'), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelMedium)
            : TextField(
                key: const Key('text-styles-input'),
                controller: _own,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'Select text in your post, or type it here', isDense: true),
              ),
      ),
      Divider(height: 1, color: nf.hairline),
      Expanded(
        child: !settled
            ? const SizedBox.shrink()
            : offered.isEmpty
                ? const _Empty('No styles found')
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: Space.xs),
                    itemCount: offered.length,
                    separatorBuilder: (_, _) => Divider(height: 1, indent: Space.md, endIndent: Space.md, color: nf.hairline),
                    itemBuilder: (context, i) {
                      final k = offered[i];
                      final styled = ts.apply(k, usable ? source : _sample);
                      final cost = usable && networks.isNotEmpty ? networks.map((n) => '${n.name} ${TextCounter.count(styled, n.rules)}').join(' · ') : null;
                      return InkWell(
                        key: ValueKey('text-style-${k.name}'),
                        onTap: usable
                            ? () {
                                widget.onStyle(styled);
                                setState(() {});
                              }
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(k.label, style: context.text.labelSmall?.copyWith(color: nf.textMuted)),
                            const SizedBox(height: Space.xxs),
                            Text(styled, maxLines: 1, overflow: TextOverflow.ellipsis, style: characterCellStyle(context, size: 17).copyWith(color: usable ? nf.text : nf.textFaint)),
                            if (cost != null) Text(cost, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 10.5, color: nf.textFaint)),
                          ]),
                        ),
                      );
                    },
                  ),
      ),
    ]);
  }
}

/// The chosen networks with a character limit, one per way of counting.
List<({String name, TextRules rules})> _distinctRules(List<TargetPreview> previews) {
  final seen = <String>{};
  return [
    for (final p in previews)
      if (p.descriptor.text.maxLength != null && seen.add('${p.descriptor.text.counting.name}/${p.descriptor.text.urlWeight}'))
        (name: p.descriptor.compactName, rules: p.descriptor.text),
  ];
}

/// Under the panel in the composer: how much room each chosen network has
/// left. An insert never blocks; a network that goes over says so here and
/// in its preview, the others are untouched.
class CharacterBudgetStrip extends ConsumerWidget {
  const CharacterBudgetStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final rows = <({String name, int left, int parts})>[
      for (final p in ref.watch(composerPreviewsProvider))
        if (p.descriptor.text.maxLength != null)
          (
            name: p.descriptor.compactName,
            left: p.descriptor.text.maxLength! - TextCounter.count(p.variant.text, p.descriptor.text),
            parts: p.variant.isThread ? p.variant.threadParts.length : 1,
          ),
    ];
    // The tightest first: networks that make a thread, then the least room.
    int rank(({String name, int left, int parts}) r) => r.parts > 1 ? -1 << 30 : r.left;
    rows.sort((a, b) => rank(a).compareTo(rank(b)));
    if (rows.isEmpty) return const SizedBox.shrink();
    String say(({String name, int left, int parts}) r) => r.parts > 1
        ? '${r.name} ${r.parts}-part thread'
        : r.left < 0
            ? '${r.name} ${-r.left} over'
            : '${r.name} ${r.left} left';
    return Container(
      key: const Key('character-budget'),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: nf.hairline))),
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.xs),
      child: Text.rich(
        TextSpan(children: [
          for (var i = 0; i < rows.length && i < 4; i++) ...[
            if (i > 0) const TextSpan(text: '  ·  '),
            TextSpan(
              text: say(rows[i]),
              style: TextStyle(
                color: rows[i].parts == 1 && rows[i].left < 0
                    ? nf.danger
                    : rows[i].parts > 1
                        ? nf.warning
                        : nf.textMuted,
                fontWeight: rows[i].parts > 1 || rows[i].left < 0 ? FontWeight.w700 : null,
              ),
            ),
          ],
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: monoStyle(context, size: 11),
      ),
    );
  }
}

/// [text] cut to whole characters (grapheme clusters).
String cutToCharacters(String text, int max) => text.characters.length <= max ? text : '${text.characters.take(max)}…';
