import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// The offset from the center of a color wheel of [radius] at which [hue]
/// (degrees) and [saturation] (0 to 1) sit. Hue 0 (red) points right and
/// hues turn clockwise; saturation grows from the center (white) to the edge.
Offset colorWheelOffset(double hue, double saturation, double radius) {
  final angle = hue * math.pi / 180;
  return Offset(math.cos(angle), math.sin(angle)) * (saturation.clamp(0.0, 1.0) * radius);
}

/// The hue (degrees, 0 to under 360) and saturation (0 to 1) at [offset]
/// from the center of a color wheel of [radius]. Points outside the wheel
/// give its edge.
({double hue, double saturation}) colorWheelHueSaturation(Offset offset, double radius) {
  final saturation = radius <= 0 ? 0.0 : (offset.distance / radius).clamp(0.0, 1.0);
  var hue = math.atan2(offset.dy, offset.dx) * 180 / math.pi;
  if (hue < 0) hue += 360;
  return (hue: hue % 360, saturation: saturation);
}

/// An HSV color picker: a hue and saturation wheel with a draggable thumb,
/// and a brightness (value) slider under it.
///
/// Mouse, touch and keyboard: drag or tap on the wheel; with the wheel
/// focused, Left and Right turn the hue, Up and Down change the saturation
/// (hold Shift for bigger steps). The slider takes the arrow keys as any
/// slider does. Screen readers adjust the hue with increase and decrease,
/// and the saturation with the wheel's custom actions.
///
/// Opaque colors only: [color]'s alpha is ignored and [onChanged] always
/// gets an opaque color. Greys and black keep the hue (and black the
/// saturation) the wheel had, so the thumb does not jump.
class ColorWheel extends StatefulWidget {
  const ColorWheel({super.key, required this.color, required this.onChanged, this.onChangeEnd, this.diameter = 200});

  final Color color;

  /// Every change, while the user drags too.
  final ValueChanged<Color> onChanged;

  /// When a drag, tap or key press is over.
  final ValueChanged<Color>? onChangeEnd;

  /// Of the wheel. The widget is a little wider (room for the thumb and the
  /// focus ring).
  final double diameter;

  /// Room around the wheel for the thumb at its edge and the focus ring.
  static const double margin = 14;

  @override
  State<ColorWheel> createState() => _ColorWheelState();
}

class _ColorWheelState extends State<ColorWheel> {
  late HSVColor _hsv = HSVColor.fromColor(widget.color.withValues(alpha: 1));
  final FocusNode _focus = FocusNode(debugLabel: 'ColorWheel');
  bool _focused = false;

  double get _radius => widget.diameter / 2;

  @override
  void didUpdateWidget(ColorWheel old) {
    super.didUpdateWidget(old);
    final next = widget.color.withValues(alpha: 1);
    if (next.toARGB32() == _hsv.toColor().toARGB32()) return;
    final hsv = HSVColor.fromColor(next);
    final achromatic = hsv.saturation == 0 || hsv.value == 0;
    _hsv = HSVColor.fromAHSV(
      1,
      achromatic ? _hsv.hue : hsv.hue,
      hsv.value == 0 ? _hsv.saturation : hsv.saturation,
      hsv.value,
    );
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _emit(HSVColor hsv, {bool end = false}) {
    setState(() => _hsv = hsv);
    final color = hsv.toColor();
    widget.onChanged(color);
    if (end) widget.onChangeEnd?.call(color);
  }

  void _end() => widget.onChangeEnd?.call(_hsv.toColor());

  void _pointAt(Offset local) {
    final center = Offset(_radius + ColorWheel.margin, _radius + ColorWheel.margin);
    final hs = colorWheelHueSaturation(local - center, _radius);
    _emit(_hsv.withHue(hs.hue).withSaturation(hs.saturation));
  }

  void _turnHue(double degrees) => _emit(_hsv.withHue((_hsv.hue + degrees) % 360), end: true);

  void _saturate(double amount) => _emit(_hsv.withSaturation((_hsv.saturation + amount).clamp(0.0, 1.0)), end: true);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final big = HardwareKeyboard.instance.isShiftPressed;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      _turnHue(big ? 15 : 2);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _turnHue(big ? -15 : -2);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _saturate(big ? 0.1 : 0.02);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _saturate(big ? -0.1 : -0.02);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  static String _percent(double v) => '${(v * 100).round()}%';

  String _describe(HSVColor hsv) => 'hue ${hsv.hue.round()} degrees, saturation ${_percent(hsv.saturation)}';

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final side = widget.diameter + ColorWheel.margin * 2;
    final hsv = _hsv;
    final full = hsv.withValue(1).toColor();

    final wheel = Semantics(
      slider: true,
      focusable: true,
      focused: _focused,
      label: 'Hue and saturation',
      value: _describe(hsv),
      increasedValue: _describe(hsv.withHue((hsv.hue + 5) % 360)),
      decreasedValue: _describe(hsv.withHue((hsv.hue - 5) % 360)),
      hint: 'Left and right arrows change the hue, up and down the saturation',
      onIncrease: () => _turnHue(5),
      onDecrease: () => _turnHue(-5),
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'More saturated'): () => _saturate(0.05),
        const CustomSemanticsAction(label: 'Less saturated'): () => _saturate(-0.05),
      },
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        onFocusChange: (f) => setState(() => _focused = f),
        child: MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              _ImmediatePanGestureRecognizer: GestureRecognizerFactoryWithHandlers<_ImmediatePanGestureRecognizer>(
                () => _ImmediatePanGestureRecognizer(debugOwner: this),
                (r) {
                  r.onDown = (d) {
                    _focus.requestFocus();
                    _pointAt(d.localPosition);
                  };
                  r.onUpdate = (d) => _pointAt(d.localPosition);
                  r.onEnd = (_) => _end();
                  r.onCancel = _end;
                },
              ),
            },
            child: CustomPaint(
              size: Size.square(side),
              painter: _WheelPainter(
                hsv: hsv,
                radius: _radius,
                margin: ColorWheel.margin,
                edge: nf.border,
                focusRing: _focused ? nf.accent : null,
              ),
            ),
          ),
        ),
      ),
    );

    final brightness = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 12,
        trackShape: _GradientTrackShape(LinearGradient(colors: [Colors.black, full]), edge: nf.border),
        thumbShape: _RingThumbShape(fill: hsv.toColor()),
        overlayColor: nf.accent.withValues(alpha: 0.12),
        activeTrackColor: full,
        inactiveTrackColor: full,
        showValueIndicator: ShowValueIndicator.never,
      ),
      child: MergeSemantics(
        child: Semantics(
          label: 'Brightness',
          child: Slider(
            value: hsv.value,
            onChanged: (v) => _emit(_hsv.withValue(v)),
            onChangeEnd: (_) => _end(),
            semanticFormatterCallback: _percent,
          ),
        ),
      ),
    );

    return SizedBox(
      width: side,
      child: Column(mainAxisSize: MainAxisSize.min, children: [wheel, brightness]),
    );
  }
}

