// 1.3.5: the classic text card's style (TextCardStyle), the "more editing
// power" of the text card editor: its JSON, the render parameters it adds,
// proof that an untouched card is drawn exactly as NEFORUM 1.3.4 drew it
// (goldens recorded from 1.3.4, a frozen copy of the 1.3.4 painter compared
// pixel for pixel, and byte-equal JPEGs), every choice changing the saved
// JPEG where it should, and the style through attachTextCards on several
// networks, a scheduled run, sync and the composer's draft.
//
// Goldens: flutter test test/text_card_style_test.dart --update-goldens

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart' show Bidi;
import 'package:neforum_app/brand/neforum_logo.dart';
import 'package:neforum_app/media/aligned_text.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/photo_composite.dart';
import 'package:neforum_app/media/render_parameters.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/media/text_card_background.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart' show TextCardAlignment;
import 'package:neforum_app/state/text_cards.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  final Map<String, Uint8List> _media = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async {
    final path = 'mem://$id.$extension';
    _media[path] = bytes;
    return path;
  }

  @override
  Future<Uint8List> readMedia(String path) async => _media[path] ?? (throw StateError('No file at $path'));
  @override
  Future<void> deleteMedia(String path) async => _media.remove(path);
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

const _words = 'Short words, set large.\nA second line of them.';
const _long = 'A longer card with many words so the size has to shrink to fit the room the card leaves, '
    'and more words again, and again more of them, until the card is full and has to stop somewhere.';

/// Cards as 1.3.4 made them, at a quarter of their size: (golden name, card).
final _cards1_3_4 = <String, Future<Uint8List> Function()>{
  'instagram-dark-signed': () => renderTextCardJpeg(text: _words, theme: TextCardTheme.dark, size: const Size(270, 338), byline: '@ana@mastodon.social'),
  'bluesky-light-plain': () => renderTextCardJpeg(
      text: _words, theme: TextCardTheme.light, size: const Size(270, 270), byline: '@ana.bsky.social', branded: false, alignment: TextCardAlignment.center),
  'tiktok-safe-no-handle': () => renderTextCardJpeg(
      text: _words, theme: TextCardTheme.dark, size: const Size(270, 480), safe: fullScreenSafeArea('tiktok'), alignment: TextCardAlignment.right),
};

