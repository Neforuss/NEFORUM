import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path_package;

import 'appimage_update.dart';
import 'desktop.dart';
import 'update_check.dart';

/// AppImages exist only on Linux: paths are POSIX paths, also when the tests
/// run on Windows.
final path_package.Context _posix = path_package.posix;

/// One download's answer: its size when the server gave one, and its bytes.
class UpdateDownload {
  const UpdateDownload({required this.body, this.contentLength});

  final Stream<List<int>> body;
  final int? contentLength;
}

/// Opens a release download; replaced in tests.
typedef UpdateDownloader = Future<UpdateDownload> Function(Uri url);

/// A file being written. Errors (a full disk, no permission) come out of
/// [add] and [close], not later.
abstract interface class UpdateFileSink {
  Future<void> add(List<int> bytes);

  /// Flushes the bytes to the disk and closes the file.
  Future<void> close();
}

/// The file operations an AppImage update needs; replaced in tests.
abstract interface class AppImageFiles {
  /// [path] with symbolic links resolved.
  String resolve(String path);

  bool isFile(String path);

  /// Creates or empties [path] for writing.
  Future<UpdateFileSink> openWrite(String path);

  /// Gives [path] the permissions of [likePath], plus execute for its owner.
  Future<void> makeExecutable(String path, {required String likePath});

  /// Renames [from] over [to] (same folder, so atomic).
  Future<void> rename(String from, String to);

  /// Removes [path] if it is there; never throws.
  Future<void> delete(String path);
}

/// Starts the AppImage at the given path once this process has quit.
typedef AppImageRelauncher = Future<void> Function(String appImagePath);

/// [AppImageSelfUpdate] on Linux, for the AppImage at [appImagePath].
class AppImageUpdater implements AppImageSelfUpdate {
  AppImageUpdater({
    required this.appImagePath,
    required this.downloadKey,
    UpdateDownloader? download,
    AppImageFiles? files,
    AppImageRelauncher? relaunch,
    Future<void> Function()? quit,
  })  : _download = download ?? downloadReleaseFile,
        _files = files ?? const IoAppImageFiles(),
        _relaunch = relaunch ?? relaunchAppImageAfterExit,
        _quit = quit ?? (() => DesktopIntegration.instance.quit());

  @override
  final String appImagePath;

  /// This processor's latest.json key (see [appImageDownloadKey]).
  final String downloadKey;

  final UpdateDownloader _download;
  final AppImageFiles _files;
  final AppImageRelauncher _relaunch;
  final Future<void> Function() _quit;

  /// Where the update is written before the rename: hidden, next to the
  /// AppImage, so the rename stays on one file system.
  static String partPath(String target, String version) => _posix.join(_posix.dirname(target), '.${_posix.basename(target)}.$version.part');

  @override
  ReleaseDownload? downloadFor(LatestRelease release) {
    final d = release.downloads[downloadKey];
    return d != null && isReleaseDownloadUrl(d.url) ? d : null;
  }

