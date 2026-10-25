import 'storage_maintenance.dart';

/// Web preview: media lives in memory and nothing is exported to a folder.
Future<List<StoredFile>> listMediaFiles(String? dataDir) async => const [];

Future<int> deleteExpiredShareExports({required Duration maxAge, DateTime? now, String? temporaryDir}) async => 0;
