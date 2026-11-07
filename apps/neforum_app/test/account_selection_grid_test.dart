// The phone composer's account grid: 21 accounts at 360 x 640, at the normal
// and the largest text size. What the grid promises is counted here: taps to
// leave out 3, nothing sideways, every state on screen, nothing cut.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/brand/platform_brand.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/account_selection_grid.dart';
import 'package:neforum_app/ui/compose/action_bar.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/compose/target_picker.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/widgets/account_avatar.dart';
import 'package:neforum_app/widgets/badges.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> json = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}

// The app's own fonts are in the repo, so real widths hold on every system.
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

const _networks = [
  'mastodon', 'bluesky', 'x', 'threads', 'instagram', 'facebook', 'linkedin', //
  'tiktok', 'youtube', 'pinterest', 'reddit', 'tumblr', 'telegram', 'discord',
  'nostr', 'lemmy', 'wordpress', 'substack', 'snapchat', 'whatsapp', 'matrix',
];

ConnectedAccount _account(String platformId, {String? id, String? handle, bool enabled = true, PlatformTier? tier, String? avatarUrl}) => ConnectedAccount(
      id: id ?? 'acct-$platformId',
      platformId: platformId,
      tier: tier ?? builtinRegistry().descriptor(platformId)!.defaultTier,
      displayName: platformId,
      handle: handle,
      avatarUrl: avatarUrl,
      createdAt: DateTime.utc(2026, 10, 1),
      enabled: enabled,
    );

List<ConnectedAccount> _twentyOne() => [for (final p in _networks) _account(p)];

Finder _cell(String id) => find.byWidgetPredicate((w) => w is AccountCell && w.entry.account.id == id);
Finder get _cells => find.byType(AccountCell);
AccountEntry _entry(WidgetTester t, String id) => t.widget<AccountCell>(_cell(id)).entry;

/// Boots the real app on the composer, as a real workspace (no demo banner).
Future<ProviderContainer> _boot(
  WidgetTester t, {
  required List<ConnectedAccount> accounts,
  Size size = const Size(360, 640),
  double textScale = 1,
  _MemoryStorage? storage,
  Map<String, Object> settings = const {},
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  addTearDown(t.view.resetViewInsets);
  // The first-start question about update checks would cover the screen.
  final store = (storage ?? _MemoryStorage())..json['settings.json'] = {'updateCheck': 'off', ...settings};
  final services = (await t.runAsync(() => AppServices.create(demo: true, storage: store)))!;
  await t.pumpWidget(ProviderScope(overrides: [
    servicesProvider.overrideWithValue(services),
    isDemoProvider.overrideWithValue(false),
    accountsProvider.overrideWith((ref) => Stream.value(accounts)),
  ], child: const NeforumApp()));
  await t.pump(const Duration(milliseconds: 300));
  final c = ProviderScope.containerOf(t.element(find.byType(MaterialApp)));
  if (textScale != 1) await t.runAsync(() => c.read(settingsProvider.notifier).update((s) => s.copyWith(mobileTextScale: textScale)));
  c.read(routerProvider).go('/compose');
  await t.pump();
  c.read(composerProvider.notifier).reset(keepTargets: false);
  await _settle(t);
  return c;
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _end(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump(const Duration(seconds: 1));
}

/// Taps a cell after bringing it into view by scrolling down only if it has
/// to, and counts the tap.
class _TapCounter {
  _TapCounter(this.t);
  final WidgetTester t;
  int taps = 0;

  Future<void> tap(Finder f) async {
    await t.ensureVisible(f);
    await t.pump();
    await t.tap(f);
    taps++;
    await _settle(t);
  }
}

void _expectAtLeastTouchSize(WidgetTester t, Finder f, String what) {
  final s = t.getSize(f);
  expect(s.width >= 48 && s.height >= 48, isTrue, reason: '$what is ${s.width} x ${s.height}');
}

final _editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
final _summary = find.byType(AccountSelectionSummary);
final _filter = find.byKey(kTargetFilterKey);

void _keyboard(WidgetTester t, double height) => t.view.viewInsets = FakeViewPadding(bottom: height);

/// The text field's caret is on screen: below the Write and Preview tabs and
/// above the action bar, which sits on the keyboard.
void _expectCaretInView(WidgetTester t) {
  final state = t.state<EditableTextState>(find.descendant(of: _editor, matching: find.byType(EditableText)));
  final box = state.renderEditable;
  final selection = state.textEditingValue.selection;
  final offset = selection.isValid ? selection.extent : const TextPosition(offset: 0);
  final caret = box.localToGlobal(box.getLocalRectForCaret(offset).center);
  expect(caret.dy, greaterThan(t.getRect(find.text('Write')).bottom), reason: 'the caret is below the tabs');
  expect(caret.dy, lessThan(t.getRect(find.byType(ComposerActionBar)).top), reason: 'the caret is above the action bar');
}

/// The account of the cell that has the keyboard focus.
String? _focusedCell() {
  String? id;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
    final w = e.widget;
    if (w is AccountCell) {
      id = w.entry.account.id;
      return false;
    }
    return true;
  });
  return id;
}

