// Writes the character catalog (assets/characters/*.json) from pinned Unicode
// files: the Symbols tab's blocks and sets, the Text styles tab's tables, and
// keywords for searching emoji and symbols. Run from packages/neforum_core:
//
//   dart run tool/generate_character_catalog.dart
//
// It downloads each source once into .dart_tool/character_sources, checks it
// against the SHA-256 pinned below, and stops when one differs. It also copies
// Blocks.txt and UnicodeData.txt to test/fixtures/unicode, where
// test/characters/character_catalog_gate_test.dart reads them back and holds
// the JSON to them. README.md ("Character catalog") says how to move to a new
// Unicode version.
//
// Nothing here is typed from memory: block ranges come from Blocks.txt, names
// and categories from UnicodeData.txt, sections and the Letterlike stand-ins
// for gaps in the mathematical alphabets from NamesList.txt, Alt codes from
// Unicode's code page tables. The selections (which blocks, which sets, the
// "Popular" set, the upside-down pairs) are NEFORUM's own.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// The Unicode version every UCD file comes from. emoji-test.txt in
/// test/fixtures/unicode is the same version.
const String kUnicodeVersion = '18.0.0';

/// The CLDR release the emoji and symbol keywords come from.
const String kCldrVersion = '49.0.0';

/// One pinned source file.
class PinnedSource {
  const PinnedSource(this.name, this.url, this.sha256, {required this.version});
  final String name;
  final String url;
  final String sha256;
  final String version;

  Map<String, String> toJson() => {'file': name, 'version': version, 'url': url, 'sha256': sha256};
}

const String _ucd = 'https://www.unicode.org/Public/$kUnicodeVersion/ucd';
const String _cldr = 'https://raw.githubusercontent.com/unicode-org/cldr-json/$kCldrVersion/cldr-json';

/// Every file the catalog is made from. An empty hash prints the file's hash
/// and goes on: that is how a new version gets pinned (see README.md).
const List<PinnedSource> kSources = [
  PinnedSource('Blocks.txt', '$_ucd/Blocks.txt', 'a58f8d322f3c5e254f9f97b1cbf76a454a7e02de6ac35619a5e4f27aaabfd553', version: kUnicodeVersion),
  PinnedSource('UnicodeData.txt', '$_ucd/UnicodeData.txt', '0736451de439ae7baf1425136617da495e09ee5afbe6e394374db7009ea08950', version: kUnicodeVersion),
  PinnedSource('NamesList.txt', '$_ucd/NamesList.txt', 'e0732f7cb47a08ee2186c83a18a91ae277126e8099b53c432b4c3e32488dac9b', version: kUnicodeVersion),
  PinnedSource('CP437.TXT', 'https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/PC/CP437.TXT', '6bad4dabcdf5940227c7d81fab130dcb18a77850b5d79de28b5dc4e047b0aaac',
      version: '2.00 (1998-04-24)'),
  PinnedSource('CP1252.TXT', 'https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WINDOWS/CP1252.TXT', 'f607ae328b4dff5e9bfef725f5fff0ae23f38797f8a5b95998a0d2735c0e8fad',
      version: '2.01 (1998-04-15)'),
  PinnedSource('IBMGRAPH.TXT', 'https://www.unicode.org/Public/MAPPINGS/VENDORS/MISC/IBMGRAPH.TXT', '5c8052b5a9c3852b1cb4b6a1b5d1591e8d26604e7ed457cbdc6f1cbe09463cf2', version: '1.0'),
  PinnedSource('annotations.json', '$_cldr/cldr-annotations-full/annotations/en/annotations.json', '6b6b6e0e5f211bc31cf3fa39f385d80dea6cd19ee19bbc6db9071fce3ae5d360',
      version: 'CLDR $kCldrVersion'),
  PinnedSource('annotationsDerived.json', '$_cldr/cldr-annotations-derived-full/annotationsDerived/en/annotations.json',
      '7aad034f689cb6553f8d7366bfee8c4ea2818c7776907bc5118aab575223dea3',
      version: 'CLDR $kCldrVersion'),
  PinnedSource('license.txt', 'https://www.unicode.org/license.txt', 'e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96', version: 'Unicode License v3'),
];

// ---------------------------------------------------------------------------
// Parsing. Public so the gate tests parse the vendored files the same way.

/// One line of Blocks.txt.
typedef UnicodeBlock = ({int first, int last, String name});

