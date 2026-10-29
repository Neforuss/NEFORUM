// Story and/or post: the story's own 9:16 copies (fitted photos, text cards)
// beside the feed post's, and the composer's checks of both copies.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/fitted_photos.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/state/text_cards.dart';
import 'package:neforum_app/ui/activity/post_detail_screen.dart';
import 'package:neforum_app/ui/root.dart';
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
  final loader = FontLoader('Inter');
  for (final f in ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Bold.ttf']) {
    loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
  }
  await loader.load();
}

const _feedAndStory = {kPlacementKey: 'feedAndStory'};

void main() {
  setUpAll(_loadFonts);

  Future<(AppServices, ProviderContainer)> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
    await tester.pump(const Duration(milliseconds: 300));
    return (services, ProviderScope.containerOf(tester.element(find.byType(MaterialApp))));
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  final now = DateTime(2026, 10, 28);
  final igApi = ConnectedAccount(id: 'ig-api', platformId: 'instagram', tier: PlatformTier.byokApi, displayName: 'neforus', createdAt: now);
  final fbApi = ConnectedAccount(
      id: 'fb-api', platformId: 'facebook', tier: PlatformTier.byokApi, displayName: 'My Page', createdAt: now, config: const {'page_id': '123'});

  test('Instagram frames: 4:5 for the feed post (also of Post + Story), 9:16 for a story', () {
    expect(fullFrameAspect('instagram', const PostVariant(text: 'x', extra: _feedAndStory)), 4 / 5);
    expect(fullFrameAspect('instagram', const PostVariant(text: 'x', extra: _feedAndStory).asStory()), 9 / 16);
    expect(fullFrameAspect('instagram', const PostVariant(text: 'x', extra: {kStoryModeKey: true})), 9 / 16);
    expect(textCardSize('instagram', story: true), const Size(1080, 1920));
    expect(textCardSafeArea('instagram', story: true), isNot(EdgeInsets.zero), reason: 'a story card keeps clear of the story buttons');
  });

  test('the target row names the copies a result recorded', () {
    expect(copiesLabel(PostPlacement.feedAndStory, 1), 'Posted with a story of 1 frame');
    expect(copiesLabel(PostPlacement.feedAndStory, 3), 'Posted with a story of 3 frames');
    expect(copiesLabel(PostPlacement.story, 2), 'Posted as a story of 3 frames');
  });

  testWidgets('Post + Story: the feed post gets a 4:5 copy of the photo, the story a 9:16 copy of its own', (tester) async {
    final (services, _) = await boot(tester);
    await tester.runAsync(() => services.accounts.upsert(igApi));
    final art = (await tester.runAsync(() => services.media.importBytes(
          img.encodeJpg(img.Image(width: 300, height: 400)..clear(img.ColorRgb8(200, 160, 40))),
          fileName: 'art.jpg',
        )))!;
    var post = Post(
      id: 'p-story',
      text: 'Caption',
      media: [art],
      targets: [PostTarget(accountId: igApi.id, overrides: const PostOverrides(extra: _feedAndStory))],
      createdAt: now,
      updatedAt: now,
    );
    const settings = AppSettings();
    post = (await tester.runAsync(() => attachFittedPhotos(services, post, settings)))!;
    final o = post.targetFor(igApi.id)!.overrides;
    final feed = post.media.singleWhere((m) => m.id == o.mediaIds!.single);
    final story = post.media.singleWhere((m) => m.id == o.storyMediaIds!.single);
    expect(feed.aspectRatio, closeTo(4 / 5, 0.01));
    expect(story.aspectRatio, closeTo(9 / 16, 0.01));
    expect({feed.derivedFrom, story.derivedFrom}, {art.id});

    // Both copies are checked by their own rules, and both pass.
    final adapter = services.registry.byId('instagram')!;
    final variant = const VariantResolver().resolve(post, post.targetFor(igApi.id)!, adapter.descriptor, account: igApi);
    expect(variant.storyMedia.single.id, story.id);
    expect(adapter.validate(variant, igApi).hasErrors, isFalse);

    // Fitting again keeps both copies.
    final again = (await tester.runAsync(() => attachFittedPhotos(services, post, settings)))!;
    expect(again.targetFor(igApi.id)!.overrides.storyMediaIds, [story.id]);

    // Back to a feed post only: the story list goes.
    final feedOnly = post.withTarget(post.targetFor(igApi.id)!.copyWith(overrides: o.copyWith(extra: const {})));
    final plain = (await tester.runAsync(() => attachFittedPhotos(services, feedOnly, settings)))!;
    expect(plain.targetFor(igApi.id)!.overrides.storyMediaIds, isNull);

    // The composer shows the original photo and no story copies.
    final shown = withoutTextCards(post);
    expect(shown.media.map((m) => m.id), [art.id]);
    expect(shown.targetFor(igApi.id)!.overrides.storyMediaIds, isNull);
    expect(shown.targetFor(igApi.id)!.overrides.extra, _feedAndStory);
    await done(tester);
  });

  testWidgets('words only: a Story is a 9:16 card; Post + Story keeps the 4:5 feed card and adds a 9:16 story card', (tester) async {
    final (services, _) = await boot(tester);
    await tester.runAsync(() => services.accounts.upsert(igApi));
    await tester.runAsync(() => services.accounts.upsert(fbApi));
    Post post(Map<String, dynamic> igExtra, Map<String, dynamic> fbExtra) => Post(
          id: 'p-words',
          text: 'Open bench tonight',
          targets: [
            PostTarget(accountId: igApi.id, overrides: PostOverrides(extra: igExtra)),
            PostTarget(accountId: fbApi.id, overrides: PostOverrides(extra: fbExtra)),
          ],
          createdAt: now,
          updatedAt: now,
        );
    Future<(Size, Size?)> cardsOf(Post p, String accountId) async {
      final o = p.targetFor(accountId)!.overrides;
      MediaAttachment? byId(String? id) => id == null ? null : p.media.firstWhere((m) => m.id == id);
      final main = byId(o.mediaIds?.single);
      final story = byId(o.storyMediaIds?.single);
      return (
        main == null ? Size.zero : Size(main.width!.toDouble(), main.height!.toDouble()),
        story == null ? null : Size(story.width!.toDouble(), story.height!.toDouble()),
      );
    }

    final story = (await tester.runAsync(() => attachTextCards(services, post(const {kPlacementKey: 'story'}, const {kPlacementKey: 'story'}), services.settings)))!;
    expect(await cardsOf(story, igApi.id), (const Size(1080, 1920), null));
    expect(await cardsOf(story, fbApi.id), (const Size(1080, 1920), null), reason: 'a Facebook story needs a picture too');

    final both = (await tester.runAsync(() => attachTextCards(services, post(_feedAndStory, _feedAndStory), services.settings)))!;
    expect(await cardsOf(both, igApi.id), (const Size(1080, 1350), const Size(1080, 1920)));
    expect(await cardsOf(both, fbApi.id), (Size.zero, const Size(1080, 1920)), reason: 'the Page post stays a text post');
    await done(tester);
  });

  testWidgets('the composer previews a story card and checks the story copy', (tester) async {
    final (services, c) = await boot(tester);
    await tester.runAsync(() => services.accounts.upsert(igApi));
    await tester.runAsync(() => services.accounts.upsert(fbApi));
    await tester.pump(const Duration(milliseconds: 300));
    final notifier = c.read(composerProvider.notifier)
      ..selectAccounts([igApi.id, fbApi.id])
      ..setText('Open bench tonight')
      ..setOverride(igApi.id, const PostOverrides(extra: {kPlacementKey: 'story', kStoryModeKey: true}))
      ..setOverride(fbApi.id, const PostOverrides(extra: _feedAndStory));
    await tester.pump(const Duration(milliseconds: 300));
    final previews = {for (final p in c.read(composerPreviewsProvider)) p.account.id: p};
    final ig = previews[igApi.id]!;
    expect((ig.variant.media.single.width, ig.variant.media.single.height), (1080, 1920));
    expect(ig.issues.where((i) => i.isError), isEmpty);
    final fb = previews[fbApi.id]!;
    expect(fb.variant.media, isEmpty, reason: 'the Page post is text');
    expect((fb.variant.storyMedia.single.width, fb.variant.storyMedia.single.height), (1080, 1920));
    expect(fb.issues.where((i) => i.code == 'facebook.story_media'), isEmpty);
    expect(fb.issues.any((i) => i.code == 'media.text_card'), isTrue);

    // A 2-minute video: fine for the Page post, too long for the story.
    final clip = MediaAttachment(id: 'clip', path: 'mem://clip.mp4', mimeType: 'video/mp4', sizeBytes: 1000, width: 1080, height: 1920, durationMs: 120000);
    notifier.addMedia([clip]);
    await tester.pump(const Duration(milliseconds: 300));
    final withVideo = c.read(composerPreviewsProvider).firstWhere((p) => p.account.id == fbApi.id);
    final errors = withVideo.issues.where((i) => i.isError).toList();
    expect(errors.map((i) => i.code), ['facebook.story_video_too_long']);
    expect(errors.single.message, startsWith('Story: '));
    await done(tester);
  });

  testWidgets('Post + Story with the card alone: the preview shows the feed card without the words, as publishing sends it', (tester) async {
    final (services, c) = await boot(tester);
    await tester.runAsync(() => services.accounts.upsert(igApi));
    await tester.pump(const Duration(milliseconds: 300));
    c.read(composerProvider.notifier)
      ..selectAccounts([igApi.id])
      ..setText('Open bench tonight')
      ..setOverride(igApi.id, const PostOverrides(extra: _feedAndStory))
      ..setTextCardWithText('instagram', false);
    await tester.pump(const Duration(milliseconds: 300));
    final ig = c.read(composerPreviewsProvider).single;
    expect(ig.variant.text, isEmpty, reason: 'kTextCardOnlyKey drops the words at publish');
    expect((ig.variant.media.single.width, ig.variant.media.single.height), (1080, 1350));
    expect((ig.variant.storyMedia.single.width, ig.variant.storyMedia.single.height), (1080, 1920), reason: 'the story keeps its own card');
    await done(tester);
  });

  test('a Post + Story whose story failed after the feed post went live offers no Retry', () {
    final partly = PostTarget(
        accountId: igApi.id,
        status: TargetStatus.failed,
        result: PublishResult.partialFailure(const PublishError.network('story timed out'), remoteId: 'feed-1'));
    expect(needsRetry(partly), isFalse, reason: 'a retry would post the feed post twice');
    final failed = PostTarget(accountId: igApi.id, status: TargetStatus.failed, result: PublishResult.failure(const PublishError.network('down')));
    expect(needsRetry(failed), isTrue);
  });

  testWidgets('a document thread keeps each network\'s time and settings', (tester) async {
    final (services, c) = await boot(tester);
    await tester.runAsync(() => services.accounts.upsert(igApi));
    await tester.pump(const Duration(milliseconds: 300));
    final at = DateTime.now().add(const Duration(days: 1));
    c.read(composerProvider.notifier)
      ..selectAccounts([igApi.id])
      ..setText('Old words')
      ..setOverride(igApi.id, PostOverrides(text: 'Old version', mediaIds: const ['gone'], scheduledAt: at, extra: _feedAndStory))
      ..fillThread(const ['One', 'Two'], const [], const {});
    final o = c.read(composerProvider).overrides[igApi.id]!;
    expect(o.scheduledAt, at);
    expect(o.extra, _feedAndStory);
    expect((o.text, o.mediaIds), (null, null), reason: 'the old version of the words and its media go');
    expect(c.read(composerProvider).text, 'One');
    await done(tester);
  });
}
