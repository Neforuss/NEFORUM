import 'package:flutter/services.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// A folder picked in the Files app on an iPhone or iPad.
typedef PickedFolder = ({String bookmark, String name, String path});

/// iPhone and iPad: the sync file in a Files-app location (iCloud Drive, or a
/// cloud app such as OneDrive, Google Drive or Dropbox). iOS has no folders a
/// cloud app syncs in the background the way a computer does; instead each
/// cloud app offers a location in the Files app. NEFORUM keeps access to the
/// picked folder with a bookmark and reads and writes the file through
/// NSFileCoordinator, so iCloud or the cloud app fetches the newest file and
/// uploads the new one (ios/Runner/AppDelegate.swift, SyncFolderPlugin).
abstract final class FilesAppFolder {
  static const MethodChannel channel = MethodChannel('neforum/syncfolder');

  /// Opens the Files picker for a folder; `null` when the user cancelled.
  static Future<PickedFolder?> pick() async {
    final r = await channel.invokeMapMethod<String, Object?>('pick');
    if (r == null) return null;
    return (bookmark: '${r['bookmark']}', name: '${r['name'] ?? ''}', path: '${r['path'] ?? ''}');
  }
}

class FilesAppSyncBackend extends SyncBackend {
  FilesAppSyncBackend(this.bookmark, {required this.folderName, this.fileName = kSyncFileName, MethodChannel? channel})
      : _channel = channel ?? FilesAppFolder.channel;

  /// From [FilesAppFolder.pick].
  final String bookmark;
  final String folderName;
  final String fileName;
  final MethodChannel _channel;

  @override
  String get label => folderName;

  /// The cloud app uploads later; two devices can still collide, which the
  /// conflict copies and the next merge take care of.
  @override
  bool get atomicWrites => false;

  Future<T?> _call<T>(String method, [Map<String, Object?> args = const {}]) async {
    try {
      return await _channel.invokeMethod<T>(method, {'bookmark': bookmark, ...args});
    } on PlatformException catch (e) {
      if (e.code == 'conflict') throw const SyncConflict();
      if (e.code == 'bookmark') throw SyncBackendException(e.message ?? 'Choose the folder again in Settings > Sync.');
      throw SyncBackendException('Could not use the folder "$folderName": ${e.message ?? e.code}', temporary: true);
    } on MissingPluginException {
      throw const SyncBackendException('This version of NEFORUM cannot use Files app folders.');
    }
  }

  Future<SyncBlob?> _read(String name) async {
    final r = await _call<Map<Object?, Object?>>('read', {'name': name});
    if (r == null) return null;
    final bytes = r['bytes'];
    if (bytes is! Uint8List) return null;
    return SyncBlob(bytes, '${r['version'] ?? ''}');
  }

  @override
  Future<SyncBlob?> read() => _read(fileName);

  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) =>
      _call<String>('write', {'name': fileName, 'bytes': bytes, 'ifMatch': ifMatch});

  @override
  Future<List<SyncSideCopy>> conflictCopies() async {
    final names = await _call<List<Object?>>('list') ?? const [];
    final out = <SyncSideCopy>[];
    for (final n in names.whereType<String>()) {
      if (!isSyncConflictCopyName(n, fileName: fileName)) continue;
      try {
        final blob = await _read(n);
        if (blob != null) out.add(SyncSideCopy(n, blob.bytes));
      } on SyncBackendException {
        // Not downloaded yet: next time.
      }
    }
    return out;
  }

  @override
  Future<void> removeConflictCopy(SyncSideCopy copy) async {
    if (!isSyncConflictCopyName(copy.name, fileName: fileName)) return;
    try {
      await _call<void>('delete', {'name': copy.name});
    } on SyncBackendException {
      // Next time.
    }
  }

  @override
  Future<void> check() async {
    final probe = '.$fileName.check';
    await _call<String>('write', {'name': probe, 'bytes': Uint8List.fromList(const [0x4E]), 'force': true});
    await _call<void>('delete', {'name': probe});
  }
}
