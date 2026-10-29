import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:url_launcher/url_launcher.dart';

import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/layout.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/surfaces.dart';
import '../compose/rich_text.dart';
import '../queue/post_menu.dart';
import '../router.dart';
import 'schedule_summary.dart';
import '../shell/app_backdrop.dart';
import 'time_format.dart';

/// Everything about one post: text, media and every network's outcome.
class PostDetailScreen extends ConsumerWidget {
  const PostDetailScreen({super.key, required this.postId});
  final String postId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final post = ref.watch(postByIdProvider(postId));
    final loading = ref.watch(postsProvider).isLoading && post == null;
    void back() => context.canPop() ? context.pop() : context.go(AppSection.activity.path);

    final backButton = Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: back,
        icon: const Icon(Icons.arrow_back_rounded, size: 18),
        label: const Text('Activity'),
        style: TextButton.styleFrom(foregroundColor: nf.textMuted),
      ),
    );

    if (loading) return const Center(child: CircularProgressIndicator());
    if (post == null) {
      return PageBody(maxWidth: 860, children: [
        backButton,
        const EmptyState(
          icon: Icons.search_off_rounded,
          title: 'This post is no longer in NEFORUM',
          body: 'It was deleted, by you or because every network has it (Settings > Activity and history).',
        ),
      ]);
    }

    final (label, tone, icon) = postStatusStyleOf(post);
    final format = TimeFormatting.of(context, ref);
    final registry = ref.watch(registryProvider);
    String? networkOf(String accountId) {
      final a = ref.watch(accountByIdProvider(accountId));
      return a == null ? null : registry.descriptor(a.platformId)?.name ?? a.displayName;
    }

    final summary = scheduleSummary(post, networkOf: networkOf, format: format);
    final timeLine = switch (post.status) {
      PostStatus.scheduled when summary != null => summary,
      PostStatus.scheduled when post.scheduledAt != null => 'Scheduled for ${format.scheduled(post.scheduledAt!)}',
      PostStatus.draft => 'Draft · edited ${format.moment(post.updatedAt)}',
      PostStatus.publishing => 'Started ${format.moment(post.updatedAt)}',
      PostStatus.failed => 'Last tried ${format.moment(post.updatedAt)}',
      PostStatus.cancelled => 'Cancelled ${format.moment(post.updatedAt)}',
      _ => 'Posted ${format.moment(post.updatedAt)}',
    };
    final publishing = ref.watch(activePublishingProvider)[post.id];
    final style = context.text.bodyLarge!.copyWith(height: 1.55);

    return Scaffold(
      // Over a background picture the page lets it show, as the others do.
      backgroundColor: AppBackdrop.activeOf(context) ? Colors.transparent : nf.bg,
      body: PageBody(maxWidth: 860, children: [
        backButton,
        const SizedBox(height: Space.md),
        Row(children: [
          StatusPill(label, tone: tone, icon: icon),
          const SizedBox(width: Space.md),
          Expanded(child: Text(timeLine, style: context.text.bodyMedium?.copyWith(color: nf.textMuted))),
        ]),
        const SizedBox(height: Space.lg),
        NfCard(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if ((post.title ?? '').isNotEmpty) ...[
              Text(post.title!, style: context.text.headlineSmall),
              const SizedBox(height: Space.md),
            ],
            if (post.contentWarning != null) ...[
              StatusPill('CW: ${post.contentWarning}', tone: Tone.warning, icon: Icons.warning_amber_rounded),
              const SizedBox(height: Space.md),
            ],
            SelectableText.rich(TextSpan(style: style, children: highlightSpans(post.text.isEmpty ? '(no text)' : post.text, style, nf))),
            if (post.media.isNotEmpty) ...[
              const SizedBox(height: Space.lg),
              Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
                for (final m in post.media)
                  GestureDetector(
                    onTap: () => _viewMedia(context, m),
                    child: MouseRegion(cursor: SystemMouseCursors.zoomIn, child: MediaThumb(m, size: 120)),
                  ),
              ]),
            ],
            if (post.link != null || post.tags.isNotEmpty) ...[
              const SizedBox(height: Space.lg),
              Wrap(spacing: Space.xs + 2, runSpacing: Space.xs + 2, children: [
                if (post.link != null) StatusPill(post.link!, tone: Tone.info, icon: Icons.link_rounded),
                for (final t in post.tags) StatusPill('#$t', tone: Tone.accent),
              ]),
            ],
          ]),
        ),
        const SizedBox(height: Space.x3),
        SectionHeader('Networks', subtitle: '${post.targets.length} ${post.targets.length == 1 ? 'destination' : 'destinations'}'),
        const SizedBox(height: Space.md),
        NfCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (var i = 0; i < post.targets.length; i++) ...[
              if (i > 0) Divider(height: 1, color: nf.border),
              _TargetRow(post: post, target: post.targets[i]),
            ],
          ]),
        ),
        const SizedBox(height: Space.x3),
        Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          if (publishing != null)
            OutlinedButton.icon(
              onPressed: publishing.isCancelled ? null : () => ref.read(postActionsProvider).cancelPublishing(post.id),
              icon: const Icon(Icons.block_rounded, size: 18),
              label: Text(publishing.isCancelled ? 'Cancelling…' : 'Cancel publishing'),
            ),
          for (final a in postMenuActions(context, ref, post).where((a) => !a.destructive))
            OutlinedButton.icon(onPressed: a.onSelected, icon: Icon(a.icon, size: 18), label: Text(a.label)),
          OutlinedButton.icon(
            onPressed: () async {
              if (await confirmDeletePost(context, ref, post)) back();
            },
            icon: Icon(Icons.delete_outline_rounded, size: 18, color: nf.danger),
            label: Text('Delete', style: TextStyle(color: nf.danger)),
          ),
        ]),
      ]),
    );
  }

  void _viewMedia(BuildContext context, MediaAttachment m) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          InteractiveViewer(child: MediaThumb(m, size: MediaQuery.sizeOf(context).height * 0.7, aspect: m.aspectRatio ?? 1, fit: BoxFit.contain, radius: BorderRadius.zero)),
          Positioned(right: 8, top: 8, child: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.white), tooltip: 'Close')),
          if ((m.altText ?? '').isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.all(Space.md),
                child: Text(m.altText!, style: const TextStyle(color: Colors.white)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// What a target's [PublishResult.additionalRemoteIds] stand for: the frames
/// of a story ([placement] story, after the first) or the story next to the
/// feed post (Post + Story).
String copiesLabel(PostPlacement placement, int additional) => placement == PostPlacement.story
    ? 'Posted as a story of ${additional + 1} frames'
    : 'Posted with a story of $additional ${additional == 1 ? 'frame' : 'frames'}';

class _TargetRow extends ConsumerStatefulWidget {
  const _TargetRow({required this.post, required this.target});
  final Post post;
  final PostTarget target;

  @override
  ConsumerState<_TargetRow> createState() => _TargetRowState();
}

class _TargetRowState extends ConsumerState<_TargetRow> {
  bool _details = false;
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on HeldCopiesException catch (e) {
      if (mounted) await showHeldCopiesDialog(context, e);
    } on Object catch (e) {
      if (mounted) showToast(context, 'Could not do that: $e', icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final t = widget.target;
    final a = ref.watch(accountByIdProvider(t.accountId));
    final d = a == null ? null : ref.watch(registryProvider).descriptor(a.platformId);
    final (label, tone, icon) = targetStatusStyle(t.status);
    final err = t.result?.error;
    final url = t.result?.remoteUrl;
    final actions = ref.read(postActionsProvider);
    final format = TimeFormatting.of(context, ref);
    // This network's own time, not the post's last change.
    final due = widget.post.dueAtFor(t);
    final (String? timeLabel, DateTime? timeAt) = switch (t.status) {
      // Its own time when the post has a different time per network.
      TargetStatus.pending when widget.post.status == PostStatus.scheduled && due != null && t.attempts == 0 => ('Goes out', due),
      TargetStatus.published => ('Posted', t.result?.publishedAt ?? t.lastAttemptAt),
      TargetStatus.handedOff => ('Handed off', t.lastAttemptAt),
      TargetStatus.failed || TargetStatus.cancelled => ('Last tried', t.lastAttemptAt),
      _ => (null, null),
    };
    final busyElsewhere = ref.watch(activePublishingProvider).containsKey(widget.post.id);

    final buttons = <Widget>[
      if (url != null && t.status == TargetStatus.published)
        TextButton.icon(onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication), icon: const Icon(Icons.open_in_new_rounded, size: 16), label: const Text('Open')),
      if (t.status == TargetStatus.awaitingHandoff) ...[
        FilledButton.icon(onPressed: _busy ? null : () => _run(() => actions.runHandoff(widget.post.id, t.accountId)), icon: const Icon(Icons.ios_share_rounded, size: 16), label: const Text('Hand off now')),
        TextButton(onPressed: _busy ? null : () => _run(() => actions.markHandedOff(widget.post.id, t.accountId)), child: const Text('Mark as posted')),
      ],
      if (t.status == TargetStatus.handedOff)
        TextButton(onPressed: _busy ? null : () => _run(() => actions.markHandedOff(widget.post.id, t.accountId, done: false)), child: const Text('Mark as not posted')),
      if (needsRetry(t) && !busyElsewhere)
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _run(() => actions.publishExisting(widget.post.id, accountIds: {t.accountId})),
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: const Text('Retry'),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.all(Space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (a != null) AccountAvatar(a, size: 38) else const Icon(Icons.person_off_outlined),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: Space.sm, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(d?.name ?? 'Removed account', style: context.text.titleSmall),
                StatusPill(label, tone: tone, icon: icon, dense: true),
              ]),
              Text(a?.handle ?? a?.displayName ?? '', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
              if (timeLabel != null && timeAt != null) Text('$timeLabel ${format.moment(timeAt)}', style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
              // Automatic posting filled the page in without a confirmed post.
              if (t.status == TargetStatus.awaitingHandoff && t.handoffNote != null) ...[
                const SizedBox(height: Space.xs + 2),
                Text(t.handoffNote!, style: context.text.bodySmall?.copyWith(color: nf.warning)),
              ],
              if (err != null) ...[
                const SizedBox(height: Space.xs + 2),
                Text(err.message, style: context.text.bodySmall?.copyWith(color: nf.danger)),
                // No Retry: it would post the live copies a second time.
                if (t.isPartlyLive)
                  Text('Part of this is already live on ${d?.name ?? 'the network'}, so NEFORUM does not post it again. '
                      'Post what is missing again as a new post.', style: context.text.bodySmall),
              ] else if (t.isHeldByPlatform && t.result?.scheduledFor != null) ...[
                const SizedBox(height: Space.xs),
                Text(
                  '${d?.name ?? 'The platform'} holds this post and publishes it itself on ${format.exactTime(t.result!.scheduledFor!)}, even if this device is off. Editing or deleting the post here takes it back.',
                  style: context.text.bodySmall,
                ),
              ] else if (t.result?.threadRemoteIds.isNotEmpty ?? false) ...[
                const SizedBox(height: Space.xs),
                Text('Posted as a ${t.result!.threadRemoteIds.length}-part thread', style: context.text.bodySmall),
              ] else if (t.result?.additionalRemoteIds.isNotEmpty ?? false) ...[
                const SizedBox(height: Space.xs),
                Text(copiesLabel(placementOfExtra(t.overrides.extra), t.result!.additionalRemoteIds.length), style: context.text.bodySmall),
              ],
              if (t.attempts > 1) Text('${t.attempts} attempts', style: context.text.bodySmall?.copyWith(color: nf.textFaint, fontSize: 11)),
            ]),
          ),
          if (_busy) const Padding(padding: EdgeInsets.all(Space.sm), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
        ]),
        if (buttons.isNotEmpty) ...[
          const SizedBox(height: Space.sm),
          Padding(padding: const EdgeInsets.only(left: 50), child: Wrap(spacing: Space.sm, runSpacing: Space.xs, children: buttons)),
        ],
        if (err != null) ...[
          Padding(
            padding: const EdgeInsets.only(left: 42),
            child: TextButton.icon(
              onPressed: () => setState(() => _details = !_details),
              icon: Icon(_details ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
              label: const Text('Technical details'),
              style: TextButton.styleFrom(foregroundColor: nf.textMuted),
            ),
          ),
          AnimatedSize(
            duration: Motion.medium,
            child: !_details
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(left: 50),
                    child: NfWell(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                          child: SelectableText(
                            'kind: ${err.kind.name}\nretryable: ${err.retryable}${err.statusCode == null ? '' : '\nHTTP ${err.statusCode}'}${err.raw == null ? '' : '\n\n${err.raw}'}',
                            style: monoStyle(context, size: 11.5),
                          ),
                        ),
                        ToolButton(
                          icon: Icons.copy_rounded,
                          tooltip: 'Copy',
                          size: 32,
                          onPressed: () => Clipboard.setData(ClipboardData(text: '${err.message}\n${err.kind.name} ${err.statusCode ?? ''}\n${err.raw ?? ''}')),
                        ),
                      ]),
                    ),
                  ),
          ),
        ],
      ]),
    );
  }
}
