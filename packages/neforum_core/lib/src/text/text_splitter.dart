import 'package:characters/characters.dart';

import '../model/platform_descriptor.dart';
import 'text_counter.dart';

/// Splits long text into thread parts that each fit the platform's limit,
/// breaking at paragraph, then sentence, then word boundaries.
class TextSplitter {
  TextSplitter._();

  /// Returns the parts; a single element when the text already fits.
  /// With [numbering] each part gets a ` (i/n)` suffix that is accounted for
  /// in the limit.
  static List<String> split(String text, TextRules rules, {bool numbering = true}) {
    final max = rules.maxLength;
    if (max == null || TextCounter.fits(text, rules)) return [text];

    // Reserve room for the widest possible suffix " (nn/nn)"; refine after.
    var parts = _splitTo(text, rules, max - (numbering ? 8 : 0));
    if (numbering) {
      final suffixLen = ' (${parts.length}/${parts.length})'.length;
      if (suffixLen + 1 > 8) parts = _splitTo(text, rules, max - suffixLen); // >99 parts, unlikely
      return [for (var i = 0; i < parts.length; i++) '${parts[i]} (${i + 1}/${parts.length})'];
    }
    return parts;
  }

  static List<String> _splitTo(String text, TextRules rules, int budget) {
    final out = <String>[];
    var current = StringBuffer();

    void flush() {
      final s = current.toString().trim();
      if (s.isNotEmpty) out.add(s);
      current = StringBuffer();
    }

    bool fits(String candidate) => TextCounter.count(candidate, rules) <= budget;

    for (final paragraph in text.split(RegExp(r'\n{2,}'))) {
      final candidate = current.isEmpty ? paragraph : '$current\n\n$paragraph';
      if (fits(candidate)) {
        current = StringBuffer(candidate);
        continue;
      }
      flush();
      if (fits(paragraph)) {
        current = StringBuffer(paragraph);
        continue;
      }
      // Paragraph alone is too long: sentences.
      for (final sentence in _sentences(paragraph)) {
        final c2 = current.isEmpty ? sentence : '$current $sentence';
        if (fits(c2)) {
          current = StringBuffer(c2);
          continue;
        }
        flush();
        if (fits(sentence)) {
          current = StringBuffer(sentence);
          continue;
        }
        // Sentence alone is too long: words.
        for (final word in sentence.split(RegExp(r'\s+'))) {
          final c3 = current.isEmpty ? word : '$current $word';
          if (fits(c3)) {
            current = StringBuffer(c3);
            continue;
          }
          flush();
          if (fits(word)) {
            current = StringBuffer(word);
            continue;
          }
          // A single "word" longer than the budget (huge URL / no spaces): hard cut by graphemes.
          var chunk = StringBuffer();
          for (final g in word.characters) {
            if (!fits('$chunk$g')) {
              out.add(chunk.toString());
              chunk = StringBuffer();
            }
            chunk.write(g);
          }
          current = chunk;
        }
      }
    }
    flush();
    return out;
  }

  static Iterable<String> _sentences(String paragraph) sync* {
    final re = RegExp(r'[^.!?…]+(?:[.!?…]+["”’)]*|$)', unicode: true);
    var any = false;
    for (final m in re.allMatches(paragraph)) {
      final s = m[0]!.trim();
      if (s.isEmpty) continue;
      any = true;
      yield s;
    }
    if (!any) yield paragraph;
  }

  /// Truncates to fit, appending [ellipsis]. Never cuts inside a grapheme or
  /// a URL.
  static String truncate(String text, TextRules rules, {String ellipsis = '…'}) {
    final max = rules.maxLength;
    if (max == null || TextCounter.fits(text, rules)) return text;
    final chars = text.characters.toList();
    var lo = 0, hi = chars.length;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      final candidate = '${chars.take(mid).join()}$ellipsis';
      if (TextCounter.count(candidate, rules) <= max) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    var cut = chars.take(lo).join();
    final lastSpace = cut.lastIndexOf(RegExp(r'\s'));
    if (lastSpace > cut.length * 0.6) cut = cut.substring(0, lastSpace);
    return '${cut.trimRight()}$ellipsis';
  }
}
