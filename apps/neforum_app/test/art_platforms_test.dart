// Art sites: artwork mode in the composer's target picker, the add-accounts
// filters, and adding another account on a platform.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/artwork_targets.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/ui/accounts/account_card.dart';
import 'package:neforum_app/ui/accounts/add_account_screen.dart';
import 'package:neforum_app/ui/accounts/platform_picker.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/compose/target_picker.dart';
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

ConnectedAccount _account(String platformId, {PlatformTier tier = PlatformTier.handoff, bool enabled = true, String? id}) => ConnectedAccount(
      id: id ?? 'acct-$platformId',
      platformId: platformId,
      tier: tier,
      displayName: platformId,
      createdAt: DateTime.utc(2026, 10, 1),
      enabled: enabled,
    );

void main() {
  setUpAll(_loadFonts);

  group('default targets', () {
    final registry = builtinRegistry();
    final accounts = [
      _account('mastodon', tier: PlatformTier.openApi),
      _account('instagram'),
      _account('behance'),
      _account('cara'),
      _account('pixiv', enabled: false),
    ];

    test('an ordinary post never goes to an art site by default', () {
      expect(defaultPostTargets(accounts, registry, const AppSettings()), {'acct-mastodon', 'acct-instagram'});
      // Even when an art site is marked "Include in new posts".
      const marked = AppSettings(defaultTargetIds: ['acct-mastodon', 'acct-behance']);
      expect(defaultPostTargets(accounts, registry, marked), {'acct-mastodon'});
    });

    test('an artwork post goes to the enabled art sites included in new posts', () {
      expect(defaultPostTargets(accounts, registry, const AppSettings(), artwork: true), {'acct-behance', 'acct-cara'});
      const marked = AppSettings(defaultTargetIds: ['acct-mastodon', 'acct-cara']);
      expect(defaultPostTargets(accounts, registry, marked, artwork: true), {'acct-cara'});
    });

    test('new artwork starts with the Settings defaults', () {
      const s = AppSettings(artworkMaturity: ArtworkMaturity.mature, artworkDisallowAiTraining: false);
      expect(newArtworkDetails(s), const ArtworkDetails(maturity: ArtworkMaturity.mature, disallowAiTraining: false));
    });
  });

  group('add-accounts filters', () {
    final all = builtinRegistry().descriptors;
    Set<String> shown(PlatformFilter f, [Map<String, int> added = const {}]) => {for (final d in all) if (f.matches(d, added)) d.id};

    test('chips come in the specified order', () {
      expect(PlatformFilter.values.map((f) => f.label),
          ['Not added yet', 'Added', 'Personal accounts', 'No developer keys', 'Posts automatically', 'Art and portfolios', 'All']);
    });

    test('each filter narrows the list to what its name says', () {
      final added = {'mastodon': 2, 'behance': 1};
      expect(shown(PlatformFilter.added, added), {'mastodon', 'behance'});
      expect(shown(PlatformFilter.notAdded, added), isNot(contains('mastodon')));
      expect(shown(PlatformFilter.notAdded, added).length, all.length - 2);
      // Automatic posting with a personal account: no business-only APIs, no hand-off-only sites.
      final personal = shown(PlatformFilter.personal);
      expect(personal, containsAll(['mastodon', 'bluesky', 'x']));
      expect(personal, isNot(anyOf(contains('instagram'), contains('facebook'), contains('snapchat'), contains('behance'))));
      final noKeys = shown(PlatformFilter.noKeys);
      expect(noKeys, containsAll(['mastodon', 'bluesky', 'discord']));
      expect(noKeys, isNot(anyOf(contains('x'), contains('rumble'))));
      expect(shown(PlatformFilter.automatic), containsAll(['x', 'mastodon']));
      expect(shown(PlatformFilter.automatic), isNot(contains('rumble')));
      expect(shown(PlatformFilter.art),
          containsAll(['behance', 'artstation', 'cara', 'pixiv', 'itaku', 'newgrounds', 'furaffinity', 'weasyl', 'kofi', 'artfol', 'fivehundredpx']));
      expect(shown(PlatformFilter.art), isNot(contains('instagram')));
      expect(shown(PlatformFilter.all).length, all.length);
    });
  });

  group('in the app', () {
    Future<(AppServices, ProviderContainer)> boot(WidgetTester tester, {Size size = const Size(1440, 900)}) async {
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

    Future<void> addArtSites(WidgetTester tester, AppServices services) async {
      await tester.runAsync(() async {
        await services.accounts.upsert(_account('behance', id: 'demo-behance'));
        await services.accounts.upsert(_account('cara', id: 'demo-cara'));
      });
      await settle(tester);
    }

    for (final size in const {'desktop': Size(1440, 900), 'phone': Size(360, 740)}.entries) {
      testWidgets('artwork mode: art sites only, rating and AI choices, back again (${size.key})', (tester) async {
        final (services, c) = await boot(tester, size: size.value);
        await addArtSites(tester, services);
        final composer = c.read(composerProvider.notifier);
        composer.reset(keepTargets: false);
        c.read(routerProvider).go('/compose');
        await settle(tester);

        // Art sites are never selected for an ordinary post.
        expect(c.read(composerProvider).selected, isNot(anyOf(contains('demo-behance'), contains('demo-cara'))));
        expect(c.read(composerProvider).selected, contains('demo-mastodon'));
        final chips = find.descendant(of: find.byType(TargetPicker), matching: find.byType(AccountChip));
        // Phones build only the chips in view of their scrolling row.
        if (size.key == 'desktop') expect(chips.evaluate().length, c.read(accountListProvider).length);

        // Artwork on: only the art sites, chosen, with the Settings defaults.
        await tester.ensureVisible(find.byKey(TargetPicker.artworkSwitchKey));
        await tester.tap(find.byKey(TargetPicker.artworkSwitchKey));
        await settle(tester);
        var state = c.read(composerProvider);
        expect(state.artwork, newArtworkDetails(c.read(settingsProvider)));
        expect(state.selected, {'demo-behance', 'demo-cara'});
        expect(chips.evaluate().length, 2);
        expect(find.textContaining('Art sites only receive artwork'), findsOneWidget);

        // The title field is shown, because the art sites need a title.
        expect(find.widgetWithText(TextField, 'Title (for Reddit, YouTube, blogs…)'), findsOneWidget);

        // Rating and AI choices.
        await tester.ensureVisible(find.text('Made with AI'));
        await tester.tap(find.text('Made with AI'));
        await settle(tester);
        await tester.ensureVisible(find.text('Mature'));
        await settle(tester);
        await tester.tap(find.text('Mature'));
        await settle(tester);
        state = c.read(composerProvider);
        expect(state.artwork!.aiGenerated, isTrue);
        expect(state.artwork!.maturity, ArtworkMaturity.mature);

        // Words only: art sites refuse the post (no text card for them).
        final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
        await tester.enterText(editor, 'A dragon in ink and wash.');
        await settle(tester);
        final behance = c.read(composerPreviewsProvider).firstWhere((p) => p.account.platformId == 'behance');
        expect(behance.issues.where((i) => i.isError).map((i) => i.code), contains('art.media_required'));
        expect(behance.variant.artwork!.maturity, ArtworkMaturity.mature);
        expect(c.read(composerReadinessProvider).canPublish, isFalse);

        // Artwork off: back to the ordinary accounts.
        await tester.ensureVisible(find.byKey(TargetPicker.artworkSwitchKey));
        await tester.tap(find.byKey(TargetPicker.artworkSwitchKey));
        await settle(tester);
        state = c.read(composerProvider);
        expect(state.isArtwork, isFalse);
        expect(state.selected, isNot(anyOf(contains('demo-behance'), contains('demo-cara'))));
        expect(state.selected, isNotEmpty);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      });
    }

    testWidgets('choosing an art site turns artwork mode on with that site alone', (tester) async {
      final (services, c) = await boot(tester);
      await addArtSites(tester, services);
      c.read(composerProvider.notifier).reset(keepTargets: false);
      c.read(routerProvider).go('/compose');
      await settle(tester);

      final cara = find.descendant(of: find.byType(TargetPicker), matching: find.byWidgetPredicate((w) => w is AccountChip && w.account.id == 'demo-cara'));
      expect((tester.widget(cara) as AccountChip).artSite, isTrue);
      await tester.tap(cara);
      await settle(tester);
      expect(c.read(composerProvider).isArtwork, isTrue);
      expect(c.read(composerProvider).selected, {'demo-cara'});

      // A finished post keeps artwork mode with its art sites.
      c.read(composerProvider.notifier).setArtwork(const ArtworkDetails(aiGenerated: true));
      c.read(composerProvider.notifier).reset();
      expect(c.read(composerProvider).selected, {'demo-cara'});
      expect(c.read(composerProvider).artwork, newArtworkDetails(c.read(settingsProvider)));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('add accounts: Not added yet first, Added to add another, search within the filter', (tester) async {
      final (_, c) = await boot(tester);
      c.read(routerProvider).go('/accounts/add');
      await settle(tester);
      Finder onScreen(String text) => find.descendant(of: find.byType(AddAccountScreen), matching: find.text(text));

      // Default: platforms without an account.
      expect(onScreen('Mastodon'), findsNothing);
      expect(onScreen('Lemmy'), findsOneWidget);
      expect(onScreen('Platforms you have not added yet.'), findsOneWidget);

      await tester.tap(onScreen('Art and portfolios'));
      await settle(tester);
      expect(onScreen('Behance'), findsOneWidget);
      expect(onScreen('Lemmy'), findsNothing);
      expect(onScreen('ART AND PORTFOLIOS'), findsOneWidget);

      await tester.tap(onScreen('Added'));
      await settle(tester);
      expect(onScreen('Mastodon'), findsOneWidget);
      expect(onScreen('Behance'), findsNothing);
      expect(find.descendant(of: find.byType(AddAccountScreen), matching: find.text('1 account')), findsWidgets);

      final search = find.descendant(of: find.byType(AddAccountScreen), matching: find.byType(TextField));
      await tester.enterText(search, 'blue');
      await settle(tester);
      expect(onScreen('Bluesky'), findsOneWidget);
      expect(onScreen('Mastodon'), findsNothing);
      await tester.enterText(search, 'behance');
      await settle(tester);
      expect(onScreen('No platform matches'), findsOneWidget);

      // Picking an added platform starts another account there.
      await tester.enterText(search, 'mast');
      await settle(tester);
      await tester.tap(onScreen('Mastodon'));
      await settle(tester);
      expect(find.textContaining('How should NEFORUM post to Mastodon?'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('an account card adds another account on its platform', (tester) async {
      final (_, c) = await boot(tester);
      c.read(routerProvider).go('/accounts');
      await settle(tester);
      final card = find.byType(AccountCard).first;
      final account = tester.widget<AccountCard>(card).account;
      await tester.tap(find.descendant(of: card, matching: find.byTooltip('More')));
      await settle(tester);
      await tester.tap(find.text('Add another account'));
      await settle(tester);
      expect(c.read(routerProvider).routeInformationProvider.value.uri.toString(), '/accounts/add?platform=${account.platformId}');
      final name = c.read(registryProvider).descriptor(account.platformId)!.name;
      expect(find.descendant(of: find.byType(AddAccountScreen), matching: find.textContaining(name)), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
