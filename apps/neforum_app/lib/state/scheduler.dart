import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:workmanager/workmanager.dart';

import '../platform/desktop.dart';
import '../platform/env.dart';
import '../platform/notifications.dart';
import 'automatic_handoff.dart';
import 'fitted_photos.dart';
import 'providers.dart';
import 'services.dart';

/// Background task name shared with the WorkManager callback in main.dart.
const String kPublishDueTask = 'org.neforum.publish_due';

/// Makes scheduled posts go out on time on every OS, without a server:
///
/// * Desktop: an in-process timer (NEFORUM keeps running in the tray).
/// * Android: WorkManager one-off + periodic tasks, plus reminders.
/// * iOS: background refresh is best effort, so every scheduled post also
///   gets a notification at its time; tapping it publishes.
///
/// Hand-off targets get a "time to post" notification, except on a desktop
/// where automatic posting through the paired browser extension posts them
/// while NEFORUM runs (automatic_handoff.dart).
class AppScheduler {
  AppScheduler(this.ref);
  final Ref ref;

  Timer? _timer;
  Timer? _retentionTimer;
  Timer? _recoveryTimer;
  bool _busy = false;

  AppServices get _s => ref.read(servicesProvider);

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => runDue());
    unawaited(runDue());
    if (Env.isAndroid || Env.isIOS) unawaited(_registerPeriodic());
    // Startup applied retention already (main.dart); kept posts expire by
    // the hour after that.
    _retentionTimer = Timer.periodic(const Duration(hours: 1), (_) => unawaited(applyRetention()));
    // Startup settled the runs a closed NEFORUM abandoned. A run that was
    // still alive then (a background task) is settled once it falls silent.
    _recoveryTimer = Timer.periodic(const Duration(minutes: 5), (_) => unawaited(recoverInterruptedPublishing()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _retentionTimer?.cancel();
    _retentionTimer = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
  }

  /// Settles the runs on this device that ended without saving their
  /// outcome (a background task that was stopped, an outcome posts.json
  /// would not take); runs of this process are left alone.
  Future<int> recoverInterruptedPublishing() async {
    if (_s.demo) return 0;
    try {
      final n = await _s.recoverInterruptedPublishing(exclude: ref.read(activePublishingProvider).keys.toSet());
      if (n > 0) updateTrayStatus();
      return n;
    } on Object catch (e) {
      debugPrint('Recovery of interrupted runs failed: $e');
      return 0;
    }
  }

  /// Deletes the finished posts Settings > Activity and history no longer
  /// keeps. The demo keeps its sample history.
  Future<int> applyRetention() async {
    if (_s.demo) return 0;
    try {
      final n = await _s.applyRetention();
      if (n > 0) updateTrayStatus();
      return n;
    } on Object catch (e) {
      debugPrint('Retention run failed: $e');
      return 0;
    }
  }

  /// Publishes everything that is due. Non-interactive: hand-off targets are
  /// left waiting and announced with a notification, unless automatic posting
  /// through the browser extension posts them. Each run can be cancelled from
  /// Activity while it goes.
  Future<List<Post>> runDue({bool interactive = false}) async {
    if (_busy) return const [];
    _busy = true;
    try {
      final due = await _s.posts.due(DateTime.now());
      final out = <Post>[];
      for (final p in due) {
        // With cloud sync, the device the post was scheduled on publishes it.
        if (!await _s.cloudSync.mayPublish(p)) continue;
        final active = ref.read(activePublishingProvider.notifier);
        final signal = CancellationSignal();
        active.begin(p.id, signal);
        final Post done;
        try {
          await fitPhotosOfSavedPost(_s, p.id);
          // Networks whose own time has not come yet wait for a later run.
          final published =
              await _s.publisher().publish(p.id, interactive: interactive, retryFailed: false, cancellation: signal, dueTargetsOnly: true);
          // With automatic posting on, the browser extension posts the
          // hand-off targets now instead of leaving them waiting; Cancel in
          // Activity stops that too.
          done = await AutomaticHandoff(_s).complete(published, unattended: !interactive, cancellation: signal);
        } on Object catch (e) {
          // Never leave the post looking busy without a run.
          await _s.concludeStoppedRun(p.id, e);
          rethrow;
        } finally {
          active.end(p.id, signal);
        }
        out.add(done);
        final discarded = await _s.discardIfComplete(p.id);
        await announcePublishResult(_s, done, discarded: discarded);
        await planNextReminders(_s, done);
      }
      updateTrayStatus();
      return out;
    } on Object catch (e) {
      debugPrint('Scheduler run failed: $e');
      return const [];
    } finally {
      _busy = false;
    }
  }

  /// Sets up OS-level reminders and background work for a scheduled post.
  Future<void> planReminders(Post p) async {
    await planPostReminders(_s, p);
    updateTrayStatus();
  }

  Future<void> cancelReminders(Post p) async {
    await NotificationService.instance.cancel('due:${p.id}');
    if (Env.isAndroid) {
      try {
        await Workmanager().cancelByUniqueName('publish-${p.id}');
      } on Object {
        // Nothing registered.
      }
    }
    updateTrayStatus();
  }

  Future<void> _registerPeriodic() async {
    try {
      // On iOS the unique name is the BGTaskScheduler identifier, which must
      // match BGTaskSchedulerPermittedIdentifiers in Info.plist.
      await Workmanager().registerPeriodicTask(
        kPublishDueTask,
        kPublishDueTask,
        frequency: const Duration(minutes: 15),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } on Object catch (e) {
      debugPrint('Periodic task not available: $e');
    }
  }

  /// Shows how many posts are scheduled and how many need the user in the
  /// tray tooltip (desktop).
  void updateTrayStatus() {
    if (!Env.isDesktop) return;
    final scheduled = ref.read(scheduledPostsProvider).length;
    final waiting = ref.read(needsAttentionProvider).length;
    final parts = <String>[
      if (scheduled > 0) '$scheduled scheduled',
      if (waiting > 0) '$waiting need you',
    ];
    DesktopIntegration.instance.setTrayStatus(parts.isEmpty ? 'NEFORUM' : 'NEFORUM · ${parts.join(' · ')}');
  }

}

String _short(String s) => s.length > 80 ? '${s.substring(0, 80)}…' : s;

/// Sets up the OS-level reminder and background work for the next time [p]
/// is due: its [Post.scheduledAt], which with a different time per network is
/// the next network's time. Called when the post is scheduled and again after
/// every run that leaves it scheduled, from the app and from a background
/// task (no UI needed). Each call replaces the post's earlier reminder and
/// Android one-off task.
Future<void> planPostReminders(AppServices s, Post p) async {
  final when = p.scheduledAt;
  if (when == null || p.status != PostStatus.scheduled) return;
  final handoffNames = <String>[];
  final heldNames = <String>[];
  for (final t in p.targets) {
    final a = await s.accounts.get(t.accountId);
    final d = a == null ? null : s.registry.descriptor(a.platformId);
    if (a == null || d == null) continue;
    if (t.isHeldByPlatform) heldNames.add(d.name);
    // Only the hand-offs due at this time; later ones get their own reminder.
    final due = p.dueAtFor(t);
    if (a.tier == PlatformTier.handoff && !t.isDone && (due == null || !due.isAfter(when))) handoffNames.add(d.name);
  }
  if (Env.isIOS) {
    if (!p.needsDeviceAtSchedule) {
      // Every target is held by its platform: nothing for the phone to do.
      await NotificationService.instance.cancel('due:${p.id}');
    } else {
      final held = heldNames.isEmpty ? '' : '${_join(heldNames)} already ${heldNames.length == 1 ? 'has' : 'have'} it. ';
      await NotificationService.instance.schedule(
        key: 'due:${p.id}',
        when: when,
        title: handoffNames.isEmpty ? 'Your scheduled post is ready' : 'Time to post',
        body: '${held}Publish now: ${_short(p.text)}',
        payload: 'publish:${p.id}',
        publishAction: true,
      );
    }
  } else if (handoffNames.isNotEmpty) {
    await NotificationService.instance.schedule(
      key: 'due:${p.id}',
      when: when,
      title: 'Time to post to ${_join(handoffNames)}',
      body: _short(p.text),
      payload: 'post:${p.id}',
    );
  }
  // One-off tasks need a per-post identifier, which iOS only allows when it
  // is declared in Info.plist ahead of time; iOS relies on the reminder
  // above plus the periodic refresh task instead.
  if (Env.isAndroid) {
    final delay = when.difference(DateTime.now());
    try {
      await Workmanager().registerOneOffTask(
        'publish-${p.id}',
        kPublishDueTask,
        initialDelay: delay.isNegative ? Duration.zero : delay,
        existingWorkPolicy: ExistingWorkPolicy.replace,
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } on Object catch (e) {
      debugPrint('Could not register background task: $e');
    }
  }
}

/// After a scheduler run: a post with a different time per network whose
/// later networks are still to go gets the reminder and background task for
/// the next of those times. Retries keep waiting for the regular checks, as
/// before. Best effort.
Future<void> planNextReminders(AppServices s, Post done) async {
  final next = done.scheduledAt;
  if (done.status != PostStatus.scheduled || !done.schedulesEachTarget || next == null || !next.isAfter(DateTime.now())) return;
  try {
    await planPostReminders(s, done);
  } on Object catch (e) {
    debugPrint('Could not plan the next run of ${done.id}: $e');
  }
}

String _join(List<String> names) {
  if (names.isEmpty) return 'your networks';
  if (names.length == 1) return names.first;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// Notifies the user about the outcome of an unattended publish run.
/// [discarded]: the finished post was deleted right away (Settings >
/// Activity and history), so the notification neither quotes nor opens it.
Future<void> announcePublishResult(AppServices s, Post p, {bool discarded = false}) async {
  final names = <String>[];
  for (final t in p.targets.where((t) => t.status == TargetStatus.awaitingHandoff)) {
    final a = await s.accounts.get(t.accountId);
    final d = a == null ? null : s.registry.descriptor(a.platformId);
    if (d != null) names.add(d.name);
  }
  final notice = publishResultNotice(p, discarded: discarded, notifyOnPublish: s.settings.notifyOnPublish, waitingNetworks: names);
  if (notice == null) return;
  await NotificationService.instance.show(key: notice.key, title: notice.title, body: notice.body, payload: notice.payload);
}

/// The notification [announcePublishResult] shows for [p], or null when
/// there is nothing to say. [waitingNetworks] names the hand-offs waiting
/// for the user. Only networks that got the post (published or handed off)
/// count as posted, and nothing is announced as live when none did.
({String key, String title, String body, String? payload})? publishResultNotice(
  Post p, {
  required bool discarded,
  required bool notifyOnPublish,
  List<String> waitingNetworks = const [],
}) {
  final waiting = p.targets.where((t) => t.status == TargetStatus.awaitingHandoff).length;
  final failed = p.targets.where((t) => t.status == TargetStatus.failed).length;
  final ok = p.targets.where((t) => t.status == TargetStatus.published || t.status == TargetStatus.handedOff).length;
  // The user stopped this run in Activity and has seen how it ended.
  if (waiting == 0 && p.targets.any((t) => t.status == TargetStatus.cancelled)) return null;
  if (waiting > 0) {
    // Automatic posting filled a page in without a confirmed post: say what
    // to check there, so the post is not made a second time.
    final note = p.targets.where((t) => t.status == TargetStatus.awaitingHandoff).map((t) => t.handoffNote).nonNulls.firstOrNull;
    return (
      key: 'handoff:${p.id}',
      title: 'Time to post to ${_join(waitingNetworks)}',
      body: '${ok > 0 ? 'Already posted to $ok. ' : ''}${note == null ? '' : '$note '}Tap to finish in ${waitingNetworks.length == 1 ? 'the app' : 'each app'}.',
      payload: 'post:${p.id}',
    );
  }
  if (!notifyOnPublish) return null;
  if (p.targets.isNotEmpty && p.targets.every((t) => t.status == TargetStatus.skipped)) {
    // Every account of the post is switched off: it stays in Activity.
    return (
      key: 'result:${p.id}',
      title: 'Not posted',
      body: 'The accounts for this post are switched off. It stays in Activity.',
      payload: 'post:${p.id}',
    );
  }
  if (discarded) {
    return (key: 'result:${p.id}', title: 'Posted to $ok ${ok == 1 ? 'network' : 'networks'}', body: 'Your scheduled post is live.', payload: null);
  }
  return (
    key: 'result:${p.id}',
    title: failed > 0 ? 'Posted to $ok, $failed failed' : 'Posted to $ok ${ok == 1 ? 'network' : 'networks'}',
    body: p.text.length > 90 ? '${p.text.substring(0, 90)}…' : p.text,
    payload: 'post:${p.id}',
  );
}

/// Publishes all due posts without UI (WorkManager / iOS background task).
/// Finished posts are deleted right away when the setting keeps nothing.
Future<int> publishDueHeadless(AppServices s) async {
  final due = await s.posts.due(DateTime.now());
  for (final p in due) {
    if (!await s.cloudSync.mayPublish(p)) continue;
    final Post done;
    try {
      await fitPhotosOfSavedPost(s, p.id);
      done = await s.publisher().publish(p.id, interactive: false, retryFailed: false, dueTargetsOnly: true);
    } on Object catch (e) {
      await s.concludeStoppedRun(p.id, e);
      rethrow;
    }
    final discarded = await s.discardIfComplete(p.id);
    await announcePublishResult(s, done, discarded: discarded);
    // The next network's time: WorkManager one-off on Android, a reminder on iOS.
    await planNextReminders(s, done);
  }
  return due.length;
}

final schedulerProvider = Provider<AppScheduler>((ref) {
  final s = AppScheduler(ref);
  ref.onDispose(s.stop);
  return s;
});
