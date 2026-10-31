// Sound files: reading their type, codec and length from synthetic headers,
// importing every accepted type, the Standard / Lossless choice per network,
// and the renditions made on save (the Standard copy, a still-picture video
// for video-only networks). The native compositor is a channel stub that
// writes files.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/audio_plan.dart';
import 'package:neforum_app/media/audio_probe.dart';
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/platform/media_library.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/audio_renditions.dart';
import 'package:neforum_app/state/card_designs.dart';
import 'package:neforum_app/state/fitted_photos.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/compose/audio_quality_option.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

// ------------------------------------------------------------ test files

class _W {
  final b = BytesBuilder();
  void ascii(String s) => b.add(s.codeUnits);
  void u8(int v) => b.addByte(v & 0xFF);
  void u16le(int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32le(int v) => b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u16be(int v) => b.add([(v >> 8) & 0xFF, v & 0xFF]);
  void u32be(int v) => b.add([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
  void zeros(int n) => b.add(Uint8List(n));
  void bytes(List<int> v) => b.add(v);
  Uint8List done() => b.toBytes();
}

/// A WAV of [seconds] of 16-bit stereo 44.1 kHz silence ([format] 1 = PCM,
/// 0xFFFE = extensible).
Uint8List wav({double seconds = 2, int format = 1, int subFormat = 1}) {
  const rate = 44100, channels = 2, bits = 16;
  final data = (seconds * rate).round() * channels * bits ~/ 8;
  final fmtSize = format == 0xFFFE ? 40 : 16;
  final w = _W()
    ..ascii('RIFF')
    ..u32le(4 + 8 + fmtSize + 8 + data)
    ..ascii('WAVE')
    ..ascii('fmt ')
    ..u32le(fmtSize)
    ..u16le(format)
    ..u16le(channels)
    ..u32le(rate)
    ..u32le(rate * channels * bits ~/ 8)
    ..u16le(channels * bits ~/ 8)
    ..u16le(bits);
  if (format == 0xFFFE) {
    w
      ..u16le(22)
      ..u16le(bits)
      ..u32le(3)
      ..u16le(subFormat)
      ..zeros(14);
  }
  w
    ..ascii('data')
    ..u32le(data)
    ..zeros(data);
  return w.done();
}

/// An AIFF of 3 s at 44.1 kHz (frames only; the samples are left out).
Uint8List aiff() => (_W()
      ..ascii('FORM')
      ..u32be(4 + 8 + 18)
      ..ascii('AIFF')
      ..ascii('COMM')
      ..u32be(18)
      ..u16be(2)
      ..u32be(44100 * 3)
      ..u16be(16)
      ..bytes(const [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0])) // 44100 as an 80-bit float
    .done();

/// A FLAC with STREAMINFO for 5 s of 48 kHz stereo, after an ID3v2 tag.
Uint8List flac() {
  const rate = 48000, samples = 48000 * 5;
  return (_W()
        ..ascii('ID3')
        ..bytes(const [4, 0, 0, 0, 0, 0, 10])
        ..zeros(10)
        ..ascii('fLaC')
        ..u8(0x80) // last block, STREAMINFO
        ..bytes(const [0, 0, 34])
        ..zeros(10)
        ..u8(rate >> 12)
        ..u8((rate >> 4) & 0xFF)
        ..u8(((rate & 0x0F) << 4) | (1 << 1)) // 2 channels, bits-per-sample high bit 0
        ..u8(0xF0) // bits per sample (low nibble of 16-1=15) and total samples high bits 0
        ..u32be(samples)
        ..zeros(16))
      .done();
}

/// [frames] MPEG-1 layer III frames at 128 kbit/s, 44.1 kHz (417 bytes each).
Uint8List mp3Cbr(int frames, {bool id3 = false}) {
  final w = _W();
  if (id3) {
    w
      ..ascii('ID3')
      ..bytes(const [3, 0, 0, 0, 0, 0, 20])
      ..zeros(20);
  }
  for (var i = 0; i < frames; i++) {
    w
      ..bytes(const [0xFF, 0xFB, 0x90, 0x00])
      ..zeros(413);
  }
  return w.done();
}

/// An MP3 whose first frame is a Xing header for [frames] frames.
Uint8List mp3Xing(int frames) {
  final w = _W()
    ..bytes(const [0xFF, 0xFB, 0x90, 0x00])
    ..zeros(32) // side information, MPEG-1 stereo
    ..ascii('Xing')
    ..u32be(1) // frame count present
    ..u32be(frames)
    ..zeros(417 - 4 - 32 - 12);
  for (var i = 0; i < 3; i++) {
    w
      ..bytes(const [0xFF, 0xFB, 0x90, 0x00])
      ..zeros(413);
  }
  return w.done();
}

Uint8List _box(String type, List<Uint8List> children) {
  final body = BytesBuilder();
  for (final c in children) {
    body.add(c);
  }
  return (_W()
        ..u32be(8 + body.length)
        ..ascii(type)
        ..bytes(body.toBytes()))
      .done();
}

Uint8List _raw(List<int> v) => Uint8List.fromList(v);

/// An M4A of 3 s with one sound track in [codec] (`alac`, `mp4a`), or a
/// video track when [handler] is `vide`.
Uint8List m4a({String codec = 'alac', String handler = 'soun', String brand = 'M4A '}) {
  final mvhd = (_W()
        ..u8(0)
        ..zeros(3)
        ..u32be(0)
        ..u32be(0)
        ..u32be(44100)
        ..u32be(44100 * 3)
        ..zeros(80))
      .done();
  final hdlr = (_W()
        ..zeros(4)
        ..zeros(4)
        ..ascii(handler)
        ..zeros(12)
        ..u8(0))
      .done();
  final entry = (_W()
        ..u32be(36)
        ..ascii(codec)
        ..zeros(6)
        ..u16be(1)
        ..zeros(8)
        ..u16be(2) // channels
        ..u16be(16)
        ..zeros(4)
        ..u16be(44100)
        ..u16be(0))
      .done();
  final stsd = (_W()
        ..zeros(4)
        ..u32be(1)
        ..bytes(entry))
      .done();
  final moov = _box('moov', [
    _box('mvhd', [mvhd]),
    _box('trak', [
      _box('mdia', [
        _box('hdlr', [hdlr]),
        _box('minf', [
          _box('stbl', [_box('stsd', [stsd])]),
        ]),
      ]),
    ]),
  ]);
  final ftyp = (_W()
        ..u32be(16)
        ..ascii('ftyp')
        ..ascii(brand)
        ..u32be(0))
      .done();
  return (_W()
        ..bytes(ftyp)
        ..bytes(moov)
        ..bytes(_box('mdat', [_raw(List.filled(64, 1))])))
      .done();
}

Uint8List _oggPage(List<int> packet, int granule) {
  final w = _W()
    ..ascii('OggS')
    ..u8(0)
    ..u8(granule == 0 ? 2 : 4)
    ..u32le(granule)
    ..u32le(0)
    ..u32le(1)
    ..u32le(0)
    ..u32le(0)
    ..u8(1)
    ..u8(packet.length)
    ..bytes(packet);
  return w.done();
}

/// Ogg Opus of 2 s (48 kHz granules, 312 samples of pre-skip).
Uint8List oggOpus() {
  final head = (_W()
        ..ascii('OpusHead')
        ..u8(1)
        ..u8(2)
        ..u16le(312)
        ..u32le(48000)
        ..u16le(0)
        ..u8(0))
      .done();
  return (_W()
        ..bytes(_oggPage(head, 0))
        ..bytes(_oggPage(List.filled(40, 0), 48000 * 2 + 312)))
      .done();
}

/// Ogg Vorbis of 4 s at 44.1 kHz.
Uint8List oggVorbis() {
  final head = (_W()
        ..u8(1)
        ..ascii('vorbis')
        ..u32le(0)
        ..u8(2)
        ..u32le(44100)
        ..zeros(13))
      .done();
  return (_W()
        ..bytes(_oggPage(head, 0))
        ..bytes(_oggPage(List.filled(40, 0), 44100 * 4)))
      .done();
}

MediaAttachment _sound(String mime, {String? codec, String id = 's1', int? durationMs = 180000, String name = 'Track'}) =>
    MediaAttachment(id: id, path: '/tmp/$id', mimeType: mime, sizeBytes: 1000, durationMs: durationMs, audioCodec: codec, fileName: '$name.${audioExtensionFor(mime)}');

final _mp3 = _sound(AudioMimeTypes.mp3, codec: AudioCodecs.mp3);
final _flac = _sound(AudioMimeTypes.flac, codec: AudioCodecs.flac);
final _aac = _sound(AudioMimeTypes.m4a, codec: AudioCodecs.aac);
final _aiff = _sound(AudioMimeTypes.aiff, codec: AudioCodecs.pcm);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reading sound files', () {
    test('WAV: PCM and extensible float, length from the data chunk', () {
      final p = probeAudio(wav(seconds: 2))!;
      expect((p.mimeType, p.codec, p.durationMs, p.sampleRate, p.channels), (AudioMimeTypes.wav, AudioCodecs.pcm, 2000, 44100, 2));
      expect(probeAudio(wav(seconds: 1.5, format: 0xFFFE, subFormat: 3))!.codec, AudioCodecs.pcm);
      expect(probeAudio(wav(format: 0x55))!.codec, AudioCodecs.mp3, reason: 'MP3 inside a WAV is not lossless');
    });

    test('AIFF: frames over the 80-bit sample rate', () {
      final p = probeAudio(aiff())!;
      expect((p.mimeType, p.codec, p.durationMs, p.sampleRate), (AudioMimeTypes.aiff, AudioCodecs.pcm, 3000, 44100));
    });

    test('FLAC: STREAMINFO, after an ID3 tag', () {
      final p = probeAudio(flac())!;
      expect((p.mimeType, p.codec, p.durationMs, p.sampleRate, p.channels), (AudioMimeTypes.flac, AudioCodecs.flac, 5000, 48000, 2));
    });

    test('MP3: constant bitrate, with and without an ID3 tag', () {
      final p = probeAudio(mp3Cbr(100), fileName: 'a.mp3')!;
      expect((p.mimeType, p.codec, p.sampleRate), (AudioMimeTypes.mp3, AudioCodecs.mp3, 44100));
      expect(p.durationMs, closeTo(100 * 417 * 8 / 128, 2));
      expect(probeAudio(mp3Cbr(100, id3: true))!.durationMs, closeTo(100 * 417 * 8 / 128, 2));
    });

    test('MP3: a Xing header gives the frame count', () {
      expect(probeAudio(mp3Xing(1000), fileName: 'v.mp3')!.durationMs, (1000 * 1152 * 1000 / 44100).round());
    });

    test('M4A: length from mvhd, Apple Lossless told from AAC; a video is no sound file', () {
      final alac = probeAudio(m4a())!;
      expect((alac.mimeType, alac.codec, alac.durationMs, alac.channels, alac.sampleRate), (AudioMimeTypes.m4a, AudioCodecs.alac, 3000, 2, 44100));
      expect(probeAudio(m4a(codec: 'mp4a', brand: 'isom'))!.codec, AudioCodecs.aac);
      expect(probeAudio(m4a(handler: 'vide', brand: 'isom')), isNull);
    });

    test('Ogg: Opus (minus pre-skip) and Vorbis from the last granule', () {
      final opus = probeAudio(oggOpus())!;
      expect((opus.mimeType, opus.codec, opus.durationMs, opus.channels), (AudioMimeTypes.ogg, AudioCodecs.opus, 2000, 2));
      final vorbis = probeAudio(oggVorbis())!;
      expect((vorbis.codec, vorbis.durationMs, vorbis.sampleRate), (AudioCodecs.vorbis, 4000, 44100));
    });

    test('anything else is no sound file; cut-off headers give no length', () {
      expect(probeAudio(Uint8List.fromList('hello world'.codeUnits), fileName: 'notes.txt'), isNull);
      final cut = wav().sublist(0, 30);
      expect(probeAudio(cut)!.durationMs, isNull);
      expect(formatAudioDuration(184000), '3:04');
      expect(formatAudioDuration(3723000), '1:02:03');
    });
  });