/// Blocks.txt: `0000..007F; Basic Latin`.
List<UnicodeBlock> parseBlocks(String source) => [
      for (final line in const LineSplitter().convert(source))
        if (RegExp(r'^([0-9A-F]+)\.\.([0-9A-F]+); (.+)$').firstMatch(line.trim()) case final m?)
          (first: int.parse(m[1]!, radix: 16), last: int.parse(m[2]!, radix: 16), name: m[3]!.trim()),
    ];

/// One character of UnicodeData.txt.
typedef UnicodeChar = ({int cp, String name, String category, int combiningClass, String decomposition});

/// UnicodeData.txt by code point. `<..., First>`/`<..., Last>` ranges are
/// filled in, each with the range's name.
Map<int, UnicodeChar> parseUnicodeData(String source) {
  final out = <int, UnicodeChar>{};
  int? rangeStart;
  for (final line in const LineSplitter().convert(source)) {
    if (line.trim().isEmpty) continue;
    final f = line.split(';');
    final cp = int.parse(f[0], radix: 16);
    final name = f[1];
    UnicodeChar at(int c, String n) => (cp: c, name: n, category: f[2], combiningClass: int.parse(f[3]), decomposition: f[5]);
    if (name.endsWith(', First>')) {
      rangeStart = cp;
      continue;
    }
    if (name.endsWith(', Last>') && rangeStart != null) {
      final base = name.substring(1, name.length - ', Last>'.length);
      for (var c = rangeStart; c <= cp; c++) {
        out[c] = at(c, base);
      }
      rangeStart = null;
      continue;
    }
    out[cp] = at(cp, name);
  }
  return out;
}

/// Whether a character of [category] is a cell of its own in the Symbols tab:
/// letters, spacing marks, numbers, punctuation and symbols. Never controls,
/// formats, surrogates, private use, unassigned, separators (spaces draw
/// nothing) or combining marks (they need a base).
bool isInsertableCategory(String category) => const {'L', 'N', 'P', 'S'}.contains(category[0]) || category == 'Mc';

/// NamesList.txt: each character's section (`@` subheader) and, for a
/// reserved code point, the character it points to (`x (... - 212C)`).
({Map<int, String> sections, Map<int, int> reservedPointers}) parseNamesList(String source) {
  final sections = <int, String>{};
  final pointers = <int, int>{};
  String? section;
  int? reserved;
  final entry = RegExp(r'^([0-9A-F]{4,6})\t(.*)$');
  final pointer = RegExp(r'^\tx \(.* - ([0-9A-F]{4,6})\)$');
  for (final line in const LineSplitter().convert(source)) {
    if (line.startsWith('@@\t')) {
      section = null;
      reserved = null;
      continue;
    }
    if (line.startsWith('@\t')) {
      section = line.replaceFirst(RegExp(r'^@\t+'), '').trim();
      continue;
    }
    final e = entry.firstMatch(line);
    if (e != null) {
      final cp = int.parse(e[1]!, radix: 16);
      reserved = e[2] == '<reserved>' ? cp : null;
      if (section != null) sections[cp] = section;
      continue;
    }
    final p = pointer.firstMatch(line);
    if (p != null && reserved != null) {
      pointers.putIfAbsent(reserved, () => int.parse(p[1]!, radix: 16));
    }
  }
  return (sections: sections, reservedPointers: pointers);
}

/// A Microsoft or IBM mapping table: byte to code point. [columns] says which
/// column holds which (CP437 and CP1252: byte, then Unicode; IBMGRAPH: Unicode,
/// then byte).
Map<int, int> parseCodePage(String source, {bool unicodeFirst = false}) {
  final out = <int, int>{};
  for (final line in const LineSplitter().convert(source)) {
    final body = line.split('#').first.trim();
    if (body.isEmpty) continue;
    final cols = body.split(RegExp(r'\s+'));
    if (cols.length < 2) continue;
    int? hex(String s) => int.tryParse(s.replaceFirst(RegExp('^0x', caseSensitive: false), ''), radix: 16);
    final byte = hex(unicodeFirst ? cols[1] : cols[0]);
    final cp = hex(unicodeFirst ? cols[0] : cols[1]);
    if (byte == null || cp == null) continue;
    out.putIfAbsent(byte, () => cp);
  }
  return out;
}

/// "BLACK HEART SUIT" as "Black heart suit".
String sentenceCase(String name) {
  final lower = name.toLowerCase();
  return lower.isEmpty ? lower : lower[0].toUpperCase() + lower.substring(1);
}

// ---------------------------------------------------------------------------
// The Symbols tab.

