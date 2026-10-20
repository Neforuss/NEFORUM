import '../model/account.dart';

/// Renews an account's keys: the adapter's `refreshSecrets` for [secrets].
typedef SecretsRefresh = Future<Map<String, String>?> Function(Map<String, String> secrets);

/// Lets several devices share the sign-in of an account whose network
/// replaces the refresh token on every renewal (X, Tumblr): only one device
/// renews at a time, and every device then uses the renewed keys instead of
/// the stale ones (which the network would reject, signing that device out).
abstract class SecretsCoordinator {
  /// Runs [refresh] for [account] in step with the other devices. Returns
  /// the keys to use when they differ from [current] (renewed here or by
  /// another device), else `null`. Throws what [refresh] throws.
  Future<Map<String, String>?> renew(ConnectedAccount account, Map<String, String> current, SecretsRefresh refresh);
}
