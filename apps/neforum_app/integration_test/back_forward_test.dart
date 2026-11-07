// The mouse's side buttons on a compiled build, through the real engine, in a
// throwaway demo workspace. Debug tests missed an AOT-only crash before, and a
// widget test cannot show the engine delivers the buttons at all:
//
//   flutter drive --profile -d windows --driver=test_driver/integration_test.dart --target=integration_test/back_forward_test.dart
//
// Windows has two lanes, each at zoom 1.0, 1.5 and 0.5:
//
// * Posted: PostMessage to this process's own view. Needs no cursor or
//   foreground, so it always runs.
// * SendInput: the real input path. It is only ever sent when WindowFromPoint
//   says the cursor is over this process's own view, checked before every
//   click; the cursor is never moved. If that cannot be proved the click is not
//   sent and the run prints SKIPPED with the reason.
//
// Windows are found by process id, never by title: a NEFORUM the user has
// running has the same window class and title.
//
// Linux has one lane, `xdotool click 8` and `9`. It runs only with
// NEFORUM_XDOTOOL_LANE=1, which CI sets on its private Xvfb display, where this
// is the only window: on a real desktop a click goes wherever the mouse is.
//
// Locally, the runner's single-instance mutex stops this from starting while a
// NEFORUM is open: in a copy of the repo, under a short path, rename it in
// windows/runner/main.cpp to L"Local\\org.neforum.NEFORUM.integration" first.

// Run output is the evidence, so it prints. Fields, never objects: profile
// builds minify toString.
// ignore_for_file: avoid_print

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neforum_app/platform/desktop.dart';
import 'package:neforum_app/platform/notifications.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/compose/publish_progress_sheet.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/queue/queue_screen.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/ui/shell/paste_code_dialog.dart';
import 'package:neforum_app/widgets/post_card.dart';

void _note(String line) => print('NAV $line');

// ---------------------------------------------------------------- user32

final _user32 = DynamicLibrary.open('user32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _findWindowEx = _user32.lookupFunction<IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>), int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
final _getWindowThreadProcessId = _user32.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
final _getCurrentProcessId = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
final _postMessage = _user32.lookupFunction<Int32 Function(IntPtr, Uint32, IntPtr, IntPtr), int Function(int, int, int, int)>('PostMessageW');
final _getCursorPos = _user32.lookupFunction<Int32 Function(Pointer<Int32>), int Function(Pointer<Int32>)>('GetCursorPos');
final _setWindowPos = _user32.lookupFunction<Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32), int Function(int, int, int, int, int, int, int)>('SetWindowPos');
final _getWindowRect = _user32.lookupFunction<Int32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>('GetWindowRect');
final _windowFromPoint = _user32.lookupFunction<IntPtr Function(Int64), int Function(int)>('WindowFromPoint');
final _sendInput = _user32.lookupFunction<Uint32 Function(Uint32, Pointer<Uint8>, Int32), int Function(int, Pointer<Uint8>, int)>('SendInput');

const _wmLButtonDown = 0x0201, _wmLButtonUp = 0x0202, _wmXButtonDown = 0x020B, _wmXButtonUp = 0x020C;
const _mkLButton = 0x0001, _mkXButton1 = 0x0020, _mkXButton2 = 0x0040;
const _xButton1 = 1, _xButton2 = 2;
const _hwndTopmost = -1, _hwndNotTopmost = -2;
const _swpNoSize = 0x0001, _swpNoMove = 0x0002, _swpShowWindow = 0x0040;

/// sizeof(INPUT) on x64, with MOUSEINPUT.mouseData at 16 and dwFlags at 20.
const _inputSize = 40;
const _mouseEventXDown = 0x0080, _mouseEventXUp = 0x0100;

int _makeWParam(int low, int high) => (high << 16) | low;
int _makeLParam(int x, int y) => (y << 16) | (x & 0xFFFF);

/// This process's top window and the engine's view in it. By process id: a
/// NEFORUM the user has open has the same class and title.
({int top, int view})? _ownWindow() {
  final runner = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final flutterView = 'FLUTTERVIEW'.toNativeUtf16();
  final pid = calloc<Uint32>();
  try {
    var top = 0;
    while (true) {
      top = _findWindowEx(0, top, runner, nullptr);
      if (top == 0) return null;
      _getWindowThreadProcessId(top, pid);
      if (pid.value != _getCurrentProcessId()) continue;
      final view = _findWindowEx(top, 0, flutterView, nullptr);
      if (view != 0) return (top: top, view: view);
    }
  } finally {
    calloc.free(runner);
    calloc.free(flutterView);
    calloc.free(pid);
  }
}

