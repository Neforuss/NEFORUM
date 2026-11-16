// 1.4.4: GIFs on Instagram. Instagram's API takes no GIF, so an animated GIF
// becomes an MP4 (H.264, the GIF's timing, looped to at least 5 s, in the
// frame Settings fit photos to) made by the runner's compositor; a GIF that
// does not move, or one on a device that cannot make videos, becomes a still
// JPEG. The native encoders are faked here (the "neforum/video" channel); the
// Windows encoder itself runs in integration_test/video_tools_test.dart.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/gif_video.dart';
import 'package:neforum_app/media/photo_fitter.dart';
import 'package:neforum_app/media/render_parameters.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/platform/video_compositor.dart';
import 'package:neforum_app/state/captioned_photos.dart' show videoCaptionsSupportedProvider;
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/fitted_photos.dart';
import 'package:neforum_app/state/gif_videos.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// An animated GIF of [colours] (one picture each, [width] x [height]),
/// each shown [centiseconds].
Uint8List gifOf(List<img.Color> colours, {int width = 64, int height = 36, int centiseconds = 10}) {
  final encoder = img.GifEncoder();
  for (final c in colours) {
    encoder.addFrame(img.Image(width: width, height: height)..clear(c), duration: centiseconds);
  }
  return encoder.finish()!;
}

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

final img.Color _red = img.ColorRgb8(220, 20, 20);
final img.Color _green = img.ColorRgb8(20, 200, 40);
final img.Color _blue = img.ColorRgb8(30, 40, 230);

ConnectedAccount _instagram(String id, PlatformTier tier) =>
    ConnectedAccount(id: id, platformId: 'instagram', tier: tier, displayName: id, createdAt: DateTime(2026, 11, 16));