/// The blocks the Symbols tab offers, by their Blocks.txt names, in the order
/// it shows them. Symbol-heavy blocks only: no scripts, no ideographs, no
/// mathematical letters (those are the Text styles tab) and no emoji blocks
/// (the Emoji tab). The ranges come from Blocks.txt.
const List<String> kSymbolBlocks = [
  'Latin-1 Supplement',
  'Latin Extended-A',
  'General Punctuation',
  'Superscripts and Subscripts',
  'Currency Symbols',
  'Letterlike Symbols',
  'Number Forms',
  'Arrows',
  'Supplemental Arrows-A',
  'Supplemental Arrows-B',
  'Supplemental Arrows-C',
  'Miscellaneous Symbols and Arrows',
  'Mathematical Operators',
  'Supplemental Mathematical Operators',
  'Miscellaneous Mathematical Symbols-A',
  'Miscellaneous Mathematical Symbols-B',
  'Miscellaneous Technical',
  'Control Pictures',
  'Optical Character Recognition',
  'Enclosed Alphanumerics',
  'Enclosed Alphanumeric Supplement',
  'Enclosed CJK Letters and Months',
  'Enclosed Ideographic Supplement',
  'Box Drawing',
  'Block Elements',
  'Geometric Shapes',
  'Geometric Shapes Extended',
  'Miscellaneous Symbols',
  'Dingbats',
  'Ornamental Dingbats',
  'Supplemental Punctuation',
  'CJK Symbols and Punctuation',
  'CJK Compatibility',
  'Halfwidth and Fullwidth Forms',
  'Braille Patterns',
  'Yijing Hexagram Symbols',
  'Musical Symbols',
  'Chess Symbols',
  'Playing Cards',
  'Mahjong Tiles',
  'Domino Tiles',
  'Alchemical Symbols',
  'Symbols for Legacy Computing',
];

/// NEFORUM's own pick of everyday symbols, the first set the tab shows.
const String kPopularSymbols = '✓✔✗✘★☆✦✧♥♡❤❥•·‣◦…–—©®™℠°±×÷≈≠≤≥∞√∑∆‰§¶†‡'
    '←↑→↓↔↕⇐⇒⇔↩↪⟵⟶➜➤▲▼◀▶△▽◆◇■□●○◉◎'
    '€£¥¢₹₽₩₿¤'
    '½⅓⅔¼¾⅛'
    '☀☁☂☃☄⚡❄☔☕☎✉✂✏✒⌘⌥⇧⏎⌫⌛⏰'
    '☮☯☪✝✡☸♈♉♊♋♌♍♎♏♐♑♒♓'
    '♠♣♥♦♤♧♡♢♔♕♖♗♘♙♚♛♜♝♞♟'
    '♩♪♫♬♭♮♯'
    '✿❀❁✾❃❋✽✻✺✹✸✷✶✵✴✳❖⚘⚜'
    '☺☻☹♀♂⚢⚣⚤⚥⚧'
    '«»‹›„“”‘’¡¿⁂※⁕⁜';

/// A set of the Symbols tab built by a rule over the blocks above.
typedef SymbolSetRule = ({String id, String title, bool Function(UnicodeChar c, String? section) test});

final RegExp _zodiac = RegExp(r'^(ARIES|TAURUS|GEMINI|CANCER|LEO|VIRGO|LIBRA|SCORPIUS|SAGITTARIUS|CAPRICORN|AQUARIUS|PISCES|OPHIUCHUS)$');

