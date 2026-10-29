// Track details on a real build: a tagged WAV is imported (tags and cover
// read in another isolate), saved with the user's details over them, and
// the system encoder makes the Standard copy that NEFORUM then tags (MP3 on
// Windows; an M4A is made and tagged too). The copies are read back with
// NEFORUM's reader and left in the system temp folder
// (neforum-audio-tags-probe) for a check with Windows' property system.
// Nothing is posted anywhere.
//
//   flutter drive --profile -d windows --driver=test_driver/integration_test.dart --target=integration_test/audio_tags_test.dart

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/platform/video_compositor.dart';
import 'package:neforum_app/state/audio_renditions.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tags read on import, written into the Standard copy, the cover in the video', (tester) async {
    final compositor = VideoCompositor();
    if (!await compositor.isSupported()) {
      if (Platform.environment['GITHUB_ACTIONS'] == 'true') {
        debugPrint('SKIPPED: this runner has no Media Foundation encoders.');
        return;
      }
      fail('Media Foundation encoders are missing.');
    }
    final work = await Directory.systemTemp.createTemp('neforum-audio-tags-');
    final probe = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}neforum-audio-tags-probe');
    if (probe.existsSync()) probe.deleteSync(recursive: true);
    probe.createSync(recursive: true);

    final services = await AppServices.create(demo: true, storage: await openAppStorage(overrideDir: work.path));
    final accounts = [
      for (final (id, platform) in const [('tg', 'telegram'), ('x', 'x')])
        ConnectedAccount(id: id, platformId: platform, tier: PlatformTier.handoff, displayName: id, createdAt: DateTime(2026, 10, 29)),
    ];
    for (final a in accounts) {
      await services.accounts.upsert(a);
    }
    final cover = img.encodeJpg(img.Image(width: 300, height: 300)..clear(img.ColorRgb8(20, 180, 60)), quality: 92);
    final track = await services.media.importBytes(_taggedWav(cover), fileName: 'Master.wav');
    final own = track.audioTags!;
    expect((own.title, own.artist, own.album, own.genre, own.trackNumber), ('Señorita Ø', 'Zoë & the Ünits', 'Ålbum — Deluxe', 'Pop', 3));
    expect(File(own.coverPath!).readAsBytesSync(), cover);

    final now = DateTime(2026, 10, 29);
    var post = Post(
      id: 'probe',
      text: 'Out now',
      media: [track],
      audioDetails: const AudioTags(title: 'Señorita Ø (Edit)', composer: 'J. Doe'),
      targets: [for (final a in accounts) PostTarget(accountId: a.id)],
      createdAt: now,
      updatedAt: now,
    );
    post = await attachAudioRenditions(services, post, services.settings);
    final copy = post.media.singleWhere((m) => isAudioRendition(m) && m.isAudio);
    final video = post.media.singleWhere((m) => isAudioRendition(m) && m.isVideo);
    final read = readAudioTags(File(copy.path).readAsBytesSync());
    debugPrint('PROBE copy ${copy.mimeType} ${copy.sizeBytes} bytes, tags ${read.tags.toJson()}');
    expect(read.tags.title, 'Señorita Ø (Edit)');
    expect(read.tags.artist, 'Zoë & the Ünits');
    expect(read.tags.composer, 'J. Doe');
    expect(read.cover, cover);
    expect(await _decodedMs(compositor, copy.path, work), closeTo(2000, 250), reason: 'the tagged copy still decodes');
    File(copy.path).copySync('${probe.path}${Platform.pathSeparator}standard-copy.${copy.mimeType == AudioMimeTypes.mp3 ? 'mp3' : 'm4a'}');
    File(video.path).copySync('${probe.path}${Platform.pathSeparator}audio-video.mp4');

    // An M4A from the same encoder, tagged by NEFORUM.
    if ((await compositor.audioOutputFormats()).contains('m4a')) {
      final m4a = '${work.path}${Platform.pathSeparator}copy.m4a';
      await compositor.transcodeAudio(inputPath: track.path, outputPath: m4a, format: 'm4a', bitsPerSecond: 256000);
      final effective = post.effectiveAudioTagsOf(track)!;
      final tagged = embedAudioTagsJob((File(m4a).readAsBytesSync(), AudioMimeTypes.m4a, effective.toJson(), cover, 'image/jpeg'));
      expect(tagged, isNotNull, reason: 'the encoder\'s M4A can be tagged');
      final out = '${probe.path}${Platform.pathSeparator}standard-copy.m4a';
      File(out).writeAsBytesSync(tagged!);
      final back = readAudioTags(tagged);
      expect(back.tags.title, 'Señorita Ø (Edit)');
      expect(back.cover, cover);
      expect(await _decodedMs(compositor, out, work), closeTo(2000, 250), reason: 'the tagged M4A still decodes');
    }
    debugPrint('PROBE_DIR=${probe.path}');
    try {
      await work.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file open.
    }
  });
}

