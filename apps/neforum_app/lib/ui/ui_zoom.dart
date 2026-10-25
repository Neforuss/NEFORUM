import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import '../theme/zoom.dart';

/// Draws the app [zoom] times bigger or smaller, the way a browser zooms a
/// page: one logical pixel covers [zoom] times more of the screen, so pages
/// lay out in a smaller (or bigger) window and every menu, tooltip and
/// right-click menu still opens where it should. Ctrl + / Ctrl − / Ctrl 0
/// (⌘ on a Mac) and Ctrl + mouse wheel change it through [onChanged]; a short
/// "110%" label shows each change.
///
/// Wrap the [MaterialApp]'s navigator ([MaterialApp.builder]'s child). With
/// [enabled] off it draws [child] as it is and listens to nothing.
class UiZoom extends StatefulWidget {
  const UiZoom({super.key, required this.zoom, required this.onChanged, required this.child, this.enabled = true});

  final double zoom;
  final ValueChanged<double> onChanged;
  final bool enabled;
  final Widget child;

  @override
  State<UiZoom> createState() => _UiZoomState();
}

class _UiZoomState extends State<UiZoom> with WidgetsBindingObserver {
  late double _zoom = widget.zoom;
  bool _showLabel = false;
  Timer? _hideLabel;
  Duration? _lastWheelStep;
  bool _lastWheelIn = false;

