import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The NEFORUM mark: one yellow point broadcasting outward in three white
/// arcs, on the purple tile. "One message, every platform."
///
/// With [animate] the arcs pulse outward in sequence (used while publishing).
class NeforumMark extends StatefulWidget {
  const NeforumMark({super.key, this.size = 40, this.animate = false, this.gradient});

  final double size;
  final bool animate;

  /// Defaults to the fixed brand tile ([Brand.markGradient]).
  final Gradient? gradient;

  @override
  State<NeforumMark> createState() => _NeforumMarkState();
}

class _NeforumMarkState extends State<NeforumMark> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void didUpdateWidget(NeforumMark old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_c.isAnimating) _c.repeat();
    if (!widget.animate && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        gradient: widget.gradient ?? Brand.markGradient,
        borderRadius: BorderRadius.circular(s * 0.3),
      ),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(
          painter: _MarkPainter(progress: widget.animate ? _c.value : null),
        ),
      ),
    );
  }
}

/// Paints the full mark (tile, yellow point, white arcs) into [rect], for
/// canvases that are not widgets (generated text cards).
void paintNeforumMark(Canvas canvas, Rect rect) {
  final tile = RRect.fromRectAndRadius(rect, Radius.circular(rect.width * 0.3));
  canvas.drawRRect(tile, Paint()..shader = Brand.markGradient.createShader(rect));
  canvas.save();
  canvas.translate(rect.left, rect.top);
  _MarkPainter().paint(canvas, rect.size);
  canvas.restore();
}

class _MarkPainter extends CustomPainter {
  _MarkPainter({this.progress});

  /// 0..1 animation phase, or null for the static mark.
  final double? progress;

  /// Mark size relative to the tile (matches tool/generate_icons.dart).
  static const double k = 0.82;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width * k;
    final origin = Offset(size.width * 0.5 - w * 0.20, size.height * 0.5);
    final dot = Paint()..color = Brand.yellow;
    canvas.drawCircle(origin, w * 0.085, dot);

    const sweep = 100 * math.pi / 180;
    final radii = [0.21, 0.355, 0.50];
    final baseAlpha = [1.0, 0.82, 0.62];
    for (var i = 0; i < radii.length; i++) {
      var alpha = baseAlpha[i];
      if (progress != null) {
        // Each arc lights up a third of a cycle after the previous one.
        final phase = (progress! - i * 0.22) % 1.0;
        alpha = 0.35 + 0.65 * (phase < 0.5 ? math.sin(phase * math.pi * 2).clamp(0.0, 1.0) : 0.0);
      }
      final p = Paint()
        ..color = Colors.white.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = w * 0.078;
      final r = w * radii[i];
      canvas.drawArc(Rect.fromCircle(center: origin, radius: r), -sweep / 2, sweep, false, p);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.progress != progress;
}

/// Mark + "NEFORUM" wordmark.
class NeforumWordmark extends StatelessWidget {
  const NeforumWordmark({super.key, this.size = 30, this.showTagline = false, this.onChrome = false});

  final double size;
  final bool showTagline;

  /// White type for the deep-purple navigation chrome.
  final bool onChrome;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        NeforumMark(size: size),
        SizedBox(width: size * 0.36),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'NEFORUM',
              style: TextStyle(
                fontFamily: Fonts.display,
                fontWeight: FontWeight.w800,
                fontSize: size * 0.62,
                letterSpacing: size * 0.035,
                height: 1,
                color: onChrome ? nf.onChrome : nf.text,
              ),
            ),
            if (showTagline) ...[
              SizedBox(height: size * 0.12),
              Text(
                'One message, every platform',
                style: TextStyle(fontSize: size * 0.34, color: onChrome ? nf.onChromeMuted : nf.textFaint, height: 1, fontWeight: FontWeight.w500),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
