import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../state/publishing_order.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';

/// 1.4.3: the publishing order, from the composer's "Post to" and from
/// Settings > Posting. Every account, the automatic ones and then the hand-offs,
/// each group dragged into the order posts go out in. A change is saved as it is
/// made, syncs with the other settings, and holds for every post from then on,
/// scheduled ones included. [inPost]: the accounts the post being written goes
/// to, which the list marks.
Future<void> showPublishingOrder(BuildContext context, {Set<String> inPost = const {}}) {
  final editor = PublishingOrderEditor(inPost: inPost);
  if (context.isCompact) {
    return showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: editor));
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760), child: editor),
    ),
  );
}

/// 1.4.3: phones: the publishing order under the post. The account grid's
/// header has no room to spare: its height is worked out to keep every account
/// on screen. Wider windows have a button beside the quick choices instead.
class PublishingOrderLink extends ConsumerWidget {
  const PublishingOrderLink({super.key});

  static const linkKey = ValueKey('composer-publishing-order');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(accountListProvider).isEmpty) return const SizedBox.shrink();
    final selected = ref.watch(composerProvider.select((c) => c.selected));
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: linkKey,
          onPressed: () => showPublishingOrder(context, inPost: selected),
          icon: const Icon(Icons.swap_vert_rounded, size: 18),
          label: const Text('Publishing order'),
          style: TextButton.styleFrom(foregroundColor: context.nf.textMuted, minimumSize: const Size(48, 48)),
        ),
      ),
    );
  }
}

/// What the publishing order says about itself, here and in Settings > Posting.
const String kPublishingOrderDescription = 'NEFORUM posts to your accounts one after another, in this order. Accounts that post '
    'automatically go first, then hand-offs, which wait for you. New accounts go to the end.';

/// The publishing order, edited in place. See [showPublishingOrder].
class PublishingOrderEditor extends ConsumerWidget {
  const PublishingOrderEditor({super.key, this.inPost = const {}});

  final Set<String> inPost;

  /// The list's rows, for tests: `ValueKey('publishing-order-<account id>')`.
  static ValueKey<String> rowKey(String accountId) => ValueKey('publishing-order-$accountId');

  /// The button that puts back the order the accounts were connected in.
  static const resetKey = ValueKey('publishing-order-reset');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final sequence = ref.watch(publishingSequenceProvider);
    final all = sequence.accounts;
    final automatic = [for (final a in all) if (!waitsForAutomaticAccounts(a)) a];
    final handoffs = [for (final a in all) if (waitsForAutomaticAccounts(a)) a];

    void move(bool inHandoffs, int oldIndex, int newIndex) {
      final next = publishingOrderAfterMove(
        automatic: automatic,
        handoffs: handoffs,
        inHandoffs: inHandoffs,
        oldIndex: oldIndex,
        newIndex: newIndex,
        previous: sequence.order,
      );
      ref.read(settingsProvider.notifier).update((s) => s.copyWith(publishingOrder: next));
    }

