import 'storage_maintenance_web.dart' if (dart.library.io) 'storage_maintenance_io.dart' as impl;

/// A file found in NEFORUM's own folders, with its last change.
typedef StoredFile = ({String path, DateTime modified});

/// Every file in the media folder under [dataDir] (none on web).
Future<List<StoredFile>> listMediaFiles(String? dataDir) => impl.listMediaFiles(dataDir);

/// Deletes the copies made for the share sheet on phones (the system
/// temporary folder's `neforum-share`) that are older than [maxAge], and
/// the folders that leaves empty. [temporaryDir] replaces the system
/// folder in tests. Returns how many files were deleted.
Future<int> deleteExpiredShareExports({Duration maxAge = const Duration(days: 1), DateTime? now, String? temporaryDir}) =>
    impl.deleteExpiredShareExports(maxAge: maxAge, now: now, temporaryDir: temporaryDir);
