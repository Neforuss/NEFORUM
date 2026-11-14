// 1.4.3: **bold** and *italic* written in a post's words, drawn on its text
// card, and left out of the words of networks without Markdown when the
// card uses them (kEmphasisMarkupKey).

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

void main() {
  group('parseEmphasis', () {
    test('bold, italic and both, with the asterisks left out', () {
      expect(parseEmphasis('A **bold** and *italic* and ***both*** word'), const [
        EmphasisRun('A '),
        EmphasisRun('bold', bold: true),
        EmphasisRun(' and '),
        EmphasisRun('italic', italic: true),
        EmphasisRun(' and '),
        EmphasisRun('both', bold: true, italic: true),
        EmphasisRun(' word'),
      ]);
    });

    test('part of a sentence, across a line break inside a paragraph', () {
      expect(parseEmphasis('We keep **every word\nyou write** here.'), const [
        EmphasisRun('We keep '),
        EmphasisRun('every word\nyou write', bold: true),
        EmphasisRun(' here.'),
      ]);
    });

    test('italic inside bold', () {
      expect(parseEmphasis('**very *much* so**'), const [
        EmphasisRun('very ', bold: true),
        EmphasisRun('much', bold: true, italic: true),
        EmphasisRun(' so', bold: true),
      ]);
    });

    test('ordinary writing is never read as emphasis', () {
      for (final s in [
        '5 * 3 * 2 = 30',
        '2*3*4',
        'a ** b',
        'a lone * star',
        '* a list item',
        '** not closed',
        '**',
        '****',
        'snake_case and _underscores_ stay',
        'word*s* inside a word',
        '** spaced **',
      ]) {
        expect(parseEmphasis(s), [EmphasisRun(s)], reason: s);
        expect(hasEmphasis(s), isFalse, reason: s);
        expect(stripEmphasis(s), s, reason: s);
      }
    });

    test('never across a blank line', () {
      const s = '**one paragraph\n\nanother**';
      expect(hasEmphasis(s), isFalse);
      expect(stripEmphasis(s), s);
    });

    test('punctuation around the markers', () {
      expect(stripEmphasis('("**Yes**," she said.)'), '("Yes," she said.)');
      expect(stripEmphasis('*Really?*'), 'Really?');
    });

    test('empty and plain words', () {
      expect(parseEmphasis(''), isEmpty);
      expect(parseEmphasis('plain'), const [EmphasisRun('plain')]);
    });
  });

  group('the words networks get', () {
    final registry = builtinRegistry();
    final now = DateTime.utc(2026, 11, 13);
    Post post({bool marked = true, String? own}) => Post(
          id: 'p',
          text: 'Write **once**, post *everywhere*.',
          targets: [
            PostTarget(
              accountId: 'a',
              overrides: PostOverrides(text: own, extra: {if (marked) kEmphasisMarkupKey: true}),
            ),
          ],
          createdAt: now,
          updatedAt: now,
        );
    String textOn(String platform, Post p) => const VariantResolver().resolve(p, p.targets.single, registry.descriptor(platform)!).text;

    test('without Markdown: the asterisks of the card leave the caption', () {
      expect(registry.descriptor('instagram')!.text.supportsMarkdown, isFalse);
      expect(textOn('instagram', post()), 'Write once, post everywhere.');
      expect(textOn('linkedin', post()), 'Write once, post everywhere.');
    });

    test('with Markdown: the words go as written', () {
      expect(registry.descriptor('reddit')!.text.supportsMarkdown, isTrue);
      expect(textOn('reddit', post()), 'Write **once**, post *everywhere*.');
    });

    test('a post whose card does not use emphasis keeps every asterisk', () {
      expect(textOn('instagram', post(marked: false)), 'Write **once**, post *everywhere*.');
    });

    test("a network's own version follows the same rule", () {
      expect(textOn('instagram', post(own: 'Just **this**')), 'Just this');
    });
  });
}
