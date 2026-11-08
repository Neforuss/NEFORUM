import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/account_connection.dart';
import '../../state/providers.dart';
import '../../state/sign_in_view.dart';
import '../../theme/tokens.dart';
import '../router.dart';

/// Above every section while a sign-in is at 14 days or fewer, ended or
/// refused. Closing it holds until the next threshold of any sign-in in it.
class SignInBanner extends ConsumerWidget {
  const SignInBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(signInMinuteProvider);
    final statuses = ref.watch(signInStatusesProvider).value;
    final ledger = ref.watch(signInLedgerProvider).value;
    if (statuses == null || ledger == null) return const SizedBox.shrink();
    final accounts = ref.watch(accountListProvider);
    final registry = ref.watch(registryProvider);
    final now = ref.watch(signInClockProvider)();
    final items = signInBannerItems(signInStatusesToWatch(accounts, statuses), now);
    final open = openSignInBannerItems(items, ledger.bannerClosed);
    if (open.isEmpty) return const SizedBox.shrink();

    String networkOf(SignInBannerItem i) {
      final a = accounts.where((x) => x.id == i.status.accountId).firstOrNull;
      return a == null ? 'A network' : (registry.descriptor(a.platformId)?.name ?? a.displayName);
    }

    final nf = context.nf;
    final urgent = items.any((i) => i.ended || i.refused);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey('sign-in-banner'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.xs, Space.xs),
        decoration: BoxDecoration(color: urgent ? nf.dangerSoft : nf.warningSoft, border: Border(bottom: BorderSide(color: nf.border))),
        child: Row(children: [
          Icon(urgent ? Icons.link_off_rounded : Icons.schedule_rounded, size: 16, color: urgent ? nf.danger : nf.warning),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              signInBannerSummary(items, networkOf),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall?.copyWith(color: nf.text),
            ),
          ),
          TextButton(
            onPressed: () => context.go(kSignInsPath),
            // The accent lacks contrast on the dark theme's amber tint.
            style: TextButton.styleFrom(foregroundColor: nf.text),
            child: const Text('Review'),
          ),
          IconButton(
            tooltip: 'Close until the next warning',
            icon: Icon(Icons.close_rounded, size: 18, color: nf.textMuted),
            onPressed: () => ref.read(servicesProvider).signInWarningStore.update((l) => l.copyWith(bannerClosed: {
                  ...l.bannerClosed,
                  for (final i in items) i.status.accountId: i.signature,
                })),
          ),
        ]),
      ),
    );
  }
}
