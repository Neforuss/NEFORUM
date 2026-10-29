// The color wheel (lib/widgets/color_wheel.dart) and the custom accent
// dialog that uses it beside the hex field.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/settings/appearance_section.dart';
import 'package:neforum_app/widgets/color_wheel.dart';

const _diameter = 200.0;

/// Hosts a [ColorWheel] that follows its own changes, like a real parent.
class _Host extends StatefulWidget {
  const _Host({super.key, required this.initial, required this.changes, required this.ends});
  final Color initial;
  final List<Color> changes;
  final List<Color> ends;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late Color color = widget.initial;

  void set(Color c) => setState(() => color = c);

  @override
  Widget build(BuildContext context) => ColorWheel(
        color: color,
        diameter: _diameter,
        onChanged: (c) {
          widget.changes.add(c);
          set(c);
        },
        onChangeEnd: widget.ends.add,
      );
}

Future<({List<Color> changes, List<Color> ends})> _pump(WidgetTester tester, Color initial) async {
  final changes = <Color>[];
  final ends = <Color>[];
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light, AccentChoice.neforum),
    home: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: _Host(key: ValueKey(initial), initial: initial, changes: changes, ends: ends)),
    ),
  ));
  return (changes: changes, ends: ends);
}

/// The wheel's center on screen.
Offset _center(WidgetTester tester) =>
    tester.getTopLeft(find.byType(ColorWheel)) + const Offset(ColorWheel.margin + _diameter / 2, ColorWheel.margin + _diameter / 2);

HSVColor _hsv(Color c) => HSVColor.fromColor(c);

