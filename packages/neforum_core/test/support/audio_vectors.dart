import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Sound files built byte by byte from the format specifications, for the
/// tag reader and writer tests (and, written to disk, for checking them
/// against Windows' own property system).

// ------------------------------------------------------------------ bytes

List<int> u16be(int n) => [n >> 8 & 0xFF, n & 0xFF];
List<int> u32be(int n) => [n >> 24 & 0xFF, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF];
List<int> u16le(int n) => [n & 0xFF, n >> 8 & 0xFF];
List<int> u32le(int n) => [n & 0xFF, n >> 8 & 0xFF, n >> 16 & 0xFF, n >> 24 & 0xFF];
List<int> ascii(String s) => latin1.encode(s);
List<int> syncsafe(int n) => [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F];

List<int> utf16le(String s) => [for (final u in s.codeUnits) ...u16le(u)];
List<int> utf16be(String s) => [for (final u in s.codeUnits) ...u16be(u)];

/// A solid [width] x [height] picture of one colour, as JPEG or PNG.
Uint8List solidPicture({int width = 64, int height = 64, int r = 220, int g = 30, int b = 40, bool png = false}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return png ? img.encodePng(image) : img.encodeJpg(image, quality: 95);
}

/// A PNG of seeded random pixels: it does not compress, so it is about
/// 3 x [width] x [height] bytes.
Uint8List noisePicture({int width = 200, int height = 200, int seed = 1}) {
  final image = img.Image(width: width, height: height);
  var state = seed;
  int next() => state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
  for (final p in image) {
    p
      ..r = next() >> 16 & 0xFF
      ..g = next() >> 16 & 0xFF
      ..b = next() >> 16 & 0xFF;
  }
  return img.encodePng(image);
}

// -------------------------------------------------------------------- MP3

/// [count] silent MPEG-1 Layer III frames (128 kbit/s, 44.1 kHz, joint
/// stereo, no CRC): a header and 413 zero bytes, side information included,
/// so every frame decodes to silence.
List<int> mp3Frames([int count = 40]) => [
      for (var i = 0; i < count; i++) ...[0xFF, 0xFB, 0x90, 0x64, ...List<int>.filled(413, 0)],
    ];

/// An ID3v1.1 tag.
List<int> id3v1({String title = '', String artist = '', String album = '', String year = '', String comment = '', int track = 0, int genre = 255}) {
  List<int> field(String s, int n) {
    final b = latin1.encode(s);
    return [...b.take(n), ...List<int>.filled(n - (b.length < n ? b.length : n), 0)];
  }

  return [
    ...ascii('TAG'),
    ...field(title, 30),
    ...field(artist, 30),
    ...field(album, 30),
    ...field(year, 4),
    ...field(comment, 28),
    0,
    track,
    genre,
  ];
}

/// ID3 text encodings.
enum Id3Encoding { latin1, utf16Bom, utf16be, utf8 }

/// A text string in [e], without terminator, with its BOM for UTF-16.
List<int> id3String(String s, Id3Encoding e) => switch (e) {
      Id3Encoding.latin1 => latin1.encode(s),
      Id3Encoding.utf16Bom => [0xFF, 0xFE, ...utf16le(s)],
      Id3Encoding.utf16be => utf16be(s),
      Id3Encoding.utf8 => utf8.encode(s),
    };

List<int> id3Terminator(Id3Encoding e) => e == Id3Encoding.utf16Bom || e == Id3Encoding.utf16be ? [0, 0] : [0];

/// A text frame's content: encoding byte and the values, NUL-separated.
List<int> id3TextContent(Id3Encoding e, List<String> values) => [
      e.index,
      for (var i = 0; i < values.length; i++) ...[...id3String(values[i], e), if (i < values.length - 1) ...id3Terminator(e)],
    ];

/// COMM/USLT content.
List<int> id3DescribedContent(Id3Encoding e, String text, {String description = '', String language = 'eng'}) =>
    [e.index, ...ascii(language), ...id3String(description, e), ...id3Terminator(e), ...id3String(text, e)];

/// APIC content (2.3/2.4).
List<int> id3PictureContent(Uint8List picture, {String mime = 'image/jpeg', int type = 3, String description = '', Id3Encoding e = Id3Encoding.latin1}) =>
    [e.index, ...ascii(mime), 0, type, ...id3String(description, e), ...id3Terminator(e), ...picture];

