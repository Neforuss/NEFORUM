import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:workmanager/workmanager.dart';

import '../platform/desktop.dart';
import '../platform/env.dart';
import '../platform/notifications.dart';
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
/// Hand-off targets can never be fully automatic, so they always get a
/// "time to post" notification.
class AppScheduler {
  AppScheduler(this.ref);
  final Ref ref;

  Timer? _timer;
  bool _busy = false;

  AppServices get _s => ref.read(servicesProvider);

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => runDue());
    unawaited(runDue());
    if (Env.isAndroid || Env.isIOS) unawaited(_registerPeriodic());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Publishes everything that is due. Non-interactive: hand-off targets are
  /// left waiting and announced with a notification.
  Future<List<Post>> runDue({bool interactive = false}) async {
    if (_busy) return const [];
    _busy = true;
    try {
      final due = await _s.posts.due(DateTime.now());
      final out = <Post>[];
      for (final p in due) {
        // With cloud sync, the device the post was scheduled on publishes it.
        if (!await _s.cloudSync.mayPublish(p)) continue;
        await fitPhotosOfSavedPost(_s, p.id);
        final done = await _s.publisher().publish(p.id, interactive: interactive, retryFailed: false);
        out.add(done);
        await _announce(done);
      }
      _updateTray();
      return out;
    } on Object catch (e) {
      debugPrint('Scheduler run failed: $e');
      return const [];
    } finally {
      _busy = false;
    }
  }

  Future<void> _announce(Post p) => announcePublishResult(_s, p);

  /// Sets up OS-level reminders and background work for a scheduled post.
  Future<void> planReminders(Post p) async {
    final when = p.scheduledAt;
    if (when == null || p.status != PostStatus.scheduled) return;
    final s = _s;
    final handoffNames = <String>[];
    final heldNames = <String>[];
    for (final t in p.targets) {
      final a = await s.accounts.get(t.accountId);
      final d = a == null ? null : s.registry.descriptor(a.platformId);
      if (a == null || d == null) continue;
      if (t.isHeldByPlatform) heldNames.add(d.name);
      if (a.tier == PlatformTier.handoff) handoffNames.add(d.name);
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
    _updateTray();
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
    _updateTray();
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

  void _updateTray() {
    if (!Env.isDesktop) return;
    final scheduled = ref.read(scheduledPostsProvider).length;
    final waiting = ref.read(needsAttentionProvider).length;
    final parts = <String>[
      if (scheduled > 0) '$scheduled scheduled',
      if (waiting > 0) '$waiting need you',
    ];
    DesktopIntegration.instance.setTrayStatus(parts.isEmpty ? 'NEFORUM' : 'NEFORUM · ${parts.join(' · ')}');
  }

  static String _short(String s) => s.length > 80 ? '${s.substring(0, 80)}…' : s;
}

String _join(List<String> names) {
  if (names.isEmpty) return 'your networks';
  if (names.length == 1) return names.first;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// Notifies the user about the outcome of an unattended publish run.
Future<void> announcePublishResult(AppServices s, Post p) async {
  final waiting = p.targets.where((t) => t.status == TargetStatus.awaitingHandoff).toList();
  final failed = p.targets.where((t) => t.status == TargetStatus.failed).length;
  final ok = p.targets.where((t) => t.status == TargetStatus.published).length;
  if (waiting.isNotEmpty) {
    final names = <String>[];
    for (final t in waiting) {
      final a = await s.accounts.get(t.accountId);
      final d = a == null ? null : s.registry.descriptor(a.platformId);
      if (d != null) names.add(d.name);
    }
    await NotificationService.instance.show(
      key: 'handoff:${p.id}',
      title: 'Time to post to ${_join(names)}',
      body: '${ok > 0 ? 'Already posted to $ok. ' : ''}Tap to finish in ${names.length == 1 ? 'the app' : 'each app'}.',
      payload: 'post:${p.id}',
    );
  } else if (s.settings.notifyOnPublish) {
    await NotificationService.instance.show(
      key: 'result:${p.id}',
      title: failed > 0 ? 'Posted to $ok, $failed failed' : 'Posted to $ok ${ok == 1 ? 'network' : 'networks'}',
      body: p.text.length > 90 ? '${p.text.substring(0, 90)}…' : p.text,
      payload: 'post:${p.id}',
    );
  }
}

/// Publishes all due posts without UI (WorkManager / iOS background task).
Future<int> publishDueHeadless(AppServices s) async {
  final due = await s.posts.due(DateTime.now());
  for (final p in due) {
    if (!await s.cloudSync.mayPublish(p)) continue;
    await fitPhotosOfSavedPost(s, p.id);
    final done = await s.publisher().publish(p.id, interactive: false, retryFailed: false);
    await announcePublishResult(s, done);
  }
  return due.length;
}

final schedulerProvider = Provider<AppScheduler>((ref) {
  final s = AppScheduler(ref);
  ref.onDispose(s.stop);
  return s;
});
