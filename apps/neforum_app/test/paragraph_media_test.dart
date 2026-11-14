// 1.4.3: paragraph-to-media links in the composer. Off by default; the
// composer keeps them with their paragraphs while the user types, the post
// and the composer's draft carry them, and the editor links a paragraph to
// the photos and videos the user taps.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/media_tray.dart';
import 'package:neforum_app/ui/compose/paragraph_media_sheet.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

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
      SizedBox(width: width, height: height);
}

MediaAttachment _image(String id) => MediaAttachment(id: id, path: '/m/$id.jpg', mimeType: 'image/jpeg', sizeBytes: 10, width: 1080, height: 1080);

const _text = 'Intro.\n\nFirst place.\n\nSecond place.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> container() async {
    final s = await AppServices.create(demo: true, storage: _MemoryStorage());
    final c = ProviderContainer(overrides: [servicesProvider.overrideWithValue(s)]);
    addTearDown(c.dispose);
    return c;
  }

  test('off by default: a post without links carries none (regression)', () {
    final c = ComposerState(text: _text, media: [_image('a')]);
    final post = c.toPost(id: 'p', status: PostStatus.draft, now: DateTime.utc(2026));
    expect(post.paragraphMedia, isEmpty);
    expect(post.toJson().containsKey('paragraphMedia'), isFalse);
    expect(c.canLinkParagraphs, isTrue);
    expect(const ComposerState(text: 'One paragraph').canLinkParagraphs, isFalse);
    expect(ComposerState(text: _text, media: [_image('a')], additionalParts: const ['More']).canLinkParagraphs, isFalse,
        reason: 'a thread places media by part');
  });

  test('toPost keeps the links of paragraphs that exist and files still attached; the draft keeps them', () {
    final c = ComposerState(
      text: _text,
      media: [_image('a'), _image('b'), _image('c')],
      paragraphMedia: const {1: ['a'], 2: ['b', 'gone'], 7: ['c']},
    );
    final post = c.toPost(id: 'p', status: PostStatus.draft, now: DateTime.utc(2026));
    expect(post.paragraphMedia, {1: ['a'], 2: ['b']});
    expect(Post.fromJson(post.toJson()).paragraphMedia, {1: ['a'], 2: ['b']}, reason: 'synced and saved with the post');
    expect(composerDraftFromJson(composerDraftToJson(c))!.paragraphMedia, {1: ['a'], 2: ['b']});
  });

  test('links follow their paragraphs while typing; removing or moving a file updates them', () async {
    final c = await container();
    final n = c.read(composerProvider.notifier);
    n.setText(_text);
    n.addMedia([_image('a'), _image('b'), _image('c')]);
    n.toggleParagraphMedia(1, 'a');
    n.toggleParagraphMedia(2, 'c');
    n.toggleParagraphMedia(2, 'b');
    expect(c.read(composerProvider).paragraphMedia, {1: ['a'], 2: ['b', 'c']}, reason: 'in the order of the attachments');

    // A paragraph written above them: the links move down with theirs.
    n.setText('New start.\n\n$_text');
    expect(c.read(composerProvider).paragraphMedia, {2: ['a'], 3: ['b', 'c']});

    // Linking a file to another paragraph takes it from the first; tapping
    // it again unlinks it.
    n.toggleParagraphMedia(2, 'b');
    expect(c.read(composerProvider).paragraphMedia, {2: ['a', 'b'], 3: ['c']});
    n.toggleParagraphMedia(2, 'b');
    expect(c.read(composerProvider).paragraphMedia, {2: ['a'], 3: ['c']});

    n.moveMedia(2, 0);
    n.toggleParagraphMedia(2, 'c');
    expect(c.read(composerProvider).paragraphMedia, {2: ['c', 'a']}, reason: 'c is now the first attachment');

    n.removeMedia('c');
    expect(c.read(composerProvider).paragraphMedia, {2: ['a']});
    n.clearParagraphMedia();
    expect(c.read(composerProvider).paragraphMedia, isEmpty);
  });

  test('a saved post opens with its links, and a duplicate keeps them', () async {
    final c = await container();
    final post = Post(
      id: 'saved',
      text: _text,
      media: [_image('a'), _image('b')],
      paragraphMedia: const {0: ['b'], 2: ['a']},
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    c.read(composerProvider.notifier).load(post);
    expect(c.read(composerProvider).paragraphMedia, {0: ['b'], 2: ['a']});
    c.read(composerProvider.notifier).duplicate(post);
    expect(c.read(composerProvider).paragraphMedia, {0: ['b'], 2: ['a']});
    c.read(composerProvider.notifier).clearPost();
    expect(c.read(composerProvider).paragraphMedia, isEmpty);
  });

  testWidgets('the editor: tap a paragraph\'s link button, then the photos it is about', (tester) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: const Scaffold(body: Column(children: [MediaTray(), ParagraphMediaRow()])),
      ),
    ));
    final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    final n = c.read(composerProvider.notifier);
    n.addMedia([_image('a'), _image('b')]);
    await tester.pump();
    expect(find.byKey(const ValueKey('paragraph-media-button')), findsNothing, reason: 'one paragraph: nothing to link');

    n.setText(_text);
    await tester.pump();
    expect(find.text('No paragraph linked to a photo or video'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('paragraph-media-button')));
    await tester.pumpAndSettle();
    expect(find.text('First place.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('paragraph-link-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('paragraph-1-pick-b')));
    await tester.pumpAndSettle();
    expect(c.read(composerProvider).paragraphMedia, {1: ['b']});

    // Another paragraph sees b as linked elsewhere; picking it moves it.
    await tester.tap(find.byKey(const ValueKey('paragraph-link-2')));
    await tester.pumpAndSettle();
    expect(find.text('¶ 2'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('paragraph-2-pick-b')));
    await tester.tap(find.byKey(const ValueKey('paragraph-2-pick-a')));
    await tester.pumpAndSettle();
    expect(c.read(composerProvider).paragraphMedia, {2: ['a', 'b']});

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('1 paragraph linked to photos or videos'), findsOneWidget);
    expect(find.byKey(const ValueKey('paragraph-chip-a')), findsOneWidget, reason: 'the tray shows the paragraph of each linked file');
    expect(find.text('¶ 3'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('paragraph-media-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('paragraph-media-clear')));
    await tester.pumpAndSettle();
    expect(c.read(composerProvider).paragraphMedia, isEmpty);
  });
}
