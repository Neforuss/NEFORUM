import 'dart:typed_data';

bool backgroundImagesSupported(String? dataDir) => false;

Future<String?> saveBackgroundImage(String? dataDir, Uint8List bytes, String extension) async => null;

Future<Uint8List?> readBackgroundImage(String path) async => null;

Future<void> deleteBackgroundImage(String? dataDir, String path) async {}
