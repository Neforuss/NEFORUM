// Emoji on the real desktop engine, with the system's real fonts, the way NEFORUM
// ships. `flutter test` has no system fonts, so only this shows what a saved card
// holds on this computer. It draws a sample sheet, every sample on all four card
// styles, and pictures of the emoji sheet, and saves them as PNG files.
//
//   flutter drive --profile -d windows --driver=test_driver/integration_test.dart --target=integration_test/emoji_sample_sheet_test.dart
//
// The pictures go to the folder in NEFORUM_EMOJI_OUT, or a new temporary folder.
// Each run prints how this device draws every sample.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neforum_app/media/caption_fonts.dart';
import 'package:neforum_app/media/caption_overlay.dart';
import 'package:neforum_app/media/caption_style.dart';
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/card_renderer.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/media/emoji_text.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/emoji_catalog.dart';
import 'package:neforum_app/ui/compose/emoji_sheet.dart';

const List<(String, String)> kSamples = [
  ('grin', '\u{1F600}'),
  ('skin tone', '\u{1F44D}\u{1F3FD}'),
  ('family', '\u{1F468}‍\u{1F469}‍\u{1F467}‍\u{1F466}'),
  ('yawn E12', '\u{1F971}'),
  ('pinch E13', '\u{1F90C}'),
  ('heart fire', '❤️‍\u{1F525}'),
  ('red heart', '❤️'),
  ('keycap', '1️⃣'),
  ('flag', '\u{1F1FA}\u{1F1F8}'),
  ('England', '\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}'),
  ('black heart', '\u{1F5A4}'),
  ('racing flag', '\u{1F3C1}'),
  ('melting E14', '\u{1FAE0}'),
  ('goose E15', '\u{1FABF}'),
  ('shake E15.1', '\u{1F642}‍↔️'),
  ('unassigned', '\u{1FAFE}'),
];

const List<String> kStyles = ['classic Inter', 'classic Arial', 'custom font', 'designed Inter', 'caption'];
const double kCell = 150;

CardDesign _design(String words) {
  final template = cardTemplateById('neon')!.design(CardKind.text);
  return template.copyWith(blocks: [
    CardTextBlock(role: CardBlockRole.postText, text: words, anchor: CardAnchor.topLeft, color: 0xFF000000, size: 120, font: TextCardFont.original),
  ]);
}

void _paintStyle(Canvas canvas, String style, String words, Size size) {
  switch (style) {
    case 'classic Inter':
      TextCardPainter(text: words, theme: TextCardTheme.light, branded: false).paint(canvas, size);
    case 'classic Arial':
      TextCardPainter(text: words, theme: TextCardTheme.light, branded: false, font: TextCardFont.arial).paint(canvas, size);
    case 'custom font':
      TextCardPainter(text: words, theme: TextCardTheme.light, branded: false, customFont: const CaptionFont(family: 'Consolas')).paint(canvas, size);
    case 'designed Inter':
      CardDesignPainter(design: _design(words), texts: {CardBlockRole.postText: words}).paint(canvas, size);
    case 'caption':
      canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF808080));
      CaptionOverlayPainter(text: words, font: TextCardFont.original, style: const CaptionStyle()).paint(canvas, size);
  }
}

Future<Uint8List> _rgba(int width, int height, void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = const Color(0xFFFFFFFF));
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  image.dispose();
  return data!.buffer.asUint8List();
}

int _coloured(Uint8List rgba) {
  var n = 0;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 40) continue;
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    final hi = [r, g, b].reduce((x, y) => x > y ? x : y), lo = [r, g, b].reduce((x, y) => x < y ? x : y);
    if (hi - lo > 40) n++;
  }
  return n;
}

void _label(Canvas canvas, String text, Offset at, double width) {
  final p = TextPainter(
    text: TextSpan(text: text, style: const TextStyle(fontFamily: Fonts.body, fontSize: 13, color: Color(0xFF000000))),
    textDirection: TextDirection.ltr,
    maxLines: 2,
  )..layout(maxWidth: width);
  p.paint(canvas, at);
  p.dispose();
}

Future<void> _savePicture(String path, void Function(Canvas) paint, int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = const Color(0xFFFFFFFF));
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  File(path).writeAsBytesSync(data!.buffer.asUint8List());
}

