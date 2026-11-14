// The generated catalog held to Unicode's own files (vendored under
// test/fixtures/unicode by tool/generate_character_catalog.dart): no range,
// name or mapping in the JSON is trusted on its own.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../../tool/generate_character_catalog.dart';
import 'catalog_files.dart';

void main() {
  final blocks = parseBlocks(unicodeFixture('Blocks.txt'));
  final chars = parseUnicodeData(unicodeFixture('UnicodeData.txt'));
  final symbols = catalogJson('symbols.json');
  final styles = catalogJson('text_styles.json');

  group('sources', () {
    test('the JSON was made from exactly the vendored Blocks.txt and UnicodeData.txt', () {
      for (final json in [symbols, styles]) {
        final recorded = {for (final s in (json['sources'] as List).cast<Map<String, Object?>>()) s['file']: s['sha256']};
        expect(recorded['UnicodeData.txt'], sha256.convert(utf8.encode(unicodeFixture('UnicodeData.txt'))).toString());
        expect(json['unicode'], kUnicodeVersion);
      }
      final recorded = {for (final s in (symbols['sources'] as List).cast<Map<String, Object?>>()) s['file']: s['sha256']};
      expect(recorded['Blocks.txt'], sha256.convert(utf8.encode(unicodeFixture('Blocks.txt'))).toString());
    });

    test('every pinned source has a SHA-256 and a version', () {
      for (final s in kSources) {
        expect(s.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: s.name);
        expect(s.version, isNotEmpty, reason: s.name);
      }
    });

    test('the Unicode version matches the vendored emoji-test.txt', () {
      final emojiVersion = RegExp(r'# Version: (\S+)').firstMatch(unicodeFixture('emoji-test.txt'))![1];
      expect(kUnicodeVersion, startsWith('$emojiVersion.'));
    });
  });

  group('Symbols', () {
    final jsonBlocks = (symbols['blocks'] as List).cast<Map<String, Object?>>();

    test('the blocks are the chosen ones, in order, with the ranges Blocks.txt gives', () {
      expect([for (final b in jsonBlocks) b['name']], kSymbolBlocks);
      for (final b in jsonBlocks) {
        final real = blocks.singleWhere((x) => x.name == b['name']);
        expect(b['first'], real.first, reason: '${b['name']}');
        expect(b['last'], real.last, reason: '${b['name']}');
      }
    });

    test('every assigned graphic character of each block is a cell, and nothing else', () {
      var total = 0;
      for (final b in jsonBlocks) {
        final first = b['first'] as int, last = b['last'] as int;
        final expected = [
          for (var cp = first; cp <= last; cp++)
            if (chars[cp] case final c? when isInsertableCategory(c.category)) cp,
        ];
        final cells = [
          for (final s in (b['sections'] as List).cast<Map<String, Object?>>())
            for (final c in (s['chars'] as List).cast<List<Object?>>()) c[0] as int,
        ];
        expect(cells, expected, reason: '${b['name']}');
        total += cells.length;
      }
      expect(total, bundledCatalog.groups(CharacterTab.symbols).where((g) => g.isBlock).expand((g) => g.entries).length);
      expect(total, greaterThan(5000));
    });

    test('names are UnicodeData\'s, and no control, format, space or lone combining mark is a cell', () {
      for (final g in bundledCatalog.groups(CharacterTab.symbols).where((g) => g.isBlock)) {
        for (final e in g.entries) {
          final c = chars[e.text.runes.single]!;
          expect(e.name, sentenceCase(c.name));
          expect(const ['Cc', 'Cf', 'Co', 'Cs', 'Cn', 'Zs', 'Zl', 'Zp', 'Mn', 'Me'], isNot(contains(c.category)), reason: e.name);
        }
      }
    });

    test('every set holds only cells of the blocks, and is not empty', () {
      final cells = {for (final g in bundledCatalog.groups(CharacterTab.symbols).where((g) => g.isBlock)) ...g.entries.map((e) => e.text)};
      final sets = bundledCatalog.groups(CharacterTab.symbols).where((g) => !g.isBlock).toList();
      expect(sets.first.title, 'Popular');
      for (final s in sets) {
        expect(s.entries, isNotEmpty, reason: s.title);
        expect(s.entries.map((e) => e.text).where((t) => !cells.contains(t)), isEmpty, reason: s.title);
      }
      final raw = (symbols['sets'] as List).cast<Map<String, Object?>>();
      for (final s in raw) {
        expect(bundledCatalog.groups(CharacterTab.symbols).singleWhere((g) => g.id == s['id']).entries.length, (s['chars'] as List).length,
            reason: 'every code point of ${s['id']} resolves to a cell');
      }
    });

    test('Alt codes: Windows-1252 with Alt+0, code page 437 and IBM\'s pictures without', () {
      String? alt(String c) => bundledCatalog.entryFor(c)?.altCode;
      expect(alt('©'), '0169');
      expect(alt('é'), '0233', reason: 'Windows-1252 first');
      expect(alt('€'), '0128');
      expect(alt('♥'), '3');
      expect(alt('☺'), '1');
      expect(alt('⌂'), '127');
      expect(alt('░'), '176');
      expect(alt('½'), '0189');
      expect(alt('➜'), isNull);
    });
  });

  group('Text styles', () {
    final tables = (styles['tables'] as Map).map((k, v) => MapEntry('$k', (v as Map).map((a, b) => MapEntry('$a', '$b'))));
    const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
    int one(String s) => s.runes.single;

    test('every table style of the tab has a table, and every table a style', () {
      final tableKinds = {for (final k in TextStyleKind.values) if (k.method == TextStyleMethod.table) k.name};
      expect(tables.keys.toSet(), tableKinds);
    });

    test('the mathematical alphabets: all 52 letters each, Unicode\'s <font> letter, gaps from Letterlike Symbols', () {
      final letterlike = blocks.singleWhere((b) => b.name == 'Letterlike Symbols');
      final math = blocks.singleWhere((b) => b.name == 'Mathematical Alphanumeric Symbols');
      var gaps = 0;
      for (final style in kMathStyles.keys) {
        final t = tables[style]!;
        for (final l in letters.split('')) {
          final styled = t[l];
          expect(styled, isNotNull, reason: '$style $l');
          final c = chars[one(styled!)]!;
          expect(c.decomposition, '<font> ${l.codeUnitAt(0).toRadixString(16).toUpperCase().padLeft(4, '0')}', reason: '$style $l');
          if (c.cp >= letterlike.first && c.cp <= letterlike.last) {
            gaps++;
          } else {
            expect(c.cp, inInclusiveRange(math.first, math.last));
            expect(c.name, startsWith('MATHEMATICAL ${kMathStyles[style]} '), reason: '$style $l');
          }
        }
      }
      expect(gaps, 24, reason: 'script 11, fraktur 5, double-struck 7, italic h 1');
    });

    test('the gap letters Unicode points elsewhere', () {
      expect(one(tables['script']!['B']!), 0x212C);
      expect(one(tables['script']!['e']!), 0x212F);
      expect(one(tables['fraktur']!['H']!), 0x210C);
      expect(one(tables['doubleStruck']!['C']!), 0x2102);
      expect(one(tables['italic']!['h']!), 0x210E, reason: 'PLANCK CONSTANT');
    });

    test('digits where Unicode has them, by <font>', () {
      for (final style in ['bold', 'doubleStruck', 'sans', 'sansBold', 'monospace']) {
        for (var d = 0; d <= 9; d++) {
          final c = chars[one(tables[style]!['$d']!)]!;
          expect(c.decomposition, '<font> 003$d', reason: '$style $d');
        }
      }
      expect(tables['italic']!.containsKey('1'), isFalse, reason: 'no italic digits in Unicode');
    });

    void tagged(String style, String tag, {bool folded = false}) {
      final t = tables[style]!;
      expect(t, isNotEmpty);
      for (final e in t.entries) {
        final c = chars[one(e.value)]!;
        final target = folded ? e.key.toUpperCase() : e.key;
        expect(c.decomposition, '<$tag> ${target.codeUnitAt(0).toRadixString(16).toUpperCase().padLeft(4, '0')}', reason: '$style ${e.key}');
      }
    }

    test('fullwidth, circled, squared, superscript and subscript follow their decompositions', () {
      tagged('fullwidth', 'wide');
      tagged('circled', 'circle');
      tagged('squared', 'square', folded: true);
      tagged('superscript', 'super');
      tagged('subscript', 'sub');
      expect(tables['fullwidth']![' '], '　');
      expect(tables['fullwidth']!.length, 95, reason: 'all of printable ASCII');
    });

    test('parenthesized follows <compat> ( x )', () {
      for (final e in tables['parenthesized']!.entries) {
        final hex = e.key.codeUnitAt(0).toRadixString(16).toUpperCase().padLeft(4, '0');
        expect(chars[one(e.value)]!.decomposition, '<compat> 0028 $hex 0029', reason: e.key);
      }
    });

    test('small capitals and the filled circles and squares follow their names', () {
      for (final e in tables['smallCaps']!.entries) {
        expect(chars[one(e.value)]!.name, 'LATIN LETTER SMALL CAPITAL ${e.key.toUpperCase()}');
      }
      for (final e in tables['squaredNegative']!.entries) {
        expect(chars[one(e.value)]!.name, 'NEGATIVE SQUARED LATIN CAPITAL LETTER ${e.key.toUpperCase()}');
      }
      for (final e in tables['circledNegative']!.entries.where((e) => RegExp('[A-Za-z]').hasMatch(e.key))) {
        expect(chars[one(e.value)]!.name, 'NEGATIVE CIRCLED LATIN CAPITAL LETTER ${e.key.toUpperCase()}');
      }
      expect(tables['circledNegative']!['1'], '❶');
    });

    test('a letter a style has no form for stays plain', () {
      final ts = bundledCatalog.textStyles;
      for (final kind in TextStyleKind.values.where((k) => k.method == TextStyleMethod.table)) {
        for (final l in '${letters}0123456789'.split('')) {
          if (tables[kind.name]!.containsKey(l)) continue;
          expect(ts.apply(kind, l), l, reason: '${kind.name} $l');
        }
      }
      expect(tables['smallCaps']!.containsKey('x'), isFalse, reason: 'Unicode has no small capital X');
    });

    test('every upside-down character is assigned, and the map is its own inverse', () {
      final map = (styles['upsideDown'] as Map).map((k, v) => MapEntry('$k', '$v'));
      expect(map.length, kUpsideDownPairs.length * 2);
      for (final e in map.entries) {
        for (final r in [...e.key.runes, ...e.value.runes]) {
          expect(chars.containsKey(r), isTrue, reason: 'U+${r.toRadixString(16)}');
        }
        expect(map[e.value], e.key);
      }
    });

    test('Zalgo marks are the combining marks of U+0300 to U+036F that sit above or below', () {
      for (final key in ['zalgoAbove', 'zalgoBelow']) {
        final marks = (styles[key] as List).cast<int>();
        expect(marks, isNotEmpty);
        for (final m in marks) {
          final c = chars[m]!;
          expect(m, inInclusiveRange(0x300, 0x36F));
          expect(c.category, 'Mn');
          expect(c.combiningClass, key == 'zalgoAbove' ? 230 : 220);
        }
      }
    });
  });

  group('keywords', () {
    test('come from CLDR for emoji and for symbols', () {
      expect(bundledCatalog.keywordsFor('😀'), contains('grin'));
      expect(bundledCatalog.keywordsFor('❤️'), contains('love'), reason: 'U+FE0F ignored');
      expect(bundledCatalog.keywordsFor('→'), contains('arrow'));
      expect(catalogJson('keywords.json')['cldr'], kCldrVersion);
    });
  });
}
