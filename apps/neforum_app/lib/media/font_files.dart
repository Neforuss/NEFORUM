import 'package:flutter/foundation.dart';

// Font files read in Dart: the family names and styles in an OpenType or
// TrueType file's 'name' and 'OS/2' tables, and a single face taken out of a
// collection (.ttc/.otc). Only the header, the table directory and those two
// tables are read ([FontByteReader]), so a 20 MB CJK font costs a few
// kilobytes. Nothing here throws on a broken file: it yields no faces.

/// Reads [length] bytes at [offset] of a font file; null when that range is
/// outside the file or cannot be read.
typedef FontByteReader = Uint8List? Function(int offset, int length);

/// File name extensions of the font files NEFORUM reads.
const Set<String> kFontFileExtensions = {'ttf', 'otf', 'ttc', 'otc'};

/// Whether [path] names a font file NEFORUM reads, by its extension.
bool isFontFilePath(String path) {
  final dot = path.lastIndexOf('.');
  return dot >= 0 && kFontFileExtensions.contains(path.substring(dot + 1).toLowerCase());
}

/// One face in a font file: its family ("Fira Sans"), style ("Bold
/// Italic"), weight (100 to 900) and slant, and its [index] in a collection
/// (0 in a single-face file).
@immutable
class FontFace {
  const FontFace({required this.family, this.subfamily = 'Regular', this.weight = 400, this.italic = false, this.index = 0});

  /// Null when [j] is not a face.
  static FontFace? tryParse(Object? j) {
    if (j is! Map) return null;
    final family = j['family'];
    if (family is! String || family.isEmpty) return null;
    final subfamily = j['subfamily'], weight = j['weight'], italic = j['italic'], index = j['index'];
    return FontFace(
      family: family,
      subfamily: subfamily is String ? subfamily : 'Regular',
      weight: weight is int ? weight : 400,
      italic: italic == true,
      index: index is int ? index : 0,
    );
  }

  final String family;
  final String subfamily;
  final int weight;
  final bool italic;
  final int index;

  Map<String, dynamic> toJson() => {'family': family, 'subfamily': subfamily, 'weight': weight, 'italic': italic, 'index': index};

  @override
  bool operator ==(Object other) =>
      other is FontFace && other.family == family && other.subfamily == subfamily && other.weight == weight && other.italic == italic && other.index == index;

  @override
  int get hashCode => Object.hash(family, subfamily, weight, italic, index);

  @override
  String toString() => 'FontFace($family $subfamily $weight${italic ? ' italic' : ''} #$index)';
}

/// Most faces read from one collection, and most tables read from one face:
/// real files stay far below both, broken ones cannot make the scan spin.
const int _maxFaces = 256;
const int _maxTables = 512;

/// The longest 'name' table read (real ones are a few kilobytes; a few CJK
/// fonts carry long licence texts).
const int _maxNameTable = 4 << 20;

const int _tagTtcf = 0x74746366; // 'ttcf'
const int _tagName = 0x6E616D65; // 'name'
const int _tagOs2 = 0x4F532F32; // 'OS/2'

int _u16(Uint8List b, int o) => b[o] << 8 | b[o + 1];
int _u32(Uint8List b, int o) => b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];

bool _isSfntVersion(int v) =>
    v == 0x00010000 || // TrueType
    v == 0x4F54544F || // 'OTTO', CFF outlines
    v == 0x74727565 || // 'true', old Apple TrueType
    v == 0x74797031; // 'typ1'

/// The start of every face in the file: one offset for a plain font, one per
/// face for a collection; empty when the file is not a font.
List<int> _faceOffsets(FontByteReader read) {
  final head = read(0, 12);
  if (head == null || head.length < 12) return const [];
  final tag = _u32(head, 0);
  if (_isSfntVersion(tag)) return const [0];
  if (tag != _tagTtcf) return const [];
  final count = _u32(head, 8);
  if (count <= 0 || count > _maxFaces) return const [];
  final table = read(12, count * 4);
  if (table == null || table.length < count * 4) return const [];
  return [for (var i = 0; i < count; i++) _u32(table, i * 4)];
}

