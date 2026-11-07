import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' show Logger;

/// The page a location stands for in the history.
///
/// `/compose?post=X` is a command that opens post X (see `ComposeScreen`), not
/// a page: walking back to it must never load X over what is being written
/// now. It is always recorded as plain `/compose`.
String historyLocationOf(Uri uri) => uri.path == '/compose' ? '/compose' : uri.toString();

/// Sees every route on the root navigator and, through go_router's shell
/// routes, on the section navigators, to know which popup is on top. Passed
/// once, as `GoRouter(observers:)`.
class NavModalWatch extends NavigatorObserver {
  final List<PopupRoute<dynamic>> _popups = [];

  /// The popup the user sees on top, or null. Popups on the root navigator
  /// cover the section navigators, so they come first. A sheet left open on a
  /// section that is now hidden does not count: it blocks nothing on screen.
  PopupRoute<dynamic>? get top {
    // A navigator that went away takes its routes along without telling.
    _popups.removeWhere((r) => !r.isActive);
    PopupRoute<dynamic>? onSection;
    for (final route in _popups.reversed) {
      final owner = route.navigator;
      if (owner == null) continue;
      if (owner == navigator) return route;
      if (onSection == null && TickerMode.getValuesNotifier(owner.context).value.enabled) onSection = route;
    }
    return onSection;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute<dynamic>) _popups.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _popups.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _popups.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _popups.remove(oldRoute);
    if (newRoute is PopupRoute<dynamic>) _popups.add(newRoute);
  }
}

/// A browser's Back and Forward over the app's pages: one list and an index,
/// in memory only.
///
/// Dialogs, sheets and menus are not pages. Back closes one that may be
/// dismissed and does nothing under a locked one; Forward waits until none is
/// open.
class NavHistory extends ChangeNotifier {
  NavHistory(this._router, this._modals, {Logger? log}) : _log = log ?? Logger('nav') {
    _router.routerDelegate.addListener(_onLocationChanged);
    _onLocationChanged();
  }

  /// The most pages kept. The oldest goes first.
  static const int capacity = 50;

  final GoRouter _router;
  final NavModalWatch _modals;
  final Logger _log;

  final List<String> _entries = [];
  int _index = 0;

  /// Locations asked for by [back] and [forward] that have not arrived yet.
  /// They are not new pages.
  final List<String> _replays = [];

  bool _replaceNext = false;

  List<String> get entries => List.unmodifiable(_entries);
  int get index => _index;
  bool get canBack => _index > 0;
  bool get canForward => _index < _entries.length - 1;

  void _onLocationChanged() {
    final location = historyLocationOf(_router.routerDelegate.currentConfiguration.uri);
    // The router has no configuration until its first route is parsed.
    if (location.isEmpty) return;
    if (_entries.isEmpty) {
      _entries.add(location);
      return;
    }
    if (location == _entries[_index]) {
      _replays.clear();
      _replaceNext = false;
      return;
    }
    if (_replays.remove(location)) return;
    _replays.clear();
    _entries.removeRange(_index + 1, _entries.length);
    if (_replaceNext) {
      _replaceNext = false;
      _entries[_index] = location;
    } else {
      _entries.add(location);
      if (_entries.length > capacity) _entries.removeAt(0);
      _index = _entries.length - 1;
    }
    notifyListeners();
  }

  /// One step back, or closes the popup on top if it may be dismissed.
  /// `maybePop` alone would also close a locked dialog, so that is checked
  /// first; through `maybePop` a `PopScope` still has its say.
  Future<void> back() async {
    final modal = _modals.top;
    if (modal != null) {
      if (modal.barrierDismissible) {
        _log.debug('nav back closes a popup');
        await modal.navigator?.maybePop();
      } else {
        _log.debug('nav back stays: a locked popup is open');
      }
      return;
    }
    if (canBack) _replay(_index - 1, 'back');
  }

  /// One step forward; nothing while a popup is open.
  void forward() {
    if (_modals.top != null || !canForward) return;
    _replay(_index + 1, 'forward');
  }

  /// An on-screen arrow back to [location]: the same as [back] when that is
  /// the page before this one, so the page left stays one Forward away.
  /// Otherwise a new step, as any link is.
  void stepBackTo(String location) {
    if (canBack && _entries[_index - 1] == location) {
      _replay(_index - 1, 'back');
    } else {
      _router.go(location);
    }
  }

  /// The next new location takes the place of the current page rather than
  /// adding one, for a page that must not be walked back to (a form already
  /// sent).
  void replaceNext() => _replaceNext = true;

  void _replay(int to, String direction) {
    final from = _entries[_index];
    final location = _entries[to];
    _log.debug('nav $direction $from -> $location');
    _index = to;
    _replays.add(location);
    notifyListeners();
    _router.go(location);
  }

  @override
  void dispose() {
    _router.routerDelegate.removeListener(_onLocationChanged);
    super.dispose();
  }
}
