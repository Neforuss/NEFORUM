import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibDecoder;

import '../model/audio_tags.dart';

/// What [readAudioTags] found in a sound file: the tags, and the front cover
/// as the bytes the file carries (the caller saves them and sets
/// [AudioTags.coverPath]).
class AudioTagExtraction {
  const AudioTagExtraction({this.tags = AudioTags.none, this.cover, this.coverMimeType});

  /// Every field the file sets; [AudioTags.coverPath] is always null here.
  final AudioTags tags;

  /// The picture the file marks as its front cover, else its first picture.
  final Uint8List? cover;

  /// `image/jpeg`, `image/png`... read from the picture's own bytes when they
  /// say, else from the tag.
  final String? coverMimeType;

  bool get isEmpty => tags.isEmpty && cover == null;
}

/// Reads the tags a sound file carries, as Mp3tag and similar programs write
/// them: ID3v2.2, 2.3 and 2.4 (with ID3v1 as a fallback) in MP3 files and in
/// WAV (`id3 `) and AIFF (`ID3 `) chunks, WAV LIST/INFO and AIFF text chunks,
/// FLAC and Ogg (Vorbis, Opus, FLAC) Vorbis comments with their pictures, and
/// MP4/M4A `moov/udta/meta/ilst` atoms.
///
/// Pure Dart and synchronous, so it runs in any isolate. It never throws: a
/// cut-off or damaged file gives whatever was read before the damage.
AudioTagExtraction readAudioTags(Uint8List bytes) {
  final t = _Tags();
  try {
    _readContainer(_Bytes(bytes), t);
  } on Object {
    // Keep what was read before the damage.
  }
  return t.build();
}

void _readContainer(_Bytes b, _Tags t) {
  if (b.ascii(0, 4) == 'RIFF' && b.ascii(8, 4) == 'WAVE') return _wav(b, t);
  if (b.ascii(0, 4) == 'FORM' && (b.ascii(8, 4) == 'AIFF' || b.ascii(8, 4) == 'AIFC')) return _aiff(b, t);
  if (b.ascii(4, 4) == 'ftyp') return _mp4(b, t);
  if (b.ascii(0, 4) == 'OggS') return _ogg(b, t);
  // MP3 (or a FLAC file some tool put an ID3 tag in front of).
  final id3 = _Tags();
  var start = 0;
  if (b.ascii(0, 3) == 'ID3') {
    start = _id3TagLength(b, 0);
    _guard(() => _id3v2(b, 0, id3));
  }
  if (b.ascii(start, 4) == 'fLaC') {
    _guard(() => _flac(b, start + 4, t));
    t.fillFrom(id3);
    return;
  }
  t.fillFrom(id3);
  _guard(() => _id3v1(b, t));
}

/// Runs one reading step; damage in it leaves what it already read.
void _guard(void Function() step) {
  try {
    step();
  } on Object {
    // Keep what was read.
  }
}

// ------------------------------------------------------------------ ID3v2

/// Bytes of the ID3v2 tag at [at] (header, body and footer), else 0.
int _id3TagLength(_Bytes b, int at) {
  if (b.ascii(at, 3) != 'ID3' || at + 10 > b.length) return 0;
  final footer = b[at + 3] >= 4 && (b[at + 5] & 0x10) != 0 ? 10 : 0;
  return 10 + _syncsafe(b, at + 6) + footer;
}

int _syncsafe(_Bytes b, int at) => (b[at] & 0x7F) << 21 | (b[at + 1] & 0x7F) << 14 | (b[at + 2] & 0x7F) << 7 | (b[at + 3] & 0x7F);

/// Reads the ID3v2 tag at [at] (ID3v2.2, 2.3 or 2.4, informal structure
/// documents at id3.org) into [t].
void _id3v2(_Bytes b, int at, _Tags t) {
  if (b.ascii(at, 3) != 'ID3') return;
  final major = b[at + 3];
  if (major < 2 || major > 4) return;
  final flags = b[at + 5];
  final size = _syncsafe(b, at + 6);
  final bodyEnd = at + 10 + size > b.length ? b.length : at + 10 + size;
  if (bodyEnd <= at + 10) return;
  // ID3v2.2 compression has no defined scheme: such a tag cannot be read.
  if (major == 2 && (flags & 0x40) != 0) return;
  var body = b.slice(at + 10, bodyEnd);
  // Whole-tag unsynchronisation (2.2 and 2.3; in 2.4 it is per frame, and
  // this flag only says every frame has it).
  final tagUnsync = (flags & 0x80) != 0;
  if (tagUnsync && major < 4) body = _deunsynchronise(body);
  final d = _Bytes(body);
  var pos = 0;
  if (major >= 3 && (flags & 0x40) != 0) {
    // Extended header: in 2.3 its size leaves out its own 4 bytes, in 2.4
    // it is syncsafe and counts them.
    pos = major == 3 ? 4 + d.u32be(0) : _syncsafe(d, 0);
  }
  final idLength = major == 2 ? 3 : 4;
  final headerLength = major == 2 ? 6 : 10;
  final frames = <_Id3Frame>[];
  while (pos + headerLength <= d.length) {
    final id = d.ascii(pos, idLength);
    if (!_isFrameId(id)) break; // padding, or the end of what is readable
    int frameSize;
    var formatFlags = 0;
    if (major == 2) {
      frameSize = d[pos + 3] << 16 | d[pos + 4] << 8 | d[pos + 5];
    } else if (major == 3) {
      frameSize = d.u32be(pos + 4);
      formatFlags = d[pos + 9];
    } else {
      frameSize = _syncsafe(d, pos + 4);
      // Older iTunes wrote plain sizes in 2.4: take the plain size when the
      // syncsafe one does not land on a frame (or the end) but it does.
      final plain = d.u32be(pos + 4);
      if (plain != frameSize && !_frameBoundary(d, pos + headerLength + frameSize) && _frameBoundary(d, pos + headerLength + plain)) {
        frameSize = plain;
      }
      formatFlags = d[pos + 9];
    }
    final start = pos + headerLength;
    if (frameSize <= 0) {
      pos = start;
      continue;
    }
    final end = start + frameSize > d.length ? d.length : start + frameSize;
    final data = _frameData(d.slice(start, end), major, formatFlags, tagUnsync);
    if (data != null) frames.add(_Id3Frame(id, data));
    pos = start + frameSize;
  }
  _id3Frames(frames, t);
}

