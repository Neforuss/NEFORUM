// The phone composer's account tiles: every account on screen at 360 x 640,
// no sideways scrolling, states readable without colour, the fold, the filter,
// and wider windows keeping their chips.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/brand/platform_brand.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/account_tile_grid.dart';
import 'package:neforum_app/ui/compose/action_bar.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/compose/target_picker.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/widgets/badges.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  _MemoryStorage(Map<String, Object> settings) : json = {'settings.json': settings};
  final Map<String, Object> json;
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
  await family('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf']);
}

var _order = 0;

ConnectedAccount _account(String platformId, PlatformTier tier, {String? id, String? handle, bool enabled = true}) => ConnectedAccount(
      id: id ?? platformId,
      platformId: platformId,
      tier: tier,
      displayName: handle ?? platformId,
      handle: handle,
      // The order they are stored in is the order they are listed in.
      createdAt: DateTime.utc(2026, 10, 1).add(Duration(minutes: _order++)),
      enabled: enabled,
    );

/// 21 accounts on 21 networks, with all three common tiers.
List<ConnectedAccount> _twentyOne() => [
      for (final (id, tier) in const [
        ('mastodon', PlatformTier.openApi),
        ('bluesky', PlatformTier.openApi),
        ('x', PlatformTier.byokApi),
        ('threads', PlatformTier.byokApi),
        ('linkedin', PlatformTier.byokApi),
        ('facebook', PlatformTier.handoff),
        ('instagram', PlatformTier.handoff),
        ('tiktok', PlatformTier.handoff),
        ('youtube', PlatformTier.byokApi),
        ('reddit', PlatformTier.byokApi),
        ('pinterest', PlatformTier.byokApi),
        ('tumblr', PlatformTier.byokApi),
        ('telegram', PlatformTier.openApi),
        ('discord', PlatformTier.openApi),
        ('lemmy', PlatformTier.openApi),
        ('misskey', PlatformTier.openApi),
        ('nostr', PlatformTier.openApi),
        ('matrix', PlatformTier.openApi),
        ('wordpress', PlatformTier.openApi),
        ('substack', PlatformTier.handoff),
        ('whatsapp', PlatformTier.handoff),
      ])
        _account(id, tier),
    ];

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// The composer on [accounts] and nothing else, with a new post.
Future<(ProviderContainer, _MemoryStorage)> _boot(
  WidgetTester tester, {
  required List<ConnectedAccount> accounts,
  Size size = const Size(360, 640),
  double textScale = 1,
  Brightness brightness = Brightness.light,
  Map<String, Object> settings = const {},
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  final storage = _MemoryStorage({'mobileTextScale': textScale, ...settings});
  final services = (await tester.runAsync(() async {
    final s = await AppServices.create(demo: true, storage: storage);
    for (final a in await s.accounts.all()) {
      await s.accounts.delete(a.id);
    }
    for (final a in accounts) {
      await s.accounts.upsert(a);
    }
    return s;
  }))!;
  await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
  await tester.pump(const Duration(milliseconds: 300));
  final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  await _settle(tester);
  c.read(composerProvider.notifier).reset(keepTargets: false);
  c.read(routerProvider).go('/compose');
  await _settle(tester);
  return (c, storage);
}

Finder _tile(String id) => find.byKey(AccountTile.keyFor(id));
final _tiles = find.byType(AccountTile);
final _summary = find.byKey(const ValueKey('target-picker-summary'));
final _fold = find.byKey(TargetPicker.foldKey);
final _picker = find.byType(TargetPicker);
final _editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);

Set<String> _selected(ProviderContainer c) => c.read(composerProvider).selected;

/// A tap at the middle of [f] really lands on it.
void _expectHittable(WidgetTester tester, Finder f) {
  final target = tester.renderObject(f);
  final hit = tester.hitTestOnBinding(tester.getCenter(f));
  expect(hit.path.any((e) => e.target == target), isTrue, reason: '${f.describeMatch(Plurality.one)} takes the tap');
}

void _expectTarget(WidgetTester tester, Finder f) {
  final size = tester.getRect(f).size;
  expect(size.width, greaterThanOrEqualTo(48), reason: '$f width');
  expect(size.height, greaterThanOrEqualTo(48), reason: '$f height');
  _expectHittable(tester, f);
}

