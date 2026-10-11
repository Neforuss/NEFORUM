import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Circular character budget indicator.
///
/// Fills as text grows; turns amber in the last 10% and red past the limit,
/// at which point it shows the overflow as a negative number. When [max] is
/// null (unlimited platforms) it shows the plain count.
class CharRing extends StatelessWidget {
  const CharRing({super.key, required this.used, required this.max, this.size = 26, this.showNumber = true, this.parts = 1, this.alwaysShowCount = false});

  final int used;
  final int? max;
  final double size;
  final bool showNumber;

  /// Show the remaining count even when far from the limit (so the ring is
  /// never mistaken for a loading spinner).
  final bool alwaysShowCount;

  /// When the text will be split into a thread, the number of parts.
  final int parts;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    if (max == null) {
      return Text('$used', style: monoStyle(context, size: 12, color: nf.textFaint));
    }
    final m = max!;
    final ratio = m == 0 ? 1.0 : used / m;
    final remaining = m - used;
    final color = parts > 1
        ? nf.info
        : ratio > 1
            ? nf.danger
            : ratio >= 0.9
                ? nf.warning
                : nf.accent;
    final showCount = showNumber && (alwaysShowCount || ratio >= 0.8 || parts > 1);
    final countColor = parts > 1 || ratio >= 0.9 ? color : nf.textFaint;
    return Tooltip(
      message: parts > 1 ? '$used characters → $parts-part thread' : '$used / $m characters',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (showCount) ...[
          AnimatedSwitcher(
            duration: Motion.fast,
            child: Text(
              parts > 1 ? '$parts parts' : '$remaining',
              key: ValueKey(parts > 1 ? 'p$parts' : remaining),
              style: monoStyle(context, size: 12, color: countColor, weight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: Space.xs + 2),
        ],
        TweenAnimationBuilder<double>(
          tween: Tween(end: ratio.clamp(0.0, 1.0)),
          duration: Motion.medium,
          curve: Motion.standard,
          builder: (context, v, _) => CustomPaint(
            size: Size.square(ratio > 1 ? size * 1.15 : size),
            painter: _RingPainter(value: v, color: color, track: nf.borderStrong, pulse: ratio > 1),
          ),
        ),
      ]),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.value, required this.color, required this.track, required this.pulse});

  final double value;
  final Color color;
  final Color track;
  final bool pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.12;
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke / 2);
    canvas.drawArc(r, 0, math.pi * 2, false, Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke);
    canvas.drawArc(r, -math.pi / 2, math.pi * 2 * value, false, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke);
    if (pulse) {
      canvas.drawCircle(rect.center, size.width * 0.16, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value || old.color != color || old.track != track;
}
