import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' show CharacterCatalog, CharacterTab;
import 'package:unicode_emojis/unicode_emojis.dart';

import '../../media/emoji_text.dart';
import '../../state/character_catalog.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import 'character_tabs.dart';
import 'emoji_catalog.dart';

/// The five skin tones and the default, as the tone row shows them.
const List<({String name, Color color})> kEmojiTones = [
  (name: 'Default', color: Color(0xFFFFC83D)),
  (name: 'Light', color: Color(0xFFF7DECE)),
  (name: 'Medium light', color: Color(0xFFF3D2A2)),
  (name: 'Medium', color: Color(0xFFD5AB88)),
  (name: 'Medium dark', color: Color(0xFFAF7E57)),
  (name: 'Dark', color: Color(0xFF7C533E)),
];

const Map<Category, IconData> _categoryIcons = {
  Category.smileysAndEmotion: Icons.emoji_emotions_outlined,
  Category.peopleAndBody: Icons.emoji_people_outlined,
  Category.animalsAndNature: Icons.emoji_nature_outlined,
  Category.foodAndDrink: Icons.emoji_food_beverage_outlined,
  Category.travelAndPlaces: Icons.emoji_transportation_outlined,
  Category.activities: Icons.emoji_events_outlined,
  Category.objects: Icons.emoji_objects_outlined,
  Category.symbols: Icons.emoji_symbols_outlined,
  Category.flags: Icons.emoji_flags_outlined,
};

/// The tabs of the character panel, with what they show.
const List<({CharacterTab tab, String label, IconData icon, String hint})> kCharacterTabs = [
  (tab: CharacterTab.emoji, label: 'Emoji', icon: Icons.emoji_emotions_outlined, hint: 'Search emoji'),
  (tab: CharacterTab.symbols, label: 'Symbols', icon: Icons.emoji_symbols_outlined, hint: 'Search symbols'),
  (tab: CharacterTab.kaomoji, label: 'Kaomoji', icon: Icons.mood_outlined, hint: 'Search kaomoji'),
  (tab: CharacterTab.textStyles, label: 'Text styles', icon: Icons.text_format_rounded, hint: 'Search styles'),
];

/// The character panel (the emoji sheet since 1.4): Emoji, Symbols, Kaomoji
/// and Text styles tabs (1.4.3), one search for the open tab, recent and
/// starred characters. Works the same on every system, over data in the app:
/// nothing here goes over the network. [onPick] gets each emoji, symbol or
/// kaomoji; the sheet stays open.
class EmojiPanel extends ConsumerStatefulWidget {
  const EmojiPanel({super.key, required this.onPick, required this.onClose, this.selection, this.onStyle, this.showBudget = false});
  final ValueChanged<String> onPick;
  final VoidCallback onClose;

  /// The text selected in the field the panel writes to (Text styles).
  final String Function()? selection;

  /// Puts styled text in place of the selection, or at the cursor; not
  /// remembered as a recent character. Defaults to [onPick].
  final ValueChanged<String>? onStyle;

  /// Shows how much room each chosen network has left (the composer).
  final bool showBudget;

  @override
  ConsumerState<EmojiPanel> createState() => _EmojiPanelState();
}

/// Forgets the tab and groups the panel opened on last, for tests.
@visibleForTesting
void debugResetCharacterPanel() {
  _EmojiPanelState._lastTab = CharacterTab.emoji;
  debugResetCharacterTabs();
}

class _EmojiPanelState extends ConsumerState<EmojiPanel> {
  /// The tab the panel opened on last, for the rest of the run.
  static CharacterTab _lastTab = CharacterTab.emoji;

  final TextEditingController _search = TextEditingController();
  CharacterTab _tab = _lastTab;

  /// The recent list as the sheet opened: it does not reorder under the pointer
  /// while picking. The Emoji tab shows the single characters of it.
  late final List<String> _recents;

  /// Null shows the recent emoji.
  Category? _category;

  /// The starred emoji instead of a category.
  bool _favourites = false;
  EmojiDeviceSupport _support = EmojiDeviceSupport.assumed;

