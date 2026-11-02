// 1.3.5 review fixes, round 5, for the text card editor: the tests that kill
// the mutations that survived round 4 (C-verdict-4 finding 5), rewritten for
// the round-5 placement (declared picture areas, free bands, template blocks
// that never move), plus the designer's switch and Settings' theme.
// The pixel matrix itself is text_card_placement_gate_test.dart.
//  N3       the cover's border counts in the worked-out picture areas.
//  areas    each template's declared areas hold its drawn pictures on every
//           network's card of that shape.
//  N5       the free band is judged within the block's own width: Vinyl's
//           added @handle sits beside the record, not under it.
//  N6       the size note measures the placed words (and says when they
//           are cut at the minimum).
//  N7       the preview's size note counts the framed photo as drawn.
//  N8       a cover with no picture is no obstacle: Polaroid's words at the
//           top without a photo are at the top.
//  N13/N14  placeWords and placeHandle survive toJson / tryParse, and the
//           saved card's render parameters.
//  switch   the designer turns the placement off and on.
//  theme    a theme changed in Settings > Text cards gets the readability
//           rule.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/card_design_edits.dart';
import 'package:neforum_app/media/card_renderer.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/media/photo_pixels.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/media/text_card_background.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/text_cards.dart' show isRenderedTextCard;
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/compose/text_card_style_editor.dart' show textCardFitWarning;
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
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
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF777777)));
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
  // Polaroid's words: measured in the font the card is drawn in.
  await family('Times New Roman', [r'C:\Windows\Fonts\times.ttf', r'C:\Windows\Fonts\timesi.ttf']);
}

const _platforms = ['instagram', 'bluesky', 'mastodon'];
const _master = 'text-card-master-style';
const _photo = MediaAttachment(id: 'bg-photo', path: 'mem://bg-photo.jpg', mimeType: 'image/jpeg', sizeBytes: 10, width: 100, height: 100);
const _long =
    'This is a long post of a few sentences, the kind people write when they have something to say. It runs on for a while so the card has to work to fit it all in, and every word should still be there and readable.';

final _veryLong = List.filled(3, _long).join(' ');

/// Every network's card: (name, size, safe area), the three shapes.
final _networkCards = [
  for (final id in ['bluesky', 'instagram', 'pinterest', 'tiktok', 'snapchat']) (id, textCardSize(id), textCardSafeArea(id)),
  for (final id in ['instagram', 'facebook', 'youtube']) ('$id story', textCardSize(id, story: true), textCardSafeArea(id, story: true)),
];

CardDesign _template(String id) => cardTemplateById(id)!.design(CardKind.text);

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

