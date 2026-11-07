// The emoji sheet: search, recent emoji, skin tones, no overflow at phone size,
// what a device cannot draw, and that its settings stay on the device and go with
// Delete everything.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/emoji_text.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/emoji_catalog.dart';
import 'package:neforum_app/ui/compose/emoji_sheet.dart';
import 'package:neforum_app/ui/settings/data_section.dart';
import 'package:unicode_emojis/unicode_emojis.dart' show Category, Emoji, UnicodeEmojis;

const String grin = '\u{1F600}';

Future<AppStorage> _tempStorage(Map<String, Object> settings) async {
  final dir = Directory.systemTemp.createTempSync('nf-emoji-');
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

class _Sheet {
  late ProviderContainer container;
  final List<String> picks = [];
}

Future<_Sheet> _pump(WidgetTester t, {Size size = const Size(360, 640), double scale = 1, Map<String, Object> settings = const {}, Brightness brightness = Brightness.light}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final storage = (await t.runAsync(() => _tempStorage(settings)))!;
  final s = (await t.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
  final out = _Sheet();
  await t.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(s)],
    child: MaterialApp(
      theme: buildTheme(brightness, AccentChoice.neforum),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: Scaffold(
        body: Builder(builder: (context) {
          out.container = ProviderScope.containerOf(context);
          return EmojiPanel(onPick: out.picks.add, onClose: () {});
        }),
      ),
    ),
  ));
  await _settle(t);
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await _settle(t);
  return out;
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUp(() {
    EmojiSupport.debugReset();
    EmojiSupport.debugProbe = (_) => EmojiDraw.whole;
    debugResetEmojiDeviceSupport();
  });
  tearDown(() {
    EmojiSupport.debugReset();
    debugResetEmojiDeviceSupport();
  });

  group('the data', () {
    test('holds current emoji, in order, with skin tones', () {
      expect(allEmoji.length, greaterThan(1800));
      expect(allEmoji.first.emoji, grin);
      expect(emojiOf(Category.flags).length, greaterThan(200));
      expect(UnicodeEmojis.allEmojis.where((e) => e.addedIn == '16.0'), isNotEmpty, reason: 'recent emoji, the reason for this package');
    });

    test('search finds by short name, word start and category, with the best fit first', () {
      expect(searchEmoji('tada').first.emoji, '\u{1F389}');
      expect(searchEmoji('heart').first.shortName, 'heart');
      expect(searchEmoji('thumbsup').first.emoji, '\u{1F44D}');
      expect(searchEmoji('+1').first.emoji, '\u{1F44D}');
      expect(searchEmoji('blue heart').map((e) => e.emoji), contains('\u{1F499}'));
      expect(searchEmoji('flags').length, greaterThan(200));
      expect(searchEmoji('zzzzqq'), isEmpty);
      expect(searchEmoji('   '), isEmpty);
    });

    test('a tone picks the variation with that one tone', () {
      final wave = searchEmoji('wave').firstWhere((e) => e.emoji == '\u{1F44B}');
      expect(emojiAtTone(wave, 0), '\u{1F44B}');
      expect(emojiAtTone(wave, 3), '\u{1F44B}\u{1F3FD}');
      expect(emojiAtTone(allEmoji.first, 3), grin, reason: 'an emoji with no tones stays itself');
    });

    test('a tone on two people puts it on both', () {
      final Emoji pair = allEmoji.firstWhere((e) => (e.skinVariations?.length ?? 0) > 5);
      final toned = emojiAtTone(pair, 5);
      final tones = toned.runes.where((r) => r >= 0x1F3FB && r <= 0x1F3FF).toSet();
      expect(tones, {0x1F3FF});
    });

    test('recent emoji: newest first, once each, capped', () {
      expect(withRecentEmoji(['a', 'b'], 'b'), ['b', 'a']);
      expect(withRecentEmoji(['a'], 'c'), ['c', 'a']);
      final full = [for (var i = 0; i < kEmojiRecentsMax; i++) '$i'];
      final next = withRecentEmoji(full, 'x');
      expect(next.length, kEmojiRecentsMax);
      expect(next.first, 'x');
      expect(next.last, '${kEmojiRecentsMax - 2}');
    });
  });

  group('the sheet', () {
    for (final (size, scale) in const [(Size(360, 640), 1.0), (Size(360, 640), 1.5), (Size(348, 420), 1.0), (Size(360, 340), 1.0)]) {
      testWidgets('no overflow at ${size.width.toInt()} x ${size.height.toInt()}, text scale $scale', (t) async {
        final s = await _pump(t, size: size, scale: scale);
        expect(t.takeException(), isNull);
        await t.enterText(find.byKey(const Key('emoji-search')), 'heart');
        await _settle(t);
        expect(t.takeException(), isNull);
        await t.tap(find.byKey(const Key('emoji-tone-3')));
        await _settle(t);
        expect(t.takeException(), isNull);
        expect(s.container.read(settingsProvider).emojiSkinTone, 3);
        await t.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('dark theme has no overflow either', (t) async {
      await _pump(t, brightness: Brightness.dark);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('search narrows the grid and a pick reports the emoji', (t) async {
      final s = await _pump(t);
      expect(find.byKey(const ValueKey('emoji-1F389')), findsNothing, reason: 'a party popper is not a smiley');
      await t.enterText(find.byKey(const Key('emoji-search')), 'tada');
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('emoji-1F389')));
      await t.pump();
      expect(s.picks, ['\u{1F389}']);
      await t.enterText(find.byKey(const Key('emoji-search')), 'zzzzqq');
      await _settle(t);
      expect(find.text('No emoji found'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('categories switch the grid', (t) async {
      await _pump(t);
      expect(find.byKey(const ValueKey('emoji-1F600')), findsOneWidget);
      await t.tap(find.byKey(const Key('emoji-category-animalsAndNature')));
      await _settle(t);
      expect(find.byKey(const ValueKey('emoji-1F600')), findsNothing);
      expect(find.byKey(const ValueKey('emoji-1F435')), findsOneWidget, reason: 'the monkey face leads Animals');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('skin tone is one tap on the row, not a long press, and every toned emoji follows', (t) async {
      final s = await _pump(t);
      await t.tap(find.byKey(const Key('emoji-category-peopleAndBody')));
      await _settle(t);
      await t.tap(find.byKey(const Key('emoji-tone-4')));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('emoji-1F44B')));
      await t.pump();
      expect(s.picks, ['\u{1F44B}\u{1F3FE}']);
      expect(find.text('\u{1F44B}\u{1F3FE}'), findsOneWidget, reason: 'the grid shows what goes in');
      expect(s.container.read(settingsProvider).emojiSkinTone, 4);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the chosen tone can be told without colour, by a mark and to a screen reader', (t) async {
      final handle = t.ensureSemantics();
      await _pump(t, settings: {'emojiSkinTone': 2});
      expect(find.descendant(of: find.byKey(const Key('emoji-tone-2')), matching: find.byIcon(Icons.check_rounded)), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('emoji-tone-1')), matching: find.byIcon(Icons.check_rounded)), findsNothing);
      expect(find.bySemanticsLabel('Medium light skin tone'), findsOneWidget);
      handle.dispose();
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('recent emoji come first when there are any, and hold still while picking', (t) async {
      final s = await _pump(t, settings: {
        'emojiRecents': ['\u{1F389}', grin]
      });
      expect(find.byKey(const ValueKey('emoji-\u{1F389}')), findsOneWidget);
      expect(find.byKey(const ValueKey('emoji-$grin')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('emoji-$grin')));
      await t.pump();
      expect(s.picks, [grin]);
      expect(t.getTopLeft(find.byKey(const ValueKey('emoji-\u{1F389}'))).dx, lessThan(t.getTopLeft(find.byKey(const ValueKey('emoji-$grin'))).dx));
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('with no recent emoji there is no recent tab', (t) async {
      await _pump(t);
      expect(find.byKey(const Key('emoji-category-recent')), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('what the device cannot draw', () {
    // Windows 10: nothing from Emoji 14 on, flags as letters.
    EmojiDraw windows10(String cluster) {
      final first = cluster.runes.first;
      if (first >= 0x1F1E6 && first <= 0x1F1FF) return EmojiDraw.parts;
      final known = emojiByGlyph(cluster);
      final version = double.tryParse(known?.addedIn ?? '') ?? 0;
      return version >= 14 ? EmojiDraw.missing : EmojiDraw.whole;
    }

    testWidgets('newer emoji are not in the grid, so it shows no blank boxes', (t) async {
      EmojiSupport.debugProbe = windows10;
      await _pump(t);
      expect(find.byKey(const ValueKey('emoji-1FAE0')), findsNothing, reason: 'melting face, Emoji 14');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('search still finds them, with a plain icon and a note, and they can go in', (t) async {
      EmojiSupport.debugProbe = windows10;
      final s = await _pump(t);
      await t.enterText(find.byKey(const Key('emoji-search')), 'melting');
      await _settle(t);
      final tile = find.byKey(const ValueKey('emoji-1FAE0'));
      expect(find.descendant(of: tile, matching: find.byType(Text)), findsNothing, reason: 'no glyph drawn');
      expect(find.descendant(of: tile, matching: find.byIcon(Icons.image_not_supported_outlined)), findsOneWidget);
      expect(find.textContaining('cannot show'), findsOneWidget);
      await t.tap(tile);
      await t.pump();
      expect(s.picks, ['\u{1FAE0}']);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('flags stay, with a note that they look like letters here', (t) async {
      EmojiSupport.debugProbe = windows10;
      await _pump(t);
      await t.tap(find.byKey(const Key('emoji-category-flags')));
      await _settle(t);
      expect(find.textContaining('Flags look like letters'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('no emoji font at all: says so, and draws no boxes', (t) async {
      EmojiSupport.debugProbe = (_) => EmojiDraw.missing;
      await _pump(t);
      expect(find.textContaining('no emoji font'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('settings', () {
    test('stay on the device', () {
      const s = AppSettings(emojiRecents: [grin], emojiSkinTone: 2);
      for (final key in ['emojiRecents', 'emojiSkinTone']) {
        expect(kDeviceOnlySettings.containsKey(key), isTrue, reason: key);
        expect(kExportableSettings.contains(key), isFalse, reason: key);
        expect(exportableSettings(s).containsKey(key), isFalse, reason: key);
        expect(syncedSettings(s).containsKey(key), isFalse, reason: key);
      }
      final imported = withImportedSettings(const AppSettings(), {'emojiRecents': [grin], 'emojiSkinTone': 2});
      expect(imported.emojiRecents, isEmpty);
      expect(imported.emojiSkinTone, 0);
    });

    test('read back, and bad values are harmless', () {
      const s = AppSettings(emojiRecents: [grin], emojiSkinTone: 2);
      final back = AppSettings.fromJson(s.toJson());
      expect(back.emojiRecents, [grin]);
      expect(back.emojiSkinTone, 2);
      expect(const AppSettings().toJson().containsKey('emojiRecents'), isFalse, reason: 'the default is not written');
      expect(AppSettings.fromJson(const {'emojiSkinTone': 99}).emojiSkinTone, 5);
      expect(AppSettings.fromJson(const {'emojiRecents': [1, 'a']}).emojiRecents, ['a']);
    });

    testWidgets('Delete everything clears them', (t) async {
      t.view.physicalSize = const Size(1200, 2000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final storage = (await t.runAsync(() => _tempStorage({
            'emojiRecents': [grin],
            'emojiSkinTone': 3
          })))!;
      final s = (await t.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      late ProviderContainer container;
      await t.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(s)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Scaffold(
            body: Builder(builder: (context) {
              container = ProviderScope.containerOf(context);
              return const SingleChildScrollView(child: DataSettingsSection());
            }),
          ),
        ),
      ));
      await _settle(t);
      expect(container.read(settingsProvider).emojiRecents, [grin]);
      await t.ensureVisible(find.text('Delete…'));
      await t.pump();
      await t.tap(find.text('Delete…'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, 'Delete everything'));
      for (var i = 0; i < 200 && container.read(settingsProvider).emojiRecents.isNotEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(container.read(settingsProvider).emojiRecents, isEmpty);
      expect(container.read(settingsProvider).emojiSkinTone, 0);
      await t.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });
}
