import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'settings.dart';

/// Whether [account] is on an art portfolio or gallery site
/// (PlatformCategory.art). Those sites only receive artwork posts.
bool isArtAccount(AdapterRegistry registry, ConnectedAccount account) => registry.descriptor(account.platformId)?.isArtPlatform ?? false;

/// The accounts a new post goes to.
///
/// An ordinary post goes to the accounts marked "Include in new posts" (every
/// enabled account when none are marked), never to an art site. An artwork
/// post ([artwork]) goes to the enabled art sites marked "Include in new
/// artwork posts" (every enabled art site when none are marked, as with a
/// list saved before the first art site was added).
Set<String> defaultPostTargets(List<ConnectedAccount> accounts, AdapterRegistry registry, AppSettings settings, {bool artwork = false}) {
  final pool = [
    for (final a in accounts)
      if (isArtAccount(registry, a) == artwork) a,
  ];
  final chosen = settings.defaultTargetIds;
  if (artwork) {
    final marked = {
      for (final a in pool)
        if (a.enabled && chosen.contains(a.id)) a.id,
    };
    return marked.isNotEmpty ? marked : pool.where((a) => a.enabled).map((a) => a.id).toSet();
  }
  final ids = pool.map((a) => a.id).toSet();
  final defaults = chosen.where(ids.contains).toSet();
  return defaults.isNotEmpty ? defaults : pool.where((a) => a.enabled).map((a) => a.id).toSet();
}

/// Whether new posts of [account]'s kind (artwork for an art site) go to
/// it, exactly as [defaultPostTargets] decides. Its account card shows this
/// as "Include in new posts".
bool includedInNewPosts(List<ConnectedAccount> accounts, AdapterRegistry registry, AppSettings settings, ConnectedAccount account) =>
    defaultPostTargets(accounts, registry, settings, artwork: isArtAccount(registry, account)).contains(account.id);

/// [AppSettings.defaultTargetIds] with [account] switched to [included].
///
/// When no account of [account]'s kind is marked, every enabled one is
/// included, so they are all marked first: switching one off leaves the
/// others on. An empty list, kept when every enabled account is included,
/// means all of them.
List<String> defaultTargetIdsWith(List<ConnectedAccount> accounts, AdapterRegistry registry, AppSettings settings, ConnectedAccount account,
    {required bool included}) {
  final enabled = [for (final a in accounts) if (a.enabled) a.id];
  final current = settings.defaultTargetIds.isEmpty
      ? enabled
      : [...settings.defaultTargetIds, ...defaultPostTargets(accounts, registry, settings, artwork: isArtAccount(registry, account))];
  final next = {...current, account.id};
  if (!included) next.remove(account.id);
  return enabled.every(next.contains) ? const [] : next.toList();
}

/// The details a new artwork post starts with: the rating and the AI
/// training choice from Settings > Artwork.
ArtworkDetails newArtworkDetails(AppSettings settings) =>
    ArtworkDetails(maturity: settings.artworkMaturity, disallowAiTraining: settings.artworkDisallowAiTraining);
