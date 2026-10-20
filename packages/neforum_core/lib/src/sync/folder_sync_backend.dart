import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'sync_backend.dart';

/// The sync file in a folder that a desktop cloud client keeps in sync
/// (OneDrive, Google Drive, Dropbox, iCloud Drive, Box, MEGA, pCloud, Proton
/// Drive, Sync.com, Syncthing, the Nextcloud client...), the way KeePassXC
/// keeps its database: NEFORUM only reads and writes the file, the cloud app
/// moves it.
///
/// Writes go to a temporary file in the same folder, then replace the sync
/// file in one rename, so a cloud client never uploads half a file. When two
/// devices write before their cloud clients caught up, the clients keep both
/// ("conflicted copy"); [conflictCopies] finds those for the merge.
class FolderSyncBackend extends SyncBackend {
  FolderSyncBackend(this.folder, {this.fileName = kSyncFileName, Random? random}) : _rng = random ?? Random();

  final String folder;
  final String fileName;
  final Random _rng;

  File get _file => File(p.join(folder, fileName));

  @override
  String get label => folder;

  @override
  bool get atomicWrites => false;

  @override
  Future<SyncBlob?> read() async {
    final f = _file;
    try {
      if (!await f.exists()) {
        if (!await Directory(folder).exists()) {
          throw SyncBackendException('The folder $folder is not there. Is the cloud app running and the drive connected?', temporary: true);
        }
        return null;
      }
      final bytes = await f.readAsBytes();
      return SyncBlob(bytes, await _version(f));
    } on FileSystemException catch (e) {
      throw SyncBackendException('Could not read ${f.path}: ${e.osError?.message ?? e.message}', temporary: true);
    }
  }

  @override
  Future<String?> write(Uint8List bytes, {required String? ifMatch}) async {
    final f = _file;
    try {
      final exists = await f.exists();
      final current = exists ? await _version(f) : null;
      if (current != ifMatch) throw const SyncConflict();
      final tmp = File(p.join(folder, '.$fileName.${_rng.nextInt(1 << 32).toRadixString(16)}.tmp'));
      await tmp.writeAsBytes(bytes, flush: true);
      try {
        await tmp.rename(f.path);
      } on FileSystemException {
        // Some systems refuse to rename over an existing file.
        if (await f.exists()) await f.delete();
        await tmp.rename(f.path);
      }
      return await _version(f);
    } on FileSystemException catch (e) {
      throw SyncBackendException('Could not write ${f.path}: ${e.osError?.message ?? e.message}', temporary: true);
    }
  }

  /// Names cloud clients give conflicting copies: "NEFORUM (Alice's
  /// conflicted copy 2026-10-20).neforumsync" (Dropbox), "NEFORUM-PC.neforumsync"
  /// (OneDrive), "NEFORUM (1).neforumsync" (Google Drive),
  /// "NEFORUM.sync-conflict-20261020-101500-ABCDEFG.neforumsync" (Syncthing),
  /// "NEFORUM (conflicted copy 2026-10-20 101500).neforumsync" (Nextcloud).
  bool isConflictCopyName(String name) {
    final stem = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    return name != fileName && name.startsWith(stem) && name.endsWith(ext) && !name.startsWith('.');
  }

  @override
  Future<List<SyncSideCopy>> conflictCopies() async {
    final out = <SyncSideCopy>[];
    try {
      await for (final e in Directory(folder).list(followLinks: false)) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (!isConflictCopyName(name)) continue;
        try {
          out.add(SyncSideCopy(name, await e.readAsBytes()));
        } on FileSystemException {
          // Still being written by the cloud client: next time.
        }
      }
    } on FileSystemException {
      return out;
    }
    return out;
  }

  @override
  Future<void> removeConflictCopy(SyncSideCopy copy) async {
    if (!isConflictCopyName(copy.name)) return;
    final f = File(p.join(folder, copy.name));
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // The cloud client holds it: next time.
    }
  }

  @override
  Future<void> check() async {
    final dir = Directory(folder);
    if (!await dir.exists()) {
      throw SyncBackendException('The folder $folder does not exist.');
    }
    final probe = File(p.join(folder, '.$fileName.check'));
    try {
      await probe.writeAsBytes(const [0x4E], flush: true);
      await probe.delete();
    } on FileSystemException catch (e) {
      throw SyncBackendException('NEFORUM may not write in $folder: ${e.osError?.message ?? e.message}');
    }
  }

  static Future<String> _version(File f) async {
    final s = await f.stat();
    return '${s.modified.microsecondsSinceEpoch}:${s.size}';
  }
}
