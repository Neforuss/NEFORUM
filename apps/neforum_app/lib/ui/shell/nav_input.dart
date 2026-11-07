import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../state/nav_history.dart';

/// The mouse's side buttons walk [history]. Desktop only: iOS does not deliver
/// them, and Android may send its own Back key for the same press.
///
/// A side button pressed while another button is held arrives as a move, not
/// a down, so this watches the bits go down on every event. The engine's
/// buttons pass through `UiZoom` unchanged, at any zoom.
class NavMouseButtons extends StatefulWidget {
  const NavMouseButtons({super.key, required this.enabled, required this.history, required this.child});

  final bool enabled;
  final NavHistory history;
  final Widget child;

  @override
  State<NavMouseButtons> createState() => _NavMouseButtonsState();
}

class _NavMouseButtonsState extends State<NavMouseButtons> {
  static const int _sideButtons = kBackMouseButton | kForwardMouseButton;

  int _held = 0;

  void _onPointer(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    final pressed = event.buttons & ~_held;
    _held = event.buttons;
    // A side button is not a click. A dialog's barrier takes any button as a
    // tap, so Forward would close it. With another button already down this
    // arrives as a move, and that button's own press is left alone.
    if (event is PointerDownEvent && pressed & _sideButtons != 0 && event.buttons & ~_sideButtons == 0) {
      GestureBinding.instance.cancelPointer(event.pointer);
    }
    if (pressed & kBackMouseButton != 0) widget.history.back();
    if (pressed & kForwardMouseButton != 0) widget.history.forward();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointer,
      onPointerMove: _onPointer,
      onPointerUp: _onPointer,
      // A route closing mid-click cancels the pointer (Navigator does, with an
      // event that says "touch" whatever the device was) and its release never
      // arrives here. Without this the next press of the same button is lost.
      onPointerCancel: (_) => _held = 0,
      // No button down: a release this window never heard about is forgotten.
      onPointerHover: _onPointer,
      child: widget.child,
    );
  }
}

/// Alt+Left and Alt+Right (Windows, Linux), Cmd+[ and Cmd+] (macOS), and a
/// keyboard's own Back and Forward keys walk [history]. Desktop only.
///
/// A text field keeps its own shortcuts: Alt+Left moves the caret there.
class NavKeyboardShortcuts extends StatefulWidget {
  const NavKeyboardShortcuts({super.key, required this.enabled, required this.history, required this.child});

  final bool enabled;
  final NavHistory history;
  final Widget child;

  @override
  State<NavKeyboardShortcuts> createState() => _NavKeyboardShortcutsState();
}

class _NavKeyboardShortcutsState extends State<NavKeyboardShortcuts> {
  @override
  void initState() {
    super.initState();
    if (widget.enabled) HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didUpdateWidget(NavKeyboardShortcuts old) {
    super.didUpdateWidget(old);
    if (widget.enabled == old.enabled) return;
    if (widget.enabled) {
      HardwareKeyboard.instance.addHandler(_onKey);
    } else {
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.browserBack) return _run(widget.history.back);
    if (key == LogicalKeyboardKey.browserForward) return _run(widget.history.forward);

    final keys = HardwareKeyboard.instance;
    final bool isBack, isForward;
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      if (!keys.isMetaPressed || keys.isAltPressed || keys.isControlPressed || keys.isShiftPressed) return false;
      isBack = key == LogicalKeyboardKey.bracketLeft;
      isForward = key == LogicalKeyboardKey.bracketRight;
    } else {
      if (!keys.isAltPressed || keys.isMetaPressed || keys.isControlPressed || keys.isShiftPressed) return false;
      isBack = key == LogicalKeyboardKey.arrowLeft;
      isForward = key == LogicalKeyboardKey.arrowRight;
    }
    if ((!isBack && !isForward) || _inTextField) return false;
    return _run(isBack ? widget.history.back : widget.history.forward);
  }

  static bool get _inTextField => primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;

  bool _run(void Function() step) {
    step();
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The keys for Back and Forward, for the buttons' tooltips. Null where
/// [NavKeyboardShortcuts] is off.
({String back, String forward})? navShortcutLabels({required bool desktop}) {
  if (!desktop) return null;
  return defaultTargetPlatform == TargetPlatform.macOS ? (back: '⌘[', forward: '⌘]') : (back: 'Alt+Left', forward: 'Alt+Right');
}
