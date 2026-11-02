// 1.3.5 review fixes for the text card editor ("Text card for every
// network"): one group per finding of the blind review, each with a test
// that fails without its fix.
//  1. A card designer design gets every control, editing the design.
//  2. The words' place and colour are one setting with the background
//     photo's "Words" controls.
//  3. "Text & @handle…" only where no master editor is.
//  4. The @handle line keeps naming the handles a written one replaces.
//  5. A larger size that changes nothing says so.
//  6. The @handle in the middle of the top or bottom edge.
//  7. A designed card records only what it draws of the style.
//  8. The composer's stand-ins record the @handle only when one is written.
// Plus the A−/A+ steps and the hex code on the colour buttons.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/card_design_edits.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/media/render_parameters.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/media/text_card_background.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart' show TextCardAlignment;
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
}

const _platforms = ['instagram', 'bluesky', 'mastodon'];
const _master = 'text-card-master-style';
const _long = 'A long post with a great many words, enough that the card has to set them small to fit at all, and then '
    'more words again, and again more of them, so that nothing larger could possibly fit on any card anywhere.';

CardDesign _template(String id) => cardTemplateById(id)!.design(CardKind.text);

void main() {
  setUpAll(_loadFonts);

  Future<(AppServices, ProviderContainer)> boot(WidgetTester tester, {Size size = const Size(1440, 2600)}) async {
    tester.view.physicalSize = size;
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

  Future<Map<String, ConnectedAccount>> compose(WidgetTester tester, ProviderContainer c, {List<String> platforms = _platforms, String text = 'One card, styled once.'}) async {
    c.read(routerProvider).go('/compose');
    await settle(tester);
    final demo = c.read(accountListProvider);
    final byPlatform = {for (final p in platforms) p: demo.firstWhere((a) => a.platformId == p)};
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), text);
    c.read(composerProvider.notifier)
      ..selectAccounts([for (final a in byPlatform.values) a.id])
      ..setTextCardEveryNetwork(true);
    await settle(tester);
    return byPlatform;
  }

  MediaAttachment placeholderOf(ProviderContainer c, ConnectedAccount a) =>
      c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == a.id).variant.media.single;

  Finder key(String name) => find.byKey(Key('$_master-$name'));

  FocusNode focusOf(WidgetTester tester, Finder control) =>
      Focus.of(tester.element(find.descendant(of: control, matching: find.byWidgetPredicate((_) => true)).last));

  Future<void> tapKey(WidgetTester tester, String name) async {
    await tester.ensureVisible(key(name));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(key(name));
    await settle(tester);
  }

  Future<void> unfold(WidgetTester tester) async {
    if (key('text-size').evaluate().isEmpty && key('handle-size').evaluate().isEmpty) await tapKey(tester, 'more');
    expect(key('handle-size'), findsOneWidget);
  }

  Future<void> arrows(WidgetTester tester, String name, LogicalKeyboardKey k, int times) async {
    await tester.ensureVisible(key(name));
    focusOf(tester, key(name)).requestFocus();
    await tester.pump();
    for (var i = 0; i < times; i++) {
      await tester.sendKeyEvent(k);
      await tester.pump();
    }
    await settle(tester);
  }

  Future<void> colour(WidgetTester tester, String name, String hex) async {
    await tapKey(tester, name);
    await tester.enterText(find.byKey(const Key('card-colour-hex')), hex);
    await tester.tap(find.byKey(const Key('card-colour-use')));
    await settle(tester);
  }

  /// Saves the composer's post; each network's saved card.
  Future<Map<String, MediaAttachment>> save(WidgetTester tester, ProviderContainer c, Map<String, ConnectedAccount> accounts) async {
    final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
    final cards = {for (final m in post.media.where(isRenderedTextCard)) m.id: m};
    return {
      for (final MapEntry(key: platform, value: a) in accounts.entries)
        platform: post.targetFor(a.id)!.overrides.mediaIds!.map((id) => cards[id]).whereType<MediaAttachment>().single,
    };
  }

  group('1. a card designer design gets every control, and they edit the design', () {
    test('words: size, colour (with the blocks drawn in it), line spacing, place; card colour; margins', () {
      final d = _template('minimal');
      expect(d.withWordsSize(150).wordsBlock!.size, 150);
      expect(d.withWordsLineHeight(1.7).wordsBlock!.lineHeight, 1.7);
      final red = d.withWordsColor(0xFFFF3B30);
      expect(red.wordsBlock!.color, 0xFFFF3B30);
      expect(red.handleBlock!.color, 0x99FF3B30, reason: 'the handle was drawn in the words\' colour, faded: it follows, still faded');
      expect(d.withCardColor(0xFF3A0CA3).background.color, 0xFF3A0CA3);
      expect(_template('gradientWave').withCardColor(0xFF3A0CA3).background.kind, CardFillKind.solid);
      expect(_template('photoOverlay').cardColorEditable, isFalse, reason: 'a photo card has no colour to change');
      expect(d.withMargin(120).margin, 120);
      expect(d.withWordsPosition(TextCardTextPosition.top).wordsPosition, TextCardTextPosition.top);
      expect(d.withWordsPosition(TextCardTextPosition.top).wordsBlock!.offsetY, 0);
    });

    test('round 5: words moved to the @handle\'s edge are placed by the renderer, not stacked into the @handle\'s anchor', () {
      // Photo overlay: the @handle at the top left, the words at the bottom.
      // Round 4 joined the words to the @handle's anchor; round 5 leaves every
      // template block where it is and places the words in the free band
      // under the @handle when the card is drawn (CardDesign.placeWords).
      final t = _template('photoOverlay');
      final up = t.withWordsPosition(TextCardTextPosition.top);
      expect(up.wordsBlock!.anchor.name, startsWith('top'));
      expect(up.placeWords, isTrue);
      expect(up.handleBlock!.toJson(), t.handleBlock!.toJson(), reason: 'the template\'s @handle is not moved for the words');
      expect([for (final b in up.blocks) b.role], [for (final b in t.blocks) b.role], reason: 'no reorder');
    });

    test('the @handle: size, colour, the six places; a design without one gets one in its free slot; the signature stays', () {
      final vinyl = _template('vinyl');
      expect(vinyl.handleBlock, isNull);
      final withHandle = vinyl.withHandleSize(40);
      expect(withHandle.handleBlock!.size, 40);
      expect(withHandle.handleBlock!.anchor, CardAnchor.topRight, reason: 'Vinyl\'s declared slot: beside the record, across from the signature');
      final m = _template('minimal');
      for (final p in kDesignHandlePositions) {
        final moved = m.withHandlePosition(p);
        expect(moved.handlePosition, p);
        expect(moved.handleBlock!.alignment, cardAlignmentAt(cardAnchorOfHandlePosition(p)));
        expect(moved.placeHandle, isTrue);
        expect(moved.signatureBlock!.toJson(), m.signatureBlock!.toJson(), reason: 'round 5: the signature never moves; the @handle is placed clear of it');
      }
      expect(m.withHandleColor(0xFFFF3B30).handleBlock!.color, 0xFFFF3B30);
    });

    // control -> the post's design -> every stand-in -> every saved card.
    final controls = <String, (Future<void> Function(WidgetTester t), bool Function(CardDesign before, CardDesign after) changed)>{
      'words size (A+)': ((t) => tapKey(t, 'text-size-larger'), (b, a) => a.wordsSize == b.wordsSize + 8),
      'line spacing': ((t) => arrows(t, 'line-spacing', LogicalKeyboardKey.arrowRight, 3), (b, a) => a.wordsLineHeight > b.wordsLineHeight),
      'words position': ((t) => tapKey(t, 'position-top'), (b, a) => a.wordsPosition == TextCardTextPosition.top),
      'words colour': ((t) => colour(t, 'text-colour', '#FFD60A'), (b, a) => a.wordsColor & 0xFFFFFF == 0xFFD60A),
      'card colour': ((t) => colour(t, 'background-colour', '#3A0CA3'), (b, a) => a.background.color == 0xFF3A0CA3),
      'margins': ((t) => arrows(t, 'margin', LogicalKeyboardKey.arrowRight, 2), (b, a) => a.margin > b.margin),
      'handle size': ((t) => arrows(t, 'handle-size', LogicalKeyboardKey.arrowRight, 2), (b, a) => a.handleSize > b.handleSize),
      'handle place (top centre)': ((t) => tapKey(t, 'handle-corner-topCenter'), (b, a) => a.handlePosition == TextCardHandlePosition.topCenter),
      'handle colour': ((t) => colour(t, 'handle-colour', '#FF3B30'), (b, a) => a.handleColor == 0xFFFF3B30),
    };
    for (final MapEntry(key: name, value: (act, changed)) in controls.entries) {
      testWidgets('designed card: $name', (tester) async {
        final (_, c) = await boot(tester);
        c.read(composerProvider.notifier).setTextCardDesign(_template('minimal'));
        final accounts = await compose(tester, c);
        expect(key('handle'), findsOneWidget);
        await unfold(tester);
        expect(key('design-note'), findsOneWidget);
        final before = c.read(composerProvider).textDesign(c.read(settingsProvider))!;
        await act(tester);
        final after = c.read(composerProvider).textDesign(c.read(settingsProvider))!;
        expect(changed(before, after), isTrue, reason: 'the post\'s design changed');
        expect(c.read(composerProvider).textCardStyle, TextCardStyle.classic, reason: 'the classic style is left for when the design is off');
        for (final MapEntry(key: platform, value: a) in accounts.entries) {
          expect(renderParametersEqual(textCardDesignOf(placeholderOf(c, a))!.toJson(), after.toJson()), isTrue, reason: '$platform\'s stand-in');
        }
        final cards = await save(tester, c, accounts);
        for (final MapEntry(key: platform, value: card) in cards.entries) {
          expect(renderParametersEqual(card.renderParameters!['design'], after.toJson()), isTrue, reason: '$platform\'s saved card is drawn from it');
        }
        await finish(tester);
      });
    }

    testWidgets('"Reset handle and words" puts the design back as it was, the classic style untouched', (tester) async {
      final (_, c) = await boot(tester);
      c.read(composerProvider.notifier)
        ..setTextCardDesign(_template('minimal'))
        ..setTextCardStyle(const TextCardStyle(margin: 140));
      await compose(tester, c);
      await unfold(tester);
      final before = c.read(composerProvider).textCardDesign;
      await tapKey(tester, 'text-size-larger');
      await tapKey(tester, 'handle-corner-topRight');
      expect(renderParametersEqual(c.read(composerProvider).textCardDesign, before), isFalse);
      await tapKey(tester, 'reset');
      expect(renderParametersEqual(c.read(composerProvider).textCardDesign, before), isTrue);
      expect(c.read(composerProvider).textCardStyle, const TextCardStyle(margin: 140));
      await finish(tester);
    });
  });

  group('2. the words\' place and colour: one setting with the background photo', () {
    const photo = MediaAttachment(id: 'bg-photo', path: 'mem://bg-photo.jpg', mimeType: 'image/jpeg', sizeBytes: 10, width: 100, height: 100);

    test('a place or colour the photo chose before 1.3.5 is what both show, until either sets one', () {
      const bg = TextCardBackground(photo: photo, textPosition: TextCardTextPosition.top, textColor: TextCardTextColor.black);
      expect(textCardWordsPosition(TextCardStyle.classic, bg), TextCardTextPosition.top);
      expect(textCardWordsColour(TextCardStyle.classic, bg), 0xFF000000);
      expect(textCardWordsPosition(const TextCardStyle(textPosition: TextCardTextPosition.bottom), bg), TextCardTextPosition.bottom);
    });

    testWidgets('the master editor and the Background sheet show and set the same place and colour', (tester) async {
      final (_, c) = await boot(tester);
      final accounts = await compose(tester, c);
      // A photo whose own choices (from before 1.3.5) are the top and black.
      c.read(composerProvider.notifier).setTextCardBackground(
          const TextCardBackground(photo: photo, textPosition: TextCardTextPosition.top, textColor: TextCardTextColor.black).toJson());
      await settle(tester);
      await unfold(tester);
      expect(tester.widget<ChoiceChip>(key('position-top')).selected, isTrue, reason: 'the master shows the photo\'s place');
      expect(find.descendant(of: key('text-colour'), matching: find.text('Words #000000')), findsOneWidget, reason: 'and its colour');

      // The master sets the bottom: the photo's own place is folded in.
      await tapKey(tester, 'position-bottom');
      final afterMaster = c.read(composerProvider);
      expect(afterMaster.textCardStyle.textPosition, TextCardTextPosition.bottom);
      expect(TextCardBackground.tryParse(afterMaster.textCardBackground)!.textPosition, TextCardTextPosition.center);

      // The sheet shows the bottom, and sets the top and white for both.
      final open = find.descendant(of: find.byKey(const ValueKey('text-card-style-master')), matching: find.text('Background: photo'));
      await tester.ensureVisible(open);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(open);
      await settle(tester);
      await tester.tap(find.descendant(of: find.byKey(const Key('card-background-groups')), matching: find.text('Words')));
      await settle(tester);
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('card-background-position-bottom'))).selected, isTrue);
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('card-background-text-black'))).selected, isTrue);
      await tester.tap(find.byKey(const Key('card-background-position-top')));
      await tester.tap(find.byKey(const Key('card-background-text-white')));
      await settle(tester);
      final afterSheet = c.read(composerProvider);
      expect(afterSheet.textCardStyle.textPosition, TextCardTextPosition.top, reason: 'no silent override: the sheet\'s place is the card\'s');
      // White is the photo's own (round 3): it goes with the photo.
      expect(afterSheet.textCardStyle.textColor, isNull);
      expect(TextCardBackground.tryParse(afterSheet.textCardBackground)!.textColor, TextCardTextColor.white);
      expect(textCardWordsColour(afterSheet.textCardStyle, TextCardBackground.tryParse(afterSheet.textCardBackground)), 0xFFFFFFFF);
      for (final a in accounts.values) {
        expect(textCardStyleOf(placeholderOf(c, a)).textPosition, TextCardTextPosition.top);
      }
      await tester.tap(find.text('Done'));
      await settle(tester);
      expect(tester.widget<ChoiceChip>(key('position-top')).selected, isTrue, reason: 'the master shows what the sheet set');
      expect(find.descendant(of: key('text-colour'), matching: find.text('Words #FFFFFF')), findsOneWidget);
      await finish(tester);
    });
  });

  group('3. "Text & @handle…" only where no master editor is', () {
    testWidgets('with three networks\' cards only the master editor edits them; with one, the pill under its card', (tester) async {
      final (_, c) = await boot(tester);
      await compose(tester, c);
      expect(find.byKey(const Key('text-card-master')), findsOneWidget);
      expect(find.byKey(const Key('text-card-text-style')), findsNothing, reason: 'no per-network pill that edits every network');
      c.read(composerProvider.notifier).selectAccounts([c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram').id]);
      await settle(tester);
      expect(find.byKey(const Key('text-card-master')), findsNothing);
      expect(find.byKey(const Key('text-card-text-style')), findsOneWidget);
      await finish(tester);
    });
  });

  group('4. the @handle line names what it replaces', () {
    testWidgets('after typing, "In place of" lists every network\'s own handle', (tester) async {
      final (_, c) = await boot(tester);
      final accounts = await compose(tester, c);
      await tester.enterText(key('handle'), '@neforum');
      await settle(tester);
      final line = find.textContaining('In place of ');
      expect(line, findsOneWidget);
      final text = tester.widget<Text>(line).data!;
      for (final a in accounts.values) {
        expect(text, contains(a.handle ?? a.displayName));
      }
      await finish(tester);
    });
  });

  group('5. a larger size that changes nothing says so', () {
    testWidgets('measureWords: short words grow, long ones stay as large as fits', (tester) async {
      const size = Size(1080, 1350);
      final short = TextCardPainter(text: 'Hi.', theme: TextCardTheme.dark, style: const TextCardStyle(textSize: 1.5)).measureWords(size);
      expect(short.drawn, closeTo(short.fitted * 1.5, 0.01));
      final long = TextCardPainter(text: _long, theme: TextCardTheme.dark, style: const TextCardStyle(textSize: 2)).measureWords(size);
      expect(long.drawn, long.fitted);
      // The measure is the paint: the same size the card is drawn at.
      final small = TextCardPainter(text: 'Hi.', theme: TextCardTheme.dark, style: const TextCardStyle(textSize: 0.5)).measureWords(size);
      expect(small.drawn, closeTo(small.fitted * 0.5, 0.01));
    });

    testWidgets('the master editor: "Already as large as these words fit" on a long post, nothing on a short one', (tester) async {
      final (_, c) = await boot(tester);
      await compose(tester, c, text: _long);
      c.read(composerProvider.notifier).setTextCardStyle(const TextCardStyle(textSize: 2));
      await settle(tester);
      await unfold(tester);
      expect(find.textContaining('Already as large as these words fit'), findsOneWidget);
      c.read(composerProvider.notifier).prefill('Hi.');
      await settle(tester);
      expect(key('text-size-note'), findsNothing);
      await finish(tester);
    });

    testWidgets('a design whose words shrink to fit says the size they come out at', (tester) async {
      final (_, c) = await boot(tester);
      c.read(composerProvider.notifier).setTextCardDesign(_template('minimal').withWordsSize(220));
      await compose(tester, c, text: 'Words set large, shrinking to fit.');
      await unfold(tester);
      expect(find.textContaining('Shrinks to fit on'), findsOneWidget);
      // Round 5: a post too long even at the smallest size is cut, and the
      // note says that rather than only the size.
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), _long);
      await settle(tester);
      expect(find.textContaining('Shrinks to fit on'), findsNothing);
      expect(find.textContaining('Too long for this card on'), findsOneWidget, reason: 'no position was measured to help on a design that does not place its words');
      await finish(tester);
    });
  });

  group('6. the @handle in the middle of the top or bottom edge', () {
    testWidgets('top centre and bottom centre are drawn centred, and round-trip', (tester) async {
      Future<img.Image> card(TextCardHandlePosition p) async => img.decodeJpg((await tester.runAsync(() => renderTextCardJpeg(
          text: 'Hi.', theme: TextCardTheme.dark, size: const Size(360, 450), byline: '@centred.handle', branded: false, style: TextCardStyle(handlePosition: p))))!)!;
      double inkCentre(img.Image i, int y0, int y1) {
        var sum = 0.0, n = 0;
        for (var y = y0; y < y1; y++) {
          for (var x = 0; x < i.width; x++) {
            final p = i.getPixel(x, y);
            if (p.r + p.g + p.b > 300) {
              sum += x;
              n++;
            }
          }
        }
        return n == 0 ? -1 : sum / n;
      }

      expect(inkCentre(await card(TextCardHandlePosition.topCenter), 30, 52), closeTo(180, 6), reason: 'top centre');
      expect(inkCentre(await card(TextCardHandlePosition.bottomCenter), 398, 426), closeTo(180, 6), reason: 'bottom centre');
      expect(inkCentre(await card(TextCardHandlePosition.bottomLeft), 398, 426), lessThan(120));
      for (final p in [TextCardHandlePosition.topCenter, TextCardHandlePosition.bottomCenter]) {
        expect(TextCardStyle.fromJson(TextCardStyle(handlePosition: p).toJson()).handlePosition, p);
      }
    });

    testWidgets('the master editor offers them', (tester) async {
      final (_, c) = await boot(tester);
      await compose(tester, c);
      await unfold(tester);
      await tapKey(tester, 'handle-corner-bottomCenter');
      expect(c.read(composerProvider).textCardStyle.handlePosition, TextCardHandlePosition.bottomCenter);
      expect(key('handle-corner-topCenter'), findsOneWidget);
      await finish(tester);
    });
  });

  group('7. a designed card records only what it draws of the style', () {
    test('only the @handle; a classic change it does not show leaves its parameters alone', () {
      final design = _template('minimal');
      Map<String, dynamic> params(TextCardStyle style) => textCardRenderParameters(
          platformId: 'instagram', theme: TextCardTheme.dark, font: TextCardFont.original, branded: true, alignment: TextCardAlignment.left, showsHandle: true,
          design: design, style: style);
      expect(params(const TextCardStyle(textSize: 1.4, margin: 140, handle: '@neforum'))['style'], {'handle': '@neforum'});
      expect(params(const TextCardStyle(textSize: 1.4)).containsKey('style'), isFalse);
      expect(renderParametersEqual(params(const TextCardStyle(textSize: 1.4)), params(TextCardStyle.classic)), isTrue,
          reason: 'not made again for a change it does not show');
      // The classic card still records the whole style.
      expect(textCardRenderParameters(
          platformId: 'instagram', theme: TextCardTheme.dark, font: TextCardFont.original, branded: true, alignment: TextCardAlignment.left, showsHandle: true,
          style: const TextCardStyle(textSize: 1.4))['style'], {'textSize': 1.4});
    });
  });

  group('8. the composer\'s stand-ins record the @handle only when one is written', () {
    testWidgets('an untouched post\'s stand-ins have 1.3.4\'s parameters; a written @handle is recorded', (tester) async {
      final (_, c) = await boot(tester);
      final accounts = await compose(tester, c);
      for (final a in accounts.values) {
        expect(placeholderOf(c, a).renderParameters!.containsKey('byline'), isFalse);
        expect(placeholderOf(c, a).renderParameters!.containsKey('style'), isFalse);
      }
      await tester.enterText(key('handle'), '@neforum');
      await settle(tester);
      for (final a in accounts.values) {
        expect(textCardBylineOf(placeholderOf(c, a)), '@neforum');
      }
      await finish(tester);
    });
  });

  group('taken from the other design: steps and hex codes', () {
    testWidgets('A− and A+ step the words\' size; each colour button shows its hex code', (tester) async {
      final (_, c) = await boot(tester);
      await compose(tester, c);
      await unfold(tester);
      await tapKey(tester, 'text-size-larger');
      await tapKey(tester, 'text-size-larger');
      expect(c.read(composerProvider).textCardStyle.textSize, closeTo(1.2, 1e-9));
      await tapKey(tester, 'text-size-smaller');
      expect(c.read(composerProvider).textCardStyle.textSize, closeTo(1.1, 1e-9));
      await colour(tester, 'background-colour', '#3A0CA3');
      expect(find.descendant(of: key('background-colour'), matching: find.text('Card #3A0CA3')), findsOneWidget);
      await finish(tester);
    });
  });
}
