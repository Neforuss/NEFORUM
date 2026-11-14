import 'package:flutter/services.dart';
import 'package:neforum_core/neforum_core.dart' show editPassphraseField, isCodeShaped;

import '../platform/env.dart';

/// 1.4.3: a passphrase field's formatter. A code (letters and digits from
/// the generated codes' alphabet, at most 24 of them) is written in capitals
/// with a dash after every four characters as it is typed or pasted; any
/// other passphrase stays exactly as typed (see [editPassphraseField]).
///
/// One per field. It remembers what the user actually typed, before
/// reshaping: [typedFor] gives it back, for opening an existing file that
/// was locked with that exact text before 1.4.3.
class PassphraseInputFormatter extends TextInputFormatter {
  String _typed = '';
  String _shown = '';

  /// What the user typed to make the field show [shown]: [shown] itself
  /// when the app put that text there (a stored or generated passphrase).
  String typedFor(String shown) => shown == _shown ? _typed : shown;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final sel = newValue.selection;
    final e = editPassphraseField(
      typed: typedFor(oldValue.text),
      oldText: oldValue.text,
      newText: newValue.text,
      caret: sel.isValid && sel.isCollapsed ? sel.extentOffset : null,
    );
    _typed = e.typed;
    _shown = e.text;
    // Unchanged: keep the keyboard's own value (and its composing region).
    if (e.text == newValue.text && (!sel.isValid || !sel.isCollapsed || sel.extentOffset == e.caret)) return newValue;
    return TextEditingValue(text: e.text, selection: TextSelection.collapsed(offset: e.caret));
  }
}

/// The keyboard for a passphrase on phones: no autocorrect and no
/// suggestions (set on the field), and on Android the visible-password
/// layout (digits on top, nothing learned). Not on iPhone and iPad, where
/// that layout is ASCII only and a passphrase like "café au lait" could not
/// be typed.
TextInputType get passphraseKeyboardType => Env.isAndroid ? TextInputType.visiblePassword : TextInputType.text;

/// The note under a field that holds a code.
const String kPassphraseCodeNote = 'Codes are not case-sensitive: NEFORUM writes them in capitals and adds the dashes as you type.';

/// Whether [text] gets [kPassphraseCodeNote].
bool showsPassphraseCodeNote(String text) => isCodeShaped(text);