/// The text field's caret is on screen: below the Write and Preview tabs and
/// above the action [bar], which sits on the keyboard.
void _expectCaretInView(WidgetTester tester, Rect bar) {
  final state = tester.state<EditableTextState>(find.descendant(of: _editor, matching: find.byType(EditableText)));
  final box = state.renderEditable;
  final selection = state.textEditingValue.selection;
  final offset = selection.isValid ? selection.extent : const TextPosition(offset: 0);
  final caret = box.localToGlobal(box.getLocalRectForCaret(offset).center);
  final tabs = tester.getRect(find.text('Write'));
  expect(caret.dy, greaterThan(tabs.bottom), reason: 'the caret is below the tabs');
  expect(caret.dy, lessThan(bar.top), reason: 'the caret is above the action bar');
}

void main() {
  setUpAll(_loadFonts);

  group('layout rules', () {
    test('a 360 wide phone holds 6 columns of 53, a 320 wide one 5', () {
      expect(accountTileColumns(328), 6);
      expect((328 - 5 * kAccountTileGap) / 6, 53);
      expect(accountTileColumns(288), 5);
      expect(accountTileColumns(10), 1, reason: 'never zero');
    });

    test('accounts on one network sit together, in their own order', () {
      final accounts = [
        _account('mastodon', PlatformTier.openApi, id: 'm1'),
        _account('x', PlatformTier.byokApi, id: 'x1'),
        _account('mastodon', PlatformTier.openApi, id: 'm2'),
        _account('bluesky', PlatformTier.openApi, id: 'b1'),
        _account('x', PlatformTier.handoff, id: 'x2'),
      ];
      expect(groupedByNetwork(accounts).map((a) => a.id), ['m1', 'm2', 'x1', 'x2', 'b1']);
    });

    test('a tile says the short name, or the handle when a network has several accounts', () {
      final labels = accountTileLabels([
        _account('x', PlatformTier.byokApi, id: 'x1'),
        _account('mastodon', PlatformTier.openApi, id: 'm1', handle: '@ana@one.example'),
        _account('mastodon', PlatformTier.openApi, id: 'm2', handle: '@ben@two.example'),
        _account('bluesky', PlatformTier.openApi, id: 'b1', handle: 'studio_acme_news'),
        _account('bluesky', PlatformTier.openApi, id: 'b2', handle: 'studio_acme_art'),
        _account('threads', PlatformTier.byokApi, id: 't1', handle: 'same_handle_long'),
        _account('threads', PlatformTier.byokApi, id: 't2', handle: 'same_handle_long'),
      ], builtinRegistry());
      expect(labels['x1'], 'X');
      expect(labels['m1'], 'ana@one.example');
      expect(labels['m2'], 'ben@two.example');
      expect(labels['b1'], '…news', reason: 'the start they share would fill the whole tile');
      expect(labels['b2'], '…art');
      expect(labels['t1']!.length, greaterThan(1), reason: 'identical handles keep something to show');
    });

    test('the summary names the shorter list', () {
      final accounts = [for (var i = 0; i < 5; i++) _account('mastodon', PlatformTier.openApi, id: 'a$i')];
      final ids = [for (final a in accounts) a.id];
      void check(Set<String> selected, bool leftOut, List<String> named) {
        final f = foldedAccounts(accounts, selected);
        expect(f.leftOut, leftOut, reason: '$selected');
        expect(f.accounts.map((a) => a.id), named, reason: '$selected');
      }

      check(ids.toSet(), true, const []);
      check(ids.toSet()..remove('a1'), true, const ['a1']);
      check({'a0', 'a1', 'a2'}, true, const ['a3', 'a4']);
      check({'a0', 'a1'}, false, const ['a0', 'a1']);
      check(const {}, false, const []);
    });

    testWidgets('every network\'s short name fits a tile whole at the normal text size', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Builder(builder: (c) {
          context = c;
          return const SizedBox.shrink();
        }),
      ));
      final style = accountTileLabelStyle(context);
      expect(style.fontFamily, Fonts.body, reason: 'measured in the real font');
      final room = 53 - 2 * kAccountTileBorderRoom;
      final tooLong = <String>[];
      for (final adapter in builtinAdapters()) {
        final name = adapter.descriptor.compactName;
        final painter = TextPainter(text: TextSpan(text: name, style: style), textDirection: TextDirection.ltr)..layout();
        if (painter.width > room) tooLong.add('$name ${painter.width}');
        painter.dispose();
      }
      expect(tooLong, isEmpty);
    });
  });

  for (final scale in const [1.0, 1.5]) {
    group('21 accounts at 360 x 640, text scale $scale', () {
      testWidgets('leaving out 3 of 21 takes 3 taps from the default state', (tester) async {
        final (c, _) = await _boot(tester, accounts: _twentyOne(), textScale: scale);
        expect(_selected(c).length, 21);

        var taps = 0;
        Future<void> tap(Finder f) async {
          taps++;
          _expectHittable(tester, f);
          await tester.tap(f);
          await _settle(tester);
        }

        // Spread out: first, middle, last.
        for (final id in const ['mastodon', 'reddit', 'whatsapp']) {
          await tap(_tile(id));
        }
        expect(taps, lessThanOrEqualTo(5));
        expect(taps, 3);
        expect(_selected(c).length, 18);
        expect(_selected(c), isNot(anyOf(contains('mastodon'), contains('reddit'), contains('whatsapp'))));
        expect(find.descendant(of: _picker, matching: find.text('18 of 21')), findsOneWidget);
        await _unmount(tester);
      });

      testWidgets('nothing under the picker scrolls, and sideways least of all', (tester) async {
        await _boot(tester, accounts: _twentyOne(), textScale: scale);
        expect(_tiles, findsNWidgets(21), reason: 'built, not waiting to be scrolled to');
        final scrollables = find.descendant(of: _picker, matching: find.byType(Scrollable));
        final horizontal = tester.widgetList<Scrollable>(scrollables).where((s) => axisDirectionToAxis(s.axisDirection) == Axis.horizontal);
        expect(horizontal, isEmpty);
        expect(scrollables, findsNothing, reason: 'the page scrolls, not the picker');
        await _unmount(tester);
      });

      testWidgets('every account is on screen at once, with its states, on a 48 x 48 target', (tester) async {
        final accounts = _twentyOne();
        accounts[4] = accounts[4].copyWith(enabled: false); // LinkedIn
        final (c, _) = await _boot(tester, accounts: accounts, textScale: scale);
        c.read(composerProvider.notifier).toggleAccount('reddit');
        await _settle(tester);

        final limit = tester.getRect(find.byType(ComposerActionBar)).top;
        final semantics = tester.ensureSemantics();
        for (final a in accounts) {
          final tile = _tile(a.id);
          expect(tester.getRect(tile).bottom, lessThanOrEqualTo(limit), reason: '${a.id} is above the action bar without scrolling');
          _expectTarget(tester, tile);

          // Tier: its own glyph, whatever the colour.
          expect(find.descendant(of: tile, matching: find.byIcon(tierIcon(a.tier))), findsOneWidget, reason: a.id);

          final posting = _selected(c).contains(a.id);
          final check = find.descendant(of: tile, matching: find.byIcon(Icons.check_circle_rounded));
          final block = find.descendant(of: tile, matching: find.byIcon(Icons.block_rounded));
          final platformTile = tester.widget<PlatformTile>(find.descendant(of: tile, matching: find.byType(PlatformTile)));
          if (!a.enabled) {
            expect(block, findsOneWidget, reason: '${a.id}: a block sign says disabled');
            expect(check, findsNothing);
            expect(platformTile.dimmed, isTrue);
          } else {
            expect(block, findsNothing);
            expect(check, posting ? findsOneWidget : findsNothing, reason: '${a.id}: a check says selected');
            expect(platformTile.dimmed, !posting, reason: '${a.id}: faded when left out');
          }

          // The same, for a screen reader.
          final name = c.read(registryProvider).descriptor(a.platformId)!.name;
          final state = !a.enabled ? 'disabled in Accounts' : (posting ? 'posting' : 'left out');
          expect(
            tester.getSemantics(tile),
            isSemantics(label:'$name, ${a.displayName}, ${tierShortLabel(a.tier)}, $state', isButton: true, isSelected: posting, hasTapAction: a.enabled),
          );
        }
        semantics.dispose();

        // A disabled tile takes no tap.
        await tester.tap(_tile('linkedin'));
        await _settle(tester);
        expect(_selected(c), isNot(contains('linkedin')));

        // The rest of the picker keeps to 48 x 48 as well.
        for (final label in const ['All', 'Automatic only', 'None']) {
          _expectTarget(tester, find.widgetWithText(TextButton, label));
        }
        _expectTarget(tester, _fold);
        await _unmount(tester);
      });

      testWidgets('the artwork controls are 48 x 48 too', (tester) async {
        final accounts = [..._twentyOne().take(4), _account('behance', PlatformTier.handoff), _account('cara', PlatformTier.handoff)];
        final (c, _) = await _boot(tester, accounts: accounts, textScale: scale);
        _expectTarget(tester, find.byKey(TargetPicker.artworkSwitchKey));
        await tester.tap(find.byKey(TargetPicker.artworkSwitchKey));
        await _settle(tester);
        expect(c.read(composerProvider).isArtwork, isTrue);
        for (final f in [find.byKey(TargetPicker.artworkSwitchKey), find.byType(FilterChip).first, find.byType(FilterChip).last]) {
          await tester.ensureVisible(f);
          await _settle(tester);
          final size = tester.getRect(f).size;
          expect(size.height, greaterThanOrEqualTo(48), reason: '$f');
          expect(size.width, greaterThanOrEqualTo(48), reason: '$f');
        }
        await _unmount(tester);
      });

      testWidgets('light and dark, folded and open: no overflow', (tester) async {
        for (final brightness in Brightness.values) {
          final accounts = _twentyOne();
          final (c, _) = await _boot(tester, accounts: accounts, textScale: scale, brightness: brightness);
          // Ten left out: the longest list the summary can hold at 21.
          c.read(composerProvider.notifier).selectAccounts([for (final a in accounts.take(11)) a.id]);
          await _settle(tester);
          await tester.tap(_fold);
          await _settle(tester);
          expect(_summary, findsOneWidget);
          await tester.tap(_fold);
          await _settle(tester);
          expect(_tiles, findsNWidgets(21));
          await _unmount(tester);
        }
      });
    });
  }

  group('several accounts on one network, and art sites', () {
    testWidgets('two accounts on one network stay two targets, side by side', (tester) async {
      final (c, _) = await _boot(tester, accounts: [
        _account('mastodon', PlatformTier.openApi, id: 'm1', handle: '@ana@one.example'),
        _account('x', PlatformTier.byokApi),
        _account('bluesky', PlatformTier.openApi),
        _account('mastodon', PlatformTier.handoff, id: 'm2', handle: '@ben@two.example'),
      ]);
      expect(tester.getRect(_tile('m2')).left, tester.getRect(_tile('m1')).right + kAccountTileGap, reason: 'neighbours though stored apart');
      expect(find.descendant(of: _tile('m1'), matching: find.text('ana@one.example')), findsOneWidget);
      expect(find.descendant(of: _tile('m2'), matching: find.text('ben@two.example')), findsOneWidget);
      // Each keeps its own tier.
      expect(find.descendant(of: _tile('m1'), matching: find.byIcon(tierIcon(PlatformTier.openApi))), findsOneWidget);
      expect(find.descendant(of: _tile('m2'), matching: find.byIcon(tierIcon(PlatformTier.handoff))), findsOneWidget);

      await tester.tap(_tile('m1'));
      await _settle(tester);
      expect(_selected(c), {'x', 'bluesky', 'm2'});
      await tester.tap(_tile('m2'));
      await _settle(tester);
      expect(_selected(c), {'x', 'bluesky'});
      await tester.tap(_tile('m1'));
      await _settle(tester);
      expect(_selected(c), {'x', 'bluesky', 'm1'});

      // Folded, the summary tells them apart too.
      await tester.tap(_fold);
      await _settle(tester);
      expect(find.descendant(of: _summary, matching: find.text('Left out:')), findsOneWidget);
      expect(find.descendant(of: _summary, matching: find.text('ben@two.example')), findsOneWidget);
      await _unmount(tester);
    });

    List<ConnectedAccount> mixed() => [
          _account('mastodon', PlatformTier.openApi),
          _account('behance', PlatformTier.handoff),
          _account('instagram', PlatformTier.handoff),
          _account('cara', PlatformTier.handoff),
          _account('pixiv', PlatformTier.handoff, enabled: false),
        ];

    testWidgets('art sites sit apart, stay out of All and the count, and choosing one turns artwork mode on', (tester) async {
      final (c, _) = await _boot(tester, accounts: mixed());
      expect(_selected(c), {'mastodon', 'instagram'});
      expect(find.descendant(of: _picker, matching: find.text('Art sites')), findsOneWidget);
      expect(find.descendant(of: _picker, matching: find.text('2 of 2')), findsOneWidget, reason: 'art sites are not for an ordinary post');
      expect(tester.getRect(_tile('behance')).top, greaterThan(tester.getRect(_tile('instagram')).bottom), reason: 'below the ordinary accounts');
      expect(find.descendant(of: _tile('behance'), matching: find.byIcon(Icons.brush_outlined)), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'None'));
      await _settle(tester);
      expect(_selected(c), isEmpty);
      await tester.tap(find.widgetWithText(TextButton, 'All'));
      await _settle(tester);
      expect(_selected(c), {'mastodon', 'instagram'}, reason: 'All skips art sites');
      await tester.tap(find.widgetWithText(TextButton, 'Automatic only'));
      await _settle(tester);
      expect(_selected(c), {'mastodon'});

      // A disabled art site takes no tap.
      await tester.tap(_tile('pixiv'));
      await _settle(tester);
      expect(c.read(composerProvider).isArtwork, isFalse);

      await tester.tap(_tile('cara'));
      await _settle(tester);
      expect(c.read(composerProvider).isArtwork, isTrue);
      expect(_selected(c), {'cara'});
      expect(_tiles, findsNWidgets(3), reason: 'only art sites in artwork mode');
      expect(find.descendant(of: _picker, matching: find.text('Art sites')), findsNothing);
      expect(find.descendant(of: _picker, matching: find.text('1 of 3')), findsOneWidget);
      expect(find.descendant(of: _tile('cara'), matching: find.byIcon(Icons.brush_outlined)), findsNothing, reason: 'choosing it no longer turns anything on');

      // In artwork mode a tile toggles, as a chip does.
      await tester.tap(_tile('behance'));
      await _settle(tester);
      expect(_selected(c), {'cara', 'behance'});
      await tester.tap(_tile('cara'));
      await _settle(tester);
      expect(_selected(c), {'behance'});
      expect(c.read(composerProvider).isArtwork, isTrue);

      // And back.
      await tester.ensureVisible(find.byKey(TargetPicker.artworkSwitchKey));
      await tester.tap(find.byKey(TargetPicker.artworkSwitchKey));
      await _settle(tester);
      expect(c.read(composerProvider).isArtwork, isFalse);
      expect(_selected(c), {'mastodon', 'instagram'});
      await _unmount(tester);
    });

    testWidgets('only art sites connected: the count and the summary say nothing untrue', (tester) async {
      await _boot(tester, accounts: [_account('behance', PlatformTier.handoff), _account('cara', PlatformTier.handoff)]);
      expect(find.textContaining(' of '), findsNothing);
      await tester.tap(_fold);
      await _settle(tester);
      expect(find.descendant(of: _summary, matching: find.text('Only art sites connected')), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('the fold', () {
    testWidgets('the user folds: "18 of 21" and exactly who is left out, and the choice is kept on this device only', (tester) async {
      final (c, storage) = await _boot(tester, accounts: _twentyOne());
      for (final id in const ['mastodon', 'reddit', 'whatsapp']) {
        await tester.tap(_tile(id));
        await _settle(tester);
      }
      await tester.tap(_fold);
      await _settle(tester);

      expect(_tiles, findsNothing);
      expect(find.descendant(of: _summary, matching: find.text('18 of 21')), findsOneWidget);
      expect(find.descendant(of: _summary, matching: find.text('Left out:')), findsOneWidget);
      final named = find.descendant(of: _summary, matching: find.byType(AccountTileFace));
      expect(tester.widgetList<AccountTileFace>(named).map((f) => f.account.id), ['mastodon', 'reddit', 'whatsapp']);
      _expectTarget(tester, _fold);

      // The screen reader hears all of it.
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp(r'^18 of 21 accounts selected\. Left out: Mastodon .*, Reddit .*, WhatsApp ')), findsOneWidget);
      semantics.dispose();

      // Kept, and not for other devices.
      expect(c.read(settingsProvider).composerTargetsFolded, isTrue);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect((storage.json['settings.json']! as Map)['composerTargetsFolded'], isTrue);
      expect(kDeviceOnlySettings.containsKey('composerTargetsFolded'), isTrue);
      expect(exportableSettings(c.read(settingsProvider)).containsKey('composerTargetsFolded'), isFalse);

      // Chevron, then the tiles again.
      await tester.tap(_fold);
      await _settle(tester);
      expect(_tiles, findsNWidgets(21));
      expect(c.read(settingsProvider).composerTargetsFolded, isFalse);
      await _unmount(tester);
    });

    testWidgets('folded by choice at launch, leaving out 3 takes 4 taps', (tester) async {
      final (c, _) = await _boot(tester, accounts: _twentyOne(), settings: {'composerTargetsFolded': true});
      expect(find.descendant(of: _summary, matching: find.text('All selected')), findsOneWidget);
      var taps = 0;
      Future<void> tap(Finder f) async {
        taps++;
        await tester.tap(f);
        await _settle(tester);
      }

      await tap(_fold);
      for (final id in const ['x', 'lemmy', 'substack']) {
        await tap(_tile(id));
      }
      expect(taps, 4);
      expect(_selected(c).length, 18);
      await _unmount(tester);
    });

    testWidgets('a tap on the summary opens it too, and few chosen reads "Only:"', (tester) async {
      final (c, _) = await _boot(tester, accounts: _twentyOne(), settings: {'composerTargetsFolded': true});
      c.read(composerProvider.notifier).selectAccounts(const ['x']);
      await _settle(tester);
      expect(find.descendant(of: _summary, matching: find.text('Only:')), findsOneWidget);
      expect(find.descendant(of: _summary, matching: find.text('1 of 21')), findsOneWidget);
      expect(tester.widget<AccountTileFace>(find.descendant(of: _summary, matching: find.byType(AccountTileFace))).account.id, 'x');
      c.read(composerProvider.notifier).selectAccounts(const []);
      await _settle(tester);
      expect(find.descendant(of: _summary, matching: find.text('None selected')), findsOneWidget);

      await tester.tap(find.descendant(of: _summary, matching: find.text('0 of 21')));
      await _settle(tester);
      expect(_tiles, findsNWidgets(21));
      await _unmount(tester);
    });

    testWidgets('a disabled account in the summary says so', (tester) async {
      final accounts = _twentyOne();
      accounts[2] = accounts[2].copyWith(enabled: false);
      await _boot(tester, accounts: accounts, settings: {'composerTargetsFolded': true});
      expect(find.descendant(of: _summary, matching: find.text('20 of 21')), findsOneWidget);
      expect(find.descendant(of: _summary, matching: find.byIcon(Icons.block_rounded)), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('with the phone keyboard open', () {
    void keyboard(WidgetTester tester, double height) => tester.view.viewInsets = FakeViewPadding(bottom: height);

    testWidgets('the tiles fold, the text field and the action bar stay usable, and the tiles come back', (tester) async {
      final (c, _) = await _boot(tester, accounts: _twentyOne());
      c.read(composerProvider.notifier).toggleAccount('mastodon');
      await _settle(tester);

      // 21 tiles push the text field down: the page scrolls to it.
      await tester.ensureVisible(_editor);
      await _settle(tester);
      await tester.tap(_editor);
      keyboard(tester, 280);
      await _settle(tester);

      const keyboardTop = 640.0 - 280;
      expect(_tiles, findsNothing);
      expect(find.descendant(of: _summary, matching: find.text('20 of 21')), findsOneWidget);
      final bar = tester.getRect(find.byType(ComposerActionBar));
      expect(bar.bottom, lessThanOrEqualTo(keyboardTop));
      _expectCaretInView(tester, bar);

      await tester.enterText(_editor, 'Typed with the keyboard open.');
      await _settle(tester);
      expect(c.read(composerProvider).text, 'Typed with the keyboard open.');
      expect(_tiles, findsNothing, reason: 'typing does not bring them back');
      _expectCaretInView(tester, bar);

      // The fold button overrides, only while the keyboard shows.
      await tester.ensureVisible(_fold);
      await _settle(tester);
      await tester.tap(_fold);
      await _settle(tester);
      expect(_tiles, findsNWidgets(21));
      expect(c.read(settingsProvider).composerTargetsFolded, isFalse, reason: 'not a lasting choice');
      await tester.ensureVisible(_tile('whatsapp'));
      await _settle(tester);
      await tester.tap(_tile('whatsapp'));
      await _settle(tester);
      expect(_selected(c), isNot(contains('whatsapp')));

      keyboard(tester, 0);
      await _settle(tester);
      expect(_tiles, findsNWidgets(21));
      expect(_summary, findsNothing);

      // The next keyboard folds again.
      keyboard(tester, 280);
      await _settle(tester);
      expect(_tiles, findsNothing);
      keyboard(tester, 0);
      await _settle(tester);
      await _unmount(tester);
    });

    // The tiles fold within the frame: a height animation moved the field out
    // of view after it had scrolled its caret into view.
    testWidgets('a long post scrolled to its end keeps the caret in view when the tiles fold', (tester) async {
      await _boot(tester, accounts: _twentyOne());
      await tester.ensureVisible(_editor);
      await _settle(tester);
      await tester.enterText(_editor, List.generate(30, (i) => 'Line $i of a long post').join('\n'));
      await _settle(tester);
      keyboard(tester, 280);
      await _settle(tester);
      expect(_tiles, findsNothing);
      _expectCaretInView(tester, tester.getRect(find.byType(ComposerActionBar)));
      keyboard(tester, 0);
      await _settle(tester);
      await _unmount(tester);
    });

    testWidgets('folding takes its height at once and fades in', (tester) async {
      await _boot(tester, accounts: _twentyOne());
      final open = tester.getSize(_picker).height;
      await tester.tap(_fold);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final midway = tester.getSize(_picker).height;
      final fade = tester.widget<FadeTransition>(find.ancestor(of: _summary, matching: find.byType(FadeTransition)).first);
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      await _settle(tester);
      expect(midway, lessThan(open));
      expect(midway, tester.getSize(_picker).height);
      await _unmount(tester);
    });

    testWidgets('the system setting for less motion: the fold works, without any animation', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await _boot(tester, accounts: _twentyOne());
      await tester.tap(_fold);
      await tester.pump();
      expect(_summary, findsOneWidget);
      expect(_tiles, findsNothing);
      await tester.tap(_fold);
      await tester.pump();
      expect(_tiles, findsNWidgets(21));
      await _unmount(tester);
    });

    testWidgets('over the keyboard the artwork controls step aside, and come back', (tester) async {
      final (c, _) = await _boot(tester, accounts: [_account('behance', PlatformTier.handoff), _account('cara', PlatformTier.handoff)]);
      await tester.tap(find.byKey(TargetPicker.artworkSwitchKey));
      await _settle(tester);
      expect(c.read(composerProvider).isArtwork, isTrue);
      expect(find.text('Made with AI'), findsOneWidget);
      keyboard(tester, 280);
      await _settle(tester);
      expect(find.text('Made with AI'), findsNothing);
      expect(find.byKey(TargetPicker.artworkSwitchKey), findsNothing);
      keyboard(tester, 0);
      await _settle(tester);
      expect(find.text('Made with AI'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('folded by choice: artwork controls stay when there is no keyboard', (tester) async {
      await _boot(tester, accounts: [_account('mastodon', PlatformTier.openApi), _account('behance', PlatformTier.handoff)], settings: {'composerTargetsFolded': true});
      expect(_summary, findsOneWidget);
      expect(find.byKey(TargetPicker.artworkSwitchKey), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('the filter field', () {
    List<ConnectedAccount> many(int n) => [
          for (var i = 0; i < n; i++)
            _account('mastodon', i.isEven ? PlatformTier.openApi : PlatformTier.handoff, id: 'm$i', handle: i < 3 ? '@alpha$i@one.example' : '@user$i@two.example'),
        ];
    final filter = find.byKey(TargetPicker.filterKey);

    testWidgets('24 accounts have none, 25 have one', (tester) async {
      await _boot(tester, accounts: many(24));
      expect(filter, findsNothing);
      await _unmount(tester);
      await _boot(tester, accounts: many(25));
      expect(filter, findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('it narrows the tiles, All and None act on the matches and it says so, and its keyboard does not fold it', (tester) async {
      final (c, _) = await _boot(tester, accounts: many(30));
      await tester.tap(filter);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await _settle(tester);
      expect(filter, findsOneWidget, reason: 'its own keyboard leaves it in place');
      expect(_tiles, findsNWidgets(30));

      await tester.enterText(filter, 'alpha');
      await _settle(tester);
      expect(_tiles, findsNWidgets(3));
      expect(find.text('All, Automatic only and None act on the 3 shown'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'None'));
      await _settle(tester);
      expect(_selected(c).length, 27);
      expect(_selected(c), isNot(anyOf(contains('m0'), contains('m1'), contains('m2'))));
      expect(find.descendant(of: _picker, matching: find.text('27 of 30')), findsOneWidget, reason: 'the count stays about all of them');

      await tester.tap(find.widgetWithText(TextButton, 'Automatic only'));
      await _settle(tester);
      expect(_selected(c), containsAll(const ['m0', 'm2']));
      expect(_selected(c), isNot(contains('m1')), reason: 'the hand-off one');
      expect(_selected(c).length, 29);

      await tester.tap(find.widgetWithText(TextButton, 'All'));
      await _settle(tester);
      expect(_selected(c).length, 30);

      await tester.enterText(filter, 'nothing like this');
      await _settle(tester);
      expect(find.text('No account matches.'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear'));
      await _settle(tester);
      expect(_tiles, findsNWidgets(30));
      expect(find.textContaining('act on the'), findsNothing);

      // The fold button works while typing in the filter too.
      await tester.ensureVisible(_fold);
      await _settle(tester);
      await tester.tap(_fold);
      await _settle(tester);
      expect(_tiles, findsNothing);
      expect(filter, findsNothing);
      expect(_summary, findsOneWidget);

      tester.view.viewInsets = FakeViewPadding.zero;
      await _settle(tester);
      await _unmount(tester);
    });
  });

  group('wider windows keep the chips', () {
    Future<void> expectChips(WidgetTester tester, Size size) async {
      final accounts = _twentyOne();
      final (c, _) = await _boot(tester, accounts: accounts, size: size);
      final chips = find.descendant(of: _picker, matching: find.byType(AccountChip));
      expect(chips, findsNWidgets(21));
      expect(_tiles, findsNothing);
      expect(_fold, findsNothing);
      expect(find.descendant(of: _picker, matching: find.byType(Wrap)), findsWidgets);
      expect(find.descendant(of: _picker, matching: find.byType(Scrollable)), findsNothing);
      // The chip is still 40 high, and the quick choices keep their size.
      expect(tester.getSize(chips.first).height, 40);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'None')).style!.minimumSize!.resolve(const {}), const Size(0, 30));
      await tester.tap(find.byWidgetPredicate((w) => w is AccountChip && w.account.id == 'mastodon'));
      await _settle(tester);
      expect(_selected(c), isNot(contains('mastodon')));
      await _unmount(tester);
    }

    testWidgets('desktop', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await expectChips(tester, const Size(1440, 900));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a medium window', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await expectChips(tester, const Size(900, 700));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a tablet', (tester) async {
      await expectChips(tester, const Size(900, 700));
    });

    testWidgets('a desktop window narrowed to phone width gets the tiles, never a sideways row', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await _boot(tester, accounts: _twentyOne(), size: const Size(500, 800));
      expect(_tiles, findsNWidgets(21));
      expect(find.descendant(of: _picker, matching: find.byType(Scrollable)), findsNothing);
      await _unmount(tester);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the count leaves out art sites on the chips too', (tester) async {
      await _boot(tester, accounts: [_account('mastodon', PlatformTier.openApi), _account('behance', PlatformTier.handoff)], size: const Size(1440, 900));
      expect(find.descendant(of: _picker, matching: find.text('1 of 1')), findsOneWidget);
      await _unmount(tester);
    });
  });
}
