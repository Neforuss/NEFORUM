// 1.4.3: Post / Story / Post + Story sticks and is in plain sight. The
// choice is made on the network's preview (no menu to open), the current one
// reads at a glance, and it is remembered per account for new posts: after a
// publish or a clear, after a restart, and on the other devices through sync.
// An account that cannot post a story stays a feed post.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/state/story_placements.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/placement_switch.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> json = {};
  final Map<String, Uint8List> _media = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async {
    final path = 'mem://$id.$extension';
    _media[path] = bytes;
    return path;
  }

  @override
  Future<Uint8List> readMedia(String path) async => _media[path]!;
  @override
  Future<void> deleteMedia(String path) async => _media.remove(path);
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF777777)));
}

Future<void> _loadFonts() async {
  final loader = FontLoader('Inter');
  for (final f in ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Bold.ttf']) {
    loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
  }
  await loader.load();
}

/// The demo workspace's Instagram account (hand-off, which takes stories).
const _ig = 'demo-instagram';

final _now = DateTime(2026, 11, 10);

/// A Facebook account on hand-off: Facebook posts stories through its API
/// only, so this one cannot.
final _fbHandoff = ConnectedAccount(id: 'fb-handoff', platformId: 'facebook', tier: PlatformTier.handoff, displayName: 'My Page', createdAt: _now);

/// A Facebook Page on its API, which takes stories.
final _fbApi = ConnectedAccount(
    id: 'fb-api', platformId: 'facebook', tier: PlatformTier.byokApi, displayName: 'My Page', createdAt: _now, config: const {'page_id': '123'});

Finder _switchOf(String accountId) => find.byKey(Key('placement-$accountId'));

/// The segment of [accountId]'s switch that reads [label].
Finder _segment(String accountId, String label) => find.descendant(of: _switchOf(accountId), matching: find.text(label));

