// 1.3.5 review fixes, round 4, for the text card editor: one group per
// finding of the third blind review, each with a test that fails without
// its fix, on the saved pictures where the finding is about them.
//  1. A handle place never puts the words on Vinyl's record.
//  2. A handle colour picked for a photo never leaves an unreadable
//     @handle on the plain card.
//  3. The added handle, and words at the bottom, keep clear of Gradient
//     wave's waveform.
//  4. Words placed at the top before a photo is added keep clear of
//     Polaroid's framed photo.
//  6. The "Other…" then Black chip order, the editor's chips against the
//     drawn card, and the words' room under a cover.
//  7. A design that hides its handle says so.
//  8. Vinyl's handle at the top centre keeps clear of the record.

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
import 'package:neforum_app/state/card_designs.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/text_cards.dart' show isRenderedTextCard;
import 'package:neforum_app/ui/compose/rich_text.dart';
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
  await family('Times New Roman', [r'C:\Windows\Fonts\times.ttf']);
}

const _platforms = ['instagram', 'bluesky', 'mastodon'];
const _master = 'text-card-master-style';
const _photo = MediaAttachment(id: 'bg-photo', path: 'mem://bg-photo.jpg', mimeType: 'image/jpeg', sizeBytes: 10, width: 100, height: 100);
const _size = Size(270, 338);
const _words = 'Words that would cover the picture on that edge if they were allowed to, long enough to fill lines.';

CardDesign _template(String id) => cardTemplateById(id)!.design(CardKind.text);

/// [d] drawn small, with [handle] as the @handle and an optional [photo].
Future<img.Image> _draw(WidgetTester tester, CardDesign d, {String? handle, PhotoPixels? photo, String text = _words}) async {
  final backdrop = photo == null ? null : TextCardBackdrop(pixels: photo, luminance: photo.luminance, background: const TextCardBackground(photo: _photo));
  final bytes = (await tester.runAsync(() => renderDesignedTextCard(_MemoryStorage(),
      design: d, platformId: 'instagram', size: _size, text: text, byline: handle, backdrop: backdrop)))!;
  return img.decodeJpg(bytes)!;
}

/// How many sampled pixels of [area] differ between [a] and [b].
int _differing(img.Image a, img.Image b, Rect area) {
  var n = 0;
  for (var y = area.top.ceil(); y < area.bottom.floor(); y += 2) {
    for (var x = area.left.ceil(); x < area.right.floor(); x += 2) {
      final p = a.getPixel(x, y), q = b.getPixel(x, y);
      if ((p.r - q.r).abs() + (p.g - q.g).abs() + (p.b - q.b).abs() > 60) n++;
    }
  }
  return n;
}

/// [d] with no text: the pictures alone.
CardDesign _picturesOnly(CardDesign d) => d.copyWith(blocks: const []);

/// 1.3.5 round 5: [d] without the editor's words and @handle, the
/// template's own blocks kept: Gradient wave's signature sits on its own
/// waveform as the template was made, and only the editor's text is judged.
CardDesign _withoutEditorText(CardDesign d) =>
    d.copyWith(blocks: [for (final b in d.blocks) if (b.role != CardBlockRole.postText && b.role != CardBlockRole.handle) b]);

