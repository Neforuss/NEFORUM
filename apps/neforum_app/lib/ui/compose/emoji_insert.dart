import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/env.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import 'emoji_catalog.dart';
import 'emoji_sheet.dart';

/// [value] with [text] in place of its selection, the caret right after it
/// (counted in UTF-16 units, as Dart's strings are), and any composition an input
/// method had in progress ended. A value with no selection gets [text] at the end.
TextEditingValue valueWithInserted(TextEditingValue value, String text) {
  final length = value.text.length;
  final selection = value.selection;
  final hasPlace = selection.isValid && selection.start >= 0;
  final start = hasPlace ? selection.start.clamp(0, length) : length;
  final end = hasPlace ? selection.end.clamp(0, length) : length;
  return TextEditingValue(
    text: value.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
    composing: TextRange.empty,
  );
}

/// Puts [text] at the cursor of [controller] and tells [onChanged], the field's
/// own callback: setting a controller's value does not fire it, and the counters,
/// previews and draft all listen to it.
void insertAtCursor(TextEditingController controller, String text, {ValueChanged<String>? onChanged}) {
  controller.value = valueWithInserted(controller.value, text);
  onChanged?.call(controller.text);
}

/// The text fields the emoji sheet can write to, most recently focused first.
/// A button sits on a card or a sheet, not on a field, so this finds the field.
class EmojiTargets {
  EmojiTargets._();
  static final List<_EmojiTargetFieldState> _fields = [];

  /// The field a button on [route] writes to: the one last focused on that
  /// route, else its default field, else its first. Null with no field there.
  static EmojiTargetField? resolve(ModalRoute<dynamic>? route) => _resolve(route)?.widget;

  static _EmojiTargetFieldState? _resolve(ModalRoute<dynamic>? route) {
    final here = _fields.where((f) => f._route == route).toList();
    if (here.isEmpty) return null;
    return here.where((f) => f._focused).firstOrNull ?? here.where((f) => f.widget.isDefault).firstOrNull ?? here.first;
  }
}

/// Marks a text field as one the emoji sheet can write to. Goes around the field.
class EmojiTargetField extends StatefulWidget {
  const EmojiTargetField({super.key, required this.controller, this.onChanged, this.focusNode, this.isDefault = false, required this.child});
  final TextEditingController controller;

  /// The field's own `onChanged`.
  final ValueChanged<String>? onChanged;

  /// The field's own focus node, when it has one.
  final FocusNode? focusNode;

  /// Written to when no field on this route had focus yet.
  final bool isDefault;
  final Widget child;

  @override
  State<EmojiTargetField> createState() => _EmojiTargetFieldState();
}

class _EmojiTargetFieldState extends State<EmojiTargetField> {
  ModalRoute<dynamic>? _route;
  bool _focused = false;
  FocusNode? _focusedNode;

  @override
  void initState() {
    super.initState();
    EmojiTargets._fields.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    EmojiTargets._fields.remove(this);
    super.dispose();
  }

  void _onFocus(bool focused) {
    if (!focused) return;
    _focused = true;
    _focusedNode = widget.focusNode ?? FocusManager.instance.primaryFocus;
    EmojiTargets._fields
      ..remove(this)
      ..insert(0, this);
  }

  void _refocus() => (widget.focusNode ?? _focusedNode)?.requestFocus();

  @override
  Widget build(BuildContext context) => Focus(canRequestFocus: false, skipTraversal: true, onFocusChange: _onFocus, child: widget.child);
}

/// Opens the emoji sheet for the text field last used on this route: a panel
/// beside the button on a computer, which stays open across picks and leaves the
/// cursor in the field; a bottom sheet on a phone.
class EmojiButton extends ConsumerStatefulWidget {
  const EmojiButton({super.key, this.size = 38, this.showBudget = false});
  final double size;

  /// 1.4.3: the panel shows how much room each chosen network has left: for
  /// the composer's own text, not for captions or answers.
  final bool showBudget;

  @override
  ConsumerState<EmojiButton> createState() => _EmojiButtonState();
}

class _EmojiButtonState extends ConsumerState<EmojiButton> {
  final OverlayPortalController _panel = OverlayPortalController();

  @override
  void dispose() {
    _removeKeyHandler();
    super.dispose();
  }

