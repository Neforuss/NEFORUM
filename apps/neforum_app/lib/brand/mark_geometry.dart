/// Geometry of the NEFORUM mark, shared by the in-app painter
/// (neforum_logo.dart) and tool/generate_icons.dart. Pure Dart on purpose:
/// the icon tool runs without Flutter.
///
/// The mark is a diamond. Its top half is the broadcast sign NEFORUM started
/// with: a point in a round window, an arc over it, and the solid roof as the
/// outer arc. Below the middle the signal breaks into bars, one for every
/// platform. "One message, every platform."
class MarkGeometry {
  MarkGeometry._(this.cx, this.cy, this.r, this.bars, this.simple);

  /// Lays the mark out in a tile [tile] px wide centred on ([cx], [cy]).
  ///
  /// [radius] is the diamond's half-diagonal as a fraction of the tile. Below
  /// 96 px the bars snap to whole pixels and there are fewer of them, and
  /// below [simpleBelow] the inner arc is left out, so small icons stay crisp
  /// instead of turning into a blur.
  factory MarkGeometry(double tile, {required double cx, required double cy, double radius = defaultRadius}) {
    final target = tile * radius;
    final n = barCountFor(tile);
    final simple = tile < simpleBelow;
    if (tile >= 96) {
      final p = target / n;
      return MarkGeometry._(cx, cy, target, _bars(n, p, p * barFill), simple);
    }
    final p = (target / n).round().clamp(2, 1 << 20).toDouble();
    final t = (p * barFill).roundToDouble().clamp(1.0, p - 1);
    return MarkGeometry._(cx, cy.roundToDouble(), n * p, _bars(n, p, t), simple);
  }

  /// Half-diagonal of the diamond, as a fraction of the tile.
  static const double defaultRadius = 0.38;

  /// Share of each bar's period that is solid.
  static const double barFill = 0.5;

  /// Tiles narrower than this get the simple mark: no inner arc, a bigger
  /// window and point.
  static const double simpleBelow = 36;

  /// How many bars a tile [px] wide gets.
  static int barCountFor(double px) => px <= 24 ? 3 : (px <= 40 ? 4 : (px < 96 ? 5 : 6));

  final double cx, cy;

  /// Half-diagonal of the outer diamond, in px.
  final double r;

  /// Bars as (top, bottom) offsets below [cy], in px. The last one ends at
  /// the bottom tip.
  final List<(double, double)> bars;

  /// The small-size mark without the inner arc.
  final bool simple;

  /// Radius of the point at the centre.
  double get pointRadius => r * (simple ? 0.16 : 0.13);

  /// Radius of the round window around the point, cut out of the bars.
  double get windowRadius => r * (simple ? 0.47 : 0.30);

  /// Inner and outer radius of the arc over the point (top half only), or
  /// null for the simple mark.
  (double, double)? get arc => simple ? null : (r * 0.30, r * 0.47);

  /// The roof (the outer arc) starts beyond this radius.
  double get roofInner => r * (simple ? 0.47 : 0.56);

  /// Corners of the outer diamond (top, right, bottom, left).
  List<(double, double)> get diamond => [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)];

  static List<(double, double)> _bars(int n, double p, double t) => [for (var k = 0; k < n; k++) (k * p + (p - t), (k + 1) * p)];
}