  group('importing', () {
    late Directory dir;
    late MediaLibrary library;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('neforum-audio-import');
      library = MediaLibrary(await openAppStorage(overrideDir: dir.path));
    });
    tearDown(() => dir.delete(recursive: true));

    test('every accepted type, with its canonical type, codec and length', () async {
      final cases = <(String, Uint8List, String?, String, String?, int?)>[
        ('Voice note.mp3', mp3Cbr(50), null, AudioMimeTypes.mp3, AudioCodecs.mp3, (50 * 417 * 8 / 128).round()),
        ('Master.wav', wav(seconds: 2), 'audio/x-wav', AudioMimeTypes.wav, AudioCodecs.pcm, 2000),
        ('Master.flac', flac(), null, AudioMimeTypes.flac, AudioCodecs.flac, 5000),
        ('Master.aiff', aiff(), null, AudioMimeTypes.aiff, AudioCodecs.pcm, 3000),
        ('Lossless.m4a', m4a(), null, AudioMimeTypes.m4a, AudioCodecs.alac, 3000),
        ('Podcast.m4a', m4a(codec: 'mp4a', brand: 'isom'), 'audio/x-m4a', AudioMimeTypes.m4a, AudioCodecs.aac, 3000),
        ('Memo.opus', oggOpus(), null, AudioMimeTypes.ogg, AudioCodecs.opus, 2000),
        ('Song.ogg', oggVorbis(), null, AudioMimeTypes.ogg, AudioCodecs.vorbis, 4000),
      ];
      for (final (name, bytes, hint, mime, codec, ms) in cases) {
        final m = await library.importBytes(bytes, fileName: name, mimeHint: hint);
        expect((m.mimeType, m.audioCodec), (mime, codec), reason: name);
        expect(m.durationMs, closeTo(ms!, 2), reason: name);
        expect(m.isAudio, isTrue, reason: name);
        expect(m.sizeBytes, bytes.length);
        expect(File(m.path).existsSync(), isTrue);
      }
    });

