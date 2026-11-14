import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

MediaAttachment _image(String id, {String? derivedFrom, bool generated = false}) => MediaAttachment(
      id: id,
      path: '/m/$id.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: 64,
      width: 1080,
      height: 1080,
      derivedFrom: derivedFrom,
      generated: generated,
    );

PlatformDescriptor _network(ParagraphMediaStyle style, {int? maxLength, bool threads = false, int maxImages = 10}) => PlatformDescriptor(
      id: style.name,
      name: 'Net ${style.name}',
      tiers: const {PlatformTier.openApi, PlatformTier.handoff},
      defaultTier: PlatformTier.openApi,
      text: TextRules(maxLength: maxLength, supportsThreads: threads, linkInText: true, supportsHashtags: true),
      media: MediaRules(maxImages: maxImages, maxVideos: maxImages, allowsMixedImageVideo: true, paragraphMedia: style),
      accountRequirements: '',
      apiCostSummary: '',
    );

const _text = 'Intro line.\n\nFirst place.\n\nSecond place, with two views.\n\nThanks for reading.';

Post _post({
  String text = _text,
  List<MediaAttachment>? media,
  ParagraphMediaLinks links = const {1: ['a'], 2: ['b', 'c']},
  List<String> additionalParts = const [],
  PostOverrides overrides = const PostOverrides(),
  String? link,
  List<String> tags = const [],
}) =>
    Post(
      id: 'p',
      text: text,
      media: media ?? [_image('c'), _image('a'), _image('d'), _image('b')],
      paragraphMedia: links,
      additionalParts: additionalParts,
      link: link,
      tags: tags,
      createdAt: testNow,
      updatedAt: testNow,
      targets: [PostTarget(accountId: 'acct-1', overrides: overrides)],
    );

PostVariant _resolve(Post post, PlatformDescriptor d, {PlatformTier tier = PlatformTier.openApi, ResolverOptions options = const ResolverOptions()}) =>
    VariantResolver(options).resolve(post, post.targets.single, d, account: fakeAccount(d.id, tier: tier));

List<String> _ids(Iterable<MediaAttachment> media) => [for (final m in media) m.id];

