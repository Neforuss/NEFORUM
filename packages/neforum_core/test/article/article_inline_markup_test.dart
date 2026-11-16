import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

// 1.4.4: the article editor's inline markup (articleInlineFromMarkup). What
// the user types in a block is read as spans, and writing the spans back
// gives the same text, so nothing typed is ever changed or lost.
void main() {
  test('marks and links are read', () {
    expect(articleInlineFromMarkup('A **bold** and *italic* `code` [link](https://example.org) end'), const [
      ArticleSpan('A '),
      ArticleSpan('bold', marks: {ArticleMark.bold}),
      ArticleSpan(' and '),
      ArticleSpan('italic', marks: {ArticleMark.italic}),
      ArticleSpan(' '),
      ArticleSpan('code', marks: {ArticleMark.code}),
      ArticleSpan(' '),
      ArticleSpan('link', link: 'https://example.org'),
      ArticleSpan(' end'),
    ]);
  });

  test('spaces around the text are kept, so a mark survives a trailing space', () {
    final spans = articleInlineFromMarkup('  **bold** ');
    expect(spans.first, const ArticleSpan('  '));
    expect(spans[1], const ArticleSpan('bold', marks: {ArticleMark.bold}));
    expect(spans.last, const ArticleSpan(' '));
  });

  test('every text comes back exactly as typed', () {
    const samples = [
      '',
      ' ',
      'plain words',
      '**unclosed',
      '__underscores__',
      '2 * 3 * 4',
      '# not a heading here',
      '1. not a list here',
      '- not a list either',
      'line one\nline two',
      '*a* **b** `c` [d](https://e.example)',
      'https://example.org/bare',
      '> not a quote',
      '***both***',
    ];
    for (final s in samples) {
      expect(composerInline(articleInlineFromMarkup(s)), s, reason: s);
    }
  });

  test('text that would not come back as written stays plain', () {
    expect(articleInlineFromMarkup('__x__'), const [ArticleSpan('__x__')]);
    expect(articleInlineFromMarkup('# title'), const [ArticleSpan('# title')]);
  });

  test('reading is stable: parsing the written spans gives the same spans', () {
    for (final s in ['**a** b', '__x__', '*i* [l](https://x.example)', 'plain']) {
      final once = articleInlineFromMarkup(s);
      expect(articleInlineFromMarkup(composerInline(once)), once, reason: s);
    }
  });
}
