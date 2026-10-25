import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../platform/env.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/layout.dart';
import '../../widgets/post_card.dart';
import '../activity/time_format.dart';
import '../router.dart';
import 'post_menu.dart';

/// Scheduled posts on a timeline, plus drafts.
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key});

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen> {
  DateTime _weekStart = dayOf(DateTime.now());
  DateTime? _selectedDay;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final scheduled = ref.watch(scheduledPostsProvider);
    final drafts = ref.watch(draftPostsProvider);
    void newPost() {
      ref.read(composerProvider.notifier).reset();
      context.go(AppSection.compose.path);
    }

    final visible = _selectedDay == null ? scheduled : scheduled.where((p) => dayOf(p.scheduledAt!) == _selectedDay).toList();
    final byDay = <DateTime, List<Post>>{};
    for (final p in visible) {
      byDay.putIfAbsent(dayOf(p.scheduledAt!), () => []).add(p);
    }
    final counts = <DateTime, int>{};
    for (final p in scheduled) {
      final d = dayOf(p.scheduledAt!);
      counts[d] = (counts[d] ?? 0) + 1;
    }

    return PageBody(maxWidth: 980, children: [
      PageHeader(
        eyebrow: 'Queue',
        title: "What's coming up",
        subtitle: '${scheduled.length} scheduled · ${drafts.length} ${drafts.length == 1 ? 'draft' : 'drafts'}',
        actions: [PrimaryAction(label: 'New post', icon: Icons.add_rounded, onPressed: newPost, compact: true)],
      ),
      const SizedBox(height: Space.md),
      Row(children: [
        Icon(Icons.info_outline_rounded, size: 15, color: nf.textFaint),
        const SizedBox(width: Space.sm),
        Expanded(child: Text(_howItWorks(), style: context.text.bodySmall?.copyWith(color: nf.textFaint))),
      ]),
      const SizedBox(height: Space.xxl),
      _WeekStrip(
        start: _weekStart,
        selected: _selectedDay,
        counts: counts,
        onSelect: (d) => setState(() => _selectedDay = _selectedDay == d ? null : d),
        onShift: (weeks) => setState(() {
          final next = _weekStart.add(Duration(days: 7 * weeks));
          final today = dayOf(DateTime.now());
          _weekStart = next.isBefore(today) ? today : next;
        }),
      ),
      const SizedBox(height: Space.xxl),
      if (scheduled.isEmpty)
        EmptyState(
          title: 'Nothing scheduled yet',
          body: 'Write a post and pick a time. NEFORUM sends it to every network on schedule, even while it sits in your tray.',
          action: PrimaryAction(label: 'Write a post', icon: Icons.edit_rounded, onPressed: newPost),
        )
      else if (visible.isEmpty)
        EmptyState(
          compact: true,
          icon: Icons.event_busy_outlined,
          title: 'Nothing on ${DateFormat.MMMMEEEEd().format(_selectedDay!)}',
          body: 'Pick another day, or tap it again to see everything.',
        )
      else
        for (final e in byDay.entries) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: Row(children: [
              Flexible(child: Text(TimeFormatting.of(context, ref).day(e.key), style: context.text.titleLarge)),
              const SizedBox(width: Space.sm),
              Text('${e.value.length} ${e.value.length == 1 ? 'post' : 'posts'}', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
            ]),
          ),
          for (var i = 0; i < e.value.length; i++) _AgendaRow(post: e.value[i], last: i == e.value.length - 1),
          const SizedBox(height: Space.xl),
        ],
      if (drafts.isNotEmpty) ...[
        const SizedBox(height: Space.lg),
        SectionHeader('Drafts', subtitle: 'Saved but not scheduled.', icon: Icons.inventory_2_outlined),
        const SizedBox(height: Space.md),
        ResponsiveGrid(
          minItemWidth: 360,
          maxColumns: 2,
          spacing: Space.md,
          children: [
            for (final p in drafts)
              PostCard(
                post: p,
                onTap: () => context.go('${AppSection.compose.path}?post=${p.id}'),
                actions: postMenuActions(context, ref, p),
              ),
          ],
        ),
      ],
    ]);
  }

  static String _howItWorks() {
    if (Env.isIOS) return "On iPhone you'll get a notification at the scheduled time; tap it to publish.";
    if (Env.isAndroid) return 'Posts go out in the background within a few minutes of their time.';
    if (Env.isDesktop) return 'Keep NEFORUM running (it lives in the tray) and posts go out on time.';
    return 'Scheduled posts go out from the installed app on your phone or computer.';
  }
}

