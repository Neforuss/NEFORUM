import '../model/account.dart';
import '../model/platform_descriptor.dart';

// 1.4.3: the user's publishing order.
//
// A run posts to the automatic accounts first and to the hand-offs after them,
// so a sheet waiting for the person never holds up a network that needs nobody.
// Within each of those two groups it follows the order the user set: a list of
// account ids (Settings > Posting > Publishing order, and the composer). An
// account missing from that list, such as one connected since, comes after the
// listed ones of its group, the oldest first. That is also where a new account
// shows in the list the user reorders.

/// Whether [account] waits for the automatic accounts of a run: it posts by
/// hand-off. An account that cannot be read does not wait: its target reports
/// what is wrong with it when its turn comes.
bool waitsForAutomaticAccounts(ConnectedAccount? account) => account?.tier == PlatformTier.handoff;

/// [items] in the order a publish run takes them: automatic accounts first and
/// hand-offs after them, each group in [order] (account ids), then the accounts
/// [order] leaves out, the oldest first, then the accounts [accountOf] does not
/// know. With a null [order] each group keeps the order of [items].
///
/// Stable: items that compare equal keep their order. An id listed twice in
/// [order] counts where it is listed first.
List<T> inPublishingOrder<T>(
  Iterable<T> items, {
  required String Function(T item) accountIdOf,
  required ConnectedAccount? Function(String accountId) accountOf,
  List<String>? order,
}) {
  final rank = <String, int>{};
  if (order != null) {
    for (var i = 0; i < order.length; i++) {
      rank.putIfAbsent(order[i], () => i);
    }
  }
  final entries = [
    for (final (i, item) in items.indexed) _Entry(item, i, accountOf(accountIdOf(item)), rank[accountIdOf(item)]),
  ];
  int compare(_Entry<T> a, _Entry<T> b) {
    final group = (waitsForAutomaticAccounts(a.account) ? 1 : 0).compareTo(waitsForAutomaticAccounts(b.account) ? 1 : 0);
    if (group != 0) return group;
    if (order != null) {
      final ra = a.rank, rb = b.rank;
      if (ra != null || rb != null) {
        if (ra == null) return 1;
        if (rb == null) return -1;
        if (ra != rb) return ra.compareTo(rb);
      } else {
        final ca = a.account?.createdAt, cb = b.account?.createdAt;
        if (ca == null && cb != null) return 1;
        if (cb == null && ca != null) return -1;
        if (ca != null && cb != null && ca != cb) return ca.compareTo(cb);
      }
    }
    return a.index.compareTo(b.index);
  }

  entries.sort(compare);
  return [for (final e in entries) e.item];
}

class _Entry<T> {
  _Entry(this.item, this.index, this.account, this.rank);
  final T item;
  final int index;
  final ConnectedAccount? account;
  final int? rank;
}
