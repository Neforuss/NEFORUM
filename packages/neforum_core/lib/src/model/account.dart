import 'package:meta/meta.dart';

import 'platform_descriptor.dart';

/// One connected account on one platform, reached through one [PlatformTier].
///
/// Non-secret configuration (instance URL, page id, channel id, chosen
/// visibility defaults, the user's own client id, ...) lives in [config].
/// Secrets (access tokens, app passwords, bot tokens, private keys) are kept
/// separately in a [SecretStore] under this account's [id] and are handed to
/// the adapter only for the duration of a call.
@immutable
class ConnectedAccount {
  const ConnectedAccount({
    required this.id,
    required this.platformId,
    required this.tier,
    required this.displayName,
    required this.createdAt,
    this.handle,
    this.avatarUrl,
    this.profileUrl,
    this.config = const {},
    this.quotaOverrides = const {},
    this.enabled = true,
    this.lastError,
  });

  factory ConnectedAccount.fromJson(Map<String, dynamic> json) {
    return ConnectedAccount(
      id: json['id'] as String,
      platformId: json['platformId'] as String,
      tier: PlatformTier.values.byName(json['tier'] as String),
      displayName: json['displayName'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      handle: json['handle'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      profileUrl: json['profileUrl'] as String?,
      config: Map<String, dynamic>.from(json['config'] as Map? ?? const {}),
      quotaOverrides: (json['quotaOverrides'] as Map? ?? const {})
          .map((k, v) => MapEntry(k as String, v as int)),
      enabled: json['enabled'] as bool? ?? true,
      lastError: json['lastError'] as String?,
    );
  }

  final String id;
  final String platformId;
  final PlatformTier tier;

  /// Human label, e.g. `Alice (mastodon.social)`.
  final String displayName;

  /// `@alice@mastodon.social`, `u/alice`, channel name, ...
  final String? handle;
  final String? avatarUrl;
  final String? profileUrl;
  final DateTime createdAt;

  /// Adapter-specific, non-secret configuration.
  final Map<String, dynamic> config;

  /// Overrides for [QuotaRule.limit] keyed by [QuotaRule.id], so a user on a
  /// paid X tier can raise the monthly cap.
  final Map<String, int> quotaOverrides;
  final bool enabled;
  final String? lastError;

  String configString(String key, [String fallback = '']) =>
      (config[key] as String?) ?? fallback;

  ConnectedAccount copyWith({
    String? displayName,
    String? handle,
    String? avatarUrl,
    String? profileUrl,
    Map<String, dynamic>? config,
    Map<String, int>? quotaOverrides,
    bool? enabled,
    String? lastError,
    bool clearLastError = false,
  }) {
    return ConnectedAccount(
      id: id,
      platformId: platformId,
      tier: tier,
      displayName: displayName ?? this.displayName,
      createdAt: createdAt,
      handle: handle ?? this.handle,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      profileUrl: profileUrl ?? this.profileUrl,
      config: config ?? this.config,
      quotaOverrides: quotaOverrides ?? this.quotaOverrides,
      enabled: enabled ?? this.enabled,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'platformId': platformId,
        'tier': tier.name,
        'displayName': displayName,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (handle != null) 'handle': handle,
        if (avatarUrl != null) 'avatarUrl': avatarUrl,
        if (profileUrl != null) 'profileUrl': profileUrl,
        'config': config,
        'quotaOverrides': quotaOverrides,
        'enabled': enabled,
        if (lastError != null) 'lastError': lastError,
      };

  @override
  String toString() => 'ConnectedAccount($platformId:$displayName, ${tier.name})';
}
