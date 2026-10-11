import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'storage.dart';

/// Web preview: everything stays in memory for the tab's lifetime.
Future<AppStorage> openAppStorage({String? overrideDir}) async => _MemoryStorage();

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  final Map<String, Uint8List> _media = {};

  @override
  String? get dataDir => null;

  @override
  Future<Map<String, dynamic>?> readJson(String name) async {
    final v = _json[name];
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;

  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async {
    final path = 'mem://$id.$extension';
    _media[path] = bytes;
    return path;
  }

  @override
  Future<Uint8List> readMedia(String path) async {
    final b = _media[path];
    if (b == null) throw StateError('Media not found: $path');
    return b;
  }

  @override
  Future<void> deleteMedia(String path) async => _media.remove(path);

  @override
  Future<int> mediaBytes() async => _media.values.fold<int>(0, (s, b) => s + b.length);

  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) {
    final b = _media[path];
    if (b == null) return const SizedBox.shrink();
    return Image.memory(b, fit: fit, width: width, height: height, cacheWidth: cacheWidth, gaplessPlayback: true);
  }
}
