// Text cards and captions on photos (1.2.0): caption styles, the block above
// the photo (and its overlay for videos), the five alignments, the @handle,
// background photos on cards, render parameters, and the fixes (card reuse
// per account, captions kept for scheduled posts, every thread part on the
// card, a network's own photo list kept under its card, captioned photos made
// before 1.2.0 kept in their style).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/aligned_text.dart';
import 'package:neforum_app/media/caption_overlay.dart';
import 'package:neforum_app/media/caption_style.dart';
import 'package:neforum_app/media/photo_pixels.dart';
import 'package:neforum_app/media/render_parameters.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/media/text_card_background.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/captioned_photos.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/fitted_photos.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/render_warnings.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/state/text_cards.dart';
import 'package:neforum_app/ui/compose/caption_editor_sheet.dart';
import 'package:neforum_app/ui/compose/card_background_sheet.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/widgets/layout.dart' show showToast;
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
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-SemiBold.ttf', 'assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
}

/// Columns of [rgba] (width [w]) in row [y] that have ink (alpha > 0).
(int, int) _inkSpan(ByteData rgba, int w, int y) {
  var minX = w, maxX = -1;
  for (var x = 0; x < w; x++) {
    if (rgba.getUint8((y * w + x) * 4 + 3) > 0) {
      if (x < minX) minX = x;
      maxX = x;
    }
  }
  return (minX, maxX);
}

Future<ByteData> _paint(Size size, void Function(Canvas) draw) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  final image = await recorder.endRecording().toImage(size.width.round(), size.height.round());
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  return data;
}

Uint8List _photo(int width, int height, img.Color colour) => img.encodeJpg(img.Image(width: width, height: height)..clear(colour), quality: 95);

