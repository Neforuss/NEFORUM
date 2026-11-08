import 'dart:typed_data';

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import 'support/media_bytes.dart';

void main() {
  group('videoHasSound', () {
    test('MP4: a sound track is found, wherever the moov box is', () {
      expect(videoHasSound(mp4(['vide', 'soun'])), isTrue);
      expect(videoHasSound(mp4(['vide', 'soun'], moovLast: true)), isTrue);
    });

    test('MP4 with its sound dropped (pict-rs without allow_audio): no sound', () {
      expect(videoHasSound(mp4(['vide'])), isFalse);
      expect(videoHasSound(mp4(['vide'], moovLast: true)), isFalse);
    });

    test('WebM: an audio track (by type or codec) is found; video only is not', () {
      expect(videoHasSound(webm([(1, 'V_VP9'), (2, 'A_OPUS')])), isTrue);
      expect(videoHasSound(webm([(1, 'V_VP9')])), isFalse);
    });

    test('cannot tell: not a video, or cut before its moov box', () {
      expect(videoHasSound(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])), isNull);
      final whole = mp4(['vide', 'soun'], moovLast: true);
      expect(videoHasSound(Uint8List.sublistView(whole, 0, whole.length - 40)), isNull);
      expect(videoHasSound(Uint8List(0)), isNull);
    });
  });
}
