// 1.3.5: the placement gate for the text card editor's words and @handle on
// card designer designs. Written before the layout it judges (round 5 of the
// review) and judged on rendered pixels: the picture areas come from the
// pictures as the compositor DRAWS them (the card without its text, cover
// shadow off, against the same card without its cover and waveform), never
// from the layout's own geometry, so a picture drawn somewhere the layout
// does not expect fails here (round-5 critic, G1).
//
// Two parts, on the six real card shapes (1:1 Bluesky, 4:5 Instagram, 2:3
// Pinterest, and the 9:16 TikTok, Snapchat and Instagram story cards, each
// with its safe area):
//
// The matrix: every built-in template x words Top / Middle / Bottom x a typed
// @handle or not x a photo or not: 720 cells.
// The sweep: Vinyl, Polaroid and Gradient wave with a photo x margins 24 /
// 120 / 200 / 240 x @handle size 28 / 64 / 96 x words at the template's size
// or 240 x Top / Middle / Bottom, on the 1:1 and TikTok cards: 432 cells.
//
// Each cell checks:
//  (a) no pixel of the editor's text (the words, and the @handle when the
//      editor placed it) on a drawn picture or inside the picture's drawn
//      bounds (between a waveform's bars counts), on the template's own text,
//      or inside the network's safe area;
//  (b) matrix only: the template's own blocks are drawn exactly where the
//      untouched template draws them (the sweep resizes some on purpose);
//  (c) the words come out at no less than kMinWordsPx (pixels at 1080 wide),
//      and every word is on the card: in the matrix (the template's own
//      margin and @handle size) words cut (ellipsis) or left off FAIL, even
//      when no position would fit (round 7); in the sweep they FAIL when
//      another position shows every word, and only cells where no position
//      can are listed, with the reason;
//  (d) the @handle the editor placed is drawn (or reported left off, under
//      the same rule) and never under the words.
//
// Plus, on full-size renders: the room under the drawn picture for Top on
// Vinyl and on Polaroid with a photo is at most kPlacedTextGapPx + the
// card's declared slack + 6 px (round 7).

import 'dart:io';

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
  await family('Times New Roman', [r'C:\Windows\Fonts\times.ttf', r'C:\Windows\Fonts\timesi.ttf']);
  await family('Arial', [r'C:\Windows\Fonts\arial.ttf', r'C:\Windows\Fonts\arialbd.ttf']);
}

/// A card shape: its name, the size it is rendered at here, its real size
/// (measured at) and its safe area in pixels at 1080.
typedef _Shape = (String name, Size render, Size real, EdgeInsets safe);

final List<_Shape> _shapes = [
  ('1:1', const Size(360, 360), textCardSize('bluesky'), EdgeInsets.zero),
  ('4:5', const Size(360, 450), textCardSize('instagram'), EdgeInsets.zero),
  ('2:3', const Size(400, 600), textCardSize('pinterest'), EdgeInsets.zero),
  ('9:16 TikTok', const Size(360, 640), textCardSize('tiktok'), textCardSafeArea('tiktok')),
  ('9:16 Snapchat', const Size(360, 640), textCardSize('snapchat'), textCardSafeArea('snapchat')),
  ('9:16 Instagram story', const Size(360, 640), textCardSize('instagram', story: true), textCardSafeArea('instagram', story: true)),
];

/// A rendered card's pixels, RGB.
class _Px {
  _Px(img.Image i)
      : width = i.width,
        height = i.height,
        rgb = i.getBytes(order: img.ChannelOrder.rgb);
  final int width, height;
  final Uint8List rgb;
}

/// Where [a] and [b] differ by more than [threshold] (summed over RGB), every
/// pixel: 1 or 0 per pixel.
Uint8List _mask(_Px a, _Px b, [int threshold = 60]) {
  final m = Uint8List(a.width * a.height);
  final p = a.rgb, q = b.rgb;
  for (var i = 0, o = 0; i < m.length; i++, o += 3) {
    if ((p[o] - q[o]).abs() + (p[o + 1] - q[o + 1]).abs() + (p[o + 2] - q[o + 2]).abs() > threshold) m[i] = 1;
  }
  return m;
}

