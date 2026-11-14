import 'package:meta/meta.dart';

import 'kaomoji.dart';
import 'text_styles.dart';

/// The tabs of the character panel. Emoji keep their own data (the app's
/// emoji package, built from Unicode's emoji-test.txt); the catalog gives them
/// search words ([CharacterCatalog.keywordsFor]).
enum CharacterTab { emoji, symbols, kaomoji, textStyles }

/// One thing the panel inserts: a symbol, or a kaomoji.
@immutable
class CharacterEntry {
  const CharacterEntry(this.text, this.name, {this.altCode, this.keywords = const []});

  /// What goes into the post, exactly.
  final String text;

  /// Unicode's name in sentence case ("Black heart suit"), or a kaomoji's
  /// group ("Joy").
  final String name;

  /// The digits typed with Alt on a Windows numeric keypad ("0169" for ©,
  /// "3" for ♥), or null.
  final String? altCode;

  /// Search words beyond the name (CLDR keywords, a kaomoji group's words).
  final List<String> keywords;

  /// `U+2665`, or `U+0028 U+00AF ...` for a longer text.
  String get codePoints => [for (final r in text.runes) 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}'].join(' ');

  /// The numeric HTML reference: `&#9829;`.
  String get htmlCode => [for (final r in text.runes) '&#$r;'].join();

  @override
  bool operator ==(Object other) => other is CharacterEntry && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'CharacterEntry($text, $name)';
}

/// A run of entries under one heading: a NamesList section ("Weather and
/// astrological symbols"), or the whole of a small group.
@immutable
class CharacterSection {
  const CharacterSection(this.title, this.entries);
  final String title;
  final List<CharacterEntry> entries;
}

/// A chip of a tab: a Unicode block, a set such as Hearts, or a kaomoji
/// group.
@immutable
class CharacterGroup {
  const CharacterGroup({required this.id, required this.title, required this.sections, this.isBlock = false, this.firstCodePoint, this.lastCodePoint});
  final String id;
  final String title;
  final List<CharacterSection> sections;

  /// A whole Unicode block (with its range from Blocks.txt), not a set.
  final bool isBlock;
  final int? firstCodePoint;
  final int? lastCodePoint;

  Iterable<CharacterEntry> get entries => sections.expand((s) => s.entries);
}

/// Symbols, kaomoji and text styles behind one interface, so the panel does
/// not care whether they come from data bundled with the app (the default) or
/// from somewhere else later.
abstract interface class CharacterCatalog {
  /// The Unicode version the symbols and text styles come from.
  String get unicodeVersion;

  /// The groups of [tab], in the order the panel shows them. Empty for
  /// [CharacterTab.emoji] and [CharacterTab.textStyles].
  List<CharacterGroup> groups(CharacterTab tab);

  /// Entries of [tab] that fit every word of [query], best fit first.
  List<CharacterEntry> search(String query, CharacterTab tab, {int limit = 300});

  /// The entry for [text] in any tab, or null.
  CharacterEntry? entryFor(String text);

  /// CLDR's English search words for an emoji or symbol, U+FE0F ignored.
  List<String> keywordsFor(String text);

  /// The Text styles tab's tables.
  TextStyles get textStyles;
}

/// The catalog from the JSON files in `assets/characters` (made by
/// tool/generate_character_catalog.dart) and the kaomoji in this package.
class BundledCharacterCatalog implements CharacterCatalog {
  BundledCharacterCatalog._(this.unicodeVersion, this._symbols, this._kaomoji, this._keywords, this.textStyles) {
    for (final tab in [_symbols, _kaomoji]) {
      for (final g in tab) {
        for (final e in g.entries) {
          _byText.putIfAbsent(e.text, () => e);
        }
      }
    }
  }

