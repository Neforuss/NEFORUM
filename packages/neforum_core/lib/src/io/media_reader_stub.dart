import 'dart:typed_data';

/// Web has no file paths; the app must supply `readMedia` to AdapterContext.
Future<Uint8List> readMediaFromPath(String path) async =>
    throw UnsupportedError('Reading media from a path is not supported on this platform; provide readMedia to AdapterContext');