void main() {
  setUpAll(_loadFonts);

  /// NEFORUM started on [storage], with only Instagram picked for new posts.
  Future<(AppServices, ProviderContainer)> boot(WidgetTester tester, _MemoryStorage storage) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
    await tester.pump(const Duration(milliseconds: 300));
    return (services, ProviderScope.containerOf(tester.element(find.byType(MaterialApp))));
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  PostPlacement placementIn(ProviderContainer c, String accountId) => placementOfExtra(c.read(composerProvider).overrides[accountId]?.extra ?? const {});

  /// What the switch shows as chosen: the one selected segment, its check
  /// mark, and the line under it.
  void expectShown(WidgetTester tester, String accountId, PostPlacement p) {
    final control = tester.widget<SegmentedButton<PostPlacement>>(_switchOf(accountId));
    expect(control.selected, {p});
    expect(find.descendant(of: _switchOf(accountId), matching: find.byIcon(Icons.check_rounded)), findsOneWidget, reason: 'the choice carries a check');
    final summary = tester.widget<Text>(find.byKey(Key('placement-summary-$accountId')));
    expect(summary.data, switch (p) {
      PostPlacement.feed => 'A regular post with your caption.',
      PostPlacement.story => 'A story only: 9:16, without a caption.',
      PostPlacement.feedAndStory => 'The post with your caption, and the same photos or videos as a story.',
    });
  }

  group('settings', () {
    test('the remembered placements survive a save and a load, and junk is dropped', () {
      const s = AppSettings(defaultPlacements: {'a': 'feedAndStory', 'b': 'story'});
      expect(AppSettings.fromJson(s.toJson()).defaultPlacements, {'a': 'feedAndStory', 'b': 'story'});
      expect(const AppSettings().toJson().containsKey('defaultPlacements'), isFalse, reason: 'left out while empty, like other maps');
      expect(validDefaultPlacements({'a': 'story', 'b': 'feed', 'c': 'sideways', 'd': 3, 5: 'story'}), {'a': 'story'});
      expect(validDefaultPlacements('nope'), isEmpty);
    });

    test('the feed is the default and is not stored', () {
      var m = withRememberedPlacement(const {}, 'a', PostPlacement.feedAndStory);
      expect(m, {'a': 'feedAndStory'});
      m = withRememberedPlacement(m, 'a', PostPlacement.feed);
      expect(m, isEmpty);
    });

    test('it travels with sync and follows an account that sync merged', () {
      expect(kExportableSettings, contains('defaultPlacements'));
      expect(syncedSettings(const AppSettings())['defaultPlacements'], isEmpty, reason: 'a reset to nothing travels too');
      final moved = remapSettingAccountIds('defaultPlacements', {'old': 'story', 'other': 'feedAndStory'}, {'old': 'kept'});
      expect(moved, {'other': 'feedAndStory', 'kept': 'story'});
      final kept = remapSettingAccountIds('defaultPlacements', {'old': 'story', 'kept': 'feedAndStory'}, {'old': 'kept'});
      expect(kept, {'kept': 'feedAndStory'}, reason: "the kept account's own choice wins");
      final same = {'x': 'story'};
      expect(identical(remapSettingAccountIds('defaultPlacements', same, {'old': 'kept'}), same), isTrue);
      expect(remapSettingAccountIds('defaultTargetIds', ['old', 'b'], {'old': 'kept'}), ['kept', 'b']);
    });

    test('an account that cannot post a story falls back to the feed', () {
      final registry = builtinRegistry();
      const s = AppSettings(defaultPlacements: {'fb-handoff': 'story', 'fb-api': 'story'});
      expect(rememberedPlacement(s, _fbHandoff, registry), PostPlacement.feed);
      expect(rememberedPlacement(s, _fbApi, registry), PostPlacement.story);
      final seeded = withRememberedPlacements(const {}, ['fb-handoff', 'fb-api'], [_fbHandoff, _fbApi], registry, s);
      expect(seeded.keys, ['fb-api']);
    });

    test('a placement the post already has is kept', () {
      final registry = builtinRegistry();
      const s = AppSettings(defaultPlacements: {'fb-api': 'story'});
      final own = {'fb-api': const PostOverrides(text: 'Mine', extra: {kPlacementKey: 'feedAndStory'})};
      expect(identical(withRememberedPlacements(own, ['fb-api'], [_fbApi], registry, s), own), isTrue);
      final words = {'fb-api': const PostOverrides(text: 'Mine')};
      final seeded = withRememberedPlacements(words, ['fb-api'], [_fbApi], registry, s)['fb-api']!;
      expect((seeded.text, placementOfExtra(seeded.extra)), ('Mine', PostPlacement.story));
    });
  });

  testWidgets('the switch fits a phone card at 360 wide, in both themes and with large text', (tester) async {
    for (final b in Brightness.values) {
      for (final scale in [1.0, 1.5]) {
        var picked = PostPlacement.feed;
        await tester.pumpWidget(MaterialApp(
          theme: buildTheme(b, AccentChoice.neforum),
          home: MediaQuery(
            data: MediaQueryData(size: const Size(360, 640), textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Center(
                // 360 less the 16 px gutters and the card's own padding.
                child: SizedBox(
                  width: 360 - 2 * Space.lg - 2 * Space.md,
                  child: StatefulBuilder(
                    builder: (context, setState) => PlacementSwitch(
                      accountId: 'ig',
                      network: 'Instagram',
                      value: picked,
                      onChanged: (v) => setState(() => picked = v),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(_segment('ig', 'Post + Story'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$b at ${scale}x');
        expect(picked, PostPlacement.feedAndStory);
        expectShown(tester, 'ig', PostPlacement.feedAndStory);
      }
    }
  });

  testWidgets('the switch is on the preview, reads at a glance, and the choice survives a new post and a restart', (tester) async {
    final storage = _MemoryStorage()..json['settings.json'] = const AppSettings(defaultTargetIds: [_ig]).toJson();
    var (services, c) = await boot(tester, storage);
    expect(c.read(composerProvider).selected, {_ig});

    // On the preview without opening anything, Post chosen.
    expect(_switchOf(_ig), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expectShown(tester, _ig, PostPlacement.feed);

    await tester.tap(_segment(_ig, 'Post + Story'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(placementIn(c, _ig), PostPlacement.feedAndStory);
    expectShown(tester, _ig, PostPlacement.feedAndStory);
    expect(find.text('Customized'), findsNothing, reason: 'Post / Story is not a customization of the words');
    expect(c.read(composerProvider).hasContent, isFalse, reason: 'starting over loses nothing');
    expect(c.read(settingsProvider).defaultPlacements, {_ig: 'feedAndStory'});
    expect((storage.json['settings.json']! as Map)['defaultPlacements'], {_ig: 'feedAndStory'}, reason: 'saved with the settings');

    // The next post (after a publish, or New post) starts with it.
    c.read(composerProvider.notifier).reset();
    await tester.pump(const Duration(milliseconds: 300));
    expect(placementIn(c, _ig), PostPlacement.feedAndStory);
    expectShown(tester, _ig, PostPlacement.feedAndStory);

    // Clearing the post keeps it; so does "Use the main post".
    c.read(composerProvider.notifier)
      ..setText('Words')
      ..setOverride(_ig, const PostOverrides(text: 'Instagram words', extra: {kPlacementKey: 'feedAndStory'}));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Customized'), findsOneWidget);
    await tester.ensureVisible(find.text('Use the main post'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Use the main post'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.read(composerProvider).overrides[_ig]?.text, isNull);
    expect(placementIn(c, _ig), PostPlacement.feedAndStory);
    c.read(composerProvider.notifier).clearPost();
    expect(placementIn(c, _ig), PostPlacement.feedAndStory);

    // A post written before keeps its own placement.
    c.read(composerProvider.notifier).load(Post(id: 'old', text: 'Old', targets: const [PostTarget(accountId: _ig)], createdAt: _now, updatedAt: _now));
    await tester.pump(const Duration(milliseconds: 300));
    expect(placementIn(c, _ig), PostPlacement.feed);
    expectShown(tester, _ig, PostPlacement.feed);
    await done(tester);

    // Restart: a fresh composer on the saved settings.
    (services, c) = await boot(tester, storage);
    expect(services.settings.defaultPlacements, {_ig: 'feedAndStory'});
    expect(placementIn(c, _ig), PostPlacement.feedAndStory);
    expectShown(tester, _ig, PostPlacement.feedAndStory);

    // Back to Post: remembered too.
    await tester.tap(_segment(_ig, 'Post'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(placementIn(c, _ig), PostPlacement.feed);
    expect(c.read(settingsProvider).defaultPlacements, isEmpty);
    c.read(composerProvider.notifier).reset();
    expect(placementIn(c, _ig), PostPlacement.feed);
    await done(tester);
  });

  testWidgets('an account added to the post starts with its remembered placement; one without stories gets no switch', (tester) async {
    final storage = _MemoryStorage()
      ..json['settings.json'] = const AppSettings(defaultTargetIds: [_ig], defaultPlacements: {'fb-api': 'story', 'fb-handoff': 'story'}).toJson();
    final (services, c) = await boot(tester, storage);
    await tester.runAsync(() => services.accounts.upsert(_fbApi));
    await tester.runAsync(() => services.accounts.upsert(_fbHandoff));
    await tester.pump(const Duration(milliseconds: 300));

    c.read(composerProvider.notifier).toggleAccount(_fbApi.id);
    c.read(composerProvider.notifier).selectAccounts([_ig, _fbApi.id, _fbHandoff.id]);
    await tester.pump(const Duration(milliseconds: 300));
    expect(placementIn(c, _fbApi.id), PostPlacement.story);
    expect(c.read(composerProvider).overrides.containsKey(_fbHandoff.id), isFalse, reason: 'a hand-off Page cannot post a story: it stays a Page post');
    expect(_switchOf(_fbHandoff.id), findsNothing);
    final fb = c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == _fbHandoff.id);
    expect(fb.variant.placement, PostPlacement.feed);

    // The switch of the Page on its API, scrolled to.
    await tester.ensureVisible(_switchOf(_fbApi.id));
    await tester.pump(const Duration(milliseconds: 300));
    expectShown(tester, _fbApi.id, PostPlacement.story);

    // Taken off and put back, the post's own choice stays.
    c.read(composerProvider.notifier).setPlacement(_fbApi.id, PostPlacement.feedAndStory);
    c.read(composerProvider.notifier)
      ..toggleAccount(_fbApi.id)
      ..toggleAccount(_fbApi.id);
    expect(placementIn(c, _fbApi.id), PostPlacement.feedAndStory);
    expect(c.read(settingsProvider).defaultPlacements, {'fb-api': 'feedAndStory', 'fb-handoff': 'story'});
    await done(tester);
  });
}
