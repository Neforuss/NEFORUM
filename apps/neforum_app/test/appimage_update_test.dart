// The Linux AppImage updating itself: which releases it installs, the
// download, the SHA-256 check against latest.json, the atomic replace, every
// failure leaving the running AppImage as it was, the restart after this
// copy has quit, and the Update now button and dialog.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/appimage_update.dart';
import 'package:neforum_app/platform/appimage_update_io.dart' as io;
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/platform/update_check.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/update_checks.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/settings/appimage_update_dialog.dart';
import 'package:neforum_app/ui/settings/updates_section.dart';

const _appImage = '/home/someone/Applications/NEFORUM-x86_64.AppImage';
const _releaseUrl = 'https://github.com/Neforuss/NEFORUM/releases/download/v9.0.0/NEFORUM-x86_64.AppImage';

final List<int> _oldBytes = utf8.encode('the AppImage that runs now');
final List<int> _newBytes = List<int>.generate(300 * 1024, (i) => (i * 31 + 7) & 0xff);

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

LatestRelease _release({String? sha, String url = _releaseUrl, String key = 'linux-x64-appimage'}) => LatestRelease.fromJson({
      'version': '9.0.0',
      'notes': 'Faster.',
      'downloads': {
        key: {'url': url, 'sha256': sha ?? _sha(_newBytes)},
      },
    });

/// An in-memory POSIX file system with switches for each failure.
class _Files implements io.AppImageFiles {
  _Files() {
    files[_appImage] = List.of(_oldBytes);
    modes[_appImage] = 0x1ED; // 0755
  }

  final Map<String, List<int>> files = {};
  final Map<String, int> modes = {};
  final Map<String, String> links = {};
  final List<String> log = [];
  bool failOpen = false;
  int? failAddAfterBytes;
  bool failChmod = false;
  bool failRename = false;

  @override
  String resolve(String path) => links[path] ?? path;

  @override
  bool isFile(String path) => files.containsKey(path);

  @override
  Future<io.UpdateFileSink> openWrite(String path) async {
    log.add('open $path');
    if (failOpen) throw FileSystemException('Permission denied', path, const OSError('Permission denied', 13));
    files[path] = [];
    return _Sink(this, path);
  }

  @override
  Future<void> makeExecutable(String path, {required String likePath}) async {
    log.add('chmod $path like $likePath');
    if (failChmod) throw FileSystemException('chmod failed', path);
    modes[path] = (modes[likePath] ?? 0) | 0x40;
  }

  @override
  Future<void> rename(String from, String to) async {
    log.add('rename $from -> $to');
    if (failRename) throw FileSystemException('Device or resource busy', from);
    files[to] = files.remove(from)!;
    modes[to] = modes.remove(from) ?? 0;
  }

  @override
  Future<void> delete(String path) async {
    log.add('delete $path');
    files.remove(path);
    modes.remove(path);
  }
}

class _Sink implements io.UpdateFileSink {
  _Sink(this.files, this.path);
  final _Files files;
  final String path;
  bool closed = false;

  @override
  Future<void> add(List<int> bytes) async {
    final limit = files.failAddAfterBytes;
    if (limit != null && files.files[path]!.length + bytes.length > limit) {
      throw FileSystemException('No space left on device', path, const OSError('No space left on device', 28));
    }
    files.files[path]!.addAll(bytes);
  }

  @override
  Future<void> close() async => closed = true;
}

Stream<List<int>> _chunks(List<int> bytes, {int size = 64 * 1024}) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size);
  }
}

io.AppImageUpdater _updater(_Files files, {List<int>? body, int? contentLength, Object? startError, List<Uri>? requested}) => io.AppImageUpdater(
      appImagePath: _appImage,
      downloadKey: 'linux-x64-appimage',
      files: files,
      download: (url) async {
        requested?.add(url);
        if (startError != null) throw startError;
        final b = body ?? _newBytes;
        return io.UpdateDownload(body: _chunks(b), contentLength: contentLength ?? b.length);
      },
      relaunch: (_) async => fail('no restart in install tests'),
      quit: () async => fail('no quit in install tests'),
    );

String get _part => io.AppImageUpdater.partPath(_appImage, '9.0.0');

/// The running AppImage is exactly as before, and nothing is left beside it.
void _expectUntouched(_Files files) {
  expect(files.files[_appImage], _oldBytes, reason: 'the running AppImage is unchanged');
  expect(files.files.keys, [_appImage], reason: 'the partial download is removed');
}

