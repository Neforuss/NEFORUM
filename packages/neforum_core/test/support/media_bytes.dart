// Small media files built byte by byte for tests: MP4 and WebM with or
// without a sound track.
import 'dart:typed_data';

/// An MP4 box: size, type, payload.
List<int> box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return [(size >> 24) & 0xFF, (size >> 16) & 0xFF, (size >> 8) & 0xFF, size & 0xFF, ...type.codeUnits, ...payload];
}

/// A track whose handler is [handler] ('vide', 'soun').
List<int> trak(String handler) => box('trak', [
      ...box('tkhd', List.filled(12, 0)),
      ...box('mdia', [
        ...box('mdhd', List.filled(12, 0)),
        // version and flags, pre_defined, handler type, reserved, name.
        ...box('hdlr', [0, 0, 0, 0, 0, 0, 0, 0, ...handler.codeUnits, ...List.filled(12, 0), 0]),
      ]),
    ]);

/// A small MP4 with [tracks]; [moovLast]: the moov box after the media data,
/// as encoders write it unless they optimise for streaming.
Uint8List mp4(List<String> tracks, {bool moovLast = false}) {
  final ftyp = box('ftyp', [...'isom'.codeUnits, 0, 0, 2, 0, ...'isomiso2mp41'.codeUnits]);
  final moov = box('moov', [...box('mvhd', List.filled(20, 0)), for (final t in tracks) ...trak(t)]);
  final mdat = box('mdat', List.filled(64, 7));
  return Uint8List.fromList(moovLast ? [...ftyp, ...mdat, ...moov] : [...ftyp, ...moov, ...mdat]);
}

/// A small WebM: the EBML header, then a Segment with Tracks holding one track
/// per entry of [codecs] (TrackType 1 video, 2 audio, then its codec ID).
Uint8List webm(List<(int, String)> codecs) {
  List<int> element(List<int> id, List<int> payload) => [...id, 0x80 | payload.length, ...payload];
  final entries = [
    for (final (type, codec) in codecs)
      ...element([0xAE], [
        ...element([0xD7], [1]),
        ...element([0x83], [type]),
        ...element([0x86], codec.codeUnits),
      ]),
  ];
  return Uint8List.fromList([
    ...element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], 'webm'.codeUnits)),
    0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // Segment, unknown size
    ...element([0x16, 0x54, 0xAE, 0x6B], entries),
  ]);
}
