import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../media/card_design.dart';
import '../../media/card_design_edits.dart';
import '../../media/text_card.dart';
import '../../media/text_card_background.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../accounts/guide_sheet.dart' show showGuideSheet;
import '../settings/appearance_section.dart' show hexColor;
import 'card_colour_dialog.dart';

/// How large a post's words come out against what the editor's size control
/// asks, on the network where they fall shortest: on the classic card both
/// are against the size at 100% (1.0), on a design both are pixels at 1080
/// wide. 1.3.5 rounds 5 and 6, from [CardDesignPainter.drawnWords]: [cut], a
/// design's words were cut to fit at their smallest readable size;
/// [dropped], its placed words found no room at all and are left off;
/// [handleDropped], the same for its placed @handle; [fitsAt], another
/// position measured to show every word on that card, if there is one.
typedef TextCardWordsFit = ({String network, double asked, double drawn, bool cut, bool dropped, bool handleDropped, String? fitsAt});

/// 1.3.5 round 6: what to tell the user when [fit] says words or the
/// @handle are missing from a network's card; null when nothing is. The
/// advice is only what was measured to help: another position when one
/// shows every word, else what makes room.
String? textCardFitWarning(TextCardWordsFit fit) {
  final net = fit.network;
  if (fit.dropped) {
    return 'No room for the words on $net: ${fit.fitsAt != null ? '${fit.fitsAt} shows them, or ' : ''}smaller margins or a smaller handle make room';
  }
  if (fit.handleDropped) return 'No room for the handle on $net: smaller margins or a smaller handle make room';
  if (fit.cut) {
    final px = '${fit.drawn.round()} px';
    return fit.fitsAt != null
        ? 'Too long for this place on $net: cut at $px. ${fit.fitsAt} shows every word'
        : 'Too long for this card on $net: cut at $px. Shorter words or smaller margins make room';
  }
  return null;
}

/// 1.3.5: cards. The text card editor's "more editing power": the @handle
/// written on the cards, its size, place and colour, and the words' size,
/// line spacing, place top to bottom and colour, the card's colour and its
/// margins. On the classic card every control edits the composer's
/// [ComposerState.textCardStyle]; when a card designer design draws the
/// cards, the same controls edit that design ([CardDesignEdits]), so the
/// designer and every card show one look. Either is the post's, so a change
/// reaches every network's preview, stand-in and saved card alike. The
/// master editor shows it inline; the card of a post that only one network
/// gets a card for opens it in a sheet ("Text & @handle…"). The @handle
/// field is always shown; the rest folds under "Style the words and the
/// handle", which says what is set, so the master editor stays short enough
/// for the networks' previews to show under it.
///
/// The words' place and colour are one setting with the background photo's
/// "Words" controls ([ComposerNotifier.setTextCardWordsPosition],
/// [ComposerNotifier.setTextCardWordsColour]): either shows what the other
/// set.
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
    this.design,
    this.initiallyExpanded,
    this.wordsFit,
  });

  /// Whether the size, colour, spacing, place and margin controls start
  /// unfolded; null unfolds them when the post's classic card is already
  /// restyled (beyond its @handle), so the master editor stays short and the
  /// networks' previews in view until they are wanted.
  final bool? initiallyExpanded;

  /// Keys of the controls start with this ("text-card-master-style").
  final String keyPrefix;

  /// Each network's own @handle, shown in the empty @handle field and, once
  /// one is written, in the line saying which it replaces.
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

  /// The card's background photo, whose text colour and word position (from
  /// before 1.3.5) are the defaults over it.
  final TextCardBackground? background;

  /// The card designer design that draws the cards; null for the classic
  /// card.
  final CardDesign? design;

  /// How large the words come out ([TextCardWordsFit]); asked only while the
  /// controls are unfolded, to say when a larger size changes nothing.
  final TextCardWordsFit? Function()? wordsFit;

  @override
  ConsumerState<TextCardStyleEditor> createState() => _TextCardStyleEditorState();
}

class _TextCardStyleEditorState extends ConsumerState<TextCardStyleEditor> {
  late final TextEditingController _handle = TextEditingController(text: ref.read(composerProvider).textCardStyle.handle ?? '');

  /// 1.4.3: cards. The attribution under the words.
  late final TextEditingController _attribution = TextEditingController(text: ref.read(composerProvider).textCardStyle.attribution ?? '');

  /// [s] without the @handle's words (above the fold) and (1.4.3) the card's
  /// shape and layout, which a new post takes from Settings: a post is
  /// restyled when anything else is set.
  static TextCardStyle _folded(TextCardStyle s) => s.copyWith(shape: TextCardShape.automatic, layout: TextCardLayout.full, clearHandle: true);