class _MemoryStorage implements AppStorage {
  _MemoryStorage([Map<String, Object> settings = const {}]) : json = {'settings.json': settings};
  final Map<String, Object> json;
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}

/// The widget tests in this file install flutter_test's HttpOverrides (every
/// request answers 400); the download tests talk to a real loopback server.
class _RealHttp extends HttpOverrides {}

HttpClient _realClient() => HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());

/// A self-updater for the widget tests.
class _FakeSelfUpdate implements AppImageSelfUpdate {
  _FakeSelfUpdate({this.error});
  final Object? error;
  final List<String> calls = [];
  final Completer<void> release = Completer<void>();
  bool cancelledSeen = false;

  @override
  String get appImagePath => _appImage;

  @override
  ReleaseDownload? downloadFor(LatestRelease release) => release.downloads['linux-x64-appimage'];

  @override
  Future<void> install(LatestRelease r, {void Function(AppImageUpdateProgress progress)? onProgress, bool Function()? isCancelled}) async {
    calls.add('install ${r.version}');
    onProgress?.call(const AppImageUpdateProgress(AppImageUpdateStage.downloading, receivedBytes: 0, totalBytes: 100 * 1024 * 1024));
    onProgress?.call(const AppImageUpdateProgress(AppImageUpdateStage.downloading, receivedBytes: 50 * 1024 * 1024, totalBytes: 100 * 1024 * 1024));
    await release.future;
    if (isCancelled?.call() ?? false) {
      cancelledSeen = true;
      throw const AppImageUpdateCancelled();
    }
    if (error != null) throw error!;
    onProgress?.call(const AppImageUpdateProgress(AppImageUpdateStage.verifying, receivedBytes: 100 * 1024 * 1024, totalBytes: 100 * 1024 * 1024));
    onProgress?.call(const AppImageUpdateProgress(AppImageUpdateStage.installing, receivedBytes: 100 * 1024 * 1024, totalBytes: 100 * 1024 * 1024));
  }

  @override
  Future<void> restart() async => calls.add('restart');
}

