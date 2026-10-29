import 'dart:convert';
import 'dart:typed_data';

import '../model/audio.dart' show AudioMimeTypes;
import '../model/audio_tags.dart';

/// [bytes] (a sound file of [mimeType]) carrying [tags] and the [cover]
/// picture instead of any tags it had: an ID3v2.4 tag in front of an MP3, an
/// iTunes-style `moov/udta/meta` in an M4A. The audio itself is unchanged.
///
/// Null when NEFORUM does not write tags into this type, or when the file
/// cannot be changed safely (an M4A without a `moov` box, a fragmented MP4,
/// chunk offsets that would no longer fit in 32 bits).
Uint8List? embedAudioTags(Uint8List bytes, String mimeType, AudioTags tags, {Uint8List? cover, String? coverMimeType}) {
  try {
    return switch (mimeType) {
      AudioMimeTypes.mp3 => embedId3v24Tag(bytes, tags, cover: cover, coverMimeType: coverMimeType),
      AudioMimeTypes.m4a => embedMp4Metadata(bytes, tags, cover: cover, coverMimeType: coverMimeType),
      _ => null,
    };
  } on Object {
    return null;
  }
}

// ------------------------------------------------------------------- MP3

/// [mp3] with its leading ID3v2 tags replaced by [buildId3v24Tag].
Uint8List embedId3v24Tag(Uint8List mp3, AudioTags tags, {Uint8List? cover, String? coverMimeType}) {
  var start = 0;
  // Every ID3v2 tag in front (some files have more than one).
  while (start + 10 <= mp3.length && mp3[start] == 0x49 && mp3[start + 1] == 0x44 && mp3[start + 2] == 0x33) {
    final size = (mp3[start + 6] & 0x7F) << 21 | (mp3[start + 7] & 0x7F) << 14 | (mp3[start + 8] & 0x7F) << 7 | (mp3[start + 9] & 0x7F);
    final footer = mp3[start + 3] >= 4 && (mp3[start + 5] & 0x10) != 0 ? 10 : 0;
    final next = start + 10 + size + footer;
    if (next > mp3.length) break;
    start = next;
  }
  final tag = buildId3v24Tag(tags, cover: cover, coverMimeType: coverMimeType);
  return Uint8List.fromList([...tag, ...Uint8List.sublistView(mp3, start)]);
}

/// An ID3v2.4.0 tag (id3.org "ID3 tag version 2.4.0 - Main Structure" and
/// "- Native Frames"): text frames, COMM and USLT (English, no description)
/// and the cover as APIC picture type 3 (front cover). No unsynchronisation,
/// no extended header.
///
/// Text is ISO-8859-1 when it fits, else UTF-16 with a byte order mark: both
/// are ID3v2.4 encodings every reader knows, while Windows' own reader
/// mistakes UTF-8 COMM and USLT frames (it shows the description, or
/// nothing).
Uint8List buildId3v24Tag(AudioTags tags, {Uint8List? cover, String? coverMimeType}) {
  final frames = BytesBuilder(copy: false);
  void text(String id, String? value) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return;
    final (encoding, bytes, _) = _id3Encoded(v);
    frames.add(_id3Frame(id, [encoding, ...bytes]));
  }

  void described(String id, String? value) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return;
    // Encoding, language, empty description (its terminator only), text.
    final (encoding, bytes, terminator) = _id3Encoded(v);
    final emptyDescription = encoding == 1 ? [0xFF, 0xFE, ...terminator] : terminator;
    frames.add(_id3Frame(id, [encoding, ...latin1.encode('eng'), ...emptyDescription, ...bytes]));
  }

  final track = tags.trackNumber;
  final total = tags.trackTotal;
  text('TIT2', tags.title);
  text('TPE1', tags.artist);
  text('TALB', tags.album);
  text('TPE2', tags.albumArtist);
  text('TDRC', tags.date ?? tags.year?.toString());
  text('TCON', tags.genre);
  text('TRCK', track == null ? null : (total == null ? '$track' : '$track/$total'));
  text('TPOS', tags.discNumber?.toString());
  text('TCOM', tags.composer);
  described('COMM', tags.comment);
  described('USLT', tags.lyrics);
  if (cover != null && cover.isNotEmpty) {
    final mime = coverMimeType ?? 'image/jpeg';
    // Encoding, MIME type, NUL, picture type 3 (front cover), empty description.
    frames.add(_id3Frame('APIC', [0, ...latin1.encode(mime), 0, 3, 0, ...cover]));
  }
  final body = frames.takeBytes();
  return Uint8List.fromList([0x49, 0x44, 0x33, 4, 0, 0, ..._syncsafeBytes(body.length), ...body]);
}