  /// The shape, size, colour, spacing, place and margin controls are
  /// unfolded.
  late bool _expanded = widget.initiallyExpanded ?? (widget.design == null && !_folded(ref.read(composerProvider).textCardStyle).isClassic);

  /// What the folded controls are set to, in a few words.
  static String _summary(TextCardStyle s) {
    final set = [
      // 1.4.3: cards.
      if (s.shape != TextCardShape.automatic) s.shape.label,
      if (s.layout != TextCardLayout.full) s.layout.label.toLowerCase(),
      if (s.attribution != null) 'attribution',
      if (s.textSize != 1) 'words ${(s.textSize * 100).round()}%',
      if (s.hasCardColours) 'own colours',
      if (s.textPosition != null) 'words at the ${s.textPosition!.label.toLowerCase()}',
      if (s.lineSpacing != TextCardStyle.defaultLineSpacing) 'spacing ${s.lineSpacing.toStringAsFixed(2)}',
      if (s.margin != TextCardStyle.defaultMargin) 'margins ${s.margin.round()} px',
      if (s.handleSize != 1 || s.handlePosition != TextCardHandlePosition.automatic || s.handleColor != null) 'handle styled',
    ];
    return set.isEmpty ? 'Shape, size, colours, line spacing, place and margins' : set.join(' · ');
  }

  @override
  void dispose() {
    _handle.dispose();
    _attribution.dispose();
    super.dispose();
  }

  TextCardStyle get _style => ref.read(composerProvider).textCardStyle;
  ComposerNotifier get _composer => ref.read(composerProvider.notifier);

  /// Changes the style as it is now in the composer (not as the last frame
  /// showed it), so quick edits in a row all count.
  void _edit(TextCardStyle Function(TextCardStyle s) change) => _composer.setTextCardStyle(change(_style));

  /// Changes the post's design as it is now (the post's own, or the
  /// Settings default it starts from). The composer remembers the design
  /// before the first change ([ComposerState.textCardDesignBeforeEdits]),
  /// so "Reset" works however often the editor is folded or rebuilt.
  void _editDesign(CardDesign Function(CardDesign d) change) {
    final current = ref.read(composerProvider).textDesign(ref.read(settingsProvider));
    if (current == null) return;
    _composer.setTextCardDesignEdited(change(current));
  }

  Key _key(String name) => Key('${widget.keyPrefix}-$name');

