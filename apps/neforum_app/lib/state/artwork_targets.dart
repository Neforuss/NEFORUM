import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'settings.dart';

/// Whether [account] is on an art portfolio or gallery site
/// (PlatformCategory.art). Those sites only receive artwork posts.
bool isArtAccount(AdapterRegistry registry, ConnectedAccount account) => registry.descriptor(account.platformId)?.isArtPlatform ?? false;

/// The accounts a new post goes to.
///
/// An ordinary post goes to the accounts marked "Include in new posts" (every
/// enabled account when none are marked), never to an art site. An artwork
/// post ([artwork]) goes to the enabled art sites that are included in new
/// posts.
Set<String> defaultPostTargets(List<ConnectedAccount> accounts, AdapterRegistry registry, AppSettings settings, {bool artwork = false}) {
  final pool = [
    for (final a in accounts)
      if (isArtAccount(registry, a) == artwork) a,
  ];
  final chosen = settings.defaultTargetIds;
  if (artwork) {
    return {
      for (final a in pool)
        if (a.enabled && (chosen.isEmpty || chosen.contains(a.id))) a.id,
    };
  }
  final ids = pool.map((a) => a.id).toSet();
  final defaults = chosen.where(ids.contains).toSet();
  return defaults.isNotEmpty ? defaults : pool.where((a) => a.enabled).map((a) => a.id).toSet();
}

/// The details a new artwork post starts with: the rating and the AI
/// training choice from Settings > Artwork.
ArtworkDetails newArtworkDetails(AppSettings settings) =>
    ArtworkDetails(maturity: settings.artworkMaturity, disallowAiTraining: settings.artworkDisallowAiTraining);
