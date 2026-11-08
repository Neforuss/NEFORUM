import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'font_catalog.dart' show kFontCatalogFile;
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

/// The imported fonts: (file id, path). Only the folder's own files: the
/// subfolder of downloaded fonts ([catalogFontsDirectory]) is not imported fonts.
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

// ---------------------------------------------------------------------------
// Downloaded fonts (1.4): fonts/catalog/<id>@<version>/ with the font files,
// the licence text and manifest.json. Everything a download leaves anywhere is
// listed in deleteFontDownloadData.
// ---------------------------------------------------------------------------

/// The folder downloaded fonts are kept in.
String? catalogFontsDirectory(String? dataDir) => dataDir == null ? null : p.join(dataDir, 'fonts', 'catalog');

/// The small files the picker's rows are drawn in, newest use last.
String? fontPreviewsDirectory(String? dataDir) => dataDir == null ? null : p.join(dataDir, 'font-previews');

/// What the previews may take on disk; the least recently used go first.
const int kFontPreviewCacheBytes = 20 * 1024 * 1024;

const String _stagingPrefix = '.staging-';

/// A folder or file name from a manifest, or null when it is anything else.
String? _plainName(String name) => name.isEmpty || p.basename(name) != name || name.startsWith('.') ? null : name;

/// The raw `manifest.json` of every downloaded font. A folder without a
/// readable one, or a download that never finished, is left out.
Future<List<Object?>> readCatalogManifests(String? dataDir) async {
  final dir = catalogFontsDirectory(dataDir);
  if (dir == null) return const [];
  final out = <Object?>[];
  try {
    final d = Directory(dir);
    if (!await d.exists()) return const [];
    await for (final e in d.list(followLinks: false)) {
      if (e is! Directory || p.basename(e.path).startsWith('.')) continue;
      try {
        out.add(jsonDecode(await File(p.join(e.path, 'manifest.json')).readAsString()));
      } on Object {
        // A folder without a readable manifest is not a font.
      }
    }
  } on Object {
    // The folder cannot be read: no downloaded fonts.
  }
  return out;
}

/// Keeps a downloaded font as `fonts/catalog/<folder>`, all at once: it is
/// written to a staging folder and renamed, so a crash leaves either nothing
/// or a whole font. [replacing] names older versions of it, removed afterwards.
Future<void> saveCatalogFont(String? dataDir, String folder, Map<String, Uint8List> files, {Iterable<String> replacing = const []}) async {
  final dir = catalogFontsDirectory(dataDir);
  final name = _plainName(folder);
  if (dir == null || name == null) throw ArgumentError('No place for the font $folder');
  final root = Directory(dir);
  await root.create(recursive: true);
  await _removeOldStaging(root);
  final staging = Directory(p.join(dir, '$_stagingPrefix${DateTime.now().microsecondsSinceEpoch}'));
  await staging.create();
  try {
    for (final e in files.entries) {
      final file = _plainName(e.key);
      if (file == null) throw ArgumentError('Not a file name: ${e.key}');
      await File(p.join(staging.path, file)).writeAsBytes(e.value, flush: true);
    }
    final target = Directory(p.join(dir, name));
    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);
  } on Object {
    try {
      await staging.delete(recursive: true);
    } on Object {
      // Removed by the next download.
    }
    rethrow;
  }
  for (final old in replacing) {
    if (old != name) await deleteCatalogFont(dataDir, old);
  }
}

/// A staging folder more than an hour old is a download that died.
Future<void> _removeOldStaging(Directory root) async {
  final limit = DateTime.now().subtract(const Duration(hours: 1));
  await for (final e in root.list(followLinks: false)) {
    if (e is! Directory || !p.basename(e.path).startsWith(_stagingPrefix)) continue;
    try {
      if ((await e.stat()).modified.isBefore(limit)) await e.delete(recursive: true);
    } on Object {
      // Tried again next time.
    }
  }
}

/// Adds font files to a downloaded font. The manifest is replaced last, by a
/// rename, so until then the font stays as it was and the new files are ignored.
Future<void> addCatalogFontFiles(String? dataDir, String folder, Map<String, Uint8List> files, Uint8List manifest) async {
  final dir = catalogFontsDirectory(dataDir);
  final name = _plainName(folder);
  if (dir == null || name == null) throw ArgumentError('No place for the font $folder');
  final target = p.join(dir, name);
  for (final e in files.entries) {
    final file = _plainName(e.key);
    if (file == null) throw ArgumentError('Not a file name: ${e.key}');
    await File(p.join(target, file)).writeAsBytes(e.value, flush: true);
  }
  final next = File(p.join(target, '.manifest-next'));
  await next.writeAsBytes(manifest, flush: true);
  await next.rename(p.join(target, 'manifest.json'));
}