class _WeekStrip extends StatelessWidget {
  const _WeekStrip({required this.start, required this.selected, required this.counts, required this.onSelect, required this.onShift});

  final DateTime start;
  final DateTime? selected;
  final Map<DateTime, int> counts;
  final ValueChanged<DateTime> onSelect;
  final ValueChanged<int> onShift;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final today = dayOf(DateTime.now());
    final days = [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
    final arrow = context.isCompact ? 30.0 : 38.0;
    return Row(children: [
      ToolButton(icon: Icons.chevron_left_rounded, tooltip: 'Earlier', size: arrow, onPressed: start.isAfter(today) ? () => onShift(-1) : null),
      const SizedBox(width: Space.xs),
      Expanded(
        child: Row(children: [
          for (final d in days)
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: context.isCompact ? 1.5 : 3),
                child: _DayCell(
                  day: d,
                  count: counts[d] ?? 0,
                  today: d == today,
                  selected: selected == d,
                  onTap: () => onSelect(d),
                  nf: nf,
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(width: Space.xs),
      ToolButton(icon: Icons.chevron_right_rounded, tooltip: 'Later', size: arrow, onPressed: () => onShift(1)),
    ]);
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.day, required this.count, required this.today, required this.selected, required this.onTap, required this.nf});
  final DateTime day;
  final int count;
  final bool today;
  final bool selected;
  final VoidCallback onTap;
  final NfColors nf;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : (today ? nf.accent : nf.text);
    return Tooltip(
      message: '${DateFormat.MMMMEEEEd().format(day)}: ${count == 0 ? 'nothing scheduled' : '$count scheduled'}',
      child: Material(
        color: selected ? nf.accent : nf.surface,
        shape: RoundedRectangleBorder(borderRadius: Radii.rMd, side: BorderSide(color: selected ? nf.accent : (today ? nf.accent.withValues(alpha: 0.5) : nf.border))),
        child: InkWell(
          borderRadius: Radii.rMd,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.md),
            child: Column(children: [
              Text(
                (context.isCompact ? DateFormat.EEEEE() : DateFormat.E()).format(day).toUpperCase(),
                style: context.text.labelSmall?.copyWith(color: selected ? Colors.white70 : nf.textFaint, letterSpacing: context.isCompact ? 0 : 1),
              ),
              const SizedBox(height: Space.xs),
              Text('${day.day}', style: context.text.titleLarge?.copyWith(color: fg)),
              const SizedBox(height: Space.xs),
              SizedBox(
                height: 6,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < count.clamp(0, 3); i++)
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      decoration: BoxDecoration(color: selected ? Colors.white : nf.accent, shape: BoxShape.circle),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _AgendaRow extends ConsumerWidget {
  const _AgendaRow({required this.post, required this.last});
  final Post post;
  final bool last;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final t = post.scheduledAt!;
    final format = TimeFormatting.of(context, ref);
    final soon = t.difference(DateTime.now()).inMinutes < 60;
    if (context.isCompact) {
      // Phones: no separate time column; the card shows the time.
      return Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : Space.md),
        child: PostCard(
          post: post,
          onTap: () => context.go('${AppSection.compose.path}?post=${post.id}'),
          actions: postMenuActions(context, ref, post),
        ),
      );
    }
    const timeW = 72.0;
    const nodeW = 32.0;
    // The connector line is painted behind the row so no intrinsic sizing is
    // needed (the card uses LayoutBuilder).
    return Stack(children: [
      if (!last)
        Positioned(
          left: timeW + nodeW / 2 - 1,
          top: Space.lg + 11,
          bottom: 0,
          child: Container(width: 2, color: nf.border),
        ),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: timeW,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            const SizedBox(height: Space.md + 2),
            Text(format.clock(t), style: monoStyle(context, size: 13, color: nf.text, weight: FontWeight.w600)),
            if (soon) Text(inFuture(t, use24Hour: format.use24Hour), style: context.text.bodySmall?.copyWith(color: nf.accent, fontSize: 11)),
          ]),
        ),
        SizedBox(
          width: nodeW,
          child: Padding(
            padding: const EdgeInsets.only(top: Space.lg),
            child: Center(
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(color: soon ? nf.accent : nf.surface, shape: BoxShape.circle, border: Border.all(color: nf.accent, width: 2)),
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : Space.md),
            child: PostCard(
              post: post,
              showTime: false,
              onTap: () => context.go('${AppSection.compose.path}?post=${post.id}'),
              actions: postMenuActions(context, ref, post),
            ),
          ),
        ),
      ]),
    ]);
  }
}
