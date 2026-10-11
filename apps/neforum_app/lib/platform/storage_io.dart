import 'dart:convert';
import 'dart:io';
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

  @override
  Future<void> writeJson(String name, Object data) async {
    final target = File(p.join(dataDir, name));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data), flush: true);
    await tmp.rename(target.path);
  }

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
