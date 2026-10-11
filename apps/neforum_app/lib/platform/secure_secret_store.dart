import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:neforum_core/neforum_core.dart';

/// [SecretStore] backed by the OS keychain / keystore:
/// Keychain on iOS and macOS, Android Keystore-wrapped storage on Android,
/// DPAPI-encrypted storage on Windows.
///
/// Each account's secrets are one JSON value under `neforum.acct.<id>`.
class SecureSecretStore extends SecretStore {
  SecureSecretStore({FlutterSecureStorage? storage})
      : _s = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(migrateWithBackup: true),
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
              // The legacy keychain works without a provisioning profile, which
              // matters for self-built, unsigned FOSS builds.
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  final FlutterSecureStorage _s;
  final Map<String, Map<String, String>> _cache = {};

  static String _key(String id) => 'neforum.acct.$id';

  @override
  Future<Map<String, String>?> read(String accountId) async {
    final cached = _cache[accountId];
    if (cached != null) return Map.unmodifiable(cached);
    final raw = await _s.read(key: _key(accountId));
    if (raw == null) return null;
    try {
      final m = Map<String, String>.from(jsonDecode(raw) as Map);
      _cache[accountId] = m;
      return Map.unmodifiable(m);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String accountId, Map<String, String> secrets) async {
    _cache[accountId] = Map.of(secrets);
    await _s.write(key: _key(accountId), value: jsonEncode(secrets));
  }

  @override
  Future<void> delete(String accountId) async {
    _cache.remove(accountId);
    await _s.delete(key: _key(accountId));
  }
}
