// The per-network options of the Customize sheet are drawn from their one
// declaration in core (PlatformDescriptor.options): every declared option
// shows, folded ones under "More options", gated ones say who can use them,
// and a choice can be kept for the account.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/text_card.dart' show kTextCardChoiceKey;
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/compose/customize_sheet.dart';
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

/// A small photo.
final Uint8List _png = img.encodePng(img.Image(width: 64, height: 48));

ConnectedAccount _account(String platformId, PlatformTier tier, {Map<String, dynamic> config = const {}}) => ConnectedAccount(
      id: 'opt-$platformId-${tier.name}',
      platformId: platformId,
      tier: tier,
      displayName: '$platformId account',
      createdAt: DateTime.utc(2026),
      config: {'demo': true, ...config},
    );

void main() {
  setUpAll(_loadFonts);

  Future<(AppServices, ProviderContainer)> boot(WidgetTester tester, {Size size = const Size(1440, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
    await tester.pump(const Duration(milliseconds: 300));
    final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    c.read(routerProvider).go('/compose');
    return (services, c);
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

  Future<void> addAndSelect(WidgetTester tester, AppServices services, ProviderContainer c, List<ConnectedAccount> accounts) async {
    await tester.runAsync(() async {
      for (final a in accounts) {
        await services.accounts.upsert(a);
      }
    });
    await settle(tester);
    c.read(composerProvider.notifier).selectAccounts([for (final a in accounts) a.id]);
    c.read(composerProvider.notifier).setText('Options for every network https://example.org/post');
    await settle(tester);
  }

  Future<void> customize(WidgetTester tester, ProviderContainer c, String accountId) async {
    unawaited(showCustomizeSheet(
        tester.element(find.byType(Scaffold).first), c.read(composerPreviewsProvider).singleWhere((p) => p.account.id == accountId)));
    await settle(tester);
  }

  Future<void> showMore(WidgetTester tester) async {
    if (find.byKey(const Key('more-options')).evaluate().isEmpty) return;
    if (find.textContaining('More options').evaluate().isEmpty) return;
    await tester.ensureVisible(find.byKey(const Key('more-options')));
    await tester.tap(find.byKey(const Key('more-options')));
    await settle(tester);
  }

  testWidgets('every network\'s sheet shows each option it declares, and only those', (tester) async {
    final (services, c) = await boot(tester);
    await settle(tester);
    final registry = c.read(registryProvider);
    final accounts = [
      for (final a in builtinAdapters())
        for (final tier in a.descriptor.tiers)
          if (a.descriptor.userOptionsFor(tier).any((o) => o.surface != PostOptionSurface.dedicated))
            _account(a.id, tier, config: a.id == 'telegram' ? const {'chatType': 'supergroup'} : const {}),
    ];
    expect(accounts.length, greaterThan(20), reason: 'the networks with options, on each of their tiers');
    await addAndSelect(tester, services, c, accounts);

    for (final a in accounts) {
      final options = registry.byId(a.platformId)!.postOptionsFor(a);
      await customize(tester, c, a.id);
      await showMore(tester);
      for (final o in options.where((o) => o.surface == PostOptionSurface.main || o.surface == PostOptionSurface.more)) {
        expect(find.byKey(ValueKey('option-${o.key}')), findsOneWidget, reason: '${a.platformId} ${a.tier.name}: ${o.key}');
        expect(find.descendant(of: find.byKey(ValueKey('option-${o.key}')), matching: find.textContaining(o.label)), findsWidgets,
            reason: '${a.platformId}: ${o.label}');
        if (o.gate != null) {
          expect(find.text(o.gate!), findsWidgets, reason: '${a.platformId}: the gate of ${o.key} is explained');
        }
      }
      // Nothing that is not declared for this account's tier. Only the sheet
      // counts: the previews behind it have keys of their own
      // ('option-pill-check' on a pill that is on).
      final shown = find.descendant(
          of: find.byType(CustomizeSheet),
          matching: find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('option-')));
      expect(shown.evaluate().length, options.where((o) => o.surface != PostOptionSurface.dedicated).length, reason: a.platformId);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
    }
    await finish(tester);
  });

  testWidgets('Telegram: up front and folded options; a channel has no Topic; a choice is saved per post', (tester) async {
    final (services, c) = await boot(tester);
    await settle(tester);
    final group = _account('telegram', PlatformTier.openApi, config: const {'chatType': 'supergroup'});
    final channel = ConnectedAccount(
        id: 'opt-telegram-channel', platformId: 'telegram', tier: PlatformTier.openApi, displayName: 'Channel', createdAt: DateTime.utc(2026),
        config: const {'demo': true, 'chatType': 'channel'});
    await addAndSelect(tester, services, c, [group, channel]);

    await customize(tester, c, group.id);
    for (final label in ['Send silently', 'Pin the post', 'Caption above the media', 'Hide behind a spoiler', 'No link preview']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Protect from forwarding and saving'), findsNothing, reason: 'folded');
    expect(find.text('More options (6)'), findsOneWidget);
    await showMore(tester);
    expect(find.text('Protect from forwarding and saving'), findsOneWidget);
    expect(find.text('Topic'), findsOneWidget);
    expect(find.text('Groups with topics only.'), findsOneWidget);

    final silent = find.widgetWithText(SwitchListTile, 'Send silently');
    await tester.ensureVisible(silent);
    await tester.tap(silent);
    await tester.enterText(find.widgetWithText(TextField, 'Topic'), '42');
    await settle(tester);
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(c.read(composerProvider).overrides[group.id]!.extra, {'silent': true, 'topicId': 42});
    final variant = c.read(composerPreviewsProvider).singleWhere((p) => p.account.id == group.id).variant;
    expect(variant.extra, containsPair('topicId', 42), reason: 'a number, as message_thread_id takes');

    await customize(tester, c, channel.id);
    await showMore(tester);
    expect(find.text('Topic'), findsNothing, reason: 'a channel has no topics');
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    await finish(tester);
  });

  testWidgets('on a 360 x 640 phone the sheet with every Telegram option and a photo lays out without overflow', (tester) async {
    final (services, c) = await boot(tester, size: const Size(360, 640));
    await settle(tester);
    final group = _account('telegram', PlatformTier.openApi, config: const {'chatType': 'supergroup'});
    await addAndSelect(tester, services, c, [group]);
    final photo = (await tester.runAsync(() => services.media.importBytes(_png, fileName: 'a-rather-long-photo-name.png', mimeHint: 'image/png')))!;
    c.read(composerProvider.notifier).addMedia([photo]);
    await settle(tester);

    await customize(tester, c, group.id);
    await showMore(tester);
    await tester.ensureVisible(find.byKey(const Key('remember-options')));
    await settle(tester);
    expect(tester.takeException(), isNull);
    // The photo can be hidden behind a spoiler.
    final tile = find.byKey(ValueKey('spoilerMedia-${photo.id}'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await settle(tester);
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(c.read(composerProvider).overrides[group.id]!.extra['spoilerMedia'], [photo.id]);
    await finish(tester);
  });

  testWidgets('"Keep these for every post" stores the choice on the account; later posts start from it', (tester) async {
    final (services, c) = await boot(tester);
    await settle(tester);
    final group = _account('telegram', PlatformTier.openApi, config: const {'chatType': 'supergroup'});
    await addAndSelect(tester, services, c, [group]);

    await customize(tester, c, group.id);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Send silently'));
    await tester.ensureVisible(find.byKey(const Key('remember-options')));
    await tester.tap(find.byKey(const Key('remember-options')));
    await settle(tester);
    await tester.tap(find.text('Save'));
    await settle(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);

    final stored = c.read(accountListProvider).singleWhere((a) => a.id == group.id);
    expect(stored.config['postDefaults'], {'silent': true});
    expect(stored.config['chatType'], 'supergroup', reason: 'the rest of the account is kept');
    expect(c.read(composerProvider).overrides[group.id], isNull, reason: 'the post now gets it from the account');
    final variant = c.read(composerPreviewsProvider).singleWhere((p) => p.account.id == group.id).variant;
    expect(variant.extra['silent'], isTrue);

    // Opened again: the switch shows the account's choice, and turning it off
    // for this post is a choice of the post.
    await customize(tester, c, group.id);
    final silent = find.widgetWithText(SwitchListTile, 'Send silently');
    expect(tester.widget<SwitchListTile>(silent).value, isTrue);
    await tester.tap(silent);
    await settle(tester);
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(c.read(composerProvider).overrides[group.id]!.extra, {'silent': false});
    await finish(tester);
  });

  testWidgets('a Pinterest board saved by 1.4.2 under "board" opens and saves as the Board ID', (tester) async {
    final (services, c) = await boot(tester);
    await settle(tester);
    final pin = _account('pinterest', PlatformTier.byokApi);
    await addAndSelect(tester, services, c, [pin]);
    c.read(composerProvider.notifier).setOverride(pin.id, const PostOverrides(extra: {'board': '987'}));
    await settle(tester);
    expect(c.read(composerPreviewsProvider).singleWhere((p) => p.account.id == pin.id).variant.extra['pinterestBoardId'], '987');

    await customize(tester, c, pin.id);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Board ID')).controller!.text, '987');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(c.read(composerProvider).overrides[pin.id]!.extra, {'pinterestBoardId': '987'});
    await finish(tester);
  });

  test('the app\'s keys are the declared ones', () {
    final registry = builtinRegistry();
    expect(registry.descriptor('youtube_posts')!.option(kTextCardChoiceKey), isNotNull);
    expect(registry.descriptor('discord')!.option(kMentionEveryoneKey), isNotNull);
    expect(registry.descriptor('youtube')!.option(YouTubeAdapter.thumbnailKey)!.surface, PostOptionSurface.dedicated);
  });
}
