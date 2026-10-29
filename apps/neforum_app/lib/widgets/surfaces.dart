import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The basic container of the app: a surface with a hairline border.
/// Hover and press feedback when [onTap] is set.
class NfCard extends StatefulWidget {
  const NfCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.lg),
    this.onTap,
    this.selected = false,
    this.color,
    this.borderColor,
    this.radius,
    this.elevated = false,
    this.clip = true,
  });

  final Widget child;

  /// Three quarters of it with the compact density.
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool selected;
  final Color? color;
  final Color? borderColor;

  /// Defaults to [Radii.rLg].
  final BorderRadius? radius;

  /// Adds a soft shadow (popovers, floating bars).
  final bool elevated;
  final bool clip;

  @override
  State<NfCard> createState() => _NfCardState();
}

class _NfCardState extends State<NfCard> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final interactive = widget.onTap != null;
    final border = widget.selected
        ? nf.accent
        : widget.borderColor ?? (interactive && _hover ? nf.borderStrong : nf.border);
    final bg = widget.color ?? (widget.selected ? nf.accentSoft : (interactive && _hover ? nf.surfaceHover : nf.surface));

    Widget content = AnimatedContainer(
      duration: context.motion(Motion.fast),
      curve: Motion.standard,
      padding: context.denseLayout ? widget.padding * 0.75 : widget.padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: widget.radius ?? Radii.rLg,
        border: Border.all(color: border, width: widget.selected ? 1.5 : 1),
        boxShadow: widget.elevated ? nf.elevation1 : null,
      ),
      clipBehavior: widget.clip ? Clip.antiAlias : Clip.none,
      child: widget.child,
    );

    if (!interactive) return content;

    // The press shrink is decoration: none when the system asks for less
    // motion.
    content = AnimatedScale(
      scale: _down && !context.reduceMotion ? 0.985 : 1,
      duration: context.motion(Motion.fast),
      curve: Motion.standard,
      child: content,
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: Semantics(button: true, child: content),
      ),
    );
  }
}

/// A recessed area (media tray, code block, drop zone).
class NfWell extends StatelessWidget {
  const NfWell({super.key, required this.child, this.padding = const EdgeInsets.all(Space.md), this.radius, this.dashed = false, this.highlight = false});

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Defaults to [Radii.rMd].
  final BorderRadius? radius;
  final bool dashed;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final radius = this.radius ?? Radii.rMd;
    final decoration = BoxDecoration(
      color: highlight ? nf.accentSoft : nf.surfaceSunken,
      borderRadius: radius,
      border: dashed ? null : Border.all(color: highlight ? nf.accent : nf.border),
    );
    final box = AnimatedContainer(duration: Motion.fast, padding: padding, decoration: decoration, child: child);
    if (!dashed) return box;
    return CustomPaint(
      foregroundPainter: _DashedBorderPainter(color: highlight ? nf.accent : nf.borderStrong, radius: radius),
      child: box,
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = radius.toRRect(Offset.zero & size).deflate(0.75);
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 6), paint);
        d += 11;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

/// Thin labelled divider: `──── Label ────`.
class LabeledDivider extends StatelessWidget {
  const LabeledDivider(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Row(children: [
      Expanded(child: Divider(color: nf.border)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.md),
        child: Text(label.toUpperCase(), style: context.text.labelSmall?.copyWith(color: nf.textFaint, letterSpacing: 1.2)),
      ),
      Expanded(child: Divider(color: nf.border)),
    ]);
  }
}
