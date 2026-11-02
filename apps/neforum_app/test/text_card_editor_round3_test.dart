// 1.3.5 review fixes, round 3, for the text card editor: one group per
// finding of the second blind review, each with a test that fails without
// its fix.
//  1. The photo's White / Black / Automatic are the photo's own, and going
//     back to a plain colour never leaves unreadable words.
//  2. "Reset" on a design survives folding the editor (and a restart).
//  3. A typed @handle shows on every built-in design.
//  4. Words moved to the top on Vinyl keep clear of the record.
//  5. Reset on the Settings default design follows the default again.
//  6. The footer follows the margins.
//  7. A design's margins never go under 24.
//  8. The size note is measured once per set of inputs.

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
import 'package:neforum_app/media/render_parameters.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/media/text_card_background.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/card_designs.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/text_cards.dart' show isRenderedTextCard;
import 'package:neforum_app/ui/compose/preview_card.dart' show debugTextCardWordsFitMeasurements;
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
const _photo = MediaAttachment(id: 'bg-photo', path: 'mem://bg-photo.jpg', mimeType: 'image/jpeg', sizeBytes: 10, width: 100, height: 100);

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

  Future<Map<String, ConnectedAccount>> compose(WidgetTester tester, ProviderContainer c, {String text = 'Readable words, always.'}) async {
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

  MediaAttachment placeholderOf(ProviderContainer c, ConnectedAccount a) =>
      c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == a.id).variant.media.single;

  Finder key(String name) => find.byKey(Key('$_master-$name'));

  Future<void> tapKey(WidgetTester tester, String name) async {
    await tester.ensureVisible(key(name));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(key(name));
    await settle(tester);
  }

  Future<void> unfold(WidgetTester tester) async {
    if (key('handle-size').evaluate().isEmpty) await tapKey(tester, 'more');
    expect(key('handle-size'), findsOneWidget);
  }

  group('1. the photo\'s White / Black are its own; a plain card never gets unreadable words', () {
    testWidgets('photo, Black, back to Colour: the saved cards have the theme\'s light words on the black card', (tester) async {
      final (s, c) = await boot(tester);
      final accounts = await compose(tester, c);
      c.read(composerProvider.notifier).setTextCardBackground(const TextCardBackground(photo: _photo).toJson());
      await settle(tester);
      // The Background sheet, as the user opens it.
      final open = find.descendant(of: find.byKey(const ValueKey('text-card-style-master')), matching: find.text('Background: photo'));
      await tester.ensureVisible(open);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(open);
      await settle(tester);
      await tester.tap(find.descendant(of: find.byKey(const Key('card-background-groups')), matching: find.text('Words')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('card-background-text-black')));
      await settle(tester);
      expect(c.read(composerProvider).textCardStyle.textColor, isNull, reason: 'the photo\'s own choice, not every card\'s');
      expect(TextCardBackground.tryParse(c.read(composerProvider).textCardBackground)!.textColor, TextCardTextColor.black);
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('card-background-text-black'))).selected, isTrue);
      // Back to a plain colour.
      await tester.tap(find.text('Colour').first);
      await settle(tester);
      await tester.tap(find.text('Done'));
      await settle(tester);
      expect(c.read(composerProvider).textCardBackground, isNull);
      for (final a in accounts.values) {
        expect(textCardStyleOf(placeholderOf(c, a)).textColor, isNull);
      }
      // The saved card: light words on the theme's black card.
      final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
      final card = post.media.where(isRenderedTextCard).first;
      final picture = img.decodeJpg((await tester.runAsync(() => s.media.read(card)))!)!;
      var light = 0;
      for (var y = picture.height ~/ 5; y < picture.height * 3 ~/ 5; y += 2) {
        for (var x = 0; x < picture.width; x += 2) {
          final p = picture.getPixel(x, y);
          if (p.r + p.g + p.b > 600) light++;
        }
      }
      expect(light, greaterThan(500), reason: 'readable words, not black on black');
      await finish(tester);
    });

    testWidgets('a words colour of the style too close to the plain card goes back to the theme\'s; a readable one stays', (tester) async {
      final (_, c) = await boot(tester);
      await compose(tester, c);
      final n = c.read(composerProvider.notifier)
        ..setTextCardTheme(TextCardTheme.dark)
        ..setTextCardBackground(const TextCardBackground(photo: _photo).toJson())
        ..setTextCardWordsColour(0xFF111111);
      n.setTextCardBackground(null);
      expect(c.read(composerProvider).textCardStyle.textColor, isNull, reason: 'near-black on black: unreadable');
      n
        ..setTextCardBackground(const TextCardBackground(photo: _photo).toJson())
        ..setTextCardWordsColour(0xFFFFD60A)
        ..setTextCardBackground(null);
      expect(c.read(composerProvider).textCardStyle.textColor, 0xFFFFD60A, reason: 'yellow on black reads: kept');
      expect(textCardContrast(const Color(0xFF000000), const Color(0xFF000000)), 1);
      expect(textCardContrast(const Color(0xFFFFFFFF), const Color(0xFF000000)), closeTo(21, 0.01));
      await finish(tester);
    });
  });

  group('2. Reset on a design survives folding the editor and a restart', () {
    testWidgets('edit, fold, unfold: Reset is still there and puts the design back', (tester) async {
      final (_, c) = await boot(tester);
      c.read(composerProvider.notifier).setTextCardDesign(_template('gradientWave'));
      await compose(tester, c);
      final before = c.read(composerProvider).textCardDesign;
      await unfold(tester);
      await tapKey(tester, 'text-size-larger');
      // The card colour turns the gradient into one colour.
      c.read(composerProvider.notifier).setTextCardDesignEdited(_template('gradientWave').withCardColor(0xFF3A0CA3));
      await settle(tester);
      for (var i = 0; i < 2; i++) {
        await tester.ensureVisible(find.byKey(const Key('text-card-master-toggle')));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const Key('text-card-master-toggle')));
        await settle(tester);
      }
      expect(key('handle-size'), findsNothing, reason: 'the editor was rebuilt: folded again');
      expect(tester.widget<ButtonStyleButton>(key('reset')).onPressed, isNotNull, reason: 'still enabled after folding');
      await tapKey(tester, 'reset');
      expect(renderParametersEqual(c.read(composerProvider).textCardDesign, before), isTrue, reason: 'the gradient is back');
      await finish(tester);
    });

    test('the draft keeps what Reset puts back; a design picked or a save forgets it', () {
      final before = {'design': _template('minimal').toJson()};
      final kept = composerDraftFromJson(composerDraftToJson(ComposerState(text: 'x', textCardDesignBeforeEdits: before)))!;
      expect(renderParametersEqual(kept.textCardDesignBeforeEdits, before), isTrue);
      expect(composerDraftToJson(const ComposerState(text: 'x')).containsKey('textCardDesignBeforeEdits'), isFalse);
    });

    testWidgets('picking a design starts afresh; saving makes the changes the post\'s', (tester) async {
      final (_, c) = await boot(tester);
      await compose(tester, c);
      final n = c.read(composerProvider.notifier)
        ..setTextCardDesign(_template('minimal'))
        ..setTextCardDesignEdited(_template('minimal').withMargin(120));
      expect(c.read(composerProvider).textCardDesignBeforeEdits, isNotNull);
      n.setTextCardDesign(_template('vinyl'));
      expect(c.read(composerProvider).textCardDesignBeforeEdits, isNull);
      n.setTextCardDesignEdited(_template('vinyl').withMargin(120));
      await tester.runAsync(() => c.read(postActionsProvider).saveDraft());
      expect(c.read(composerProvider).textCardDesignBeforeEdits, isNull);
      await finish(tester);
    });
  });

  group('3. a typed @handle shows on every built-in design', () {
    for (final t in kCardTemplates) {
      testWidgets(t.name, (tester) async {
        final design = designWithHandle(t.design(CardKind.text), '@neforum.app');
        expect(design.handleBlock, isNotNull);
        expect(designWithHandle(t.design(CardKind.text), null).toJson(), t.design(CardKind.text).toJson(), reason: 'no handle written: unchanged');
        Future<Uint8List> render(String? byline) async => (await tester.runAsync(() => renderDesignedTextCard(_MemoryStorage(),
            design: design, platformId: 'instagram', size: const Size(270, 338), text: 'Words on the card.', byline: byline)))!;
        expect(await render('@neforum.app'), isNot(await render(null)), reason: 'the handle is drawn');
      });
    }

    test('it goes where the template leaves room', () {
      final vinyl = _template('vinyl').withHandleBlock();
      expect(vinyl.handleBlock!.anchor, vinyl.wordsBlock!.anchor, reason: 'under the words at the bottom');
      expect([for (final b in vinyl.blocks) if (b.anchor == vinyl.wordsBlock!.anchor) b.role].last, CardBlockRole.handle);
      final neon = _template('neon').withHandleBlock();
      expect(neon.handleBlock!.anchor, CardAnchor.bottomCenter);
      expect([for (final b in neon.blocks) if (b.anchor == CardAnchor.bottomCenter) b.role], [CardBlockRole.handle, CardBlockRole.signature]);
      expect(_template('gradientWave').withHandleBlock().handleBlock!.anchor, CardAnchor.bottomLeft, reason: 'the corner the signature leaves free');
      expect(_template('sunset').withHandleBlock().handleBlock!.anchor, CardAnchor.bottomLeft);
    });

    testWidgets('on a design without one, the saved card has the typed @handle', (tester) async {
      final (_, c) = await boot(tester);
      c.read(composerProvider.notifier).setTextCardDesign(_template('gradientWave'));
      final accounts = await compose(tester, c);
      await tester.enterText(key('handle'), '@neforum.app');
      await settle(tester);
      for (final a in accounts.values) {
        expect(textCardDesignOf(placeholderOf(c, a))!.handleBlock, isNotNull);
      }
      final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
      for (final card in post.media.where(isRenderedTextCard)) {
        expect(textCardDesignOf(card)!.handleBlock, isNotNull);
        expect(textCardBylineOf(card), '@neforum.app');
      }
      expect(c.read(composerProvider).textCardDesign!['blocks'].length, _template('gradientWave').blocks.length, reason: 'the post\'s own design is not changed for it');
      await finish(tester);
    });
  });

  group('4. words moved to the top on Vinyl keep clear of the record', () {
    test('on every card shape the words start below the record; back in the middle they have the template\'s room', () {
      final vinyl = _template('vinyl');
      final top = vinyl.withWordsPosition(TextCardTextPosition.top);
      for (final (size, safe) in [
        (const Size(1080, 1080), EdgeInsets.zero),
        (const Size(1080, 1350), EdgeInsets.zero),
        (const Size(1080, 1920), fullScreenSafeArea('tiktok')),
      ]) {
        final frame = cardFrameOf(size, safe, top.margin);
        final record = cardCoverRect(top.cover, frame);
        final wordsTop = frame.top + top.wordsBlock!.offsetY * frame.height;
        expect(wordsTop, greaterThanOrEqualTo(record.bottom), reason: '$size');
      }
      final middle = top.withWordsPosition(TextCardTextPosition.center);
      expect(middle.wordsBlock!.offsetY, 0);
      expect(middle.wordsBlock!.maxHeight, vinyl.wordsBlock!.maxHeight);
      // No cover drawn on that edge: nothing to keep clear of.
      expect(_template('minimal').withWordsPosition(TextCardTextPosition.top).wordsBlock!.offsetY, 0);
    });

    testWidgets('the pixels: no words on the record', (tester) async {
      Future<img.Image> draw(CardDesign d) async {
        final bytes = (await tester.runAsync(() => renderDesignedTextCard(_MemoryStorage(),
            design: d, platformId: 'instagram', size: const Size(270, 270), text: 'Words that would cover the record if they could.')))!;
        return img.decodeJpg(bytes)!;
      }

      final top = _template('vinyl').withWordsPosition(TextCardTextPosition.top);
      final plain = _template('vinyl').copyWith(blocks: const []);
      final withWords = await draw(top), without = await draw(plain);
      final frame = cardFrameOf(const Size(270, 270), EdgeInsets.zero, top.margin);
      final record = cardCoverRect(top.cover, frame).deflate(4);
      var differing = 0;
      for (var y = record.top.ceil(); y < record.bottom; y += 2) {
        for (var x = record.left.ceil(); x < record.right; x += 2) {
          final a = withWords.getPixel(x, y), b = without.getPixel(x, y);
          if ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs() > 60) differing++;
        }
      }
      expect(differing, lessThan(8), reason: 'the record looks the same with the words at the top');
    });
  });

  group('5. Reset on the Settings default design follows the default again', () {
    testWidgets('A+ then Reset: the post has no design of its own', (tester) async {
      final (_, c) = await boot(tester);
      await c.read(settingsProvider.notifier).update((x) => x.copyWith(textCardDesign: _template('minimal').toJson()));
      await compose(tester, c);
      expect(c.read(composerProvider).textCardDesign, isNull, reason: 'follows Settings');
      await unfold(tester);
      await tapKey(tester, 'text-size-larger');
      expect(c.read(composerProvider).textCardDesign, isNotNull);
      await tapKey(tester, 'reset');
      expect(c.read(composerProvider).textCardDesign, isNull, reason: 'follows Settings again');
      expect(effectiveCardDesign(c.read(composerProvider).textCardDesign, _template('vinyl').toJson())!.template, 'vinyl',
          reason: 'a later default reaches the post');
      await finish(tester);
    });
  });

  group('6. the footer follows the margins', () {
    testWidgets('margins 24 and 240: the @handle\'s row moves up by the margin\'s share of 84 px', (tester) async {
      Future<int> lowestInkRow(double margin) async {
        final bytes = (await tester.runAsync(() => renderTextCardJpeg(
            text: 'Hi.', theme: TextCardTheme.dark, size: const Size(360, 450), byline: '@footer.handle', branded: false, style: TextCardStyle(margin: margin))))!;
        final i = img.decodeJpg(bytes)!;
        for (var y = i.height - 1; y > 0; y--) {
          for (var x = 0; x < i.width; x++) {
            final p = i.getPixel(x, y);
            if (p.r + p.g + p.b > 300) return y;
          }
        }
        return -1;
      }

      final low = await lowestInkRow(24), high = await lowestInkRow(240);
      // 84 px at the card's own 92, scaled by margin / 92, at 360 wide (/3).
      expect(low - high, closeTo((84 * 240 / 92 - 84 * 24 / 92) / 3, 4));
    });
  });

  group('7. a design\'s margins never go under 24', () {
    testWidgets('the edit and the slider stop at 24', (tester) async {
      expect(_template('minimal').withMargin(0).margin, 24);
      final (_, c) = await boot(tester);
      c.read(composerProvider.notifier).setTextCardDesign(_template('minimal'));
      await compose(tester, c);
      await unfold(tester);
      await tester.ensureVisible(key('margin'));
      await tester.drag(key('margin'), const Offset(-2000, 0));
      await settle(tester);
      expect(c.read(composerProvider).textDesign(c.read(settingsProvider))!.margin, 24);
      await finish(tester);
    });
  });

  group('8. the size note is measured once per set of inputs', () {
    testWidgets('a composer change that leaves the words, cards and style alone measures nothing again', (tester) async {
      final (_, c) = await boot(tester);
      await compose(tester, c);
      c.read(composerProvider.notifier).setTextCardStyle(const TextCardStyle(textSize: 1.5));
      await settle(tester);
      await unfold(tester);
      final before = debugTextCardWordsFitMeasurements;
      c.read(composerProvider.notifier)
        ..setTitle('A title nobody sees on the card')
        ..setContentWarning('cw');
      await settle(tester);
      expect(debugTextCardWordsFitMeasurements, before, reason: 'from the cache');
      c.read(composerProvider.notifier).setTextCardStyle(const TextCardStyle(textSize: 1.6));
      await settle(tester);
      expect(debugTextCardWordsFitMeasurements, before + 1, reason: 'a new size is measured once');
      await finish(tester);
    });
  });
}
