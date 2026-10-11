import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'file_export.dart';

Future<ExportResult> saveFiles(String folder, List<ExportFile> files, {Object? shareOrigin}) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final tmp = await getTemporaryDirectory();
    final dir = await Directory(p.join(tmp.path, 'neforum-share', folder)).create(recursive: true);
    final xs = <XFile>[];
    for (final f in files) {
      final file = File(p.join(dir.path, f.name));
      await file.writeAsBytes(f.bytes, flush: true);
      xs.add(XFile(file.path, mimeType: f.mimeType, name: f.name));
    }
    await SharePlus.instance.share(ShareParams(files: xs, sharePositionOrigin: shareOrigin is Rect ? shareOrigin : null));
    return const ExportResult(location: 'the share sheet', paths: [], shown: true);
  }

  final downloads = await _downloads();
  final dir = await Directory(p.join(downloads.path, 'NEFORUM', folder)).create(recursive: true);
  final paths = <String>[];
  for (final f in files) {
    final target = await _unique(p.join(dir.path, f.name));
    await File(target).writeAsBytes(f.bytes, flush: true);
    paths.add(target);
  }
  final shown = paths.isNotEmpty && await reveal(paths.first);
  return ExportResult(location: dir.path, paths: paths, shown: shown);
}

/// Downloads when the OS has one, otherwise Documents, otherwise home.
Future<Directory> _downloads() async {
  try {
    final d = await getDownloadsDirectory();
    if (d != null) return d;
  } on Object catch (e) {
    debugPrint('No Downloads folder: $e');
  }
  try {
    return await getApplicationDocumentsDirectory();
  } on Object {
    return Directory(Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.systemTemp.path);
  }
}

/// `name.jpg`, then `name (2).jpg`, … so earlier exports are never
/// overwritten.
Future<String> _unique(String path) async {
  if (!await File(path).exists()) return path;
  final dir = p.dirname(path);
  final stem = p.basenameWithoutExtension(path);
  final ext = p.extension(path);
  for (var i = 2; i < 1000; i++) {
    final candidate = p.join(dir, '$stem ($i)$ext');
    if (!await File(candidate).exists()) return candidate;
  }
  return p.join(dir, '$stem ${DateTime.now().millisecondsSinceEpoch}$ext');
}

/// Shows [path] in Explorer / Finder with the file selected (Linux opens
/// the folder). Uses the OS tools directly: a `file:` URL with spaces or a
/// long AppData path is exactly what failed before.
Future<bool> reveal(String path) async {
  try {
    if (Platform.isWindows) {
      // explorer.exe returns 1 even on success, so only failure to start counts.
      await Process.start('explorer.exe', ['/select,', p.normalize(path)]);
      return true;
    }
    if (Platform.isMacOS) {
      final r = await Process.run('open', ['-R', path]);
      return r.exitCode == 0;
    }
    if (Platform.isLinux) {
      final target = await FileSystemEntity.isDirectory(path) ? path : p.dirname(path);
      final r = await Process.run('xdg-open', [target]);
      return r.exitCode == 0;
    }
  } on Object catch (e) {
    debugPrint('Could not open the file manager: $e');
  }
  return false;
}
