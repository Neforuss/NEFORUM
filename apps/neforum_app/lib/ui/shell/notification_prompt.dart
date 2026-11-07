import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../platform/env.dart';
import '../../platform/notification_access.dart';
import '../../state/notification_state.dart';
import '../../state/providers.dart';
import '../../state/publish_result_notices.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/layout.dart';
import '../router.dart';

/// Android, iOS and macOS ask before a notification can show.
bool get _platformAsks => Env.isAndroid || Env.isIOS || Env.isMacOS;

/// The OS's name in a sentence.
String get notificationOsName => Env.isAndroid
    ? 'Android'
    : Env.isIOS
        ? 'iOS'
        : Env.isMacOS
            ? 'macOS'
            : 'This computer';

/// D8: the explanation screen, once, after the first frame of the first launch
/// of a real workspace. The OS prompt comes only from its Turn on: Not now
/// and closing it spend nothing with the OS.
Future<void> askAboutNotificationsOnFirstLaunch(BuildContext context, WidgetRef ref) async {
  if (!_platformAsks || ref.read(isDemoProvider)) return;
  final access = ref.read(notificationAccessProvider.notifier);
  await access.refresh();
  if (!context.mounted) return;
  final view = ref.read(notificationAccessProvider);
  final settings = ref.read(settingsProvider);
  if (!shouldOfferFirstLaunchPrompt(platformAsks: _platformAsks, demo: ref.read(isDemoProvider), access: view.access, promptAt: settings.notificationPromptAt)) return;
  // Before it shows: a NEFORUM closed on this screen does not show it again.
  final now = ref.read(notificationClockProvider)();
  await ref.read(settingsProvider.notifier).update((x) => x.copyWith(notificationPromptAt: now));
  if (!context.mounted) return;
  final turnOn = await showNotificationExplanation(context);
  if (turnOn == true && context.mounted) await turnOnNotifications(context, ref);
}

/// The explanation: a bottom sheet on phones, a dialog on wide windows. True
/// when the user pressed Turn on.
Future<bool?> showNotificationExplanation(BuildContext context) {
  if (context.isCompact) {
    return showModalBottomSheet<bool>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => const NotificationExplanation());
  }
  return showDialog<bool>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: const NotificationExplanation()),
    ),
  );
}

/// What notifications are for here, in the OS's own terms. Nothing about
/// posting going on in the background: the words wait for the run that proves it.
class NotificationExplanation extends StatelessWidget {
  const NotificationExplanation({super.key});

  @override
  Widget build(BuildContext context) {
    final ios = Env.isIOS;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Space.xxl),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.notifications_none_rounded, size: 32, color: context.nf.accent),
        const SizedBox(height: Space.md),
        Text(ios ? "Don't miss a scheduled post" : 'Know how your post went', style: context.text.headlineSmall),
        const SizedBox(height: Space.sm),
        Text(
          ios
              ? 'iOS stops apps you are not using, so at its time a scheduled post needs a notification: tap it and NEFORUM posts. The same notifications tell you how each network went.'
              : 'A notification tells you how each network went, and when a scheduled post goes out or needs you.',
          style: context.text.bodyMedium,
        ),
        const SizedBox(height: Space.sm),
        Text('These notifications are made on this device. NEFORUM has no server.', style: context.text.bodySmall),
        if (ios) ...[
          const SizedBox(height: Space.sm),
          Text('iOS asks only once. If you say no, you can change it later in Settings.', style: context.text.bodySmall),
        ],
        const SizedBox(height: Space.xl),
        Wrap(alignment: WrapAlignment.end, spacing: Space.sm, runSpacing: Space.sm, children: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Turn on notifications')),
        ]),
      ]),
    );
  }
}

/// The action of every Turn on and Open settings: the banner, the Settings
/// row, the pill and the quiet line. The user just asked, so no explanation
/// first. On a refusal, one toast and no second screen.
Future<void> turnOnNotifications(BuildContext context, WidgetRef ref) async {
  final notifier = ref.read(notificationAccessProvider.notifier);
  final view = ref.read(notificationAccessProvider);
  if (view.resultsChannelOff) return NotificationAccessPlatform.instance.openResultsChannelSettings();
  final action = primaryActionFor(view.access);
  if (view.readFailed || view.access == NotificationAccess.granted || action == NotificationAccessAction.openSettings) {
    return NotificationAccessPlatform.instance.openSettings();
  }
  if (action == NotificationAccessAction.none) return;
  final on = await notifier.ask();
  if (!context.mounted) return;
  if (on) {
    showToast(context, 'Notifications are on', icon: Icons.check_rounded);
  } else if (view.access == NotificationAccess.askedUnclear || ref.read(notificationAccessProvider).access == NotificationAccess.blocked) {
    // Android may not have shown anything, and cannot say whether it did.
    showToast(context, 'Notifications are still off. If $notificationOsName did not ask, turn them on in its settings.',
        icon: Icons.info_outline_rounded, actionLabel: 'Open settings', onAction: NotificationAccessPlatform.instance.openSettings);
  } else {
    showToast(context, 'Posting still works. Open Activity to see how it went.', icon: Icons.info_outline_rounded);
  }
}

