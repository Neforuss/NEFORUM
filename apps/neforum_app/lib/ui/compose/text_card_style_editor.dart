import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../media/text_card.dart';
import '../../media/text_card_background.dart';
import '../../state/composer.dart';
import '../../theme/tokens.dart';
import '../accounts/guide_sheet.dart' show showGuideSheet;
import '../settings/appearance_section.dart' show hexColor;
import 'card_colour_dialog.dart';

/// 1.3.5: cards. The text card editor's "more editing power": the @handle
/// written on the cards, its size, corner and colour, and the words' size,
/// line spacing, place top to bottom, colour, the card's colour and its
/// margins. Every control edits the composer's [ComposerState.textCardStyle]
/// as it moves, which is the post's, so it reaches every network's preview,
/// stand-in and saved card alike. The master editor shows it inline; each
/// network's card opens it in a sheet ("Text & @handle…"). The @handle field
/// is always shown; the rest folds under "Style the words and the handle",
/// which says what is set, so the master editor stays short enough for the
/// networks' previews to show under it.
///
/// Every control is a standard focusable one (text field, sliders, chips and
/// buttons), so the editor is used by keyboard too: Tab moves between them,
/// the arrow keys move a slider.
class TextCardStyleEditor extends ConsumerStatefulWidget {
  const TextCardStyleEditor({
    super.key,
    required this.keyPrefix,
    required this.ownHandles,
    required this.where,
    required this.theme,
    this.master = false,
    this.handleHiddenOn = const [],
    this.handleShownNowhere = false,
    this.background,
    this.designed = false,
    this.initiallyExpanded,
  });

  /// Whether the size, colour, spacing, place and margin controls start
  /// unfolded; null unfolds them when the post's card is already restyled
  /// (beyond its @handle), so the master editor stays short and the
  /// networks' previews in view until they are wanted.
  final bool? initiallyExpanded;

  /// Keys of the controls start with this ("text-card-master-style").
  final String keyPrefix;

  /// Each network's own @handle, shown in the empty @handle field.
  final List<String> ownHandles;

  /// "every network", or the network's name.
  final String where;

  /// The master editor's: it speaks of every card.
  final bool master;

  /// The card's theme: the colours a colour of the card's own replaces.
  final TextCardTheme theme;

  /// Names of the networks whose "Show @handle" is off: the @handle written
  /// here stays off there.
  final List<String> handleHiddenOn;

  /// "Show @handle" is off everywhere this edits.
  final bool handleShownNowhere;

  /// The card's background photo, whose text colour and word position are
  /// the defaults over it.
  final TextCardBackground? background;

  /// A card designer design draws the card: only the @handle's words are
  /// the editor's; the design sets everything else.
  final bool designed;

  @override
  ConsumerState<TextCardStyleEditor> createState() => _TextCardStyleEditorState();
}

class _TextCardStyleEditorState extends ConsumerState<TextCardStyleEditor> {
  late final TextEditingController _handle = TextEditingController(text: ref.read(composerProvider).textCardStyle.handle ?? '');

  /// The size, colour, spacing, place and margin controls are unfolded.
  late bool _expanded = widget.initiallyExpanded ?? !ref.read(composerProvider).textCardStyle.copyWith(clearHandle: true).isClassic;

  /// What the folded controls are set to, in a few words.
  static String _summary(TextCardStyle s) {
    final set = [
      if (s.textSize != 1) 'words ${(s.textSize * 100).round()}%',
      if (s.hasCardColours) 'own colours',
      if (s.textPosition != null) 'words at the ${s.textPosition!.label.toLowerCase()}',
      if (s.lineSpacing != TextCardStyle.defaultLineSpacing) 'spacing ${s.lineSpacing.toStringAsFixed(2)}',
      if (s.margin != TextCardStyle.defaultMargin) 'margins ${s.margin.round()} px',
      if (s.handleSize != 1 || s.handlePosition != TextCardHandlePosition.automatic || s.handleColor != null) 'handle styled',
    ];
    return set.isEmpty ? 'Size, colours, line spacing, place and margins' : set.join(' · ');
  }

  @override
  void dispose() {
    _handle.dispose();
    super.dispose();
  }

  TextCardStyle get _style => ref.read(composerProvider).textCardStyle;

  /// Changes the style as it is now in the composer (not as the last frame
  /// showed it), so quick edits in a row all count.
  void _edit(TextCardStyle Function(TextCardStyle s) change) => ref.read(composerProvider.notifier).setTextCardStyle(change(_style));

  Key _key(String name) => Key('${widget.keyPrefix}-$name');

