import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/neforum_logo.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import '../root.dart';
import '../router.dart';
import 'account_card.dart';
import 'tier_explainer.dart';

/// Connected accounts, grouped by how they publish.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountListProvider);
    final loading = ref.watch(accountsProvider).isLoading && accounts.isEmpty;
    final auto = accounts.where((a) => a.tier != PlatformTier.handoff).length;
    void add() => context.go('${AppSection.accounts.path}/add');

    return PageBody(children: [
      PageHeader(
        eyebrow: 'Accounts',
        title: 'Your networks',
        subtitle: accounts.isEmpty ? 'Connect the places you post to.' : '${accounts.length} connected · $auto post automatically',
        actions: [PrimaryAction(label: 'Add account', icon: Icons.add_rounded, onPressed: add, compact: context.isCompact)],
      ),
      const SizedBox(height: Space.x3),
      if (loading)
        const Padding(padding: EdgeInsets.all(Space.x5), child: Center(child: CircularProgressIndicator()))
      else if (accounts.isEmpty)
        const _Welcome()
      else ...[
        for (final tier in const [PlatformTier.openApi, PlatformTier.byokApi, PlatformTier.webSession, PlatformTier.handoff])
          if (accounts.any((a) => a.tier == tier)) ...[
            SectionHeader(
              switch (tier) {
                PlatformTier.openApi => 'Posts automatically',
                PlatformTier.byokApi => 'Uses your own API keys',
                PlatformTier.handoff => 'Hand-off (you tap Post)',
                PlatformTier.webSession => 'Web session (experimental)',
              },
              subtitle: switch (tier) {
                PlatformTier.openApi => 'Open networks: no keys, no fees, no review.',
                PlatformTier.byokApi => 'Official APIs through a developer app you created. Quotas shown below each account.',
                PlatformTier.handoff => 'NEFORUM prepares the post and opens the app; works with any personal account.',
                PlatformTier.webSession => 'Drives the website you are signed into.',
              },
            ),
            const SizedBox(height: Space.md),
            ResponsiveGrid(
              minItemWidth: 320,
              maxColumns: 3,
              children: [for (final a in accounts.where((a) => a.tier == tier)) AccountCard(account: a)],
            ),
            const SizedBox(height: Space.x3),
          ],
        const _HowItWorks(),
      ],
    ]);
  }
}

class _Welcome extends ConsumerWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final demo = ref.watch(isDemoProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      NfCard(
        padding: EdgeInsets.all(context.isCompact ? Space.xl : Space.x4),
        child: Column(children: [
          const NeforumMark(size: 64),
          const SizedBox(height: Space.xl),
          Text('Connect your first network', textAlign: TextAlign.center, style: context.text.headlineMedium),
          const SizedBox(height: Space.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Text(
              'NEFORUM posts three ways, so every platform works, even the ones that only allow business accounts or charge for their API. No NEFORUM account, no server, nothing leaves your device except your posts.',
              textAlign: TextAlign.center,
              style: context.text.bodyLarge?.copyWith(color: nf.textMuted),
            ),
          ),
          const SizedBox(height: Space.xxl),
          Wrap(alignment: WrapAlignment.center, spacing: Space.md, runSpacing: Space.md, children: [
            PrimaryAction(label: 'Add an account', icon: Icons.add_rounded, onPressed: () => context.go('${AppSection.accounts.path}/add')),
            if (!demo)
              OutlinedButton.icon(
                onPressed: () => NeforumRoot.of(context).setDemo(true),
                icon: const Icon(Icons.science_outlined, size: 18),
                label: const Text('Explore the demo workspace'),
              ),
          ]),
        ]),
      ),
      const SizedBox(height: Space.xl),
      const TierExplainer(),
    ]);
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: const [
      SectionHeader('How NEFORUM reaches each network', subtitle: 'Every account uses one of these. You can connect the same platform more than one way.'),
      SizedBox(height: Space.md),
      TierExplainer(),
    ]);
  }
}
