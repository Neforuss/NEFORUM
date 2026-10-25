import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'storage.dart';

Future<AppStorage> openAppStorage({String? overrideDir}) async {
  final base = overrideDir ?? (await getApplicationSupportDirectory()).path;
  final dir = Directory(p.join(base, 'neforum'));
  await Directory(p.join(dir.path, 'media')).create(recursive: true);
  return _IoStorage(dir.path);
}

class _IoStorage implements AppStorage {
  _IoStorage(this.dataDir);

  @override
  final String dataDir;

  String get _mediaDir => p.join(dataDir, 'media');

  @override
  Future<Map<String, dynamic>?> readJson(String name) async {
    final f = File(p.join(dataDir, name));
    if (!await f.exists()) return null;
    try {
      final decoded = jsonDecode(await f.readAsString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  /// The latest write of each file. Writes of one file wait for each other:
  /// they share its .tmp file, and quick changes (holding Ctrl + to zoom)
  /// would otherwise write it at the same time.
  final _writes = <String, Future<void>>{};

  @override
  Future<void> writeJson(String name, Object data) {
    final json = const JsonEncoder.withIndent('  ').convert(data);
    final write = (_writes[name] ?? Future<void>.value()).then((_) {}, onError: (Object _) {}).then((_) => _writeNow(name, json));
    _writes[name] = write;
    write.then((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_writes[name], write)) _writes.remove(name);
    });
    return write;
  }

  /// Antivirus, backup and sync tools can hold the file for a moment; try
  /// again for about 20 seconds before giving up, as the core's JSON files
  /// do.
  Future<void> _writeNow(String name, String json) async {
    final target = File(p.join(dataDir, name));
    final tmp = File('${target.path}.tmp');
    for (var attempt = 0;; attempt++) {
      try {
        await tmp.writeAsString(json, flush: true);
        await tmp.rename(target.path);
        return;
      } on FileSystemException {
        if (attempt >= _writeAttempts - 1) rethrow;
        await Future<void>.delayed(Duration(milliseconds: math.min(2000, 100 * (attempt + 1))));
      }
    }
  }

  static const _writeAttempts = 20;

  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async {
    final ext = extension.startsWith('.') ? extension : '.$extension';
    final f = File(p.join(_mediaDir, '$id$ext'));
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  @override
  Future<Uint8List> readMedia(String path) => File(path).readAsBytes();

  @override
  Future<void> deleteMedia(String path) async {
    // Only ever delete files inside our own media library.
    if (!p.isWithin(_mediaDir, path)) return;
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<int> mediaBytes() async {
    var total = 0;
    final d = Directory(_mediaDir);
    if (!await d.exists()) return 0;
    await for (final e in d.list()) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => Image.file(
        File(path),
        fit: fit,
        width: width,
        height: height,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
}
