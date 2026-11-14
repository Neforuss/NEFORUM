// 1.4.3: symbols. The character panel's Symbols, Kaomoji and Text styles tabs:
// search in every tab, recents and favourites, the device check, the
// screen-reader note, no overflow at phone size, and the real composer: the
// insert lands at the caret, styled text replaces the selection, and a
// network pushed over its limit says so while the others are untouched.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/emoji_text.dart';
import 'package:neforum_app/media/glyph_support.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/character_catalog.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/editor_card.dart';
import 'package:neforum_app/ui/compose/emoji_catalog.dart';
import 'package:neforum_app/ui/compose/emoji_sheet.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

Map<String, Object?> _json(String name) => jsonDecode(File('../../packages/neforum_core/assets/characters/$name').readAsStringSync()) as Map<String, Object?>;

final CharacterCatalog catalog = BundledCharacterCatalog.fromJson(symbols: _json('symbols.json'), textStyles: _json('text_styles.json'), keywords: _json('keywords.json'));

Future<AppStorage> _tempStorage(Map<String, Object> settings) async {
  final dir = Directory.systemTemp.createTempSync('nf-chars-');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // Still in use on Windows; the system cleans it up.
    }
  });
  final storage = await openAppStorage(overrideDir: dir.path);
  await storage.writeJson('settings.json', {'onboarded': true, 'updateCheck': 'off', ...settings});
  return storage;
}

class _Panel {
  late ProviderContainer container;
  final List<String> picks = [];
  final List<String> styled = [];
  String selection = '';
}

