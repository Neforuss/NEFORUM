import 'dart:typed_data';

import 'file_export_web.dart' if (dart.library.io) 'file_export_io.dart' as impl;

/// One file to hand to the user.
class ExportFile {
  const ExportFile(this.name, this.bytes, {this.mimeType});
  final String name;
  final Uint8List bytes;
  final String? mimeType;
}

/// Where exported files ended up.
class ExportResult {
  const ExportResult({required this.location, required this.paths, required this.shown});

  /// Folder (desktop) or a short description ("Downloads", "share sheet").
  final String location;

  /// Full paths of the written files (empty when nothing was written, e.g.
  /// the share sheet on phones).
  final List<String> paths;

  /// The file manager was opened on them.
  final bool shown;
}

/// Puts files where people can find them, instead of NEFORUM's private
/// media folder (whose file names are random ids):
///
/// * Windows, macOS, Linux: `Downloads/NEFORUM/<folder>/` with readable
///   names, then the folder opens with the files selected.
/// * Android, iOS: the share sheet (Save to Photos / Files, or straight
///   into an app).
/// * Web: ordinary browser downloads.
abstract final class FileExport {
  /// Saves [files] into a folder named [folder] and reveals them.
  static Future<ExportResult> save(String folder, List<ExportFile> files, {Object? shareOrigin}) =>
      impl.saveFiles(safeName(folder), [for (final f in files) ExportFile(safeName(f.name), f.bytes, mimeType: f.mimeType)], shareOrigin: shareOrigin);

  /// Opens the file manager with [path] selected (desktop only).
  static Future<bool> reveal(String path) => impl.reveal(path);

  /// A file or folder name every OS accepts: no reserved characters, no
  /// trailing dots or spaces, at most 80 characters before the extension.
  static String safeName(String name) {
    var s = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final dot = s.lastIndexOf('.');
    final ext = dot > 0 && s.length - dot >= 2 && s.length - dot <= 6 ? s.substring(dot) : '';
    var stem = ext.isEmpty ? s : s.substring(0, dot);
    if (stem.length > 80) stem = stem.substring(0, 80).trim();
    stem = stem.replaceAll(RegExp(r'[. ]+$'), '');
    if (stem.isEmpty) stem = 'NEFORUM';
    return '$stem$ext';
  }
}