  @override
  Future<void> install(LatestRelease release, {void Function(AppImageUpdateProgress progress)? onProgress, bool Function()? isCancelled}) async {
    final download = downloadFor(release);
    if (download == null) throw const AppImageUpdateException('This release has no AppImage for this computer on GitHub.');
    final String target;
    try {
      target = _files.resolve(appImagePath);
    } on Object {
      throw AppImageUpdateException('NEFORUM cannot find its AppImage at $appImagePath.');
    }
    if (!_files.isFile(target)) throw AppImageUpdateException('NEFORUM cannot find its AppImage at $appImagePath.');
    final part = partPath(target, release.version);
    var created = false;
    try {
      onProgress?.call(const AppImageUpdateProgress(AppImageUpdateStage.downloading));
      final UpdateDownload response;
      try {
        response = await _download(Uri.parse(download.url));
      } on AppImageUpdateException {
        rethrow;
      } on Object catch (e) {
        throw AppImageUpdateException('The download did not start ($e).');
      }
      final total = response.contentLength;
      if (total != null && total > kMaximumAppImageBytes) {
        await _discard(response);
        throw AppImageUpdateException('The download is too large ($total bytes).');
      }

      final UpdateFileSink sink;
      try {
        created = true;
        sink = await _files.openWrite(part);
      } on Object catch (e) {
        await _discard(response);
        throw AppImageUpdateException('NEFORUM cannot write next to its AppImage in ${_posix.dirname(target)} ($e).');
      }
      final digest = _DigestSink();
      final hash = sha256.startChunkedConversion(digest);
      var received = 0;
      try {
        await for (final chunk in response.body) {
          if (isCancelled?.call() ?? false) throw const AppImageUpdateCancelled();
          received += chunk.length;
          if (received > kMaximumAppImageBytes) throw AppImageUpdateException('The download is too large (over $kMaximumAppImageBytes bytes).');
          hash.add(chunk);
          try {
            await sink.add(chunk);
          } on Object catch (e) {
            throw AppImageUpdateException('NEFORUM could not save the download in ${_posix.dirname(target)} ($e).');
          }
          onProgress?.call(AppImageUpdateProgress(AppImageUpdateStage.downloading, receivedBytes: received, totalBytes: total));
        }
      } on AppImageUpdateException {
        await _closeQuietly(sink);
        rethrow;
      } on Object catch (e) {
        await _closeQuietly(sink);
        throw AppImageUpdateException('The download stopped ($e).');
      }
      try {
        await sink.close();
      } on Object catch (e) {
        throw AppImageUpdateException('NEFORUM could not save the download in ${_posix.dirname(target)} ($e).');
      }
      if (total != null && received != total) throw AppImageUpdateException('The download ended early ($received of $total bytes).');

      onProgress?.call(AppImageUpdateProgress(AppImageUpdateStage.verifying, receivedBytes: received, totalBytes: total));
      hash.close();
      final actual = digest.value.toString();
      if (actual != download.sha256) {
        throw const AppImageUpdateException('The download does not match the SHA-256 in latest.json, so it was not installed.');
      }

      onProgress?.call(AppImageUpdateProgress(AppImageUpdateStage.installing, receivedBytes: received, totalBytes: total));
      try {
        await _files.makeExecutable(part, likePath: target);
        await _files.rename(part, target);
      } on Object catch (e) {
        throw AppImageUpdateException('NEFORUM could not replace $target ($e).');
      }
      created = false;
    } finally {
      if (created) await _files.delete(part);
    }
  }

  /// Lets go of a download that will not be read (its connection closes).
  static Future<void> _discard(UpdateDownload response) async {
    try {
      await response.body.listen(null).cancel();
    } on Object {
      // Closing anyway.
    }
  }

  static Future<void> _closeQuietly(UpdateFileSink sink) async {
    try {
      await sink.close();
    } on Object {
      // The partial file is removed next.
    }
  }

  @override
  Future<void> restart() async {
    await _relaunch(appImagePath);
    await _quit();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

/// [AppImageFiles] on the real file system.
class IoAppImageFiles implements AppImageFiles {
  const IoAppImageFiles();

  @override
  String resolve(String path) => File(path).resolveSymbolicLinksSync();

  @override
  bool isFile(String path) => FileSystemEntity.isFileSync(path);

  @override
  Future<UpdateFileSink> openWrite(String path) async => _IoFileSink(await File(path).open(mode: FileMode.writeOnly));

  @override
  Future<void> makeExecutable(String path, {required String likePath}) async {
    // Read, write and execute bits of the old AppImage, plus owner execute.
    final mode = ((await File(likePath).stat()).mode & 0x1FF) | 0x40;
    final r = await Process.run('chmod', [mode.toRadixString(8), path]);
    if (r.exitCode != 0) throw FileSystemException('chmod failed: ${r.stderr}'.trim(), path);
  }

  @override
  Future<void> rename(String from, String to) => File(from).rename(to);

  @override
  Future<void> delete(String path) async {
    try {
      await File(path).delete();
    } on Object {
      // Already gone, or nothing to do about it.
    }
  }
}

class _IoFileSink implements UpdateFileSink {
  _IoFileSink(this._file);

  final RandomAccessFile _file;

  @override
  Future<void> add(List<int> bytes) => _file.writeFrom(bytes);

  @override
  Future<void> close() async {
    try {
      await _file.flush();
    } finally {
      await _file.close();
    }
  }
}

/// GETs a release file: the same fixed User-Agent and no cookies as the
/// update check, redirects followed only over https (GitHub sends release
/// files from another host). [createClient] is for tests.
Future<UpdateDownload> downloadReleaseFile(Uri url, {HttpClient Function()? createClient}) async {
  final client = (createClient ?? HttpClient.new)()
    ..userAgent = kUpdateCheckUserAgent
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(url);
    request
      ..persistentConnection = false
      ..followRedirects = true
      ..maxRedirects = 5;
    request.headers
      ..set(HttpHeaders.userAgentHeader, kUpdateCheckUserAgent)
      ..set(HttpHeaders.acceptHeader, 'application/octet-stream')
      ..removeAll(HttpHeaders.cookieHeader);
    final response = await request.close().timeout(const Duration(seconds: 30));
    var at = url;
    for (final r in response.redirects) {
      at = at.resolveUri(r.location);
      if (!at.isScheme('https')) {
        await response.drain<void>();
        throw AppImageUpdateException('The download was redirected to a page that is not https ($at).');
      }
    }
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw AppImageUpdateException('GitHub answered ${response.statusCode} for ${url.pathSegments.last}.');
    }
    final controller = StreamController<List<int>>();
    // The client closes when the body is read, failed or abandoned.
    controller.onListen = () {
      final sub = response.timeout(const Duration(seconds: 60)).listen(
            controller.add,
            onError: controller.addError,
            onDone: () {
              client.close(force: true);
              controller.close();
            },
            cancelOnError: true,
          );
      controller.onCancel = () async {
        await sub.cancel();
        client.close(force: true);
      };
    };
    return UpdateDownload(body: controller.stream, contentLength: response.contentLength >= 0 ? response.contentLength : null);
  } on Object {
    client.close(force: true);
    rethrow;
  }
}