/// NEFORUM 1.3.4's TextCardPainter.paint, frozen here word for word (only
/// its fields became parameters): the reference an untouched 1.3.5 card is
/// compared with, pixel for pixel.
void _paint1_3_4(Canvas canvas, Size size,
    {required String text,
    required TextCardTheme theme,
    String? byline,
    bool branded = true,
    TextCardFont font = TextCardFont.original,
    EdgeInsets safe = EdgeInsets.zero,
    TextCardAlignment alignment = TextCardAlignment.left}) {
  const lineHeight = 1.3;
  TextStyle wordsStyle(double fontSize, Color color) => font.style(fontSize: fontSize, height: lineHeight, color: color);
  final u = size.width / 1080;
  final w = size.width;
  final h = size.height;
  final fg = theme.foreground;
  final pad = 92 * u;
  final safeTop = safe.top * u, safeRight = safe.right * u, safeBottom = safe.bottom * u;
  canvas.drawRect(Offset.zero & size, Paint()..color = theme.background);
  final rule = branded ? 14 * u : 0.0;
  if (branded) {
    canvas.drawRect(Rect.fromLTWH(0, 0, w, rule), Paint()..color = Brand.purple);
    canvas.drawRect(Rect.fromLTWH(0, 0, pad + 120 * u, rule), Paint()..color = Brand.yellow);
  }
  final markSize = 60 * u;
  final footerY = h - safeBottom - 84 * u - markSize;
  final by = byline?.trim() ?? '';
  var authorLeft = pad;
  if (branded) {
    paintNeforumMark(canvas, Rect.fromLTWH(pad, footerY, markSize, markSize));
    final word = TextPainter(
      text: TextSpan(
        text: 'NEFORUM',
        style: TextStyle(fontFamily: Fonts.display, fontWeight: FontWeight.w800, fontSize: 30 * u, letterSpacing: 1.6 * u, color: fg, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final wordX = pad + markSize + 20 * u;
    word.paint(canvas, Offset(wordX, footerY + (markSize - word.height) / 2));
    authorLeft = wordX + word.width + 32 * u;
    word.dispose();
  }
  if (by.isNotEmpty) {
    final room = w - pad - safeRight - authorLeft;
    if (room > 40 * u) {
      final author = TextPainter(
        text: TextSpan(
          text: by,
          style: TextStyle(fontFamily: Fonts.body, fontWeight: FontWeight.w500, fontSize: 26 * u, color: fg.withValues(alpha: 0.62), height: 1.1),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: room);
      author.paint(canvas, Offset(branded ? w - pad - safeRight - author.width : pad, footerY + (markSize - author.height) / 2));
      author.dispose();
    }
  }
  final double bottom;
  if (branded) {
    final dividerY = footerY - 44 * u;
    canvas.drawLine(
      Offset(pad, dividerY),
      Offset(w - pad - safeRight, dividerY),
      Paint()
        ..color = fg.withValues(alpha: 0.16)
        ..strokeWidth = 2 * u,
    );
    bottom = dividerY - 56 * u;
  } else {
    bottom = by.isEmpty ? h - pad - safeBottom : footerY - 40 * u;
  }
  final top = rule + pad + safeTop;
  final areaW = w - pad * 2 - safeRight;
  final areaH = math.max(0.0, bottom - top);
  final rtl = Bidi.detectRtlDirectionality(text);
  AlignedText layout(double fs, {int? maxLines}) => AlignedText(
        text,
        style: wordsStyle(fs, fg),
        alignment: alignment,
        direction: rtl ? TextDirection.rtl : TextDirection.ltr,
        maxLines: maxLines,
      )..layout(areaW, fill: true);
  var fs = 104 * u;
  final minFs = 30 * u;
  var words = layout(fs);
  while (words.height > areaH && fs > minFs) {
    words.dispose();
    fs = math.max(minFs, fs - 4 * u);
    words = layout(fs);
  }
  if (words.height > areaH) {
    final lines = math.max(1, (areaH / (fs * lineHeight)).floor());
    words.dispose();
    words = layout(fs, maxLines: lines);
  }
  final origin = Offset(pad, top + (areaH - words.height) / 2);
  words.paint(canvas, origin);
  words.dispose();
}

/// A card drawn small (360 x 450) for the pixel checks, decoded. Its footer
/// row (the @handle's) is y 402 to 422; above the words, y 35 to 50.
Future<img.Image> _card(WidgetTester tester,
    {String text = 'Hi there.', TextCardStyle style = TextCardStyle.classic, String? byline = '@ana.example.social', bool branded = true}) async {
  final bytes = (await tester.runAsync(
      () => renderTextCardJpeg(text: text, theme: TextCardTheme.dark, size: const Size(360, 450), byline: byline, branded: branded, style: style)))!;
  return img.decodeJpg(bytes)!;
}

/// Pixels in [area] (x, y, width, height) for which [test] holds.
int _count(img.Image image, (int, int, int, int) area, bool Function(img.Pixel p) test) {
  final (x0, y0, w, h) = area;
  var n = 0;
  for (var y = y0; y < y0 + h; y++) {
    for (var x = x0; x < x0 + w; x++) {
      if (test(image.getPixel(x, y))) n++;
    }
  }
  return n;
}

/// Light "ink" on the dark card.
bool _ink(img.Pixel p) => p.r + p.g + p.b > 300;

/// The first row of [area] with ink, from the top.
int _firstInkRow(img.Image image, (int, int, int, int) area) {
  final (x0, y0, w, h) = area;
  for (var y = y0; y < y0 + h; y++) {
    for (var x = x0; x < x0 + w; x++) {
      if (_ink(image.getPixel(x, y))) return y;
    }
  }
  return -1;
}

void main() {
  setUpAll(_loadFonts);

  group('TextCardStyle', () {
    test('the classic style writes nothing, and every choice round-trips', () {
      expect(TextCardStyle.classic.toJson(), isEmpty);
      expect(TextCardStyle.classic.isClassic, isTrue);
      const full = TextCardStyle(
        textSize: 1.4,
        textColor: 0xFFFFD60A,
        backgroundColor: 0xFF3A0CA3,
        textPosition: TextCardTextPosition.bottom,
        lineSpacing: 1.6,
        margin: 140,
        handle: '@neforum',
        handleSize: 1.8,
        handlePosition: TextCardHandlePosition.topLeft,
        handleColor: 0xFFFF3B30,
      );
      expect(TextCardStyle.fromJson(full.toJson()), full);
      expect(full.isClassic, isFalse);
      // Only what differs is written.
      expect(const TextCardStyle(margin: 120).toJson(), {'margin': 120.0});
      expect(TextCardStyle.fromJson(null), TextCardStyle.classic);
      expect(TextCardStyle.fromJson('nonsense'), TextCardStyle.classic);
    });

    test('values out of range are brought into it, unknown ones left at their default, colours made opaque', () {
      final s = TextCardStyle.fromJson({
        'textSize': 9,
        'lineSpacing': 0.1,
        'margin': -5,
        'handleSize': 99,
        'textPosition': 'sideways',
        'handlePosition': 'upsideDown',
        'textColor': 0x00FFD60A,
        'handle': '   ',
      });
      expect(s.textSize, TextCardStyle.maxTextSize);
      expect(s.lineSpacing, TextCardStyle.minLineSpacing);
      expect(s.margin, TextCardStyle.minMargin);
      expect(s.handleSize, TextCardStyle.maxHandleSize);
      expect(s.textPosition, isNull);
      expect(s.handlePosition, TextCardHandlePosition.automatic);
      expect(s.textColor, 0xFFFFD60A);
      expect(s.handle, isNull, reason: 'a blank @handle is each network\'s own');
    });

    test('a typed @handle is trimmed and kept to 80 characters; an empty one is each network\'s own', () {
      expect(TextCardStyle.cleanHandle('  @neforum  '), '@neforum');
      expect(TextCardStyle.cleanHandle(''), isNull);
      expect(TextCardStyle.cleanHandle('x' * 200)!.length, TextCardStyle.maxHandleLength);
      expect(TextCardStyle.classic.copyWith(handle: ' @me ').handle, '@me');
      expect(const TextCardStyle(handle: '@me').bylineFor('@own'), '@me');
      expect(TextCardStyle.classic.bylineFor('@own'), '@own');
    });

    test('picking a theme drops the words\' and card\'s own colours, not the @handle\'s', () {
      const s = TextCardStyle(textColor: 0xFFFFD60A, backgroundColor: 0xFF3A0CA3, handleColor: 0xFFFF3B30, margin: 120);
      final themed = s.withoutColours();
      expect(themed.textColor, isNull);
      expect(themed.backgroundColor, isNull);
      expect(themed.handleColor, 0xFFFF3B30);
      expect(themed.margin, 120);
    });

    test('the automatic corner is where the @handle always was', () {
      expect(TextCardHandlePosition.automatic.resolve(branded: true), TextCardHandlePosition.bottomRight);
      expect(TextCardHandlePosition.automatic.resolve(branded: false), TextCardHandlePosition.bottomLeft);
      expect(TextCardHandlePosition.topLeft.resolve(branded: true), TextCardHandlePosition.topLeft);
    });
  });

  group('render parameters', () {
    test('an untouched card has exactly the parameters 1.3.4 gave it', () {
      final params = textCardRenderParameters(
        platformId: 'instagram',
        theme: TextCardTheme.dark,
        font: TextCardFont.original,
        branded: true,
        alignment: TextCardAlignment.left,
        showsHandle: true,
        byline: '@ana',
        textHash: 'abc',
      );
      // The map 1.3.4's textCardRenderParameters made for these choices.
      expect(params, {
        'kind': RenderKind.textCard,
        'platform': 'instagram',
        'theme': 'dark',
        'font': 'original',
        'branded': true,
        'alignment': 'left',
        'handle': true,
        'byline': '@ana',
        'safe': false,
        'textHash': 'abc',
      });
      expect(textCardPlaceholder('instagram', TextCardTheme.dark).renderParameters!.containsKey('style'), isFalse);
    });

    test('a restyled card records its style, its stand-in too, so a change makes the card again', () {
      const style = TextCardStyle(textSize: 1.2, handle: '@neforum');
      final params = textCardRenderParameters(
          platformId: 'bluesky', theme: TextCardTheme.dark, font: TextCardFont.original, branded: true, alignment: TextCardAlignment.left, showsHandle: true, style: style);
      expect(params['style'], style.toJson());
      final placeholder = textCardPlaceholder('bluesky', TextCardTheme.dark, style: style, byline: style.bylineFor('@own'));
      expect(textCardStyleOf(placeholder), style);
      expect(textCardBylineOf(placeholder), '@neforum');
      expect(textCardBylineOf(textCardPlaceholder('bluesky', TextCardTheme.dark, showsHandle: false, style: style, byline: '@neforum')), isNull,
          reason: 'Show @handle off: no @handle on the card');
      expect(renderParametersEqual(params, {...params, 'style': const TextCardStyle(textSize: 1.25, handle: '@neforum').toJson()}), isFalse);
    });
  });

  // Recorded on Windows from NEFORUM 1.3.4 (commit fce0a00), before
  // TextCardStyle existed; Linux draws text a little differently, so they
  // run on Windows only, as card_design_test.dart's do.
  group('cards as 1.3.4 drew them', skip: !Platform.isWindows, () {
    for (final MapEntry(key: name, value: render) in _cards1_3_4.entries) {
      testWidgets(name, (tester) async {
        final bytes = (await tester.runAsync(render))!;
        final image = (await tester.runAsync(() => _decode(bytes)))!;
        await expectLater(image, matchesGoldenFile('card_goldens/classic-1.3.4-$name.png'));
        image.dispose();
      });
    }
  });

  group('an untouched card is the 1.3.4 picture', () {
    final cases = <String, ({String text, TextCardTheme theme, Size size, String? byline, bool branded, EdgeInsets safe, TextCardAlignment alignment})>{
      'signed, with the @handle': (text: _words, theme: TextCardTheme.dark, size: const Size(1080, 1350), byline: '@ana@mastodon.social', branded: true, safe: EdgeInsets.zero, alignment: TextCardAlignment.left),
      'plain, with the @handle': (text: _words, theme: TextCardTheme.light, size: const Size(1080, 1080), byline: '@ana.bsky.social', branded: false, safe: EdgeInsets.zero, alignment: TextCardAlignment.center),
      'plain, no @handle, long words': (text: _long, theme: TextCardTheme.dark, size: const Size(1000, 1500), byline: null, branded: false, safe: EdgeInsets.zero, alignment: TextCardAlignment.justify),
      'TikTok safe area, cut to fit': (text: '$_long $_long $_long', theme: TextCardTheme.light, size: const Size(1080, 1920), byline: '@ana', branded: true, safe: fullScreenSafeArea('tiktok'), alignment: TextCardAlignment.right),
      'right to left': (text: 'مرحبا بالعالم، هذه بطاقة نصية.', theme: TextCardTheme.dark, size: const Size(540, 540), byline: '@ana', branded: true, safe: EdgeInsets.zero, alignment: TextCardAlignment.left),
    };
    for (final MapEntry(key: name, value: c) in cases.entries) {
      testWidgets('$name: the same pixels as the frozen 1.3.4 painter, and the same JPEG bytes', (tester) async {
        final w = c.size.width.round(), h = c.size.height.round();
        final now = (await tester.runAsync(() => rasterizeWordsLayer(w, h, (canvas) {
              TextCardPainter(text: c.text, theme: c.theme, byline: c.byline, branded: c.branded, safe: c.safe, alignment: c.alignment, style: TextCardStyle.classic)
                  .paint(canvas, c.size);
            })))!;
        final then = (await tester.runAsync(() => rasterizeWordsLayer(w, h, (canvas) {
              _paint1_3_4(canvas, c.size, text: c.text, theme: c.theme, byline: c.byline, branded: c.branded, safe: c.safe, alignment: c.alignment);
            })))!;
        expect(now.length, then.length);
        var differing = 0;
        for (var i = 0; i < now.length; i++) {
          if (now[i] != then[i]) differing++;
        }
        expect(differing, 0, reason: 'every byte of the RGBA picture');
        final jpeg = (await tester.runAsync(() => renderTextCardJpeg(
            text: c.text, theme: c.theme, size: c.size, byline: c.byline, branded: c.branded, safe: c.safe, alignment: c.alignment)))!;
        expect(jpeg, encodeRgbaJpeg((then, w, h)), reason: 'the saved card is the same file');
      });
    }
  });

  group('every choice changes the saved JPEG', () {
    testWidgets('the card colour fills the card', (tester) async {
      final card = await _card(tester, style: const TextCardStyle(backgroundColor: 0xFF3A0CA3));
      final p = card.getPixel(6, 200);
      expect((p.r - 0x3A).abs() + (p.g - 0x0C).abs() + (p.b - 0xA3).abs(), lessThan(18));
    });

    testWidgets('the words take their colour; the signature tab keeps its own', (tester) async {
      bool yellow(img.Pixel p) => p.r > 200 && p.g > 170 && p.b < 90;
      const words = (20, 40, 320, 280);
      expect(_count(await _card(tester), words, yellow), 0);
      expect(_count(await _card(tester, style: const TextCardStyle(textColor: 0xFFFFD60A)), words, yellow), greaterThan(300));
    });

    testWidgets('a larger size draws more of the words, a smaller one less', (tester) async {
      const words = (20, 30, 320, 300);
      final normal = _count(await _card(tester), words, _ink);
      expect(_count(await _card(tester, style: const TextCardStyle(textSize: 1.6)), words, _ink), greaterThan(normal * 1.5));
      expect(_count(await _card(tester, style: const TextCardStyle(textSize: 0.6)), words, _ink), lessThan(normal * 0.6));
    });

    testWidgets('long words that already fill the card are never made larger than fits', (tester) async {
      final larger = await _card(tester, text: _long, style: const TextCardStyle(textSize: 2));
      final normal = await _card(tester, text: _long);
      const words = (20, 30, 320, 300);
      expect(_count(larger, words, _ink), closeTo(_count(normal, words, _ink), _count(normal, words, _ink) * 0.05));
    });

    testWidgets('the words go to the top, the middle or the bottom', (tester) async {
      const area = (20, 20, 320, 330);
      final top = _firstInkRow(await _card(tester, style: const TextCardStyle(textPosition: TextCardTextPosition.top)), area);
      final middle = _firstInkRow(await _card(tester), area);
      final bottom = _firstInkRow(await _card(tester, style: const TextCardStyle(textPosition: TextCardTextPosition.bottom)), area);
      expect(top, lessThan(middle));
      expect(middle, lessThan(bottom));
    });

    testWidgets('line spacing spreads the lines', (tester) async {
      const area = (20, 20, 320, 330);
      int span(img.Image i) {
        final first = _firstInkRow(i, area);
        var last = first;
        for (var y = first; y < 350; y++) {
          if (_count(i, (20, y, 320, 1), _ink) > 0) last = y;
        }
        return last - first;
      }

      const two = 'One line.\nTwo lines.';
      final tight = span(await _card(tester, text: two, style: const TextCardStyle(lineSpacing: 1.0)));
      final loose = span(await _card(tester, text: two, style: const TextCardStyle(lineSpacing: 2.0)));
      expect(loose, greaterThan(tight + 10));
    });

    testWidgets('margins move the words in from the edges', (tester) async {
      int firstInkColumn(img.Image i) {
        for (var x = 0; x < 360; x++) {
          if (_count(i, (x, 40, 1, 280), _ink) > 0) return x;
        }
        return -1;
      }

      final normal = firstInkColumn(await _card(tester));
      final wide = firstInkColumn(await _card(tester, style: const TextCardStyle(margin: 200)));
      expect(wide - normal, closeTo((200 - 92) / 3, 4), reason: '108 px more at 1080 wide is 36 px at 360');
    });

    testWidgets('the @handle written here is drawn exactly where the network\'s own would be', (tester) async {
      Future<Uint8List> render({String? byline, TextCardStyle style = TextCardStyle.classic}) async => (await tester.runAsync(() =>
          renderTextCardJpeg(text: 'Hi there.', theme: TextCardTheme.dark, size: const Size(360, 450), byline: byline, style: style)))!;
      final mine = await render(byline: '@ana', style: const TextCardStyle(handle: '@neforum'));
      expect(mine, await render(byline: '@neforum'), reason: 'the same picture as an account whose handle is @neforum');
      expect(mine, isNot(await render(byline: '@ana')));
      // Show @handle off: the card has no @handle, whatever is written.
      expect(await render(style: const TextCardStyle(handle: '@neforum')), await render());
    });

    testWidgets('the @handle\'s size, corner and colour', (tester) async {
      const footerRight = (200, 392, 140, 45);
      const topRight = (180, 20, 160, 50);
      final normal = await _card(tester);
      expect(_count(await _card(tester, style: const TextCardStyle(handleSize: 2)), footerRight, _ink), greaterThan(_count(normal, footerRight, _ink) * 2));
      final moved = await _card(tester, style: const TextCardStyle(handlePosition: TextCardHandlePosition.topRight));
      expect(_count(normal, topRight, _ink), 0);
      expect(_count(moved, topRight, _ink), greaterThan(20), reason: 'the @handle at the top right');
      expect(_count(moved, footerRight, _ink), lessThan(_count(normal, footerRight, _ink) ~/ 3), reason: 'and no longer in the footer');
      bool red(img.Pixel p) => p.r > 180 && p.g < 110 && p.b < 110;
      expect(_count(normal, footerRight, red), 0);
      expect(_count(await _card(tester, style: const TextCardStyle(handleColor: 0xFFFF3B30)), footerRight, red), greaterThan(20));
    });

    testWidgets('on a plain card the bottom right and top left corners work too', (tester) async {
      const bottomLeft = (20, 392, 120, 45), bottomRight = (220, 392, 120, 45), topLeft = (20, 20, 140, 50);
      final plain = await _card(tester, branded: false);
      expect(_count(plain, bottomLeft, _ink), greaterThan(20), reason: 'automatic: bottom left without the signature');
      final right = await _card(tester, branded: false, style: const TextCardStyle(handlePosition: TextCardHandlePosition.bottomRight));
      expect(_count(right, bottomRight, _ink), greaterThan(20));
      expect(_count(right, bottomLeft, _ink), 0);
      final up = await _card(tester, branded: false, style: const TextCardStyle(handlePosition: TextCardHandlePosition.topLeft));
      expect(_count(up, topLeft, _ink), greaterThan(20));
    });
  });

  group('through attachTextCards', () {
    Future<(AppServices, Map<String, ConnectedAccount>)> workspace(WidgetTester tester) async {
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
      final accounts = (await tester.runAsync(() => s.accounts.all()))!;
      return (s, {for (final p in ['instagram', 'bluesky', 'mastodon', 'x']) p: accounts.firstWhere((a) => a.platformId == p)});
    }

    Post written(Map<String, ConnectedAccount> accounts, {Map<String, dynamic> extra = const {}}) {
      final now = DateTime(2026, 11, 1);
      return Post(
        id: 'p-style',
        text: 'One card, styled once.',
        targets: [
          for (final a in accounts.values) PostTarget(accountId: a.id, overrides: PostOverrides(extra: {kTextCardEveryNetworkKey: true, ...extra})),
        ],
        createdAt: now,
        updatedAt: now,
      );
    }

    Map<String, MediaAttachment> cardsByPlatform(Post post, Map<String, ConnectedAccount> accounts) {
      final cards = {for (final m in post.media.where(isRenderedTextCard)) m.id: m};
      return {
        for (final MapEntry(key: platform, value: a) in accounts.entries)
          platform: ?post.targetFor(a.id)!.overrides.mediaIds?.map((id) => cards[id]).whereType<MediaAttachment>().firstOrNull,
      };
    }

    const style = TextCardStyle(textSize: 1.3, textColor: 0xFFFFD60A, backgroundColor: 0xFF3A0CA3, handle: '@neforum', handleSize: 1.5);

    testWidgets('four networks get the style and the written @handle in their parameters and in their pictures; Show @handle off stays off',
        (tester) async {
      final (s, accounts) = await workspace(tester);
      final post = (await tester.runAsync(() => attachTextCards(s, written(accounts), s.settings,
          theme: TextCardTheme.dark,
          font: TextCardFont.original,
          alignment: TextCardAlignment.left,
          branded: const {'instagram': true, 'bluesky': true, 'mastodon': true, 'x': true},
          handle: const {'instagram': true, 'bluesky': true, 'mastodon': true, 'x': false},
          cardStyle: style)))!;
      final cards = cardsByPlatform(post, accounts);
      expect(cards.keys, unorderedEquals(['instagram', 'bluesky', 'mastodon', 'x']));
      for (final MapEntry(key: platform, value: card) in cards.entries) {
        expect(card.renderParameters!['style'], style.toJson(), reason: platform);
        expect(textCardStyleOf(card), style, reason: platform);
        expect(textCardBylineOf(card), platform == 'x' ? isNull : '@neforum', reason: platform);
      }
      // The pictures: each the card an account named @neforum would get
      // with this style, not its own @handle's.
      for (final platform in ['instagram', 'bluesky', 'mastodon']) {
        final card = cards[platform]!;
        final saved = (await tester.runAsync(() => s.media.read(card)))!;
        Future<Uint8List> render(String byline, TextCardStyle st) async => (await tester.runAsync(() => renderTextCardJpeg(
            text: 'One card, styled once.',
            theme: TextCardTheme.dark,
            size: textCardSizeOf(card, platform),
            byline: byline,
            safe: textCardSafeArea(platform),
            font: TextCardFont.original.resolve(platform),
            style: st)))!;
        expect(saved, await render('@neforum', style.copyWith(clearHandle: true)), reason: '$platform shows @neforum');
        expect(saved, isNot(await render(accounts[platform]!.handle ?? accounts[platform]!.displayName, style.copyWith(clearHandle: true))),
            reason: '$platform does not show its own handle');
      }
    });

    testWidgets('a scheduled run makes nothing again, and makes a new network\'s card with the saved style', (tester) async {
      final (s, accounts) = await workspace(tester);
      // As the composer saves it: the style written on the targets too.
      final chosen = withTextCardChoices(written(accounts), everyNetwork: true, withText: const {}, platformOf: (id) => accounts.values.firstWhere((a) => a.id == id).platformId, style: style);
      expect(textCardStyleChoiceOfPost(chosen), style);
      final saved = (await tester.runAsync(() => attachTextCards(s, chosen, s.settings, cardStyle: style)))!;
      final before = {for (final e in cardsByPlatform(saved, accounts).entries) e.key: e.value.id};
      // The run: every choice read back from the post.
      final run = (await tester.runAsync(() => attachTextCards(s, saved, s.settings)))!;
      expect({for (final e in cardsByPlatform(run, accounts).entries) e.key: e.value.id}, before, reason: 'unchanged cards are kept');
      // Saved while no card existed yet (the cards rebuilt from nothing):
      // the style on the targets still reaches every card.
      final bare = withoutTextCards(saved).copyWith(targets: [for (final t in saved.targets) t.copyWith(overrides: t.overrides.copyWith(extra: chosen.targetFor(t.accountId)!.overrides.extra))]);
      final rebuilt = (await tester.runAsync(() => attachTextCards(s, bare, s.settings)))!;
      for (final card in cardsByPlatform(rebuilt, accounts).values) {
        expect(textCardStyleOf(card), style);
      }
    });

    testWidgets('sync and reopening: the post\'s JSON keeps the style; the composer gets it back, its overrides clean', (tester) async {
      final (s, accounts) = await workspace(tester);
      final chosen = withTextCardChoices(written(accounts), everyNetwork: true, withText: const {}, platformOf: (id) => accounts.values.firstWhere((a) => a.id == id).platformId, style: style);
      final saved = (await tester.runAsync(() => attachTextCards(s, chosen, s.settings, cardStyle: style)))!;
      final synced = Post.fromJson(saved.toJson());
      expect(textCardStyleOfPost(synced), style);
      for (final t in synced.targets) {
        expect(withoutTextCardChoices(t.overrides).extra.containsKey(kTextCardStyleKey), isFalse, reason: 'not a target\'s own override');
      }
      // A post from before 1.3.5: no style anywhere, so the classic card.
      final old = (await tester.runAsync(() => attachTextCards(s, written(accounts), s.settings)))!;
      expect(textCardStyleOfPost(old), TextCardStyle.classic);
      expect(old.media.where(isRenderedTextCard).every((m) => !m.renderParameters!.containsKey('style')), isTrue);
    });

    testWidgets('a card made by 1.3.4 is kept, not made again', (tester) async {
      final (s, accounts) = await workspace(tester);
      final first = (await tester.runAsync(() => attachTextCards(s, written(accounts), s.settings)))!;
      // What 1.3.4 left: the same cards, whose parameters it wrote without a style.
      final again = (await tester.runAsync(() => attachTextCards(s, first, s.settings, cardStyle: TextCardStyle.classic)))!;
      expect(again.media.where(isRenderedTextCard).map((m) => m.id).toSet(), first.media.where(isRenderedTextCard).map((m) => m.id).toSet());
    });

    testWidgets('a designed card takes the written @handle too', (tester) async {
      final (s, accounts) = await workspace(tester);
      final design = kCardTemplates.first.design(CardKind.text);
      final post = (await tester.runAsync(() => attachTextCards(s, written(accounts), s.settings,
          design: design.toJson(), cardStyle: const TextCardStyle(handle: '@neforum'), handle: const {'instagram': true})))!;
      final ig = cardsByPlatform(post, accounts)['instagram']!;
      expect(textCardDesignOf(ig), isNotNull);
      expect(textCardBylineOf(ig), '@neforum');
    });
  });

  group('the composer\'s draft', () {
    test('keeps the style across a restart, and writes nothing for the classic card', () {
      const style = TextCardStyle(textSize: 0.8, handle: '@neforum', handlePosition: TextCardHandlePosition.topLeft, margin: 60);
      const c = ComposerState(text: 'Kept.', textCardStyle: style);
      final j = composerDraftToJson(c);
      expect(j['textCardStyle'], style.toJson());
      expect(composerDraftFromJson(j)!.textCardStyle, style);
      expect(composerDraftToJson(const ComposerState(text: 'Plain.')).containsKey('textCardStyle'), isFalse);
      expect(composerDraftFromJson(composerDraftToJson(const ComposerState(text: 'Plain.')))!.textCardStyle, TextCardStyle.classic);
    });
  });
}