/// Whether [at] in [d] is the end of the tag body, padding, or a frame ID.
bool _frameBoundary(_Bytes d, int at) {
  if (at == d.length) return true;
  if (at > d.length) return false;
  if (d[at] == 0) return true;
  return _isFrameId(d.ascii(at, 4));
}

bool _isFrameId(String id) {
  if (id.isEmpty) return false;
  for (var i = 0; i < id.length; i++) {
    final c = id.codeUnitAt(i);
    if (!((c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39))) return false;
  }
  return true;
}

/// A frame's content with its format flags undone: grouping and data length
/// bytes skipped, per-frame unsynchronisation removed, zlib compression
/// inflated. Null for an encrypted frame.
Uint8List? _frameData(Uint8List raw, int major, int formatFlags, bool tagUnsync) {
  var data = raw;
  var compressed = false;
  if (major == 3) {
    // %ijk00000: compression (4-byte decompressed size), encryption, grouping.
    var skip = 0;
    if ((formatFlags & 0x80) != 0) {
      compressed = true;
      skip += 4;
    }
    if ((formatFlags & 0x40) != 0) return null;
    if ((formatFlags & 0x20) != 0) skip += 1;
    data = _tail(data, skip);
  } else if (major == 4) {
    // %0h00kmnp: grouping, compression, encryption, unsynchronisation,
    // data length indicator; the extra bytes follow in that order.
    var skip = 0;
    if ((formatFlags & 0x40) != 0) skip += 1;
    if ((formatFlags & 0x04) != 0) return null;
    if ((formatFlags & 0x01) != 0) skip += 4;
    compressed = (formatFlags & 0x08) != 0;
    data = _tail(data, skip);
    if ((formatFlags & 0x02) != 0 || tagUnsync) data = _deunsynchronise(data);
  }
  if (compressed) {
    try {
      data = ZLibDecoder().decodeBytes(data);
    } on Object {
      return null;
    }
  }
  return data;
}

Uint8List _tail(Uint8List data, int skip) => skip >= data.length ? Uint8List(0) : Uint8List.sublistView(data, skip);

/// Undoes unsynchronisation: every 0x00 after a 0xFF was inserted.
Uint8List _deunsynchronise(Uint8List data) {
  final buffer = Uint8List(data.length);
  var n = 0;
  for (var i = 0; i < data.length; i++) {
    buffer[n++] = data[i];
    if (data[i] == 0xFF && i + 1 < data.length && data[i + 1] == 0x00) i++;
  }
  return Uint8List.sublistView(buffer, 0, n);
}

class _Id3Frame {
  const _Id3Frame(this.id, this.data);
  final String id;
  final Uint8List data;
}

/// ID3v2.2 frame IDs as their 2.3/2.4 equivalents.
const Map<String, String> _v22Ids = {
  'TT2': 'TIT2',
  'TP1': 'TPE1',
  'TAL': 'TALB',
  'TP2': 'TPE2',
  'TYE': 'TYER',
  'TDA': 'TDAT',
  'TOR': 'TORY',
  'TCO': 'TCON',
  'TRK': 'TRCK',
  'TPA': 'TPOS',
  'TCM': 'TCOM',
  'COM': 'COMM',
  'ULT': 'USLT',
  'PIC': 'APIC',
};