Future<void> _saveWidget(WidgetTester t, GlobalKey key, String path) async {
  await t.pump();
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  File(path).writeAsBytesSync(data!.buffer.asUint8List());
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every sample on all the card styles, and the emoji sheet, on the real engine', (t) async {
    final named = Platform.environment['NEFORUM_EMOJI_OUT'];
    final out = named == null || named.isEmpty ? Directory.systemTemp.createTempSync('neforum-emoji-') : (Directory(named)..createSync(recursive: true));

    // How this device draws each sample, tried the way a saved picture tries it.
    final draws = <String, EmojiDraw>{};
    for (final (name, e) in kSamples) {
      draws[e] = await EmojiSupport.probe(e);
      // ignore: avoid_print
      print('EMOJI $name ${e.runes.map((r) => r.toRadixString(16)).join(' ')}: ${draws[e]!.name}');
    }

    const size = Size(kCell, kCell);
    await _savePicture(
      '${out.path}${Platform.pathSeparator}emoji_sample_sheet.png',
      (canvas) {
        for (var col = 0; col < kStyles.length; col++) {
          _label(canvas, kStyles[col], Offset(130 + col * (kCell + 8), 4), kCell);
        }
        for (var row = 0; row < kSamples.length; row++) {
          final (name, e) = kSamples[row];
          final y = 26 + row * (kCell + 8);
          _label(canvas, '$name\n${draws[e]!.name}', Offset(4, y + 4), 122);
          for (var col = 0; col < kStyles.length; col++) {
            canvas.save();
            canvas.translate(130 + col * (kCell + 8), y);
            canvas.clipRect(Offset.zero & size);
            _paintStyle(canvas, kStyles[col], e, size);
            canvas.restore();
          }
        }
      },
      (130 + kStyles.length * (kCell + 8)).round(),
      (26 + kSamples.length * (kCell + 8)).round(),
    );

    // A red heart is in colour on every style.
    const heart = '❤️';
    final colours = <String, int>{};
    for (final style in kStyles.where((s) => s != 'caption')) {
      final withHeart = _coloured(await _rgba(300, 300, (c) => _paintStyle(c, style, heart, const Size(300, 300))));
      final without = _coloured(await _rgba(300, 300, (c) => _paintStyle(c, style, 'x', const Size(300, 300))));
      colours[style] = withHeart - without;
      // ignore: avoid_print
      print('HEART $style coloured=$withHeart without=$without');
    }
    for (final entry in colours.entries) {
      expect(entry.value, greaterThan(100), reason: '${entry.key}: the red heart');
    }

    // What this device cannot draw leaves the picture as if it were not there.
    for (final (name, e) in kSamples.where((s) => draws[s.$2] == EmojiDraw.missing)) {
      for (final style in kStyles) {
        final withIt = await _rgba(300, 300, (c) => _paintStyle(c, style, 'x$e', const Size(300, 300)));
        final without = await _rgba(300, 300, (c) => _paintStyle(c, style, 'x', const Size(300, 300)));
        expect(withIt, without, reason: '$style, $name: no tile and no box');
        final alone = await _rgba(300, 300, (c) => _paintStyle(c, style, e, const Size(300, 300)));
        final empty = await _rgba(300, 300, (c) => _paintStyle(c, style, '', const Size(300, 300)));
        expect(alone, empty, reason: '$style, $name alone: nothing at all, not an empty label');
      }
    }
    expect(draws['\u{1F600}'], EmojiDraw.whole);
    expect(draws['\u{1F5A4}'], EmojiDraw.whole, reason: 'a black heart is a real picture');
    expect(draws['\u{1F3C1}'], EmojiDraw.whole, reason: 'so is a racing flag');
    expect(draws['\u{1FAFE}'], EmojiDraw.missing, reason: 'nothing draws an emoji that does not exist');

    // The emoji sheet at phone size.
    final dir = Directory.systemTemp.createTempSync('neforum-emoji-data-');
    final storage = await openAppStorage(overrideDir: dir.path);
    await storage.writeJson('settings.json', {
      'onboarded': true,
      'updateCheck': 'off',
      'emojiRecents': ['\u{1F600}', '\u{1FAE0}', '❤️'],
    });
    final services = await AppServices.create(demo: true, storage: storage);
    final shot = GlobalKey();
    await t.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(
          body: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 360,
            maxWidth: 360,
            minHeight: 640,
            maxHeight: 640,
            child: RepaintBoundary(
              key: shot,
              child: ColoredBox(color: const Color(0xFFFFFFFF), child: EmojiPanel(onPick: (_) {}, onClose: () {})),
            ),
          ),
        ),
      ),
    ));
    final support = await emojiDeviceSupport();
    // ignore: avoid_print
    print('SUPPORT hidden=${support.hiddenVersions?.toList()} flagsInPieces=${support.flagsInPieces} anyFont=${support.anyFont}');
    await _settle(t);
    String path(String name) => '${out.path}${Platform.pathSeparator}$name.png';
    await _saveWidget(t, shot, path('emoji_sheet_recent'));
    await t.tap(find.byKey(const Key('emoji-category-smileysAndEmotion')));
    await _settle(t);
    await _saveWidget(t, shot, path('emoji_sheet_smileys'));
    await t.tap(find.byKey(const Key('emoji-category-peopleAndBody')));
    await _settle(t);
    await t.tap(find.byKey(const Key('emoji-tone-3')));
    await _settle(t);
    await _saveWidget(t, shot, path('emoji_sheet_people_medium_tone'));
    await t.tap(find.byKey(const Key('emoji-category-flags')));
    await _settle(t);
    await _saveWidget(t, shot, path('emoji_sheet_flags'));
    // Live tests have no test text input: fill the field the way typing ends up.
    final search = t.widget<TextField>(find.byKey(const Key('emoji-search')));
    search.controller!.text = 'face';
    search.onChanged!('face');
    await _settle(t);
    // 1.4.3: search also matches CLDR keywords, so "face" finds far more emoji
    // and the grid builds only the rows on screen. Scroll to a newer face.
    await t.scrollUntilVisible(
      find.byIcon(Icons.image_not_supported_outlined).first,
      220,
      scrollable: find.descendant(of: find.byType(GridView), matching: find.byType(Scrollable)).first,
      maxScrolls: 200,
    );
    await _settle(t);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsWidgets, reason: 'newer faces show the plain icon on this Windows');
    await _saveWidget(t, shot, path('emoji_sheet_search'));
    expect(t.takeException(), isNull);
    expect(allEmoji.length, greaterThan(1800));
    // ignore: avoid_print
    print('SAVED ${out.path}');
    await t.pumpWidget(const SizedBox.shrink());
  });
}
