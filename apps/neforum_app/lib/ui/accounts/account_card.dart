import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import '../router.dart';
import 'guide_sheet.dart';

/// One connected account with its status, quotas and controls.
class AccountCard extends ConsumerWidget {
  const AccountCard({super.key, required this.account});
  final ConnectedAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final a = account;
    final d = ref.watch(registryProvider).descriptor(a.platformId);
    final settings = ref.watch(settingsProvider);
    final quotas = a.tier == PlatformTier.handoff ? null : ref.watch(quotaStatusProvider(a.id)).value;
    final isDefault = settings.defaultTargetIds.isEmpty || settings.defaultTargetIds.contains(a.id);

    return NfCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.sm, Space.md),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AccountAvatar(a, size: 46, dimmed: !a.enabled),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleMedium),
                if (a.handle != null)
                  Text(a.handle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
                const SizedBox(height: Space.xs + 2),
                // The badges move to a second line when a long platform name
                // or a large text size leaves no room beside it.
                Wrap(spacing: Space.sm, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(d?.name ?? a.platformId, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelMedium?.copyWith(color: nf.textMuted)),
                  TierBadge(a.tier),
                  if (!a.enabled) const StatusPill('Off', dense: true),
                ]),
              ]),
            ),
            _Menu(account: a),
          ]),
        ),
        if (a.lastError != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: Space.lg),
            padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.xs, Space.sm),
            decoration: BoxDecoration(color: nf.dangerSoft, borderRadius: Radii.rSm),
            child: Row(children: [
              Icon(Icons.link_off_rounded, size: 18, color: nf.danger),
              const SizedBox(width: Space.sm),
              Expanded(child: Text('Needs reconnecting: ${a.lastError}', maxLines: 3, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.text))),
              TextButton(
                onPressed: () => context.go('${AppSection.accounts.path}/add?platform=${a.platformId}'),
                child: const Text('Reconnect'),
              ),
            ]),
          ),
        if (quotas != null && quotas.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 0),
            child: Column(children: [
              for (final q in quotas.take(2)) Padding(padding: const EdgeInsets.only(bottom: Space.sm), child: QuotaMeter(q, dense: true)),
            ]),
          ),
        const SizedBox(height: Space.xs),
        Divider(height: 1, color: nf.border),
        _Toggle(
          // Art sites only receive artwork, so they join artwork posts only.
          label: (d?.isArtPlatform ?? false) ? 'Include in new artwork posts' : 'Include in new posts',
          value: a.enabled && isDefault,
          onChanged: a.enabled
              ? (v) async {
                  final all = ref.read(accountListProvider).where((x) => x.enabled).map((x) => x.id).toList();
                  final current = settings.defaultTargetIds.isEmpty ? all : settings.defaultTargetIds;
                  final next = v ? {...current, a.id}.toList() : current.where((id) => id != a.id).toList();
                  await ref.read(settingsProvider.notifier).update((s) => s.copyWith(defaultTargetIds: next.length == all.length ? const [] : next));
                }
              : null,
        ),
        _Toggle(
          label: 'Enabled',
          value: a.enabled,
          onChanged: (v) async {
            await ref.read(servicesProvider).accounts.upsert(a.copyWith(enabled: v));
            if (!v && ref.read(composerProvider).selected.contains(a.id)) ref.read(composerProvider.notifier).toggleAccount(a.id);
          },
        ),
        const SizedBox(height: Space.xs),
      ]),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xxs),
          child: Row(children: [
            Expanded(child: Text(label, style: context.text.bodyMedium?.copyWith(color: onChanged == null ? context.nf.textFaint : null))),
            Transform.scale(scale: 0.82, child: Switch(value: value, onChanged: onChanged)),
          ]),
        ),
      );
}

class _Menu extends ConsumerWidget {
  const _Menu({required this.account});
  final ConnectedAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: Icon(Icons.more_horiz_rounded, color: nf.textMuted),
      position: PopupMenuPosition.under,
      onSelected: (v) async {
        switch (v) {
          case 'another':
            context.go('${AppSection.accounts.path}/add?platform=${account.platformId}');
          case 'guide':
            await showGuideSheet(context, account.platformId);
          case 'copy':
            await Clipboard.setData(ClipboardData(text: account.profileUrl!));
            if (context.mounted) showToast(context, 'Profile link copied', icon: Icons.check_rounded);
          case 'disconnect':
            await disconnectAccount(context, ref, account);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
            value: 'another',
            child: ListTile(leading: Icon(Icons.person_add_alt_outlined), title: Text('Add another account'), dense: true, contentPadding: EdgeInsets.zero)),
        const PopupMenuItem(value: 'guide', child: ListTile(leading: Icon(Icons.menu_book_outlined), title: Text('Setup guide'), dense: true, contentPadding: EdgeInsets.zero)),
        if (account.profileUrl != null)
          const PopupMenuItem(value: 'copy', child: ListTile(leading: Icon(Icons.link_rounded), title: Text('Copy profile link'), dense: true, contentPadding: EdgeInsets.zero)),
        PopupMenuItem(
          value: 'disconnect',
          child: ListTile(
            leading: Icon(Icons.logout_rounded, color: nf.danger),
            title: Text('Disconnect', style: TextStyle(color: nf.danger)),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

/// Revokes (best effort), forgets secrets and removes the account.
Future<void> disconnectAccount(BuildContext context, WidgetRef ref, ConnectedAccount a) async {
  final s = ref.read(servicesProvider);
  final name = s.registry.descriptor(a.platformId)?.name ?? a.platformId;
  final ok = await confirmDialog(
    context,
    title: 'Disconnect $name?',
    message: 'NEFORUM forgets ${a.handle ?? a.displayName} and its keys on this device. Posts already published stay online. You can connect it again any time.',
    confirmLabel: 'Disconnect',
    destructive: true,
  );
  if (!ok) return;
  // Take back scheduled posts the platform holds for this account while its
  // keys still work; afterwards nothing could remove them.
  var stillHeld = 0;
  for (final p in await s.posts.all()) {
    if (!p.targets.any((t) => t.accountId == a.id && t.isHeldByPlatform)) continue;
    final outcome = await s.publisher().releaseSchedules(p.id, onlyAccountIds: {a.id});
    stillHeld += outcome.failed.length;
  }
  try {
    final secrets = await s.secrets.read(a.id) ?? const <String, String>{};
    await s.registry.byId(a.platformId)?.disconnect(a, secrets, s.connectContext());
  } on Object {
    // Revocation is best effort.
  }
  await s.secrets.delete(a.id);
  await s.accounts.delete(a.id);
  final settings = ref.read(settingsProvider);
  if (settings.defaultTargetIds.contains(a.id)) {
    await ref.read(settingsProvider.notifier).update((x) => x.copyWith(defaultTargetIds: x.defaultTargetIds.where((id) => id != a.id).toList()));
  }
  if (ref.read(composerProvider).selected.contains(a.id)) ref.read(composerProvider.notifier).toggleAccount(a.id);
  if (!context.mounted) return;
  if (stillHeld > 0) {
    showToast(context, '$name disconnected. $stillHeld scheduled ${stillHeld == 1 ? 'post is' : 'posts are'} still held there; delete ${stillHeld == 1 ? 'it' : 'them'} on $name.', icon: Icons.warning_amber_rounded);
  } else {
    showToast(context, '$name disconnected', icon: Icons.check_rounded);
  }
}
