import 'dart:convert';

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/article_fixture.dart';
import '../support/test_context.dart';

/// [text] with its paragraphs separated by exactly one blank line, which is
/// what a document gives back.
String _normalized(String text) => ParagraphMedia.split(text).join('\n\n');

void main() {
  group('JSON', () {
    test('every block type and field survives a round trip', () {
      final json = jsonDecode(jsonEncode(richArticle.toJson())) as Map<String, dynamic>;
      final back = ArticleDocument.fromJson(json);
      expect(back, richArticle);
      expect(back.toJson(), richArticle.toJson());
      expect(json['v'], ArticleDocument.schemaVersion);
    });

    test('status and list markers round trip; defaults are not written', () {
      const doc = ArticleDocument(status: ArticleStatus.draft, blocks: [
        ArticleList('l', [
          [ArticleSpan('a')],
        ], marker: '*'),
      ]);
      expect(ArticleDocument.fromJson(doc.toJson()), doc);
      expect(const ArticleDocument().toJson(), {'v': 1, 'blocks': <Object>[]});
    });

    test('a block of a newer kind is kept as it came and written back unchanged', () {
      final raw = {
        'v': 2,
        'blocks': [
          {'id': 'p', 'type': 'paragraph', 'spans': [{'text': 'Hi'}]},
          {'id': 'x', 'type': 'poll', 'question': 'Q?', 'options': ['a', 'b']},
        ],
      };
      final doc = ArticleDocument.fromJson(raw);
      expect(doc.blocks[1], isA<ArticleUnknownBlock>());
      expect(doc.toJson()['blocks'], raw['blocks']);
    });

    test('a broken block does not break the document', () {
      final doc = ArticleDocument.fromJson({
        'blocks': [
          {'id': 'h', 'type': 'heading', 'level': 'two'},
        ],
      });
      expect(doc.blocks.single, isA<ArticleUnknownBlock>());
    });
  });

  group('the post carries it', () {
    test('Post JSON round trip, a post without one writes no key', () {
      final post = Post(
        id: 'p1',
        text: 'Short version',
        createdAt: testNow,
        updatedAt: testNow,
        media: richMedia(),
        article: richArticle,
        targets: const [
          PostTarget(accountId: 'a', overrides: PostOverrides(excludedBlockIds: ['vid', ArticleDocument.coverId])),
        ],
      );
      final back = Post.fromJson(jsonDecode(jsonEncode(post.toJson())) as Map<String, dynamic>);
      expect(back.article, richArticle);
      expect(back.targets.single.overrides.excludedBlockIds, ['vid', 'cover']);
      final plain = post.copyWith(clearArticle: true, targets: const []);
      expect(plain.toJson().containsKey('article'), isFalse);
      expect(Post.fromJson(plain.toJson()).article, isNull);
      expect(const PostOverrides().toJson().containsKey('excludedBlockIds'), isFalse);
      expect(const PostOverrides(excludedBlockIds: ['x']).isEmpty, isFalse);
    });

    test('a post from before 1.4.4 loads without an article', () {
      final json = {
        'id': 'old',
        'text': 'Hello',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'updatedAt': '2026-01-01T00:00:00.000Z',
      };
      expect(Post.fromJson(json).article, isNull);
    });
  });

  group('from plain text and back', () {
    final samples = <String>[
      'Hello world.',
      'One paragraph.\n\nTwo paragraphs.\nWith a line break.',
      '# Title line\n\nBody',
      '## Heading with **bold**\n\ntext *italic* and `code` and [a link](https://example.com/x).',
      '- one\n- two\n- three',
      '* star\n* list',
      '1. first\n2. second',
      '> quoted\n> lines',
      '```dart\nvoid main() {}\n\nprint(1);\n```',
      '---',
      'See https://example.com/a_b?c=d for more.',
      'Prices: 5 * 3 * 2 = 30, a ** b, 2*3*4.',
      r'Escaped \*stars\* and _underscores_ and __double__.',
      '1984. It was a good year.',
      '1. first\n3. third',
      '#hashtag at the start',
      '- item\n  indented continuation',
      '**unclosed bold',
      '<b>html</b> & entities &amp;',
      'Emoji 😀 and kaomoji (╯°□°)╯︵ ┻━┻',
      '   leading spaces kept?',
      'line with trailing spaces   \nnext',
      '***bold italic*** and ***',
      '[not a link](javascript:alert(1))',
      '~~strike~~ text',
    ];
    for (final s in samples) {
      test('lossless: ${jsonEncode(s)}', () {
        final doc = ArticleDocument.fromPlainText(s);
        expect(doc.toComposerText(), _normalized(s));
      });
    }

    test('several paragraphs, blank lines between them made single', () {
      const text = 'a\n\n\n\nb\n\n## c\n\n- d\n- e';
      expect(ArticleDocument.fromPlainText(text).toComposerText(), 'a\n\nb\n\n## c\n\n- d\n- e');
    });

    test('structure is read the way blogs read the composer text', () {
      final doc = ArticleDocument.fromPlainText('## Head\n\n- a\n- b\n\n1. x\n2. y\n\n> q\n\n```js\nx()\n```\n\n---\n\n**b** and *i*');
      expect(doc.blocks.map((b) => b.type), [
        ArticleBlockType.heading,
        ArticleBlockType.list,
        ArticleBlockType.list,
        ArticleBlockType.quote,
        ArticleBlockType.code,
        ArticleBlockType.divider,
        ArticleBlockType.paragraph,
      ]);
      expect((doc.blocks[0] as ArticleHeading).level, 2);
      expect((doc.blocks[2] as ArticleList).ordered, isTrue);
      expect((doc.blocks[4] as ArticleCode).language, 'js');
      expect((doc.blocks.last as ArticleParagraph).spans, const [
        ArticleSpan('b', marks: {ArticleMark.bold}),
        ArticleSpan(' and '),
        ArticleSpan('i', marks: {ArticleMark.italic}),
      ]);
    });

    test('a sentence that starts with a year stays a sentence', () {
      expect(ArticleDocument.fromPlainText('1984. It was a good year.').blocks.single, isA<ArticleParagraph>());
    });

    test('media: first unlinked photo is the cover, linked files follow their paragraph, the rest at the end; generated files stay out', () {
      final card = MediaAttachment(id: 'card', path: '/c.png', mimeType: 'image/png', sizeBytes: 1, generated: true);
      final media = [fakeImage(id: 'a'), fakeImage(id: 'b'), fakeVideo(id: 'v'), fakeAudio(id: 's'), card];
      final doc = ArticleDocument.fromPlainText('First.\n\nSecond.\n\nThird.', media: media, links: const {
        1: ['b', 'v'],
      });
      expect(doc.cover?.mediaId, 'a');
      expect(doc.blocks.map((b) => b.type), [
        ArticleBlockType.paragraph,
        ArticleBlockType.paragraph,
        ArticleBlockType.image,
        ArticleBlockType.video,
        ArticleBlockType.paragraph,
        ArticleBlockType.audio,
      ]);
      expect(doc.mediaIds, ['a', 'b', 'v', 's']);
      expect(doc.toComposerText(), 'First.\n\nSecond.\n\nThird.');
      expect(doc.structuralProblems, isEmpty);
    });

    test('coverFromFirstImage false keeps every photo in the body', () {
      final doc = ArticleDocument.fromPlainText('x', media: [fakeImage(id: 'a')], coverFromFirstImage: false);
      expect(doc.cover, isNull);
      expect(doc.blocks.last, isA<ArticleImage>());
    });
  });

  group('the short version for social networks', () {
    test('toPlainText: words only, no markup', () {
      expect(richArticle.toPlainText(), [
        'Intro & <setup>',
        'Plain bold, italic, code() and a link (https://example.com/a?b=1&c=2) *not emphasis* 2 < 3\nnext line',
        'Details',
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        '“To be or not to be.”\nHamlet',
        '• first\n• second',
        '3. three\n4. four',
        'void main() {\n  print("```");\n}',
        'The end. See https://example.org/x_y.',
      ].join('\n\n'));
    });

    test('toPlainPost: the files in reading order, each linked to the paragraph it follows', () {
      final post = richArticle.toPlainPost(markup: false);
      expect(post.mediaIds, ['c1', 'i1', 'g1', 'g2', 'g3', 'v1', 'a1']);
      final paragraphs = ParagraphMedia.split(post.text);
      expect(paragraphs[post.paragraphMedia.keys.first], startsWith('Plain bold'));
      expect(post.paragraphMedia, {
        1: ['i1', 'g1', 'g2', 'g3'],
        2: ['v1', 'a1'],
      });
    });
  });

  group('editing helpers', () {
    test('withoutBlocks drops blocks and the cover', () {
      final d = richArticle.withoutBlocks(['vid', 'gal', ArticleDocument.coverId]);
      expect(d.blockById('vid'), isNull);
      expect(d.cover, isNull);
      expect(d.mediaIds, ['i1', 'a1']);
      expect(identical(richArticle.withoutBlocks(const []), richArticle), isTrue);
    });

    test('withoutMedia removes the file everywhere', () {
      final d = richArticle.withoutMedia('g2').withoutMedia('i1').withoutMedia('c1');
      expect((d.blockById('gal')! as ArticleGallery).items.map((m) => m.mediaId), ['g1', 'g3']);
      expect(d.blockById('img'), isNull);
      expect(d.cover, isNull);
    });

    test('mediaIn finds a fitted copy for its photo', () {
      final fitted = MediaAttachment(id: 'fit', path: '/f.jpg', mimeType: 'image/jpeg', sizeBytes: 1, generated: true, derivedFrom: 'i1');
      const doc = ArticleDocument(blocks: [ArticleImage('x', ArticleMediaRef('i1'))]);
      expect(doc.mediaIn([fitted]).single.id, 'fit');
      expect(ArticleAssets([ArticleAsset(fitted, url: 'u')]).find('i1')?.url, 'u');
    });

    test('newBlockId and structural problems', () {
      const doc = ArticleDocument(blocks: [ArticleDivider('b1'), ArticleDivider('b1'), ArticleDivider('cover'), ArticleDivider('')]);
      expect(doc.newBlockId(), 'b4');
      expect(doc.structuralProblems, hasLength(3));
    });

    test('captionLine and alt text', () {
      expect(const ArticleMediaRef('x', caption: 'C', credit: 'R').captionLine, 'C · R');
      expect(const ArticleMediaRef('x', credit: 'R').captionLine, 'R');
      expect(const ArticleMediaRef('x').altFor(fakeImage(altText: 'Own')), 'Own');
      expect(const ArticleMediaRef('x', altText: ' Set ').altFor(fakeImage()), 'Set');
    });
  });
}
