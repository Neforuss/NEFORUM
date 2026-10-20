import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/zoom.dart';
import 'package:neforum_app/ui/ui_zoom.dart';

/// A MaterialApp zoomed like NEFORUM's, with the zoom kept in [zoom].
class _Harness extends StatefulWidget {
  const _Harness({required this.home, this.initial = 1});
  final Widget home;
  final double initial;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late double zoom = widget.initial;
  final changes = <double>[];

  /// A change made elsewhere (Settings).
  void setZoom(double z) => setState(() => zoom = z);

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: widget.home,
        builder: (context, child) => UiZoom(
          zoom: zoom,
          onChanged: (z) => setState(() {
            zoom = z;
            changes.add(z);
          }),
          child: child!,
        ),
      );
}

_HarnessState _state(WidgetTester tester) => tester.state<_HarnessState>(find.byType(_Harness));

/// A mouse wheel turn as the engine sends it, through the same entry point.
void _wheel(WidgetTester tester, Offset at, double dy, Duration time) {
  final dpr = tester.view.devicePixelRatio;
  tester.binding.platformDispatcher.onPointerDataPacket!(ui.PointerDataPacket(data: [
    ui.PointerData(
      viewId: tester.view.viewId,
      timeStamp: time,
      change: ui.PointerChange.hover,
      kind: PointerDeviceKind.mouse,
      signalKind: ui.PointerSignalKind.scroll,
      device: 7,
      physicalX: at.dx * dpr,
      physicalY: at.dy * dpr,
      scrollDeltaY: dy * dpr,
    ),
  ]));
}

