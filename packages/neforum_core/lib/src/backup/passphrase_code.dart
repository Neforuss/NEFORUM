import 'package:meta/meta.dart';

import 'backup_format.dart';

// 1.4.3: passphrase fields that write codes the way NEFORUM generates them
// (generatePassphrase): capitals, a dash after every four characters.
//
// The key comes from the passphrase exactly as given, so case and dashes
// matter to the file. A field only reshapes text that is code-shaped
// (isCodeShaped); anything else (a custom passphrase with other characters,
// or longer than a code) stays exactly as typed. Opening an existing file
// tries what the field shows, then the exact text the user typed
// (passphraseAttempts, openWithPassphraseAttempts), so a file locked with a
// lowercase code-shaped passphrase before 1.4.3 still opens.

/// The 32 characters generated codes use: no 0, 1, I or O.
const String passphraseCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// Characters in a generated code, dashes not counted.
const int passphraseCodeLength = 24;

/// Characters between two dashes.
const int passphraseCodeGroup = 4;

/// Spaces (any kind) and dashes (ASCII and the typographic ones a notes app
/// or word processor puts in when a code is pasted from there).
bool _isSeparator(int c) =>
    c == 0x2D || // -
    (c >= 0x2010 && c <= 0x2015) || // hyphen, non-breaking hyphen, figure dash, en dash, em dash, bar
    c == 0x2212 || // minus sign
    _space.hasMatch(String.fromCharCode(c));

final RegExp _space = RegExp(r'\s');

bool _isCodeChar(int c) => passphraseCodeAlphabet.contains(String.fromCharCode(c).toUpperCase());

/// [text] without its spaces and dashes.
String _compact(String text) => String.fromCharCodes(text.codeUnits.where((c) => !_isSeparator(c)));

/// True when [text] reads as a code: once spaces and dashes are removed, one
/// to [passphraseCodeLength] characters, every one from
/// [passphraseCodeAlphabet] in either case. `k7qf mz3d`, `K7QF-MZ3D-W9TB` and
/// `bad cafe` are; `hello` (the O), `K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG-A` (too
/// long), `` and `--` are not.
bool isCodeShaped(String text) {
  final c = _compact(text);
  return c.isNotEmpty && c.length <= passphraseCodeLength && c.codeUnits.every(_isCodeChar);
}

/// [text] in the shape of a generated code (capitals, a dash after every
/// four characters) when it is code-shaped, otherwise [text] unchanged.
String formatPassphraseCode(String text) {
  if (!isCodeShaped(text)) return text;
  final c = _compact(text).toUpperCase();
  return [for (var i = 0; i < c.length; i += passphraseCodeGroup) c.substring(i, (i + passphraseCodeGroup).clamp(0, c.length))].join('-');
}

/// The passphrases to try, in order, when opening an existing file: what
/// the field shows, then the exact text the user typed when that differs.
/// Never more: other spellings are not guessed.
List<String> passphraseAttempts(String shown, String typed) => [shown, if (typed != shown) typed];

/// Opens a file with each of [attempts] in turn (see [passphraseAttempts])
/// and returns the passphrase that worked with what [open] returned. Only a
/// wrong passphrase moves on to the next attempt; any other error (not a
/// NEFORUM file, made by a newer NEFORUM, the storage failing) is thrown at
/// once. When none opens it, the first attempt's error is thrown.
Future<(String, T)> openWithPassphraseAttempts<T>(List<String> attempts, Future<T> Function(String passphrase) open) async {
  if (attempts.isEmpty) throw ArgumentError.value(attempts, 'attempts', 'needs at least one passphrase');
  BackupException? first;
  for (final p in attempts) {
    try {
      return (p, await open(p));
    } on BackupException catch (e) {
      if (e.kind != BackupErrorKind.wrongPassphraseOrDamaged) rethrow;
      first ??= e;
    }
  }
  throw first!;
}

/// The result of one edit in a passphrase field ([editPassphraseField]).
@immutable
class PassphraseFieldEdit {
  const PassphraseFieldEdit({required this.typed, required this.text, required this.caret});

  /// Exactly what the user typed and pasted, before any reshaping.
  final String typed;

  /// What the field shows: [typed] as a code when it is code-shaped,
  /// otherwise [typed] itself.
  final String text;