void main() {
  setUpAll(_loadFonts);

  group('caption style', () {
    test('round-trips through JSON; missing or out-of-range values take the default', () {
      const style = CaptionStyle(
        text: 'Sale today',
        placement: CaptionPlacement.blockAbove,
        textScale: 1.4,
        textColor: 0xFF000000,
        background: CaptionBackground.solid,
        backgroundColor: 0xFFFFFF00,
        opacity: 0.9,
        alignment: TextCardAlignment.distributed,
        font: TextCardFont.arial,
        bold: true,
        shadow: true,
        lineSpacing: 1.5,
        padding: 40,
      );
      expect(CaptionStyle.fromJson(style.toJson()), style);
      expect(CaptionStyle.fromJson(const {}), const CaptionStyle());
      expect(CaptionStyle.fromJson(null).placement, CaptionPlacement.bottom);
      final odd = CaptionStyle.fromJson(const {'textScale': 9, 'opacity': -1, 'lineSpacing': 'x', 'placement': 'sideways', 'text': '  '});
      expect((odd.textScale, odd.opacity, odd.lineSpacing, odd.placement, odd.text), (CaptionStyle.maxTextScale, 0.0, 1.22, CaptionPlacement.bottom, null));
      expect(const CaptionStyle().wordsFor('The caption'), 'The caption');
      expect(style.wordsFor('The caption'), 'Sale today');
      expect(const CaptionStyle().copyWith(textScale: 2).copyWith(automaticSize: true).fixedSize, isFalse);
    });

    test('the default looks like the caption did before: white on a translucent dark label, centred, low', () {
      const s = CaptionStyle();
      expect((s.placement, s.alignment, s.font, s.textColor), (CaptionPlacement.bottom, TextCardAlignment.center, TextCardFont.platform, 0xFFFFFFFF));
      expect(s.backgroundFill.a, closeTo(0.65, 0.01));
      expect(s.opaqueBackgroundArgb, 0xFF000000);
      expect(const CaptionStyle(background: CaptionBackground.solid, backgroundColor: 0xFFFF0000, opacity: 1).opaqueBackgroundArgb, 0xFFFF0000);
    });

    test('render parameters compare by content', () {
      expect(renderParametersEqual({'a': 1, 'b': 12.0, 'c': [1, 2]}, {'c': [1, 2], 'b': 12, 'a': 1}), isTrue);
      expect(renderParametersEqual({'a': 1}, {'a': 2}), isFalse);
      expect(renderParametersEqual(null, {'a': 1}), isFalse);
    });
  });

  group('alignment', () {
    const width = 300.0;
    const style = TextStyle(fontSize: 20, color: Color(0xFF000000));

    testWidgets('distributed: every line spans the width, the last one too; a single word is centred', (tester) async {
      await tester.runAsync(() async {
        final words = AlignedText('aa bb cc dd ee ff gg hh ii\nword', style: style, alignment: TextCardAlignment.distributed, direction: TextDirection.ltr)
          ..layout(width);
        expect(words.width, width);
        final data = await _paint(Size(width, words.height), (c) => words.paint(c, Offset.zero));
        for (final y in [8, 28]) {
          final (left, right) = _inkSpan(data, width.toInt(), y);
          expect(left, lessThanOrEqualTo(2), reason: 'line at $y starts at the left edge');
          expect(right, greaterThanOrEqualTo(width - 3), reason: 'line at $y ends at the right edge');
        }
        final (left, right) = _inkSpan(data, width.toInt(), 48);
        expect(((left + right) / 2 - width / 2).abs(), lessThan(3), reason: 'a single word is centred');
        expect(right - left, lessThan(100));
        words.dispose();
      });
    });

    testWidgets('justify spreads every line but the last; centre and right line up as asked', (tester) async {
      await tester.runAsync(() async {
        final justified = AlignedText('aa bb cc dd ee ff gg hh ii', style: style, alignment: TextCardAlignment.justify, direction: TextDirection.ltr)
          ..layout(width);
        final j = await _paint(Size(width, justified.height), (c) => justified.paint(c, Offset.zero));
        expect(_inkSpan(j, width.toInt(), 8).$2, greaterThanOrEqualTo(width - 3));
        expect(_inkSpan(j, width.toInt(), 28).$2, lessThan(width - 40), reason: 'the last line is not stretched');
        justified.dispose();

        for (final (a, expected) in [(TextCardAlignment.center, 150.0), (TextCardAlignment.right, 270.0), (TextCardAlignment.left, 30.0)]) {
          final t = AlignedText('abc', style: style, alignment: a, direction: TextDirection.ltr)..layout(width, fill: true);
          final d = await _paint(Size(width, t.height), (c) => t.paint(c, Offset.zero));
          final (l, r) = _inkSpan(d, width.toInt(), 8);
          expect((l + r) / 2, closeTo(expected, 3), reason: a.name);
          t.dispose();
        }
      });
    });

    test('right-to-left words start at the right edge with the default (left) alignment', () {
      expect(textAlignOf(TextCardAlignment.left), TextAlign.start);
      expect(alignmentAnchor(TextCardAlignment.left, TextDirection.rtl), 1);
      expect(alignmentAnchor(TextCardAlignment.right, TextDirection.ltr), 1);
      expect(alignmentAnchor(TextCardAlignment.justify, TextDirection.ltr), 0.5);
    });
  });

  group('caption block above the photo', () {
    test('as tall as the words need, within 14% to 45% of the frame; the content gets the rest', () {
      const frame = Size(1080, 1920);
      final short = CaptionBlockLayout.measure(text: 'Hi', style: const CaptionStyle(placement: CaptionPlacement.blockAbove), font: TextCardFont.original, frame: frame);
      expect(short.block.height, closeTo(1920 * kCaptionBlockMinShare, 0.5));
      expect(short.content, Rect.fromLTWH(0, short.block.height, 1080, 1920 - short.block.height));
      short.dispose();

      final long = CaptionBlockLayout.measure(
        text: List.filled(80, 'words that go on').join(' '),
        style: const CaptionStyle(placement: CaptionPlacement.blockAbove),
        font: TextCardFont.original,
        frame: frame,
        safe: fullScreenSafeArea('tiktok'),
      );
      expect(long.block.height, lessThanOrEqualTo(1920 * kCaptionBlockMaxShare + 0.5));
      expect(long.block.height, greaterThan(short.block.height));
      long.dispose();
    });

    testWidgets('for a video: a transparent full-frame PNG with the block, the content rectangle and the frame colour', (tester) async {
      final overlay = (await tester.runAsync(() => renderCaptionBlockOverlay(
            text: 'New drop this Friday',
            style: const CaptionStyle(placement: CaptionPlacement.blockAbove, background: CaptionBackground.solid, backgroundColor: 0xFFFF0000, opacity: 1),
            platformId: 'tiktok',
            frameAspect: 9 / 16,
          )))!;
      expect((overlay.frameWidth, overlay.frameHeight), (1080, 1920));
      expect(overlay.backgroundArgb, 0xFFFF0000);
      expect(overlay.contentRect.bottom, 1920);
      expect(overlay.contentRect.top, greaterThan(1920 * kCaptionBlockMinShare - 1));
      final png = img.decodePng(overlay.png)!;
      expect((png.width, png.height), (1080, 1920));
      final block = png.getPixel(20, 20);
      expect((block.r, block.g, block.a), (255, 0, 255), reason: 'the block is drawn in the frame colour');
      expect(png.getPixel(540, 1500).a, 0, reason: 'transparent over the video');
    });

    testWidgets('for a photo: the whole frame, the block on top and the photo below', (tester) async {
      final out = (await tester.runAsync(() => renderCaptionedPhoto(
            _photo(800, 800, img.ColorRgb8(20, 40, 220)),
            text: 'Blue square',
            font: TextCardFont.original,
            platformId: 'instagram',
            style: const CaptionStyle(placement: CaptionPlacement.blockAbove, background: CaptionBackground.solid, backgroundColor: 0xFFFFFF00, opacity: 1),
            frameAspect: 4 / 5,
          )))!;
      expect((out.width, out.height), (1080, 1350));
      final frame = img.decodeJpg(out.bytes)!;
      final top = frame.getPixel(10, 10);
      expect(top.r > 200 && top.g > 200 && top.b < 80, isTrue, reason: 'the yellow block at the top');
      final photo = frame.getPixel(540, 1100);
      expect(photo.b > 180 && photo.r < 80, isTrue, reason: 'the photo below the block');
    });

    group('composed on the CPU', () {
      // A 400 x 200 photo: left half red, right half blue.
      final halves = Uint8List(400 * 200 * 4);
      for (var i = 0; i < 400 * 200; i++) {
        final red = i % 400 < 200;
        halves.setAll(i * 4, [red ? 230 : 10, 10, red ? 10 : 230, 255]);
      }
      const content = Rect.fromLTWH(0, 300, 1080, 1050);
      img.Image compose({PhotoFitMode fit = PhotoFitMode.pad, int? background, Uint8List? words, Uint8List? photo}) =>
          img.decodeJpg(composeCaptionedPhoto(CaptionComposeJob(
            photo: photo ?? halves,
            photoWidth: 400,
            photoHeight: 200,
            words: words ?? Uint8List(1080 * 1350 * 4),
            width: 1080,
            height: 1350,
            content: content,
            fit: fit,
            topColor: 0x00FF00,
            bottomColor: 0x0000FF,
            backgroundArgb: background,
          )))!;
      bool near(img.Pixel p, int r, int g, int b, [int tolerance = 40]) => (p.r - r).abs() < tolerance && (p.g - g).abs() < tolerance && (p.b - b).abs() < tolerance;

      test('fit: the whole photo centred in the content, a blur of it around', () {
        final f = compose();
        // Scaled to 1080 x 540, centred in 300..1350: rows 555..1095.
        expect(near(f.getPixel(100, 820), 230, 10, 10), isTrue, reason: 'red half');
        expect(near(f.getPixel(980, 820), 10, 10, 230), isTrue, reason: 'blue half');
        final border = f.getPixel(540, 400);
        expect(border.r + border.g + border.b, inInclusiveRange(60, 500), reason: 'a blur of the photo, not white or black');
      });

      test('colour fill: the photo\'s edge colours top to bottom', () {
        final f = compose(fit: PhotoFitMode.color);
        expect(near(f.getPixel(540, 2), 0, 255, 0), isTrue, reason: 'top colour');
        expect(near(f.getPixel(540, 1347), 0, 0, 255), isTrue, reason: 'bottom colour');
      });

      test('crop: the photo fills the content, cut around its centre', () {
        final f = compose(fit: PhotoFitMode.crop);
        // The middle 210 x 200 of the photo: the red/blue edge at x = 540.
        expect(near(f.getPixel(200, 320), 230, 10, 10), isTrue);
        expect(near(f.getPixel(880, 1330), 10, 10, 230), isTrue);
      });

      test('a see-through background colour tints the frame and stays opaque', () {
        final f = compose(background: 0x80000000);
        final border = f.getPixel(540, 400);
        final plain = compose().getPixel(540, 400);
        expect(border.r + border.g + border.b, lessThan(plain.r + plain.g + plain.b), reason: 'darker, never white');
        expect(f.numChannels, 3);
      });

      test('the words layer goes over everything, with its alpha', () {
        final words = Uint8List(1080 * 1350 * 4);
        void dot(int x, int y, int a) => words.setAll((y * 1080 + x) * 4, [255, 255, 0, a]);
        for (var y = 100; y < 140; y++) {
          for (var x = 100; x < 140; x++) {
            dot(x, y, 255);
          }
        }
        final f = compose(words: words, fit: PhotoFitMode.color);
        expect(near(f.getPixel(120, 120), 255, 255, 0, 20), isTrue);
      });

      test('on the photo: the photo at its own size, a transparent part black', () {
        final see = Uint8List.fromList(halves);
        for (var i = 3; i < see.length; i += 4) {
          if ((i ~/ 4) ~/ 400 < 20) see[i] = 0;
        }
        final f = img.decodeJpg(composeCaptionedPhoto(
            CaptionComposeJob(photo: see, photoWidth: 400, photoHeight: 200, words: Uint8List(400 * 200 * 4), width: 400, height: 200)))!;
        expect((f.width, f.height), (400, 200));
        expect(near(f.getPixel(100, 5), 0, 0, 0, 20), isTrue);
        expect(near(f.getPixel(100, 100), 230, 10, 10), isTrue);
      });

      test('a text card over a photo: cover-fitted, blurred, dimmed, the card on top', () {
        final px = PhotoPixels(rgba: halves, width: 400, height: 200, luminance: 0.3, topColor: 0, bottomColor: 0);
        img.Image card(double dimming) => img.decodeJpg(composeTextCard(
            TextCardComposeJob(photo: px, words: Uint8List(1080 * 1350 * 4), width: 1080, height: 1350, blur: 12, dimming: dimming)))!;
        final clear = card(0), dimmed = card(0.5);
        expect((clear.width, clear.height), (1080, 1350));
        expect(near(clear.getPixel(60, 675), 230, 10, 10), isTrue, reason: 'red half, cut to cover');
        expect(near(clear.getPixel(1020, 675), 10, 10, 230), isTrue, reason: 'blue half');
        expect(near(dimmed.getPixel(60, 675), 115, 5, 5, 25), isTrue, reason: 'half as bright');
      });
    });

    testWidgets('on the photo: the label goes to the top or the bottom as asked', (tester) async {
      await tester.runAsync(() async {
        Future<ByteData> render(CaptionPlacement p) => _paint(const Size(1080, 1080), (c) {
              CaptionOverlayPainter(
                text: 'Label',
                font: TextCardFont.original,
                style: CaptionStyle(placement: p, background: CaptionBackground.solid, backgroundColor: 0xFFFF0000, opacity: 1, alignment: TextCardAlignment.left),
              ).paint(c, const Size(1080, 1080));
            });
        int alpha(ByteData d, int x, int y) => d.getUint8((y * 1080 + x) * 4 + 3);
        final top = await render(CaptionPlacement.top);
        final bottom = await render(CaptionPlacement.bottom);
        expect(alpha(top, 70, 70), 255, reason: 'top left: the label');
        expect(alpha(top, 70, 1010), 0);
        expect(alpha(bottom, 70, 1010), 255, reason: 'bottom left: the label');
        expect(alpha(bottom, 1000, 1010), 0, reason: 'left-aligned: nothing on the right');
      });
    });
  });

  group('render parameters of text cards', () {
    test('placeholders carry every choice; old cards are read from their file names', () {
      final p = textCardPlaceholder('tiktok', TextCardTheme.light,
          branded: false, font: TextCardFont.arial, alignment: TextCardAlignment.justify, showsHandle: false);
      expect(textCardThemeOf(p), TextCardTheme.light);
      expect(textCardFontOf(p), TextCardFont.arial);
      expect(textCardBrandedOf(p), isFalse);
      expect(textCardAlignmentOf(p), TextCardAlignment.justify);
      expect(textCardShowsHandleOf(p), isFalse);
      expect(textCardSafeOf(p), isTrue);
      expect(textCardPlatformOf(p), 'tiktok');

      final old = MediaAttachment(
          id: 'c', path: '/c.jpg', mimeType: 'image/jpeg', sizeBytes: 1, fileName: 'neforum-text-card-light-plain-font-arial-safe.jpg', generated: true);
      expect((textCardThemeOf(old), textCardFontOf(old), textCardBrandedOf(old), textCardSafeOf(old)), (TextCardTheme.light, TextCardFont.arial, false, true));
      expect((textCardAlignmentOf(old), textCardShowsHandleOf(old), textCardPlatformOf(old)), (TextCardAlignment.left, true, null));
    });

    test('a background photo qualifies a target only when it is that target\'s only photo', () {
      final d = builtinRegistry().descriptor('instagram')!;
      const photo = MediaAttachment(id: 'p', path: '/p.jpg', mimeType: 'image/jpeg', sizeBytes: 1);
      const other = MediaAttachment(id: 'q', path: '/q.jpg', mimeType: 'image/jpeg', sizeBytes: 1);
      expect(qualifiesForTextCard(d, const PostVariant(text: 'x', media: [photo])), isFalse);
      expect(qualifiesForTextCard(d, const PostVariant(text: 'x', media: [photo]), backgroundMediaId: 'p'), isTrue);
      expect(qualifiesForTextCard(d, const PostVariant(text: 'x', media: [photo, other]), backgroundMediaId: 'p'), isFalse);
      expect(takesTextCards(d), isTrue);
      expect(takesTextCards(builtinRegistry().descriptor('mastodon')!), isFalse);
    });

    test('fix: the words of a thread are every part, as networks without threads get them; an empty first part is left out', () {
      final now = DateTime(2026, 10, 25);
      const target = PostTarget(accountId: 'ig');
      final thread = Post(
        id: 'p-parts',
        text: 'Big news',
        additionalParts: const ['We launched today; details in the link', '#launch https://example.com/launch'],
        targets: const [target],
        createdAt: now,
        updatedAt: now,
      );
      expect(textCardText(thread, target), 'Big news\n\nWe launched today; details in the link', reason: 'the trailing tag line stays in the caption');
      expect(captionWords(thread, target), textCardText(thread, target), reason: 'the caption on a photo has the same words');

      final plain = thread.copyWith(additionalParts: const ['We launched today; details in the link']);
      final instagram = const VariantResolver().resolve(plain, target, builtinRegistry().descriptor('instagram')!);
      expect(textCardText(plain, target), instagram.text, reason: 'the words Instagram receives');

      final secondOnly = thread.copyWith(text: '', additionalParts: const ['Only the second part has words']);
      expect(textCardText(secondOnly, target), 'Only the second part has words', reason: 'never a blank card');
      const version = PostTarget(accountId: 'ig', overrides: PostOverrides(text: 'Words for Instagram only'));
      expect(textCardText(thread, version), 'Words for Instagram only', reason: 'the network\'s own version replaces every part');
    });

    test('the composer keeps the new choices across restarts', () {
      const photo = MediaAttachment(id: 'bg', path: '/data/media/bg.jpg', mimeType: 'image/jpeg', sizeBytes: 3);
      final c = ComposerState(
        text: 'x',
        textCardAlignment: TextCardAlignment.distributed,
        textCardHandle: const {'instagram': false},
        captionStyle: const CaptionStyle(placement: CaptionPlacement.blockAbove).toJson(),
        textCardBackground: const TextCardBackground(photo: photo, blur: 20).toJson(),
      );
      final back = composerDraftFromJson(composerDraftToJson(c))!;
      expect(back.textCardAlignment, TextCardAlignment.distributed);
      expect(back.textCardHandle, {'instagram': false});
      expect(CaptionStyle.fromJson(back.captionStyle).placement, CaptionPlacement.blockAbove);
      final bg = TextCardBackground.tryParse(back.textCardBackground)!;
      expect((bg.photo.path, bg.blur), ('/data/media/bg.jpg', 20.0));
    });
  });

  group('with a workspace', () {
    Future<(AppServices, ProviderContainer)> boot(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
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

    ConnectedAccount account(String id, String platform, String handle) =>
        ConnectedAccount(id: id, platformId: platform, tier: PlatformTier.handoff, displayName: handle, handle: handle, createdAt: DateTime(2026, 10, 1));

    testWidgets('a picture left out for taking too long: a banner that outlasts the save toast, until dismissed', (tester) async {
      await boot(tester);
      reportRenderWarning('The text card for Instagram took too long to make, so Instagram gets no card.');
      reportRenderWarning('Writing the caption on the photo for TikTok took too long, so the photo goes without it.');
      await settle(tester);
      expect(find.byType(MaterialBanner), findsOneWidget);
      expect(find.textContaining('Instagram gets no card'), findsOneWidget);
      expect(find.textContaining('for TikTok took too long'), findsOneWidget, reason: 'both warnings in one banner');

      // The toast after a save does not take it away.
      showToast(tester.element(find.byType(Scaffold).first), 'Saved to drafts');
      await settle(tester);
      expect(find.textContaining('Instagram gets no card'), findsOneWidget);

      await tester.tap(find.text('Dismiss'));
      await settle(tester);
      expect(find.byType(MaterialBanner), findsNothing);
      await finish(tester);
    });

    MediaAttachment cardOf(Post post, String accountId) =>
        post.media.firstWhere((m) => m.id == post.targetFor(accountId)!.overrides.mediaIds!.single);

    Future<bool> exists(WidgetTester tester, AppServices s, MediaAttachment m) async => (await tester.runAsync(() async {
          try {
            await s.media.read(m);
            return true;
          } on Object {
            return false;
          }
        }))!;

    testWidgets('fix: each account keeps its own card when the cards are made again (publishing runs it twice)', (tester) async {
      final (s, c) = await boot(tester);
      final ana = account('ig-ana', 'instagram', '@ana');
      final ben = account('ig-ben', 'instagram', '@ben');
      final snap = account('snap-1', 'snapchat', '@snappy');
      final tiktok = c.read(accountListProvider).firstWhere((a) => a.platformId == 'tiktok');
      await tester.runAsync(() async {
        for (final a in [ana, ben, snap]) {
          await s.accounts.upsert(a);
        }
      });
      final now = DateTime(2026, 10, 25);
      var post = Post(
        id: 'p-cards',
        text: 'Two accounts, two cards, two handles.',
        targets: [PostTarget(accountId: ana.id), PostTarget(accountId: ben.id), PostTarget(accountId: tiktok.id), PostTarget(accountId: snap.id)],
        createdAt: now,
        updatedAt: now,
      );
      post = (await tester.runAsync(() => attachTextCards(s, post, s.settings)))!;
      expect(cardOf(post, ana.id).renderParameters!['byline'], '@ana');
      expect(cardOf(post, ben.id).renderParameters!['byline'], '@ben');
      expect(cardOf(post, tiktok.id).renderParameters!['platform'], 'tiktok');
      expect(cardOf(post, snap.id).renderParameters!['platform'], 'snapchat');
      expect({for (final t in post.targets) t.overrides.mediaIds!.single}.length, 4, reason: 'four different cards');

      // The second run, as Publish now does from the saved post.
      final again = (await tester.runAsync(() => attachTextCards(s, post, s.settings)))!;
      for (final t in post.targets) {
        expect(again.targetFor(t.accountId)!.overrides.mediaIds, t.overrides.mediaIds, reason: 'the same card for ${t.accountId}');
      }
      expect(again.media.where(isRenderedTextCard).length, 4);
      await finish(tester);
    });

    testWidgets('1.3: the same card on every network goes to each target that takes images, at its size, with its words as alt text',
        (tester) async {
      final (s, c) = await boot(tester);
      final youtube = account('yt-1', 'youtube', '@robin');
      await tester.runAsync(() => s.accounts.upsert(youtube));
      final demo = c.read(accountListProvider);
      final byPlatform = {for (final p in ['mastodon', 'bluesky', 'x', 'instagram']) p: demo.firstWhere((a) => a.platformId == p)};
      final platforms = {for (final a in [...byPlatform.values, youtube]) a.id: a.platformId};
      final now = DateTime(2026, 10, 28);
      final written = Post(
        id: 'p-every',
        text: 'One card, every network.\n\n#cards',
        targets: [for (final id in platforms.keys) PostTarget(accountId: id)],
        createdAt: now,
        updatedAt: now,
      );

      // Off (the default): only the network that needs an image gets a card.
      final before = (await tester.runAsync(() => attachTextCards(s, written, s.settings)))!;
      expect([for (final t in before.targets) if (t.overrides.mediaIds != null) platforms[t.accountId]], ['instagram']);

      // On, with Mastodon getting the card alone.
      var post = withTextCardChoices(written, everyNetwork: true, withText: const {'mastodon': false}, platformOf: (id) => platforms[id]);
      expect(textCardEveryNetworkOfPost(post), isTrue);
      post = (await tester.runAsync(() => attachTextCards(s, post, s.settings)))!;
      final words = textCardText(post, post.targets.first);
      expect(words, 'One card, every network.', reason: 'trailing hashtags stay in the text');
      for (final platform in ['mastodon', 'bluesky', 'x', 'instagram']) {
        final card = cardOf(post, byPlatform[platform]!.id);
        expect(isRenderedTextCard(card), isTrue, reason: platform);
        expect(card.altText, words, reason: '$platform: the card\'s words are its alt text');
        expect(Size(card.width!.toDouble(), card.height!.toDouble()), textCardSize(platform), reason: platform);
      }
      expect(post.targetFor(youtube.id)!.overrides.mediaIds, isNull, reason: 'YouTube takes no images: plain text');

      // What each network receives: Mastodon only the card, the others the text too.
      final resolver = VariantResolver(s.settings.resolverOptions);
      PostVariant variant(ConnectedAccount a) => resolver.resolve(post, post.targetFor(a.id)!, s.registry.byId(a.platformId)!.descriptorForAccount(a), account: a);
      final mastodon = variant(byPlatform['mastodon']!);
      expect(mastodon.text, isEmpty);
      expect(mastodon.media.single.altText, words);
      expect(variant(byPlatform['bluesky']!).text, contains('One card, every network.'));

      // Published later from the saved post: the same choices, the same cards.
      final again = (await tester.runAsync(() => attachTextCards(s, post, s.settings)))!;
      for (final t in post.targets) {
        expect(again.targetFor(t.accountId)!.overrides.mediaIds, t.overrides.mediaIds, reason: 'kept for ${platforms[t.accountId]}');
      }

      // Edited again: the choices come back as the composer's, not as overrides.
      await settle(tester);
      c.read(composerProvider.notifier).load(again);
      final composer = c.read(composerProvider);
      expect(composer.textCardEveryNetwork, isTrue);
      expect(composer.textCardWithText, {'mastodon': false});
      for (final o in composer.overrides.values) {
        expect(o.extra.containsKey(kTextCardEveryNetworkKey) || o.extra.containsKey(kTextCardOnlyKey), isFalse);
      }
      await finish(tester);
    });

    testWidgets('1.3: the composer previews the card on every network and says which networks keep plain text', (tester) async {
      final (s, c) = await boot(tester);
      final youtube = account('yt-2', 'youtube', '@robin');
      await tester.runAsync(() => s.accounts.upsert(youtube));
      await settle(tester);
      final demo = c.read(accountListProvider);
      final mastodon = demo.firstWhere((a) => a.platformId == 'mastodon');
      final instagram = demo.firstWhere((a) => a.platformId == 'instagram');
      final notifier = c.read(composerProvider.notifier)
        ..selectAccounts([mastodon.id, instagram.id, youtube.id])
        ..prefill('Words for everyone.');
      TargetPreview preview(ConnectedAccount a) => c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == a.id);

      expect(preview(mastodon).variant.media, isEmpty, reason: 'off by default');
      expect(isTextCardPlaceholder(preview(instagram).variant.media.single), isTrue);

      notifier.setTextCardEveryNetwork(true);
      final card = preview(mastodon).variant.media.single;
      expect(isTextCardPlaceholder(card), isTrue);
      expect(card.altText, 'Words for everyone.');
      expect(preview(mastodon).variant.text, 'Words for everyone.');
      expect(preview(youtube).issues.map((i) => i.code), contains('media.text_card_unsupported'));

      notifier.setTextCardWithText('mastodon', false);
      expect(preview(mastodon).variant.text, isEmpty);
      expect(isTextCardPlaceholder(preview(mastodon).variant.media.single), isTrue);
      expect(preview(instagram).variant.text, 'Words for everyone.', reason: 'per network');

      // The per-post choice leaves the Settings default alone.
      await settle(tester);
      expect(c.read(settingsProvider).textCardEveryNetwork, isFalse);
      await finish(tester);
    });

    testWidgets('1.3: the card background editor groups its controls and edits the composer live', (tester) async {
      final (s, c) = await boot(tester);
      const photo = MediaAttachment(id: 'bg-photo', path: 'missing/bg.jpg', mimeType: 'image/jpeg', sizeBytes: 1, width: 800, height: 600);
      c.read(composerProvider.notifier).setTextCardBackground(const TextCardBackground(photo: photo).toJson());
      showCardBackgroundSheet(
        tester.element(find.byType(Scaffold).first),
        CardLook(
          platform: s.registry.descriptor('instagram')!,
          text: 'Words over a photo.',
          theme: TextCardTheme.dark,
          font: TextCardFont.original,
          branded: true,
          alignment: TextCardAlignment.left,
        ),
      );
      await settle(tester);
      TextCardBackground current() => TextCardBackground.tryParse(c.read(composerProvider).textCardBackground)!;

      await tester.tap(find.byKey(const Key('card-background-fit-contain')));
      await tester.tap(find.byKey(const Key('card-background-rotate')));
      await tester.tap(find.byKey(const Key('card-background-flip')));
      await settle(tester);
      expect((current().fit, current().quarterTurns, current().flipHorizontal), (TextCardBackgroundFit.contain, 1, true));

      await tester.tap(find.text('Adjust'));
      await settle(tester);
      expect(find.byKey(const Key('card-background-blur')), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-background-black-and-white')));
      await settle(tester);
      expect(current().blackAndWhite, isTrue);
      expect(find.byKey(const Key('card-background-saturation')), findsNothing, reason: 'no saturation in black and white');

      await tester.tap(find.text('Overlay'));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Tint hex'), '00FF88');
      await settle(tester);
      expect((current().tintColor, current().tintStrength), (0xFF00FF88, 0.4), reason: 'picking a colour turns the tint on');

      await tester.tap(find.text('Words'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('card-background-position-bottom')));
      await settle(tester);
      expect(current().textPosition, TextCardTextPosition.bottom);

      await tester.tap(find.byKey(const Key('card-background-reset')));
      await settle(tester);
      expect(current().toRenderParameters().length, 5, reason: 'back to what 1.2 recorded');
      await finish(tester);
    });

    testWidgets('the @handle and the alignment are per post, recorded on the card and read back for publishing', (tester) async {
      final (s, c) = await boot(tester);
      final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
      final now = DateTime(2026, 10, 25);
      var post = Post(id: 'p-h', text: 'No handle here.', targets: [PostTarget(accountId: ig.id)], createdAt: now, updatedAt: now);
      post = (await tester.runAsync(() =>
          attachTextCards(s, post, s.settings, handle: const {'instagram': false}, alignment: TextCardAlignment.distributed)))!;
      final card = cardOf(post, ig.id);
      expect(card.renderParameters!['handle'], isFalse);
      expect(card.renderParameters!.containsKey('byline'), isFalse);
      expect(textCardAlignmentOf(card), TextCardAlignment.distributed);
      String? platformOf(String id) => id == ig.id ? 'instagram' : null;
      expect(textCardHandleOfPost(post, platformOf), {'instagram': false});
      expect(textCardAlignmentOfPost(post), TextCardAlignment.distributed);

      final again = (await tester.runAsync(() => attachTextCards(s, post, s.settings)))!;
      expect(cardOf(again, ig.id).id, card.id, reason: 'reused: the choices come back from the card');
      await finish(tester);
    });

    testWidgets('a card over one of the post\'s photos replaces it on Instagram only; the choice survives publishing', (tester) async {
      final (s, c) = await boot(tester);
      final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
      final red = (await tester.runAsync(() => s.media.importBytes(_photo(600, 600, img.ColorRgb8(230, 20, 20)), fileName: 'red.jpg')))!;
      final now = DateTime(2026, 10, 25);
      var post = Post(
        id: 'p-bg',
        text: 'Words over my photo.',
        media: [red],
        targets: [PostTarget(accountId: ig.id), PostTarget(accountId: masto.id)],
        createdAt: now,
        updatedAt: now,
      );
      final background = TextCardBackground(photo: red, dimming: 0, textColor: TextCardTextColor.white).toJson();
      post = (await tester.runAsync(() => attachTextCards(s, post, s.settings, background: background)))!;
      final card = cardOf(post, ig.id);
      expect(card.renderParameters!['background']['mediaId'], red.id);
      expect(post.targetFor(masto.id)!.overrides.mediaIds, isNull, reason: 'Mastodon gets the photo itself');
      final bytes = (await tester.runAsync(() => s.media.read(card)))!;
      final px = img.decodeJpg(bytes)!.getPixel(40, 700);
      expect(px.r > 170 && px.g < 90, isTrue, reason: 'the red photo behind the words');
      expect(textCardBackgroundOfPost(post)!['photo']['id'], red.id);

      final again = (await tester.runAsync(() => attachTextCards(s, post, s.settings)))!;
      expect(cardOf(again, ig.id).id, card.id);

      final plain = (await tester.runAsync(() => attachTextCards(s, again, s.settings, background: const {})))!;
      expect(plain.targetFor(ig.id)!.overrides.mediaIds, isNull, reason: 'a plain card is not made for a post with a photo');
      expect(await exists(tester, s, card), isFalse);
      expect(await exists(tester, s, red), isTrue, reason: 'the user\'s photo is never deleted');
      await finish(tester);
    });

    testWidgets('fix: a card over the photo a network kept leaves that network\'s own photo list in place, for publishing and editing', (tester) async {
      final (s, c) = await boot(tester);
      final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
      final none = account('ig-none', 'instagram', '@none');
      await tester.runAsync(() => s.accounts.upsert(none));
      final red = (await tester.runAsync(() => s.media.importBytes(_photo(600, 600, img.ColorRgb8(230, 20, 20)), fileName: 'red.jpg')))!;
      final blue = (await tester.runAsync(() => s.media.importBytes(_photo(600, 600, img.ColorRgb8(20, 40, 230)), fileName: 'blue.jpg')))!;
      final now = DateTime(2026, 10, 25);
      var post = Post(
        id: 'p-subset',
        text: 'Words over the red photo.',
        media: [red, blue],
        targets: [
          // Instagram keeps only the red photo (Customize); the second
          // Instagram account is set to no photos.
          PostTarget(accountId: ig.id, overrides: PostOverrides(mediaIds: [red.id])),
          PostTarget(accountId: none.id, overrides: const PostOverrides(mediaIds: [])),
          PostTarget(accountId: masto.id),
        ],
        createdAt: now,
        updatedAt: now,
      );
      post = (await tester.runAsync(() => attachTextCards(s, post, s.settings, background: TextCardBackground(photo: red).toJson())))!;
      final card = cardOf(post, ig.id);
      final noneCard = cardOf(post, none.id);
      expect(card.renderParameters!['background']['mediaId'], red.id);

      // Publish now makes the cards again from the saved post.
      final again = (await tester.runAsync(() => attachTextCards(s, post, s.settings)))!;
      expect(cardOf(again, ig.id).id, card.id, reason: 'the card the preview showed is the one posted');
      expect(cardOf(again, none.id).id, noneCard.id);
      expect(await exists(tester, s, card), isTrue);
      final instagram = const VariantResolver().resolve(again, again.targetFor(ig.id)!, s.registry.descriptor('instagram')!, account: ig);
      expect(instagram.media.map((m) => m.id), [card.id], reason: 'not the blue photo the user left out');
      expect(again.targetFor(masto.id)!.overrides.mediaIds, isNull, reason: 'Mastodon gets both photos');

      // Edited again: each network lists what the user chose.
      final shown = withoutTextCards(again);
      expect(shown.targetFor(ig.id)!.overrides.mediaIds, [red.id]);
      expect(shown.targetFor(none.id)!.overrides.mediaIds, isEmpty);
      expect(shown.targetFor(ig.id)!.overrides.extra, isEmpty, reason: 'the record of the replaced list stays out of the composer');
      c.read(composerProvider.notifier).load(again);
      expect(c.read(composerProvider).overrides[ig.id]!.mediaIds, [red.id]);
      final preview = c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == ig.id);
      expect(isTextCardPlaceholder(preview.variant.media.single), isTrue, reason: 'the card is still shown for Instagram');

      // Text cards turned off: the network gets its own photo back, not every photo.
      await tester.runAsync(() => s.saveSettings(s.settings.copyWith(textCards: false)));
      final off = (await tester.runAsync(() => attachTextCards(s, again, s.settings)))!;
      expect(off.targetFor(ig.id)!.overrides.mediaIds, [red.id]);
      await finish(tester);
    });

    testWidgets('fix: a thread\'s card holds every part; an empty first part does not make a blank card', (tester) async {
      final (s, c) = await boot(tester);
      final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
      final now = DateTime(2026, 10, 25);
      var post = Post(
        id: 'p-thread-card',
        text: '',
        additionalParts: const ['We launched today'],
        targets: [PostTarget(accountId: ig.id)],
        createdAt: now,
        updatedAt: now,
      );
      post = (await tester.runAsync(() => attachTextCards(s, post, s.settings)))!;
      expect(cardOf(post, ig.id).altText, 'We launched today');
      expect(cardOf(post, ig.id).renderParameters!['textHash'], stableHash('We launched today'));
      await finish(tester);
    });

    testWidgets('a photo picked only for the cards is kept with the post, never posted, and deleted when replaced', (tester) async {
      final (s, c) = await boot(tester);
      final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
      final blue = (await tester.runAsync(() => s.media.importBytes(_photo(400, 700, img.ColorRgb8(20, 40, 230)), fileName: 'blue.jpg')))!;
      final now = DateTime(2026, 10, 25);
      var post = Post(id: 'p-own', text: 'Only words.', targets: [PostTarget(accountId: ig.id), PostTarget(accountId: masto.id)], createdAt: now, updatedAt: now);
      post = (await tester.runAsync(() => attachTextCards(s, post, s.settings, background: TextCardBackground(photo: blue).toJson())))!;
      final kept = post.media.singleWhere(isTextCardBackground);
      expect(kept.id, blue.id);
      expect(cardOf(post, ig.id).renderParameters!['background']['mediaId'], blue.id);
      final mastoVariant = const VariantResolver().resolve(post, post.targetFor(masto.id)!, s.registry.descriptor('mastodon')!, account: masto);
      expect(mastoVariant.media, isEmpty, reason: 'the background photo is not posted');
      expect(withoutTextCards(post).media, isEmpty, reason: 'the composer shows no attachments');
      expect(TextCardBackground.tryParse(textCardBackgroundOfPost(post))!.photo.id, blue.id);

      final cleared = (await tester.runAsync(() => attachTextCards(s, post, s.settings, background: const {})))!;
      expect(cleared.media.where(isTextCardBackground), isEmpty);
      expect(await exists(tester, s, blue), isFalse);
      expect(cardOf(cleared, ig.id).renderParameters!.containsKey('background'), isFalse);
      await finish(tester);
    });

    testWidgets('fix: scheduled and background publishing keep the caption written on the photo, in its style', (tester) async {
      final (s, c) = await boot(tester);
      final tiktok = c.read(accountListProvider).firstWhere((a) => a.platformId == 'tiktok');
      final photo = (await tester.runAsync(() => s.media.importBytes(_photo(600, 800, img.ColorRgb8(40, 160, 60)), fileName: 'green.jpg')))!;
      final now = DateTime(2026, 10, 25);
      var post = Post(
        id: 'p-sched',
        text: 'Launch day',
        media: [photo],
        targets: [PostTarget(accountId: tiktok.id)],
        status: PostStatus.scheduled,
        scheduledAt: now.add(const Duration(days: 1)),
        createdAt: now,
        updatedAt: now,
      );
      final style = const CaptionStyle(placement: CaptionPlacement.blockAbove).toJson();
      await tester.runAsync(() async {
        post = await attachFittedPhotos(s, post, s.settings);
        post = await attachCaptionedPhotos(s, post, s.settings, choices: const {'tiktok': true}, style: style);
        await s.posts.upsert(post);
      });
      final copy = post.media.singleWhere(isCaptionedCopy);
      expect((copy.width, copy.height), (1080, 1920), reason: 'the whole 9:16 frame');
      expect(copy.derivedFrom, photo.id);
      expect(CaptionStyle.fromJson(Map<String, dynamic>.from(copy.renderParameters!['style'] as Map)).placement, CaptionPlacement.blockAbove);
      expect(post.targetFor(tiktok.id)!.overrides.mediaIds!.first, copy.id);

      await tester.runAsync(() => fitPhotosOfSavedPost(s, post.id));
      final after = (await tester.runAsync(() => s.posts.get(post.id)))!;
      expect(after.targetFor(tiktok.id)!.overrides.mediaIds!.first, copy.id, reason: 'the captioned photo is still the one posted');
      expect(after.media.where(isCaptionedCopy).map((m) => m.id), [copy.id]);
      expect(captionStyleOfPost(after)!['placement'], 'blockAbove');
      await finish(tester);
    });

    testWidgets('a captioned photo made before 1.2.0 is still used by a scheduled post', (tester) async {
      final (s, c) = await boot(tester);
      final tiktok = c.read(accountListProvider).firstWhere((a) => a.platformId == 'tiktok');
      final photo = (await tester.runAsync(() => s.media.importBytes(_photo(600, 800, img.ColorRgb8(90, 60, 160)), fileName: 'old.jpg')))!;
      final now = DateTime(2026, 10, 25);
      var post = Post(id: 'p-old', text: 'Saved by 1.1', media: [photo], targets: [PostTarget(accountId: tiktok.id)], createdAt: now, updatedAt: now);
      late MediaAttachment legacy;
      await tester.runAsync(() async {
        post = await attachFittedPhotos(s, post, s.settings);
        final fitted = post.media.singleWhere((m) => m.derivedFrom != null);
        final made = await s.media.importBytes(_photo(1080, 1920, img.ColorRgb8(90, 60, 160)), fileName: 'old (captioned).jpg');
        legacy = MediaAttachment(
          id: made.id,
          path: made.path,
          mimeType: 'image/jpeg',
          sizeBytes: made.sizeBytes,
          width: 1080,
          height: 1920,
          generated: true,
          derivedFrom: photo.id,
          fitKey: 'caption|tiktok|${fitted.id}|${stableHash('Saved by 1.1')}',
        );
        post = post.copyWith(media: [...post.media, legacy]).withTarget(PostTarget(accountId: tiktok.id, overrides: PostOverrides(mediaIds: [legacy.id])));
        await s.posts.upsert(post);
        await fitPhotosOfSavedPost(s, post.id);
      });
      final after = (await tester.runAsync(() => s.posts.get(post.id)))!;
      expect(after.targetFor(tiktok.id)!.overrides.mediaIds, [legacy.id]);
      await finish(tester);
    });

    testWidgets('fix: a captioned photo made before 1.2.0 is kept when a different default caption style is saved later', (tester) async {
      final (s, c) = await boot(tester);
      final tiktok = c.read(accountListProvider).firstWhere((a) => a.platformId == 'tiktok');
      final photo = (await tester.runAsync(() => s.media.importBytes(_photo(600, 800, img.ColorRgb8(90, 60, 160)), fileName: 'old.jpg')))!;
      final now = DateTime(2026, 10, 25);
      var post = Post(id: 'p-old-style', text: 'Saved by 1.1', media: [photo], targets: [PostTarget(accountId: tiktok.id)], createdAt: now, updatedAt: now);
      late MediaAttachment legacy;
      await tester.runAsync(() async {
        post = await attachFittedPhotos(s, post, s.settings);
        final fitted = post.media.singleWhere((m) => m.derivedFrom != null);
        final made = await s.media.importBytes(_photo(1080, 1920, img.ColorRgb8(90, 60, 160)), fileName: 'old (captioned).jpg');
        legacy = MediaAttachment(
          id: made.id,
          path: made.path,
          mimeType: 'image/jpeg',
          sizeBytes: made.sizeBytes,
          width: 1080,
          height: 1920,
          generated: true,
          derivedFrom: photo.id,
          fitKey: 'caption|tiktok|${fitted.id}|${stableHash('Saved by 1.1')}',
        );
        post = post.copyWith(media: [...post.media, legacy]).withTarget(PostTarget(accountId: tiktok.id, overrides: PostOverrides(mediaIds: [legacy.id])));
        await s.posts.upsert(post);
        // After the update: a new default caption style in Settings.
        await s.saveSettings(s.settings.copyWith(
          captionStyle: const CaptionStyle(placement: CaptionPlacement.blockAbove, background: CaptionBackground.solid, backgroundColor: 0xFFFFFF00).toJson(),
        ));
      });
      expect(CaptionStyle.fromJson(captionStyleOfPost(post)), const CaptionStyle(), reason: 'the style the old copy was made in');
      expect(captionStyleOfPost(Post(id: 'p-none', text: 'x', createdAt: now, updatedAt: now)), isNull);

      await tester.runAsync(() => fitPhotosOfSavedPost(s, post.id));
      final after = (await tester.runAsync(() => s.posts.get(post.id)))!;
      expect(after.targetFor(tiktok.id)!.overrides.mediaIds, [legacy.id], reason: 'TikTok gets the picture that was scheduled');
      expect(after.media.where(isCaptionedCopy).map((m) => m.id), [legacy.id]);
      expect(await exists(tester, s, legacy), isTrue);
      await finish(tester);
    });

    testWidgets('a post saved with the caption off stays off when the Settings default is turned on', (tester) async {
      final (s, c) = await boot(tester);
      final tiktok = c.read(accountListProvider).firstWhere((a) => a.platformId == 'tiktok');
      final photo = (await tester.runAsync(() => s.media.importBytes(_photo(600, 800, img.ColorRgb8(200, 160, 60)), fileName: 'gold.jpg')))!;
      final now = DateTime(2026, 10, 25);
      var post = Post(id: 'p-off', text: 'No words on this one', media: [photo], targets: [PostTarget(accountId: tiktok.id)], createdAt: now, updatedAt: now);
      await tester.runAsync(() async {
        post = await attachFittedPhotos(s, post, s.settings);
        post = await attachCaptionedPhotos(s, post, s.settings, choices: const {'tiktok': false});
        await s.posts.upsert(post);
        await s.saveSettings(s.settings.copyWith(captionPhotoPlatforms: ['tiktok']));
      });
      expect(captionChoicesOfPost(post, (_) => 'tiktok'), {'tiktok': false});
      final textOnly = Post(id: 'p-text', text: 'x', targets: [PostTarget(accountId: tiktok.id)], createdAt: now, updatedAt: now);
      expect(captionChoicesOfPost(textOnly, (_) => 'tiktok'), isEmpty, reason: 'no photo yet: the default applies later');

      await tester.runAsync(() => fitPhotosOfSavedPost(s, post.id));
      final after = (await tester.runAsync(() => s.posts.get(post.id)))!;
      expect(after.media.where(isCaptionedCopy), isEmpty);
      await finish(tester);
    });

    testWidgets('composer: the caption editor opens from the pill and changes the style live', (tester) async {
      final (s, c) = await boot(tester);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final tiktok = c.read(accountListProvider).firstWhere((a) => a.platformId == 'tiktok');
      final photo = (await tester.runAsync(() => s.media.importBytes(_photo(600, 800, img.ColorRgb8(40, 160, 60)), fileName: 'green.jpg')))!;
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), 'Launch day is here');
      c.read(composerProvider.notifier)
        ..addMedia([photo])
        ..selectAccounts([tiktok.id]);
      await settle(tester);

      await tester.ensureVisible(find.text('Caption on photo').first);
      await tester.tap(find.text('Caption on photo').first);
      await settle(tester);
      expect(c.read(composerProvider).captionOnPhoto['tiktok'], isTrue, reason: 'the pill turns it on and opens the editor');
      expect(find.byType(CaptionEditorSheet), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('caption-placement-blockAbove')));
      await tester.tap(find.byKey(const Key('caption-placement-blockAbove')));
      await settle(tester);
      expect(CaptionStyle.fromJson(c.read(composerProvider).captionStyle).placement, CaptionPlacement.blockAbove);
      expect(find.byType(CaptionBlockFrame), findsWidgets);

      await tester.enterText(find.byKey(const Key('caption-words')), 'Out now');
      await tester.ensureVisible(find.byKey(const Key('caption-background-solid')));
      await tester.tap(find.byKey(const Key('caption-background-solid')));
      await settle(tester);
      final style = CaptionStyle.fromJson(c.read(composerProvider).captionStyle);
      expect((style.text, style.background), ('Out now', CaptionBackground.solid));
      final preview = c.read(composerPreviewsProvider).single;
      expect(preview.issues.where((i) => i.code == 'media.caption_photo').single.message, contains('block above'));

      await tester.tap(find.text('Done'));
      await settle(tester);
      final saved = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
      final copy = saved.media.singleWhere(isCaptionedCopy);
      expect((copy.width, copy.height), (1080, 1920));
      c.read(composerProvider.notifier).load(saved);
      expect(CaptionStyle.fromJson(c.read(composerProvider).captionStyle).text, 'Out now', reason: 'read back when the post is edited again');
      await finish(tester);
    });

    testWidgets('composer: @handle, alignment and a card over the photo, under the preview', (tester) async {
      final (s, c) = await boot(tester);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), 'Words on a card');
      c.read(composerProvider.notifier).selectAccounts([ig.id]);
      await settle(tester);

      await tester.ensureVisible(find.text('Show @handle').first);
      await tester.tap(find.text('Show @handle').first);
      await settle(tester);
      expect(c.read(composerProvider).textCardHandle['instagram'], isFalse);
      expect(c.read(settingsProvider).textCardShowsHandle('instagram'), isFalse, reason: 'remembered for Instagram');
      expect(textCardShowsHandleOf(c.read(composerPreviewsProvider).single.variant.media.single), isFalse);

      await tester.ensureVisible(find.text('Left').first);
      await tester.tap(find.text('Left').first);
      await settle(tester);
      await tester.tap(find.text('Distributed').last);
      await settle(tester);
      expect(c.read(composerProvider).textCardAlignment, TextCardAlignment.distributed);
      expect(textCardAlignmentOf(c.read(composerPreviewsProvider).single.variant.media.single), TextCardAlignment.distributed);

      // A photo: Instagram shows it, with the choice of a card over it.
      final photo = (await tester.runAsync(() => s.media.importBytes(_photo(500, 500, img.ColorRgb8(200, 30, 30)), fileName: 'red.jpg')))!;
      c.read(composerProvider.notifier).addMedia([photo]);
      await settle(tester);
      expect(isTextCardPlaceholder(c.read(composerPreviewsProvider).single.variant.media.single), isFalse);
      await tester.ensureVisible(find.text('Text card on this photo'));
      await tester.tap(find.text('Text card on this photo'));
      await settle(tester);
      expect(TextCardBackground.tryParse(c.read(composerProvider).textCardBackground)!.photo.id, photo.id);
      final placeholder = c.read(composerPreviewsProvider).single.variant.media.single;
      expect(isTextCardPlaceholder(placeholder), isTrue);
      expect(textCardParametersOf(placeholder)!['background']['mediaId'], photo.id);

      await tester.ensureVisible(find.text('Background: photo'));
      await tester.tap(find.text('Background: photo'));
      await settle(tester);
      expect(find.text('Card background'), findsOneWidget);
      await tester.tap(find.text('Colour'));
      await settle(tester);
      expect(c.read(composerProvider).textCardBackground, isNull);
      await tester.tap(find.text('Done'));
      await settle(tester);
      expect(isTextCardPlaceholder(c.read(composerPreviewsProvider).single.variant.media.single), isFalse, reason: 'the photo again');
      await finish(tester);
    });

    testWidgets('Settings > Text cards: @handle per network, the default alignment and the default caption style', (tester) async {
      final (_, c) = await boot(tester);
      c.read(routerProvider).go('/settings');
      await settle(tester);

      await tester.ensureVisible(find.byKey(const Key('text-card-handle-tiktok')));
      await tester.tap(find.byKey(const Key('text-card-handle-tiktok')));
      await settle(tester);
      expect(c.read(settingsProvider).textCardShowsHandle('tiktok'), isFalse);
      expect(c.read(settingsProvider).textCardShowsHandle('instagram'), isTrue);

      await tester.ensureVisible(find.byKey(const Key('text-card-alignment-justify')));
      await tester.tap(find.byKey(const Key('text-card-alignment-justify')));
      await settle(tester);
      expect(c.read(settingsProvider).textCardAlignment, TextCardAlignment.justify);

      await tester.ensureVisible(find.byKey(const Key('caption-style-edit')));
      await tester.tap(find.byKey(const Key('caption-style-edit')));
      await settle(tester);
      expect(find.text('Default caption style'), findsOneWidget);
      expect(find.byKey(const Key('caption-words')), findsNothing, reason: 'the words belong to a post');
      await tester.ensureVisible(find.byKey(const Key('caption-alignment-right')));
      await tester.tap(find.byKey(const Key('caption-alignment-right')));
      await settle(tester);
      expect(CaptionStyle.fromJson(c.read(settingsProvider).captionStyle).alignment, TextCardAlignment.right);
      await tester.tap(find.text('Done'));
      await settle(tester);
      await finish(tester);
    });
  });
}
