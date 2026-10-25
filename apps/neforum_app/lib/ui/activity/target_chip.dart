import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:url_launcher/url_launcher.dart';

import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';

/// One network's outcome for a post; tap to act on it.
class TargetChip extends ConsumerWidget {
  const TargetChip({super.key, required this.post, required this.target});
  final Post post;
  final PostTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final a = ref.watch(accountByIdProvider(target.accountId));
    if (a == null) return const SizedBox.shrink();
    final name = ref.watch(registryProvider).descriptor(a.platformId)?.name ?? a.platformId;
    final (label, tone, icon) = targetStatusStyle(target.status);
    final url = target.result?.remoteUrl;
    final tappable = (target.status == TargetStatus.published && url != null) ||
        target.status == TargetStatus.awaitingHandoff ||
        needsRetry(target);
    final tip = switch (target.status) {
      TargetStatus.published when url != null => 'Open on $name',
      TargetStatus.awaitingHandoff => 'Finish on $name',
      TargetStatus.failed => target.result?.error?.message ?? 'Failed',
      TargetStatus.cancelled => 'You cancelled this before it reached $name',
      TargetStatus.heldByPlatform => '$name publishes this itself at the scheduled time',
      _ => '$name: $label',
    };

    return Tooltip(
      message: tip,
      child: Material(
        color: nf.surface,
        shape: Radii.stadium.copyWith(side: BorderSide(color: target.status == TargetStatus.failed ? nf.danger.withValues(alpha: 0.5) : nf.border)),
        child: InkWell(
          customBorder: Radii.stadium,
          onTap: !tappable
              ? null
              : () async {
                  switch (target.status) {
                    case TargetStatus.published:
                      await launchUrl(Uri.parse(url!), mode: LaunchMode.externalApplication);
                    case TargetStatus.awaitingHandoff:
                      await ref.read(postActionsProvider).runHandoff(post.id, target.accountId);
                    case TargetStatus.failed || TargetStatus.cancelled:
                      if (context.mounted) await showTargetError(context, ref, post, target, name);
                    default:
                      break;
                  }
                },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(3, 3, Space.sm + 2, 3),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AccountAvatar(a, size: 20, showBadge: false),
              const SizedBox(width: Space.xs + 2),
              Text(name, style: context.text.labelMedium),
              const SizedBox(width: Space.xs + 2),
              Icon(icon, size: 13, color: tone.fg(nf)),
              const SizedBox(width: 2),
              Text(label, style: context.text.labelSmall?.copyWith(color: tone.fg(nf))),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Explains a failed or cancelled target and offers a retry.
Future<void> showTargetError(BuildContext context, WidgetRef ref, Post post, PostTarget target, String platformName) {
  final e = target.result?.error;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final nf = dialogContext.nf;
      return AlertDialog(
        title: Text(target.status == TargetStatus.cancelled ? 'Not posted to $platformName' : '$platformName did not take it'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e?.message ?? 'Unknown error', style: dialogContext.text.bodyMedium?.copyWith(color: nf.text)),
            const SizedBox(height: Space.md),
            Text(_advice(e), style: dialogContext.text.bodySmall),
            if (e?.raw != null) ...[
              const SizedBox(height: Space.md),
              NfWell(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(child: SelectableText(e!.raw!, style: monoStyle(dialogContext, size: 11.5))),
                ),
              ),
            ],
          ]),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(Space.xxl, 0, Space.xxl, Space.xl),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Close')),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(dialogContext);
              final Post done;
              try {
                done = await ref.read(postActionsProvider).publishExisting(post.id, accountIds: {target.accountId});
              } on Object catch (e) {
                if (context.mounted) showToast(context, 'Could not publish: $e', icon: Icons.error_outline_rounded);
                return;
              }
              final t = done.targetFor(target.accountId);
              if (context.mounted) {
                final message = switch (t?.status) {
                  TargetStatus.failed => 'Still failing: ${t?.result?.error?.message}',
                  TargetStatus.cancelled => 'Cancelled',
                  _ => 'Posted to $platformName',
                };
                showToast(context, message, icon: t != null && needsRetry(t) ? Icons.error_outline_rounded : Icons.check_circle_rounded);
              }
            },
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Retry'),
          ),
        ],
      );
    },
  );
}

String _advice(PublishError? e) => switch (e?.kind) {
      PublishErrorKind.auth => 'The sign-in expired or was revoked. Reconnect the account in Accounts, then retry.',
      PublishErrorKind.quota => 'A posting limit was reached. Retry after it resets, or post this one by hand-off.',
      PublishErrorKind.validation => 'The platform rejected the content. Customize the post for this network and retry.',
      // Connection drops, platform or media host outages, and posts the
      // platform had not finished preparing all land here.
      PublishErrorKind.network => 'This is usually temporary: a connection problem or the platform being busy. Retry in a minute.',
      PublishErrorKind.configuration => 'Something needs setting up first (see the message above).',
      PublishErrorKind.unsupported => 'This account type cannot do that. Try a different tier for this platform.',
      PublishErrorKind.cancelled => 'Publishing was cancelled before this network got the post. Retry to post it now.',
      _ => 'Retry, and if it keeps failing, copy the details above when reporting the problem.',
    };