/// The sets after "Popular", each a rule over names, categories and NamesList
/// sections, so a new Unicode version fills them in by itself.
final List<SymbolSetRule> kSymbolSets = [
  (id: 'hearts', title: 'Hearts', test: (c, _) => RegExp(r'\bHEART\b').hasMatch(c.name) && !c.name.contains('PLAYING CARD')),
  (id: 'stars', title: 'Stars and sparkles', test: (c, _) => RegExp(r'\b(STAR|STARS|ASTERISK|ASTERISM|SPARKLE|SPARKLES)\b').hasMatch(c.name)),
  (id: 'checks', title: 'Checks and crosses', test: (c, _) => RegExp(r'\b(CHECK MARK|BALLOT|X MARK|SALTIRE|MULTIPLICATION X|HEAVY MULTIPLICATION)\b').hasMatch(c.name)),
  (id: 'arrows', title: 'Arrows', test: (c, _) => RegExp(r'\b(ARROW|ARROWS|ARROWHEAD)\b').hasMatch(c.name) && c.category.startsWith('S')),
  (id: 'flowers', title: 'Flowers and florettes', test: (c, _) => RegExp(r'\b(FLORETTE|FLOWER|ROSETTE|BLOSSOM|SHAMROCK|FLEUR|PROPELLER|ASTERISK)\b').hasMatch(c.name)),
  (id: 'faces', title: 'Faces and hands', test: (c, _) => RegExp(r'\b(FACE|HAND|INDEX)\b').hasMatch(c.name) && c.category == 'So'),
  (id: 'weather', title: 'Weather and sky', test: (c, s) => RegExp(r'\b(SUN|SUNRISE|CLOUD|UMBRELLA|SNOWMAN|SNOWFLAKE|LIGHTNING|THUNDERSTORM|RAIN|COMET|MOON|CRESCENT|FOG)\b').hasMatch(c.name) && c.category == 'So'),
  (id: 'zodiac', title: 'Zodiac', test: (c, _) => _zodiac.hasMatch(c.name)),
  (id: 'music', title: 'Music', test: (c, _) => RegExp(r'\b(MUSIC|MUSICAL|NOTE|NOTES|BEAMED|SHARP SIGN|FLAT SIGN|NATURAL SIGN)\b').hasMatch(c.name) && !c.name.startsWith('MUSICAL SYMBOL')),
  (id: 'chess', title: 'Chess and cards', test: (c, _) => RegExp(r'^(WHITE|BLACK) CHESS |\b(SPADE|CLUB|DIAMOND|HEART) SUIT\b').hasMatch(c.name)),
  (id: 'currency', title: 'Currency', test: (c, _) => c.category == 'Sc'),
  (id: 'math', title: 'Math', test: (c, _) => c.category == 'Sm' && c.cp < 0x2A00),
  (id: 'fractions', title: 'Numbers and fractions', test: (c, _) => RegExp(r'\b(VULGAR FRACTION|FRACTION NUMERATOR|ROMAN NUMERAL|CIRCLED DIGIT|CIRCLED NUMBER|PARENTHESIZED DIGIT|DIGIT [A-Z]+ FULL STOP)\b').hasMatch(c.name)),
  (id: 'bullets', title: 'Bullets and dots', test: (c, _) => RegExp(r'\b(BULLET|DOT OPERATOR|MIDDLE DOT|CIRCLE)\b').hasMatch(c.name) && c.cp < 0x2800 && !c.name.contains('CIRCLED')),
  (id: 'brackets', title: 'Brackets and quotes', test: (c, _) => const {'Ps', 'Pe', 'Pi', 'Pf'}.contains(c.category)),
  (id: 'gender', title: 'Gender', test: (c, _) => RegExp(r'\b(MALE|FEMALE|GENDER|HERMAPHRODITE|NEUTER|INTERSEX)\b').hasMatch(c.name)),
  (id: 'keyboard', title: 'Keys and technical', test: (c, s) => s != null && RegExp(r'keyboard|user interface|computing|media control', caseSensitive: false).hasMatch(s)),
  (id: 'lines', title: 'Lines and blocks', test: (c, _) => c.cp >= 0x2500 && c.cp <= 0x259F),
];

/// The Symbols tab's data.
Map<String, Object?> buildSymbols({
  required List<UnicodeBlock> blocks,
  required Map<int, UnicodeChar> chars,
  required Map<int, String> sections,
  required Map<int, String> altCodes,
  required List<PinnedSource> sources,
}) {
  final byName = {for (final b in blocks) b.name: b};
  final included = <int>[];
  final outBlocks = <Map<String, Object?>>[];
  List<Object> cell(int cp) => [cp, sentenceCase(chars[cp]!.name), if (altCodes[cp] != null) altCodes[cp]!];
  for (final name in kSymbolBlocks) {
    final b = byName[name];
    if (b == null) throw StateError('Blocks.txt has no block named "$name"');
    final outSections = <Map<String, Object?>>[];
    for (var cp = b.first; cp <= b.last; cp++) {
      final c = chars[cp];
      if (c == null || !isInsertableCategory(c.category)) continue;
      included.add(cp);
      final title = sections[cp] ?? b.name;
      if (outSections.isEmpty || outSections.last['title'] != title) outSections.add({'title': title, 'chars': <List<Object>>[]});
      (outSections.last['chars'] as List<List<Object>>).add(cell(cp));
    }
    outBlocks.add({'name': b.name, 'first': b.first, 'last': b.last, 'sections': outSections});
  }
  final inScope = included.toSet();
  final popular = <int>[];
  for (final r in kPopularSymbols.runes) {
    if (!inScope.contains(r)) throw StateError('Popular symbol U+${r.toRadixString(16)} is outside the Symbols blocks');
    if (!popular.contains(r)) popular.add(r);
  }
  final sets = <Map<String, Object?>>[
    {'id': 'popular', 'title': 'Popular', 'chars': popular},
    for (final rule in kSymbolSets)
      {
        'id': rule.id,
        'title': rule.title,
        'chars': [
          for (final cp in included)
            if (rule.test(chars[cp]!, sections[cp])) cp,
        ],
      },
  ];
  for (final s in sets) {
    if ((s['chars'] as List).isEmpty) throw StateError('The set "${s['id']}" came out empty');
  }
  return {
    'format': 1,
    'unicode': kUnicodeVersion,
    'sources': [for (final s in sources) s.toJson()],
    'sets': sets,
    'blocks': outBlocks,
  };
}