  @override
  void initState() {
    super.initState();
    _recents = [for (final r in ref.read(settingsProvider).emojiRecents) if (r.characters.length == 1) r];
    if (_recents.isEmpty) _category = Category.smileysAndEmotion;
    emojiDeviceSupport().then((s) {
      if (mounted) setState(() => _support = s);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setTab(CharacterTab tab) => setState(() {
        _tab = tab;
        _lastTab = tab;
      });

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final hint = kCharacterTabs.firstWhere((t) => t.tab == _tab).hint;
    final catalog = ref.watch(characterCatalogProvider);
    final query = _search.text.trim();
    final Widget body;
    if (_tab == CharacterTab.emoji) {
      body = _emoji(context, catalog.value);
    } else {
      body = catalog.when(
        data: (c) => switch (_tab) {
          CharacterTab.symbols => SymbolsTab(catalog: c, query: query, onPick: widget.onPick),
          CharacterTab.kaomoji => KaomojiTab(catalog: c, query: query, onPick: widget.onPick),
          _ => TextStylesTab(catalog: c, query: query, selection: widget.selection ?? () => '', onStyle: widget.onStyle ?? widget.onPick, showCosts: widget.showBudget),
        },
        loading: () => const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
        error: (e, _) => Center(child: Text('The symbols could not be read: $e', style: context.text.bodySmall?.copyWith(color: nf.danger))),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.xs, Space.xs),
        child: Row(children: [
          Expanded(
            child: TextField(
              key: const Key('emoji-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(hintText: hint, prefixIcon: const Icon(Icons.search_rounded, size: 20), isDense: true),
            ),
          ),
          IconButton(key: const Key('emoji-close'), tooltip: 'Close', icon: const Icon(Icons.close_rounded, size: 20), onPressed: widget.onClose),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xs),
        child: Row(children: [
          for (final t in kCharacterTabs)
            Expanded(child: _TabButton(key: Key('character-tab-${t.tab.name}'), label: t.label, icon: t.icon, selected: _tab == t.tab, onTap: () => _setTab(t.tab))),
        ]),
      ),
      Divider(height: 1, color: nf.hairline),
      Expanded(child: KeyedSubtree(key: ValueKey(_tab), child: body)),
      if (widget.showBudget) const CharacterBudgetStrip(),
    ]);
  }

  void _setTone(int tone) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(emojiSkinTone: tone));

  /// A recent emoji may have come from search, or from a device that drew it.
  bool _drawsRecent(String glyph) {
    final e = emojiByGlyph(glyph);
    return e == null || _support.draws(e);
  }

  void _showCategory(Category? c) => setState(() {
        _category = c;
        _favourites = false;
      });

  /// The Emoji tab under the search: tones, categories, the grid.
  Widget _emoji(BuildContext context, CharacterCatalog? catalog) {
    final nf = context.nf;
    final tone = ref.watch(settingsProvider.select((s) => s.emojiSkinTone));
    final starred = [for (final f in ref.watch(settingsProvider.select((s) => s.characterFavourites))) if (f.characters.length == 1) f];
    final query = _search.text.trim();
    final searching = query.isNotEmpty;
    final List<Emoji> found = searching
        ? searchEmoji(query, keywords: catalog?.keywordsFor)
        : (_category == null || _favourites ? const [] : emojiOf(_category!).where(_support.draws).toList());
    final listShown = !searching && (_category == null || _favourites);
    final list = _favourites ? starred : _recents;
    final anyUndrawable = searching ? found.any((e) => !_support.draws(e)) : listShown && list.any((g) => !_drawsRecent(g));
    final showFlagsNote = _support.flagsInPieces && (_category == Category.flags || (searching && found.any((e) => e.category == Category.flags)));
    void toggle(String glyph) => toggleCharacterFavourite(ref, glyph);
    final favourites = ref.watch(settingsProvider.select((s) => s.characterFavourites)).toSet();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.md),
        child: Row(children: [
          Flexible(child: Text('Skin tone', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelMedium?.copyWith(color: nf.textMuted))),
          const SizedBox(width: Space.sm),
          for (var i = 0; i < kEmojiTones.length; i++) _ToneSwatch(index: i, selected: i == tone, onTap: () => _setTone(i)),
        ]),
      ),
      if (!searching)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          child: Row(children: [
            if (_recents.isNotEmpty)
              Expanded(child: _CategoryButton(key: const Key('emoji-category-recent'), icon: Icons.history_rounded, tooltip: 'Recent', selected: _category == null && !_favourites, onTap: () => _showCategory(null))),
            if (starred.isNotEmpty || _favourites)
              Expanded(
                child: _CategoryButton(
                  key: const Key('emoji-category-favourites'),
                  icon: Icons.star_outline_rounded,
                  tooltip: 'Favourites',
                  selected: _favourites,
                  onTap: () => setState(() => _favourites = true),
                ),
              ),
            for (final c in Category.values)
              Expanded(child: _CategoryButton(key: Key('emoji-category-${c.name}'), icon: _categoryIcons[c]!, tooltip: c.description, selected: _category == c && !_favourites, onTap: () => _showCategory(c))),
          ]),
        ),
      Divider(height: 1, color: nf.hairline),
      Expanded(
        child: listShown
            ? list.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.lg),
                      child: Text('Long press or right-click an emoji to add it to your favourites.', textAlign: TextAlign.center, style: context.text.bodyMedium?.copyWith(color: nf.textFaint)),
                    ),
                  )
                : _Grid(
                    key: PageStorageKey(_favourites ? 'emoji-favourites' : 'emoji-recent'),
                    glyphs: [for (final g in list) (glyph: g, name: emojiByGlyph(g)?.name ?? catalog?.entryFor(g)?.name ?? 'Emoji', drawn: _drawsRecent(g), id: g)],
                    favourites: favourites,
                    onPick: widget.onPick,
                    onToggleFavourite: toggle,
                  )
            : found.isEmpty
                ? Center(child: Padding(padding: const EdgeInsets.all(Space.lg), child: Text(!_support.anyFont && !searching ? 'Search by name to add an emoji.' : 'No emoji found', textAlign: TextAlign.center, style: context.text.bodyMedium?.copyWith(color: nf.textFaint))))
                : _Grid(
                    key: PageStorageKey('emoji-${_category?.name}-$searching'),
                    glyphs: [
                      for (final e in found) (glyph: emojiAtTone(e, tone), name: e.name, drawn: _support.draws(e), id: e.unified),
                    ],
                    favourites: favourites,
                    onPick: widget.onPick,
                    onToggleFavourite: toggle,
                  ),
      ),
      if (anyUndrawable || showFlagsNote || !_support.anyFont)
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.md, Space.sm),
          child: Text(
            !_support.anyFont
                ? 'This device has no emoji font, so emoji cannot be shown here. They still go out in your post.'
                : anyUndrawable
                    ? 'This device cannot show the emoji marked with a plain icon. They still go out in your post, and show on devices that have them.'
                    : 'Flags look like letters on this device. The networks show them as flags, but a text card made here shows the letters.',
            style: context.text.bodySmall?.copyWith(color: nf.textMuted),
          ),
        ),
    ]);
  }
}

