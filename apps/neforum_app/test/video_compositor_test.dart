import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/video_compositor.dart';

/// Enough of a PNG for the request check (the runner decodes the rest).
final Uint8List _png = Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);

/// A portrait phone video: a landscape frame shown rotated.
const Map<String, Object?> _portrait = {'width': 1920, 'height': 1080, 'rotation': 90, 'durationMs': 15000, 'hasAudio': true};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(VideoCompositor.channelName);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  /// Answers the compositor's calls like a runner would; [compose] decides
  /// what a composition does.
  void runner({bool supported = true, Object? probe = _portrait, Future<Object?> Function(MethodCall call)? compose}) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'isSupported':
          return supported;
        case 'probe':
          if (probe is PlatformException) throw probe;
          return probe;
        case 'compose':
          return compose == null ? null : await compose(call);
      }
      return null;
    });
  }

  /// A "progress" call from the runner, as the native side sends it.
  Future<void> progress(int id, double value) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall('progress', {'id': id, 'progress': value}));
    await messenger.handlePlatformMessage(VideoCompositor.channelName, data, (_) {});
  }

  Future<void> compose(
    VideoCompositor compositor, {
    int frameWidth = 1080,
    int frameHeight = 1920,
    Rect contentRect = const Rect.fromLTWH(0, 600, 1080, 1320),
    Uint8List? overlay,
    String output = '/media/out.mp4',
    void Function(double)? onProgress,
  }) =>
      compositor.compose(
        inputPath: '/media/in.mov',
        outputPath: output,
        overlayPng: overlay ?? _png,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        contentRect: contentRect,
        backgroundArgb: 0x80123456,
        onProgress: onProgress,
      );

  Matcher failsWith(String code) => throwsA(isA<VideoCompositionException>().having((e) => e.code, 'code', code));

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Linux and the web have no compositor: nothing is asked of the runner', () async {
    runner();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final compositor = VideoCompositor();
      expect(VideoCompositor.platformHasCompositor, isFalse);
      expect(await compositor.isSupported(), isFalse);
      expect(await compositor.probe('/media/in.mov'), isNull);
      await expectLater(compose(compositor), failsWith('unsupported'));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(calls, isEmpty);
  });

  test('a runner without the channel (an old build, a background engine) has no compositor', () async {
    final compositor = VideoCompositor();
    expect(await compositor.isSupported(), isFalse);
    expect(await compositor.probe('/media/in.mov'), isNull);
    await expectLater(compose(compositor), failsWith('unsupported'));
  });

  test('a device without an encoder says so once, and nothing is composed', () async {
    runner(supported: false);
    final compositor = VideoCompositor();
    expect(await compositor.isSupported(), isFalse);
    expect(await compositor.isSupported(), isFalse);
    await expectLater(compose(compositor), failsWith('unsupported'));
    expect(calls.map((c) => c.method), ['isSupported']);
  });

  test('a runner that fails while answering counts as no compositor', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'boom'));
    expect(await VideoCompositor().isSupported(), isFalse);
    messenger.setMockMethodCallHandler(channel, (call) async => 'yes');
    expect(await VideoCompositor().isSupported(), isFalse, reason: 'not a bool');
  });

  group('probe', () {
    test('reads the size, rotation, duration and sound', () async {
      runner(probe: const {'width': 1920, 'height': 1080, 'rotation': -90, 'durationMs': 12345.6, 'hasAudio': true});
      final probe = await VideoCompositor().probe('/media/in.mov');
      expect(probe, const VideoProbe(width: 1920, height: 1080, rotation: 270, durationMs: 12346, hasAudio: true));
      expect(probe!.displayWidth, 1080);
      expect(probe.displayHeight, 1920);
      expect(calls.last.arguments, {'path': '/media/in.mov'});
    });

    test('an unreadable video, a bad answer or a failure is null', () async {
      for (final answer in <Object?>[
        null,
        'video',
        const {'width': 0, 'height': 1080},
        const {'width': 1920},
        PlatformException(code: 'probe', message: 'This file has no video.'),
      ]) {
        runner(probe: answer);
        expect(await VideoCompositor().probe('/media/in.mov'), isNull, reason: '$answer');
      }
      runner();
      expect(await VideoCompositor().probe(''), isNull);
    });

    test('missing fields mean no rotation, no duration and no sound', () async {
      runner(probe: const {'width': 640, 'height': 360});
      final probe = await VideoCompositor().probe('/media/in.mp4');
      expect(probe, const VideoProbe(width: 640, height: 360));
      expect(probe!.displayWidth, 640);
    });

    test('rotations are whole quarter turns', () {
      final cases = {0: 0, 90: 90, -90: 270, 180: 180, -180: 180, 270: 270, 360: 0, 450: 90, 359: 0, 89.6: 90, double.nan: 0};
      cases.forEach((degrees, expected) => expect(VideoProbe.normalizedRotation(degrees), expected, reason: '$degrees'));
    });
  });

  group('compose', () {
    test('sends the frame, the fitted video, the colour and the caption; reports progress up to 1', () async {
      late Map<Object?, Object?> sent;
      runner(compose: (call) async {
        sent = call.arguments as Map<Object?, Object?>;
        final id = sent['id']! as int;
        await progress(id, 0.25);
        await progress(id, 0.6);
        await progress(id, 0.5); // late, out of order: never shown going back
        await progress(id + 1, 0.9); // another job's
        return null;
      });
      final reported = <double>[];
      await compose(VideoCompositor(), onProgress: reported.add);

      expect(calls.map((c) => c.method), ['isSupported', 'probe', 'compose']);
      expect(sent['inputPath'], '/media/in.mov');
      expect(sent['outputPath'], '/media/out.mp4');
      expect(sent['overlayPng'], _png);
      expect(sent['frameWidth'], 1080);
      expect(sent['frameHeight'], 1920);
      // A 1080x1920 picture (the portrait video upright) fitted into the
      // 1080x1320 area under a 600-pixel caption block: 742.5 wide, centred.
      expect([sent['videoLeft'], sent['videoTop'], sent['videoWidth'], sent['videoHeight']], [169, 600, 742, 1320]);
      expect(sent['backgroundRgb'], 0x123456, reason: 'video has no alpha');
      expect(reported, [0, 0.25, 0.6, 1]);
    });

    test('a native failure arrives with its code and message', () async {
      runner(compose: (call) async => throw PlatformException(code: 'audio', message: 'The sound of this video could not be converted.'));
      await expectLater(
        compose(VideoCompositor()),
        throwsA(isA<VideoCompositionException>()
            .having((e) => e.code, 'code', 'audio')
            .having((e) => e.message, 'message', 'The sound of this video could not be converted.')),
      );
    });

    test('a video that cannot be read never reaches the encoder', () async {
      runner(probe: null);
      await expectLater(compose(VideoCompositor()), failsWith('probe'));
      expect(calls.map((c) => c.method), ['isSupported', 'probe']);
    });

    test('requests NEFORUM should not make are refused before the runner sees them', () async {
      runner();
      final compositor = VideoCompositor();
      await expectLater(compose(compositor, frameWidth: 1081), failsWith('invalid'));
      await expectLater(compose(compositor, frameHeight: 8192), failsWith('invalid'));
      await expectLater(compose(compositor, overlay: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])), failsWith('invalid'));
      await expectLater(compose(compositor, output: '/media/out.mov'), failsWith('invalid'));
      await expectLater(compose(compositor, contentRect: const Rect.fromLTWH(0, 1000, 1080, 1320)), failsWith('invalid'));
      expect(calls, isEmpty);
    });

    test('compositions run one at a time', () async {
      final first = Completer<Object?>();
      final order = <String>[];
      runner(compose: (call) async {
        final output = (call.arguments as Map)['outputPath'];
        order.add('start $output');
        if (output == '/media/a.mp4') await first.future;
        order.add('end $output');
        return null;
      });
      final compositor = VideoCompositor();
      final a = compose(compositor, output: '/media/a.mp4');
      final b = compose(compositor, output: '/media/b.mp4');
      await pumpEventQueue();
      expect(order, ['start /media/a.mp4']);
      first.complete();
      await Future.wait([a, b]);
      expect(order, ['start /media/a.mp4', 'end /media/a.mp4', 'start /media/b.mp4', 'end /media/b.mp4']);
    });

    test('one failed composition does not stop the next', () async {
      runner(compose: (call) async {
        if ((call.arguments as Map)['outputPath'] == '/media/a.mp4') throw PlatformException(code: 'compose', message: 'The encoder stopped.');
        return null;
      });
      final compositor = VideoCompositor();
      final a = compose(compositor, output: '/media/a.mp4');
      final b = compose(compositor, output: '/media/b.mp4');
      await expectLater(a, failsWith('compose'));
      await b;
    });

    test('a progress listener that throws does not stop the composition', () async {
      runner(compose: (call) async {
        await progress((call.arguments as Map)['id'] as int, 0.5);
        return null;
      });
      var heard = 0;
      await compose(VideoCompositor(), onProgress: (_) {
        heard++;
        throw StateError('listener');
      });
      expect(heard, 3);
    });
  });

  group('request check', () {
    String? problem({String input = '/a.mov', String output = '/b.mp4', int width = 1080, int height = 1350, Rect? content, Uint8List? png}) =>
        VideoCompositor.validationProblem(
          inputPath: input,
          outputPath: output,
          overlayPng: png ?? _png,
          frameWidth: width,
          frameHeight: height,
          contentRect: content ?? const Rect.fromLTWH(0, 300, 1080, 1050),
        );

    test('accepts a frame with the video inside it, half a pixel of rounding included', () {
      expect(problem(), isNull);
      expect(problem(output: '/B.MP4'), isNull);
      expect(problem(content: const Rect.fromLTRB(-0.4, 299.6, 1080.4, 1350.3)), isNull);
      expect(problem(width: 16, height: 4096, content: const Rect.fromLTWH(0, 0, 16, 4096)), isNull);
    });

    test('refuses missing paths, other formats and overwriting the original', () {
      expect(problem(input: ''), isNotNull);
      expect(problem(output: ''), isNotNull);
      expect(problem(output: '/b.mov'), isNotNull);
      expect(problem(input: '/a.mp4', output: '/a.mp4'), isNotNull);
    });

    test('refuses odd, tiny and huge frames', () {
      expect(problem(width: 1079), isNotNull);
      expect(problem(height: 14, content: const Rect.fromLTWH(0, 0, 1080, 14)), isNotNull);
      expect(problem(width: 4098), isNotNull);
    });

    test('refuses a caption that is not a PNG', () {
      expect(problem(png: Uint8List(0)), isNotNull);
      expect(problem(png: Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47])), isNotNull);
    });

    test('refuses a video place that is empty, not finite or outside the frame', () {
      expect(problem(content: const Rect.fromLTWH(0, 300, 1080, 0)), isNotNull);
      expect(problem(content: const Rect.fromLTWH(0, double.nan, 1080, 100)), isNotNull);
      expect(problem(content: const Rect.fromLTWH(-2, 300, 1080, 1050)), isNotNull);
      expect(problem(content: const Rect.fromLTWH(0, 301, 1080, 1050)), isNotNull);
    });
  });

  group('video placement', () {
    test('a landscape video in a portrait frame sits centred between bars', () {
      const video = VideoProbe(width: 1920, height: 1080);
      final r = VideoCompositor.fittedVideoRect(video, const Rect.fromLTWH(0, 0, 1080, 1920), frameWidth: 1080, frameHeight: 1920);
      expect(r, const Rect.fromLTRB(0, 656, 1080, 1264));
    });

    test('a portrait phone video fills a block-free 9:16 frame exactly', () {
      final video = VideoProbe.fromChannel(_portrait)!;
      final r = VideoCompositor.fittedVideoRect(video, const Rect.fromLTWH(0, 0, 1080, 1920), frameWidth: 1080, frameHeight: 1920);
      expect(r, const Rect.fromLTWH(0, 0, 1080, 1920));
    });

    test('a content area reaching past the frame is cut to it, and never comes out empty', () {
      const video = VideoProbe(width: 1000, height: 1000);
      expect(VideoCompositor.fittedVideoRect(video, const Rect.fromLTRB(-100, 0, 1180, 1000), frameWidth: 1080, frameHeight: 1350),
          const Rect.fromLTRB(40, 0, 1040, 1000));
      final outside = VideoCompositor.fittedVideoRect(video, const Rect.fromLTWH(2000, 2000, 10, 10), frameWidth: 1080, frameHeight: 1350);
      expect(outside.width, greaterThan(0));
      expect(outside.height, greaterThan(0));
      expect(const Rect.fromLTWH(0, 0, 1080, 1350).intersect(outside), outside);
    });
  });
}