void _id3Frames(List<_Id3Frame> frames, _Tags t) {
  String? year, dayMonth, recorded, original;
  final comments = <(String, String)>[];
  for (final f in frames) {
    final id = _v22Ids[f.id] ?? f.id;
    final pictureV22 = f.id == 'PIC';
    _guard(() {
      switch (id) {
        case 'TIT2':
          t.title ??= _id3Text(f.data);
        case 'TPE1':
          t.artist ??= _id3Text(f.data);
        case 'TALB':
          t.album ??= _id3Text(f.data);
        case 'TPE2':
          t.albumArtist ??= _id3Text(f.data);
        case 'TCOM':
          t.composer ??= _id3Text(f.data);
        case 'TCON':
          t.genre ??= _id3Genre(_id3Values(f.data));
        case 'TRCK':
          final (n, total) = _numberPair(_id3Text(f.data));
          t.track ??= n;
          t.trackTotal ??= total;
        case 'TPOS':
          t.disc ??= _numberPair(_id3Text(f.data)).$1;
        case 'TYER':
          year ??= _id3Text(f.data);
        case 'TDAT':
          dayMonth ??= _id3Text(f.data);
        case 'TDRC':
          recorded ??= _id3Text(f.data);
        case 'TDOR' || 'TORY':
          original ??= _id3Text(f.data);
        case 'COMM':
          final c = _id3Comment(f.data);
          if (c != null) comments.add(c);
        case 'USLT':
          t.lyrics ??= _id3Comment(f.data)?.$2;
        case 'APIC':
          _id3Picture(f.data, t, v22: pictureV22);
      }
    });
  }
  // TDRC (2.4) is the full timestamp; TYER + TDAT (2.3) say the same.
  final stamp = recorded ?? year;
  if (stamp != null) {
    t.setDate(stamp);
    final dm = dayMonth;
    if (recorded == null && dm != null && RegExp(r'^\d{4}$').hasMatch(dm) && t.year != null && t.date == null) {
      t.date = '${t.year}-${dm.substring(2, 4)}-${dm.substring(0, 2)}';
    }
  }
  final o = original;
  if (t.year == null && o != null) t.year = _year(o);
  // The comment proper has no description; iTunes keeps its own data
  // (iTunNORM, iTunSMPB...) in described ones.
  final plain = comments.where((c) => c.$1.isEmpty).firstOrNull ??
      comments.where((c) => !c.$1.startsWith('iTun') && !c.$1.startsWith('Songs-DB')).firstOrNull;
  t.comment ??= _clean(plain?.$2);
}

/// The values of a text frame (one, or several separated by NUL in 2.4).
List<String> _id3Values(Uint8List data) {
  if (data.isEmpty) return const [];
  final encoding = data[0];
  final out = <String>[];
  var at = 1;
  var bigEndian = false;
  while (at < data.length) {
    final (text, next, be) = _readTerminated(data, at, encoding, bigEndian);
    bigEndian = be;
    final v = _clean(text);
    if (v != null) out.add(v);
    if (next <= at) break;
    at = next;
  }
  return out;
}

/// A text frame's values as one string ("A; B" for several).
String? _id3Text(Uint8List data) {
  final values = _id3Values(data);
  return values.isEmpty ? null : values.join('; ');
}

/// COMM and USLT: encoding, language, a described text, then the text.
(String, String)? _id3Comment(Uint8List data) {
  if (data.length < 4) return null;
  final encoding = data[0];
  final (description, next, be) = _readTerminated(data, 4, encoding, false);
  final (text, _, _) = _readTerminated(data, next, encoding, be, untilEnd: true);
  final value = _clean(text);
  return value == null ? null : (description.trim(), value);
}

/// APIC: encoding, MIME type, picture type, description, data. ID3v2.2 PIC
/// has a three-letter image format instead of the MIME type.
void _id3Picture(Uint8List data, _Tags t, {required bool v22}) {
  if (data.length < 4) return;
  final encoding = data[0];
  final String mime;
  final int at;
  if (v22) {
    mime = switch (String.fromCharCodes(data.sublist(1, 4)).toUpperCase()) {
      'JPG' => 'image/jpeg',
      'PNG' => 'image/png',
      'GIF' => 'image/gif',
      'BMP' => 'image/bmp',
      _ => '',
    };
    at = 4;
  } else {
    var end = 1;
    while (end < data.length && data[end] != 0) {
      end++;
    }
    mime = String.fromCharCodes(data.sublist(1, end)).trim().toLowerCase();
    at = end + 1;
  }
  if (at >= data.length) return;
  final type = data[at];
  final (_, next, _) = _readTerminated(data, at + 1, encoding, false);
  if (next >= data.length || mime == '-->') return; // a link, not a picture
  t.offerCover(Uint8List.sublistView(data, next), mime, type);
}

/// Reads a string in ID3 [encoding] from [at] up to its terminator (one NUL,
/// or two on an even boundary for UTF-16) or the end. Returns the text, where
/// the next string starts, and the UTF-16 byte order (carried to the next
/// string of a frame whose later strings have no BOM).
(String, int, bool) _readTerminated(Uint8List data, int at, int encoding, bool bigEndian, {bool untilEnd = false}) {
  if (at >= data.length) return ('', data.length, bigEndian);
  final wide = encoding == 1 || encoding == 2;
  var end = at;
  if (untilEnd) {
    end = data.length;
  } else if (wide) {
    while (end + 1 < data.length && !(data[end] == 0 && data[end + 1] == 0)) {
      end += 2;
    }
    if (end + 1 >= data.length) end = data.length;
  } else {
    while (end < data.length && data[end] != 0) {
      end++;
    }
  }
  final raw = Uint8List.sublistView(data, at, end);
  final next = end >= data.length ? data.length : end + (wide ? 2 : 1);
  switch (encoding) {
    case 1:
      var be = bigEndian;
      var from = 0;
      if (raw.length >= 2 && raw[0] == 0xFE && raw[1] == 0xFF) {
        be = true;
        from = 2;
      } else if (raw.length >= 2 && raw[0] == 0xFF && raw[1] == 0xFE) {
        be = false;
        from = 2;
      }
      return (_utf16(raw, from, be), next, be);
    case 2:
      return (_utf16(raw, 0, true), next, true);
    case 3:
      return (utf8.decode(raw, allowMalformed: true), next, bigEndian);
    default:
      return (latin1.decode(raw), next, bigEndian);
  }
}