bool _foldHasFocus() {
  var found = false;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
    if (e.widget.key == kTargetFoldKey) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Runs [body] as a desktop window, where the Tab key is how some people move.
Future<void> _onDesktop(WidgetTester t, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  setUpAll(_loadFonts);

  for (final scale in const [1.0, 1.5]) {
    group('21 accounts at 360 x 640, text x$scale', () {
      testWidgets('every account is on screen at once, with its states, on a 48 x 48 target', (t) async {
        final accounts = _twentyOne();
        accounts[6] = _account('linkedin', enabled: false);
        final c = await _boot(t, accounts: accounts, textScale: scale);
        c.read(composerProvider.notifier).toggleAccount('acct-reddit');
        await _settle(t);

        final limit = t.getRect(find.byType(ComposerActionBar)).top;
        for (final a in accounts) {
          final cell = _cell(a.id);
          expect(t.getRect(cell).bottom, lessThanOrEqualTo(limit), reason: '${a.platformId} is above the action bar without scrolling');
          _expectAtLeastTouchSize(t, cell, a.platformId);
          final hit = t.hitTestOnBinding(t.getCenter(cell));
          expect(hit.path.any((e) => e.target == t.renderObject(cell)), isTrue, reason: '${a.platformId} takes the tap');

          // Tier and state: their own shapes, whatever the colour.
          expect(find.descendant(of: cell, matching: find.byIcon(tierIcon(a.tier))), findsOneWidget, reason: a.platformId);
          final state = !a.enabled
              ? Icons.block_rounded
              : c.read(composerProvider).selected.contains(a.id)
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded;
          expect(find.descendant(of: cell, matching: find.byIcon(state)), findsOneWidget, reason: a.platformId);
        }
        await _end(t);
      });

      testWidgets('leaving out 3 takes 3 taps from the default state, none of them hunting sideways', (t) async {
        final c = await _boot(t, accounts: _twentyOne(), textScale: scale);
        expect(c.read(composerProvider).selected.length, 21, reason: 'the default state: nothing marked, everything chosen');

        final counter = _TapCounter(t);
        // Spread over the grid on purpose: the old row was worst at its end.
        for (final id in const ['acct-threads', 'acct-reddit', 'acct-matrix']) {
          await counter.tap(_cell(id));
        }
        expect(counter.taps, lessThanOrEqualTo(5));
        expect(counter.taps, 3);
        expect(c.read(composerProvider).selected.length, 18);
        expect(c.read(composerProvider).selected, isNot(anyOf(contains('acct-threads'), contains('acct-reddit'), contains('acct-matrix'))));
        await t.ensureVisible(find.byKey(kTargetFoldKey));
        await t.pump();
        expect(find.text('18 of 21'), findsOneWidget);
        await _end(t);
      });

      testWidgets('nothing under the picker scrolls sideways, and no chip row is left', (t) async {
        await _boot(t, accounts: _twentyOne(), textScale: scale);
        final scrollables = find.descendant(of: find.byType(TargetPicker), matching: find.byType(Scrollable));
        for (final s in t.widgetList<Scrollable>(scrollables)) {
          expect(axisDirectionToAxis(s.axisDirection), isNot(Axis.horizontal));
        }
        expect(find.descendant(of: find.byType(TargetPicker), matching: find.byType(AccountChip)), findsNothing);
        // Every account exists in the tree at once, not built on demand.
        expect(find.descendant(of: find.byType(TargetPicker), matching: _cells), findsNWidgets(21));
        // And the grid is as wide as the column: nothing past the gutter.
        for (final e in t.elementList(_cells)) {
          final box = e.renderObject! as RenderBox;
          final left = box.localToGlobal(Offset.zero).dx;
          expect(left, greaterThanOrEqualTo(16));
          expect(left + box.size.width, lessThanOrEqualTo(344.01));
        }
        await _end(t);
      });

      testWidgets('every target is at least 48 x 48', (t) async {
        final accounts = _twentyOne();
        accounts[20] = _account('behance'); // brings the Artwork switch
        await _boot(t, accounts: accounts, textScale: scale);
        for (final a in accounts) {
          _expectAtLeastTouchSize(t, _cell(a.id), a.platformId);
        }
        _expectAtLeastTouchSize(t, find.byKey(kTargetFoldKey), 'the fold control');
        _expectAtLeastTouchSize(t, find.byKey(TargetPicker.artworkSwitchKey), 'the Artwork switch');
        for (final label in const ['All', 'Automatic only', 'None']) {
          _expectAtLeastTouchSize(t, find.widgetWithText(TextButton, label), label);
        }
        await t.ensureVisible(find.byKey(kTargetFoldKey));
        await t.pump();
        await t.tap(find.byKey(kTargetFoldKey));
        await _settle(t);
        _expectAtLeastTouchSize(t, find.byKey(kTargetFoldKey), 'the folded summary');
        await _end(t);
      });

      testWidgets('selected, left out and disabled differ in more than colour, and tier always shows', (t) async {
        final accounts = _twentyOne();
        accounts[15] = _account('lemmy', enabled: false);
        final c = await _boot(t, accounts: accounts, textScale: scale);
        c.read(composerProvider.notifier).toggleAccount('acct-threads');
        await _settle(t);

        Iterable<IconData?> icons(String id) => t.widgetList<Icon>(find.descendant(of: _cell(id), matching: find.byType(Icon))).map((i) => i.icon);
        TextDecoration? decoration(String id, String label) =>
            t.widget<Text>(find.descendant(of: _cell(id), matching: find.text(label))).style?.decoration;

        expect(icons('acct-mastodon'), containsAll([Icons.check_circle_rounded, tierIcon(accounts[0].tier)]));
        expect(decoration('acct-mastodon', 'Mastodon'), isNot(TextDecoration.lineThrough));

        expect(icons('acct-threads'), containsAll([Icons.radio_button_unchecked_rounded, tierIcon(accounts[3].tier)]));
        expect(icons('acct-threads'), isNot(contains(Icons.check_circle_rounded)));
        expect(decoration('acct-threads', 'Threads'), TextDecoration.lineThrough);

        expect(icons('acct-lemmy'), containsAll([Icons.block_rounded, tierIcon(accounts[15].tier)]));
        expect(icons('acct-lemmy'), isNot(contains(Icons.check_circle_rounded)));
        expect(decoration('acct-lemmy', 'Lemmy'), isNot(TextDecoration.lineThrough), reason: 'disabled is not the same as left out');

        // Tiers differ in shape as well as tone.
        expect({for (final t in PlatformTier.values) tierIcon(t)}.length, PlatformTier.values.length);
        await _end(t);
      });

      testWidgets('every name reads whole on one line', (t) async {
        final accounts = _twentyOne();
        await _boot(t, accounts: accounts, textScale: scale);
        for (final a in accounts) {
          final label = _entry(t, a.id).label;
          final paragraph = t.renderObject<RenderParagraph>(find.descendant(of: _cell(a.id), matching: find.text(label)));
          expect(paragraph.didExceedMaxLines, isFalse, reason: label);
          final line = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: label.length));
          expect(line.map((b) => b.top).toSet().length, 1, reason: '$label wrapped');
        }
        await _end(t);
      });

      testWidgets('the composer has no overflow, grid open or folded', (t) async {
        // Any overflow reports a FlutterError, which fails the test.
        await _boot(t, accounts: _twentyOne(), textScale: scale);
        await t.ensureVisible(find.byKey(kTargetFoldKey));
        await t.pump();
        await t.tap(find.byKey(kTargetFoldKey));
        await _settle(t);
        expect(_cells, findsNothing);
        expect(t.takeException(), isNull);
        await _end(t);
      });

      testWidgets('with the keyboard open the grid folds and the text stays usable', (t) async {
        final c = await _boot(t, accounts: _twentyOne(), textScale: scale);
        c.read(composerProvider.notifier).toggleAccount('acct-threads');
        await _settle(t);
        final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
        await t.ensureVisible(editor);
        await t.pump();
        await t.tap(editor);
        await t.pump();
        t.view.viewInsets = const FakeViewPadding(bottom: 260);
        await _settle(t);

        expect(_cells, findsNothing, reason: 'folded for the keyboard');
        expect(find.byType(AccountSelectionSummary), findsOneWidget);
        expect(find.text('Left out:'), findsOneWidget);

        // Type, and the words land in the composer with the field on screen.
        await t.enterText(editor, 'Typing with the keyboard open');
        await _settle(t);
        expect(c.read(composerProvider).text, 'Typing with the keyboard open');
        // No scrolling by the test: the field has to stay in view by itself.
        final field = t.getRect(editor);
        const keyboardTop = 640 - 260;
        final bar = t.getRect(find.byType(ComposerActionBar));
        expect(bar.bottom, lessThanOrEqualTo(keyboardTop + 0.01), reason: 'the action bar is above the keyboard');
        // At least two lines of the post can be seen while typing.
        final visible = bar.top - field.top.clamp(0, bar.top);
        debugPrint('keyboard open, text x$scale: field ${field.top.toStringAsFixed(0)}-${field.bottom.toStringAsFixed(0)}, bar top ${bar.top.toStringAsFixed(0)}');
        expect(visible, greaterThanOrEqualTo(40), reason: 'room to see the text');
        expect(field.bottom, greaterThan(field.top));

        // The control opens the grid over the keyboard; the keyboard closing
        // goes back to the user's own choice, which was not touched.
        await t.ensureVisible(find.byKey(kTargetFoldKey));
        await t.pump();
        await t.tap(find.byKey(kTargetFoldKey));
        await _settle(t);
        expect(_cells, findsNWidgets(21));
        expect(c.read(settingsProvider).targetPickerFolded, isFalse);
        t.view.resetViewInsets();
        await _settle(t);
        expect(_cells, findsNWidgets(21));
        await _end(t);
      });
    });
  }

  testWidgets('at the largest text the count and the quick choices share a line, and the words stay for screen readers', (t) async {
    final handle = t.ensureSemantics();
    await _boot(t, accounts: _twentyOne(), textScale: 1.5);
    final fold = t.getRect(find.byKey(kTargetFoldKey));
    for (final label in const ['All', 'Automatic only', 'None']) {
      expect(t.getRect(find.widgetWithText(TextButton, label)).top, fold.top, reason: label);
    }
    expect(find.text('21 of 21'), findsOneWidget);
    expect(find.descendant(of: find.byType(TargetPicker), matching: find.text('Post to')), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'^Post to, 21 of 21\. Fold the accounts$')), findsOneWidget);
    handle.dispose();
    await _end(t);
  });

  testWidgets('at the largest text the header stays on one line for every count, and its words do not touch', (t) async {
    final c = await _boot(t, accounts: _twentyOne(), textScale: 1.5);
    final limit = t.getRect(find.byType(ComposerActionBar)).top;
    var widest = 0.0;
    for (final p in [..._networks, null]) {
      final fold = t.getRect(find.byKey(kTargetFoldKey));
      if (fold.width > widest) widest = fold.width;
      for (final label in const ['All', 'Automatic only', 'None']) {
        expect(t.getRect(find.widgetWithText(TextButton, label)).top, fold.top, reason: '$label at ${accountCountLabel(t.widget<AccountCountLabel>(find.byType(AccountCountLabel)).entries)}');
      }
      expect(t.getRect(_cell('acct-matrix')).bottom, lessThanOrEqualTo(limit));
      expect(t.getRect(find.text('None')).left - t.getRect(find.text('Automatic only')).right, greaterThanOrEqualTo(Space.xs));
      if (p != null) {
        c.read(composerProvider.notifier).toggleAccount('acct-$p');
        await _settle(t);
      }
    }
    debugPrint('largest text: the widest count takes ${widest.toStringAsFixed(1)} px of the 328 px header');
    await _end(t);
  });

  testWidgets('at normal text the header keeps its words and the rows their gap', (t) async {
    await _boot(t, accounts: _twentyOne());
    expect(find.descendant(of: find.byType(TargetPicker), matching: find.text('Post to')), findsOneWidget);
    expect(t.getRect(_cell('acct-instagram')).top - t.getRect(_cell('acct-mastodon')).bottom, 4);
    await _end(t);
  });

  group('the fold over the keyboard', () {
    testWidgets('over the keyboard the artwork controls step aside, and come back', (t) async {
      final c = await _boot(t, accounts: [_account('behance'), _account('cara')]);
      await t.tap(find.byKey(TargetPicker.artworkSwitchKey));
      await _settle(t);
      expect(c.read(composerProvider).isArtwork, isTrue);
      expect(find.text('Made with AI'), findsOneWidget);

      _keyboard(t, 280);
      await _settle(t);
      expect(find.text('Made with AI'), findsNothing);
      expect(find.byKey(TargetPicker.artworkSwitchKey), findsNothing);

      // Opened by hand over the keyboard, they are back with the grid.
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      expect(find.byKey(TargetPicker.artworkSwitchKey), findsOneWidget);
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      expect(find.byKey(TargetPicker.artworkSwitchKey), findsNothing);

      _keyboard(t, 0);
      await _settle(t);
      expect(find.text('Made with AI'), findsOneWidget);
      expect(find.byKey(TargetPicker.artworkSwitchKey), findsOneWidget);
      await _end(t);
    });

    testWidgets('folded by choice: artwork controls stay when there is no keyboard', (t) async {
      await _boot(t, accounts: [_account('mastodon'), _account('behance')], settings: {'targetPickerFolded': true});
      expect(_summary, findsOneWidget);
      expect(find.byKey(TargetPicker.artworkSwitchKey), findsOneWidget);
      await _end(t);
    });

    // The grid folds within the frame: a height animation moved the field out
    // of view after it had scrolled its caret into view.
    testWidgets('a long post scrolled to its end keeps the caret in view when the tiles fold', (t) async {
      await _boot(t, accounts: _twentyOne());
      await t.ensureVisible(_editor);
      await _settle(t);
      await t.enterText(_editor, List.generate(30, (i) => 'Line $i of a long post').join('\n'));
      await _settle(t);
      _keyboard(t, 280);
      await _settle(t);
      expect(_cells, findsNothing);
      _expectCaretInView(t);
      _keyboard(t, 0);
      await _settle(t);
      await _end(t);
    });

    testWidgets('folding takes its height at once and fades in', (t) async {
      await _boot(t, accounts: _twentyOne());
      final picker = find.byType(TargetPicker);
      final open = t.getSize(picker).height;
      await t.tap(find.byKey(kTargetFoldKey));
      await t.pump();
      await t.pump(const Duration(milliseconds: 40));
      final midway = t.getSize(picker).height;
      final fade = t.widget<FadeTransition>(find.ancestor(of: _summary, matching: find.byType(FadeTransition)).first);
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      await _settle(t);
      expect(midway, lessThan(open));
      expect(midway, t.getSize(picker).height);
      await _end(t);
    });

    testWidgets('the system setting for less motion: the fold works, without any animation', (t) async {
      t.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await _boot(t, accounts: _twentyOne());
      await t.tap(find.byKey(kTargetFoldKey));
      await t.pump();
      expect(_summary, findsOneWidget);
      expect(_cells, findsNothing);
      await t.tap(find.byKey(kTargetFoldKey));
      await t.pump();
      expect(_cells, findsNWidgets(21));
      expect(t.takeException(), isNull);
      await _end(t);
    });

    Finder inSummary(Finder f) => find.descendant(of: _summary, matching: f);

    for (final scale in const [1.0, 1.5]) {
      testWidgets('ten named accounts become icons over the keyboard and stay short, text x$scale', (t) async {
        final handle = t.ensureSemantics();
        final c = await _boot(t, accounts: _twentyOne(), textScale: scale);
        for (final p in _networks.take(10)) {
          c.read(composerProvider.notifier).toggleAccount('acct-$p');
        }
        await _settle(t);
        await t.ensureVisible(_editor);
        await t.pump();
        await t.tap(_editor);
        _keyboard(t, 280);
        await _settle(t);

        expect(inSummary(find.text('Left out:')), findsOneWidget);
        expect(inSummary(find.text('Mastodon')), findsNothing);
        expect(inSummary(find.byType(PlatformTile)), findsNWidgets(10));
        // Every one still shows how it posts.
        final tierGlyphs = t.widgetList<Icon>(inSummary(find.byType(Icon))).where((i) => PlatformTier.values.any((tier) => tierIcon(tier) == i.icon));
        expect(tierGlyphs.length, greaterThanOrEqualTo(10));
        final height = t.getSize(_summary).height;
        debugPrint('ten named over the keyboard, text x$scale: summary $height px');
        expect(height, lessThanOrEqualTo(100));
        // A screen reader still hears the names.
        expect(find.bySemanticsLabel(RegExp(r'Left out Mastodon, Bluesky, ')), findsOneWidget);
        handle.dispose();
        _keyboard(t, 0);
        await _settle(t);
        await _end(t);
      });
    }

    testWidgets('four named accounts keep their names over the keyboard, five do not', (t) async {
      final c = await _boot(t, accounts: _twentyOne());
      for (final p in _networks.take(4)) {
        c.read(composerProvider.notifier).toggleAccount('acct-$p');
      }
      await _settle(t);
      await t.ensureVisible(_editor);
      await t.pump();
      await t.tap(_editor);
      _keyboard(t, 280);
      await _settle(t);
      expect(inSummary(find.text('Mastodon')), findsOneWidget);
      c.read(composerProvider.notifier).toggleAccount('acct-${_networks[4]}');
      await _settle(t);
      expect(inSummary(find.text('Mastodon')), findsNothing);
      _keyboard(t, 0);
      await _settle(t);
      await _end(t);
    });

    for (final scale in const [1.0, 1.5]) {
      testWidgets('ten named accounts keep their names with no keyboard, text x$scale', (t) async {
        final c = await _boot(t, accounts: _twentyOne(), settings: {'targetPickerFolded': true}, textScale: scale);
        for (final p in _networks.take(10)) {
          c.read(composerProvider.notifier).toggleAccount('acct-$p');
        }
        await _settle(t);
        expect(inSummary(find.text('Mastodon')), findsOneWidget);
        debugPrint('ten named with their names, text x$scale: summary ${t.getSize(_summary).height} px');
        await _end(t);
      });
    }

    testWidgets('as icons, two accounts on one network keep what tells them apart', (t) async {
      final accounts = [
        _account('mastodon', id: 'work', handle: '@ana@social.example'),
        _account('mastodon', id: 'home', handle: '@ben@social.example'),
        for (final p in _networks.skip(1).take(10)) _account(p),
      ];
      final c = await _boot(t, accounts: accounts);
      for (final id in const ['work', 'home', 'acct-bluesky', 'acct-x', 'acct-threads']) {
        c.read(composerProvider.notifier).toggleAccount(id);
      }
      await _settle(t);
      await t.ensureVisible(_editor);
      await t.pump();
      await t.tap(_editor);
      _keyboard(t, 280);
      await _settle(t);
      expect(inSummary(find.text('Bluesky')), findsNothing);
      expect(inSummary(find.text('@ana')), findsOneWidget);
      expect(inSummary(find.text('@ben')), findsOneWidget);
      _keyboard(t, 0);
      await _settle(t);
      await _end(t);
    });
  });

  group('reached with the Tab key, in a desktop window narrowed to a phone\'s width', () {
    const narrow = Size(500, 800);

    Future<void> tabTo(WidgetTester t, bool Function() arrived) async {
      for (var i = 0; i < 80; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        if (arrived()) return;
      }
      fail('the Tab key never got there');
    }

    testWidgets('a cell takes focus, shows it without moving, and Enter or Space operates it', (t) async {
      await _onDesktop(t, () async {
        final c = await _boot(t, accounts: _twentyOne(), size: narrow);
        expect(_cells, findsNWidgets(21));
        final before = t.getRect(_cell('acct-nostr'));
        AnimatedContainer box() => t.widget<AnimatedContainer>(find.byKey(const ValueKey('account-cell-box-acct-nostr')));
        expect(box().foregroundDecoration, isNull);

        await tabTo(t, () => _focusedCell() == 'acct-nostr');
        await _settle(t);
        final ring = (box().foregroundDecoration! as BoxDecoration).border! as Border;
        expect(ring.top.width, 2);
        expect(t.getRect(_cell('acct-nostr')), before, reason: 'the focus mark takes no room');

        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await _settle(t);
        expect(c.read(composerProvider).selected, isNot(contains('acct-nostr')));
        expect(_focusedCell(), 'acct-nostr');
        await t.sendKeyEvent(LogicalKeyboardKey.space);
        await _settle(t);
        expect(c.read(composerProvider).selected, contains('acct-nostr'));
        await _end(t);
      });
    });

    testWidgets('a disabled cell is passed over', (t) async {
      await _onDesktop(t, () async {
        final accounts = [_account('mastodon'), _account('lemmy', enabled: false), _account('nostr')];
        await _boot(t, accounts: accounts, size: narrow);
        final seen = <String>{};
        await tabTo(t, () {
          final id = _focusedCell();
          if (id != null) seen.add(id);
          return id == 'acct-nostr';
        });
        expect(seen, {'acct-mastodon', 'acct-nostr'});
        await _end(t);
      });
    });

    testWidgets('the fold control is reached too, and keeps the focus both ways', (t) async {
      await _onDesktop(t, () async {
        await _boot(t, accounts: _twentyOne(), size: narrow);
        await tabTo(t, _foldHasFocus);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await _settle(t);
        expect(_cells, findsNothing);
        expect(_foldHasFocus(), isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await _settle(t);
        expect(_cells, findsNWidgets(21));
        expect(_foldHasFocus(), isTrue);
        await _end(t);
      });
    });
  });

  group('the filter field', () {
    List<ConnectedAccount> many(int n) => [
          for (var i = 0; i < n; i++)
            _account('mastodon', id: 'm$i', tier: i.isEven ? PlatformTier.openApi : PlatformTier.handoff, handle: i < 3 ? '@alpha$i@one.example' : '@user$i@two.example'),
        ];

    testWidgets('24 accounts have none, 25 have one, on a whole touch target', (t) async {
      expect(kTargetFilterThreshold, 24);
      await _boot(t, accounts: many(24));
      expect(_filter, findsNothing);
      await _end(t);
      await _boot(t, accounts: many(25));
      expect(_filter, findsOneWidget);
      _expectAtLeastTouchSize(t, _filter, 'the filter');
      await _end(t);
    });

    testWidgets('it narrows the cells, All and None act on the matches and it says so, and its keyboard does not fold it', (t) async {
      final c = await _boot(t, accounts: many(30));
      Set<String> selected() => c.read(composerProvider).selected;
      await t.tap(_filter);
      _keyboard(t, 280);
      await _settle(t);
      expect(_filter, findsOneWidget, reason: 'its own keyboard leaves it in place');
      expect(_cells, findsNWidgets(30));

      await t.enterText(_filter, 'alpha');
      await _settle(t);
      expect(_cells, findsNWidgets(3));
      expect(find.text('All, Automatic only and None act on the 3 shown'), findsOneWidget);

      await t.tap(find.widgetWithText(TextButton, 'None'));
      await _settle(t);
      expect(selected().length, 27);
      expect(selected(), isNot(anyOf(contains('m0'), contains('m1'), contains('m2'))));
      expect(find.text('27 of 30'), findsOneWidget, reason: 'the count stays about all of them');

      await t.tap(find.widgetWithText(TextButton, 'Automatic only'));
      await _settle(t);
      expect(selected(), containsAll(const ['m0', 'm2']));
      expect(selected(), isNot(contains('m1')), reason: 'the hand-off one');
      expect(selected().length, 29);

      await t.tap(find.widgetWithText(TextButton, 'All'));
      await _settle(t);
      expect(selected().length, 30);

      await t.enterText(_filter, 'nothing like this');
      await _settle(t);
      expect(find.text('No account matches.'), findsOneWidget);

      await t.tap(find.byTooltip('Clear'));
      await _settle(t);
      expect(_cells, findsNWidgets(30));
      expect(find.textContaining('act on the'), findsNothing);

      // The fold control works while typing in the filter too. That takes the
      // field away and the keyboard with it, so it is the lasting choice.
      await t.ensureVisible(find.byKey(kTargetFoldKey));
      await _settle(t);
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      expect(_cells, findsNothing);
      expect(_filter, findsNothing);
      expect(_summary, findsOneWidget);
      expect(c.read(settingsProvider).targetPickerFolded, isTrue);

      _keyboard(t, 0);
      await _settle(t);
      expect(_summary, findsOneWidget, reason: 'it stays folded when the keyboard has gone');
      await _settle(t);
      await _end(t);
    });

    testWidgets('a filter opened over the keyboard stays open while typing in it, whatever the lasting choice', (t) async {
      await _boot(t, accounts: many(30), settings: {'targetPickerFolded': true});
      await t.ensureVisible(_editor);
      await t.pump();
      await t.tap(_editor);
      _keyboard(t, 280);
      await _settle(t);
      await t.ensureVisible(find.byKey(kTargetFoldKey));
      await t.pump();
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      await t.tap(_filter);
      await _settle(t);
      expect(_filter, findsOneWidget);
      expect(_cells, findsNWidgets(30));

      // The fold control still folds it from there, with the choice already
      // being folded.
      await t.ensureVisible(find.byKey(kTargetFoldKey));
      await t.pump();
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      expect(_filter, findsNothing);
      expect(_summary, findsOneWidget);

      // Opened by hand, it stays open for the text too, until folded by hand.
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      expect(_filter, findsOneWidget);
      await t.ensureVisible(_editor);
      await t.pump();
      await t.tap(_editor);
      await _settle(t);
      expect(_cells, findsNWidgets(30));
      await t.ensureVisible(find.byKey(kTargetFoldKey));
      await t.pump();
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      expect(_filter, findsNothing);
      _keyboard(t, 0);
      await _settle(t);
      await _end(t);
    });

    testWidgets('from the filter, moving on to the text folds the grid as usual', (t) async {
      await _boot(t, accounts: many(30));
      await t.tap(_filter);
      _keyboard(t, 280);
      await _settle(t);
      expect(_cells, findsNWidgets(30));
      await t.ensureVisible(_editor);
      await t.pump();
      await t.tap(_editor);
      await _settle(t);
      expect(_cells, findsNothing);
      expect(_filter, findsNothing);
      _keyboard(t, 0);
      await _settle(t);
      await _end(t);
    });

    testWidgets('quick choices over matches skip art sites, as they do without a filter', (t) async {
      final accounts = [...many(25), _account('cara')];
      final c = await _boot(t, accounts: accounts);
      await t.enterText(_filter, 'a');
      await _settle(t);
      await t.tap(find.widgetWithText(TextButton, 'All'));
      await _settle(t);
      expect(c.read(composerProvider).selected, isNot(contains('acct-cara')));
      await _end(t);
    });

    testWidgets('finds by network, short name and handle', (t) async {
      final accounts = [...many(24), _account('x'), _account('nostr')];
      await _boot(t, accounts: accounts);
      await t.enterText(_filter, 'twitter');
      await _settle(t);
      expect(_cells, findsOneWidget, reason: 'the network\'s full name');
      await t.enterText(_filter, 'NOSTR');
      await _settle(t);
      expect(_cells, findsOneWidget);
      await t.enterText(_filter, 'user24');
      await _settle(t);
      expect(_cells, findsNothing);
      await t.enterText(_filter, 'user23');
      await _settle(t);
      expect(_cells, findsOneWidget, reason: 'a handle');
      await _end(t);
    });
  });

  group('the fold', () {
    testWidgets('names exactly what is left out, each with how it posts', (t) async {
      final accounts = _twentyOne();
      final c = await _boot(t, accounts: accounts);
      for (final id in const ['acct-threads', 'acct-reddit', 'acct-nostr']) {
        c.read(composerProvider.notifier).toggleAccount(id);
      }
      await _settle(t);
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);

      final summary = find.byType(AccountSelectionSummary);
      expect(_cells, findsNothing);
      expect(find.descendant(of: summary, matching: find.text('18 of 21')), findsOneWidget);
      expect(find.descendant(of: summary, matching: find.text('Left out:')), findsOneWidget);
      for (final name in const ['Threads', 'Reddit', 'Nostr']) {
        expect(find.descendant(of: summary, matching: find.text(name)), findsOneWidget);
      }
      expect(find.descendant(of: summary, matching: find.text('Mastodon')), findsNothing);
      // The tiers of what is chosen add up to what is chosen.
      final counts = AccountTierCounts.of(t.widget<AccountSelectionSummary>(summary).entries);
      expect(counts.values.reduce((a, b) => a + b), 18);
      for (final e in counts.entries) {
        expect(find.descendant(of: summary, matching: find.byIcon(tierIcon(e.key))), findsWidgets);
        expect(find.descendant(of: summary, matching: find.text('${e.value}')), findsOneWidget);
      }

      // Opening again is one tap, anywhere on it.
      await t.tap(find.text('Left out:'));
      await _settle(t);
      expect(_cells, findsNWidgets(21));
      await _end(t);
    });

    test('names the shorter side, and nothing when the count says it all', () {
      AccountEntry e(String id, {bool selected = true}) =>
          AccountEntry(account: _account(id), platformName: id, label: id, selected: selected, onTap: () {});
      expect(AccountSelectionSummary.named([e('x'), e('nostr')]), isNull, reason: 'everything chosen');
      expect(AccountSelectionSummary.named([e('x', selected: false), e('nostr', selected: false)]), isNull, reason: 'nothing chosen');
      final left = AccountSelectionSummary.named([e('x', selected: false), e('nostr'), e('reddit')])!;
      expect(left.$1, 'Left out');
      expect(left.$2.map((e) => e.label), ['x']);
      final only = AccountSelectionSummary.named([e('x'), e('nostr', selected: false), e('reddit', selected: false)])!;
      expect(only.$1, 'Only');
      expect(only.$2.map((e) => e.label), ['x']);
      // A tie names what is left out.
      expect(AccountSelectionSummary.named([e('x'), e('nostr', selected: false)])!.$1, 'Left out');
    });

    testWidgets('with everything chosen it is one line, about as tall as the old row', (t) async {
      final c = await _boot(t, accounts: _twentyOne());
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      expect(find.text('Left out:'), findsNothing);
      expect(t.getSize(find.byType(AccountSelectionSummary)).height, lessThanOrEqualTo(48.01));
      expect(c.read(composerProvider).selected.length, 21, reason: 'folding changes nothing');
      await _end(t);
    });

    testWidgets('the choice is kept on this device, and never travels', (t) async {
      final storage = _MemoryStorage();
      final c = await _boot(t, accounts: _twentyOne(), storage: storage);
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(c.read(settingsProvider).targetPickerFolded, isTrue);
      expect((storage.json['settings.json']! as Map)['targetPickerFolded'], isTrue);
      await _end(t);
      expect(AppSettings.fromJson(const {'targetPickerFolded': true}).targetPickerFolded, isTrue);
      expect(const AppSettings().toJson().containsKey('targetPickerFolded'), isFalse, reason: 'the default is not written');
      expect(kDeviceOnlySettings.containsKey('targetPickerFolded'), isTrue);
      expect(kExportableSettings.contains('targetPickerFolded'), isFalse);
    });
  });

  group('accounts', () {
    testWidgets('two on one network are two targets, side by side, told apart by handle', (t) async {
      final accounts = [
        _account('mastodon', id: 'work', handle: '@ana@social.example'),
        _account('bluesky'),
        _account('x'),
        _account('mastodon', id: 'home', handle: '@ben@social.example'),
      ];
      final c = await _boot(t, accounts: accounts);
      final work = t.getRect(_cell('work'));
      final home = t.getRect(_cell('home'));
      expect(home.left, greaterThan(work.left), reason: 'in the next column');
      expect(home.top, work.top, reason: 'on the same row');
      expect(find.descendant(of: _cell('work'), matching: find.text('@ana')), findsOneWidget);
      expect(find.descendant(of: _cell('home'), matching: find.text('@ben')), findsOneWidget);
      expect(find.descendant(of: _cell('work'), matching: find.text('Mastodon')), findsOneWidget);
      expect(find.descendant(of: _cell('acct-bluesky'), matching: find.text('Bluesky')), findsOneWidget);
      expect(_entry(t, 'acct-bluesky').handle, isNull);

      await t.tap(_cell('home'));
      await _settle(t);
      final selected = c.read(composerProvider).selected;
      expect(selected, contains('work'));
      expect(selected, isNot(contains('home')));
      await _end(t);
    });

    test('order keeps the user\'s, with siblings together and art sites last', () {
      final a = [
        _account('x'),
        _account('behance'),
        _account('mastodon', id: 'm1'),
        _account('nostr'),
        _account('x', id: 'x2'),
        _account('cara'),
        _account('mastodon', id: 'm2'),
      ];
      final registry = builtinRegistry();
      expect(orderedForAccountGrid(a, (x) => registry.descriptor(x.platformId)!.isArtPlatform).map((x) => x.id),
          ['acct-x', 'x2', 'm1', 'm2', 'acct-nostr', 'acct-behance', 'acct-cara']);
    });

    test('handles shorten only while they stay different', () {
      expect(accountGridHandles([_account('mastodon', handle: '@ana@a.example')]), isEmpty, reason: 'one account needs none');
      expect(
          accountGridHandles([_account('mastodon', id: '1', handle: '@ana@a.example'), _account('mastodon', id: '2', handle: '@ben@a.example')]),
          {'1': '@ana', '2': '@ben'});
      expect(
          accountGridHandles([_account('mastodon', id: '1', handle: '@ana@a.example'), _account('mastodon', id: '2', handle: '@ana@b.example')]),
          {'1': '@ana@a.example', '2': '@ana@b.example'});
      expect(accountGridHandles([_account('bluesky', id: '1', handle: 'ana.bsky.social'), _account('bluesky', id: '2')]), {'1': 'ana.bsky.social', '2': 'bluesky'});
    });

    testWidgets('a disabled account takes no tap, and the quick choices skip it', (t) async {
      final accounts = _twentyOne();
      accounts[15] = _account('lemmy', enabled: false);
      final c = await _boot(t, accounts: accounts);
      expect(c.read(composerProvider).selected, isNot(contains('acct-lemmy')));
      await t.tap(_cell('acct-lemmy'));
      await _settle(t);
      expect(c.read(composerProvider).selected, isNot(contains('acct-lemmy')));
      expect(_entry(t, 'acct-lemmy').semanticLabel, contains('disabled in Accounts'));

      await t.tap(find.widgetWithText(TextButton, 'None'));
      await _settle(t);
      expect(c.read(composerProvider).selected, isEmpty);
      expect(find.text('0 of 21'), findsOneWidget);

      await t.tap(find.widgetWithText(TextButton, 'All'));
      await _settle(t);
      expect(c.read(composerProvider).selected.length, 20);

      await t.tap(find.widgetWithText(TextButton, 'Automatic only'));
      await _settle(t);
      final auto = accounts.where((a) => a.enabled && a.tier != PlatformTier.handoff).map((a) => a.id).toSet();
      expect(c.read(composerProvider).selected, auto);
      await _end(t);
    });

    testWidgets('screen readers hear the name, the tier and the state of each', (t) async {
      final handle = t.ensureSemantics();
      await _boot(t, accounts: [_account('mastodon', handle: '@ana'), _account('instagram'), _account('nostr')]);
      expect(find.bySemanticsLabel(RegExp(r'^Mastodon, @ana, Auto, posting$')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Instagram, Hand-off, posting$')), findsOneWidget);
      await t.tap(_cell('acct-nostr'));
      await _settle(t);
      expect(find.bySemanticsLabel(RegExp(r'^Nostr, Auto, left out$')), findsOneWidget);
      // They can act on it too, on the cell and on the fold, open and folded.
      bool canTap(String label) => t.getSemantics(find.bySemanticsLabel(RegExp(label))).getSemanticsData().hasAction(SemanticsAction.tap);
      expect(canTap(r'^Mastodon, @ana, Auto, posting$'), isTrue);
      expect(canTap(r'Fold the accounts$'), isTrue);
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      expect(canTap(r'Left out Nostr\. Show all accounts$'), isTrue);
      handle.dispose();
      await _end(t);
    });

    testWidgets('a disabled account offers screen readers no action', (t) async {
      final handle = t.ensureSemantics();
      await _boot(t, accounts: [_account('mastodon'), _account('lemmy', enabled: false)]);
      final lemmy = t.getSemantics(find.bySemanticsLabel(RegExp(r'^Lemmy, .*disabled in Accounts$')));
      expect(lemmy.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      handle.dispose();
      await _end(t);
    });

    testWidgets('with reduced motion the grid still folds and chooses', (t) async {
      t.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final c = await _boot(t, accounts: _twentyOne());
      await t.tap(_cell('acct-nostr'));
      await t.pump();
      expect(c.read(composerProvider).selected, isNot(contains('acct-nostr')));
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      expect(_cells, findsNothing);
      await _end(t);
    });
  });

  group('the account\'s photo', () {
    const photo = 'https://avatars.example/a.png';

    testWidgets('several accounts on one network show the photo; a network\'s only account keeps the mark', (t) async {
      final c = await _boot(t, accounts: [
        _account('mastodon', id: 'work', handle: '@ana@social.example', avatarUrl: photo),
        _account('mastodon', id: 'home', handle: '@ben@social.example', avatarUrl: photo),
        _account('mastodon', id: 'none', handle: '@cy@social.example'),
        _account('mastodon', id: 'local', handle: '@di@social.example', avatarUrl: 'mem://a.png'),
        _account('bluesky', avatarUrl: photo),
      ]);
      Finder avatar(String id) => find.descendant(of: _cell(id), matching: find.byType(AccountAvatar));
      expect(avatar('work'), findsOneWidget);
      expect(avatar('home'), findsOneWidget);
      expect(avatar('none'), findsNothing, reason: 'no photo');
      expect(avatar('local'), findsNothing, reason: 'not a photo that can be fetched');
      expect(avatar('acct-bluesky'), findsNothing, reason: 'the only one on its network');
      expect(find.descendant(of: _cell('none'), matching: find.byType(PlatformTile)), findsOneWidget);

      // The cell is no taller or wider for it, and left out fades it.
      expect(t.getSize(_cell('work')), t.getSize(_cell('none')));
      expect(t.widget<AccountAvatar>(avatar('work')).dimmed, isFalse);
      c.read(composerProvider.notifier).toggleAccount('work');
      await _settle(t);
      expect(t.widget<AccountAvatar>(avatar('work')).dimmed, isTrue);

      // The summary shows the same face.
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      expect(find.descendant(of: _summary, matching: find.byType(AccountAvatar)), findsOneWidget);
      expect(t.takeException(), isNull);
      await _end(t);
    });
  });

  group('art sites behave as they do on a computer', () {
    final accounts = [_account('mastodon'), _account('nostr'), _account('behance'), _account('cara')];

    testWidgets('only art sites connected: the count and the summary say nothing untrue', (t) async {
      final handle = t.ensureSemantics();
      await _boot(t, accounts: [_account('behance'), _account('cara')]);
      expect(find.textContaining(' of '), findsNothing);
      expect(find.bySemanticsLabel(RegExp(r'0 of 0')), findsNothing);
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      expect(find.textContaining(' of '), findsNothing);
      expect(find.descendant(of: _summary, matching: find.text('Only art sites connected')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'0 of 0')), findsNothing);
      _expectAtLeastTouchSize(t, find.byKey(kTargetFoldKey), 'the folded summary');
      handle.dispose();
      await _end(t);
    });

    testWidgets('artwork mode with no art site left: it does not claim there are only art sites', (t) async {
      final c = await _boot(t, accounts: [_account('mastodon')]);
      c.read(composerProvider.notifier).setArtwork(const ArtworkDetails());
      await _settle(t);
      expect(_cells, findsNothing);
      expect(find.textContaining(' of '), findsNothing);
      _expectAtLeastTouchSize(t, find.byKey(kTargetFoldKey), 'the fold control');
      await t.tap(find.byKey(kTargetFoldKey));
      await _settle(t);
      expect(find.descendant(of: _summary, matching: find.text('No art sites connected')), findsOneWidget);
      expect(find.text('Only art sites connected'), findsNothing);
      await _end(t);
    });

    testWidgets('the fold control keeps its whole target at the largest text with no count to show', (t) async {
      await _boot(t, accounts: [_account('behance'), _account('cara')], textScale: 1.5);
      _expectAtLeastTouchSize(t, find.byKey(kTargetFoldKey), 'the fold control');
      expect(find.descendant(of: find.byType(TargetPicker), matching: find.text('Post to')), findsOneWidget);
      await _end(t);
    });

    testWidgets('long art site names keep their short form, on one row with the others, at the largest text', (t) async {
      await _boot(t, accounts: [_account('deviantart'), _account('furaffinity'), _account('newgrounds')], textScale: 1.5);
      for (final (id, name) in const [('acct-deviantart', 'Deviant'), ('acct-furaffinity', 'Fur Aff.'), ('acct-newgrounds', 'NG')]) {
        expect(find.descendant(of: _cell(id), matching: find.text(name)), findsOneWidget);
      }
      final top = t.getRect(_cell('acct-deviantart')).top;
      expect(t.getRect(_cell('acct-furaffinity')).top, top);
      expect(t.getRect(_cell('acct-newgrounds')).top, top, reason: 'one long name would drop the section to two columns');
      await _end(t);
    });

    testWidgets('never counted or chosen for an ordinary post, shown apart, and tapping one turns on Artwork with it alone', (t) async {
      final c = await _boot(t, accounts: accounts);
      expect(c.read(composerProvider).selected, {'acct-mastodon', 'acct-nostr'});
      expect(find.text('2 of 2'), findsOneWidget);
      expect(find.text('Art sites: choosing one turns on Artwork'), findsOneWidget);
      expect(_entry(t, 'acct-cara').artSite, isTrue);
      expect(find.descendant(of: _cell('acct-cara'), matching: find.byIcon(Icons.brush_outlined)), findsOneWidget);
      final text = t.widget<Text>(find.descendant(of: _cell('acct-cara'), matching: find.text('Cara')));
      expect(text.style?.decoration, isNot(TextDecoration.lineThrough), reason: 'not chosen, but not left out either');

      await t.tap(find.widgetWithText(TextButton, 'All'));
      await _settle(t);
      expect(c.read(composerProvider).selected, {'acct-mastodon', 'acct-nostr'}, reason: 'All skips art sites');

      await t.tap(_cell('acct-cara'));
      await _settle(t);
      expect(c.read(composerProvider).isArtwork, isTrue);
      expect(c.read(composerProvider).selected, {'acct-cara'});
      expect(_cells, findsNWidgets(2), reason: 'artwork mode shows art sites only');
      expect(find.text('Art sites: choosing one turns on Artwork'), findsNothing);
      expect(find.text('1 of 2'), findsOneWidget);

      await t.tap(_cell('acct-behance'));
      await _settle(t);
      expect(c.read(composerProvider).selected, {'acct-cara', 'acct-behance'}, reason: 'in artwork mode a tap chooses it');
      await _end(t);
    });

    for (final scale in const [1.0, 1.5]) {
      testWidgets('artwork choices have no overflow and whole touch targets, text x$scale', (t) async {
        await _boot(t, accounts: accounts, textScale: scale);
        await t.ensureVisible(find.byKey(TargetPicker.artworkSwitchKey));
        await t.pump();
        await t.tap(find.byKey(TargetPicker.artworkSwitchKey));
        await _settle(t);
        for (final label in const ['General', 'Made with AI', 'Ask not to train AI']) {
          expect(find.text(label), findsOneWidget);
        }
        expect(t.getSize(find.byType(FilterChip).first).height, greaterThanOrEqualTo(48));
        expect(t.getSize(find.byType(SegmentedButton<ArtworkMaturity>)).height, greaterThanOrEqualTo(48));
        expect(t.takeException(), isNull);
        await _end(t);
      });
    }
  });

  group('columns', () {
    test('as many as the names allow, never below 2', () {
      expect(accountGridColumns(328, 60), 4);
      expect(accountGridColumns(328, 96), 3);
      expect(accountGridColumns(328, 300), 2);
      expect(accountGridColumns(288, 60), 3, reason: 'a 320 px phone');
      expect(accountGridColumns(680, 60), 9, reason: 'wide phones do not stretch four cells');
    });

    for (final scale in const [1.0, 1.5]) {
      testWidgets('all of the catalog\'s names read whole at 360 px, text x$scale', (t) async {
        final registry = builtinRegistry();
        // Every platform, so a long new name without a shortName fails here.
        final accounts = [for (final d in registry.descriptors) _account(d.id)];
        await _boot(t, accounts: accounts, textScale: scale);
        for (final a in accounts) {
          final label = _entry(t, a.id).label;
          final paragraph = t.renderObject<RenderParagraph>(find.descendant(of: _cell(a.id), matching: find.text(label)));
          expect(paragraph.didExceedMaxLines, isFalse, reason: label);
          _expectAtLeastTouchSize(t, _cell(a.id), label);
        }
        await _end(t);
      });
    }

    for (final (scale, columns) in const [(1.0, 4), (1.5, 3)]) {
      testWidgets('21 ordinary names take $columns columns at text x$scale', (t) async {
        await _boot(t, accounts: _twentyOne(), textScale: scale);
        final top = t.getRect(_cell('acct-mastodon')).top;
        final firstRow = t.elementList(_cells).where((e) => (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy == top);
        expect(firstRow.length, columns);
        await _end(t);
      });
    }

    testWidgets('one long art site name leaves the ordinary accounts as they are', (t) async {
      final accounts = [..._twentyOne().take(20), _account('artstation')];
      await _boot(t, accounts: accounts);
      final top = t.getRect(_cell('acct-mastodon')).top;
      expect(t.elementList(_cells).where((e) => (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy == top).length, 4);
      final name = t.renderObject<RenderParagraph>(find.descendant(of: _cell('acct-artstation'), matching: find.text('ArtStation')));
      expect(name.didExceedMaxLines, isFalse);
      expect(name.getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 10)).map((b) => b.top).toSet().length, 1);
      await _end(t);
    });

    testWidgets('choosing does not move the grid', (t) async {
      final c = await _boot(t, accounts: _twentyOne());
      final before = t.getRect(_cell('acct-matrix'));
      c.read(composerProvider.notifier).toggleAccount('acct-threads');
      c.read(composerProvider.notifier).toggleAccount('acct-matrix');
      await _settle(t);
      expect(t.getRect(_cell('acct-matrix')), before);
      await _end(t);
    });
  });

  group('wider windows keep the chips', () {
    Future<void> check(WidgetTester t, Size size) async {
      final c = await _boot(t, accounts: _twentyOne(), size: size);
      final picker = find.byType(TargetPicker);
      expect(find.descendant(of: picker, matching: find.byType(AccountChip)), findsNWidgets(21));
      expect(find.descendant(of: picker, matching: _cells), findsNothing);
      expect(find.descendant(of: picker, matching: find.byType(Wrap)), findsWidgets);
      expect(find.byType(AccountSelectionSummary), findsNothing);
      expect(find.byKey(kTargetFoldKey), findsNothing);
      await t.tap(find.descendant(of: picker, matching: find.byWidgetPredicate((w) => w is AccountChip && w.account.id == 'acct-nostr')));
      await _settle(t);
      expect(c.read(composerProvider).selected, isNot(contains('acct-nostr')));
      await _end(t);
    }

    testWidgets('a computer', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await check(t, const Size(1440, 900));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a tablet', (t) => check(t, const Size(900, 700)));
  });
}
