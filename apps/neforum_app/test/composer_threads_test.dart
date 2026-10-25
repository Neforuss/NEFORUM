// Thread parts, "Clear post", the phone keyboard and Discord's @everyone in
// the composer, driven through the demo workspace.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// The main editor: the one text field with a HighlightController.
final _editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);

/// The editors of the parts after the first.
final _partFields = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Continue the thread');

/// The content warning and title fields above the main editor.
final _cwField = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Content warning'));
final _titleField = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Title'));

/// What the Undo of the toast on screen does, kept to be tapped later.
VoidCallback _undoAction(WidgetTester tester) => tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed;

bool _hasFocus(WidgetTester tester, Finder field) => tester.widget<TextField>(field).focusNode?.hasFocus ?? false;

void main() {
  setUpAll(_loadFonts);

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

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  group('thread parts', () {
    testWidgets('"Add to thread" adds a part editor; networks with threads post each part', (tester) async {
      final (_, c) = await boot(tester);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
      final linkedin = c.read(accountListProvider).firstWhere((a) => a.platformId == 'linkedin');
      c.read(composerProvider.notifier).selectAccounts([masto.id, linkedin.id]);
      await settle(tester);
      expect(find.text('Add to thread'), findsNothing, reason: 'the starters offer "Start a thread" on an empty post');

      await tester.enterText(_editor, 'The first part of the story.');
      await settle(tester);
      await tester.tap(find.text('Add to thread'));
      await settle(tester);
      expect(c.read(composerProvider).additionalParts, ['']);
      expect(_partFields, findsOneWidget);
      expect(_hasFocus(tester, _partFields), isTrue, reason: 'the new part gets the cursor');

      await tester.enterText(_partFields, 'The second part.');
      await settle(tester);
      expect(c.read(composerProvider).additionalParts, ['The second part.']);
      expect(_editor, findsOneWidget, reason: 'part editors are not the main editor');
      expect(find.text('Part 2'), findsOneWidget);

      final previews = {for (final p in c.read(composerPreviewsProvider)) p.account.platformId: p};
      expect(previews['mastodon']!.variant.threadParts, ['The first part of the story. (1/2)', 'The second part. (2/2)']);
      expect(previews['linkedin']!.variant.isThread, isFalse);
      expect(previews['linkedin']!.variant.text, 'The first part of the story.\n\nThe second part.');

      // Saved with the post, and back in the editors when it is opened again.
      final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
      expect(post.additionalParts, ['The second part.']);
      c.read(composerProvider.notifier).reset();
      await settle(tester);
      expect(_partFields, findsNothing);
      c.read(composerProvider.notifier).load(post);
      await settle(tester);
      expect(tester.widget<TextField>(_partFields).controller!.text, 'The second part.');
      expect(tester.widget<TextField>(_editor).controller!.text, 'The first part of the story.');
      await finish(tester);
    });

    testWidgets('removing a part can be undone', (tester) async {
      final (_, c) = await boot(tester);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final notifier = c.read(composerProvider.notifier);
      notifier.restore(c.read(composerProvider).copyWith(text: 'One', additionalParts: ['Two', 'Three']));
      await settle(tester);
      expect(_partFields, findsNWidgets(2));

      await tester.tap(find.byTooltip('Remove part 2'));
      await settle(tester);
      expect(c.read(composerProvider).additionalParts, ['Three']);
      expect(tester.widget<TextField>(_partFields).controller!.text, 'Three');
      expect(find.text('Part 2 removed'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(c.read(composerProvider).additionalParts, ['Two', 'Three']);
      expect(tester.widgetList<TextField>(_partFields).map((f) => f.controller!.text), ['Two', 'Three']);
      await finish(tester);
    });

    testWidgets('undoing a removed part keeps everything written since', (tester) async {
      final (_, c) = await boot(tester);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final notifier = c.read(composerProvider.notifier);
      notifier.restore(c.read(composerProvider).copyWith(text: 'One', additionalParts: ['Two', 'Three']));
      await settle(tester);
      await tester.tap(find.byTooltip('Remove part 2'));
      await settle(tester);

      await tester.enterText(_editor, 'One, rewritten');
      await tester.enterText(_partFields, 'Three, rewritten');
      notifier.setLink('https://example.org');
      await settle(tester);
      await tester.tap(find.text('Undo'));
      await settle(tester);
      final back = c.read(composerProvider);
      expect(back.text, 'One, rewritten');
      expect(back.additionalParts, ['Two', 'Three, rewritten']);
      expect(back.link, 'https://example.org');
      expect(tester.widget<TextField>(_editor).controller!.text, 'One, rewritten');
      expect(tester.widgetList<TextField>(_partFields).map((f) => f.controller!.text), ['Two', 'Three, rewritten']);
      expect(_hasFocus(tester, _partFields.at(1)), isTrue, reason: 'the part being written keeps the cursor');
      await finish(tester);
    });

    testWidgets('publishing takes the Undo of a removed part away; a late Undo cannot bring the post back', (tester) async {
      final (_, c) = await boot(tester);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
      final notifier = c.read(composerProvider.notifier)..selectAccounts([masto.id]);
      notifier.restore(c.read(composerProvider).copyWith(text: 'One', additionalParts: ['Two', 'Three']));
      await settle(tester);
      await tester.tap(find.byTooltip('Remove part 3'));
      await settle(tester);
      expect(find.text('Part 3 removed'), findsOneWidget);
      final undo = _undoAction(tester);

      // In the test's own clock, so the toast's exit runs in it too.
      final publishing = c.read(postActionsProvider).publishNow();
      await settle(tester);
      await settle(tester);
      expect((await publishing).additionalParts, ['Two']);
      expect(find.text('Part 3 removed'), findsNothing, reason: 'the Undo goes with the post it belonged to');

      undo();
      await settle(tester);
      final after = c.read(composerProvider);
      expect(after.isEmpty, isTrue, reason: 'the published post does not come back');
      expect(after.additionalParts, isEmpty);
      expect(_partFields, findsNothing);
      await finish(tester);
    });

    testWidgets('adding or removing a part leaves an open, empty warning and title and the cursor alone', (tester) async {
      final (_, c) = await boot(tester);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
      final linkedin = c.read(accountListProvider).firstWhere((a) => a.platformId == 'linkedin');
      c.read(composerProvider.notifier).selectAccounts([masto.id, linkedin.id]);
      await settle(tester);
      await tester.enterText(_editor, 'A headline worth a warning');
      await settle(tester);
      await tester.tap(find.byTooltip('Content warning'));
      await tester.tap(find.byTooltip('Title'));
      await settle(tester);
      expect(_cwField, findsOneWidget);
      expect(_titleField, findsOneWidget);
      final editor = tester.widget<TextField>(_editor).controller!;
      editor.selection = const TextSelection.collapsed(offset: 2);

      await tester.tap(find.text('Add to thread'));
      await settle(tester);
      expect(_partFields, findsOneWidget);
      expect(_cwField, findsOneWidget, reason: 'an opened warning stays open while it is empty');
      expect(_titleField, findsOneWidget);
      expect(editor.selection, const TextSelection.collapsed(offset: 2));

      await tester.tap(find.byTooltip('Remove part 2'));
      await settle(tester);
      expect(_partFields, findsNothing);
      expect(_cwField, findsOneWidget);
      expect(_titleField, findsOneWidget);
      expect(editor.selection, const TextSelection.collapsed(offset: 2));
      expect(editor.text, 'A headline worth a warning');
      await finish(tester);
    });

    testWidgets('"Start a thread" adds the second part and puts the cursor in the first', (tester) async {
      final (_, c) = await boot(tester);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      await tester.tap(find.text('Start a thread'));
      await settle(tester);
      expect(c.read(composerProvider).additionalParts, ['']);
      expect(_partFields, findsOneWidget);
      expect(_hasFocus(tester, _editor), isTrue);
      expect(find.text('Start a thread'), findsNothing);
      expect(find.text('Add to thread'), findsOneWidget);
      await finish(tester);
    });
  });

  testWidgets('"Clear post" empties everything but the targets, and Undo brings it back', (tester) async {
    final (_, c) = await boot(tester);
    c.read(routerProvider).go('/compose');
    await settle(tester);
    expect(find.byTooltip('Clear post').hitTestable(), findsNothing, reason: 'nothing to clear yet');
    await tester.enterText(_editor, 'Something worth clearing');
    final notifier = c.read(composerProvider.notifier)
      ..setLink('https://example.org')
      ..setTags(['news']);
    notifier.restore(c.read(composerProvider).copyWith(additionalParts: ['Part two']));
    await settle(tester);
    final targets = c.read(composerProvider).selected;
    final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
    notifier.setVersionText(masto.id, 'A version of its own');

    await tester.tap(find.byTooltip('Clear post'));
    await settle(tester);
    final cleared = c.read(composerProvider);
    expect(cleared.isEmpty, isTrue);
    expect(cleared.additionalParts, isEmpty);
    expect(cleared.link, isNull);
    expect(cleared.tags, isEmpty);
    expect(cleared.overrides, isEmpty);
    expect(cleared.selected, targets);
    expect(tester.widget<TextField>(_editor).controller!.text, isEmpty);
    expect(_partFields, findsNothing);
    expect(find.text('Post cleared'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await settle(tester);
    final back = c.read(composerProvider);
    expect(back.text, 'Something worth clearing');
    expect(back.link, 'https://example.org');
    expect(back.tags, ['news']);
    expect(back.additionalParts, ['Part two']);
    expect(back.overrides[masto.id]?.text, 'A version of its own');
    expect(tester.widget<TextField>(_editor).controller!.text, 'Something worth clearing');
    expect(tester.widget<TextField>(_partFields).controller!.text, 'Part two');
    await finish(tester);
  });

  testWidgets('the Undo of "Clear post" lapses once something new is written, and goes by itself', (tester) async {
    final (_, c) = await boot(tester);
    c.read(routerProvider).go('/compose');
    await settle(tester);
    await tester.enterText(_editor, 'First draft');
    await settle(tester);
    await tester.tap(find.byTooltip('Clear post'));
    await settle(tester);
    expect(find.text('Post cleared'), findsOneWidget);
    final undo = _undoAction(tester);

    await tester.enterText(_editor, 'A new start');
    await settle(tester);
    expect(find.text('Post cleared'), findsNothing, reason: 'it would overwrite the new words');
    undo();
    await settle(tester);
    expect(c.read(composerProvider).text, 'A new start');
    expect(tester.widget<TextField>(_editor).controller!.text, 'A new start');

    // Left alone, the toast goes after a few seconds instead of staying.
    await tester.tap(find.byTooltip('Clear post'));
    await settle(tester);
    expect(find.text('Post cleared'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await settle(tester);
    expect(find.text('Post cleared'), findsNothing);
    await finish(tester);
  });

  group('phone keyboard', () {
    // flutter_test runs as Android, so Env.isMobile is true here.

    testWidgets('"Hide keyboard" shows while the keyboard is open and closes it', (tester) async {
      final (_, c) = await boot(tester, size: const Size(390, 844));
      c.read(routerProvider).go('/compose');
      await settle(tester);
      await tester.enterText(_editor, 'Typing on a phone');
      await settle(tester);
      expect(_hasFocus(tester, _editor), isTrue);
      expect(find.byTooltip('Hide keyboard'), findsNothing);

      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await settle(tester);
      expect(find.byTooltip('Hide keyboard'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide keyboard'));
      await settle(tester);
      expect(_hasFocus(tester, _editor), isFalse);

      tester.view.resetViewInsets();
      await settle(tester);
      expect(find.byTooltip('Hide keyboard'), findsNothing);
      await finish(tester);
    });

    testWidgets('a downward drag closes the keyboard; an upward one only scrolls', (tester) async {
      final (_, c) = await boot(tester, size: const Size(390, 844));
      c.read(routerProvider).go('/compose');
      await settle(tester);
      await tester.enterText(_editor, 'Short post');
      await settle(tester);
      final handle = find.text('Add to thread');
      await tester.ensureVisible(handle);
      await settle(tester);
      expect(_hasFocus(tester, _editor), isTrue);

      await tester.drag(handle, const Offset(0, -150));
      await settle(tester);
      expect(_hasFocus(tester, _editor), isTrue, reason: 'scrolling up keeps the keyboard');

      await tester.drag(handle, const Offset(0, 150));
      await settle(tester);
      expect(_hasFocus(tester, _editor), isFalse);
      await finish(tester);
    });

    testWidgets('a tap outside the text fields closes the keyboard', (tester) async {
      final (_, c) = await boot(tester, size: const Size(390, 844));
      c.read(routerProvider).go('/compose');
      await settle(tester);
      await tester.enterText(_editor, 'Short post');
      await settle(tester);
      final label = find.text('DIFFERENTIATION');
      await tester.ensureVisible(label);
      await settle(tester);
      expect(_hasFocus(tester, _editor), isTrue);

      // A tap in the text keeps it.
      await tester.tap(_editor);
      await settle(tester);
      expect(_hasFocus(tester, _editor), isTrue);

      await tester.tap(label);
      await settle(tester);
      expect(_hasFocus(tester, _editor), isFalse);
      await finish(tester);
    });
  });

  group('Discord @everyone', () {
    Future<(ConnectedAccount, ConnectedAccount)> withDiscord(WidgetTester tester, AppServices services, ProviderContainer c) async {
      final discord = ConnectedAccount(
        id: 'demo-discord',
        platformId: 'discord',
        tier: PlatformTier.openApi,
        displayName: 'Workshop (Discord webhook)',
        handle: 'Workshop',
        createdAt: DateTime.now(),
        config: const {'demo': true, 'webhookId': '1', 'channelId': '2', 'guildId': '3'},
      );
      await tester.runAsync(() => services.accounts.upsert(discord));
      await settle(tester);
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
      c.read(composerProvider.notifier).selectAccounts([discord.id, masto.id]);
      await settle(tester);
      return (discord, masto);
    }

    testWidgets('saving writes the Settings value into Discord targets that make no choice', (tester) async {
      final (services, c) = await boot(tester);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final (discord, masto) = await withDiscord(tester, services, c);
      await tester.enterText(_editor, 'Launch day');
      await settle(tester);

      // The preview already counts with it, without marking the post customized.
      final preview = c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == discord.id);
      expect(preview.variant.extra['mentionEveryone'], isTrue);
      expect(preview.issues.map((i) => i.code), contains('mention.everyone'));
      expect(preview.target.overrides.isEmpty, isTrue);

      var post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
      expect(post.targetFor(discord.id)!.overrides.extra['mentionEveryone'], isTrue);
      expect(post.targetFor(masto.id)!.overrides.extra.containsKey('mentionEveryone'), isFalse);

      // Opened again: the written default is not a choice of the post.
      c.read(composerProvider.notifier).load(post);
      expect(c.read(composerProvider).overrides[discord.id], isNull);

      // Settings off: off is written.
      await tester.runAsync(() => c.read(settingsProvider.notifier).update((s) => s.copyWith(discordMentionEveryone: false)));
      post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
      expect(post.targetFor(discord.id)!.overrides.extra['mentionEveryone'], isFalse);

      // A choice of the post wins over Settings.
      c.read(composerProvider.notifier)
        ..load(post)
        ..setOverride(discord.id, const PostOverrides(extra: {'mentionEveryone': true}));
      post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
      expect(post.targetFor(discord.id)!.overrides.extra['mentionEveryone'], isTrue);
      await finish(tester);
    });

    testWidgets('Customize has a per-post "Mention @everyone" switch', (tester) async {
      final (services, c) = await boot(tester);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final (discord, _) = await withDiscord(tester, services, c);
      await tester.enterText(_editor, 'Launch day');
      await settle(tester);

      Finder mentionSwitch() => find.widgetWithText(SwitchListTile, 'Mention @everyone');
      Future<void> openCustomize() async {
        await tester.ensureVisible(find.byTooltip('Customize for Discord'));
        await tester.tap(find.byTooltip('Customize for Discord'));
        await settle(tester);
        await tester.ensureVisible(mentionSwitch());
        await settle(tester);
      }

      await openCustomize();
      expect(tester.widget<SwitchListTile>(mentionSwitch()).value, isTrue, reason: 'Settings default');
      await tester.tap(mentionSwitch());
      await settle(tester);
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(c.read(composerProvider).overrides[discord.id]!.extra['mentionEveryone'], isFalse);

      // Back to the default: the post no longer has its own choice.
      await openCustomize();
      expect(tester.widget<SwitchListTile>(mentionSwitch()).value, isFalse);
      await tester.tap(mentionSwitch());
      await settle(tester);
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(c.read(composerProvider).overrides[discord.id], isNull);
      await finish(tester);
    });

    testWidgets('Settings > Posting turns the default off', (tester) async {
      final (_, c) = await boot(tester);
      expect(c.read(settingsProvider).discordMentionEveryone, isTrue);
      c.read(routerProvider).go('/settings');
      await settle(tester);
      final row = find.text('Mention @everyone on Discord');
      await tester.ensureVisible(row);
      await settle(tester);
      await tester.tap(row);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
      expect(c.read(settingsProvider).discordMentionEveryone, isFalse);
      await finish(tester);
    });
  });
}