/// The table records of the face at [offset]: tag -> (offset, length).
Map<int, (int, int)>? _tables(FontByteReader read, int offset) {
  final head = read(offset, 12);
  if (head == null || head.length < 12 || !_isSfntVersion(_u32(head, 0))) return null;
  final n = _u16(head, 4);
  if (n == 0 || n > _maxTables) return null;
  final records = read(offset + 12, n * 16);
  if (records == null || records.length < n * 16) return null;
  return {
    for (var i = 0; i < n; i++) _u32(records, i * 16): (_u32(records, i * 16 + 8), _u32(records, i * 16 + 12)),
  };
}

/// Every face in a font file, read through [read]. Faces without a usable
/// family name, and macOS's hidden system faces (names starting with a
/// dot), are left out. Empty for anything that is not a font.
List<FontFace> readFontFaces(FontByteReader read) {
  final out = <FontFace>[];
  try {
    final offsets = _faceOffsets(read);
    for (var i = 0; i < offsets.length; i++) {
      final face = _readFace(read, offsets[i], i);
      if (face != null) out.add(face);
    }
  } on Object {
    // A file that lies about its sizes: whatever was read stays.
  }
  return out;
}

/// [readFontFaces] over a whole file in memory.
List<FontFace> readFontFacesFromBytes(Uint8List bytes) => readFontFaces(bytesFontReader(bytes));

/// A [FontByteReader] over [bytes].
FontByteReader bytesFontReader(Uint8List bytes) => (offset, length) {
      if (offset < 0 || length < 0 || offset + length > bytes.length) return null;
      return Uint8List.sublistView(bytes, offset, offset + length);
    };

FontFace? _readFace(FontByteReader read, int offset, int index) {
  final tables = _tables(read, offset);
  if (tables == null) return null;
  final name = tables[_tagName];
  if (name == null || name.$2 < 6 || name.$2 > _maxNameTable) return null;
  final names = read(name.$1, name.$2);
  if (names == null || names.length < 6) return null;
  final family = _bestName(names, 16) ?? _bestName(names, 1);
  if (family == null || family.startsWith('.')) return null;
  final subfamily = _bestName(names, 17) ?? _bestName(names, 2) ?? 'Regular';
  var weight = 400;
  var italic = false;
  final os2 = tables[_tagOs2];
  if (os2 != null && os2.$2 >= 64) {
    final t = read(os2.$1, 64);
    if (t != null && t.length >= 64) {
      final w = _u16(t, 4);
      // A few old fonts give 1 to 9 (hundreds), a few 0.
      weight = w >= 1 && w <= 9 ? w * 100 : (w >= 1 && w <= 1000 ? w : 400);
      italic = _u16(t, 62) & 1 != 0;
    }
  }
  final style = subfamily.toLowerCase();
  if (style.contains('italic') || style.contains('oblique')) italic = true;
  return FontFace(family: family, subfamily: subfamily, weight: weight, italic: italic, index: index);
}

/// The best string for [nameId] in a 'name' table: Windows English (US),
/// then any Windows English, any Windows or Unicode entry, then Mac Roman.
String? _bestName(Uint8List t, int nameId) {
  final count = _u16(t, 2);
  final storage = _u16(t, 4);
  String? best;
  var bestScore = 0;
  for (var i = 0; i < count; i++) {
    final r = 6 + i * 12;
    if (r + 12 > t.length) break;
    if (_u16(t, r + 6) != nameId) continue;
    final platform = _u16(t, r), encoding = _u16(t, r + 2), language = _u16(t, r + 4);
    final length = _u16(t, r + 8), start = storage + _u16(t, r + 10);
    if (length == 0 || start + length > t.length) continue;
    final int score;
    if (platform == 3 && language == 0x409) {
      score = 5;
    } else if (platform == 3 && language & 0xFF == 0x09) {
      score = 4;
    } else if (platform == 3 || platform == 0) {
      score = 3;
    } else if (platform == 1 && encoding == 0 && language == 0) {
      score = 2;
    } else if (platform == 1 && encoding == 0) {
      score = 1;
    } else {
      continue;
    }
    if (score <= bestScore) continue;
    final bytes = Uint8List.sublistView(t, start, start + length);
    final s = _clean(platform == 1 ? _macRoman(bytes) : _utf16be(bytes));
    if (s.isEmpty) continue;
    best = s;
    bestScore = score;
  }
  return best;
}

