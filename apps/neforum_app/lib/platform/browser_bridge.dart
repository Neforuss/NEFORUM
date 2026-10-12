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
  const PairedBrowser({required this.label, required this.token, required this.createdAt, required this.lastSeen});

  factory PairedBrowser.fromJson(Map<String, dynamic> j) {
    final created = DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return PairedBrowser(
      label: j['label'] as String? ?? 'Browser',
      token: j['token'] as String? ?? '',
      createdAt: created,
      lastSeen: DateTime.tryParse(j['lastSeen'] as String? ?? '') ?? created,
    );
  }

  /// What the extension called itself: "Chrome", "Firefox", "Microsoft Edge".
  final String label;
  final String token;
  final DateTime createdAt;
  final DateTime lastSeen;

  PairedBrowser copyWith({DateTime? lastSeen}) => PairedBrowser(label: label, token: token, createdAt: createdAt, lastSeen: lastSeen ?? this.lastSeen);

  Map<String, dynamic> toJson() => {
        'label': label,
        'token': token,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'lastSeen': lastSeen.toUtc().toIso8601String(),
      };
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
  final DateTime createdAt;
  final DateTime expiresAt;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

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
        'createdAt': _isoSeconds(createdAt),
        'expiresAt': _isoSeconds(expiresAt),
      };

  /// `2026-10-12T10:00:00Z`, as in the protocol.
  static String _isoSeconds(DateTime t) => t.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
}

enum BrowserFillStatus { filled, partial, failed }

/// What the extension reported after filling in a page
/// (`POST /v1/job/<id>/result`).
@immutable
class BrowserFillResult {
  const BrowserFillResult({required this.jobId, required this.host, required this.status, this.text = false, this.media = 0, this.message, required this.at});
  final String jobId;

  /// The site that asked for the job (or the job's own host).
  final String host;
  final BrowserFillStatus status;

  /// The text went in.
  final bool text;

  /// How many files went in.
  final int media;
  final String? message;
  final DateTime at;
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

  /// Makes the hand-off the extension gets next, replacing any other.
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
  });

  /// Drops the job (only if it is still [id], when given).
  void clearJob([String? id]);

  Future<void> dispose();
}
