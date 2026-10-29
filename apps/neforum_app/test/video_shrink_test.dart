// Videos over a network's size limit (1.3): the bitrate plan, the retries
// when a copy comes out too big, one copy per distinct limit shared by the
// networks with that limit, reuse, and what the composer says. The native
// compositor is replaced by a channel stub that writes small files.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/render_parameters.dart';
import 'package:neforum_app/media/video_shrink.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/platform/video_compositor.dart';
import 'package:neforum_app/state/captioned_photos.dart';
import 'package:neforum_app/state/fitted_photos.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/shrunk_videos.dart';
import 'package:neforum_app/state/video_frames.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('planVideoShrink', () {
    test('spends the limit less 4% over the duration, less the sound', () {
      // 50 MB over 100 s: 50e6 * 0.96 * 8 / 100 = 3.84 Mbit/s in all.
      final plan = planVideoShrink(limitBytes: 50000000, durationMs: 100000, width: 1920, height: 1080)!;
      expect(plan.audioBitsPerSecond, 128000);
      expect(plan.videoBitsPerSecond, 3840000 - 128000);
      expect(plan.maxSide, 1920);
    });

    test('each retry aims 15% lower', () {
      final first = planVideoShrink(limitBytes: 50000000, durationMs: 100000, width: 1920, height: 1080)!;
      final second = planVideoShrink(limitBytes: 50000000, durationMs: 100000, width: 1920, height: 1080, attempt: 1)!;
      final third = planVideoShrink(limitBytes: 50000000, durationMs: 100000, width: 1920, height: 1080, attempt: 2)!;
      expect(second.videoBitsPerSecond + second.audioBitsPerSecond, closeTo((first.videoBitsPerSecond + 128000) * 0.85, 1));
      expect(third.videoBitsPerSecond + third.audioBitsPerSecond, closeTo((first.videoBitsPerSecond + 128000) * 0.85 * 0.85, 1));
    });

    test('a silent video gives the sound\'s share to the picture', () {
      final plan = planVideoShrink(limitBytes: 50000000, durationMs: 100000, width: 1920, height: 1080, hasAudio: false)!;
      expect(plan.audioBitsPerSecond, 0);
      expect(plan.videoBitsPerSecond, 3840000);
    });

    test('less than 1 Mbit/s in all takes the AAC encoder\'s least sound bitrate', () {
      final plan = planVideoShrink(limitBytes: 10000000, durationMs: 120000, width: 1280, height: 720)!;
      expect(plan.audioBitsPerSecond, 96000);
      expect(plan.videoBitsPerSecond, (10000000 * 0.96 * 8 / 120).floor() - 96000);
    });

    test('drops the size while bits per pixel are too few, never below 360', () {
      // 4K at 2.5 Mbit/s: 1920 has 0.04 bits per pixel, 1280 has 0.09.
      final plan = planVideoShrink(limitBytes: 31250000, durationMs: 100000, width: 3840, height: 2160, hasAudio: false)!;
      expect(plan.videoBitsPerSecond, 2400000);
      expect(plan.maxSide, 1280);
      final starved = planVideoShrink(limitBytes: 1500000, durationMs: 60000, width: 1080, height: 1920, hasAudio: false)!;
      expect(starved.maxSide, 360);
    });

    test('never larger than the video', () {
      expect(planVideoShrink(limitBytes: 50000000, durationMs: 10000, width: 640, height: 360)!.maxSide, 640);
      expect(planVideoShrink(limitBytes: 50000000, durationMs: 10000, width: 1080, height: 1920)!.maxSide, 1920);
    });

    test('null when the video is too long for the limit, or nothing is known', () {
      // 10 MB over an hour: 21 kbit/s, under the 64 kbit/s floor.
      expect(planVideoShrink(limitBytes: 10000000, durationMs: 3600000, width: 1920, height: 1080), isNull);
      expect(planVideoShrink(limitBytes: 10000000, durationMs: 0, width: 1920, height: 1080), isNull);
      expect(planVideoShrink(limitBytes: 0, durationMs: 1000, width: 1920, height: 1080), isNull);
      expect(planVideoShrink(limitBytes: 10000000, durationMs: 1000, width: 0, height: 1080), isNull);
    });

    test('shrunkFrameSize scales down on even sides, as the runners do', () {
      expect(shrunkFrameSize(1920, 1080, 1280), (width: 1280, height: 720));
      expect(shrunkFrameSize(1080, 1920, 960), (width: 540, height: 960));
      expect(shrunkFrameSize(641, 361, 1920), (width: 642, height: 362), reason: 'never up, always even');
      expect(shrunkFrameSize(1000, 10, 360), (width: 360, height: 16), reason: 'at least 16');
    });
  });

  group('shrinkVideoToFit', () {
    final calls = <Map<String, Object?>>[];
    late Directory dir;
    // Bytes a copy comes out at, from its bitrates: overshoot as encoders do.
    double overshoot = 1.1;

    setUp(() async {
      calls.clear();
      overshoot = 1.1;
      dir = await Directory.systemTemp.createTemp('neforum-shrink');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), (call) async {
        if (call.method == 'isSupported') return true;
        if (call.method == 'transcode') {
          final args = Map<String, Object?>.from(call.arguments as Map);
          calls.add(args);
          final bits = (args['videoBitrate']! as int) + (args['audioBitrate']! as int);
          File(args['outputPath']! as String).writeAsBytesSync(Uint8List((bits * 4 / 8 * overshoot).round()));
        }
        return null;
      });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), null);
      await dir.delete(recursive: true);
    });

    const probe = VideoProbe(width: 1280, height: 720, durationMs: 4000, hasAudio: true);

    test('a copy over the limit is made again 15% lower', () async {
      final out = '${dir.path}/out.mp4';
      final result = await shrinkVideoToFit(VideoCompositor(), inputPath: '${dir.path}/in.mov', outputPath: out, limitBytes: 200000, probe: probe);
      expect(calls, hasLength(2));
      expect(calls[1]['videoBitrate']! as int, lessThan(calls[0]['videoBitrate']! as int));
      expect(result!.sizeBytes, lessThanOrEqualTo(200000));
      expect(result.plan, planVideoShrink(limitBytes: 200000, durationMs: 4000, width: 1280, height: 720, attempt: 1));
      expect(File(out).lengthSync(), result.sizeBytes);
    });

    test('gives up after three retries and leaves no file', () async {
      overshoot = 2;
      final out = '${dir.path}/out.mp4';
      final result = await shrinkVideoToFit(VideoCompositor(), inputPath: '${dir.path}/in.mov', outputPath: out, limitBytes: 200000, probe: probe);
      expect(result, isNull);
      expect(calls, hasLength(1 + kShrinkRetries));
      expect(File(out).existsSync(), isFalse);
    });
  });

  group('attachShrunkVideos', () {
    final transcoded = <Map<String, Object?>>[];

    setUp(() {
      transcoded.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), (call) async {
        switch (call.method) {
          case 'isSupported':
            return true;
          case 'probe':
            return {'width': 1920, 'height': 1080, 'rotation': 0, 'durationMs': 120000, 'hasAudio': true};
          case 'transcode':
            final args = Map<String, Object?>.from(call.arguments as Map);
            transcoded.add(args);
            File(args['outputPath']! as String).writeAsBytesSync(Uint8List(4096));
            return null;
        }
        return null;
      });
    });

    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), null));

    ConnectedAccount account(String id, String platform) => ConnectedAccount(
        id: id, platformId: platform, tier: PlatformTier.openApi, displayName: 'Me', handle: '@me', createdAt: DateTime(2026, 10, 1));

    Future<(AppServices, Directory, MediaAttachment)> workspace(WidgetTester tester, List<ConnectedAccount> accounts) async {
      return (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('neforum-shrunk-videos');
        final s = await AppServices.create(demo: true, storage: await openAppStorage(overrideDir: dir.path));
        for (final a in accounts) {
          await s.accounts.upsert(a);
        }
        final file = await s.media.importBytes(Uint8List.fromList([0, 0, 0, 24, 102, 116, 121, 112, ...List.filled(64, 1)]), fileName: 'long take.mp4');
        // The file is small; the size the networks see is what counts here.
        final video = MediaAttachment(id: file.id, path: file.path, mimeType: 'video/mp4', sizeBytes: 400000000, fileName: file.fileName);
        return (s, dir, video);
      }))!;
    }

    Post postFor(List<ConnectedAccount> accounts, List<MediaAttachment> media, {Map<String, List<String>> lists = const {}}) {
      final now = DateTime(2026, 10, 28);
      return Post(
        id: 'p-shrink',
        text: 'A long take',
        media: media,
        targets: [for (final a in accounts) PostTarget(accountId: a.id, overrides: PostOverrides(mediaIds: lists[a.id]))],
        createdAt: now,
        updatedAt: now,
      );
    }

    testWidgets('one copy per distinct limit, just under it; the original where it fits', (tester) async {
      final bluesky = account('bs', 'bluesky');
      final mastodon = account('md1', 'mastodon');
      final mastodon2 = account('md2', 'mastodon');
      final x = account('x', 'x');
      final accounts = [bluesky, mastodon, mastodon2, x];
      final (s, dir, video) = await workspace(tester, accounts);
      addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
      final settings = s.settings.copyWith(shrinkOversizedVideos: true);
      final progress = <String, String>{};

      var post = (await tester.runAsync(() => attachShrunkVideos(s, postFor(accounts, [video]), settings, onProgress: (id, m) => progress[id] = m)))!;
      final copies = post.media.where(isShrunkCopy).toList();
      expect(copies, hasLength(2), reason: 'Bluesky (300 MB) and Mastodon (99 MiB): two limits');
      expect(transcoded, hasLength(2));

      MediaAttachment sent(ConnectedAccount a) => post.media.singleWhere((m) => m.id == post.targetFor(a.id)!.overrides.mediaIds!.single);
      final forBluesky = sent(bluesky);
      final forMastodon = sent(mastodon);
      expect(forBluesky.renderParameters!['limitBytes'], 300000000);
      expect(forMastodon.renderParameters!['limitBytes'], 103809024);
      expect(sent(mastodon2).id, forMastodon.id, reason: 'the same limit shares a copy');
      expect(post.targetFor(x.id)!.overrides.mediaIds, isNull, reason: 'X takes the video as it is');
      for (final c in copies) {
        expect(c.derivedFrom, video.id);
        expect(renderKindOf(c), RenderKind.shrunkVideo);
        expect(c.fileName, 'long take (smaller).mp4');
        expect(c.sizeBytes, 4096);
        expect((c.width, c.height), (1920, 1080));
      }
      // Each copy aims at its own network's limit, never the smallest for all.
      final bitrates = {for (final t in transcoded) t['videoBitrate']! as int};
      expect(bitrates, {
        planVideoShrink(limitBytes: 300000000, durationMs: 120000, width: 1920, height: 1080)!.videoBitsPerSecond,
        planVideoShrink(limitBytes: 103809024, durationMs: 120000, width: 1920, height: 1080)!.videoBitsPerSecond,
      });
      expect(progress.keys.toSet(), {bluesky.id, mastodon.id, mastodon2.id});
      expect(progress[bluesky.id], contains('for Bluesky'));

      // Again (a retry): the copies are reused.
      post = (await tester.runAsync(() => attachShrunkVideos(s, post, settings)))!;
      expect(transcoded, hasLength(2));
      expect(post.media.where(isShrunkCopy).map((m) => m.id).toSet(), copies.map((m) => m.id).toSet());

      // Photo fitting hands them on untouched.
      post = (await tester.runAsync(() => attachFittedPhotos(s, post, settings)))!;
      expect(post.media.where(isShrunkCopy), hasLength(2));
      post = (await tester.runAsync(() => attachShrunkVideos(s, post, settings)))!;
      expect(transcoded, hasLength(2));
      expect(sent(bluesky).id, forBluesky.id);

      // Off: the copies go and every network lists the video again.
      post = (await tester.runAsync(() => attachShrunkVideos(s, post, settings.copyWith(shrinkOversizedVideos: false))))!;
      expect(post.media.where(isShrunkCopy), isEmpty);
      expect(File(forBluesky.path).existsSync(), isFalse);
      expect(post.targetFor(bluesky.id)!.overrides.mediaIds, [video.id]);
    });

    testWidgets('a video over the length limit is not shrunk; nor is a target already posted', (tester) async {
      final bluesky = account('bs', 'bluesky');
      final mastodon = account('md1', 'mastodon');
      final (s, dir, video) = await workspace(tester, [bluesky, mastodon]);
      addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
      final settings = s.settings.copyWith(shrinkOversizedVideos: true);
      final long = MediaAttachment(id: video.id, path: video.path, mimeType: video.mimeType, sizeBytes: video.sizeBytes, durationMs: 700000);
      var post = postFor([bluesky, mastodon], [long]);
      post = post.withTarget(post.targetFor(mastodon.id)!.copyWith(status: TargetStatus.published));
      post = (await tester.runAsync(() => attachShrunkVideos(s, post, settings)))!;
      expect(transcoded, isEmpty, reason: 'Bluesky takes 10 minutes at most; Mastodon has it already');
      expect(post.media.where(isShrunkCopy), isEmpty);
    });

    testWidgets('a captioned copy is shrunk as the network gets it, and still reads as captioned', (tester) async {
      final instagram = ConnectedAccount(
          id: 'ig', platformId: 'instagram', tier: PlatformTier.handoff, displayName: 'Me', handle: '@me', createdAt: DateTime(2026, 10, 1));
      final (s, dir, video) = await workspace(tester, [instagram]);
      addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
      final captioned = MediaAttachment(
        id: 'captioned',
        path: video.path,
        mimeType: 'video/mp4',
        sizeBytes: 400000000,
        generated: true,
        derivedFrom: video.id,
        fitKey: 'caption|instagram|${video.id}|abc|def',
        renderParameters: const {'kind': RenderKind.caption, 'video': true},
      );
      var post = postFor([instagram], [video, captioned], lists: {instagram.id: [captioned.id]});
      post = (await tester.runAsync(() => attachShrunkVideos(s, post, s.settings.copyWith(shrinkOversizedVideos: true))))!;
      final copy = post.media.singleWhere(isShrunkCopy);
      expect(transcoded.single['inputPath'], video.path);
      expect(copy.renderParameters!['source'], captioned.id);
      expect(copy.derivedFrom, video.id, reason: 'back to the video the user attached');
      expect(post.targetFor(instagram.id)!.overrides.mediaIds, [copy.id]);
      expect(captionChoicesOfPost(post, (_) => 'instagram'), {'instagram': true});
      // Fitting lists the attached video again, for the caption step to put
      // its copy back before the size step.
      expect(withoutFittedPhotos(post).targetFor(instagram.id)!.overrides.mediaIds ?? [video.id], [video.id]);
    });
  });

  group('withVideoLimitAdvice', () {
    testWidgets('size: an error that says by how much, or what will be shrunk; length: its own error', (tester) async {
      final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('neforum-advice')))!;
      addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
      final s = (await tester.runAsync(() async => AppServices.create(demo: true, storage: await openAppStorage(overrideDir: dir.path))))!;
      final d = s.registry.descriptor('bluesky')!;
      const big = MediaAttachment(id: 'v', path: '/v.mp4', mimeType: 'video/mp4', sizeBytes: 350000000, fileName: 'big.mp4', durationMs: 60000);
      final variant = PostVariant(text: 'x', media: const [big]);
      final core = RulesValidator.validate(variant, d);
      final tooLarge = core.singleWhere((i) => i.code == 'media.video_too_large');
      expect(tooLarge.message, contains('over the'));
      expect(tooLarge.message, contains('for Bluesky'));

      final off = withVideoLimitAdvice(core, variant, d, shrink: false, canShrink: true);
      expect(off.singleWhere((i) => i.code == 'media.video_too_large').severity, IssueSeverity.error);
      expect(off.singleWhere((i) => i.code == 'media.video_too_large').message, contains('Settings > Posting'));

      final on = withVideoLimitAdvice(core, variant, d, shrink: true, canShrink: true);
      expect(on.where((i) => i.code == 'media.video_too_large'), isEmpty);
      final info = on.singleWhere((i) => i.code == 'media.video_shrink');
      expect(info.severity, IssueSeverity.info);
      expect(info.message, 'big.mp4 (333.8 MB) will be shrunk to fit 286.1 MB for Bluesky');

      const long = MediaAttachment(id: 'l', path: '/l.mp4', mimeType: 'video/mp4', sizeBytes: 350000000, fileName: 'long.mp4', durationMs: 700000);
      final longVariant = PostVariant(text: 'x', media: const [long]);
      final advised = withVideoLimitAdvice(RulesValidator.validate(longVariant, d), longVariant, d, shrink: true, canShrink: true);
      final tooLong = advised.singleWhere((i) => i.code == 'media.video_too_long');
      expect(tooLong.severity, IssueSeverity.error);
      expect(tooLong.message, contains('11:40 long'));
      expect(tooLong.message, contains('Shrinking cannot shorten'));
      expect(advised.where((i) => i.code == 'media.video_shrink'), isEmpty, reason: 'a copy would not help');
    });
  });

  group('preview frames', () {
    test('black and flat frames are skipped', () {
      expect(isUninformativeFrame(8, 400), isTrue, reason: 'nearly black');
      expect(isUninformativeFrame(128, 10), isTrue, reason: 'one flat shade');
      expect(isUninformativeFrame(110, 900), isFalse);
    });

    test('positions fall between 10% and 90% of the video', () {
      final rng = math.Random(7);
      for (var i = 0; i < 200; i++) {
        expect(previewFramePosition(10000, rng), inInclusiveRange(1000, 9000));
      }
      expect(previewFramePosition(0, rng), 0);
    });

    test('frameLuminance reads a PNG', () {
      final grey = img.Image(width: 32, height: 32)..clear(img.ColorRgb8(128, 128, 128));
      final stats = frameLuminance(img.encodePng(grey))!;
      expect(stats.mean, closeTo(128, 1));
      expect(stats.variance, lessThan(1));
      final checker = img.Image(width: 64, height: 64);
      for (final p in checker) {
        final on = (p.x ~/ 8 + p.y ~/ 8).isEven;
        p
          ..r = on ? 255 : 0
          ..g = on ? 255 : 0
          ..b = on ? 255 : 0;
      }
      expect(frameLuminance(img.encodePng(checker))!.variance, greaterThan(10000));
      expect(frameLuminance(Uint8List.fromList([1, 2, 3])), isNull);
    });

    testWidgets('readPreviewFrame tries other places past black frames', (tester) async {
      final asked = <int>[];
      final black = img.encodePng(img.Image(width: 16, height: 16));
      final picture = img.Image(width: 16, height: 16);
      for (final p in picture) {
        p
          ..r = p.x * 16
          ..g = p.y * 16
          ..b = 90;
      }
      final png = img.encodePng(picture);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), (call) async {
        switch (call.method) {
          case 'isSupported':
            return true;
          case 'probe':
            return {'width': 1920, 'height': 1080, 'rotation': 0, 'durationMs': 20000, 'hasAudio': true};
          case 'frame':
            final at = (call.arguments as Map)['positionMs'] as int;
            asked.add(at);
            return {'png': asked.length < 3 ? black : png, 'width': 16, 'height': 16, 'positionMs': at};
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), null));
      final frame = (await tester.runAsync(() => readPreviewFrame(VideoCompositor(), '/v.mp4', random: math.Random(3))))!;
      expect(asked, hasLength(3));
      for (final at in asked) {
        expect(at, inInclusiveRange(2000, 18000));
      }
      expect(frame.png, png);
    });
  });
}
