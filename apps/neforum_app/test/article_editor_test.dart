// 1.4.4: articles. The article editor in the real composer: the Post /
// Article switch (only with a blog selected), adding, typing in, moving and
// removing blocks, placing a photo between paragraphs, the fields panel,
// the keyboard on a computer, each blog's choice of blocks and its render
// report in the previews, and the phone layout. A post for social networks
// only keeps the plain composer exactly as before.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/compose/article_editor.dart';
import 'package:neforum_app/ui/compose/editor_card.dart';
import 'package:neforum_app/ui/compose/media_tray.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  _MemoryStorage([Map<String, Object>? settings]) : _json = {'settings.json': ?settings};
  final Map<String, Object> _json;
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

MediaAttachment _image(String id) =>
    MediaAttachment(id: id, path: 'mem://$id.jpg', mimeType: 'image/jpeg', sizeBytes: 10, width: 1600, height: 900, fileName: '$id.jpg');

final _wordpress = ConnectedAccount(id: 'wp', platformId: 'wordpress', tier: PlatformTier.openApi, displayName: 'My blog', handle: 'blog.example', createdAt: DateTime.utc(2026));

const _desktop = Size(1440, 1000);
const _phone = Size(360, 740);

/// The app at /compose, [size] wide, with a WordPress account next to the demo
/// ones and [select] chosen. Returns the provider container.
Future<ProviderContainer> _pumpCompose(WidgetTester tester, {Size size = _desktop, List<String> select = const ['wp', 'demo-mastodon'], Map<String, Object>? settings, Brightness brightness = Brightness.light}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  final services = (await tester.runAsync(() async {
    final s = await AppServices.create(demo: true, storage: _MemoryStorage(settings));
    await s.accounts.upsert(_wordpress);
    return s;
  }))!;
  var picks = 0;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      servicesProvider.overrideWithValue(services),
      // The device's picker: two new photos each time.
      mediaPickerProvider.overrideWithValue((context) async {
        picks++;
        return (added: [_image('new$picks-1'), _image('new$picks-2')], rejected: const <String>[]);
      }),
    ],
    child: const NeforumApp(),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  c.read(routerProvider).go('/compose');
  await tester.pump(const Duration(milliseconds: 300));
  c.read(composerProvider.notifier).selectAccounts(select);
  await tester.pump(const Duration(milliseconds: 300));
  return c;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
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

Future<void> _tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _settle(tester);
}

ArticleDocument _doc(ProviderContainer c) => c.read(composerProvider).article!;