  Future<void> _pickColour({
    required String title,
    required int? current,
    required Color fallback,
    required String defaultLabel,
    required TextCardStyle Function(TextCardStyle s, int? colour) apply,
  }) async {
    final choice = await showCardColourDialog(context, title: title, current: current, fallback: fallback, defaultLabel: defaultLabel);
    if (choice != null) _edit((s) => apply(s, choice.color));
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final style = ref.watch(composerProvider.select((c) => c.textCardStyle));
    // The field follows a style changed elsewhere (reset, a post loaded, the
    // other editor), never the user's own typing.
    ref.listen(composerProvider.select((c) => c.textCardStyle.handle), (_, next) {
      if (TextCardStyle.cleanHandle(_handle.text) != next) _handle.text = next ?? '';
    });
    final background = widget.background;
    final wordsColour = background == null
        ? widget.theme.foreground
        : switch (background.textColor) {
            TextCardTextColor.black => const Color(0xFF000000),
            _ => const Color(0xFFFFFFFF),
          };
    final words = style.textColorOr(wordsColour);
    final position = style.textPosition ?? background?.textPosition ?? TextCardTextPosition.center;
    // The card's colour shows without a photo, or around a whole one.
    final cardColourShows = background == null || background.contain;

    Widget section(String title, IconData icon) => Padding(
      padding: const EdgeInsets.only(top: Space.md, bottom: Space.xs),
      child: Row(
        children: [
          Icon(icon, size: 16, color: nf.textMuted),
          const SizedBox(width: Space.xs + 2),
          Text(title, style: context.text.labelLarge),
        ],
      ),
    );

    Widget labelled(String label, Widget control) => Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
          ),
          Expanded(child: control),
        ],
      ),
    );

    // No divisions (their tick marks crowd a narrow panel): each change is
    // rounded to the control's step instead, and the arrow keys move a step
    // of the track at a time.
    Widget slider(String name, String label, double value, double min, double max, String shown, ValueChanged<double> onChanged) => labelled(
      label,
      Row(
        children: [
          Expanded(
            child: Slider(key: _key(name), value: value.clamp(min, max), min: min, max: max, semanticFormatterCallback: (_) => shown, onChanged: onChanged),
          ),
          SizedBox(
            width: 52,
            child: Text(shown, textAlign: TextAlign.end, style: context.text.bodySmall),
          ),
        ],
      ),
    );

    Widget chips<T extends Enum>(String name, List<T> values, T selected, String Function(T v) label, ValueChanged<T> onSelected) => Wrap(
      spacing: Space.xs,
      runSpacing: Space.xs,
      children: [
        for (final v in values)
          ChoiceChip(
            key: _key('$name-${v.name}'),
            label: Text(label(v)),
            selected: v == selected,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => onSelected(v),
          ),
      ],
    );

    Widget colour(String name, String label, Color shown, {required bool own, required VoidCallback onTap}) => Tooltip(
      message: own ? '$label: ${hexColor(shown.toARGB32())}' : '$label: the theme\'s',
      child: OutlinedButton(
        key: _key(name),
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: Space.sm + 2),
          side: BorderSide(color: own ? nf.accent : nf.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: shown,
                shape: Radii.circleShape,
                border: Border.all(color: nf.borderStrong),
              ),
            ),
            const SizedBox(width: Space.xs + 2),
            Text(label, style: context.text.labelMedium?.copyWith(color: nf.text)),
          ],
        ),
      ),
    );

    String percent(double v) => '${(v * 100).round()}%';
    final hidden = widget.handleShownNowhere
        ? 'Show @handle is off, so no card shows it. Turn Show @handle on to use this.'
        : widget.handleHiddenOn.isEmpty
        ? null
        : 'Stays off on ${widget.handleHiddenOn.join(', ')}, where Show @handle is off.';

    // Tab walks the editor's own controls in reading order, top to bottom,
    // before it leaves the editor: without the group, reading order across
    // the composer jumps to whatever sits level with the field in the other
    // column. (Widget order would put the controls unfolded later after
    // "How it works": focus nodes keep the order they were created in.)
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          section('Your @handle', Icons.alternate_email_rounded),
          TextField(
            key: _key('handle'),
            controller: _handle,
            maxLength: TextCardStyle.maxHandleLength,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              labelText: widget.master ? 'Handle on every card' : 'Handle on the card',
              hintText: widget.ownHandles.join(', '),
              hintMaxLines: 1,
              helperText: hidden ?? (style.handle == null ? 'Empty: each network shows its own handle.' : 'Replaces your handle on ${widget.where}.'),
              helperMaxLines: 2,
              suffixIcon: style.handle == null
                  ? null
                  : IconButton(
                      key: _key('handle-reset'),
                      tooltip: "Back to each network's own handle",
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                      onPressed: () {
                        _handle.clear();
                        _edit((s) => s.copyWith(clearHandle: true));
                      },
                    ),
            ),
            onChanged: (v) => _edit((s) => TextCardStyle.cleanHandle(v) == null ? s.copyWith(clearHandle: true) : s.copyWith(handle: v)),
          ),
          if (widget.designed) ...[
            const SizedBox(height: Space.sm),
            Text(
              'Your design sets the size, colours and place of the words and the handle; change them in Design card.',
              style: context.text.bodySmall?.copyWith(color: nf.textFaint),
            ),
          ] else ...[
            const SizedBox(height: Space.sm),
            Semantics(
              button: true,
              expanded: _expanded,
              child: InkWell(
                key: _key('more'),
                borderRadius: Radii.rMd,
                onTap: () => setState(() => _expanded = !_expanded),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.sm, Space.sm),
                  decoration: BoxDecoration(
                    borderRadius: Radii.rMd,
                    border: Border.all(color: style.copyWith(clearHandle: true).isClassic ? nf.border : nf.accent),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.tune_rounded, size: 18, color: nf.textMuted),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Style the words and the handle', style: context.text.labelLarge),
                            Text(
                              _summary(style),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.bodySmall?.copyWith(color: nf.textFaint),
                            ),
                          ],
                        ),
                      ),
                      Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: nf.textMuted),
                    ],
                  ),
                ),
              ),
            ),
          ],
          if (!widget.designed && _expanded) ...[
            section('Handle', Icons.alternate_email_rounded),
            slider(
              'handle-size',
              'Size',
              style.handleSize,
              TextCardStyle.minHandleSize,
              TextCardStyle.maxHandleSize,
              percent(style.handleSize),
              (v) => _edit((s) => s.copyWith(handleSize: (v * 20).round() / 20)),
            ),
            labelled(
              'Corner',
              chips('handle-corner', TextCardHandlePosition.values, style.handlePosition, (p) => p.label, (p) => _edit((s) => s.copyWith(handlePosition: p))),
            ),
            labelled(
              'Colour',
              Align(
                alignment: Alignment.centerLeft,
                child: colour(
                  'handle-colour',
                  style.handleColor == null ? 'Like the words' : 'Handle',
                  style.handleColor == null ? words : Color(style.handleColor!),
                  own: style.handleColor != null,
                  onTap: () => _pickColour(
                    title: 'Handle colour',
                    current: style.handleColor,
                    fallback: words,
                    defaultLabel: 'Like the words',
                    apply: (s, c) => c == null ? s.copyWith(clearHandleColor: true) : s.copyWith(handleColor: c),
                  ),
                ),
              ),
            ),
            section('Words', Icons.text_fields_rounded),
            slider(
              'text-size',
              'Size',
              style.textSize,
              TextCardStyle.minTextSize,
              TextCardStyle.maxTextSize,
              percent(style.textSize),
              (v) => _edit((s) => s.copyWith(textSize: (v * 20).round() / 20)),
            ),
            slider(
              'line-spacing',
              'Line spacing',
              style.lineSpacing,
              TextCardStyle.minLineSpacing,
              TextCardStyle.maxLineSpacing,
              style.lineSpacing.toStringAsFixed(2),
              (v) => _edit((s) => s.copyWith(lineSpacing: (v * 20).round() / 20)),
            ),
            labelled('Position', chips('position', TextCardTextPosition.values, position, (p) => p.label, (p) => _edit((s) => s.copyWith(textPosition: p)))),
            labelled(
              'Colours',
              Wrap(
                spacing: Space.xs,
                runSpacing: Space.xs,
                children: [
                  colour(
                    'text-colour',
                    'Words',
                    words,
                    own: style.textColor != null,
                    onTap: () => _pickColour(
                      title: 'Colour of the words',
                      current: style.textColor,
                      fallback: wordsColour,
                      defaultLabel: background == null ? "The theme's" : "The photo's",
                      apply: (s, c) => c == null ? s.copyWith(clearTextColor: true) : s.copyWith(textColor: c),
                    ),
                  ),
                  if (cardColourShows)
                    colour(
                      'background-colour',
                      'Card',
                      style.backgroundColorOr(widget.theme.background),
                      own: style.backgroundColor != null,
                      onTap: () => _pickColour(
                        title: 'Colour of the card',
                        current: style.backgroundColor,
                        fallback: widget.theme.background,
                        defaultLabel: "The theme's",
                        apply: (s, c) => c == null ? s.copyWith(clearBackgroundColor: true) : s.copyWith(backgroundColor: c),
                      ),
                    ),
                ],
              ),
            ),
            slider(
              'margin',
              'Margins',
              style.margin,
              TextCardStyle.minMargin,
              TextCardStyle.maxMargin,
              '${style.margin.round()} px',
              (v) => _edit((s) => s.copyWith(margin: (v / 4).round() * 4.0)),
            ),
          ],
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              TextButton.icon(
                key: _key('reset'),
                onPressed: style.isClassic
                    ? null
                    : () {
                        _handle.clear();
                        ref.read(composerProvider.notifier).setTextCardStyle(TextCardStyle.classic);
                      },
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('Reset handle and words'),
              ),
              TextButton.icon(
                key: _key('guide'),
                onPressed: () => showGuideSheet(context, 'text-cards', asset: 'text-cards.md'),
                style: TextButton.styleFrom(foregroundColor: nf.textMuted),
                icon: const Icon(Icons.help_outline_rounded, size: 18),
                label: const Text('How it works'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
