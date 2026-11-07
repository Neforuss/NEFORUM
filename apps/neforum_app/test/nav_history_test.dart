// NavHistory, NavModalWatch and NavMouseButtons against go_router, with the
// route shape of lib/ui/router.dart and real mouse gestures. The real screens
// are in nav_history_app_test.dart; the compiled build with real Windows
// messages in integration_test/back_forward_test.dart.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_app/state/nav_history.dart';
import 'package:neforum_app/ui/shell/nav_input.dart';
import 'package:neforum_core/neforum_core.dart' show LogLevel, Logger;

final _rootKey = GlobalKey<NavigatorState>();

GoRouter _router(NavModalWatch watch) => GoRouter(
      navigatorKey: _rootKey,
      initialLocation: '/compose',
      observers: [watch],
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (c, s, shell) => Scaffold(body: shell),
          branches: [
            StatefulShellBranch(routes: [
              GoRoute(path: '/compose', pageBuilder: (c, s) => const NoTransitionPage(child: Text('compose'))),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(path: '/queue', pageBuilder: (c, s) => const NoTransitionPage(child: Text('queue'))),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/activity',
                pageBuilder: (c, s) => const NoTransitionPage(child: Text('activity')),
                routes: [GoRoute(path: 'post/:id', builder: (c, s) => Text('post ${s.pathParameters['id']}'))],
              ),
            ]),
          ],
        ),
      ],
    );

class _Rig {
  _Rig(this.router, this.history);
  final GoRouter router;
  final NavHistory history;
  String get location => router.routerDelegate.currentConfiguration.uri.toString();
  List<String> get entries => history.entries;
}

Future<_Rig> _start(WidgetTester t, {Logger? log}) async {
  final watch = NavModalWatch();
  final router = _router(watch);
  addTearDown(router.dispose);
  final history = NavHistory(router, watch, log: log);
  addTearDown(history.dispose);
  await t.pumpWidget(MaterialApp.router(
    routerConfig: router,
    builder: (c, child) => NavKeyboardShortcuts(enabled: true, history: history, child: NavMouseButtons(enabled: true, history: history, child: child!)),
  ));
  await t.pumpAndSettle();
  return _Rig(router, history);
}

Future<void> _click(WidgetTester t, int button) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse, buttons: button);
  await g.down(const Offset(400, 300));
  await g.up();
  await g.removePointer();
  await t.pumpAndSettle();
}