/// [s] as ID3 text: (encoding byte, bytes, terminator). ISO-8859-1 (0) when
/// every character fits, else UTF-16 little-endian with its BOM (1).
(int, List<int>, List<int>) _id3Encoded(String s) {
  if (s.codeUnits.every((u) => u <= 0xFF)) return (0, latin1.encode(s), const [0]);
  return (1, [0xFF, 0xFE, for (final u in s.codeUnits) ...[u & 0xFF, u >> 8]], const [0, 0]);
}

List<int> _id3Frame(String id, List<int> content) => [...latin1.encode(id), ..._syncsafeBytes(content.length), 0, 0, ...content];

List<int> _syncsafeBytes(int n) => [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F];

// ------------------------------------------------------------------- MP4

/// [m4a] with an iTunes-style metadata box (`moov/udta/meta` with an `hdlr`
/// of type `mdir` and an `ilst`) in place of any it had. When the `moov` box
/// comes before the media data, every `stco`/`co64` chunk offset past it
/// moves by the change in its size.
///
/// Throws [FormatException] when the file has no `moov` box, is fragmented
/// (`moof`), or an offset would no longer fit.
Uint8List embedMp4Metadata(Uint8List m4a, AudioTags tags, {Uint8List? cover, String? coverMimeType}) {
  final top = _children(m4a, 0, m4a.length);
  if (top.any((b) => b.type == 'moof')) throw const FormatException('Fragmented MP4');
  final moov = top.where((b) => b.type == 'moov').firstOrNull;
  if (moov == null) throw const FormatException('No moov box');
  final meta = _mp4Meta(tags, cover: cover, coverMimeType: coverMimeType);

  final body = BytesBuilder(copy: false);
  var hasUdta = false;
  for (final child in _children(m4a, moov.bodyStart, moov.end)) {
    if (child.type == 'udta') {
      hasUdta = true;
      final udta = BytesBuilder(copy: false);
      for (final u in _children(m4a, child.bodyStart, child.end)) {
        if (u.type != 'meta') udta.add(Uint8List.sublistView(m4a, u.start, u.end));
      }
      udta.add(meta);
      body.add(_box('udta', udta.takeBytes()));
    } else {
      body.add(Uint8List.sublistView(m4a, child.start, child.end));
    }
  }
  if (!hasUdta) body.add(_box('udta', meta));
  final newMoov = _box('moov', body.takeBytes());
  final delta = newMoov.length - (moov.end - moov.start);
  // Chunk offsets are absolute: those pointing past the old moov move.
  if (delta != 0) _shiftChunkOffsets(newMoov, moov.start, delta);
  return Uint8List.fromList([
    ...Uint8List.sublistView(m4a, 0, moov.start),
    ...newMoov,
    ...Uint8List.sublistView(m4a, moov.end),
  ]);
}