/// Alt codes for Windows: Alt+0 and the ANSI byte (Windows-1252) where it has
/// the character, else Alt and the OEM byte (code page 437, with IBM's
/// pictures for 1 to 31 and 127).
Map<int, String> altCodesFrom({required Map<int, int> cp1252, required Map<int, int> cp437, required Map<int, int> ibmGraph}) {
  final out = <int, String>{};
  for (final e in cp437.entries) {
    if (e.key >= 0x80) out.putIfAbsent(e.value, () => '${e.key}');
  }
  for (final e in ibmGraph.entries) {
    if ((e.key >= 0x01 && e.key <= 0x1F) || e.key == 0x7F) out.putIfAbsent(e.value, () => '${e.key}');
  }
  for (final e in cp1252.entries) {
    if (e.key >= 0x80) out[e.value] = '0${e.key}';
  }
  return out;
}

// ---------------------------------------------------------------------------
// The Text styles tab.

/// The mathematical alphabets, by the word UnicodeData names them with:
/// "MATHEMATICAL BOLD SCRIPT CAPITAL A" is boldScript.
const Map<String, String> kMathStyles = {
  'bold': 'BOLD',
  'italic': 'ITALIC',
  'boldItalic': 'BOLD ITALIC',
  'script': 'SCRIPT',
  'boldScript': 'BOLD SCRIPT',
  'fraktur': 'FRAKTUR',
  'boldFraktur': 'BOLD FRAKTUR',
  'doubleStruck': 'DOUBLE-STRUCK',
  'sans': 'SANS-SERIF',
  'sansBold': 'SANS-SERIF BOLD',
  'sansItalic': 'SANS-SERIF ITALIC',
  'sansBoldItalic': 'SANS-SERIF BOLD ITALIC',
  'monospace': 'MONOSPACE',
};

const List<String> _digitWords = ['ZERO', 'ONE', 'TWO', 'THREE', 'FOUR', 'FIVE', 'SIX', 'SEVEN', 'EIGHT', 'NINE'];