String _utf16(Uint8List raw, int from, bool bigEndian) {
  final units = <int>[];
  for (var i = from; i + 1 < raw.length; i += 2) {
    units.add(bigEndian ? raw[i] << 8 | raw[i + 1] : raw[i + 1] << 8 | raw[i]);
  }
  return String.fromCharCodes(units);
}

/// TCON: "Rock", "(17)", "(17)Rock" (a refinement), "(RX)", "(CR)", or in
/// 2.4 plain numbers among the values.
String? _id3Genre(List<String> values) {
  final out = <String>[];
  for (final value in values) {
    var s = value;
    final refs = <String>[];
    while (s.startsWith('(') && !s.startsWith('((')) {
      final close = s.indexOf(')');
      if (close < 0) break;
      refs.add(s.substring(1, close));
      s = s.substring(close + 1);
    }
    if (s.startsWith('((')) s = s.substring(1);
    final refinement = s.trim();
    if (refinement.isNotEmpty && !RegExp(r'^\d+$').hasMatch(refinement)) {
      out.add(refinement);
      continue;
    }
    if (refinement.isNotEmpty) refs.add(refinement);
    for (final r in refs) {
      final g = _genreReference(r);
      if (g != null) out.add(g);
    }
  }
  final unique = <String>[];
  for (final g in out) {
    if (!unique.contains(g)) unique.add(g);
  }
  return unique.isEmpty ? null : unique.join('; ');
}

String? _genreReference(String r) {
  if (r == 'RX') return 'Remix';
  if (r == 'CR') return 'Cover';
  final n = int.tryParse(r);
  return n != null && n >= 0 && n < id3v1Genres.length ? id3v1Genres[n] : null;
}

// ------------------------------------------------------------------ ID3v1

/// The 128-byte ID3v1 (or v1.1, with a track number) tag at the end.
void _id3v1(_Bytes b, _Tags t) {
  final at = b.length - 128;
  if (at < 0 || b.ascii(at, 3) != 'TAG') return;
  String? field(int offset, int length) {
    final raw = b.slice(at + offset, at + offset + length);
    var end = raw.indexOf(0);
    if (end < 0) end = raw.length;
    return _clean(latin1.decode(Uint8List.sublistView(raw, 0, end)));
  }

  t.title ??= field(3, 30);
  t.artist ??= field(33, 30);
  t.album ??= field(63, 30);
  t.year ??= _year(field(93, 4) ?? '');
  // ID3v1.1: a zero byte before the last comment byte makes it the track.
  final v11 = b[at + 125] == 0 && b[at + 126] != 0;
  t.comment ??= field(97, v11 ? 28 : 30);
  if (v11) t.track ??= b[at + 126];
  final genre = b[at + 127];
  if (genre < id3v1Genres.length) t.genre ??= id3v1Genres[genre];
}

/// The ID3v1 genres with the Winamp extensions (0-191), as ID3v2 TCON
/// references and MP4 `gnre` (one more) use them.
const List<String> id3v1Genres = [
  'Blues', 'Classic Rock', 'Country', 'Dance', 'Disco', 'Funk', 'Grunge', 'Hip-Hop', 'Jazz', 'Metal', //
  'New Age', 'Oldies', 'Other', 'Pop', 'R&B', 'Rap', 'Reggae', 'Rock', 'Techno', 'Industrial', //
  'Alternative', 'Ska', 'Death Metal', 'Pranks', 'Soundtrack', 'Euro-Techno', 'Ambient', 'Trip-Hop', 'Vocal', 'Jazz+Funk', //
  'Fusion', 'Trance', 'Classical', 'Instrumental', 'Acid', 'House', 'Game', 'Sound Clip', 'Gospel', 'Noise', //
  'Alternative Rock', 'Bass', 'Soul', 'Punk', 'Space', 'Meditative', 'Instrumental Pop', 'Instrumental Rock', 'Ethnic', 'Gothic', //
  'Darkwave', 'Techno-Industrial', 'Electronic', 'Pop-Folk', 'Eurodance', 'Dream', 'Southern Rock', 'Comedy', 'Cult', 'Gangsta', //
  'Top 40', 'Christian Rap', 'Pop/Funk', 'Jungle', 'Native American', 'Cabaret', 'New Wave', 'Psychedelic', 'Rave', 'Showtunes', //
  'Trailer', 'Lo-Fi', 'Tribal', 'Acid Punk', 'Acid Jazz', 'Polka', 'Retro', 'Musical', 'Rock & Roll', 'Hard Rock', //
  'Folk', 'Folk-Rock', 'National Folk', 'Swing', 'Fast Fusion', 'Bebop', 'Latin', 'Revival', 'Celtic', 'Bluegrass', //
  'Avantgarde', 'Gothic Rock', 'Progressive Rock', 'Psychedelic Rock', 'Symphonic Rock', 'Slow Rock', 'Big Band', 'Chorus', 'Easy Listening', 'Acoustic', //
  'Humour', 'Speech', 'Chanson', 'Opera', 'Chamber Music', 'Sonata', 'Symphony', 'Booty Bass', 'Primus', 'Porn Groove', //
  'Satire', 'Slow Jam', 'Club', 'Tango', 'Samba', 'Folklore', 'Ballad', 'Power Ballad', 'Rhythmic Soul', 'Freestyle', //
  'Duet', 'Punk Rock', 'Drum Solo', 'A Cappella', 'Euro-House', 'Dance Hall', 'Goa', 'Drum & Bass', 'Club-House', 'Hardcore Techno', //
  'Terror', 'Indie', 'BritPop', 'Afro-Punk', 'Polsk Punk', 'Beat', 'Christian Gangsta Rap', 'Heavy Metal', 'Black Metal', 'Crossover', //
  'Contemporary Christian', 'Christian Rock', 'Merengue', 'Salsa', 'Thrash Metal', 'Anime', 'J-Pop', 'Synthpop', 'Abstract', 'Art Rock', //
  'Baroque', 'Bhangra', 'Big Beat', 'Breakbeat', 'Chillout', 'Downtempo', 'Dub', 'EBM', 'Eclectic', 'Electro', //
  'Electroclash', 'Emo', 'Experimental', 'Garage', 'Global', 'IDM', 'Illbient', 'Industro-Goth', 'Jam Band', 'Krautrock', //
  'Leftfield', 'Lounge', 'Math Rock', 'New Romantic', 'Nu-Breakz', 'Post-Punk', 'Post-Rock', 'Psytrance', 'Shoegaze', 'Space Rock', //
  'Trop Rock', 'World Music', 'Neoclassical', 'Audiobook', 'Audio Theatre', 'Neue Deutsche Welle', 'Podcast', 'Indie Rock', 'G-Funk', 'Dubstep', //
  'Garage Rock', 'Psybient', //
];

