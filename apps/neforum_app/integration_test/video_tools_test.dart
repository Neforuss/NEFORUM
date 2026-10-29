// Runs the native video tools of the "neforum/video" channel on real files:
// a sound file becomes a video of a still picture (audioVideo), the existing
// compositor puts a caption over it (compose), frames are read back (frame),
// it is re-encoded smaller (transcode, and the size-limit loop on top of it),
// and sound files are converted (audioFormats, transcodeAudio). The sample
// media is made here: WAV and FLAC files written in Dart, PNG pictures from
// the image package. Nothing is posted anywhere.
//
//   flutter drive --profile -d windows --driver=test_driver/integration_test.dart --target=integration_test/video_tools_test.dart

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:neforum_app/platform/video_compositor.dart';
import 'package:neforum_app/state/shrunk_videos.dart';
import 'package:neforum_app/state/video_frames.dart';

/// Far longer than any of these files takes; a call that hangs fails the
/// test instead of stalling CI.
const Duration _limit = Duration(seconds: 120);

/// Durations read back may differ from the sound by encoder padding (an MP3
/// adds about 50 ms) and the last video frame.
const int _durationToleranceMs = 250;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('frame, transcode, audioVideo, audioFormats and transcodeAudio on Windows', (tester) async {
    final dir = await Directory.systemTemp.createTemp('neforum-video-tools-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file open; the OS cleans temp later.
      }
    });
    String path(String name) => '${dir.path}${Platform.pathSeparator}$name';
    final compositor = VideoCompositor();
    if (!await compositor.isSupported()) {
      // Windows Server images install Media Foundation only as an optional
      // feature; anywhere else, no compositor is a failure.
      if (Platform.environment['GITHUB_ACTIONS'] == 'true') {
        debugPrint('SKIPPED: this runner has no Media Foundation with H.264 and AAC encoders.');
        return;
      }
      fail('Media Foundation with H.264 and AAC encoders is missing.');
    }

    Future<VideoProbe> probed(String file) async {
      final probe = await compositor.probe(file).timeout(_limit);
      expect(probe, isNotNull, reason: '$file can be read back');
      return probe!;
    }

    // --- sample media --------------------------------------------------------
    final wav = path('tone.wav');
    File(wav).writeAsBytesSync(_wav(sampleRate: 44100, channels: 2, ms: 3000));
    final wavMono22k = path('tone 22k mono.wav');
    File(wavMono22k).writeAsBytesSync(_wav(sampleRate: 22050, channels: 1, ms: 2000));
    final flac = path('tone.flac');
    File(flac).writeAsBytesSync(_flac(ms: 2500));
    final picture = _picture(1280, 720);

    // --- audioFormats ------------------------------------------------------
    final formats = await compositor.audioOutputFormats().timeout(_limit);
    debugPrint('Audio formats: $formats');
    expect(formats, contains('m4a'));
    expect(formats, contains('mp3'), reason: 'Windows 8 and later have an MP3 encoder');

    // --- audioVideo: a still picture for the length of the sound ------------
    final still = path('still.mp4');
    final stillProgress = <double>[];
    var watch = Stopwatch()..start();
    await compositor
        .renderAudioVideo(audioPath: wav, outputPath: still, imagePng: picture, frameWidth: 1280, frameHeight: 720, onProgress: stillProgress.add)
        .timeout(_limit);
    debugPrint('audioVideo: ${watch.elapsedMilliseconds} ms, ${File(still).lengthSync()} bytes');
    final stillProbe = await probed(still);
    expect((stillProbe.width, stillProbe.height), (1280, 720));
    expect(stillProbe.hasAudio, isTrue);
    expect(stillProbe.durationMs, closeTo(3000, _durationToleranceMs));
    expect(stillProgress.last, 1);
    // Static frames encode tiny: far under 1 MB for 3 seconds of 720p.
    expect(File(still).lengthSync(), lessThan(1000000));

    // --- compose: the existing compositor, a caption block over the video --
    final composed = path('composed.mp4');
    await compositor
        .compose(
          inputPath: still,
          outputPath: composed,
          overlayPng: _overlay(1080, 1920),
          frameWidth: 1080,
          frameHeight: 1920,
          contentRect: const Rect.fromLTWH(0, 480, 1080, 1440),
          backgroundArgb: 0xFF203040,
        )
        .timeout(_limit);
    final composedProbe = await probed(composed);
    expect((composedProbe.width, composedProbe.height), (1080, 1920));
    expect(composedProbe.durationMs, closeTo(3000, _durationToleranceMs));
    expect(composedProbe.hasAudio, isTrue);

    // --- frame ---------------------------------------------------------------
    final frame = await compositor.frameAt(composed, 1500, maxSide: 480).timeout(_limit);
    expect(frame, isNotNull);
    expect((frame!.width, frame.height), (270, 480), reason: 'longest side at most 480, aspect kept');
    expect(frame.positionMs, closeTo(1500, 100));
    final decoded = img.decodePng(frame.png)!;
    expect((decoded.width, decoded.height), (270, 480));
    // The background colour below the video, the caption band above it.
    final edge = decoded.getPixel(135, 475);
    expect(edge.r.toInt(), closeTo(0x20, 12));
    expect(edge.g.toInt(), closeTo(0x30, 12));
    expect(edge.b.toInt(), closeTo(0x40, 12));
    final band = decoded.getPixel(135, 20);
    expect(band.r.toInt() + band.g.toInt() + band.b.toInt(), greaterThan(700), reason: 'the caption band is drawn on top');
    final stats = frameLuminance(frame.png)!;
    expect(isUninformativeFrame(stats.mean, stats.variance), isFalse);
    final first = await compositor.frameAt(still, 0, maxSide: 4096).timeout(_limit);
    expect((first!.width, first.height), (1280, 720), reason: 'never scaled up');
    final pastEnd = await compositor.frameAt(still, 999999, maxSide: 320).timeout(_limit);
    expect(pastEnd, isNotNull, reason: 'a position past the end takes the last frame');
    expect(pastEnd!.positionMs, lessThanOrEqualTo(3000));
    expect(await readPreviewFrame(compositor, composed), isNotNull);

    // --- transcode -------------------------------------------------------------
    final small = path('small.mp4');
    final transcodeProgress = <double>[];
    watch = Stopwatch()..start();
    await compositor
        .transcode(
          inputPath: composed,
          outputPath: small,
          videoBitsPerSecond: 400000,
          audioBitsPerSecond: 96000,
          maxSide: 640,
          onProgress: transcodeProgress.add,
        )
        .timeout(_limit);
    final smallBytes = File(small).lengthSync();
    debugPrint('transcode: ${watch.elapsedMilliseconds} ms, $smallBytes bytes');
    final smallProbe = await probed(small);
    expect((smallProbe.width, smallProbe.height), (360, 640));
    expect(smallProbe.durationMs, closeTo(3000, _durationToleranceMs));
    expect(smallProbe.hasAudio, isTrue);
    // 496 kbit/s for 3 s is 186 kB; the container and the first key frame
    // may add a little.
    expect(smallBytes, lessThan((496000 * 3 / 8 * 1.25).round() + 30000));
    expect(transcodeProgress.last, 1);

    // The size-limit loop on top of it: a copy within 60% of the original.
    final limit = (File(composed).lengthSync() * 0.6).round();
    final fitted = path('fitted.mp4');
    final result = await shrinkVideoToFit(compositor, inputPath: composed, outputPath: fitted, limitBytes: limit, probe: composedProbe).timeout(_limit);
    expect(result, isNotNull);
    expect(File(fitted).lengthSync(), lessThanOrEqualTo(limit));
    debugPrint('shrinkVideoToFit: ${result!.sizeBytes} bytes for a $limit byte limit with ${result.plan}');

    // A request the runner cannot do fails and leaves no file.
    final missing = path('missing.mp4');
    await expectLater(
      compositor.transcode(inputPath: path('nothing here.mov'), outputPath: missing, videoBitsPerSecond: 400000).timeout(_limit),
      throwsA(isA<VideoCompositionException>()),
    );
    expect(File(missing).existsSync(), isFalse);

    // --- transcodeAudio, then each result decoded again by audioVideo -------
    Future<void> convert(String input, String format, int bitsPerSecond, int ms) async {
      final out = path('${input.split(Platform.pathSeparator).last} $bitsPerSecond.$format');
      final progress = <double>[];
      await compositor.transcodeAudio(inputPath: input, outputPath: out, format: format, bitsPerSecond: bitsPerSecond, onProgress: progress.add).timeout(_limit);
      final bytes = File(out).lengthSync();
      final expected = bitsPerSecond * ms / 1000 / 8;
      debugPrint('transcodeAudio $format: $bytes bytes, ${expected.round()} expected');
      expect(bytes, inInclusiveRange((expected * 0.5).round(), (expected * 1.4).round() + 8000), reason: '$out near its bitrate');
      expect(progress.last, 1);
      final video = '$out.mp4';
      await compositor.renderAudioVideo(audioPath: out, outputPath: video, imagePng: _picture(320, 320), frameWidth: 320, frameHeight: 320).timeout(_limit);
      expect((await probed(video)).durationMs, closeTo(ms, _durationToleranceMs), reason: '$out decodes to its length');
    }

    await convert(wav, 'm4a', 128000, 3000);
    await convert(wav, 'mp3', 192000, 3000);
    // Resampled from 22.05 kHz mono.
    await convert(wavMono22k, 'mp3', 128000, 2000);
    await convert(wavMono22k, 'm4a', 96000, 2000);
    // FLAC in.
    await convert(flac, 'm4a', 192000, 2500);
    final flacVideo = path('flac.mp4');
    await compositor.renderAudioVideo(audioPath: flac, outputPath: flacVideo, imagePng: picture, frameWidth: 1280, frameHeight: 720).timeout(_limit);
    expect((await probed(flacVideo)).durationMs, closeTo(2500, _durationToleranceMs));

    final none = path('none.mp4');
    await expectLater(
      compositor.renderAudioVideo(audioPath: path('no sound.wav'), outputPath: none, imagePng: picture, frameWidth: 1280, frameHeight: 720).timeout(_limit),
      throwsA(isA<VideoCompositionException>()),
    );
    expect(File(none).existsSync(), isFalse);
  });
}

