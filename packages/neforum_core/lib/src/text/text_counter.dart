import 'dart:convert';

import 'package:characters/characters.dart';

import '../model/platform_descriptor.dart';
import 'url_detector.dart';

/// Counts text the way each platform does.
class TextCounter {
  TextCounter._();

  static int count(String text, TextRules rules) => switch (rules.counting) {
        CountingRule.graphemes => graphemes(text),
        CountingRule.utf16 => text.length,
        CountingRule.utf8Bytes => utf8Bytes(text),
        CountingRule.weightedX => weightedX(text, urlWeight: rules.urlWeight ?? 23),
        CountingRule.codePointsWithUrlWeight => codePointsWithUrlWeight(
            text,
            urlWeight: rules.urlWeight ?? 23,
            mentionCountsDomain: rules.mentionCountsDomain,
          ),
      };

  /// Remaining characters, or `null` when the platform has no limit.
  static int? remaining(String text, TextRules rules) =>
      rules.maxLength == null ? null : rules.maxLength! - count(text, rules);

  static bool fits(String text, TextRules rules) => rules.maxLength == null || count(text, rules) <= rules.maxLength!;

  static int graphemes(String text) => text.characters.length;

  static int utf8Bytes(String text) => utf8.encode(text).length;

  /// twitter-text v3 weighted length (scaled back to "characters").
  /// Latin, Latin-1, Latin Extended, Greek, Cyrillic, ... (U+0000–U+10FF)
  /// and the general-punctuation ranges weigh 1; everything else weighs 2;
  /// every emoji grapheme weighs 2; every URL weighs [urlWeight].
  static int weightedX(String text, {int urlWeight = 23}) {
    var weighted = 0;
    var cursor = 0;
    for (final url in UrlDetector.find(text)) {
      weighted += _weightedSegment(text.substring(cursor, url.start));
      weighted += urlWeight * 100;
      cursor = url.end;
    }
    weighted += _weightedSegment(text.substring(cursor));
    return (weighted + 99) ~/ 100;
  }

  static int _weightedSegment(String segment) {
    var w = 0;
    for (final cluster in segment.characters) {
      if (_isEmojiCluster(cluster)) {
        w += 200;
        continue;
      }
      for (final r in cluster.runes) {
        w += _runeWeight(r);
      }
    }
    return w;
  }

  static int _runeWeight(int r) {
    if (r <= 0x10FF) return 100;
    if (r >= 0x2000 && r <= 0x200D) return 100;
    if (r >= 0x2010 && r <= 0x201F) return 100;
    if (r >= 0x2032 && r <= 0x2037) return 100;
    return 200;
  }

  static bool _isEmojiCluster(String cluster) {
    final runes = cluster.runes.toList();
    if (runes.length == 1) {
      final r = runes.single;
      return (r >= 0x1F000 && r <= 0x1FAFF) || (r >= 0x2600 && r <= 0x27BF) || r == 0x2B50 || r == 0x2B55 || r == 0x3030 || r == 0x303D;
    }
    // Multi-code-point clusters with emoji markers: ZWJ sequences, VS16,
    // skin tones, keycaps, flags (regional indicators), tag sequences.
    return runes.any((r) =>
        r == 0x200D ||
        r == 0xFE0F ||
        r == 0x20E3 ||
        (r >= 0x1F3FB && r <= 0x1F3FF) ||
        (r >= 0x1F1E6 && r <= 0x1F1FF) ||
        (r >= 0xE0020 && r <= 0xE007F) ||
        (r >= 0x1F000 && r <= 0x1FAFF));
  }

  /// Mastodon-style: one per code point, URLs count as [urlWeight],
  /// `@user@domain` counts as `@user` when [mentionCountsDomain] is false.
  static int codePointsWithUrlWeight(String text, {int urlWeight = 23, bool mentionCountsDomain = false}) {
    var total = 0;
    var cursor = 0;
    for (final url in UrlDetector.find(text)) {
      total += _codePoints(text.substring(cursor, url.start), mentionCountsDomain);
      total += urlWeight;
      cursor = url.end;
    }
    total += _codePoints(text.substring(cursor), mentionCountsDomain);
    return total;
  }

  static final RegExp _remoteMention = RegExp(r'(?<![\w/])@([a-z0-9_.-]+)@([a-z0-9.-]+\.[a-z]{2,})', caseSensitive: false);

  static int _codePoints(String s, bool mentionCountsDomain) {
    final collapsed = mentionCountsDomain ? s : s.replaceAllMapped(_remoteMention, (m) => '@${m[1]}');
    return collapsed.runes.length;
  }
}
