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

// No data folder here, so no downloaded fonts either (the picker hides them).

Future<List<Object?>> readCatalogManifests(String? dataDir) async => const [];

Future<void> saveCatalogFont(String? dataDir, String folder, Map<String, Uint8List> files, {Iterable<String> replacing = const []}) async {
  throw UnsupportedError('Fonts cannot be downloaded here');
}

Future<void> addCatalogFontFiles(String? dataDir, String folder, Map<String, Uint8List> files, Uint8List manifest) async {
  throw UnsupportedError('Fonts cannot be downloaded here');
}

Future<Uint8List?> readCatalogFontFile(String? dataDir, String folder, String file, String sha256) async => null;

Future<String?> readCatalogFontLicense(String? dataDir, String folder) async => null;

Future<void> deleteCatalogFont(String? dataDir, String folder) async {}

Future<void> deleteFontDownloadData(String? dataDir) async {}

Future<Uint8List?> readFontPreview(String? dataDir, String id) async => null;

Future<void> saveFontPreview(String? dataDir, String id, Uint8List bytes) async {}

Future<String> sha256OfFontFile(Uint8List bytes) async => '';
