import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../media/card_design.dart';
import '../../media/card_quick_edits.dart';
import '../../media/card_templates.dart' show kClassicHandleSize, kClassicMargin, kClassicWordsSize;
import '../../media/text_card_background.dart' show TextCardTextPosition;
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart' show monoStyle;
import '../../theme/tokens.dart';
import '../../widgets/color_swatch_field.dart' show kPictureColorSwatches;
import '../../widgets/color_wheel.dart';
import '../settings/appearance_section.dart' show hexColor, parseHexColor;

/// 1.3.5: the master editor as a quick designer ("Text card for every
/// network"): the @handle every card shows, the text's size, line spacing
/// and place, the margins, the words' and the background's colours (any
/// colour, on the colour wheel or as hex), and the @handle's size and place.
/// Every control edits the post's text card design ([CardQuickEdits]) for
/// every network, the saved cards included; on a classic card the first
/// touch makes it a design that draws the classic card
/// ([ComposerState.quickDesignStart]), so only what was touched changes. The
/// @handle is the post's ([ComposerState.textCardByline]), not the design's:
/// typing it alone leaves the card's look as it is, classic or designed.
/// A post never touched here keeps exactly the cards it had.
///
/// Each control works by keyboard: the sliders take the arrow keys, the
/// buttons and the places Enter and Space, and the colour dialog's wheel
/// the arrow keys beside its hex field.
class TextCardQuickControls extends ConsumerStatefulWidget {
  const TextCardQuickControls({super.key, required this.handles, required this.handleHiddenOn, required this.plain});

  /// Each network's own @handle, once each: the @handle field shows them
  /// until something is typed.
  final List<String> handles;

  /// The networks whose card shows no @handle ("Show @handle" off): they
  /// stay without one whatever is typed.
  final List<String> handleHiddenOn;

  /// Most of the networks' cards carry no signature, so a classic card made
  /// a design keeps the @handle at the left, where a plain card has it.
  final bool plain;

  @override
  ConsumerState<TextCardQuickControls> createState() => _TextCardQuickControlsState();
}

class _TextCardQuickControlsState extends ConsumerState<TextCardQuickControls> {
  late final TextEditingController _byline = TextEditingController(text: ref.read(composerProvider).textCardByline ?? '');

  /// The size, colour and place controls unfolded; null until the user
  /// folds or unfolds them: then open when the card is restyled.
  bool? _more;

  @override
  void dispose() {
    _byline.dispose();
    super.dispose();
  }

  void _edit(CardDesign Function(CardDesign d) change) => ref.read(composerProvider.notifier).editTextCardDesign(change, plain: widget.plain);

  static String _percent(double size) => '${(size / kClassicWordsSize * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    // The field follows the post when it changes elsewhere (loaded, reset,
    // restored), never while the words typed already say the same.
    ref.listen(composerProvider.select((c) => c.textCardByline), (_, next) {
      if ((next ?? '') != _byline.text.trim()) _byline.text = next ?? '';
    });
    final c = ref.watch(composerProvider);
    final settings = ref.watch(settingsProvider);
    final look = c.quickDesignStart(settings, plain: widget.plain);
    final designed = c.textDesign(settings) != null;
    final open = _more ?? designed;
    final photo = c.textCardBackground != null && look.backgroundIsPhoto;
    final hidden = widget.handleHiddenOn;

    Widget heading(String text, {List<Widget> actions = const [], bool first = false}) => Padding(
          padding: EdgeInsets.only(top: first ? 0 : Space.md, bottom: first ? Space.sm : 2),
          child: SizedBox(
            height: 30,
            child: Row(children: [
              Expanded(child: Text(text, style: context.text.labelMedium?.copyWith(color: nf.textMuted))),
              ...actions,
            ]),
          ),
        );
    final own = widget.handles.join(' · ');

