import 'dart:io';

import 'package:path/path.dart' as p;

String? newMediaFilePath(String? dataDir, String id, String extension) {
  if (dataDir == null) return null;
  final ext = extension.startsWith('.') ? extension : '.$extension';
  return p.join(dataDir, 'media', '$id$ext');
}

Future<int> mediaFileLength(String path) async {
  try {
    return await File(path).length();
  } on FileSystemException {
    return 0;
  }
}
