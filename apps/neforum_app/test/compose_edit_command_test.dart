// /compose?post=X is a one-shot command: it loads the post once, the location
// goes back to /compose, and no history step can ever load it again. Edit,
// New post and the rest never replace words in the composer without an Undo.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/queue/queue_screen.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/widgets/post_card.dart';

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
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
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF888888)));
}

const _postId = 'demo-post-3';
final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);

Future<ProviderContainer> _start(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage()));
  await tester.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(services!)],
    child: const NeforumApp(),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
  return c;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

String _location(ProviderContainer c) => c.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

Finder get _editor => find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController).first;

Future<void> _type(WidgetTester tester, String words) async {
  await tester.enterText(_editor, words);
  await _settle(tester);
}

/// A side button pressed and released where the mouse already is.
Future<void> _sideButton(WidgetTester tester, int button) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: button);
  await g.down(const Offset(900, 500));
  await g.up();
  await g.removePointer();
  await _settle(tester);
}

/// Taps a card in the queue, as the user edits a post.
Future<void> _tapPostInQueue(WidgetTester tester, ProviderContainer c, String postId) async {
  c.read(routerProvider).go('/queue');
  await _settle(tester);
  final card = find.descendant(of: find.byType(QueueScreen), matching: find.byWidgetPredicate((w) => w is PostCard && w.post.id == postId));
  await tester.ensureVisible(card);
  await tester.pump();
  (tester.widget<PostCard>(card).onTap!)();
  await _settle(tester);
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

void main() {
  setUpAll(_loadFonts);

  // Failed on 9f62fea: _loadedId was never cleared and a query change keeps
  // the same State, so the second open of the same post loaded nothing.
  testWidgets('edit, discard, edit the same post again: it loads again', variant: _desktop, (tester) async {
    final c = await _start(tester);
    final router = c.read(routerProvider);

    router.go('/compose?post=$_postId');
    await _settle(tester);
    expect(c.read(composerProvider).editingPostId, _postId);
    final words = c.read(composerProvider).text;
    expect(words, isNotEmpty);

    await tester.tap(find.text('Discard changes'));
    await _settle(tester);
    expect(c.read(composerProvider).text, isEmpty);

    router.go('/compose?post=$_postId');
    await _settle(tester);
    expect(c.read(composerProvider).editingPostId, _postId, reason: 'the second open of the same post must load it');
    expect(c.read(composerProvider).text, words);
  });

  testWidgets('the command is carried out once: the location goes back to /compose', variant: _desktop, (tester) async {
    final c = await _start(tester);
    c.read(routerProvider).go('/compose?post=$_postId');
    await _settle(tester);
    expect(c.read(composerProvider).editingPostId, _postId);
    expect(_location(c), '/compose');
    expect(c.read(navHistoryProvider).entries, ['/compose']);
  });

  testWidgets('a command for a post that is gone says so and loads nothing', variant: _desktop, (tester) async {
    final c = await _start(tester);
    await _type(tester, 'my own words');
    c.read(routerProvider).go('/compose?post=no-such-post');
    await _settle(tester);
    expect(find.text('This post is no longer in NEFORUM'), findsOneWidget);
    expect(c.read(composerProvider).text, 'my own words');
    expect(_location(c), '/compose');
  });

  testWidgets('walking back to Compose never loads a post over new words', variant: _desktop, (tester) async {
    final c = await _start(tester);
    final router = c.read(routerProvider);

    // Edit X from the queue, leave, start something new.
    await _tapPostInQueue(tester, c, _postId);
    expect(c.read(composerProvider).editingPostId, _postId);
    expect(_location(c), '/compose');
    await tester.tap(find.text('Discard changes'));
    await _settle(tester);
    await _type(tester, 'something new');
    router.go('/queue');
    await _settle(tester);
    router.go('/activity');
    await _settle(tester);

    // Back, back, forward, back through every entry, the Edit one too.
    final history = c.read(navHistoryProvider);
    expect(history.entries.where((e) => e.contains('post=')), isEmpty);
    while (history.canBack) {
      await _sideButton(tester, kBackMouseButton);
      expect(c.read(composerProvider).text, 'something new', reason: 'at ${_location(c)}');
    }
    while (history.canForward) {
      await _sideButton(tester, kForwardMouseButton);
      expect(c.read(composerProvider).text, 'something new', reason: 'at ${_location(c)}');
    }
    expect(c.read(composerProvider).editingPostId, isNull);
    final hidden = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController, skipOffstage: false).first;
    expect(tester.widget<TextField>(hidden).controller!.text, 'something new', reason: 'the editor shows them too');
  });

  testWidgets('typing, then Back and Forward: the words and the editor are untouched', variant: _desktop, (tester) async {
    final c = await _start(tester);
    await _type(tester, 'draft in progress');
    final before = c.read(composerProvider);
    c.read(routerProvider).go('/settings');
    await _settle(tester);
    await _sideButton(tester, kBackMouseButton);
    expect(_location(c), '/compose');
    expect(identical(c.read(composerProvider), before), isTrue, reason: 'nothing touched the composer');
    await _sideButton(tester, kForwardMouseButton);
    await _sideButton(tester, kBackMouseButton);
    expect(c.read(composerProvider).text, 'draft in progress');
    expect(tester.widget<TextField>(_editor).controller!.text, 'draft in progress');
  });

  group('Undo', () {
    testWidgets('Edit over words in the composer offers them back', variant: _desktop, (tester) async {
      final c = await _start(tester);
      await _type(tester, 'words I want back');
      await _tapPostInQueue(tester, c, _postId);
      expect(c.read(composerProvider).editingPostId, _postId);
      expect(find.text('Replaced what you were writing'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await _settle(tester);
      expect(c.read(composerProvider).text, 'words I want back');
      expect(c.read(composerProvider).editingPostId, isNull);
      expect(tester.widget<TextField>(_editor).controller!.text, 'words I want back');
    });

    testWidgets('New post over words in the composer offers them back', variant: _desktop, (tester) async {
      final c = await _start(tester);
      await _type(tester, 'words I want back');
      await tester.tap(find.text('New post').first);
      await _settle(tester);
      expect(c.read(composerProvider).text, isEmpty);
      expect(find.text('Cleared what you were writing'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await _settle(tester);
      expect(c.read(composerProvider).text, 'words I want back');
    });

    testWidgets('New post from the queue and Duplicate offer the same', variant: _desktop, (tester) async {
      final c = await _start(tester);
      await _type(tester, 'words I want back');
      c.read(routerProvider).go('/queue');
      await _settle(tester);
      await tester.tap(find.descendant(of: find.byType(QueueScreen), matching: find.text('New post')));
      await _settle(tester);
      expect(_location(c), '/compose');
      await tester.tap(find.text('Undo'));
      await _settle(tester);
      expect(c.read(composerProvider).text, 'words I want back');
    });

    testWidgets('no words, no Undo', variant: _desktop, (tester) async {
      final c = await _start(tester);
      await tester.tap(find.text('New post').first);
      await _settle(tester);
      expect(find.text('Undo'), findsNothing);
      await _tapPostInQueue(tester, c, _postId);
      expect(c.read(composerProvider).editingPostId, _postId);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('new words take the offer away: Undo can never overwrite them', variant: _desktop, (tester) async {
      final c = await _start(tester);
      await _type(tester, 'old words');
      await tester.tap(find.text('New post').first);
      await _settle(tester);
      expect(find.text('Undo'), findsOneWidget);
      await _type(tester, 'new words');
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Undo'), findsNothing);
      expect(c.read(composerProvider).text, 'new words');
    });

    testWidgets('opening the post already open keeps the changes made to it', variant: _desktop, (tester) async {
      final c = await _start(tester);
      await _tapPostInQueue(tester, c, _postId);
      await _type(tester, 'my changes to it');
      await _tapPostInQueue(tester, c, _postId);
      expect(c.read(composerProvider).text, 'my changes to it');
      expect(c.read(composerProvider).editingPostId, _postId);
      expect(_location(c), '/compose');
      expect(find.text('Undo'), findsNothing);
    });
  });
}