typedef _Glyph = ({String glyph, String name, bool drawn, String id});

class _Grid extends StatelessWidget {
  const _Grid({super.key, required this.glyphs, required this.onPick, required this.favourites, required this.onToggleFavourite});
  final List<_Glyph> glyphs;
  final ValueChanged<String> onPick;

  /// 1.4.3: starred ones get a star; long press or right click stars.
  final Set<String> favourites;
  final ValueChanged<String> onToggleFavourite;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(Space.xs),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 44, mainAxisExtent: 44),
      itemCount: glyphs.length,
      itemBuilder: (context, i) {
        final g = glyphs[i];
        final starred = favourites.contains(g.glyph);
        return Tooltip(
          message: g.name,
          waitDuration: const Duration(milliseconds: 600),
          child: Semantics(
            button: true,
            label: g.name,
            excludeSemantics: true,
            customSemanticsActions: {CustomSemanticsAction(label: starred ? 'Remove from favourites' : 'Add to favourites'): () => onToggleFavourite(g.glyph)},
            child: InkWell(
              key: ValueKey('emoji-${g.id}'),
              borderRadius: Radii.rSm,
              onTap: () => onPick(g.glyph),
              onLongPress: () => onToggleFavourite(g.glyph),
              onSecondaryTap: () => onToggleFavourite(g.glyph),
              child: Stack(children: [
                Center(
                  child: g.drawn
                      ? Text(
                          g.glyph,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.visible,
                          textScaler: TextScaler.noScaling,
                          style: emojiStyleOf(const TextStyle(fontSize: 24, height: 1.2)),
                        )
                      : Icon(Icons.image_not_supported_outlined, size: 22, color: context.nf.textFaint),
                ),
                if (starred) Positioned(right: 2, top: 2, child: Icon(Icons.star_rounded, size: 10, color: context.nf.accent)),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _ToneSwatch extends StatelessWidget {
  const _ToneSwatch({required this.index, required this.selected, required this.onTap});
  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final tone = kEmojiTones[index];
    return Tooltip(
      message: '${tone.name} skin tone',
      child: Semantics(
        button: true,
        selected: selected,
        label: '${tone.name} skin tone',
        excludeSemantics: true,
        child: InkWell(
          key: Key('emoji-tone-$index'),
          customBorder: Radii.circleBorder,
          onTap: onTap,
          child: SizedBox(
            width: 34,
            height: 36,
            child: Center(
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: tone.color,
                  shape: Radii.circleShape,
                  border: Border.all(color: selected ? nf.accent : nf.borderStrong, width: selected ? 3 : 1),
                ),
                // Not by colour alone.
                // 1.4.3: white or ink, whichever reads on the tone.
                child: selected ? Icon(Icons.check_rounded, size: 12, color: readableOn(tone.color)) : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One tab of the panel: an icon over its name.
class _TabButton extends StatelessWidget {
  const _TabButton({super.key, required this.label, required this.icon, required this.selected, required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final color = selected ? nf.accent : nf.textMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: selected ? nf.accent : Colors.transparent, width: 2))),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18, color: color),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label, maxLines: 1, style: context.text.labelSmall?.copyWith(color: color, fontWeight: selected ? FontWeight.w700 : null)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _CategoryButton extends StatelessWidget {
  const _CategoryButton({super.key, required this.icon, required this.tooltip, required this.selected, required this.onTap});
  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: selected ? nf.accent : Colors.transparent, width: 2))),
            child: Icon(icon, size: 19, color: selected ? nf.accent : nf.textMuted),
          ),
        ),
      ),
    );
  }
}