/// PIC content (2.2): a three-letter image format instead of the MIME type.
List<int> id3v22PictureContent(Uint8List picture, {String format = 'JPG', int type = 3}) => [0, ...ascii(format), type, 0, ...picture];

/// One frame: its ID and content.
typedef Id3FrameSpec = (String, List<int>);

/// Unsynchronisation: a 0x00 after every 0xFF that is followed by 0x00 or by
/// a byte of 0xE0 or more (and after a final 0xFF).
List<int> unsynchronise(List<int> data) {
  final out = <int>[];
  for (var i = 0; i < data.length; i++) {
    out.add(data[i]);
    if (data[i] == 0xFF && (i + 1 == data.length || data[i + 1] == 0 || data[i + 1] >= 0xE0)) out.add(0);
  }
  return out;
}

/// An ID3v2.[major] tag. [unsync] unsynchronises the whole tag (2.2, 2.3) or
/// every frame (2.4); [extendedHeader] adds an empty extended header;
/// [padding] adds zero bytes after the frames.
List<int> id3v2(int major, List<Id3FrameSpec> frames, {bool unsync = false, bool extendedHeader = false, int padding = 0, bool plainSizesIn24 = false}) {
  final body = <int>[];
  if (extendedHeader && major == 3) {
    body.addAll([...u32be(6), 0, 0, ...u32be(0)]); // size 6, no flags, padding size 0
  } else if (extendedHeader && major == 4) {
    body.addAll([...syncsafe(6), 1, 0]); // size 6 (counts itself), one flag byte, none set
  }
  for (final (id, rawContent) in frames) {
    var content = rawContent;
    var formatFlags = 0;
    if (major == 4 && unsync) {
      content = unsynchronise(content);
      formatFlags |= 0x02;
    }
    if (major == 2) {
      body.addAll([...ascii(id), content.length >> 16 & 0xFF, content.length >> 8 & 0xFF, content.length & 0xFF, ...content]);
    } else if (major == 3) {
      body.addAll([...ascii(id), ...u32be(content.length), 0, formatFlags, ...content]);
    } else {
      body.addAll([...ascii(id), ...(plainSizesIn24 ? u32be(content.length) : syncsafe(content.length)), 0, formatFlags, ...content]);
    }
  }
  body.addAll(List<int>.filled(padding, 0));
  final tagBody = unsync && major < 4 ? unsynchronise(body) : body;
  final flags = (unsync ? 0x80 : 0) | (extendedHeader ? 0x40 : 0);
  return [...ascii('ID3'), major, 0, flags, ...syncsafe(tagBody.length), ...tagBody];
}

// ------------------------------------------------------------------- FLAC

/// A FLAC metadata block.
List<int> flacBlock(int type, List<int> body, {bool last = false}) =>
    [(last ? 0x80 : 0) | type, body.length >> 16 & 0xFF, body.length >> 8 & 0xFF, body.length & 0xFF, ...body];

/// STREAMINFO: 4096-sample blocks, 44.1 kHz, stereo, 16 bits, [samples] long.
List<int> flacStreamInfo({int samples = 44100}) {
  // 20 bits rate, 3 bits channels-1, 5 bits bps-1, 36 bits total samples.
  const rate = 44100;
  final packed = <int>[
    rate >> 12 & 0xFF,
    rate >> 4 & 0xFF,
    (rate & 0x0F) << 4 | (1 << 1) | (15 >> 4),
    (15 & 0x0F) << 4 | (samples >> 32 & 0x0F),
    ...u32be(samples & 0xFFFFFFFF),
  ];
  return [...u16be(4096), ...u16be(4096), 0, 0, 0, 0, 0, 0, ...packed, ...List<int>.filled(16, 0)];
}

/// A Vorbis comment block body.
List<int> vorbisComment(List<String> entries, {String vendor = 'NEFORUM test'}) => [
      ...u32le(utf8.encode(vendor).length),
      ...utf8.encode(vendor),
      ...u32le(entries.length),
      for (final e in entries) ...[...u32le(utf8.encode(e).length), ...utf8.encode(e)],
    ];