void main() {
  setUpAll(_loadFonts);

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

  Future<Map<String, ConnectedAccount>> compose(WidgetTester tester, ProviderContainer c) async {
    c.read(routerProvider).go('/compose');
    await settle(tester);
    final demo = c.read(accountListProvider);
    final byPlatform = {for (final p in _platforms) p: demo.firstWhere((a) => a.platformId == p)};
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), 'Readable, and clear of every picture.');
    c.read(composerProvider.notifier)
      ..selectAccounts([for (final a in byPlatform.values) a.id])
      ..setTextCardEveryNetwork(true);
    await settle(tester);
    return byPlatform;
  }

  Finder key(String name) => find.byKey(Key('$_master-$name'));

  Future<void> tapKey(WidgetTester tester, String name) async {
    await tester.ensureVisible(key(name));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(key(name));
    await settle(tester);
  }

  Rect recordOf(CardDesign d) => cardCoverRect(d.cover, cardFrameOf(_size, EdgeInsets.zero, d.margin)).deflate(3);

  group('1. a handle place never puts the words on Vinyl\'s record', () {
    for (final (name, edit) in [
      ('words Top, then handle Top centre', (CardDesign d) => d.withWordsPosition(TextCardTextPosition.top).withHandlePosition(TextCardHandlePosition.topCenter)),
      ('handle Top centre, then words Top', (CardDesign d) => d.withHandlePosition(TextCardHandlePosition.topCenter).withWordsPosition(TextCardTextPosition.top)),
      ('words Top, then handle Top left', (CardDesign d) => d.withWordsPosition(TextCardTextPosition.top).withHandlePosition(TextCardHandlePosition.topLeft)),
    ]) {
      testWidgets('$name: the record looks the same with the text on it', (tester) async {
        final d = edit(_template('vinyl'));
        final withText = await _draw(tester, d, handle: '@neforum.app');
        final alone = await _draw(tester, _picturesOnly(d));
        expect(_differing(withText, alone, recordOf(d)), lessThan(8));
      });
    }

    test('round 5: both are placed by the renderer, and the template\'s blocks keep their order and places', () {
      final vinyl = _template('vinyl');
      final d = vinyl.withWordsPosition(TextCardTextPosition.top).withHandlePosition(TextCardHandlePosition.topCenter);
      expect(d.placeWords, isTrue);
      expect(d.placeHandle, isTrue);
      expect(d.wordsBlock!.anchor.name, startsWith('top'));
      expect([for (final b in d.blocks) b.role], [for (final b in vinyl.blocks) b.role, CardBlockRole.handle], reason: 'no stacking reorder any more; the added handle goes on the end');
      for (var i = 0; i < vinyl.blocks.length; i++) {
        final b = d.blocks[i], was = vinyl.blocks[i];
        if (b.role == CardBlockRole.postText || b.role == CardBlockRole.handle) continue;
        expect((b.anchor, b.offsetX, b.offsetY), (was.anchor, was.offsetX, was.offsetY), reason: '${b.role} never moves');
      }
    });
  });

  group('2. a handle colour picked for a photo never leaves an unreadable handle', () {
    testWidgets('dark card, black handle for a light photo, back to Colour: the saved card shows the handle', (tester) async {
      final (s, c) = await boot(tester);
      await compose(tester, c);
      c.read(composerProvider.notifier)
        ..setTextCardTheme(TextCardTheme.dark)
        ..setTextCardBackground(const TextCardBackground(photo: _photo).toJson())
        ..setTextCardStyle(c.read(composerProvider).textCardStyle.copyWith(handle: '@my.long.handle.here', handleColor: 0xFF000000));
      await settle(tester);
      c.read(composerProvider.notifier).setTextCardBackground(null);
      await settle(tester);
      expect(c.read(composerProvider).textCardStyle.handleColor, isNull, reason: 'black on the black card: back to the words\' colour');
      expect(c.read(composerProvider).textCardStyle.handle, '@my.long.handle.here');
      final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
      final card = post.media.where(isRenderedTextCard).first;
      final picture = img.decodeJpg((await tester.runAsync(() => s.media.read(card)))!)!;
      // The footer's right half, where the handle sits beside the signature.
      var light = 0;
      for (var y = picture.height * 85 ~/ 100; y < picture.height; y++) {
        for (var x = picture.width * 55 ~/ 100; x < picture.width; x++) {
          final p = picture.getPixel(x, y);
          if (p.r + p.g + p.b > 300) light++;
        }
      }
      expect(light, greaterThan(40), reason: 'the handle is visible');
      await finish(tester);
    });

    testWidgets('a readable handle colour stays; a theme that would hide it drops it', (tester) async {
      final (_, c) = await boot(tester);
      await compose(tester, c);
      final n = c.read(composerProvider.notifier)
        ..setTextCardTheme(TextCardTheme.dark)
        ..setTextCardStyle(const TextCardStyle(handleColor: 0xFFFFD60A))
        ..setTextCardBackground(const TextCardBackground(photo: _photo).toJson())
        ..setTextCardBackground(null);
      expect(c.read(composerProvider).textCardStyle.handleColor, 0xFFFFD60A, reason: 'yellow on black reads');
      n.setTextCardStyle(const TextCardStyle(handleColor: 0xFFFFFFFF));
      n.setTextCardTheme(TextCardTheme.light);
      expect(c.read(composerProvider).textCardStyle.handleColor, isNull, reason: 'white on the white card would vanish');
      await finish(tester);
    });
  });

  group('3. Gradient wave: the added handle and words at the bottom keep clear of the waveform', () {
    Rect waveOf(CardDesign d) => cardWaveformRect(d.waveform, cardFrameOf(_size, EdgeInsets.zero, d.margin)).deflate(2);

    testWidgets('the handle added for a typed handle', (tester) async {
      final d = designWithHandle(_template('gradientWave'), '@a.rather.long.handle');
      final withText = await _draw(tester, d, handle: '@a.rather.long.handle', text: 'Hi.');
      final alone = await _draw(tester, _withoutEditorText(d), text: 'Hi.');
      expect(_differing(withText, alone, waveOf(d)), lessThan(6));
    });

    testWidgets('words moved to the bottom', (tester) async {
      final d = _template('gradientWave').withWordsPosition(TextCardTextPosition.bottom);
      final withText = await _draw(tester, d);
      final alone = await _draw(tester, _withoutEditorText(d));
      expect(_differing(withText, alone, waveOf(d)), lessThan(6));
    });
  });

  group('4. words at the top before a photo is added keep clear of Polaroid\'s framed photo', () {
    testWidgets('Top with no photo, then a photo: the framed photo is untouched', (tester) async {
      // Placed while the post had no photo.
      final d = _template('polaroid').withWordsPosition(TextCardTextPosition.top);
      final source = img.Image(width: 120, height: 120)..clear(img.ColorRgb8(40, 160, 220));
      final photo = (await tester.runAsync(() => decodePhotoPixels(img.encodeJpg(source), maxSide: 200)))!;
      final withText = await _draw(tester, d, photo: photo);
      final alone = await _draw(tester, _picturesOnly(d), photo: photo);
      final frame = cardFrameOf(_size, EdgeInsets.zero, d.margin);
      final framed = cardCoverRect(d.cover, frame).deflate(14);
      expect(_differing(withText, alone, framed), lessThan(8));
      // And the words are on the card at all, under the photo.
      expect(_differing(withText, alone, Offset.zero & _size), greaterThan(50));
    });
  });

  group('6. tests for the mutations that survived round 3', () {
    testWidgets('M1: "Other…" yellow, then the photo\'s Black chip: the card follows the last change (black)', (tester) async {
      final (_, c) = await boot(tester);
      await compose(tester, c);
      c.read(composerProvider.notifier)
        ..setTextCardBackground(const TextCardBackground(photo: _photo).toJson())
        ..setTextCardWordsColour(0xFFFFD60A)
        ..setTextCardPhotoWordsColour(TextCardTextColor.black);
      final s = c.read(composerProvider);
      expect(s.textCardStyle.textColor, isNull);
      expect(textCardWordsColour(s.textCardStyle, TextCardBackground.tryParse(s.textCardBackground)), 0xFF000000);
      await finish(tester);
    });

    testWidgets('M4: on a design without a handle, the editor\'s chips and size show the handle the card draws', (tester) async {
      final (_, c) = await boot(tester);
      c.read(composerProvider.notifier).setTextCardDesign(_template('gradientWave'));
      await compose(tester, c);
      await tester.enterText(key('handle'), '@neforum.app');
      await settle(tester);
      if (key('handle-size').evaluate().isEmpty) await tapKey(tester, 'more');
      final drawn = designWithHandle(_template('gradientWave'), '@neforum.app');
      expect(drawn.handlePosition, TextCardHandlePosition.bottomLeft);
      expect(tester.widget<ChoiceChip>(key('handle-corner-bottomLeft')).selected, isTrue, reason: 'where the card draws it');
      expect(tester.widget<ChoiceChip>(key('handle-corner-bottomRight')).selected, isFalse);
      await finish(tester);
    });

    testWidgets('M5: under a cover the words keep the template\'s room, and a too small room falls back to the frame', (tester) async {
      final vinyl = _template('vinyl');
      // A design an earlier build cut the room of (for a baked cover offset).
      final cut = vinyl.withBlock(vinyl.blocks.indexWhere((b) => b.role == CardBlockRole.postText), (b) => b.copyWith(maxHeight: 0.12));
      final top = cut.withWordsPosition(TextCardTextPosition.top);
      expect(top.wordsBlock!.maxHeight, vinyl.wordsBlock!.maxHeight, reason: 'the template\'s room back');
      // The words still come out large enough to read under the record.
      final size = CardDesignPainter(design: top, texts: const {CardBlockRole.postText: _words}, coverShown: true).drawnWordsSize(const Size(1080, 1350));
      expect(size, greaterThan(30));
    });
  });

  group('7. a design that hides its handle says so', () {
    testWidgets('typed handle on a hidden handle block: the note, not "In place of"', (tester) async {
      final (_, c) = await boot(tester);
      final m = _template('minimal');
      final hidden = m.withBlock(m.blocks.indexWhere((b) => b.role == CardBlockRole.handle), (b) => b.copyWith(visible: false));
      c.read(composerProvider.notifier).setTextCardDesign(hidden);
      await compose(tester, c);
      await tester.enterText(key('handle'), '@neforum.app');
      await settle(tester);
      expect(find.textContaining('This design hides its handle'), findsOneWidget);
      expect(find.textContaining('In place of'), findsNothing);
      await finish(tester);
    });
  });

  group('8. Vinyl\'s handle at the top centre keeps clear of the record', () {
    testWidgets('the record looks the same with the handle above it', (tester) async {
      final d = _template('vinyl').withHandlePosition(TextCardHandlePosition.topCenter);
      final withText = await _draw(tester, d, handle: '@a.handle.long.enough.to.see', text: 'Hi.');
      final alone = await _draw(tester, _picturesOnly(d), text: 'Hi.');
      expect(_differing(withText, alone, recordOf(d)), lessThan(6));
    });

    testWidgets('also on a design with a handle of its own (the place chip itself keeps it clear)', (tester) async {
      // Vinyl as a user design that already has a handle at the bottom,
      // saved before 1.3.5 placement existed.
      final own = _template('vinyl').withHandleBlock().copyWith(placeHandle: false);
      expect(own.placeHandle, isFalse);
      final d = own.withHandlePosition(TextCardHandlePosition.topCenter);
      expect(d.placeHandle, isTrue);
      final withText = await _draw(tester, d, handle: '@a.handle.long.enough.to.see', text: 'Hi.');
      final alone = await _draw(tester, _picturesOnly(d), text: 'Hi.');
      expect(_differing(withText, alone, recordOf(d)), lessThan(6));
    });
  });
}
