import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';

/// The gallery's filters, in the order of their chips.
enum PlatformFilter { notAdded, added, personal, noKeys, automatic, art, all }

extension PlatformFilterText on PlatformFilter {
  String get label => switch (this) {
        PlatformFilter.notAdded => 'Not added yet',
        PlatformFilter.added => 'Added',
        PlatformFilter.personal => 'Personal accounts',
        PlatformFilter.noKeys => 'No developer keys',
        PlatformFilter.automatic => 'Posts automatically',
        PlatformFilter.art => 'Art and portfolios',
        PlatformFilter.all => 'All',
      };

  /// One line under the chips about what the filter shows.
  String get description => switch (this) {
        PlatformFilter.notAdded => 'Platforms you have not added yet.',
        PlatformFilter.added => 'Platforms you already post to. Pick one to add another account there.',
        PlatformFilter.personal => 'Posts automatically with a personal account; no business or creator account needed.',
        PlatformFilter.noKeys => 'Posts automatically without a developer app or API keys.',
        PlatformFilter.automatic => 'Posts automatically, through an open API or with your own API keys.',
        PlatformFilter.art => 'Portfolio and gallery sites. They only receive artwork posts.',
        PlatformFilter.all => 'Every platform NEFORUM supports.',
      };

  /// Whether [d] is shown; [added] counts the accounts per platform id.
  bool matches(PlatformDescriptor d, Map<String, int> added) => switch (this) {
        PlatformFilter.notAdded => !added.containsKey(d.id),
        PlatformFilter.added => added.containsKey(d.id),
        PlatformFilter.personal => d.personalAccountOk && d.tiers.any((t) => t.isAutomatic),
        PlatformFilter.noKeys => d.supportsTier(PlatformTier.openApi),
        PlatformFilter.automatic => d.supportsTier(PlatformTier.openApi) || d.supportsTier(PlatformTier.byokApi),
        PlatformFilter.art => d.isArtPlatform,
        PlatformFilter.all => true,
      };
}

/// The section of art sites, found by their category (PlatformCategory.art).
const _artGroup = 'Art and portfolios';

/// Sections of the gallery, in order. [_artGroup] lists no ids: every art
/// site goes there.
const _groups = <String, List<String>>{
  'Open networks': ['mastodon', 'bluesky', 'misskey', 'nostr', 'lemmy', 'matrix'],
  'Big platforms': ['x', 'threads', 'facebook', 'linkedin', 'reddit', 'tumblr'],
  'Photo & video': ['instagram', 'tiktok', 'youtube_posts', 'pinterest', 'snapchat'],
  'Video sites': ['youtube', 'rumble', 'odysee', 'bitchute'],
  _artGroup: [],
  'Messaging': ['telegram', 'discord', 'whatsapp'],
  'Blogs & newsletters': ['wordpress', 'ghost', 'writefreely', 'micropub', 'devto', 'hashnode', 'substack'],
  'Business': ['google_business'],
};

/// Step 1: searchable, filterable gallery of platforms.
class PlatformPicker extends ConsumerStatefulWidget {
  const PlatformPicker({super.key, required this.onPick});
  final ValueChanged<String> onPick;

  @override
  ConsumerState<PlatformPicker> createState() => _PlatformPickerState();
}

class _PlatformPickerState extends ConsumerState<PlatformPicker> {
  final _search = TextEditingController();

