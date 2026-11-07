// Emoji on the pictures NEFORUM publishes. `flutter test` has no real fonts, so
// the colour checks load real files: the bundled Inter, and the system's emoji
// font where this machine has one (Windows, or Noto Color Emoji on a Linux
// runner). Without one they are skipped; the logic checks run everywhere.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/aligned_text.dart';
import 'package:neforum_app/media/caption_fonts.dart';
import 'package:neforum_app/media/caption_overlay.dart';
import 'package:neforum_app/media/caption_style.dart';
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/card_renderer.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/media/emoji_text.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/state/render_warnings.dart';
import 'package:neforum_app/state/settings.dart' show TextCardAlignment;
import 'package:neforum_app/theme/tokens.dart';

const String redHeart = '\u2764\uFE0F';
const String keycap = '1\uFE0F\u20E3';
const String grin = '\u{1F600}';
const String unassigned = '\u{1FAFE}';

/// The system's colour emoji font file, if this machine has a known one.
final String? emojiFontFile = () {
  for (final path in [
    r'C:\Windows\Fonts\seguiemj.ttf',
    '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf',
    '/System/Library/Fonts/Apple Color Emoji.ttc',
  ]) {
    if (File(path).existsSync()) return path;
  }
  return null;
}();

final bool windowsFonts = File(r'C:\Windows\Fonts\arial.ttf').existsSync();

Future<void> _load(String family, List<String> files) async {
  final present = [for (final f in files) if (File(f).existsSync()) f];
  if (present.isEmpty) return;
  final loader = FontLoader(family);
  for (final f in present) {
    loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  await _load('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await _load('Arial', [r'C:\Windows\Fonts\arial.ttf', r'C:\Windows\Fonts\arialbd.ttf']);
  await _load('Custom Mono', ['assets/fonts/JetBrainsMono-Regular.ttf']);
  // Under the first name in the list, whichever system this is.
  await _load(kEmojiFontFamilies.first, [emojiFontFile!]);
}

({int coloured, int ink}) _measure(Uint8List rgba) {
  var coloured = 0, ink = 0;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final a = rgba[i + 3];
    if (a < 40) continue;
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    final hi = [r, g, b].reduce((x, y) => x > y ? x : y), lo = [r, g, b].reduce((x, y) => x < y ? x : y);
    if (lo < 200) ink++;
    if (hi - lo > 40) coloured++;
  }
  return (coloured: coloured, ink: ink);
}

Future<Uint8List> _rgba(int w, int h, void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFFFFFFFF));
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  image.dispose();
  return data!.buffer.asUint8List();
}

CardDesign _design(String words) {
  final template = cardTemplateById('neon')!.design(CardKind.text);
  return template.copyWith(blocks: [
    CardTextBlock(role: CardBlockRole.postText, text: words, anchor: CardAnchor.topLeft, color: 0xFF000000, size: 120, font: TextCardFont.original),
  ]);
}

/// A card with [words], its pixels, drawn the way each of the four styles draws.
Future<Uint8List> _styled(String style, String words) => _rgba(600, 600, (canvas) {
      const size = Size(600, 600);
      switch (style) {
        case 'classic Inter':
          TextCardPainter(text: words, theme: TextCardTheme.light, branded: false).paint(canvas, size);
        case 'classic Arial':
          TextCardPainter(text: words, theme: TextCardTheme.light, branded: false, font: TextCardFont.arial).paint(canvas, size);
        case 'custom font':
          TextCardPainter(text: words, theme: TextCardTheme.light, branded: false, customFont: _custom).paint(canvas, size);
        case 'designed':
          CardDesignPainter(design: _design(words), texts: {CardBlockRole.postText: words}).paint(canvas, size);
      }
    });

