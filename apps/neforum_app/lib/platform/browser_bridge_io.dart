import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' show HandoffSnippet, SecretStore;
import 'package:path/path.dart' as p;

import 'browser_bridge.dart';
import 'file_export.dart';

BrowserBridge createBrowserBridge({required SecretStore secrets, required DateTime Function() clock, required List<int> ports, required String version}) =>
    IoBrowserBridge(secrets: secrets, clock: clock, ports: ports, version: version);

/// `<exe dir>/data/flutter_assets/assets/browser-extension` on Windows and
/// Linux, `NEFORUM.app/Contents/Frameworks/App.framework/Resources/
/// flutter_assets/assets/browser-extension` on macOS.
Future<String?> revealExtensionFiles() async {
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final assets = Platform.isMacOS ? p.join(exeDir, '..', 'Frameworks', 'App.framework', 'Resources', 'flutter_assets') : p.join(exeDir, 'data', 'flutter_assets');
    final dir = Directory(p.normalize(p.join(assets, 'assets', 'browser-extension')));
    if (!await dir.exists()) return null;
    // Select the chrome folder so both folders show side by side (Linux
    // file managers only open folders, so open the parent there).
    final chrome = Directory(p.join(dir.path, 'chrome'));
    await FileExport.reveal(!Platform.isLinux && await chrome.exists() ? chrome.path : dir.path);
    return dir.path;
  } on Object catch (e) {
    debugPrint('Could not find the extension files: $e');
    return null;
  }
}

// ---- installed browsers ------------------------------------------------------

/// Browser apps looked for on macOS, in /Applications and ~/Applications.
const List<String> _macBrowsers = [
  'Google Chrome', 'Google Chrome Beta', 'Google Chrome Dev', 'Google Chrome Canary', 'Chromium', 'Microsoft Edge', 'Brave Browser', //
  'Opera', 'Opera GX', 'Vivaldi', 'Arc', 'Helium', 'Thorium', 'Orion', //
  'Firefox', 'Firefox Developer Edition', 'Firefox Nightly', 'Zen', 'Zen Browser', 'LibreWolf', 'Waterfox', 'Floorp',
];

/// Browser commands looked for on Linux, with their names.
const List<(String, String)> _linuxBrowsers = [
  ('google-chrome', 'Google Chrome'), ('google-chrome-stable', 'Google Chrome'), ('chromium', 'Chromium'), ('chromium-browser', 'Chromium'),
  ('microsoft-edge', 'Microsoft Edge'), ('microsoft-edge-stable', 'Microsoft Edge'), ('brave-browser', 'Brave'), ('brave', 'Brave'),
  ('vivaldi', 'Vivaldi'), ('vivaldi-stable', 'Vivaldi'), ('opera', 'Opera'), ('helium', 'Helium'), ('helium-browser', 'Helium'),
  ('firefox', 'Mozilla Firefox'), ('librewolf', 'LibreWolf'), ('zen-browser', 'Zen'), ('floorp', 'Floorp'), ('waterfox', 'Waterfox'),
];

List<InstalledBrowser>? _installed;

Future<List<InstalledBrowser>> installedBrowsers({bool refresh = false}) async {
  final cached = _installed;
  if (!refresh && cached != null) return cached;
  var found = <InstalledBrowser>[];
  try {
    if (Platform.isWindows) {
      found = await _windowsBrowsers();
    } else if (Platform.isMacOS) {
      found = await _macInstalled();
    } else if (Platform.isLinux) {
      found = await _linuxInstalled();
    }
  } on Object catch (e) {
    debugPrint('Could not list the installed browsers: $e');
  }
  final seen = <String>{};
  found = [for (final b in found) if (seen.add(b.id.toLowerCase())) b]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return _installed = List.unmodifiable(found);
}

/// The browsers registered with Windows (Clients\StartMenuInternet: the list
/// Default Apps shows; per user first), each with its program.
Future<List<InstalledBrowser>> _windowsBrowsers() async {
  final out = <InstalledBrowser>[];
  for (final root in const [r'HKCU\SOFTWARE\Clients\StartMenuInternet', r'HKLM\SOFTWARE\Clients\StartMenuInternet', r'HKLM\SOFTWARE\WOW6432Node\Clients\StartMenuInternet']) {
    final r = await Process.run('reg', ['query', root, '/s']);
    if (r.exitCode == 0) out.addAll(parseStartMenuInternet('${r.stdout}'));
  }
  return [for (final b in out) if (await File(b.id).exists()) b];
}