    // The @handle on every card: what it says.
    final handle = <Widget>[
      heading('@handle', first: true),
      TextField(
        key: const Key('text-card-master-byline'),
        controller: _byline,
        inputFormatters: [LengthLimitingTextInputFormatter(80)],
        decoration: InputDecoration(
          isDense: true,
          labelText: 'On every card',
          floatingLabelBehavior: FloatingLabelBehavior.always,
          hintText: own,
          hintMaxLines: 1,
          prefixIcon: Icon(Icons.alternate_email_rounded, size: 18, color: nf.textFaint),
          prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          helperText: [
            c.textCardByline == null ? 'Empty: each network\'s own handle' : 'In place of $own',
            if (hidden.isNotEmpty) 'not on ${hidden.join(', ')}, where "Show @handle" is off',
          ].join('; '),
          helperMaxLines: 3,
          suffixIcon: c.textCardByline == null
              ? null
              : IconButton(
                  key: const Key('text-card-master-byline-reset'),
                  tooltip: 'Back to each network\'s own handle',
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  onPressed: () {
                    _byline.clear();
                    ref.read(composerProvider.notifier).setTextCardByline(null);
                  },
                ),
        ),
        onChanged: (v) => ref.read(composerProvider.notifier).setTextCardByline(v),
      ),
      const SizedBox(height: Space.sm),
      // The rest folds away, so the networks' previews stay in view below
      // the panel; open once the card is restyled.
      Semantics(
        button: true,
        expanded: open,
        child: InkWell(
          key: const Key('text-card-master-more'),
          borderRadius: Radii.rSm,
          onTap: () => setState(() => _more = !open),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.sm),
            decoration: BoxDecoration(
              color: open ? null : nf.accentSoft.withValues(alpha: 0.5),
              borderRadius: Radii.rSm,
              border: Border.all(color: open ? nf.border : nf.accent.withValues(alpha: 0.4)),
            ),
            child: Row(children: [
              Icon(Icons.tune_rounded, size: 18, color: nf.accent),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text('Size, colours and place', style: context.text.labelLarge),
                  if (!open)
                    Text('Text size and spacing, where the words and the @handle go, margins, any colour',
                        style: context.text.bodySmall?.copyWith(color: nf.textFaint, fontSize: 11.5)),
                ]),
              ),
              Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: nf.textMuted),
            ]),
          ),
        ),
      ),
    ];
    // The rest: the words, the colours, the @handle's size and place.
    final more = <Widget>[
      heading('Words', actions: [
        // Stepped, beside the slider's continuous size.
        IconButton(
          key: const Key('text-card-master-size-down'),
          tooltip: 'Smaller text',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          icon: const Icon(Icons.text_decrease_rounded),
          onPressed: look.wordsSize <= kQuickWordsSizeMin ? null : () => _edit((d) => d.withWordsSize((d.wordsSize - 8).clamp(kQuickWordsSizeMin, kQuickWordsSizeMax))),
        ),
        IconButton(
          key: const Key('text-card-master-size-up'),
          tooltip: 'Larger text',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          icon: const Icon(Icons.text_increase_rounded),
          onPressed: look.wordsSize >= kQuickWordsSizeMax ? null : () => _edit((d) => d.withWordsSize((d.wordsSize + 8).clamp(kQuickWordsSizeMin, kQuickWordsSizeMax))),
        ),
      ]),
      _QuickSlider(
        key: const Key('text-card-master-size'),
        label: 'Text size',
        value: look.wordsSize,
        min: kQuickWordsSizeMin,
        max: kQuickWordsSizeMax,
        divisions: ((kQuickWordsSizeMax - kQuickWordsSizeMin) / 4).round(),
        shown: _percent(look.wordsSize),
        semantics: 'Text size ${_percent(look.wordsSize)} of the classic card\'s',
        onChanged: (v) => _edit((d) => d.withWordsSize(v)),
      ),
      _QuickSlider(
        key: const Key('text-card-master-line-height'),
        label: 'Line spacing',
        value: look.wordsLineHeight,
        min: kQuickLineHeightMin,
        max: kQuickLineHeightMax,
        divisions: ((kQuickLineHeightMax - kQuickLineHeightMin) / 0.05).round(),
        shown: '${look.wordsLineHeight.toStringAsFixed(2)}×',
        semantics: 'Line spacing ${look.wordsLineHeight.toStringAsFixed(2)} times the text size',
        onChanged: (v) => _edit((d) => d.withWordsLineHeight(v)),
      ),
      _QuickSlider(
        key: const Key('text-card-master-margin'),
        label: 'Margins',
        value: look.margin,
        min: kQuickMarginMin,
        max: kQuickMarginMax,
        divisions: ((kQuickMarginMax - kQuickMarginMin) / 4).round(),
        shown: '${(look.margin / kClassicMargin * 100).round()}%',
        semantics: 'Margins ${(look.margin / kClassicMargin * 100).round()}% of the classic card\'s',
        onChanged: (v) => _edit((d) => d.withQuickMargin(v)),
      ),
      _QuickRow(
        label: 'Words at',
        // The icons go where there is no room for them beside the words.
        child: LayoutBuilder(
          builder: (context, box) => Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<TextCardTextPosition>(
              key: const Key('text-card-master-position'),
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              segments: [
                for (final p in TextCardTextPosition.values)
                  ButtonSegment(
                    value: p,
                    label: Text(p.label, maxLines: 1, softWrap: false),
                    tooltip: 'The words at the ${p == TextCardTextPosition.center ? 'middle' : p.label.toLowerCase()} of every card',
                    icon: box.maxWidth < 280
                        ? null
                        : Icon(switch (p) {
                            TextCardTextPosition.top => Icons.vertical_align_top_rounded,
                            TextCardTextPosition.center => Icons.vertical_align_center_rounded,
                            TextCardTextPosition.bottom => Icons.vertical_align_bottom_rounded,
                          }, size: 16),
                  ),
              ],
              selected: {look.wordsPosition},
              onSelectionChanged: (s) => _edit((d) => d.withWordsPosition(s.first)),
            ),
          ),
        ),
      ),
      heading('Colours'),
      Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
        _ColourButton(
          key: const Key('text-card-master-text-colour'),
          label: 'Text',
          argb: look.wordsColor,
          tooltip: 'The words\' colour on every card (the @handle and signature follow)',
          onPicked: (v) => _edit((d) => d.withWordsColor(v)),
        ),
        _ColourButton(
          key: const Key('text-card-master-background-colour'),
          label: photo ? 'Background (photo)' : 'Background',
          argb: look.backgroundColor,
          tooltip: photo ? 'A plain colour behind the words, in place of the photo' : 'The card\'s colour behind the words',
          onPicked: (v) {
            // A colour picked is the background: the photo goes.
            if (photo) ref.read(composerProvider.notifier).setTextCardBackground(null);
            _edit((d) => d.withBackgroundColor(v));
          },
        ),
      ]),
      heading('@handle size and place'),
      _QuickSlider(
        key: const Key('text-card-master-handle-size'),
        label: 'Size',
        value: look.handleSize,
        min: kQuickHandleSizeMin,
        max: kQuickHandleSizeMax,
        divisions: ((kQuickHandleSizeMax - kQuickHandleSizeMin) / 2).round(),
        shown: '${(look.handleSize / kClassicHandleSize * 100).round()}%',
        semantics: '@handle size ${(look.handleSize / kClassicHandleSize * 100).round()}% of the classic card\'s',
        onChanged: (v) => _edit((d) => d.withHandleSize(v)),
      ),
      _QuickRow(
        label: 'Place',
        child: Align(
          alignment: Alignment.centerLeft,
          child: _HandlePlaces(value: look.handleAnchor, onChanged: (a) => _edit((d) => d.withHandleAnchor(a))),
        ),
      ),
      if (designed) ...[
        const SizedBox(height: Space.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('text-card-master-classic'),
            onPressed: () => ref.read(composerProvider.notifier).setTextCardDesign(null),
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('Back to the classic card'),
            style: TextButton.styleFrom(foregroundColor: nf.textMuted, textStyle: context.text.labelMedium),
          ),
        ),
      ] else
        Padding(
          padding: const EdgeInsets.only(top: Space.sm),
          child: Text(
            'The classic card until you change something here; then every network\'s card follows. Untouched, the cards stay as they are.',
            style: context.text.bodySmall?.copyWith(color: nf.textFaint, fontSize: 11.5),
          ),
        ),
    ];
    final controls = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [...handle, if (open) ...more]);
    // Compact sliders, so every control fits beside the card.
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
        tickMarkShape: SliderTickMarkShape.noTickMark,
        showValueIndicator: ShowValueIndicator.onDrag,
      ),
      child: controls,
    );
  }
}

