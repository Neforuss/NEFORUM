// 1.4.3: symbols. The character panel on the real engine, with this device's
// real fonts: `flutter test` has none, so only this shows which symbols, kaomoji
// and text styles a device draws and that the panel hides the rest. It prints,
// for every Unicode block, how many characters this device leaves out, saves
// pictures of each tab, and checks the device check against characters every
// system draws and one that cannot exist.
//
//   flutter test integration_test/character_panel_sample_test.dart -d windows
//
// The pictures go to the folder in NEFORUM_CHARACTERS_OUT, or a new temporary
// folder. Look at them: no cell may be an empty box.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neforum_app/media/glyph_support.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/character_catalog.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/emoji_sheet.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _save(WidgetTester t, GlobalKey key, String path) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  File(path).writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the panel on this device', (t) async {
    final outPath = Platform.environment['NEFORUM_CHARACTERS_OUT'];
    final out = outPath == null ? Directory.systemTemp.createTempSync('neforum-characters-') : (Directory(outPath)..createSync(recursive: true));
    final container = ProviderContainer();
    final catalog = await container.read(characterCatalogProvider.future);
    container.dispose();

    // The check itself, on characters with a known answer.
    final known = await GlyphSupport.probe(['★', '♥', '→', '©', '\u{1FAFE}', '\u{10FFFD}']);
    expect(known['★'], isTrue);
    expect(known['♥'], isTrue);
    expect(known['→'], isTrue);
    expect(known['©'], isTrue);
    expect(known['\u{1FAFE}'], isFalse, reason: 'no font has an unassigned code point');
    expect(known['\u{10FFFD}'], isFalse, reason: 'nor a private-use one');

    // Every block: what this device leaves out.
    var shown = 0, hidden = 0;
    for (final g in catalog.groups(CharacterTab.symbols).where((g) => g.isBlock)) {
      final texts = [for (final e in g.entries) e.text];
      final r = await GlyphSupport.probe(texts);
      final missing = r.values.where((v) => !v).length;
      shown += texts.length - missing;
      hidden += missing;
      // ignore: avoid_print
      print('BLOCK ${g.title}: ${texts.length - missing}/${texts.length} drawn');
    }
    // ignore: avoid_print
    print('SYMBOLS drawn=$shown hidden=$hidden');
    for (final k in TextStyleKind.values) {
      final sample = catalog.textStyles.apply(k, 'AaZz09');
      final r = await GlyphSupport.probe({for (final r in sample.runes) if (r > 0x7F && !(r >= 0x300 && r <= 0x36F)) String.fromCharCode(r)});
      // ignore: avoid_print
      print('STYLE ${k.name}: ${r.values.every((v) => v) ? 'offered' : 'left out'}');
    }

    final dir = Directory.systemTemp.createTempSync('neforum-characters-data-');
    final storage = await openAppStorage(overrideDir: dir.path);
    await storage.writeJson('settings.json', {'onboarded': true, 'updateCheck': 'off'});
    final services = await AppServices.create(demo: true, storage: storage);
    final shot = GlobalKey();
    await t.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(
          body: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 380,
            maxWidth: 380,
            minHeight: 640,
            maxHeight: 640,
            child: RepaintBoundary(
              key: shot,
              child: ColoredBox(color: const Color(0xFFFFFFFF), child: EmojiPanel(onPick: (_) {}, onClose: () {}, selection: () => 'NEFORUM 143')),
            ),
          ),
        ),
      ),
    ));
    await _settle(t);
    String path(String name) => '${out.path}${Platform.pathSeparator}$name.png';
    await t.tap(find.byKey(const Key('character-tab-symbols')));
    await _settle(t);
    await _save(t, shot, path('symbols_popular'));
    for (final block in ['Miscellaneous Symbols', 'Dingbats', 'Box Drawing', 'Chess Symbols', 'Symbols for Legacy Computing']) {
      await t.tap(find.byKey(const Key('symbols-groups')));
      await _settle(t);
      await t.ensureVisible(find.text(block).last);
      await _settle(t);
      await t.tap(find.text(block).last);
      await _settle(t);
      await _save(t, shot, path('symbols_${block.toLowerCase().replaceAll(' ', '_')}'));
    }
    await t.tap(find.byKey(const Key('character-tab-kaomoji')));
    await _settle(t);
    await _save(t, shot, path('kaomoji'));
    await t.tap(find.byKey(const Key('kaomoji-group-build')));
    await _settle(t);
    await _save(t, shot, path('kaomoji_builder'));
    await t.tap(find.byKey(const Key('character-tab-textStyles')));
    await _settle(t);
    await _save(t, shot, path('text_styles'));
    expect(t.takeException(), isNull);
    // ignore: avoid_print
    print('SAVED ${out.path}');
    await t.pumpWidget(const SizedBox.shrink());
  });
}
