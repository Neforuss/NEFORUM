// 1.4.3: symbols. The device check that keeps empty boxes out of the character
// panel, on the real engine: a character the font draws differs from the "no
// glyph" box, one it does not have is that box. `flutter test` falls back to its
// own test font, whose box stands in for a device's missing glyph.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/glyph_support.dart';

void main() {
  setUp(GlyphSupport.debugReset);
  tearDown(GlyphSupport.debugReset);

  testWidgets('a character in the font draws; one it lacks, and an unassigned one, do not', (t) async {
    final bytes = File('assets/fonts/Inter-Regular.ttf').readAsBytesSync();
    await t.runAsync(() async {
      final loader = FontLoader('Glyph check Inter')..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    });
    const style = TextStyle(fontFamily: 'Glyph check Inter');
    final r = (await t.runAsync(() => GlyphSupport.probe(['A', 'é', '€', '⣿', '♜', '\u{1FAFE}'], style: style)))!;
    expect(r['A'], isTrue);
    expect(r['é'], isTrue);
    expect(r['€'], isTrue);
    expect(r['⣿'], isFalse, reason: 'Inter has no Braille');
    expect(r['♜'], isFalse, reason: 'nor chess pieces');
    expect(r['\u{1FAFE}'], isFalse, reason: 'nothing draws an unassigned code point');
    expect(GlyphSupport.known('A'), isTrue, reason: 'remembered for the rest of the run');
  });

  testWidgets('more than one row of cells is read right', (t) async {
    final bytes = File('assets/fonts/Inter-Regular.ttf').readAsBytesSync();
    await t.runAsync(() async {
      final loader = FontLoader('Glyph check Inter 2')..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    });
    const style = TextStyle(fontFamily: 'Glyph check Inter 2');
    final letters = [for (var c = 0x41; c <= 0x5A; c++) String.fromCharCode(c)];
    final braille = [for (var c = 0x2801; c <= 0x2810; c++) String.fromCharCode(c)];
    final mixed = [for (var i = 0; i < 16; i++) ...[letters[i], braille[i]]];
    final r = (await t.runAsync(() => GlyphSupport.probe(mixed, style: style)))!;
    for (var i = 0; i < 16; i++) {
      expect(r[letters[i]], isTrue, reason: letters[i]);
      expect(r[braille[i]], isFalse, reason: 'U+${braille[i].runes.single.toRadixString(16)}');
    }
  });

  testWidgets('the test hook answers without drawing', (t) async {
    GlyphSupport.debugProbe = (c) => c == 'x';
    final r = await GlyphSupport.probe(['x', 'y']);
    expect(r, {'x': true, 'y': false});
  });
}