/// A label and a control, lined up with the other rows.
class _QuickRow extends StatelessWidget {
  const _QuickRow({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 84, child: Text(label, style: context.text.bodyMedium)),
          Expanded(child: child),
        ]),
      );
}

/// A labelled slider with its value beside it; the arrow keys move it one
/// step ([divisions]) at a time.
class _QuickSlider extends StatelessWidget {
  const _QuickSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.shown,
    required this.semantics,
    required this.onChanged,
  });
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String shown;
  final String semantics;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => _QuickRow(
        label: label,
        child: Row(children: [
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: shown,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              semanticFormatterCallback: (_) => semantics,
              onChanged: onChanged,
            ),
          ),
          SizedBox(width: 48, child: Text(shown, textAlign: TextAlign.end, style: context.text.bodySmall)),
        ]),
      );
}

/// Where the @handle goes, picked on a little card: the three places along
/// its top edge and the three along its bottom, the words' lines between.
class _HandlePlaces extends StatelessWidget {
  const _HandlePlaces({required this.value, required this.onChanged});
  final CardAnchor value;
  final ValueChanged<CardAnchor> onChanged;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    Widget place(CardAnchor a) {
      final selected = a == value;
      return Tooltip(
        message: 'The @handle ${a.label.toLowerCase()}',
        child: Semantics(
          button: true,
          selected: selected,
          label: '@handle ${a.label.toLowerCase()}',
          child: InkWell(
            key: Key('text-card-master-handle-at-${a.name}'),
            borderRadius: Radii.rXs,
            onTap: () => onChanged(a),
            child: Container(
              width: 40,
              height: 24,
              decoration: BoxDecoration(color: selected ? nf.accentSoft : null, borderRadius: Radii.rXs),
              alignment: Alignment(a.x * 2 - 1, 0) * 0.6,
              child: Container(
                width: selected ? 18 : 12,
                height: 4,
                decoration: BoxDecoration(color: selected ? nf.accent : nf.textFaint, borderRadius: Radii.rPill),
              ),
            ),
          ),
        ),
      );
    }

