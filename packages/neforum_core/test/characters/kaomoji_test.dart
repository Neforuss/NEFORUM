// The curated kaomoji: the set's house rules, the builder, and that each one
// shows as itself on the Markdown networks (CommonMark, Discord, NEFORUM's
// Telegram and Matrix formatting, Misskey's MFM).
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/chat/chat_common.dart';
import 'package:test/test.dart';

import 'catalog_files.dart';

/// The MFM syntax that would change how a kaomoji shows on Misskey: bold,
/// italic of letters, strike, code, functions, inline math, tags, custom
/// emoji, mentions, hashtags, quotes, links and search.
final List<RegExp> _mfmMarkup = [
  RegExp(r'\*\*|__|~~|`[^`´\n]+`|\$\[|\\\(|\\\['),
  RegExp(r'<(/?)(small|i|b|s|center|plain|sup|sub)>'),
  RegExp(r'(?<![a-z0-9])\*[a-z0-9 ]+\*', caseSensitive: false),
  RegExp(r'(?<![a-z0-9])_[a-z0-9 ]+_', caseSensitive: false),
  RegExp(r':[a-z0-9_+-]+:', caseSensitive: false),
  RegExp(r'[@#]'),
  RegExp(r'^>'),
  RegExp(r'https?://'),
  RegExp(r'\[.*\]\(.*\)'),
  RegExp(r'(検索|search)$', caseSensitive: false),
];