void main() {
  setUpAll(_loadFonts);

  /// [d] rendered at [size] (PNG) with [texts].
  Future<img.Image> draw(WidgetTester tester, CardDesign d, Size size, {EdgeInsets safe = EdgeInsets.zero, required Map<CardBlockRole, String> texts}) async {
    final bytes = (await tester.runAsync(() => renderCardDesign(CardRenderInput(design: d, size: size, safe: safe, platformId: 'instagram', texts: texts), png: true)))!;
    return img.decodePng(bytes)!;
  }

  group('N3 and the declared areas', () {
    // Round 6 (critic 5, finding 1): the compositor draws a cover's border
    // INSIDE its square, so the worked-out area is the drawn square itself;
    // round 5 added the border outside a second time, which cut Polaroid's
    // words for room they had. Judged on the drawn pixels.
    for (final (name, edit) in <(String, CardCoverLayer Function(CardCoverLayer))>[
      ('Polaroid, turned, 30 px border', (c) => c),
      ('a square, not turned, 60 px border', (c) => c.copyWith(rotation: 0, borderWidth: 60)),
    ]) {
      testWidgets('N3: the worked-out area of a cover is the square as drawn, border inside ($name)', (tester) async {
        final polaroid = _template('polaroid');
        // A user's own design (not the template as made): areas from layers.
        final d = polaroid.copyWith(margin: polaroid.margin + 10, blocks: const [], cover: edit(polaroid.cover).copyWith(shadow: 0));
        const size = Size(540, 540);
        final photoSource = img.Image(width: 64, height: 64)..clear(img.ColorRgb8(30, 140, 220));
        final pixels = (await tester.runAsync(() => decodePhotoPixels(img.encodeJpg(photoSource), maxSide: 64)))!;
        Future<img.Image> render(CardDesign x) async =>
            img.decodePng((await tester.runAsync(() => renderCardDesign(CardRenderInput(design: x, size: size, platformId: 'instagram', texts: const {}, cover: pixels), png: true)))!)!;
        final on = await render(d), off = await render(d.copyWith(cover: d.cover.copyWith(visible: false)));
        var left = size.width, top = size.height, right = -1.0, bottom = -1.0;
        for (var y = 0; y < on.height; y++) {
          for (var x = 0; x < on.width; x++) {
            final p = on.getPixel(x, y), q = off.getPixel(x, y);
            if ((p.r - q.r).abs() + (p.g - q.g).abs() + (p.b - q.b).abs() > 40) {
              left = x < left ? x.toDouble() : left;
              right = x + 1 > right ? x + 1.0 : right;
              top = y < top ? y.toDouble() : top;
              bottom = y + 1 > bottom ? y + 1.0 : bottom;
            }
          }
        }
        final drawn = Rect.fromLTRB(left, top, right, bottom);
        final frame = cardFrameOf(size, EdgeInsets.zero, d.margin);
        final area = cardLayerPictureAreas(d, frame, cardUnit(size), coverShown: true, waveformShown: false).single;
        expect(area.inflate(1.5).contains(drawn.topLeft) && area.inflate(1.5).contains(drawn.bottomRight), isTrue, reason: 'holds the drawn cover: $area vs $drawn');
        for (final (side, gap) in [('left', drawn.left - area.left), ('top', drawn.top - area.top), ('right', area.right - drawn.right), ('bottom', area.bottom - drawn.bottom)]) {
          expect(gap, lessThan(2.5), reason: '$side: no room counted that is not drawn ($area vs $drawn)');
        }
        expect(cardPictureAreas(d, size, EdgeInsets.zero, coverShown: true, waveformShown: false).single, area, reason: 'not the template as made: worked out');
      });
    }

    test('each template\'s declared areas hold its drawn pictures on every network\'s card of that shape', () {
      for (final MapEntry(key: id, value: declared) in kCardTemplatePictureAreas.entries) {
        final d = _template(id);
        for (final (name, size, safe) in _networkCards) {
          final frame = cardFrameOf(size, safe, d.margin);
          final shape = cardShapeOf(size);
          final s = frame.shortestSide, u = cardUnit(size);
          Rect coverIn(Rect f) => Rect.fromLTRB(frame.center.dx + f.left * s, frame.top + f.top * s, frame.center.dx + f.right * s, frame.top + f.bottom * s);
          Rect inFrame(Rect f) => Rect.fromLTRB(frame.left + f.left * frame.width, frame.top + f.top * frame.height, frame.left + f.right * frame.width, frame.top + f.bottom * frame.height);
          final drawn = cardLayerPictureAreas(d, frame, u, coverShown: declared.cover.isNotEmpty, waveformShown: declared.waveform.isNotEmpty);
          final held = [if (declared.cover[shape] != null) coverIn(declared.cover[shape]!), if (declared.waveform[shape] != null) inFrame(declared.waveform[shape]!)];
          expect(held.length, drawn.length, reason: '$id $name: one declared area per picture');
          for (var i = 0; i < drawn.length; i++) {
            expect(held[i].inflate(0.5).contains(drawn[i].topLeft) && held[i].inflate(0.5).contains(drawn[i].bottomRight), isTrue,
                reason: '$id $name ($shape): declared ${held[i]} holds drawn ${drawn[i]}');
            // Round 6 (critic 5, finding 5): no more than 24 px looser than the
            // drawn picture on any side inside the frame (round 5 left 65 to
            // 176 px on Pinterest and Instagram story cards).
            final r = held[i].intersect(frame), p = drawn[i].intersect(frame);
            for (final (side, slack) in [('left', p.left - r.left), ('top', p.top - r.top), ('right', r.right - p.right), ('bottom', r.bottom - p.bottom)]) {
              expect(slack / u, lessThanOrEqualTo(24), reason: '$id $name: $side slack ${(slack / u).toStringAsFixed(1)} px');
            }
          }
          // As made, the renderer uses the declared areas.
          expect(cardPictureAreas(d, size, safe, coverShown: declared.cover.isNotEmpty, waveformShown: declared.waveform.isNotEmpty), held, reason: '$id $name');
        }
      }
    });

    test('on a size no network uses (16:9, 6:7, 3:4, 1:4) the declared area still takes in the drawn picture', () {
      // 1:4 counts as a story, but Polaroid's frame sits lower in it (its
      // offset is a fraction of the frame's height) than the story rectangle
      // reaches.
      for (final size in const [Size(1920, 1080), Size(900, 1050), Size(1080, 1440), Size(900, 2000), Size(600, 2400)]) {
        for (final id in ['vinyl', 'polaroid', 'gradientWave']) {
          final d = _template(id);
          final frame = cardFrameOf(size, EdgeInsets.zero, d.margin);
          final cover = id != 'gradientWave';
          final drawn = cardLayerPictureAreas(d, frame, cardUnit(size), coverShown: cover, waveformShown: !cover).single;
          final area = cardPictureAreas(d, size, EdgeInsets.zero, coverShown: cover, waveformShown: !cover).single;
          expect(area.expandToInclude(drawn), area, reason: '$id $size');
        }
      }
    });

    test('every template with a declared slot has one for every card shape', () {
      for (final MapEntry(key: id, value: slots) in kCardTemplateHandleSlots.entries) {
        expect(slots.keys.toSet(), CardShape.values.toSet(), reason: id);
        expect(_template(id).handleBlock, isNull, reason: '$id: slots are for templates without a @handle');
      }
    });
  });

  group('N13/N14: the placement is saved with the design', () {
    test('placeWords and placeHandle round-trip; an untouched template writes neither', () {
      final d = designWithHandle(_template('vinyl').withWordsPosition(TextCardTextPosition.top), '@a.handle');
      expect((d.placeWords, d.placeHandle), (true, true));
      final json = d.toJson();
      expect((json['placeWords'], json['placeHandle']), (true, true));
      final back = CardDesign.tryParse(json)!;
      expect((back.placeWords, back.placeHandle), (true, true));
      for (final t in kCardTemplates) {
        final j = t.design(CardKind.text).toJson();
        expect(j.containsKey('placeWords') || j.containsKey('placeHandle'), isFalse, reason: '${t.id}: 1.3.4\'s parameters');
      }
      final off = CardDesign.tryParse(_template('vinyl').toJson())!;
      expect((off.placeWords, off.placeHandle), (false, false));
    });
  });

  group('round 6: no room left', () {
    test('Polaroid with a photo, large margins and handle: the words are never laid on the photo, nor taller than their band', () {
      // Critic 5, finding 2: round 5 fell back to the whole frame here and
      // printed the post across the photo and the handle.
      var dropped = 0;
      for (final margin in [160.0, 200.0, 240.0]) {
        for (final handle in [64.0, 80.0, 96.0]) {
          for (final p in [TextCardTextPosition.top, TextCardTextPosition.bottom, TextCardTextPosition.center]) {
            const size = Size(1080, 1080);
            final d = _template('polaroid').withWordsPosition(p).withMargin(margin).withHandleSize(handle);
            final painter = CardDesignPainter(design: d, texts: const {CardBlockRole.postText: _long, CardBlockRole.handle: '@robin.makes'}, coverShown: true);
            final m = painter.drawnWords(size)!;
            final words = painter.editorPlacements(size)[CardBlockRole.postText];
            final photo = cardPictureAreas(d, size, EdgeInsets.zero, coverShown: true, waveformShown: false).single;
            final frame = cardFrameOf(size, EdgeInsets.zero, d.margin);
            final label = 'margin $margin handle $handle ${p.name}';
            if (words == null) {
              expect(m.dropped, isTrue, reason: '$label: left off, and said so');
              dropped++;
            } else {
              expect(m.dropped, isFalse, reason: label);
              expect(words.overlaps(photo), isFalse, reason: '$label: off the photo');
              expect(words.top >= frame.top - 0.5 && words.bottom <= frame.bottom + 0.5, isTrue, reason: '$label: inside the frame');
            }
          }
        }
      }
      expect(dropped, greaterThan(0), reason: 'the sweep reaches the no-room case');
    });

    test('a band shorter than one line holds nothing: fixed 400 px words or a 300 px handle under Polaroid\'s photo are left off, not overflowed', () {
      const size = Size(1080, 1080);
      final polaroid = _template('polaroid');
      final photo = cardPictureAreas(polaroid, size, EdgeInsets.zero, coverShown: true, waveformShown: false).single;
      // Words of a fixed size (a designer's choice) taller than the band.
      final words = polaroid.withWordsPosition(TextCardTextPosition.bottom);
      final big = words.withBlock(words.blocks.indexWhere((b) => b.role == CardBlockRole.postText), (b) => b.copyWith(autoFit: false, size: 400));
      final p1 = CardDesignPainter(design: big, texts: const {CardBlockRole.postText: _long, CardBlockRole.handle: '@robin.makes'}, coverShown: true);
      expect(p1.drawnWords(size)!.dropped, isTrue);
      expect(p1.editorPlacements(size)[CardBlockRole.postText], isNull, reason: 'never laid over the photo or past the frame');
      // A placed @handle taller than any band.
      final placed = polaroid.withHandlePosition(TextCardHandlePosition.bottomCenter);
      final huge = placed.withBlock(placed.blocks.indexWhere((b) => b.role == CardBlockRole.handle), (b) => b.copyWith(size: 300));
      final p2 = CardDesignPainter(design: huge, texts: const {CardBlockRole.postText: 'Hi.', CardBlockRole.handle: '@robin.makes'}, coverShown: true);
      expect(p2.drawnWords(size)!.handleDropped, isTrue);
      final at = p2.editorPlacements(size);
      expect(at[CardBlockRole.handle], isNull);
      for (final r in at.values) {
        expect(r.overlaps(photo), isFalse);
      }
    });

    test('placed words shrink to 28 px whatever size was picked (at 240 they stopped at 80 and were cut)', () {
      final d = _template('vinyl').withWordsPosition(TextCardTextPosition.top).withWordsSize(240);
      final m = CardDesignPainter(design: d, texts: const {CardBlockRole.postText: _long}, coverShown: true).drawnWords(const Size(1080, 1080))!;
      expect(m.cut, isFalse);
      expect(m.size, lessThan(80));
      expect(m.size, greaterThanOrEqualTo(kPlacedWordsMinPx));
    });

    test('the warnings say what is missing and only advice that was measured', () {
      ({String network, double asked, double drawn, bool cut, bool dropped, bool handleDropped, String? fitsAt}) fit(
              {bool cut = false, bool dropped = false, bool handleDropped = false, String? fitsAt}) =>
          (network: 'Bluesky', asked: 64, drawn: 28, cut: cut, dropped: dropped, handleDropped: handleDropped, fitsAt: fitsAt);
      expect(textCardFitWarning(fit()), isNull);
      expect(textCardFitWarning(fit(dropped: true)), 'No room for the words on Bluesky: smaller margins or a smaller handle make room');
      expect(textCardFitWarning(fit(dropped: true, fitsAt: 'Bottom')), 'No room for the words on Bluesky: Bottom shows them, or smaller margins or a smaller handle make room');
      expect(textCardFitWarning(fit(handleDropped: true)), 'No room for the handle on Bluesky: smaller margins or a smaller handle make room');
      expect(textCardFitWarning(fit(cut: true)), 'Too long for this card on Bluesky: cut at 28 px. Shorter words or smaller margins make room');
      expect(textCardFitWarning(fit(cut: true, fitsAt: 'Middle')), 'Too long for this place on Bluesky: cut at 28 px. Middle shows every word');
    });
  });

  group('the room the placed text keeps', () {
    for (final (name, size, safe) in _networkCards) {
      test('$name: Vinyl Top keeps ${kPlacedTextGapPx.toInt()} px under the record, the typed @handle half that beside it (or the full gap under it)', () {
        final d = designWithHandle(_template('vinyl').withWordsPosition(TextCardTextPosition.top), '@my.handle');
        final u = cardUnit(size);
        final frame = cardFrameOf(size, safe, d.margin);
        final record = cardPictureAreas(d, size, safe, coverShown: true, waveformShown: false).single;
        final at = CardDesignPainter(design: d, texts: const {CardBlockRole.postText: _long, CardBlockRole.handle: '@my.handle'}, safe: safe, coverShown: true).editorPlacements(size);
        final words = at[CardBlockRole.postText]!, handle = at[CardBlockRole.handle]!;
        expect(words.top, greaterThanOrEqualTo(record.bottom + kPlacedTextGapPx * u - 0.5), reason: 'the words under the record, a gap away');
        expect(words.overlaps(handle), isFalse);
        final side = kPlacedTextGapPx / 2 * u;
        final fits = frame.right - (record.right + side) >= handle.width;
        if (safe == EdgeInsets.zero) expect(fits, isTrue, reason: 'square and portrait cards have room beside the record');
        if (fits) {
          expect(handle.top, lessThan(record.bottom), reason: 'room beside the record: the @handle goes there, not under it');
          expect(handle.left, greaterThanOrEqualTo(record.right + side - 0.5), reason: 'half the gap to the side');
        } else {
          // A narrow full-screen frame: no room beside, so under, a gap away.
          expect(handle.top, greaterThanOrEqualTo(record.bottom + kPlacedTextGapPx * u - 0.5));
        }
      });
    }

    test('the side gap: a @handle a little too wide for the room beside Vinyl\'s record goes under it', () {
      const size = Size(1080, 1080);
      final d = designWithHandle(_template('vinyl'), '@x');
      final frame = cardFrameOf(size, EdgeInsets.zero, d.margin);
      final record = cardPictureAreas(d, size, EdgeInsets.zero, coverShown: true, waveformShown: false).single;
      final room = frame.right - record.right, side = kPlacedTextGapPx / 2;
      Rect handleFor(String text) => CardDesignPainter(design: d, texts: {CardBlockRole.postText: 'Hi.', CardBlockRole.handle: text}, coverShown: true).editorPlacements(size)[CardBlockRole.handle]!;
      // A handle whose width falls between the room less the side gap and
      // the room itself: it would touch the record's area without the gap.
      Rect? tight;
      search:
      for (var k = 0; k < 30; k++) {
        for (var j = 0; j < 8; j++) {
          final box = handleFor('@${'m' * k}${'.' * j}');
          if (box.width > room - side + 1 && box.width < room - 1) {
            tight = box;
            break search;
          }
        }
      }
      expect(tight, isNotNull, reason: 'a width in the window exists');
      expect(tight!.top, greaterThanOrEqualTo(record.bottom + kPlacedTextGapPx - 0.5), reason: 'not squeezed against the record: under it, a gap away');
      expect(handleFor('@x').top, lessThan(record.bottom), reason: 'a short one fits beside it');
    });

    test('the @handle is placed first and the words keep clear of it (Gradient wave, Bottom)', () {
      for (final (name, size, safe) in _networkCards) {
        final d = designWithHandle(_template('gradientWave').withWordsPosition(TextCardTextPosition.bottom), '@my.handle');
        final at = CardDesignPainter(design: d, texts: const {CardBlockRole.postText: _long, CardBlockRole.handle: '@my.handle'}, safe: safe, waveform: const [0.5, 0.8, 0.3])
            .editorPlacements(size);
        final words = at[CardBlockRole.postText]!, handle = at[CardBlockRole.handle]!;
        final wave = cardPictureAreas(d, size, safe, coverShown: false, waveformShown: true).single;
        expect(handle.bottom, lessThanOrEqualTo(wave.top - kPlacedTextGapPx * cardUnit(size) + 0.5), reason: '$name: the @handle above the waveform');
        expect(words.bottom, lessThanOrEqualTo(handle.top - kPlacedTextGapPx * cardUnit(size) + 0.5), reason: '$name: the words above the @handle');
      }
    });
  });

  group('N5, N8: where the placed text goes', () {
    for (final (shape, size) in const [('1:1', Size(360, 360)), ('4:5', Size(360, 450))]) {
      testWidgets('N5 $shape: Vinyl\'s added @handle sits at the top right, beside the record', (tester) async {
        final d = designWithHandle(_template('vinyl'), '@my.handle');
        final texts = {CardBlockRole.postText: 'Hi.', CardBlockRole.handle: '@my.handle'};
        final withHandle = await draw(tester, d, size, texts: texts);
        final without = await draw(tester, d, size, texts: {...texts, CardBlockRole.handle: ''});
        final handle = _differing(withHandle, without);
        expect(handle.length, greaterThan(8), reason: 'drawn');
        final frame = cardFrameOf(size, EdgeInsets.zero, d.margin);
        expect(handle.every((p) => p.dy < frame.top + frame.height * 0.15), isTrue, reason: 'on the top edge, not pushed under the record');
        expect(handle.every((p) => p.dx > frame.center.dx), isTrue, reason: 'on the right');
      });
    }

    testWidgets('the band follows the row: Top above a block in the middle, Bottom below it, Middle in the taller band', (tester) async {
      // Minimal with a line of its own across the middle: two free bands for
      // the words, the upper one taller (the lower holds the @handle and the
      // signature).
      const size = Size(360, 450);
      final minimal = _template('minimal');
      final split = minimal.copyWith(blocks: [...minimal.blocks, const CardTextBlock(role: CardBlockRole.custom, text: 'A LINE ACROSS THE MIDDLE', anchor: CardAnchor.center, size: 60)]);
      final frame = cardFrameOf(size, EdgeInsets.zero, split.margin);
      final texts = {CardBlockRole.handle: '@robin.makes'};
      Future<(double, double)> wordsSpan(TextCardTextPosition p) async {
        final d = split.withWordsPosition(p);
        final words = _differing(await draw(tester, d, size, texts: {...texts, CardBlockRole.postText: 'Short words.'}), await draw(tester, d, size, texts: {...texts, CardBlockRole.postText: ''}));
        expect(words, isNotEmpty, reason: p.name);
        final ys = words.map((o) => o.dy);
        return (ys.reduce((a, b) => a < b ? a : b), ys.reduce((a, b) => a > b ? a : b));
      }

      final middleLine = frame.center.dy;
      final top = await wordsSpan(TextCardTextPosition.top);
      expect(top.$2, lessThan(middleLine), reason: 'Top: the band above the line');
      expect(top.$1, lessThan(frame.top + frame.height * 0.1), reason: 'at its top');
      final bottom = await wordsSpan(TextCardTextPosition.bottom);
      expect(bottom.$1, greaterThan(middleLine), reason: 'Bottom: the band below the line');
      final middle = await wordsSpan(TextCardTextPosition.center);
      expect(middle.$2, lessThan(middleLine), reason: 'Middle: the taller band, above the line');
      expect(middle.$1, greaterThan(top.$1 + 10), reason: 'centred in it, not at its top');
    });

    testWidgets('N8: Polaroid with no photo draws no frame, so Top words are at the top', (tester) async {
      const size = Size(360, 450);
      final d = _template('polaroid').withWordsPosition(TextCardTextPosition.top);
      final texts = {CardBlockRole.postText: 'Short words at the top.'};
      final words = _differing(await draw(tester, d, size, texts: texts), await draw(tester, d, size, texts: const {CardBlockRole.postText: ''}));
      expect(words, isNotEmpty);
      final frame = cardFrameOf(size, EdgeInsets.zero, d.margin);
      expect(words.map((p) => p.dy).reduce((a, b) => a < b ? a : b), lessThan(frame.top + frame.height * 0.1));
    });
  });

  group('N6: the size the words come out at is measured where they are placed', () {
    test('round 6: Polaroid under a photo on a square card shows every word of the long post at every position', () {
      // Critic 5, finding 1: with the border counted once the 215-character
      // post fits whole (about 31 px) where round 5 cut it at 28 px.
      for (final p in TextCardTextPosition.values) {
        final d = _template('polaroid').withWordsPosition(p);
        final m = CardDesignPainter(design: d, texts: const {CardBlockRole.postText: _long}, coverShown: true).drawnWords(const Size(1080, 1080))!;
        expect(m.cut, isFalse, reason: p.name);
        expect(m.dropped, isFalse, reason: p.name);
        expect(m.size, greaterThanOrEqualTo(kPlacedWordsMinPx), reason: p.name);
      }
    });

    test('a post three times as long is cut at the minimum under the photo, and measured where it is placed', () {
      final d = _template('polaroid').withWordsPosition(TextCardTextPosition.top);
      final under = CardDesignPainter(design: d, texts: {CardBlockRole.postText: _veryLong}, coverShown: true).drawnWords(const Size(1080, 1080))!;
      expect(under.size, kPlacedWordsMinPx);
      expect(under.cut, isTrue);
      final free = CardDesignPainter(design: d, texts: {CardBlockRole.postText: _veryLong}).drawnWords(const Size(1080, 1080))!;
      expect(free.size > under.size || !free.cut, isTrue, reason: 'no photo, no frame: more room');
      expect(CardDesignPainter(design: d, texts: {CardBlockRole.postText: _veryLong}, coverShown: true).drawnWordsSize(const Size(1080, 1080)), under.size);
    });

    test('Vinyl Top on a square card keeps every word of a long post, larger than the minimum', () {
      final d = _template('vinyl').withWordsPosition(TextCardTextPosition.top);
      final m = CardDesignPainter(design: d, texts: const {CardBlockRole.postText: _long}, coverShown: true).drawnWords(const Size(1080, 1080))!;
      expect(m.cut, isFalse);
      expect(m.size, greaterThan(kPlacedWordsMinPx));
    });
  });

  group('in the app', () {
    Future<(AppServices, ProviderContainer)> boot(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
      await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
      await tester.pump(const Duration(milliseconds: 300));
      return (services, ProviderScope.containerOf(tester.element(find.byType(MaterialApp))));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    Future<Map<String, ConnectedAccount>> compose(WidgetTester tester, ProviderContainer c, {String text = 'Readable, and clear of every picture.'}) async {
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final demo = c.read(accountListProvider);
      final byPlatform = {for (final p in _platforms) p: demo.firstWhere((a) => a.platformId == p)};
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), text);
      c.read(composerProvider.notifier)
        ..selectAccounts([for (final a in byPlatform.values) a.id])
        ..setTextCardEveryNetwork(true);
      await settle(tester);
      return byPlatform;
    }

    Finder key(String name) => find.byKey(Key('$_master-$name'));

    Future<void> tap(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(f);
      await settle(tester);
    }

    testWidgets('N7: Polaroid under a photo: a cut post is said folded, under the cards and unfolded, with only true advice', (tester) async {
      final (_, c) = await boot(tester);
      c.read(composerProvider.notifier)
        ..setTextCardDesign(_template('polaroid').withWordsPosition(TextCardTextPosition.top))
        ..setTextCardBackground(const TextCardBackground(photo: _photo).toJson());
      await compose(tester, c, text: _veryLong);
      // Folded: the warning shows under the fold, and under each square card.
      expect(key('handle-size'), findsNothing, reason: 'the controls are folded');
      expect(key('fit-warning'), findsOneWidget);
      expect(tester.widget<Text>(key('fit-warning')).data, contains('cut at 28 px'));
      expect(find.byKey(const ValueKey('text-card-fit-warning-bluesky')), findsOneWidget);
      expect(find.byKey(const ValueKey('text-card-fit-warning-mastodon')), findsOneWidget);
      // Unfolded: the size note says it, and claims no position helps where
      // none does (all three cut under the photo).
      await tap(tester, key('more'));
      expect(find.textContaining('Too long for this card on'), findsWidgets);
      expect(find.textContaining('shows every word'), findsNothing);
      // The 215-character post fits whole: no warning anywhere.
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), _long);
      await settle(tester);
      expect(find.textContaining('cut at'), findsNothing);
      expect(find.byKey(const ValueKey('text-card-fit-warning-bluesky')), findsNothing);
      await finish(tester);
    });

    testWidgets('the note on Gradient wave counts the waveform the saved card draws', (tester) async {
      // A post long enough to be cut only once the waveform's band is
      // taken: the preview's measurement must take it too.
      final d = designWithHandle(_template('gradientWave').withWordsPosition(TextCardTextPosition.bottom), '@my.handle');
      bool cutWith(List<double>? waveform, String text) => CardDesignPainter(
              design: d, texts: {CardBlockRole.postText: text, CardBlockRole.handle: '@my.handle'}, waveform: waveform, platformId: 'bluesky')
          .drawnWords(const Size(1080, 1080))!
          .cut;
      String? text;
      for (var n = 1; n < 60 && text == null; n++) {
        final t = List.filled(n, 'Words that need room on the card.').join(' ');
        if (cutWith(const [1.0], t) && !cutWith(null, t)) text = t;
      }
      expect(text, isNotNull, reason: 'a length cut only with the waveform taken');
      final (_, c) = await boot(tester);
      c.read(composerProvider.notifier).setTextCardDesign(d);
      await compose(tester, c, text: text!);
      await tester.enterText(key('handle'), '@my.handle');
      await settle(tester);
      expect(find.byKey(const ValueKey('text-card-fit-warning-bluesky')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('advice: when another position shows every word, the note names it', (tester) async {
      // Minimal with a line of its own a third of the way down: Top gets the
      // short band above it, Bottom the tall band below. A post long enough
      // to be cut above fits below.
      final minimal = _template('minimal');
      final split = minimal.copyWith(blocks: [
        ...minimal.blocks,
        const CardTextBlock(role: CardBlockRole.custom, text: 'A LINE', anchor: CardAnchor.topCenter, offsetY: 0.3, size: 40),
      ]).withWordsPosition(TextCardTextPosition.top);
      ({double size, bool cut, bool dropped, bool handleDropped}) at(TextCardTextPosition p, String text) =>
          CardDesignPainter(design: split.withWordsPosition(p), texts: {CardBlockRole.postText: text, CardBlockRole.handle: '@a'}).drawnWords(const Size(1080, 1080))!;
      String? text;
      for (var n = 1; n < 40 && text == null; n++) {
        final t = List.filled(n, 'Words that need room on the card.').join(' ');
        if (at(TextCardTextPosition.top, t).cut && !at(TextCardTextPosition.bottom, t).cut) text = t;
      }
      expect(text, isNotNull, reason: 'a length that is cut at Top and whole at Bottom');
      final (_, c) = await boot(tester);
      c.read(composerProvider.notifier).setTextCardDesign(split);
      await compose(tester, c, text: text!);
      if (key('handle-size').evaluate().isEmpty) await tap(tester, key('more'));
      expect(find.textContaining('Too long for this place on'), findsWidgets);
      expect(find.textContaining('Middle shows every word').evaluate().isNotEmpty || find.textContaining('Bottom shows every word').evaluate().isNotEmpty, isTrue);
      await finish(tester);
    });

    testWidgets('N13/N14: the saved cards keep the placement in their render parameters', (tester) async {
      final (_, c) = await boot(tester);
      c.read(composerProvider.notifier).setTextCardDesign(_template('vinyl').withWordsPosition(TextCardTextPosition.bottom));
      await compose(tester, c);
      await tester.enterText(key('handle'), '@my.handle');
      await settle(tester);
      final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
      final cards = post.media.where(isRenderedTextCard).toList();
      expect(cards, hasLength(_platforms.length));
      for (final card in cards) {
        final d = textCardDesignOf(card)!;
        expect((d.placeWords, d.placeHandle), (true, true), reason: '${card.width}x${card.height}');
      }
      await finish(tester);
    });

    testWidgets('switch: the designer turns the placement off and back on', (tester) async {
      final (_, c) = await boot(tester);
      c.read(composerProvider.notifier).setTextCardDesign(_template('vinyl').withWordsPosition(TextCardTextPosition.top));
      await compose(tester, c);
      final design = find.descendant(of: find.byKey(const ValueKey('text-card-style-bluesky')), matching: find.byKey(const Key('text-card-design')));
      await tap(tester, design);
      await tap(tester, find.byKey(const Key('card-designer-group-layout')));
      final clear = find.byKey(const Key('card-place-clear'));
      expect(clear, findsOneWidget);
      CardDesign now() => CardDesign.tryParse(c.read(composerProvider).textCardDesign)!;
      expect(now().placeWords, isTrue);
      await tap(tester, clear);
      expect((now().placeWords, now().placeHandle), (false, false), reason: 'off: drawn where the anchor and offsets put them');
      await tap(tester, clear);
      expect((now().placeWords, now().placeHandle), (true, false), reason: 'on: only blocks the design has (Vinyl has no @handle block)');
      await tap(tester, find.byKey(const Key('card-designer-done')));
      await finish(tester);
    });

    testWidgets('theme: a theme changed in Settings > Text cards drops a @handle colour that would not read', (tester) async {
      final (_, c) = await boot(tester);
      await c.read(settingsProvider.notifier).update((s) => s.copyWith(textCardTheme: TextCardTheme.dark));
      final accounts = await compose(tester, c);
      final n = c.read(composerProvider.notifier);
      // A white @handle (reads on black, not on white) and red words (over
      // 3:1 on both).
      n.setTextCardStyle(const TextCardStyle(handle: '@my.handle', handleColor: 0xFFFFFFFF, textColor: 0xFFE63946));
      await settle(tester);
      expect(c.read(composerProvider).textCardTheme, isNull, reason: 'the post follows Settings');
      await tester.runAsync(() => c.read(settingsProvider.notifier).update((s) => s.copyWith(textCardTheme: TextCardTheme.light)));
      await settle(tester);
      final style = c.read(composerProvider).textCardStyle;
      expect(style.handleColor, isNull, reason: 'white on the white card goes');
      expect(style.textColor, 0xFFE63946, reason: 'a colour that still reads stays');
      expect(style.handle, '@my.handle');
      final placeholder = c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == accounts['bluesky']!.id).variant.media.single;
      expect(textCardStyleOf(placeholder).handleColor, isNull, reason: 'the stand-in follows');
      await finish(tester);
    });
  });
}
