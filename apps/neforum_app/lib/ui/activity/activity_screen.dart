import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/layout.dart';
import '../../widgets/post_card.dart';
import '../../widgets/surfaces.dart';
import '../queue/post_menu.dart';
import '../router.dart';
import 'target_chip.dart';

enum _Filter { all, attention, failed, published }

/// History of everything posted, with what still needs the user.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  _Filter _filter = _Filter.all;

  bool _matches(Post p) => switch (_filter) {
        _Filter.all => true,
        _Filter.attention => p.targets.any((t) => t.status == TargetStatus.awaitingHandoff),
        _Filter.failed => p.targets.any(needsRetry),
        _Filter.published => p.status == PostStatus.published,
      };

  /// Deletes the posts that reached no network and skips the failed networks
  /// of the others, after the user confirms.
  Future<void> _clearFailed(List<Post> failedPosts) async {
    final active = ref.read(activePublishingProvider);
    final clearable = failedPosts.where((p) => !active.containsKey(p.id)).toList();
    if (clearable.isEmpty) return;
    final n = clearable.length;
    final ok = await confirmDialog(
      context,
      title: 'Clear $n failed ${n == 1 ? 'post' : 'posts'}?',
      message: 'Posts that reached no network are deleted. Posts that reached some networks keep them, and the networks that failed '
          'or were cancelled are marked as skipped. This cannot be undone.',
      confirmLabel: 'Clear failed',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final (:deleted, :kept) = await ref.read(postActionsProvider).clearFailed(clearable);
    if (!mounted) return;
    final cleared = deleted + kept;
    showToast(context, 'Cleared $cleared failed ${cleared == 1 ? 'post' : 'posts'}', icon: Icons.delete_sweep_outlined);
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(historyPostsProvider);
    final failedPosts = ref.watch(failedPostsProvider);
    final weekAgo = DateTime.now().subtract(const Duration(days: 7));
    final recent = history.where((p) => p.updatedAt.isAfter(weekAgo)).toList();
    final reached = recent.expand((p) => p.targets).where((t) => t.status == TargetStatus.published || t.status == TargetStatus.handedOff).length;
    final waiting = history.expand((p) => p.targets).where((t) => t.status == TargetStatus.awaitingHandoff).length;
    final failed = history.expand((p) => p.targets).where(needsRetry).length;
    final list = history.where(_matches).toList();

    void newPost() {
      ref.read(composerProvider.notifier).reset();
      context.go(AppSection.compose.path);
    }

    return PageBody(maxWidth: 1080, children: [
      PageHeader(
        eyebrow: 'Activity',
        title: "Everything you've posted",
        actions: [
          if (failedPosts.isNotEmpty)
            PopupMenuButton<int>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert_rounded),
              position: PopupMenuPosition.under,
              onSelected: (_) => _clearFailed(failedPosts),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 0,
                  child: Row(children: [Icon(Icons.delete_sweep_outlined, size: 18), SizedBox(width: Space.md), Text('Clear failed')]),
                ),
              ],
            ),
        ],
      ),
      const SizedBox(height: Space.xxl),
      ResponsiveGrid(minItemWidth: 200, spacing: Space.md, children: [
        _Stat(label: 'Posts this week', value: '${recent.length}', icon: Icons.edit_note_rounded, tone: Tone.accent, spark: _perDay(history, (p) => 1)),
        _Stat(label: 'Networks reached', value: '$reached', icon: Icons.hub_outlined, tone: Tone.info, spark: _perDay(history, (p) => p.targets.where((t) => t.status == TargetStatus.published || t.status == TargetStatus.handedOff).length)),
        _Stat(label: 'Waiting for you', value: '$waiting', icon: Icons.touch_app_outlined, tone: waiting > 0 ? Tone.warning : Tone.neutral, onTap: waiting > 0 ? () => setState(() => _filter = _Filter.attention) : null),
        _Stat(label: 'Failed', value: '$failed', icon: Icons.error_outline_rounded, tone: failed > 0 ? Tone.danger : Tone.neutral, onTap: failed > 0 ? () => setState(() => _filter = _Filter.failed) : null),
      ]),
      const SizedBox(height: Space.xxl),
      Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<_Filter>(
            segments: [
              const ButtonSegment(value: _Filter.all, label: Text('All')),
              ButtonSegment(value: _Filter.attention, label: Text(waiting > 0 ? 'Needs you ($waiting)' : 'Needs you')),
              ButtonSegment(value: _Filter.failed, label: Text(failed > 0 ? 'Failed ($failed)' : 'Failed')),
              const ButtonSegment(value: _Filter.published, label: Text('Published')),
            ],
            selected: {_filter},
            onSelectionChanged: (s) => setState(() => _filter = s.first),
            showSelectedIcon: false,
          ),
        ),
      ),
      if (_filter == _Filter.failed && failedPosts.isNotEmpty) ...[
        const SizedBox(height: Space.md),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => _clearFailed(failedPosts),
            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
            label: const Text('Clear failed'),
          ),
        ),
      ],
      const SizedBox(height: Space.lg),
      if (history.isEmpty)
        EmptyState(
          title: 'No posts yet',
          body: ref.watch(settingsProvider).publishedPostRetention == PublishedPostRetention.discardOnCompletion
              ? 'Posts show up here while they go out and while a network still needs you. Once every network has a post, NEFORUM deletes '
                  'its copy (Settings > Activity and history).'
              : 'Everything you publish shows up here, with a live link for every network.',
          action: PrimaryAction(label: 'Write your first post', icon: Icons.edit_rounded, onPressed: newPost),
        )
      else if (list.isEmpty)
        EmptyState(compact: true, icon: Icons.filter_alt_off_outlined, title: 'Nothing here', body: 'No posts match this filter.', action: TextButton(onPressed: () => setState(() => _filter = _Filter.all), child: const Text('Show all')))
      else
        for (final p in list)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: PostCard(
              post: p,
              onTap: () => context.go('${AppSection.activity.path}/post/${p.id}'),
              actions: postMenuActions(context, ref, p),
              footer: _Footer(post: p),
            ),
          ),
    ]);
  }

  /// Counts per day for the last 7 days (oldest first).
  static List<double> _perDay(List<Post> posts, int Function(Post) weight) {
    final today = DateTime.now();
    return [
      for (var i = 6; i >= 0; i--)
        posts.where((p) {
          final d = today.subtract(Duration(days: i));
          final at = p.updatedAt.toLocal();
          return at.year == d.year && at.month == d.month && at.day == d.day;
        }).fold<int>(0, (s, p) => s + weight(p)).toDouble(),
    ];
  }
}

