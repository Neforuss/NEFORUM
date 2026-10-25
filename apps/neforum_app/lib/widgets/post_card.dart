import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../state/providers.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../ui/activity/time_format.dart';
import 'account_avatar.dart';
import 'badges.dart';
import 'media_thumb.dart';
import 'surfaces.dart';

/// An action in a [PostCard]'s menu.
class PostMenuAction {
  const PostMenuAction(this.label, this.icon, this.onSelected, {this.destructive = false});
  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool destructive;
}

/// Summary card for a post in Queue and Activity.
class PostCard extends ConsumerWidget {
  const PostCard({super.key, required this.post, this.onTap, this.actions = const [], this.footer, this.showTime = true});

  final Post post;
  final VoidCallback? onTap;
  final List<PostMenuAction> actions;

  /// Extra content under the body (target chips, buttons).
  final Widget? footer;
  final bool showTime;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final p = post;
    final (label, tone, icon) = postStatusStyle(p.status);
    final platforms = <String>[];
    final statuses = <TargetStatus>[];
    for (final t in p.targets) {
      final a = ref.watch(accountByIdProvider(t.accountId));
      if (a == null) continue;
      platforms.add(a.platformId);
      statuses.add(t.status);
    }
    final format = TimeFormatting.of(context, ref);
    final time = p.status == PostStatus.scheduled && p.scheduledAt != null ? format.scheduled(p.scheduledAt!) : format.moment(p.updatedAt);
    // The full weekday, date and time gets a line of its own.
    final timeInRow = showTime && !format.exact;
    final timeBelow = showTime && format.exact;

    return NfCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.xs, Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              // Room left for the platform stack after the pill, time and menu.
              final room = c.maxWidth - 110 - (timeInRow ? 90 : 0) - (actions.isEmpty ? 8 : 48);
              final maxIcons = (room / 15).floor().clamp(2, 6);
              return Row(
                children: [
                  StatusPill(label, tone: tone, icon: icon, dense: true),
                  if (timeInRow) ...[
                    const SizedBox(width: Space.sm),
                    Flexible(
                      child: Text(
                        time,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodySmall?.copyWith(color: nf.textFaint),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (platforms.isNotEmpty) PlatformStack(platforms, statuses: statuses, size: 20, max: maxIcons),
                  if (actions.isNotEmpty)
                    PopupMenuButton<int>(
                      tooltip: 'Actions',
                      icon: Icon(Icons.more_horiz_rounded, color: nf.textMuted, size: 20),
                      position: PopupMenuPosition.under,
                      onSelected: (i) => actions[i].onSelected(),
                      itemBuilder: (_) => [
                        for (var i = 0; i < actions.length; i++)
                          PopupMenuItem(
                            value: i,
                            child: Row(
                              children: [
                                Icon(actions[i].icon, size: 18, color: actions[i].destructive ? nf.danger : nf.textMuted),
                                const SizedBox(width: Space.md),
                                Text(actions[i].label, style: TextStyle(color: actions[i].destructive ? nf.danger : null)),
                              ],
                            ),
                          ),
                      ],
                    )
                  else
                    const SizedBox(width: Space.sm),
                ],
              );
            },
          ),
          if (timeBelow) ...[
            const SizedBox(height: Space.xs),
            Padding(
              padding: const EdgeInsets.only(right: Space.md),
              child: Text(time, style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
            ),
          ],
          const SizedBox(height: Space.sm),
          Padding(
            padding: const EdgeInsets.only(right: Space.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if ((p.title ?? '').isNotEmpty) ...[
                        Text(p.title!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleSmall),
                        const SizedBox(height: 2),
                      ],
                      Text(
                        p.text.trim().isEmpty
                            ? (p.media.isEmpty ? '(empty)' : '${p.media.length} attachment${p.media.length == 1 ? '' : 's'}')
                            : p.text.trim().replaceAll(RegExp(r'\n{2,}'), '\n'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodyMedium?.copyWith(color: p.text.trim().isEmpty ? nf.textFaint : nf.text),
                      ),
                    ],
                  ),
                ),
                if (p.media.isNotEmpty) ...[const SizedBox(width: Space.md), _Thumbs(media: p.media)],
              ],
            ),
          ),
          if (footer != null) ...[
            const SizedBox(height: Space.md),
            Padding(
              padding: const EdgeInsets.only(right: Space.md),
              child: footer!,
            ),
          ],
        ],
      ),
    );
  }
}

class _Thumbs extends StatelessWidget {
  const _Thumbs({required this.media});
  final List<MediaAttachment> media;

  @override
  Widget build(BuildContext context) {
    final shown = media.take(2).toList();
    final extra = media.length - shown.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < shown.length; i++)
          Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : Space.xs),
            child: Stack(
              children: [
                MediaThumb(shown[i], size: 56, showAltTag: false),
                if (i == shown.length - 1 && extra > 0)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: Radii.circular(56 * 0.14)),
                      alignment: Alignment.center,
                      child: Text(
                        '+$extra',
                        style: monoStyle(context, size: 13, color: Colors.white, weight: FontWeight.w700),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