int _count(Uint8List m) {
  var n = 0;
  for (final v in m) {
    n += v;
  }
  return n;
}

int _both(Uint8List a, Uint8List b) {
  var n = 0;
  for (var i = 0; i < a.length; i++) {
    n += a[i] & b[i];
  }
  return n;
}

/// The last row of [m] (rows [width] wide) with a pixel set; null if none.
int? _lastRow(Uint8List m, int width) {
  for (var i = m.length - 1; i >= 0; i--) {
    if (m[i] == 1) return i ~/ width;
  }
  return null;
}

Uint8List _or(Uint8List a, Uint8List b) => Uint8List.fromList([for (var i = 0; i < a.length; i++) a[i] | b[i]]);

/// The drawn pictures as one mask: their pixels, and the bounding box of
/// each picture's pixels (so the gaps between a waveform's bars count).
Uint8List _pictureArea(Uint8List drawn, int width) {
  final out = Uint8List.fromList(drawn);
  // A box per run of rows that hold picture pixels: each picture of these
  // templates is one such run (a cover above, a waveform below).
  final height = drawn.length ~/ width;
  var y = 0;
  while (y < height) {
    // Find the next run of rows with picture pixels.
    bool rowHas(int r) {
      for (var x = 0; x < width; x++) {
        if (drawn[r * width + x] == 1) return true;
      }
      return false;
    }

    while (y < height && !rowHas(y)) {
      y++;
    }
    if (y >= height) break;
    final top = y;
    var left = width, right = -1;
    while (y < height && rowHas(y)) {
      for (var x = 0; x < width; x++) {
        if (drawn[y * width + x] == 1) {
          if (x < left) left = x;
          if (x > right) right = x;
        }
      }
      y++;
    }
    for (var r = top; r < y; r++) {
      for (var x = left; x <= right; x++) {
        out[r * width + x] = 1;
      }
    }
  }
  return out;
}

/// Pixels of [m] inside the network's safe area.
int _inSafe(Uint8List m, int width, Size size, EdgeInsets safe) {
  final u = size.width / 1080, height = m.length ~/ width;
  var n = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (m[y * width + x] == 0) continue;
      if (y < safe.top * u - 1 || x > size.width - safe.right * u + 1 || y > size.height - safe.bottom * u + 1) n++;
    }
  }
  return n;
}

CardDesign _withoutWords(CardDesign d) => d.copyWith(blocks: [for (final b in d.blocks) if (b.role != CardBlockRole.postText) b]);

