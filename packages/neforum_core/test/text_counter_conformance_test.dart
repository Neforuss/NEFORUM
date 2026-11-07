// X's counter against twitter-text's own conformance file and Unicode's own list
// of emoji. Both files are vendored under test/fixtures with their licence terms:
// twitter_text/validate.yml (Apache-2.0, twitter_text/LICENSE, file last changed
// 2020-03-31) and unicode/emoji-test.txt (18.0, terms in its header).
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../tool/generate_emoji_tables.dart' show emojiTablesFrom;
import 'package:neforum_core/src/text/emoji_tables.dart';

/// Cases in the old v2 section that NEFORUM rightly answers differently: that
/// section predates X's rule that every emoji counts 2, the rule X documents and
/// the v3 section checks. Each entry must still differ, so the list cannot rot.
const Map<String, String> kV2NotApplicable = {
  'Count a mix of single byte single word, and double word unicode characters':
      'v2 wants 16 for a family emoji counted by its code points; the v3 section and X want 7',
  'Count unicode emoji chars outside the basic multilingual plane with skin tone modifiers':
      'v2 wants 9, a skin tone and a joiner counted as code points of their own; the v3 section and X want 4',
};

void main() {
  final conformance = loadYaml(File('test/fixtures/twitter_text/validate.yml').readAsStringSync()) as YamlMap;
  final tests = conformance['tests'] as YamlMap;

  group('twitter-text validate.yml', () {
    for (final section in const ['WeightedTweetsWithDiscountedEmojiCounterTest', 'UnicodeDirectionalMarkerCounterTest']) {
      group(section, () {
        for (final c in tests[section] as YamlList) {
          test(c['description'] as String, () {
            expect(TextCounter.weightedX(c['text'] as String), c['expected']['weightedLength']);
          });
        }
      });
    }

    group('WeightedTweetsCounterTest (v2 rules)', () {
      for (final c in tests['WeightedTweetsCounterTest'] as YamlList) {
        final description = c['description'] as String;
        final want = c['expected']['weightedLength'] as int;
        final why = kV2NotApplicable[description];
        if (why != null) {
          test('not applicable: $description', () {
            expect(TextCounter.weightedX(c['text'] as String), isNot(want), reason: 'no longer differs, so it comes off the list: $why');
          });
        } else {
          test(description, () => expect(TextCounter.weightedX(c['text'] as String), want));
        }
      }

      test('every not-applicable name is a case in the file', () {
        final names = {for (final c in tests['WeightedTweetsCounterTest'] as YamlList) c['description']};
        expect(names, containsAll(kV2NotApplicable.keys));
      });
    });
  });

  group('emoji-test.txt 18.0', () {
    final source = File('test/fixtures/unicode/emoji-test.txt').readAsStringSync();
    final fullyQualified = <String>[];
    for (final line in source.split('\n')) {
      if (line.startsWith('#') || !line.contains('; fully-qualified')) continue;
      fullyQualified.add(String.fromCharCodes(line.split(';').first.trim().split(' ').map((h) => int.parse(h, radix: 16))));
    }

    test('every fully-qualified line counts 2 on X and 1 as graphemes', () {
      expect(fullyQualified.length, greaterThan(3900), reason: 'the file was read');
      final wrong = [
        for (final e in fullyQualified)
          if (TextCounter.weightedX(e) != 2 || TextCounter.graphemes(e) != 1) e.runes.map((r) => r.toRadixString(16)).join(' '),
      ];
      expect(wrong, isEmpty);
    });

    test('every sequence shows as an emoji on a card', () {
      expect([for (final e in fullyQualified) if (!EmojiClusters.showsAsEmoji(e)) e], isEmpty);
    });

    test('the generated tables match the vendored file', () {
      final t = emojiTablesFrom(source);
      expect(kEmojiBaseRanges, t.bases);
      expect(kEmojiPresentationRanges, t.presentation);
    });
  });

  group('NFC, as X counts', () {
    test('a letter and its combining mark count once', () {
      expect(TextCounter.weightedX('Á'), 1);
      expect(TextCounter.weightedX('Á'), 1);
    });

    test('a lone surrogate does not throw', () {
      expect(TextCounter.weightedX('a\uD83D'), greaterThan(0));
    });
  });

  group('a joiner or variation selector alone does not make an emoji (B4)', () {
    // Official weights and regex, computed for the research report.
    const cases = {
      'Sinhala conjunct': ('ක්‍ර', 4),
      'Malayalam chillu': ('ന്‍', 3),
      'CJK with VS16': ('中️', 4),
      'Latin with VS16': ('a️', 3),
      'digit with VS16 but no keycap': ('1️', 3),
      'Latin with a skin tone': ('a\u{1F3FB}', 3),
      'emoji then a dangling joiner': ('\u{1F600}‍', 3),
      'emoji with text presentation': ('\u{1F600}︎', 4),
    };
    cases.forEach((name, c) {
      test('$name counts ${c.$2}', () => expect(TextCounter.weightedX(c.$1), c.$2));
    });

    test('real emoji still count 2', () {
      for (final e in ['❤️', '1️⃣', '1⃣', '\u{1F1FA}\u{1F1F8}', '\u{1F44D}\u{1F3FD}', '©️', '\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}']) {
        expect(TextCounter.weightedX(e), 2, reason: e.runes.map((r) => r.toRadixString(16)).join(' '));
      }
    });

    test('plain symbols stay what they weigh', () {
      expect(TextCounter.weightedX('©'), 1);
      expect(TextCounter.weightedX('1'), 1);
      expect(TextCounter.weightedX('❤'), 2);
    });
  });

  group('which text a card draws in the emoji font', () {
    test('a digit, a plain heart and words stay text', () {
      for (final t in ['1', '#', '©', '❤', 'a', '中', 'ක්‍ර', 'a️']) {
        expect(EmojiClusters.showsAsEmoji(t), isFalse, reason: t);
      }
    });

    test('an emoji newer than the table still shows as one', () {
      expect(EmojiClusters.showsAsEmoji('\u{1FAFE}'), isTrue);
      expect(EmojiClusters.showsAsEmoji('\u{1F600}'), isTrue);
      expect(EmojiClusters.showsAsEmoji('❤️'), isTrue);
    });

    test('mayHoldEmoji is false only for plain ASCII', () {
      expect(EmojiClusters.mayHoldEmoji('hello 123 #tag'), isFalse);
      expect(EmojiClusters.mayHoldEmoji('©'), isTrue);
      expect(EmojiClusters.mayHoldEmoji('\u{1F600}'), isTrue);
    });

    test('characters splits a family as one cluster', () {
      expect('\u{1F468}‍\u{1F469}‍\u{1F467}'.characters.length, 1);
    });
  });
}