// ------------------------------------------------------- Vorbis comments

/// A Vorbis comment block (little-endian lengths): vendor, then
/// `KEY=value` entries in UTF-8. Shared by FLAC, Ogg Vorbis, Opus and FLAC.
void _vorbisComments(_Bytes b, int at, int end, _Tags t) {
  final limit = end > b.length ? b.length : end;
  final vendor = b.u32le(at);
  var pos = at + 4 + vendor;
  final count = b.u32le(pos);
  pos += 4;
  final fields = <String, List<String>>{};
  for (var i = 0; i < count && pos + 4 <= limit; i++) {
    final length = b.u32le(pos);
    pos += 4;
    if (length > limit - pos) break;
    final entry = utf8.decode(b.slice(pos, pos + length), allowMalformed: true);
    pos += length;
    final eq = entry.indexOf('=');
    if (eq <= 0) continue;
    final key = entry.substring(0, eq).toUpperCase();
    final value = entry.substring(eq + 1);
    // Pictures are kept raw (they can be large); every other value trimmed.
    if (key == 'METADATA_BLOCK_PICTURE' || key == 'COVERART') {
      (fields[key] ??= []).add(value);
    } else if (_clean(value) case final v?) {
      (fields[key] ??= []).add(v);
    }
  }
  _vorbisFields(fields, t);
}

void _vorbisFields(Map<String, List<String>> f, _Tags t) {
  String? one(List<String> keys) {
    for (final k in keys) {
      final v = f[k];
      if (v != null && v.isNotEmpty) return v.join('; ');
    }
    return null;
  }

  t.title ??= one(['TITLE']);
  t.artist ??= one(['ARTIST']);
  t.album ??= one(['ALBUM']);
  t.albumArtist ??= one(['ALBUMARTIST', 'ALBUM ARTIST', 'ALBUM_ARTIST']);
  t.genre ??= one(['GENRE']);
  t.composer ??= one(['COMPOSER']);
  t.comment ??= one(['COMMENT', 'DESCRIPTION']);
  t.lyrics ??= one(['LYRICS', 'UNSYNCEDLYRICS', 'UNSYNCED LYRICS']);
  final date = one(['DATE']) ?? one(['YEAR']) ?? one(['ORIGINALDATE', 'ORIGINALYEAR']);
  if (date != null) t.setDate(f['DATE']?.first ?? date);
  final (track, totalInTrack) = _numberPair(one(['TRACKNUMBER']));
  t.track ??= track;
  t.trackTotal ??= totalInTrack ?? _numberPair(one(['TRACKTOTAL', 'TOTALTRACKS'])).$1;
  t.disc ??= _numberPair(one(['DISCNUMBER'])).$1;
  for (final encoded in f['METADATA_BLOCK_PICTURE'] ?? const <String>[]) {
    final block = _base64(encoded);
    if (block != null) _guard(() => _flacPicture(_Bytes(block), 0, block.length, t));
  }
  // The old, unofficial way: COVERART (base64 picture) with COVERARTMIME.
  final old = f['COVERART']?.firstOrNull;
  if (old != null) {
    final picture = _base64(old);
    if (picture != null) t.offerCover(picture, f['COVERARTMIME']?.firstOrNull ?? '', 0);
  }
}

Uint8List? _base64(String s) {
  try {
    final compact = s.replaceAll(RegExp(r'\s'), '');
    return base64.decode(base64.normalize(compact));
  } on FormatException {
    return null;
  }
}

// ------------------------------------------------------------------- FLAC

/// FLAC metadata blocks after the `fLaC` marker: VORBIS_COMMENT (4) and
/// PICTURE (6).
void _flac(_Bytes b, int at, _Tags t) {
  var pos = at;
  for (var guard = 0; guard < 1024 && pos + 4 <= b.length; guard++) {
    final header = b[pos];
    final type = header & 0x7F;
    final length = b[pos + 1] << 16 | b[pos + 2] << 8 | b[pos + 3];
    final body = pos + 4;
    if (type == 4) _guard(() => _vorbisComments(b, body, body + length, t));
    if (type == 6) _guard(() => _flacPicture(b, body, body + length, t));
    if (type == 127) break; // invalid
    pos = body + length;
    if ((header & 0x80) != 0) break; // the last block
  }
}