/// A pan that claims the pointer as soon as it touches the wheel, so a drag
/// in a scrolling dialog moves the thumb instead of scrolling.
class _ImmediatePanGestureRecognizer extends PanGestureRecognizer {
  _ImmediatePanGestureRecognizer({super.debugOwner});

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter({required this.hsv, required this.radius, required this.margin, required this.edge, required this.focusRing});

  final HSVColor hsv;
  final double radius;
  final double margin;
  final Color edge;
  final Color? focusRing;

  static final List<Color> _hues = [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, (h % 360).toDouble(), 1, 1).toColor()];

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(margin + radius, margin + radius);
    final disc = Rect.fromCircle(center: center, radius: radius);
    // At full brightness, HSV (h, s, 1) is white blended toward the pure hue
    // by s: the hue sweep under a white center fading out at the edge. Lower
    // brightness scales every channel, a black veil of 1 - v.
    canvas.drawCircle(center, radius, Paint()..shader = SweepGradient(colors: _hues).createShader(disc));
    canvas.drawCircle(
      center,
      radius,
      Paint()..shader = RadialGradient(colors: [Colors.white, Colors.white.withValues(alpha: 0)]).createShader(disc),
    );
    if (hsv.value < 1) canvas.drawCircle(center, radius, Paint()..color = Colors.black.withValues(alpha: 1 - hsv.value));
    canvas.drawCircle(center, radius - 0.5, Paint()
      ..style = PaintingStyle.stroke
      ..color = edge);

    final ring = focusRing;
    if (ring != null) {
      canvas.drawCircle(center, radius + 4, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ring);
    }

    final thumb = center + colorWheelOffset(hsv.hue, hsv.saturation, radius);
    _paintThumb(canvas, thumb, hsv.toColor());
  }

  @override
  bool shouldRepaint(_WheelPainter old) =>
      old.hsv != hsv || old.radius != radius || old.edge != edge || old.focusRing != focusRing || old.margin != margin;
}

/// A thumb that shows on every color: the color inside a white ring with a
/// dark outline.
void _paintThumb(Canvas canvas, Offset center, Color fill) {
  canvas.drawCircle(center, 11, Paint()..color = const Color(0x66000000));
  canvas.drawCircle(center, 10, Paint()..color = Colors.white);
  canvas.drawCircle(center, 7, Paint()..color = fill);
}

class _RingThumbShape extends SliderComponentShape {
  const _RingThumbShape({required this.fill});

  final Color fill;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size.square(22);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) =>
      _paintThumb(context.canvas, center, fill);
}

class _GradientTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _GradientTrackShape(this.gradient, {required this.edge});

  final Gradient gradient;
  final Color edge;

  @override
  bool get isRounded => true;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(parentBox: parentBox, offset: offset, sliderTheme: sliderTheme, isEnabled: isEnabled, isDiscrete: isDiscrete);
    final track = RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2));
    context.canvas
      ..drawRRect(track, Paint()..shader = gradient.createShader(rect))
      ..drawRRect(track.deflate(0.5), Paint()
        ..style = PaintingStyle.stroke
        ..color = edge);
  }
}