/// Down and up as one SendInput call: Microsoft says such events "are not
/// interspersed with other keyboard or mouse input events". Returns how many
/// went in. dwExtraInfo stays 0, as the engine tells mouse from touch by it.
int _sendSideButton(int button) {
  final input = calloc<Uint8>(_inputSize * 2);
  void fill(int at, int flags) {
    final words = (input + at).cast<Uint32>();
    (words + 4).value = button;
    (words + 5).value = flags;
  }

  fill(0, _mouseEventXDown);
  fill(_inputSize, _mouseEventXUp);
  final sent = _sendInput(2, input, _inputSize);
  calloc.free(input);
  return sent;
}

// ---------------------------------------------------------------- lanes

/// How a click reaches the engine.
abstract class _Lane {
  String get name;

  /// A side button press and release. False when it could not be sent, with
  /// the reason printed.
  Future<bool> side(int button);

  /// A left click at [x], [y] in the view's physical pixels.
  Future<void> leftClick(int x, int y);
}

class _PostedLane implements _Lane {
  _PostedLane(this.view);
  final int view;

  @override
  String get name => 'posted';

  @override
  Future<bool> side(int button) async {
    final (mk, x) = button == kBackMouseButton ? (_mkXButton1, _xButton1) : (_mkXButton2, _xButton2);
    _postMessage(view, _wmXButtonDown, _makeWParam(mk, x), _makeLParam(4, 4));
    _postMessage(view, _wmXButtonUp, _makeWParam(0, x), _makeLParam(4, 4));
    return true;
  }

  @override
  Future<void> leftClick(int x, int y) async {
    _postMessage(view, _wmLButtonDown, _mkLButton, _makeLParam(x, y));
    _postMessage(view, _wmLButtonUp, 0, _makeLParam(x, y));
  }

  /// Left held, then the back button, as a real hand does: the engine sends
  /// the side button as a move, since a button is already down.
  void leftHeldThenBack() {
    _postMessage(view, _wmLButtonDown, _mkLButton, _makeLParam(4, 4));
    _postMessage(view, _wmXButtonDown, _makeWParam(_mkLButton | _mkXButton1, _xButton1), _makeLParam(4, 4));
    _postMessage(view, _wmXButtonUp, _makeWParam(_mkLButton, _xButton1), _makeLParam(4, 4));
    _postMessage(view, _wmLButtonUp, 0, _makeLParam(4, 4));
  }
}

class _SendInputLane implements _Lane {
  _SendInputLane(this.window);
  final ({int top, int view}) window;
  bool _placed = false;

  @override
  String get name => 'sendinput';

  /// The topmost test window goes where the cursor already is. The cursor
  /// itself is never moved.
  void place() {
    final cursor = calloc<Int32>(2);
    final rect = calloc<Int32>(4);
    _getCursorPos(cursor);
    _getWindowRect(window.top, rect);
    final width = rect[2] - rect[0];
    final height = rect[3] - rect[1];
    _setWindowPos(window.top, _hwndTopmost, cursor[0] - width ~/ 2, cursor[1] - height ~/ 2, 0, 0, _swpNoSize | _swpShowWindow);
    calloc.free(cursor);
    calloc.free(rect);
    _placed = true;
  }

  void release() {
    if (_placed) _setWindowPos(window.top, _hwndNotTopmost, 0, 0, 0, 0, _swpNoMove | _swpNoSize);
    _placed = false;
  }

  /// The cursor is over this process's own view, now.
  bool get _gatePasses {
    final cursor = calloc<Int32>(2);
    final ok = _getCursorPos(cursor) != 0;
    final packed = (cursor[1] << 32) | (cursor[0] & 0xFFFFFFFF);
    calloc.free(cursor);
    return ok && _windowFromPoint(packed) == window.view;
  }

  @override
  Future<bool> side(int button) async {
    if (!_gatePasses) {
      _note('SKIPPED sendinput click: the cursor is not over this test window, nothing was sent');
      return false;
    }
    final sent = _sendSideButton(button == kBackMouseButton ? _xButton1 : _xButton2);
    if (sent != 2) {
      _note('SKIPPED sendinput click: SendInput took $sent of 2 events (no input desktop)');
      return false;
    }
    return true;
  }