/// A FLAC PICTURE block body.
List<int> flacPicture(Uint8List picture, {int type = 3, String mime = 'image/jpeg', String description = '', int width = 64, int height = 64}) => [
      ...u32be(type),
      ...u32be(mime.length),
      ...ascii(mime),
      ...u32be(utf8.encode(description).length),
      ...utf8.encode(description),
      ...u32be(width),
      ...u32be(height),
      ...u32be(24),
      ...u32be(0),
      ...u32be(picture.length),
      ...picture,
    ];

/// One FLAC frame of [samples] silent stereo samples: two CONSTANT
/// subframes of 0, with the header CRC-8 and frame CRC-16 the format
/// requires.
List<int> flacSilentFrame(int frameNumber, {int samples = 4096}) {
  // Sync 0x3FFE + reserved + fixed blocking; block size code 0111 (16-bit
  // value follows), sample rate code 1001 (44.1 kHz); channels 0001 (stereo,
  // independent), sample size 100 (16 bits), reserved 0.
  final header = <int>[0xFF, 0xF8, 0x79, 0x18, ..._utf8Number(frameNumber), ...u16be(samples - 1)];
  header.add(_crc8(header));
  // Subframe: padding 0, type CONSTANT (000000), no wasted bits, then one
  // 16-bit sample.
  final frame = [...header, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
  return [...frame, ...u16be(_crc16(frame))];
}

List<int> _utf8Number(int n) => n < 0x80 ? [n] : [0xC0 | n >> 6, 0x80 | (n & 0x3F)];

int _crc8(List<int> data) {
  var crc = 0;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
    }
  }
  return crc;
}

int _crc16(List<int> data) {
  var crc = 0;
  for (final byte in data) {
    crc ^= byte << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x8005) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

/// A FLAC file: STREAMINFO, the comments, a picture, and [frames] silent
/// frames of 4096 samples.
List<int> flacFile({required List<String> comments, Uint8List? picture, int frames = 11, List<int> before = const []}) {
  final blocks = <List<int>>[
    flacBlock(0, flacStreamInfo(samples: frames * 4096)),
    flacBlock(4, vorbisComment(comments), last: picture == null),
    if (picture != null) flacBlock(6, flacPicture(picture), last: true),
  ];
  return [
    ...before,
    ...ascii('fLaC'),
    for (final b in blocks) ...b,
    for (var i = 0; i < frames; i++) ...flacSilentFrame(i),
  ];
}

// -------------------------------------------------------------------- Ogg

int _oggCrc(List<int> data) {
  var crc = 0;
  for (final byte in data) {
    crc ^= byte << 24;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x80000000) != 0 ? ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF : (crc << 1) & 0xFFFFFFFF;
    }
  }
  return crc;
}

/// Ogg pages carrying [packets], each packet starting a new page (as the
/// Vorbis and Opus headers do), split across pages of at most 255 segments.
List<int> oggStream(List<List<int>> packets, {int serial = 0x4E45464F}) {
  final out = <int>[];
  var sequence = 0;
  for (var p = 0; p < packets.length; p++) {
    final packet = packets[p];
    // Lacing: 255s then the remainder (a 0 when it divides evenly).
    final laces = <int>[];
    var n = packet.length;
    for (; n >= 255; n -= 255) {
      laces.add(255);
    }
    laces.add(n);
    var offset = 0;
    var first = true;
    for (var start = 0; start < laces.length; start += 255) {
      final segs = laces.sublist(start, start + 255 > laces.length ? laces.length : start + 255);
      final size = segs.fold<int>(0, (a, b) => a + b);
      final continued = !first;
      final headerType = (continued ? 0x01 : 0) | (p == 0 && first ? 0x02 : 0);
      final page = <int>[
        ...ascii('OggS'), 0, headerType, ...u32le(0), ...u32le(0), // granule 0
        ...u32le(serial), ...u32le(sequence++), ...u32le(0), segs.length, ...segs,
        ...packet.sublist(offset, offset + size),
      ];
      final crc = _oggCrc(page);
      page.setRange(22, 26, u32le(crc));
      out.addAll(page);
      offset += size;
      first = false;
    }
  }
  return out;
}