void main() {
  setUpAll(_loadFonts);

  testWidgets('regression: social networks only, no Article switch and the plain composer as before', (tester) async {
    final c = await _pumpCompose(tester, select: const ['demo-mastodon', 'demo-bluesky']);
    expect(find.byKey(const ValueKey('article-mode-switch')), findsNothing);
    expect(find.byType(EditorCard), findsOneWidget);
    expect(find.byType(ArticleEditor), findsNothing);
    c.read(composerProvider.notifier).setText('Hello');
    await _settle(tester);
    expect(c.read(composerProvider).toPost(id: 'p', status: PostStatus.draft, now: DateTime.utc(2026)).toJson().containsKey('article'), isFalse);
  });

  testWidgets('blocks: switch to Article, add, type, move and remove, then back to Post without loss', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final c = await _pumpCompose(tester);
    c.read(composerProvider.notifier).setText('First paragraph.\n\nSecond paragraph.');
    await _settle(tester);
    final before = c.read(composerProvider).text;

    expect(find.byKey(const ValueKey('article-mode-switch')), findsOneWidget);
    await tester.tap(find.text('Article'));
    await _settle(tester);
    expect(find.byType(ArticleEditor), findsOneWidget);
    expect(find.byType(EditorCard), findsNothing);
    expect(_doc(c).blocks.length, 2);
    expect(find.descendant(of: find.byType(ArticleEditor), matching: find.text('First paragraph.')), findsOneWidget);

    // A heading from "Add block" at the end, then typed in.
    await _tapVisible(tester, find.byKey(const ValueKey('article-add-block')));
    await tester.tap(find.byKey(const ValueKey('article-add-heading')));
    await _settle(tester);
    final heading = _doc(c).blocks.last;
    expect(heading, isA<ArticleHeading>());
    await tester.enterText(find.byKey(ValueKey('article-text-${heading.id}')), 'A **bold** heading');
    await _settle(tester);
    expect((_doc(c).blockById(heading.id)! as ArticleHeading).spans[1], const ArticleSpan('bold', marks: {ArticleMark.bold}));

    // A divider, then moved up from its menu.
    await _tapVisible(tester, find.byKey(const ValueKey('article-add-block')));
    await tester.tap(find.byKey(const ValueKey('article-add-divider')));
    await _settle(tester);
    final divider = _doc(c).blocks.last;
    expect(divider, isA<ArticleDivider>());
    await _tapVisible(tester, find.byKey(ValueKey('article-block-menu-${divider.id}')));
    await tester.tap(find.text('Move up'));
    await _settle(tester);
    expect(_doc(c).blocks.map((b) => b.type), [ArticleBlockType.paragraph, ArticleBlockType.paragraph, ArticleBlockType.divider, ArticleBlockType.heading]);

    // Dragged by its handle to the top.
    final handle = find.descendant(of: find.byKey(ValueKey('article-block-${divider.id}')), matching: find.byIcon(Icons.drag_indicator_rounded));
    await tester.ensureVisible(handle);
    final first = find.byKey(ValueKey('article-block-${_doc(c).blocks.first.id}'));
    final from = tester.getCenter(handle);
    final distance = from.dy - tester.getTopLeft(first).dy + 20;
    final drag = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 20; i++) {
      await drag.moveBy(Offset(0, -distance / 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await drag.up();
    await _settle(tester);
    expect(_doc(c).blocks.first.id, divider.id, reason: 'dragged to the top');

    // Removed from its menu.
    await _tapVisible(tester, find.byKey(ValueKey('article-block-menu-${divider.id}')));
    await tester.tap(find.text('Remove this divider'));
    await _settle(tester);
    expect(_doc(c).blockById(divider.id), isNull);
    expect(c.read(composerProvider).text, '$before\n\n## A **bold** heading', reason: 'the short version follows');

    // Back to Post: the article as text; back to Article: the same article.
    final article = _doc(c);
    await _tapVisible(tester, find.text('Post'));
    expect(find.byType(EditorCard), findsOneWidget);
    expect(c.read(composerProvider).article, isNull);
    await _tapVisible(tester, find.text('Article'));
    expect(_doc(c), article);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a photo placed between two paragraphs, from the post\'s files or new ones', (tester) async {
    final c = await _pumpCompose(tester);
    final n = c.read(composerProvider.notifier);
    n.setText('Before the photo.\n\nAfter the photo.');
    n.enterArticleMode();
    await _settle(tester);
    final firstId = _doc(c).blocks.first.id;

    await _tapVisible(tester, find.byKey(ValueKey('article-block-menu-$firstId')));
    await tester.tap(find.text('Add photo below'));
    await _settle(tester);
    expect(find.text('Choose a photo'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('article-media-add-new')));
    await _settle(tester);
    expect(_doc(c).blocks.map((b) => b.type), [ArticleBlockType.paragraph, ArticleBlockType.image, ArticleBlockType.paragraph]);
    expect((_doc(c).blocks[1] as ArticleImage).media.mediaId, 'new1-1');
    expect(c.read(composerProvider).paragraphMedia, {0: ['new1-1']}, reason: 'social networks with paragraph links keep the layout');

    // Caption and credit; the second new photo then fills a gallery.
    final photo = _doc(c).blocks[1];
    await tester.enterText(find.byKey(ValueKey('article-caption-${photo.id}')), 'At dawn');
    await tester.enterText(find.byKey(ValueKey('article-credit-${photo.id}')), 'Photo: me');
    await _settle(tester);
    expect((_doc(c).blocks[1] as ArticleImage).media, const ArticleMediaRef('new1-1', caption: 'At dawn', credit: 'Photo: me'));

    await _tapVisible(tester, find.byKey(const ValueKey('article-add-block')));
    await tester.tap(find.byKey(const ValueKey('article-add-gallery')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('article-media-choice-new1-2')));
    await tester.tap(find.byKey(const ValueKey('article-media-choice-new1-1')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('article-media-use')));
    await _settle(tester);
    final gallery = _doc(c).blocks.last as ArticleGallery;
    expect(gallery.items.map((r) => r.mediaId), ['new1-2', 'new1-1'], reason: 'in the order they were ticked');
  });

  testWidgets('the fields panel: title, subtitle, cover, excerpt, address, tags, publish as', (tester) async {
    final c = await _pumpCompose(tester);
    final n = c.read(composerProvider.notifier);
    n.addMedia([_image('c1')]);
    n.enterArticleMode();
    await _settle(tester);

    await tester.enterText(find.byKey(const ValueKey('article-title')), 'Ünïcode Title, Here!');
    await tester.enterText(find.byKey(const ValueKey('article-subtitle')), 'The subtitle');
    await _settle(tester);
    expect(c.read(composerProvider).title, 'Ünïcode Title, Here!');
    expect(_doc(c).subtitle, 'The subtitle');
    expect(find.textContaining('unicode-title-here'), findsWidgets, reason: 'the address made from the title is shown');

    await tester.enterText(find.byKey(const ValueKey('article-excerpt')), 'In short');
    await tester.enterText(find.byKey(const ValueKey('article-slug')), 'my-own-address');
    await tester.enterText(find.byKey(const ValueKey('article-canonical')), 'https://first.example/a');
    await tester.enterText(find.byKey(const ValueKey('article-tag-input')), 'travel, photo,');
    await _settle(tester);
    await _tapVisible(tester, find.text('Draft'));
    final doc = _doc(c);
    expect(doc.excerpt, 'In short');
    expect(doc.slug, 'my-own-address');
    expect(doc.canonicalUrl, 'https://first.example/a');
    expect(doc.status, ArticleStatus.draft);
    expect(c.read(composerProvider).tags, ['travel', 'photo']);
    expect(doc.cover?.mediaId, 'c1', reason: 'the first photo became the cover');

    await _tapVisible(tester, find.byKey(const ValueKey('article-cover-remove')));
    expect(_doc(c).cover, isNull);
    await _tapVisible(tester, find.byKey(const ValueKey('article-cover-choose')));
    await tester.tap(find.byKey(const ValueKey('article-media-choice-c1')));
    await _settle(tester);
    expect(_doc(c).cover?.mediaId, 'c1');
  });

  testWidgets('desktop keys: Ctrl+B bolds the selection, Enter starts a new paragraph', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final c = await _pumpCompose(tester);
    final n = c.read(composerProvider.notifier);
    n.setText('make this strong');
    n.enterArticleMode();
    await _settle(tester);
    final id = _doc(c).blocks.single.id;
    final field = find.byKey(ValueKey('article-text-$id'));
    await _tapVisible(tester, field);
    final editable = tester.state<EditableTextState>(find.descendant(of: field, matching: find.byType(EditableText)));
    editable.userUpdateTextEditingValue(
        const TextEditingValue(text: 'make this strong', selection: TextSelection(baseOffset: 10, extentOffset: 16)), SelectionChangedCause.keyboard);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester);
    expect(c.read(composerProvider).text, 'make this **strong**');

    editable.userUpdateTextEditingValue(
        const TextEditingValue(text: 'make this **strong**', selection: TextSelection.collapsed(offset: 4)), SelectionChangedCause.keyboard);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(_doc(c).blocks.map((b) => (b as ArticleParagraph).text), ['make', ' this strong']);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('previews: the blog\'s report before posting, and its own choice of blocks', (tester) async {
    final c = await _pumpCompose(tester);
    final n = c.read(composerProvider.notifier);
    n.setTitle('Title');
    n.enterArticleMode();
    n.setArticle(const ArticleDocument(subtitle: 'A subtitle', blocks: [
      ArticleParagraph('p1', [ArticleSpan('First')]),
      ArticleParagraph('p2', [ArticleSpan('Second')]),
    ]));
    await _settle(tester);

    // WordPress has no subtitle field: said before posting, never silently.
    final section = find.byKey(const ValueKey('article-preview-wp'));
    expect(section, findsOneWidget);
    expect(find.descendant(of: section, matching: find.textContaining('the subtitle is left out')), findsOneWidget);
    expect(find.descendant(of: section, matching: find.text('1 left out')), findsOneWidget);
    // Mastodon gets the short version, and says so.
    expect(find.byKey(const ValueKey('article-short-note-demo-mastodon')), findsOneWidget);

    await _tapVisible(tester, find.byKey(const ValueKey('article-choose-wp')));
    await _tapVisible(tester, find.byKey(const ValueKey('article-include-wp-p2')));
    expect(c.read(composerProvider).overrides['wp']!.excludedBlockIds, ['p2']);
    final wp = c.read(composerPreviewsProvider).singleWhere((p) => p.account.id == 'wp');
    expect(wp.variant.article!.blocks.map((b) => b.id), ['p1'], reason: 'WordPress no longer gets it');
    expect(find.text('Article · 1 of 2 blocks'), findsOneWidget);

    await _tapVisible(tester, find.byKey(const ValueKey('article-include-all-wp')));
    expect(c.read(composerProvider).overrides['wp']?.excludedBlockIds ?? const [], isEmpty);
  });

  for (final brightness in Brightness.values) {
    testWidgets('phone width (${brightness.name}): the article editor fits, and Preview shows the report', (tester) async {
      final c = await _pumpCompose(tester, size: _phone, brightness: brightness);
      final n = c.read(composerProvider.notifier);
      n.addMedia([_image('a'), _image('b')]);
      n.setText('## A heading\n\nWords.');
      n.enterArticleMode();
      n.setArticle(_doc(c).copyWith(subtitle: 'Sub', blocks: [
        ..._doc(c).blocks,
        const ArticleGallery('g', [ArticleMediaRef('a'), ArticleMediaRef('b')], caption: 'Two'),
        const ArticleQuote('q', [ArticleSpan('A quote')], citation: 'Someone'),
        const ArticleList('l', [
          [ArticleSpan('one')],
        ]),
        const ArticleCode('c', 'print(1)'),
        const ArticleEmbed('e', 'https://www.youtube.com/watch?v=x'),
        const ArticleDivider('d'),
      ]));
      await _settle(tester);
      expect(find.byType(ArticleEditor), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('article-add-block')));
      await _settle(tester);
      await _tapVisible(tester, find.byKey(const ValueKey('article-details-toggle')));
      expect(find.byKey(const ValueKey('article-details')), findsOneWidget);

      await tester.tap(find.textContaining('Preview ('));
      await _settle(tester);
      expect(find.byKey(const ValueKey('article-preview-wp')), findsOneWidget);
    });
  }

  testWidgets('a block menu turns a paragraph into a heading, then a list, keeping its words', (tester) async {
    final c = await _pumpCompose(tester);
    final n = c.read(composerProvider.notifier);
    n.setText('Some *words*');
    n.enterArticleMode();
    await _settle(tester);
    final id = _doc(c).blocks.single.id;
    await _tapVisible(tester, find.byKey(ValueKey('article-block-menu-$id')));
    await tester.tap(find.text('Turn into heading'));
    await _settle(tester);
    expect(_doc(c).blocks.single, const ArticleHeading('b0', [ArticleSpan('Some '), ArticleSpan('words', marks: {ArticleMark.italic})]));
    expect(find.descendant(of: find.byType(ArticleEditor), matching: find.text('H2')), findsOneWidget);
    await _tapVisible(tester, find.byKey(ValueKey('article-block-menu-$id')));
    await tester.tap(find.text('Turn into list'));
    await _settle(tester);
    expect(_doc(c).blocks.single, isA<ArticleList>());
    expect(c.read(composerProvider).text, '- Some *words*');
  });

  testWidgets('"How articles work" opens the guide, which starts with its steps', (tester) async {
    await _pumpCompose(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('article-guide')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await _settle(tester);
    expect(find.textContaining('Pick where the post goes', findRichText: true), findsOneWidget);
  });

  testWidgets('seamless mode on a desktop renders the article editor and previews', (tester) async {
    final c = await _pumpCompose(tester, settings: {'seamlessSurfaces': true, 'navigationChrome': 'theme'}, brightness: Brightness.dark);
    c.read(composerProvider.notifier).enterArticleMode();
    await _settle(tester);
    expect(find.byType(ArticleEditor), findsOneWidget);
    expect(find.byKey(const ValueKey('article-preview-wp')), findsOneWidget);
  });
}
