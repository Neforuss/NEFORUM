// 1.3.5: the text card editor's @handle and "more editing power". Every new
// control of the master editor ("Text card for every network") is driven
// through the real widget and followed through the chain: control ->
// composer state -> every network's preview stand-in -> every network's
// saved card. Also: the @handle field and its reset, Show @handle off staying
// off, keyboard use, a phone and CI's window size without overflow, the
// sheet under one network's card, the theme pills, "Make them match", and
// saving, reopening and a scheduled post.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/media/text_card_background.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
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

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
}

const _platforms = ['instagram', 'bluesky', 'mastodon'];
const _master = 'text-card-master-style';

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

  /// A text-only post going to [platforms] with the card on every network;
  /// returns the accounts by platform.
  Future<Map<String, ConnectedAccount>> compose(WidgetTester tester, ProviderContainer c, {List<String> platforms = _platforms}) async {
    c.read(routerProvider).go('/compose');
    await settle(tester);
    final demo = c.read(accountListProvider);
    final byPlatform = {for (final p in platforms) p: demo.firstWhere((a) => a.platformId == p)};
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), 'One card, styled once.');
    c.read(composerProvider.notifier)
      ..selectAccounts([for (final a in byPlatform.values) a.id])
      ..setTextCardEveryNetwork(true);
    await settle(tester);
    return byPlatform;
  }

  MediaAttachment placeholderOf(ProviderContainer c, ConnectedAccount a) =>
      c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == a.id).variant.media.single;

  /// Saves the composer's post as a draft; each network's saved card.
  Future<(Post, Map<String, MediaAttachment>)> save(WidgetTester tester, ProviderContainer c, Map<String, ConnectedAccount> accounts,
      {bool schedule = false}) async {
    final post = (await tester.runAsync(() => schedule ? c.read(postActionsProvider).schedule() : c.read(postActionsProvider).saveDraft()))!;
    final cards = {for (final m in post.media.where(isRenderedTextCard)) m.id: m};
    return (
      post,
      {
        for (final MapEntry(key: platform, value: a) in accounts.entries)
          platform: post.targetFor(a.id)!.overrides.mediaIds!.map((id) => cards[id]).whereType<MediaAttachment>().single,
      }
    );
  }

  Finder key(String name) => find.byKey(Key('$_master-$name'));

  /// The focus node a control takes keyboard focus with: the nearest one
  /// around its innermost widget.
  FocusNode focusOf(WidgetTester tester, Finder control) =>
      Focus.of(tester.element(find.descendant(of: control, matching: find.byWidgetPredicate((_) => true)).last));

  /// Focuses the slider [name] as the keyboard would and presses [k] [times].
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

  Future<void> tapKey(WidgetTester tester, String name) async {
    await tester.ensureVisible(key(name));
    // A scroll still moving (a focused field revealing its caret) holds
    // pointers back from the list, as on a device: let it finish.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(key(name));
    await settle(tester);
  }

  /// Unfolds "Style the words and the handle" when it is folded.
  Future<void> unfold(WidgetTester tester) async {
    if (key('text-size').evaluate().isEmpty) await tapKey(tester, 'more');
    expect(key('text-size'), findsOneWidget);
  }

  /// Opens the colour button [name], types [hex] and uses it.
  Future<void> colour(WidgetTester tester, String name, String hex) async {
    await tapKey(tester, name);
    expect(find.text('Pick a colour on the wheel or below it, or type its hex code.'), findsOneWidget, reason: 'the colour wheel and hex dialog');
    await tester.enterText(find.byKey(const Key('card-colour-hex')), hex);
    await tester.tap(find.byKey(const Key('card-colour-use')));
    await settle(tester);
  }

  // control -> composer state -> stand-ins -> saved cards, one control each.
  final controls = <String, (Future<void> Function(WidgetTester t), bool Function(TextCardStyle s))>{
    'words size (arrow keys)': ((t) => arrows(t, 'text-size', LogicalKeyboardKey.arrowRight, 3), (s) => s.textSize > 1),
    'words size (dragged)': (
      (t) async {
        await t.ensureVisible(key('text-size'));
        await t.drag(key('text-size'), const Offset(120, 0));
        await settle(t);
      },
      (s) => s.textSize > 1,
    ),
    'line spacing': ((t) => arrows(t, 'line-spacing', LogicalKeyboardKey.arrowRight, 3), (s) => s.lineSpacing > TextCardStyle.defaultLineSpacing),
    'margins': ((t) => arrows(t, 'margin', LogicalKeyboardKey.arrowLeft, 3), (s) => s.margin < TextCardStyle.defaultMargin),
    'position of the words': ((t) => tapKey(t, 'position-bottom'), (s) => s.textPosition == TextCardTextPosition.bottom),
    'colour of the words': ((t) => colour(t, 'text-colour', '#FFD60A'), (s) => s.textColor == 0xFFFFD60A),
    'colour of the card': ((t) => colour(t, 'background-colour', '#3A0CA3'), (s) => s.backgroundColor == 0xFF3A0CA3),
    '@handle words': (
      (t) async {
        await t.ensureVisible(key('handle'));
        await t.enterText(key('handle'), '@neforum');
        await settle(t);
      },
      (s) => s.handle == '@neforum',
    ),
    '@handle size': ((t) => arrows(t, 'handle-size', LogicalKeyboardKey.arrowUp, 4), (s) => s.handleSize > 1),
    '@handle corner': ((t) => tapKey(t, 'handle-corner-topLeft'), (s) => s.handlePosition == TextCardHandlePosition.topLeft),
    '@handle colour': ((t) => colour(t, 'handle-colour', '#FF3B30'), (s) => s.handleColor == 0xFFFF3B30),
  };

  group('every control of the master editor reaches every network\'s saved card', () {
    for (final MapEntry(key: name, value: (act, changed)) in controls.entries) {
      testWidgets(name, (tester) async {
        final (_, c) = await boot(tester);
        final accounts = await compose(tester, c);
        expect(c.read(composerProvider).textCardStyle, TextCardStyle.classic);
        await unfold(tester);
        await act(tester);
        final style = c.read(composerProvider).textCardStyle;
        expect(changed(style), isTrue, reason: 'the composer holds the change: $style');
        for (final MapEntry(key: platform, value: a) in accounts.entries) {
          expect(textCardStyleOf(placeholderOf(c, a)), style, reason: '$platform\'s preview stands in for the restyled card');
        }
        final (post, cards) = await save(tester, c, accounts);
        expect(textCardStyleChoiceOfPost(post), style, reason: 'kept on the post for a scheduled run');
        for (final MapEntry(key: platform, value: card) in cards.entries) {
          expect(card.renderParameters!['style'], style.toJson(), reason: '$platform\'s saved card is drawn with it');
        }
        await finish(tester);
      });
    }
  });

  testWidgets('@handle: the field shows each network\'s own; what is typed goes on every card that shows one; reset brings each network\'s own back',
      (tester) async {
    final (_, c) = await boot(tester);
    final accounts = await compose(tester, c);
    final own = {for (final e in accounts.entries) e.key: e.value.handle ?? e.value.displayName};
    final field = tester.widget<TextField>(key('handle'));
    for (final h in own.values) {
      expect(field.decoration!.hintText, contains(h), reason: 'the placeholder names every network\'s own handle');
    }
    // Mastodon's card leaves the @handle out.
    c.read(composerProvider.notifier).setTextCardHandle('mastodon', false);
    await settle(tester);
    expect(find.textContaining('Stays off on Mastodon'), findsOneWidget);

    await tester.ensureVisible(key('handle'));
    await tester.enterText(key('handle'), '  @neforum  ');
    await settle(tester);
    expect(c.read(composerProvider).textCardStyle.handle, '@neforum', reason: 'trimmed');
    expect(textCardBylineOf(placeholderOf(c, accounts['instagram']!)), '@neforum');
    expect(textCardBylineOf(placeholderOf(c, accounts['bluesky']!)), '@neforum');
    expect(textCardBylineOf(placeholderOf(c, accounts['mastodon']!)), isNull, reason: 'Show @handle off stays off');
    final (_, cards) = await save(tester, c, accounts);
    expect(textCardBylineOf(cards['instagram']!), '@neforum');
    expect(textCardBylineOf(cards['bluesky']!), '@neforum');
    expect(textCardBylineOf(cards['mastodon']!), isNull);

    await tester.tap(key('handle-reset'));
    await settle(tester);
    expect(c.read(composerProvider).textCardStyle.handle, isNull);
    expect(tester.widget<TextField>(key('handle')).controller!.text, isEmpty);
    // Each network's own again: drawn by its preview, not recorded on the
    // stand-in (as 1.3.4's stand-ins).
    for (final p in ['instagram', 'bluesky']) {
      expect(textCardBylineOf(placeholderOf(c, accounts[p]!)), isNull);
      final drawn = tester.widget<TextCardView>(find.descendant(of: find.byKey(ValueKey('text-card-preview-$p')), matching: find.byType(TextCardView)));
      expect(drawn.byline, own[p], reason: '$p draws its own handle');
    }
    // Clearing the field by hand does the same.
    await tester.enterText(key('handle'), '@again');
    await settle(tester);
    await tester.enterText(key('handle'), '');
    await settle(tester);
    expect(c.read(composerProvider).textCardStyle.handle, isNull);
    await finish(tester);
  });

  testWidgets('short by default: the @handle field shows, the rest folds and says what is set, and the previews show under it (1440 x 900)',
      (tester) async {
    final (_, c) = await boot(tester, size: const Size(1440, 900));
    await compose(tester, c);
    expect(key('handle'), findsOneWidget);
    expect(key('text-size'), findsNothing, reason: 'folded on a classic card');
    expect(find.text('Size, colours, line spacing, place and margins'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Customize for')), findsWidgets,
        reason: 'a network\'s preview is still built under the master editor');
    c.read(composerProvider.notifier).setTextCardStyle(const TextCardStyle(margin: 120, textColor: 0xFFFFD60A, handlePosition: TextCardHandlePosition.topLeft));
    await settle(tester);
    expect(find.text('own colours · margins 120 px · handle styled'), findsOneWidget, reason: 'the fold says what is set');
    await finish(tester);
  });

  testWidgets('a restyled post opens with the controls unfolded', (tester) async {
    final (_, c) = await boot(tester);
    c.read(composerProvider.notifier).setTextCardStyle(const TextCardStyle(textSize: 1.3));
    await compose(tester, c);
    expect(key('text-size'), findsOneWidget);
    // Only a written @handle: still short.
    await finish(tester);
    final (_, c2) = await boot(tester);
    c2.read(composerProvider.notifier).setTextCardStyle(const TextCardStyle(handle: '@neforum'));
    await compose(tester, c2);
    expect(key('text-size'), findsNothing);
    expect(tester.widget<TextField>(key('handle')).controller!.text, '@neforum');
    await finish(tester);
  });

  testWidgets('"Reset handle and words" puts the classic card back on every network', (tester) async {
    final (_, c) = await boot(tester);
    final accounts = await compose(tester, c);
    c.read(composerProvider.notifier).setTextCardStyle(const TextCardStyle(textSize: 1.5, handle: '@neforum', margin: 140));
    await settle(tester);
    expect(tester.widget<TextField>(key('handle')).controller!.text, '@neforum', reason: 'the field follows a style set elsewhere');
    await tapKey(tester, 'reset');
    expect(c.read(composerProvider).textCardStyle, TextCardStyle.classic);
    for (final a in accounts.values) {
      expect(placeholderOf(c, a).renderParameters!.containsKey('style'), isFalse);
    }
    expect(tester.widget<TextField>(key('handle')).controller!.text, isEmpty);
    await finish(tester);
  });

  testWidgets('keyboard: Tab goes from the @handle field to the fold and on to the sliders; Enter, arrows and Space work them', (tester) async {
    final (_, c) = await boot(tester);
    await compose(tester, c);
    await tester.ensureVisible(key('handle'));
    await tester.tap(key('handle'));
    await tester.pump();
    // The next stop is "Style the words and the handle": Enter unfolds it.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(key('handle-size'), findsOneWidget, reason: 'unfolded by keyboard');
    // Then the @handle's size slider: the right arrow grows it.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, focusOf(tester, key('handle-size')), reason: 'the next stop is the slider just under the fold');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(c.read(composerProvider).textCardStyle.handleSize, greaterThan(1));
    // A chip by Space, a colour button by Enter (it opens the dialog).
    await tester.ensureVisible(key('position-top'));
    focusOf(tester, key('position-top')).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await settle(tester);
    expect(c.read(composerProvider).textCardStyle.textPosition, TextCardTextPosition.top);
    await tester.ensureVisible(key('text-colour'));
    focusOf(tester, key('text-colour')).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.byKey(const Key('card-colour-hex')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('card-colour-hex')), '#00FF88');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(c.read(composerProvider).textCardStyle.textColor, 0xFF00FF88, reason: 'Enter in the hex field uses the colour');
    await finish(tester);
  });

  testWidgets('a phone: the editor starts folded, opens on demand, and every control fits', (tester) async {
    final (_, c) = await boot(tester, size: const Size(390, 844));
    await compose(tester, c);
    await tester.tap(find.textContaining('Preview ('));
    await settle(tester);
    expect(find.byKey(const Key('text-card-master')), findsOneWidget);
    expect(key('handle'), findsNothing, reason: 'folded');
    await tester.tap(find.byKey(const Key('text-card-master-toggle')));
    await settle(tester);
    expect(key('handle'), findsOneWidget, reason: 'the @handle field shows as soon as the editor opens');
    await unfold(tester);
    for (final name in ['handle', 'handle-size', 'handle-corner-topRight', 'handle-colour', 'text-size', 'line-spacing', 'position-center', 'text-colour',
      'background-colour', 'margin', 'reset']) {
      expect(key(name), findsOneWidget, reason: name);
      await tester.ensureVisible(key(name));
      await tester.pump();
      final box = tester.getRect(key(name));
      expect(box.right, lessThanOrEqualTo(390), reason: '$name fits the screen');
    }
    await tester.ensureVisible(key('handle'));
    await tester.enterText(key('handle'), '@neforum');
    // The field scrolls itself into view as it is typed in; a tap during
    // that scroll is held back, on a device too.
    await settle(tester);
    await tapKey(tester, 'handle-corner-topRight');
    await arrows(tester, 'margin', LogicalKeyboardKey.arrowRight, 2);
    expect(c.read(composerProvider).textCardStyle, isA<TextCardStyle>().having((s) => s.handle, 'handle', '@neforum').having((s) => s.margin, 'margin', greaterThan(92)));
    expect(c.read(composerProvider).textCardStyle.handlePosition, TextCardHandlePosition.topRight);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('CI\'s window (940 x 760): open, the card beside the editor, nothing overflows', (tester) async {
    final (_, c) = await boot(tester, size: const Size(940, 760));
    await compose(tester, c);
    await tester.tap(find.textContaining('Preview ('));
    await settle(tester);
    expect(find.byKey(const Key('text-card-master-preview')), findsOneWidget, reason: 'open at this width');
    await tester.ensureVisible(key('handle'));
    await tester.pump();
    expect(tester.getTopLeft(key('handle')).dx, greaterThan(tester.getTopRight(find.byKey(const Key('text-card-master-preview'))).dx),
        reason: 'the editor beside the card');
    await unfold(tester);
    for (final name in ['handle', 'handle-corner-bottomRight', 'text-size', 'position-bottom', 'background-colour', 'margin', 'reset']) {
      await tester.ensureVisible(key(name));
      await tester.pump();
      expect(tester.getRect(key(name)).right, lessThanOrEqualTo(940), reason: name);
    }
    await arrows(tester, 'text-size', LogicalKeyboardKey.arrowRight, 2);
    await tapKey(tester, 'position-bottom');
    expect(c.read(composerProvider).textCardStyle.textSize, greaterThan(1));
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('one network: "Text & @handle…" under its card opens the same editor, live on its card', (tester) async {
    final (_, c) = await boot(tester);
    final accounts = await compose(tester, c, platforms: ['instagram']);
    expect(find.byKey(const Key('text-card-master')), findsNothing, reason: 'one card: no master editor');
    await tester.ensureVisible(find.byKey(const Key('text-card-text-style')));
    await tester.tap(find.byKey(const Key('text-card-text-style')));
    await settle(tester);
    expect(find.text('Text & @handle'), findsOneWidget);
    expect(find.byKey(const ValueKey('text-card-picture-instagram')), findsOneWidget, reason: 'the network\'s card, live in the sheet');
    await tester.enterText(find.byKey(const Key('text-card-style-handle')), '@neforum');
    await tester.tap(find.byKey(const Key('text-card-style-position-top')));
    await settle(tester);
    final placeholder = placeholderOf(c, accounts['instagram']!);
    expect(textCardBylineOf(placeholder), '@neforum');
    expect(textCardStyleOf(placeholder).textPosition, TextCardTextPosition.top);
    await tester.tap(find.byTooltip('Close'));
    await settle(tester);
    expect(find.text('Text & @handle'), findsNothing);
    await finish(tester);
  });

  testWidgets('"How it works" opens the text card guide in the app', (tester) async {
    final (_, c) = await boot(tester);
    await compose(tester, c);
    await tapKey(tester, 'guide');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle(tester);
    expect(find.textContaining('Text cards: your @handle and the look of the words'), findsWidgets);
    expect(find.textContaining('Handle on every card'), findsWidgets, reason: 'the steps name the controls');
    await finish(tester);
  });

  testWidgets('a theme pill means the theme\'s colours: the card\'s own colours go', (tester) async {
    final (_, c) = await boot(tester);
    await compose(tester, c);
    c.read(composerProvider.notifier).setTextCardStyle(const TextCardStyle(textColor: 0xFFFFD60A, backgroundColor: 0xFF3A0CA3, margin: 120));
    await settle(tester);
    final light = find.descendant(of: find.byKey(const ValueKey('text-card-style-master')), matching: find.text('Black on white'));
    await tester.ensureVisible(light);
    await tester.tap(light);
    await settle(tester);
    final s = c.read(composerProvider);
    expect(s.textCardTheme, TextCardTheme.light);
    expect(s.textCardStyle.textColor, isNull);
    expect(s.textCardStyle.backgroundColor, isNull);
    expect(s.textCardStyle.margin, 120, reason: 'the rest of the style stays');
    await finish(tester);
  });

  testWidgets('what differs and "Make them match" still work with a restyled card; each network\'s own controls too', (tester) async {
    final (_, c) = await boot(tester);
    final accounts = await compose(tester, c);
    c.read(composerProvider.notifier)
      ..setTextCardStyle(const TextCardStyle(handle: '@neforum', textSize: 1.2))
      ..setTextCardBranded('bluesky', false);
    await settle(tester);
    expect(find.textContaining('no signature on Bluesky'), findsOneWidget);
    // Bluesky's own signature pill, under its preview, puts it back.
    final own = find.descendant(of: find.byKey(const ValueKey('text-card-style-bluesky')), matching: find.byKey(const Key('text-card-signature')));
    await tester.ensureVisible(own);
    await tester.pump();
    await tester.tap(own);
    await settle(tester);
    expect(textCardBrandedOf(placeholderOf(c, accounts['bluesky']!)), isTrue);
    expect(find.textContaining('Not the same everywhere'), findsNothing);
    // A difference again, and one tap makes them match.
    c.read(composerProvider.notifier).setTextCardHandle('mastodon', false);
    await settle(tester);
    expect(find.textContaining('no @handle on Mastodon'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('text-card-match')));
    await tester.tap(find.byKey(const Key('text-card-match')));
    await settle(tester);
    expect({for (final a in accounts.values) textCardBylineOf(placeholderOf(c, a))}, {'@neforum'}, reason: 'every card shows the written @handle');
    expect(c.read(composerProvider).textCardStyle, const TextCardStyle(handle: '@neforum', textSize: 1.2), reason: 'matching leaves the style');
    await finish(tester);
  });

  testWidgets('saved, reopened, scheduled: the style comes back, is no network\'s own change, and the scheduled run keeps the cards',
      (tester) async {
    final (s, c) = await boot(tester);
    final accounts = await compose(tester, c);
    const style = TextCardStyle(handle: '@neforum', textSize: 1.25, textColor: 0xFFFFD60A, handlePosition: TextCardHandlePosition.topRight);
    c.read(composerProvider.notifier)
      ..setTextCardStyle(style)
      ..setSchedule(DateTime.now().add(const Duration(days: 2)));
    await settle(tester);
    final (post, cards) = await save(tester, c, accounts, schedule: true);
    expect(post.status, PostStatus.scheduled);
    // Edited again: the composer gets the style back; no preview says
    // "Customized" for it.
    c.read(composerProvider.notifier).load(post);
    await settle(tester);
    final loaded = c.read(composerProvider);
    expect(loaded.textCardStyle, style);
    expect(loaded.overrides.values.where((o) => o.extra.containsKey(kTextCardStyleKey)), isEmpty);
    expect(find.text('Customized'), findsNothing);
    // The scheduled run: every choice read back from the post, nothing made
    // again; and from the synced copy too.
    for (final copy in [post, Post.fromJson(post.toJson())]) {
      final run = (await tester.runAsync(() => attachTextCards(s, copy, s.settings)))!;
      expect(run.media.where(isRenderedTextCard).map((m) => m.id).toSet(), {for (final m in cards.values) m.id});
    }
    await finish(tester);
  });
}
