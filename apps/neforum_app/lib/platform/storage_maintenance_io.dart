import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'storage_maintenance.dart';

/// The folder file_export_io.dart writes share-sheet copies to.
const _shareExportFolder = 'neforum-share';

Future<List<StoredFile>> listMediaFiles(String? dataDir) async {
  if (dataDir == null) return const [];
  final dir = Directory(p.join(dataDir, 'media'));
  if (!await dir.exists()) return const [];
  final out = <StoredFile>[];
  await for (final e in dir.list(followLinks: false)) {
    if (e is! File) continue;
    try {
      out.add((path: e.path, modified: await e.lastModified()));
    } on FileSystemException {
      // Gone or locked meanwhile: leave it for the next sweep.
    }
  }
  return out;
}

Future<int> deleteExpiredShareExports({required Duration maxAge, DateTime? now, String? temporaryDir}) async {
  final base = temporaryDir ?? (await getTemporaryDirectory()).path;
  final dir = Directory(p.join(base, _shareExportFolder));
  if (!await dir.exists()) return 0;
  final cutoff = (now ?? DateTime.now()).subtract(maxAge);
  final entries = await dir.list(recursive: true, followLinks: false).toList();
  var deleted = 0;
  for (final f in entries.whereType<File>()) {
    try {
      if ((await f.lastModified()).isBefore(cutoff)) {
        await f.delete();
        deleted++;
      }
    } on FileSystemException {
      // Still open in the app it was shared to: try again next time.
    }
  }
  // Deepest folders first, so a parent can go once its children are gone.
  final folders = entries.whereType<Directory>().toList()..sort((a, b) => b.path.length.compareTo(a.path.length));
  for (final d in folders) {
    try {
      if (await d.list().isEmpty) await d.delete();
    } on FileSystemException {
      // Not empty or in use.
    }
  }
  return deleted;
}
