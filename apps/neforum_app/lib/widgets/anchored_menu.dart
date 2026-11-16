import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/selection_theme.dart';
import '../theme/tokens.dart';

// 1.4.4: the group menu of the character panel's Symbols and Kaomoji tabs.
//
// Before, that menu was a PopupMenuButton. A popup menu is a route pushed on
// the nearest Navigator, and in the app that is the navigator of the shell's
// tab (go_router's StatefulShellRoute). The character panel is not on that
// navigator: it is an overlay child of the ROOT overlay (emoji_insert.dart),
// which paints above the whole shell. So the menu was drawn under the panel,
// cut off by it ("diac", "usic"), as tall as the tab's navigator, and a second
// press of the chevron landed on the popup route's barrier instead of the
// chevron. This menu is an overlay child of the root overlay too, shown after
// the panel, so it paints above it, and it is placed and sized from the
// chevron's own position.

/// One choice of an [AnchoredMenuButton].
@immutable
class AnchoredMenuItem<T> {
  const AnchoredMenuItem({required this.value, required this.label, this.dividerBefore = false});
  final T value;
  final String label;

  /// A line above this item, to start a new part of the list.
  final bool dividerBefore;
}

/// A chevron that opens a list of [items] right under it (or over it, when
/// there is more room above), in the root overlay, so it is drawn above every
/// panel and page. The chevron toggles the list and turns over while it is
/// open; the [selected] item is marked. The keyboard moves through the list
/// with the arrow keys, Home and End, picks with Enter or Space, and Escape
/// closes it. A tap anywhere else closes it too. The list scrolls inside
/// itself and never runs past the window or [maxHeight].
class AnchoredMenuButton<T> extends StatefulWidget {
  const AnchoredMenuButton({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    required this.tooltip,
    this.maxHeight = 360,
    this.width = 260,
  });

  final List<AnchoredMenuItem<T>> items;
  final T? selected;
  final ValueChanged<T> onSelected;
  final String tooltip;

  /// The tallest the list gets; less when the window has less room.
  final double maxHeight;

  /// The list's width; less on a narrow window.
  final double width;

  /// The key of the open list, for tests.
  static const Key menuKey = Key('anchored-menu');

  /// The key of [item]'s row in the open list.
  static Key itemKey(Object? value) => ValueKey('anchored-menu-item-$value');

  static final Set<Object> _open = {};

  /// A menu is open somewhere. The character panel closes on Escape, unless a
  /// menu is open: then Escape closes the menu only.
  static bool get anyOpen => _open.isNotEmpty;

  @override
  State<AnchoredMenuButton<T>> createState() => _AnchoredMenuButtonState<T>();
}

class _AnchoredMenuButtonState<T> extends State<AnchoredMenuButton<T>> {
  final OverlayPortalController _portal = OverlayPortalController();
  final FocusNode _anchorFocus = FocusNode(debugLabel: 'anchored menu button');
  final FocusScopeNode _menuScope = FocusScopeNode(debugLabel: 'anchored menu');
  bool _hover = false;

  /// What had the focus when the list opened: it gets it back on close, so a
  /// pick from the list leaves the caret in the text field it was in.
  FocusNode? _before;

  bool get _isOpen => _portal.isShowing;

  @override
  void dispose() {
    _detach();
    _anchorFocus.dispose();
    _menuScope.dispose();
    super.dispose();
  }

