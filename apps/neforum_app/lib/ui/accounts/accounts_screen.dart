import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/neforum_logo.dart';
import '../../state/account_connection.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import '../root.dart';
import '../router.dart';
import 'account_card.dart';
import 'connection_section.dart';
import 'tier_explainer.dart';

/// The order the page groups accounts in, by how they publish.
const List<PlatformTier> _tierOrder = [PlatformTier.openApi, PlatformTier.byokApi, PlatformTier.webSession, PlatformTier.handoff];

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
        actions: [
          if (accounts.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () => context.go(kSignInsPath),
              icon: const Icon(Icons.event_rounded, size: 18),
              label: const Text('Sign-ins'),
            ),
          if (accounts.isNotEmpty) _CopyAllSetupsButton(accounts: [for (final tier in _tierOrder) ...accounts.where((a) => a.tier == tier)]),
          PrimaryAction(label: 'Add account', icon: Icons.add_rounded, onPressed: add, compact: context.isCompact),
        ],
      ),
      const SizedBox(height: Space.x3),
      if (loading)
        const Padding(padding: EdgeInsets.all(Space.x5), child: Center(child: CircularProgressIndicator()))
      else if (accounts.isEmpty)
        const _Welcome()
      else ...[
        for (final tier in _tierOrder)
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

/// 1.3.5: "Copy all setups": every account's setup as text, in the page's
/// order, to paste next to the same list from another device. No key values
/// (see connectionSetupText). Disabled while a copy runs, so a second tap
/// neither asks the keychain twice nor shows two toasts. An account whose
/// keys the keychain will not read still gets its block and the toast says
/// how many; a keychain that does not answer at all (a prompt left open)
/// times out with its own message; any other failure says nothing was copied.
class _CopyAllSetupsButton extends ConsumerStatefulWidget {
  const _CopyAllSetupsButton({required this.accounts});

  /// In the page's order.
  final List<ConnectedAccount> accounts;

  /// How long one keychain read may take before the copy gives up on it.
  static const Duration readTimeout = Duration(seconds: 15);

  @override
  ConsumerState<_CopyAllSetupsButton> createState() => _CopyAllSetupsButtonState();
}

class _CopyAllSetupsButtonState extends ConsumerState<_CopyAllSetupsButton> {
  bool _busy = false;

  Future<void> _copy() async {
    if (_busy) return;
    setState(() => _busy = true);
    final count = widget.accounts.length;
    try {
      final result = await allConnectionSetupsText(
        widget.accounts,
        secrets: ref.read(connectionSecretsProvider),
        registry: ref.read(registryProvider),
        travel: currentKeysTravel(ref),
        deviceLabel: ref.read(connectionDeviceLabelProvider),
        readTimeout: _CopyAllSetupsButton.readTimeout,
        statuses: await ref.read(servicesProvider).signInStatusStore.all(),
      );
      await Clipboard.setData(ClipboardData(text: result.text));
      if (!mounted) return;
      final copied = '${count == 1 ? 'Setup' : 'Setups of $count accounts'} copied, without keys or passwords';
      final n = result.unreadable;
      final accountsWord = n == 1 ? 'account' : 'accounts';
      if (result.timedOut) {
        showToast(context, '$copied. The keychain did not answer, so the keys of $n $accountsWord were not read: unlock it and copy again.',
            icon: Icons.warning_amber_rounded);
      } else if (n > 0) {
        showToast(context, '$copied. The keys of $n $accountsWord could not be read on this device.', icon: Icons.warning_amber_rounded);
      } else {
        showToast(context, copied, icon: Icons.check_rounded);
      }
    } on Object {
      if (mounted) showToast(context, 'Could not copy the setups. Nothing was copied.', icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: _busy ? null : _copy,
        icon: _busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.copy_all_rounded, size: 18),
        label: const Text('Copy all setups'),
      );
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