void main() {
  group('steps', () {
    test('go like a browser and stop at the ends', () {
      expect(zoomIn(1), 1.1);
      expect(zoomOut(1), 0.9);
      expect(zoomIn(1.05), 1.1);
      expect(zoomOut(1.05), 1.0);
      expect(zoomIn(3), 3);
      expect(zoomOut(0.5), 0.5);
      expect(zoomLabel(0.67), '67%');
      expect(zoomLabel(1.25), '125%');
    });

    test('a stored zoom is kept within range', () {
      expect(validZoom(null), 1);
      expect(validZoom('2'), 1);
      expect(validZoom(double.nan), 1);
      expect(validZoom(9), 3);
      expect(validZoom(0.1), 0.5);
      expect(validZoom(1.5), 1.5);
    });
  });

  group('setting', () {
    test('is saved, read back and stays on this device', () {
      expect(const AppSettings().toJson().containsKey('uiZoom'), isFalse);
      final s = const AppSettings().copyWith(uiZoom: 1.25);
      expect(s.toJson()['uiZoom'], 1.25);
      expect(AppSettings.fromJson(s.toJson()).uiZoom, 1.25);
      expect(AppSettings.fromJson({'uiZoom': 40}).uiZoom, 3);
      expect(exportableSettings(s).containsKey('uiZoom'), isFalse);
      expect(withImportedSettings(const AppSettings(), {'uiZoom': 2}).uiZoom, 1);
    });

    test('quick saves of one file do not trip over each other', () async {
      final dir = await Directory.systemTemp.createTemp('neforum-zoom');
      addTearDown(() => dir.delete(recursive: true));
      final storage = await openAppStorage(overrideDir: dir.path);
      await Future.wait([for (var i = 0; i < 25; i++) storage.writeJson('settings.json', {'i': i})]);
      expect((await storage.readJson('settings.json'))!['i'], 24);
    });
  });

  group('drawing', () {
    testWidgets('lays out in a smaller window drawn bigger, and clicks land on what is drawn', (tester) async {
      late Size seen;
      late double zoomSeen;
      var presses = 0;
      await tester.pumpWidget(_Harness(
        initial: 2,
        home: Builder(builder: (context) {
          seen = MediaQuery.sizeOf(context);
          zoomSeen = ZoomScope.of(context);
          return Stack(children: [
            Positioned(left: 50, top: 50, width: 40, height: 40, child: ElevatedButton(key: const Key('b'), onPressed: () => presses++, child: null)),
          ]);
        }),
      ));
      final dpr = tester.view.devicePixelRatio;
      expect(seen, const Size(400, 300));
      expect(zoomSeen, 2);
      expect(tester.binding.renderViews.single.configuration.devicePixelRatio, dpr * 2);
      expect(tester.binding.renderViews.single.size, const Size(400, 300));

      // A click from the engine at window pixel (140, 140): the button is
      // drawn from 100 to 180 there.
      void send(ui.PointerChange change) => tester.binding.platformDispatcher.onPointerDataPacket!(ui.PointerDataPacket(data: [
            ui.PointerData(
              viewId: tester.view.viewId,
              change: change,
              kind: PointerDeviceKind.mouse,
              device: 3,
              buttons: change == ui.PointerChange.up ? 0 : kPrimaryMouseButton,
              physicalX: 140 * dpr,
              physicalY: 140 * dpr,
            ),
          ]));
      send(ui.PointerChange.add);
      send(ui.PointerChange.down);
      send(ui.PointerChange.up);
      send(ui.PointerChange.remove);
      await tester.pumpAndSettle();
      expect(presses, 1);

      // Back to 100% when it goes away.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.binding.renderViews.single.configuration.devicePixelRatio, dpr);
      expect(tester.binding.renderViews.single.size, const Size(800, 600));
    });

    testWidgets('changing it keeps the page and its state', (tester) async {
      await tester.pumpWidget(const _Harness(home: Scaffold(body: TextField())));
      await tester.enterText(find.byType(TextField), 'kept');
      final element = tester.element(find.byType(TextField));
      _state(tester).setZoom(1.5);
      await tester.pump();
      expect(tester.element(find.byType(TextField)), same(element));
      expect(find.text('kept'), findsOneWidget);
      expect(find.text('150%'), findsOneWidget);
      expect(_state(tester).changes, isEmpty);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('the hover moves to what is under the mouse after zooming', (tester) async {
      final entered = <int>[];
      await tester.pumpWidget(_Harness(
        home: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < 5; i++) MouseRegion(onEnter: (_) => entered.add(i), child: const SizedBox(height: 50)),
        ]),
      ));
      final dpr = tester.view.devicePixelRatio;
      void send(ui.PointerChange change) => tester.binding.platformDispatcher.onPointerDataPacket!(ui.PointerDataPacket(data: [
            ui.PointerData(viewId: tester.view.viewId, change: change, kind: PointerDeviceKind.mouse, device: 5, physicalX: 300 * dpr, physicalY: 175 * dpr),
          ]));
      send(ui.PointerChange.add);
      send(ui.PointerChange.hover);
      await tester.pump();
      expect(entered.last, 3);
      // At 200% the mouse, still at window pixel 175, is over the second row.
      _state(tester).setZoom(2);
      await tester.pump();
      await tester.pump();
      expect(entered.last, 1);
      send(ui.PointerChange.remove);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('menus open next to their button', (tester) async {
      await tester.pumpWidget(_Harness(
        initial: 2,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: PopupMenuButton<int>(
                key: const Key('menu'),
                itemBuilder: (_) => const [PopupMenuItem(value: 1, child: Text('First item'))],
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('menu')));
      await tester.pumpAndSettle();
      final button = tester.getRect(find.byKey(const Key('menu')));
      final item = tester.getRect(find.text('First item'));
      expect((item.topLeft - button.topLeft).distance, lessThan(160));
    });

    testWidgets('a text field\'s right-click menu opens where the click was', (tester) async {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      await tester.pumpWidget(_Harness(
        initial: 2,
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.only(left: 60, top: 40, right: 60), child: TextField(controller: controller)),
        ),
      ));
      final at = tester.getCenter(find.byType(TextField));
      final gesture = await tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await gesture.up();
      await gesture.removePointer();
      await tester.pumpAndSettle();
      final selectAll = find.text('Select all');
      expect(selectAll, findsOneWidget);
      expect((tester.getTopLeft(selectAll) - at).distance, lessThan(160));
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  group('shortcuts', () {
    testWidgets('Ctrl + / Ctrl − / Ctrl 0', (tester) async {
      await tester.pumpWidget(const _Harness(home: Scaffold(body: TextField(autofocus: true))));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
      await tester.pump();
      expect(_state(tester).zoom, 1.25);
      expect(find.text('125%'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.minus);
      await tester.pump();
      expect(_state(tester).zoom, 1.1);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.pump();
      expect(_state(tester).zoom, 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      // Without Ctrl the keys type as usual.
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();
      expect(_state(tester).zoom, 1);
      expect(_state(tester).changes, [1.1, 1.25, 1.1, 1.0]);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('Ctrl + mouse wheel zooms without scrolling; the wheel alone scrolls', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(_Harness(
        home: Scaffold(body: ListView(controller: scroll, children: [for (var i = 0; i < 100; i++) SizedBox(height: 50, child: Text('row $i'))])),
      ));
      const at = Offset(200, 200);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      _wheel(tester, at, -50, const Duration(seconds: 1));
      // A smooth wheel's next small turn right after: still one step.
      _wheel(tester, at, -10, const Duration(seconds: 1, milliseconds: 20));
      await tester.pump();
      expect(_state(tester).zoom, 1.1);
      expect(scroll.offset, 0);
      _wheel(tester, at, -50, const Duration(seconds: 2));
      await tester.pump();
      expect(_state(tester).zoom, 1.25);
      _wheel(tester, at, 50, const Duration(seconds: 2, milliseconds: 10));
      await tester.pump();
      expect(_state(tester).zoom, 1.1);
      expect(scroll.offset, 0);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      _wheel(tester, at, 50, const Duration(seconds: 3));
      await tester.pump();
      expect(scroll.offset, greaterThan(0));
      expect(_state(tester).zoom, 1.1);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('off: no zoom, no shortcuts', (tester) async {
      late Size seen;
      final changes = <double>[];
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          seen = MediaQuery.sizeOf(context);
          return const SizedBox();
        }),
        builder: (context, child) => UiZoom(enabled: false, zoom: 2, onChanged: changes.add, child: child!),
      ));
      expect(seen, const Size(800, 600));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(changes, isEmpty);
    });
  });
}
