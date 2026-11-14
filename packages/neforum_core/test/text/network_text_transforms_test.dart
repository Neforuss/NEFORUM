// Per-network text transforms (text/network_text_transforms.dart) and the
// over-limit rule: an insert never blocks, each network over its limit says so.
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../characters/catalog_files.dart';
import '../support/test_context.dart';

Post _post(String text, {String? title}) => Post(
      id: 'p',
      text: text,
      title: title,
      createdAt: testNow,
      updatedAt: testNow,
      targets: const [PostTarget(accountId: 'acct-1')],
    );

PostVariant _resolve(String id, Post post, {ResolverOptions options = const ResolverOptions()}) {
  final d = builtinRegistry().require(id).descriptor;
  return VariantResolver(options).resolve(post, post.targets.single, d, account: fakeAccount(id));
}

void main() {
  final registry = builtinRegistry();

  group('which networks get what', () {
    test('every Markdown network in the registry is classified on purpose', () {
      final markdown = {for (final a in registry.all) if (a.descriptor.text.supportsMarkdown) a.id};
      expect(NetworkTextTransforms.dialects.keys.toSet(), markdown);
    });

    test('a network without Markdown gets the text exactly as written', () {
      final ts = bundledCatalog.textStyles;
      final text = '¯\\_(ツ)_/¯ ${ts.apply(TextStyleKind.bold, 'bold')} ① Ⓐ ｆ ㎏ **real** _md_ 👍🏽';
      for (final a in registry.all.where((a) => !a.descriptor.text.supportsMarkdown)) {
        expect(NetworkTextTransforms.adapt(text, a.descriptor), text, reason: a.id);
      }
    });
  });

  test('variation selectors, joined emoji and skin tones go out untouched everywhere: no network is proven to need a change', () {
    const emoji = '❤️ 👨‍👩‍👧 👍🏽 ☺︎ 🏳️‍🌈 1️⃣';
    for (final a in registry.all) {
      expect(NetworkTextTransforms.adapt('Hi $emoji', a.descriptor), 'Hi $emoji', reason: a.id);
    }
  });

  group('CommonMark networks', () {
    final reddit = registry.require('reddit').descriptor;

    test('only kaomoji are escaped: Markdown the user wrote stays Markdown', () {
      const text = '**Big** news ¯\\_(ツ)_/¯ and _this_ (^_^)';
      final out = NetworkTextTransforms.adapt(text, reddit);
      expect(out, r'**Big** news ¯\\\_\(ツ\)\_\/¯ and _this_ \(\^\_\^\)');
      expect(renderedCommonMark(out), contains('news ¯\\_(ツ)_/¯ and'));
      expect(renderedCommonMark(out), endsWith('(^_^)'));
    });

    test('a kaomoji inside code the user wrote is left alone', () {
      expect(NetworkTextTransforms.adapt('`¯\\_(ツ)_/¯`', reddit), '`¯\\_(ツ)_/¯`');
      expect(NetworkTextTransforms.adapt('```\n(^_^)\n```', reddit), '```\n(^_^)\n```');
    });

    test('the longest kaomoji wins where two overlap', () {
      // ┻━┻ ︵ヽ(`Д´)ﾉ︵ ┻━┻ holds (`Д´): escaped once, as the whole.
      const flip = '┻━┻ ︵ヽ(`Д´)ﾉ︵ ┻━┻';
      expect(renderedCommonMark(NetworkTextTransforms.adapt(flip, reddit)), flip);
      expect(NetworkTextTransforms.kaomojiSpans(flip), [(start: 0, end: flip.length)]);
    });

    test('Reddit gets the escapes, the draft keeps the kaomoji as picked, and a title from the first line has none', () {
      final post = _post('¯\\_(ツ)_/¯ Monday again\n\nMore text');
      final v = _resolve('reddit', post);
      expect(renderedCommonMark(v.text), contains('¯\\_(ツ)_/¯ Monday again'), reason: 'shows as picked on Reddit');
      expect(v.text, startsWith(r'¯\\\_\(ツ\)\_\/¯'));
      expect(post.text, startsWith('¯\\_(ツ)_/¯'), reason: 'the draft is never changed');
      expect(v.title, '¯\\_(ツ)_/¯ Monday again', reason: 'titles are plain text');
      expect(_resolve('mastodon', post).text, post.text, reason: 'Mastodon is plain text');
    });

    test('a per-network version is adapted too', () {
      final post = Post(
        id: 'p',
        text: 'main',
        createdAt: testNow,
        updatedAt: testNow,
        targets: const [PostTarget(accountId: 'acct-1', overrides: PostOverrides(text: 'only here (^_^)'))],
      );
      final d = registry.require('lemmy').descriptor;
      final v = const VariantResolver().resolve(post, post.targets.single, d, account: fakeAccount('lemmy'));
      expect(v.text, r'only here \(\^\_\^\)');
    });
  });

  group('over the limit: insert, then warn per network', () {
    // 270 letters and 10 mathematical bold letters: 280 characters as the
    // user sees them. X weighs each bold letter 2, so 290 there.
    final bold = bundledCatalog.textStyles.apply(TextStyleKind.bold, 'NEFORUMXYZ');
    final text = '${'a' * 270}$bold';

    test('the draft is the 280 characters the user sees', () {
      expect(text.runes.length, 280);
      expect(TextCounter.count(text, registry.require('x').descriptor.text), 290);
    });

    test('X shows it is over and why; Mastodon and Bluesky are untouched', () {
      const strict = ResolverOptions(overflow: OverflowStrategy.error);
      final x = _resolve('x', _post(text), options: strict);
      final issue = x.issues.singleWhere((i) => i.code == 'text.too_long');
      expect(issue.severity, IssueSeverity.error);
      expect(issue.message, 'Text is 290/280 characters for ${registry.require('x').descriptor.name}');
      expect(x.text, text, reason: 'inserted, not blocked or cut');
      for (final id in ['mastodon', 'bluesky']) {
        final v = _resolve(id, _post(text), options: strict);
        expect(v.text, text, reason: id);
        expect(v.issues.where((i) => i.field == 'text' && i.severity == IssueSeverity.error), isEmpty, reason: id);
        expect(registry.require(id).validate(v, fakeAccount(id)).where((i) => i.code == 'text.too_long'), isEmpty, reason: id);
      }
      expect(registry.require('x').validate(x, fakeAccount('x')).map((i) => i.code), contains('text.too_long'));
    });

    test('with the default settings X makes a thread of it and says so', () {
      final x = _resolve('x', _post(text));
      expect(x.isThread, isTrue);
      expect(x.issues.map((i) => i.code), contains('text.threaded'));
      expect(x.threadParts.join(), contains(bold.substring(0, 2)), reason: 'the styled letters go out as they are');
    });
  });
}
