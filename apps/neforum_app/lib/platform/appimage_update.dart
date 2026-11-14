import 'package:flutter/foundation.dart';

import 'appimage_update_web.dart' if (dart.library.io) 'appimage_update_io.dart' as impl;
import 'update_check.dart';

/// The only place NEFORUM installs an AppImage from: this project's GitHub
/// releases. The SHA-256 it checks comes from latest.json on neforus.com, so
/// a bad file has to get past both sites.
final Uri kReleaseDownloadBase = Uri.parse('https://github.com/Neforuss/NEFORUM/releases/download/');

/// The largest AppImage NEFORUM downloads (a release is about 60 MB).
const int kMaximumAppImageBytes = 1024 * 1024 * 1024;

/// The latest.json download key of the AppImage for a processor, by Dart's
/// ABI name (`Abi.current().toString()`), or null when no AppImage is built
/// for it. The keys come from tool/make_latest_json.dart.
String? appImageDownloadKey(String abi) => switch (abi) {
      'linux_x64' => 'linux-x64-appimage',
      'linux_arm64' => 'linux-arm64-appimage',
      _ => null,
    };

/// [url] is a file of one of this project's GitHub releases: https on
/// github.com, no user, port or query, and a path under
/// [kReleaseDownloadBase] with no `..` or empty part.
bool isReleaseDownloadUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null || !u.isScheme('https') || u.host != kReleaseDownloadBase.host) return false;
  if (u.userInfo.isNotEmpty || u.hasPort && u.port != 443 || u.hasQuery || u.hasFragment) return false;
  final base = kReleaseDownloadBase.pathSegments.where((s) => s.isNotEmpty).toList();
  final path = u.pathSegments;
  if (path.length != base.length + 2) return false;
  for (var i = 0; i < base.length; i++) {
    if (path[i] != base[i]) return false;
  }
  return path.skip(base.length).every((s) => s.isNotEmpty && s != '.' && s != '..');
}

/// What an AppImage update is doing.
enum AppImageUpdateStage { downloading, verifying, installing }

@immutable
class AppImageUpdateProgress {
  const AppImageUpdateProgress(this.stage, {this.receivedBytes = 0, this.totalBytes});

  final AppImageUpdateStage stage;
  final int receivedBytes;

  /// Null when the server did not say how large the file is.
  final int? totalBytes;

  /// 0 to 1, or null when the size is unknown.
  double? get fraction {
    final t = totalBytes;
    return t == null || t <= 0 ? null : (receivedBytes / t).clamp(0.0, 1.0);
  }
}

/// Why an AppImage update did not happen. [message] is shown to the user as
/// it is, after "Could not update: ".
class AppImageUpdateException implements Exception {
  const AppImageUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The user pressed Cancel during the download.
class AppImageUpdateCancelled extends AppImageUpdateException {
  const AppImageUpdateCancelled() : super('The update was cancelled.');
}

/// Replaces the running AppImage with a newer release and starts it again.
abstract interface class AppImageSelfUpdate {
  /// The .AppImage file NEFORUM runs from (the runtime's `$APPIMAGE`).
  String get appImagePath;

  /// The AppImage of [release] for this processor, when NEFORUM can install
  /// it itself (see [isReleaseDownloadUrl]); null otherwise, and then the
  /// Download button opens the download page as before.
  ReleaseDownload? downloadFor(LatestRelease release);

  /// Downloads [release]'s AppImage next to [appImagePath], checks its
  /// SHA-256, makes it executable and renames it over [appImagePath]. The
  /// running copy is untouched until that rename, which is atomic. Throws an
  /// [AppImageUpdateException] on any failure, after removing the partial
  /// download.
  Future<void> install(LatestRelease release, {void Function(AppImageUpdateProgress progress)? onProgress, bool Function()? isCancelled});

  /// Starts the new AppImage once this NEFORUM has quit, then quits.
  Future<void> restart();
}

/// The self-updater when NEFORUM runs as an AppImage on Linux, else null.
AppImageSelfUpdate? createAppImageSelfUpdate() => impl.createAppImageSelfUpdate();
