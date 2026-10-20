import 'package:flutter/services.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// A location picked with the system file picker: a folder, or the sync file
/// itself ([isFile]).
typedef PickedLocation = ({String bookmark, String name, bool isFile});

/// How to pick the location.
enum PickMode {
  /// A folder: NEFORUM keeps NEFORUM.neforumsync in it (and merges the
  /// copies a cloud app makes when two devices collide).
  folder,

  /// The sync file another device already made, for cloud apps that do not
  /// let other apps pick their folders (Google Drive, OneDrive, MEGA... look
  /// grayed out in the iOS folder picker) but do let them open and save a
  /// file in place.
  file,

  /// A new, empty sync file saved into such a cloud app, for the first
  /// device.
  create,
}

/// Phones and tablets: the sync file in a location of the system file picker
/// (the Files app on iPhone and iPad, Android's picker): iCloud Drive or a
/// cloud app such as OneDrive, Google Drive or Dropbox. A phone has no
/// folders a cloud app syncs in the background the way a computer does;
/// each cloud app offers its files through the picker instead. Access is
/// kept across restarts (an iOS bookmark, an Android persisted permission),
/// and on iOS reads and writes go through NSFileCoordinator so iCloud or the
/// cloud app fetches the newest file and uploads the new one
/// (ios/Runner/AppDelegate.swift and android/.../MainActivity.kt).
abstract final class FilesAppFolder {
  static const MethodChannel channel = MethodChannel('neforum/syncfolder');

  /// Opens the picker; `null` when the user cancelled.
  static Future<PickedLocation?> pick(PickMode mode) async {
    final r = await channel.invokeMapMethod<String, Object?>('pick', {'mode': mode.name});
    if (r == null) return null;
    return (bookmark: '${r['bookmark']}', name: '${r['name'] ?? ''}', isFile: r['file'] == true);
  }

  /// A .neforumsync file the user tapped in the Files app (or opened with
  /// "Open in NEFORUM") since the last call, once. `null` bookmark: iOS
  /// handed over a copy instead of the file itself, which cannot be synced.
  static Future<({String? bookmark, String name})?> takeOpened() async {
    try {
      final r = await channel.invokeMapMethod<String, Object?>('takeOpened');
      if (r == null) return null;
      final bookmark = r['bookmark'];
      return (bookmark: bookmark is String && bookmark.isNotEmpty ? bookmark : null, name: '${r['name'] ?? kSyncFileName}');
    } on MissingPluginException {
      return null;
    }
  }

  /// Calls [onOpened] whenever a sync file is opened while NEFORUM runs.
  static void listenForOpened(void Function() onOpened) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'openedAvailable') onOpened();
      return null;
    });
  }
}

class FilesAppSyncBackend extends SyncBackend {
  FilesAppSyncBackend(this.bookmark, {required this.folderName, this.isFile = false, this.fileName = kSyncFileName, MethodChannel? channel})
      : _channel = channel ?? FilesAppFolder.channel;

  /// From [FilesAppFolder.pick].
  final String bookmark;

  /// The folder's (or the picked file's) name, for the settings.
  final String folderName;

  /// The bookmark is the sync file itself, not its folder.
  final bool isFile;
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
      return await _channel.invokeMethod<T>(method, {'bookmark': bookmark, 'file': isFile, ...args});
    } on PlatformException catch (e) {
      if (e.code == 'conflict') throw const SyncConflict();
      if (e.code == 'bookmark') throw SyncBackendException(e.message ?? 'Choose the location again in Settings > Sync.');
      throw SyncBackendException('Could not use "$folderName": ${e.message ?? e.code}', temporary: true);
    } on MissingPluginException {
      throw const SyncBackendException('The sync location cannot be reached right now; NEFORUM syncs when it is open.', temporary: true);
    }
  }

  Future<SyncBlob?> _read(String name, {bool sideCopy = false}) async {
    final r = await _call<Map<Object?, Object?>>('read', {'name': name, if (sideCopy) 'file': false});
    if (r == null) return null;
    final bytes = r['bytes'];
    // An empty file is a sync file not written yet ("Create the sync file").
    if (bytes is! Uint8List || bytes.isEmpty) return null;
    return SyncBlob(bytes, '${r['version'] ?? ''}');
  }

  @override
  Future<SyncBlob?> read() => _read(fileName);

  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) =>
      _call<String>('write', {'name': fileName, 'bytes': bytes, 'ifMatch': ifMatch});

  @override
  Future<List<SyncSideCopy>> conflictCopies() async {
    if (isFile) return const [];
    final names = await _call<List<Object?>>('list') ?? const [];
    final out = <SyncSideCopy>[];
    for (final n in names.whereType<String>()) {
      if (!isSyncConflictCopyName(n, fileName: fileName)) continue;
      try {
        final blob = await _read(n, sideCopy: true);
        if (blob != null) out.add(SyncSideCopy(n, blob.bytes));
      } on SyncBackendException {
        // Not downloaded yet: next time.
      }
    }
    return out;
  }

  @override
  Future<void> removeConflictCopy(SyncSideCopy copy) async {
    if (isFile || !isSyncConflictCopyName(copy.name, fileName: fileName)) return;
    try {
      await _call<void>('delete', {'name': copy.name});
    } on SyncBackendException {
      // Next time.
    }
  }

  /// Proves NEFORUM may write there without changing the sync file: the
  /// system says whether the file (or the folder) may be changed ("probe"),
  /// and in a folder a probe file is written and removed next to it. Writing
  /// a picked file back could upload a stale copy over a newer one.
  @override
  Future<void> check() async {
    if (await _call<bool>('probe') != true) {
      throw SyncBackendException('NEFORUM may not change files there: "$folderName" is read-only for other apps. '
          'Check that your account may edit it, or choose another location.');
    }
    if (isFile) return;
    final probe = '.$fileName.check';
    await _call<String>('write', {'name': probe, 'bytes': Uint8List.fromList(const [0x4E]), 'force': true});
    await _call<void>('delete', {'name': probe});
  }
}
