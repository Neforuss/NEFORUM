import 'update_check.dart';

bool get installedByPackageManager => false;

/// The web preview never checks for updates (see updateChecksAvailable).
Future<LatestRelease> fetchLatestRelease({required Uri url}) => Future.error(UnsupportedError('No update check in the web preview'));