bool _isAsciiAlnum(int c) => (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// The one ASCII code point [decomposition] stands for under [tag]
/// (`<font> 0042` is B), or null.
int? _taggedTarget(String decomposition, String tag) {
  final m = RegExp('^<$tag> ([0-9A-F]{4})\$').firstMatch(decomposition);
  if (m == null) return null;
  final t = int.parse(m[1]!, radix: 16);
  return t >= 0x20 && t <= 0x7E ? t : null;
}

/// Each table style: plain character to styled character.
Map<String, Map<String, String>> buildStyleTables(Map<int, UnicodeChar> chars, Map<int, int> reservedPointers) {
  final tables = <String, Map<String, String>>{};
  String s(int cp) => String.fromCharCode(cp);

  // Mathematical alphabets, with the Letterlike stand-ins NamesList points
  // the reserved gaps to (script B is U+212C, not a missing letter).
  final letter = RegExp(r'^MATHEMATICAL (.+) (CAPITAL|SMALL) ([A-Z])$');
  final digit = RegExp(r'^MATHEMATICAL (.+) DIGIT ([A-Z]+)$');
  final capitalA = <String, int>{};
  for (final c in chars.values) {
    final l = letter.firstMatch(c.name);
    final d = digit.firstMatch(c.name);
    final style = kMathStyles.entries.where((e) => e.value == (l ?? d)?[1]).firstOrNull?.key;
    if (style == null) continue;
    final plain = _taggedTarget(c.decomposition, 'font');
    if (plain == null) continue;
    (tables[style] ??= {})[s(plain)] = s(c.cp);
    if (l != null && l[2] == 'CAPITAL' && l[3] == 'A') capitalA[style] = c.cp;
  }
  for (final style in kMathStyles.keys) {
    final a = capitalA[style];
    if (a == null) throw StateError('No MATHEMATICAL ${kMathStyles[style]} CAPITAL A');
    for (var i = 0; i < 52; i++) {
      final plain = i < 26 ? 0x41 + i : 0x61 + i - 26;
      if (tables[style]!.containsKey(s(plain))) continue;
      final stand = reservedPointers[a + i];
      if (stand == null) continue;
      if (_taggedTarget(chars[stand]?.decomposition ?? '', 'font') != plain) {
        throw StateError('NamesList points U+${(a + i).toRadixString(16)} to U+${stand.toRadixString(16)}, which is not <font> ${s(plain)}');
      }
      tables[style]![s(plain)] = s(stand);
    }
  }

  // Compatibility decompositions to one ASCII character.
  void byTag(String style, String tag, {bool foldCase = false, bool lettersAndDigitsOnly = true, bool Function(UnicodeChar c)? prefer}) {
    final picked = <int, UnicodeChar>{};
    for (final c in chars.values) {
      final t = _taggedTarget(c.decomposition, tag);
      if (t == null || (lettersAndDigitsOnly && !_isAsciiAlnum(t))) continue;
      final had = picked[t];
      if (had == null) {
        picked[t] = c;
      } else if (prefer != null && prefer(c) && !prefer(had)) {
        picked[t] = c;
      }
    }
    final table = tables[style] = {};
    for (final e in picked.entries) {
      table[s(e.key)] = s(e.value.cp);
    }
    if (foldCase) {
      for (var u = 0x41; u <= 0x5A; u++) {
        final up = table[s(u)];
        if (up != null) table.putIfAbsent(s(u + 0x20), () => up);
      }
    }
  }

  bool modifierOrScript(UnicodeChar c) => c.name.startsWith('MODIFIER LETTER') || c.name.startsWith('SUPERSCRIPT') || c.name.contains('SUBSCRIPT');
  byTag('fullwidth', 'wide', lettersAndDigitsOnly: false);
  byTag('circled', 'circle');
  byTag('squared', 'square', foldCase: true);
  byTag('superscript', 'super', lettersAndDigitsOnly: false, prefer: modifierOrScript);
  byTag('subscript', 'sub', lettersAndDigitsOnly: false, prefer: modifierOrScript);
  // Keep only what reads as text in a raised or lowered line: letters,
  // digits and + - = ( ).
  for (final style in ['superscript', 'subscript']) {
    tables[style]!.removeWhere((k, _) => !_isAsciiAlnum(k.codeUnitAt(0)) && !'+-=()'.contains(k));
  }

  // Parenthesized: `<compat> 0028 0061 0029`.
  final paren = tables['parenthesized'] = {};
  for (final c in chars.values) {
    final m = RegExp(r'^<compat> 0028 ([0-9A-F]{4}) 0029$').firstMatch(c.decomposition);
    if (m == null) continue;
    final t = int.parse(m[1]!, radix: 16);
    if (_isAsciiAlnum(t)) paren.putIfAbsent(s(t), () => s(c.cp));
  }

  // By name: small capitals and the negative (filled) circles and squares.
  void byName(String style, RegExp pattern, {Map<String, String> digits = const {}}) {
    final table = tables[style] = {};
    for (final c in chars.values) {
      final m = pattern.firstMatch(c.name);
      if (m == null) continue;
      final l = m[1]!;
      table.putIfAbsent(l, () => s(c.cp));
      table.putIfAbsent(l.toLowerCase(), () => s(c.cp));
    }
    for (final e in digits.entries) {
      final c = chars.values.where((c) => c.name == e.value).firstOrNull;
      if (c != null) table[e.key] = s(c.cp);
    }
  }

  byName('smallCaps', RegExp(r'^LATIN LETTER SMALL CAPITAL ([A-Z])$'));
  byName('circledNegative', RegExp(r'^NEGATIVE CIRCLED LATIN CAPITAL LETTER ([A-Z])$'), digits: {
    '0': 'NEGATIVE CIRCLED DIGIT ZERO',
    for (var i = 1; i <= 9; i++) '$i': 'DINGBAT NEGATIVE CIRCLED DIGIT ${_digitWords[i]}',
  });
  byName('squaredNegative', RegExp(r'^NEGATIVE SQUARED LATIN CAPITAL LETTER ([A-Z])$'));
  return tables;
}

/// NEFORUM's own upside-down pairs: each character and what it looks like
/// turned half a circle. Every pair works both ways; a character not listed
/// stays as it is (o, s, x, z, H, I, N, O, S, X, Z, 0 and 8 already look the
/// same). The generator checks every code point is assigned.
const List<(String, String)> kUpsideDownPairs = [
  ('a', 'ɐ'), ('b', 'q'), ('c', 'ɔ'), ('d', 'p'), ('e', 'ǝ'), ('f', 'ɟ'), ('g', 'ƃ'),
  ('h', 'ɥ'), ('i', 'ᴉ'), ('j', 'ɾ'), ('k', 'ʞ'), ('l', 'ꞁ'), ('m', 'ɯ'), ('n', 'u'),
  ('r', 'ɹ'), ('t', 'ʇ'), ('v', 'ʌ'), ('w', 'ʍ'), ('y', 'ʎ'),
  ('A', '∀'), ('B', 'ꓭ'), ('C', 'Ɔ'), ('D', 'ᗡ'), ('E', 'Ǝ'), ('F', 'Ⅎ'), ('G', '⅁'),
  ('J', 'ſ'), ('K', 'ꓘ'), ('L', '⅂'), ('M', 'W'), ('P', 'Ԁ'), ('Q', 'Ό'), ('R', 'ᴚ'),
  ('T', 'Ʇ'), ('U', '∩'), ('V', 'Λ'), ('Y', '⅄'),
  ('1', 'Ɩ'), ('2', 'ᄅ'), ('3', 'Ɛ'), ('4', 'ㄣ'), ('5', 'ϛ'), ('6', '9'), ('7', 'ㄥ'),
  ('.', '˙'), (',', "'"), ('?', '¿'), ('!', '¡'), ('"', '„'), ('(', ')'), ('[', ']'), ('{', '}'),
  ('<', '>'), ('&', '⅋'), ('_', '‾'), (';', '؛'), ('‿', '⁀'),
];

/// [kUpsideDownPairs] as one map, both ways. Throws when a character is in two
/// pairs or a code point is not assigned in [chars].
Map<String, String> buildUpsideDown(Map<int, UnicodeChar> chars) {
  final out = <String, String>{};
  void put(String a, String b) {
    if (out.containsKey(a) && out[a] != b) throw StateError('"$a" is in two upside-down pairs');
    out[a] = b;
  }

  for (final (a, b) in kUpsideDownPairs) {
    for (final r in [...a.runes, ...b.runes]) {
      if (!chars.containsKey(r)) throw StateError('U+${r.toRadixString(16)} in the upside-down pairs is not assigned');
    }
    put(a, b);
    put(b, a);
  }
  return out;
}

/// The combining marks the Zalgo style stacks: the ones in Combining
/// Diacritical Marks that sit above (class 230) or below (class 220).
({List<int> above, List<int> below}) zalgoMarks(Map<int, UnicodeChar> chars) {
  final above = <int>[], below = <int>[];
  for (var cp = 0x300; cp <= 0x36F; cp++) {
    final c = chars[cp];
    if (c == null || c.category != 'Mn') continue;
    if (c.combiningClass == 230) above.add(cp);
    if (c.combiningClass == 220) below.add(cp);
  }
  return (above: above, below: below);
}

Map<String, Object?> buildTextStyles(Map<int, UnicodeChar> chars, Map<int, int> reservedPointers, List<PinnedSource> sources) {
  final z = zalgoMarks(chars);
  final tables = buildStyleTables(chars, reservedPointers);
  return {
    'format': 1,
    'unicode': kUnicodeVersion,
    'sources': [for (final s in sources) s.toJson()],
    'tables': {
      for (final e in tables.entries)
        e.key: Map.fromEntries(e.value.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
    },
    'upsideDown': Map.fromEntries(buildUpsideDown(chars).entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
    'zalgoAbove': z.above,
    'zalgoBelow': z.below,
  };
}

// ---------------------------------------------------------------------------
// Keywords.

/// Search words for emoji and symbols from CLDR's English annotations, keyed
/// by the character without U+FE0F. Skin tone and hair variants are left out:
/// search finds the base emoji, and the tone row does the rest.
Map<String, Object?> buildKeywords(String annotations, String derived, List<PinnedSource> sources) {
  final out = <String, List<String>>{};
  void add(String json, String root) {
    final map = ((jsonDecode(json) as Map)[root] as Map)['annotations'] as Map;
    for (final e in map.entries) {
      final key = (e.key as String).replaceAll('️', '');
      if (key.runes.any((r) => (r >= 0x1F3FB && r <= 0x1F3FF) || (r >= 0x1F9B0 && r <= 0x1F9B3))) continue;
      final words = [for (final w in ((e.value as Map)['default'] as List? ?? const [])) (w as String).toLowerCase()];
      final tts = [for (final w in ((e.value as Map)['tts'] as List? ?? const [])) (w as String).toLowerCase()];
      final all = <String>{...words, ...tts}.toList();
      if (all.isNotEmpty) (out[key] ??= []).addAll(all.where((w) => !(out[key] ?? const []).contains(w)));
    }
  }

  add(annotations, 'annotations');
  add(derived, 'annotationsDerived');
  final keys = out.keys.toList()..sort();
  return {
    'format': 1,
    'cldr': kCldrVersion,
    'sources': [for (final s in sources) s.toJson()],
    'keywords': {for (final k in keys) k: out[k]},
  };
}

// ---------------------------------------------------------------------------

Future<({String text, String sha256})> _fetch(PinnedSource s, Directory cache) async {
  final file = File('${cache.path}/${s.name}');
  if (!file.existsSync()) {
    stdout.writeln('Downloading ${s.url}');
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(s.url));
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('${res.statusCode} for ${s.url}');
      final bytes = <int>[];
      await for (final chunk in res) {
        bytes.addAll(chunk);
      }
      file.writeAsBytesSync(bytes);
    } finally {
      client.close();
    }
  }
  final bytes = file.readAsBytesSync();
  final hash = sha256.convert(bytes).toString();
  if (s.sha256.isEmpty) {
    stdout.writeln('PIN ${s.name}: $hash');
  } else if (hash != s.sha256) {
    throw StateError('${s.name} does not match its pinned SHA-256 (got $hash). Delete ${file.path} to download it again, or pin the new file (README.md).');
  }
  return (text: utf8.decode(bytes), sha256: hash);
}

Future<void> main(List<String> args) async {
  final cache = Directory('.dart_tool/character_sources')..createSync(recursive: true);
  final text = <String, String>{};
  final recorded = <PinnedSource>[];
  for (final s in kSources) {
    final got = await _fetch(s, cache);
    text[s.name] = got.text;
    // The JSON records the hash of the file actually read.
    recorded.add(PinnedSource(s.name, s.url, got.sha256, version: s.version));
  }
  List<PinnedSource> only(List<String> names) => [for (final s in recorded) if (names.contains(s.name)) s];

  final blocks = parseBlocks(text['Blocks.txt']!);
  final chars = parseUnicodeData(text['UnicodeData.txt']!);
  final names = parseNamesList(text['NamesList.txt']!);
  final alt = altCodesFrom(
    cp1252: parseCodePage(text['CP1252.TXT']!),
    cp437: parseCodePage(text['CP437.TXT']!),
    ibmGraph: parseCodePage(text['IBMGRAPH.TXT']!, unicodeFirst: true),
  );

  const encoder = JsonEncoder();
  final out = Directory('assets/characters')..createSync(recursive: true);
  final symbols = buildSymbols(
    blocks: blocks,
    chars: chars,
    sections: names.sections,
    altCodes: alt,
    sources: only(['Blocks.txt', 'UnicodeData.txt', 'NamesList.txt', 'CP437.TXT', 'CP1252.TXT', 'IBMGRAPH.TXT']),
  );
  File('${out.path}/symbols.json').writeAsStringSync(encoder.convert(symbols));
  File('${out.path}/text_styles.json').writeAsStringSync(encoder.convert(buildTextStyles(chars, names.reservedPointers, only(['UnicodeData.txt', 'NamesList.txt']))));
  File('${out.path}/keywords.json').writeAsStringSync(encoder.convert(buildKeywords(text['annotations.json']!, text['annotationsDerived.json']!, only(['annotations.json', 'annotationsDerived.json']))));
  File('${out.path}/LICENSE-Unicode.txt').writeAsStringSync(text['license.txt']!);

  // The gate tests hold the JSON to these copies.
  final fixtures = Directory('test/fixtures/unicode')..createSync(recursive: true);
  File('${fixtures.path}/Blocks.txt').writeAsStringSync(text['Blocks.txt']!);
  File('${fixtures.path}/UnicodeData.txt').writeAsStringSync(text['UnicodeData.txt']!);

  var cells = 0;
  for (final b in symbols['blocks'] as List) {
    for (final s in (b as Map)['sections'] as List) {
      cells += ((s as Map)['chars'] as List).length;
    }
  }
  stdout.writeln('Wrote ${(symbols['blocks'] as List).length} blocks, $cells symbols, Unicode $kUnicodeVersion, CLDR $kCldrVersion.');
}