  void _removeKeyHandler() => HardwareKeyboard.instance.removeHandler(_onKey);

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && _panel.isShowing) {
      _closePanel();
      return true;
    }
    return false;
  }

  void _closePanel() {
    if (!_panel.isShowing) return;
    _removeKeyHandler();
    setState(_panel.hide);
    _lastTarget()?._refocus();
  }

  _EmojiTargetFieldState? _lastTarget() => EmojiTargets._resolve(ModalRoute.of(context));

  void _pick(String emoji) {
    if (!_insert(emoji)) return;
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(emojiRecents: withRecentEmoji(s.emojiRecents, emoji)));
  }

  /// Styled text from the Text styles tab: in place of the selection, and not
  /// a recent character.
  void _style(String styled) => _insert(styled);

  bool _insert(String text) {
    final target = _lastTarget();
    if (target == null) return false;
    insertAtCursor(target.widget.controller, text, onChanged: target.widget.onChanged);
    // On a phone the sheet holds the focus until it closes, so the keyboard does
    // not come up over it.
    if (Env.isDesktop) target._refocus();
    return true;
  }

  /// The text selected in the field the panel writes to, or ''.
  String _selection() {
    final c = _lastTarget()?.widget.controller;
    if (c == null) return '';
    final s = c.selection;
    if (!s.isValid || s.isCollapsed || s.start < 0 || s.end > c.text.length) return '';
    return s.textInside(c.text);
  }

  Widget _panelContent(VoidCallback onClose) => EmojiPanel(onPick: _pick, onClose: onClose, selection: _selection, onStyle: _style, showBudget: widget.showBudget);

  Future<void> _open() async {
    if (Env.isDesktop) {
      if (_panel.isShowing) {
        _closePanel();
      } else {
        HardwareKeyboard.instance.addHandler(_onKey);
        setState(_panel.show);
      }
      return;
    }
    final target = _lastTarget();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      barrierColor: Colors.transparent,
      builder: (sheet) {
        final size = MediaQuery.sizeOf(sheet);
        final keyboard = MediaQuery.viewInsetsOf(sheet).bottom;
        final room = size.height - keyboard;
        return Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: SizedBox(height: room < 420 ? room : (room * 0.66).clamp(380.0, 560.0), child: _panelContent(() => Navigator.pop(sheet))),
        );
      },
    );
    if (mounted) target?._refocus();
  }

  Widget _floating(BuildContext overlay) {
    final box = context.findRenderObject() as RenderBox?;
    final screen = MediaQuery.sizeOf(overlay);
    const margin = Space.sm;
    final width = (screen.width - margin * 2).clamp(0.0, 380.0);
    final height = (screen.height - margin * 2).clamp(0.0, 480.0);
    final at = box != null && box.hasSize ? box.localToGlobal(Offset.zero) : Offset.zero;
    final buttonHeight = box != null && box.hasSize ? box.size.height : 0.0;
    final below = at.dy + buttonHeight + height + margin <= screen.height;
    final top = below ? at.dy + buttonHeight + Space.xs : at.dy - height - Space.xs;
    return Positioned(
      left: at.dx.clamp(margin, screen.width - width - margin),
      top: top.clamp(margin, screen.height - height - margin),
      width: width,
      height: height,
      child: TextFieldTapRegion(
        onTapOutside: (_) => _closePanel(),
        child: Material(
          key: const Key('emoji-panel'),
          elevation: 8,
          color: overlay.nf.surface,
          shape: RoundedRectangleBorder(borderRadius: Radii.rLg, side: BorderSide(color: overlay.nf.border)),
          clipBehavior: Clip.antiAlias,
          child: _panelContent(_closePanel),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
        overlayLocation: OverlayChildLocation.rootOverlay,
        controller: _panel,
        overlayChildBuilder: _floating,
        // A tap here is not a tap outside the text field: it keeps its focus.
        child: TextFieldTapRegion(
          child: ToolButton(
            key: const Key('emoji-button'),
            icon: Icons.emoji_emotions_outlined,
            tooltip: 'Emoji, symbols and text styles',
            size: widget.size,
            active: _panel.isShowing,
            onPressed: _open,
          ),
        ),
      );
}