/// Reads the output of `reg query ...\Clients\StartMenuInternet /s`: each
/// browser key's default value is its name, and its shell\open\command the
/// program. A default value's name is in parentheses in every language
/// ("(Default)", "(Standard)"). Internet Explorer is left out.
@visibleForTesting
List<InstalledBrowser> parseStartMenuInternet(String output) {
  final names = <String, String>{};
  final commands = <String, String>{};
  final order = <String>[];
  const marker = r'\startmenuinternet\';
  final value = RegExp(r'^\s+(\(.*?\))\s+REG_(?:EXPAND_)?SZ(?:\s+(.*?))?\s*$');
  String? key;
  for (final line in const LineSplitter().convert(output)) {
    if (line.startsWith('HKEY_')) {
      key = line.trim();
      continue;
    }
    final m = value.firstMatch(line);
    final at = key?.toLowerCase().indexOf(marker) ?? -1;
    if (m == null || key == null || at < 0) continue;
    final parts = key.substring(at + marker.length).split(r'\');
    final id = parts.first;
    final data = m.group(2) ?? '';
    if (parts.length == 1) {
      names[id] = data;
    } else if (parts.length == 4 && parts.skip(1).map((s) => s.toLowerCase()).join('/') == 'shell/open/command') {
      commands[id] = data;
    } else {
      continue;
    }
    if (!order.contains(id)) order.add(id);
  }
  final out = <InstalledBrowser>[];
  for (final id in order) {
    if (id.toLowerCase() == 'iexplore.exe') continue;
    final exe = _exeOf(commands[id] ?? '');
    if (exe == null) continue;
    var name = (names[id] ?? '').trim();
    // "(value not set)", in whatever language.
    if (name.startsWith('(') && name.endsWith(')')) name = '';
    out.add(InstalledBrowser(id: exe, name: name.isEmpty ? p.windows.basenameWithoutExtension(exe) : name));
  }
  return out;
}

/// The program of a command line: `"C:\x\chrome.exe" --flag` → `C:\x\chrome.exe`.
String? _exeOf(String command) {
  final c = command.trim();
  String? path;
  if (c.startsWith('"')) {
    final end = c.indexOf('"', 1);
    if (end > 1) path = c.substring(1, end);
  } else {
    path = RegExp(r'^(.+?\.exe)\b', caseSensitive: false).firstMatch(c)?.group(1);
  }
  return path == null ? null : _expandEnv(path);
}

String _expandEnv(String s) => s.replaceAllMapped(RegExp('%([^%]+)%'), (m) => Platform.environment[m.group(1)!] ?? m.group(0)!);

Future<List<InstalledBrowser>> _macInstalled() async {
  final home = Platform.environment['HOME'];
  final out = <InstalledBrowser>[];
  for (final name in _macBrowsers) {
    for (final dir in ['/Applications', if (home != null) '$home/Applications']) {
      final path = '$dir/$name.app';
      if (await Directory(path).exists()) {
        out.add(InstalledBrowser(id: path, name: name));
        break;
      }
    }
  }
  return out;
}

Future<List<InstalledBrowser>> _linuxInstalled() async {
  final out = <InstalledBrowser>[];
  final names = <String>{};
  for (final (cmd, name) in _linuxBrowsers) {
    if (names.contains(name)) continue;
    if ((await Process.run('which', [cmd])).exitCode == 0) {
      out.add(InstalledBrowser(id: cmd, name: name));
      names.add(name);
    }
  }
  return out;
}

Future<bool> browserAvailable(String id) async {
  if ((await installedBrowsers()).any((b) => b.id.toLowerCase() == id.toLowerCase())) return true;
  try {
    // A program the user picked in Settings.
    if (Platform.isMacOS) return await Directory(id).exists();
    if (p.isAbsolute(id)) return await File(id).exists();
    return Platform.isLinux && (await Process.run('which', [id])).exitCode == 0;
  } on Object {
    return false;
  }
}

Future<bool> openInBrowser(String id, Uri url) async {
  if (!(url.isScheme('http') || url.isScheme('https'))) return false;
  try {
    if (Platform.isMacOS) return (await Process.run('open', ['-a', id, url.toString()])).exitCode == 0;
    await Process.start(id, [url.toString()], mode: ProcessStartMode.detached);
    return true;
  } on Object catch (e) {
    debugPrint('Could not open $id: $e');
    return false;
  }
}

/// Raised while reading a request body that is larger than the bridge takes.
class _TooLarge implements Exception {
  const _TooLarge();
}

/// Opens the server socket on [port] of [address]; tests put a stand-in here.
typedef BrowserBridgeBind = Future<HttpServer> Function(InternetAddress address, int port);

/// Did the system refuse the port, rather than another program using it?
/// Windows says 10013 (WSAEACCES, "access forbidden") for a port Hyper-V
/// (WSL, Docker, Windows Sandbox) reserved, or one another program holds
/// exclusively; elsewhere EACCES (13) or EPERM (1).
@visibleForTesting
bool isPortRefused(SocketException e) => const {10013, 13, 1}.contains(e.osError?.errorCode);

/// The bridge server (extensions/browser/PROTOCOL.md) on dart:io.
class IoBrowserBridge extends BrowserBridge {
  IoBrowserBridge({required this._secrets, required this._clock, required this._ports, required this._version, BrowserBridgeBind? bind})
      : _bind = bind ?? HttpServer.bind;

  final SecretStore _secrets;
  final DateTime Function() _clock;
  final List<int> _ports;
  final String _version;
  final BrowserBridgeBind _bind;
  final Random _random = Random.secure();

  final ValueNotifier<BrowserBridgeStatus> _status = ValueNotifier(const BrowserBridgeStatus(BrowserBridgeState.off));
  final ValueNotifier<List<PairedBrowser>> _browsers = ValueNotifier(const []);
  final ValueNotifier<PairingCode?> _pairing = ValueNotifier(null);
  final StreamController<BrowserFillResult> _results = StreamController.broadcast();
  final StreamController<String> _served = StreamController.broadcast();

  HttpServer? _server;
  Future<void>? _starting;
  bool _loaded = false;
  bool _disposed = false;
  int _wrongTries = 0;
  BrowserJob? _job;

  /// The site that last fetched [_job] (shown in "Filled in on ...").
  String? _jobHost;

  /// The page that may post [_job] by itself: the first page of the browser
  /// it was opened in to fetch it, by the id the page sends. An automatic
  /// job is posted from that one page only, never from another tab.
  String? _automaticPage;

  /// [endAutomaticPosting] was called for [_job]: no page posts it by itself.
  bool _automaticEnded = false;

  /// What a page id looks like (`?page=`): random letters and digits.
  static final RegExp _pageId = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

  /// Keychain writes, one after the other.
  Future<void>? _writes;

  static const int _maxBody = 64 * 1024;
  static const _wrongCode = {'error': 'That code is wrong or has expired. Make a new one in NEFORUM.'};

  @override
  ValueListenable<BrowserBridgeStatus> get status => _status;
  @override
  ValueListenable<List<PairedBrowser>> get browsers => _browsers;
  @override
  ValueListenable<PairingCode?> get pairing => _pairing;
  @override
  Stream<BrowserFillResult> get results => _results.stream;
  @override
  Stream<String> get served => _served.stream;
  @override
  DateTime now() => _clock();

  @override
  BrowserJob? get job {
    final j = _job;
    if (j == null) return null;
    if (j.isExpiredAt(_clock())) {
      _setJob(null);
      return null;
    }
    return j;
  }

  /// Makes [job] the one served (null: none), with nobody fetching or
  /// posting it yet.
  void _setJob(BrowserJob? job) {
    _job = job;
    _jobHost = null;
    _automaticPage = null;
    _automaticEnded = false;
  }

  // ---- lifecycle -----------------------------------------------------------

  @override
  Future<void> start() {
    if (_disposed || _server != null) return Future.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    await _load();
    var refused = false;
    final skipped = <String>[];
    for (final port in _ports) {
      if (_disposed) return;
      final HttpServer server;
      try {
        server = await _bind(InternetAddress.loopbackIPv4, port);
      } on SocketException catch (e) {
        // In use, reserved or forbidden: any failure moves on to the next port.
        if (isPortRefused(e)) refused = true;
        skipped.add('$port (${e.osError?.errorCode ?? '?'})');
        continue;
      }
      if (skipped.isNotEmpty) debugPrint('Browser bridge: could not open ${skipped.join(', ')}; using ${server.port}');
      if (_disposed) {
        await server.close(force: true);
        return;
      }
      server
        ..autoCompress = false
        ..idleTimeout = const Duration(seconds: 30);
      // No CORS headers, ever; nothing a browser could sniff or cache.
      server.defaultResponseHeaders
        ..clear()
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('x-content-type-options', 'nosniff');
      _server = server;
      server.listen(_handle, onError: (Object e) => debugPrint('Browser bridge: $e'));
      _status.value = BrowserBridgeStatus(BrowserBridgeState.listening, port: server.port);
      return;
    }
    debugPrint('Browser bridge: could not open any port: ${skipped.join(', ')}');
    _status.value = BrowserBridgeStatus(refused ? BrowserBridgeState.portBlocked : BrowserBridgeState.portBusy);
  }

  @override
  Future<void> stop() async {
    final starting = _starting;
    if (starting != null) await starting;
    final server = _server;
    _server = null;
    _setJob(null);
    cancelPairing();
    if (!_disposed) _status.value = const BrowserBridgeStatus(BrowserBridgeState.off);
    await server?.close(force: true);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _writes;
    await _results.close();
    await _served.close();
  }

  // ---- paired browsers -----------------------------------------------------

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await _secrets.read(kBrowserSecretsKey))?['browsers'];
      if (raw == null) return;
      final list = [
        for (final m in (jsonDecode(raw) as List).whereType<Map<Object?, Object?>>())
          PairedBrowser.fromJson(m.cast<String, dynamic>()),
      ].where((b) => b.token.isNotEmpty).toList();
      _browsers.value = List.unmodifiable(list);
      unawaited(_guessPrograms());
    } on Object catch (e) {
      debugPrint('Browser bridge: could not read the paired browsers: $e');
    }
  }

  /// Gives each paired browser without a program its likely one ("Chrome" is
  /// Google Chrome). The user can change it in Settings.
  Future<void> _guessPrograms() async {
    if (!_browsers.value.any((b) => b.app == null)) return;
    final List<InstalledBrowser> installed;
    try {
      installed = await BrowserBridge.installedBrowsers();
    } on Object {
      return;
    }
    if (_disposed) return;
    final before = _browsers.value;
    final next = [for (final b in before) b.app == null ? b.copyWith(app: guessInstalledBrowser(b.label, installed)) : b];
    if ([for (var i = 0; i < next.length; i++) next[i].app == before[i].app].every((same) => same)) return;
    _browsers.value = List.unmodifiable(next);
    await _persist();
  }

  Future<void> _persist() {
    final list = _browsers.value;
    final json = jsonEncode([for (final b in list) b.toJson()]);
    return _writes = (_writes ?? Future<void>.value()).then((_) async {
      try {
        if (list.isEmpty) {
          await _secrets.delete(kBrowserSecretsKey);
        } else {
          await _secrets.write(kBrowserSecretsKey, {'browsers': json});
        }
      } on Object catch (e) {
        debugPrint('Browser bridge: could not save the paired browsers: $e');
      }
    });
  }

  @override
  Future<void> remove(String token) async {
    await _load();
    final next = [for (final b in _browsers.value) if (b.token != token) b];
    if (next.length == _browsers.value.length) return;
    _browsers.value = List.unmodifiable(next);
    await _persist();
  }

  @override
  Future<void> forgetAll() async {
    await _load();
    _browsers.value = const [];
    await _persist();
  }

  @override
  Future<void> makeFirst(String token) async {
    await _load();
    final list = _browsers.value;
    final i = list.indexWhere((b) => b.token == token);
    if (i <= 0) return;
    _browsers.value = List.unmodifiable([list[i], ...list.take(i), ...list.skip(i + 1)]);
    await _persist();
  }

  @override
  Future<void> setProgram(String token, InstalledBrowser program) async {
    await _load();
    if (!_browsers.value.any((b) => b.token == token)) return;
    _browsers.value = List.unmodifiable([for (final b in _browsers.value) b.token == token ? b.copyWith(app: program) : b]);
    await _persist();
  }

  /// The paired browser whose token is in the `Authorization` header.
  /// Compares against every token in constant time.
  PairedBrowser? _authenticate(HttpRequest req) {
    final values = req.headers[HttpHeaders.authorizationHeader];
    if (values == null || values.length != 1) return null;
    final m = RegExp(r'^bearer\s+(\S+)\s*$', caseSensitive: false).firstMatch(values.single);
    if (m == null) return null;
    final token = m.group(1)!;
    PairedBrowser? found;
    for (final b in _browsers.value) {
      if (_sameSecret(b.token, token)) found = b;
    }
    if (found != null) _touch(found);
    return found;
  }

  /// Updates "last used", at most once a minute (each save is a keychain write).
  void _touch(PairedBrowser b) {
    final now = _clock();
    if (now.difference(b.lastSeen) < kBrowserLastSeenThrottle) return;
    _browsers.value = List.unmodifiable([for (final x in _browsers.value) x.token == b.token ? x.copyWith(lastSeen: now) : x]);
    unawaited(_persist());
  }

  static bool _sameSecret(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// 32 random bytes as unpadded base64url: 43 characters.
  String _newToken() => base64Url.encode(List<int>.generate(32, (_) => _random.nextInt(256))).replaceAll('=', '');

  // ---- pairing -------------------------------------------------------------

  @override
  PairingCode startPairing() {
    final code = PairingCode(code: _random.nextInt(1000000).toString().padLeft(6, '0'), expiresAt: _clock().add(kPairingCodeLifetime));
    _wrongTries = 0;
    _pairing.value = code;
    return code;
  }

  @override
  void cancelPairing() {
    _wrongTries = 0;
    if (!_disposed) _pairing.value = null;
  }

  Future<void> _pair(HttpRequest req) async {
    final body = await _readJson(req);
    final pending = _pairing.value;
    if (pending == null) return _send(req, 403, _wrongCode);
    if (!_clock().isBefore(pending.expiresAt)) {
      cancelPairing();
      return _send(req, 403, _wrongCode);
    }
    final raw = body?['code'];
    final code = raw is String ? raw.trim() : (raw is int ? raw.toString().padLeft(6, '0') : '');
    if (!_sameSecret(code, pending.code)) {
      _wrongTries++;
      if (_wrongTries >= kPairingMaxWrongTries) cancelPairing();
      return _send(req, 403, _wrongCode);
    }
    final now = _clock();
    final browser = PairedBrowser(label: _label(body?['browser']), token: _newToken(), createdAt: now, lastSeen: now);
    // The list first, so Settings sees the new browser when the code goes.
    _browsers.value = List.unmodifiable([..._browsers.value, browser]);
    cancelPairing();
    await _persist();
    unawaited(_guessPrograms());
    return _send(req, 200, {'token': browser.token});
  }

  static String _label(Object? v) {
    var s = v is String ? v.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim() : '';
    if (s.length > 40) s = s.substring(0, 40).trim();
    return s.isEmpty ? 'Browser' : s;
  }

  // ---- jobs ----------------------------------------------------------------

  @override
  BrowserJob? createJob({
    required String platformId,
    required String platformName,
    required String url,
    required List<String> hosts,
    required String text,
    String? title,
    List<HandoffSnippet> snippets = const [],
    List<BrowserJobMedia> media = const [],
    String steps = '',
    bool quickPost = false,
    bool autoPost = false,
    BrowserJobDetails details = const BrowserJobDetails(),
    String? target,
  }) {
    final now = _clock();
    final id = 'j_${List<String>.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final job = BrowserJob(
      id: id,
      platformId: platformId,
      platformName: platformName,
      url: url,
      hosts: List.unmodifiable(hosts),
      text: text,
      title: (title ?? '').trim().isEmpty ? null : title,
      snippets: List.unmodifiable(snippets),
      media: List.unmodifiable(media),
      steps: steps,
      quickPost: quickPost,
      autoPost: autoPost,
      details: details,
      target: target,
      createdAt: now,
      expiresAt: now.add(kBrowserJobLifetime),
    );
    _setJob(job);
    return job;
  }

  @override
  void clearJob([String? id]) {
    if (id != null && _job?.id != id) return;
    _setJob(null);
  }

  @override
  void endAutomaticPosting(String id) {
    if (_job?.id == id) _automaticEnded = true;
  }

  /// The job for `?host=`, with `preferred`: whether [browser] is the one
  /// NEFORUM opened the page in (only that one fills in on its own). An
  /// automatic job says `autoPost: true` only to the page that may post it
  /// (`?page=`, see [_automaticPage]); every other page gets it to fill in.
  Future<void> _getJob(HttpRequest req, PairedBrowser browser) {
    final host = req.uri.queryParameters['host']?.trim() ?? '';
    if (host.isEmpty) return _send(req, 400, {'error': 'Add ?host=<location.host>.'});
    final j = job;
    if (j == null || !j.matchesHost(host)) return _send(req, 204);
    _jobHost = host.toLowerCase();
    final preferred = j.prefers(browser);
    final page = req.uri.queryParameters['page']?.trim() ?? '';
    final automatic = j.autoPost && !_automaticEnded;
    if (automatic && preferred && _automaticPage == null && _pageId.hasMatch(page)) _automaticPage = page;
    if (!_served.isClosed) _served.add(j.id);
    return _send(req, 200, {...j.toJson(), 'autoPost': automatic && page == _automaticPage, 'preferred': preferred});
  }

  Future<void> _media(HttpRequest req, String id, String index) async {
    final j = job;
    final i = RegExp(r'^\d{1,4}$').hasMatch(index) ? int.parse(index) : -1;
    if (j == null || j.id != id || i < 0 || i >= j.media.length) return _send(req, 404, {'error': 'There is no such file (the hand-off may have expired).'});
    final m = j.media[i];
    final Uint8List bytes;
    try {
      bytes = await m.read();
    } on Object catch (e) {
      debugPrint('Browser bridge: could not read ${m.name}: $e');
      return _send(req, 500, {'error': 'NEFORUM could not read ${m.name}.'});
    }
    if (!_served.isClosed) _served.add(j.id);
    final res = req.response;
    res.statusCode = 200;
    try {
      res.headers.contentType = ContentType.parse(m.mimeType);
    } on Object {
      res.headers.contentType = ContentType.binary;
    }
    res.contentLength = bytes.length;
    res.add(bytes);
    await res.close();
  }

  Future<void> _result(HttpRequest req, String id, PairedBrowser browser) async {
    final body = await _readJson(req);
    final j = job;
    if (j == null || j.id != id) return _send(req, 404, {'error': 'That hand-off has expired.'});
    final status = BrowserFillStatus.values.asNameMap()[body?['status']];
    if (body == null || status == null) return _send(req, 400, {'error': 'status must be filled, partial or failed.'});
    final media = body['media'];
    var message = body['message'] is String ? (body['message'] as String).trim() : '';
    if (message.length > 300) message = '${message.substring(0, 300).trim()}…';
    if (_results.isClosed) return _send(req, 503, {'error': 'NEFORUM is stopping.'});
    _results.add(BrowserFillResult(
      jobId: j.id,
      host: _jobHost ?? Uri.tryParse(j.url)?.host ?? '',
      status: status,
      text: body['text'] == true,
      media: media is num ? media.toInt().clamp(0, 999) : 0,
      message: message.isEmpty ? null : message,
      // Only a job that allowed it can be posted from the page.
      posted: j.quickPost || j.autoPost ? BrowserPostState.values.asNameMap()[body['posted']] ?? BrowserPostState.none : BrowserPostState.none,
      automatic: j.autoPost ? BrowserAutomaticState.values.asNameMap()[body['automatic']] ?? BrowserAutomaticState.none : BrowserAutomaticState.none,
      browser: browser.label,
      at: _clock(),
    ));
    return _send(req, 204);
  }

  // ---- HTTP ----------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    try {
      final port = _server?.port;
      if (port == null) return await _send(req, 503, {'error': 'NEFORUM is stopping.'});
      if (!_hostAllowed(req, port)) return await _send(req, 403, {'error': 'Wrong Host header.'});
      if (!_originAllowed(req)) return await _send(req, 403, {'error': 'Only the NEFORUM browser extension can use this.'});

      final path = req.uri.path;
      final method = req.method;
      if (path == '/v1/hello') {
        if (method != 'GET') return await _send(req, 405, {'error': 'Use GET.'});
        return await _send(req, 200, {'app': 'NEFORUM', 'version': _version, 'protocol': kBrowserProtocolVersion, 'paired': _authenticate(req) != null});
      }
      if (path == '/v1/pair') {
        if (method != 'POST') return await _send(req, 405, {'error': 'Use POST.'});
        return await _pair(req);
      }

      final browser = _authenticate(req);
      if (browser == null) return await _send(req, 401, {'error': 'Pair this browser in NEFORUM first.'});

      final seg = req.uri.pathSegments;
      if (path == '/v1/unpair') {
        if (method != 'POST') return await _send(req, 405, {'error': 'Use POST.'});
        await remove(browser.token);
        return await _send(req, 204);
      }
      if (path == '/v1/job') {
        if (method != 'GET') return await _send(req, 405, {'error': 'Use GET.'});
        return await _getJob(req, browser);
      }
      if (seg.length == 5 && seg[0] == 'v1' && seg[1] == 'job' && seg[3] == 'media') {
        if (method != 'GET') return await _send(req, 405, {'error': 'Use GET.'});
        return await _media(req, seg[2], seg[4]);
      }
      if (seg.length == 4 && seg[0] == 'v1' && seg[1] == 'job' && seg[3] == 'result') {
        if (method != 'POST') return await _send(req, 405, {'error': 'Use POST.'});
        return await _result(req, seg[2], browser);
      }
      return await _send(req, 404, {'error': 'Not found.'});
    } on _TooLarge {
      req.response.persistentConnection = false;
      await _trySend(req, 413, {'error': 'Too large.'});
    } on Object catch (e) {
      debugPrint('Browser bridge: ${req.method} ${req.uri.path} failed: $e');
      await _trySend(req, 500, {'error': 'Something went wrong in NEFORUM.'});
    }
  }

  /// DNS rebinding: a page on evil.example resolving to 127.0.0.1 still
  /// sends `Host: evil.example`.
  static bool _hostAllowed(HttpRequest req, int port) {
    final values = req.headers[HttpHeaders.hostHeader];
    if (values == null || values.length != 1) return false;
    final host = values.single.trim().toLowerCase();
    return host == '127.0.0.1:$port' || host == 'localhost:$port';
  }

  /// Requests made by web pages carry their origin; the extension's carry
  /// its own (or none).
  static bool _originAllowed(HttpRequest req) {
    final values = req.headers['origin'];
    if (values == null || values.isEmpty) return true;
    if (values.length != 1) return false;
    final origin = values.single.trim().toLowerCase();
    return origin.startsWith('chrome-extension://') || origin.startsWith('moz-extension://') || origin.startsWith('safari-web-extension://');
  }

  /// The JSON object in the body, `{}` when empty, null when it is not an
  /// object. Throws [_TooLarge] past 64 KB.
  static Future<Map<String, dynamic>?> _readJson(HttpRequest req) async {
    if (req.contentLength > _maxBody) throw const _TooLarge();
    final b = BytesBuilder(copy: false);
    await for (final chunk in req) {
      b.add(chunk);
      if (b.length > _maxBody) throw const _TooLarge();
    }
    if (b.isEmpty) return const {};
    try {
      final v = jsonDecode(utf8.decode(b.takeBytes()));
      return v is Map<String, dynamic> ? v : null;
    } on FormatException {
      return null;
    }
  }

  static Future<void> _send(HttpRequest req, int status, [Map<String, Object?>? body]) async {
    final res = req.response;
    res.statusCode = status;
    if (body == null) {
      res.contentLength = 0;
    } else {
      final bytes = utf8.encode(jsonEncode(body));
      res.headers.contentType = ContentType.json;
      res.contentLength = bytes.length;
      res.add(bytes);
    }
    await res.close();
  }

  static Future<void> _trySend(HttpRequest req, int status, Map<String, Object?> body) async {
    try {
      await _send(req, status, body);
    } on Object {
      // The response may already be under way; nothing more to do.
    }
  }
}
