import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cross_file/cross_file.dart';
import 'package:mime/mime.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'storage.dart';

/// Raised when an imported file is not an image or video NEFORUM can post.
class UnsupportedMediaException implements Exception {
  const UnsupportedMediaException(this.fileName, this.mimeType);
  final String fileName;
  final String? mimeType;
  @override
  String toString() => '$fileName is not an image or video (${mimeType ?? 'unknown type'})';
}

/// Imports user files into NEFORUM's private media folder and builds
/// [MediaAttachment]s with type, size and dimensions filled in.
///
/// Media is copied so that scheduled posts still have their files even if
/// the user moves or deletes the original.
class MediaLibrary {
  MediaLibrary(this._storage);

  final AppStorage _storage;
  static const _uuid = Uuid();

  static const supportedExtensions = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'mp4', 'mov', 'm4v', 'webm'];

  Future<MediaAttachment> importXFile(XFile file) async {
    final bytes = await file.readAsBytes();
    return importBytes(bytes, fileName: file.name, mimeHint: file.mimeType);
  }

  Future<MediaAttachment> importBytes(Uint8List bytes, {required String fileName, String? mimeHint}) async {
    final header = bytes.length > 64 ? bytes.sublist(0, 64) : bytes;
    var mime = lookupMimeType(fileName, headerBytes: header) ?? mimeHint;
    if (mime == 'image/jpg') mime = 'image/jpeg';
    if (mime == null || !(mime.startsWith('image/') || mime.startsWith('video/'))) {
      throw UnsupportedMediaException(fileName, mime);
    }
    final id = _uuid.v7();
    final ext = _extensionFor(fileName, mime);
    final path = await _storage.saveMedia(id, ext, bytes);
    int? width;
    int? height;
    if (mime.startsWith('image/')) {
      final dims = await _imageSize(bytes);
      width = dims?.$1;
      height = dims?.$2;
    }
    return MediaAttachment(
      id: id,
      path: path,
      mimeType: mime,
      sizeBytes: bytes.length,
      width: width,
      height: height,
      fileName: fileName,
    );
  }

  Future<Uint8List> read(MediaAttachment media) => _storage.readMedia(media.path);

  Future<void> discard(MediaAttachment media) => _storage.deleteMedia(media.path);

  Future<int> totalBytes() => _storage.mediaBytes();

  static String _extensionFor(String fileName, String mime) {
    final fromName = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    if (fromName.isNotEmpty) return fromName;
    return extensionFromMime(mime) ?? 'bin';
  }

  /// Reads the image header only; never decodes the full bitmap.
  static Future<(int, int)?> _imageSize(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = (descriptor.width, descriptor.height);
      descriptor.dispose();
      buffer.dispose();
      return size;
    } on Object {
      return null;
    }
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
