// 1.3.5: the text card master editor as a quick designer. The @handle every
// card shows (stored on the post, in the cards' render parameters and their
// pictures, through drafts, saving, sync and publishing), the classic card
// drawn as a design, the quick edits (text size and colour, background
// colour, position, line spacing, margins, the @handle's size and place),
// the renderer's signature rules and keep-clear layout, each control of the
// panel from the tap to the saved card, the panel at phone and CI sizes and
// by keyboard, and the proof that a post never touched keeps 1.3.4's cards.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/aligned_text.dart' show TextCardAlignmentLabels;
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/card_quick_edits.dart';
import 'package:neforum_app/media/card_renderer.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/media/render_parameters.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/media/text_card_background.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/state/text_cards.dart';
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
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-SemiBold.ttf', 'assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
}

/// 0 (black) to 255 (white).
double _luma(img.Pixel p) => (p.r * 299 + p.g * 587 + p.b * 114) / 1000;

/// The mean difference in brightness of [a] and [b] over [r].
double _meanDiff(img.Image a, img.Image b, Rect r) {
  var sum = 0.0, n = 0;
  for (var y = r.top.round(); y < r.bottom.round(); y++) {
    for (var x = r.left.round(); x < r.right.round(); x++) {
      sum += (_luma(a.getPixel(x, y)) - _luma(b.getPixel(x, y))).abs();
      n++;
    }
  }
  return n == 0 ? 0 : sum / n;
}

/// The mean difference in brightness of [a] and [b] seen at a distance: each
/// averaged over blocks of [block] pixels first, so the same lines a pixel
/// apart, or a glyph a hair wider, count as the same.
double _blockDiff(img.Image a, img.Image b, {int block = 27}) {
  var sum = 0.0, n = 0;
  for (var by = 0; by + block <= a.height; by += block) {
    for (var bx = 0; bx + block <= a.width; bx += block) {
      var la = 0.0, lb = 0.0;
      for (var y = by; y < by + block; y++) {
        for (var x = bx; x < bx + block; x++) {
          la += _luma(a.getPixel(x, y));
          lb += _luma(b.getPixel(x, y));
        }
      }
      sum += (la - lb).abs() / (block * block);
      n++;
    }
  }
  return sum / n;
}

/// How many pixels of [m] in [r] are within [tolerance] of [argb] in every channel.
int _countNear(img.Image m, int argb, {Rect? r, int tolerance = 40}) {
  final area = r ?? Rect.fromLTWH(0, 0, m.width.toDouble(), m.height.toDouble());
  final cr = argb >> 16 & 0xFF, cg = argb >> 8 & 0xFF, cb = argb & 0xFF;
  var n = 0;
  for (var y = area.top.round(); y < area.bottom.round(); y++) {
    for (var x = area.left.round(); x < area.right.round(); x++) {
      final p = m.getPixel(x, y);
      if ((p.r - cr).abs() <= tolerance && (p.g - cg).abs() <= tolerance && (p.b - cb).abs() <= tolerance) n++;
    }
  }
  return n;
}

/// Top and bottom rows of [m] (between [from] and [to]) with a pixel brighter than [threshold].
(int, int)? _inkRows(img.Image m, {int from = 0, int? to, double threshold = 160}) {
  int? top, bottom;
  for (var y = from; y < (to ?? m.height); y++) {
    for (var x = 0; x < m.width; x += 2) {
      if (_luma(m.getPixel(x, y)) > threshold) {
        top ??= y;
        bottom = y;
        break;
      }
    }
  }
  return top == null ? null : (top, bottom!);
}

Map<CardBlockRole, String> _words(String text, {String handle = '@robin.makes', bool signed = true}) => {
      CardBlockRole.postText: text,
      CardBlockRole.handle: handle,
      if (!signed) CardBlockRole.signature: '',
    };

const _sentence = 'One app, one message, every platform. Write once and it goes out the same everywhere.';

