import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../state/providers.dart';
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
        _Filter.failed => p.targets.any((t) => t.status == TargetStatus.failed),
        _Filter.published => p.status == PostStatus.published,
      };

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(historyPostsProvider);
    final weekAgo = DateTime.now().subtract(const Duration(days: 7));
    final recent = history.where((p) => p.updatedAt.isAfter(weekAgo)).toList();
    final reached = recent.expand((p) => p.targets).where((t) => t.status == TargetStatus.published || t.status == TargetStatus.handedOff).length;
    final waiting = history.expand((p) => p.targets).where((t) => t.status == TargetStatus.awaitingHandoff).length;
    final failed = history.expand((p) => p.targets).where((t) => t.status == TargetStatus.failed).length;
    final list = history.where(_matches).toList();

    void newPost() {
      ref.read(composerProvider.notifier).reset();
      context.go(AppSection.compose.path);
    }

    return PageBody(maxWidth: 1080, children: [
      const PageHeader(eyebrow: 'Activity', title: "Everything you've posted"),
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
      const SizedBox(height: Space.lg),
      if (history.isEmpty)
        EmptyState(
          title: 'No posts yet',
          body: 'Everything you publish shows up here, with a live link for every network.',
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
          return p.updatedAt.year == d.year && p.updatedAt.month == d.month && p.updatedAt.day == d.day;
        }).fold<int>(0, (s, p) => s + weight(p)).toDouble(),
    ];
  }
}

class _Footer extends ConsumerWidget {
  const _Footer({required this.post});
  final Post post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = post.targets.where((t) => t.status == TargetStatus.awaitingHandoff).toList();
    final failed = post.targets.where((t) => t.status == TargetStatus.failed).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: Space.xs + 2, runSpacing: Space.xs + 2, children: [for (final t in post.targets) TargetChip(post: post, target: t)]),
      if (waiting.isNotEmpty || failed.isNotEmpty) ...[
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
          if (failed.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () async {
                final done = await ref.read(postActionsProvider).publishExisting(post.id, accountIds: failed.map((t) => t.accountId).toSet());
                if (context.mounted) showPublishedToast(context, done);
              },
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: const Text('Retry failed'),
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