/// An Ogg Opus file's headers (OpusHead, OpusTags).
List<int> oggOpus(List<String> comments) => oggStream([
      [...ascii('OpusHead'), 1, 2, ...u16le(312), ...u32le(48000), ...u16le(0), 0],
      [...ascii('OpusTags'), ...vorbisComment(comments)],
    ]);

/// An Ogg Vorbis file's headers (identification, comment with framing bit,
/// a stand-in setup header).
List<int> oggVorbis(List<String> comments) => oggStream([
      [1, ...ascii('vorbis'), ...u32le(0), 2, ...u32le(44100), ...u32le(0), ...u32le(128000), ...u32le(0), 0xB8, 1],
      [3, ...ascii('vorbis'), ...vorbisComment(comments), 1],
      [5, ...ascii('vorbis'), 0, 0, 0, 0],
    ]);

// -------------------------------------------------------------------- MP4

List<int> mp4Box(String type, List<int> body) => [...u32be(body.length + 8), ...ascii(type), ...body];
List<int> mp4FullBox(String type, List<int> body, {int version = 0, int flags = 0}) =>
    mp4Box(type, [version, flags >> 16 & 0xFF, flags >> 8 & 0xFF, flags & 0xFF, ...body]);

/// An `ilst` item with one `data` atom.
List<int> mp4Item(String type, int dataType, List<int> value) =>
    mp4Box(type, mp4Box('data', [0, 0, 0, dataType, 0, 0, 0, 0, ...value]));
List<int> mp4Text(String type, String value) => mp4Item(type, 1, utf8.encode(value));

/// `udta/meta` with an `mdir` handler and [items].
List<int> mp4Udta(List<List<int>> items) => mp4Box('udta', [
      ...mp4FullBox('meta', [
        ...mp4FullBox('hdlr', [...u32be(0), ...ascii('mdir'), ...ascii('appl'), ...u32be(0), ...u32be(0), 0]),
        ...mp4Box('ilst', [for (final i in items) ...i]),
      ]),
    ]);

/// The bytes of each AAC sample: tag readers and writers never decode them.
const List<int> _silentAacFrame = [0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C];