void main() {
  group('geometry', () {
    test('hue and saturation round-trip through a point on the wheel', () {
      for (var hue = 0.0; hue < 360; hue += 7.5) {
        for (final saturation in [0.05, 0.3, 0.5, 0.8, 1.0]) {
          final back = colorWheelHueSaturation(colorWheelOffset(hue, saturation, 100), 100);
          expect(back.hue, closeTo(hue, 1e-9), reason: 'hue $hue, saturation $saturation');
          expect(back.saturation, closeTo(saturation, 1e-9));
        }
      }
    });

    test('red points right, hues turn clockwise, the center is white and outside is the edge', () {
      expect(colorWheelOffset(0, 1, 100).dx, closeTo(100, 1e-9));
      expect(colorWheelOffset(90, 1, 100).dy, closeTo(100, 1e-9), reason: 'screen y grows downward');
      expect(colorWheelHueSaturation(Offset.zero, 100).saturation, 0);
      expect(colorWheelHueSaturation(const Offset(0, -500), 100), (hue: 270.0, saturation: 1.0));
    });
  });

  group('widget', () {
    testWidgets('the thumb sits on the color, and a tap there gives the color back', (tester) async {
      for (final color in const [Color(0xFF7D00FF), Color(0xFF0F9F6E), Color(0xFFF2542D), Color(0xFF1677FF), Color(0xFFC77800)]) {
        final log = await _pump(tester, color);
        final hsv = _hsv(color);
        await tester.tapAt(_center(tester) + colorWheelOffset(hsv.hue, hsv.saturation, _diameter / 2));
        await tester.pump();
        final picked = _hsv(log.changes.single);
        expect(picked.hue, closeTo(hsv.hue, 1.5), reason: hexColor(color.toARGB32()));
        expect(picked.saturation, closeTo(hsv.saturation, 0.02));
        expect(picked.value, closeTo(hsv.value, 1e-9), reason: 'the wheel keeps the brightness');
        expect(log.ends, hasLength(1));
      }
    });

    testWidgets('dragging updates the color all along, and ends once', (tester) async {
      final log = await _pump(tester, const Color(0xFFFFFFFF));
      final gesture = await tester.startGesture(_center(tester));
      await tester.pump();
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(_center(tester) + Offset(i * 12.0, 0));
        await tester.pump();
      }
      await gesture.moveTo(_center(tester) + const Offset(0, 300));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(log.changes.length, greaterThanOrEqualTo(10));
      final mid = _hsv(log.changes[5]);
      expect(mid.hue, closeTo(0, 1e-6), reason: 'moving right: red');
      expect(mid.saturation, greaterThan(0.3));
      final last = _hsv(log.changes.last);
      expect(last.hue, closeTo(90, 0.5), reason: 'straight down, past the edge (8-bit channels round the hue a little)');
      expect(last.saturation, 1);
      expect(log.ends, [log.changes.last]);
    });

    testWidgets('a drag inside a scrolling view moves the thumb, not the page', (tester) async {
      final changes = <Color>[];
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: Column(children: [
              ColorWheel(color: const Color(0xFFFF0000), diameter: _diameter, onChanged: changes.add),
              const SizedBox(height: 2000),
            ]),
          ),
        ),
      ));
      final start = tester.getTopLeft(find.byType(ColorWheel)) + const Offset(ColorWheel.margin + _diameter / 2, ColorWheel.margin + 30);
      await tester.dragFrom(start, const Offset(0, 120));
      await tester.pump();
      expect(scroll.offset, 0);
      expect(changes, isNotEmpty);
    });

    testWidgets('the brightness slider sets the value and keeps hue and saturation', (tester) async {
      final log = await _pump(tester, const Color(0xFF1677FF));
      final before = _hsv(const Color(0xFF1677FF));
      final slider = find.byType(Slider);
      await tester.tapAt(tester.getCenter(slider));
      await tester.pump();
      final mid = _hsv(log.changes.last);
      expect(mid.value, closeTo(0.5, 0.05));
      expect(mid.hue, closeTo(before.hue, 1));
      expect(mid.saturation, closeTo(before.saturation, 0.02));
      // All the way down is black; the thumb keeps its hue and saturation.
      await tester.drag(slider, const Offset(-600, 0));
      await tester.pump();
      expect(log.changes.last.toARGB32(), 0xFF000000);
      await tester.drag(slider, const Offset(600, 0));
      await tester.pump();
      final back = _hsv(log.changes.last);
      expect(back.value, 1);
      expect(back.hue, closeTo(before.hue, 1));
      expect(back.saturation, closeTo(before.saturation, 0.02));
    });

    testWidgets('a grey set from outside keeps the hue the wheel had', (tester) async {
      final log = await _pump(tester, const Color(0xFF00C853));
      final hue = _hsv(const Color(0xFF00C853)).hue;
      tester.state<_HostState>(find.byType(_Host)).set(const Color(0xFF808080));
      await tester.pump();
      // Saturation up: the color comes back with the old hue, not red.
      await tester.tapAt(_center(tester) + colorWheelOffset(hue, 0.9, _diameter / 2));
      await tester.pump();
      expect(_hsv(log.changes.last).hue, closeTo(hue, 1.5));
    });

    testWidgets('keyboard: arrows turn the hue and change the saturation, and back again', (tester) async {
      const start = Color(0xFF7D00FF);
      final log = await _pump(tester, start);
      await tester.tapAt(_center(tester) + colorWheelOffset(_hsv(start).hue, _hsv(start).saturation, _diameter / 2));
      await tester.pump();
      log.changes.clear();
      final focused = log.ends.length;

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_hsv(log.changes.last).hue, closeTo(_hsv(start).hue + 2, 1.5));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_hsv(log.changes.last).saturation, closeTo(_hsv(start).saturation - 0.02, 0.02));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      final end = log.changes.last;
      for (final (a, b) in [(end.r, start.r), (end.g, start.g), (end.b, start.b)]) {
        expect(a, closeTo(b, 2 / 255), reason: 'right, left, down, up: where it started');
      }
      expect(log.ends.length - focused, 4, reason: 'every key press is a finished change');
    });

    testWidgets('screen readers: a labelled slider that adjusts the hue, with saturation actions', (tester) async {
      final handle = tester.ensureSemantics();
      final log = await _pump(tester, const Color(0xFFFF0000));
      final data = tester.getSemantics(find.bySemanticsLabel('Hue and saturation')).getSemanticsData();
      expect(data.value, 'hue 0 degrees, saturation 100%');
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      expect(data.hasAction(SemanticsAction.decrease), isTrue);
      expect(data.hasAction(SemanticsAction.customAction), isTrue, reason: 'More and Less saturated');
      tester.semantics.performAction(find.semantics.byLabel('Hue and saturation'), SemanticsAction.increase);
      await tester.pump();
      expect(_hsv(log.changes.last).hue, closeTo(5, 0.5));
      expect(find.bySemanticsLabel(RegExp('Brightness')), findsOneWidget);
      handle.dispose();
    });
  });

  group('custom accent dialog', () {
    Future<void> open(WidgetTester tester, {int? initial, Size size = const Size(1280, 900)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(body: CustomAccentDialog(initial: initial)),
      ));
    }

    String hexText(WidgetTester tester) => tester.widget<TextField>(find.widgetWithText(TextField, 'Hex color')).controller!.text;
    Color wheelColor(WidgetTester tester) => tester.widget<ColorWheel>(find.byType(ColorWheel)).color;

    for (final size in const [Size(1280, 900), Size(390, 844)]) {
      testWidgets('the wheel and the hex field stay in sync (${size.width.toInt()} wide)', (tester) async {
        await open(tester, initial: 0xFF7D00FF, size: size);
        expect(wheelColor(tester), const Color(0xFF7D00FF));

        // Hex field -> wheel.
        await tester.enterText(find.widgetWithText(TextField, 'Hex color'), '#0F9F6E');
        await tester.pump();
        expect(wheelColor(tester), const Color(0xFF0F9F6E));

        // Wheel -> hex field and preview: due right on the wheel is red.
        await tester.ensureVisible(find.byType(ColorWheel));
        await tester.pump();
        final wheel = tester.getTopLeft(find.byType(ColorWheel));
        final radius = tester.widget<ColorWheel>(find.byType(ColorWheel)).diameter / 2;
        await tester.tapAt(wheel + Offset(ColorWheel.margin + radius * 2 - 1, ColorWheel.margin + radius));
        await tester.pump();
        final picked = parseHexColor(hexText(tester))!;
        expect(Color(picked), wheelColor(tester));
        expect(_hsv(Color(picked)).hue, closeTo(0, 2));
        expect(find.text('Button'), findsOneWidget, reason: 'the live preview follows the wheel');

        // A swatch -> both.
        await tester.tap(find.byTooltip('#1677FF'));
        await tester.pump();
        expect(hexText(tester), '#1677FF');
        expect(wheelColor(tester), const Color(0xFF1677FF));
      });
    }

    testWidgets('the readability adjustment still applies to a wheel color', (tester) async {
      await open(tester);
      expect(find.text('Button'), findsNothing, reason: 'no preview before a color is chosen');
      // A pale yellow from the wheel: near the center, at full brightness.
      final wheel = tester.getTopLeft(find.byType(ColorWheel));
      final radius = tester.widget<ColorWheel>(find.byType(ColorWheel)).diameter / 2;
      final center = wheel + Offset(ColorWheel.margin + radius, ColorWheel.margin + radius);
      await tester.tapAt(center + colorWheelOffset(60, 0.6, radius));
      await tester.pump();
      final picked = parseHexColor(hexText(tester))!;
      final button = tester.widget<Container>(find.ancestor(of: find.text('Button'), matching: find.byType(Container)).first);
      final fill = (button.decoration! as BoxDecoration).color!;
      expect(fill, accentShadesOf(Color(picked)).light);
      expect(contrastRatio(Colors.white, fill), greaterThanOrEqualTo(4.5));
      expect(find.text('Adjusted a little so text on it and beside it stays readable.'), findsOneWidget);
    });

    testWidgets('the dialog meets the tap target and label guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, initial: 0xFF7D00FF);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });
}