/// A FLAC PICTURE block (big-endian): type, MIME type, description, size and
/// colours, then the picture data.
void _flacPicture(_Bytes b, int at, int end, _Tags t) {
  final type = b.u32be(at);
  final mimeLength = b.u32be(at + 4);
  final mimeAt = at + 8;
  if (mimeLength > end - mimeAt) return;
  final mime = latin1.decode(b.slice(mimeAt, mimeAt + mimeLength));
  final descriptionLength = b.u32be(mimeAt + mimeLength);
  final afterDescription = mimeAt + mimeLength + 4 + descriptionLength;
  if (afterDescription > end) return;
  // Width, height, depth, colours (4 bytes each), then the data length.
  final dataLength = b.u32be(afterDescription + 16);
  final dataAt = afterDescription + 20;
  if (dataLength == 0 || dataAt >= b.length) return;
  final dataEnd = dataAt + dataLength > b.length ? b.length : dataAt + dataLength;
  t.offerCover(b.slice(dataAt, dataEnd), mime, type);
}

// -------------------------------------------------------------------- Ogg

/// The comment header of the first logical stream: the second packet
/// (Vorbis `\x03vorbis`, Opus `OpusTags`, Ogg FLAC VORBIS_COMMENT block).
void _ogg(_Bytes b, _Tags t) {
  final packets = _oggPackets(b, 2);
  if (packets.length < 2) return;
  final first = _Bytes(packets[0]);
  final comments = _Bytes(packets[1]);
  if (first.ascii(0, 8) == 'OpusHead' && comments.ascii(0, 8) == 'OpusTags') {
    _vorbisComments(comments, 8, comments.length, t);
  } else if (first[0] == 1 && first.ascii(1, 6) == 'vorbis' && comments[0] == 3 && comments.ascii(1, 6) == 'vorbis') {
    _vorbisComments(comments, 7, comments.length, t);
  } else if (first.ascii(0, 5) == '\x7FFLAC' && (comments[0] & 0x7F) == 4) {
    _vorbisComments(comments, 4, comments.length, t);
  }
}

/// The first [count] packets of the first logical stream, put together
/// across pages (a lacing value of 255 continues a packet).
List<Uint8List> _oggPackets(_Bytes b, int count) {
  final packets = <Uint8List>[];
  final current = BytesBuilder(copy: false);
  int? serial;
  var at = 0;
  while (at + 27 <= b.length && packets.length < count) {
    if (b.ascii(at, 4) != 'OggS') break;
    final pageSerial = b.u32le(at + 14);
    final segments = b[at + 26];
    final table = at + 27;
    var data = table + segments;
    var size = 0;
    for (var i = 0; i < segments; i++) {
      size += b[table + i];
    }
    serial ??= pageSerial;
    if (pageSerial == serial) {
      for (var i = 0; i < segments && packets.length < count; i++) {
        final lace = b[table + i];
        final end = data + lace > b.length ? b.length : data + lace;
        if (end > data) current.add(b.slice(data, end));
        data += lace;
        if (lace < 255) packets.add(current.takeBytes());
      }
    }
    at = table + segments + size;
  }
  // A packet cut off by the end of the file: read what there is of it.
  if (packets.length < count && current.length > 0) packets.add(current.takeBytes());
  return packets;
}

// -------------------------------------------------------------------- MP4

/// iTunes-style metadata: `moov/udta/meta/ilst` (or `moov/meta/ilst`), each
/// item holding a `data` atom whose type says how to read its value.
void _mp4(_Bytes b, _Tags t) {
  final moov = _box(b, 0, b.length, 'moov');
  if (moov == null) return;
  final udta = _box(b, moov.$1, moov.$2, 'udta');
  var meta = udta == null ? null : _box(b, udta.$1, udta.$2, 'meta');
  meta ??= _box(b, moov.$1, moov.$2, 'meta');
  if (meta == null) return;
  // A full box (version and flags) in ISO files; QuickTime's has none.
  final children = b.ascii(meta.$1 + 4, 4) == 'hdlr' ? meta.$1 : meta.$1 + 4;
  final ilst = _box(b, children, meta.$2, 'ilst');
  if (ilst == null) return;
  var at = ilst.$1;
  while (at + 8 <= ilst.$2) {
    final item = _boxAt(b, at, ilst.$2);
    if (item == null) break;
    final (type, bodyStart, end) = item;
    _guard(() => _mp4Item(b, type, bodyStart, end, t));
    at = end;
  }
}

