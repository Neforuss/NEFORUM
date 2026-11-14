// The catalog interface: groups per tab, lookup, search in the Symbols and
// Kaomoji tabs, and what an entry says about itself.
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import 'catalog_files.dart';

void main() {
  final c = bundledCatalog;

  test('the Symbols tab: sets first (Popular leading), then the blocks; no groups for Emoji or Text styles', () {
    final groups = c.groups(CharacterTab.symbols);
    expect(groups.first.id, 'popular');
    final firstBlock = groups.indexWhere((g) => g.isBlock);
    expect(groups.skip(firstBlock).every((g) => g.isBlock), isTrue);
    expect(groups.where((g) => g.isBlock).first.title, 'Latin-1 Supplement');
    expect(c.groups(CharacterTab.emoji), isEmpty);
    expect(c.groups(CharacterTab.textStyles), isEmpty);
    expect(c.groups(CharacterTab.kaomoji).map((g) => g.title), containsAll(['Joy', 'Shrug', 'Table flip', 'Dividers']));
  });

  test('an entry names itself, with its code points, HTML code and Alt code', () {
    final heart = c.entryFor('♥')!;
    expect(heart.name, 'Black heart suit');
    expect(heart.codePoints, 'U+2665');
    expect(heart.htmlCode, '&#9829;');
    expect(heart.altCode, '3');
    expect(heart.keywords, contains('card'));
    expect(c.entryFor('¯\\_(ツ)_/¯')!.name, 'Shrug');
    expect(c.entryFor('not a character'), isNull);
  });

  group('search', () {
    List<String> symbols(String q) => [for (final e in c.search(q, CharacterTab.symbols)) e.text];

    test('a whole word of the name comes before a word that only starts with it', () {
      final found = symbols('heart');
      expect(found.take(10), contains('♥'));
      expect(found.indexOf('♥'), lessThan(found.indexOf('❥')), reason: '"heart" exactly before "hearts" or a longer word');
    });

    test('every word has to fit', () {
      expect(symbols('black heart'), contains('♥'));
      expect(symbols('black heart'), isNot(contains('♡')));
    });

    test('by code point, by Alt code, by the character itself, by CLDR word', () {
      expect(symbols('u+2665').first, '♥');
      expect(symbols('2665').first, '♥');
      expect(symbols('alt+0169'), ['©']);
      expect(symbols('alt3'), ['♥']);
      expect(symbols('©').first, '©');
      expect(symbols('copyright').first, '©');
    });

    test('each character once, even when it is in a set and in its block', () {
      final found = symbols('star');
      expect(found.toSet(), hasLength(found.length));
    });

    test('kaomoji by their group and its words', () {
      final found = [for (final e in c.search('shrug', CharacterTab.kaomoji)) e.text];
      expect(found, contains('¯\\_(ツ)_/¯'));
      expect([for (final e in c.search('happy', CharacterTab.kaomoji)) e.text], contains('(＾▽＾)'));
      expect(c.search('   ', CharacterTab.kaomoji), isEmpty);
    });

    test('a limit keeps a broad search short', () {
      expect(c.search('a', CharacterTab.symbols, limit: 50), hasLength(50));
    });
  });
}