  /// The filter the user chose; until then, "Not added yet" once an account
  /// exists, else "All".
  PlatformFilter? _chosen;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matchesSearch(PlatformDescriptor d) {
    final q = _search.text.trim().toLowerCase();
    return q.isEmpty || d.name.toLowerCase().contains(q) || d.id.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final registry = ref.watch(registryProvider);
    final added = <String, int>{};
    for (final a in ref.watch(accountListProvider)) {
      added[a.platformId] = (added[a.platformId] ?? 0) + 1;
    }
    final filter = _chosen ?? (added.isEmpty ? PlatformFilter.all : PlatformFilter.notAdded);
    final all = registry.descriptors;
    final art = [for (final d in all) if (d.isArtPlatform) d];
    final listed = {for (final g in _groups.values) ...g, for (final d in art) d.id};
    final groups = <String, List<PlatformDescriptor>>{
      for (final e in _groups.entries) e.key: e.key == _artGroup ? art : [for (final id in e.value) ?registry.descriptor(id)],
      'Other': [for (final d in all) if (!listed.contains(d.id)) d],
    };

    final sections = <Widget>[];
    for (final e in groups.entries) {
      final items = e.value.where((d) => _matchesSearch(d) && filter.matches(d, added)).toList();
      if (items.isEmpty) continue;
      sections
        ..add(Padding(
          padding: const EdgeInsets.only(top: Space.xl, bottom: Space.md),
          child: Text(e.key.toUpperCase(), style: context.text.labelSmall?.copyWith(color: nf.textFaint, letterSpacing: 1.4)),
        ))
        ..add(ResponsiveGrid(
          minItemWidth: 230,
          spacing: Space.md,
          children: [for (final d in items) _PlatformTileCard(d: d, accounts: added[d.id] ?? 0, onTap: () => widget.onPick(d.id))],
        ));
    }

    final searching = _search.text.trim().isNotEmpty;
    final Widget empty = switch (filter) {
      PlatformFilter.notAdded when !searching => const EmptyState(
          compact: true,
          icon: Icons.done_all_rounded,
          title: 'Every platform is added',
          body: 'Pick Added to add another account on one of them.',
        ),
      PlatformFilter.added when added.isEmpty => const EmptyState(
          compact: true,
          icon: Icons.add_link_rounded,
          title: 'No platforms added yet',
          body: 'Pick one under Not added yet or All.',
        ),
      _ => const EmptyState(compact: true, icon: Icons.search_off_rounded, title: 'No platform matches', body: 'Try another name or clear the filters.'),
    };

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _search,
        autofocus: !context.isCompact,
        onChanged: (_) => setState(() {}),
        style: context.text.bodyLarge,
        decoration: InputDecoration(
          hintText: 'Search ${all.length} platforms',
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(icon: const Icon(Icons.close_rounded), tooltip: 'Clear', onPressed: () => setState(_search.clear)),
        ),
      ),
      const SizedBox(height: Space.md),
      Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
        for (final f in PlatformFilter.values)
          ChoiceChip(
            label: Text(f.label),
            selected: filter == f,
            onSelected: (_) => setState(() => _chosen = f),
          ),
      ]),
      const SizedBox(height: Space.sm),
      Text(filter.description, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
      if (sections.isEmpty) empty else ...sections,
    ]);
  }
}

class _PlatformTileCard extends StatelessWidget {
  const _PlatformTileCard({required this.d, required this.accounts, required this.onTap});
  final PlatformDescriptor d;

  /// Accounts already added on this platform.
  final int accounts;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final tiers = [for (final t in const [PlatformTier.openApi, PlatformTier.byokApi, PlatformTier.handoff, PlatformTier.webSession]) if (d.supportsTier(t)) t];
    return NfCard(
      onTap: onTap,
      padding: const EdgeInsets.all(Space.md + 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PlatformTile(d.id, size: 44),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(d.name, overflow: TextOverflow.ellipsis, style: context.text.titleSmall)),
              if (accounts > 0) ...[
                const SizedBox(width: Space.xs),
                Tooltip(
                  message: 'Added: pick it to add another account',
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.check_circle_rounded, size: 15, color: nf.success),
                    const SizedBox(width: Space.xxs),
                    Text(accounts == 1 ? '1 account' : '$accounts accounts', style: context.text.labelSmall?.copyWith(color: nf.textFaint)),
                  ]),
                ),
              ],
            ]),
            const SizedBox(height: Space.xs),
            Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [for (final t in tiers) TierBadge(t)]),
            const SizedBox(height: Space.xs + 2),
            Text(d.accountRequirements, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.textFaint, fontSize: 11.5)),
          ]),
        ),
      ]),
    );
  }
}