const CaptionFont _custom = CaptionFont(family: 'Custom Mono');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(EmojiSupport.debugReset);
  tearDown(() {
    EmojiSupport.debugReset();
    debugResetCaptionFonts();
  });

  group('runs', () {
    const base = TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 20);

    test('text with no emoji is the plain span it always was', () {
      for (final words in ['plain words', 'caf\u00E9 \u4E2D\u6587', '1 2 # * \u00A9 \u2764']) {
        final span = emojiSpan(words, base);
        expect(span.text, words);
        expect(span.children, isNull, reason: words);
        expect(span.style, base);
      }
    });

    test('each emoji is its own run with the emoji font first; the words are whole', () {
      final span = emojiSpan('I $redHeart this $grin', base);
      expect(span.toPlainText(), 'I $redHeart this $grin');
      final runs = span.children!.cast<TextSpan>();
      expect(runs.map((r) => r.text), ['I ', redHeart, ' this ', grin]);
      expect(runs[1].style!.fontFamily, kEmojiFontFamilies.first);
      expect(runs[1].style!.fontFamilyFallback, kEmojiFontFamilies.skip(1), reason: "the words' font has a heart of its own, so it is not in the run");
      expect(runs[1].style!.fontWeight, FontWeight.w400, reason: 'never synthesized bold');
      expect(runs[0].style, isNull, reason: 'the words take the parent style');
    });

    test('a keycap, a flag, a skin tone and a family are one run each', () {
      for (final e in [keycap, '\u{1F1FA}\u{1F1F8}', '\u{1F44D}\u{1F3FD}', '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}']) {
        final runs = emojiSpan('a${e}b', base).children!.cast<TextSpan>();
        expect(runs.map((r) => r.text), ['a', e, 'b']);
      }
    });

    test('neighbouring emoji share a run', () {
      final runs = emojiSpan('$grin$grin', base).children!.cast<TextSpan>();
      expect(runs.single.text, '$grin$grin');
    });

    test('a field keeps every character, known to be missing or not', () async {
      EmojiSupport.debugProbe = (_) => EmojiDraw.missing;
      await EmojiSupport.probe(grin);
      expect(emojiSpan('a${grin}b', base, dropMissing: false).toPlainText(), 'a${grin}b');
      expect(emojiSpan('a${grin}b', base).toPlainText(), 'ab');
    });
  });

  test('classic cards fall back to the same fonts as designed ones (B2)', () {
    final style = TextCardFont.original.style(fontSize: 20);
    expect(style.fontFamilyFallback, containsAll(kCaptionFontFallbacks));
    final arial = TextCardFont.arial.style(fontSize: 20);
    expect(arial.fontFamilyFallback, containsAll(['Helvetica', ...kCaptionFontFallbacks]));
  });

  group('an emoji this device cannot draw (B3)', () {
    late StreamSubscription<String> sub;
    late List<String> warnings;

    setUp(() {
      warnings = [];
      sub = renderWarnings.listen(warnings.add);
    });
    tearDown(() => sub.cancel());

    testWidgets('raises one warning per emoji and use, and leaves the picture without it', (t) async {
      EmojiSupport.debugProbe = (c) => c == '\u{1FAE0}' ? EmojiDraw.missing : EmojiDraw.whole;
      await EmojiSupport.prepare('hello \u{1FAE0} $grin');
      await EmojiSupport.prepare('again \u{1FAE0}');
      await t.pump();
      expect(warnings.length, 1);
      expect(warnings.single, contains('melting face'));
      expect(warnings.single, contains('leaves it out'));
      expect(AlignedText('a\u{1FAE0}b$grin', style: const TextStyle(), alignment: TextCardAlignment.left, direction: TextDirection.ltr).text, 'ab$grin');
    });

    testWidgets('an emoji that draws in pieces is kept, and says so', (t) async {
      EmojiSupport.debugProbe = (c) => EmojiDraw.parts;
      await EmojiSupport.prepare('\u{1F1FA}\u{1F1F8}', usage: 'the text card');
      await t.pump();
      expect(warnings.single, contains('in pieces'));
      expect(EmojiSupport.withoutMissing('\u{1F1FA}\u{1F1F8}'), '\u{1F1FA}\u{1F1F8}');
    });

    testWidgets('a saved text card tries the emoji first, before it draws', (t) async {
      EmojiSupport.debugProbe = (c) => EmojiDraw.missing;
      await t.runAsync(() => renderTextCardJpeg(text: 'hello \u{1FAE0}', theme: TextCardTheme.light, size: const Size(200, 200)));
      await t.pump();
      expect(warnings.single, contains('the text card'));
      expect(EmojiSupport.known('\u{1FAE0}'), EmojiDraw.missing);
    });

    testWidgets('a saved designed card does too', (t) async {
      EmojiSupport.debugProbe = (c) => EmojiDraw.missing;
      await t.runAsync(() => renderCardDesign(CardRenderInput(design: _design('x'), size: const Size(200, 200), texts: const {CardBlockRole.postText: 'hi \u{1FAE0}'})));
      await t.pump();
      expect(warnings.single, contains('the text card'));
    });

    testWidgets('a caption on a photo style does too', (t) async {
      EmojiSupport.debugProbe = (c) => EmojiDraw.missing;
      await t.runAsync(() => renderCaptionBlockOverlay(text: 'hi \u{1FAE0}', style: const CaptionStyle(), platformId: 'instagram', frameAspect: 0.8));
      await t.pump();
      expect(warnings.single, contains('the caption'));
    });

    testWidgets('a caption of nothing but such emoji leaves no empty label on the photo', (t) async {
      EmojiSupport.debugProbe = (c) => EmojiDraw.missing;
      await EmojiSupport.prepare('\u{1FAE0}', usage: 'the caption on the photo');
      void caption(Canvas c, String words) => CaptionOverlayPainter(text: words, font: TextCardFont.original, style: const CaptionStyle()).paint(c, const Size(300, 300));
      final withIt = (await t.runAsync(() => _rgba(300, 300, (c) => caption(c, '\u{1FAE0}'))))!;
      final without = (await t.runAsync(() => _rgba(300, 300, (c) => caption(c, ''))))!;
      expect(withIt, without);
    });

    test('text with no emoji costs no try and no warning', () async {
      var tries = 0;
      EmojiSupport.debugProbe = (c) {
        tries++;
        return EmojiDraw.whole;
      };
      await EmojiSupport.prepare('plain words 123');
      EmojiSupport.note('plain words 123');
      expect(tries, 0);
      expect(warnings, isEmpty);
    });
  });

  group('with real font files', () {
    final skip = emojiFontFile == null ? 'no colour emoji font on this machine' : null;

    testWidgets('a red heart draws in colour on all four card styles (B1)', (t) async {
      await t.runAsync(_loadFonts);
      debugMarkCaptionFontRegistered(_custom);
      // Under the Inter that owns U+2764, in the same style.
      final styles = ['classic Inter', if (windowsFonts) 'classic Arial', 'custom font', 'designed'];
      for (final style in styles) {
        final heart = _measure((await t.runAsync(() => _styled(style, redHeart)))!);
        final plain = _measure((await t.runAsync(() => _styled(style, 'x')))!);
        expect(heart.coloured - plain.coloured, greaterThan(200), reason: '$style: coloured ${heart.coloured}, without it ${plain.coloured}');
      }
    }, skip: skip != null);

    testWidgets('the same heart without the fix would be black: the plain Inter glyph has no colour', (t) async {
      await t.runAsync(_loadFonts);
      final black = _measure((await t.runAsync(() => _rgba(300, 300, (c) {
            final p = TextPainter(text: const TextSpan(text: redHeart, style: TextStyle(fontFamily: 'Inter', fontFamilyFallback: ['Segoe UI Emoji'], fontSize: 120, color: Color(0xFF000000))), textDirection: TextDirection.ltr)..layout();
            p.paint(c, Offset.zero);
          })))!);
      expect(black.coloured, lessThan(50), reason: 'this is the bug the emoji run works around');
      expect(black.ink, greaterThan(100));
    }, skip: skip != null || !File('assets/fonts/Inter-Regular.ttf').existsSync());

    testWidgets('a keycap draws through the emoji run on classic cards (B2)', (t) async {
      await t.runAsync(_loadFonts);
      final withKeycap = _measure((await t.runAsync(() => _styled('classic Inter', keycap)))!);
      final plain = _measure((await t.runAsync(() => _styled('classic Inter', 'x')))!);
      expect(withKeycap.coloured - plain.coloured, greaterThan(200), reason: 'in colour, not a one-colour box');
    }, skip: skip != null);

    testWidgets('an emoji that is really black or grey counts as drawn, not as a stand-in tile', (t) async {
      await t.runAsync(_loadFonts);
      // A black heart, a chequered flag, a black flag: a colour font's own glyphs.
      for (final e in ['\u{1F5A4}', '\u{1F3C1}', '\u{1F3F4}']) {
        expect((await t.runAsync(() => EmojiSupport.probe(e)))!, EmojiDraw.whole, reason: e.runes.first.toRadixString(16));
      }
    }, skip: skip != null);

    testWidgets('an emoji no font has is reported missing and leaves no tile on the card (B3)', (t) async {
      await t.runAsync(_loadFonts);
      final draw = (await t.runAsync(() => EmojiSupport.probe(unassigned)))!;
      expect(draw, EmojiDraw.missing);
      expect((await t.runAsync(() => EmojiSupport.probe(grin)))!, EmojiDraw.whole);
      final warnings = <String>[];
      final sub = renderWarnings.listen(warnings.add);
      addTearDown(sub.cancel);
      await t.runAsync(() => EmojiSupport.prepare('word $unassigned', usage: 'the text card'));
      await t.pump();
      expect(warnings.single, contains('cannot draw'));
      for (final style in ['classic Inter', 'designed']) {
        final withIt = (await t.runAsync(() => _styled(style, 'word $unassigned')))!;
        final without = (await t.runAsync(() => _styled(style, 'word ')))!;
        expect(withIt, without, reason: '$style: same picture as without it, so no tile and no box');
      }
    }, skip: skip != null);

    testWidgets('colour survives a card saved the real way', (t) async {
      await t.runAsync(_loadFonts);
      final coloured = await t.runAsync(() async {
        final jpeg = await renderTextCardJpeg(text: redHeart, theme: TextCardTheme.light, size: const Size(400, 400), branded: false);
        final codec = await ui.instantiateImageCodec(jpeg);
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        frame.image.dispose();
        codec.dispose();
        return _measure(data!.buffer.asUint8List()).coloured;
      });
      expect(coloured, greaterThan(200), reason: 'the saved JPEG holds the red heart');
      expect(Fonts.body, 'Inter');
    }, skip: skip != null);
  });

  test('a card with no emoji is unchanged: AlignedText keeps the words as given', () {
    final a = AlignedText('plain', style: const TextStyle(), alignment: TextCardAlignment.left, direction: TextDirection.ltr);
    expect(a.text, 'plain');
    expect(EmojiSupport.withoutMissing('plain'), 'plain');
  });

  test('CaptionOverlayPainter takes emoji through the same words path', () {
    expect(CaptionOverlayPainter(text: grin, font: TextCardFont.original, style: const CaptionStyle()).text, grin);
  });
}
