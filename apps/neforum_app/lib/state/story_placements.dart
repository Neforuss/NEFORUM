import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'settings.dart';

/// 1.4.3: Post / Story / Post + Story sticks. The choice made on a network's
/// preview in the composer is remembered for that account
/// ([AppSettings.defaultPlacements]), and a new post starts with it on every
/// account that can take a story. Posts already written keep their own.

/// The placement a new post starts with on [account]: the one remembered for
/// it, or the feed when nothing is remembered or the account cannot post a
/// story ([PlatformAdapter.supportsStories]).
PostPlacement rememberedPlacement(AppSettings settings, ConnectedAccount account, AdapterRegistry registry) {
  final adapter = registry.byId(account.platformId);
  if (adapter == null || !adapter.supportsStories(account)) return PostPlacement.feed;
  return PostPlacement.tryParse(settings.defaultPlacements[account.id]) ?? PostPlacement.feed;
}

/// [remembered] with [placement] as [accountId]'s choice. The feed is the
/// default, so it is not stored.
Map<String, String> withRememberedPlacement(Map<String, String> remembered, String accountId, PostPlacement placement) {
  final out = {...remembered}..remove(accountId);
  if (placement != PostPlacement.feed) out[accountId] = placement.name;
  return out;
}

/// Whether [o] names a placement of its own (a story, or Post + Story).
bool hasOwnPlacement(PostOverrides o) => o.extra.containsKey(kPlacementKey) || o.extra.containsKey(kStoryModeKey);

/// [o] without its placement: what the user changed for the network besides
/// Post / Story.
PostOverrides withoutPlacement(PostOverrides o) =>
    hasOwnPlacement(o) ? o.copyWith(extra: {...o.extra}..remove(kPlacementKey)..remove(kStoryModeKey)) : o;

/// Only the placement of [o], as overrides of their own (empty for the feed).
PostOverrides placementOnly(PostOverrides o) => PostOverrides(extra: extraWithPlacement(const {}, placementOfExtra(o.extra)));

/// [overrides] with the remembered placement of each of [accountIds] that has
/// none of its own yet. Accounts that cannot post a story, and accounts with
/// nothing remembered, are left as they are.
Map<String, PostOverrides> withRememberedPlacements(
  Map<String, PostOverrides> overrides,
  Iterable<String> accountIds,
  List<ConnectedAccount> accounts,
  AdapterRegistry registry,
  AppSettings settings,
) {
  if (settings.defaultPlacements.isEmpty) return overrides;
  Map<String, PostOverrides>? out;
  for (final id in accountIds) {
    final account = accounts.where((a) => a.id == id).firstOrNull;
    if (account == null) continue;
    final placement = rememberedPlacement(settings, account, registry);
    if (placement == PostPlacement.feed) continue;
    final current = overrides[id] ?? const PostOverrides();
    if (hasOwnPlacement(current)) continue;
    (out ??= {...overrides})[id] = current.copyWith(extra: extraWithPlacement(current.extra, placement));
  }
  return out ?? overrides;
}
