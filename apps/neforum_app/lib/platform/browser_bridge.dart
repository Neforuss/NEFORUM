import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' show ArtworkDetails, HandoffSnippet, MediaAttachment, PostPoll, PostVariant, SecretStore;
import 'package:path/path.dart' as p;

import 'browser_bridge_web.dart' if (dart.library.io) 'browser_bridge_io.dart' as impl;
import 'env.dart';

/// Secret-store key holding the paired browsers (label, token, dates) as JSON.
const String kBrowserSecretsKey = 'neforum.browser';

/// Ports the bridge tries, in order (52771 is the OAuth loopback); the
/// extension (extensions/browser/src/background.js) looks on the same list.
/// The 5277x ports come first, so existing setups keep working. They are in
/// Windows' dynamic port range (49152 to 65535), where Hyper-V (WSL, Docker,
/// Windows Sandbox) reserves random blocks of ports at startup; the
/// [kBrowserBridgeFallbackPorts] are below that range, so they stay free when
/// those are reserved.
const List<int> kBrowserBridgePorts = [52772, 52773, 52774, 52775, 52776, 52777, 52778, 52779, ...kBrowserBridgeFallbackPorts];

/// The ports tried when none of the 5277x ones can be opened. Extensions
/// before 1.0.1 don't look on these.
const List<int> kBrowserBridgeFallbackPorts = [41772, 41773, 41774, 41775, 41776, 41777, 41778, 41779];

/// Only extensions from 1.0.1 on find the bridge on [port].
bool isFallbackPort(int? port) => kBrowserBridgeFallbackPorts.contains(port);

/// [ports] as runs of consecutive ports: "52772 to 52779 and 41772 to 41779".
String describePorts(List<int> ports) {
  final runs = <String>[];
  for (var i = 0; i < ports.length;) {
    var j = i;
    while (j + 1 < ports.length && ports[j + 1] == ports[j] + 1) {
      j++;
    }
    runs.add(i == j ? '${ports[i]}' : '${ports[i]} to ${ports[j]}');
    i = j + 1;
  }
  if (runs.length < 2) return runs.join();
  return '${runs.sublist(0, runs.length - 1).join(', ')} and ${runs.last}';
}

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

  /// No port of [kBrowserBridgePorts] could be opened, and the system refused
  /// at least one ("access forbidden": on Windows, error 10013, a port
  /// reserved by Hyper-V or held exclusively by another program).
  portBlocked,

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

/// The name a hand-off file gets on the page: its own file name, else
/// "NEFORUM card" for a generated card, else its id, with its extension.
String browserJobFileName(MediaAttachment m) {
  if ((m.fileName ?? '').isNotEmpty) return m.fileName!;
  final ext = p.extension(m.path).isEmpty ? (m.isVideo ? '.mp4' : '.jpg') : p.extension(m.path);
  return m.generated ? 'NEFORUM card$ext' : '${m.id}$ext';
}

/// The files of a hand-off for the extension, each read only when asked for.
List<BrowserJobMedia> browserJobMedia(List<MediaAttachment> files, Future<Uint8List> Function(MediaAttachment m) read) => [
      for (final m in files)
        BrowserJobMedia(name: browserJobFileName(m), mimeType: m.mimeType, size: m.sizeBytes, isVideo: m.isVideo, read: () => read(m)),
    ];

/// The parts of a post that sites keep in fields of their own, so the
/// extension can fill each one: the thread's parts, the description apart
/// from the title, the tags, the poll or quiz, and the artwork labels.
@immutable
class BrowserJobDetails {
  const BrowserJobDetails({this.parts = const [], this.description, this.tags = const [], this.poll, this.artwork});

  /// What [variant] holds of these.
  factory BrowserJobDetails.fromVariant(PostVariant variant) => BrowserJobDetails(
        parts: variant.isThread ? List.unmodifiable(variant.threadParts) : const [],
        description: variant.text.trim().isEmpty ? null : variant.text,
        tags: List.unmodifiable(variant.tags),
        poll: variant.poll,
        artwork: variant.artwork,
      );

  /// Every part of a thread, the first one included; empty for a single post.
  final List<String> parts;

  /// The post's text alone (no title, no tags), for sites with a description
  /// field (video uploads, art sites).
  final String? description;

  /// Tags without `#`.
  final List<String> tags;
  final PostPoll? poll;
  final ArtworkDetails? artwork;

  /// The fields of the job's JSON (only those with something in them).
  Map<String, Object?> toJson() {
    final poll = this.poll;
    final answers = poll?.cleanOptions ?? const <String>[];
    return {
      if (parts.length > 1) 'parts': parts,
      if (description != null) 'description': description,
      if (tags.isNotEmpty) 'tags': tags,
      if (poll != null && answers.isNotEmpty)
        'poll': {
          'kind': poll.kind.name,
          'imageOptions': poll.imageOptions,
          'options': answers,
          if (poll.isQuiz && _correctAnswer(poll) != null) 'correctIndex': _correctAnswer(poll),
          if (poll.isQuiz && (poll.explanation ?? '').trim().isNotEmpty) 'explanation': poll.explanation!.trim(),
        },
      if (artwork != null) 'artwork': artwork!.toJson(),
    };
  }

  /// Index of the quiz's correct answer among the non-empty answers.
  static int? _correctAnswer(PostPoll poll) {
    final c = poll.correctIndex;
    if (c == null || c < 0 || c >= poll.options.length || poll.options[c].trim().isEmpty) return null;
    return poll.options.take(c).where((o) => o.trim().isNotEmpty).length;
  }
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
    this.autoPost = false,
    this.details = const BrowserJobDetails(),
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

