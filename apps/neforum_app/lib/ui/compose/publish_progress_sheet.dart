import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:url_launcher/url_launcher.dart';

import '../../brand/neforum_logo.dart';
import '../../state/composer.dart';
import '../../state/notification_state.dart';
import '../../state/providers.dart';
import '../../state/publish_progress_view.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';
import '../../widgets/publish_progress.dart';
import '../shell/notification_prompt.dart';

/// Shows live progress for the publish run in [publishRunProvider].
Future<void> showPublishProgress(BuildContext context) {
  const sheet = PublishProgressSheet();
  // While it is open and visible, the sheet is the run's result (D10).
  final open = ProviderScope.containerOf(context, listen: false).read(publishSheetOpenProvider.notifier)..opened();
  final Future<void> shown;
  if (context.isCompact) {
    shown = showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true, isDismissible: false, enableDrag: false, builder: (_) => sheet);
  } else {
    shown = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520, maxHeight: 760), child: sheet),
      ),
    );
  }
  return shown.whenComplete(open.closed);
}

/// The run's progress, with Cancel while it goes. It cannot be swiped
/// away, so every state, an error included, offers a way to close it.
class PublishProgressSheet extends ConsumerWidget {
  const PublishProgressSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final run = ref.watch(publishRunProvider);
    // A Cancel pressed in Activity changes this map.
    ref.watch(activePublishingProvider);
    // Null only while the sheet animates out after "Done".
    if (run == null) return _Closing(onClose: () => Navigator.pop(context));
    final registry = ref.watch(registryProvider);
    final done = run.done;
    final error = run.error;
    final targets = run.progress.entries.toList();
    final post = run.result;
    // The run's figures, from the moment it has a plan until it is over. Before that
    // nothing is known to count, and after it the post is the record.
    final postId = run.postId;
    final live = done || postId == null ? null : ref.watch(publishProgressOfProvider(postId));
    // Saved as each network ends, so a finished row has its link or its error at once.
    final saved = postId == null ? null : ref.watch(postByIdProvider(postId));

    int count(TargetStatus s) => targets.where((e) => e.value.status == s).length;
    final ok = count(TargetStatus.published) + count(TargetStatus.handedOff);
    final failed = count(TargetStatus.failed);
    final cancelled = count(TargetStatus.cancelled);
    final waiting = count(TargetStatus.awaitingHandoff);
    // A plan with no member of this run is about to end: the words stay as they were.
    final total = live == null || live.total == 0 ? targets.length : live.total;

    final String headline;
    final String sub;
    if (error != null) {
      headline = 'Could not post';
      sub = error;
    } else if (run.preparing) {
      headline = run.cancelling ? 'Cancelling…' : kGettingReady;
      sub = 'Saving it and preparing the photos each network needs.';
    } else if (!done) {
      headline = run.cancelling ? 'Cancelling…' : 'Posting to $total ${total == 1 ? 'network' : 'networks'}…';
      sub = run.cancelling
          ? 'Stopping after the network being posted to now. Anything already posted stays online.'
          : 'You can keep this open. Hand-off networks will ask you to finish in their app.';
    } else if (cancelled > 0 && ok == 0 && failed == 0 && waiting == 0) {
      headline = 'Posting cancelled';
      sub = 'Nothing was posted. You can post it later from Activity.';
    } else if (ok == 0 && failed == 0 && waiting == 0 && cancelled == 0) {
      // Every network was skipped (or its account is switched off).
      headline = 'Nothing was posted';
      sub = 'Every network was skipped. The post stays in Activity.';
    } else if (failed == 0 && waiting == 0 && cancelled == 0) {
      headline = ok == total ? 'Posted everywhere' : 'Posted to $ok of $total';
      sub = 'Your post is live on $ok ${ok == 1 ? 'network' : 'networks'}.';
    } else {
      headline = 'Posted to $ok of $total';
      sub = [
        if (failed > 0) '$failed failed',
        if (cancelled > 0) '$cancelled cancelled',
        if (waiting > 0) '$waiting waiting for you',
      ].join(' · ');
    }

