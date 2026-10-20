import 'dart:math';
import 'dart:typed_data';

import 'sync_backend.dart';

/// Web stand-in: browsers have no synced folders.
class FolderSyncBackend extends SyncBackend {
  FolderSyncBackend(this.folder, {this.fileName = kSyncFileName, Random? random});

  final String folder;
  final String fileName;

  static const _unsupported = SyncBackendException('Folder sync needs the desktop app.');

  @override
  String get label => folder;

  @override
  bool get atomicWrites => false;

  bool isConflictCopyName(String name) => false;

  @override
  Future<SyncBlob?> read() async => throw _unsupported;

  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) async => throw _unsupported;

  @override
  Future<void> check() async => throw _unsupported;
}
