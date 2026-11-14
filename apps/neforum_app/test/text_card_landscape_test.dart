// 1.4.3: horizontal text cards. The card's shape (each network's own,
// square, landscape 16:9 or 1.91:1) and layout (the whole card, or a quote
// card with rounded corners), an attribution line under the words, and
// **bold** / *italic* written in the words. Followed through the chain:
// the style's JSON and Settings (synced) -> the frame each network gets
// (shown whole, or inside a full-screen frame, never cut) -> the painter's
// layout (wide wrapping, the size bounds, paragraph spacing, bold measured,
// the attribution at the bottom) -> the composer's editor, previews and
// saved cards -> the words networks without Markdown get. A golden of the
// landscape quote card, recorded on Windows like the card designer's.
//
// Golden: flutter test test/text_card_landscape_test.dart --update-goldens

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/state/text_cards.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'sync_fixtures.dart' show fakeAccount, populatedSettings;

/// Pixel-exact goldens break on font rasterizing differences between
/// operating systems; this allows a sliver of pixels to differ (as
/// card_design_test.dart does).
class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

  static const double tolerance = 0.015;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(imageBytes, await getGoldenBytes(golden));
    if (result.passed || result.diffPercent <= tolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

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

/// A neutral sample in the shape of a quote shared as a picture: two
/// paragraphs, a few phrases in bold, an attribution.
const _quote = 'The best tools stay out of the way. **You write once**, and the work of fitting every network happens quietly '
    'in the background, where it belongs.\n\n'
    'Good software respects your time. It should **never ask you to repeat yourself**, and it should always show you '
    'exactly what will be sent before it goes.';
const _quoteBy = '- Jordan Lee';

const _landscape = Size(1920, 1080);

TextCardPainter _painter(String text,
        {TextCardStyle style = const TextCardStyle(shape: TextCardShape.landscape),
        TextCardTheme theme = TextCardTheme.light,
        bool branded = false,
        String? byline,
        EdgeInsets safe = EdgeInsets.zero,
        TextCardAlignment alignment = TextCardAlignment.left}) =>
    TextCardPainter(text: text, theme: theme, byline: byline, branded: branded, safe: safe, alignment: alignment, style: style);

const _long = 'Every sentence here is ordinary on purpose, so that a long post fills the card and shows how the words wrap '
    'across a wide box. ';

void main() {
  setUpAll(() async {
    await _loadFonts();
    goldenFileComparator = _TolerantComparator(Uri.parse('${(goldenFileComparator as LocalFileComparator).basedir}text_card_landscape_test.dart'));
  });

  group('the style', () {
    test('shape, layout and attribution round-trip; untouched they write nothing', () {
      const style = TextCardStyle(shape: TextCardShape.wide, layout: TextCardLayout.panel, attribution: '- Jordan Lee');
      expect(style.toJson(), {'shape': 'wide', 'layout': 'panel', 'attribution': '- Jordan Lee'});
      expect(TextCardStyle.fromJson(style.toJson()), style);
      expect(TextCardStyle.classic.toJson(), isEmpty, reason: 'a card nobody restyled keeps the parameters it was made with');
      expect(TextCardStyle.fromJson({'shape': 'hexagon', 'layout': 'scroll'}), TextCardStyle.classic, reason: 'a newer value still draws a card');
      expect(style.copyWith(clearAttribution: true).attribution, isNull);
      expect(style.isClassic, isFalse);
    });

    test('an attribution is one trimmed line of at most 80 characters', () {
      expect(TextCardStyle.cleanAttribution('  - Jordan\n  Lee  '), '- Jordan Lee');
      expect(TextCardStyle.cleanAttribution('   '), isNull);
      expect(TextCardStyle.cleanAttribution('x' * 200)!.length, TextCardStyle.maxAttributionLength);
      expect(const TextCardStyle().copyWith(attribution: ' - A ').attribution, '- A');
    });

    test('the shapes', () {
      expect(TextCardShape.automatic.size, isNull);
      expect(TextCardShape.square.aspect, 1);
      expect(TextCardShape.landscape.aspect, closeTo(16 / 9, 1e-9));
      expect(TextCardShape.wide.aspect, closeTo(1.91, 1e-9));
    });
  });

  group('Settings', () {
    test('remembered, with each network\'s own and the whole card by default', () {
      const fresh = AppSettings();
      expect(fresh.textCardShape, TextCardShape.automatic);
      expect(fresh.textCardLayout, TextCardLayout.full);
      expect(fresh.newTextCardStyle, TextCardStyle.classic);
      final set = fresh.copyWith(textCardShape: TextCardShape.landscape, textCardLayout: TextCardLayout.panel);
      final back = AppSettings.fromJson(set.toJson());
      expect(back.textCardShape, TextCardShape.landscape);
      expect(back.textCardLayout, TextCardLayout.panel);
      expect(back.newTextCardStyle, const TextCardStyle(shape: TextCardShape.landscape, layout: TextCardLayout.panel));
      expect(AppSettings.fromJson({'textCardShape': 'oval'}).textCardShape, TextCardShape.automatic);
    });

    test('they travel with Sync and Move to another device', () {
      expect(kExportableSettings, containsAll(['textCardShape', 'textCardLayout']));
      final synced = syncedSettings(populatedSettings());
      expect(synced['textCardShape'], 'landscape');
      expect(synced['textCardLayout'], 'panel');
      expect(syncedSettings(const AppSettings())['textCardShape'], 'automatic', reason: 'a setting put back to its default travels too');
    });
  });

  group('the picture each network gets', () {
    test("each network's own shape is the card as before", () {
      for (final id in ['instagram', 'tiktok', 'pinterest', 'bluesky']) {
        expect(textCardFrameSize(id), textCardSize(id), reason: id);
        expect(textCardFrameSize(id, story: true, shape: TextCardShape.landscape), const Size(1080, 1920), reason: '$id story');
      }
    });

    test("a shape the network's rules take goes as it is: Instagram's feed takes up to 1.91:1", () {
      expect(textCardFrameSize('instagram', shape: TextCardShape.wide, minAspect: 0.8, maxAspect: 1.91), const Size(1910, 1000));
      expect(textCardFrameSize('instagram', shape: TextCardShape.landscape, minAspect: 0.8, maxAspect: 1.91), const Size(1920, 1080));
      expect(textCardFrameSize('instagram', shape: TextCardShape.square, minAspect: 0.8, maxAspect: 1.91), const Size(1080, 1080));
      expect(textCardFrameSize('bluesky', shape: TextCardShape.landscape), const Size(1920, 1080));
    });

    test('a shape the rules refuse gets room added, never a cut', () {
      expect(textCardFrameSize('x', shape: TextCardShape.landscape, maxAspect: 1.5), const Size(1920, 1280));
      expect(textCardFrameSize('x', shape: TextCardShape.square, minAspect: 1.2), const Size(1296, 1080));
    });

    test('full-screen networks keep their 9:16 frame; TikTok only while it fills the frame', () {
      expect(textCardFrameSize('tiktok', shape: TextCardShape.landscape), const Size(1080, 1920));
      expect(textCardFrameSize('tiktok', shape: TextCardShape.landscape, fillsFrame: false), const Size(1920, 1080),
          reason: 'TikTok shows a photo it is left alone whole on black');
      expect(textCardFrameSize('snapchat', shape: TextCardShape.wide, fillsFrame: false), const Size(1080, 1920));
    });

    test('with the real networks: Instagram feed takes 1.91:1, TikTok gets its fill-frame', () {
      final registry = builtinRegistry();
      Size frame(String id, TextCardShape shape, {AppSettings settings = const AppSettings(), bool story = false, PlatformTier tier = PlatformTier.byokApi}) {
        final adapter = registry.byId(id)!;
        return textCardFrameFor(adapter, fakeAccount('a', id, tier: tier), const PostVariant(text: 'x'), settings, story: story, shape: shape);
      }

      expect(frame('instagram', TextCardShape.wide), const Size(1910, 1000), reason: 'Instagram in Settings fills its frame by default: a card keeps its shape');
      expect(frame('instagram', TextCardShape.wide, tier: PlatformTier.handoff), const Size(1910, 1000));
      expect(frame('instagram', TextCardShape.wide, story: true), const Size(1080, 1920));
      expect(frame('tiktok', TextCardShape.landscape, tier: PlatformTier.handoff), const Size(1080, 1920));
      expect(frame('tiktok', TextCardShape.landscape, tier: PlatformTier.handoff, settings: const AppSettings(fillFramePlatforms: [])), const Size(1920, 1080));
      expect(frame('instagram', TextCardShape.automatic), textCardSize('instagram'));
      expect(textCardSafeArea('tiktok', size: const Size(1920, 1080)), EdgeInsets.zero, reason: 'no buttons over a landscape picture');
    });

    test('the preview says what a network gets when it is not the card itself', () {
      expect(textCardFrameNote('TikTok', TextCardShape.landscape, const Size(1080, 1920)), 'TikTok gets a 9:16 picture with your 16:9 card whole inside it');
      expect(textCardFrameNote('X', TextCardShape.wide, const Size(1910, 1000)), isNull);
      expect(textCardFrameNote('Instagram', TextCardShape.automatic, const Size(1080, 1350)), isNull);
    });

    test('inside a full-screen frame the card is whole, clear of the buttons', () {
      const frame = Size(1080, 1920);
      final safe = fullScreenSafeArea('tiktok');
      final p = _painter('Hello there.', safe: safe, branded: true, byline: '@robin');
      final card = p.cardRect(frame)!;
      expect(card.rect.width / card.rect.height, closeTo(16 / 9, 0.01));
      expect(card.rect.left, greaterThanOrEqualTo(safe.left));
      expect(card.rect.top, greaterThanOrEqualTo(safe.top));
      expect(card.rect.right, lessThanOrEqualTo(frame.width - safe.right));
      expect(card.rect.bottom, lessThanOrEqualTo(frame.height - safe.bottom));
      final layout = p.describe(frame);
      expect(card.rect.contains(layout.lines.topLeft) && card.rect.contains(layout.lines.bottomRight), isTrue, reason: 'the words are on the card');
    });

    test('the card is the whole picture when the frame is its shape, as cards always were', () {
      expect(_painter('Hi.').cardRect(_landscape), isNull);
      expect(_painter('Hi.', style: TextCardStyle.classic).cardRect(const Size(1080, 1350)), isNull);
      // Every card before 1.4.3 measures by its width, which is its shorter
      // side: the words come out as large as before.
      expect(_painter('Hi.', style: TextCardStyle.classic).describe(const Size(1080, 1350)).fontSize, TextCardPainter.maxWordsSize);
    });
  });

  group('a wide card', () {
    test('the words wrap to the wide box', () {
      final m = _painter(_long * 4).describe(_landscape);
      expect(m.lineMetrics.length, greaterThan(2));
      const margin = TextCardStyle.defaultMargin;
      expect(m.lines.left, greaterThanOrEqualTo(margin - 0.5));
      expect(m.lines.right, lessThanOrEqualTo(_landscape.width - margin + 0.5));
      expect(m.lines.width, greaterThan(_landscape.width * 0.7), reason: 'lines use the width the card has');
      expect(m.cut, isFalse);
    });

    test('the size fits the length of the words, within readable bounds', () {
      final short = _painter('Short words.').describe(_landscape);
      expect(short.fontSize, TextCardPainter.maxWordsSize, reason: 'measured on the shorter side: 1080');
      final medium = _painter(_long * 4).describe(_landscape);
      expect(medium.fontSize, inExclusiveRange(TextCardPainter.minWordsSize, TextCardPainter.maxWordsSize));
      final huge = _painter(_long * 40).describe(_landscape);
      expect(huge.fontSize, TextCardPainter.minWordsSize, reason: 'never smaller than the smallest readable size');
      expect(huge.cut, isTrue, reason: 'cut with an ellipsis instead');
      // 1.91:1 is 1000 high: everything scales with it.
      expect(_painter('Short words.', style: const TextCardStyle(shape: TextCardShape.wide)).describe(const Size(1910, 1000)).fontSize,
          closeTo(TextCardPainter.maxWordsSize * 1000 / 1080, 1e-9));
    });

    test('a blank line puts a paragraph between the words', () {
      final two = _painter('First paragraph.\n\nSecond paragraph.').describe(_landscape);
      final one = _painter('First paragraph.\nSecond paragraph.').describe(_landscape);
      expect(two.fontSize, one.fontSize);
      expect(two.lineMetrics.length, 3, reason: 'the blank line is laid out');
      final line = one.lineMetrics[1].baseline - one.lineMetrics[0].baseline;
      final paragraph = two.lineMetrics[2].baseline - two.lineMetrics[0].baseline;
      expect(paragraph, closeTo(2 * line, 0.5), reason: 'a full line of space between paragraphs');
      expect(line, closeTo(two.fontSize * TextCardStyle.defaultLineSpacing, 0.5));
    });

    test('**bold** is measured in bold and its asterisks are not drawn', () {
      const quote = TextCardStyle(shape: TextCardShape.landscape, layout: TextCardLayout.panel);
      final plain = _painter('Bold words here', style: quote).describe(_landscape);
      final bold = _painter('**Bold words** here', style: quote).describe(_landscape);
      final italic = _painter('*Bold words* here', style: quote).describe(_landscape);
      expect(bold.fontSize, plain.fontSize);
      expect(bold.lines.width, greaterThan(plain.lines.width + 1), reason: 'bold letters are wider');
      final stars = TextPainter(text: TextSpan(text: '****', style: TextStyle(fontFamily: 'Inter', fontSize: plain.fontSize)), textDirection: TextDirection.ltr)
        ..layout();
      expect(bold.lines.width - plain.lines.width, lessThan(stars.width), reason: 'no asterisks drawn');
      expect(italic.lines.width, closeTo(plain.lines.width, 1), reason: 'italic leaves the asterisks out too');
      stars.dispose();
    });

    test('the attribution sits under the words, lined up with them', () {
      const style = TextCardStyle(shape: TextCardShape.landscape, layout: TextCardLayout.panel, attribution: _quoteBy);
      final m = _painter(_quote, style: style).describe(_landscape);
      final card = m.card!;
      expect(m.attribution, isNotNull);
      expect(m.attribution!.top, greaterThan(m.words.bottom), reason: 'below the last paragraph, after a space');
      expect(m.attribution!.left, closeTo(m.words.left, 0.5), reason: 'left, like the words');
      expect(m.attribution!.bottom, lessThanOrEqualTo(card.bottom));
      expect(m.attribution!.height, closeTo(m.fontSize * 1.25, 1), reason: 'one line, at the size of the words');
      expect(m.attribution!.top - m.words.bottom, closeTo(m.fontSize * TextCardPainter.attributionGap, 0.5));
      // Centred words: a centred attribution.
      final centred = _painter(_quote, style: style, alignment: TextCardAlignment.center).describe(_landscape);
      expect(centred.attribution!.center.dx, closeTo(card.center.dx, 1));
      // However long the words, the attribution keeps its room.
      final long = _painter(_long * 40, style: style).describe(_landscape);
      expect(long.cut, isTrue);
      expect(long.attribution!.top, greaterThanOrEqualTo(long.words.bottom));
      expect(long.attribution!.bottom, lessThanOrEqualTo(long.card!.bottom));
    });

    test('a quote card: rounded, inside the picture, on a shade of its colour', () async {
      const style = TextCardStyle(shape: TextCardShape.landscape, layout: TextCardLayout.panel);
      final p = _painter('Hi.', style: style);
      final card = p.cardRect(_landscape)!;
      expect(card.radius, greaterThan(0));
      // Half the margins around it: the picture is the card's shape, so the
      // card fills it but for that room.
      expect(card.rect, const Rect.fromLTRB(46, 46, 1874, 1034));
      expect(_painter('Hi.', style: style.copyWith(shape: TextCardShape.automatic)).cardRect(const Size(1080, 1350))!.rect,
          const Rect.fromLTRB(46, 46, 1034, 1304), reason: "a quote card on each network's own shape too");
      expect(textCardSurroundColour(const Color(0xFFFFFFFF)).computeLuminance(), lessThan(1));
      expect(textCardSurroundColour(const Color(0xFF000000)).computeLuminance(), greaterThan(0));
    });
  });

  testWidgets('a saved quote card: the shade around, the card, the words in it', (tester) async {
    const style = TextCardStyle(shape: TextCardShape.landscape, layout: TextCardLayout.panel, attribution: _quoteBy);
    final jpeg = (await tester.runAsync(() => renderTextCardJpeg(text: _quote, theme: TextCardTheme.light, size: const Size(640, 360), style: style)))!;
    final image = img.decodeJpg(jpeg)!;
    expect((image.width, image.height), (640, 360));
    int grey(int x, int y) => image.getPixel(x, y).r.toInt();
    final shade = (textCardSurroundColour(const Color(0xFFFFFFFF)).r * 255).round();
    expect(grey(3, 3), closeTo(shade, 6), reason: 'the corner is the surround');
    expect(grey(20, 180), closeTo(255, 6), reason: 'the card is white');
    var ink = 0;
    for (var y = 40; y < 320; y += 2) {
      for (var x = 40; x < 600; x += 2) {
        if (grey(x, y) < 100) ink++;
      }
    }
    expect(ink, greaterThan(200), reason: 'the words are drawn');
  });

  group('alt text and the words networks get', () {
    test('the alt text has the words without the asterisks, and the attribution', () {
      expect(textCardAltText('Say **this** *gently*', attribution: '- Jordan Lee'), 'Say this gently\n- Jordan Lee');
      expect(textCardAltText('5 * 3 * 2'), '5 * 3 * 2');
    });

    test('the emphasis key is written, taken away, and never shown as a choice of the target', () {
      final now = DateTime.utc(2026, 11, 13);
      final post = Post(id: 'p', text: 'x', targets: const [PostTarget(accountId: 'a'), PostTarget(accountId: 'b')], createdAt: now, updatedAt: now);
      final marked = withCardEmphasis(post, marked: true);
      expect(marked.targets.every((t) => t.overrides.extra[kEmphasisMarkupKey] == true), isTrue);
      expect(identical(withCardEmphasis(marked, marked: true), marked), isTrue);
      expect(withCardEmphasis(marked, marked: false).targets.every((t) => !t.overrides.extra.containsKey(kEmphasisMarkupKey)), isTrue);
      expect(withoutTextCardChoices(marked.targets.first.overrides).extra, isEmpty);
    });
  });

  group('in the composer', () {
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

    Future<Map<String, ConnectedAccount>> compose(WidgetTester tester, ProviderContainer c, String words, List<String> platforms) async {
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final demo = c.read(accountListProvider);
      final byPlatform = {for (final p in platforms) p: demo.firstWhere((a) => a.platformId == p)};
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), words);
      c.read(composerProvider.notifier)
        ..selectAccounts([for (final a in byPlatform.values) a.id])
        ..setTextCardEveryNetwork(true);
      await settle(tester);
      return byPlatform;
    }

    TargetPreview preview(ProviderContainer c, ConnectedAccount a) => c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == a.id);

    testWidgets('a new post starts with the shape and layout in Settings, and an empty one follows a change', (tester) async {
      final (_, c) = await boot(tester);
      expect(c.read(composerProvider).textCardStyle, TextCardStyle.classic);
      c.read(settingsProvider.notifier).update((x) => x.copyWith(textCardShape: TextCardShape.wide, textCardLayout: TextCardLayout.panel));
      await settle(tester);
      expect(c.read(composerProvider).textCardStyle, const TextCardStyle(shape: TextCardShape.wide, layout: TextCardLayout.panel));
      c.read(composerProvider.notifier).reset();
      expect(c.read(composerProvider).textCardStyle.shape, TextCardShape.wide, reason: 'a fresh post starts from Settings');
      await finish(tester);
    });

    testWidgets('the editor sets the shape for every network; each preview shows what its network gets', (tester) async {
      final (_, c) = await boot(tester);
      final accounts = await compose(tester, c, 'One card, wide.', ['instagram', 'tiktok', 'bluesky']);
      // The shape is among the styling controls, folded on a new post.
      expect(find.text('Shape, size, colours, line spacing, place and margins'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('text-card-master-style-more')));
      await tester.tap(find.byKey(const Key('text-card-master-style-more')));
      await settle(tester);
      final chip = find.byKey(const Key('text-card-master-style-shape-wide'));
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await settle(tester);
      expect(c.read(composerProvider).textCardStyle.shape, TextCardShape.wide);
      expect(c.read(settingsProvider).textCardShape, TextCardShape.wide, reason: 'remembered for new posts');

      MediaAttachment card(String platform) => preview(c, accounts[platform]!).variant.media.single;
      expect((card('instagram').width, card('instagram').height), (1910, 1000), reason: "Instagram's feed takes 1.91:1 as it is");
      expect((card('bluesky').width, card('bluesky').height), (1910, 1000));
      expect((card('tiktok').width, card('tiktok').height), (1080, 1920), reason: "TikTok's full-screen frame, the card whole inside it");
      expect(textCardStyleOf(card('tiktok')).shape, TextCardShape.wide);
      expect(find.byKey(const ValueKey('text-card-frame-note-tiktok')), findsOneWidget);
      expect(find.text('TikTok gets a 9:16 picture with your 1.91:1 card whole inside it'), findsOneWidget);
      expect(find.byKey(const ValueKey('text-card-frame-note-instagram')), findsNothing);

      // The layout and the attribution, from the same editor.
      await tester.ensureVisible(find.byKey(const Key('text-card-master-style-layout-panel')));
      await tester.tap(find.byKey(const Key('text-card-master-style-layout-panel')));
      await settle(tester);
      await tester.ensureVisible(find.byKey(const Key('text-card-master-style-attribution')));
      await tester.enterText(find.byKey(const Key('text-card-master-style-attribution')), _quoteBy);
      await settle(tester);
      expect(c.read(composerProvider).textCardStyle, const TextCardStyle(shape: TextCardShape.wide, layout: TextCardLayout.panel, attribution: _quoteBy));
      expect(card('instagram').altText, 'One card, wide.\n$_quoteBy');
      expect(find.text('Landscape 1.91:1 · quote card · attribution'), findsOneWidget, reason: 'the fold says what is set');

      // Reset puts the words back and keeps the card's shape and layout.
      await tester.ensureVisible(find.byKey(const Key('text-card-master-style-reset')));
      await tester.tap(find.byKey(const Key('text-card-master-style-reset')));
      await settle(tester);
      expect(c.read(composerProvider).textCardStyle, const TextCardStyle(shape: TextCardShape.wide, layout: TextCardLayout.panel));
      await finish(tester);
    });

    testWidgets('saved: each network gets its picture, and bold leaves the words of networks without Markdown', (tester) async {
      final (_, c) = await boot(tester);
      final accounts = await compose(tester, c, 'Write **once**, post *everywhere*.', ['instagram', 'tiktok', 'reddit']);
      c.read(composerProvider.notifier).setTextCardStyle(const TextCardStyle(shape: TextCardShape.landscape, layout: TextCardLayout.panel));
      await settle(tester);
      // The previews already show it.
      expect(preview(c, accounts['instagram']!).variant.text, startsWith('Write once, post everywhere.'));
      expect(preview(c, accounts['reddit']!).variant.text, startsWith('Write **once**, post *everywhere*.'), reason: 'Reddit takes Markdown');

      final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
      final cards = {for (final m in post.media.where(isRenderedTextCard)) m.id: m};
      MediaAttachment saved(String platform) => cards[post.targetFor(accounts[platform]!.id)!.overrides.mediaIds!.single]!;
      expect((saved('instagram').width, saved('instagram').height), (1920, 1080));
      expect((saved('tiktok').width, saved('tiktok').height), (1080, 1920));
      expect(textCardStyleOf(saved('instagram')).layout, TextCardLayout.panel);
      expect(saved('instagram').altText, 'Write once, post everywhere.');
      expect(post.targets.every((t) => t.overrides.extra[kEmphasisMarkupKey] == true), isTrue);
      final registry = builtinRegistry();
      String sent(String platform) =>
          const VariantResolver().resolve(post, post.targetFor(accounts[platform]!.id)!, registry.descriptor(platform)!).text;
      expect(sent('instagram'), startsWith('Write once, post everywhere.'));
      expect(sent('reddit'), startsWith('Write **once**, post *everywhere*.'));

      // Opened again: the shape comes back with the post, and the emphasis
      // key is not a choice of the network's own.
      c.read(composerProvider.notifier).load(post);
      await settle(tester);
      expect(c.read(composerProvider).textCardStyle.shape, TextCardShape.landscape);
      expect(c.read(composerProvider).overrides.values.every((o) => !o.extra.containsKey(kEmphasisMarkupKey)), isTrue);
      await finish(tester);
    });
  });

  // Recorded on Windows, like card_design_test.dart's goldens: Linux draws
  // text a little differently (more than the tolerance), so they run on
  // Windows only, on a developer's PC and in the CI Windows job.
  group('goldens', skip: !Platform.isWindows, () {
    testWidgets('a landscape quote card: two paragraphs, bold phrases, an attribution', (tester) async {
      const size = Size(960, 540);
      final recorder = ui.PictureRecorder();
      _painter(
        _quote,
        style: const TextCardStyle(shape: TextCardShape.landscape, layout: TextCardLayout.panel, attribution: _quoteBy),
      ).paint(Canvas(recorder), size);
      final picture = recorder.endRecording();
      final image = (await tester.runAsync(() => picture.toImage(size.width.round(), size.height.round())))!;
      picture.dispose();
      await expectLater(image, matchesGoldenFile('card_goldens/text-card-landscape-quote.png'));
      image.dispose();
    });
  });
}