void main() {
  setUpAll(_loadFonts);

  PhotoPixels? photo;

  Future<_Px> draw(WidgetTester tester, CardDesign d, _Shape shape, {required Map<CardBlockRole, String> texts, required bool withPhoto}) async {
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
          size: shape.$2,
          safe: shape.$4,
          platformId: 'instagram',
          texts: texts,
          photo: withPhoto ? photo : null,
          photoBackground: withPhoto ? const TextCardBackground(photo: _photoRef) : null,
          cover: withPhoto ? photo : null,
          waveform: d.waveform.visible ? decorativeWaveform(7) : null,
        ),
        png: true)))!;
    return _Px(img.decodePng(bytes)!);
  }

  // Renders that do not depend on the words, kept per key.
  final cache = <String, Object>{};
  Future<T> kept<T extends Object>(String key, Future<T> Function() make) async => (cache[key] ??= await make()) as T;

  /// The drawn pictures of [d] on [shape] (with [withPhoto]), as an area.
  Future<Uint8List> pictures(WidgetTester tester, CardDesign d, _Shape shape, bool withPhoto) => kept('pic|${d.template}|${d.margin}|${shape.$1}|$withPhoto', () async {
        final on = await draw(tester, d.copyWith(blocks: const [], cover: d.cover.copyWith(shadow: 0)), shape, texts: const {}, withPhoto: withPhoto);
        final off = await draw(tester, d.copyWith(blocks: const [], cover: d.cover.copyWith(visible: false), waveform: d.waveform.copyWith(visible: false)), shape,
            texts: const {}, withPhoto: withPhoto);
        return _pictureArea(_mask(on, off, 40), on.width);
      });

  ({double size, bool cut, bool dropped, bool handleDropped})? measure(CardDesign d, _Shape shape, Map<CardBlockRole, String> texts, bool withPhoto) =>
      CardDesignPainter(
        design: d,
        texts: texts,
        safe: shape.$4,
        platformId: 'instagram',
        waveform: d.waveform.visible ? decorativeWaveform(7) : null,
        coverShown: cardCoverDrawn(d, picture: withPhoto),
      ).drawnWords(shape.$3);

  /// The rule for words that do not all show: a FAIL when another position
  /// shows every word on this card, else a listed cell with the reason.
  /// Null when every word shows.
  (bool fail, String why)? missing(CardDesign d, TextCardTextPosition position, _Shape shape, Map<CardBlockRole, String> texts, bool withPhoto, String label) {
    final m = measure(d, shape, texts, withPhoto);
    if (m == null || (!m.cut && !m.dropped && !m.handleDropped)) return null;
    final what = m.dropped ? 'words left off' : (m.cut ? 'words cut at ${m.size.toStringAsFixed(1)} px' : 'handle left off');
    for (final other in TextCardTextPosition.values) {
      if (other == position) continue;
      final o = measure(d.withWordsPosition(other), shape, texts, withPhoto);
      if (o != null && !o.cut && !o.dropped && !o.handleDropped) return (true, '(c) $what where ${other.name} shows everything');
    }
    return (false, '$label: $what; no position fits it (${m.dropped || m.handleDropped ? 'no free band left by the margins and handle size' : 'the post is longer than any free band holds at ${kMinWordsPx.toInt()} px'})');
  }

  final summary = <String>[];
  final sweep = <String>[];
  final listed = <String>[];
  tearDownAll(() {
    int fails(List<String> s) => s.where((l) => l.startsWith('FAIL')).length;
    // ignore: avoid_print
    print('PLACEMENT GATE: ${fails(summary)} of ${summary.length} cells fail');
    // ignore: avoid_print
    print('PLACEMENT SWEEP: ${fails(sweep)} of ${sweep.length} cells fail');
    for (final s in [...summary, ...sweep].where((s) => s.startsWith('FAIL'))) {
      // ignore: avoid_print
      print(s);
    }
    // ignore: avoid_print
    print('Cells where no arrangement shows everything: ${listed.length}${listed.isEmpty ? '' : '\n  ${listed.join('\n  ')}'}');
  });

  /// One cell; returns its problems (empty: PASS).
  Future<List<String>> cell(WidgetTester tester, CardDesign template, CardDesign design, TextCardTextPosition position, _Shape shape,
      {required bool typed, required bool withPhoto, required bool checkMoved, required bool strict, required String label}) async {
    final handleText = typed ? _typed : _own;
    // The editor placed the @handle when it added one for a typed handle, or
    // when the handle was edited onto a design that places it.
    final editorHandle = design.placeHandle && design.handleBlock != null;
    final texts = {CardBlockRole.postText: _long, CardBlockRole.handle: handleText};
    final noEditorTexts = {...texts, if (editorHandle) CardBlockRole.handle: ''};
    final full = await draw(tester, design, shape, texts: texts, withPhoto: withPhoto);
    final noWords = await draw(tester, _withoutWords(design), shape, texts: texts, withPhoto: withPhoto);
    final noEditorText = await draw(tester, _withoutWords(design), shape, texts: noEditorTexts, withPhoto: withPhoto);
    final reference = await kept('ref|${template.template}|${shape.$1}|$withPhoto|${noEditorTexts[CardBlockRole.handle]}',
        () => draw(tester, _withoutWords(template), shape, texts: noEditorTexts, withPhoto: withPhoto));
    final bare = await kept('bare|${design.template}|${design.margin}|${shape.$1}|$withPhoto', () => draw(tester, design.copyWith(blocks: const []), shape, texts: texts, withPhoto: withPhoto));
    final picture = await pictures(tester, design, shape, withPhoto);
    final words = _mask(full, noWords);
    final handle = editorHandle ? _mask(noWords, noEditorText) : Uint8List(words.length);
    final editor = _or(words, handle);
    final templateText = _mask(noEditorText, bare);
    final problems = <String>[];
    // (a)
    final onPicture = _both(editor, picture);
    if (onPicture > 0) problems.add('(a) $onPicture text pixels on a drawn picture');
    final onTemplate = _both(words, templateText) + _both(handle, templateText);
    if (onTemplate > 3) problems.add('(a) $onTemplate text pixels on the template\'s own text');
    final inSafe = _inSafe(editor, full.width, shape.$2, shape.$4);
    if (inSafe > 0) problems.add('(a) $inSafe text pixels in the safe area');
    // (b)
    if (checkMoved) {
      final moved = _count(_mask(noEditorText, reference));
      if (moved > 3) problems.add('(b) template blocks moved ($moved pixels)');
    }
    // (c)
    final m = measure(design, shape, texts, withPhoto);
    final miss = missing(design, position, shape, texts, withPhoto, label);
    if (miss != null) {
      // Round 7 (critic 6): at the template's own margin and handle size
      // (the matrix, [strict]) every word of the 215-character post must
      // show, whether or not another position would fit: a geometry that
      // wastes room (round 5's Polaroid) fails here instead of being listed.
      if (miss.$1 || strict) {
        problems.add(strict && !miss.$1 ? '(c) at the template\'s own margin and handle size: ${miss.$2.substring(label.length + 2)}' : miss.$2);
      } else {
        listed.add(miss.$2);
      }
    }
    if (m != null && !m.dropped && m.size < kMinWordsPx) problems.add('(c) words at ${m.size.toStringAsFixed(1)} px');
    // Cut while they could still have shrunk: the post loses words for a
    // size nobody needs.
    if (m != null && m.cut && m.size > kMinWordsPx + 0.5) problems.add('(c) words cut at ${m.size.toStringAsFixed(1)} px, above the ${kMinWordsPx.toInt()} px they may shrink to');
    if (m != null && !m.dropped && _count(words) < 30) problems.add('(c) words not drawn');
    // (d)
    if (editorHandle && !(m?.handleDropped ?? false)) {
      if (_count(handle) < 8) problems.add('(d) handle not drawn');
      final under = _both(handle, words);
      if (under > 2) problems.add('(d) handle under the words ($under pixels)');
    }
    return problems;
  }

  for (final t in kCardTemplates) {
    testWidgets('placement gate: ${t.name}', (tester) async {
      final template = t.design(CardKind.text);
      final failures = <String>[];
      for (final position in TextCardTextPosition.values) {
        for (final typed in [false, true]) {
          for (final withPhoto in [false, true]) {
            for (final shape in _shapes) {
              final label = '${t.id} words=${position.name} handle=${typed ? 'typed' : 'own'} photo=$withPhoto ${shape.$1}';
              var design = template.withWordsPosition(position);
              if (typed) design = designWithHandle(design, _typed);
              final problems = await cell(tester, template, design, position, shape, typed: typed, withPhoto: withPhoto, checkMoved: true, strict: true, label: label);
              final line = '${problems.isEmpty ? 'PASS' : 'FAIL'} $label${problems.isEmpty ? '' : ': ${problems.join('; ')}'}';
              summary.add(line);
              if (problems.isNotEmpty) failures.add(line);
            }
          }
        }
      }
      cache.clear();
      expect(failures, isEmpty, reason: failures.join('\n'));
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  // Round 7 (critic 6): the room left under a drawn picture, on full-size
  // renders (1080 px wide; Pinterest's 1000) of every shape. For Top on
  // Vinyl (with and without a photo) and on Polaroid with a photo, from the
  // picture's lowest drawn pixel (cover shadow off) to the words' laid-out
  // box top, the room is at most kPlacedTextGapPx + that card's declared
  // slack + 6 px. The slack is the template's declared rectangle (the data
  // in kCardTemplatePictureAreas, read here, not through the layout's
  // geometry) below that drawn pixel, so room counted twice (round 5 counted
  // Polaroid's border outside its square as well as inside) fails here.
  testWidgets('room under the picture, full size: Top on Vinyl and on Polaroid with a photo', (tester) async {
    final failures = <String>[];
    for (final (id, photos) in [('vinyl', [false, true]), ('polaroid', [true])]) {
      final template = cardTemplateById(id)!.design(CardKind.text);
      final design = template.withWordsPosition(TextCardTextPosition.top);
      for (final withPhoto in photos) {
        for (final shape in _shapes) {
          final full = (shape.$1, shape.$3, shape.$3, shape.$4);
          final size = shape.$3, u = cardUnit(size);
          final on = await draw(tester, design.copyWith(blocks: const [], cover: design.cover.copyWith(shadow: 0)), full, texts: const {}, withPhoto: withPhoto);
          final off = await draw(tester, design.copyWith(blocks: const [], cover: design.cover.copyWith(visible: false)), full, texts: const {}, withPhoto: withPhoto);
          final lowest = _lastRow(_mask(on, off, 40), on.width);
          final box = CardDesignPainter(
            design: design,
            texts: const {CardBlockRole.postText: _long, CardBlockRole.handle: _own},
            safe: shape.$4,
            platformId: 'instagram',
            coverShown: cardCoverDrawn(design, picture: withPhoto),
          ).editorPlacements(size)[CardBlockRole.postText];
          final label = '$id photo=$withPhoto ${shape.$1}';
          if (lowest == null || box == null) {
            failures.add('$label: ${lowest == null ? 'no picture drawn' : 'no words placed'}');
            continue;
          }
          final pictureBottom = lowest + 1.0;
          final frame = cardFrameOf(size, shape.$4, design.margin);
          final declared = kCardTemplatePictureAreas[id]!.cover[cardShapeOf(size)]!;
          final declaredBottom = frame.top + declared.bottom * frame.shortestSide;
          final slack = (declaredBottom - pictureBottom).clamp(0.0, double.infinity) / u;
          final room = (box.top - pictureBottom) / u;
          final bound = kPlacedTextGapPx + slack + 6;
          final line = 'ROOM $label: room ${room.toStringAsFixed(1)} px, bound ${bound.toStringAsFixed(1)} px (slack ${slack.toStringAsFixed(1)}), margin ${(bound - room).toStringAsFixed(1)} px';
          // ignore: avoid_print
          print(line);
          if (room > bound) failures.add(line);
          if (room < kPlacedTextGapPx - 1) failures.add('$line: closer than the gap');
        }
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 10)));
  for (final id in ['vinyl', 'polaroid', 'gradientWave']) {
    testWidgets('placement sweep: $id, margins x handle size x words size', (tester) async {
      final template = cardTemplateById(id)!.design(CardKind.text);
      final failures = <String>[];
      for (final margin in [24.0, 120.0, 200.0, 240.0]) {
        for (final handleSize in [28.0, 64.0, 96.0]) {
          for (final wordsSize in [null, 240.0]) {
            for (final position in TextCardTextPosition.values) {
              for (final shape in [_shapes[0], _shapes[3]]) {
                final label = '$id margin=${margin.toInt()} handle=${handleSize.toInt()} words=${wordsSize?.toInt() ?? 'template'} ${position.name} ${shape.$1}';
                var design = designWithHandle(template.withWordsPosition(position), _typed).withMargin(margin).withHandleSize(handleSize);
                if (wordsSize != null) design = design.withWordsSize(wordsSize);
                final problems = await cell(tester, template, design, position, shape, typed: true, withPhoto: true, checkMoved: false, strict: false, label: label);
                final line = '${problems.isEmpty ? 'PASS' : 'FAIL'} sweep $label${problems.isEmpty ? '' : ': ${problems.join('; ')}'}';
                sweep.add(line);
                if (problems.isNotEmpty) failures.add(line);
              }
            }
          }
        }
      }
      cache.clear();
      expect(failures, isEmpty, reason: failures.join('\n'));
    }, timeout: const Timeout(Duration(minutes: 15)));
  }
}
