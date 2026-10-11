import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The one big call to action on a screen ("Post to 6 networks").
/// Signature gradient, soft colored glow, press-scale and a loading state.
class PrimaryAction extends StatefulWidget {
  const PrimaryAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = false,
    this.compact = false,
    this.trailing,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final bool expand;
  final bool compact;

  /// Small widget after the label (e.g. a count badge or a chevron).
  final Widget? trailing;

  @override
  State<PrimaryAction> createState() => _PrimaryActionState();
}

class _PrimaryActionState extends State<PrimaryAction> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final enabled = widget.onPressed != null && !widget.loading;
    final h = widget.compact ? 40.0 : 50.0;

    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.loading)
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
        else if (widget.icon != null)
          Icon(widget.icon, size: 19, color: enabled ? Colors.white : nf.textFaint),
        if (widget.loading || widget.icon != null) const SizedBox(width: Space.sm + 2),
        Flexible(
          child: Text(
            widget.label,
            overflow: TextOverflow.ellipsis,
            style: context.text.labelLarge?.copyWith(
              color: enabled ? Colors.white : nf.textFaint,
              fontSize: widget.compact ? 13.5 : 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
            ),
          ),
        ),
        if (widget.trailing != null) ...[const SizedBox(width: Space.sm), widget.trailing!],
      ],
    );

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: enabled ? widget.onPressed : null,
        child: Semantics(
          button: true,
          enabled: enabled,
          label: widget.label,
          child: AnimatedScale(
            scale: _down ? 0.97 : 1,
            duration: Motion.fast,
            curve: Motion.standard,
            child: AnimatedContainer(
              duration: Motion.medium,
              curve: Motion.standard,
              height: h,
              padding: EdgeInsets.symmetric(horizontal: widget.compact ? Space.lg : Space.xxl),
              decoration: BoxDecoration(
                gradient: enabled ? nf.brandGradient : null,
                color: enabled ? null : nf.surfaceSunken,
                borderRadius: BorderRadius.circular(h / 2.6),
                boxShadow: enabled ? nf.glow(nf.accent, strength: _hover ? 1.35 : 1) : null,
                border: enabled ? null : Border.all(color: nf.border),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Sheen on hover.
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: Motion.medium,
                      opacity: enabled && _hover ? 1 : 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(h / 2.6),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.white.withValues(alpha: 0.18), Colors.white.withValues(alpha: 0)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  content,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Square icon button with a tooltip, hover background and optional
/// "active" tint. Used in toolbars.
class ToolButton extends StatefulWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
    this.size = 38,
    this.badge,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;
  final double size;
  final String? badge;
  final Color? color;

  @override
  State<ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<ToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final enabled = widget.onPressed != null;
    final fg = !enabled ? nf.textFaint : widget.active ? nf.accent : (widget.color ?? (_hover ? nf.text : nf.textMuted));
    final bg = widget.active ? nf.accentSoft : (_hover && enabled ? nf.surfaceHover : Colors.transparent);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Semantics(
            button: true,
            label: widget.tooltip,
            child: AnimatedContainer(
              duration: Motion.fast,
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(color: bg, borderRadius: Radii.rSm),
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Icon(widget.icon, size: widget.size * 0.5, color: fg),
                  if (widget.badge != null)
                    Positioned(
                      right: 3,
                      top: 3,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(color: nf.accent, borderRadius: Radii.rPill),
                        child: Text(widget.badge!, style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact pill-shaped secondary button ("Schedule", "Save draft").
class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.label, required this.onPressed, this.icon, this.tone, this.filled = false});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color? tone;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final c = tone ?? nf.text;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: filled ? Colors.white : c,
        backgroundColor: filled ? c : null,
        side: BorderSide(color: filled ? c : nf.border),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md),
        minimumSize: const Size(0, 40),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 17), const SizedBox(width: Space.sm)],
        Text(label),
      ]),
    );
  }
}
