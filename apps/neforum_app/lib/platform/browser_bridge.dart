import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' show HandoffSnippet, SecretStore;

import 'browser_bridge_web.dart' if (dart.library.io) 'browser_bridge_io.dart' as impl;
import 'env.dart';

/// Secret-store key holding the paired browsers (label, token, dates) as JSON.
const String kBrowserSecretsKey = 'neforum.browser';

/// Ports the bridge tries, in order (52771 is the OAuth loopback).
const List<int> kBrowserBridgePorts = [52772, 52773, 52774, 52775, 52776, 52777, 52778, 52779];

/// Version of extensions/browser/PROTOCOL.md this app speaks.
const int kBrowserProtocolVersion = 1;

/// How long a pairing code works, and how many wrong tries cancel it.
const Duration kPairingCodeLifetime = Duration(minutes: 5);
const int kPairingMaxWrongTries = 5;

/// How long a hand-off stays available to the extension.
const Duration kBrowserJobLifetime = Duration(minutes: 10);

/// "Last used" is saved at most this often per browser (each save is a
/// keychain write).
const Duration kBrowserLastSeenThrottle = Duration(minutes: 1);

enum BrowserBridgeState {
  /// Not listening: the setting is off, or the app has not started it.
  off,
  listening,

  /// Every port of [kBrowserBridgePorts] is taken by another program.
  portBusy,

  /// Web and phones: there is no extension to talk to.
  unsupported,
}

@immutable
class BrowserBridgeStatus {
  const BrowserBridgeStatus(this.state, {this.port});
  final BrowserBridgeState state;

  /// The port while [state] is [BrowserBridgeState.listening].
  final int? port;

  bool get listening => state == BrowserBridgeState.listening;

  @override
  bool operator ==(Object other) => other is BrowserBridgeStatus && other.state == state && other.port == port;

  @override
  int get hashCode => Object.hash(state, port);
}

/// A browser that paired with NEFORUM; its token is a key, kept in the
/// system keychain.
@immutable
class PairedBrowser {
  const PairedBrowser({required this.label, required this.token, required this.createdAt, required this.lastSeen, this.app, this.appName});

  factory PairedBrowser.fromJson(Map<String, dynamic> j) {
    final created = DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final app = j['app'] as String?;
    return PairedBrowser(
      label: j['label'] as String? ?? 'Browser',
      token: j['token'] as String? ?? '',
      createdAt: created,
      lastSeen: DateTime.tryParse(j['lastSeen'] as String? ?? '') ?? created,
      app: app == null || app.isEmpty ? null : app,
      appName: j['appName'] as String?,
    );
  }

  /// What the extension called itself: "Chrome", "Firefox", "Microsoft Edge",
  /// "Chromium-based browser". Chromium browsers can look alike, so [app]
  /// says which program it really is.
  final String label;
  final String token;
  final DateTime createdAt;
  final DateTime lastSeen;

  /// The installed program this browser is ([InstalledBrowser.id]): where
  /// NEFORUM opens hand-offs for it. Guessed at pairing, set by the user in
  /// Settings; null when unknown.
  final String? app;

  /// That program's name ("Google Chrome", "Helium"), for showing.
  final String? appName;

  PairedBrowser copyWith({DateTime? lastSeen, InstalledBrowser? app, bool clearApp = false}) => PairedBrowser(
        label: label,
        token: token,
        createdAt: createdAt,
        lastSeen: lastSeen ?? this.lastSeen,
        app: clearApp ? null : (app?.id ?? this.app),
        appName: clearApp ? null : (app?.name ?? appName),
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'token': token,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'lastSeen': lastSeen.toUtc().toIso8601String(),
        if (app != null) 'app': app,
        if (app != null && appName != null) 'appName': appName,
      };
}

/// A web browser installed on this computer.
@immutable
class InstalledBrowser {
  const InstalledBrowser({required this.id, required this.name});

  /// What starts it: the program's path on Windows (`...\chrome.exe`), the
  /// app's path on macOS (`/Applications/Helium.app`), a command on Linux.
  /// Two browsers can share a file name (Helium's is chrome.exe too), never
  /// a path.
  final String id;