String _utf16be(Uint8List b) => String.fromCharCodes([for (var i = 0; i + 1 < b.length; i += 2) b[i] << 8 | b[i + 1]]);

/// Mac Roman: ASCII is the same; the rest is rare in family names and kept
/// as Latin-1, close enough for a name in a list.
String _macRoman(Uint8List b) => String.fromCharCodes(b);

String _clean(String s) => s.replaceAll(RegExp(r'[\x00-\x1F\x7F�﻿]'), '').trim();

/// The face at [index] of the font in [bytes] as a font file of its own: a
/// plain font comes back as it is (index 0), a collection's face with its
/// tables copied out. The engine loads only the first face of a collection,
/// so every other face goes through here. Null when there is no such face.
Uint8List? extractFontFace(Uint8List bytes, int index) {
  try {
    final read = bytesFontReader(bytes);
    final offsets = _faceOffsets(read);
    if (index < 0 || index >= offsets.length) return null;
    if (offsets.length == 1 && offsets.single == 0) return index == 0 ? bytes : null;
    final at = offsets[index];
    final head = read(at, 12);
    if (head == null) return null;
    final n = _u16(head, 4);
    if (n == 0 || n > _maxTables) return null;
    final records = read(at + 12, n * 16);
    if (records == null) return null;
    var size = 12 + n * 16;
    final tables = <(int tag, int checksum, int offset, int length)>[];
    for (var i = 0; i < n; i++) {
      final o = i * 16;
      final t = (_u32(records, o), _u32(records, o + 4), _u32(records, o + 8), _u32(records, o + 12));
      if (t.$3 + t.$4 > bytes.length) return null;
      tables.add(t);
      size += (t.$4 + 3) & ~3;
    }
    final out = Uint8List(size);
    out.setRange(0, 12, head);
    var data = 12 + n * 16;
    final view = ByteData.sublistView(out);
    for (var i = 0; i < n; i++) {
      final (tag, checksum, offset, length) = tables[i];
      final r = 12 + i * 16;
      view
        ..setUint32(r, tag)
        ..setUint32(r + 4, checksum)
        ..setUint32(r + 8, data)
        ..setUint32(r + 12, length);
      out.setRange(data, data + length, bytes, offset);
      data += (length + 3) & ~3;
    }
    return out;
  } on Object {
    return null;
  }
}

/// The face of [faces] to draw regular words in: upright and closest to
/// weight 400; an italic face only when there is nothing else.
FontFace? regularFaceOf(Iterable<FontFace> faces) {
  FontFace? best;
  for (final f in faces) {
    if (best == null || _regularScore(f) < _regularScore(best)) best = f;
  }
  return best;
}

int _regularScore(FontFace f) => (f.italic ? 10000 : 0) + (f.weight - 400).abs();

/// The face of [faces] to draw bold words in: upright, weight 600 or more,
/// closest to 700; null when the family has none.
FontFace? boldFaceOf(Iterable<FontFace> faces) {
  FontFace? best;
  for (final f in faces) {
    if (f.italic || f.weight < 600) continue;
    if (best == null || (f.weight - 700).abs() < (best.weight - 700).abs()) best = f;
  }
  return best;
}
