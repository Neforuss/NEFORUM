import 'file_exists_web.dart' if (dart.library.io) 'file_exists_io.dart' as impl;

/// Whether every path in [paths] is a file on this device (a synced post's
/// photos and videos stay on the device they were added on).
Future<bool> filesExist(Iterable<String> paths) => impl.filesExist(paths);