/// An M4A file: one AAC track of [frames] frames. [moovFirst] puts the
/// `moov` before `mdat` (fast start), so its chunk offset points past it.
/// [udta] goes inside `moov` when given.
List<int> m4aFile({int frames = 43, bool moovFirst = true, List<int>? udta}) {
  final sample = _silentAacFrame;
  final mdatBody = [for (var i = 0; i < frames; i++) ...sample];
  final ftyp = mp4Box('ftyp', [...ascii('M4A '), ...u32be(0x200), ...ascii('M4A '), ...ascii('mp42'), ...ascii('isom')]);
  List<int> moov(int chunkOffset) {
    final esds = mp4FullBox('esds', [
      0x03, 0x19, ...u16be(1), 0x00, // ES_Descriptor, ES_ID 1
      0x04, 0x11, 0x40, 0x15, 0x00, 0x00, 0x00, ...u32be(128000), ...u32be(128000), // DecoderConfig: AAC
      0x05, 0x02, 0x12, 0x10, // AudioSpecificConfig: AAC LC, 44.1 kHz, stereo
      0x06, 0x01, 0x02, // SLConfig
    ]);
    final mp4a = mp4Box('mp4a', [
      0, 0, 0, 0, 0, 0, ...u16be(1), // reserved, data reference index
      0, 0, 0, 0, 0, 0, 0, 0, ...u16be(2), ...u16be(16), 0, 0, 0, 0, ...u32be(44100 << 16),
      ...esds,
    ]);
    final stbl = mp4Box('stbl', [
      ...mp4FullBox('stsd', [...u32be(1), ...mp4a]),
      ...mp4FullBox('stts', [...u32be(1), ...u32be(frames), ...u32be(1024)]),
      ...mp4FullBox('stsc', [...u32be(1), ...u32be(1), ...u32be(frames), ...u32be(1)]),
      ...mp4FullBox('stsz', [...u32be(sample.length), ...u32be(frames)]),
      ...mp4FullBox('stco', [...u32be(1), ...u32be(chunkOffset)]),
    ]);
    final minf = mp4Box('minf', [
      ...mp4FullBox('smhd', [0, 0, 0, 0]),
      ...mp4Box('dinf', mp4FullBox('dref', [...u32be(1), ...mp4FullBox('url ', [], flags: 1)])),
      ...stbl,
    ]);
    final duration = frames * 1024;
    final mdia = mp4Box('mdia', [
      ...mp4FullBox('mdhd', [...u32be(0), ...u32be(0), ...u32be(44100), ...u32be(duration), 0x55, 0xC4, 0, 0]),
      ...mp4FullBox('hdlr', [...u32be(0), ...ascii('soun'), ...u32be(0), ...u32be(0), ...u32be(0), ...ascii('SoundHandler'), 0]),
      ...minf,
    ]);
    final matrix = [...u32be(0x10000), ...u32be(0), ...u32be(0), ...u32be(0), ...u32be(0x10000), ...u32be(0), ...u32be(0), ...u32be(0), ...u32be(0x40000000)];
    final ms = (duration * 1000 / 44100).round();
    final tkhd = mp4FullBox('tkhd', [
      ...u32be(0), ...u32be(0), ...u32be(1), ...u32be(0), ...u32be(ms), ...u32be(0), ...u32be(0),
      ...u16be(0), ...u16be(0), ...u16be(0x0100), ...u16be(0), ...matrix, ...u32be(0), ...u32be(0),
    ], flags: 7);
    final mvhd = mp4FullBox('mvhd', [
      ...u32be(0), ...u32be(0), ...u32be(1000), ...u32be(ms), ...u32be(0x10000), ...u16be(0x0100), ...List<int>.filled(10, 0),
      ...matrix, ...List<int>.filled(24, 0), ...u32be(2),
    ]);
    return mp4Box('moov', [...mvhd, ...mp4Box('trak', [...tkhd, ...mdia]), ...?udta]);
  }

  if (moovFirst) {
    final size = moov(0).length;
    final offset = ftyp.length + size + 8;
    return [...ftyp, ...moov(offset), ...mp4Box('mdat', mdatBody)];
  }
  final offset = ftyp.length + 8;
  return [...ftyp, ...mp4Box('mdat', mdatBody), ...moov(offset)];
}

// ------------------------------------------------------------- WAV, AIFF

List<int> riffChunk(String id, List<int> body) => [...ascii(id), ...u32le(body.length), ...body, if (body.length.isOdd) 0];

/// A LIST/INFO chunk; each value NUL-terminated.
List<int> riffInfo(Map<String, String> fields) => riffChunk('LIST', [
      ...ascii('INFO'),
      for (final e in fields.entries) ...riffChunk(e.key, [...utf8.encode(e.value), 0]),
    ]);

/// A WAV file: 16-bit stereo 44.1 kHz PCM, one second of silence, then the
/// [extra] chunks.
List<int> wavFile({List<List<int>> extra = const [], int dataBytes = 176400}) {
  final fmt = riffChunk('fmt ', [...u16le(1), ...u16le(2), ...u32le(44100), ...u32le(176400), ...u16le(4), ...u16le(16)]);
  final data = riffChunk('data', List<int>.filled(dataBytes, 0));
  final body = [...ascii('WAVE'), ...fmt, ...data, for (final c in extra) ...c];
  return [...ascii('RIFF'), ...u32le(body.length), ...body];
}

List<int> aiffChunk(String id, List<int> body) => [...ascii(id), ...u32be(body.length), ...body, if (body.length.isOdd) 0];

/// An AIFF file: 16-bit stereo 44.1 kHz, one second of silence, then the
/// [extra] chunks.
List<int> aiffFile({List<List<int>> extra = const []}) {
  const frames = 44100;
  // 44100 as an 80-bit extended float.
  final rate = [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0];
  final comm = aiffChunk('COMM', [...u16be(2), ...u32be(frames), ...u16be(16), ...rate]);
  final ssnd = aiffChunk('SSND', [...u32be(0), ...u32be(0), ...List<int>.filled(frames * 4, 0)]);
  final body = [...ascii('AIFF'), ...comm, ...ssnd, for (final c in extra) ...c];
  return [...ascii('FORM'), ...u32be(body.length), ...body];
}
