import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../state/composer.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';

/// Bottom bar of the composer: draft, readiness summary, schedule, post.
class ComposerActionBar extends ConsumerWidget {
  const ComposerActionBar({
    super.key,
    required this.onSaveDraft,
    required this.onSchedule,
    required this.onPublish,
    required this.onShowProblems,
    this.busy = false,
  });

  final VoidCallback onSaveDraft;
  final VoidCallback onSchedule;
  final VoidCallback onPublish;
  final VoidCallback onShowProblems;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final c = ref.watch(composerProvider);
    final r = ref.watch(composerReadinessProvider);
    final compact = context.isCompact;
    final targets = r.ready + r.handoff + r.blocked;
    final when = c.scheduledAt;

    final String label;
    if (when != null) {
      label = compact ? 'Schedule' : 'Schedule for ${DateFormat.E().add_jm().format(when)}';
    } else if (targets == 0) {
      label = 'Post';
    } else {
      label = 'Post to $targets';
    }

    String? why;
    if (c.isEmpty) {
      why = 'Write something or add media first';
    } else if (targets == 0) {
      why = 'Pick at least one account under "Post to"';
    } else if (r.blocked > 0) {
      why = '${r.blocked} ${r.blocked == 1 ? 'network needs' : 'networks need'} attention; see the previews';
    }

    final summary = Wrap(spacing: Space.md, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (r.ready > 0) _Dot(color: nf.success, label: '${r.ready} ready'),
      if (r.handoff > 0) _Dot(color: nf.warning, label: '${r.handoff} hand-off'),
      if (r.blocked > 0)
        InkWell(
          onTap: onShowProblems,
          borderRadius: Radii.rSm,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: _Dot(color: nf.danger, label: '${r.blocked} need attention', underline: true),
          ),
        ),
    ]);

    final schedule = when == null
        ? (compact
            ? IconButton.outlined(
                onPressed: busy ? null : onSchedule,
                tooltip: 'Schedule',
                icon: const Icon(Icons.schedule_rounded),
                style: IconButton.styleFrom(side: BorderSide(color: nf.border), minimumSize: const Size(44, 44)),
              )
            : PillButton(label: 'Schedule', icon: Icons.schedule_rounded, onPressed: busy ? null : onSchedule))
        : InputChip(
            avatar: Icon(Icons.schedule_rounded, size: 16, color: nf.accent),
            label: Text(DateFormat.MMMEd().add_jm().format(when)),
            onPressed: onSchedule,
            onDeleted: () => ref.read(composerProvider.notifier).setSchedule(null),
            side: BorderSide(color: nf.accent.withValues(alpha: 0.5)),
            backgroundColor: nf.accentSoft,
          );

    final post = Tooltip(
      message: why ?? (when == null ? 'Ctrl+Enter' : 'Adds it to the queue'),
      child: PrimaryAction(
        label: label,
        icon: when == null ? Icons.send_rounded : Icons.event_available_rounded,
        loading: busy,
        compact: compact,
        expand: compact,
        onPressed: why == null ? onPublish : null,
      ),
    );

    return Container(
      padding: EdgeInsets.fromLTRB(compact ? Space.lg : Space.xl, Space.md, compact ? Space.lg : Space.xl, Space.md),
      decoration: BoxDecoration(color: nf.bg, border: Border(top: BorderSide(color: nf.border))),
      child: compact
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              if (targets > 0) Padding(padding: const EdgeInsets.only(bottom: Space.sm), child: summary),
              Row(children: [
                IconButton(onPressed: busy ? null : onSaveDraft, tooltip: 'Save draft', icon: const Icon(Icons.save_outlined)),
                const SizedBox(width: Space.xs),
                if (when == null) schedule else Flexible(child: schedule),
                const SizedBox(width: Space.md),
                Expanded(child: post),
              ]),
            ])
          : Row(children: [
              TextButton.icon(
                onPressed: busy ? null : onSaveDraft,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('Save draft'),
                style: TextButton.styleFrom(foregroundColor: nf.textMuted),
              ),
              const SizedBox(width: Space.md),
              Expanded(child: summary),
              const SizedBox(width: Space.md),
              schedule,
              const SizedBox(width: Space.sm),
              post,
            ]),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.label, this.underline = false});
  final Color color;
  final String label;
  final bool underline;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: Space.xs + 2),
        Text(
          label,
          style: context.text.labelMedium?.copyWith(
            color: context.nf.textMuted,
            decoration: underline ? TextDecoration.underline : null,
            decorationColor: color,
          ),
        ),
      ]);
}
