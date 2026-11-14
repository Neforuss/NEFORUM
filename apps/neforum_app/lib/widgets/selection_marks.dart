import 'package:flutter/material.dart';

import '../theme/selection_theme.dart';
import '../theme/tokens.dart';

/// 1.4.3: clear selected state. The marks a hand-made selectable control
/// uses to show it is on, matching the themed chips (see
/// lib/theme/selection_theme.dart): a solid [NfSelection.selectedFill] and a
/// check mark, never a tint or a border alone.

/// A round check in the selected fill, for the corner of a selected tile,
/// thumbnail or card. Drawn with a ring in the surface color, so it stands
/// out on a picture too.
class SelectionCheckBadge extends StatelessWidget {
  const SelectionCheckBadge({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return ExcludeSemantics(
      child: Container(
        key: const Key('selection-check-badge'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: nf.selectedFill,
          shape: BoxShape.circle,
          border: Border.all(color: nf.surface, width: 1.5),
        ),
        child: Icon(Icons.check_rounded, size: size * 0.68, color: nf.onSelectedFill),
      ),
    );
  }
}

/// [child] with a [SelectionCheckBadge] on its top-right corner while
/// [selected].
class SelectionBadged extends StatelessWidget {
  const SelectionBadged({super.key, required this.selected, required this.child, this.inset = 4, this.size = 20});

  final bool selected;
  final Widget child;
  final double inset;
  final double size;

  @override
  Widget build(BuildContext context) => Stack(children: [
        child,
        if (selected) Positioned(top: inset, right: inset, child: SelectionCheckBadge(size: size)),
      ]);
}

/// The check on a selected color swatch, white or ink, whichever reads on
/// [color].
Widget swatchCheck(Color color, {double size = 14}) =>
    Icon(Icons.check_rounded, key: const Key('swatch-check'), size: size, color: readableOn(color.withValues(alpha: 1)));

/// A small pill that switches an option on or off, as under the composer's
/// previews. On, it is filled with the [NfSelection.selectedFill] and shows
/// a check before its [leading] mark; off, it is outlined. A null [selected]
/// makes it a plain action (it never shows as on).
///
/// [leading] icons and text take the pill's own color, so give them none.
class OptionPill extends StatelessWidget {
  const OptionPill({super.key, required this.label, required this.leading, required this.onTap, this.selected, this.tooltip});

  final String label;
  final Widget leading;
  final VoidCallback? onTap;
  final bool? selected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final on = selected == true;
    final fg = on ? nf.onSelectedFill : nf.textMuted;
    return Tooltip(
      message: tooltip ?? label,
      child: Semantics(
        button: true,
        toggled: selected,
        enabled: onTap != null,
        child: InkWell(
          borderRadius: Radii.rPill,
          onTap: onTap,
          child: AnimatedContainer(
            duration: context.motion(Motion.fast),
            padding: const EdgeInsets.symmetric(horizontal: Space.sm + 2, vertical: Space.xs + 1),
            decoration: BoxDecoration(
              color: on ? nf.selectedFill : Colors.transparent,
              borderRadius: Radii.rPill,
              border: Border.all(color: on ? nf.selectedFill : nf.border),
            ),
            child: IconTheme.merge(
              data: IconThemeData(color: on ? fg : nf.textFaint, size: 14),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: fg),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (on) ...[
                    Icon(Icons.check_rounded, key: const Key('option-pill-check'), size: 14, color: fg),
                    const SizedBox(width: Space.xs),
                  ],
                  leading,
                  const SizedBox(width: Space.xs + 2),
                  Text(label, style: context.text.labelSmall?.copyWith(color: fg)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
