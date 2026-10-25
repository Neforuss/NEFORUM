import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'env.dart';

/// Where a share into an app went.
enum ShareTargetOutcome {
  /// The app opened with the files and the caption.
  app,

  /// The app is not installed: the system share sheet opened instead.
  chooser,

  /// This device cannot share this way (not Android, or a build without the
  /// channel); use the share sheet.
  unavailable,
}

/// One file to share: its path and type.
typedef SharedFile = ({String path, String mimeType});

/// Shares a hand-off's files and caption straight into one app on Android
/// (the plan's `androidPackage`), through the "neforum/share" channel
/// (android/app/src/main/kotlin/org/neforum/neforum_app/ShareChannel.kt):
/// ACTION_SEND or ACTION_SEND_MULTIPLE aimed at that package, with the
/// caption in EXTRA_TEXT. The hand-off also puts the caption on the
/// clipboard, since many apps drop shared text. When the app is missing, the
/// system share sheet opens instead. iOS lets no app pick the receiving app,
/// so it keeps the share sheet.
abstract final class ShareTarget {
  static const MethodChannel _channel = MethodChannel('neforum/share');

  static bool get supported => Env.isAndroid;

  /// Shares [files] and [text] into the app [package].
  static Future<ShareTargetOutcome> shareToApp({required String package, List<SharedFile> files = const [], String? text}) async {
    if (!supported || package.isEmpty) return ShareTargetOutcome.unavailable;
    try {
      final r = await _channel.invokeMethod<String>('share', {
        'package': package,
        'paths': [for (final f in files) f.path],
        'mimeTypes': [for (final f in files) f.mimeType],
        if (text != null && text.isNotEmpty) 'text': text,
      });
      return ShareTargetOutcome.values.asNameMap()[r] ?? ShareTargetOutcome.unavailable;
    } on MissingPluginException {
      return ShareTargetOutcome.unavailable;
    } on PlatformException catch (e) {
      debugPrint('Could not share to $package: ${e.message}');
      return ShareTargetOutcome.unavailable;
    }
  }
}
