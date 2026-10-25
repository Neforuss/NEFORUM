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
      return [for (var i = 0; i < parts.length; i++) '${parts[i]}${_label(i, parts.length)}'];
    }
    return parts;
  }

  /// Turns the parts a user wrote into thread parts that each fit: a part
  /// that is too long is split further, as [split] does. With [numbering]
  /// every final part gets a ` (i/n)` suffix counted across all of them, and
  /// the suffix is accounted for in the limit.
  static List<String> splitParts(List<String> parts, TextRules rules, {bool numbering = true}) {
    if (parts.length == 1) return split(parts.single, rules, numbering: numbering);
    final max = rules.maxLength;
    List<String> pieces(int reserve) => [
          for (final p in parts)
            if (max == null || TextCounter.count(p, rules) <= max - reserve) p else ..._splitTo(p, rules, max - reserve),
        ];
    if (!numbering) return pieces(0);
    // The suffix grows with the number of parts, and a longer suffix can
    // split a part again; repeat until the count is stable.
    var reserve = _suffix(parts.length).length;
    var out = pieces(reserve);
    while (_suffix(out.length).length > reserve) {
      reserve = _suffix(out.length).length;
      out = pieces(reserve);
    }
    return number(out);
  }

  /// Adds ` (i/n)` to each part; a single part stays as it is.
  static List<String> number(List<String> parts) =>
      parts.length < 2 ? parts : [for (var i = 0; i < parts.length; i++) '${parts[i]}${_label(i, parts.length)}'];

  /// [part] without the ` (i/n)` suffix that [number] gives part [index]
  /// (from 0) of a thread of [count] parts; unchanged when it has none.
  static String withoutNumber(String part, int index, int count) {
    final label = _label(index, count);
    return count > 1 && part.endsWith(label) ? part.substring(0, part.length - label.length) : part;
  }

  /// The widest suffix [number] adds to a thread of [count] parts.
  static int suffixLength(int count) => _suffix(count).length;

  static String _suffix(int count) => ' ($count/$count)';

  static String _label(int index, int count) => ' (${index + 1}/$count)';

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
  /// a URL. [reserve] keeps that many characters of the limit free (for a
  /// thread part's ` (i/n)` suffix).
  static String truncate(String text, TextRules rules, {String ellipsis = '…', int reserve = 0}) {
    final limit = rules.maxLength;
    if (limit == null) return text;
    final max = limit - reserve;
    if (TextCounter.count(text, rules) <= max) return text;
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
