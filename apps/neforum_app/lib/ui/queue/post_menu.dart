import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/post_card.dart';
import '../activity/time_format.dart';
import '../compose/schedule_sheet.dart';
import '../router.dart';

/// The actions that make sense for [p] in lists and detail views.
List<PostMenuAction> postMenuActions(BuildContext context, WidgetRef ref, Post p) {
  final actions = ref.read(postActionsProvider);
  final editable = p.status == PostStatus.draft || p.status == PostStatus.scheduled;
  return [
    if (editable) PostMenuAction('Edit', Icons.edit_outlined, () => context.go('${AppSection.compose.path}?post=${p.id}')),
    if (editable)
      PostMenuAction('Publish now', Icons.send_rounded, () async {
        final done = await guardHeldCopies(context, () => actions.publishExisting(p.id));
        if (done != null && context.mounted) showPublishedToast(context, done);
      }),
    if (editable)
      PostMenuAction(p.status == PostStatus.scheduled ? 'Reschedule' : 'Schedule', Icons.schedule_rounded, () async {
        final when = await showScheduleSheet(context, initial: p.scheduledAt, post: p);
        if (when == null || !context.mounted) return;
        if (when == kClearSchedule) {
          final done = await guardHeldCopies(context, () => actions.unschedule(p));
          if (done != null && context.mounted) showToast(context, 'Moved to drafts', icon: Icons.inventory_2_outlined);
        } else {
          final done = await guardHeldCopies(context, () => actions.reschedule(p, when));
          if (done != null && context.mounted) {
            final format = TimeFormatting.from(ref.read(settingsProvider), context);
            showToast(context, 'Scheduled for ${format.scheduled(when)}', icon: Icons.event_available_rounded);
          }
        }
      }),
    if (p.status == PostStatus.scheduled)
      PostMenuAction('Move to drafts', Icons.inventory_2_outlined, () async {
        final done = await guardHeldCopies(context, () => actions.unschedule(p));
        if (done != null && context.mounted) showToast(context, 'Moved to drafts', icon: Icons.inventory_2_outlined);
      }),
    PostMenuAction('Duplicate as new post', Icons.copy_all_rounded, () {
      ref.read(composerProvider.notifier).duplicate(p);
      context.go(AppSection.compose.path);
    }),
    PostMenuAction('Delete', Icons.delete_outline_rounded, () => confirmDeletePost(context, ref, p), destructive: true),
  ];
}

Future<bool> confirmDeletePost(BuildContext context, WidgetRef ref, Post p) async {
  final published = p.targets.any((t) => t.status == TargetStatus.published);
  final ok = await confirmDialog(
    context,
    title: 'Delete this post?',
    message: published
        ? 'This removes it from NEFORUM only. Copies already published on your networks stay online; delete those on each network.'
        : 'This cannot be undone.',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (!ok) return false;
  final actions = ref.read(postActionsProvider);
  try {
    await actions.delete(p);
  } on HeldCopiesException catch (e) {
    if (!context.mounted) return false;
    final anyway = await confirmDialog(
      context,
      title: 'Still scheduled on ${e.platforms.join(', ')}',
      message: '${e.message}\n\nDelete it from NEFORUM anyway? The copy on ${e.platforms.length == 1 ? 'that site' : 'those sites'} will still be published.',
      confirmLabel: 'Delete here anyway',
      destructive: true,
    );
    if (!anyway) return false;
    await actions.delete(p, force: true);
  }
  if (context.mounted) showToast(context, 'Post deleted', icon: Icons.delete_outline_rounded);
  return true;
}

/// Runs [action]. When a platform still holds a copy NEFORUM could not take
/// back, explains that instead of failing silently; returns null then.
Future<T?> guardHeldCopies<T>(BuildContext context, Future<T> Function() action) async {
  try {
    return await action();
  } on HeldCopiesException catch (e) {
    if (context.mounted) await showHeldCopiesDialog(context, e);
    return null;
  }
}

Future<void> showHeldCopiesDialog(BuildContext context, HeldCopiesException e) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.cloud_off_rounded),
        title: Text('Still scheduled on ${e.platforms.join(', ')}'),
        content: Text(e.message),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );

void showPublishedToast(BuildContext context, Post p) {
  final ok = p.targets.where((t) => t.status == TargetStatus.published || t.status == TargetStatus.handedOff).length;
  final failed = p.targets.where((t) => t.status == TargetStatus.failed).length;
  final waiting = p.targets.where((t) => t.status == TargetStatus.awaitingHandoff).length;
  final cancelled = p.targets.where((t) => t.status == TargetStatus.cancelled).length;
  final parts = ['Posted to $ok', if (failed > 0) '$failed failed', if (cancelled > 0) '$cancelled cancelled', if (waiting > 0) '$waiting waiting for you'];
  showToast(context, parts.join(' · '), icon: failed > 0 ? Icons.error_outline_rounded : Icons.check_circle_rounded);
}
