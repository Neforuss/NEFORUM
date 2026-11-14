import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'providers.dart';

// 1.4.3: the user's publishing order (AppSettings.publishingOrder). Runs follow
// it (PublishService.publishingOrder); the composer, Settings > Posting, the
// progress sheet and Activity show it.

/// The accounts and the user's publishing order as they stand, to put things in
/// that order on screen.
class PublishingSequence {
  PublishingSequence({required List<ConnectedAccount> accounts, required this.order}) : _accounts = {for (final a in accounts) a.id: a}, _all = accounts;

  final Map<String, ConnectedAccount> _accounts;
  final List<ConnectedAccount> _all;

  /// AppSettings.publishingOrder.
  final List<String> order;

  /// Every account in publishing order: automatic ones, then hand-offs.
  List<ConnectedAccount> get accounts => inPublishingOrder(_all, accountIdOf: (a) => a.id, accountOf: (id) => _accounts[id], order: order);

  /// [targets] in the order a run takes them.
  List<PostTarget> targets(Iterable<PostTarget> targets) => inPublishingOrder(targets, accountIdOf: (t) => t.accountId, accountOf: (id) => _accounts[id], order: order);

  /// [accountIds] in the order a run takes them.
  List<String> accountIds(Iterable<String> accountIds) => inPublishingOrder(accountIds, accountIdOf: (id) => id, accountOf: (id) => _accounts[id], order: order);
}

/// The publishing order with the accounts it puts in order, live.
final publishingSequenceProvider = Provider<PublishingSequence>((ref) => PublishingSequence(
      accounts: ref.watch(accountListProvider),
      order: ref.watch(settingsProvider.select((s) => s.publishingOrder)),
    ));

/// The publishing order to save once the user moved the account at [oldIndex]
/// to [newIndex] within one group: the hand-offs when [inHandoffs], the
/// automatic accounts otherwise. [newIndex] is where it ends up
/// (SliverReorderableList.onReorderItem). [automatic] and [handoffs] are both
/// groups as shown, in order.
///
/// Every account is listed, so the order holds for the accounts it did not list
/// yet as well. Ids of [previous] that name no account here (one this device
/// does not have yet, through sync) stay, at the end.
List<String> publishingOrderAfterMove({
  required List<ConnectedAccount> automatic,
  required List<ConnectedAccount> handoffs,
  required bool inHandoffs,
  required int oldIndex,
  required int newIndex,
  List<String> previous = const [],
}) {
  final moved = [...inHandoffs ? handoffs : automatic];
  if (oldIndex >= 0 && oldIndex < moved.length) {
    final account = moved.removeAt(oldIndex);
    moved.insert(newIndex.clamp(0, moved.length), account);
  }
  final ids = [
    for (final a in inHandoffs ? automatic : moved) a.id,
    for (final a in inHandoffs ? moved : handoffs) a.id,
  ];
  final shown = ids.toSet();
  return [...ids, ...{for (final id in previous) if (!shown.contains(id)) id}];
}