  /// Coordinates are proved by the posted lane; this lane proves the path of
  /// the side buttons. A real left click here could land on anything.
  @override
  Future<void> leftClick(int x, int y) async {
    _postMessage(window.view, _wmLButtonDown, _mkLButton, _makeLParam(x, y));
    _postMessage(window.view, _wmLButtonUp, 0, _makeLParam(x, y));
  }
}

class _XdotoolLane implements _Lane {
  @override
  String get name => 'xdotool';

  String? _window;

  Future<String> _run(List<String> args) async {
    final r = await Process.run('xdotool', args);
    if (r.exitCode != 0) throw StateError('xdotool ${args.join(' ')}: ${r.stderr}');
    return (r.stdout as String).trim();
  }

  Future<String> _ownWindowId() async => _window ??= (await _run(['search', '--onlyvisible', '--name', '^NEFORUM\$'])).split('\n').first;

  @override
  Future<bool> side(int button) async {
    await _run(['mousemove', '--window', await _ownWindowId(), '4', '4']);
    await _run(['click', button == kBackMouseButton ? '8' : '9']);
    return true;
  }

  @override
  Future<void> leftClick(int x, int y) async {
    await _run(['mousemove', '--window', await _ownWindowId(), '$x', '$y']);
    await _run(['click', '1']);
  }
}