Future<void> _visit(WidgetTester t, _Rig r, String location) async {
  r.router.go(location);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('walks sections and a detail page, both ways', (t) async {
    final r = await _start(t);
    await _visit(t, r, '/queue');
    await _visit(t, r, '/activity');
    await _visit(t, r, '/activity/post/1');
    expect(r.entries, ['/compose', '/queue', '/activity', '/activity/post/1']);

    await _click(t, kBackMouseButton);
    expect(r.location, '/activity');
    await _click(t, kBackMouseButton);
    expect(r.location, '/queue');
    await _click(t, kForwardMouseButton);
    expect(r.location, '/activity');
    await _click(t, kForwardMouseButton);
    expect(r.location, '/activity/post/1');
    await _click(t, kForwardMouseButton);
    expect(r.location, '/activity/post/1', reason: 'nothing further');
    expect(r.entries.length, 4, reason: 'a replay records nothing');
  });

  testWidgets('the empty location before the first route is not an entry', (t) async {
    final watch = NavModalWatch();
    final router = _router(watch);
    addTearDown(router.dispose);
    final history = NavHistory(router, watch);
    addTearDown(history.dispose);
    expect(history.entries, isEmpty, reason: 'no route has been parsed yet');
    await t.pumpWidget(MaterialApp.router(routerConfig: router));
    await t.pumpAndSettle();
    expect(history.entries, ['/compose']);
    expect(history.canBack, isFalse);
    expect(history.canForward, isFalse);
  });

  testWidgets('a new page after going back drops the forward part', (t) async {
    final r = await _start(t);
    await _visit(t, r, '/queue');
    await _visit(t, r, '/activity');
    await _click(t, kBackMouseButton);
    await _click(t, kBackMouseButton);
    expect(r.history.canForward, isTrue);
    await _visit(t, r, '/queue');
    expect(r.entries, ['/compose', '/queue']);
    expect(r.history.canForward, isFalse);
  });

  testWidgets('keeps the last 50 pages', (t) async {
    final r = await _start(t);
    for (var i = 0; i < 60; i++) {
      await _visit(t, r, '/activity/post/$i');
    }
    expect(r.entries.length, NavHistory.capacity);
    expect(NavHistory.capacity, 50);
    expect(r.entries.first, '/activity/post/10');
    expect(r.entries.last, '/activity/post/59');
    expect(r.history.index, 49);
    await _click(t, kBackMouseButton);
    expect(r.location, '/activity/post/58');
    for (var i = 0; i < 60; i++) {
      await r.history.back();
    }
    await t.pumpAndSettle();
    expect(r.location, '/activity/post/10', reason: 'the oldest kept page');
    expect(r.history.canBack, isFalse);
  });

  testWidgets('two quick steps with no frame between them land where they should', (t) async {
    final r = await _start(t);
    await _visit(t, r, '/queue');
    await _visit(t, r, '/activity');
    await r.history.back();
    await r.history.back();
    await t.pumpAndSettle();
    expect(r.location, '/compose');
    expect(r.entries, ['/compose', '/queue', '/activity'], reason: 'neither step is a new page');
    expect(r.history.index, 0);
    r.history.forward();
    await r.history.back();
    r.history.forward();
    await t.pumpAndSettle();
    expect(r.location, '/queue');
    expect(r.entries.length, 3);
  });

  testWidgets('a compose command is recorded as plain /compose', (t) async {
    final r = await _start(t);
    await _visit(t, r, '/queue');
    await _visit(t, r, '/compose?post=X');
    expect(r.entries, ['/compose', '/queue', '/compose']);
    await _visit(t, r, '/queue');
    await _click(t, kBackMouseButton);
    expect(r.location, '/compose', reason: 'never the location that loads the post');
  });

  testWidgets('replaceNext takes the place of the current page', (t) async {
    final r = await _start(t);
    await _visit(t, r, '/queue');
    await _visit(t, r, '/activity');
    await _click(t, kBackMouseButton);
    r.history.replaceNext();
    await _visit(t, r, '/activity/post/1');
    expect(r.entries, ['/compose', '/activity/post/1']);
    expect(r.history.index, 1);
    await _visit(t, r, '/queue');
    expect(r.entries, ['/compose', '/activity/post/1', '/queue'], reason: 'only one location is replaced');
  });

  testWidgets('stepBackTo is Back when that is the page before, otherwise a new page', (t) async {
    final r = await _start(t);
    await _visit(t, r, '/activity');
    await _visit(t, r, '/activity/post/1');
    r.history.stepBackTo('/activity');
    await t.pumpAndSettle();
    expect(r.location, '/activity');
    expect(r.entries, ['/compose', '/activity', '/activity/post/1'], reason: 'the page left stays one Forward away');
    expect(r.history.canForward, isTrue);

    r.history.stepBackTo('/queue');
    await t.pumpAndSettle();
    expect(r.entries, ['/compose', '/activity', '/queue']);
  });

  testWidgets('listeners hear about every change the buttons depend on', (t) async {
    final r = await _start(t);
    var heard = 0;
    r.history.addListener(() => heard++);
    await _visit(t, r, '/queue');
    expect(heard, greaterThan(0));
    heard = 0;
    await r.history.back();
    await t.pumpAndSettle();
    expect(heard, greaterThan(0));
    expect(r.history.canBack, isFalse);
    expect(r.history.canForward, isTrue);
  });

  testWidgets('each step leaves one debug line with no more than the two locations', (t) async {
    final lines = <String>[];
    final r = await _start(t, log: Logger('nav', sink: (level, area, message, [error]) {
      if (level == LogLevel.debug) lines.add(message);
    }));
    await _visit(t, r, '/queue');
    await _click(t, kBackMouseButton);
    await _click(t, kForwardMouseButton);
    expect(lines, ['nav back /queue -> /compose', 'nav forward /compose -> /queue']);
  });

  group('mouse buttons', () {
    testWidgets('left held, then back: the bit arrives on a move, and one press is one step', (t) async {
      final r = await _start(t);
      await _visit(t, r, '/queue');
      await _visit(t, r, '/activity');
      final g = await t.createGesture(pointer: 77, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      await g.down(const Offset(400, 300));
      await t.pump();
      Future<void> move(int buttons) async {
        await g.updateWithCustomEvent(PointerMoveEvent(pointer: 77, kind: PointerDeviceKind.mouse, position: const Offset(400, 300), buttons: buttons));
        await t.pumpAndSettle();
      }

      await move(kPrimaryMouseButton | kBackMouseButton);
      expect(r.location, '/queue');
      await move(kPrimaryMouseButton | kBackMouseButton);
      expect(r.location, '/queue', reason: 'still held: no second step');
      await move(kPrimaryMouseButton);
      expect(r.location, '/queue', reason: 'the release is not a step');
      await g.up();
      await t.pumpAndSettle();
      expect(r.location, '/queue');
    });

    testWidgets('Forward pressed while Back is still held is one step only, and the next press works', (t) async {
      final r = await _start(t);
      await _visit(t, r, '/queue');
      final g = await t.createGesture(pointer: 78, kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
      await g.down(const Offset(400, 300));
      await t.pumpAndSettle();
      expect(r.location, '/compose');
      await g.updateWithCustomEvent(const PointerMoveEvent(pointer: 78, kind: PointerDeviceKind.mouse, position: Offset(400, 300), buttons: kBackMouseButton | kForwardMouseButton));
      await t.pumpAndSettle();
      expect(r.location, '/compose', reason: 'the side button press ended at the first button');
      await g.up();
      await g.removePointer();
      await t.pumpAndSettle();
      await _click(t, kForwardMouseButton);
      expect(r.location, '/queue');
    });

    testWidgets('a touch carrying the same bits is not the mouse', (t) async {
      final r = await _start(t);
      await _visit(t, r, '/queue');
      final g = await t.createGesture(kind: PointerDeviceKind.touch, buttons: kBackMouseButton);
      await g.down(const Offset(400, 300));
      await g.up();
      await t.pumpAndSettle();
      expect(r.location, '/queue');
    });

    testWidgets('a release the window never heard about does not eat the next press', (t) async {
      final r = await _start(t);
      await _visit(t, r, '/queue');
      await _visit(t, r, '/activity');
      final g = await t.createGesture(pointer: 79, kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
      await g.down(const Offset(400, 300));
      await t.pumpAndSettle();
      expect(r.location, '/queue');
      await g.cancel();
      await g.removePointer();
      await t.pumpAndSettle();
      await _click(t, kBackMouseButton);
      expect(r.location, '/compose');
    });

    testWidgets('off: side buttons do nothing', (t) async {
      final watch = NavModalWatch();
      final router = _router(watch);
      addTearDown(router.dispose);
      final history = NavHistory(router, watch);
      addTearDown(history.dispose);
      await t.pumpWidget(MaterialApp.router(
        routerConfig: router,
        builder: (c, child) => NavMouseButtons(enabled: false, history: history, child: child!),
      ));
      await t.pumpAndSettle();
      router.go('/queue');
      await t.pumpAndSettle();
      await _click(t, kBackMouseButton);
      expect(router.routerDelegate.currentConfiguration.uri.toString(), '/queue');
    });
  });

  group('popups', () {
    testWidgets('a dismissible dialog closes first, and the page stays', (t) async {
      final r = await _start(t);
      await _visit(t, r, '/queue');
      showDialog<void>(context: _rootKey.currentContext!, builder: (_) => const AlertDialog(content: Text('plain')));
      await t.pumpAndSettle();
      await _click(t, kBackMouseButton);
      expect(find.text('plain'), findsNothing);
      expect(r.location, '/queue');
      await _click(t, kBackMouseButton);
      expect(r.location, '/compose', reason: 'with it gone, Back walks again');
    });

    testWidgets('a locked dialog stays, and a dismissal is not faked', (t) async {
      final r = await _start(t);
      await _visit(t, r, '/queue');
      final done = showDialog<void>(context: _rootKey.currentContext!, barrierDismissible: false, builder: (_) => const AlertDialog(content: Text('locked')));
      await t.pumpAndSettle();
      await _click(t, kBackMouseButton);
      await _click(t, kForwardMouseButton);
      expect(find.text('locked'), findsOneWidget);
      expect(r.location, '/queue');
      _rootKey.currentState!.pop();
      await done;
    });

    testWidgets('a locked sheet stays', (t) async {
      final r = await _start(t);
      await _visit(t, r, '/queue');
      final sheet = showModalBottomSheet<void>(context: t.element(find.text('queue')), isDismissible: false, enableDrag: false, builder: (_) => const Text('locked sheet'));
      await t.pumpAndSettle();
      await _click(t, kBackMouseButton);
      expect(find.text('locked sheet'), findsOneWidget);
      expect(r.location, '/queue');
      Navigator.of(t.element(find.text('locked sheet'))).pop();
      await sheet;
    });

    testWidgets('Forward does nothing while a popup is open, and never reopens one', (t) async {
      final r = await _start(t);
      await _visit(t, r, '/queue');
      await _click(t, kBackMouseButton);
      expect(r.history.canForward, isTrue);
      showDialog<void>(context: _rootKey.currentContext!, builder: (_) => const AlertDialog(content: Text('open')));
      await t.pumpAndSettle();
      await _click(t, kForwardMouseButton);
      expect(find.text('open'), findsOneWidget);
      expect(r.location, '/compose');
      await _click(t, kBackMouseButton);
      expect(find.text('open'), findsNothing);
      await _click(t, kForwardMouseButton);
      expect(find.text('open'), findsNothing, reason: 'a popup is not a page');
      expect(r.location, '/queue');
      expect(r.entries, ['/compose', '/queue']);
    });

    // Found by the compiled test: a barrier takes any button as a tap, and
    // a real click lands on the barrier more often than on the dialog.
    Future<void> clickOnBarrier(WidgetTester t, int button) async {
      final g = await t.createGesture(kind: PointerDeviceKind.mouse, buttons: button);
      await g.down(const Offset(5, 5));
      await g.up();
      await g.removePointer();
      await t.pumpAndSettle();
    }

    testWidgets('Forward on the barrier does not close the dialog', (t) async {
      final r = await _start(t);
      await _visit(t, r, '/queue');
      await _click(t, kBackMouseButton);
      showDialog<void>(context: _rootKey.currentContext!, builder: (_) => const AlertDialog(content: Text('open')));
      await t.pumpAndSettle();
      await clickOnBarrier(t, kForwardMouseButton);
      expect(find.text('open'), findsOneWidget);
      expect(r.location, '/compose');
      await clickOnBarrier(t, kPrimaryMouseButton);
      expect(find.text('open'), findsNothing, reason: 'a real click on the barrier still closes it');
    });

    testWidgets('Back on the barrier closes one popup, not two', (t) async {
      final r = await _start(t);
      final page = t.element(find.text('compose'));
      showModalBottomSheet<void>(context: page, builder: (_) => const Text('sheet'));
      await t.pumpAndSettle();
      showDialog<void>(context: page, builder: (_) => const AlertDialog(content: Text('dialog')));
      await t.pumpAndSettle();
      await clickOnBarrier(t, kBackMouseButton);
      expect(find.text('dialog'), findsNothing);
      expect(find.text('sheet'), findsOneWidget);
      expect(r.location, '/compose');
    });

    testWidgets('a side button pressed on a button does not press it, and left held keeps its press', (t) async {
      var presses = 0, ups = 0, cancels = 0;
      final watch = NavModalWatch();
      final router = GoRouter(
        navigatorKey: _rootKey,
        initialLocation: '/a',
        observers: [watch],
        routes: [
          GoRoute(
            path: '/a',
            builder: (c, s) => Center(
              child: Listener(
                onPointerUp: (_) => ups++,
                onPointerCancel: (_) => cancels++,
                child: TextButton(onPressed: () => presses++, child: const Text('press')),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      final history = NavHistory(router, watch);
      addTearDown(history.dispose);
      await t.pumpWidget(MaterialApp.router(routerConfig: router, builder: (c, child) => NavMouseButtons(enabled: true, history: history, child: child!)));
      await t.pumpAndSettle();
      final at = t.getCenter(find.text('press'));
      final side = await t.createGesture(kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
      await side.down(at);
      await side.up();
      await side.removePointer();
      await t.pumpAndSettle();
      expect(presses, 0);
      expect(cancels, 1, reason: 'the side button press stops there');
      ups = cancels = 0;

      // Left down on the button, the side button pressed and released, left up.
      final left = await t.createGesture(pointer: 80, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      await left.down(at);
      await t.pump();
      await left.updateWithCustomEvent(PointerMoveEvent(pointer: 80, kind: PointerDeviceKind.mouse, position: at, buttons: kPrimaryMouseButton | kBackMouseButton));
      await left.updateWithCustomEvent(PointerMoveEvent(pointer: 80, kind: PointerDeviceKind.mouse, position: at, buttons: kPrimaryMouseButton));
      await left.up();
      await left.removePointer();
      await t.pumpAndSettle();
      expect(cancels, 0, reason: 'the left press under way is not cancelled');
      expect(ups, 1);
    });

    testWidgets('a sheet on a section navigator and a menu are seen too', (t) async {
      final r = await _start(t);
      showModalBottomSheet<void>(context: t.element(find.text('compose')), builder: (_) => const Text('sheet'));
      await t.pumpAndSettle();
      await _click(t, kBackMouseButton);
      expect(find.text('sheet'), findsNothing);

      showMenu<void>(context: t.element(find.text('compose')), position: const RelativeRect.fromLTRB(10, 10, 10, 10), items: const [PopupMenuItem(child: Text('item'))]);
      await t.pumpAndSettle();
      await _click(t, kBackMouseButton);
      expect(find.text('item'), findsNothing);
      expect(r.location, '/compose');
    });

    testWidgets('a dialog on the root covers a sheet opened after it: the dialog goes first', (t) async {
      final r = await _start(t);
      final page = t.element(find.text('compose'));
      showDialog<void>(context: page, builder: (_) => const AlertDialog(content: Text('dialog')));
      await t.pumpAndSettle();
      showModalBottomSheet<void>(context: page, builder: (_) => const Text('sheet'));
      await t.pumpAndSettle();
      await r.history.back();
      await t.pumpAndSettle();
      expect(find.text('dialog'), findsNothing);
      expect(find.text('sheet', skipOffstage: false), findsOneWidget);
      await r.history.back();
      await t.pumpAndSettle();
      expect(find.text('sheet', skipOffstage: false), findsNothing);
    });

    testWidgets('a sheet left open on a hidden section blocks nothing, and is there on return', (t) async {
      final r = await _start(t);
      showModalBottomSheet<void>(context: t.element(find.text('compose')), builder: (_) => const Text('sheet'));
      await t.pumpAndSettle();
      await _visit(t, r, '/queue');
      expect(find.text('sheet'), findsNothing, reason: 'hidden with its section');
      await _visit(t, r, '/activity');

      await _click(t, kBackMouseButton);
      expect(r.location, '/queue', reason: 'Back walks: the sheet is not on screen');
      await _click(t, kForwardMouseButton);
      expect(r.location, '/activity', reason: 'Forward walks too');
      await _click(t, kBackMouseButton);
      await _click(t, kBackMouseButton);
      expect(r.location, '/compose');
      expect(find.text('sheet'), findsOneWidget);
      await _click(t, kBackMouseButton);
      expect(find.text('sheet'), findsNothing, reason: 'on screen again, it closes first');
      expect(r.location, '/compose');
    });

    testWidgets('a popup whose navigator went away does not block Back for ever', (t) async {
      final watch = NavModalWatch();
      final showNavigator = ValueNotifier(true);
      addTearDown(showNavigator.dispose);
      await t.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: showNavigator,
          builder: (c, on, _) => on
              ? Navigator(observers: [watch], onGenerateRoute: (s) => MaterialPageRoute<void>(builder: (_) => const Text('page')))
              : const SizedBox.shrink(),
        ),
      ));
      showDialog<void>(context: t.element(find.text('page')), useRootNavigator: false, builder: (_) => const AlertDialog(content: Text('d')));
      await t.pumpAndSettle();
      expect(watch.top, isNotNull);
      showNavigator.value = false;
      await t.pumpAndSettle();
      expect(watch.top, isNull);
    });
  });
}
