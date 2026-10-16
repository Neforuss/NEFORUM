import 'package:flutter/foundation.dart';

/// Shown in the sidebar and Settings; keep in step with `version:` in
/// pubspec.yaml (CI fails otherwise, see test/version_test.dart).
const String kAppVersion = '1.0.4';

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

  /// Native share sheet with files is meaningful here.
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
