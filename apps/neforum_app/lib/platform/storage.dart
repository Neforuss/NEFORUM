import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'storage_web.dart' if (dart.library.io) 'storage_io.dart' as impl;

/// Local, app-private storage for small JSON documents and media files.
///
/// Native: files under the OS application-support directory.
/// Web (preview builds): memory only.
abstract class AppStorage {
  /// Directory holding NEFORUM's data, or null on web.
  String? get dataDir;

  Future<Map<String, dynamic>?> readJson(String name);
  Future<void> writeJson(String name, Object data);

  /// Copies [bytes] into the media library and returns the path to store on
  /// the [MediaAttachment].
  Future<String> saveMedia(String id, String extension, Uint8List bytes);

  /// Reads a media file saved with [saveMedia] (or any absolute path).
  Future<Uint8List> readMedia(String path);
  Future<void> deleteMedia(String path);

  /// Total bytes used by the media library.
  Future<int> mediaBytes();

  /// An image widget for a stored media path.
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth});
}

Future<AppStorage> openAppStorage({String? overrideDir}) => impl.openAppStorage(overrideDir: overrideDir);
