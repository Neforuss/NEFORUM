// 1.4.3: passphrase fields write codes in shape (capitals, a dash every four
// characters), leave every other passphrase exactly as typed, and opening an
// existing file falls back to the exact text typed.

import 'dart:math';
import 'dart:typed_data';

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

const _fast = BackupKdfParams.testing;

/// A field driven like a keyboard: the text shown, the caret, and what the
/// user actually typed.
class _Field {
  String typed = '', text = '';
  int caret = 0;

  /// The app puts [t] in the field (a stored passphrase, a generated one).
  void set(String t) {
    text = t;
    caret = t.length;
  }

  void _apply(String newText, int? newCaret) {
    final e = editPassphraseField(typed: _typedFor(text), oldText: text, newText: newText, caret: newCaret);
    typed = e.typed;
    text = e.text;
    caret = e.caret;
    _shown = e.text;
  }

  // As the app's formatter: what was typed belongs to the text it produced.
  String _shown = '';
  String _typedFor(String t) => t == _shown ? typed : t;

  void type(String chars) {
    for (final ch in chars.split('')) {
      _apply(text.replaceRange(caret, caret, ch), caret + 1);
    }
  }

  void paste(String s, {int? start, int? end}) {
    final a = start ?? caret, b = end ?? caret;
    _apply(text.replaceRange(a, b, s), a + s.length);
  }

  void backspace() {
    if (caret == 0) return;
    _apply(text.replaceRange(caret - 1, caret, ''), caret - 1);
  }
}

