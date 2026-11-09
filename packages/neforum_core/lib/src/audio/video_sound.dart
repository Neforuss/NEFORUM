import 'dart:typed_data';

/// Whether the video in [bytes] has a sound track: true or false for an MP4
/// (or QuickTime) file with its `moov` box, or a WebM (Matroska) file with
/// its `Tracks`; null when the file is neither or is cut short, so it cannot
/// be told.
///
/// A network's media server may take a video and drop its sound (Lemmy's
/// pict-rs does unless its admin allows audio): NEFORUM reads the uploaded
/// file back and checks before a track goes out as a silent video.
bool? videoHasSound(Uint8List bytes) {
  if (bytes.length >= 8 && _ascii(bytes, 4, 4) == 'ftyp') return _mp4HasSound(bytes);
  if (bytes.length >= 4 && bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3) return _webmHasSound(bytes);
  return null;
}

String _ascii(Uint8List b, int at, int length) => at + length > b.length ? '' : String.fromCharCodes(b.sublist(at, at + length));

int _u32(Uint8List b, int at) => (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

/// The boxes directly inside [start]..[end] as (type, payload start, end).
Iterable<(String, int, int)> _boxes(Uint8List b, int start, int end) sync* {
  var at = start;
  while (at + 8 <= end) {
    var size = _u32(b, at);
    var header = 8;
    if (size == 1) {
      if (at + 16 > end) return;
      // A 64-bit size: the high half must be 0 for a file this size.
      if (_u32(b, at + 8) != 0) return;
      size = _u32(b, at + 12);
      header = 16;
    } else if (size == 0) {
      size = end - at;
    }
    if (size < header || at + size > end) return;
    yield (_ascii(b, at + 4, 4), at + header, at + size);
    at += size;
  }
}

bool? _mp4HasSound(Uint8List b) {
  for (final (type, start, end) in _boxes(b, 0, b.length)) {
    if (type != 'moov') continue;
    for (final (trak, ts, te) in _boxes(b, start, end)) {
      if (trak != 'trak') continue;
      for (final (mdia, ms, me) in _boxes(b, ts, te)) {
        if (mdia != 'mdia') continue;
        for (final (hdlr, hs, he) in _boxes(b, ms, me)) {
          // version and flags (4), pre_defined (4), then the handler type.
          if (hdlr == 'hdlr' && hs + 12 <= he && _ascii(b, hs + 8, 4) == 'soun') return true;
        }
      }
    }
    return false;
  }
  return null;
}

/// An EBML variable-length number at [at]: (value, length); null when broken.
(int, int)? _vint(Uint8List b, int at) {
  if (at >= b.length) return null;
  final first = b[at];
  var length = 1;
  var mask = 0x80;
  while (length <= 8 && first & mask == 0) {
    length++;
    mask >>= 1;
  }
  if (length > 8 || at + length > b.length) return null;
  var value = first & (mask - 1);
  for (var i = 1; i < length; i++) {
    value = (value << 8) | b[at + i];
  }
  return (value, length);
}

bool? _webmHasSound(Uint8List b) {
  // The Tracks element (ID 16 54 AE 6B); its tracks say their type (83: 2 is
  // audio) and codec (86: "A_OPUS", "A_VORBIS", "A_AAC"...).
  for (var at = 0; at + 4 < b.length; at++) {
    if (b[at] != 0x16 || b[at + 1] != 0x54 || b[at + 2] != 0xAE || b[at + 3] != 0x6B) continue;
    final size = _vint(b, at + 4);
    if (size == null) return null;
    final start = at + 4 + size.$2;
    final end = start + size.$1;
    if (end > b.length) return null;
    for (var i = start; i + 3 <= end; i++) {
      if (b[i] == 0x83 && b[i + 1] == 0x81 && b[i + 2] == 0x02) return true;
      if (b[i] == 0x86 && i + 4 <= end) {
        final codec = _vint(b, i + 1);
        if (codec != null && _ascii(b, i + 1 + codec.$2, 2) == 'A_') return true;
      }
    }
    return false;
  }
  return null;
}
