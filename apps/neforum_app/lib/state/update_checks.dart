import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/env.dart';
import '../platform/update_check.dart';
import 'providers.dart';
import 'settings.dart';

/// What the update check knows in this run.
@immutable
class UpdateCheckStatus {
  const UpdateCheckStatus({this.latest, this.checking = false, this.hiddenThisRun = false});

  /// The last latest.json read (saved in settings, so it survives restarts).
  final LatestRelease? latest;

  /// A check is under way.
  final bool checking;

  /// The user closed the banner; it stays closed until the next start
  /// (for critical releases) or the next version (for the others).
  final bool hiddenThisRun;

  /// [latest] when it is newer than this NEFORUM.
  LatestRelease? get available {
    final l = latest;
    return l != null && l.isNewerThan(kAppVersion) ? l : null;
  }

  /// The banner shows: a newer version the user has not closed.
  bool showsBanner(AppSettings settings) {
    final a = available;
    if (a == null || hiddenThisRun) return false;
    return a.critical || settings.updateDismissedVersion != a.version;
  }

  UpdateCheckStatus copyWith({LatestRelease? latest, bool? checking, bool? hiddenThisRun}) =>
      UpdateCheckStatus(latest: latest ?? this.latest, checking: checking ?? this.checking, hiddenThisRun: hiddenThisRun ?? this.hiddenThisRun);
}

/// Reads latest.json; replaced in tests.
final latestReleaseFetcherProvider = Provider<Future<LatestRelease> Function()>((ref) => fetchLatestRelease);

/// Settings > Updates and the update banner. Automatic checks run at most
/// once a day ([UpdateSchedule]), only while NEFORUM runs, never in the demo
/// workspace, a store build or the web preview, and never install anything.
class UpdateCheckNotifier extends Notifier<UpdateCheckStatus> {
  Timer? _timer;
  DateTime? _lastAttempt;
  final math.Random _random = math.Random();

  @override
  UpdateCheckStatus build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(settingsProvider.select((s) => s.updateCheck), (_, _) => _schedule());
    final saved = ref.read(settingsProvider).updateLatestRelease;
    LatestRelease? latest;
    if (saved.isNotEmpty) {
      try {
        latest = LatestRelease.fromJson(saved);
      } on FormatException {
        latest = null;
      }
    }
    return UpdateCheckStatus(latest: latest);
  }

  /// Update checks apply here at all.
  bool get applies => updateChecksAvailable && !ref.read(isDemoProvider);

  /// Starts automatic checks if they are on. Called once the app is up.
  void start() => _schedule();

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final s = ref.read(settingsProvider);
    if (!applies || s.updateCheck != UpdateCheckMode.automatic) return;
    // A failed attempt counts too: an offline computer does not retry all day.
    final checked = s.updateCheckedAt;
    final attempt = _lastAttempt;
    final last = checked == null || (attempt != null && attempt.isAfter(checked)) ? attempt : checked;
    final delay = UpdateSchedule.nextDelay(now: DateTime.now(), lastCheck: last, random: _random);
    _timer = Timer(delay, () async {
      try {
        await checkNow();
      } on Object catch (e) {
        debugPrint('Update check failed: $e');
      }
      if (ref.mounted) _schedule();
    });
  }

  /// Reads latest.json now (Check now, or the daily timer) and keeps the
  /// answer. Throws when neforus.com cannot be read.
  Future<LatestRelease?> checkNow() async {
    if (!updateChecksAvailable) return null;
    if (state.checking) return state.latest;
    state = state.copyWith(checking: true);
    _lastAttempt = DateTime.now();
    try {
      final latest = await ref.read(latestReleaseFetcherProvider)();
      if (!ref.mounted) return latest;
      await ref.read(settingsProvider.notifier).update((x) => x.copyWith(updateCheckedAt: DateTime.now(), updateLatestRelease: latest.toJson()));
      if (!ref.mounted) return latest;
      // A newer version than the one closed brings the banner back.
      final hidden = state.hiddenThisRun && state.latest?.version == latest.version;
      state = UpdateCheckStatus(latest: latest, hiddenThisRun: hidden);
      return latest;
    } finally {
      if (ref.mounted && state.checking) state = state.copyWith(checking: false);
    }
  }

  /// Closes the banner: for this version (critical ones: until the next start).
  Future<void> dismiss() async {
    final a = state.available;
    if (a == null) return;
    state = state.copyWith(hiddenThisRun: true);
    if (!a.critical) await ref.read(settingsProvider.notifier).update((x) => x.copyWith(updateDismissedVersion: a.version));
  }

  /// The answer to the one-time question, or the switch in Settings.
  Future<void> setMode(UpdateCheckMode mode) => ref.read(settingsProvider.notifier).update((x) => x.copyWith(updateCheck: mode));
}

final updateCheckProvider = NotifierProvider<UpdateCheckNotifier, UpdateCheckStatus>(UpdateCheckNotifier.new);