  void _detach() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    AnchoredMenuButton._open.remove(this);
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && _isOpen) {
      _close();
      return true;
    }
    return false;
  }

  void _toggle() => _isOpen ? _close() : _openMenu();

  void _openMenu() {
    if (_isOpen || widget.items.isEmpty) return;
    final focus = FocusManager.instance.primaryFocus;
    _before = focus == _anchorFocus ? _anchorFocus : focus;
    AnchoredMenuButton._open.add(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    setState(_portal.show);
  }

  void _close() {
    if (!_isOpen) return;
    _detach();
    // Only when the focus is still in the list: a tap on another field keeps
    // that field's focus.
    final inside = _menuScope.hasFocus;
    setState(_portal.hide);
    final back = _before;
    _before = null;
    if (inside && back != null && back.context != null && back.canRequestFocus) back.requestFocus();
  }

  void _pick(T value) {
    _close();
    widget.onSelected(value);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final open = _isOpen;
    return OverlayPortal(
      overlayLocation: OverlayChildLocation.rootOverlay,
      controller: _portal,
      overlayChildBuilder: _menu,
      child: TapRegion(
        // The chevron is part of the list's region: a press on it while the
        // list is open is not a tap outside, so it closes the list once.
        groupId: this,
        child: Semantics(
          button: true,
          expanded: open,
          label: widget.tooltip,
          excludeSemantics: true,
          onTap: _toggle,
          child: Tooltip(
            message: widget.tooltip,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: Material(
                color: open ? nf.accentSoft : (_hover ? nf.surfaceHover : Colors.transparent),
                shape: RoundedRectangleBorder(borderRadius: Radii.rSm),
                child: InkWell(
                  focusNode: _anchorFocus,
                  borderRadius: Radii.rSm,
                  onTap: _toggle,
                  child: Padding(
                    padding: const EdgeInsets.all(Space.xs),
                    child: AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: context.motion(Motion.fast),
                      child: Icon(Icons.expand_more_rounded, size: 22, color: open ? nf.accent : nf.textMuted),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _menu(BuildContext overlayContext) => LayoutBuilder(builder: (overlayContext, constraints) {
        // Laid out after the chevron (an overlay child is laid out after its
        // portal), so the chevron's place is this frame's.
        final anchor = context.findRenderObject() as RenderBox?;
        final overlay = Overlay.of(context, rootOverlay: true).context.findRenderObject() as RenderBox?;
        if (anchor == null || overlay == null || !anchor.attached || !anchor.hasSize) return const SizedBox.shrink();
        final area = constraints.biggest;
        final rect = anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size;
        final layout = anchoredMenuLayout(
          anchor: rect,
          area: area,
          width: widget.width,
          maxHeight: widget.maxHeight,
          naturalHeight: _naturalHeight(overlayContext),
        );
        return Stack(children: [
          Positioned(
            left: layout.rect.left,
            top: layout.rect.top,
            width: layout.rect.width,
            height: layout.rect.height,
            child: TextFieldTapRegion(
              // A tap in the list is no tap outside the text field the panel
              // writes to, nor outside the panel (also a TextFieldTapRegion).
              child: TapRegion(
                groupId: this,
                onTapOutside: (_) => _close(),
                child: _MenuList<T>(
                  key: AnchoredMenuButton.menuKey,
                  scope: _menuScope,
                  items: widget.items,
                  selected: widget.selected,
                  onPick: _pick,
                ),
              ),
            ),
          ),
        ]);
      });

  double _naturalHeight(BuildContext context) {
    final row = _MenuList.rowHeight(context);
    final dividers = widget.items.where((i) => i.dividerBefore).length;
    return widget.items.length * row + dividers * _MenuList.dividerHeight + _MenuList.padding * 2;
  }
}

/// Where the list of an [AnchoredMenuButton] goes: right-aligned with the
/// [anchor], under it when it fits there or there is more room under it than
/// over it, else over it; never past [area] less [margin]; at most
/// [maxHeight] tall, scrolling inside when its [naturalHeight] is more.
({Rect rect, bool below}) anchoredMenuLayout({
  required Rect anchor,
  required Size area,
  required double width,
  required double maxHeight,
  required double naturalHeight,
  double margin = Space.sm,
  double gap = Space.xs,
}) {
  final w = math.max(0.0, math.min(width, area.width - margin * 2));
  final left = (anchor.right - w).clamp(margin, math.max(margin, area.width - w - margin)).toDouble();
  final roomBelow = math.max(0.0, area.height - anchor.bottom - gap - margin);
  final roomAbove = math.max(0.0, anchor.top - gap - margin);
  final wanted = math.min(naturalHeight, maxHeight);
  final below = wanted <= roomBelow || roomBelow >= roomAbove;
  final h = math.min(wanted, below ? roomBelow : roomAbove);
  final top = below ? anchor.bottom + gap : anchor.top - gap - h;
  return (rect: Rect.fromLTWH(left, top, w, h), below: below);
}

class _MenuList<T> extends StatefulWidget {
  const _MenuList({super.key, required this.scope, required this.items, required this.selected, required this.onPick});
  final FocusScopeNode scope;
  final List<AnchoredMenuItem<T>> items;
  final T? selected;
  final ValueChanged<T> onPick;

  static const double padding = Space.xs;
  static const double dividerHeight = Space.sm + 1;

  /// A row's height at the text size in use.
  static double rowHeight(BuildContext context) => math.max(40, MediaQuery.textScalerOf(context).scale(14) * 1.45 + Space.md * 2 - 4);

  @override
  State<_MenuList<T>> createState() => _MenuListState<T>();
}

class _MenuListState<T> extends State<_MenuList<T>> {
  late List<FocusNode> _nodes = _nodesFor(widget.items);
  final ScrollController _scroll = ScrollController();

  static List<FocusNode> _nodesFor(List<AnchoredMenuItem<Object?>> items) => [for (final i in items) FocusNode(debugLabel: 'menu item ${i.label}')];

  @override
  void didUpdateWidget(_MenuList<T> old) {
    super.didUpdateWidget(old);
    // The list changed while open: one focus node per row again.
    if (old.items.length != widget.items.length) {
      final stale = _nodes;
      _nodes = _nodesFor(widget.items);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final n in stale) {
          n.dispose();
        }
      });
    }
  }
  final GlobalKey _selectedKey = GlobalKey();

  int get _selectedIndex => widget.items.indexWhere((i) => i.value == widget.selected);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final at = _selectedIndex;
      final row = _selectedKey.currentContext;
      if (row != null) Scrollable.ensureVisible(row, alignment: 0.5);
      _nodes[at < 0 ? 0 : at].requestFocus();
    });
  }

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  /// Focuses row [i] and scrolls just enough to show it: to its bottom edge
  /// when it is [below] the rows in view, else to its top edge.
  void _focusAt(int i, {required bool below}) {
    final node = _nodes[i];
    node.requestFocus();
    final c = node.context;
    if (c == null) return;
    Scrollable.ensureVisible(c, alignmentPolicy: below ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
  }

  int get _focused => _nodes.indexWhere((n) => n.hasPrimaryFocus);

  void _move(int by) {
    final now = _focused;
    final n = _nodes.length;
    final next = now < 0 ? (by > 0 ? 0 : n - 1) : (now + by) % n;
    _focusAt(next, below: next > now);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final rowHeight = _MenuList.rowHeight(context);
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown): _MoveIntent(1),
        SingleActivator(LogicalKeyboardKey.arrowUp): _MoveIntent(-1),
        SingleActivator(LogicalKeyboardKey.tab): _MoveIntent(1),
        SingleActivator(LogicalKeyboardKey.tab, shift: true): _MoveIntent(-1),
        SingleActivator(LogicalKeyboardKey.home): _EndIntent(first: true),
        SingleActivator(LogicalKeyboardKey.end): _EndIntent(first: false),
      },
      child: Actions(
        actions: {
          _MoveIntent: CallbackAction<_MoveIntent>(onInvoke: (i) => _move(i.by)),
          _EndIntent: CallbackAction<_EndIntent>(onInvoke: (i) => _focusAt(i.first ? 0 : _nodes.length - 1, below: !i.first)),
          // Escape is the menu's (its keyboard handler closes it): it must not
          // also close a bottom sheet the menu is over.
          DismissIntent: DoNothingAction(consumesKey: true),
        },
        child: FocusScope(
          node: widget.scope,
          child: Semantics(
            explicitChildNodes: true,
            child: Material(
              elevation: 12,
              color: nf.surfaceRaised,
              shadowColor: nf.shadow,
              shape: RoundedRectangleBorder(borderRadius: Radii.rMd, side: BorderSide(color: nf.borderStrong)),
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(vertical: _MenuList.padding),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var i = 0; i < widget.items.length; i++) ...[
                    if (widget.items[i].dividerBefore) Divider(height: _MenuList.dividerHeight, thickness: 1, color: nf.hairline),
                    _row(context, i, rowHeight),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int i, double height) {
    final nf = context.nf;
    final item = widget.items[i];
    final selected = item.value == widget.selected;
    return Semantics(
      key: selected ? _selectedKey : null,
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      onTap: () => widget.onPick(item.value),
      // On and off (STYLE.md): the current group is the solid selected fill
      // with a check mark, never a tint alone.
      child: Material(
        color: selected ? nf.selectedFill : Colors.transparent,
        child: InkWell(
          key: AnchoredMenuButton.itemKey(item.value),
          focusNode: _nodes[i],
          onTap: () => widget.onPick(item.value),
          hoverColor: nf.surfaceHover,
          focusColor: nf.surfaceHover,
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              child: Row(children: [
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodyMedium?.copyWith(color: selected ? nf.onSelectedFill : nf.text, fontWeight: selected ? FontWeight.w700 : null),
                  ),
                ),
                if (selected) ...[const SizedBox(width: Space.sm), Icon(Icons.check_rounded, size: 18, color: nf.onSelectedFill)],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _MoveIntent extends Intent {
  const _MoveIntent(this.by);
  final int by;
}

class _EndIntent extends Intent {
  const _EndIntent({required this.first});
  final bool first;
}