void main() {
  group('which releases NEFORUM installs itself', () {
    test('an AppImage per processor NEFORUM builds one for', () {
      expect(appImageDownloadKey('linux_x64'), 'linux-x64-appimage');
      expect(appImageDownloadKey('linux_arm64'), 'linux-arm64-appimage');
      expect(appImageDownloadKey('linux_riscv64'), isNull);
      expect(appImageDownloadKey('windows_x64'), isNull);
    });

    test('only files of this project\'s GitHub releases', () {
      expect(isReleaseDownloadUrl(_releaseUrl), isTrue);
      expect(isReleaseDownloadUrl('https://github.com/Neforuss/NEFORUM/releases/download/v9.0.0/NEFORUM-aarch64.AppImage'), isTrue);
      for (final bad in [
        'http://github.com/Neforuss/NEFORUM/releases/download/v9.0.0/NEFORUM-x86_64.AppImage',
        'https://github.com.example.org/Neforuss/NEFORUM/releases/download/v9.0.0/NEFORUM-x86_64.AppImage',
        'https://example.org/Neforuss/NEFORUM/releases/download/v9.0.0/NEFORUM-x86_64.AppImage',
        'https://github.com/someone-else/NEFORUM/releases/download/v9.0.0/NEFORUM-x86_64.AppImage',
        'https://github.com/Neforuss/NEFORUM/releases/download/NEFORUM-x86_64.AppImage',
        'https://github.com/Neforuss/NEFORUM/releases/download/v9.0.0/sub/NEFORUM-x86_64.AppImage',
        'https://github.com/Neforuss/NEFORUM/releases/download/v9.0.0/..',
        'https://github.com/Neforuss/NEFORUM/releases/download/v9.0.0/NEFORUM-x86_64.AppImage?x=1',
        'https://github.com:8443/Neforuss/NEFORUM/releases/download/v9.0.0/NEFORUM-x86_64.AppImage',
        'https://user@github.com/Neforuss/NEFORUM/releases/download/v9.0.0/NEFORUM-x86_64.AppImage',
        'not a url at all',
      ]) {
        expect(isReleaseDownloadUrl(bad), isFalse, reason: bad);
      }
    });

    test('a release without this processor\'s AppImage, or with one elsewhere, goes to the download page', () {
      final u = _updater(_Files());
      expect(u.downloadFor(_release())!.url, _releaseUrl);
      expect(u.downloadFor(_release(key: 'linux-arm64-appimage')), isNull);
      expect(u.downloadFor(_release(url: 'https://example.org/NEFORUM-x86_64.AppImage')), isNull);
      expect(u.downloadFor(const LatestRelease(version: '9.0.0')), isNull);
    });
  });

  group('not an AppImage', () {
    test('no updater outside Linux, without \$APPIMAGE, or for a file that is not there', () {
      final files = _Files();
      expect(io.createAppImageSelfUpdate(environment: {'APPIMAGE': _appImage}, isLinux: false, abi: 'linux_x64', files: files), isNull);
      expect(io.createAppImageSelfUpdate(environment: const {}, isLinux: true, abi: 'linux_x64', files: files), isNull, reason: 'the tarball or a source build');
      expect(io.createAppImageSelfUpdate(environment: const {'APPIMAGE': ''}, isLinux: true, abi: 'linux_x64', files: files), isNull);
      expect(io.createAppImageSelfUpdate(environment: const {'APPIMAGE': 'NEFORUM.AppImage'}, isLinux: true, abi: 'linux_x64', files: files), isNull,
          reason: 'a relative path is not what the runtime sets');
      expect(io.createAppImageSelfUpdate(environment: const {'APPIMAGE': '/tmp/gone.AppImage'}, isLinux: true, abi: 'linux_x64', files: files), isNull);
      expect(io.createAppImageSelfUpdate(environment: const {'APPIMAGE': _appImage}, isLinux: true, abi: 'linux_riscv64', files: files), isNull);
    });

    test('an AppImage on a processor with releases gets the updater for that processor', () {
      final u = io.createAppImageSelfUpdate(environment: const {'APPIMAGE': _appImage}, isLinux: true, abi: 'linux_arm64', files: _Files())! as io.AppImageUpdater;
      expect(u.appImagePath, _appImage);
      expect(u.downloadKey, 'linux-arm64-appimage');
    });

    test('flutter test itself is not an AppImage', () {
      expect(createAppImageSelfUpdate(), isNull);
    });
  });

  group('install', () {
    test('downloads, checks the SHA-256, makes it executable and renames it over the AppImage', () async {
      final files = _Files();
      final requested = <Uri>[];
      final progress = <AppImageUpdateProgress>[];
      await _updater(files, requested: requested).install(_release(), onProgress: progress.add);

      expect(requested, [Uri.parse(_releaseUrl)]);
      expect(files.files[_appImage], _newBytes);
      expect(files.modes[_appImage]! & 0x49, 0x49, reason: 'still executable');
      expect(files.files.keys, [_appImage], reason: 'nothing left beside it');
      expect(_part, '/home/someone/Applications/.NEFORUM-x86_64.AppImage.9.0.0.part', reason: 'hidden, in the same folder (one file system)');
      expect(files.log, ['open $_part', 'chmod $_part like $_appImage', 'rename $_part -> $_appImage'],
          reason: 'the AppImage is only ever replaced by one rename');

      expect(progress.map((p) => p.stage).toSet().toList(), [AppImageUpdateStage.downloading, AppImageUpdateStage.verifying, AppImageUpdateStage.installing]);
      final downloaded = progress.where((p) => p.stage == AppImageUpdateStage.downloading).last;
      expect(downloaded.receivedBytes, _newBytes.length);
      expect(downloaded.fraction, 1);
    });

    test('a symbolic link to the AppImage: the file it points to is replaced', () async {
      final files = _Files();
      const link = '/home/someone/bin/neforum';
      files.links[link] = _appImage;
      final u = io.AppImageUpdater(
        appImagePath: link,
        downloadKey: 'linux-x64-appimage',
        files: files,
        download: (_) async => io.UpdateDownload(body: _chunks(_newBytes), contentLength: _newBytes.length),
      );
      await u.install(_release());
      expect(files.files[_appImage], _newBytes);
      expect(files.log.last, 'rename $_part -> $_appImage');
    });

    test('a download that does not match the SHA-256 in latest.json is not installed', () async {
      final files = _Files();
      final tampered = List.of(_newBytes)..[1000] ^= 1;
      await expectLater(
        _updater(files, body: tampered).install(_release()),
        throwsA(isA<AppImageUpdateException>().having((e) => e.message, 'message', contains('SHA-256'))),
      );
      _expectUntouched(files);
      expect(files.log.where((l) => l.startsWith('rename') || l.startsWith('chmod')), isEmpty);
    });

    test('a folder NEFORUM cannot write to (an AppImage in /opt) fails before downloading anything into it', () async {
      final files = _Files()..failOpen = true;
      await expectLater(
        _updater(files).install(_release()),
        throwsA(isA<AppImageUpdateException>().having((e) => e.message, 'message', contains('cannot write next to its AppImage in /home/someone/Applications'))),
      );
      _expectUntouched(files);
    });

    test('a full disk halfway through removes the partial file', () async {
      final files = _Files()..failAddAfterBytes = 100 * 1024;
      await expectLater(
        _updater(files).install(_release()),
        throwsA(isA<AppImageUpdateException>().having((e) => e.message, 'message', contains('No space left on device'))),
      );
      _expectUntouched(files);
      expect(files.log, contains('delete $_part'));
    });

    test('a failed rename or chmod leaves the AppImage as it was', () async {
      for (final setUp in <void Function(_Files)>[(f) => f.failRename = true, (f) => f.failChmod = true]) {
        final files = _Files();
        setUp(files);
        await expectLater(_updater(files).install(_release()), throwsA(isA<AppImageUpdateException>()));
        _expectUntouched(files);
      }
    });

    test('a download that ends early, never starts, breaks off or is too large fails', () async {
      var files = _Files();
      await expectLater(
        _updater(files, contentLength: _newBytes.length + 10).install(_release()),
        throwsA(isA<AppImageUpdateException>().having((e) => e.message, 'message', contains('ended early'))),
      );
      _expectUntouched(files);

      files = _Files();
      await expectLater(
        _updater(files, startError: const SocketException('Network is unreachable')).install(_release()),
        throwsA(isA<AppImageUpdateException>().having((e) => e.message, 'message', contains('did not start'))),
      );
      _expectUntouched(files);

      files = _Files();
      final broken = io.AppImageUpdater(
        appImagePath: _appImage,
        downloadKey: 'linux-x64-appimage',
        files: files,
        download: (_) async => io.UpdateDownload(body: () async* {
          yield _newBytes.sublist(0, 1000);
          throw const SocketException('Connection reset by peer');
        }()),
      );
      await expectLater(broken.install(_release()), throwsA(isA<AppImageUpdateException>().having((e) => e.message, 'message', contains('stopped'))));
      _expectUntouched(files);

      files = _Files();
      await expectLater(
        _updater(files, contentLength: kMaximumAppImageBytes + 1).install(_release()),
        throwsA(isA<AppImageUpdateException>().having((e) => e.message, 'message', contains('too large'))),
      );
      _expectUntouched(files);
    });

    test('Cancel during the download stops it and removes the partial file', () async {
      final files = _Files();
      var chunks = 0;
      await expectLater(
        _updater(files).install(_release(), onProgress: (_) => chunks++, isCancelled: () => chunks >= 2),
        throwsA(isA<AppImageUpdateCancelled>()),
      );
      _expectUntouched(files);
    });

    test('a release with no AppImage for this computer, or an AppImage that is gone, fails without touching anything', () async {
      var files = _Files();
      await expectLater(_updater(files).install(_release(key: 'linux-arm64-appimage')), throwsA(isA<AppImageUpdateException>()));
      _expectUntouched(files);

      files = _Files()..files.clear();
      await expectLater(
        _updater(files).install(_release()),
        throwsA(isA<AppImageUpdateException>().having((e) => e.message, 'message', contains('cannot find its AppImage'))),
      );
      expect(files.files, isEmpty);
    });

    test('restart starts the new AppImage after this copy quits, then quits', () async {
      final calls = <String>[];
      final u = io.AppImageUpdater(
        appImagePath: _appImage,
        downloadKey: 'linux-x64-appimage',
        files: _Files(),
        relaunch: (path) async => calls.add('relaunch $path'),
        quit: () async => calls.add('quit'),
      );
      await u.restart();
      expect(calls, ['relaunch $_appImage', 'quit']);
    });
  });

  group('the restart', () {
    test('the new AppImage does not inherit this run\'s AppImage variables', () {
      final env = io.relaunchEnvironment({
        'APPIMAGE': _appImage,
        'APPDIR': '/tmp/.mount_NEFORUabc',
        'ARGV0': './NEFORUM-x86_64.AppImage',
        'OWD': '/home/someone',
        'HOME': '/home/someone',
        'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/run/user/1000/bus',
        'DISPLAY': ':0',
      });
      expect(env, {'HOME': '/home/someone', 'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/run/user/1000/bus', 'DISPLAY': ':0'});
    });

    test('the helper waits for this process to exit, then runs the new AppImage', () async {
      final dir = await Directory.systemTemp.createTemp('neforum_relaunch_');
      addTearDown(() => dir.delete(recursive: true));
      final out = File('${dir.path}/started');
      final fakeAppImage = File('${dir.path}/NEFORUM.AppImage');
      await fakeAppImage.writeAsString('#!/bin/sh\nenv > "${out.path}"\n');
      await Process.run('chmod', ['755', fakeAppImage.path]);
      // Stands in for the NEFORUM that is quitting.
      final old = await Process.start('sleep', ['30']);
      await io.relaunchAppImageAfterExit(fakeAppImage.path, pid: old.pid, environment: {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'APPIMAGE': '/old/NEFORUM.AppImage',
        'NEFORUM_RELAUNCH_TEST': 'yes',
      });
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(out.existsSync(), isFalse, reason: 'not while the old NEFORUM still runs (one instance per session)');
      old.kill();
      await old.exitCode;
      for (var i = 0; i < 100 && !out.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final env = out.readAsStringSync();
      expect(env, contains('NEFORUM_RELAUNCH_TEST=yes'));
      expect(env, isNot(contains('/old/NEFORUM.AppImage')), reason: 'the new runtime sets its own APPIMAGE');
    }, skip: Platform.isLinux ? false : 'needs /proc and /bin/sh (Linux CI runs it)');
  });

  group('on the real file system', () {
    test('replaces the AppImage and keeps it executable', () async {
      final dir = await Directory.systemTemp.createTemp('neforum_appimage_');
      addTearDown(() => dir.delete(recursive: true));
      final appImage = File('${dir.path}/NEFORUM-x86_64.AppImage');
      await appImage.writeAsBytes(_oldBytes);
      await Process.run('chmod', ['750', appImage.path]);
      final u = io.AppImageUpdater(
        appImagePath: appImage.path,
        downloadKey: 'linux-x64-appimage',
        download: (_) async => io.UpdateDownload(body: _chunks(_newBytes), contentLength: _newBytes.length),
      );
      await u.install(_release());
      expect(await appImage.readAsBytes(), _newBytes);
      expect((await appImage.stat()).mode & 0x1FF, 0x1E8, reason: '0750 kept');
      expect(dir.listSync().map((e) => e.path), [appImage.path]);
    }, skip: Platform.isLinux ? false : 'chmod and POSIX renames (Linux CI runs it)');

    test('a folder without write permission fails and leaves the AppImage', () async {
      final dir = await Directory.systemTemp.createTemp('neforum_appimage_');
      final appImage = File('${dir.path}/NEFORUM-x86_64.AppImage');
      await appImage.writeAsBytes(_oldBytes);
      await Process.run('chmod', ['555', dir.path]);
      addTearDown(() async {
        await Process.run('chmod', ['755', dir.path]);
        await dir.delete(recursive: true);
      });
      final u = io.AppImageUpdater(
        appImagePath: appImage.path,
        downloadKey: 'linux-x64-appimage',
        download: (_) async => io.UpdateDownload(body: _chunks(_newBytes), contentLength: _newBytes.length),
      );
      if (Platform.environment['USER'] == 'root') return; // root writes anyway
      await expectLater(u.install(_release()), throwsA(isA<AppImageUpdateException>()));
      expect(await appImage.readAsBytes(), _oldBytes);
      expect(dir.listSync().map((e) => e.path), [appImage.path]);
    }, skip: Platform.isLinux ? false : 'POSIX permissions (Linux CI runs it)');
  });

  group('the download request', () {
    late HttpServer server;
    final headers = <HttpHeaders>[];

    setUp(() async {
      headers.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        headers.add(r.headers);
        switch (r.uri.path) {
          case '/file':
            r.response.contentLength = _newBytes.length;
            r.response.add(_newBytes);
          case '/to-http':
            r.response.statusCode = HttpStatus.found;
            r.response.headers.set(HttpHeaders.locationHeader, 'http://127.0.0.1:${server.port}/file');
          default:
            r.response.statusCode = HttpStatus.notFound;
        }
        await r.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('one GET with the update check\'s fixed User-Agent, no cookies, and the size', () async {
      final d = await io.downloadReleaseFile(Uri.parse('http://127.0.0.1:${server.port}/file'), createClient: _realClient);
      expect(d.contentLength, _newBytes.length);
      final bytes = await d.body.expand((c) => c).toList();
      expect(bytes, _newBytes);
      expect(headers.single.value(HttpHeaders.userAgentHeader), kUpdateCheckUserAgent);
      expect(headers.single.value(HttpHeaders.cookieHeader), isNull);
    });

    test('a status other than 200 fails', () async {
      await expectLater(
        io.downloadReleaseFile(Uri.parse('http://127.0.0.1:${server.port}/missing/NEFORUM-x86_64.AppImage'), createClient: _realClient),
        throwsA(isA<AppImageUpdateException>().having((e) => e.message, 'message', contains('404'))),
      );
    });

    test('a redirect to a page that is not https is refused', () async {
      await expectLater(
        io.downloadReleaseFile(Uri.parse('http://127.0.0.1:${server.port}/to-http'), createClient: _realClient),
        throwsA(isA<AppImageUpdateException>().having((e) => e.message, 'message', contains('not https'))),
      );
    });
  });

  group('Update now', () {
    Future<void> pumpSection(WidgetTester tester, AppImageSelfUpdate? updater) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = (await tester.runAsync(() => AppServices.create(
            demo: true,
            storage: _MemoryStorage({'themeMode': 'light', 'updateLatestRelease': _release().toJson()}),
          )))!;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          servicesProvider.overrideWithValue(services),
          appImageSelfUpdateProvider.overrideWithValue(updater),
        ],
        child: MaterialApp(theme: buildTheme(Brightness.light, AccentChoice.neforum), home: const Scaffold(body: SingleChildScrollView(child: UpdateSettingsSection()))),
      ));
      await tester.pump();
    }

    testWidgets('an AppImage shows Update now; after asking, it installs and restarts', (tester) async {
      final updater = _FakeSelfUpdate();
      await pumpSection(tester, updater);
      expect(find.text('NEFORUM 9.0.0 is available'), findsOneWidget);
      expect(find.text('Download'), findsNothing);
      await tester.tap(find.text('Update now'));
      await tester.pumpAndSettle();
      expect(find.text('Update to NEFORUM 9.0.0?'), findsOneWidget);
      expect(find.text(_appImage), findsOneWidget, reason: 'says which file it replaces');
      expect(updater.calls, isEmpty, reason: 'nothing happens before Update');

      await tester.tap(find.widgetWithText(FilledButton, 'Update'));
      await tester.pump();
      expect(find.text('Downloading: 50.0 of 100.0 MB'), findsOneWidget);
      updater.release.complete();
      await tester.pump();
      await tester.pump();
      expect(updater.calls, ['install 9.0.0', 'restart']);
      expect(find.text('Restarting NEFORUM'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('anything else keeps the Download button (the download page)', (tester) async {
      await pumpSection(tester, null);
      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Update now'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    Future<List<String>> pumpDialog(WidgetTester tester, _FakeSelfUpdate updater) async {
      final opened = <String>[];
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => AppImageUpdateDialog(release: _release(), updater: updater, openDownloadPage: () async => opened.add('download page')),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Update'));
      await tester.pump();
      return opened;
    }

    testWidgets('a failure says why and falls back to the download page', (tester) async {
      final updater = _FakeSelfUpdate(error: const AppImageUpdateException('The download does not match the SHA-256 in latest.json, so it was not installed.'));
      final opened = await pumpDialog(tester, updater);
      updater.release.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('Could not update'), findsOneWidget);
      expect(find.textContaining('does not match the SHA-256'), findsOneWidget);
      expect(find.textContaining('This NEFORUM is unchanged'), findsOneWidget);
      expect(updater.calls, ['install 9.0.0'], reason: 'no restart after a failure');
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(opened, ['download page']);
      expect(find.byType(AppImageUpdateDialog), findsNothing);
    });

    testWidgets('Cancel stops the download', (tester) async {
      final updater = _FakeSelfUpdate();
      await pumpDialog(tester, updater);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      updater.release.complete();
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(updater.cancelledSeen, isTrue);
      expect(updater.calls, ['install 9.0.0']);
      expect(find.byType(AppImageUpdateDialog), findsNothing, reason: 'Cancel closes the dialog');
    });
  });
}
