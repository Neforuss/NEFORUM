import 'package:flutter/widgets.dart';

/// The zoom steps of the desktop apps, like a browser's.
const kZoomLevels = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];

double zoomIn(double zoom) => kZoomLevels.firstWhere((l) => l > zoom + 0.001, orElse: () => kZoomLevels.last);
double zoomOut(double zoom) => kZoomLevels.lastWhere((l) => l < zoom - 0.001, orElse: () => kZoomLevels.first);

/// A stored zoom that can be used: within the steps' range, 1 otherwise.
double validZoom(Object? zoom) {
  if (zoom is! num || !zoom.isFinite) return 1;
  return zoom.toDouble().clamp(kZoomLevels.first, kZoomLevels.last);
}

String zoomLabel(double zoom) => '${(zoom * 100).round()}%';

/// Where [box] is in the window, in the window's own pixels, for native
/// popovers (share sheets): the app's pixels are zoomed.
Rect windowRectOf(BuildContext context, RenderBox box) {
  final zoom = ZoomScope.of(context);
  final o = box.localToGlobal(Offset.zero);
  return Rect.fromLTWH(o.dx * zoom, o.dy * zoom, box.size.width * zoom, box.size.height * zoom);
}

/// The zoom the widgets below are drawn at (see UiZoom).
class ZoomScope extends InheritedWidget {
  const ZoomScope({super.key, required this.zoom, required super.child});
  final double zoom;

  /// 1 without a [ZoomScope].
  static double of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ZoomScope>()?.zoom ?? 1;

  @override
  bool updateShouldNotify(ZoomScope old) => zoom != old.zoom;
}
