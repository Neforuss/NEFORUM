import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart' show monoStyle;
import '../theme/tokens.dart';

/// Colours offered as swatches for colours the user picks for pictures (ARGB).
const List<int> kPictureColorSwatches = [
  0xFFFFFFFF,
  0xFF000000,
  0xFFFFFF00,
  0xFF7D00FF,
  0xFFFF3B30,
  0xFFFF9500,
  0xFF34C759,
  0xFF0A84FF,
  0xFFFF2D55,
];

/// Picks an opaque colour for a picture (a card's tint or gradient): a row of
/// swatches plus a hex field. Every colour choice in the card background
/// editor goes through this one widget, so a fuller picker (a colour wheel)
/// can replace its body later without touching the editor.
class ColorSwatchField extends StatefulWidget {
  const ColorSwatchField({super.key, required this.value, required this.onChanged, required this.label, this.swatches = kPictureColorSwatches});

  /// ARGB; the alpha is ignored.
  final int value;
  final ValueChanged<int> onChanged;

  /// What the colour is for, for screen readers ("Tint").
  final String label;
  final List<int> swatches;

  @override
  State<ColorSwatchField> createState() => _ColorSwatchFieldState();
}

class _ColorSwatchFieldState extends State<ColorSwatchField> {
  late final TextEditingController _hex = TextEditingController(text: _hexOf(widget.value));

  static String _hexOf(int argb) => (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  @override
  void didUpdateWidget(ColorSwatchField old) {
    super.didUpdateWidget(old);
    final shown = int.tryParse(_hex.text, radix: 16);
    if ((widget.value & 0xFFFFFF) != shown) _hex.text = _hexOf(widget.value);
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _typed(String text) {
    if (text.length != 6) return;
    final v = int.tryParse(text, radix: 16);
    if (v != null) widget.onChanged(0xFF000000 | v);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final current = widget.value | 0xFF000000;
    return Wrap(spacing: Space.sm, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final c in widget.swatches)
        Semantics(
          button: true,
          selected: c == current,
          label: '${widget.label} #${_hexOf(c)}',
          child: InkWell(
            customBorder: Radii.circleBorder,
            onTap: () => widget.onChanged(c),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: Color(c),
                shape: Radii.circleShape,
                border: Border.all(color: c == current ? nf.accent : nf.borderStrong, width: c == current ? 3 : 1),
              ),
            ),
          ),
        ),
      SizedBox(
        width: 112,
        child: TextField(
          controller: _hex,
          style: monoStyle(context),
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]'))],
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            prefixText: '#',
            labelText: '${widget.label} hex',
            prefixIcon: Padding(
              padding: const EdgeInsets.all(Space.sm),
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(color: Color(current), shape: Radii.circleShape, border: Border.all(color: nf.borderStrong)),
              ),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          onChanged: _typed,
        ),
      ),
    ]);
  }
}
