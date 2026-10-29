import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

String _folder(String dataDir) => p.join(dataDir, 'appearance');

bool backgroundImagesSupported(String? dataDir) => dataDir != null;

Future<String?> saveBackgroundImage(String? dataDir, Uint8List bytes, String extension) async {
  if (dataDir == null) return null;
  final folder = Directory(_folder(dataDir));
  await folder.create(recursive: true);
  final ext = extension.startsWith('.') ? extension.substring(1) : extension;
  final file = File(p.join(folder.path, 'background-${DateTime.now().microsecondsSinceEpoch}.${ext.toLowerCase()}'));
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

Future<Uint8List?> readBackgroundImage(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  return file.readAsBytes();
}

Future<void> deleteBackgroundImage(String? dataDir, String path) async {
  if (dataDir == null || !p.isWithin(_folder(dataDir), path)) return;
  final file = File(path);
  if (await file.exists()) await file.delete();
}
