// 1.3.3: the text card's master editor above the previews: one card and one
// set of controls for every network that gets a card, what still differs
// between them, and one tap to make them match.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
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

void main() {
  setUpAll(_loadFonts);

  Future<ProviderContainer> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 5200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
    await tester.pump(const Duration(milliseconds: 300));
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
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

  const platforms = ['instagram', 'bluesky', 'mastodon', 'x'];

  /// The networks the master editor's note names after [what] ("no
  /// signature on"), in any order.
  Set<String> named(WidgetTester tester, String what) {
    final note = tester.widget<Text>(find.textContaining('Not the same everywhere')).data!;
    final match = RegExp('$what ([^;.]+)').firstMatch(note);
    return match == null ? const {} : match.group(1)!.split(', ').toSet();
  }

  /// The composer with one text-only post going to [platforms], with the
  /// same card everywhere; returns each network's card stand-in.
  Future<MediaAttachment Function(String)> compose(WidgetTester tester, ProviderContainer c) async {
    c.read(routerProvider).go('/compose');
    await settle(tester);
    final demo = c.read(accountListProvider);
    final byPlatform = {for (final p in platforms) p: demo.firstWhere((a) => a.platformId == p)};
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), 'One card for every network.');
    c.read(composerProvider.notifier)
      ..selectAccounts([for (final a in byPlatform.values) a.id])
      ..setTextCardEveryNetwork(true);
    await settle(tester);
    return (platform) => c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == byPlatform[platform]!.id).variant.media.single;
  }

  testWidgets('cards that differ per network are listed, and one tap makes them the same', (tester) async {
    final c = await boot(tester);
    // As the user had it: plain cards on Instagram and Bluesky, no @handle
    // on Bluesky, each network's own font.
    c.read(settingsProvider.notifier).update((x) => x.copyWith(
          textCardPlainPlatforms: const ['instagram', 'bluesky'],
          textCardHandleHiddenPlatforms: const ['bluesky'],
          textCardFont: TextCardFont.platform,
        ));
    final cardOf = await compose(tester, c);
    expect(find.byKey(const Key('text-card-master')), findsOneWidget);
    expect(find.byKey(const Key('text-card-master-preview')), findsOneWidget);
    expect([for (final p in platforms) textCardBrandedOf(cardOf(p))], [false, false, true, true]);
    expect(find.textContaining('Not the same everywhere'), findsOneWidget);
    expect(named(tester, 'no signature on'), {'Instagram', 'Bluesky'});
    expect(named(tester, 'no @handle on'), {'Bluesky'});
    expect(find.textContaining("each network's own font"), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('text-card-match')));
    await tester.tap(find.byKey(const Key('text-card-match')));
    await settle(tester);
    expect({for (final p in platforms) textCardBrandedOf(cardOf(p))}, {true}, reason: 'the signature, as most networks had it');
    expect({for (final p in platforms) textCardShowsHandleOf(cardOf(p))}, {true});
    expect({for (final p in platforms) textCardFontOf(cardOf(p)).resolve(p)}, {TextCardFont.original}, reason: 'one font, the one most networks were drawn in');
    expect(find.byKey(const Key('text-card-match')), findsNothing);
    expect(find.textContaining('The same card on all 4 networks'), findsOneWidget);
    // Remembered for the next post, like each network's own controls.
    final settings = c.read(settingsProvider);
    expect(settings.textCardPlainPlatforms, isEmpty);
    expect(settings.textCardHandleHiddenPlatforms, isEmpty);
    expect(settings.textCardFont, TextCardFont.original);
    await finish(tester);
  });

  testWidgets('the master editor\'s signature, @handle and "Post text too" go to every network at once', (tester) async {
    final c = await boot(tester);
    final cardOf = await compose(tester, c);
    expect({for (final p in platforms) textCardBrandedOf(cardOf(p))}, {true});

    for (final key in ['text-card-master-signature', 'text-card-master-handle', 'text-card-master-with-text']) {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.tap(find.byKey(Key(key)));
      await settle(tester);
    }
    expect({for (final p in platforms) textCardBrandedOf(cardOf(p))}, {false});
    expect({for (final p in platforms) textCardShowsHandleOf(cardOf(p))}, {false});
    final composer = c.read(composerProvider);
    expect({for (final p in platforms) composer.textCardWithText[p]}, {false});
    expect(c.read(settingsProvider).textCardPlainPlatforms.toSet(), containsAll(platforms));

    // One network changed under its own preview: the master says it is mixed,
    // and its signature then puts it back on everywhere.
    c.read(composerProvider.notifier).setTextCardBranded('x', true);
    await settle(tester);
    expect(named(tester, 'no signature on'), {'Instagram', 'Bluesky', 'Mastodon'});
    await tester.ensureVisible(find.byKey(const Key('text-card-master-signature')));
    await tester.tap(find.byKey(const Key('text-card-master-signature')));
    await settle(tester);
    expect({for (final p in platforms) textCardBrandedOf(cardOf(p))}, {true});
    await finish(tester);
  });

  testWidgets('on a phone the master editor starts folded, so the networks\' previews stay in view', (tester) async {
    final c = await boot(tester);
    tester.view.physicalSize = const Size(390, 844);
    // Plain cards on two networks, so there is something to match.
    c.read(settingsProvider.notifier).update((x) => x.copyWith(textCardPlainPlatforms: const ['instagram', 'bluesky']));
    await compose(tester, c);
    await tester.tap(find.textContaining('Preview ('));
    await settle(tester);
    expect(find.byKey(const Key('text-card-master')), findsOneWidget);
    expect(find.byKey(const Key('text-card-master-preview')), findsNothing, reason: 'folded');
    expect(find.byKey(const Key('text-card-match')), findsOneWidget, reason: 'matching is one tap even folded');
    expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Customize for')), findsWidgets,
        reason: 'the first network\'s preview is on screen');
    await tester.tap(find.byKey(const Key('text-card-master-toggle')));
    await settle(tester);
    expect(find.byKey(const Key('text-card-master-preview')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('one network with a card gets no master editor', (tester) async {
    final c = await boot(tester);
    c.read(routerProvider).go('/compose');
    await settle(tester);
    final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), 'Only Instagram.');
    c.read(composerProvider.notifier).selectAccounts([ig.id]);
    await settle(tester);
    expect(find.byKey(const ValueKey('text-card-style-instagram')), findsOneWidget);
    expect(find.byKey(const Key('text-card-master')), findsNothing);
    await finish(tester);
  });
}
