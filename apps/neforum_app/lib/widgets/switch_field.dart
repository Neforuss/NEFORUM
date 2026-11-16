import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 1.4.4: a yes/no setting in a form, drawn as one of its text fields: the
/// same fill, outline and corners, and its label starts where a text field's
/// text starts (the theme's `inputDecorationTheme.contentPadding`), so a
/// switch row lines up with the fields above and below it in every density,
/// corner style and Seamless setting. The switch keeps the same inset from
/// the right edge, and the whole row toggles it.
///
/// Replaces a `SwitchListTile` with zero padding, whose label sat flush
/// against the row's left edge and whose switch hugged the right.
class NfSwitchField extends StatelessWidget {
  const NfSwitchField({super.key, required this.label, required this.value, required this.onChanged, this.errorText});

  final String label;
  final bool value;

  /// Null disables the row.
  final ValueChanged<bool>? onChanged;
  final String? errorText;

  /// A Material 3 switch with a shrink-wrapped tap target: a 60 x 40 box
  /// whose track (52 x 32) sits in its middle.
  static const double _switchHeight = 40;
  static const double _switchWidth = 60;

  /// The visible track's width: the box has (60 - 52) / 2 px of margin on
  /// each side, taken out of the right padding so the track's right end sits
  /// as far from the edge as the label's start from the left.
  static const double trackWidth = 52;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dir = Directionality.of(context);
    final themed = (theme.inputDecorationTheme.contentPadding ?? const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md)).resolve(dir);
    // As tall as a one-line text field: the switch is taller than a line of
    // text, so it takes that difference out of the padding above and below.
    final line = (theme.textTheme.bodyMedium?.fontSize ?? 14) * (theme.textTheme.bodyMedium?.height ?? 1.43);
    final trim = ((_switchHeight - line) / 2).clamp(0.0, themed.top);
    const margin = (_switchWidth - trackWidth) / 2;
    final padding = EdgeInsets.fromLTRB(themed.left, themed.top - trim, (themed.right - margin).clamp(0.0, themed.right), themed.bottom - trim);
    final enabled = onChanged != null;
    final radius = _radiusOf(theme.inputDecorationTheme.enabledBorder) ?? Radii.rMd;

    return MergeSemantics(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: enabled ? () => onChanged!(!value) : null,
          child: InputDecorator(
            isEmpty: false,
            decoration: InputDecoration(contentPadding: padding, errorText: errorText, enabled: enabled, isDense: true),
            child: Row(
              children: [
                Expanded(
                  child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: enabled ? null : context.nf.textFaint)),
                ),
                const SizedBox(width: Space.md),
                Switch(value: value, onChanged: onChanged, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static BorderRadius? _radiusOf(InputBorder? border) => border is OutlineInputBorder ? border.borderRadius : null;
}
