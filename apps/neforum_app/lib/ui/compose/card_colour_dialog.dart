import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/tokens.dart';
import '../../widgets/color_swatch_field.dart' show kPictureColorSwatches;
import '../../widgets/color_wheel.dart';
import '../settings/appearance_section.dart' show hexColor, parseHexColor;

/// What [showCardColourDialog] returns: the colour picked (opaque ARGB), or a
/// null [color] for the default back. The dialog itself returns null when it
/// is cancelled.
typedef CardColourChoice = ({int? color});

/// 1.3.5: cards. Picks any colour for a part of a text card (its words, the
/// card, the @handle) the way Settings > Appearance picks the accent colour:
/// swatches, the colour wheel with its brightness slider, and a hex code,
/// all following each other. [current] is the part's own colour, null while
/// it has the default [fallback] (the theme's); [defaultLabel] names the
/// button that puts the default back.
Future<CardColourChoice?> showCardColourDialog(BuildContext context,
        {required String title, required int? current, required Color fallback, required String defaultLabel}) =>
    showDialog<CardColourChoice>(
      context: context,
      builder: (_) => CardColourDialog(title: title, current: current, fallback: fallback, defaultLabel: defaultLabel),
    );

class CardColourDialog extends StatefulWidget {
  const CardColourDialog({super.key, required this.title, required this.current, required this.fallback, required this.defaultLabel});

  final String title;
  final int? current;
  final Color fallback;
  final String defaultLabel;

  @override
  State<CardColourDialog> createState() => _CardColourDialogState();
}

class _CardColourDialogState extends State<CardColourDialog> {
  late int _color = widget.current ?? (widget.fallback.toARGB32() | 0xFF000000);
  late final TextEditingController _hex = TextEditingController(text: hexColor(_color));
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
    final compact = MediaQuery.sizeOf(context).width < 600;
    final swatches = {widget.fallback.toARGB32() | 0xFF000000, ...kPictureColorSwatches};
    final wheel = ColorWheel(color: Color(_color), diameter: compact ? 180 : 164, onChanged: (c) => _pick(c.toARGB32()));
    final details = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        key: const Key('card-colour-hex'),
        controller: _hex,
        decoration: InputDecoration(labelText: 'Hex colour', hintText: '#7D00FF', errorText: _error),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')), LengthLimitingTextInputFormatter(7)],
        onChanged: _typed,
        onSubmitted: (_) {
          if (_error == null) Navigator.pop(context, (color: _color));
        },
      ),
      const SizedBox(height: Space.lg),
      Semantics(
        label: 'The colour picked, ${hexColor(_color)}',
        child: Container(
          height: 40,
          decoration: BoxDecoration(color: Color(_color), borderRadius: Radii.rSm, border: Border.all(color: nf.borderStrong)),
        ),
      ),
    ]);
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pick a colour on the wheel or below it, or type its hex code.', style: context.text.bodySmall),
            const SizedBox(height: Space.lg),
            Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
              for (final c in swatches)
                _Swatch(color: c, selected: c == _color, onTap: () => _pick(c)),
            ]),
            const SizedBox(height: Space.lg),
            if (compact) ...[
              Center(child: wheel),
              const SizedBox(height: Space.md),
              details,
            ] else
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                wheel,
                const SizedBox(width: Space.lg),
                Expanded(child: Padding(padding: const EdgeInsets.only(top: ColorWheel.margin), child: details)),
              ]),
          ]),
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(key: const Key('card-colour-default'), onPressed: () => Navigator.pop(context, (color: null)), child: Text(widget.defaultLabel)),
        TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
        FilledButton(key: const Key('card-colour-use'), onPressed: () => Navigator.pop(context, (color: _color)), child: const Text('Use this colour')),
      ],
    );
  }
}

/// A round swatch of the dialog, focusable and named for screen readers.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected, required this.onTap});
  final int color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Tooltip(
      message: hexColor(color),
      child: Semantics(
        button: true,
        selected: selected,
        label: hexColor(color),
        child: InkWell(
          customBorder: Radii.circleBorder,
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(shape: Radii.circleShape, border: Border.all(color: selected ? nf.text : Colors.transparent, width: 2)),
            child: Container(
              decoration: BoxDecoration(color: Color(color), shape: Radii.circleShape, border: Border.all(color: nf.borderStrong)),
            ),
          ),
        ),
      ),
    );
  }
}
