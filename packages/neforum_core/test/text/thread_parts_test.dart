import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

/// A network with a 50-character limit, with or without threads.
PlatformDescriptor _network({required bool threads, int? max = 50}) => PlatformDescriptor(
      id: threads ? 'threaded' : 'single',
      name: threads ? 'Threaded' : 'Single',
      tiers: const {PlatformTier.openApi, PlatformTier.handoff},
      defaultTier: PlatformTier.openApi,
      text: TextRules(maxLength: max, supportsThreads: threads),
      media: const MediaRules(),
      accountRequirements: '',
      apiCostSummary: '',
    );

Post _post(String text, List<String> parts, {String? link, List<String> tags = const [], PostOverrides? overrides}) => Post(
      id: 'p',
      text: text,
      additionalParts: parts,
      link: link,
      tags: tags,
      createdAt: testNow,
      updatedAt: testNow,
      targets: [PostTarget(accountId: 'acct-1', overrides: overrides ?? const PostOverrides())],
    );

PostVariant _resolve(Post post, PlatformDescriptor d,
        {PlatformTier tier = PlatformTier.openApi, ResolverOptions options = const ResolverOptions()}) =>
    VariantResolver(options).resolve(post, post.targets.single, d, account: fakeAccount(d.id, tier: tier));

void main() {
  final threaded = _network(threads: true);
  final single = _network(threads: false);

  group('TextSplitter.splitParts', () {
    const rules = TextRules(maxLength: 20);

    test('numbers every part, counted across the thread', () {
      expect(TextSplitter.splitParts(['One', 'Two', 'Three'], rules), ['One (1/3)', 'Two (2/3)', 'Three (3/3)']);
      expect(TextSplitter.splitParts(['One', 'Two'], rules, numbering: false), ['One', 'Two']);
    });

    test('a part that only fits without the suffix is split, and the numbers follow', () {
      // 16 characters: fits 20, but not with " (1/2)".
      final out = TextSplitter.splitParts(['Sixteen chars ok', 'Short'], rules);
      expect(out, hasLength(3));
      expect(out.last, 'Short (3/3)');
      for (final p in out) {
        expect(p.length, lessThanOrEqualTo(20));
      }
    });

    test('long parts are split at word boundaries; the order is kept', () {
      final out = TextSplitter.splitParts(['alpha beta gamma delta epsilon', 'zeta'], rules, numbering: false);
      expect(out, ['alpha beta gamma', 'delta epsilon', 'zeta']);
    });

    test('a single part behaves like split', () {
      expect(TextSplitter.splitParts(['fits'], rules), ['fits']);
      expect(TextSplitter.splitParts(['alpha beta gamma delta epsilon'], rules), TextSplitter.split('alpha beta gamma delta epsilon', rules));
    });

    test('truncate can keep room for a suffix', () {
      expect(TextSplitter.truncate('alpha beta gamma delta', rules, reserve: 6).length, lessThanOrEqualTo(14));
      expect(TextSplitter.truncate('short', rules, reserve: 6), 'short');
    });
  });

  group('resolver: parts the user wrote', () {
    test('a network with threads gets one post per part, numbered', () {
      final v = _resolve(_post('First', ['Second', 'Third']), threaded);
      expect(v.threadParts, ['First (1/3)', 'Second (2/3)', 'Third (3/3)']);
      expect(v.text, 'First (1/3)');
      expect(v.issues.map((i) => i.code), contains('text.threaded'));

      final plain = _resolve(_post('First', ['Second']), threaded, options: const ResolverOptions(threadNumbering: false));
      expect(plain.threadParts, ['First', 'Second']);
    });

    test('a part longer than the limit is split further, numbering counts every final part', () {
      final long = 'This second part is far too long for one post on this network';
      final v = _resolve(_post('Intro', [long, 'End']), threaded);
      expect(v.threadParts.length, greaterThan(3));
      expect(v.threadParts.first, 'Intro (1/${v.threadParts.length})');
      expect(v.threadParts.last, 'End (${v.threadParts.length}/${v.threadParts.length})');
      for (final p in v.threadParts) {
        expect(p.length, lessThanOrEqualTo(50));
      }
      expect(v.hasErrors, isFalse);
    });

    test('the link and hashtags go at the end of the last part', () {
      final v = _resolve(_post('First', ['Last'], link: 'https://ex.org', tags: ['news']), _network(threads: true, max: 100),
          options: const ResolverOptions(threadNumbering: false));
      expect(v.threadParts, ['First', 'Last\n\nhttps://ex.org\n\n#news']);

      // Already in an earlier part: not added again.
      final again = _resolve(_post('See https://ex.org #news', ['Last'], link: 'https://ex.org', tags: ['news']),
          _network(threads: true, max: 100), options: const ResolverOptions(threadNumbering: false));
      expect(again.threadParts, ['See https://ex.org #news', 'Last']);
    });

    test('a network without threads gets the parts joined with a blank line', () {
      final v = _resolve(_post('First', ['Second']), single);
      expect(v.isThread, isFalse);
      expect(v.text, 'First\n\nSecond');
      expect(v.issues.map((i) => i.code), contains('text.parts_joined'));
    });

    test('joined parts that are too long follow the usual overflow rule', () {
      final words = 'word ' * 12;
      expect(_resolve(_post(words, [words]), single).issues.map((i) => i.code), contains('text.too_long'));
      final cut = _resolve(_post(words, [words]), single, options: const ResolverOptions(overflow: OverflowStrategy.threadOrTruncate));
      expect(cut.text.length, lessThanOrEqualTo(50));
      expect(cut.text, endsWith('…'));
    });

    test('hand-offs get the parts joined, also on networks with threads', () {
      final v = _resolve(_post('First', ['Second']), _network(threads: true, max: 500), tier: PlatformTier.handoff);
      expect(v.isThread, isFalse);
      expect(v.text, 'First\n\nSecond');
    });

    test('a per-network version replaces every part', () {
      final v = _resolve(_post('First', ['Second'], overrides: const PostOverrides(text: 'Own words')), threaded);
      expect(v.isThread, isFalse);
      expect(v.text, 'Own words');
    });

    test('empty parts are left out; one part left is not a thread', () {
      final v = _resolve(_post('', ['  ', 'Only words']), threaded);
      expect(v.isThread, isFalse);
      expect(v.text, 'Only words');
      expect(v.issues.map((i) => i.code), isNot(contains('text.threaded')));
    });

    test('"always shorten" truncates long parts but keeps the thread', () {
      final long = 'This second part is far too long for one post on this network';
      final v = _resolve(_post('Intro', [long]), threaded, options: const ResolverOptions(overflow: OverflowStrategy.truncate));
      expect(v.threadParts, hasLength(2));
      expect(v.threadParts[1], endsWith('… (2/2)'));
      expect(v.threadParts[1].length, lessThanOrEqualTo(50));
      expect(v.issues.map((i) => i.code), contains('text.truncated'));
    });

    test('"never change my text" reports a part that is too long', () {
      final long = 'This second part is far too long for one post on this network';
      final v = _resolve(_post('Intro', [long]), threaded, options: const ResolverOptions(overflow: OverflowStrategy.error));
      expect(v.threadParts, hasLength(2));
      expect(v.issues.where((i) => i.code == 'text.too_long').single.message, startsWith('Part 2 is'));
    });

    test('a title is derived from the first part', () {
      final d = PlatformDescriptor(
        id: 'titled',
        name: 'Titled',
        tiers: const {PlatformTier.openApi},
        defaultTier: PlatformTier.openApi,
        text: const TextRules(maxLength: 500, titleSupported: true, titleRequired: true),
        media: const MediaRules(),
        accountRequirements: '',
        apiCostSummary: '',
      );
      expect(_resolve(_post('', ['Headline\nbody', 'More']), d).title, 'Headline');
    });

    test('posts without parts resolve as before', () {
      final v = _resolve(_post('Just one post', const []), threaded);
      expect(v.isThread, isFalse);
      expect(v.text, 'Just one post');
      expect(v.issues.map((i) => i.code), isNot(contains('text.parts_joined')));
    });
  });
}
