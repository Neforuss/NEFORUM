String? newMediaFilePath(String? dataDir, String id, String extension) => null;

Future<int> mediaFileLength(String path) async => 0;

void writeMediaFileSync(String path, List<int> bytes) => throw UnsupportedError('No files on the web');

Future<void> deleteMediaFile(String path) async {}