    test('lossless files are recognised; a video and a text file are not sound', () async {
      expect((await library.importBytes(flac(), fileName: 'a.flac')).isLosslessAudio, isTrue);
      expect((await library.importBytes(m4a(), fileName: 'a.m4a')).isLosslessAudio, isTrue);
      expect((await library.importBytes(m4a(codec: 'mp4a'), fileName: 'b.m4a')).isLosslessAudio, isFalse);
      expect((await library.importBytes(mp3Cbr(5), fileName: 'c.mp3')).isLosslessAudio, isFalse);
      final video = await library.importBytes(m4a(handler: 'vide', brand: 'isom'), fileName: 'clip.mp4');
      expect(video.isVideo, isTrue);
      expect(() => library.importBytes(Uint8List.fromList('x'.codeUnits), fileName: 'notes.txt'), throwsA(isA<UnsupportedMediaException>()));
      expect(MediaLibrary.supportedExtensions, containsAll(['mp3', 'm4a', 'wav', 'flac', 'aiff', 'ogg', 'opus']));
    });
  });

  group('quality choice', () {
    final registry = builtinRegistry();
    MediaRules rules(String id) => registry.byId(id)!.descriptor.media;

    test('Standard is one MP3; M4A where the device has no MP3 encoder; nothing without a compositor', () {
      expect(standardAudioFormat(const ['m4a', 'mp3']), 'mp3');
      expect(standardAudioFormat(const ['m4a']), 'm4a');
      expect(standardAudioFormat(const []), isNull);
    });

    test('Lossless only for lossless files: never an MP3 or AAC "upgrade"', () {
      expect(effectiveAudioQuality(AudioQuality.lossless, _flac), AudioQuality.lossless);
      expect(effectiveAudioQuality(AudioQuality.lossless, _mp3), AudioQuality.standard);
      expect(effectiveAudioQuality(AudioQuality.lossless, _aac), AudioQuality.standard);
      expect(audioRouteFor(rules('telegram'), _mp3, AudioQuality.lossless, standardMimeType: AudioMimeTypes.mp3), AudioRoute.original);
    });

    test('Standard: an MP3 goes as it is; anything else becomes the copy', () {
      for (final id in ['telegram', 'discord', 'matrix', 'mastodon', 'wordpress', 'ghost']) {
        expect(audioRouteFor(rules(id), _mp3, AudioQuality.standard, standardMimeType: AudioMimeTypes.m4a), AudioRoute.original, reason: id);
        expect(audioRouteFor(rules(id), _flac, AudioQuality.standard, standardMimeType: AudioMimeTypes.mp3), AudioRoute.standardCopy, reason: id);
      }
    });

    test('Lossless: the original where the type is taken, else the copy', () {
      expect(audioRouteFor(rules('telegram'), _flac, AudioQuality.lossless, standardMimeType: AudioMimeTypes.mp3), AudioRoute.original);
      expect(audioRouteFor(rules('mastodon'), _flac, AudioQuality.lossless, standardMimeType: AudioMimeTypes.mp3), AudioRoute.original);
      expect(audioRouteFor(rules('mastodon'), _aiff, AudioQuality.lossless, standardMimeType: AudioMimeTypes.mp3), AudioRoute.standardCopy);
      expect(audioRouteFor(rules('ghost'), _flac, AudioQuality.lossless, standardMimeType: AudioMimeTypes.m4a), AudioRoute.standardCopy);
    });

    test('video-only networks get a video, link-only ones the file to link, the rest nothing', () {
      expect(audioRouteFor(rules('bluesky'), _flac, AudioQuality.lossless), AudioRoute.video);
      expect(audioRouteFor(rules('reddit'), _flac, AudioQuality.lossless, standardMimeType: AudioMimeTypes.mp3), AudioRoute.original);
      expect(audioRouteFor(rules('reddit'), _flac, AudioQuality.standard, standardMimeType: AudioMimeTypes.mp3), AudioRoute.standardCopy);
      expect(audioRouteFor(rules('snapchat'), _flac, AudioQuality.standard), AudioRoute.none);
    });

    test('Tumblr gets a still-picture video whenever one can be had, a link only when not', () {
      // A media host with temporary links failed the Tumblr link post; the
      // video plays in the post and needs no media host at all.
      expect(audioRouteFor(rules('tumblr'), _mp3, AudioQuality.standard, canMakeVideo: true), AudioRoute.video);
      expect(audioRouteFor(rules('tumblr'), _mp3, AudioQuality.standard), AudioRoute.original);
      // Reddit keeps the link: its video posts need a separate poster image.
      expect(audioRouteFor(rules('reddit'), _mp3, AudioQuality.standard, canMakeVideo: true), AudioRoute.original);
      final preview = previewAudio([_mp3], _mp3, registry.byId('tumblr')!.descriptor, AudioQuality.standard, canRenderVideo: true);
      expect(preview.media.single.mimeType, 'video/mp4');
      expect(preview.notes.single.message, contains('plays in the post'));
    });

    test('without a converter the original goes where it is taken', () {
      expect(audioRouteFor(rules('telegram'), _flac, AudioQuality.standard), AudioRoute.original);
      final preview = previewAudio([_flac], _flac, registry.byId('telegram')!.descriptor, AudioQuality.standard);
      expect(preview.notes.single.code, 'media.audio_no_convert');
    });

    test('previews: a stand-in for the copy and for the video, whose picture leaves the list', () {
      final photo = MediaAttachment(id: 'p1', path: '/tmp/p1.jpg', mimeType: 'image/jpeg', sizeBytes: 10, width: 800, height: 800);
      final tg = previewAudio([_flac], _flac, registry.byId('telegram')!.descriptor, AudioQuality.standard, standardFormat: 'm4a');
      final copy = tg.media.single;
      expect((copy.mimeType, copy.audioCodec, copy.durationMs), (AudioMimeTypes.m4a, AudioCodecs.aac, 180000));
      expect(copy.sizeBytes, 180000 * 256000 ~/ 8000);
      expect(tg.notes.single.message, 'Telegram gets the M4A NEFORUM makes when you save');

      final x = previewAudio([photo, _flac], _flac, registry.byId('x')!.descriptor, AudioQuality.standard, canRenderVideo: true);
      final video = x.media.single;
      expect((video.mimeType, video.width, video.height, video.durationMs), ('video/mp4', 1080, 1080, 180000));
      expect(x.notes.single.message, contains('your first photo'));
      final tiktok = previewAudio([_flac], _flac, registry.byId('tiktok')!.descriptor, AudioQuality.standard, canRenderVideo: true);
      expect((tiktok.media.single.width, tiktok.media.single.height), (1080, 1920));
      final cannot = previewAudio([_flac], _flac, registry.byId('x')!.descriptor, AudioQuality.standard);
      expect(cannot.media.single, same(_flac), reason: 'the check then says the device cannot make the video');

      final lossless = previewAudio([_flac], _flac, registry.byId('mastodon')!.descriptor, AudioQuality.lossless, standardFormat: 'mp3');
      expect(lossless.notes.single.message, 'Mastodon gets your original FLAC file and makes its own copy to play');
      final kept = previewAudio([_flac], _flac, registry.byId('telegram')!.descriptor, AudioQuality.lossless, standardFormat: 'mp3');
      expect(kept.notes.single.message, 'Telegram gets your original FLAC file, unchanged');
    });

    test('the explanation says what this device makes', () {
      expect(audioQualityExplanation(_flac, AudioQuality.standard, const ['m4a']), contains('Phones and Macs have no MP3 encoder'));
      expect(audioQualityExplanation(_flac, AudioQuality.standard, const ['m4a', 'mp3']), startsWith('NEFORUM makes one MP3'));
      expect(audioQualityExplanation(_mp3, AudioQuality.standard, const []), startsWith('Your MP3 goes as it is'));
      expect(audioQualityExplanation(_mp3, AudioQuality.standard, const []), contains('already compressed'));
      expect(audioQualityExplanation(_flac, AudioQuality.standard, const []), contains('cannot convert'));
      expect(audioQualityExplanation(_flac, AudioQuality.lossless, null), contains('byte for byte'));
    });
  });

  group('renditions on save', () {
    final calls = <(String, Map<String, Object?>)>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), (call) async {
        final args = call.arguments is Map ? Map<String, Object?>.from(call.arguments as Map) : const <String, Object?>{};
        switch (call.method) {
          case 'isSupported':
            return true;
          case 'audioFormats':
            return ['m4a'];
          case 'transcodeAudio':
          case 'audioVideo':
            calls.add((call.method, args));
            File(args['outputPath']! as String).writeAsBytesSync(Uint8List.fromList(List.filled(4096, 3)));
            return null;
        }
        return null;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), null));

    testWidgets('one Standard copy for every network, a video for X with the photo as its picture, reused and undone', (tester) async {
      final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('neforum-audio-renditions')))!;
      addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
      late AppServices s;
      late MediaAttachment track, photo;
      final accounts = [
        for (final (id, platform) in const [('tg', 'telegram'), ('dc', 'discord'), ('x', 'x')])
          ConnectedAccount(id: id, platformId: platform, tier: PlatformTier.handoff, displayName: id, createdAt: DateTime(2026, 10, 1)),
      ];
      await tester.runAsync(() async {
        s = await AppServices.create(demo: true, storage: await openAppStorage(overrideDir: dir.path));
        for (final a in accounts) {
          await s.accounts.upsert(a);
        }
        track = await s.media.importBytes(wav(seconds: 1), fileName: 'Master.wav');
        photo = await s.media.importBytes(_png, fileName: 'cover.png');
      });
      final now = DateTime(2026, 10, 28);
      var post = Post(
        id: 'p-audio',
        text: 'New single',
        media: [photo, track],
        targets: [for (final a in accounts) PostTarget(accountId: a.id)],
        createdAt: now,
        updatedAt: now,
      );
      await tester.runAsync(() async => post = await attachAudioRenditions(s, post, s.settings));

      expect(calls.map((c) => c.$1), ['transcodeAudio', 'audioVideo']);
      expect(calls.first.$2['format'], 'm4a');
      expect(calls.first.$2['bitrate'], kStandardAudioBitsPerSecond);
      final (frameW, frameH, png) = (calls.last.$2['frameWidth'], calls.last.$2['frameHeight'], calls.last.$2['imagePng']! as Uint8List);
      expect((frameW, frameH), (1080, 1080));
      expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      final copy = post.media.singleWhere((m) => isAudioRendition(m) && m.isAudio);
      final video = post.media.singleWhere((m) => isAudioRendition(m) && m.isVideo);
      expect((copy.mimeType, copy.derivedFrom, copy.audioCodec), (AudioMimeTypes.m4a, track.id, AudioCodecs.aac));
      expect(post.targetFor('tg')!.overrides.mediaIds, [photo.id, copy.id], reason: 'the resolver leaves the photo out for Telegram');
      expect(post.targetFor('dc')!.overrides.mediaIds, [photo.id, copy.id]);
      expect(post.targetFor('x')!.overrides.mediaIds, [video.id], reason: 'the photo is the video\'s picture');
      expect((video.width, video.height, video.derivedFrom), (1080, 1080, track.id));

      // Saving again reuses both; taking them back restores every list.
      await tester.runAsync(() async => post = await attachAudioRenditions(s, withoutAudioRenditions(post, keepFiles: true), s.settings));
      expect(calls, hasLength(2));
      expect(post.media.where(isAudioRendition).map((m) => m.id).toSet(), {copy.id, video.id});
      final undone = withoutAudioRenditions(post);
      expect(undone.media.map((m) => m.id), [photo.id, track.id]);
      expect(undone.targets.map((t) => t.overrides.mediaIds), everyElement(isNull));
      expect(undone.targets.any((t) => t.overrides.extra.containsKey(kAudioReplacedMediaIdsKey)), isFalse);

      // Lossless: Telegram and Discord get the WAV itself; the copy goes.
      await tester.runAsync(() async {
        post = await attachAudioRenditions(s, withoutAudioRenditions(post, keepFiles: true).copyWith(audioQuality: AudioQuality.lossless), s.settings);
      });
      expect(post.targetFor('tg')!.overrides.mediaIds, isNull, reason: 'every file as attached');
      expect(post.targetFor('dc')!.overrides.mediaIds, isNull);
      expect(post.media.where(isAudioRendition).map((m) => m.id), [video.id]);
      expect(File(copy.path).existsSync(), isFalse, reason: 'an unused copy is deleted');
    });

    Future<(AppServices, MediaAttachment, MediaAttachment)> workspace(WidgetTester tester, List<ConnectedAccount> accounts) async {
      final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('neforum-audio-saved')))!;
      addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
      return (await tester.runAsync(() async {
        final s = await AppServices.create(demo: true, storage: await openAppStorage(overrideDir: dir.path));
        for (final a in accounts) {
          await s.accounts.upsert(a);
        }
        final track = await s.media.importBytes(wav(seconds: 1), fileName: 'Master.wav');
        // Tall: Instagram gets a fitted copy.
        final photo = await s.media.importBytes(img.encodePng(img.Image(width: 40, height: 400)), fileName: 'cover.png');
        return (s, track, photo);
      }))!;
    }

    ConnectedAccount handoff(String id, String platform) =>
        ConnectedAccount(id: id, platformId: platform, tier: PlatformTier.handoff, displayName: id, createdAt: DateTime(2026, 10, 1));

    testWidgets('background runs keep the renditions, once; a network without a list of its own gets none back', (tester) async {
      final accounts = [handoff('tg', 'telegram'), handoff('x', 'x'), handoff('ig', 'instagram')];
      final (s, track, photo) = await workspace(tester, accounts);
      final now = DateTime(2026, 10, 28);
      var post = Post(id: 'p-saved', text: 'New single', media: [photo, track], targets: [for (final a in accounts) PostTarget(accountId: a.id)], createdAt: now, updatedAt: now);
      // As a save does: photos fitted, then the renditions.
      final saved = (await tester.runAsync(() async {
        final p = await attachAudioRenditions(s, await attachFittedPhotos(s, post, s.settings), s.settings);
        await s.posts.upsert(p);
        return p;
      }))!;
      final made = calls.length;
      expect(saved.targetFor('ig')!.overrides.extra[kAudioReplacedMediaIdsKey], isTrue, reason: 'it listed every file, fitted or not');
      expect(withoutAudioRenditions(saved).targetFor('ig')!.overrides.mediaIds, isNull, reason: 'files added later still reach it');

      for (var run = 1; run <= 2; run++) {
        await tester.runAsync(() async {
          await fitPhotosOfSavedPost(s, 'p-saved');
          post = (await s.posts.get('p-saved'))!;
        });
        expect(post.media.map((m) => m.id), unorderedEquals(saved.media.map((m) => m.id)), reason: 'run $run: no copy added twice');
        expect(post.targets.map((t) => t.overrides.mediaIds), saved.targets.map((t) => t.overrides.mediaIds), reason: 'run $run');
      }
      expect(calls, hasLength(made), reason: 'nothing rendered in the background');
      final forX = post.media.singleWhere((m) => m.id == post.targetFor('x')!.overrides.mediaIds!.single);
      expect(isAudioRendition(forX) && forX.isVideo, isTrue, reason: 'X still gets the video, not the sound file');
    });

    testWidgets('a saved post keeps its designed video when the Settings default design changes', (tester) async {
      final x = handoff('x', 'x');
      final (s, track, _) = await workspace(tester, [x]);
      final vinyl = cardTemplateById('vinyl')!.design(CardKind.audio);
      await tester.runAsync(() => s.saveSettings(s.settings.copyWith(audioCardDesign: vinyl.toJson())));
      final now = DateTime(2026, 10, 28);
      // Saved without a design of its own: the Settings default draws it.
      final post = Post(id: 'p-designed', text: 'New single', media: [track], targets: [PostTarget(accountId: x.id)], createdAt: now, updatedAt: now);
      final saved = (await tester.runAsync(() async {
        final p = await attachAudioRenditions(s, post, s.settings);
        await s.posts.upsert(p);
        return p;
      }))!;
      final video = saved.media.singleWhere((m) => isAudioRendition(m) && m.isVideo);
      expect(saved.targetFor(x.id)!.overrides.mediaIds, [video.id]);
      expect(CardDesign.tryParse(audioCardDesignOfPost(saved))?.template, 'vinyl', reason: 'read back from the video');

      // The default changes before the scheduled run, which has no compositor.
      final neon = cardTemplateById('neon')!.design(CardKind.audio);
      await tester.runAsync(() => s.saveSettings(s.settings.copyWith(audioCardDesign: neon.toJson())));
      final made = calls.length;
      final run = (await tester.runAsync(() async {
        await fitPhotosOfSavedPost(s, 'p-designed');
        return (await s.posts.get('p-designed'))!;
      }))!;
      expect(run.targetFor(x.id)!.overrides.mediaIds, [video.id], reason: 'X still gets the video');
      expect(File(video.path).existsSync(), isTrue, reason: 'the video is kept');
      expect(calls, hasLength(made));
    });

    testWidgets('1.3.3: a square photo goes into Instagram\'s 9:16 video whole, its sides kept, unless photos are cut to fit', (tester) async {
      final ig = handoff('ig', 'instagram');
      final (s, track, _) = await workspace(tester, [ig]);
      // Red down the left edge, blue down the right, green between: the
      // picture cut to 9:16 (before 1.3.3) kept only the green.
      final square = img.Image(width: 300, height: 300);
      img.fill(square, color: img.ColorRgb8(0, 255, 0));
      img.fillRect(square, x1: 0, y1: 0, x2: 29, y2: 299, color: img.ColorRgb8(255, 0, 0));
      img.fillRect(square, x1: 270, y1: 0, x2: 299, y2: 299, color: img.ColorRgb8(0, 0, 255));
      final photo = (await tester.runAsync(() => s.media.importBytes(img.encodePng(square), fileName: 'square.png')))!;
      final now = DateTime(2026, 10, 30);
      for (final (mode, sidesKept) in [(PhotoFitMode.color, true), (PhotoFitMode.pad, true), (PhotoFitMode.crop, false)]) {
        calls.clear();
        final post = Post(id: 'p-square-${mode.name}', text: 'New single', media: [photo, track], targets: [PostTarget(accountId: ig.id)], createdAt: now, updatedAt: now);
        await tester.runAsync(() => attachAudioRenditions(s, post, s.settings.copyWith(photoFit: mode)));
        final call = calls.singleWhere((c) => c.$1 == 'audioVideo').$2;
        expect((call['frameWidth'], call['frameHeight']), (1080, 1920));
        final frame = img.decodePng(call['imagePng']! as Uint8List)!;
        expect((frame.width, frame.height), (1080, 1920));
        final left = frame.getPixel(6, 960), right = frame.getPixel(1073, 960);
        expect(left.r > 200 && left.g < 60, sidesKept, reason: '${mode.name}: the left edge');
        expect(right.b > 200 && right.g < 60, sidesKept, reason: '${mode.name}: the right edge');
      }
    });

    testWidgets('networks with the same frame but their own safe area and fonts get designed videos of their own', (tester) async {
      final accounts = [handoff('tt', 'tiktok'), handoff('ig', 'instagram'), handoff('x', 'x'), handoff('bs', 'bluesky')];
      final (s, track, _) = await workspace(tester, accounts);
      final design = cardTemplateById('neon')!.design(CardKind.audio);
      await tester.runAsync(() => s.saveSettings(s.settings.copyWith(audioCardDesign: design.toJson())));
      final now = DateTime(2026, 10, 28);
      final post = Post(id: 'p-frames', text: 'New single', media: [track], targets: [for (final a in accounts) PostTarget(accountId: a.id)], createdAt: now, updatedAt: now);
      final saved = (await tester.runAsync(() => attachAudioRenditions(s, post, s.settings)))!;
      String videoOf(String accountId) => saved.targetFor(accountId)!.overrides.mediaIds!.single;
      expect(audioVideoFrame('tiktok'), audioVideoFrame('instagram'));
      expect(videoOf('tt'), isNot(videoOf('ig')), reason: 'TikTok\'s safe area and font are not Instagram\'s');
      expect(videoOf('x'), videoOf('bs'), reason: 'the same square card is made once');
      expect(calls.where((c) => c.$1 == 'audioVideo'), hasLength(3));
    });

    testWidgets('a designed card showing the cover art leaves the photo in the list; one showing the photo takes it', (tester) async {
      final x = handoff('x', 'x');
      final (s, plain, photo) = await workspace(tester, [x]);
      final design = cardTemplateById('vinyl')!.design(CardKind.audio);
      await tester.runAsync(() => s.saveSettings(s.settings.copyWith(audioCardDesign: design.toJson())));
      final coverPath = (await tester.runAsync(() => s.media.saveCover(_png, 'image/png')))!;
      final tagged = plain.copyWith(audioTags: AudioTags(title: 'Night Drive', coverPath: coverPath, coverMimeType: 'image/png'));
      final now = DateTime(2026, 10, 28);
      for (final (track, keepsPhoto) in [(tagged, true), (plain, false)]) {
        var post = Post(id: 'p-cover', text: 'New single', media: [photo, track], targets: [PostTarget(accountId: x.id)], createdAt: now, updatedAt: now);
        await tester.runAsync(() async => post = await attachAudioRenditions(s, post, s.settings));
        final video = post.media.singleWhere((m) => isAudioRendition(m) && m.isVideo);
        final expected = keepsPhoto ? [photo.id, video.id] : [video.id];
        expect(post.targetFor(x.id)!.overrides.mediaIds, expected, reason: keepsPhoto ? 'the cover art is the picture' : 'the photo is the picture');
        // The same when the video is reused.
        await tester.runAsync(() async => post = await attachAudioRenditions(s, withoutAudioRenditions(post, keepFiles: true), s.settings));
        expect(post.targetFor(x.id)!.overrides.mediaIds, expected, reason: 'reused');
      }
    });

    testWidgets('the story of Post + Story gets the video too, without the photo that became its picture', (tester) async {
      final ig = handoff('ig', 'instagram');
      final (s, track, photo) = await workspace(tester, [ig]);
      final now = DateTime(2026, 10, 28);
      final post = Post(
        id: 'p-story',
        text: 'New single',
        media: [photo, track],
        targets: [PostTarget(accountId: ig.id, overrides: const PostOverrides(extra: {kPlacementKey: 'feedAndStory'}))],
        createdAt: now,
        updatedAt: now,
      );
      final saved = (await tester.runAsync(() async => attachAudioRenditions(s, await attachFittedPhotos(s, post, s.settings), s.settings)))!;
      final video = saved.media.singleWhere((m) => isAudioRendition(m) && m.isVideo);
      final o = saved.targetFor(ig.id)!.overrides;
      expect(o.mediaIds, [video.id]);
      expect(o.storyMediaIds, [video.id], reason: 'not the raw sound file, nor the picture');
      expect(withoutAudioRenditions(saved).targetFor(ig.id)!.overrides.storyMediaIds, [photo.id, track.id]);
    });
  });
}

/// A 4 x 4 PNG.
final Uint8List _png = img.encodePng(img.Image(width: 4, height: 4));
