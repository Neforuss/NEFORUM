// 1.4.4: the group menu of the character panel's Symbols and Kaomoji tabs.
// In 1.4.3 it was a popup menu: a route on the shell tab's navigator, drawn
// UNDER the panel (an overlay child of the root overlay), so the panel hid the
// start of every group name, and a second press of the chevron did not close
// it. These tests build the app's real layering (a nested navigator for the
// page, the panel in the root overlay) and check, at desktop and phone widths,
// in both themes, with Seamless on and off: a hit on the first letters of a
// group name lands on the menu, the chevron toggles it, Escape closes it (and
// only it), the list fits the window and scrolls inside, and the keyboard
// moves through it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/emoji_text.dart';
import 'package:neforum_app/media/glyph_support.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/character_catalog.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/emoji_catalog.dart';
import 'package:neforum_app/ui/compose/emoji_insert.dart';
import 'package:neforum_app/ui/compose/emoji_sheet.dart';
import 'package:neforum_app/widgets/anchored_menu.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

Map<String, Object?> _json(String name) => jsonDecode(File('../../packages/neforum_core/assets/characters/$name').readAsStringSync()) as Map<String, Object?>;

final CharacterCatalog catalog = BundledCharacterCatalog.fromJson(symbols: _json('symbols.json'), textStyles: _json('text_styles.json'), keywords: _json('keywords.json'));

Future<AppStorage> _tempStorage() async {
  final dir = Directory.systemTemp.createTempSync('nf-menu-');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // Still in use on Windows; the system cleans it up.
    }
  });
  final storage = await openAppStorage(overrideDir: dir.path);
  await storage.writeJson('settings.json', {'onboarded': true, 'updateCheck': 'off'});
  return storage;
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

/// A composer field and its emoji button on a page of a NESTED navigator, as
/// in the app (go_router's shell), so a route pushed from the panel lands on
/// that navigator while the panel is in the root overlay.
Future<TextEditingController> _pumpComposer(WidgetTester t, {required Size size, required Brightness brightness, required bool seamless}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final storage = (await t.runAsync(_tempStorage))!;
  final s = (await t.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
  final controller = TextEditingController();
  addTearDown(controller.dispose);
  await t.pumpWidget(ProviderScope(
    overrides: [
      servicesProvider.overrideWithValue(s),
      characterCatalogProvider.overrideWith((ref) async => catalog),
    ],
    child: MaterialApp(
      theme: buildTheme(brightness, AccentChoice.neforum, seamless: seamless),
      home: Navigator(
        key: const Key('shell-navigator'),
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: Column(children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: EmojiTargetField(
                  controller: controller,
                  isDefault: true,
                  child: TextField(key: const Key('field'), controller: controller),
                ),
              ),
              const Align(alignment: Alignment.centerLeft, child: EmojiButton()),
            ]),
          ),
        ),
      ),
    ),
  ));
  await _settle(t);
  await t.tap(find.byKey(const Key('field')));
  await t.pump();
  await t.tap(find.byKey(const Key('emoji-button')));
  await _settle(t);
  await t.tap(find.byKey(const Key('character-tab-symbols')));
  await _settle(t);
  return controller;
}

/// The hit test at [point] reaches [target]'s render object.
bool _hits(WidgetTester t, Offset point, Finder target) {
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, point, t.view.viewId);
  final box = t.renderObject(target);
  return result.path.any((e) => e.target == box);
}

/// The panel: the floating one on a computer, the bottom sheet on a phone.
Finder get _panel => find.byType(EmojiPanel);

