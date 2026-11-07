// Shared by the font download tests and integration_test/font_downloads_test.dart.
//
// What a Fontsource subset file is: a real font whose character map covers one
// script. No such file is committed (no binaries in the repo), so one is made
// here from a real font the repo already has, with real outlines, by replacing
// its character map. The JSON has the shape api.fontsource.org answered on
// 2026-11-06, cut down to a few rows.

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_app/media/font_files.dart';

const String kInterRegular = 'assets/fonts/Inter-Regular.ttf';
const String kInterMedium = 'assets/fonts/Inter-Medium.ttf';
const String kInterBold = 'assets/fonts/Inter-Bold.ttf';
const String kMono = 'assets/fonts/JetBrainsMono-Regular.ttf';

int _u16(Uint8List b, int o) => b[o] << 8 | b[o + 1];
int _u32(Uint8List b, int o) => b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];

Map<String, Uint8List> _tablesOf(Uint8List ttf) {
  final n = _u16(ttf, 4);
  return {
    for (var i = 0; i < n; i++)
      String.fromCharCodes(ttf, 12 + i * 16, 16 + i * 16): Uint8List.sublistView(ttf, _u32(ttf, 12 + i * 16 + 8), _u32(ttf, 12 + i * 16 + 8) + _u32(ttf, 12 + i * 16 + 12)),
  };
}

Uint8List _build(int version, Map<String, Uint8List> tables) {
  final names = tables.keys.toList()..sort();
  final n = names.length;
  final dir = ByteData(12 + n * 16)
    ..setUint32(0, version)
    ..setUint16(4, n);
  final data = BytesBuilder();
  for (var i = 0; i < n; i++) {
    final t = tables[names[i]]!;
    final r = 12 + i * 16;
    for (var c = 0; c < 4; c++) {
      dir.setUint8(r + c, names[i].codeUnitAt(c));
    }
    dir
      ..setUint32(r + 8, 12 + n * 16 + data.length)
      ..setUint32(r + 12, t.length);
    data.add(t);
    while (data.length % 4 != 0) {
      data.addByte(0);
    }
  }
  return Uint8List.fromList([...dir.buffer.asUint8List(), ...data.takeBytes()]);
}

/// A format 12 'cmap' for [map], sorted.
Uint8List _cmap(Map<int, int> map) {
  final codes = map.keys.toList()..sort();
  final out = ByteData(12 + 16 + codes.length * 12)
    ..setUint16(2, 1)
    ..setUint16(4, 3)
    ..setUint16(6, 10)
    ..setUint32(8, 12)
    ..setUint16(12, 12)
    ..setUint32(16, 16 + codes.length * 12)
    ..setUint32(24, codes.length);
  for (var i = 0; i < codes.length; i++) {
    final r = 28 + i * 12;
    out
      ..setUint32(r, codes[i])
      ..setUint32(r + 4, codes[i])
      ..setUint32(r + 8, map[codes[i]]!);
  }
  return out.buffer.asUint8List();
}

/// [ttf] with a character map only for the code points [keep] accepts: real
/// outlines, one script, as a font service cuts them.
Uint8List subsetOf(Uint8List ttf, bool Function(int codePoint) keep) {
  final map = {for (final e in readCharacterMap(ttf).entries) if (keep(e.key)) e.key: e.value};
  return _build(_u32(ttf, 0), {..._tablesOf(ttf), 'cmap': _cmap(map)});
}

bool isLatin(int c) => c < 0x250;
bool isCyrillic(int c) => c >= 0x400 && c < 0x530;

/// [ttf] with every outline gone, as a color font looks to an engine that
/// cannot draw it: loads without complaint, maps its characters, draws nothing.
Uint8List blankOutlinesOf(Uint8List ttf) {
  final tables = _tablesOf(ttf);
  return _build(_u32(ttf, 0), {...tables, 'loca': Uint8List(tables['loca']!.length)});
}

/// [ttf] with every outline gone except the missing-glyph box: a test asking
/// for a character this font lacks would still see ink, from the box or from a
/// fallback font. Only asking for what the font maps shows it is blank.
Uint8List blankExceptMissingGlyphOf(Uint8List ttf) {
  final tables = _tablesOf(ttf);
  final loca = Uint8List.fromList(tables['loca']!);
  final long = _u16(tables['head']!, 50) == 1;
  final size = long ? 4 : 2;
  for (var o = size * 2; o < loca.length; o += size) {
    loca.setRange(o, o + size, loca, size);
  }
  return _build(_u32(ttf, 0), {...tables, 'loca': loca});
}

/// What the list answers, cut down. Rows that must stay hidden are included.
List<Map<String, dynamic>> fontListFixture() => [
      _row('42dot-sans', '42dot Sans', subsets: ['korean', 'latin'], weights: [300, 400, 500, 600, 700, 800]),
      _row('inter', 'Inter', subsets: ['cyrillic', 'cyrillic-ext', 'greek', 'greek-ext', 'latin', 'latin-ext', 'vietnamese'], weights: [100, 200, 300, 400, 500, 600, 700, 800, 900]),
      _row('lobster', 'Lobster', category: 'display', subsets: ['cyrillic', 'latin'], weights: [400]),
      _row('noto-sans-jp', 'Noto Sans JP', subsets: ['cyrillic', 'japanese', 'latin', 'latin-ext', 'vietnamese'], weights: [100, 400, 700, 900]),
      _row('fragment-mono', 'Fragment Mono', category: 'monospace', subsets: ['latin'], weights: [400], license: 'mit'),
      _row('ubuntu', 'Ubuntu', subsets: ['cyrillic', 'latin'], weights: [400, 700], license: 'UFL-1.0'),
      // Hidden: icons, other, color emoji, an unknown licence, no upright style.
      _row('material-symbols-outlined', 'Material Symbols Outlined', category: 'icons', subsets: ['latin'], weights: [400], license: 'Apache-2.0'),
      _row('some-symbols', 'Some Symbols', category: 'other', subsets: ['latin'], weights: [400]),
      _row('noto-color-emoji', 'Noto Color Emoji', subsets: ['emoji'], weights: [400]),
      _row('noto-emoji', 'Noto Emoji', subsets: ['emoji'], weights: [400]),
      _row('proprietary-sans', 'Proprietary Sans', subsets: ['latin'], weights: [400], license: 'ITF-FFL'),
      _row('leaning-only', 'Leaning Only', subsets: ['latin'], weights: [400], styles: ['italic']),
      {'id': '../../evil', 'family': 'Evil', 'subsets': ['latin'], 'weights': [400], 'styles': ['normal'], 'category': 'serif', 'license': 'OFL-1.1', 'defSubset': 'latin'},
      {'not': 'a row'},
    ];

