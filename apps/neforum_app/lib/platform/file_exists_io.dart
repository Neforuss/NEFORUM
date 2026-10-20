import 'dart:io';

Future<bool> filesExist(Iterable<String> paths) async {
  for (final p in paths) {
    if (!await File(p).exists()) return false;
  }
  return true;
}