void main() {
  group('reading a GIF', () {
    test('its pictures, size and timing; 0 and 1 hundredths play as 100 ms, like browsers', () {
      final a = readGifAnimation(gifOf([_red, _green, _blue], centiseconds: 7))!;
      expect((a.width, a.height, a.frameCount, a.isAnimated), (64, 36, 3, true));
      expect(a.frameDelaysMs, [70, 70, 70]);
      expect(a.durationMs, 210);
      expect(readGifAnimation(gifOf([_red, _green], centiseconds: 0))!.frameDelaysMs, [100, 100]);
      expect(gifFrameDelayMs(1), 100);
      expect(gifFrameDelayMs(2), 20);
    });

    test('a one-picture GIF is a still; a file that is no GIF is nothing', () {
      expect(readGifAnimation(gifOf([_red]))!.isAnimated, isFalse);
      expect(readGifAnimation(img.encodePng(img.Image(width: 4, height: 4))), isNull);
      expect(readGifAnimation(Uint8List.fromList('GIF89a'.codeUnits)), isNull);
    });
  });

  group('timeline', () {
    test('a short GIF loops (whole loops) to at least 5 s at 30 frames a second', () {
      final t = gifVideoTimeline([100, 100, 100]);
      expect(t.loops, 17, reason: '300 ms a pass: 17 passes are 5.1 s');
      expect(t.frameCount, 153);
      expect(t.durationMs, 5100);
      expect(t.spans.take(3), [(frame: 0, count: 3), (frame: 1, count: 3), (frame: 2, count: 3)]);
      expect(t.spans, hasLength(51));
    });

    test('each picture starts on the video frame nearest its own start: no drift over a long GIF', () {
      // 70 ms is 2.1 video frames: rounding each picture alone would lose
      // 0.1 frame a picture, 7 frames over this GIF.
      final delays = List.filled(70, 70);
      final t = gifVideoTimeline(delays);
      expect(t.loops, 2, reason: '4.9 s a pass');
      expect(t.frameCount, (2 * 70 * 70 * 30 / 1000).round());
      var at = 0;
      var elapsedMs = 0;
      for (final s in t.spans.take(70)) {
        expect((at - elapsedMs * 30 / 1000).abs(), lessThanOrEqualTo(0.5), reason: 'picture ${s.frame} starts on time');
        at += s.count;
        elapsedMs += 70;
      }
      expect(t.spans.map((s) => s.count).toSet(), {2, 3});
    });

    test('a picture shorter than a video frame can be skipped; a long GIF is cut at 60 s', () {
      final fast = gifVideoTimeline([10, 10, 10, 10, 10, 10]);
      expect(fast.loops, 84, reason: '60 ms a pass');
      expect(fast.frameCount, 151, reason: '5.04 s at 30 frames a second');
      expect(fast.spans.length, fast.frameCount, reason: 'at most one picture a video frame, not all 504');
      expect(fast.durationMs, greaterThanOrEqualTo(kGifVideoMinMs));
      final long = gifVideoTimeline(List.filled(100, 1000));
      expect((long.loops, long.durationMs, long.spans.length), (1, 60000, 60));
    });

    test('a GIF longer than 5 s plays once', () {
      final t = gifVideoTimeline(List.filled(12, 500));
      expect((t.loops, t.durationMs), (1, 6000));
    });
  });

  group('frame size', () {
    const story = PhotoFit(mimeTypes: {'image/jpeg'}, gifAsVideo: true);
    const feed = PhotoFit(minAspect: 0.8, maxAspect: 1.91, mimeTypes: {'image/jpeg'}, gifAsVideo: true);

    test('the shape a photo would get, the long side scaled into 1280 to 1920, even sides', () {
      // Fill the frame: Instagram 4:5 and 9:16.
      expect(gifVideoFrameSize(480, 270, feed.copyWith(minAspect: 0.8, maxAspect: 0.8), PhotoFitMode.pad), (width: 1024, height: 1280));
      expect(gifVideoFrameSize(480, 270, story.copyWith(minAspect: 9 / 16, maxAspect: 9 / 16), PhotoFitMode.pad), (width: 720, height: 1280));
      // Its own shape where the rules allow it.
      expect(gifVideoFrameSize(480, 270, story, PhotoFitMode.pad), (width: 1280, height: 720));
      expect(gifVideoFrameSize(480, 270, feed, PhotoFitMode.pad), (width: 1280, height: 720));
      // Too wide for the feed: borders (or a cut) to 1.91:1.
      expect(gifVideoFrameSize(1000, 400, feed, PhotoFitMode.pad), (width: 1280, height: 670));
      expect(gifVideoFrameSize(1000, 400, feed, PhotoFitMode.crop), (width: 1280, height: 670));
      // A big GIF is scaled down to 1920.
      expect(gifVideoFrameSize(3000, 3000, story, PhotoFitMode.pad), (width: 1920, height: 1920));
      // Odd sizes become even.
      final odd = gifVideoFrameSize(333, 501, story, PhotoFitMode.pad);
      expect((odd.width.isEven, odd.height.isEven, odd.height), (true, true, 1280));
    });
  });

  test('every picture is drawn whole in the video frame, in its own colour', () async {
    final dir = await Directory.systemTemp.createTemp('neforum-gif-frames');
    addTearDown(() => dir.delete(recursive: true));
    final paths = ['${dir.path}/a.png', '${dir.path}/b.png', '${dir.path}/c.png'];
    final ok = renderGifFramesJob((gifOf([_red, _green, _blue], width: 40, height: 40), 72, 128, PhotoFitMode.pad, const [0, 1, 2], paths));
    expect(ok, isTrue);
    for (final (i, want) in [(0, _red), (1, _green), (2, _blue)]) {
      final png = img.decodePng(File(paths[i]).readAsBytesSync())!;
      expect((png.width, png.height), (72, 128));
      final middle = png.getPixel(36, 64);
      expect((middle.r.toInt() - want.r.toInt()).abs() + (middle.g.toInt() - want.g.toInt()).abs() + (middle.b.toInt() - want.b.toInt()).abs(),
          lessThan(40), reason: 'picture $i');
    }
    expect(renderGifFramesJob((Uint8List.fromList([1, 2, 3]), 72, 128, PhotoFitMode.pad, const [0], [paths.first])), isFalse);
  });

  test('a GIF still: its first picture, transparent parts black', () {
    final rgba = img.Image(width: 8, height: 8, numChannels: 4)..clear(img.ColorRgba8(0, 0, 0, 0));
    img.fillRect(rgba, x1: 0, y1: 0, x2: 3, y2: 7, color: img.ColorRgba8(250, 250, 0, 255));
    final encoder = img.GifEncoder()
      ..addFrame(rgba, duration: 10)
      ..addFrame(img.Image(width: 8, height: 8)..clear(_blue), duration: 10);
    final first = gifFirstFrame(encoder.finish()!)!;
    expect(first.numChannels, 3);
    expect(first.getPixel(1, 1).r.toInt(), greaterThan(200));
    expect(first.getPixel(6, 6).b.toInt(), lessThan(60), reason: 'not the second picture');
  });

  test('the compositor request is checked before it is sent', () {
    String? problem({List<String> paths = const ['/a.png'], List<int> counts = const [3], String out = '/v.mp4', int w = 720, int h = 1280, int fps = 30}) =>
        VideoCompositor.framesVideoProblem(framePaths: paths, frameCounts: counts, outputPath: out, frameWidth: w, frameHeight: h, frameRate: fps);
    expect(problem(), isNull);
    expect(problem(paths: const []), isNotNull);
    expect(problem(counts: const [3, 4]), isNotNull);
    expect(problem(counts: const [0]), isNotNull);
    expect(problem(counts: const [3601]), isNotNull);
    expect(problem(out: '/v.mov'), isNotNull);
    expect(problem(w: 721), isNotNull);
    expect(problem(fps: 61), isNotNull);
  });

  group('on save', () {
    final calls = <(String, Map<String, Object?>)>[];
    var supported = true;
    setUp(() {
      calls.clear();
      supported = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), (call) async {
        final args = call.arguments is Map ? Map<String, Object?>.from(call.arguments as Map) : const <String, Object?>{};
        switch (call.method) {
          case 'isSupported':
            return supported;
          case 'framesVideo':
            // What the runner gets: every picture is a PNG of the frame's size.
            final sizes = {
              for (final p in (args['framePaths']! as List).cast<String>().toSet())
                p: () {
                  final png = img.decodePng(File(p).readAsBytesSync())!;
                  return (png.width, png.height);
                }(),
            };
            calls.add((call.method, {...args, 'pngSizes': sizes.values.toSet()}));
            File(args['outputPath']! as String).writeAsBytesSync(Uint8List.fromList(List.filled(2048, 7)));
            return null;
        }
        return null;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), null));

    Future<(AppServices, Directory)> workspace(WidgetTester tester, List<ConnectedAccount> accounts) async {
      final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('neforum-gif-save')))!;
      addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
      final s = (await tester.runAsync(() async {
        final s = await AppServices.create(demo: true, storage: await openAppStorage(overrideDir: dir.path));
        for (final a in accounts) {
          await s.accounts.upsert(a);
        }
        return s;
      }))!;
      return (s, dir);
    }

    Post postOf(List<MediaAttachment> media, List<PostTarget> targets) {
      final now = DateTime(2026, 11, 16);
      return Post(id: 'p-gif', text: 'It moves', media: media, targets: targets, createdAt: now, updatedAt: now);
    }

    testWidgets('Post + Story: an MP4 for the feed (4:5) and one for the story (9:16), with the GIF\'s timing; reused, then undone', (tester) async {
      final ig = _instagram('ig', PlatformTier.byokApi);
      final (s, _) = await workspace(tester, [ig]);
      final gif = (await tester.runAsync(() => s.media.importBytes(gifOf([_red, _green, _blue], width: 48, height: 27), fileName: 'party.gif')))!;
      expect(gif.mimeType, 'image/gif');
      var post = postOf([gif], [
        PostTarget(accountId: ig.id, overrides: PostOverrides(extra: extraWithPlacement(const {}, PostPlacement.feedAndStory))),
      ]);
      final settings = s.settings;
      post = (await tester.runAsync(() => attachFittedPhotos(s, post, settings, compositor: VideoCompositor())))!;

      expect(calls.map((c) => c.$1), ['framesVideo', 'framesVideo']);
      final feedCall = calls.first.$2, storyCall = calls.last.$2;
      expect((feedCall['frameWidth'], feedCall['frameHeight']), (1024, 1280), reason: 'Instagram fills its 4:5 feed frame');
      expect((storyCall['frameWidth'], storyCall['frameHeight']), (720, 1280), reason: 'and its 9:16 story frame');
      for (final c in [feedCall, storyCall]) {
        expect((c['outputPath']! as String).endsWith('.mp4'), isTrue, reason: 'an MP4 container');
        expect(c['frameRate'], 30);
        final counts = (c['frameCounts']! as List).cast<int>();
        expect(counts.fold<int>(0, (a, b) => a + b), 153, reason: '17 loops of 300 ms: 5.1 s at 30 frames a second');
        expect(counts.take(3), [3, 3, 3], reason: 'each picture 100 ms');
        expect((c['framePaths']! as List).toSet(), hasLength(3), reason: 'three pictures, each drawn once');
        expect(c['pngSizes'], {(c['frameWidth'], c['frameHeight'])});
      }

      final t = post.targetFor(ig.id)!;
      final feed = post.media.singleWhere((m) => m.id == t.overrides.mediaIds!.single);
      final story = post.media.singleWhere((m) => m.id == t.overrides.storyMediaIds!.single);
      for (final v in [feed, story]) {
        expect((v.mimeType, v.isVideo, v.derivedFrom, v.generated, v.durationMs), ('video/mp4', true, gif.id, true, 5100));
        expect(isGifVideo(v), isTrue);
        expect(renderKindOf(v), RenderKind.gifVideo);
        expect(v.fileName, 'party (video).mp4');
      }
      expect((feed.width, feed.height, story.width, story.height), (1024, 1280, 720, 1280));
      // The pictures were temporary.
      expect(Directory('${s.storage.dataDir}/media').listSync().where((f) => f.path.endsWith('.png')), isEmpty);

      // What the adapter checks: the feed video and the video story pass.
      final variant = const VariantResolver().resolve(post, t, s.registry.descriptor('instagram')!, account: ig);
      expect(variant.media.single.id, feed.id);
      expect(variant.storyMedia.single.id, story.id);
      expect(s.registry.byId('instagram')!.validate(variant, ig).where((i) => i.isError), isEmpty);

      // Saving again reuses both videos.
      post = (await tester.runAsync(() => attachFittedPhotos(s, post, settings, compositor: VideoCompositor())))!;
      expect(calls, hasLength(2));
      expect(post.media.where(isGifVideo).map((m) => m.id).toSet(), {feed.id, story.id});

      // A background run (no compositor) keeps them too.
      supported = false;
      post = (await tester.runAsync(() => attachFittedPhotos(s, post, settings, compositor: VideoCompositor())))!;
      expect(post.media.where(isGifVideo).map((m) => m.id).toSet(), {feed.id, story.id});
      expect(post.media.where((m) => m.derivedFrom == gif.id && m.mimeType == 'image/jpeg'), isEmpty, reason: 'never a still in their place');

      // Editing shows the GIF again.
      final shown = withoutFittedPhotos(post);
      expect(shown.media.map((m) => m.id), [gif.id]);
      expect(shown.targetFor(ig.id)!.overrides.mediaIds, isNull);
    });

    testWidgets('a Story alone gets one 9:16 video; a still photo beside it is fitted as before', (tester) async {
      final ig = _instagram('ig', PlatformTier.byokApi);
      final (s, _) = await workspace(tester, [ig]);
      late MediaAttachment gif, photo;
      await tester.runAsync(() async {
        gif = await s.media.importBytes(gifOf([_red, _blue], width: 40, height: 40, centiseconds: 50), fileName: 'wave.gif');
        photo = await s.media.importBytes(img.encodeJpg(img.Image(width: 900, height: 1600)..clear(_green)), fileName: 'tall.jpg');
      });
      var post = postOf([gif, photo], [
        PostTarget(accountId: ig.id, overrides: PostOverrides(extra: extraWithPlacement(const {}, PostPlacement.story))),
      ]);
      post = (await tester.runAsync(() => attachFittedPhotos(s, post, s.settings, compositor: VideoCompositor())))!;
      expect(calls, hasLength(1));
      expect((calls.single.$2['frameWidth'], calls.single.$2['frameHeight']), (720, 1280));
      expect((calls.single.$2['frameCounts']! as List).cast<int>(), List.filled(10, 15), reason: '1 s a pass, 5 passes, half a second each picture');
      final ids = post.targetFor(ig.id)!.overrides.mediaIds!;
      final video = post.media.singleWhere((m) => m.id == ids.first);
      expect((video.isVideo, video.durationMs), (true, 5000));
      expect(ids[1], photo.id, reason: 'a 9:16 JPEG is right for a story as it is');
    });

    testWidgets('a GIF that does not move becomes a still JPEG, with no video made', (tester) async {
      final ig = _instagram('ig', PlatformTier.byokApi);
      final (s, _) = await workspace(tester, [ig]);
      final gif = (await tester.runAsync(() => s.media.importBytes(gifOf([_red], width: 50, height: 50), fileName: 'dot.gif')))!;
      var post = postOf([gif], [PostTarget(accountId: ig.id)]);
      post = (await tester.runAsync(() => attachFittedPhotos(s, post, s.settings, compositor: VideoCompositor())))!;
      expect(calls, isEmpty);
      final still = post.media.singleWhere((m) => m.id == post.targetFor(ig.id)!.overrides.mediaIds!.single);
      expect((still.mimeType, still.derivedFrom, still.width, still.height), ('image/jpeg', gif.id, 50, 63), reason: 'given borders to 4:5');
    });

    testWidgets('without a compositor an animated GIF becomes a still JPEG of its first picture', (tester) async {
      supported = false;
      final ig = _instagram('ig', PlatformTier.byokApi);
      final (s, _) = await workspace(tester, [ig]);
      final gif = (await tester.runAsync(() => s.media.importBytes(gifOf([_red, _blue], width: 40, height: 50), fileName: 'blink.gif')))!;
      var post = postOf([gif], [PostTarget(accountId: ig.id)]);
      post = (await tester.runAsync(() => attachFittedPhotos(s, post, s.settings, compositor: VideoCompositor())))!;
      expect(calls, isEmpty);
      final still = post.media.singleWhere((m) => m.id == post.targetFor(ig.id)!.overrides.mediaIds!.single);
      expect((still.mimeType, still.isVideo), ('image/jpeg', false));
      final pixels = img.decodeJpg((await tester.runAsync(() => s.media.read(still)))!)!;
      final middle = pixels.getPixel(pixels.width ~/ 2, pixels.height ~/ 2);
      expect(middle.r.toInt(), greaterThan(150), reason: 'the first picture (red), not the second');
    });

    testWidgets('hand-off and other networks get the GIF as it is', (tester) async {
      final handoff = _instagram('ig-h', PlatformTier.handoff);
      final masto = ConnectedAccount(id: 'm', platformId: 'mastodon', tier: PlatformTier.byokApi, displayName: 'm', createdAt: DateTime(2026, 11, 16));
      final (s, _) = await workspace(tester, [handoff, masto]);
      final gif = (await tester.runAsync(() => s.media.importBytes(gifOf([_red, _blue]), fileName: 'blink.gif')))!;
      var post = postOf([gif], [PostTarget(accountId: handoff.id), PostTarget(accountId: masto.id)]);
      post = (await tester.runAsync(() => attachFittedPhotos(s, post, s.settings, compositor: VideoCompositor())))!;
      expect(calls, isEmpty);
      expect(post.media.map((m) => m.id), [gif.id]);
      expect(post.targets.map((t) => t.overrides.mediaIds), everyElement(isNull));
    });

    testWidgets('a failed encode leaves no file and falls back to the still', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), (call) async {
        if (call.method == 'isSupported') return true;
        throw PlatformException(code: 'framesVideo', message: 'encoder broke');
      });
      final ig = _instagram('ig', PlatformTier.byokApi);
      final (s, _) = await workspace(tester, [ig]);
      final gif = (await tester.runAsync(() => s.media.importBytes(gifOf([_red, _blue]), fileName: 'blink.gif')))!;
      var post = postOf([gif], [PostTarget(accountId: ig.id)]);
      post = (await tester.runAsync(() => attachFittedPhotos(s, post, s.settings, compositor: VideoCompositor())))!;
      final listed = post.media.singleWhere((m) => m.id == post.targetFor(ig.id)!.overrides.mediaIds!.single);
      expect(listed.mimeType, 'image/jpeg');
      final files = Directory('${s.storage.dataDir}/media').listSync().map((f) => f.path.split(Platform.pathSeparator).last).toList();
      expect(files.where((f) => f.endsWith('.mp4') || f.endsWith('.png')), isEmpty, reason: 'no half-made video, no pictures left');
    });
  });

  group('the composer', () {
    Future<(AppServices, ProviderContainer)> boot(WidgetTester tester, {required bool canMakeVideos}) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
      await tester.pumpWidget(ProviderScope(overrides: [
        servicesProvider.overrideWithValue(services),
        videoCaptionsSupportedProvider.overrideWith((ref) async => canMakeVideos),
      ], child: const NeforumApp()));
      await tester.pump(const Duration(milliseconds: 300));
      return (services, ProviderScope.containerOf(tester.element(find.byType(MaterialApp))));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    Future<Map<String, TargetPreview>> previewsOf(WidgetTester tester, {required bool canMakeVideos, required List<Uint8List> gifs}) async {
      final (services, c) = await boot(tester, canMakeVideos: canMakeVideos);
      final api = _instagram('ig-api', PlatformTier.byokApi);
      await tester.runAsync(() => services.accounts.upsert(api));
      final media = [
        for (final (i, bytes) in gifs.indexed) (await tester.runAsync(() => services.media.importBytes(bytes, fileName: 'gif$i.gif')))!,
      ];
      final now = DateTime(2026, 11, 16);
      c.read(composerProvider.notifier).load(Post(
            id: 'p-gif-preview',
            text: 'It moves',
            media: media,
            targets: [PostTarget(accountId: api.id)],
            createdAt: now,
            updatedAt: now,
          ));
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
      c.read(composerProvider.notifier).selectAccounts([api.id, masto.id]);
      await settle(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
      final out = {for (final p in c.read(composerPreviewsProvider)) p.account.platformId: p};
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      return out;
    }

    testWidgets('an animated GIF "plays as a video on Instagram"; the check sees the video, not an error', (tester) async {
      final previews = await previewsOf(tester, canMakeVideos: true, gifs: [gifOf([_red, _green, _blue], width: 480, height: 270)]);
      final ig = previews['instagram']!;
      final video = ig.variant.media.single;
      expect((video.mimeType, video.width, video.height, video.durationMs), ('video/mp4', 1024, 1280, 5100));
      expect(ig.issues.where((i) => i.code == 'media.gif_video').single.message,
          'gif0.gif plays as a video on Instagram: NEFORUM makes an MP4 of it when you save');
      expect(ig.issues.where((i) => i.isError), isEmpty);
      expect(ig.issues.map((i) => i.code), isNot(contains('media.dropped')));
      expect(previews['mastodon']!.variant.media.single.mimeType, 'image/gif', reason: 'Mastodon takes the GIF itself');
    });

    testWidgets('without a compositor: a still, said plainly; a GIF that does not move is just a photo made a JPEG', (tester) async {
      final previews = await previewsOf(tester, canMakeVideos: false, gifs: [gifOf([_red, _blue], width: 400, height: 500), gifOf([_red], width: 400, height: 500)]);
      final ig = previews['instagram']!;
      expect(ig.variant.media.map((m) => m.mimeType), ['image/jpeg', 'image/jpeg']);
      expect(ig.issues.where((i) => i.code == 'media.gif_still').single.message,
          'gif0.gif goes to Instagram as a still picture (its first frame): Instagram takes no GIF, and this device cannot make videos');
      expect(ig.issues.where((i) => i.code == 'media.photo_fit').single.message, 'gif1.gif will be made a still JPEG for Instagram');
      expect(ig.issues.where((i) => i.isError), isEmpty);
    });
  });

  test('the composer\'s stand-in is the video the save makes', () {
    const fit = PhotoFit(minAspect: 0.8, maxAspect: 0.8, mimeTypes: {'image/jpeg'}, gifAsVideo: true);
    const gif = MediaAttachment(id: 'g', path: '/g.gif', mimeType: 'image/gif', sizeBytes: 1000, width: 480, height: 270, fileName: 'party.gif');
    final standIn = gifVideoStandIn(gif, const GifAnimation(width: 480, height: 270, frameDelaysMs: [100, 100, 100]), fit, PhotoFitMode.pad);
    expect((standIn.mimeType, standIn.width, standIn.height, standIn.durationMs, standIn.derivedFrom), ('video/mp4', 1024, 1280, 5100, 'g'));
    expect(standIn.path, gif.path, reason: 'the preview shows the GIF');
    expect(standIn.sizeBytes, lessThan(100 * 1024 * 1024), reason: 'under the story video limit');
  });
}