/// Environment variables the AppImage runtime sets for one run; the new
/// AppImage's runtime sets its own, so they are not handed down.
const Set<String> kAppImageRunVariables = {'APPIMAGE', 'APPDIR', 'ARGV0', 'OWD'};

/// [environment] without [kAppImageRunVariables].
Map<String, String> relaunchEnvironment(Map<String, String> environment) => {
      for (final e in environment.entries)
        if (!kAppImageRunVariables.contains(e.key)) e.key: e.value,
    };

/// Waits until process `$1` has exited (or is a zombie), for at most 30
/// seconds, then runs `$2`. NEFORUM is one instance per user session
/// (GApplication on D-Bus), so the new copy must start after the old one is
/// gone, or it would only bring the old window forward and exit.
const String kRelaunchScript = r'''
i=0
while [ "$i" -lt 300 ] && [ -e "/proc/$1" ] && [ "$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -c1)" != Z ]; do
  sleep 0.1
  i=$((i + 1))
done
exec "$2"
''';

/// Starts a detached shell that runs [appImagePath] once process [pid]
/// (default: this one) has exited, from the folder NEFORUM was started in.
Future<void> relaunchAppImageAfterExit(String appImagePath, {int? pid, Map<String, String>? environment}) async {
  final env = environment ?? Platform.environment;
  final owd = env['OWD'];
  await Process.start(
    '/bin/sh',
    ['-c', kRelaunchScript, 'neforum-relaunch', '${pid ?? _currentPid}', appImagePath],
    mode: ProcessStartMode.detached,
    environment: relaunchEnvironment(env),
    includeParentEnvironment: false,
    workingDirectory: owd != null && owd.isNotEmpty && Directory(owd).existsSync() ? owd : null,
  );
}

int get _currentPid => pid;

/// The updater when this is Linux and the AppImage runtime set `$APPIMAGE`
/// to an existing file, for a processor NEFORUM builds AppImages for.
/// [environment], [isLinux] and [abi] are for tests.
AppImageSelfUpdate? createAppImageSelfUpdate({Map<String, String>? environment, bool? isLinux, String? abi, AppImageFiles files = const IoAppImageFiles()}) {
  if (!(isLinux ?? Platform.isLinux)) return null;
  final path = (environment ?? Platform.environment)['APPIMAGE'] ?? '';
  if (path.isEmpty || !_posix.isAbsolute(path) || !files.isFile(path)) return null;
  final key = appImageDownloadKey(abi ?? Abi.current().toString());
  if (key == null) return null;
  return AppImageUpdater(appImagePath: path, downloadKey: key, files: files);
}
