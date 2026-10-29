import 'media_files_web.dart' if (dart.library.io) 'media_files_io.dart' as impl;

/// Path of a new file in the media folder under [dataDir], for media written
/// by native code (the video compositor) instead of from bytes in memory.
/// Null without a data folder (web).
String? newMediaFilePath(String? dataDir, String id, String extension) => impl.newMediaFilePath(dataDir, id, extension);

/// Size in bytes of the file at [path]; 0 when it cannot be read.
Future<int> mediaFileLength(String path) => impl.mediaFileLength(path);

/// Deletes the file at [path] if there is one (a copy native code left
/// unfinished or over its limit).
Future<void> deleteMediaFile(String path) => impl.deleteMediaFile(path);
