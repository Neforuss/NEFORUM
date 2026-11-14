// NEFORUM 1.4.3: Markdown to Portable Text for EmDash. The block shapes are
// EmDash 1.5's own (emdash/src/content/converters/types.ts): what its editor
// writes and its site renders.

import 'dart:convert';

import 'package:neforum_core/src/text/portable_text.dart';
import 'package:test/test.dart';

List<Map<String, Object?>> pt(String md) => markdownToPortableText(md, keyPrefix: 'k');

/// The spans of block [i] as (text, marks) pairs, the marks joined with
/// commas ('' for none).
List<(String, String)> spans(List<Map<String, Object?>> blocks, [int i = 0]) => [
      for (final c in blocks[i]['children']! as List) ((c as Map)['text'] as String, (c['marks'] as List).join(',')),
    ];

List<Map<String, Object?>> markDefs(List<Map<String, Object?>> blocks, [int i = 0]) =>
    [for (final d in blocks[i]['markDefs']! as List) Map<String, Object?>.from(d as Map)];

void main() {
  group('blocks', () {
    test('plain text: blank lines make paragraphs, a single newline stays a line break', () {
      final b = pt('First line\nsecond line\n\n\nNext paragraph');
      expect(b, [
        {
          '_type': 'block',
          '_key': 'k0',
          'style': 'normal',
          'markDefs': <Object?>[],
          'children': [
            {'_type': 'span', '_key': 'k0s0', 'text': 'First line\nsecond line', 'marks': <String>[]},
          ],
        },
        {
          '_type': 'block',
          '_key': 'k1',
          'style': 'normal',
          'markDefs': <Object?>[],
          'children': [
            {'_type': 'span', '_key': 'k1s0', 'text': 'Next paragraph', 'marks': <String>[]},
          ],
        },
      ]);
    });

    test('empty and blank text give no blocks; Windows line ends are lines', () {
      expect(pt(''), isEmpty);
      expect(pt('  \n\n \t\n'), isEmpty);
      expect(spans(pt('a\r\nb\rc')), [('a\nb\nc', '')]);
    });

    test('headings 1 to 6, closing hashes dropped; a hashtag is not a heading', () {
      final b = pt('# One\n## Two ##\n###### Six\n#hashtag stays text\n####### seven is text');
      expect([for (final x in b) x['style']], ['h1', 'h2', 'h6', 'normal']);
      expect(spans(b, 0), [('One', '')]);
      expect(spans(b, 1), [('Two', '')]);
      expect(spans(b, 3), [('#hashtag stays text\n####### seven is text', '')]);
    });

    test('a heading ends the paragraph before it', () {
      final b = pt('Intro\n## Part');
      expect([for (final x in b) x['style']], ['normal', 'h2']);
    });

    test('quotes: one blockquote block per paragraph of the quote, formatting inside', () {
      final b = pt('> First **bold**\n> still first\n>\n> Second\n\nAfter');
      expect([for (final x in b) x['style']], ['blockquote', 'blockquote', 'normal']);
      expect(spans(b, 0), [('First ', ''), ('bold', 'strong'), ('\nstill first', '')]);
      expect(spans(b, 1), [('Second', '')]);
    });

    test('bullet lists: -, * and + items, nested by indentation', () {
      final b = pt('- one\n* two\n  - two a\n    + two a i\n- three');
      expect([for (final x in b) (x['listItem'], x['level'])], [
        ('bullet', 1),
        ('bullet', 1),
        ('bullet', 2),
        ('bullet', 3),
        ('bullet', 1),
      ]);
      expect([for (final x in b) x['style']], everyElement('normal'));
      expect([for (final x in b) x.containsKey('listId')], everyElement(isFalse));
      expect(spans(b, 3), [('two a i', '')]);
    });

    test('numbered lists keep their first number and an id, so EmDash numbers them from it', () {
      final b = pt('3. three\n4. four\n   1) nested\n\nText\n\n1. again');
      expect([for (final x in b) (x['listItem'], x['level'], x['listId'], x['listStart'])], [
        ('number', 1, 'kl0', 3),
        ('number', 1, 'kl0', 3),
        ('number', 2, 'kl1', 1),
        (null, null, null, null),
        ('number', 1, 'kl2', 1),
      ]);
    });

    test('a bullet after a numbered item at the same depth starts its own list', () {
      final b = pt('1. one\n- dot');
      expect([for (final x in b) (x['listItem'], x['level'])], [('number', 1), ('bullet', 1)]);
    });

    test('a line under an item continues it; a blank line then plain text ends the list', () {
      final b = pt('- item\ncontinued\n\nAfter the list');
      expect(b, hasLength(2));
      expect(spans(b, 0), [('item\ncontinued', '')]);
      expect(b[1].containsKey('listItem'), isFalse);
    });

    test('a blank line between items keeps one list', () {
      final b = pt('1. one\n\n2. two');
      expect([for (final x in b) x['listId']], ['kl0', 'kl0']);
    });

    test('in a paragraph only a list that starts at 1 begins a list', () {
      expect(pt('I was born in\n1984. It was cold.'), hasLength(1));
      expect(pt('Steps:\n1. open'), hasLength(2));
      expect(pt('Things:\n- one'), hasLength(2));
      expect(pt('2024. A good year.').single['listStart'], 2024, reason: 'on its own it is a list, as in CommonMark');
    });

    test('fenced code: backticks or tildes, language kept, contents untouched', () {
      final b = pt('Before\n```dart\nvoid main() {\n  print("*not em*");\n}\n```\n~~~\nraw <b>\n~~~\nAfter');
      expect(b[1], {'_type': 'code', '_key': 'k1', 'code': 'void main() {\n  print("*not em*");\n}', 'language': 'dart'});
      expect(b[2], {'_type': 'code', '_key': 'k2', 'code': 'raw <b>'});
      expect(spans(b, 3), [('After', '')]);
    });

    test('an unclosed fence runs to the end; a longer closing fence closes it', () {
      expect(pt('```\na\n\nb').single['code'], 'a\n\nb');
      expect(pt('````\nx\n``````\nafter')[0]['code'], 'x');
    });

    test('a strange language name is cleaned, never passed through', () {
      expect(pt('```c++ "><script>\nx\n```').single['language'], 'c++');
    });

    test('---, *** and ___ are a break block; - - - too', () {
      final b = pt('a\n\n---\n\n***\n___\n- - -\nb');
      expect([for (final x in b) x['_type']], ['block', 'break', 'break', 'break', 'break', 'block']);
      expect(b[1], {'_type': 'break', '_key': 'k1', 'style': 'lineBreak'});
    });

    test('a line that is only an image is an image block with the address as its asset', () {
      final b = pt('Look:\n![A red door](https://example.com/door.jpg "Door")\nNice.');
      expect(b[1], {
        '_type': 'image',
        '_key': 'k1',
        'asset': {'_ref': 'https://example.com/door.jpg', 'url': 'https://example.com/door.jpg'},
        'alt': 'A red door',
      });
      expect([for (final x in b) x['_type']], ['block', 'image', 'block']);
    });

    test('an image line with an unsafe address is not an image', () {
      final b = pt('![x](javascript:alert(1))');
      expect(b.single['_type'], 'block');
      expect(markDefs(b), isEmpty);
    });
  });

  group('inline', () {
    test('strong, em, strike and code marks', () {
      final b = pt('**bold** __also__ *em* _em too_ ~~gone~~ `x*y`');
      expect(spans(b), [
        ('bold', 'strong'),
        (' ', ''),
        ('also', 'strong'),
        (' ', ''),
        ('em', 'em'),
        (' ', ''),
        ('em too', 'em'),
        (' ', ''),
        ('gone', 'strike-through'),
        (' ', ''),
        ('x*y', 'code'),
      ]);
    });

    test('nesting: ***both***, emphasis inside strong, strong inside emphasis', () {
      expect(spans(pt('***both***')), [('both', 'strong,em')]);
      expect(spans(pt('**a *b* c**')), [('a ', 'strong'), ('b', 'strong,em'), (' c', 'strong')]);
      expect(spans(pt('*foo **bar** baz*')), [('foo ', 'em'), ('bar', 'em,strong'), (' baz', 'em')]);
    });

    test('unmatched or space-flanked markers stay text', () {
      expect(spans(pt('2 * 3 * 4')), [('2 * 3 * 4', '')]);
      expect(spans(pt('**not closed')), [('**not closed', '')]);
      expect(spans(pt('a ~single~ tilde')), [('a ~single~ tilde', '')]);
      expect(spans(pt('**a*')), [('*', ''), ('a', 'em')]);
    });

    test('underscores inside words are not emphasis', () {
      expect(spans(pt('snake_case_name and __init__')), [('snake_case_name and ', ''), ('init', 'strong')]);
    });

    test('backslash escapes keep the character; a backslash before a line break goes', () {
      expect(spans(pt(r'\*not em\* and \# and \\ and \q')), [(r'*not em* and # and \ and \q', '')]);
      expect(spans(pt('line\\\nnext')), [('line\nnext', '')]);
    });

    test('a list marker escaped at line start is text', () {
      final b = pt(r'\- not a list');
      expect(b.single.containsKey('listItem'), isFalse);
      expect(spans(b), [('- not a list', '')]);
    });

    test('code spans: longer fences, trimmed padding, unmatched backticks stay', () {
      expect(spans(pt('``a ` b``')), [('a ` b', 'code')]);
      expect(spans(pt('` padded `')), [('padded', 'code')]);
      expect(spans(pt('one ` tick')), [('one ` tick', '')]);
    });

    test('links: [text](url) with a title, formatting in the text, one mark definition per address', () {
      final b = pt('See [the **docs**](https://example.com/a "Docs") and [again](https://example.com/a).');
      expect(markDefs(b), [
        {'_type': 'link', '_key': 'k0m0', 'href': 'https://example.com/a'},
      ]);
      expect(spans(b), [
        ('See ', ''),
        ('the ', 'k0m0'),
        ('docs', 'k0m0,strong'),
        (' and ', ''),
        ('again', 'k0m0'),
        ('.', ''),
      ]);
    });

    test('bare https addresses and <autolinks> become links; trailing punctuation stays out', () {
      final b = pt('Go to https://example.com/x_y_z. Or <https://a.example/>, or www.example.com.');
      expect(markDefs(b), [
        {'_type': 'link', '_key': 'k0m0', 'href': 'https://example.com/x_y_z'},
        {'_type': 'link', '_key': 'k0m1', 'href': 'https://a.example/'},
      ]);
      expect(spans(b), [
        ('Go to ', ''),
        ('https://example.com/x_y_z', 'k0m0'),
        ('. Or ', ''),
        ('https://a.example/', 'k0m1'),
        (', or www.example.com.', ''),
      ]);
    });

    test('an address inside emphasis is linked and emphasised', () {
      final b = pt('*see https://example.com*');
      expect(spans(b), [('see ', 'em'), ('https://example.com', 'em,k0m0')]);
    });

    test('unsafe link targets keep their text and lose the link', () {
      for (final href in ['javascript:alert(1)', 'data:text/html,x', '//evil.example/x', 'vbscript:x']) {
        final b = pt('[click]($href)');
        expect(markDefs(b), isEmpty, reason: href);
        expect(spans(b), [('click', '')], reason: href);
      }
    });

    test('mailto and site paths are linked', () {
      final b = pt('[mail](mailto:me@example.com) [about](/pages/about)');
      expect([for (final d in markDefs(b)) d['href']], ['mailto:me@example.com', '/pages/about']);
    });

    test('a link with an empty text shows its address; a link inside a link is not nested', () {
      expect(spans(pt('[](https://e.example/)')), [('https://e.example/', 'k0m0')]);
      final b = pt('[see https://inner.example](https://outer.example)');
      expect(markDefs(b), [
        {'_type': 'link', '_key': 'k0m0', 'href': 'https://outer.example'},
      ]);
    });

    test('an inline image is a link to it, with its alt text', () {
      final b = pt('Photo: ![a cat](https://example.com/cat.jpg) here');
      expect(spans(b), [('Photo: ', ''), ('a cat', 'k0m0'), (' here', '')]);
    });

    test('brackets that are not a link stay text', () {
      expect(spans(pt('[not a link] (nope) [x]')), [('[not a link] (nope) [x]', '')]);
      expect(spans(pt('[open](https://example.com')), [('[open](', ''), ('https://example.com', 'k0m0')]);
    });
  });

  group('safety and determinism', () {
    test('HTML is never interpreted: tags stay text in the spans', () {
      final b = pt('<script>alert(1)</script>\n\n<b>bold?</b> <img src=x onerror=alert(1)>');
      expect(portableTextPlainText(b), '<script>alert(1)</script>\n<b>bold?</b> <img src=x onerror=alert(1)>');
      expect(jsonEncode(b), isNot(contains('htmlBlock')));
      expect([for (final x in b) x['_type']], everyElement('block'));
    });

    test('the same text gives the same blocks, and every key carries the prefix', () {
      const md = '# T\n\nHello **you** https://x.example\n\n- a\n- b\n\n```\nc\n```\n\n---\n\n![i](https://x.example/i.png)';
      final a = markdownToPortableText(md, keyPrefix: 'nfabc');
      expect(jsonEncode(markdownToPortableText(md, keyPrefix: 'nfabc')), jsonEncode(a));
      final keys = <String>[];
      void collect(Object? v) {
        if (v is Map) {
          if (v['_key'] is String) keys.add(v['_key'] as String);
          v.values.forEach(collect);
        } else if (v is List) {
          v.forEach(collect);
        }
      }

      collect(a);
      expect(keys, isNotEmpty);
      expect(keys, everyElement(startsWith('nfabc')));
      expect(keys.toSet(), hasLength(keys.length), reason: 'keys are unique');
      expect(a.first['_key'], 'nfabc0');
    });

    test('Unicode text, emoji and right-to-left text pass through whole', () {
      const text = 'Café 🎉 שלום **日本語**';
      expect(spans(pt(text)), [('Café 🎉 שלום ', ''), ('日本語', 'strong')]);
    });

    test('plain text of the blocks, for previews', () {
      expect(portableTextPlainText(pt('# Title\n\nSome *text*\n\n```\ncode\n```')), 'Title\nSome text\ncode');
    });
  });
}