    Widget group(String title, String subtitle, List<ConnectedAccount> accounts, {required bool inHandoffs, required int first}) => SliverMainAxisGroup(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.xxl, Space.lg, Space.xxl, Space.sm),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: context.text.titleSmall),
                Text(subtitle, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
              ]),
            ),
          ),
          SliverReorderableList(
            itemCount: accounts.length,
            onReorderItem: (from, to) => move(inHandoffs, from, to),
            proxyDecorator: (child, _, _) => Material(
              type: MaterialType.transparency,
              child: DecoratedBox(
                decoration: BoxDecoration(color: nf.surfaceRaised, borderRadius: Radii.rMd, border: Border.all(color: nf.borderStrong)),
                child: child,
              ),
            ),
            itemBuilder: (context, i) => _Row(
              key: rowKey(accounts[i].id),
              account: accounts[i],
              index: i,
              position: first + i + 1,
              count: accounts.length,
              inPost: inPost.contains(accounts[i].id),
              onMove: (to) => move(inHandoffs, i, to),
            ),
          ),
        ]);

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.xxl, Space.xs),
        child: Text('Publishing order', style: context.text.headlineSmall),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
        child: Text('$kPublishingOrderDescription Drag an account by its handle to move it.', style: context.text.bodySmall),
      ),
      Flexible(
        child: all.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(Space.xxl),
                child: Text('Connect an account first.', style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
              )
            : CustomScrollView(shrinkWrap: true, slivers: [
                if (automatic.isNotEmpty) group('Automatic', 'Posted one after another as soon as you post.', automatic, inHandoffs: false, first: 0),
                if (handoffs.isNotEmpty)
                  group('Hand-offs', 'After every automatic account. You finish each one in its app.', handoffs, inHandoffs: true, first: automatic.length),
                const SliverToBoxAdapter(child: SizedBox(height: Space.lg)),
              ]),
      ),
      Divider(height: 1, color: nf.hairline),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.md, Space.xxl, Space.lg),
        child: Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: Space.sm, runSpacing: Space.sm, children: [
          TextButton(
            key: resetKey,
            onPressed: sequence.order.isEmpty ? null : () => ref.read(settingsProvider.notifier).update((s) => s.copyWith(publishingOrder: const [])),
            style: TextButton.styleFrom(foregroundColor: nf.textMuted),
            child: const Text('Order they were connected in'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ]),
      ),
    ]);
  }
}

/// One account: its place, its network and name, and the handle to drag it by.
/// Screen readers move it with Move up and Move down.
class _Row extends ConsumerWidget {
  const _Row({super.key, required this.account, required this.index, required this.position, required this.count, required this.inPost, required this.onMove});

  final ConnectedAccount account;

  /// Its index in its group.
  final int index;

  /// Its place in the whole order, from 1.
  final int position;

  /// How many accounts its group has.
  final int count;
  final bool inPost;

  /// Moves it to another index of its group, where it ends up.
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final a = account;
    final name = ref.watch(registryProvider).descriptor(a.platformId)?.name ?? a.platformId;
    final who = a.handle ?? a.displayName;
    return Semantics(
      label: '$position. $name, $who${inPost ? ', in this post' : ''}',
      customSemanticsActions: {
        if (index > 0) const CustomSemanticsAction(label: 'Move up'): () => onMove(index - 1),
        if (index < count - 1) const CustomSemanticsAction(label: 'Move down'): () => onMove(index + 1),
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xxs),
        child: Row(children: [
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Tooltip(
                message: 'Drag to move',
                child: SizedBox(width: 48, height: 48, child: Icon(Icons.drag_indicator_rounded, color: nf.textMuted)),
              ),
            ),
          ),
          SizedBox(
            width: 28,
            child: Text('$position', textAlign: TextAlign.center, style: monoStyle(context, color: nf.textFaint)),
          ),
          const SizedBox(width: Space.sm),
          if (a.avatarUrl != null && a.avatarUrl!.startsWith('http'))
            AccountAvatar(a, size: 28, dimmed: !a.enabled)
          else
            PlatformTile(a.platformId, size: 28, circle: true, dimmed: !a.enabled),
          const SizedBox(width: Space.md),
          Expanded(
            child: ExcludeSemantics(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelLarge?.copyWith(color: a.enabled ? nf.text : nf.textFaint)),
                Text(a.enabled ? who : '$who · switched off', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
              ]),
            ),
          ),
          Icon(tierIcon(a.tier), size: 14, color: nf.textFaint),
          if (inPost) ...[
            const SizedBox(width: Space.sm),
            Tooltip(message: 'In this post', child: Icon(Icons.check_circle_rounded, size: 18, color: nf.accent)),
          ],
          const SizedBox(width: Space.sm),
        ]),
      ),
    );
  }
}