    // The words, faint, where the card keeps them.
    Widget line(double width) => Container(
          width: width,
          height: 3,
          margin: const EdgeInsets.only(left: Space.sm + 2, top: 3),
          decoration: BoxDecoration(color: nf.border, borderRadius: Radii.rPill),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(borderRadius: Radii.rSm, border: Border.all(color: nf.borderStrong)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [for (final a in kQuickHandleAnchors.take(3)) place(a)]),
        line(84),
        line(64),
        const SizedBox(height: 3),
        Row(mainAxisSize: MainAxisSize.min, children: [for (final a in kQuickHandleAnchors.skip(3)) place(a)]),
      ]),
    );
  }
}

/// A colour of the card: its swatch, name and hex; opens [showCardColourDialog].
class _ColourButton extends StatelessWidget {
  const _ColourButton({super.key, required this.label, required this.argb, required this.tooltip, required this.onPicked});
  final String label;
  final int argb;
  final String tooltip;
  final ValueChanged<int> onPicked;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: Radii.rPill,
        onTap: () async {
          final picked = await showCardColourDialog(context, title: '$label colour', initial: argb);
          if (picked != null) onPicked(picked);
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(Space.xs + 2, Space.xs, Space.sm + 2, Space.xs),
          decoration: BoxDecoration(borderRadius: Radii.rPill, border: Border.all(color: nf.border)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(color: Color(argb | 0xFF000000), shape: Radii.circleShape, border: Border.all(color: nf.borderStrong)),
            ),
            const SizedBox(width: Space.sm),
            Text(label, style: context.text.labelMedium),
            const SizedBox(width: Space.xs + 2),
            Text(hexColor(argb), style: monoStyle(context, size: 11, color: nf.textFaint)),
          ]),
        ),
      ),
    );
  }
}