  /// "Google Chrome", "Helium", "Mozilla Firefox".
  final String name;

  @override
  bool operator ==(Object other) => other is InstalledBrowser && other.id.toLowerCase() == id.toLowerCase();

  @override
  int get hashCode => id.toLowerCase().hashCode;
}

/// The installed program a browser labelled [label] most likely is: the
/// first of [installed] of the same [browserFamily] ("Chrome" is Google
/// Chrome, not another Chromium browser). Null when none matches.
InstalledBrowser? guessInstalledBrowser(String label, List<InstalledBrowser> installed) {
  final family = browserFamily(label);
  return installed.where((b) => browserFamily(b.name) == family).firstOrNull;
}

/// The 6-digit code shown in Settings while a browser pairs.
@immutable
class PairingCode {
  const PairingCode({required this.code, required this.expiresAt});
  final String code;
  final DateTime expiresAt;
}

/// One file of a hand-off. The bytes are read only when the extension asks
/// for them, so a big video is never held in memory for nothing.
@immutable
class BrowserJobMedia {
  const BrowserJobMedia({required this.name, required this.mimeType, required this.size, required this.read, this.isVideo = false});
  final String name;
  final String mimeType;
  final int size;
  final bool isVideo;
  final Future<Uint8List> Function() read;

  /// `image` (GIFs included) or `video`.
  String get kind => isVideo ? 'video' : 'image';
}