Map<String, dynamic> _row(String id, String family,
        {String category = 'sans-serif', required List<String> subsets, required List<int> weights, String license = 'OFL-1.1', List<String> styles = const ['normal']}) =>
    {
      'id': id,
      'family': family,
      'subsets': subsets,
      'weights': weights,
      'styles': styles,
      'defSubset': subsets.contains('latin') ? 'latin' : subsets.first,
      'variable': false,
      'lastModified': '2025-06-02',
      'category': category,
      'license': license,
      'type': 'google',
    };

/// What `/v1/fonts/<id>` answers. [numbered] adds that many numbered slices to
/// each weight, as CJK families have. The URLs in it are deliberately not the
/// ones NEFORUM may use: it builds its own, pinned ones.
Map<String, dynamic> fontDetailFixture(String id, String family,
    {String version = '5.3.0', String license = 'OFL-1.1', String category = 'sans-serif', String defSubset = 'latin', required Map<int, List<String>> variants, int numbered = 0}) {
  Map<String, dynamic> file(String name) => {
        'url': {'woff2': 'https://evil.example/$name.woff2', 'woff': 'https://evil.example/$name.woff', 'ttf': 'https://evil.example/$name.ttf'},
      };
  return {
    'id': id,
    'family': family,
    'subsets': {for (final s in variants.values) ...s}.toList(),
    'weights': variants.keys.toList(),
    'styles': ['normal'],
    'defSubset': defSubset,
    'variable': false,
    'lastModified': '2025-06-02',
    'category': category,
    'license': license,
    'type': 'google',
    'version': 'v20',
    'source': 'https://github.com/google/fonts',
    'npmVersion': version,
    'unicodeRange': {},
    'variants': {
      for (final v in variants.entries)
        '${v.key}': {
          'normal': {
            for (final s in v.value) s: file('$s-${v.key}'),
            for (var i = 0; i < numbered; i++) '$i': file('$i-${v.key}'),
          },
        },
    },
  };
}

const String kLicenseFixture = 'Copyright 2020 The Authors\nThis Font Software is licensed under the SIL Open Font License, Version 1.1.\n';

/// A fake of both font services, on a [MockClient]. Records every request, so
/// a test can say exactly what went out.
class FakeFontServices {
  FakeFontServices();

  final List<http.BaseRequest> requests = [];

  /// Path after `/v1/fonts/` -> JSON.
  final Map<String, Object?> details = {};

  /// `id@version/file` -> bytes; `id@latest/file` too, for previews.
  final Map<String, Uint8List> files = {};

  /// `id@version` -> licence text; a missing one answers 404.
  final Map<String, String> licenses = {};

  /// `id@version/file` -> the `etag` header its HEAD answers.
  final Map<String, String> etags = {};

  Object? list = fontListFixture();

  /// Every call fails, as with no network.
  bool offline = false;

  /// Every list call answers this status.
  int? listStatus;

  void addFont(String id, String version, Map<String, Uint8List> byFile, {String license = kLicenseFixture}) {
    byFile.forEach((name, bytes) => files['$id@$version/$name'] = bytes);
    licenses['$id@$version'] = license;
  }

  List<String> get paths => [for (final r in requests) r.url.path];

  http.Client get client => MockClient((request) async {
        requests.add(request);
        if (offline) throw http.ClientException('Failed host lookup', request.url);
        final path = request.url.path;
        if (path == '/v1/fonts') {
          if (listStatus != null) return http.Response('nope', listStatus!);
          return http.Response.bytes(utf8.encode(jsonEncode(list)), 200, headers: {'content-type': 'application/json'});
        }
        if (path.startsWith('/v1/fonts/')) {
          final detail = details[path.substring('/v1/fonts/'.length)];
          return detail == null ? http.Response('{}', 404) : http.Response.bytes(utf8.encode(jsonEncode(detail)), 200);
        }
        if (path.startsWith('/fontsource/fonts/')) {
          final key = path.substring('/fontsource/fonts/'.length);
          final bytes = files[key];
          if (bytes == null) return http.Response('not here', 404);
          if (request.method == 'HEAD') return http.Response('', 200, headers: {if (etags[key] != null) 'etag': etags[key]!});
          return http.Response.bytes(bytes, 200);
        }
        if (path.startsWith('/npm/@fontsource/') && path.endsWith('/LICENSE')) {
          final key = path.substring('/npm/@fontsource/'.length, path.length - '/LICENSE'.length);
          final text = licenses[key];
          return text == null ? http.Response('not here', 404) : http.Response.bytes(utf8.encode(text), 200);
        }
        return http.Response('unknown address', 500);
      });
}