void main() {
  group('code-shaped', () {
    test('alphabet characters in either case, spaces and dashes, 1 to 24 characters', () {
      for (final yes in ['k7qf', 'K7QF-MZ3D-W9TB', 'k7qf mz3d', ' k7qf\tmz3d\n', 'bad cafe', 'k7qf–mz3d', 'K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG', 'a']) {
        expect(isCodeShaped(yes), isTrue, reason: yes);
      }
      for (final no in ['', '-', ' - ', 'hello', 'K7QF-MZ3D-0', 'K1QF', 'kiqf', 'K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG-A', 'k7qf_mz3d', 'k7qf.mz3d', 'café', '😀']) {
        expect(isCodeShaped(no), isFalse, reason: no);
      }
    });

    test('formatting: capitals, a dash every four, spaces and dashes of any kind dropped', () {
      expect(formatPassphraseCode('k7qfmz3dw9tbxc4np2rvh8lg'), 'K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG');
      expect(formatPassphraseCode('k7qf-mz3d-w9tb-xc4n-p2rv-h8lg'), 'K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG');
      expect(formatPassphraseCode('K7QF MZ3D W9TB XC4N P2RV H8LG'), 'K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG');
      expect(formatPassphraseCode(' k7 qfm--z3d—w9tb '), 'K7QF-MZ3D-W9TB');
      expect(formatPassphraseCode('k7q'), 'K7Q');
      expect(formatPassphraseCode('k7qfm'), 'K7QF-M');
    });

    test('anything else is left exactly as typed', () {
      for (final t in ['correct horse battery', 'hello', 'K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG-A', 'k7qfmz3dw9tbxc4np2rvh8lgx', 'K0QF-MZ3D', '  ', '']) {
        expect(formatPassphraseCode(t), t, reason: t);
      }
    });

    test('generated codes are already in shape and come back the same however they are typed', () {
      final rng = Random(7);
      for (var i = 0; i < 200; i++) {
        final g = generatePassphrase(random: rng);
        expect(isCodeShaped(g), isTrue);
        expect(formatPassphraseCode(g), g);
        expect(formatPassphraseCode(g.toLowerCase()), g);
        expect(formatPassphraseCode(g.replaceAll('-', '')), g);
        expect(formatPassphraseCode(g.replaceAll('-', ' ').toLowerCase()), g);
        final f = _Field()..type(g.toLowerCase().replaceAll('-', ''));
        expect(f.text, g);
      }
    });
  });

  group('typing', () {
    test('lowercase without dashes: capitals and dashes appear, the caret stays at the end', () {
      final f = _Field();
      final seen = <String>[];
      for (final ch in 'k7qfmz3dw9tb'.split('')) {
        f.type(ch);
        seen.add(f.text);
        expect(f.caret, f.text.length, reason: f.text);
      }
      expect(seen, ['K', 'K7', 'K7Q', 'K7QF', 'K7QF-M', 'K7QF-MZ', 'K7QF-MZ3', 'K7QF-MZ3D', 'K7QF-MZ3D-W', 'K7QF-MZ3D-W9', 'K7QF-MZ3D-W9T', 'K7QF-MZ3D-W9TB']);
      expect(f.typed, 'k7qfmz3dw9tb');
    });

    test('the user\'s own dashes and spaces: shown once, kept in what was typed', () {
      final f = _Field()..type('k7qf-mz3d w9tb');
      expect(f.text, 'K7QF-MZ3D-W9TB');
      expect(f.typed, 'k7qf-mz3d w9tb');
      expect(f.caret, f.text.length);
    });

    test('a custom passphrase is shown as typed the moment it stops being code-shaped', () {
      final f = _Field()..type('hell');
      expect(f.text, 'HELL');
      f.type('o');
      expect(f.text, 'hello');
      expect(f.caret, 5);
      f.type(' world');
      expect(f.text, 'hello world');
      expect(f.typed, 'hello world');
    });

    test('a 25th code character makes it a custom passphrase, kept exactly as typed', () {
      final f = _Field()..type('k7qfmz3dw9tbxc4np2rvh8lg');
      expect(f.text, 'K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG');
      f.type('a');
      expect(f.text, 'k7qfmz3dw9tbxc4np2rvh8lga');
      expect(f.caret, 25);
      f.backspace();
      expect(f.text, 'K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG', reason: 'back to a code');
      expect(f.caret, f.text.length);
    });

    test('Backspace at the end and right after a dash', () {
      final f = _Field()..type('k7qfm');
      expect((f.text, f.caret), ('K7QF-M', 6));
      f.backspace();
      expect((f.text, f.caret, f.typed), ('K7QF', 4, 'k7qf'));
      f.type('mz');
      // The caret right after the dash: Backspace takes the F, not a dash
      // that would only come back.
      f.caret = 5;
      f.backspace();
      expect((f.text, f.caret, f.typed), ('K7QM-Z', 3, 'k7qmz'));
    });

    test('Backspace right after a dash the user typed takes the character before it with that dash', () {
      final f = _Field()..type('k7qf-mz');
      f.caret = 5;
      f.backspace();
      expect((f.text, f.caret, f.typed), ('K7QM-Z', 3, 'k7qmz'));
    });

    test('Backspace of the last character also drops the user\'s trailing dash the field never showed', () {
      final f = _Field()..type('k7qf-');
      expect(f.text, 'K7QF');
      f.backspace();
      expect((f.text, f.typed), ('K7Q', 'k7q'));
      f.type('f');
      expect(f.typed, 'k7qf');
    });

    test('inserting in the middle moves the dashes and keeps the caret after the new character', () {
      final f = _Field()..type('k7qfmz3d');
      f.caret = 2;
      f.type('x');
      expect((f.text, f.caret), ('K7XQ-FMZ3-D', 3));
      f.caret = 4; // right before a dash
      f.type('a');
      expect((f.text, f.caret), ('K7XQ-AFMZ-3D', 6));
      f.caret = 5; // right after a dash
      f.type('b');
      expect((f.text, f.caret), ('K7XQ-BAFM-Z3D', 6));
    });

    test('deleting in the middle closes the gap', () {
      final f = _Field()..type('k7qfmz3d');
      f.caret = 2;
      f.backspace();
      expect((f.text, f.caret, f.typed), ('KQFM-Z3D', 1, 'kqfmz3d'));
    });

    test('a selection across a dash replaced by one character', () {
      final f = _Field()..type('k7qfmz3d');
      f.paste('a', start: 3, end: 6); // "F-M"
      expect((f.text, f.caret, f.typed), ('K7QA-Z3D', 4, 'k7qaz3d'));
    });

    test('a lowercase or undashed paste is in shape at once', () {
      final a = _Field()..paste('k7qfmz3dw9tbxc4np2rvh8lg');
      expect((a.text, a.caret), ('K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG', 29));
      final b = _Field()..paste('k7qf-mz3d-w9tb-xc4n-p2rv-h8lg');
      expect((b.text, b.typed), ('K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG', 'k7qf-mz3d-w9tb-xc4n-p2rv-h8lg'));
      final c = _Field()..paste(' K7QF MZ3D W9TB XC4N P2RV H8LG\n');
      expect(c.text, 'K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG');
      expect(c.typed, ' K7QF MZ3D W9TB XC4N P2RV H8LG\n');
    });

    test('a paste in the middle', () {
      final f = _Field()..type('k7qf');
      f.caret = 2;
      f.paste('mz3d');
      expect((f.text, f.caret), ('K7MZ-3DQF', 7));
    });

    test('clearing the field leaves nothing behind, not even the spaces a paste brought', () {
      final f = _Field()..paste('  k7qf mz3d ');
      expect(f.text, 'K7QF-MZ3D');
      f.paste('', start: 0, end: f.text.length);
      expect((f.text, f.caret, f.typed), ('', 0, ''));
    });

    test('a pasted custom passphrase is not touched', () {
      final f = _Field()..paste('Correct Horse 1');
      expect((f.text, f.caret, f.typed), ('Correct Horse 1', 15, 'Correct Horse 1'));
    });

    test('text the app put in counts as typed: a stored lowercase passphrase stays as it is until edited', () {
      final f = _Field()..set('k7qfmz3d');
      expect(f.text, 'k7qfmz3d');
      f.type('w');
      expect((f.text, f.caret, f.typed), ('K7QF-MZ3D-W', 11, 'k7qfmz3dw'));
    });

    test('without a plain caret the edit is still found', () {
      final e = editPassphraseField(typed: 'k7qf', oldText: 'K7QF', newText: 'K7QFm', caret: null);
      expect((e.text, e.caret, e.typed), ('K7QF-M', 6, 'k7qfm'));
      final same = editPassphraseField(typed: 'k7qf', oldText: 'K7QF', newText: 'K7QF', caret: 4);
      expect((same.text, same.caret, same.typed), ('K7QF', 4, 'k7qf'));
    });

    test('repeated characters: the caret decides where the new one went', () {
      final f = _Field()..type('aaaa');
      f.caret = 1;
      f.type('b');
      expect((f.text, f.caret, f.typed), ('ABAA-A', 2, 'abaaa'));
    });
  });

  group('opening an existing file', () {
    test('the attempts: what the field shows, then the exact text typed when different', () {
      expect(passphraseAttempts('K7QF-MZ3D-W9TB', 'k7qfmz3dw9tb'), ['K7QF-MZ3D-W9TB', 'k7qfmz3dw9tb']);
      expect(passphraseAttempts('correct horse', 'correct horse'), ['correct horse']);
    });

    test('a backup locked with a lowercase code-shaped passphrase still opens when typed as it was set', () async {
      final payload = <String, dynamic>{'app': 'NEFORUM', 'secret': 'fake'};
      final bytes = await encryptBackup(payload, 'k7qfmz3dw9tb', params: _fast);
      final f = _Field()..type('k7qfmz3dw9tb');
      expect(f.text, 'K7QF-MZ3D-W9TB', reason: 'the field reshapes it');
      final tried = <String>[];
      final (used, opened) = await openWithPassphraseAttempts(passphraseAttempts(f.text, f.typed), (p) {
        tried.add(p);
        return decryptBackup(bytes, p, minimum: _fast);
      });
      expect(used, 'k7qfmz3dw9tb');
      expect(opened, payload);
      expect(tried, ['K7QF-MZ3D-W9TB', 'k7qfmz3dw9tb'], reason: 'two tries, nothing guessed');
    });

    test('a sync file locked with the code in shape opens on the first try, typed in lowercase', () async {
      final bytes = await BackupCipher('K7QF-MZ3D-W9TB-XC4N', params: _fast, minimum: _fast).seal({'records': <String, dynamic>{}});
      final f = _Field()..type('k7qf mz3d w9tb xc4n');
      final tried = <String>[];
      final (used, _) = await openWithPassphraseAttempts(passphraseAttempts(f.text, f.typed), (p) {
        tried.add(p);
        return BackupCipher(p, minimum: _fast).open(bytes);
      });
      expect(used, 'K7QF-MZ3D-W9TB-XC4N');
      expect(tried, ['K7QF-MZ3D-W9TB-XC4N']);
    });

    test('neither opens: the wrong passphrase error, after exactly the two tries', () async {
      final bytes = await encryptBackup({'a': 1}, 'k7qfmz3dw9tb', params: _fast);
      var calls = 0;
      await expectLater(
        openWithPassphraseAttempts(passphraseAttempts('K7QF-MZ3D-W9TC', 'k7qfmz3dw9tc'), (p) {
          calls++;
          return decryptBackup(bytes, p, minimum: _fast);
        }),
        throwsA(isA<BackupException>().having((e) => e.kind, 'kind', BackupErrorKind.wrongPassphraseOrDamaged)),
      );
      expect(calls, 2);
    });

    test('any other error stops at once', () async {
      var calls = 0;
      await expectLater(
        openWithPassphraseAttempts(['A', 'b'], (p) {
          calls++;
          return decryptBackup(Uint8List.fromList(List.filled(80, 7)), p, minimum: _fast);
        }),
        throwsA(isA<BackupException>().having((e) => e.kind, 'kind', BackupErrorKind.notABackup)),
      );
      expect(calls, 1);
      await expectLater(openWithPassphraseAttempts(const [], (p) async => p), throwsArgumentError);
    });
  });
}