/// How long [audio] lasts once decoded: the system makes a still-picture
/// video of it, and the video's length is read back.
Future<int> _decodedMs(VideoCompositor compositor, String audio, Directory work) async {
  final video = '${work.path}${Platform.pathSeparator}decoded-${audio.hashCode}.mp4';
  final picture = img.encodePng(img.Image(width: 64, height: 64));
  await compositor.renderAudioVideo(audioPath: audio, outputPath: video, imagePng: picture, frameWidth: 64, frameHeight: 64);
  return (await compositor.probe(video))!.durationMs;
}

/// Two seconds of a 440 Hz tone, 16-bit stereo 44.1 kHz, with an ID3v2.3
/// tag (UTF-16) and [cover] in an `id3 ` chunk.
Uint8List _taggedWav(Uint8List cover) {
  const rate = 44100, frames = rate * 2;
  final pcm = ByteData(frames * 4);
  for (var i = 0; i < frames; i++) {
    final v = (math.sin(2 * math.pi * 440 * i / rate) * 8000).round();
    pcm.setInt16(i * 4, v, Endian.little);
    pcm.setInt16(i * 4 + 2, v, Endian.little);
  }
  List<int> le32(int n) => [n & 0xFF, n >> 8 & 0xFF, n >> 16 & 0xFF, n >> 24 & 0xFF];
  List<int> be32(int n) => [n >> 24 & 0xFF, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF];
  List<int> utf16(String s) => [1, 0xFF, 0xFE, for (final u in s.codeUnits) ...[u & 0xFF, u >> 8]];
  List<int> frame(String id, List<int> content) => [...id.codeUnits, ...be32(content.length), 0, 0, ...content];
  final body = [
    ...frame('TIT2', utf16('Señorita Ø')),
    ...frame('TPE1', utf16('Zoë & the Ünits')),
    ...frame('TALB', utf16('Ålbum — Deluxe')),
    ...frame('TYER', utf16('2024')),
    ...frame('TCON', utf16('(13)')),
    ...frame('TRCK', utf16('3/12')),
    ...frame('APIC', [0, ...'image/jpeg'.codeUnits, 0, 3, 0, ...cover]),
  ];
  final id3 = [...'ID3'.codeUnits, 3, 0, 0, (body.length >> 21) & 0x7F, (body.length >> 14) & 0x7F, (body.length >> 7) & 0x7F, body.length & 0x7F, ...body];
  final fmt = [...'fmt '.codeUnits, ...le32(16), 1, 0, 2, 0, ...le32(rate), ...le32(rate * 4), 4, 0, 16, 0];
  final data = [...'data'.codeUnits, ...le32(frames * 4), ...pcm.buffer.asUint8List()];
  final chunk = [...'id3 '.codeUnits, ...le32(id3.length), ...id3, if (id3.length.isOdd) 0];
  final riff = [...'WAVE'.codeUnits, ...fmt, ...data, ...chunk];
  return Uint8List.fromList([...'RIFF'.codeUnits, ...le32(riff.length), ...riff]);
}