void _mp4Item(_Bytes b, String type, int start, int end, _Tags t) {
  // The first data atom; covr may hold several pictures.
  var at = start;
  while (at + 16 <= end) {
    final box = _boxAt(b, at, end);
    if (box == null) return;
    final (boxType, body, boxEnd) = box;
    at = boxEnd;
    if (boxType != 'data') continue;
    final dataType = b[body + 1] << 16 | b[body + 2] << 8 | b[body + 3];
    final valueAt = body + 8;
    if (valueAt > boxEnd) return;
    final value = b.slice(valueAt, boxEnd);
    String? text() => _clean(switch (dataType) {
          2 => _utf16(value, 0, true),
          _ => utf8.decode(value, allowMalformed: true),
        });
    switch (type) {
      case '©nam':
        t.title ??= text();
      case '©ART':
        t.artist ??= text();
      case '©alb':
        t.album ??= text();
      case 'aART':
        t.albumArtist ??= text();
      case '©day':
        final d = text();
        if (d != null && t.year == null) t.setDate(d);
      case '©gen':
        t.genre ??= text();
      case 'gnre':
        // An ID3v1 genre number plus one.
        if (value.length >= 2) {
          final n = value[0] << 8 | value[1];
          if (n >= 1 && n <= id3v1Genres.length) t.genre ??= id3v1Genres[n - 1];
        }
      case 'trkn':
        if (value.length >= 6) {
          final n = value[2] << 8 | value[3], total = value[4] << 8 | value[5];
          if (n > 0) t.track ??= n;
          if (total > 0) t.trackTotal ??= total;
        }
      case 'disk':
        if (value.length >= 4) {
          final n = value[2] << 8 | value[3];
          if (n > 0) t.disc ??= n;
        }
      case '©wrt':
        t.composer ??= text();
      case '©cmt':
        t.comment ??= text();
      case '©lyr':
        t.lyrics ??= text();
      case 'covr':
        final mime = switch (dataType) { 13 => 'image/jpeg', 14 => 'image/png', 27 => 'image/bmp', _ => '' };
        // MP4 has no picture types: the first is the cover.
        t.offerCover(value, mime, 3);
        continue;
    }
    return;
  }
}

/// The body (start, end) of the first [type] box between [from] and [to].
(int, int)? _box(_Bytes b, int from, int to, String type) {
  var at = from;
  while (at + 8 <= to) {
    final box = _boxAt(b, at, to);
    if (box == null) return null;
    if (box.$1 == type) return (box.$2, box.$3);
    at = box.$3;
  }
  return null;
}

/// The box at [at]: its type, where its body starts and where it ends.
(String, int, int)? _boxAt(_Bytes b, int at, int to) {
  var size = b.u32be(at);
  var header = 8;
  if (size == 1) {
    size = b.u32be(at + 8) * 0x100000000 + b.u32be(at + 12);
    header = 16;
  } else if (size == 0) {
    size = to - at;
  }
  if (size < header) return null;
  final end = at + size > to ? to : at + size;
  return (b.ascii(at + 4, 4), at + header, end);
}

// -------------------------------------------------------------- WAV, AIFF

/// RIFF chunks (little-endian sizes): an `id3 `/`ID3 ` chunk, and LIST/INFO
/// text (INAM, IART, IPRD, ICRD, IGNR, ICMT...). The ID3 tag wins where both
/// say something, as Windows reads them.
void _wav(_Bytes b, _Tags t) {
  final info = _Tags();
  var at = 12;
  while (at + 8 <= b.length) {
    final id = b.ascii(at, 4);
    final size = b.u32le(at + 4);
    final body = at + 8;
    final end = body + size > b.length ? b.length : body + size;
    if (id == 'id3 ' || id == 'ID3 ') _guard(() => _id3v2(b, body, t));
    if (id == 'LIST' && b.ascii(body, 4) == 'INFO') _guard(() => _riffInfo(b, body + 4, end, info));
    at = body + size + (size & 1);
  }
  t.fillFrom(info);
}

void _riffInfo(_Bytes b, int at, int end, _Tags t) {
  var pos = at;
  while (pos + 8 <= end) {
    final id = b.ascii(pos, 4);
    final size = b.u32le(pos + 4);
    final body = pos + 8;
    final stop = body + size > end ? end : body + size;
    final value = _clean(_riffText(b.slice(body, stop)));
    switch (id) {
      case 'INAM':
        t.title ??= value;
      case 'IART':
        t.artist ??= value;
      case 'IPRD':
        t.album ??= value;
      case 'ICRD':
        if (value != null && t.year == null) t.setDate(value);
      case 'IGNR':
        t.genre ??= value;
      case 'ICMT':
        t.comment ??= value;
      case 'IMUS':
        t.composer ??= value;
      case 'ITRK' || 'IPRT':
        t.track ??= _numberPair(value).$1;
    }
    pos = body + size + (size & 1);
  }
}