Future<_Panel> _pump(WidgetTester t, {Size size = const Size(360, 640), double scale = 1, Map<String, Object> settings = const {}, CharacterTab? tab}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final storage = (await t.runAsync(() => _tempStorage(settings)))!;
  final s = (await t.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
  final out = _Panel();
  await t.pumpWidget(ProviderScope(
    overrides: [
      servicesProvider.overrideWithValue(s),
      characterCatalogProvider.overrideWith((ref) async => catalog),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AccentChoice.neforum),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: Scaffold(
        body: Builder(builder: (context) {
          out.container = ProviderScope.containerOf(context);
          return EmojiPanel(onPick: out.picks.add, onClose: () {}, selection: () => out.selection, onStyle: out.styled.add);
        }),
      ),
    ),
  ));
  await _settle(t);
  if (tab != null) {
    await t.tap(find.byKey(Key('character-tab-${tab.name}')));
    await _settle(t);
  }
  return out;
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _search(WidgetTester t, String q) async {
  await t.enterText(find.byKey(const Key('emoji-search')), q);
  await _settle(t);
}

Finder _symbol(String c) => find.byKey(ValueKey('symbol-$c'));
Finder _text(String c) => find.byKey(ValueKey('text-cell-$c'));

void main() {
  setUp(() {
    debugResetCharacterPanel();
    GlyphSupport.debugReset();
    GlyphSupport.debugProbe = (_) => true;
    EmojiSupport.debugReset();
    EmojiSupport.debugProbe = (_) => EmojiDraw.whole;
    debugResetEmojiDeviceSupport();
  });
  tearDown(() {
    GlyphSupport.debugReset();
    EmojiSupport.debugReset();
    debugResetEmojiDeviceSupport();
  });

  group('the data', () {
    testWidgets('ships in the app under neforum_core and reads through the bundle', (t) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final loaded = (await t.runAsync(() => container.read(characterCatalogProvider.future)))!;
      expect(loaded.unicodeVersion, catalog.unicodeVersion);
      expect(loaded.groups(CharacterTab.symbols).length, catalog.groups(CharacterTab.symbols).length);
      expect(loaded.entryFor('♥')?.altCode, '3');
    });

    testWidgets('the Unicode licence is in the licence page', (t) async {
      registerCharacterDataLicense();
      final entries = (await t.runAsync(() => LicenseRegistry.licenses.toList()))!;
      final unicode = entries.where((e) => e.packages.contains('Unicode Character Database')).toList();
      expect(unicode, hasLength(1));
      final text = unicode.single.paragraphs.map((p) => p.text).join('\n');
      expect(text, contains('UNICODE LICENSE V3'));
      expect(text, contains('CLDR'));
    });

    test('emoji search also uses CLDR\'s words', () {
      expect(searchEmoji('celebration').map((e) => e.emoji), isNot(contains('🎉')), reason: 'not in its names');
      expect(searchEmoji('celebration', keywords: catalog.keywordsFor).map((e) => e.emoji), contains('🎉'));
    });

    test('favourites: newest first, a second star takes it out, capped', () {
      expect(withFavouriteToggled(['a'], 'b'), ['b', 'a']);
      expect(withFavouriteToggled(['b', 'a'], 'b'), ['a']);
      final full = [for (var i = 0; i < kCharacterFavouritesMax; i++) '$i'];
      expect(withFavouriteToggled(full, 'x'), hasLength(kCharacterFavouritesMax));
    });

    test('favourites travel with Sync and Move; recents stay on the device', () {
      const s = AppSettings(characterFavourites: ['★'], emojiRecents: ['★']);
      expect(kExportableSettings, contains('characterFavourites'));
      expect(syncedSettings(s)['characterFavourites'], ['★']);
      expect(syncedSettings(const AppSettings())['characterFavourites'], isEmpty, reason: 'a reset to none travels too');
      expect(withImportedSettings(const AppSettings(), {'characterFavourites': ['☆']}).characterFavourites, ['☆']);
      expect(syncedSettings(s).containsKey('emojiRecents'), isFalse);
      expect(AppSettings.fromJson(s.toJson()).characterFavourites, ['★']);
      expect(AppSettings.fromJson(const {'characterFavourites': [1, '', 'a']}).characterFavourites, ['a']);
    });
  });

  group('the panel', () {
    for (final tab in CharacterTab.values) {
      for (final (size, scale) in const [(Size(360, 640), 1.0), (Size(360, 640), 1.5), (Size(348, 420), 1.0), (Size(360, 340), 1.0)]) {
        testWidgets('${tab.name}: no overflow at ${size.width.toInt()} x ${size.height.toInt()}, text scale $scale', (t) async {
          await _pump(t, size: size, scale: scale, tab: tab);
          expect(t.takeException(), isNull);
          await _search(t, 'star');
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox.shrink());
        });
      }
    }

    testWidgets('every tab draws after another, with no error', (t) async {
      final p = await _pump(t, tab: CharacterTab.symbols);
      p.selection = '';
      for (final tab in CharacterTab.values) {
        await t.tap(find.byKey(Key('character-tab-${tab.name}')));
        await _settle(t);
        expect(t.takeException(), isNull);
      }
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('Symbols', () {
    testWidgets('opens on Popular; a tap reports the character', (t) async {
      final p = await _pump(t, tab: CharacterTab.symbols);
      expect(_symbol('★'), findsOneWidget);
      await t.tap(_symbol('★'));
      await t.pump();
      expect(p.picks, ['★']);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('search by name, by CLDR word, by code point and by Alt code', (t) async {
      await _pump(t, tab: CharacterTab.symbols);
      await _search(t, 'black heart suit');
      expect(_symbol('♥'), findsOneWidget);
      await _search(t, 'u+2665');
      expect(_symbol('♥'), findsOneWidget);
      await _search(t, 'alt+3');
      expect(_symbol('♥'), findsOneWidget);
      await _search(t, 'trademark');
      expect(_symbol('™'), findsOneWidget);
      await _search(t, 'zzqqxx');
      expect(find.text('No symbols found'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a set chip and a whole Unicode block from the menu, with its sections', (t) async {
      await _pump(t, tab: CharacterTab.symbols);
      await t.ensureVisible(find.byKey(const Key('symbols-group-hearts')));
      await _settle(t);
      await t.tap(find.byKey(const Key('symbols-group-hearts')));
      await _settle(t);
      expect(_symbol('♡'), findsOneWidget);
      await t.tap(find.byKey(const Key('symbols-groups')));
      await _settle(t);
      await t.ensureVisible(find.text('Arrows').last);
      await _settle(t);
      await t.tap(find.text('Arrows').last);
      await _settle(t);
      expect(_symbol('←'), findsOneWidget);
      expect(find.text('Simple arrows'), findsOneWidget, reason: "NamesList's section title");
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('long press stars it, right click unstars it, the details bar names it, and Favourites lists it', (t) async {
      final p = await _pump(t, tab: CharacterTab.symbols);
      await t.longPress(_symbol('★'));
      await _settle(t);
      expect(p.container.read(settingsProvider).characterFavourites, ['★']);
      expect(find.descendant(of: _symbol('★'), matching: find.byIcon(Icons.star_rounded)), findsOneWidget);
      await t.tap(find.byKey(const Key('symbols-group-favourites')));
      await _settle(t);
      expect(_symbol('★'), findsOneWidget);
      await t.tap(_symbol('★'), buttons: kSecondaryButton);
      await _settle(t);
      expect(p.container.read(settingsProvider).characterFavourites, isEmpty);
      // The keyboard: focus a cell, the details bar names it, its star keeps it.
      await t.tap(find.byKey(const Key('symbols-group-popular')));
      await _settle(t);
      Focus.of(t.element(find.descendant(of: _symbol('™'), matching: find.byType(Center)))).requestFocus();
      await _settle(t);
      expect(find.descendant(of: find.byKey(const Key('symbols-details')), matching: find.text('Trade mark sign')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('symbols-details')), matching: find.textContaining('U+2122')), findsOneWidget);
      await t.tap(find.byKey(const Key('symbols-details-star')));
      await _settle(t);
      expect(p.container.read(settingsProvider).characterFavourites, ['™']);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('what the device cannot draw is not in the grid; search shows it as a plain icon with a note', (t) async {
      GlyphSupport.debugProbe = (c) => c != '★';
      final p = await _pump(t, tab: CharacterTab.symbols);
      expect(_symbol('☆'), findsOneWidget);
      expect(_symbol('★'), findsNothing);
      await _search(t, 'black star');
      expect(_symbol('★'), findsOneWidget);
      expect(find.descendant(of: _symbol('★'), matching: find.byType(Text)), findsNothing);
      expect(find.descendant(of: _symbol('★'), matching: find.byIcon(Icons.image_not_supported_outlined)), findsOneWidget);
      expect(find.textContaining('cannot show'), findsOneWidget);
      await t.tap(_symbol('★'));
      await t.pump();
      expect(p.picks, ['★'], reason: 'it still goes in');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('recent characters are shared by the tabs, with kaomoji', (t) async {
      await _pump(t, tab: CharacterTab.symbols, settings: {
        'emojiRecents': ['★', '¯\\_(ツ)_/¯', '😀'],
      });
      expect(find.byKey(const Key('symbols-group-recent')), findsOneWidget);
      expect(_symbol('★'), findsOneWidget);
      expect(_symbol('¯\\_(ツ)_/¯'), findsOneWidget);
      await t.tap(find.byKey(const Key('character-tab-emoji')));
      await _settle(t);
      expect(find.byKey(const ValueKey('emoji-★')), findsOneWidget, reason: 'one character: the Emoji tab shows it too');
      expect(find.byKey(const ValueKey('emoji-¯\\_(ツ)_/¯')), findsNothing, reason: 'a kaomoji is no grid cell');
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('Kaomoji', () {
    testWidgets('groups, a tap, and search', (t) async {
      final p = await _pump(t, tab: CharacterTab.kaomoji);
      await t.tap(find.byKey(const Key('kaomoji-groups')));
      await _settle(t);
      await t.ensureVisible(find.text('Shrug').last);
      await _settle(t);
      await t.tap(find.text('Shrug').last);
      await _settle(t);
      await t.tap(_text('¯\\_(ツ)_/¯'));
      await t.pump();
      expect(p.picks, ['¯\\_(ツ)_/¯']);
      await _search(t, 'table flip');
      expect(_text('(╯°□°）╯︵ ┻━┻'), findsOneWidget);
      await _search(t, 'bear');
      expect(_text('ʕ•ᴥ•ʔ'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the builder makes what the user picks, and inserts it', (t) async {
      final p = await _pump(t, tab: CharacterTab.kaomoji);
      await t.tap(find.byKey(const Key('kaomoji-group-build')));
      await _settle(t);
      await t.tap(find.byKey(const Key('kaomoji-build-Face-2')));
      await t.tap(find.byKey(const Key('kaomoji-build-Arms-0')));
      await _settle(t);
      await t.ensureVisible(find.byKey(const Key('kaomoji-build-Mouth-1')));
      await t.tap(find.byKey(const Key('kaomoji-build-Mouth-1')));
      await _settle(t);
      expect(t.widget<Text>(find.byKey(const Key('kaomoji-build-preview'))).data, 'ʕ^ᴥ^ʔ');
      await t.tap(find.byKey(const Key('kaomoji-build-insert')));
      await t.pump();
      expect(p.picks, ['ʕ^ᴥ^ʔ']);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a kaomoji with a character this device lacks is left out of its group', (t) async {
      GlyphSupport.debugProbe = (c) => c != 'ᴥ';
      await _pump(t, tab: CharacterTab.kaomoji);
      await t.tap(find.byKey(const Key('kaomoji-groups')));
      await _settle(t);
      await t.ensureVisible(find.text('Bears').last);
      await _settle(t);
      await t.tap(find.text('Bears').last);
      await _settle(t);
      expect(_text('ʕ•ᴥ•ʔ'), findsNothing);
      expect(_text('ʕノ•ᴥ•ʔノ ︵ ┻━┻'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('Text styles', () {
    testWidgets('the screen-reader note, then the selection styled; a tap puts it in place', (t) async {
      final p = await _pump(t, tab: CharacterTab.textStyles);
      expect(find.byKey(const Key('text-styles-note')), findsOneWidget);
      expect(find.textContaining('Screen readers'), findsOneWidget);
      p.selection = 'Hello';
      await t.tap(find.byKey(const Key('character-tab-emoji')));
      await _settle(t);
      await t.tap(find.byKey(const Key('character-tab-textStyles')));
      await _settle(t);
      expect(find.byKey(const Key('text-styles-selection')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('text-style-bold')));
      await t.pump();
      expect(p.styled, ['\u{1D407}\u{1D41E}\u{1D425}\u{1D425}\u{1D428}']);
      expect(p.picks, isEmpty, reason: 'styled text is not a recent character');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('with nothing selected: type here, and nothing is styled until a tap', (t) async {
      final p = await _pump(t, tab: CharacterTab.textStyles);
      await t.tap(find.byKey(const ValueKey('text-style-bold')));
      await t.pump();
      expect(p.styled, isEmpty, reason: 'no text yet: the sample is only shown');
      await t.enterText(find.byKey(const Key('text-styles-input')), 'hi');
      await _settle(t);
      await t.scrollUntilVisible(find.byKey(const ValueKey('text-style-fullwidth')), 200, scrollable: find.byType(Scrollable).last);
      await t.tap(find.byKey(const ValueKey('text-style-fullwidth')));
      await t.pump();
      expect(p.styled, ['ｈｉ']);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('search finds styles by what people call them', (t) async {
      await _pump(t, tab: CharacterTab.textStyles);
      await _search(t, 'gothic');
      expect(find.byKey(const ValueKey('text-style-fraktur')), findsOneWidget);
      expect(find.byKey(const ValueKey('text-style-bold')), findsNothing);
      await _search(t, 'zzqq');
      expect(find.text('No styles found'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a style this device cannot draw is not offered', (t) async {
      final squares = catalog.textStyles.apply(TextStyleKind.squaredNegative, 'A');
      GlyphSupport.debugProbe = (c) => c != squares;
      await _pump(t, tab: CharacterTab.textStyles);
      await _search(t, 'square');
      expect(find.byKey(const ValueKey('text-style-squared')), findsOneWidget);
      expect(find.byKey(const ValueKey('text-style-squaredNegative')), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('in the composer', () {
    ConnectedAccount account(String platformId) => ConnectedAccount(
          id: 'acct-$platformId',
          platformId: platformId,
          tier: builtinRegistry().descriptor(platformId)!.defaultTier,
          displayName: platformId,
          createdAt: DateTime.utc(2026, 10, 1),
        );

    Future<({ProviderContainer container, TextEditingController controller, FocusNode focus})> composer(WidgetTester t, List<String> networks, {Map<String, Object> settings = const {}}) async {
      t.view.physicalSize = const Size(1400, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final storage = (await t.runAsync(() => _tempStorage(settings)))!;
      final s = (await t.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final accounts = [for (final n in networks) account(n)];
      late ProviderContainer container;
      await t.pumpWidget(ProviderScope(
        overrides: [
          servicesProvider.overrideWithValue(s),
          isDemoProvider.overrideWithValue(false),
          accountsProvider.overrideWith((ref) => Stream.value(accounts)),
          characterCatalogProvider.overrideWith((ref) async => catalog),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Scaffold(
            body: Builder(builder: (context) {
              container = ProviderScope.containerOf(context);
              return SingleChildScrollView(child: EditorCard(focusNode: focus));
            }),
          ),
        ),
      ));
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 100));
      container.read(composerProvider.notifier).reset(keepTargets: false);
      container.read(composerProvider.notifier).selectAccounts([for (final a in accounts) a.id]);
      await t.pump();
      final field = find.descendant(of: find.byType(EditorCard), matching: find.byType(TextField)).first;
      await t.tap(field);
      await t.pump();
      return (container: container, controller: t.widget<TextField>(field).controller!, focus: focus);
    }

    Future<void> openPanel(WidgetTester t, CharacterTab tab) async {
      await t.tap(find.byKey(const Key('emoji-button')).last);
      await _settle(t);
      await t.tap(find.byKey(Key('character-tab-${tab.name}')));
      await _settle(t);
    }

    testWidgets('a symbol goes in at the caret, mid-text, and the caret and focus stay', (t) async {
      final h = await composer(t, ['mastodon']);
      h.controller.value = const TextEditingValue(text: 'I  you', selection: TextSelection.collapsed(offset: 2));
      await _settle(t);
      await openPanel(t, CharacterTab.symbols);
      await t.tap(_symbol('♥'));
      await _settle(t);
      expect(h.controller.text, 'I ♥ you');
      expect(h.controller.selection, const TextSelection.collapsed(offset: 3));
      expect(h.focus.hasFocus, isTrue, reason: 'the panel never takes the focus');
      expect(h.container.read(settingsProvider).emojiRecents.first, '♥', reason: 'a recent character, shared by the tabs');
      expect(h.container.read(composerProvider).text, 'I ♥ you', reason: "the field's own onChanged ran");
      // Escape closes it; the caret is where it was.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(t);
      expect(find.byKey(const Key('emoji-panel')), findsNothing);
      expect(h.controller.selection, const TextSelection.collapsed(offset: 3));
      await t.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('a text style replaces the selection, the caret after it, and is not a recent character', (t) async {
      final h = await composer(t, ['mastodon']);
      h.controller.value = const TextEditingValue(text: 'say hello now', selection: TextSelection(baseOffset: 4, extentOffset: 9));
      await _settle(t);
      await openPanel(t, CharacterTab.textStyles);
      expect(find.textContaining('Styles your selection: "hello"'), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('text-style-script')));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('text-style-script')));
      await _settle(t);
      final script = catalog.textStyles.apply(TextStyleKind.script, 'hello');
      expect(h.controller.text, 'say $script now');
      expect(h.controller.selection, TextSelection.collapsed(offset: 4 + script.length));
      expect(h.container.read(settingsProvider).emojiRecents, isEmpty);
      await t.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('pushed over X\'s limit: inserted anyway, X says so, Mastodon and Bluesky have room', (t) async {
      final h = await composer(t, ['x', 'mastodon', 'bluesky'], settings: {'overflow': OverflowStrategy.error.name});
      final text = 'a' * 270;
      h.controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
      await _settle(t);
      await openPanel(t, CharacterTab.textStyles);
      await t.enterText(find.byKey(const Key('text-styles-input')), 'NEFORUMXYZ');
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('text-style-bold')));
      await _settle(t);
      expect(h.controller.text.runes.length, 280, reason: 'the insert was not blocked');
      final budget = find.byKey(const Key('character-budget'));
      expect(budget, findsOneWidget);
      final line = t.widget<Text>(find.descendant(of: budget, matching: find.byType(Text))).textSpan!.toPlainText();
      final xName = builtinRegistry().descriptor('x')!.compactName;
      expect(line, contains('$xName 10 over'));
      expect(line, contains('Bluesky 20 left'));
      final previews = h.container.read(composerPreviewsProvider);
      final x = previews.singleWhere((p) => p.descriptor.id == 'x');
      expect(x.variant.issues.map((i) => i.message), contains('Text is 290/280 characters for ${builtinRegistry().descriptor('x')!.name}'));
      for (final id in ['mastodon', 'bluesky']) {
        final v = previews.singleWhere((p) => p.descriptor.id == id).variant;
        expect(v.issues.where((i) => i.code == 'text.too_long'), isEmpty, reason: id);
      }
      await t.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });
}
