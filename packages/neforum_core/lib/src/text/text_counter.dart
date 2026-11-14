import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:unorm_dart/unorm_dart.dart' show nfc;

import '../model/platform_descriptor.dart';
import 'emoji_clusters.dart';
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
        CountingRule.codePoints => codePoints(text),
      };

  /// Remaining characters, or `null` when the platform has no limit.
  static int? remaining(String text, TextRules rules) =>
      rules.maxLength == null ? null : rules.maxLength! - count(text, rules);

  static bool fits(String text, TextRules rules) => rules.maxLength == null || count(text, rules) <= rules.maxLength!;

  static int graphemes(String text) => text.characters.length;

  static int utf8Bytes(String text) => utf8.encode(text).length;

  /// One per code point, as JavaScript's `[...text].length` counts: a
  /// surrogate pair is one, a combining mark or an emoji joiner is one more.
  static int codePoints(String text) => text.runes.length;

  /// twitter-text v3 weighted length (scaled back to "characters"), counted
  /// after NFC as X does. Latin, Latin-1, Latin Extended, Greek, Cyrillic, ...
  /// (U+0000–U+10FF) and the general-punctuation ranges weigh 1; everything else
  /// weighs 2; an emoji weighs 2 however many code points make it; every URL
  /// weighs [urlWeight]. Checked against twitter-text's own conformance file
  /// (test/text_counter_conformance_test.dart).
  static int weightedX(String text, {int urlWeight = 23}) {
    final normalized = nfc(text);
    var weighted = 0;
    var cursor = 0;
    for (final url in UrlDetector.find(normalized)) {
      weighted += _weightedSegment(normalized.substring(cursor, url.start));
      weighted += urlWeight * 100;
      cursor = url.end;
    }
    weighted += _weightedSegment(normalized.substring(cursor));
    return (weighted + 99) ~/ 100;
  }

  static int _weightedSegment(String segment) {
    var w = 0;
    for (final cluster in segment.characters) {
      if (EmojiClusters.isSequence(cluster)) {
        w += 200;
        continue;
      }
      for (final r in cluster.runes) {
        w += _runeWeight(r);
      }
    }
    return w;
  }

  /// One code point on its own: an emoji needs no case of its own, since every
  /// one above the ranges below already weighs 2.
  static int _runeWeight(int r) {
    if (r <= 0x10FF) return 100;
    if (r >= 0x2000 && r <= 0x200D) return 100;
    if (r >= 0x2010 && r <= 0x201F) return 100;
    if (r >= 0x2032 && r <= 0x2037) return 100;
    return 200;
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