void main() {
  setUpAll(_loadFonts);

  // -------------------------------------------------------------------------
  group('the classic card as a design', () {
    test('carries the classic card\'s measures, colours, font and footer', () {
      final d = classicTextCardDesign(theme: TextCardTheme.light, font: TextCardFont.timesNewRoman, alignment: TextCardAlignment.center);
      expect(d.template, kClassicTemplateId);
      expect(cardTemplateLabel(d), 'Classic, restyled');
      expect((d.margin, d.signatureRules, d.keepClear), (kClassicMargin, true, true));
      expect(d.background.kind, CardFillKind.solid);
      expect(d.background.color, 0xFFFFFFFF);
      final w = d.wordsBlock!;
      expect((w.size, w.autoFit, w.lineHeight, w.color), (kClassicWordsSize, true, kClassicLineHeight, 0xFF000000));
      expect((w.font, w.weight, w.letterSpacing, w.alignment, w.anchor), (TextCardFont.timesNewRoman, 400, 0.0, TextCardAlignment.center, CardAnchor.center));
      expect(d.signatureBlock!.anchor, CardAnchor.bottomLeft);
      expect((d.handleBlock!.anchor, d.handleBlock!.alignment, d.handleBlock!.size), (CardAnchor.bottomRight, TextCardAlignment.right, kClassicHandleSize));
      expect(d.handleBlock!.color, (kClassicHandleAlpha << 24) | 0x000000, reason: 'the words\' colour at 62%');
      // A plain card has its @handle at the left.
      expect(classicTextCardDesign(plain: true).handleAnchor, CardAnchor.bottomLeft);
    });

    test('over the post\'s photo: a photo fill, its text colour and position', () {
      const photo = MediaAttachment(id: 'bg', path: '/data/bg.jpg', mimeType: 'image/jpeg', sizeBytes: 3);
      final d = classicTextCardDesign(
          background: const TextCardBackground(photo: photo, textColor: TextCardTextColor.black, textPosition: TextCardTextPosition.bottom, textBox: true));
      expect(d.background.kind, CardFillKind.image);
      expect(d.wordsColor, 0xFF000000);
      expect(d.wordsPosition, TextCardTextPosition.bottom);
      expect(d.wordsBlock!.shadowBlur, greaterThan(0), reason: 'the box behind busy photos, as a soft shadow');
    });

    test('the new switches round-trip, and designs without them keep their JSON', () {
      final d = classicTextCardDesign();
      final back = CardDesign.tryParse(d.toJson())!;
      expect((back.signatureRules, back.keepClear, back.template), (true, true, kClassicTemplateId));
      for (final t in kCardTemplates) {
        final json = t.design(CardKind.text).toJson();
        expect(json.containsKey('signatureRules') || json.containsKey('keepClear'), isFalse, reason: t.id);
      }
      expect(CardDesign.tryParse({'kind': 'text', 'signatureRules': 'yes', 'keepClear': 1})!.signatureRules, isFalse, reason: 'lenient reading');
    });

    testWidgets('draws as the classic card does: rule, words, divider, mark and @handle in the same places', (tester) async {
      for (final (size, signed) in [(const Size(540, 540), true), (const Size(540, 540), false), (const Size(540, 675), true)]) {
        final classic = img.decodeJpg((await tester.runAsync(() => renderTextCardJpeg(
            text: _sentence, theme: TextCardTheme.dark, size: size, byline: '@robin.makes', branded: signed)))!)!;
        final designed = img.decodeJpg((await tester.runAsync(() => renderCardDesign(CardRenderInput(
            design: classicTextCardDesign(plain: !signed), size: size, platformId: 'bluesky', texts: _words(_sentence, signed: signed)))))!)!;
        expect(_blockDiff(classic, designed), lessThan(5), reason: '$size signed=$signed: the same card to the eye');
        if (signed && size.height == size.width) {
          // The measure tells cards apart: a template is far from the classic card.
          final minimal = img.decodeJpg((await tester.runAsync(() => renderCardDesign(CardRenderInput(
              design: cardTemplateById('minimal')!.design(CardKind.text).withTheme(TextCardTheme.dark), size: size, platformId: 'bluesky', texts: _words(_sentence)))))!)!;
          expect(_blockDiff(classic, minimal), greaterThan(10), reason: 'a different layout, in the same colours');
        }
        // The rule across the top: purple, with a yellow tab, only when signed.
        final rule = Rect.fromLTWH(0, 0, size.width, 6);
        final purple = _countNear(designed, 0xFF7D00FF, r: rule), yellow = _countNear(designed, 0xFFFFFF00, r: rule);
        expect(purple > 0 && yellow > 0, signed, reason: '$size signed=$signed');
        expect(_countNear(classic, 0xFF7D00FF, r: rule) > 0, signed);
        // The words start on the same line, within a few pixels.
        final c = _inkRows(classic, from: 20)!, d = _inkRows(designed, from: 20)!;
        expect((c.$1 - d.$1).abs(), lessThanOrEqualTo(4), reason: '$size signed=$signed: the words\' first line');
      }
    });
  });

  // -------------------------------------------------------------------------
  group('quick edits', () {
    final classic = classicTextCardDesign();

    test('text size, line spacing and margins, within their ranges', () {
      expect(classic.withWordsSize(160).wordsSize, 160);
      expect(classic.withWordsSize(999).wordsSize, 320, reason: 'the designer\'s own limit');
      expect(classic.withWordsLineHeight(1.734).wordsLineHeight, 1.73);
      expect(classic.withQuickMargin(40).margin, 40);
      expect(classic.withWordsSize(160).blocks.length, classic.blocks.length, reason: 'the same blocks, one changed');
    });

    test('the text colour takes the @handle and signature along, not a template\'s second colour', () {
      final yellow = classic.withWordsColor(0xFFFFE14D);
      expect(yellow.wordsColor, 0xFFFFE14D);
      expect(yellow.signatureBlock!.color, 0xFFFFE14D);
      expect(yellow.handleBlock!.color, (kClassicHandleAlpha << 24) | 0xFFE14D, reason: 'keeping its 62%');
      final neon = cardTemplateById('neon')!.design(CardKind.text);
      final white = neon.withWordsColor(0xFFFFFFFF);
      expect(white.wordsColor, 0xFFFFFFFF);
      expect(white.signatureBlock!.color, neon.signatureBlock!.color, reason: 'Neon\'s cyan signature stays');
    });

    test('the background colour replaces a gradient or photo; a theme sets both colours', () {
      final wave = cardTemplateById('gradientWave')!.design(CardKind.text).withBackgroundColor(0xFF123456);
      expect((wave.background.kind, wave.backgroundColor), (CardFillKind.solid, 0xFF123456));
      final light = classic.withTheme(TextCardTheme.light);
      expect(light.hasTheme(TextCardTheme.light), isTrue);
      expect(light.hasTheme(TextCardTheme.dark), isFalse);
      expect(light.wordsColor, 0xFF000000);
    });

    test('the words\' place: top, middle or bottom, clear of the footer', () {
      for (final p in TextCardTextPosition.values) {
        final d = classic.withWordsPosition(p);
        expect(d.wordsPosition, p);
        expect(d.keepClear, isTrue);
      }
      final minimal = cardTemplateById('minimal')!.design(CardKind.text).withWordsPosition(TextCardTextPosition.top);
      expect(minimal.wordsBlock!.anchor, CardAnchor.topLeft, reason: 'the column it had');
      expect(minimal.keepClear, isTrue, reason: 'a template too keeps its words off the @handle once moved');
    });

    test('the @handle\'s size and place; it trades places with the signature rather than stack', () {
      expect(classic.withHandleSize(40).handleSize, 40);
      final top = classic.withHandleAnchor(CardAnchor.topCenter);
      expect((top.handleAnchor, top.handleBlock!.alignment), (CardAnchor.topCenter, TextCardAlignment.center));
      final swapped = classic.withHandleAnchor(CardAnchor.bottomLeft);
      expect(swapped.handleAnchor, CardAnchor.bottomLeft);
      expect(swapped.signatureBlock!.anchor, CardAnchor.bottomRight);
      // A template without a handle block (Vinyl) gets one.
      final vinyl = cardTemplateById('vinyl')!.design(CardKind.text);
      expect(vinyl.handleBlock, isNull);
      expect(vinyl.withHandleSize(30).handleBlock!.size, 30);
      expect(vinyl.withHandleAnchor(CardAnchor.topRight).handleAnchor, CardAnchor.topRight);
    });

    test('the font and alignment edit the words', () {
      final d = classic.withWordsFont(TextCardFont.tiktokSans).withWordsAlignment(TextCardAlignment.right);
      expect((d.wordsBlock!.font, d.wordsBlock!.weight, d.wordsBlock!.alignment), (TextCardFont.tiktokSans, 700, TextCardAlignment.right));
    });
  });

  // -------------------------------------------------------------------------
  group('the renderer', () {
    testWidgets('keeping clear: words at the bottom stop above the footer; without it they run over it', (tester) async {
      const size = Size(540, 540);
      final u = cardUnit(size);
      final low = classicTextCardDesign().withWordsPosition(TextCardTextPosition.bottom).withWordsSize(200);
      Future<img.Image> draw(CardDesign d) async =>
          img.decodeJpg((await tester.runAsync(() => renderCardDesign(CardRenderInput(design: d, size: size, platformId: 'bluesky', texts: _words('Big words at the bottom')))))!)!;
      final frame = cardFrameOfDesign(low, size, EdgeInsets.zero, signed: true);
      // Between the words and the mark: the 100-pixel gap (the divider is
      // faint), from just above the signature's row.
      final mark = kClassicSignatureSize * 1.7 * u;
      final gap = Rect.fromLTRB(frame.left, frame.bottom - mark - (kKeepClearGap + kSignatureDividerRoom - 6) * u, frame.right, frame.bottom - mark - 4 * u);
      int bright(img.Image m) => _countNear(m, 0xFFFFFFFF, r: gap, tolerance: 60);
      expect(bright(await draw(low)), 0, reason: 'nothing but the faint divider between the words and the footer');
      expect(bright(await draw(low.copyWith(keepClear: false))), greaterThan(50), reason: 'without keepClear the words reach the frame\'s bottom');
    });

    testWidgets('the signature rules only on a signed card, and the frame starts below the rule', (tester) async {
      const size = Size(540, 540);
      final d = classicTextCardDesign();
      expect(cardFrameOfDesign(d, size, EdgeInsets.zero, signed: true).top, closeTo((kClassicMargin + kSignatureRuleHeight) * cardUnit(size), 0.01));
      expect(cardFrameOfDesign(d, size, EdgeInsets.zero, signed: false).top, closeTo(kClassicMargin * cardUnit(size), 0.01));
      final noRules = d.copyWith(signatureRules: false);
      expect(cardFrameOfDesign(noRules, size, EdgeInsets.zero, signed: true), cardFrameOf(size, EdgeInsets.zero, kClassicMargin));
      final plain = img.decodeJpg((await tester.runAsync(() => renderCardDesign(CardRenderInput(design: d, size: size, texts: _words('Plain', signed: false)))))!)!;
      expect(_countNear(plain, 0xFF7D00FF, r: const Rect.fromLTWH(0, 0, 540, 6)), 0);
    });
  });

  // -------------------------------------------------------------------------
  group('with a workspace', () {
    Future<(AppServices, ProviderContainer)> boot(WidgetTester tester, {Size size = const Size(1440, 3200)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
      await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
      await tester.pump(const Duration(milliseconds: 300));
      return (services, ProviderScope.containerOf(tester.element(find.byType(MaterialApp))));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    const platforms = ['instagram', 'bluesky', 'mastodon'];

    /// The 1.3.4 render parameters and (on Windows, where the fonts draw
    /// the same as when they were recorded) the JPEG of the default card for
    /// the words below, recorded from NEFORUM 1.3.4 before this change.
    const recordedWords = 'The same card as in 1.3.4, byte for byte.';
    const recorded = {
      'instagram': ('@robin.makes', '38bab6e2'),
      'bluesky': ('@robin.bsky.social', '8670051d'),
      'mastodon': ('@robin@fosstodon.org', '6cba7752'),
    };

    Map<String, String> idsOf(ProviderContainer c) {
      final demo = c.read(accountListProvider);
      return {for (final p in platforms) p: demo.firstWhere((a) => a.platformId == p).id};
    }

    Post post(Map<String, String> ids, String text, {String? byline, Map<String, bool> withText = const {}}) {
      final now = DateTime(2026, 11, 1);
      final p = Post(id: 'p-quick', text: text, targets: [for (final id in ids.values) PostTarget(accountId: id)], createdAt: now, updatedAt: now);
      return withTextCardChoices(p, everyNetwork: true, withText: withText, platformOf: (id) => ids.entries.firstWhere((e) => e.value == id).key, byline: byline);
    }

    const cardOf = _savedCardOf;

    testWidgets('a post never touched keeps 1.3.4\'s cards: the same render parameters, the same bytes', (tester) async {
      final (s, c) = await boot(tester);
      final ids = idsOf(c);
      final made = (await tester.runAsync(() => attachTextCards(s, post(ids, recordedWords), s.settings)))!;
      for (final MapEntry(key: platform, value: (byline, hash)) in recorded.entries) {
        final card = cardOf(made, ids[platform]!);
        expect(
          renderParametersEqual(card.renderParameters, {
            'kind': 'textCard',
            'platform': platform,
            'theme': 'dark',
            'font': 'original',
            'branded': true,
            'alignment': 'left',
            'handle': true,
            'byline': byline,
            'safe': false,
            'textHash': 'c2fdea04',
          }),
          isTrue,
          reason: '$platform: ${card.renderParameters}',
        );
        if (Platform.isWindows) {
          final bytes = (await tester.runAsync(() => s.media.read(card)))!;
          expect(stableHash(String.fromCharCodes(bytes)), hash, reason: '$platform: the 1.3.4 JPEG, byte for byte');
        }
      }
      // The composer's stand-in, as 1.3.4 made it.
      expect(textCardPlaceholder('instagram', TextCardTheme.dark).renderParameters,
          {'kind': 'textCard', 'platform': 'instagram', 'theme': 'dark', 'font': 'original', 'branded': true, 'alignment': 'left', 'handle': true, 'safe': false});
      await finish(tester);
    });

    testWidgets('the post\'s @handle goes on every network\'s saved card, picture included, and is read back for publishing', (tester) async {
      final (s, c) = await boot(tester);
      final ids = idsOf(c);
      const words = 'A handle of my choosing on every card.';
      final own = (await tester.runAsync(() => attachTextCards(s, post(ids, words), s.settings)))!;
      var mine = post(ids, words, byline: '  @robin everywhere ');
      expect(textCardBylineOfPost(mine), '@robin everywhere', reason: 'trimmed, on the post');
      // Saved, synced (as JSON) and read back: still there.
      mine = Post.fromJson(mine.toJson());
      expect(textCardBylineOfPost(mine), '@robin everywhere');
      mine = (await tester.runAsync(() => attachTextCards(s, mine, s.settings)))!;
      for (final platform in platforms) {
        final a = cardOf(own, ids[platform]!), b = cardOf(mine, ids[platform]!);
        expect(b.renderParameters!['byline'], '@robin everywhere', reason: platform);
        expect(a.id, isNot(b.id), reason: '$platform: a new handle is a new card');
        // The picture: the footer changed, the words above it did not.
        final pa = img.decodeJpg((await tester.runAsync(() => s.media.read(a)))!)!;
        final pb = img.decodeJpg((await tester.runAsync(() => s.media.read(b)))!)!;
        final h = pa.height.toDouble(), w = pa.width.toDouble();
        expect(_meanDiff(pa, pb, Rect.fromLTRB(w / 2, h - 84 - 64, w - 80, h - 80)), greaterThan(3), reason: '$platform: the @handle in the picture');
        expect(_meanDiff(pa, pb, Rect.fromLTRB(0, 0, w, h * 0.6)), lessThan(0.5), reason: '$platform: the words untouched');
      }
      // Publishing makes the cards again from the saved post: the same cards.
      final again = (await tester.runAsync(() => attachTextCards(s, mine, s.settings)))!;
      for (final platform in platforms) {
        expect(cardOf(again, ids[platform]!).id, cardOf(mine, ids[platform]!).id, reason: '$platform: kept, not drawn again');
      }
      // A network with "Show @handle" off stays without.
      final hidden = (await tester.runAsync(() => attachTextCards(s, mine, s.settings, handle: const {'mastodon': false})))!;
      expect(cardOf(hidden, ids['mastodon']!).renderParameters!.containsKey('byline'), isFalse);
      expect(cardOf(hidden, ids['bluesky']!).renderParameters!['byline'], '@robin everywhere');
      // Back to each network's own handle.
      final reset = (await tester.runAsync(() => attachTextCards(s, post(ids, words), s.settings)))!;
      for (final MapEntry(key: platform, value: (byline, _)) in recorded.entries) {
        expect(cardOf(reset, ids[platform]!).renderParameters!['byline'], byline, reason: platform);
      }
      await finish(tester);
    });

    testWidgets('size and colour change the saved JPEG', (tester) async {
      final (s, c) = await boot(tester);
      final ids = idsOf(c);
      const words = 'Big words.';
      Future<img.Image> saved(CardDesign? design, String platform) async {
        final p = (await tester.runAsync(() => attachTextCards(s, post(ids, words), s.settings, design: design?.toJson() ?? const {})))!;
        return img.decodeJpg((await tester.runAsync(() => s.media.read(cardOf(p, ids[platform]!))))!)!;
      }

      final classic = classicTextCardDesign();
      for (final platform in ['instagram', 'bluesky']) {
        final normal = await saved(classic, platform);
        final big = await saved(classic.withWordsSize(220), platform);
        final h = normal.height;
        // The words' ink, above the footer: taller at the larger size.
        final a = _inkRows(normal, from: 40, to: h - 200)!, b = _inkRows(big, from: 40, to: h - 200)!;
        expect(b.$2 - b.$1, greaterThan((a.$2 - a.$1) * 1.6), reason: '$platform: 220 against 104');
        // Red words on a blue card.
        final coloured = await saved(classic.withWordsColor(0xFFFF0000).withBackgroundColor(0xFF0033CC), platform);
        expect(_countNear(coloured, 0xFFFF0000), greaterThan(2000), reason: '$platform: red words');
        expect(_countNear(normal, 0xFFFF0000), 0);
        final corner = coloured.getPixel(4, h ~/ 2);
        expect([corner.r, corner.g, corner.b].map((v) => v.toInt()), [closeTo(0x00, 12), closeTo(0x33, 12), closeTo(0xCC, 12)], reason: '$platform: the blue card');
      }
      await finish(tester);
    });

    test('the composer keeps the @handle and a quick design across restarts', () {
      final design = classicTextCardDesign().withWordsSize(150).withHandleAnchor(CardAnchor.topLeft);
      final c = ComposerState(text: 'x', textCardByline: '@robin', textCardDesign: design.toJson());
      final back = composerDraftFromJson(composerDraftToJson(c))!;
      expect(back.textCardByline, '@robin');
      final d = CardDesign.tryParse(back.textCardDesign)!;
      expect((d.wordsSize, d.handleAnchor, d.template), (150.0, CardAnchor.topLeft, kClassicTemplateId));
      expect(composerDraftFromJson(composerDraftToJson(const ComposerState(text: 'x')))!.textCardByline, isNull);
    });

    // -----------------------------------------------------------------------
    // The panel.

    /// The composer with a text-only post going to [platforms], the same card
    /// on every network; returns each network's card stand-in.
    Future<MediaAttachment Function(String)> compose(WidgetTester tester, ProviderContainer c) async {
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final ids = idsOf(c);
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), 'One card for every network.');
      c.read(composerProvider.notifier)
        ..selectAccounts(ids.values)
        ..setTextCardEveryNetwork(true);
      await settle(tester);
      return (platform) => c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == ids[platform]).variant.media.single;
    }

    Future<void> tap(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pump();
      await tester.tap(f);
      await settle(tester);
    }

    Future<void> drag(WidgetTester tester, Key key, double dx) async {
      final slider = find.descendant(of: find.byKey(key), matching: find.byType(Slider));
      await tester.ensureVisible(slider);
      await tester.pump();
      await tester.drag(slider, Offset(dx, 0));
      await settle(tester);
    }

    /// Unfolds the size, colour and place controls.
    Future<void> openMore(WidgetTester tester) async {
      if (find.byKey(const Key('text-card-master-size')).evaluate().isNotEmpty) return;
      await tap(tester, find.byKey(const Key('text-card-master-more')));
      expect(find.byKey(const Key('text-card-master-size')), findsOneWidget);
    }

    /// Picks [hex] in the colour dialog the button [key] opens, typed in its hex field.
    Future<void> pickColour(WidgetTester tester, Key key, String hex) async {
      await tap(tester, find.byKey(key));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(find.byKey(const Key('card-colour-hex')), hex);
      await tester.pump();
      await tester.tap(find.byKey(const Key('card-colour-use')));
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
    }

    testWidgets('every quick control: from the panel to the composer, every network\'s stand-in and every saved card', (tester) async {
      final (s, c) = await boot(tester);
      final cardOf = await compose(tester, c);
      expect(find.byKey(const Key('text-card-master-quick')), findsOneWidget);
      CardDesign? designOf(String p) => textCardDesignOf(cardOf(p));
      CardDesign composerDesign() => CardDesign.tryParse(c.read(composerProvider).textCardDesign)!;
      expect(c.read(composerProvider).textCardDesign, isNull, reason: 'nothing touched yet');
      for (final p in platforms) {
        expect(designOf(p), isNull, reason: '$p: the classic card until a control is touched');
      }

      // The @handle: the field shows each network's own until typed.
      final field = find.byKey(const Key('text-card-master-byline'));
      final hint = tester.widget<TextField>(field).decoration!.hintText!;
      expect(hint, allOf(contains('@robin.makes'), contains('@robin.bsky.social'), contains('@robin@fosstodon.org')));
      await tester.enterText(field, '@robin everywhere');
      await settle(tester);
      expect(c.read(composerProvider).textCardByline, '@robin everywhere');
      for (final p in platforms) {
        expect(textCardBylineOf(cardOf(p)), '@robin everywhere', reason: p);
        expect(designOf(p), isNull, reason: '$p: the @handle alone leaves the look as it is');
      }

      // The size, colour and place controls are folded until asked for, so
      // the networks' previews stay in view.
      expect(find.byKey(const Key('text-card-master-size')), findsNothing);
      await openMore(tester);

      // Text size: the slider, then the stepped buttons.
      await drag(tester, const Key('text-card-master-size'), 60);
      final dragged = composerDesign().wordsSize;
      expect(dragged, greaterThan(kClassicWordsSize));
      await tap(tester, find.byKey(const Key('text-card-master-size-up')));
      expect(composerDesign().wordsSize, dragged + 8);
      await tap(tester, find.byKey(const Key('text-card-master-size-down')));
      await tap(tester, find.byKey(const Key('text-card-master-size-down')));
      expect(composerDesign().wordsSize, dragged - 8);
      for (final p in platforms) {
        expect(designOf(p)!.wordsSize, dragged - 8, reason: p);
        expect(designOf(p)!.template, kClassicTemplateId, reason: '$p: started from the classic card');
      }

      // Line spacing and margins.
      await drag(tester, const Key('text-card-master-line-height'), 80);
      expect(composerDesign().wordsLineHeight, greaterThan(kClassicLineHeight));
      await drag(tester, const Key('text-card-master-margin'), -80);
      expect(composerDesign().margin, lessThan(kClassicMargin));

      // The words' place.
      await tap(tester, find.descendant(of: find.byKey(const Key('text-card-master-position')), matching: find.text('Bottom')));
      expect(composerDesign().wordsPosition, TextCardTextPosition.bottom);

      // Colours, on the colour dialog (wheel, swatches and hex).
      await pickColour(tester, const Key('text-card-master-text-colour'), '#FFE14D');
      expect(composerDesign().wordsColor, 0xFFFFE14D);
      await pickColour(tester, const Key('text-card-master-background-colour'), '1B0B3A');
      expect(composerDesign().backgroundColor, 0xFF1B0B3A);

      // The @handle's size and place.
      await drag(tester, const Key('text-card-master-handle-size'), 60);
      expect(composerDesign().handleSize, greaterThan(kClassicHandleSize));
      await tap(tester, find.byKey(Key('text-card-master-handle-at-${CardAnchor.topLeft.name}')));
      expect(composerDesign().handleAnchor, CardAnchor.topLeft);

      // Font and alignment edit the design's words in the master editor.
      await tap(tester, find.byKey(const Key('text-card-master-font-timesNewRoman')));
      expect(composerDesign().wordsBlock!.font, TextCardFont.timesNewRoman);
      await tap(tester, find.byKey(const Key('text-card-master-alignment')));
      await tester.tap(find.text(TextCardAlignment.right.label).last);
      await settle(tester);
      expect(composerDesign().wordsBlock!.alignment, TextCardAlignment.right);

      // Every network's stand-in carries all of it...
      final want = composerDesign();
      for (final p in platforms) {
        expect(renderParametersEqual(designOf(p)!.toJson(), want.toJson()), isTrue, reason: p);
      }
      // ...and so does every saved card, with the @handle.
      final saved = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
      final ids = idsOf(c);
      for (final p in platforms) {
        final card = _savedCardOf(saved, ids[p]!);
        expect(renderParametersEqual(card.renderParameters!['design'], want.toJson()), isTrue, reason: '$p: the saved card\'s design');
        expect(card.renderParameters!['byline'], '@robin everywhere', reason: '$p: the saved card\'s @handle');
      }
      // Opened again: the composer has them back, and no network shows them as its own change.
      c.read(composerProvider.notifier).load(saved);
      await settle(tester);
      expect(c.read(composerProvider).textCardByline, '@robin everywhere');
      expect(renderParametersEqual(c.read(composerProvider).textCardDesign, want.toJson()), isTrue);
      for (final o in c.read(composerProvider).overrides.values) {
        expect(o.extra.containsKey(kTextCardBylineKey), isFalse);
      }
      expect(tester.widget<TextField>(find.byKey(const Key('text-card-master-byline'))).controller!.text, '@robin everywhere');

      // Resets: each network's own handle, then the classic card.
      await tap(tester, find.byKey(const Key('text-card-master-byline-reset')));
      expect(c.read(composerProvider).textCardByline, isNull);
      for (final p in platforms) {
        expect(textCardBylineOf(cardOf(p)), isNull, reason: '$p: its own handle again');
      }
      await tap(tester, find.byKey(const Key('text-card-master-classic')));
      for (final p in platforms) {
        expect(designOf(p), isNull, reason: '$p: the classic card again');
      }
      await finish(tester);
    });

    testWidgets('each network\'s own controls still work beside the quick designer; the panel says what differs', (tester) async {
      final (_, c) = await boot(tester);
      final cardOf = await compose(tester, c);
      await tester.enterText(find.byKey(const Key('text-card-master-byline')), '@me');
      await openMore(tester);
      await tap(tester, find.byKey(const Key('text-card-master-size-up')));
      // The theme pills set a design's colours in the master editor.
      await tap(tester, find.byKey(const Key('text-card-master-theme-light')));
      for (final p in platforms) {
        expect(textCardDesignOf(cardOf(p))!.hasTheme(TextCardTheme.light), isTrue, reason: p);
      }
      // Instagram's own "Show @handle" off, under its preview.
      final igHandle = find.descendant(of: find.byKey(const ValueKey('text-card-style-instagram')), matching: find.byKey(const Key('text-card-handle')));
      await tap(tester, igHandle);
      expect(textCardShowsHandleOf(cardOf('instagram')), isFalse);
      expect(textCardBylineOf(cardOf('instagram')), isNull, reason: 'no @handle where it is off');
      expect(textCardBylineOf(cardOf('bluesky')), '@me');
      expect(find.textContaining('no @handle on Instagram'), findsOneWidget);
      final helper = tester.widget<TextField>(find.byKey(const Key('text-card-master-byline'))).decoration!.helperText!;
      expect(helper, contains('not on Instagram'));
      await tap(tester, find.byKey(const Key('text-card-match')));
      expect({for (final p in platforms) textCardShowsHandleOf(cardOf(p))}, {true});
      expect(find.byKey(const Key('text-card-match')), findsNothing);
      // A photo picked under a preview shows on the restyled card, as on the
      // classic card; taken away, the card has its colour again.
      final n = c.read(composerProvider.notifier);
      const photo = MediaAttachment(id: 'bg', path: 'mem://bg.jpg', mimeType: 'image/jpeg', sizeBytes: 3);
      n.setTextCardBackground(const TextCardBackground(photo: photo).toJson());
      expect(CardDesign.tryParse(c.read(composerProvider).textCardDesign)!.background.kind, CardFillKind.image);
      n.setTextCardBackground(null);
      expect(CardDesign.tryParse(c.read(composerProvider).textCardDesign)!.background.kind, CardFillKind.solid);
      await settle(tester);
      await finish(tester);
    });

    testWidgets('by keyboard: the sliders take the arrow keys, the places and pills Enter, the colour its hex', (tester) async {
      final (_, c) = await boot(tester);
      await compose(tester, c);
      CardDesign? design() => CardDesign.tryParse(c.read(composerProvider).textCardDesign);

      /// Focuses the first focusable inside [f], as Tab would reach it.
      Future<void> focus(Finder f) async {
        await tester.ensureVisible(f);
        await tester.pump();
        // The first Focus inside that takes the keyboard (not a Shortcuts
        // scope); below it and its scope, the widget it wraps finds its node.
        final foci = find.descendant(of: f, matching: find.byType(Focus));
        final node = [
          for (var i = 0; i < foci.evaluate().length; i++)
            Focus.of(tester.element(find.descendant(of: foci.at(i), matching: find.byWidgetPredicate((_) => true)).at(1))),
        ].firstWhere((n) => n.canRequestFocus && !n.skipTraversal);
        node.requestFocus();
        await tester.pump();
        expect(node.hasFocus, isTrue, reason: '$f: $node');
      }

      await focus(find.byKey(const Key('text-card-master-more')));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byKey(const Key('text-card-master-size')), findsOneWidget, reason: 'unfolded by Enter');
      await focus(find.byKey(const Key('text-card-master-size')));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(design()!.wordsSize, kClassicWordsSize + 4, reason: 'one step');
      await focus(find.byKey(Key('text-card-master-handle-at-${CardAnchor.bottomCenter.name}')));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(design()!.handleAnchor, CardAnchor.bottomCenter);
      await focus(find.byKey(const Key('text-card-master-background-colour')));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(find.byKey(const Key('card-colour-hex')), '#204060');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(design()!.backgroundColor, 0xFF204060);
      await finish(tester);
    });

    testWidgets('the designer opens on the quick design, with its switches, and goes back to the classic card', (tester) async {
      final (_, c) = await boot(tester);
      await compose(tester, c);
      await openMore(tester);
      await tap(tester, find.byKey(const Key('text-card-master-size-up')));
      final pill = find.byKey(const Key('text-card-master-design'));
      expect(find.descendant(of: pill, matching: find.text('Design: Classic, restyled')), findsOneWidget);
      await tap(tester, pill);
      expect(find.text('Design the text card'), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-designer-group-layout')));
      await settle(tester);
      for (final key in ['card-keep-clear', 'card-signature-rules']) {
        expect(tester.widget<SwitchListTile>(find.byKey(Key(key))).value, isTrue, reason: key);
      }
      await tap(tester, find.byKey(const Key('card-keep-clear')));
      expect(CardDesign.tryParse(c.read(composerProvider).textCardDesign)!.keepClear, isFalse);
      await tap(tester, find.byKey(const Key('card-designer-reset')));
      expect(c.read(composerProvider).textCardDesign, isEmpty, reason: '"Back to the template": the classic card');
      await tester.tap(find.byKey(const Key('card-designer-done')));
      await settle(tester);
      await finish(tester);
    });

    for (final (name, size) in [('phone', const Size(390, 844)), ('CI window', const Size(940, 760))]) {
      testWidgets('at $name size: no overflow, every control in reach', (tester) async {
        final (_, c) = await boot(tester, size: size);
        await compose(tester, c);
        // Below the side-by-side layout, the previews are a tab.
        await tester.tap(find.textContaining('Preview ('));
        await settle(tester);
        // As the panel first shows (folded on a phone; open, with the size,
        // colour and place controls folded, at the CI's size), the first
        // network's preview is in reach below it.
        expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Customize for')), findsWidgets);
        if (size.width < 700) {
          expect(find.byKey(const Key('text-card-master-quick')), findsNothing, reason: 'folded on a phone');
          await tap(tester, find.byKey(const Key('text-card-master-toggle')));
        }
        expect(find.byKey(const Key('text-card-master-quick')), findsOneWidget, reason: 'open');
        await openMore(tester);
        for (final key in [
          'text-card-master-byline',
          'text-card-master-handle-size',
          'text-card-master-size',
          'text-card-master-line-height',
          'text-card-master-margin',
          'text-card-master-position',
          'text-card-master-text-colour',
          'text-card-master-background-colour',
        ]) {
          await tester.ensureVisible(find.byKey(Key(key)));
          await tester.pump();
          expect(tester.getRect(find.byKey(Key(key))).right, lessThanOrEqualTo(size.width), reason: key);
        }
        await tap(tester, find.byKey(const Key('text-card-master-size-up')));
        expect(CardDesign.tryParse(c.read(composerProvider).textCardDesign)!.wordsSize, kClassicWordsSize + 8);
        await tap(tester, find.byKey(Key('text-card-master-handle-at-${CardAnchor.topRight.name}')));
        expect(CardDesign.tryParse(c.read(composerProvider).textCardDesign)!.handleAnchor, CardAnchor.topRight);
        expect(tester.takeException(), isNull);
        await finish(tester);
      });
    }
  });
}

/// The card [p] gives the account [accountId].
MediaAttachment _savedCardOf(Post p, String accountId) => p.media.firstWhere((m) => m.id == p.targetFor(accountId)!.overrides.mediaIds!.single);
