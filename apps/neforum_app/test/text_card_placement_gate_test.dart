// 1.3.5: the placement gate for the text card editor's words and @handle on
// card designer designs. Written before the layout it judges (round 5 of the
// review), and judged on rendered pixels only, so it cannot be satisfied by
// how the code is organised.
//
// The matrix: every built-in template x words Top / Middle / Bottom x a
// typed @handle or not x a photo or not x the 1:1, 4:5 and 9:16 (TikTok, with
// its safe area) card shapes: 360 cells. Each cell renders the card (PNG, a
// third of its size) and checks:
//  (a) no pixel of the editor's text (the words, and the @handle when the
//      editor placed it) inside a picture area of the template (the cover or
//      record, with its border and turn, when it is drawn; the waveform), nor
//      inside the network's safe area;
//  (b) the template's own blocks the user did not touch (the signature, the
//      template's @handle, its other lines) are drawn exactly where the
//      untouched template draws them;
//  (c) the words come out at no less than kMinWordsPx (pixels at 1080 wide):
//      a long post at the top or the bottom is never shrunk twice into
//      unreadable type;
//  (d) the @handle, where one shows, is drawn, outside the picture areas
//      when the editor placed it, and never under the words.
// The picture areas are worked out here from the design's layers, the same
// way the compositor draws them, independently of the layout code.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/card_design_edits.dart';
import 'package:neforum_app/media/card_renderer.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/media/photo_pixels.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/media/text_card_background.dart';
import 'package:neforum_app/media/waveform.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// The smallest the words may come out, in pixels at 1080 wide.
const double kMinWordsPx = 28;

const _long =
    'This is a long post of a few sentences, the kind people write when they have something to say. It runs on for a while so the card has to work to fit it all in, and every word should still be there and readable.';
const _typed = '@my.handle';
const _own = '@robin.makes';
const _photoRef = MediaAttachment(id: 'bg', path: 'mem://bg.jpg', mimeType: 'image/jpeg', sizeBytes: 10, width: 100, height: 100);

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final present = [for (final f in files) if (File(f).existsSync()) f];
    if (present.isEmpty) return;
    final loader = FontLoader(name);
    for (final f in present) {
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
  await family('TikTok Sans', ['assets/fonts/TikTokSans.ttf']);
  await family('Times New Roman', [r'C:\Windows\Fonts\times.ttf']);
  await family('Arial', [r'C:\Windows\Fonts\arial.ttf', r'C:\Windows\Fonts\arialbd.ttf']);
}

/// The card shapes: (name, size at a third, safe area in pixels at 1080).
final _shapes = [
  ('1:1', const Size(360, 360), EdgeInsets.zero),
  ('4:5', const Size(360, 450), EdgeInsets.zero),
  ('9:16', const Size(360, 640), fullScreenSafeArea('tiktok')),
];

/// The drawn square of [d]'s cover in [frame], turned, with its border.
Rect _coverArea(CardDesign d, Rect frame, double u) {
  final c = d.cover;
  final r = cardCoverRect(c, frame);
  final turn = c.rotation * math.pi / 180;
  final half = r.width / 2 * (math.cos(turn).abs() + math.sin(turn).abs()) + c.borderWidth * u;
  return Rect.fromCenter(center: r.center, width: half * 2, height: half * 2);
}

/// The template's picture areas on a card of [size] (design pixels), each
/// shrunk by 2 pixels for anti-aliasing at their edges.
List<Rect> _pictureAreas(CardDesign d, Size size, EdgeInsets safe, {required bool photo}) {
  final u = cardUnit(size);
  final frame = cardFrameOf(size, safe, d.margin);
  return [
    if (d.cover.visible && (photo || d.cover.shape == CardCoverShape.vinyl)) _coverArea(d, frame, u).deflate(2),
    if (d.waveform.visible) cardWaveformRect(d.waveform, frame).deflate(2),
  ];
}

/// The network's safe area as rects on a card of [size].
List<Rect> _safeAreas(Size size, EdgeInsets safe) {
  final u = cardUnit(size);
  return [
    if (safe.top > 0) Rect.fromLTWH(0, 0, size.width, safe.top * u - 1),
    if (safe.right > 0) Rect.fromLTWH(size.width - safe.right * u + 1, 0, safe.right * u - 1, size.height),
    if (safe.bottom > 0) Rect.fromLTWH(0, size.height - safe.bottom * u + 1, size.width, safe.bottom * u - 1),
  ];
}

class _Card {
  _Card(this.image);
  final img.Image image;
}

/// Sampled points (every 2 pixels) where [a] and [b] differ.
List<Offset> _differing(img.Image a, img.Image b) {
  final out = <Offset>[];
  for (var y = 0; y < a.height; y += 2) {
    for (var x = 0; x < a.width; x += 2) {
      final p = a.getPixel(x, y), q = b.getPixel(x, y);
      if ((p.r - q.r).abs() + (p.g - q.g).abs() + (p.b - q.b).abs() > 60) out.add(Offset(x.toDouble(), y.toDouble()));
    }
  }
  return out;
}

int _inside(List<Offset> points, List<Rect> areas) => points.where((p) => areas.any((r) => r.contains(p))).length;