/// A hand-off waiting for the extension (`GET /v1/job`).
@immutable
class BrowserJob {
  const BrowserJob({
    required this.id,
    required this.platformId,
    required this.platformName,
    required this.url,
    required this.hosts,
    required this.text,
    this.title,
    this.snippets = const [],
    this.media = const [],
    this.steps = '',
    this.quickPost = false,
    this.target,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final String platformId;
  final String platformName;
  final String url;
  final List<String> hosts;
  final String text;
  final String? title;
  final List<HandoffSnippet> snippets;
  final List<BrowserJobMedia> media;
  final String steps;

  /// The extension may post when the user presses Ctrl+Enter (⌘+Enter) or
  /// its Post now button.
  final bool quickPost;

  /// The program NEFORUM opened the page in ([InstalledBrowser.id]): paired
  /// browsers set to that program fill it in on their own, others only when
  /// asked. Null: any browser.
  final String? target;
  final DateTime createdAt;
  final DateTime expiresAt;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  /// Is [browser] the one meant to fill this in on its own?
  bool prefers(PairedBrowser browser) => target == null || browser.app?.toLowerCase() == target!.toLowerCase();

  /// [host] (a page's `location.host`) without a leading `www.` equals one
  /// of [hosts] without `www.`.
  bool matchesHost(String host) {
    final h = bareHost(host);
    return h.isNotEmpty && hosts.any((x) => bareHost(x) == h);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'platformId': platformId,
        'platformName': platformName,
        'url': url,
        'hosts': hosts,
        'text': text,
        'title': title,
        'snippets': [for (final s in snippets) {'label': s.label, 'text': s.text}],
        'media': [
          for (var i = 0; i < media.length; i++)
            {'index': i, 'name': media[i].name, 'mimeType': media[i].mimeType, 'size': media[i].size, 'kind': media[i].kind},
        ],
        'steps': steps,
        'quickPost': quickPost,
        'createdAt': _isoSeconds(createdAt),
        'expiresAt': _isoSeconds(expiresAt),
      };

  /// `2026-10-12T10:00:00Z`, as in the protocol.
  static String _isoSeconds(DateTime t) => t.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
}

enum BrowserFillStatus { filled, partial, failed }

/// Whether the user posted from the page with the extension's shortcut.
enum BrowserPostState {
  /// Not posted with the shortcut (the user may still press Post themselves).
  none,

  /// The extension pressed Post but could not see the post go out.
  pressed,

  /// The extension pressed Post and the composer closed or emptied.
  confirmed,
}

/// What the extension reported after filling in a page
/// (`POST /v1/job/<id>/result`).
@immutable
class BrowserFillResult {
  const BrowserFillResult({
    required this.jobId,
    required this.host,
    required this.status,
    this.text = false,
    this.media = 0,
    this.message,
    this.posted = BrowserPostState.none,
    this.browser,
    required this.at,
  });
  final String jobId;

  /// The site that asked for the job (or the job's own host).
  final String host;
  final BrowserFillStatus status;

  /// The text went in.
  final bool text;

  /// How many files went in.
  final int media;
  final String? message;
  final BrowserPostState posted;

  /// The label of the browser that reported ("Firefox").
  final String? browser;
  final DateTime at;
}

/// A browser label or program name ("Chrome", "Google Chrome", "Microsoft
/// Edge", "Mozilla Firefox") as one lowercase word: `chrome`, `edge`,
/// `firefox`, `opera`, `brave`, `helium`..., or the label itself.
String browserFamily(String label) {
  final l = label.trim().toLowerCase();
  if (l.contains('chromium')) return 'chromium';
  for (final f in const ['firefox', 'edge', 'opera', 'brave', 'vivaldi', 'helium', 'thorium', 'chrome']) {
    if (l.contains(f)) return f;
  }
  return l;
}

/// [host] in lower case, without a leading `www.`.
String bareHost(String host) {
  final h = host.trim().toLowerCase();
  return h.startsWith('www.') ? h.substring(4) : h;
}

/// Hosts that serve the same composer, so a job for one matches the others
/// (`www.` is ignored when matching anyway).
const List<List<String>> _hostAliases = [
  ['x.com', 'twitter.com', 'mobile.twitter.com'],
  ['threads.com', 'threads.net'],
  ['youtube.com', 'www.youtube.com', 'm.youtube.com'],
  ['tiktok.com', 'www.tiktok.com'],
  ['instagram.com', 'www.instagram.com'],
  ['facebook.com', 'www.facebook.com', 'm.facebook.com'],
  ['linkedin.com', 'www.linkedin.com'],
  ['reddit.com', 'www.reddit.com', 'old.reddit.com', 'new.reddit.com'],
  ['pinterest.com', 'www.pinterest.com'],
  ['bsky.app'],
  ['substack.com'],
  ['tumblr.com', 'www.tumblr.com'],
  ['web.whatsapp.com'],
  ['business.google.com'],
  ['snapchat.com', 'www.snapchat.com'],
];

/// The hosts a job for [url] should match: its own host and known aliases.
List<String> browserJobHosts(Uri url) {
  final host = url.host.toLowerCase();
  if (host.isEmpty) return const [];
  final bare = bareHost(host);
  final out = <String>{host};
  for (final group in _hostAliases) {
    if (group.any((h) => bareHost(h) == bare)) out.addAll(group);
  }
  return out.toList();
}

/// Finds installed browsers and opens pages in a chosen one. Windows: the
/// browsers registered with Windows (the list Default Apps shows); macOS:
/// browser apps in the Applications folders; Linux: browser commands on the
/// PATH.
class BrowserLauncher {
  const BrowserLauncher();

  /// The installed browsers, by name. Looked up once, then cached; [refresh]
  /// looks again.
  Future<List<InstalledBrowser>> list({bool refresh = false}) => impl.installedBrowsers(refresh: refresh);

  /// Can [id] be started (listed, or a program the user picked that exists)?
  Future<bool> available(String id) => impl.browserAvailable(id);

  /// Opens [url] in [id]. False when it would not start.
  Future<bool> open(String id, Uri url) => impl.openInBrowser(id, url);
}

/// The local server the NEFORUM browser extension talks to
/// (extensions/browser/PROTOCOL.md): 127.0.0.1 only, on the first free port
/// of [kBrowserBridgePorts]. Desktop only; a no-op on the web.
abstract class BrowserBridge {
  /// [clock] is injectable for tests; [ports] may be `[0]` for an ephemeral
  /// port.
  static BrowserBridge create({required SecretStore secrets, DateTime Function()? clock, List<int> ports = kBrowserBridgePorts, String version = kAppVersion}) =>
      impl.createBrowserBridge(secrets: secrets, clock: clock ?? DateTime.now, ports: ports, version: version);

  /// Opens the file manager on the extension folders bundled with the app
  /// (`assets/browser-extension/chrome` and `.../firefox`). Returns the
  /// folder, or null when this build has none.
  static Future<String?> revealExtensionFiles() => impl.revealExtensionFiles();

  /// Finds and starts installed browsers; tests put a stand-in here.
  static BrowserLauncher launcher = const BrowserLauncher();

  /// The browsers installed here (desktop only; empty elsewhere).
  static Future<List<InstalledBrowser>> installedBrowsers({bool refresh = false}) => launcher.list(refresh: refresh);

  /// Opens [url] in the installed browser [id]. False when it would not start.
  static Future<bool> openInBrowser(String id, Uri url) => launcher.open(id, url);

  /// The program [browser] opens in: the one chosen in Settings, else a
  /// guess from its label among [installed].
  static InstalledBrowser? programFor(PairedBrowser browser, List<InstalledBrowser> installed) {
    final app = browser.app;
    if (app == null) return guessInstalledBrowser(browser.label, installed);
    return installed.where((b) => b.id.toLowerCase() == app.toLowerCase()).firstOrNull ?? InstalledBrowser(id: app, name: browser.appName ?? browser.label);
  }

  /// The first paired browser, in the user's order, whose program can be
  /// started, with that program. Null when none can.
  Future<({PairedBrowser browser, InstalledBrowser program})?> firstChoice() async {
    final installed = await installedBrowsers();
    for (final b in browsers.value) {
      final program = programFor(b, installed);
      if (program == null || !await launcher.available(program.id)) continue;
      // Keep the guess, so the bridge knows this browser is that program.
      if (b.app == null) await setProgram(b.token, program);
      return (browser: b, program: program);
    }
    return null;
  }

  ValueListenable<BrowserBridgeStatus> get status;

  /// Paired browsers, loaded from the keychain by [start].
  ValueListenable<List<PairedBrowser>> get browsers;

  /// The pairing code on show, if any.
  ValueListenable<PairingCode?> get pairing;

  /// What the extension managed to fill in, per job.
  Stream<BrowserFillResult> get results;

  /// The hand-off waiting for the extension (null when none or expired).
  BrowserJob? get job;

  /// The bridge's clock.
  DateTime now();

  /// Listening, with at least one paired browser: hand-offs go to the
  /// extension.
  bool get canFill => status.value.listening && browsers.value.isNotEmpty;

  Future<void> start();

  /// Stops listening and drops the job and any pairing code.
  Future<void> stop();

  /// Makes a new 6-digit code (replacing any other).
  PairingCode startPairing();
  void cancelPairing();

  /// Forgets the browser with [token].
  Future<void> remove(String token);

  /// Forgets every paired browser.
  Future<void> forgetAll();

  /// Moves the browser with [token] to the top: the first choice.
  Future<void> makeFirst(String token);

  /// Sets the program the browser with [token] is (where hand-offs for it
  /// open, and which pages it fills in on its own).
  Future<void> setProgram(String token, InstalledBrowser program);

  /// Swaps the first choice with the next browser that is a different
  /// program (Chrome and Firefox trade places; two Chrome profiles don't).
  Future<void> swapFirstTwo() async {
    final list = browsers.value;
    if (list.length < 2) return;
    String key(PairedBrowser b) => (b.app ?? browserFamily(b.label)).toLowerCase();
    final first = key(list.first);
    final next = list.skip(1).where((b) => key(b) != first).firstOrNull ?? list[1];
    await makeFirst(next.token);
  }

  /// Makes the hand-off the extension gets next, replacing any other.
  /// [target]: the program the page was opened in (see [BrowserJob.target]).
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
    String? target,
  });

  /// Drops the job (only if it is still [id], when given).
  void clearJob([String? id]);

  Future<void> dispose();
}
