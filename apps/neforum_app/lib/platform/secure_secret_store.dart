import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:neforum_core/neforum_core.dart';

import 'env.dart';

/// The system keyring could not be used: on Linux, no Secret Service runs
/// (GNOME Keyring, KWallet) or the keyring stays locked. Its [message] says
/// what to do, in words for the user.
class SecretStoreUnavailableException implements Exception {
  const SecretStoreUnavailableException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// [SecretStore] backed by the OS keychain / keystore:
/// Keychain on iOS and macOS, Android Keystore-wrapped storage on Android,
/// DPAPI-encrypted storage on Windows, the Secret Service (libsecret: GNOME
/// Keyring, KWallet) on Linux.
///
/// Each account's secrets are one JSON value under `neforum.acct.<id>`.
///
/// On Linux a desktop may run no Secret Service at all (minimal window
/// managers, some containers). Every call then fails with a
/// [SecretStoreUnavailableException] naming the fix, and [unavailableReason]
/// holds the same words for the banner NEFORUM shows; nothing is ever stored
/// unencrypted instead.
class SecureSecretStore extends SecretStore {
  SecureSecretStore({FlutterSecureStorage? storage}) : _s = storage ?? _defaultStorage;

  static const FlutterSecureStorage _defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(migrateWithBackup: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    // The legacy keychain works without a provisioning profile, which
    // matters for self-built, unsigned FOSS builds.
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  final FlutterSecureStorage _s;
  final Map<String, Map<String, String>> _cache = {};

  /// Why the system keyring cannot be used right now (shown in a banner), or
  /// null when it works or has not failed yet.
  static final ValueNotifier<String?> unavailableReason = ValueNotifier(null);

  static String _key(String id) => 'neforum.acct.$id';

  /// The user-facing explanation for a libsecret failure ([code] from
  /// flutter_secure_storage_linux: "KeyringLocked", "Libsecret error", ...).
  @visibleForTesting
  static String linuxKeyringMessage(String code) => code == 'KeyringLocked'
      ? 'The system keyring is locked, so NEFORUM cannot read or save account keys and tokens. '
          'Unlock it (in Passwords and Keys, or KWallet), then try again.'
      : 'NEFORUM could not reach a keyring (Secret Service) to keep account keys and tokens. '
          'Install and start GNOME Keyring or KWallet with its Secret Service, then restart NEFORUM. '
          'Until then accounts cannot be connected or used; nothing is stored unencrypted instead.';

  /// Checks on Linux that the Secret Service answers, so a missing keyring
  /// shows up at start instead of at the first post. True elsewhere.
  static Future<bool> verifyAvailable({FlutterSecureStorage? storage}) async {
    if (!Env.isLinux) return true;
    try {
      await _guard(() => (storage ?? _defaultStorage).read(key: 'neforum.keyring-check'));
      unavailableReason.value = null;
      return true;
    } on SecretStoreUnavailableException {
      return false;
    }
  }

  static Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PlatformException catch (e) {
      if (!Env.isLinux) rethrow;
      debugPrint('Secret Service error ${e.code}: ${e.message}');
      final message = linuxKeyringMessage(e.code);
      unavailableReason.value = message;
      throw SecretStoreUnavailableException(message);
    }
  }

  @override
  Future<Map<String, String>?> read(String accountId) async {
    final cached = _cache[accountId];
    if (cached != null) return Map.unmodifiable(cached);
    final raw = await _guard(() => _s.read(key: _key(accountId)));
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
    try {
      await _guard(() => _s.write(key: _key(accountId), value: jsonEncode(secrets)));
    } on Object {
      // Not kept as if saved: the next read asks the keyring again.
      _cache.remove(accountId);
      rethrow;
    }
  }

  @override
  Future<void> delete(String accountId) async {
    _cache.remove(accountId);
    await _guard(() => _s.delete(key: _key(accountId)));
  }
}