class _Footer extends ConsumerWidget {
  const _Footer({required this.post});
  final Post post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signal = ref.watch(activePublishingProvider)[post.id];
    final waiting = post.targets.where((t) => t.status == TargetStatus.awaitingHandoff).toList();
    final retry = post.targets.where(needsRetry).toList();
    final onlyFailed = retry.every((t) => t.status == TargetStatus.failed);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: Space.xs + 2, runSpacing: Space.xs + 2, children: [for (final t in post.targets) TargetChip(post: post, target: t)]),
      if (signal != null) ...[
        // Being published by this process right now.
        const SizedBox(height: Space.md),
        OutlinedButton.icon(
          onPressed: signal.isCancelled ? null : () => ref.read(postActionsProvider).cancelPublishing(post.id),
          icon: const Icon(Icons.block_rounded, size: 17),
          label: Text(signal.isCancelled ? 'Cancelling…' : 'Cancel'),
        ),
      ] else if (waiting.isNotEmpty || retry.isNotEmpty) ...[
        const SizedBox(height: Space.md),
        Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          if (waiting.isNotEmpty)
            FilledButton.icon(
              onPressed: () async {
                final actions = ref.read(postActionsProvider);
                for (final t in waiting) {
                  await actions.runHandoff(post.id, t.accountId);
                }
              },
              icon: const Icon(Icons.ios_share_rounded, size: 17),
              label: Text('Finish ${waiting.length} hand-off${waiting.length == 1 ? '' : 's'}'),
            ),
          if (retry.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  final done = await ref.read(postActionsProvider).publishExisting(post.id, accountIds: retry.map((t) => t.accountId).toSet());
                  if (context.mounted) showPublishedToast(context, done);
                } on HeldCopiesException catch (e) {
                  if (context.mounted) await showHeldCopiesDialog(context, e);
                } on Object catch (e) {
                  if (context.mounted) showToast(context, 'Could not publish: $e', icon: Icons.error_outline_rounded);
                }
              },
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: Text(onlyFailed ? 'Retry failed' : 'Retry'),
            ),
        ]),
      ],
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.icon, required this.tone, this.spark, this.onTap});
  final String label;
  final String value;
  final IconData icon;
  final Tone tone;
  final List<double>? spark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return NfCard(
      onTap: onTap,
      padding: const EdgeInsets.all(Space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: tone.bg(nf), borderRadius: Radii.rSm),
            child: Icon(icon, size: 17, color: tone.fg(nf)),
          ),
          const Spacer(),
          if (spark != null) SizedBox(width: 72, height: 26, child: CustomPaint(painter: _SparkPainter(spark!, tone.fg(nf)))),
          if (onTap != null) Icon(Icons.arrow_forward_rounded, size: 16, color: nf.textFaint),
        ]),
        const SizedBox(height: Space.md),
        Text(value, style: context.text.displaySmall?.copyWith(fontSize: 32, height: 1)),
        const SizedBox(height: Space.xs),
        Text(label, style: context.text.bodySmall),
      ]),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color);
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final max = values.reduce((a, b) => a > b ? a : b);
    final dx = size.width / (values.length - 1);
    Offset pt(int i) => Offset(i * dx, size.height - (max == 0 ? 0 : values[i] / max) * (size.height - 3) - 1.5);
    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < values.length; i++) {
      final p0 = pt(i - 1), p1 = pt(i);
      final mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
      line.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
    }
    line.lineTo(pt(values.length - 1).dx, pt(values.length - 1).dy);
    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color.withValues(alpha: 0.25), color.withValues(alpha: 0)]).createShader(Offset.zero & size),
    );
    canvas.drawPath(line, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.values != values || old.color != color;
}