/// What [readCatalogFontFile] needs, sent to an isolate.
class _CatalogFileRequest {
  const _CatalogFileRequest(this.path, this.sha256);
  final String path;
  final String sha256;
}

Uint8List? _readVerified(_CatalogFileRequest r) {
  try {
    final bytes = File(r.path).readAsBytesSync();
    if (sha256.convert(bytes).toString() != r.sha256) return null;
    return bytes;
  } on Object {
    return null;
  }
}

/// A downloaded font's file, off the UI isolate; null when it is gone or is
/// no longer the file that was checked when it was downloaded.
Future<Uint8List?> readCatalogFontFile(String? dataDir, String folder, String file, String sha256) async {
  final dir = catalogFontsDirectory(dataDir);
  final folderName = _plainName(folder), fileName = _plainName(file);
  if (dir == null || folderName == null || fileName == null) return null;
  final request = _CatalogFileRequest(p.join(dir, folderName, fileName), sha256);
  return Isolate.run(() => _readVerified(request));
}

/// The licence text kept with a downloaded font; null when it cannot be read.
Future<String?> readCatalogFontLicense(String? dataDir, String folder) async {
  final dir = catalogFontsDirectory(dataDir);
  final name = _plainName(folder);
  if (dir == null || name == null) return null;
  try {
    return utf8.decode(await File(p.join(dir, name, 'LICENSE')).readAsBytes(), allowMalformed: true);
  } on Object {
    return null;
  }
}

/// Removes one downloaded font.
Future<void> deleteCatalogFont(String? dataDir, String folder) async {
  final dir = catalogFontsDirectory(dataDir);
  final name = _plainName(folder);
  if (dir == null || name == null) return;
  final d = Directory(p.join(dir, name));
  if (await d.exists()) await d.delete(recursive: true);
}

/// Removes everything font downloads ever left in the data folder: the fonts
/// with their licences, the saved list and the previews. Imported fonts stay:
/// they are the user's own files.
Future<void> deleteFontDownloadData(String? dataDir) async {
  if (dataDir == null) return;
  for (final dir in [catalogFontsDirectory(dataDir), fontPreviewsDirectory(dataDir)]) {
    final d = Directory(dir!);
    if (await d.exists()) await d.delete(recursive: true);
  }
  final list = File(p.join(dataDir, kFontCatalogFile));
  if (await list.exists()) await list.delete();
}

/// The saved preview of family [id], marked as just used; null when there is none.
Future<Uint8List?> readFontPreview(String? dataDir, String id) async {
  final dir = fontPreviewsDirectory(dataDir);
  final name = _plainName('$id.ttf');
  if (dir == null || name == null) return null;
  final file = File(p.join(dir, name));
  try {
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    await file.setLastModified(DateTime.now());
    return bytes;
  } on Object {
    return null;
  }
}

/// Keeps the preview of family [id], then removes the least recently used
/// ones until the folder fits [kFontPreviewCacheBytes].
Future<void> saveFontPreview(String? dataDir, String id, Uint8List bytes, {int maxBytes = kFontPreviewCacheBytes}) async {
  final dir = fontPreviewsDirectory(dataDir);
  final name = _plainName('$id.ttf');
  if (dir == null || name == null) return;
  final d = Directory(dir);
  await d.create(recursive: true);
  await File(p.join(dir, name)).writeAsBytes(bytes, flush: true);
  final saved = <(File, DateTime, int)>[];
  await for (final e in d.list(followLinks: false)) {
    if (e is! File) continue;
    final stat = await e.stat();
    saved.add((e, stat.modified, stat.size));
  }
  saved.sort((a, b) => a.$2.compareTo(b.$2));
  var total = saved.fold<int>(0, (a, f) => a + f.$3);
  for (final (file, _, size) in saved) {
    if (total <= maxBytes) break;
    if (p.basename(file.path) == name) continue;
    await file.delete();
    total -= size;
  }
}

String _sha256Of(Uint8List bytes) => sha256.convert(bytes).toString();

/// The SHA-256 of a font file, lowercase hex, off the UI isolate.
Future<String> sha256OfFontFile(Uint8List bytes) => Isolate.run(() => _sha256Of(bytes));
