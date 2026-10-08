import 'dart:async';

/// Holds per-account secrets (tokens, app passwords, private keys), keyed by
/// account id. The Flutter app backs this with the OS keychain/keystore; the
/// CLI with a permission-restricted JSON file.
abstract class SecretStore {
  Future<Map<String, String>?> read(String accountId);
  Future<void> write(String accountId, Map<String, String> secrets);
  Future<void> delete(String accountId);

  /// Convenience: merge [patch] into the existing secrets.
  Future<Map<String, String>> update(String accountId, Map<String, String> patch) async {
    final merged = {...?await read(accountId), ...patch};
    await write(accountId, merged);
    return merged;
  }
}

class InMemorySecretStore extends SecretStore {
  final Map<String, Map<String, String>> _data = {};

  @override
  Future<Map<String, String>?> read(String accountId) async =>
      _data[accountId] == null ? null : Map.unmodifiable(_data[accountId]!);

  @override
  Future<void> write(String accountId, Map<String, String> secrets) async =>
      _data[accountId] = Map.of(secrets);

  @override
  Future<void> delete(String accountId) async => _data.remove(accountId);
}