/// The banner's close button.
Future<void> closeNotificationsBanner(WidgetRef ref) {
  final now = ref.read(notificationClockProvider)();
  return ref.read(settingsProvider.notifier).update((x) => x.copyWith(notificationBannerClosedAt: now));
}

/// D8's one quiet line, in the Post and Schedule sheets, on the first of them
/// while the OS has not asked yet. With [scheduling] on iOS it also says when no
/// reminder can appear.
class NotificationHintLine extends ConsumerStatefulWidget {
  const NotificationHintLine({super.key, this.scheduling = false});
  final bool scheduling;

  @override
  ConsumerState<NotificationHintLine> createState() => _NotificationHintLineState();
}

class _NotificationHintLineState extends ConsumerState<NotificationHintLine> {
  /// It stays for as long as this sheet does.
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(notificationAccessProvider);
    final hintShownAt = ref.watch(settingsProvider.select((s) => s.notificationHintShownAt));
    if (!_shown && shouldShowQuietLine(platformAsks: _platformAsks, demo: ref.watch(isDemoProvider), access: view.access, hintShownAt: hintShownAt)) {
      _shown = true;
      final now = ref.read(notificationClockProvider)();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(settingsProvider.notifier).update((x) => x.copyWith(notificationHintShownAt: now));
      });
    }
    final String text;
    final String action;
    if (widget.scheduling && Env.isIOS && view.access == NotificationAccess.blocked) {
      text = 'No reminder will appear at this time.';
      action = 'Open settings';
    } else if (_shown && view.isOff) {
      text = widget.scheduling && Env.isIOS ? 'A notification lets you post at this time.' : 'A notification can tell you how this goes.';
      action = 'Turn on';
    } else {
      return const SizedBox.shrink();
    }
    final nf = context.nf;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
      child: Row(children: [
        Icon(Icons.notifications_none_rounded, size: 16, color: nf.textMuted),
        const SizedBox(width: Space.sm),
        Expanded(child: Text(text, style: context.text.bodySmall)),
        TextButton(onPressed: () => turnOnNotifications(context, ref), child: Text(action)),
      ]),
    );
  }
}

/// D9's small permanent sign on Activity. Tapping it does what Turn on does.
class NotificationsOffPill extends ConsumerWidget {
  const NotificationsOffPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(notificationAccessProvider).needsAttention) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: 'Notifications off',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: Radii.rPill,
        onTap: () => turnOnNotifications(context, ref),
        child: const SizedBox(
          height: 48,
          child: Center(child: StatusPill('Notifications off', tone: Tone.warning, icon: Icons.notifications_off_outlined, dense: true)),
        ),
      ),
    );
  }
}

/// What finished with nobody watching, when the OS could not say so: once, on
/// return to the app. With notifications on, the OS already told them.
Future<void> showUnseenResultsIfAny(BuildContext context, WidgetRef ref) async {
  final s = ref.read(servicesProvider);
  if (s.demo) return;
  final view = ref.read(notificationAccessProvider);
  if (!view.loaded) return;
  final store = UnseenResults(s.storage);
  final entries = (await store.read()).entries;
  if (entries.isEmpty) return;
  if (!view.needsAttention) return store.clearEntries();
  // A second return to the app while this is up finds the list empty.
  await store.clearEntries();
  if (!context.mounted) return;
  final goToActivity = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('While you were away'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final e in entries.reversed) ...[
              Text(e.title, style: c.text.titleSmall),
              for (final line in e.lines) Text(line, style: c.text.bodySmall),
              const SizedBox(height: Space.md),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Close')),
        FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('See Activity')),
      ],
    ),
  );
  if (goToActivity == true && context.mounted) context.go(AppSection.activity.path);
}
