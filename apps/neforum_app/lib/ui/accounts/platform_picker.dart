import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';

enum _Filter { all, personal, noKeys, automatic }

const _groups = <String, List<String>>{
  'Open networks': ['mastodon', 'bluesky', 'misskey', 'nostr', 'lemmy', 'matrix'],
  'Big platforms': ['x', 'threads', 'facebook', 'linkedin', 'reddit', 'tumblr'],
  'Photo & video': ['instagram', 'tiktok', 'youtube', 'pinterest', 'snapchat'],
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
  _Filter _filter = _Filter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(PlatformDescriptor d) {
    final q = _search.text.trim().toLowerCase();
    if (q.isNotEmpty && !d.name.toLowerCase().contains(q) && !d.id.contains(q)) return false;
    return switch (_filter) {
      _Filter.all => true,
      _Filter.personal => d.personalAccountOk || d.supportsTier(PlatformTier.handoff),
      _Filter.noKeys => d.supportsTier(PlatformTier.openApi) || d.supportsTier(PlatformTier.handoff),
      _Filter.automatic => d.supportsTier(PlatformTier.openApi) || d.supportsTier(PlatformTier.byokApi),
    };
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final registry = ref.watch(registryProvider);
    final connected = ref.watch(accountListProvider).map((a) => a.platformId).toSet();
    final all = registry.descriptors;
    final listed = {for (final g in _groups.values) ...g};
    final groups = <String, List<PlatformDescriptor>>{
      for (final e in _groups.entries) e.key: [for (final id in e.value) ?registry.descriptor(id)],
      'Other': [for (final d in all) if (!listed.contains(d.id)) d],
    };

    final sections = <Widget>[];
    for (final e in groups.entries) {
      final items = e.value.where(_matches).toList();
      if (items.isEmpty) continue;
      sections
        ..add(Padding(
          padding: const EdgeInsets.only(top: Space.xl, bottom: Space.md),
          child: Text(e.key.toUpperCase(), style: context.text.labelSmall?.copyWith(color: nf.textFaint, letterSpacing: 1.4)),
        ))
        ..add(ResponsiveGrid(
          minItemWidth: 230,
          spacing: Space.md,
          children: [for (final d in items) _PlatformTileCard(d: d, connected: connected.contains(d.id), onTap: () => widget.onPick(d.id))],
        ));
    }

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
        for (final f in _Filter.values)
          ChoiceChip(
            label: Text(switch (f) {
              _Filter.all => 'All',
              _Filter.personal => 'Works with personal accounts',
              _Filter.noKeys => 'No developer keys needed',
              _Filter.automatic => 'Posts automatically',
            }),
            selected: _filter == f,
            onSelected: (_) => setState(() => _filter = f),
          ),
      ]),
      if (sections.isEmpty)
        const EmptyState(compact: true, icon: Icons.search_off_rounded, title: 'No platform matches', body: 'Try another name or clear the filters.')
      else
        ...sections,
    ]);
  }
}

class _PlatformTileCard extends StatelessWidget {
  const _PlatformTileCard({required this.d, required this.connected, required this.onTap});
  final PlatformDescriptor d;
  final bool connected;
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
              if (connected) ...[
                const SizedBox(width: Space.xs),
                Tooltip(message: 'Already connected', child: Icon(Icons.check_circle_rounded, size: 15, color: nf.success)),
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
