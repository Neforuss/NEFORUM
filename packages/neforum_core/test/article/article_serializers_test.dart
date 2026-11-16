// Each article serializer's output checked against its format's own rules,
// structurally (the exact bytes are in article_golden_test.dart):
// WordPress markup parsed the way @wordpress/block-serialization-default-parser
// parses it, Markdown parsed by package:markdown (CommonMark), NPF against
// npf-spec.md, Portable Text against EmDash's types.ts, X Articles against
// the create-draft schema. Then the render reports.
import 'dart:convert';

import 'package:markdown/markdown.dart' as md;
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/article_fixture.dart';
import '../support/test_context.dart';

/// A block found by [parseBlockMarkup].
class _Block {
  _Block(this.name, this.attrs);
  final String name;
  final String attrs;
  final List<_Block> inner = [];
}

/// The block comment grammar of WordPress's default block parser
/// (packages/block-serialization-default-parser/src/index.js): `<!-- wp:name
/// {json} -->`, `<!-- /wp:name -->`, `<!-- wp:name /-->`; core/ is implied.
final RegExp _token = RegExp(r'<!--\s+(/)?wp:([a-z][a-z0-9_-]*/)?([a-z][a-z0-9_-]*)\s+(\{[\s\S]*?\}\s+)?(/)?-->');

/// Top-level blocks of [markup] and the non-blank text outside any block
/// (what the editor would show as a Classic block).
({List<_Block> blocks, List<String> freeform}) parseBlockMarkup(String markup) {
  final top = <_Block>[];
  final freeform = <String>[];
  final stack = <_Block>[];
  var pos = 0;
  for (final m in _token.allMatches(markup)) {
    if (stack.isEmpty && markup.substring(pos, m.start).trim().isNotEmpty) freeform.add(markup.substring(pos, m.start));
    pos = m.end;
    final name = '${m[2] ?? 'core/'}${m[3]}';
    if (m[1] != null) {
      expect(stack, isNotEmpty, reason: 'closer $name without opener');
      expect(stack.last.name, name, reason: 'closer $name does not match ${stack.last.name}');
      stack.removeLast();
      continue;
    }
    final attrs = (m[4] ?? '').trim();
    // The attributes are JSON, as the parser decodes them.
    if (attrs.isNotEmpty) expect(jsonDecode(attrs), isA<Map<String, Object?>>());
    final b = _Block(name, attrs);
    (stack.isEmpty ? top : stack.last.inner).add(b);
    if (m[5] == null) stack.add(b);
  }
  expect(stack, isEmpty, reason: 'unclosed ${stack.map((b) => b.name)}');
  if (markup.substring(pos).trim().isNotEmpty) freeform.add(markup.substring(pos));
  return (blocks: top, freeform: freeform);
}

List<String> _tags(List<md.Node> nodes) => [for (final n in nodes) if (n is md.Element) n.tag];