    final Widget badge;
    if (!done) {
      badge = const NeforumMark(key: ValueKey('busy'), size: 64, animate: true);
    } else {
      final problem = error != null || failed > 0;
      // Cancelled or skipped everywhere: nothing went out, nothing failed.
      final nothingPosted = !problem && ok == 0 && waiting == 0;
      badge = Container(
        key: const ValueKey('done'),
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: error != null ? nf.dangerSoft : (problem ? nf.warningSoft : (nothingPosted ? nf.surfaceSunken : nf.successSoft)),
          shape: Radii.circleShape,
        ),
        child: Icon(
          error != null ? Icons.error_outline_rounded : (problem ? Icons.priority_high_rounded : (nothingPosted ? Icons.block_rounded : Icons.check_rounded)),
          size: 34,
          color: error != null ? nf.danger : (problem ? nf.warning : (nothingPosted ? nf.textMuted : nf.success)),
        ),
      );
    }

    final retryIds = post == null ? const <String>{} : post.targets.where(needsRetry).map((t) => t.accountId).toSet();
    // Once the plan is known its members are the rows: a network this run leaves
    // alone has no row to look busy in.
    final rowIds = live != null ? [for (final t in live.targets) t.accountId] : [for (final e in targets) e.key];
    final liveRows = {for (final t in live?.targets ?? const <TargetProgress>[]) t.accountId: t};

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xxl, Space.xxl, Space.md),
        child: Column(children: [
          // A phone on its side keeps its room for the networks.
          if (MediaQuery.sizeOf(context).height >= 480) ...[
            AnimatedSwitcher(duration: Motion.medium, child: badge),
            const SizedBox(height: Space.lg),
          ],
          Text(headline, textAlign: TextAlign.center, style: context.text.headlineSmall),
          const SizedBox(height: Space.xs),
          Text(sub, textAlign: TextAlign.center, style: context.text.bodySmall?.copyWith(color: error != null ? nf.danger : null)),
          if (!done) ...[
            const SizedBox(height: Space.lg),
            if (live == null || live.total == 0) const PublishGettingReady() else PostProgressFigure(live),
          ],
        ]),
      ),
      const NotificationHintLine(),
      if (rowIds.isNotEmpty)
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: Space.lg),
            itemCount: rowIds.length,
            separatorBuilder: (_, _) => Divider(height: 1, color: nf.border, indent: 60),
            itemBuilder: (context, i) {
              final id = rowIds[i];
              final account = ref.watch(accountByIdProvider(id));
              return _Row(
                account: account,
                platformName: account == null ? 'Removed account' : (registry.descriptor(account.platformId)?.name ?? account.platformId),
                row: run.progress[id],
                live: liveRows[id],
                reportedAt: live?.at,
                saved: post?.targetFor(id) ?? saved?.targetFor(id),
                stopped: done,
              );
            },
          ),
        ),
      const SizedBox(height: Space.md),
      Divider(height: 1, color: nf.border),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.xl, Space.lg),
        child: Wrap(alignment: WrapAlignment.end, spacing: Space.sm, runSpacing: Space.sm, children: [
          if (done && error == null && retryIds.isNotEmpty && post != null)
            OutlinedButton.icon(
              // A failure shows in this sheet (the run's error).
              onPressed: () => ref.read(postActionsProvider).publishExisting(post.id, accountIds: retryIds).then((_) {}, onError: (Object _) {}),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(cancelled == 0 ? 'Retry failed' : 'Retry'),
            ),
          if (done && error == null && waiting > 0 && post != null)
            OutlinedButton.icon(
              onPressed: () async {
                final actions = ref.read(postActionsProvider);
                Post? last;
                for (final t in post.targets.where((t) => t.status == TargetStatus.awaitingHandoff)) {
                  last = await actions.runHandoff(post.id, t.accountId);
                }
                // The last hand-off can complete the post, which may then be
                // deleted (Settings > Activity and history).
                final fresh = await ref.read(servicesProvider).posts.get(post.id) ?? last;
                if (fresh != null) ref.read(publishRunProvider.notifier).finish(fresh);
              },
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: Text('Finish $waiting hand-off${waiting == 1 ? '' : 's'}'),
            ),
          if (done)
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                _clearLater(ref);
              },
              child: Text(error != null ? 'Close' : 'Done'),
            )
          else
            OutlinedButton(
              onPressed: run.cancelling
                  ? null
                  : () {
                      final id = run.postId;
                      if (id == null) {
                        ref.read(publishRunProvider.notifier).cancel();
                      } else {
                        ref.read(postActionsProvider).cancelPublishing(id);
                      }
                    },
              child: Text(run.cancelling ? 'Cancelling…' : 'Cancel'),
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

/// What the sheet shows when there is no run (normally only while it
/// animates out): still a way to close it.
class _Closing extends StatelessWidget {
  const _Closing({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 120,
        child: Center(child: TextButton(onPressed: onClose, child: const Text('Close'))),
      );
}

class _Row extends StatelessWidget {
  const _Row({required this.account, required this.platformName, this.row, this.live, this.reportedAt, this.saved, this.stopped = false});
  final ConnectedAccount? account;
  final String platformName;

  /// The row before the plan is known, and after the run.
  final PublishRunRow? row;

  /// The row from the plan on.
  final TargetProgress? live;
  final DateTime? reportedAt;

  /// The target as last saved, which holds what it ended with.
  final PostTarget? saved;

  /// The run is over: nothing is waiting any more, even a target the run
  /// never reached (it stopped with an error).
  final bool stopped;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final outcome = live?.outcome;
    final running = !stopped && live != null && outcome == null;
    final status = outcome == null ? (row?.status ?? TargetStatus.pending) : statusOfOutcome(outcome, saved: saved);
    final (label, tone, icon) = targetStatusStyle(status);
    // The run has not got to it, and may be making its smaller video copy.
    final before = !stopped && live == null && (status == TargetStatus.publishing || status == TargetStatus.pending);
    final ended = outcome == TargetOutcome.failed || outcome == TargetOutcome.cancelled || outcome == TargetOutcome.skipped;
    // A saved error is from this run only once this run has ended the target.
    final message = live == null ? row?.message : (ended ? saved?.result?.error?.message : null);
    final words = message ?? (status == TargetStatus.awaitingHandoff ? 'Waiting for you' : label);
    final url = saved?.result?.remoteUrl;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.md, horizontal: Space.sm),
      child: Row(children: [
        if (account != null) AccountAvatar(account!, size: 36) else const Icon(Icons.person_off_outlined),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(platformName, style: context.text.titleSmall),
            if (running)
              TargetProgressLine(live!, reportedAt: reportedAt)
            else
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Only the smaller copy is under way this early, and it has its own number.
                if (before && status == TargetStatus.publishing)
                  Padding(
                    padding: const EdgeInsets.only(top: 3, right: Space.xs + 2),
                    child: ExcludeSemantics(child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: nf.accent))),
                  ),
                Expanded(
                  child: Text(
                    before ? (message ?? 'Waiting') : words,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall?.copyWith(color: status == TargetStatus.failed ? nf.danger : nf.textMuted),
                  ),
                ),
              ]),
          ]),
        ),
        if (!running && !before) ...[
          const SizedBox(width: Space.sm),
          AnimatedSwitcher(
            duration: Motion.medium,
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
            child: url != null && status == TargetStatus.published
                ? TextButton(
                    key: const ValueKey('open'),
                    onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                    child: const Text('Open'),
                  )
                : StatusPill(label, key: ValueKey(label), tone: tone, icon: icon, dense: true),
          ),
        ],
      ]),
    );
  }
}