/// INFO text: NUL-terminated, in UTF-8 when it is valid UTF-8, else in the
/// writer's 8-bit code page (read as Latin-1).
String _riffText(Uint8List raw) {
  var end = raw.indexOf(0);
  if (end < 0) end = raw.length;
  final bytes = Uint8List.sublistView(raw, 0, end);
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// AIFF/AIFC chunks (big-endian sizes): an `ID3 ` chunk, else NAME, AUTH
/// and ANNO text.
void _aiff(_Bytes b, _Tags t) {
  final text = _Tags();
  var at = 12;
  while (at + 8 <= b.length) {
    final id = b.ascii(at, 4);
    final size = b.u32be(at + 4);
    final body = at + 8;
    final end = body + size > b.length ? b.length : body + size;
    String? value() => _clean(latin1.decode(b.slice(body, end)).replaceAll('\u0000', ''));
    switch (id) {
      case 'ID3 ' || 'id3 ':
        _guard(() => _id3v2(b, body, t));
      case 'NAME':
        text.title ??= value();
      case 'AUTH':
        text.artist ??= value();
      case 'ANNO':
        text.comment ??= value();
    }
    at = body + size + (size & 1);
  }
  t.fillFrom(text);
}

// ---------------------------------------------------------------- helpers

/// "3/12" -> (3, 12), "03" -> (3, null).
(int?, int?) _numberPair(String? s) {
  if (s == null) return (null, null);
  final m = RegExp(r'^\s*(\d+)\s*(?:/\s*(\d+))?').firstMatch(s);
  if (m == null) return (null, null);
  final n = int.tryParse(m.group(1)!);
  final total = m.group(2) == null ? null : int.tryParse(m.group(2)!);
  return (n != null && n > 0 ? n : null, total != null && total > 0 ? total : null);
}

int? _year(String s) {
  final m = RegExp(r'^\s*(\d{4})').firstMatch(s);
  final y = m == null ? null : int.parse(m.group(1)!);
  return y != null && y > 0 ? y : null;
}

/// Trimmed text without NULs; null when nothing is left.
String? _clean(String? s) {
  if (s == null) return null;
  final v = s.replaceAll('\u0000', '').trim();
  return v.isEmpty ? null : v;
}

/// The picture type as a preference: the front cover (3) first, then
/// "other" (0), then anything else.
int _coverRank(int type) => switch (type) { 3 => 0, 0 => 1, _ => 2 };

/// The picture's type from its first bytes, else from what the tag says.
String? _pictureMime(Uint8List data, String said) {
  if (data.length >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return 'image/jpeg';
  if (data.length >= 8 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return 'image/png';
  if (data.length >= 6 && data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x38) return 'image/gif';
  if (data.length >= 12 && data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 && data[8] == 0x57 && data[9] == 0x45 && data[10] == 0x42 && data[11] == 0x50) {
    return 'image/webp';
  }
  if (data.length >= 2 && data[0] == 0x42 && data[1] == 0x4D) return 'image/bmp';
  final s = said.trim().toLowerCase();
  if (s == 'image/jpg') return 'image/jpeg';
  if (s.startsWith('image/')) return s;
  return null;
}

/// The fields read so far. Every setter keeps the first value, so readers
/// run in order of preference.
class _Tags {
  String? title, artist, album, albumArtist, genre, composer, comment, lyrics, date;
  int? year, track, trackTotal, disc;
  Uint8List? cover;
  String? coverMime;
  int coverRank = 99;

  /// A date or year as written ("2024", "2024-05-17", "2024-05-17T08:00").
  void setDate(String s) {
    final y = _year(s);
    if (y == null) return;
    year ??= y;
    final v = s.trim();
    if (date == null && year == y && v.length > 4) {
      final m = RegExp(r'^\d{4}-\d{2}(?:-\d{2})?').firstMatch(v);
      if (m != null) date = m.group(0);
    }
  }

  void offerCover(Uint8List data, String mime, int type) {
    final rank = _coverRank(type);
    if (data.isEmpty || rank >= coverRank) return;
    final m = _pictureMime(data, mime);
    if (m == null) return;
    cover = data;
    coverMime = m;
    coverRank = rank;
  }

  /// Takes every field [other] has and this lacks.
  void fillFrom(_Tags other) {
    title ??= other.title;
    artist ??= other.artist;
    album ??= other.album;
    albumArtist ??= other.albumArtist;
    genre ??= other.genre;
    composer ??= other.composer;
    comment ??= other.comment;
    lyrics ??= other.lyrics;
    if (year == null) {
      year = other.year;
      date ??= other.date;
    }
    track ??= other.track;
    trackTotal ??= other.trackTotal;
    disc ??= other.disc;
    final otherCover = other.cover;
    if (otherCover != null && other.coverRank < coverRank) {
      cover = otherCover;
      coverMime = other.coverMime;
      coverRank = other.coverRank;
    }
  }

  AudioTagExtraction build() {
    final picture = cover;
    return AudioTagExtraction(
      tags: AudioTags(
        title: title,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
        year: year,
        date: date,
        genre: genre,
        trackNumber: track,
        trackTotal: trackTotal,
        discNumber: disc,
        composer: composer,
        comment: comment,
        lyrics: lyrics,
      ),
      // A copy, so the file's bytes can be let go.
      cover: picture == null ? null : Uint8List.fromList(picture),
      coverMimeType: picture == null ? null : coverMime,
    );
  }
}

/// Bounds-checked reads: past the end reads as 0, so damaged lengths end the
/// reading instead of throwing.
class _Bytes {
  _Bytes(this.data);
  final Uint8List data;

  int get length => data.length;
  int operator [](int i) => i >= 0 && i < data.length ? data[i] : 0;
  int u16le(int at) => this[at] | this[at + 1] << 8;
  int u16be(int at) => this[at] << 8 | this[at + 1];
  int u32le(int at) => u16le(at) + u16le(at + 2) * 0x10000;
  int u32be(int at) => u16be(at) * 0x10000 + u16be(at + 2);
  /// [count] bytes as characters (Latin-1, so MP4's `©` reads as U+00A9).
  String ascii(int at, int count) => String.fromCharCodes([for (var i = 0; i < count; i++) this[at + i]]);

  /// The bytes from [start] to [end], clamped to the data (a view, no copy).
  Uint8List slice(int start, int end) {
    final s = start < 0 ? 0 : (start > data.length ? data.length : start);
    final e = end < s ? s : (end > data.length ? data.length : end);
    return Uint8List.sublistView(data, s, e);
  }
}
