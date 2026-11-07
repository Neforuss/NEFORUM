import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:unicode_emojis/unicode_emojis.dart';

import '../../media/emoji_text.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
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

/// The emoji sheet: search, recent emoji, the skin tone row, the categories and
/// the grid. Works the same on every system, over data in the app: nothing here
/// goes over the network. [onPick] gets each emoji; the sheet stays open.
class EmojiPanel extends ConsumerStatefulWidget {
  const EmojiPanel({super.key, required this.onPick, required this.onClose});
  final ValueChanged<String> onPick;
  final VoidCallback onClose;

  @override
  ConsumerState<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends ConsumerState<EmojiPanel> {
  final TextEditingController _search = TextEditingController();

  /// The recent list as the sheet opened: it does not reorder under the pointer
  /// while picking.
  late final List<String> _recents;

  /// Null shows the recent emoji.
  Category? _category;
  EmojiDeviceSupport _support = EmojiDeviceSupport.assumed;

  @override
  void initState() {
    super.initState();
    _recents = ref.read(settingsProvider).emojiRecents;
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

  void _setTone(int tone) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(emojiSkinTone: tone));

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final tone = ref.watch(settingsProvider.select((s) => s.emojiSkinTone));
    final query = _search.text.trim();
    final searching = query.isNotEmpty;
    final List<Emoji> found = searching ? searchEmoji(query) : (_category == null ? const [] : emojiOf(_category!).where(_support.draws).toList());
    final recentsShown = !searching && _category == null;
    final anyUndrawable = searching && found.any((e) => !_support.draws(e));
    final showFlagsNote = _support.flagsInPieces && (_category == Category.flags || (searching && found.any((e) => e.category == Category.flags)));

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
              decoration: const InputDecoration(hintText: 'Search emoji', prefixIcon: Icon(Icons.search_rounded, size: 20), isDense: true),
            ),
          ),
          IconButton(key: const Key('emoji-close'), tooltip: 'Close', icon: const Icon(Icons.close_rounded, size: 20), onPressed: widget.onClose),
        ]),
      ),
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
            if (_recents.isNotEmpty) Expanded(child: _CategoryButton(key: const Key('emoji-category-recent'), icon: Icons.history_rounded, tooltip: 'Recent', selected: _category == null, onTap: () => setState(() => _category = null))),
            for (final c in Category.values)
              Expanded(child: _CategoryButton(key: Key('emoji-category-${c.name}'), icon: _categoryIcons[c]!, tooltip: c.description, selected: _category == c, onTap: () => setState(() => _category = c))),
          ]),
        ),
      Divider(height: 1, color: nf.border),
      Expanded(
        child: recentsShown
            ? _Grid(key: const PageStorageKey('emoji-recent'), glyphs: [for (final g in _recents) (glyph: g, name: emojiByGlyph(g)?.name ?? 'Emoji', drawn: true, id: g)], onPick: widget.onPick)
            : found.isEmpty
                ? Center(child: Padding(padding: const EdgeInsets.all(Space.lg), child: Text('No emoji found', style: context.text.bodyMedium?.copyWith(color: nf.textFaint))))
                : _Grid(
                    key: PageStorageKey('emoji-${_category?.name}-$searching'),
                    glyphs: [
                      for (final e in found) (glyph: emojiAtTone(e, tone), name: e.name, drawn: _support.draws(e), id: e.unified),
                    ],
                    onPick: widget.onPick,
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
  const _Grid({super.key, required this.glyphs, required this.onPick});
  final List<_Glyph> glyphs;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(Space.xs),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 44, mainAxisExtent: 44),
      itemCount: glyphs.length,
      itemBuilder: (context, i) {
        final g = glyphs[i];
        return Tooltip(
          message: g.name,
          waitDuration: const Duration(milliseconds: 600),
          child: Semantics(
            button: true,
            label: g.name,
            excludeSemantics: true,
            child: InkWell(
              key: ValueKey('emoji-${g.id}'),
              borderRadius: Radii.rSm,
              onTap: () => onPick(g.glyph),
              child: Center(
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
                child: selected ? const Icon(Icons.check_rounded, size: 12, color: Color(0xFF000000)) : null,
              ),
            ),
          ),
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