Uint8List _mp4Meta(AudioTags tags, {Uint8List? cover, String? coverMimeType}) {
  final items = BytesBuilder(copy: false);
  void text(String type, String? value) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return;
    items.add(_item(type, 1, utf8.encode(v)));
  }

  final track = tags.trackNumber;
  text('©nam', tags.title);
  text('©ART', tags.artist);
  text('©alb', tags.album);
  text('aART', tags.albumArtist);
  text('©day', tags.date ?? tags.year?.toString());
  text('©gen', tags.genre);
  if (track != null) {
    final total = tags.trackTotal ?? 0;
    items.add(_item('trkn', 0, [0, 0, track >> 8 & 0xFF, track & 0xFF, total >> 8 & 0xFF, total & 0xFF, 0, 0]));
  }
  final disc = tags.discNumber;
  if (disc != null) items.add(_item('disk', 0, [0, 0, disc >> 8 & 0xFF, disc & 0xFF, 0, 0]));
  text('©wrt', tags.composer);
  text('©cmt', tags.comment);
  text('©lyr', tags.lyrics);
  if (cover != null && cover.isNotEmpty) {
    // Well-known types: 13 JPEG, 14 PNG, 27 BMP.
    final type = switch (coverMimeType) { 'image/png' => 14, 'image/bmp' => 27, _ => 13 };
    items.add(_item('covr', type, cover));
  }
  // hdlr: version and flags, pre_defined, handler type 'mdir', the 'appl'
  // reserved field iTunes writes, two zero words, and an empty name.
  final hdlr = _box('hdlr', [0, 0, 0, 0, 0, 0, 0, 0, ...latin1.encode('mdir'), ...latin1.encode('appl'), 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  final ilst = _box('ilst', items.takeBytes());
  return _box('meta', [0, 0, 0, 0, ...hdlr, ...ilst]);
}

/// An `ilst` item: a box named [type] around a `data` box (type indicator,
/// locale 0, value).
Uint8List _item(String type, int dataType, List<int> value) =>
    _box(type, _box('data', [0, dataType >> 16 & 0xFF, dataType >> 8 & 0xFF, dataType & 0xFF, 0, 0, 0, 0, ...value]));

Uint8List _box(String type, List<int> body) {
  final size = body.length + 8;
  return Uint8List.fromList([size >> 24 & 0xFF, size >> 16 & 0xFF, size >> 8 & 0xFF, size & 0xFF, ...latin1.encode(type), ...body]);
}

class _Mp4Box {
  const _Mp4Box(this.type, this.start, this.bodyStart, this.end);
  final String type;
  final int start;
  final int bodyStart;
  final int end;
}

List<_Mp4Box> _children(Uint8List b, int from, int to) {
  final out = <_Mp4Box>[];
  var at = from;
  while (at + 8 <= to) {
    var size = _u32(b, at);
    var header = 8;
    if (size == 1) {
      if (at + 16 > to) throw const FormatException('Cut-off box');
      size = _u32(b, at + 8) * 0x100000000 + _u32(b, at + 12);
      header = 16;
    } else if (size == 0) {
      size = to - at;
    }
    if (size < header || at + size > to) throw const FormatException('Bad box size');
    out.add(_Mp4Box(String.fromCharCodes(b.sublist(at + 4, at + 8)), at, at + header, at + size));
    at += size;
  }
  return out;
}

/// Adds [delta] to every chunk offset in [moov] (the whole box) at or past
/// [from], in `trak/mdia/minf/stbl/stco` and `co64`.
void _shiftChunkOffsets(Uint8List moov, int from, int delta) {
  final data = ByteData.sublistView(moov);
  void walk(int start, int end, int depth) {
    for (final box in _children(moov, start, end)) {
      switch (box.type) {
        case 'trak' || 'mdia' || 'minf' || 'stbl':
          if (depth < 6) walk(box.bodyStart, box.end, depth + 1);
        case 'stco':
          final count = data.getUint32(box.bodyStart + 4);
          for (var i = 0; i < count; i++) {
            final at = box.bodyStart + 8 + i * 4;
            if (at + 4 > box.end) break;
            final offset = data.getUint32(at);
            if (offset < from) continue;
            final moved = offset + delta;
            if (moved < 0 || moved > 0xFFFFFFFF) throw const FormatException('Chunk offset out of range');
            data.setUint32(at, moved);
          }
        case 'co64':
          final count = data.getUint32(box.bodyStart + 4);
          for (var i = 0; i < count; i++) {
            final at = box.bodyStart + 8 + i * 8;
            if (at + 8 > box.end) break;
            final offset = data.getUint32(at) * 0x100000000 + data.getUint32(at + 4);
            if (offset < from) continue;
            final moved = offset + delta;
            data.setUint32(at, moved ~/ 0x100000000);
            data.setUint32(at + 4, moved % 0x100000000);
          }
      }
    }
  }

  // The moov box's own children start after its 8-byte header.
  walk(8, moov.length, 0);
}

int _u32(Uint8List b, int at) => b[at] * 0x1000000 + (b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3]);