// ---------------------------------------------------------------- the run

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('side buttons on the real engine, at every zoom', (tester) async {
    final lanes = <_Lane>[];
    _SendInputLane? sendInputLane;
    _PostedLane? postedLane;
    if (Platform.isLinux) {
      if (Platform.environment['NEFORUM_XDOTOOL_LANE'] != '1') {
        _note('SKIPPED linux lane: NEFORUM_XDOTOOL_LANE is not set, and clicks on a real desktop go wherever the mouse is');
        return;
      }
      lanes.add(_XdotoolLane());
    } else if (!Platform.isWindows) {
      _note('SKIPPED: no injection lane on ${Platform.operatingSystem}. A Mac needs a five-button mouse and a person.');
      return;
    }

    final dirs = <Directory>[];
    Future<Directory> throwawayDir() async {
      final dir = await Directory.systemTemp.createTemp('neforum-nav-');
      dirs.add(dir);
      return dir;
    }

    addTearDown(() async {
      for (final dir in dirs) {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          // Windows may still hold a file open; the OS cleans temp later.
        }
      }
    });

    // Device events are dropped by a live test binding unless asked for.
    binding.shouldPropagateDevicePointerEvents = true;

    Future<void> pumpFor(int ms) async {
      for (var i = 0; i < ms ~/ 50; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await DesktopIntegration.instance.initWindow();
    await NotificationService.instance.init();
    Future<AppServices> workspace(Directory dir, {required bool demo}) async {
      final storage = await openAppStorage(overrideDir: dir.path);
      await storage.writeJson('settings.json', {'updateCheck': 'off'});
      return AppServices.create(demo: demo, storage: storage);
    }

    await tester.pumpWidget(NeforumRoot(initial: await workspace(await throwawayDir(), demo: true)));
    await pumpFor(2000);

    var c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first));
    var router = c.read(routerProvider);
    String location() => router.routerDelegate.currentConfiguration.uri.toString();

    if (Platform.isWindows) {
      final own = _ownWindow();
      expect(own, isNotNull, reason: 'this process has a window');
      _note('window found by process id: pid=${_getCurrentProcessId()}');
      lanes.add(postedLane = _PostedLane(own!.view));
      lanes.add(sendInputLane = _SendInputLane(own));
      addTearDown(sendInputLane.release);
    }

    /// Pumps until [done], or fails the run: the event never came.
    Future<void> waitFor(String what, bool Function() done) async {
      for (var i = 0; i < 120; i++) {
        if (done()) return;
        await tester.pump(const Duration(milliseconds: 50));
      }
      fail('$what did not happen in 6 s. At ${location()}.');
    }

    Future<void> settle() => pumpFor(350);

    /// Pressed, and the page must become [expected]. False if the lane could
    /// not send it.
    Future<bool> press(_Lane lane, int button, String expected) async {
      final from = location();
      if (!await lane.side(button)) return false;
      await waitFor('${lane.name} ${button == kBackMouseButton ? 'back' : 'forward'} from $from to $expected', () => location() == expected);
      await settle();
      _note('${lane.name} ${button == kBackMouseButton ? 'back' : 'forward'} $from -> ${location()}');
      expect(location(), expected);
      return true;
    }

    Finder section(String label) => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label && w.properties.button == true);

    /// The view's physical pixels for a logical position, as `UiZoom` divides
    /// them: the engine's coordinates over zoom, then over the screen's ratio.
    (int, int) physical(Offset logical) {
      final view = tester.view;
      final zoom = c.read(settingsProvider).uiZoom;
      return ((logical.dx * zoom * view.devicePixelRatio).round(), (logical.dy * zoom * view.devicePixelRatio).round());
    }

    Future<void> leftClickSection(_Lane lane, String label, String expected) async {
      final (x, y) = physical(tester.getCenter(section(label).first));
      await lane.leftClick(x, y);
      await waitFor('${lane.name} left click on $label at $x,$y', () => location() == expected);
      await settle();
      _note('${lane.name} left click on $label at $x,$y -> ${location()} zoom=${c.read(settingsProvider).uiZoom}');
    }

    const post = '/activity/post/demo-post-2';
    var sendInputClicks = 0;

    Future<void> walk(_Lane lane, double zoom) async {
      c.read(settingsProvider.notifier).update((x) => x.copyWith(uiZoom: zoom));
      await pumpFor(500);
      _note('--- lane=${lane.name} zoom=$zoom logicalWidth=${MediaQuery.sizeOf(tester.element(find.byType(Scaffold).first)).width} ---');

      // A section reopens where it was left: Activity must be left at its top.
      router.go('/activity');
      await settle();
      router.go('/compose');
      await settle();
      // A left click must still land at this zoom.
      await leftClickSection(lane, 'Queue', '/queue');
      await leftClickSection(lane, 'Activity', '/activity');
      router.go(post);
      await settle();

      if (!await press(lane, kBackMouseButton, '/activity')) return;
      if (lane == sendInputLane) sendInputClicks++;
      if (!await press(lane, kBackMouseButton, '/queue')) return;
      if (!await press(lane, kForwardMouseButton, '/activity')) return;
      if (!await press(lane, kForwardMouseButton, post)) return;

      // One press, one step, when the press comes while left is held.
      if (lane == postedLane) {
        await press(lane, kBackMouseButton, '/activity');
        final entriesBefore = c.read(navHistoryProvider).entries.length;
        postedLane!.leftHeldThenBack();
        await waitFor('left held then back', () => location() == '/queue');
        await pumpFor(500);
        _note('posted left held then back -> ${location()}');
        expect(location(), '/queue', reason: 'one step, not two, on release');
        expect(c.read(navHistoryProvider).entries.length, entriesBefore);
      }
    }

    for (final lane in lanes) {
      if (lane == sendInputLane) {
        sendInputLane!.place();
        await pumpFor(600);
      }
      for (final zoom in const [1.0, 1.5, 0.5]) {
        await walk(lane, zoom);
      }
      if (lane == sendInputLane) sendInputLane!.release();
    }
    c.read(settingsProvider.notifier).update((x) => x.copyWith(uiZoom: 1));
    await pumpFor(500);

    final lane = postedLane ?? lanes.first;
    final composer = c.read(composerProvider.notifier);
    Finder editor() => find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController).first;

    // --- Edit post X, leave, write something new, Back to Compose: the new
    // words stay. A history step never loads X.
    composer.reset();
    await settle();
    router.go('/queue');
    await settle();
    final card = find.descendant(of: find.byType(QueueScreen), matching: find.byWidgetPredicate((w) => w is PostCard && w.post.id == 'demo-post-3'));
    tester.widget<PostCard>(card).onTap!();
    await settle();
    expect(location(), '/compose');
    expect(c.read(composerProvider).editingPostId, 'demo-post-3');
    router.go('/queue');
    await settle();
    composer.reset();
    await settle();
    await press(lane, kBackMouseButton, '/compose');
    composer.prefill('Started after the edit');
    await pumpFor(500);
    expect(tester.widget<TextField>(editor()).controller!.text, 'Started after the edit');
    await press(lane, kForwardMouseButton, '/queue');
    await press(lane, kBackMouseButton, '/compose');
    expect(c.read(composerProvider).text, 'Started after the edit');
    expect(c.read(composerProvider).editingPostId, isNull);
    expect(c.read(navHistoryProvider).entries.where((e) => e.contains('post=')), isEmpty);
    _note('replay never loads: text stays, no history entry holds post=');
    composer.reset();
    await settle();

    // --- A dialog closes first, Forward waits, and the very next Back walks
    // with the mouse not having moved (the close cancels the pointer).
    router.go('/queue');
    await settle();
    router.go('/activity');
    await settle();
    await press(lane, kBackMouseButton, '/queue');
    final root = rootNavigatorKey.currentContext!;
    showDialog<void>(context: root, builder: (_) => const AlertDialog(content: Text('A dialog')));
    await pumpFor(500);
    await lane.side(kForwardMouseButton);
    await pumpFor(600);
    expect(find.text('A dialog'), findsOneWidget, reason: 'Forward does nothing while it is open');
    expect(location(), '/queue');
    await lane.side(kBackMouseButton);
    await waitFor('the dialog closing', () => find.text('A dialog').evaluate().isEmpty);
    await settle();
    expect(location(), '/queue', reason: 'the page stays');
    _note('dialog: forward waits, back closes it, page stays');
    await press(lane, kForwardMouseButton, '/activity');
    await press(lane, kBackMouseButton, '/queue');

    // --- Locked ones stay: the paste-code dialog and the publish sheet.
    final paste = showPasteCodeDialog(root, authorizationUrl: Uri.parse('https://example.invalid/a'), redirectUri: Uri.parse('https://example.invalid/r'));
    await pumpFor(500);
    await lane.side(kBackMouseButton);
    await pumpFor(600);
    expect(rootNavigatorKey.currentState!.canPop(), isTrue, reason: 'a locked dialog stays');
    expect(location(), '/queue');
    rootNavigatorKey.currentState!.pop();
    await paste;
    await pumpFor(500);
    final progress = showPublishProgress(root);
    await pumpFor(500);
    await lane.side(kBackMouseButton);
    await pumpFor(600);
    expect(location(), '/queue', reason: 'the page behind a locked sheet stays');
    expect(rootNavigatorKey.currentState!.canPop(), isTrue, reason: 'the locked sheet is still there');
    rootNavigatorKey.currentState!.pop();
    await progress;
    await pumpFor(500);
    _note('locked: paste-code dialog and publish sheet stay, the page stays');

    // --- Words typed in the composer survive Back and Forward, on disk too.
    // In an empty real workspace: the demo keeps no draft file. It holds no
    // account, so nothing asks the keychain for anything.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpFor(500);
    final real = await workspace(await throwawayDir(), demo: false);
    await tester.pumpWidget(NeforumRoot(initial: real));
    await pumpFor(1500);
    c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first));
    router = c.read(routerProvider);
    c.read(composerProvider.notifier).prefill('Words typed in the composer');
    await pumpFor(800);
    router.go('/queue');
    await settle();
    final draftFile = File('${real.storage.dataDir}${Platform.pathSeparator}$kComposerDraftFile');
    expect(draftFile.existsSync(), isTrue, reason: 'the keeper wrote the draft');
    final draftBefore = draftFile.readAsStringSync();
    expect(draftBefore, contains('Words typed in the composer'));
    await press(lane, kBackMouseButton, '/compose');
    await press(lane, kForwardMouseButton, '/queue');
    await press(lane, kBackMouseButton, '/compose');
    await pumpFor(800);
    expect(c.read(composerProvider).text, 'Words typed in the composer');
    expect(draftFile.readAsStringSync(), draftBefore, reason: '$kComposerDraftFile did not change');
    _note('draft kept: text unchanged, $kComposerDraftFile byte for byte the same (${draftBefore.length} chars)');

    _note('DONE lanes=${lanes.map((l) => l.name).join(',')} sendInputWalksCompleted=$sendInputClicks');
    if (lanes.contains(sendInputLane) && sendInputClicks == 0) _note('SKIPPED sendinput lane: no click could be sent in this session');

    // Back as it was before the test's end, which debug builds check.
    binding.shouldPropagateDevicePointerEvents = false;
  });
}