void main() {
  group('Gutenberg', () {
    test('every block is a block: no freeform, the expected blocks in order, nested images and list items', () {
      final out = renderGutenberg(richArticle, richAssets()).output;
      final parsed = parseBlockMarkup(out);
      expect(parsed.freeform, isEmpty);
      expect(parsed.blocks.map((b) => b.name), [
        'core/heading', 'core/paragraph', 'core/image', 'core/gallery', 'core/heading', 'core/video', 'core/audio', //
        'core/embed', 'core/quote', 'core/list', 'core/list', 'core/code', 'core/separator', 'core/paragraph',
      ]);
      expect(parsed.blocks[3].inner.map((b) => b.name), ['core/image', 'core/image', 'core/image']);
      expect(parsed.blocks[8].inner.map((b) => b.name), ['core/paragraph']);
      expect(parsed.blocks[9].inner.map((b) => b.name), ['core/list-item', 'core/list-item']);
      expect(parsed.blocks[2].attrs, '{"id":102,"sizeSlug":"large","linkDestination":"none"}');
      expect(parsed.blocks[10].attrs, '{"ordered":true,"start":3}');
    });

    test('the parser grammar sees a stray text as freeform (the check can fail)', () {
      expect(parseBlockMarkup('hello\n<!-- wp:paragraph -->\n<p>x</p>\n<!-- /wp:paragraph -->').freeform, ['hello\n']);
    });

    test('text is escaped, never markup', () {
      const doc = ArticleDocument(blocks: [ArticleParagraph('p', [ArticleSpan('<script>alert(1)</script> & "q"')])]);
      final out = renderGutenberg(doc, ArticleAssets.none).output;
      expect(out, contains('&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;q&quot;'));
      expect(out, isNot(contains('<script>')));
    });

    test('a block whose file WordPress does not get is left out and reported', () {
      final r = renderGutenberg(richArticle, ArticleAssets([for (final a in richAssets().items) if (a.media.id != 'v1') a]));
      expect(parseBlockMarkup(r.output).blocks.map((b) => b.name), isNot(contains('core/video')));
      expect(r.report.forBlock('vid').single.code, 'media_unavailable');
    });
  });

  group('Markdown (CommonMark, package:markdown)', () {
    for (final dialect in ArticleMarkdownDialect.values) {
      test('${dialect.name}: the blocks come back as the same structure', () {
        final out = renderMarkdown(richArticle, richAssets(), dialect: dialect, network: dialect.name).output;
        final doc = md.Document(extensionSet: md.ExtensionSet.commonMark);
        final nodes = doc.parse(out);
        final tags = _tags(nodes);
        final coverFirst = dialect == ArticleMarkdownDialect.writeFreely || dialect == ArticleMarkdownDialect.commonMark;
        expect(tags, [
          if (coverFirst) ...['p', 'p'],
          'h2', 'p', 'p', 'p', 'p', 'p', 'p', 'p', 'h3', 'p', 'p', 'blockquote', 'ul', 'ol', 'pre', 'hr', 'p', //
        ]);
        final html = md.renderToHtml(nodes);
        expect(html, contains('<h2>Intro &amp; &lt;setup&gt;</h2>'));
        expect(html, contains('<strong>bold</strong>'));
        expect(html, contains('<em>italic</em>'));
        expect(html, contains('<code>code()</code>'));
        expect(html, contains('<a href="https://example.com/a?b=1&c=2">a link</a>'));
        // Literal asterisks stay text, a line break stays a line break.
        expect(html, contains('*not emphasis* 2 &lt; 3<br />'));
        expect(html, contains('<img src="https://cdn.example.test/i1" alt="Ref alt" />'));
        expect(html, contains('<ol start="3">'));
        expect(html, contains('<code class="language-dart">void main() {\n  print(&quot;```&quot;);\n}\n</code>'));
        expect(html, contains('<a href="https://example.org/x_y">https://example.org/x_y</a>'));
        expect(html, isNot(contains('<video')));
      });
    }

    test('characters Markdown would read as markup are escaped and come back as text', () {
      const nasty = r'# not a heading *a* _b_ `c` [d](e) <f> \g 1. h &amp; ~~i~~ | j';
      const doc = ArticleDocument(blocks: [
        ArticleParagraph('p', [ArticleSpan(nasty)]),
        ArticleParagraph('q', [ArticleSpan('- not a list')]),
        ArticleParagraph('r', [ArticleSpan('1. not a list either')]),
      ]);
      final out = renderMarkdown(doc, ArticleAssets.none, dialect: ArticleMarkdownDialect.commonMark, network: 'x').output;
      final nodes = md.Document(extensionSet: md.ExtensionSet.commonMark).parse(out);
      expect(_tags(nodes), ['p', 'p', 'p']);
      String unescape(String s) => s.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&amp;', '&');
      expect(nodes.map((n) => unescape(n.textContent)).toList(), [nasty, '- not a list', '1. not a list either']);
    });
  });

  group('NPF (npf-spec.md)', () {
    const subtypes = {'heading1', 'heading2', 'quirky', 'quote', 'indented', 'chat', 'ordered-list-item', 'unordered-list-item'};
    const formats = {'bold', 'italic', 'strikethrough', 'small', 'link', 'mention', 'color'};
    void checkNpf(Map<String, Object?> post) {
      final content = (post['content']! as List).cast<Map<String, Object?>>();
      var images = 0;
      for (final b in content) {
        switch (b['type']) {
          case 'text':
            final text = b['text']! as String;
            expect(text.runes.length, lessThanOrEqualTo(4096));
            if (b['subtype'] != null) expect(subtypes, contains(b['subtype']));
            for (final f in (b['formatting'] as List? ?? const []).cast<Map<String, Object?>>()) {
              expect(formats, contains(f['type']));
              expect(f['start']! as int, lessThan(f['end']! as int));
              expect(f['end']! as int, lessThanOrEqualTo(text.runes.length));
              if (f['type'] == 'link') expect(f['url'], isA<String>());
            }
          case 'image':
            images++;
            final media = b['media']! as List;
            expect(media, isNotEmpty);
            for (final m in media.cast<Map<String, Object?>>()) {
              expect(m['type'], startsWith('image/'));
              expect(m['identifier'], isA<String>());
            }
            if (b['alt_text'] != null) expect((b['alt_text']! as String).length, lessThanOrEqualTo(4096));
            if (b['caption'] != null) expect((b['caption']! as String).length, lessThanOrEqualTo(4096));
          case 'video':
            // `media` is one object for video (tumblr/docs #88).
            expect(b['media'], isA<Map<String, Object?>>());
          case 'link':
            expect(b['url'], startsWith('https://'));
          default:
            fail('Unknown NPF block ${b['type']}');
        }
      }
      expect(images, lessThanOrEqualTo(npfMaxImages));
      expect(content.length, lessThanOrEqualTo(1000));
      final layout = post['layout'] as List?;
      if (layout != null) {
        final rows = ((layout.single as Map<String, dynamic>)['display']! as List).map((r) => ((r as Map<String, dynamic>)['blocks']! as List).cast<int>()).toList();
        // "should contain references to all content block indices", in order.
        expect(rows.expand((r) => r).toList(), [for (var i = 0; i < content.length; i++) i]);
        for (final row in rows.where((r) => r.length > 1)) {
          expect(row.every((i) => content[i]['type'] == 'image'), isTrue, reason: 'rows of several blocks hold only images');
          expect(row.length, lessThanOrEqualTo(3));
        }
      }
    }

    test('the rich article follows the spec, gallery side by side', () {
      final post = renderNpf(richArticle, richAssets(remoteId: (i, m) => 'media$i'), title: 'T').output;
      checkNpf(post);
      expect(post['layout'], isNotNull);
    });

    test('31 photos: 30 go, the last is reported, still valid', () {
      final media = [for (var i = 0; i < 31; i++) fakeImage(id: 'p$i')];
      final doc = ArticleDocument(blocks: [ArticleGallery('g', [for (final m in media) ArticleMediaRef(m.id)])]);
      final r = renderNpf(doc, ArticleAssets([for (var i = 0; i < 31; i++) ArticleAsset(media[i], url: '', remoteId: 'media$i')]));
      checkNpf(r.output);
      expect(r.report.dropped.single.code, 'too_many_images');
    });

    test('no layout when nothing sits side by side', () {
      const doc = ArticleDocument(blocks: [ArticleParagraph('p', [ArticleSpan('Hi')])]);
      expect(renderNpf(doc, ArticleAssets.none).output.containsKey('layout'), isFalse);
    });

    test('formatting offsets count code points, not UTF-16 units', () {
      const doc = ArticleDocument(blocks: [
        ArticleParagraph('p', [ArticleSpan('😀 '), ArticleSpan('bold', marks: {ArticleMark.bold})]),
      ]);
      final block = (renderNpf(doc, ArticleAssets.none).output['content']! as List).single as Map<String, dynamic>;
      expect(block['formatting'], [
        {'start': 2, 'end': 6, 'type': 'bold'},
      ]);
    });
  });

  group('Portable Text (EmDash types.ts)', () {
    test('every key is unique and carries the prefix; shapes match EmDash', () {
      final blocks = renderPortableText(richArticle, richAssets(remoteId: (i, m) => 'em$i'), keyPrefix: 'nfabc').output;
      final keys = <String>[];
      void collect(Object? v) {
        if (v is Map) {
          if (v['_key'] case final String k) keys.add(k);
          v.values.forEach(collect);
        } else if (v is List) {
          v.forEach(collect);
        }
      }

      collect(blocks);
      expect(keys.toSet().length, keys.length);
      expect(keys.every((k) => k.startsWith('nfabc')), isTrue);
      expect(blocks.map((b) => b['_type']).toSet(), {'block', 'image', 'gallery', 'video', 'code', 'break'});
      for (final b in blocks.where((b) => b['_type'] == 'block')) {
        expect(const {'normal', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote'}, contains(b['style']));
        final defs = {for (final d in (b['markDefs']! as List).cast<Map<String, dynamic>>()) d['_key']};
        for (final c in (b['children']! as List).cast<Map<String, dynamic>>()) {
          for (final m in (c['marks']! as List).cast<String>()) {
            expect(const {'strong', 'em', 'code'}.contains(m) || defs.contains(m), isTrue, reason: 'mark $m');
          }
        }
      }
      final numbered = blocks.where((b) => b['listItem'] == 'number').toList();
      expect(numbered.map((b) => b['listStart']).toSet(), {3});
      expect(numbered.map((b) => b['listId']).toSet().length, 1);
      final gallery = blocks.firstWhere((b) => b['_type'] == 'gallery');
      expect((gallery['images']! as List).length, 3);
    });

    test('plain text keeps its bare addresses linked, as EmDash posts always had', () {
      const doc = ArticleDocument(blocks: [ArticleParagraph('p', [ArticleSpan('See https://a.example/x now')])]);
      final b = renderPortableText(doc, ArticleAssets.none, keyPrefix: 'k').output.single;
      expect((b['markDefs']! as List).single, {'_type': 'link', '_key': 'k0l0', 'href': 'https://a.example/x'});
      expect([for (final c in (b['children']! as List).cast<Map<String, dynamic>>()) c['text']], ['See ', 'https://a.example/x', ' now']);
    });
  });

  group('X Articles (create draft schema)', () {
    test('blocks, styles and entities follow the schema', () {
      final body = renderXArticle(richArticle, richAssets(remoteId: (i, m) => '${1000 + i}'), title: 'T').output;
      expect(body.keys.toSet(), {'title', 'content_state', 'cover_media'});
      final state = body['content_state']! as Map<String, dynamic>;
      final blocks = (state['blocks']! as List).cast<Map<String, dynamic>>();
      final entities = (state['entities']! as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < entities.length; i++) {
        expect(entities[i]['key'], '$i');
        final value = entities[i]['value']! as Map<String, dynamic>;
        expect(const {'post', 'link', 'image', 'emoji', 'markdown', 'divider', 'latex'}, contains(value['type']));
        expect(const {'immutable', 'mutable', 'segmented'}, contains(value['mutability']));
      }
      for (final b in blocks) {
        expect(const {'unstyled', 'header-one', 'header-two', 'unordered-list-item', 'ordered-list-item', 'blockquote', 'atomic'},
            contains(b['type']));
        final text = b['text']! as String;
        for (final r in [...(b['inline_style_ranges']! as List).cast<Map<String, dynamic>>(), ...(b['entity_ranges']! as List).cast<Map<String, dynamic>>()]) {
          expect((r['offset']! as int) + (r['length']! as int), lessThanOrEqualTo(text.length));
        }
        for (final s in (b['inline_style_ranges']! as List).cast<Map<String, dynamic>>()) {
          expect(const {'bold', 'italic', 'strikethrough'}, contains(s['style']));
        }
        if (b['type'] == 'atomic') {
          expect(text, ' ');
          expect((b['entity_ranges']! as List).length, 1);
        }
      }
      final types = [for (final e in entities) (e['value']! as Map<String, dynamic>)['type']];
      expect(types.where((t) => t == 'image').length, 2); // the photo, the gallery
      expect(types, containsAll(['markdown', 'divider', 'link']));
      expect(body['cover_media'], {'media_category': 'tweet_image', 'media_id': '1000'});
    });

    test('an x.com status address becomes an embedded post', () {
      const doc = ArticleDocument(blocks: [ArticleEmbed('e', 'https://x.com/someone/status/1234567890')]);
      final r = renderXArticle(doc, ArticleAssets.none, title: 'T');
      final entity = ((r.output['content_state']! as Map<String, dynamic>)['entities']! as List).single as Map<String, dynamic>;
      expect(entity['value'], {'type': 'post', 'mutability': 'immutable', 'data': {'post_id': '1234567890'}});
      expect(r.report.isLossless, isTrue);
    });
  });

  group('render reports', () {
    test('the pre-upload report is the one the serializer gives with the real files', () {
      for (final format in ArticleFormat.values) {
        final before = ArticleRenderer.report(richArticle, format, media: richMedia(), network: 'N');
        final after = ArticleRenderer.render(richArticle, format, richAssets(), network: 'N', title: 'Title').report;
        expect(before.issues, after.issues, reason: format.name);
      }
    });

    test('nothing is lost silently: every block missing from the output is in the report', () {
      // Only the photo reaches the network: every other file block is reported.
      final only = ArticleAssets.placeholders([richMedia()[1]]);
      for (final format in ArticleFormat.values.where((f) => f != ArticleFormat.handoffHtml)) {
        final r = ArticleRenderer.render(richArticle, format, only, network: 'N', title: 'T').report;
        final reported = {for (final i in r.dropped) ?i.blockId};
        expect(reported, containsAll(['gal', 'vid', 'aud']), reason: format.name);
        expect(r.issues.where((i) => i.blockId == ArticleDocument.coverId), isNotEmpty, reason: format.name);
        expect(reported, isNot(contains('img')), reason: format.name);
      }
    });

    test('a lossless article on WordPress reports nothing', () {
      const doc = ArticleDocument(blocks: [ArticleParagraph('p', [ArticleSpan('Hello')])]);
      expect(ArticleRenderer.report(doc, ArticleFormat.gutenberg, media: const [], network: 'WordPress').isLossless, isTrue);
    });

    test('Ghost: the subtitle becomes the excerpt when there is none; the post\'s own excerpt option counts', () {
      const doc = ArticleDocument(subtitle: 'Sub');
      expect(ArticleRenderer.report(doc, ArticleFormat.ghostHtml, media: const [], network: 'Ghost').issues.single.code, 'subtitle_as_excerpt');
      expect(ArticleRenderer.report(doc, ArticleFormat.ghostHtml, media: const [], network: 'Ghost', excerptOverride: 'Own').issues.single.code,
          'subtitle');
    });

    test('unknown blocks from a newer NEFORUM are reported, never sent', () {
      final doc = ArticleDocument(blocks: [ArticleBlock.fromJson({'id': 'z', 'type': 'hologram', 'beam': 1})]);
      for (final format in ArticleFormat.values) {
        final r = ArticleRenderer.render(doc, format, ArticleAssets.none, network: 'N', title: 'T');
        expect(r.report.forBlock('z').single.code, 'unknown_block', reason: format.name);
      }
    });

    test('as checks: dropped is a warning, degraded an info', () {
      final issues = ArticleRenderer.report(richArticle, ArticleFormat.devtoMarkdown, media: richMedia(), network: 'DEV').toValidationIssues();
      expect(issues.where((i) => i.code == 'article.media_unavailable').single.severity, IssueSeverity.warning);
      expect(issues.where((i) => i.code == 'article.gallery_as_images').single.severity, IssueSeverity.info);
      expect(issues.every((i) => i.field == 'article'), isTrue);
    });
  });
}