  double get _effective => widget.enabled ? _zoom : 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.enabled) _listen();
  }

  @override
  void didUpdateWidget(UiZoom old) {
    super.didUpdateWidget(old);
    if (widget.zoom != old.zoom && widget.zoom != _zoom) {
      _zoom = widget.zoom;
      _flashLabel();
    }
    if (widget.enabled != old.enabled) {
      widget.enabled ? _listen() : _stopListening();
    } else if (widget.enabled) {
      _ZoomedView.apply(this, _zoom);
    }
  }

  @override
  void didChangeMetrics() {
    // The window was resized or moved to another screen: the binding has just
    // set its plain size again.
    if (widget.enabled) _ZoomedView.apply(this, _zoom);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopListening();
    _hideLabel?.cancel();
    super.dispose();
  }

  void _listen() {
    HardwareKeyboard.instance.addHandler(_onKey);
    _ZoomedView.apply(this, _zoom);
  }

  void _stopListening() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _ZoomedView.release(this);
  }

  bool get _modifierHeld {
    final keys = HardwareKeyboard.instance;
    if (keys.isAltPressed) return false;
    return defaultTargetPlatform == TargetPlatform.macOS ? keys.isMetaPressed : keys.isControlPressed;
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent || !_modifierHeld) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add || key == LogicalKeyboardKey.numpadAdd) {
      _set(zoomIn(_zoom));
    } else if (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract) {
      _set(zoomOut(_zoom));
    } else if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      _set(1);
    } else {
      return false;
    }
    return true;
  }

  /// One step per wheel notch; smooth wheels send many small events, so
  /// steps in the same direction are at least 90 ms apart.
  void _onWheel(double dy, Duration timeStamp) {
    final zoomingIn = dy < 0;
    final last = _lastWheelStep;
    if (last != null && zoomingIn == _lastWheelIn && timeStamp >= last && timeStamp - last < const Duration(milliseconds: 90)) return;
    _lastWheelStep = timeStamp;
    _lastWheelIn = zoomingIn;
    _set(zoomingIn ? zoomIn(_zoom) : zoomOut(_zoom));
  }

  void _set(double zoom) {
    if (!mounted) return;
    final changed = zoom != _zoom;
    setState(() {
      _zoom = zoom;
      _flashLabel();
    });
    _ZoomedView.apply(this, zoom);
    if (changed) widget.onChanged(zoom);
  }

  /// Shows the label; the caller rebuilds.
  void _flashLabel() {
    _showLabel = true;
    _hideLabel?.cancel();
    _hideLabel = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _showLabel = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final zoom = _effective;
    final mq = MediaQuery.of(context);
    final scheme = Theme.of(context).colorScheme;
    // The same tree at every zoom, so changing it never rebuilds the pages.
    return MediaQuery(
      data: mq.copyWith(
        size: mq.size / zoom,
        devicePixelRatio: mq.devicePixelRatio * zoom,
        padding: mq.padding / zoom,
        viewPadding: mq.viewPadding / zoom,
        viewInsets: mq.viewInsets / zoom,
        systemGestureInsets: mq.systemGestureInsets / zoom,
      ),
      child: ZoomScope(
        zoom: zoom,
        child: Stack(fit: StackFit.expand, children: [
          widget.child,
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: AnimatedOpacity(
                  opacity: _showLabel && widget.enabled ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: Material(
                    color: scheme.inverseSurface,
                    shape: Radii.stadium,
                    elevation: 3,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      child: Text(zoomLabel(zoom), style: TextStyle(color: scheme.onInverseSurface, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Zooms the window itself: its views get a pixel ratio [zoom] times the
/// screen's, and pointer positions from the engine are divided by [zoom] to
/// match. Scaling the widgets instead (a Transform at the root) puts text
/// fields' right-click menus in the wrong place, because Flutter places them
/// with window positions inside the scaled layer.
///
/// Also takes Ctrl + mouse wheel (⌘ on a Mac) before the app sees it: a widget
/// at the root cannot, as the list under the pointer claims the wheel first
/// and would scroll while zooming. Installed once; it serves the latest
/// [UiZoom] and passes everything on unchanged at 100% without one.
abstract final class _ZoomedView {
  static _UiZoomState? _owner;
  static double _zoom = 1;
  static ui.PointerDataPacketCallback? _next;
  static bool _installed = false;

  /// Each view's own configuration (as the binding set it) and the zoomed one
  /// set here, to tell whether the binding has replaced it since.
  static final _plain = <RenderView, ViewConfiguration>{};
  static final _zoomed = <RenderView, ViewConfiguration>{};

  /// Where each mouse is, in the engine's pixels, while no button is down.
  static final _mice = <int, ui.PointerData>{};

  static void apply(_UiZoomState owner, double zoom) {
    _owner = owner;
    if (zoom != _zoom) _rehover();
    _zoom = zoom;
    if (!_installed) {
      _installed = true;
      final dispatcher = WidgetsBinding.instance.platformDispatcher;
      _next = dispatcher.onPointerDataPacket;
      dispatcher.onPointerDataPacket = _onPacket;
    }
    _configureViews();
  }

  static void release(_UiZoomState owner) {
    if (_owner != owner) return;
    _owner = null;
    if (_zoom != 1) _rehover();
    _zoom = 1;
    _configureViews();
  }

  /// After the next frame, tells the app again where each mouse is: the
  /// widget under it is a different one at the new zoom, and the hover
  /// highlight would stay on the old one until the mouse moves.
  static void _rehover() {
    if (_mice.isEmpty) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_mice.isEmpty) return;
      _onPacket(ui.PointerDataPacket(data: [
        for (final m in _mice.values)
          ui.PointerData(
            viewId: m.viewId,
            timeStamp: m.timeStamp,
            change: ui.PointerChange.hover,
            kind: m.kind,
            device: m.device,
            physicalX: m.physicalX,
            physicalY: m.physicalY,
            synthesized: true,
          ),
      ]));
    });
  }

  static void _configureViews() {
    for (final view in RendererBinding.instance.renderViews) {
      if (!view.hasConfiguration) continue;
      final current = view.configuration;
      final plain = current == _zoomed[view] ? _plain[view]! : current;
      final next = _zoom == 1
          ? plain
          : ViewConfiguration(
              physicalConstraints: plain.physicalConstraints,
              logicalConstraints: plain.logicalConstraints / _zoom,
              devicePixelRatio: plain.devicePixelRatio * _zoom,
            );
      _plain[view] = plain;
      _zoomed[view] = next;
      view.configuration = next;
    }
  }

  static void _onPacket(ui.PointerDataPacket packet) {
    for (final p in packet.data) {
      if (p.kind != PointerDeviceKind.mouse || (p.signalKind != null && p.signalKind != ui.PointerSignalKind.none)) continue;
      if (p.change == ui.PointerChange.remove || p.buttons != 0) {
        _mice.remove(p.device);
      } else if (p.change != ui.PointerChange.cancel) {
        _mice[p.device] = p;
      }
    }
    final owner = _owner;
    final zoom = _zoom;
    final wheelZooms = owner != null && owner.mounted && owner._modifierHeld;
    if (!wheelZooms && zoom == 1) return _next?.call(packet);
    final data = <ui.PointerData>[];
    for (final p in packet.data) {
      if (wheelZooms && p.signalKind == ui.PointerSignalKind.scroll && p.kind == PointerDeviceKind.mouse && p.scrollDeltaY != 0) {
        owner._onWheel(p.scrollDeltaY, p.timeStamp);
      } else {
        data.add(zoom == 1 ? p : _scaled(p, zoom));
      }
    }
    _next?.call(ui.PointerDataPacket(data: data));
  }

  /// [p] with its screen distances in zoomed pixels.
  static ui.PointerData _scaled(ui.PointerData p, double zoom) => ui.PointerData(
        viewId: p.viewId,
        embedderId: p.embedderId,
        timeStamp: p.timeStamp,
        change: p.change,
        kind: p.kind,
        signalKind: p.signalKind,
        device: p.device,
        pointerIdentifier: p.pointerIdentifier,
        physicalX: p.physicalX / zoom,
        physicalY: p.physicalY / zoom,
        physicalDeltaX: p.physicalDeltaX / zoom,
        physicalDeltaY: p.physicalDeltaY / zoom,
        buttons: p.buttons,
        obscured: p.obscured,
        synthesized: p.synthesized,
        pressure: p.pressure,
        pressureMin: p.pressureMin,
        pressureMax: p.pressureMax,
        distance: p.distance,
        distanceMax: p.distanceMax,
        size: p.size,
        radiusMajor: p.radiusMajor / zoom,
        radiusMinor: p.radiusMinor / zoom,
        radiusMin: p.radiusMin / zoom,
        radiusMax: p.radiusMax / zoom,
        orientation: p.orientation,
        tilt: p.tilt,
        platformData: p.platformData,
        scrollDeltaX: p.scrollDeltaX / zoom,
        scrollDeltaY: p.scrollDeltaY / zoom,
        panX: p.panX / zoom,
        panY: p.panY / zoom,
        panDeltaX: p.panDeltaX / zoom,
        panDeltaY: p.panDeltaY / zoom,
        scale: p.scale,
        rotation: p.rotation,
        onRespond: ({bool allowPlatformDefault = false}) => p.respond(allowPlatformDefault: allowPlatformDefault),
      );
}