/// Two tones, a different one in each channel, with a slow swell: sound an
/// encoder cannot squeeze to nothing.
int _sample(int i, int channel, int sampleRate) {
  final t = i / sampleRate;
  final hz = channel == 0 ? 440.0 : 554.37;
  final swell = 0.35 + 0.25 * math.sin(2 * math.pi * 0.7 * t);
  return (32767 * swell * math.sin(2 * math.pi * hz * t)).round();
}

/// A 16-bit PCM WAV file.
Uint8List _wav({required int sampleRate, required int channels, required int ms}) {
  final frames = sampleRate * ms ~/ 1000;
  final data = ByteData(frames * channels * 2);
  for (var i = 0; i < frames; i++) {
    for (var c = 0; c < channels; c++) {
      data.setInt16((i * channels + c) * 2, _sample(i, c, sampleRate), Endian.little);
    }
  }
  final header = ByteData(44);
  void ascii(int at, String s) {
    for (var k = 0; k < s.length; k++) {
      header.setUint8(at + k, s.codeUnitAt(k));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + data.lengthInBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * channels * 2, Endian.little);
  header.setUint16(32, channels * 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, data.lengthInBytes, Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(data.buffer.asUint8List()))
      .takeBytes();
}

/// A FLAC file, 44.1 kHz 16-bit stereo, with verbatim (uncompressed)
/// subframes: valid FLAC that needs no encoder.
Uint8List _flac({required int ms}) {
  const rate = 44100;
  const block = 4096;
  final total = rate * ms ~/ 1000;
  final out = BytesBuilder()..add('fLaC'.codeUnits);
  // STREAMINFO, the last metadata block.
  final info = ByteData(38);
  info.setUint8(0, 0x80);
  info.setUint8(3, 34);
  info.setUint16(4, block);
  info.setUint16(6, block);
  // Frame sizes unknown (0); then 20 bits rate, 3 bits channels - 1, 5 bits
  // bits per sample - 1, 36 bits total samples.
  final packed = (BigInt.from(rate) << 44) | (BigInt.one << 41) | (BigInt.from(15) << 36) | BigInt.from(total);
  for (var k = 0; k < 8; k++) {
    info.setUint8(14 + k, ((packed >> (8 * (7 - k))) & BigInt.from(0xFF)).toInt());
  }
  out.add(info.buffer.asUint8List());

  for (var start = 0, number = 0; start < total; start += block, number++) {
    final n = math.min(block, total - start);
    final frame = BytesBuilder()
      // Sync, fixed block size; block size from the end of the header (16
      // bits), 44.1 kHz; left/right; 16 bits per sample.
      ..add([0xFF, 0xF8, 0x79, 0x18])
      ..addByte(number) // UTF-8 coded frame number, under 128 here
      ..add([(n - 1) >> 8, (n - 1) & 0xFF]);
    frame.addByte(_crc8(frame.toBytes()));
    for (var c = 0; c < 2; c++) {
      frame.addByte(0x02); // verbatim subframe, no wasted bits
      final samples = ByteData(n * 2);
      for (var i = 0; i < n; i++) {
        samples.setInt16(i * 2, _sample(start + i, c, rate));
      }
      frame.add(samples.buffer.asUint8List());
    }
    final bytes = frame.takeBytes();
    final crc = _crc16(bytes);
    out
      ..add(bytes)
      ..add([crc >> 8, crc & 0xFF]);
  }
  return out.takeBytes();
}

int _crc8(List<int> bytes) {
  var crc = 0;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
    }
  }
  return crc;
}

int _crc16(List<int> bytes) {
  var crc = 0;
  for (final b in bytes) {
    crc ^= b << 8;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x8005) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

/// A picture with detail everywhere (gradients and noise), as a PNG.
Uint8List _picture(int width, int height) {
  final rng = math.Random(13);
  final image = img.Image(width: width, height: height);
  for (final p in image) {
    final noise = rng.nextInt(60);
    p
      ..r = 40 + (p.x * 150 ~/ width) + noise ~/ 2
      ..g = 50 + (p.y * 140 ~/ height) + noise ~/ 3
      ..b = (120 + 70 * math.sin(p.x / 23 + p.y / 31)).round().clamp(0, 255);
  }
  return img.encodePng(image);
}

/// A transparent frame with an opaque caption band at the top, as a PNG.
Uint8List _overlay(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (final p in image) {
    if (p.y < height ~/ 4) {
      p
        ..r = 250
        ..g = 250
        ..b = 250
        ..a = 255;
    } else {
      p.a = 0;
    }
  }
  return img.encodePng(image);
}