/// 1.3.5: any colour for a card, as Settings > Appearance picks the accent:
/// swatches, the colour wheel (arrow keys move it) and a hex field. Returns
/// the opaque ARGB colour, or null when cancelled.
Future<int?> showCardColourDialog(BuildContext context, {required String title, required int initial}) =>
    showDialog<int>(context: context, builder: (_) => _CardColourDialog(title: title, initial: initial | 0xFF000000));

class _CardColourDialog extends StatefulWidget {
  const _CardColourDialog({required this.title, required this.initial});
  final String title;
  final int initial;

  @override
  State<_CardColourDialog> createState() => _CardColourDialogState();
}

class _CardColourDialogState extends State<_CardColourDialog> {
  late int _color = widget.initial;
  late final TextEditingController _hex = TextEditingController(text: hexColor(widget.initial));
  String? _error;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  /// A swatch or the wheel: the hex field follows.
  void _pick(int color) => setState(() {
        _color = color | 0xFF000000;
        _error = null;
        final hex = hexColor(_color);
        _hex.value = TextEditingValue(text: hex, selection: TextSelection.collapsed(offset: hex.length));
      });

  void _typed(String text) => setState(() {
        final parsed = parseHexColor(text);
        _error = parsed == null && text.trim().isNotEmpty ? 'Use six hex digits, like #7D00FF.' : null;
        if (parsed != null) _color = parsed;
      });

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
              for (final s in kPictureColorSwatches)
                Semantics(
                  button: true,
                  selected: s == _color,
                  label: hexColor(s),
                  child: InkWell(
                    key: Key('card-colour-swatch-${hexColor(s).substring(1)}'),
                    customBorder: Radii.circleBorder,
                    onTap: () => _pick(s),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Color(s),
                        shape: Radii.circleShape,
                        border: Border.all(color: s == _color ? nf.accent : nf.borderStrong, width: s == _color ? 3 : 1),
                      ),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: Space.md),
            Center(child: ColorWheel(color: Color(_color), diameter: 176, onChanged: (c) => _pick(c.toARGB32()))),
            const SizedBox(height: Space.md),
            Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: Color(_color), borderRadius: Radii.rSm, border: Border.all(color: nf.borderStrong)),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: TextField(
                  key: const Key('card-colour-hex'),
                  controller: _hex,
                  style: monoStyle(context),
                  decoration: InputDecoration(labelText: 'Hex colour', hintText: '#7D00FF', errorText: _error, isDense: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')), LengthLimitingTextInputFormatter(7)],
                  onChanged: _typed,
                  onSubmitted: (_) => _error == null ? Navigator.pop(context, _color) : null,
                ),
              ),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
        FilledButton(key: const Key('card-colour-use'), onPressed: () => Navigator.pop(context, _color), child: const Text('Use this colour')),
      ],
    );
  }
}