Finder get _menu => find.byKey(AnchoredMenuButton.menuKey);

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

  group('anchoredMenuLayout', () {
    const area = Size(1000, 800);
    test('under the chevron, right-aligned with it, when it fits', () {
      final l = anchoredMenuLayout(anchor: const Rect.fromLTWH(600, 100, 30, 30), area: area, width: 260, maxHeight: 360, naturalHeight: 300);
      expect(l.below, isTrue);
      expect(l.rect, const Rect.fromLTWH(370, 134, 260, 300));
    });
    test('never taller than maxHeight: the list scrolls inside', () {
      final l = anchoredMenuLayout(anchor: const Rect.fromLTWH(600, 100, 30, 30), area: area, width: 260, maxHeight: 360, naturalHeight: 2000);
      expect(l.rect.height, 360);
    });
    test('over the chevron when there is more room above, and inside the window', () {
      final l = anchoredMenuLayout(anchor: const Rect.fromLTWH(600, 700, 30, 30), area: area, width: 260, maxHeight: 360, naturalHeight: 2000);
      expect(l.below, isFalse);
      expect(l.rect.bottom, 696);
      expect(l.rect.height, 360);
    });
    test('a short window: as tall as the room there is', () {
      final l = anchoredMenuLayout(anchor: const Rect.fromLTWH(100, 40, 30, 30), area: const Size(300, 200), width: 260, maxHeight: 360, naturalHeight: 2000);
      expect(l.below, isTrue);
      expect(l.rect.top, 74);
      expect(l.rect.bottom, 192, reason: 'the window less the margin');
    });
    test('a narrow window: narrower, and never off its left edge', () {
      final l = anchoredMenuLayout(anchor: const Rect.fromLTWH(10, 40, 30, 30), area: const Size(200, 600), width: 260, maxHeight: 360, naturalHeight: 100);
      expect(l.rect.left, 8);
      expect(l.rect.width, 184);
    });
  });

  // The 1.4.3 bug is a desktop one (the floating panel); a phone gets the
  // panel as a bottom sheet, where the menu must also be on top.
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final size in const [Size(1400, 900), Size(390, 780)]) {
      for (final brightness in Brightness.values) {
        for (final seamless in [false, true]) {
          final name = '${platform.name} ${size.width.toInt()}x${size.height.toInt()} ${brightness.name}${seamless ? ' seamless' : ''}';

          testWidgets('$name: the group menu is above the panel, toggles, closes on Escape, and fits', (t) async {
            await _pumpComposer(t, size: size, brightness: brightness, seamless: seamless);
            expect(_panel, findsOneWidget);
            final chevron = find.byKey(const Key('symbols-groups'));
            final blocks = catalog.groups(CharacterTab.symbols).where((g) => g.isBlock).toList();

            await t.tap(chevron);
            await _settle(t);
            expect(_menu, findsOneWidget);

            // On top: the first letters of the first Unicode block's name (a
            // name only the menu shows) are the menu's, not the panel's.
            final title = find.descendant(of: _menu, matching: find.text(blocks.first.title));
            await t.ensureVisible(title);
            await _settle(t);
            final rect = t.getRect(title);
            final firstLetters = Offset(rect.left + 3, rect.center.dy);
            expect(_hits(t, firstLetters, title), isTrue, reason: 'the menu is drawn and hit above the panel');
            expect(t.getRect(_menu).left, lessThan(t.getRect(_panel).right));

            // Fits: inside the window, never taller than its cap.
            final menuRect = t.getRect(_menu);
            final window = Offset.zero & size;
            expect(window.deflate(Space.sm - 0.01).contains(menuRect.topLeft), isTrue, reason: '$menuRect in $size');
            expect(window.deflate(Space.sm - 0.01).contains(menuRect.bottomRight), isTrue, reason: '$menuRect in $size');
            expect(menuRect.height, lessThanOrEqualTo(360));
            expect(find.descendant(of: _menu, matching: find.byType(Scrollable)), findsOneWidget, reason: 'scrolls inside');

            // The chevron again closes it, at once.
            await t.tap(chevron);
            await _settle(t);
            expect(_menu, findsNothing);
            expect(_panel, findsOneWidget, reason: 'the panel stays open');

            // Escape closes the menu, and only the menu.
            await t.tap(chevron);
            await _settle(t);
            expect(_menu, findsOneWidget);
            await t.sendKeyEvent(LogicalKeyboardKey.escape);
            await _settle(t);
            expect(_menu, findsNothing);
            expect(_panel, findsOneWidget, reason: 'Escape closed the menu only');

            // A pick from the menu: the tab shows that block, the menu closes.
            await t.tap(chevron);
            await _settle(t);
            final arrows = blocks.firstWhere((g) => g.title == 'Arrows');
            final item = find.byKey(AnchoredMenuButton.itemKey(arrows.id));
            await t.ensureVisible(item);
            await _settle(t);
            await t.tap(item);
            await _settle(t);
            expect(_menu, findsNothing);
            expect(find.byKey(const ValueKey('symbol-←')), findsOneWidget);
            await t.pumpWidget(const SizedBox.shrink());
          }, variant: TargetPlatformVariant.only(platform));
        }
      }
    }
  }

  testWidgets('a tap elsewhere closes the menu; the chevron shows its state; the current group is marked', (t) async {
    await _pumpComposer(t, size: const Size(1400, 900), brightness: Brightness.light, seamless: false);
    final chevron = find.byKey(const Key('symbols-groups'));
    final chevronSemantics = find.descendant(of: chevron, matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'All groups'));
    bool expanded() => t.widget<Semantics>(chevronSemantics).properties.expanded ?? false;
    expect(expanded(), isFalse);
    await t.tap(chevron);
    await _settle(t);
    expect(expanded(), isTrue);
    final popular = find.byKey(AnchoredMenuButton.itemKey('popular'));
    expect(find.descendant(of: popular, matching: find.byIcon(Icons.check_rounded)), findsOneWidget, reason: 'the current group is marked');
    expect(find.descendant(of: _menu, matching: find.byIcon(Icons.check_rounded)), findsOneWidget);
    // A tap in the panel, outside the menu: the menu closes, the panel stays.
    await t.tapAt(t.getRect(find.byKey(const Key('symbols-details'))).center);
    await _settle(t);
    expect(_menu, findsNothing);
    expect(_panel, findsOneWidget);
    expect(expanded(), isFalse);
    await t.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the keyboard: the current group has the focus, arrows, Home and End move, Enter picks, the caret goes back', (t) async {
    final controller = await _pumpComposer(t, size: const Size(1400, 900), brightness: Brightness.dark, seamless: true);
    final field = find.byKey(const Key('field'));
    expect(Focus.of(t.element(find.descendant(of: field, matching: find.byType(EditableText)))).hasFocus, isTrue);
    controller.text = 'ab';
    await t.tap(find.byKey(const Key('symbols-groups')));
    await _settle(t);
    final groups = catalog.groups(CharacterTab.symbols);
    FocusNode focusOf(String id) => Focus.of(t.element(find.descendant(of: find.byKey(AnchoredMenuButton.itemKey(id)), matching: find.byType(Padding)).first));
    expect(focusOf('popular').hasPrimaryFocus, isTrue, reason: 'opens on the current group');
    final at = groups.indexWhere((g) => g.id == 'popular');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _settle(t);
    expect(focusOf(groups[at + 1].id).hasPrimaryFocus, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.end);
    await _settle(t);
    expect(focusOf(groups.last.id).hasPrimaryFocus, isTrue);
    final lastRect = t.getRect(find.byKey(AnchoredMenuButton.itemKey(groups.last.id)));
    expect(t.getRect(_menu).contains(lastRect.center), isTrue, reason: 'scrolled into view');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _settle(t);
    expect(focusOf(groups.first.id).hasPrimaryFocus, isTrue, reason: 'wraps around');
    await t.sendKeyEvent(LogicalKeyboardKey.end);
    await t.sendKeyEvent(LogicalKeyboardKey.home);
    await _settle(t);
    expect(focusOf(groups.first.id).hasPrimaryFocus, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(t);
    expect(_menu, findsNothing);
    expect(find.byKey(Key('symbols-group-${groups[1].id}')), findsOneWidget);
    final chip = t.widget<Semantics>(find.descendant(of: find.byKey(Key('symbols-group-${groups[1].id}')), matching: find.byType(Semantics)).first);
    expect(chip.properties.selected, isTrue, reason: 'Enter picked the focused group');
    expect(Focus.of(t.element(find.descendant(of: field, matching: find.byType(EditableText)))).hasFocus, isTrue, reason: 'the caret is back in the field');
    expect(_panel, findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Kaomoji uses the same menu, also above the panel', (t) async {
    await _pumpComposer(t, size: const Size(1400, 900), brightness: Brightness.light, seamless: false);
    await t.tap(find.byKey(const Key('character-tab-kaomoji')));
    await _settle(t);
    final chevron = find.byKey(const Key('kaomoji-groups'));
    expect(find.descendant(of: chevron, matching: find.byType(AnchoredMenuButton<String>)), findsOneWidget);
    await t.tap(chevron);
    await _settle(t);
    final first = catalog.groups(CharacterTab.kaomoji).first;
    final title = find.descendant(of: _menu, matching: find.text(first.title));
    final rect = t.getRect(title);
    expect(_hits(t, Offset(rect.left + 3, rect.center.dy), title), isTrue);
    await t.tap(chevron);
    await _settle(t);
    expect(_menu, findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