void main() {
  group('ParagraphMedia.split', () {
    test('blocks between blank lines, trimmed, blank ones left out', () {
      expect(ParagraphMedia.split(_text), ['Intro line.', 'First place.', 'Second place, with two views.', 'Thanks for reading.']);
      expect(ParagraphMedia.split('\n\n  a\nb  \n \n\n\nc\r\n\r\nd\n'), ['a\nb', 'c', 'd']);
      expect(ParagraphMedia.split('   \n\n'), isEmpty);
    });

    test('a blank line inside a code block does not end the paragraph', () {
      expect(ParagraphMedia.split('Code:\n```\nx = 1\n\ny = 2\n```\n\nAfter'), ['Code:\n```\nx = 1\n\ny = 2\n```', 'After']);
      expect(ParagraphMedia.split('inline ```x``` here\n\nnext'), ['inline ```x``` here', 'next']);
    });
  });

  group('links', () {
    test('JSON round trip; empty is left out of the post, so older posts read unchanged', () {
      final post = _post();
      final json = post.toJson();
      expect(json['paragraphMedia'], {'1': ['a'], '2': ['b', 'c']});
      final back = Post.fromJson(json);
      expect(back.paragraphMedia, {1: ['a'], 2: ['b', 'c']});
      expect(back.hasParagraphMedia, isTrue);
      final plain = _post(links: const {});
      expect(plain.toJson().containsKey('paragraphMedia'), isFalse);
      expect(Post.fromJson(plain.toJson()).paragraphMedia, isEmpty);
      expect(ParagraphMedia.fromJson('junk'), isEmpty);
      expect(ParagraphMedia.fromJson({'x': ['a'], '1': 'b', '2': [3, 'c']}), {2: ['c']});
    });

    test('a thread does not use them', () {
      expect(_post(additionalParts: ['More']).hasParagraphMedia, isFalse);
    });

    test('link: a file belongs to one paragraph, the last one it was given to', () {
      var links = ParagraphMedia.link(const {}, 0, ['a', 'b']);
      expect(links, {0: ['a', 'b']});
      links = ParagraphMedia.link(links, 2, ['b']);
      expect(links, {0: ['a'], 2: ['b']});
      links = ParagraphMedia.link(links, 0, const []);
      expect(links, {2: ['b']});
      expect(ParagraphMedia.paragraphOf(links, 'b'), 2);
      expect(ParagraphMedia.paragraphOf(links, 'a'), isNull);
      expect(ParagraphMedia.withoutMedia(links, 'b'), isEmpty);
    });

    test('normalized drops paragraphs past the end, files gone, and repeats', () {
      expect(ParagraphMedia.normalized({3: ['a'], 0: ['a', 'b', 'b'], 1: ['z']}, paragraphs: 2, mediaIds: {'a', 'b'}), {0: ['a', 'b']});
    });
  });

  group('remap while typing', () {
    const links = {0: ['a'], 1: ['b']};
    test('typing inside a paragraph keeps its links', () {
      expect(ParagraphMedia.remap('One\n\nTwo', 'One more\n\nTwo', links), links);
    });
    test('a paragraph added above moves the links down with their paragraphs', () {
      expect(ParagraphMedia.remap('One\n\nTwo', 'New\n\nOne\n\nTwo', links), {1: ['a'], 2: ['b']});
    });
    test('splitting a paragraph keeps the links on the piece most like it', () {
      // A blank line after "X": the link stays with "One", the longer match.
      expect(ParagraphMedia.remap('X\nOne\n\nTwo', 'X\n\nOne\n\nTwo', {0: ['a'], 1: ['b']}), {1: ['a'], 2: ['b']});
      expect(ParagraphMedia.remap('Hello world\n\nTwo', 'Hello\n\nworld\n\nTwo', links), {0: ['a'], 2: ['b']});
    });
    test('merging two paragraphs merges their links; deleting one drops its', () {
      expect(ParagraphMedia.remap('One\n\nTwo', 'One\nTwo', links), {0: ['a', 'b']});
      expect(ParagraphMedia.remap('One\n\nTwo\n\nThree', 'One\n\nThree', {1: ['b'], 2: ['c']}), {1: ['c']});
    });
  });

  group('sections and markers', () {
    final media = [_image('a'), _image('b'), _image('c'), _image('x')];
    const links = {1: ['a'], 2: ['b', 'c']};

    test('each linked paragraph closes a section; files on no paragraph go at the end', () {
      final s = ParagraphMedia.sections(_text, links, media);
      expect([for (final x in s) x.text], ['Intro line.\n\nFirst place.', 'Second place, with two views.', 'Thanks for reading.']);
      expect([for (final x in s) _ids(x.media)], [
        ['a'],
        ['b', 'c'],
        ['x'],
      ]);
    });

    test('no links in the media: one section with everything', () {
      final s = ParagraphMedia.sections(_text, links, [_image('q')]);
      expect(s.single.text, _text);
      expect(_ids(s.single.media), ['q']);
    });

    test('a copy made from a file stands for it', () {
      final s = ParagraphMedia.sections(_text, links, [_image('a-fit', derivedFrom: 'a'), _image('b'), _image('c')]);
      expect(_ids(s.first.media), ['a-fit']);
    });

    test('markers count the files as the post carries them', () {
      expect(ParagraphMedia.withMarkers(_text, links, media),
          'Intro line.\n\nFirst place. (1/4)\n\nSecond place, with two views. (2-3/4)\n\nThanks for reading.');
      expect(ParagraphMedia.withMarkers('A\n\nB', const {0: ['a', 'c']}, [_image('a'), _image('b'), _image('c')]), 'A (1, 3/3)\n\nB');
      expect(ParagraphMedia.withMarkers(_text, links, [_image('a')]), _text, reason: 'one file: nothing to tell apart');
    });

    test('ordered: linked files in paragraph order, then the rest in their order', () {
      expect(_ids(ParagraphMedia.ordered([_image('x'), _image('c'), _image('a'), _image('b')], links)), ['a', 'b', 'c', 'x']);
    });

    test('wordsByMedia: the first file of each section carries its words; the end goes with the last', () {
      final words = ParagraphMedia.wordsByMedia(_text, links, [_image('a'), _image('b'), _image('c')]);
      expect(words, {
        'a': 'Intro line.\n\nFirst place.',
        'b': 'Second place, with two views.\n\nThanks for reading.',
      });
      expect(ParagraphMedia.wordsByMedia(_text, const {}, [_image('a')]), isEmpty);
    });
  });

  group('resolver', () {
    test('no links: every network gets the post exactly as before (regression)', () {
      for (final style in ParagraphMediaStyle.values) {
        final d = _network(style);
        final withLinks = _resolve(_post(links: const {}), d);
        expect(withLinks.text, _text);
        expect(_ids(withLinks.media), ['c', 'a', 'd', 'b']);
        expect(withLinks.paragraphMedia, isEmpty);
        expect(withLinks.issues.map((i) => i.code), isNot(contains('media.paragraphs')));
      }
    });

    test('a network that does not show links gets the post as before, links or not', () {
      final v = _resolve(_post(), _network(ParagraphMediaStyle.none));
      expect(v.text, _text);
      expect(_ids(v.media), ['c', 'a', 'd', 'b']);
      expect(v.paragraphMedia, isEmpty);
    });

    test('markers: files in paragraph order and numbered after their paragraphs', () {
      final v = _resolve(_post(), _network(ParagraphMediaStyle.markers, maxLength: 2200));
      expect(_ids(v.media), ['a', 'b', 'c', 'd']);
      expect(v.text, 'Intro line.\n\nFirst place. (1/4)\n\nSecond place, with two views. (2-3/4)\n\nThanks for reading.');
      expect(v.paragraphMedia, {1: ['a'], 2: ['b', 'c']});
      expect(v.issues.map((i) => i.code), contains('media.paragraphs'));
    });

    test('markers: the link and hashtags still go at the end', () {
      final v = _resolve(_post(link: 'https://example.org/x', tags: ['trip']), _network(ParagraphMediaStyle.markers, maxLength: 2200));
      expect(v.text, endsWith('Thanks for reading.\n\nhttps://example.org/x\n\n#trip'));
      expect(v.text, contains('First place. (1/4)'));
    });

    test('markers that would make the text too long are left out, the order stays', () {
      final text = '${'a' * 40}\n\n${'b' * 40}';
      final v = _resolve(
          _post(text: text, media: [_image('b1'), _image('a1')], links: const {0: ['a1'], 1: ['b1']}), _network(ParagraphMediaStyle.markers, maxLength: 84));
      expect(v.text, text);
      expect(_ids(v.media), ['a1', 'b1']);
      expect(v.issues.map((i) => i.code), contains('media.paragraph_numbers'));
    });

    test('sections: links on the variant, the long text is not made a thread', () {
      final long = 'P1 ${'x' * 60}\n\nP2 ${'y' * 60}';
      final v = _resolve(_post(text: long, links: const {0: ['a'], 1: ['b']}), _network(ParagraphMediaStyle.sections, maxLength: 80, threads: true));
      expect(v.threadParts, isEmpty);
      expect(v.text, long);
      expect(v.hasParagraphMedia, isTrue);
      expect([for (final s in v.paragraphSections) _ids(s.media)], [
        ['a'],
        ['b', 'c', 'd'],
      ]);
      // The adapter cuts each section to messages, so no length error.
      expect(RulesValidator.validate(v, _network(ParagraphMediaStyle.sections, maxLength: 80, threads: true)).map((i) => i.code),
          isNot(contains('text.too_long')));
    });

    test('sections: a hand-off is one share, so the links are not used', () {
      final v = _resolve(_post(), _network(ParagraphMediaStyle.sections), tier: PlatformTier.handoff);
      expect(v.paragraphMedia, isEmpty);
      expect(_ids(v.media), ['c', 'a', 'd', 'b']);
    });

    test('a per-network version, a thread or the text card alone turn the links off', () {
      final d = _network(ParagraphMediaStyle.markers, maxLength: 2200);
      expect(_resolve(_post(overrides: const PostOverrides(text: 'Own words')), d).paragraphMedia, isEmpty);
      expect(_resolve(_post(additionalParts: ['Part two']), d).paragraphMedia, isEmpty);
      expect(_ids(_resolve(_post(additionalParts: ['Part two']), d).media), ['c', 'a', 'd', 'b']);
    });

    test('a fitted copy keeps its paragraph; the story frames follow the paragraphs too', () {
      final post = _post(media: [
        _image('c'),
        _image('a'),
        _image('b'),
        _image('a-fit', derivedFrom: 'a', generated: true),
        _image('s-c', derivedFrom: 'c', generated: true),
        _image('s-a', derivedFrom: 'a', generated: true),
      ]);
      final withCopies = post.withTarget(PostTarget(
        accountId: 'acct-1',
        overrides: const PostOverrides(mediaIds: ['c', 'a-fit', 'b'], storyMediaIds: ['s-c', 's-a'], extra: {'placement': 'feedAndStory'}),
      ));
      final v = _resolve(withCopies, _network(ParagraphMediaStyle.markers, maxLength: 2200));
      expect(_ids(v.media), ['a-fit', 'b', 'c']);
      expect(_ids(v.storyMedia), ['s-a', 's-c']);
      expect(v.text, contains('First place. (1/3)'));
      expect(v.text, contains('two views. (2-3/3)'));
    });

    test('files that go on in a series are not numbered in the first post', () {
      final v = _resolve(_post(), _network(ParagraphMediaStyle.markers, maxLength: 2200, maxImages: 2),
          options: const ResolverOptions(threadNumbering: false));
      expect(_ids(v.media), ['a', 'b']);
      expect(v.text, contains('First place. (1/2)'));
      expect(v.text, contains('two views. (2/2)'), reason: 'c went on to the next post');
      expect(v.seriesPosts.single.paragraphMedia, isEmpty);
    });
  });
}