  /// Where the caret goes in [text]: after the same character it followed
  /// in what the user typed.
  final int caret;

  @override
  String toString() => 'PassphraseFieldEdit(typed: $typed, text: $text, caret: $caret)';
}

/// What a passphrase field shows for [typed].
String passphraseFieldText(String typed) => formatPassphraseCode(typed);

/// One edit in a passphrase field that writes codes in shape.
///
/// [typed] is what the user had typed so far and [oldText] what the field
/// showed for it ([passphraseFieldText], or [typed] itself when the text
/// was put in by the app rather than typed). [newText] and [caret] are the
/// field after the keyboard's edit (a key, a paste, a deletion); [caret] is
/// `null` when the selection is not a plain caret.
///
/// The edit is carried over to [typed] and the field is drawn again from
/// it, so the text the user typed is never lost: when it stops being
/// code-shaped, the field shows it exactly as typed. Deleting only a dash
/// the field put in (Backspace right after it) deletes the character before
/// the dash, as the dash would only come back.
PassphraseFieldEdit editPassphraseField({required String typed, required String oldText, required String newText, int? caret}) {
  final shownFromTyped = passphraseFieldText(typed);
  // The field holds text the app put there (or this edit is out of step):
  // that text is what was typed.
  final identity = oldText == typed || oldText != shownFromTyped;
  if (identity) typed = oldText;

  // The replaced range: old[p, oldEnd) became new[p, newEnd).
  final oldLen = oldText.length, newLen = newText.length;
  var s = 0;
  final c = caret;
  if (c != null && c >= 0 && c <= newLen && newLen - c <= oldLen && oldText.endsWith(newText.substring(c))) {
    s = newLen - c;
  } else {
    while (s < oldLen && s < newLen && oldText.codeUnitAt(oldLen - 1 - s) == newText.codeUnitAt(newLen - 1 - s)) {
      s++;
    }
  }
  var p = 0;
  while (p < oldLen - s && p < newLen - s && oldText.codeUnitAt(p) == newText.codeUnitAt(p)) {
    p++;
  }
  final oldEnd = oldLen - s, newEnd = newLen - s;
  final inserted = newText.substring(p, newEnd);

  int rawStart, rawEnd;
  if (identity) {
    rawStart = p;
    rawEnd = oldEnd;
  } else {
    // Shown and typed differ only in case and dashes: map the range through
    // the code characters.
    final at = <int>[for (var i = 0; i < typed.length; i++) if (!_isSeparator(typed.codeUnitAt(i))) i];
    int codesIn(String t, int end) {
      var n = 0;
      for (var i = 0; i < end; i++) {
        if (!_isSeparator(t.codeUnitAt(i))) n++;
      }
      return n;
    }

    final a = codesIn(oldText, p), b = codesIn(oldText, oldEnd);
    if (b == a && inserted.isEmpty && oldEnd > p) {
      // Only a dash the field put in was deleted: delete the character
      // before it (and the user's own spaces or dashes after that one).
      if (a == 0) return PassphraseFieldEdit(typed: typed, text: oldText, caret: p);
      rawStart = at[a - 1];
      rawEnd = a < at.length ? at[a] : typed.length;
    } else if (b > a) {
      // From the first character: the user's own leading spaces go too, so
      // clearing the field leaves it empty.
      rawStart = a == 0 ? 0 : at[a];
      // Through the last character: the user's own trailing spaces or
      // dashes (which the field does not show) go with it.
      rawEnd = b < at.length ? at[b - 1] + 1 : typed.length;
    } else {
      // An insertion goes right before the next character, so typing at the
      // end keeps the user's own dashes and spaces where they typed them.
      rawStart = a < at.length ? at[a] : typed.length;
      rawEnd = rawStart;
    }
  }
  final next = typed.replaceRange(rawStart, rawEnd, inserted);
  final rawCaret = rawStart + inserted.length;
  if (!isCodeShaped(next)) return PassphraseFieldEdit(typed: next, text: next, caret: rawCaret);
  var k = 0;
  for (var i = 0; i < rawCaret; i++) {
    if (!_isSeparator(next.codeUnitAt(i))) k++;
  }
  return PassphraseFieldEdit(typed: next, text: formatPassphraseCode(next), caret: k == 0 ? 0 : k + (k - 1) ~/ passphraseCodeGroup);
}