  /// [symbols], [textStyles] and [keywords] are the decoded `symbols.json`,
  /// `text_styles.json` and `keywords.json`.
  factory BundledCharacterCatalog.fromJson({required Map<String, Object?> symbols, required Map<String, Object?> textStyles, required Map<String, Object?> keywords}) {
    final words = <String, List<String>>{
      for (final e in ((keywords['keywords'] as Map?) ?? const {}).entries) '${e.key}': [for (final w in e.value as List) '$w'],
    };
    List<String> wordsOf(String text) => words[text.replaceAll('️', '')] ?? const [];
    CharacterEntry cell(List<Object?> c) {
      final text = String.fromCharCode((c[0] as num).toInt());
      return CharacterEntry(text, '${c[1]}', altCode: c.length > 2 ? '${c[2]}' : null, keywords: wordsOf(text));
    }

    final blocks = <CharacterGroup>[];
    final byCodePoint = <int, CharacterEntry>{};
    for (final b in (symbols['blocks'] as List).cast<Map<String, Object?>>()) {
      final sections = <CharacterSection>[];
      for (final s in (b['sections'] as List).cast<Map<String, Object?>>()) {
        final entries = [for (final c in (s['chars'] as List).cast<List<Object?>>()) cell(c)];
        for (final e in entries) {
          byCodePoint[e.text.runes.single] = e;
        }
        sections.add(CharacterSection('${s['title']}', entries));
      }
      blocks.add(CharacterGroup(
        id: 'block:${b['name']}',
        title: '${b['name']}',
        sections: sections,
        isBlock: true,
        firstCodePoint: (b['first'] as num).toInt(),
        lastCodePoint: (b['last'] as num).toInt(),
      ));
    }
    final sets = [
      for (final s in (symbols['sets'] as List).cast<Map<String, Object?>>())
        CharacterGroup(id: '${s['id']}', title: '${s['title']}', sections: [
          CharacterSection('${s['title']}', [
            for (final cp in (s['chars'] as List).cast<num>())
              if (byCodePoint[cp.toInt()] case final e?) e,
          ]),
        ]),
    ];
    final kaomoji = [
      for (final g in kKaomojiGroups)
        CharacterGroup(id: 'kaomoji:${g.id}', title: g.title, sections: [
          CharacterSection(g.title, [for (final k in g.kaomoji) CharacterEntry(k, g.title, keywords: g.keywords)]),
        ]),
    ];
    return BundledCharacterCatalog._('${symbols['unicode']}', [...sets, ...blocks], kaomoji, words, TextStyles.fromJson(textStyles));
  }

  @override
  final String unicodeVersion;
  final List<CharacterGroup> _symbols;
  final List<CharacterGroup> _kaomoji;
  final Map<String, List<String>> _keywords;
  final Map<String, CharacterEntry> _byText = {};

  @override
  final TextStyles textStyles;

  @override
  List<CharacterGroup> groups(CharacterTab tab) => switch (tab) {
        CharacterTab.symbols => _symbols,
        CharacterTab.kaomoji => _kaomoji,
        CharacterTab.emoji || CharacterTab.textStyles => const [],
      };

  @override
  CharacterEntry? entryFor(String text) => _byText[text];

  @override
  List<String> keywordsFor(String text) => _keywords[text.replaceAll('️', '')] ?? const [];

  @override
  List<CharacterEntry> search(String query, CharacterTab tab, {int limit = 300}) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    final hits = <(int, int, CharacterEntry)>[];
    final seen = <String>{};
    var order = 0;
    for (final g in groups(tab)) {
      for (final e in g.entries) {
        order++;
        if (!seen.add(e.text)) continue;
        var total = 0;
        for (final w in words) {
          final f = characterFit(e, w);
          if (f == null) {
            total = -1;
            break;
          }
          total += f;
        }
        if (total >= 0) hits.add((total, order, e));
      }
    }
    hits.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    return [for (final h in hits.take(limit)) h.$3];
  }
}

final RegExp _hexWord = RegExp(r'^(?:u\+|0x)?([0-9a-f]{4,6})$');
final RegExp _altWord = RegExp(r'^alt\+?(\d+)$');
final RegExp _wordBreak = RegExp(r'[\s-]+');

/// How well one lower-case [word] fits [e]: lower is better, null for no fit.
/// The character itself, its code point (`2665`, `u+2665`) and its Alt code
/// (`alt+3`) fit best; then a whole word of its name or keywords; then the
/// start of one; then anywhere.
int? characterFit(CharacterEntry e, String word) {
  if (e.text == word || e.text.toLowerCase() == word) return 0;
  final hex = _hexWord.firstMatch(word);
  if (hex != null && e.text.runes.length == 1 && e.text.runes.single == int.parse(hex[1]!, radix: 16)) return 0;
  final alt = _altWord.firstMatch(word);
  if (alt != null) return e.altCode == alt[1] ? 0 : null;
  final name = e.name.toLowerCase();
  final nameWords = name.split(_wordBreak);
  if (nameWords.contains(word) || e.keywords.contains(word)) return 1;
  if (nameWords.any((n) => n.startsWith(word)) || e.keywords.any((k) => k.split(' ').any((p) => p.startsWith(word)))) return 2;
  if (name.contains(word) || e.keywords.any((k) => k.contains(word))) return 3;
  return null;
}
