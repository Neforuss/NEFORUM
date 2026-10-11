import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';

/// Three cards that explain how NEFORUM reaches each kind of platform.
class TierExplainer extends ConsumerWidget {
  const TierExplainer({super.key});

  static const _examples = {
    PlatformTier.openApi: ['mastodon', 'bluesky', 'nostr', 'telegram', 'discord', 'misskey'],
    PlatformTier.byokApi: ['x', 'linkedin', 'youtube', 'threads', 'pinterest', 'tumblr'],
    PlatformTier.handoff: ['instagram', 'tiktok', 'facebook', 'snapchat', 'whatsapp', 'substack'],
  };

  static const _headlines = {
    PlatformTier.openApi: 'Posts automatically',
    PlatformTier.byokApi: 'Uses your own keys',
    PlatformTier.handoff: 'You tap Post',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final registry = ref.watch(registryProvider);
    return ResponsiveGrid(
      minItemWidth: 250,
      maxColumns: 3,
      children: [
        for (final tier in _examples.keys)
          NfCard(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TierBadge(tier, dense: false),
              const SizedBox(height: Space.md),
              Text(_headlines[tier]!, style: context.text.titleLarge),
              const SizedBox(height: Space.xs),
              Text(tierDescription(tier), style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
              const SizedBox(height: Space.md),
              Wrap(spacing: Space.xs + 2, runSpacing: Space.xs + 2, children: [
                for (final id in _examples[tier]!)
                  if (registry.byId(id) != null)
                    Tooltip(message: registry.descriptor(id)!.name, child: PlatformTile(id, size: 26)),
              ]),
            ]),
          ),
      ],
    );
  }
}
