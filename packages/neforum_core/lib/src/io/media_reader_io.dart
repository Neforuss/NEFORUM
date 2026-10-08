import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readMediaFromPath(String path) => File(path).readAsBytes();