CardDesign _withoutWords(CardDesign d) => d.copyWith(blocks: [for (final b in d.blocks) if (b.role != CardBlockRole.postText) b]);

void main() {
  setUpAll(_loadFonts);

  PhotoPixels? photo;

  Future<_Card> draw(WidgetTester tester, CardDesign d, Size size, EdgeInsets safe, {required Map<CardBlockRole, String> texts, required bool withPhoto}) async {
    if (withPhoto && photo == null) {
      final src = img.Image(width: 160, height: 160);
      for (var y = 0; y < 160; y++) {
        for (var x = 0; x < 160; x++) {
          src.setPixelRgb(x, y, 30 + x, 120, 200 - y);
        }
      }
      photo = await tester.runAsync(() async => (await decodePhotoPixels(img.encodeJpg(src), maxSide: 200))!);
    }
    final bytes = (await tester.runAsync(() => renderCardDesign(
        CardRenderInput(
          design: d,
          size: size,
          safe: safe,
          platformId: 'instagram',
          texts: texts,
          photo: withPhoto ? photo : null,
          photoBackground: withPhoto ? const TextCardBackground(photo: _photoRef) : null,
          cover: withPhoto ? photo : null,
          waveform: d.waveform.visible ? decorativeWaveform(7) : null,
        ),
        png: true)))!;
    return _Card(img.decodePng(bytes)!);
  }

  final summary = <String>[];
  tearDownAll(() {
    // ignore: avoid_print
    print('PLACEMENT GATE: ${summary.where((s) => s.startsWith('FAIL')).length} of ${summary.length} cells fail');
    for (final s in summary.where((s) => s.startsWith('FAIL'))) {
      // ignore: avoid_print
      print(s);
    }
  });

  for (final t in kCardTemplates) {
    testWidgets('placement gate: ${t.name}', (tester) async {
      final template = t.design(CardKind.text);
      final failures = <String>[];
      for (final position in TextCardTextPosition.values) {
        for (final typed in [false, true]) {
          for (final withPhoto in [false, true]) {
            for (final (shape, size, safe) in _shapes) {
              final cell = '${t.id} words=${position.name} handle=${typed ? 'typed' : 'own'} photo=$withPhoto $shape';
              var design = template.withWordsPosition(position);
              if (typed) design = designWithHandle(design, _typed);
              final handleText = typed ? _typed : _own;
              // The template draws a handle of its own (untouched): the
              // editor placed it only when it added one for a typed handle.
              final editorHandle = typed && template.handleBlock == null;
              final texts = {CardBlockRole.postText: _long, CardBlockRole.handle: handleText};
              final full = await draw(tester, design, size, safe, texts: texts, withPhoto: withPhoto);
              final noWords = await draw(tester, _withoutWords(design), size, safe, texts: texts, withPhoto: withPhoto);
              final noEditorText = await draw(tester, _withoutWords(design), size, safe,
                  texts: {...texts, if (editorHandle) CardBlockRole.handle: ''}, withPhoto: withPhoto);
              // The untouched template without its words: where its own
              // blocks belong.
              final reference = await draw(tester, _withoutWords(template), size, safe,
                  texts: {...texts, if (editorHandle) CardBlockRole.handle: ''}, withPhoto: withPhoto);
              final pictures = _pictureAreas(design, size, safe, photo: withPhoto);
              final safeAreas = _safeAreas(size, safe);
              final words = _differing(full.image, noWords.image);
              final handle = editorHandle ? _differing(noWords.image, noEditorText.image) : const <Offset>[];
              final problems = <String>[];
              // (a)
              final onPictures = _inside(words, pictures) + _inside(handle, pictures);
              if (onPictures > 3) problems.add('(a) $onPictures text points on a picture');
              final onSafe = _inside(_differing(full.image, reference.image), safeAreas);
              if (onSafe > 0) problems.add('(a) $onSafe text points in the safe area');
              // (b)
              final moved = _differing(noEditorText.image, reference.image).length;
              if (moved > 3) problems.add('(b) template blocks moved ($moved points)');
              // (c)
              final px = CardDesignPainter(
                design: design,
                texts: texts,
                safe: safe,
                platformId: 'instagram',
                waveform: design.waveform.visible ? decorativeWaveform(7) : null,
                coverShown: cardCoverDrawn(design, picture: withPhoto),
              ).drawnWordsSize(Size(size.width * 3, size.height * 3));
              if (px != null && px < kMinWordsPx) problems.add('(c) words at ${px.toStringAsFixed(1)} px');
              if (words.length < 20) problems.add('(c) words not drawn');
              // (d)
              if (editorHandle) {
                if (handle.length < 8) problems.add('(d) handle not drawn');
                final under = handle.where((p) => words.any((w) => (w - p).distance < 3)).length;
                if (under > 2) problems.add('(d) handle under the words ($under points)');
              }
              final line = '${problems.isEmpty ? 'PASS' : 'FAIL'} $cell${problems.isEmpty ? '' : ': ${problems.join('; ')}'}';
              summary.add(line);
              if (problems.isNotEmpty) failures.add(line);
            }
          }
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    }, timeout: const Timeout(Duration(minutes: 6)));
  }
}
