import 'dart:typed_data';

import 'font_files.dart';

// Web preview builds have no font files: no installed fonts, no imports.

List<String> installedFontDirectories() => const [];

class FontScanJob {
  const FontScanJob({required this.directories, this.previous = const {}});
  final List<String> directories;
  final Map<String, Map<String, dynamic>> previous;
}

List<Map<String, dynamic>> scanFontDirectories(FontScanJob job) => const [];

Future<List<Map<String, dynamic>>> scanInstalledFonts(FontScanJob job) async => const [];

Future<List<FontFace>> readFontFacesOfFile(String path) async => const [];

Future<Uint8List?> readFontFaceBytes(String path, int index) async => null;

Future<bool> fontFileExists(String path) async => false;

String? importedFontsDirectory(String? dataDir) => null;

String? importedFontPath(String? dataDir, String fileId) => null;

Future<String?> saveImportedFont(String? dataDir, String fileId, Uint8List bytes) async => null;

Future<List<(String, String)>> listImportedFonts(String? dataDir) async => const [];