  Future<void> _pickColour({required String title, required int? current, required Color fallback, required String defaultLabel, required void Function(int? colour) apply}) async {
    final choice = await showCardColourDialog(context, title: title, current: current, fallback: fallback, defaultLabel: defaultLabel);
    if (choice != null) apply(choice.color);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final composer = ref.watch(composerProvider);
    final style = composer.textCardStyle;
    // A design that draws the cards, as it is now in the composer.
    // With a written @handle, as the cards draw it ([designWithHandle]).
    final own = widget.design == null ? null : (composer.textDesign(ref.watch(settingsProvider)) ?? widget.design);
    final CardDesign? design = own == null ? null : designWithHandle(own, style.handle);
    final designEdited = composer.textCardDesignBeforeEdits != null;
    // The field follows a style changed elsewhere (reset, a post loaded, the
    // other editor), never the user's own typing.
    ref.listen(composerProvider.select((c) => c.textCardStyle.handle), (_, next) {
      if (TextCardStyle.cleanHandle(_handle.text) != next) _handle.text = next ?? '';
    });
    ref.listen(composerProvider.select((c) => c.textCardStyle.attribution), (_, next) {
      if (TextCardStyle.cleanAttribution(_attribution.text) != next) _attribution.text = next ?? '';
    });
    final background = widget.background;
    final ownWords = textCardWordsColour(style, background);
    // Over a photo, "automatic" is white or black: shown as white.
    final words = ownWords == null ? (background == null ? widget.theme.foreground : const Color(0xFFFFFFFF)) : Color(ownWords);
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
            width: 84,
            child: Text(label, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
          ),
          Expanded(child: control),
        ],
      ),
    );

    // Compact (a 4 px track, a small thumb), so more of the editor fits
    // beside the card. No divisions (their tick marks crowd a narrow panel):
    // each change is rounded to the control's step instead, and the arrow
    // keys move a step of the track at a time. [step] adds smaller and
    // larger buttons.
    Widget slider(String name, String label, double value, double min, double max, String shown, ValueChanged<double> onChanged, {double? step, String? note}) {
      Widget stepButton(String which, IconData icon, String tip, double by) => IconButton(
        key: _key('$name-$which'),
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: Icon(icon),
        onPressed: (by < 0 ? value <= min : value >= max) ? null : () => onChanged((value + by).clamp(min, max)),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          labelled(
            label,
            Row(
              children: [
                if (step != null) stepButton('smaller', Icons.text_decrease_rounded, 'Smaller', -step),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                    ),
                    child: Slider(key: _key(name), value: value.clamp(min, max), min: min, max: max, semanticFormatterCallback: (_) => shown, onChanged: onChanged),
                  ),
                ),
                if (step != null) stepButton('larger', Icons.text_increase_rounded, 'Larger', step),
                SizedBox(
                  width: 48,
                  child: Text(shown, textAlign: TextAlign.end, style: context.text.bodySmall),
                ),
              ],
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(left: 84, bottom: Space.xs),
              child: Text(note, key: _key('$name-note'), style: context.text.bodySmall?.copyWith(color: nf.warning)),
            ),
        ],
      );
    }

    Widget chips<T extends Enum>(String name, List<T> values, T? selected, String Function(T v) label, ValueChanged<T> onSelected) => Wrap(
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

    // A colour button names its colour: "Words #FFD60A".
    Widget colour(String name, String label, Color shown, {required bool own, required VoidCallback onTap, String? defaultName}) {
      final hex = hexColor(shown.toARGB32());
      final named = own || defaultName == null ? '$label $hex' : '$label · $defaultName';
      return Tooltip(
        message: own ? '$label: $hex' : '$label: ${defaultName ?? hex}',
        child: OutlinedButton(
          key: _key(name),
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: Space.sm + 2),
            side: BorderSide(color: own ? nf.accent : nf.hairline),
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
              Text(named, style: context.text.labelMedium?.copyWith(color: nf.text)),
            ],
          ),
        ),
      );
    }

    String percent(double v) => '${(v * 100).round()}%';
    String px(double v) => '${v.round()} px';
    final hidden = widget.handleShownNowhere
        ? 'Show @handle is off, so no card shows it. Turn Show @handle on to use this.'
        : widget.handleHiddenOn.isEmpty
        ? null
        : 'Stays off on ${widget.handleHiddenOn.join(', ')}, where Show @handle is off.';
    // Which handles a written one replaces, so what goes away can be checked;
    // a design that hides its @handle block draws none, and says so.
    final hiddenByDesign = design != null && design.handleBlock != null && !design.handleBlock!.visible;
    final replaced = hiddenByDesign
        ? 'This design hides its handle, so no card shows it. Show it in Design card to use this.'
        : 'In place of ${widget.ownHandles.join(' · ')}';

    // How large the words come out, when a larger size changes nothing or
    // the design's words shrink to fit.
    // Round 6: on a design that places the words or the @handle, words or
    // a handle can go missing from a card (cut, or no room left), so that
    // is worked out folded too and shown under the fold.
    String? fitNote;
    final placing = design != null && (design.placeWords || design.placeHandle);
    final fit = _expanded || placing ? widget.wordsFit?.call() : null;
    final warning = design == null || fit == null ? null : textCardFitWarning(fit);
    if (fit != null && _expanded) {
      if (design == null) {
        if (style.textSize > 1 && fit.drawn < fit.asked - 0.02) {
          fitNote = fit.drawn <= 1.005 ? 'Already as large as these words fit on ${fit.network}' : 'As large as fits on ${fit.network}: ${percent(fit.drawn)}';
        }
      } else if (warning != null) {
        fitNote = warning;
      } else if (fit.drawn < fit.asked - 1) {
        fitNote = 'Shrinks to fit on ${fit.network}: ${px(fit.drawn)}';
      }
    }

    final List<Widget> controls;
    if (design == null) {
      controls = [
        section('Handle', Icons.alternate_email_rounded),
        slider('handle-size', 'Size', style.handleSize, TextCardStyle.minHandleSize, TextCardStyle.maxHandleSize, percent(style.handleSize),
            (v) => _edit((s) => s.copyWith(handleSize: (v * 20).round() / 20))),
        labelled('Place', chips('handle-corner', TextCardHandlePosition.values, style.handlePosition, (p) => p.label, (p) => _edit((s) => s.copyWith(handlePosition: p)))),
        labelled(
          'Colour',
          Align(
            alignment: Alignment.centerLeft,
            child: colour(
              'handle-colour',
              'Handle',
              style.handleColor == null ? words : Color(style.handleColor!),
              own: style.handleColor != null,
              defaultName: 'like the words',
              onTap: () => _pickColour(
                title: 'Handle colour',
                current: style.handleColor,
                fallback: words,
                defaultLabel: 'Like the words',
                apply: (c) => _edit((s) => c == null ? s.copyWith(clearHandleColor: true) : s.copyWith(handleColor: c)),
              ),
            ),
          ),
        ),
        section('Words', Icons.text_fields_rounded),
        slider('text-size', 'Size', style.textSize, TextCardStyle.minTextSize, TextCardStyle.maxTextSize, percent(style.textSize),
            (v) => _edit((s) => s.copyWith(textSize: (v * 20).round() / 20)),
            step: 0.1, note: fitNote),
        slider('line-spacing', 'Line spacing', style.lineSpacing, TextCardStyle.minLineSpacing, TextCardStyle.maxLineSpacing, style.lineSpacing.toStringAsFixed(2),
            (v) => _edit((s) => s.copyWith(lineSpacing: (v * 20).round() / 20))),
        labelled('Position', chips('position', TextCardTextPosition.values, textCardWordsPosition(style, background), (p) => p.label, _composer.setTextCardWordsPosition)),
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
                own: ownWords != null,
                defaultName: background == null ? "theme's" : 'automatic',
                onTap: () => _pickColour(
                  title: 'Colour of the words',
                  current: ownWords,
                  fallback: words,
                  defaultLabel: background == null ? "The theme's" : 'Automatic',
                  apply: _composer.setTextCardWordsColour,
                ),
              ),
              if (cardColourShows)
                colour(
                  'background-colour',
                  'Card',
                  style.backgroundColorOr(widget.theme.background),
                  own: style.backgroundColor != null,
                  defaultName: "theme's",
                  onTap: () => _pickColour(
                    title: 'Colour of the card',
                    current: style.backgroundColor,
                    fallback: widget.theme.background,
                    defaultLabel: "The theme's",
                    apply: (c) => _edit((s) => c == null ? s.copyWith(clearBackgroundColor: true) : s.copyWith(backgroundColor: c)),
                  ),
                ),
            ],
          ),
        ),
        slider('margin', 'Margins', style.margin, TextCardStyle.minMargin, TextCardStyle.maxMargin, px(style.margin),
            (v) => _edit((s) => s.copyWith(margin: (v / 4).round() * 4.0))),
      ];
    } else {
      final hasWords = design.wordsBlock != null;
      controls = [
        Padding(
          padding: const EdgeInsets.only(top: Space.sm),
          child: Text(
            'These change the post\'s design (Design card shows the same). The classic card\'s own styling is kept for when you turn the design off.',
            key: _key('design-note'),
            style: context.text.bodySmall?.copyWith(color: nf.textFaint),
          ),
        ),
        section('Handle', Icons.alternate_email_rounded),
        slider('handle-size', 'Size', design.handleSize, kDesignHandleSizeMin, kDesignHandleSizeMax, px(design.handleSize),
            (v) => _editDesign((d) => d.withHandleSize(v))),
        labelled('Place', chips('handle-corner', kDesignHandlePositions, design.handlePosition, (p) => p.label, (p) => _editDesign((d) => d.withHandlePosition(p)))),
        labelled(
          'Colour',
          Align(
            alignment: Alignment.centerLeft,
            child: colour(
              'handle-colour',
              'Handle',
              Color(design.handleColor),
              own: true,
              onTap: () => _pickColour(
                title: 'Handle colour',
                current: design.handleColor | 0xFF000000,
                fallback: Color(design.handleColor | 0xFF000000),
                defaultLabel: 'Like the words',
                apply: (c) => _editDesign((d) => c == null ? d.withHandleColorLikeWords() : d.withHandleColor(c)),
              ),
            ),
          ),
        ),
        section('Words', Icons.text_fields_rounded),
        if (!hasWords)
          Text('This design has no block for your words; add one in Design card.', style: context.text.bodySmall?.copyWith(color: nf.textFaint))
        else ...[
          slider('text-size', 'Size', design.wordsSize, kDesignWordsSizeMin, kDesignWordsSizeMax, px(design.wordsSize), (v) => _editDesign((d) => d.withWordsSize(v)),
              step: 8, note: fitNote),
          slider('line-spacing', 'Line spacing', design.wordsLineHeight, kDesignLineHeightMin, kDesignLineHeightMax, design.wordsLineHeight.toStringAsFixed(2),
              (v) => _editDesign((d) => d.withWordsLineHeight((v * 20).round() / 20))),
          labelled('Position', chips('position', TextCardTextPosition.values, design.wordsPosition, (p) => p.label, (p) => _editDesign((d) => d.withWordsPosition(p)))),
          labelled(
            'Colours',
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: [
                colour(
                  'text-colour',
                  'Words',
                  Color(design.wordsColor | 0xFF000000),
                  own: true,
                  onTap: () => _pickColour(
                    title: 'Colour of the words',
                    current: null,
                    fallback: Color(design.wordsColor | 0xFF000000),
                    defaultLabel: '',
                    apply: (c) {
                      if (c != null) _editDesign((d) => d.withWordsColor(c));
                    },
                  ),
                ),
                if (design.cardColorEditable)
                  colour(
                    'background-colour',
                    'Card',
                    Color(design.cardColor | 0xFF000000),
                    own: true,
                    onTap: () => _pickColour(
                      title: design.background.kind == CardFillKind.solid ? 'Colour of the card' : 'Colour of the card (in place of the gradient)',
                      current: null,
                      fallback: Color(design.cardColor | 0xFF000000),
                      defaultLabel: '',
                      apply: (c) {
                        if (c != null) _editDesign((d) => d.withCardColor(c));
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
        slider('margin', 'Margins', design.margin, kDesignMarginMin, kDesignMarginMax, px(design.margin), (v) => _editDesign((d) => d.withMargin((v / 4).round() * 4.0))),
      ];
    }

    // The card's shape and layout are not "handle and words": Reset keeps
    // them (1.4.3).
    final canReset = design == null ? !style.copyWith(shape: TextCardShape.automatic, layout: TextCardLayout.full).isClassic : (designEdited || style.handle != null);

    // 1.4.3: cards. The classic card's shape, layout and attribution; a
    // design draws its own frame and lines.
    final card = design != null
        ? const <Widget>[]
        : [
            section('Card', Icons.crop_landscape_rounded),
            // Remembered for new posts, as the theme, font and alignment are.
            labelled('Shape', chips('shape', TextCardShape.values, style.shape, (s) => s.label, (s) {
              _edit((x) => x.copyWith(shape: s));
              ref.read(settingsProvider.notifier).update((x) => x.textCardShape == s ? x : x.copyWith(textCardShape: s));
            })),
            labelled('Layout', chips('layout', TextCardLayout.values, style.layout, (l) => l.label, (l) {
              _edit((x) => x.copyWith(layout: l));
              ref.read(settingsProvider.notifier).update((x) => x.textCardLayout == l ? x : x.copyWith(textCardLayout: l));
            })),
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: TextField(
                key: _key('attribution'),
                controller: _attribution,
                maxLength: TextCardStyle.maxAttributionLength,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  isDense: true,
                  counterText: '',
                  labelText: 'Attribution under the words',
                  hintText: '- Ada Lovelace',
                  helperText: 'In bold, below the words. Put words between ** for bold or * for italic, like **this**.',
                  helperMaxLines: 3,
                  suffixIcon: style.attribution == null
                      ? null
                      : IconButton(
                          key: _key('attribution-clear'),
                          tooltip: 'Remove the attribution',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _attribution.clear();
                            _edit((s) => s.copyWith(clearAttribution: true));
                          },
                        ),
                ),
                onChanged: (v) => _edit((s) => TextCardStyle.cleanAttribution(v) == null ? s.copyWith(clearAttribution: true) : s.copyWith(attribution: v)),
              ),
            ),
          ];

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
              helperText: [
                ?hidden,
                style.handle == null ? 'Empty: each network shows its own handle.' : replaced,
              ].join('\n'),
              helperMaxLines: 4,
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
                  border: Border.all(color: design == null && _folded(style).isClassic || design != null && !designEdited ? nf.hairline : nf.accent),
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
                            design == null ? _summary(style) : 'Size, colours, line spacing, place and margins of the design',
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
          // 1.4.3: cards. The card's shape, layout and attribution close the
          // unfolded controls, so the words' and the handle's stay where
          // they were.
          if (_expanded) ...[...controls, ...card],
          if (!_expanded && warning != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.warning_amber_rounded, size: 18, color: nf.warning),
                const SizedBox(width: Space.xs),
                Expanded(child: Text(warning, key: _key('fit-warning'), style: context.text.bodySmall)),
              ]),
            ),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              TextButton.icon(
                key: _key('reset'),
                onPressed: !canReset
                    ? null
                    : () {
                        _handle.clear();
                        if (design == null) {
                          _attribution.clear();
                          _composer.setTextCardStyle(TextCardStyle(shape: style.shape, layout: style.layout));
                        } else {
                          // The design as it was (the Settings default
                          // again, if the post followed it); the classic
                          // styling stays for when the design is turned off.
                          _edit((s) => s.copyWith(clearHandle: true));
                          _composer.resetTextCardDesignEdits();
                        }
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
