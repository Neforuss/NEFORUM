// The Text styles tab's engine: what each style makes, that restyling
// replaces, that Upside down undoes itself, and what the combining-mark
// styles cost against each network's limit.
import 'package:characters/characters.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'catalog_files.dart';

void main() {
  final ts = bundledCatalog.textStyles;

  group('table styles', () {
    test('bold, script with its Letterlike gaps, fraktur, double-struck, monospace', () {
      expect(ts.apply(TextStyleKind.bold, 'Hi 42!'), '\u{1D407}\u{1D422} \u{1D7D2}\u{1D7D0}!');
      expect(ts.apply(TextStyleKind.script, 'Be'), 'ℬℯ');
      expect(ts.apply(TextStyleKind.fraktur, 'Hi'), 'ℌ\u{1D526}');
      expect(ts.apply(TextStyleKind.doubleStruck, 'C1'), 'ℂ\u{1D7D9}');
      expect(ts.apply(TextStyleKind.italic, 'h'), 'ℎ');
      expect(ts.apply(TextStyleKind.monospace, 'a'), '\u{1D68A}');
    });

    test('fullwidth turns spaces and punctuation too; circled and small capitals', () {
      expect(ts.apply(TextStyleKind.fullwidth, 'Hi, you!'), 'Ｈｉ，　ｙｏｕ！');
      expect(ts.apply(TextStyleKind.circled, 'ab1'), 'ⓐⓑ①');
      expect(ts.apply(TextStyleKind.smallCaps, 'Max'), 'ᴍᴀx', reason: 'no small capital X: it stays plain');
      expect(ts.apply(TextStyleKind.squared, 'ok'), '🄾🄺');
    });

    test('a second style replaces the first, and plain gives the text back', () {
      const text = 'NEFORUM 1.4.3, by everyone';
      // These have one form per letter, so upper and lower case come back as
      // one case.
      const oneCase = {TextStyleKind.squared, TextStyleKind.squaredNegative, TextStyleKind.circledNegative, TextStyleKind.smallCaps};
      for (final a in TextStyleKind.values.where((k) => k.method != TextStyleMethod.upsideDown)) {
        for (final b in [TextStyleKind.bold, TextStyleKind.fullwidth, TextStyleKind.strikethrough, TextStyleKind.zalgo]) {
          final again = ts.apply(b, ts.apply(a, text));
          if (oneCase.contains(a)) {
            expect(ts.plain(again).toLowerCase(), text.toLowerCase(), reason: '${a.name} then ${b.name}');
          } else {
            expect(again, ts.apply(b, text), reason: '${a.name} then ${b.name}');
          }
        }
      }
      for (final k in [TextStyleKind.bold, TextStyleKind.script, TextStyleKind.fullwidth, TextStyleKind.strikethrough, TextStyleKind.underline, TextStyleKind.zalgo]) {
        expect(ts.plain(ts.apply(k, 'Hello World 123')), 'Hello World 123', reason: k.name);
      }
    });

    test('characters outside a style pass through: accents, emoji, other scripts', () {
      const mixed = 'café ñ 😀 Ωμέγα 日本';
      expect(ts.apply(TextStyleKind.bold, mixed), '\u{1D41C}\u{1D41A}\u{1D41F}é ñ 😀 Ωμέγα 日本');
      expect(ts.plain('café'), 'café', reason: 'an accent written as a combining mark is not Zalgo');
    });

    test('NFKC would undo the styles made from compatibility forms: the reason NEFORUM never normalizes', () {
      const fromCompatibility = {
        TextStyleKind.bold, TextStyleKind.italic, TextStyleKind.script, TextStyleKind.fraktur, TextStyleKind.doubleStruck, TextStyleKind.monospace, //
        TextStyleKind.fullwidth, TextStyleKind.circled, TextStyleKind.squared, TextStyleKind.superscript, TextStyleKind.parenthesized,
      };
      for (final k in fromCompatibility) {
        final styled = ts.apply(k, 'A');
        expect(styled, isNot('A'), reason: k.name);
        expect(unorm.nfkc(styled), isNot(styled), reason: k.name);
        expect(unorm.nfc(styled), styled, reason: '${k.name}: NFC, which X counts with, keeps it');
      }
    });
  });

  group('upside down', () {
    final map = ts.upsideDownMap;

    test('turns and reverses', () {
      expect(ts.apply(TextStyleKind.upsideDown, 'hello world!'), '¡pꞁɹoʍ oꞁꞁǝɥ');
      expect(ts.apply(TextStyleKind.upsideDown, 'Yes?'), '¿sǝ⅄');
      expect(ts.apply(TextStyleKind.upsideDown, 'EASY'), '⅄S∀Ǝ');
    });

    test('round-trips over its whole mapped set, punctuation included, each pair both ways', () {
      final all = map.keys.join();
      expect(ts.upsideDown(ts.upsideDown(all)), all);
      for (final e in map.entries) {
        expect(ts.upsideDown(e.key), e.value);
        expect(ts.upsideDown(e.value), e.key);
      }
      expect(map.keys, containsAll(['?', '!', '.', ',', '(', ')', '[', ']', '{', '}', '<', '>', '&', '_', ';', '"', "'"]));
    });

    test('characters outside the set pass through, only reversed', () {
      expect(ts.upsideDown('ox8😀é'), 'é😀8xo');
      expect(ts.upsideDown('ab\ncd'), 'qɐ\npɔ', reason: 'lines stay in order');
    });
  });

  group('combining-mark styles', () {
    test('strikethrough and underline put one mark after every character, line breaks kept', () {
      expect(ts.apply(TextStyleKind.strikethrough, 'ab c'), 'a̶b̶ ̶c̶');
      expect(ts.apply(TextStyleKind.underline, 'a\nb'), 'a̲\nb̲');
      expect(ts.apply(TextStyleKind.strikethrough, '👍🏽'), '👍🏽̶', reason: 'a whole emoji is one character');
    });

    test('Zalgo: two or three marks per visible character, the same every time', () {
      final once = ts.apply(TextStyleKind.zalgo, 'Hello there');
      expect(ts.apply(TextStyleKind.zalgo, 'Hello there'), once);
      for (final c in once.characters) {
        if (c == ' ') continue;
        final marks = c.runes.length - 1;
        expect(marks, inInclusiveRange(2, kZalgoMaxMarks), reason: c);
      }
      expect(once.characters.where((c) => c == ' '), hasLength(1), reason: 'spaces get none');
    });

    test('the marks count against each limit: the preview shows the real length', () {
      final x = builtinRegistry().byId('x')!.descriptor.text;
      final mastodon = builtinRegistry().byId('mastodon')!.descriptor.text;
      final bluesky = builtinRegistry().byId('bluesky')!.descriptor.text;
      final struck = ts.apply(TextStyleKind.strikethrough, 'abcde');
      expect(TextCounter.count('abcde', x), 5);
      expect(TextCounter.count(struck, x), 10, reason: 'X weighs U+0336 as 1, like the letters (U+0000 to U+10FF)');
      expect(TextCounter.count(struck, mastodon), 10, reason: 'one per code point');
      expect(TextCounter.count(struck, bluesky), 5, reason: 'Bluesky counts graphemes');
      expect(TextCounter.count(ts.apply(TextStyleKind.bold, 'abcde'), x), 10, reason: 'a mathematical letter weighs 2 on X');
    });
  });

  group('search', () {
    test('styles are found by name and by what people call them', () {
      List<TextStyleKind> find(String q) => [for (final k in TextStyleKind.values) if (k.matches(q)) k];
      expect(find('cursive'), containsAll([TextStyleKind.script, TextStyleKind.boldScript]));
      expect(find('gothic'), contains(TextStyleKind.fraktur));
      expect(find('bubble'), containsAll([TextStyleKind.circled, TextStyleKind.circledNegative]));
      expect(find('vaporwave'), [TextStyleKind.fullwidth]);
      expect(find('flip'), [TextStyleKind.upsideDown]);
      expect(find('zzqq'), isEmpty);
    });
  });
}
