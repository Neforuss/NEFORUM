import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart';
import 'customize_sheet.dart';
import 'preview_card.dart';

/// How big compact previews are drawn.
const double kCompactPreviewScale = 0.8;

/// Scrollable list of per-network previews.
class PreviewPane extends ConsumerWidget {
  const PreviewPane({super.key, this.padding = const EdgeInsets.all(Space.xl), this.showHeader = true, this.controller});

  final EdgeInsets padding;
  final bool showHeader;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final previews = ref.watch(composerPreviewsProvider);
    final accounts = ref.watch(accountListProvider);
    final readiness = ref.watch(composerReadinessProvider);
    final compact = ref.watch(settingsProvider.select((s) => s.compactPreviews));

    if (previews.isEmpty) {
      return Center(
        child: EmptyState(
          compact: true,
          icon: Icons.visibility_outlined,
          title: accounts.isEmpty ? 'Previews show up here' : 'Pick where to post',
          body: accounts.isEmpty
              ? 'Connect an account and you will see how your post looks on each network before it goes out.'
              : 'Select one or more accounts under "Post to" to see how your post will look on each network.',
        ),
      );
    }

    // Blocked ones first so problems are impossible to miss.
    final sorted = [...previews]..sort((a, b) {
        final ae = a.issues.hasErrors ? 0 : 1;
        final be = b.issues.hasErrors ? 0 : 1;
        return ae.compareTo(be);
      });

    return Scrollbar(
      controller: controller,
      child: ListView.separated(
        controller: controller,
        padding: padding,
        itemCount: sorted.length + (showHeader ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: Space.md),
        itemBuilder: (context, i) {
          if (showHeader && i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: Space.xs),
              child: Row(children: [
                Text('Preview', style: context.text.titleLarge),
                const SizedBox(width: Space.sm),
                Text('${previews.length} ${previews.length == 1 ? 'network' : 'networks'}', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
                const Spacer(),
                if (readiness.blocked > 0)
                  Text('${readiness.blocked} need attention', style: context.text.labelMedium?.copyWith(color: nf.danger)),
              ]),
            );
          }
          final p = sorted[i - (showHeader ? 1 : 0)];
          final card = PreviewCard(
            key: ValueKey(p.account.id),
            preview: p,
            onCustomize: () => showCustomizeSheet(context, p),
          );
          // Settings > Appearance > Compact previews.
          return compact ? ScaledDown(key: ValueKey('compact-${p.account.id}'), scale: kCompactPreviewScale, child: card) : card;
        },
      ),
    );
  }
}
