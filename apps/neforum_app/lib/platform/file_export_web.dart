import 'package:cross_file/cross_file.dart';

import 'file_export.dart';

/// Browsers download each file into the user's Downloads folder.
Future<ExportResult> saveFiles(String folder, List<ExportFile> files, {Object? shareOrigin}) async {
  for (final f in files) {
    await XFile.fromData(f.bytes, mimeType: f.mimeType, name: f.name).saveTo(f.name);
  }
  return const ExportResult(location: 'your Downloads folder', paths: [], shown: false);
}

Future<bool> reveal(String path) async => false;
