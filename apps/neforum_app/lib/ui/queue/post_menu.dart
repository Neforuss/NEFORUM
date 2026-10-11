import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../widgets/layout.dart';
import '../../widgets/post_card.dart';
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
        final done = await actions.publishExisting(p.id);
        if (context.mounted) showPublishedToast(context, done);
      }),
    if (editable)
      PostMenuAction(p.status == PostStatus.scheduled ? 'Reschedule' : 'Schedule', Icons.schedule_rounded, () async {
        final when = await showScheduleSheet(context, initial: p.scheduledAt);
        if (when == null || !context.mounted) return;
        if (when == kClearSchedule) {
          await actions.unschedule(p);
          if (context.mounted) showToast(context, 'Moved to drafts', icon: Icons.inventory_2_outlined);
        } else {
          await actions.reschedule(p, when);
          if (context.mounted) showToast(context, 'Scheduled for ${DateFormat.MMMEd().add_jm().format(when)}', icon: Icons.event_available_rounded);
        }
      }),
    if (p.status == PostStatus.scheduled)
      PostMenuAction('Move to drafts', Icons.inventory_2_outlined, () async {
        await actions.unschedule(p);
        if (context.mounted) showToast(context, 'Moved to drafts', icon: Icons.inventory_2_outlined);
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
  await ref.read(postActionsProvider).delete(p);
  if (context.mounted) showToast(context, 'Post deleted', icon: Icons.delete_outline_rounded);
  return true;
}

void showPublishedToast(BuildContext context, Post p) {
  final ok = p.targets.where((t) => t.status == TargetStatus.published || t.status == TargetStatus.handedOff).length;
  final failed = p.targets.where((t) => t.status == TargetStatus.failed).length;
  final waiting = p.targets.where((t) => t.status == TargetStatus.awaitingHandoff).length;
  final parts = ['Posted to $ok', if (failed > 0) '$failed failed', if (waiting > 0) '$waiting waiting for you'];
  showToast(context, parts.join(' · '), icon: failed > 0 ? Icons.error_outline_rounded : Icons.check_circle_rounded);
}
