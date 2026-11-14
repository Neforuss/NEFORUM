import 'package:characters/characters.dart';
import 'package:meta/meta.dart';

/// How a style is made.
enum TextStyleMethod {
  /// Each letter swapped for its styled character (`text_styles.json`
  /// tables, from Unicode's own mappings).
  table,

  /// Turned half a circle: each character swapped, the order reversed.
  upsideDown,

  /// Combining marks after each character: they count toward each network's
  /// limit like any character.
  combining,
}

/// The styles of the Text styles tab, in the order it shows them.
enum TextStyleKind {
  bold('Bold', ['heavy', 'strong']),
  italic('Italic', ['slanted', 'oblique']),
  boldItalic('Bold italic', ['heavy', 'slanted']),
  script('Script', ['cursive', 'handwriting', 'calligraphy', 'fancy']),
  boldScript('Bold script', ['cursive', 'handwriting', 'calligraphy', 'fancy']),
  fraktur('Fraktur', ['gothic', 'blackletter', 'old english', 'medieval']),
  boldFraktur('Bold fraktur', ['gothic', 'blackletter', 'old english', 'medieval']),
  doubleStruck('Double-struck', ['outline', 'blackboard', 'hollow']),
  sans('Sans-serif', ['clean', 'plain']),
  sansBold('Sans-serif bold', ['heavy', 'strong']),
  sansItalic('Sans-serif italic', ['slanted']),
  sansBoldItalic('Sans-serif bold italic', ['heavy', 'slanted']),
  monospace('Monospace', ['typewriter', 'code', 'fixed']),
  fullwidth('Fullwidth', ['wide', 'vaporwave', 'aesthetic', 'spaced']),
  circled('Circled', ['bubble', 'round']),
  circledNegative('Filled circles', ['bubble', 'black', 'dark', 'negative']),
  squared('Squared', ['box', 'square']),
  squaredNegative('Filled squares', ['box', 'black', 'dark', 'negative', 'square']),
  parenthesized('Parenthesized', ['brackets', 'parentheses']),
  superscript('Superscript', ['tiny', 'small', 'raised', 'exponent']),
  subscript('Subscript', ['tiny', 'small', 'lowered']),
  smallCaps('Small capitals', ['small caps', 'tiny', 'capitals']),
  upsideDown('Upside down', ['flip', 'flipped', 'rotated', 'australian'], method: TextStyleMethod.upsideDown),
  strikethrough('Strikethrough', ['strike', 'crossed out', 'line through'], method: TextStyleMethod.combining),
  underline('Underline', ['underlined', 'line under'], method: TextStyleMethod.combining),
  zalgo('Zalgo', ['glitch', 'creepy', 'cursed', 'messy'], method: TextStyleMethod.combining);

  const TextStyleKind(this.label, this.keywords, {this.method = TextStyleMethod.table});
  final String label;
  final List<String> keywords;
  final TextStyleMethod method;

  /// Whether [query] (any case) names this style.
  bool matches(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final hay = [label.toLowerCase(), ...keywords];
    return words.every((w) => hay.any((h) => h.contains(w)));
  }
}

/// Combining long stroke overlay: strikethrough.
const int kCombiningStrike = 0x0336;

/// Combining low line: underline.
const int kCombiningUnderline = 0x0332;

/// Zalgo stacks at most this many marks on one character, so a post stays
/// readable and its length stays known.
const int kZalgoMaxMarks = 3;

/// The Text styles tab's engine: Unicode's styled letters, our upside-down
/// pairs and the combining-mark styles. Pure: the same text always comes out
/// the same, so the preview is exactly what goes in.
@immutable
class TextStyles {
  TextStyles({required Map<String, Map<String, String>> tables, required this.upsideDownMap, required this.zalgoAbove, required this.zalgoBelow})
      : tables = Map.unmodifiable(tables) {
    // Back to plain: every styled character to its letter. Folded styles
    // (small capitals, squares, filled circles) give capitals, except small
    // capitals, which read as lower case.
    for (final kind in TextStyleKind.values) {
      final table = tables[kind.name];
      if (table == null) continue;
      final keys = table.keys.toList()..sort((a, b) => kind == TextStyleKind.smallCaps ? a.compareTo(b) : b.compareTo(a));
      for (final k in keys) {
        _plain[table[k]!] = k;
      }
    }
    _zalgoMarks.addAll([...zalgoAbove, ...zalgoBelow]);
  }