  /// Automatic posting (Settings > Browser extension > Post automatically,
  /// for this network): once the page is filled in, the extension counts
  /// down 3 seconds (the user can stop it) and presses Post itself. Only
  /// one page posts it: the first one of the browser it was opened in that
  /// fetches it (see [BrowserBridge.endAutomaticPosting]).
  final bool autoPost;

  /// The thread's parts, title-free description, tags, poll and artwork
  /// labels, for sites that take them in fields of their own.
  final BrowserJobDetails details;

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
        'autoPost': autoPost,
        ...details.toJson(),
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

/// Where automatic posting stands on the page (jobs with
/// [BrowserJob.autoPost] only). Only the page that posts the job says; see
/// [otherPage].
enum BrowserAutomaticState {
  /// Nothing reported about automatic posting: the job is not automatic, or
  /// the report came from an extension before 1.1.0, which sends no page id
  /// and never posts by itself.
  none,

  /// The page is filled in; the extension presses Post when its 3-second
  /// countdown ends.
  countdown,

  /// The user stopped the countdown on the page: nothing was posted.
  stopped,

  /// The extension did not post: something was not filled in, the site asks
  /// for a choice, its Post button was not found, or the user had the page
  /// filled in again. The page stays filled in for the user.
  manual,

  /// Another page of the site reported (another tab, a reload, another
  /// browser): it fills the job in but never posts it by itself, so its
  /// report says nothing about automatic posting. A post made from it still
  /// counts ([BrowserFillResult.posted]).
  otherPage,
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
    this.automatic = BrowserAutomaticState.none,
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
  final BrowserAutomaticState automatic;

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
  // wa.me forwards to api.whatsapp.com, which hands over to WhatsApp Web.
  ['web.whatsapp.com', 'wa.me', 'api.whatsapp.com'],
  ['business.google.com'],
  ['snapchat.com', 'www.snapchat.com'],
  // Art and portfolio sites.
  ['behance.net', 'www.behance.net'],
  ['artstation.com', 'www.artstation.com'],
  ['cara.app'],
  ['pixiv.net', 'www.pixiv.net'],
  ['itaku.ee'],
  ['newgrounds.com', 'www.newgrounds.com'],
  ['furaffinity.net', 'www.furaffinity.net'],
  ['weasyl.com', 'www.weasyl.com'],
  ['ko-fi.com'],
  ['artfol.app', 'artfol.co'],
  ['500px.com', 'web.500px.com'],
  ['dribbble.com'],
  ['flickr.com', 'www.flickr.com'],
];

/// Hosts that only one platform's job matches besides its own page:
/// youtube.com/upload forwards to YouTube Studio's upload dialog, and only a
/// video hand-off belongs there (a YouTube Posts job must not fill in Studio).
const Map<String, List<String>> _platformHosts = {
  'youtube': ['studio.youtube.com'],
};

/// The hosts a job for [url] should match: its own host and known aliases,
/// plus the hosts only [platformId]'s page forwards to.
List<String> browserJobHosts(Uri url, {String? platformId}) {
  final host = url.host.toLowerCase();
  if (host.isEmpty) return const [];
  final bare = bareHost(host);
  final out = <String>{host};
  for (final group in _hostAliases) {
    if (group.any((h) => bareHost(h) == bare)) out.addAll(group);
  }
  out.addAll(_platformHosts[platformId] ?? const []);
  return out.toList();
}

/// The sites the extension's content scripts run on by themselves: the
/// `matches` of extensions/browser/manifest.chrome.json and
/// manifest.firefox.json, without `https://` and `/*` (test/
/// browser_bridge_test.dart keeps them the same). On any other site the
/// extension fills a page in only when the user asks from its popup.
const List<String> kExtensionPageHosts = [
  'x.com', 'twitter.com', 'bsky.app', //
  'www.threads.com', 'www.threads.net', 'threads.com', 'threads.net', //
  'www.linkedin.com', 'www.facebook.com', 'm.facebook.com', //
  'www.youtube.com', 'studio.youtube.com', 'substack.com', 'www.tiktok.com', 'www.instagram.com', //
  '*.pinterest.com', 'www.reddit.com', 'www.tumblr.com', //
  'web.whatsapp.com', 'business.google.com', 'www.snapchat.com', //
  'www.behance.net', 'www.artstation.com', 'cara.app', 'www.pixiv.net', 'itaku.ee', //
  'www.newgrounds.com', 'www.furaffinity.net', 'www.weasyl.com', 'ko-fi.com', 'artfol.app', //
  '500px.com', 'web.500px.com', 'dribbble.com', 'www.flickr.com',
];

/// Does the extension fill in the page at [url] by itself: do its content
/// scripts run there, or on the page that host forwards to (wa.me goes on
/// to WhatsApp Web)? Only such a page can report back, so automatic
/// posting opens no other.
bool extensionFillsPage(Uri url, {String? platformId}) {
  if (!url.isScheme('https')) return false;
  bool runsOn(String host) => kExtensionPageHosts.any((m) => m.startsWith('*.') ? host == m.substring(2) || host.endsWith(m.substring(1)) : host == m);
  return browserJobHosts(url, platformId: platformId).any((h) => runsOn(h.toLowerCase()));
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

  /// The id of the job each time a page fetches it or one of its files: the
  /// page is still at work on it, though it has not reported yet.
  Stream<String> get served;

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
  /// [autoPost]: the extension posts by itself once the page is filled in
  /// (see [BrowserJob.autoPost]).
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
  });

  /// Drops the job (only if it is still [id], when given).
  void clearJob([String? id]);

  /// No page posts the job [id] by itself any more (automatic posting ended
  /// without a post, or was cancelled). The job stays, to fill in again and
  /// to take the page's reports, a post made from the page included.
  void endAutomaticPosting(String id);

  Future<void> dispose();
}
