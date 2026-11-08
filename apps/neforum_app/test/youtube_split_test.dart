// NEFORUM 1.4.1: the two YouTube networks. YouTube Posts (the channel's text
// and image posts, by hand-off) takes a words-only post as text, or with the
// text card the post makes for another network; YouTube videos (uploads with
// your own keys) never takes a card, says it uploads a video, and keeps its
// custom thumbnail as a file of the post's own.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/state/text_cards.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

void main() {
  final registry = builtinRegistry();
  final posts = registry.byId('youtube_posts')!.descriptor;
  final videos = registry.byId('youtube')!.descriptor;
  final instagram = registry.byId('instagram')!.descriptor;
  PostVariant words({Map<String, dynamic> extra = const {}}) => PostVariant(text: 'I love apples', extra: extra);

  group('YouTube Posts: words only, or the post\'s text card', () {
    test('follows the post: a card when another network gets one, else the words alone', () {
      expect(qualifiesForTextCard(posts, words()), isFalse, reason: 'no other network makes a card');
      expect(qualifiesForTextCard(posts, words(), postMakesCard: true), isTrue);
      expect(qualifiesForTextCard(posts, words(), everyNetwork: true), isTrue);
    });

    test('the post\'s own choice wins: text only even when the card is everywhere, or a card on its own', () {
      final text = words(extra: {kTextCardChoiceKey: 'text'});
      expect(qualifiesForTextCard(posts, text, postMakesCard: true, everyNetwork: true), isFalse);
      expect(qualifiesForTextCard(posts, words(extra: {kTextCardChoiceKey: 'card'})), isTrue);
      expect(textCardChoiceOf(const {kTextCardChoiceKey: 'nonsense'}), isNull);
    });

    test('never with a photo of the user\'s own, never without words', () {
      final photo = MediaAttachment(id: 'p', path: '/p.jpg', mimeType: 'image/jpeg', sizeBytes: 10, width: 10, height: 10);
      expect(qualifiesForTextCard(posts, PostVariant(text: 'x', media: [photo], extra: const {kTextCardChoiceKey: 'card'})), isFalse);
      expect(qualifiesForTextCard(posts, PostVariant(text: '  ', extra: const {kTextCardChoiceKey: 'card'})), isFalse);
    });

    test('YouTube videos takes no card at all (it uploads videos); Instagram is unchanged', () {
      expect(qualifiesForTextCard(videos, words(), postMakesCard: true, everyNetwork: true), isFalse);
      expect(qualifiesForTextCard(instagram, words()), isTrue);
      expect(videos.name, 'YouTube videos');
    });
  });

  group('cards on save', () {
    late Directory dir;
    late AppServices s;
    final now = DateTime(2026, 11, 8);
    ConnectedAccount account(String id, String platform) =>
        ConnectedAccount(id: id, platformId: platform, tier: PlatformTier.handoff, displayName: id, createdAt: now);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('neforum-youtube-split');
      s = await AppServices.create(demo: true, storage: await openAppStorage(overrideDir: dir.path));
      for (final a in [account('ig', 'instagram'), account('yp', 'youtube_posts')]) {
        await s.accounts.upsert(a);
      }
    });
    tearDown(() async {
      s.dispose();
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file open.
      }
    });

    Post post(List<String> ids, {Map<String, dynamic> postsExtra = const {}}) => Post(
          id: 'p',
          text: 'I love apples',
          targets: [for (final id in ids) PostTarget(accountId: id, overrides: PostOverrides(extra: id == 'yp' ? postsExtra : const {}))],
          createdAt: now,
          updatedAt: now,
        );
    bool hasCard(Post p, String id) => (p.targetFor(id)!.overrides.mediaIds ?? const []).any((m) => p.media.any((x) => x.id == m && x.isTextCard));
    const settings = AppSettings();

    testWidgets('with Instagram making a card, YouTube Posts gets one too; "text only" keeps it plain', (tester) async {
      final both = (await tester.runAsync(() => attachTextCards(s, post(['ig', 'yp']), settings)))!;
      expect((hasCard(both, 'ig'), hasCard(both, 'yp')), (true, true));
      final plain = (await tester.runAsync(() => attachTextCards(s, post(['ig', 'yp'], postsExtra: {kTextCardChoiceKey: 'text'}), settings)))!;
      expect((hasCard(plain, 'ig'), hasCard(plain, 'yp')), (true, false));
    });

    testWidgets('YouTube Posts alone: words only, unless the post asks for the card', (tester) async {
      final alone = (await tester.runAsync(() => attachTextCards(s, post(['yp']), settings)))!;
      expect(hasCard(alone, 'yp'), isFalse);
      final asked = (await tester.runAsync(() => attachTextCards(s, post(['yp'], postsExtra: {kTextCardChoiceKey: 'card'}), settings)))!;
      expect(hasCard(asked, 'yp'), isTrue);
    });
  });

  test('a YouTube thumbnail is a file of the post\'s own: deleted with the post, kept while in use', () {
    final thumb = MediaAttachment(id: 't', path: '/media/thumb-1.jpg', mimeType: 'image/jpeg', sizeBytes: 9, width: 1280, height: 720);
    final p = Post(
      id: 'p',
      text: 'x',
      targets: [PostTarget(accountId: 'yt', overrides: PostOverrides(extra: {YouTubeAdapter.thumbnailKey: thumb.toJson()}))],
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    expect(audioCoverPaths(p), contains('/media/thumb-1.jpg'));
    expect(referencedFileNames([p.toJson()]), contains(mediaFileName('/media/thumb-1.jpg')), reason: 'not swept while the post keeps it');
  });
}
