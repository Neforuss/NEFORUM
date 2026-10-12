import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'mark_geometry.dart';

/// The NEFORUM mark, yellow on the purple tile: a diamond whose top half is
/// the broadcast sign (a point, an arc over it, the roof as the outer arc)
/// and whose bottom half breaks into bars, one for every platform.
/// "One message, every platform." Geometry: [MarkGeometry].
///
/// With [animate] the arc and then each bar light up in turn, the message
/// travelling out (used while publishing).
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

/// Paints the full mark (tile and diamond) into [rect], for canvases that are
/// not widgets (generated text cards).
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

  /// Opacity of the [i]th moving part (0 = the arc, then each bar).
  double _alpha(int i) {
    if (progress == null) return 1;
    // Each part lights up a little after the one before it.
    final phase = (progress! - i * 0.12) % 1.0;
    return 0.3 + 0.7 * (phase < 0.5 ? math.sin(phase * math.pi * 2).clamp(0.0, 1.0) : 0.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = MarkGeometry(size.width, cx: size.width / 2, cy: size.height / 2);
    final centre = Offset(g.cx, g.cy);
    final yellow = Paint()..color = Brand.yellow;
    final diamond = Path()..addPolygon([for (final (x, y) in g.diamond) Offset(x, y)], true);
    final topHalf = Path()..addRect(Rect.fromLTRB(g.cx - g.r, g.cy - g.r, g.cx + g.r, g.cy));
    Path circle(double radius) => Path()..addOval(Rect.fromCircle(center: centre, radius: radius));

    // Top half: the roof (outer arc), then the arc over the point.
    final roof = Path.combine(PathOperation.difference, Path.combine(PathOperation.intersect, diamond, topHalf), circle(g.roofInner));
    canvas.drawPath(roof, yellow);
    if (g.arc case (final inner, final outer)) {
      final band = Path.combine(PathOperation.difference, circle(outer), circle(inner));
      canvas.drawPath(Path.combine(PathOperation.intersect, band, topHalf), Paint()..color = Brand.yellow.withValues(alpha: _alpha(0)));
    }

    // Bottom half: bars clipped to the diamond, around the point's window.
    canvas.save();
    canvas.clipPath(Path.combine(PathOperation.difference, diamond, circle(g.windowRadius)));
    for (var i = 0; i < g.bars.length; i++) {
      final (top, bottom) = g.bars[i];
      canvas.drawRect(Rect.fromLTRB(g.cx - g.r, g.cy + top, g.cx + g.r, g.cy + bottom), Paint()..color = Brand.yellow.withValues(alpha: _alpha(i + 1)));
    }
    canvas.restore();

    canvas.drawCircle(centre, g.pointRadius, yellow);
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
