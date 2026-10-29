import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'update_check_web.dart' if (dart.library.io) 'update_check_io.dart' as impl;

/// Set by `--dart-define=NEFORUM_STORE_BUILD=true` for builds that a store
/// (Flathub, F-Droid, an app store) updates: NEFORUM then never checks for
/// updates itself, and Settings shows no Updates section.
const bool kStoreBuild = bool.fromEnvironment('NEFORUM_STORE_BUILD');

/// The one file the update check reads: the newest version, its notes and
/// its downloads (see tool/make_latest_json.dart).
const String kLatestReleaseUrl = 'https://neforus.com/neforum/latest.json';

/// Where the Download button leads: the download page, never a file that
/// NEFORUM would run by itself.
const String kDownloadPageUrl = 'https://neforus.com/neforum/';

/// The only User-Agent the update check sends. Fixed and without a version:
/// Dart's default ("Dart/3.x (dart:io)") would tell the server which Dart,
/// and so roughly which NEFORUM, is asking.
const String kUpdateCheckUserAgent = 'NEFORUM update check';

/// Whether this build may check for updates at all: not the web preview, not
/// a store build, and not a copy that Flatpak or Snap installed (those update
/// it themselves).
bool get updateChecksAvailable => !kIsWeb && !kStoreBuild && !impl.installedByPackageManager;

/// Settings > Updates: what NEFORUM does about new versions.
enum UpdateCheckMode {
  /// Not decided yet: NEFORUM asks once (on the first start, and once after
  /// an update from 1.2, which had no update check).
  ask,

  /// At most once a day, at a random time after start.
  automatic,

  /// Never, except when the user presses Check now.
  off,
}

/// Compares two version strings part by part as numbers: `1.10.0` is newer
/// than `1.9.9`, and a missing part counts as 0 (`1.3` equals `1.3.0`).
/// Anything after the digits of a part (`0-beta`, `+20`) is ignored. Negative
/// when [a] is older than [b], zero when equal, positive when newer.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
        for (final p in v.trim().split('+').first.split('.'))
          int.tryParse(RegExp(r'^\d+').stringMatch(p) ?? '') ?? 0,
      ];
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < math.max(x.length, y.length); i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// One file of a release in latest.json: where it is and its SHA-256.
@immutable
class ReleaseDownload {
  const ReleaseDownload({required this.url, required this.sha256});

  final String url;

  /// Lowercase hex.
  final String sha256;

  Map<String, dynamic> toJson() => {'url': url, 'sha256': sha256};
}

/// The newest release as latest.json describes it:
///
/// ```json
/// {"version": "1.3.0", "published": "2026-11-02T10:00:00Z",
///  "notes": "...", "critical": false,
///  "downloads": {"windows-installer": {"url": "https://...", "sha256": "..."}}}
/// ```
@immutable
class LatestRelease {
  const LatestRelease({required this.version, this.published, this.notes = '', this.critical = false, this.downloads = const {}});

  /// Reads latest.json. Throws a [FormatException] when it is not one (no
  /// usable version); downloads that are incomplete are left out.
  factory LatestRelease.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('latest.json is not an object');
    final version = json['version'];
    if (version is! String || !RegExp(r'^\d+(\.\d+)*$').hasMatch(version.trim())) {
      throw FormatException('latest.json has no usable version: $version');
    }
    final downloads = <String, ReleaseDownload>{};
    final d = json['downloads'];
    if (d is Map) {
      for (final e in d.entries) {
        final v = e.value;
        if (e.key is String && v is Map && v['url'] is String && v['sha256'] is String) {
          final sha = (v['sha256'] as String).toLowerCase();
          final url = Uri.tryParse(v['url'] as String);
          if (url != null && url.isScheme('https') && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
            downloads[e.key as String] = ReleaseDownload(url: url.toString(), sha256: sha);
          }
        }
      }
    }
    final notes = json['notes'];
    return LatestRelease(
      version: version.trim(),
      published: json['published'] is String ? DateTime.tryParse(json['published'] as String) : null,
      notes: notes is String ? notes.trim() : '',
      critical: json['critical'] == true,
      downloads: Map.unmodifiable(downloads),
    );
  }

  final String version;
  final DateTime? published;

  /// Release notes (plain text or Markdown).
  final String notes;

  /// A fix the user should not wait for (a security problem, posts lost):
  /// NEFORUM shows a stronger, warning-coloured banner.
  final bool critical;

  /// Keyed by download name (`windows-installer`, `linux-x64-appimage`, ...).
  final Map<String, ReleaseDownload> downloads;

  /// Newer than [current] (normally kAppVersion).
  bool isNewerThan(String current) => compareVersions(version, current) > 0;

  Map<String, dynamic> toJson() => {
        'version': version,
        if (published != null) 'published': published!.toUtc().toIso8601String(),
        'notes': notes,
        'critical': critical,
        'downloads': {for (final e in downloads.entries) e.key: e.value.toJson()},
      };
}

/// When automatic checks happen: at most once a [interval], and never right
/// at start, so a launch alone does not reveal itself to the server (and
/// many installations do not ask at the same moment).
abstract final class UpdateSchedule {
  static const Duration interval = Duration(days: 1);

  /// The random wait after start, before a check that is due.
  static const Duration minimumDelay = Duration(minutes: 10);
  static const Duration maximumDelay = Duration(hours: 2);

  /// How long from [now] until the next automatic check, given the last
  /// one ([lastCheck], null when there was none): the rest of the day since
  /// the last check, plus a random delay between [minimumDelay] and
  /// [maximumDelay]. A [lastCheck] in the future (the clock was set back)
  /// waits one [interval] at most.
  static Duration nextDelay({required DateTime now, DateTime? lastCheck, required math.Random random}) {
    final spread = (maximumDelay - minimumDelay).inSeconds;
    final jitter = minimumDelay + Duration(seconds: random.nextInt(spread + 1));
    if (lastCheck == null) return jitter;
    var wait = lastCheck.add(interval).difference(now);
    if (wait.isNegative) wait = Duration.zero;
    if (wait > interval) wait = interval;
    return wait + jitter;
  }
}

/// Reads [kLatestReleaseUrl] (or [url]): one GET with a fixed User-Agent,
/// no cookies, and nothing about this NEFORUM or this device in it. Throws
/// on a network error, a status other than 200, or a file that is not
/// latest.json.
Future<LatestRelease> fetchLatestRelease({Uri? url}) => impl.fetchLatestRelease(url: url ?? Uri.parse(kLatestReleaseUrl));
