// A video on TikTok or Instagram with the caption in a block above it: the
// caption pipeline asks the video compositor for a copy in the 9:16 frame,
// posts that copy, reuses it, and leaves the video alone for captions on it.
// The native compositor is replaced by a channel stub that writes a file.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/caption_style.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/captioned_photos.dart';
import 'package:neforum_app/state/fitted_photos.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final composed = <Map<String, Object?>>[];

  setUp(() {
    composed.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), (call) async {
      switch (call.method) {
        case 'isSupported':
          return true;
        case 'probe':
          return {'width': 720, 'height': 1280, 'rotation': 0, 'durationMs': 4000, 'hasAudio': true};
        case 'compose':
          final args = Map<String, Object?>.from(call.arguments as Map);
          composed.add(args);
          File(args['outputPath']! as String).writeAsBytesSync(Uint8List.fromList(List.filled(2048, 7)));
          return null;
      }
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), null));

  Future<(AppServices, ConnectedAccount, MediaAttachment, Directory)> workspace(WidgetTester tester) async {
    return (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('neforum-video-captions');
      final storage = await openAppStorage(overrideDir: dir.path);
      final s = await AppServices.create(demo: true, storage: storage);
      final tiktok = ConnectedAccount(
          id: 'tt-video', platformId: 'tiktok', tier: PlatformTier.handoff, displayName: 'Me', handle: '@me', createdAt: DateTime(2026, 10, 1));
      await s.accounts.upsert(tiktok);
      final video = await s.media.importBytes(Uint8List.fromList([0, 0, 0, 24, 102, 116, 121, 112, 109, 112, 52, 50, ...List.filled(64, 1)]), fileName: 'clip.mp4');
      return (s, tiktok, video, dir);
    }))!;
  }

  Post postWith(ConnectedAccount account, MediaAttachment video) {
    final now = DateTime(2026, 10, 25);
    return Post(id: 'p-video', text: 'Behind the scenes', media: [video], targets: [PostTarget(accountId: account.id)], createdAt: now, updatedAt: now);
  }

  testWidgets('a block above the video: a 9:16 copy is composed, posted and reused', (tester) async {
    final (s, tiktok, video, dir) = await workspace(tester);
    addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
    final style = const CaptionStyle(placement: CaptionPlacement.blockAbove).toJson();
    var post = postWith(tiktok, video);
    await tester.runAsync(() async {
      post = await attachCaptionedPhotos(s, post, s.settings, choices: const {'tiktok': true}, style: style);
    });

    final copy = post.media.singleWhere(isCaptionedCopy);
    expect(copy.mimeType, 'video/mp4');
    expect((copy.width, copy.height), (1080, 1920), reason: 'TikTok shows videos at 9:16');
    expect(copy.derivedFrom, video.id);
    expect(copy.renderParameters!['video'], isTrue);
    expect(copy.sizeBytes, 2048);
    expect(post.targetFor(tiktok.id)!.overrides.mediaIds!.first, copy.id, reason: 'the copy is what TikTok receives');
    expect(composed, hasLength(1));
    expect((composed.single['frameWidth'], composed.single['frameHeight']), (1080, 1920));
    expect(composed.single['inputPath'], video.path);
    expect(File(copy.path).existsSync(), isTrue);
    expect(captionChoicesOfPost(post, (_) => 'tiktok'), {'tiktok': true}, reason: 'a captioned video reads back as on');

    // Saving again from the composer (targets as the user set them, the old
    // copies handed over) with the same words and style reuses the copy.
    await tester.runAsync(() async {
      var again = post.copyWith(targets: [PostTarget(accountId: tiktok.id)]);
      again = await attachFittedPhotos(s, again, s.settings);
      post = await attachCaptionedPhotos(s, again, s.settings, choices: const {'tiktok': true}, style: style);
      await s.posts.upsert(post);
    });
    expect(composed, hasLength(1));
    expect(post.media.singleWhere(isCaptionedCopy).id, copy.id);
    expect(post.targetFor(tiktok.id)!.overrides.mediaIds!.first, copy.id);

    // Scheduled and background publishing keep it without composing again.
    await tester.runAsync(() => fitPhotosOfSavedPost(s, post.id));
    final saved = (await tester.runAsync(() => s.posts.get(post.id)))!;
    expect(saved.targetFor(tiktok.id)!.overrides.mediaIds!.first, copy.id);
    expect(composed, hasLength(1));
  });

  testWidgets('a caption on the photo leaves a video as it is', (tester) async {
    final (s, tiktok, video, dir) = await workspace(tester);
    addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
    var post = postWith(tiktok, video);
    await tester.runAsync(() async {
      post = await attachCaptionedPhotos(s, post, s.settings,
          choices: const {'tiktok': true}, style: const CaptionStyle(placement: CaptionPlacement.bottom).toJson());
    });
    expect(post.media.where(isCaptionedCopy), isEmpty);
    expect(composed, isEmpty);
    expect(post.targetFor(tiktok.id)!.overrides.mediaIds, isNull);
    expect(videoFrameAspect('instagram'), 9 / 16);
    expect(videoFrameAspect('mastodon'), isNull);
  });
}
