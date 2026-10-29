import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'font_files.dart';

/// The folders this device keeps installed fonts in: the system's and the
/// user's own. Android and iOS give apps no list of their fonts, so there
/// fonts are imported ([saveImportedFont]).
List<String> installedFontDirectories() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final windows = env['WINDIR'] ?? env['SystemRoot'] ?? r'C:\Windows';
    final local = env['LOCALAPPDATA'];
    return [p.join(windows, 'Fonts'), if (local != null) p.join(local, 'Microsoft', 'Windows', 'Fonts')];
  }
  final home = env['HOME'];
  if (Platform.isMacOS) {
    return ['/System/Library/Fonts', '/Library/Fonts', if (home != null) p.join(home, 'Library', 'Fonts')];
  }
  if (Platform.isLinux) {
    return [if (home != null) p.join(home, '.local', 'share', 'fonts'), '/usr/share/fonts', '/usr/local/share/fonts'];
  }
  return const [];
}

/// What [scanFontDirectories] needs, sent to an isolate: plain data only.
class FontScanJob {
  const FontScanJob({required this.directories, this.previous = const {}});
  final List<String> directories;

  /// The last scan's entries by path ([scanFontDirectories]); a file whose
  /// size and time are unchanged is not read again.
  final Map<String, Map<String, dynamic>> previous;
}

/// Most font files looked at in one scan.
const int _maxFontFiles = 20000;

/// Every font file under [FontScanJob.directories] (subfolders included) as
/// `{path, size, modified, faces}`, with [faces] from [readFontFaces]. Files
/// that are not fonts, or cannot be read, have no faces. Synchronous: run it
/// in an isolate ([scanInstalledFonts]).
List<Map<String, dynamic>> scanFontDirectories(FontScanJob job) {
  final out = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final dir in job.directories) {
    final d = Directory(dir);
    try {
      if (!d.existsSync()) continue;
      for (final e in d.listSync(recursive: true, followLinks: false)) {
        if (out.length >= _maxFontFiles) break;
        if (e is! File || !isFontFilePath(e.path) || !seen.add(e.path)) continue;
        out.add(_entryOf(e, job.previous[e.path]));
      }
    } on Object {
      // A folder we may not read: the fonts found so far stay.
    }
  }
  return out;
}

Map<String, dynamic> _entryOf(File f, Map<String, dynamic>? previous) {
  var size = -1, modified = -1;
  try {
    final stat = f.statSync();
    size = stat.size;
    modified = stat.modified.millisecondsSinceEpoch;
  } on Object {
    return {'path': f.path, 'size': size, 'modified': modified, 'faces': const <Object>[]};
  }
  if (previous != null && previous['size'] == size && previous['modified'] == modified && previous['faces'] is List) {
    return previous;
  }
  return {
    'path': f.path,
    'size': size,
    'modified': modified,
    'faces': [for (final face in _readFacesSync(f.path)) face.toJson()],
  };
}

List<FontFace> _readFacesSync(String path) {
  RandomAccessFile? raf;
  try {
    final file = raf = File(path).openSync();
    final length = file.lengthSync();
    return readFontFaces((offset, n) {
      if (offset < 0 || n < 0 || offset + n > length) return null;
      file.setPositionSync(offset);
      final b = file.readSync(n);
      return b.length == n ? b : null;
    });
  } on Object {
    return const [];
  } finally {
    try {
      raf?.closeSync();
    } on Object {
      // Already closed.
    }
  }
}

/// [scanFontDirectories] off the UI isolate.
Future<List<Map<String, dynamic>>> scanInstalledFonts(FontScanJob job) => Isolate.run(() => scanFontDirectories(job));

/// The faces in the font file at [path], read off the UI isolate.
Future<List<FontFace>> readFontFacesOfFile(String path) => Isolate.run(() => _readFacesSync(path));

/// What [readFontFaceBytes] needs, sent to an isolate.
class _FaceRequest {
  const _FaceRequest(this.path, this.index);
  final String path;
  final int index;
}

Uint8List? _faceBytes(_FaceRequest r) {
  try {
    final bytes = File(r.path).readAsBytesSync();
    return extractFontFace(bytes, r.index);
  } on Object {
    return null;
  }
}

/// The face at [index] of the font file at [path], as a font of its own
/// ([extractFontFace]), read off the UI isolate; null when it cannot be read.
Future<Uint8List?> readFontFaceBytes(String path, int index) {
  final request = _FaceRequest(path, index);
  return Isolate.run(() => _faceBytes(request));
}

Future<bool> fontFileExists(String path) async {
  try {
    return await File(path).exists();
  } on Object {
    return false;
  }
}

/// The folder imported fonts are kept in.
String? importedFontsDirectory(String? dataDir) => dataDir == null ? null : p.join(dataDir, 'fonts');

/// Path of the imported font [fileId]; null without a data folder or for an
/// id that is not a plain file name.
String? importedFontPath(String? dataDir, String fileId) {
  final dir = importedFontsDirectory(dataDir);
  if (dir == null || fileId.isEmpty || p.basename(fileId) != fileId || fileId.startsWith('.')) return null;
  return p.join(dir, fileId);
}

/// Keeps [bytes] as the imported font [fileId]; returns its path.
Future<String?> saveImportedFont(String? dataDir, String fileId, Uint8List bytes) async {
  final path = importedFontPath(dataDir, fileId);
  if (path == null) return null;
  await Directory(p.dirname(path)).create(recursive: true);
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}

/// The imported fonts: (file id, path).
Future<List<(String, String)>> listImportedFonts(String? dataDir) async {
  final dir = importedFontsDirectory(dataDir);
  if (dir == null) return const [];
  final d = Directory(dir);
  try {
    if (!await d.exists()) return const [];
    return [
      await for (final e in d.list(followLinks: false))
        if (e is File && isFontFilePath(e.path)) (p.basename(e.path), e.path),
    ];
  } on Object {
    return const [];
  }
}