  /// `text_styles.json`, decoded.
  factory TextStyles.fromJson(Map<String, Object?> json) => TextStyles(
        tables: {
          for (final e in (json['tables'] as Map).entries) '${e.key}': {for (final m in (e.value as Map).entries) '${m.key}': '${m.value}'},
        },
        upsideDownMap: {for (final e in (json['upsideDown'] as Map).entries) '${e.key}': '${e.value}'},
        zalgoAbove: [for (final c in json['zalgoAbove'] as List) (c as num).toInt()],
        zalgoBelow: [for (final c in json['zalgoBelow'] as List) (c as num).toInt()],
      );

  /// Plain character to styled character, by [TextStyleKind.name].
  final Map<String, Map<String, String>> tables;

  /// Both ways: each character and its turned form.
  final Map<String, String> upsideDownMap;

  /// Combining marks that sit above (class 230) and below (class 220).
  final List<int> zalgoAbove;
  final List<int> zalgoBelow;

  final Map<String, String> _plain = {};
  final Set<int> _zalgoMarks = {};

  /// [text] in [kind]. Styled text is made plain first, so a second style
  /// replaces the first instead of stacking; Upside down applied twice gives
  /// the text back. A character a style has no form for stays as it is.
  String apply(TextStyleKind kind, String text) {
    final base = plain(text);
    switch (kind.method) {
      case TextStyleMethod.table:
        final table = tables[kind.name] ?? const {};
        return [for (final r in base.runes) table[String.fromCharCode(r)] ?? String.fromCharCode(r)].join();
      case TextStyleMethod.upsideDown:
        return upsideDown(base);
      case TextStyleMethod.combining:
        return switch (kind) {
          TextStyleKind.strikethrough => _withMark(base, kCombiningStrike),
          TextStyleKind.underline => _withMark(base, kCombiningUnderline),
          _ => zalgo(base),
        };
    }
  }

  /// [text] turned half a circle: each character in [upsideDownMap] swapped,
  /// the others kept, and the order of characters reversed. Its own inverse.
  String upsideDown(String text) => [
        for (final line in text.split('\n'))
          [
            for (final c in line.characters.toList().reversed) upsideDownMap[c] ?? c,
          ].join(),
      ].join('\n');

  String _withMark(String text, int mark) {
    final m = String.fromCharCode(mark);
    return [for (final c in text.characters) c == '\n' || c == '\r\n' ? c : '$c$m'].join();
  }

  /// Zalgo: two to [kZalgoMaxMarks] marks above or below each visible
  /// character (two at least, so [plain] can tell them from an accent).
  /// Chosen by a generator seeded from [text], so the same text always gives
  /// the same result.
  String zalgo(String text) {
    var seed = 0x2545F491;
    for (final u in text.codeUnits) {
      seed = (seed * 31 + u) & 0x7FFFFFFF;
    }
    int next() {
      // xorshift32
      seed ^= (seed << 13) & 0xFFFFFFFF;
      seed ^= seed >> 17;
      seed ^= (seed << 5) & 0xFFFFFFFF;
      seed &= 0xFFFFFFFF;
      return seed;
    }

    final out = StringBuffer();
    for (final c in text.characters) {
      out.write(c);
      if (c.trim().isEmpty || zalgoAbove.isEmpty || zalgoBelow.isEmpty) continue;
      final count = 2 + next() % (kZalgoMaxMarks - 1);
      for (var i = 0; i < count; i++) {
        final pool = next().isEven ? zalgoAbove : zalgoBelow;
        out.writeCharCode(pool[next() % pool.length]);
      }
    }
    return out.toString();
  }

  /// [text] with every styled letter back to plain and the marks the
  /// combining styles add taken off: strikethrough and underline marks
  /// always, Zalgo's where a character carries two or more of them. A single
  /// accent written as a combining mark (é as e and U+0301) stays. Upside-down
  /// text is not turned back: apply Upside down again for that.
  String plain(String text) {
    final out = StringBuffer();
    for (final cluster in text.characters) {
      final runes = cluster.runes.toList();
      final stacked = runes.where(_zalgoMarks.contains).length >= 2;
      for (final r in runes) {
        if (r == kCombiningStrike || r == kCombiningUnderline) continue;
        if (stacked && _zalgoMarks.contains(r)) continue;
        final c = String.fromCharCode(r);
        out.write(_plain[c] ?? c);
      }
    }
    return out.toString();
  }
}