void main() {
  final all = allKaomoji;

  group('the set', () {
    test('is big enough to be worth a tab, in named groups with search words', () {
      expect(all.length, greaterThan(300));
      expect(kKaomojiGroups.map((g) => g.id).toSet(), hasLength(kKaomojiGroups.length));
      for (final g in kKaomojiGroups) {
        expect(g.kaomoji, isNotEmpty, reason: g.id);
        expect(g.keywords, isNotEmpty, reason: g.id);
        expect(g.title, isNot(contains('—')), reason: 'no em dashes in what the user reads');
      }
    });

    test('house rules: one line, no outer spaces, no ASCII # or @, each once', () {
      final seen = <String>{};
      for (final k in all) {
        expect(k, isNot(contains('\n')), reason: k);
        expect(k.trim(), k, reason: 'outer spaces: "$k"');
        expect(k, isNot(contains(RegExp('[#@]'))), reason: '$k: use the fullwidth ＃ ＠');
        expect(seen.add(k), isTrue, reason: '$k twice');
      }
      for (final g in kKaomojiGroups) {
        expect(g.kaomoji.toSet(), hasLength(g.kaomoji.length), reason: '${g.id} lists one twice');
      }
    });

    test('Misskey: every kaomoji MFM would read as markup goes in <plain>; ones it cannot are left as they are', () {
      var wrapped = 0;
      for (final k in all) {
        final out = NetworkTextTransforms.plainKaomojiForMfm(k);
        if (_mfmMarkup.any((r) => r.hasMatch(k)) || k.contains('`')) expect(out, '<plain>$k</plain>', reason: k);
        if (out != k) {
          wrapped++;
          expect(out, '<plain>$k</plain>');
        }
      }
      expect(wrapped, lessThan(all.length), reason: 'kaomoji with no markup characters cost nothing');
      expect(NetworkTextTransforms.plainKaomojiForMfm('ʕ•ᴥ•ʔ'), 'ʕ•ᴥ•ʔ');
    });

    test('no mention or hashtag starts inside a kaomoji, on Misskey or anywhere', () {
      for (final k in all) {
        expect(_mfmMarkup[5].hasMatch(k), isFalse, reason: k);
      }
    });

    test('the bundled catalog has them all, with their group as name', () {
      final catalog = [for (final g in bundledCatalog.groups(CharacterTab.kaomoji)) ...g.entries];
      expect(catalog.map((e) => e.text).toSet(), all.toSet());
      expect(catalog.firstWhere((e) => e.text == '¯\\_(ツ)_/¯').name, 'Shrug');
    });
  });

  group('the builder', () {
    test('puts the parts in order', () {
      expect(
        KaomojiBuilder.build(arm: KaomojiBuilder.arms[1], edge: KaomojiBuilder.edges[0], eye: KaomojiBuilder.eyes[2], mouth: '‿'),
        'ヽ(◕‿◕)ﾉ',
      );
      expect(KaomojiBuilder.build(arm: KaomojiBuilder.arms[0], edge: KaomojiBuilder.edges[2], eye: KaomojiBuilder.eyes[1], mouth: 'ᴥ'), 'ʕ•ᴥ•ʔ');
    });

    test('every part is one line with no outer spaces', () {
      for (final p in [...KaomojiBuilder.arms, ...KaomojiBuilder.edges, ...KaomojiBuilder.eyes]) {
        for (final s in [p.left, p.right]) {
          expect(s.trim(), s);
          expect(s, isNot(contains(RegExp(r'[\n#@]'))));
        }
      }
      expect(KaomojiBuilder.mouths.toSet(), hasLength(KaomojiBuilder.mouths.length));
    });
  });

  group('on Markdown networks', () {
    test('CommonMark shows each escaped kaomoji as itself, alone and mid-sentence', () {
      for (final k in all) {
        final escaped = NetworkTextTransforms.escapeKaomojiForCommonMark(k);
        expect(renderedCommonMark(escaped), k, reason: 'alone: $k as $escaped');
        expect(renderedCommonMark('ok $escaped ok', gfm: true), 'ok $k ok', reason: 'GFM, mid-sentence: $k');
      }
    });

    test('without the escapes some would break: the reason this exists', () {
      expect(renderedCommonMark('¯\\_(ツ)_/¯'), isNot('¯\\_(ツ)_/¯'), reason: 'the arm is eaten');
      expect(renderedCommonMark('(＃`Д´) and (´｡• ω •｡`) ♡'), isNot('(＃`Д´) and (´｡• ω •｡`) ♡'), reason: 'two backticks make code');
      final broken = [for (final k in all) if (renderedCommonMark('a $k a', gfm: true) != 'a $k a') k];
      expect(broken, isNotEmpty);
    });

    test('two kaomoji with a backtick each stay kaomoji, not code', () {
      const text = '(＃`Д´) then (´｡• ω •｡`) ♡';
      expect(renderedCommonMark(NetworkTextTransforms.escapeKaomojiForCommonMark(text)), text);
    });

    test('Telegram and Matrix formatting leaves every kaomoji alone, beside real Markdown', () {
      for (final k in all) {
        expect(chatMarkdownToHtml(k), isNull, reason: 'no Markdown in $k: it goes as plain text');
        final html = chatMarkdownToHtml('**hi** $k _there_ $k')!;
        expect(html, '<b>hi</b> ${chatEscapeHtml(k)} <i>there</i> ${chatEscapeHtml(k)}', reason: k);
        expect(visibleText(chatMarkdownToHtml('$k\n**b**', brLineBreaks: true)!.replaceAll('<br>', '\n')), '$k\nb');
      }
    });

    test('Misskey: two kaomoji with a backtick each never make code; code the user wrote is left alone', () {
      const text = '(´▽`) and (＃`Д´) and ʕ•ᴥ•ʔ';
      expect(NetworkTextTransforms.plainKaomojiForMfm(text), '<plain>(´▽`)</plain> and <plain>(＃`Д´)</plain> and ʕ•ᴥ•ʔ');
      expect(NetworkTextTransforms.plainKaomojiForMfm('`code (´▽`)`'), '`code (´▽`)`');
      expect(NetworkTextTransforms.plainKaomojiForMfm('m(_ _)m'), '<plain>m(_ _)m</plain>', reason: 'an italic space on Misskey otherwise');
    });

    test('without the guard Telegram would italicise (*^▽^*)', () {
      expect(chatMarkdownToHtml('(*^▽^*)'), isNull);
      expect(chatMarkdownToHtml('(*^x^*)'), '(<i>^x^</i>)', reason: 'a lookalike that is not in the set is Markdown');
    });
  });
}
