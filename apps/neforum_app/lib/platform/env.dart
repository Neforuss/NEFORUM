import 'package:flutter/foundation.dart';

/// Shown in the sidebar and Settings; keep in step with `version:` in
/// pubspec.yaml (CI fails otherwise, see test/version_test.dart).
const String kAppVersion = '1.3.0';

/// NEFORUM's terms of service and privacy policy on neforus.com.
const String kTermsUrl = 'https://neforus.com/neforum/terms/';
const String kPrivacyUrl = 'https://neforus.com/neforum/privacy/';

/// Where NEFORUM is running. Uses [defaultTargetPlatform] so it never touches
/// `dart:io` (keeps the web preview building).
abstract final class Env {
  static bool get isWeb => kIsWeb;
  static bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  static bool get isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  static bool get isLinux => !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  static bool get isMobile => isAndroid || isIOS;
  static bool get isDesktop => isMacOS || isWindows || isLinux;

  /// Native share sheet with files is meaningful here. Windows and Linux have
  /// none that share_plus can fill with files (on Linux it only opens a
  /// mailto: link), so there hand-offs copy to the clipboard and save media
  /// to Downloads/NEFORUM instead, and exports go through a save dialog.
  static bool get hasShareSheet => isMobile || isMacOS;

  /// Can run a loopback HTTP server for OAuth redirects.
  static bool get canListenLoopback => !kIsWeb;

  static String get platformName {
    if (kIsWeb) return 'Web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.fuchsia => 'Fuchsia',
    };
  }
}
