import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' show Clock, systemClock;

import '../platform/notification_access.dart';
import 'providers.dart';
import 'publish_result_notices.dart';

/// How many publish progress sheets are open (D10: an open, visible sheet is
/// the run's result).
class PublishSheetOpenNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void opened() => state = state + 1;
  void closed() {
    if (ref.mounted && state > 0) state = state - 1;
  }
}

final publishSheetOpenProvider = NotifierProvider<PublishSheetOpenNotifier, int>(PublishSheetOpenNotifier.new);

/// The time the notification settings record. Replaced by tests.
final notificationClockProvider = Provider<Clock>((_) => systemClock);

/// What the OS says about notifications here, read once at the start and again
/// on every return to the app. The demo never asks anything.
class NotificationAccessNotifier extends Notifier<NotificationAccessView> {
  @override
  NotificationAccessView build() {
    if (ref.watch(servicesProvider).demo) return const NotificationAccessView(loaded: true);
    scheduleMicrotask(refresh);
    return const NotificationAccessView();
  }

  Future<void> refresh() async {
    final s = ref.read(servicesProvider);
    if (s.demo) return;
    final facts = await NotificationAccessPlatform.instance.read();
    final unseen = await UnseenResults(s.storage).read();
    if (!ref.mounted) return;
    state = NotificationAccessView(
      access: notificationAccessFrom(facts, askedBefore: ref.read(settingsProvider).notificationOsAskedAt != null),
      loaded: true,
      resultsChannelOff: facts is AndroidNotificationFacts && facts.enabled && facts.resultsChannelOff,
      readFailed: facts is NoPromptFacts && facts.readFailed,
      lastUnseenAt: unseen.lastAt,
    );
  }

  /// Shows the OS prompt. True when access is on afterwards.
  Future<bool> ask() async {
    final now = ref.read(notificationClockProvider)();
    await ref.read(settingsProvider.notifier).update((x) => x.copyWith(notificationOsAskedAt: now));
    final ok = await NotificationAccessPlatform.instance.request();
    await refresh();
    return ok;
  }
}

final notificationAccessProvider = NotifierProvider<NotificationAccessNotifier, NotificationAccessView>(NotificationAccessNotifier.new);
