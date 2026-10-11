import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:url_launcher/url_launcher.dart';

import '../../brand/neforum_logo.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';

/// Shows live progress for the publish run in [publishRunProvider].
Future<void> showPublishProgress(BuildContext context) {
  const sheet = PublishProgressSheet();
  if (context.isCompact) {
    return showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true, isDismissible: false, enableDrag: false, builder: (_) => sheet);
  }
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520, maxHeight: 760), child: sheet),
    ),
  );
}

class PublishProgressSheet extends ConsumerWidget {
  const PublishProgressSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final run = ref.watch(publishRunProvider);
    // Null while the sheet animates out after "Done"; render nothing.
    if (run == null) return const SizedBox(height: 120);
    final registry = ref.watch(registryProvider);
    final done = run.done;
    final targets = run.progress.entries.toList();
    final post = run.result;

    int count(TargetStatus s) => targets.where((e) => e.value.status == s).length;
    final ok = count(TargetStatus.published) + count(TargetStatus.handedOff);
    final failed = count(TargetStatus.failed);
    final waiting = count(TargetStatus.awaitingHandoff);
    final total = targets.length;

    final String headline;
    final String sub;
    if (!done) {
      headline = 'Posting to $total ${total == 1 ? 'network' : 'networks'}…';
      sub = 'You can keep this open. Hand-off networks will ask you to finish in their app.';
    } else if (failed == 0 && waiting == 0) {
      headline = ok == total ? 'Posted everywhere' : 'Posted to $ok of $total';
      sub = 'Your post is live on $ok ${ok == 1 ? 'network' : 'networks'}.';
    } else {
      headline = 'Posted to $ok of $total';
      sub = [
        if (failed > 0) '$failed failed',
        if (waiting > 0) '$waiting waiting for you',
      ].join(' · ');
    }

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xxl, Space.xxl, Space.md),
        child: Column(children: [
          AnimatedSwitcher(
            duration: Motion.medium,
            child: done
                ? Container(
                    key: const ValueKey('done'),
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(color: failed > 0 ? nf.warningSoft : nf.successSoft, shape: BoxShape.circle),
                    child: Icon(failed > 0 ? Icons.priority_high_rounded : Icons.check_rounded, size: 34, color: failed > 0 ? nf.warning : nf.success),
                  )
                : const NeforumMark(key: ValueKey('busy'), size: 64, animate: true),
          ),
          const SizedBox(height: Space.lg),
          Text(headline, textAlign: TextAlign.center, style: context.text.headlineSmall),
          const SizedBox(height: Space.xs),
          Text(sub, textAlign: TextAlign.center, style: context.text.bodySmall),
          if (!done) ...[
            const SizedBox(height: Space.lg),
            ClipRRect(
              borderRadius: Radii.rPill,
              child: LinearProgressIndicator(
                value: total == 0 ? null : (targets.where((e) => e.value.status != TargetStatus.pending && e.value.status != TargetStatus.publishing).length / total).clamp(0.05, 1.0),
                minHeight: 5,
              ),
            ),
          ],
        ]),
      ),
      Flexible(
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          itemCount: targets.length,
          separatorBuilder: (_, _) => Divider(height: 1, color: nf.border, indent: 60),
          itemBuilder: (context, i) {
            final e = targets[i];
            final account = ref.watch(accountByIdProvider(e.key));
            final target = post?.targetFor(e.key);
            return _Row(
              account: account,
              platformName: account == null ? 'Removed account' : (registry.descriptor(account.platformId)?.name ?? account.platformId),
              progress: e.value,
              url: target?.result?.remoteUrl,
            );
          },
        ),
      ),
      const SizedBox(height: Space.md),
      Divider(height: 1, color: nf.border),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.xl, Space.lg),
        child: Wrap(alignment: WrapAlignment.end, spacing: Space.sm, runSpacing: Space.sm, children: [
          if (done && failed > 0 && post != null)
            OutlinedButton.icon(
              onPressed: () {
                final ids = post.targets.where((t) => t.status == TargetStatus.failed).map((t) => t.accountId).toSet();
                ref.read(postActionsProvider).publishExisting(post.id, accountIds: ids);
              },
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry failed'),
            ),
          if (done && waiting > 0 && post != null)
            OutlinedButton.icon(
              onPressed: () async {
                final actions = ref.read(postActionsProvider);
                for (final t in post.targets.where((t) => t.status == TargetStatus.awaitingHandoff)) {
                  await actions.runHandoff(post.id, t.accountId);
                }
                final fresh = await ref.read(servicesProvider).posts.get(post.id);
                if (fresh != null) ref.read(publishRunProvider.notifier).finish(fresh);
              },
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: Text('Finish $waiting hand-off${waiting == 1 ? '' : 's'}'),
            ),
          if (done)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                ref.read(composerProvider.notifier).reset();
                _clearLater(ref);
              },
              child: const Text('New post'),
            ),
          FilledButton(
            onPressed: done
                ? () {
                    Navigator.pop(context);
                    if (failed == 0) ref.read(composerProvider.notifier).reset();
                    _clearLater(ref);
                  }
                : null,
            child: Text(done ? 'Done' : 'Posting…'),
          ),
        ]),
      ),
    ]);
  }
}

/// Clears the run after the sheet's exit animation so it never flashes an
/// empty state while closing.
void _clearLater(WidgetRef ref) {
  final notifier = ref.read(publishRunProvider.notifier);
  Future<void>.delayed(Motion.slow, notifier.clear);
}

class _Row extends StatelessWidget {
  const _Row({required this.account, required this.platformName, required this.progress, this.url});
  final ConnectedAccount? account;
  final String platformName;
  final TargetProgress progress;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final (label, tone, icon) = targetStatusStyle(progress.status);
    final busy = progress.status == TargetStatus.publishing || progress.status == TargetStatus.pending;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.md, horizontal: Space.sm),
      child: Row(children: [
        if (account != null) AccountAvatar(account!, size: 36) else const Icon(Icons.person_off_outlined),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(platformName, style: context.text.titleSmall),
            AnimatedSwitcher(
              duration: Motion.fast,
              child: Text(
                progress.message ?? (busy ? 'Waiting…' : label),
                key: ValueKey('${progress.status}${progress.message}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodySmall?.copyWith(color: progress.status == TargetStatus.failed ? nf.danger : nf.textMuted),
              ),
            ),
          ]),
        ),
        const SizedBox(width: Space.sm),
        AnimatedSwitcher(
          duration: Motion.medium,
          transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
          child: busy
              ? SizedBox(
                  key: const ValueKey('spin'),
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: progress.status == TargetStatus.pending ? nf.textFaint : nf.accent),
                )
              : (url != null && progress.status == TargetStatus.published
                  ? TextButton(
                      key: const ValueKey('open'),
                      onPressed: () => launchUrl(Uri.parse(url!), mode: LaunchMode.externalApplication),
                      child: const Text('Open'),
                    )
                  : StatusPill(label, key: ValueKey(label), tone: tone, icon: icon, dense: true)),
        ),
      ]),
    );
  }
}
