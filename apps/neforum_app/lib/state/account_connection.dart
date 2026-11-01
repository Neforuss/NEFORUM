import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'cloud_sync.dart';
import 'demo.dart';
import 'providers.dart';

// 1.3.5: what the Connection section of an account card shows, so the user
// can read each account's setup on two devices and see what differs (the way
// Settings > Media hosting already shows the media host's setup).
//
// The one rule that matters: no secret value ever reaches this file's output,
// not even partly. The secrets map goes in so the section can say WHICH keys
// are stored and when the sign-in runs out; what comes out holds labels,
// dates and non-secret config only, and every config value is checked
// against the stored keys first ([SecretGuard]).

/// One labelled, non-secret line of an account's setup, such as
/// "Server address: https://mastodon.social".
@immutable
class ConnectionDetail {
  const ConnectionDetail(this.label, this.value);
  final String label;

  /// May hold line breaks (a list such as Nostr relays, one per line).
  final String value;

  @override
  String toString() => '$label: $value';
}

/// When the stored sign-in runs out ([OAuthTokens.keyExpiresAt]) and whether
/// NEFORUM renews it by itself.
@immutable
class SignInExpiry {
  const SignInExpiry({required this.expiresAt, required this.expired, required this.renewsAutomatically});

  final DateTime expiresAt;

  /// [expiresAt] has passed.
  final bool expired;

  /// NEFORUM renews the sign-in on its own: before [expiresAt] (a token that
  /// renews itself while it is still valid), or even after it (a refresh
  /// token, or an app password it signs in again with).
  final bool renewsAutomatically;

  /// The sign-in ran out and nothing stored can renew it.
  bool get needsReconnecting => expired && !renewsAutomatically;
}

/// Whether the account's keys reach the user's other devices.
enum KeysTravel {
  /// Cloud sync is on: the keys are in the shared sync file.
  synced,

  /// Sync is set up, but its last run failed.
  syncNotWorking,

  /// No sync: the keys exist only in this device's keychain.
  thisDeviceOnly,
}

/// [KeysTravel] for this device: sync turned on in [settingsSyncOn], and how
/// its last run went ([phase], from `CloudSync.status`).
KeysTravel keysTravelFor({required bool settingsSyncOn, required CloudSyncPhase phase}) {
  if (!settingsSyncOn) return KeysTravel.thisDeviceOnly;
  return phase == CloudSyncPhase.error ? KeysTravel.syncNotWorking : KeysTravel.synced;
}

/// The short status for [t], as the Connection section's pill shows it.
String keysTravelLabel(KeysTravel t) => switch (t) {
      KeysTravel.synced => 'Synced',
      KeysTravel.syncNotWorking => 'Sync is not working',
      KeysTravel.thisDeviceOnly => 'Only on this device',
    };

/// One sentence under [keysTravelLabel] saying what it means.
String keysTravelExplanation(KeysTravel t) => switch (t) {
      KeysTravel.synced => 'Sync keeps these keys the same on your other devices.',
      KeysTravel.syncNotWorking => 'Sync is set up, but its last run failed: see Settings > Sync.',
      KeysTravel.thisDeviceOnly =>
        'To have them on another device, turn on Settings > Sync, or use Settings > Data & privacy > Move to another device.',
    };

/// Everything the Connection section shows for one account. Holds no secret
/// value: [storedKeys] are labels ("Access token"), [details] went through
/// [SecretGuard].
@immutable
class AccountConnection {
  const AccountConnection({
    required this.network,
    required this.method,
    required this.details,
    required this.storedKeys,
    required this.connectedAt,
    required this.tier,
    this.signIn,
    this.keysRotate = false,
    this.demo = false,
  });

  /// The platform's name ("Mastodon").
  final String network;

  /// How it posts, in plain words ([connectionMethodText]).
  final String method;
  final PlatformTier tier;

  /// Server, the user's own app, where posts go, options: see [connectionDetails].
  final List<ConnectionDetail> details;
  final SignInExpiry? signIn;

  /// The keys this device holds for the account, by friendly label, in a
  /// stable order. Empty for a hand-off account (it needs none) or when the
  /// keys never reached this device.
  final List<String> storedKeys;

  /// When the account was connected ([ConnectedAccount.createdAt]).
  final DateTime connectedAt;

  /// The platform replaces its keys on every renewal (X and Tumblr with OAuth
  /// 2.0, DeviantArt: [PlatformAdapter.rotatesRefreshTokensFor]), so without
  /// sync a copy on another device stops working.
  final bool keysRotate;

  /// A demo-workspace account (it has no keys at all).
  final bool demo;

  /// Hand-off accounts publish without keys.
  bool get needsKeys => tier != PlatformTier.handoff && !demo;
}

/// How an account on [tier] posts to [network], in plain words.
String connectionMethodText(PlatformTier tier, String network) => switch (tier) {
      PlatformTier.openApi => 'Automatically, through the open $network API',
      PlatformTier.byokApi => 'Automatically, through the official $network API and your own developer app',
      PlatformTier.handoff => 'Hand-off: NEFORUM prepares the post and opens $network, you tap Post',
      PlatformTier.webSession => 'Through the $network website you are signed into (experimental)',
    };

// ---------------------------------------------------------------------------
// Secrets: which are keys, what they are called, and the guard.
// ---------------------------------------------------------------------------

/// Secret-store entries that are bookkeeping about a key, not a key: when it
/// runs out, what kind it is, what it may do, when it was last renewed.
/// They are not listed as stored keys and their values are never shown; only
/// [OAuthTokens.keyExpiresAt] is read, and only as a date. They are left out
/// of [SecretGuard] because they hold no secret (a date, "Bearer").
const Set<String> kSecretBookkeepingKeys = {
  OAuthTokens.keyExpiresAt,
  OAuthTokens.keyTokenType,
  OAuthTokens.keyScope,
  'refresh_expires_at', // Pinterest, YouTube, TikTok: when the refresh token runs out.
  'token_issued_at', // ThreadsAdapter.secretIssuedAt
  'refreshed_at', // InstagramAdapter.keyRefreshedAt
  'user_token_expires_at', // FacebookAdapter.secUserTokenExpiresAt
  'open_id', // TikTokSecretKeys.openId: the user's id at TikTok, kept with the tokens.
};

/// When a renewal timestamp is stored, the access token renews itself while
/// it is still valid (Threads, Instagram): no refresh token, but not
/// "needs reconnecting" either, until it actually runs out.
const Set<String> _selfRenewingMarkers = {'token_issued_at', 'refreshed_at'};

/// Friendly names for the secret-store keys the adapters write. Checked
/// before the connect form's own label because the standard OAuth keys are
/// written by browser sign-ins too: Threads' form calls its token field
/// "Access token from the User Token Generator", which would be wrong for a
/// token that came from signing in.
const Map<String, String> kSecretKeyLabels = {
  OAuthTokens.keyAccessToken: 'Access token',
  OAuthTokens.keyRefreshToken: 'Refresh token',
  OAuth1Credentials.keyConsumerKey: 'Consumer key (API key)',
  OAuth1Credentials.keyConsumerSecret: 'Consumer secret (API key secret)',
  OAuth1Credentials.keyToken: 'OAuth 1.0a access token',
  OAuth1Credentials.keyTokenSecret: 'OAuth 1.0a access token secret',
  'client_id': 'Client ID',
  'client_secret': 'Client secret',
  'app_secret': 'App secret',
  'consumer_secret': 'Consumer secret',
  'app_password': 'App password',
  'admin_api_key': 'Admin API key',
  'bot_token': 'Bot token',
  'webhook_url': 'Webhook URL',
  'user_access_token': 'User access token',
  'privateKey': 'Private key',
  'password': 'Password',
  'sid': 'Session',
};

/// Withholds any text that shares [run] or more characters in a row with a
/// stored key, so no part of a secret can reach the screen or the clipboard.
///
/// Why a guard on top of choosing which config keys to show: some config
/// values are cut from a secret by design. Telegram's bot id is the start of
/// the bot token, Ghost's key id the start of the Admin API key, a Discord
/// thread id sits inside the webhook address, and a Tumblr account connected
/// with OAuth 1.0a keeps its consumer key both in its config and with its
/// keys. The guard makes all of those, and any added later, structurally
/// unable to show.
///
/// It errs on the side of hiding: an innocent value that happens to share 6
/// characters with a key is left out. A secret shorter than [run] (4 or more
/// characters) is matched whole.
class SecretGuard {
  SecretGuard(Map<String, String> secrets, {this.run = 6}) {
    for (final e in secrets.entries) {
      if (kSecretBookkeepingKeys.contains(e.key)) continue;
      final v = e.value;
      if (v.length >= run) {
        for (var i = 0; i + run <= v.length; i++) {
          _windows.add(v.substring(i, i + run));
        }
      } else if (v.length >= 4) {
        _short.add(v);
      }
    }
  }

  final int run;
  final Set<String> _windows = {};
  final List<String> _short = [];

  /// Whether [text] would show part of a stored key.
  bool reveals(String text) {
    for (var i = 0; i + run <= text.length; i++) {
      if (_windows.contains(text.substring(i, i + run))) return true;
    }
    return _short.any(text.contains);
  }
}

/// The keys in [secrets], by friendly label: [kSecretKeyLabels], else the
/// connect form's label for that key, else the key name in words. Bookkeeping
/// entries and empty values are left out. Only the names are read here.
List<String> storedKeyLabels(Map<String, String> secrets, PlatformAdapter? adapter) {
  final formLabels = <String, String>{
    for (final s in adapter?.connectSpecs ?? const <ConnectSpec>[])
      for (final f in s.fields)
        if (f.secret) f.key: cleanFieldLabel(f.label),
  };
  final labels = <String>[];
  for (final e in secrets.entries) {
    if (kSecretBookkeepingKeys.contains(e.key) || e.value.isEmpty) continue;
    final label = kSecretKeyLabels[e.key] ?? formLabels[e.key] ?? humanizeKey(e.key);
    if (!labels.contains(label)) labels.add(label);
  }
  // A stable order, so the same keys read the same on every device.
  final order = kSecretKeyLabels.values.toList();
  int rank(String l) {
    final i = order.indexOf(l);
    return i < 0 ? order.length : i;
  }

  labels.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : a.compareTo(b);
  });
  return labels;
}

/// `user_access_token` / `apiKey` -> "User access token" / "Api key". Key
/// names are not secret; this is the last resort for one no label covers.
String humanizeKey(String key) {
  final spaced = key
      .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll(RegExp('[_-]+'), ' ')
      .trim()
      .toLowerCase();
  return spaced.isEmpty ? key : '${spaced[0].toUpperCase()}${spaced.substring(1)}';
}

/// A connect form label without the hint meant for the form: "Client ID
/// (advanced, optional)" -> "Client ID", "Redirect URI (advanced)" ->
/// "Redirect URI". A parenthesis that names the thing ("Private key (nsec)",
/// "Media server (NIP-96)") stays.
String cleanFieldLabel(String label) =>
    label.replaceFirst(RegExp(r'\s*\((?:[^()]*\b(?:optional|advanced|if|only|instead)\b[^()]*)\)\s*$', caseSensitive: false), '').trim();

// ---------------------------------------------------------------------------
// Config: which keys are shown, and under what label.
// ---------------------------------------------------------------------------

/// A config key the connect form does not ask for but that describes the
/// setup, with its label; [only] limits it to some platforms.
@immutable
class _ConfigLabel {
  const _ConfigLabel(this.label, {this.only});
  final String label;
  final Set<String>? only;
}

/// Config keys shown beyond the connect form's own fields, reviewed one by
/// one against what every built-in adapter stores (1.3.5).
///
/// Labels come from the adapter's connect form first: a config key that is
/// also a form field (Mastodon's `instance`, Facebook's `app_id`, WordPress's
/// `site`) is shown under that field's label. This map covers what the
/// adapters store under another name or find out while connecting (the
/// Bluesky PDS, the Facebook Page, the Pinterest board). Every other key is
/// left out on purpose:
/// - parts of a secret: Ghost `keyId`, Telegram `botId`, Discord `webhookId`
///   and `threadId` (and [SecretGuard] catches any that slip through);
/// - internal ids the handle already covers (`userId`, `personId`, `sub`,
///   `remoteAccountId`, `pubkey`);
/// - what the server reported and NEFORUM caches: limits, capability flags,
///   discovered endpoints, scopes, version numbers, lists of other blogs,
///   Pages and languages.
const Map<String, _ConfigLabel> _configLabels = {
  // Where the account lives.
  'pds': _ConfigLabel('PDS (data server)'),
  'software': _ConfigLabel('Server software'),
  'base': _ConfigLabel('Forem community', only: {'devto'}),
  'micropubEndpoint': _ConfigLabel('Micropub endpoint'),
  'mediaEndpoint': _ConfigLabel('Media endpoint'),
  'siteName': _ConfigLabel('Site name'),
  'siteTitle': _ConfigLabel('Site name'),
  'blogUrl': _ConfigLabel('Blog address'),
  'collectionUrl': _ConfigLabel('Blog address'),
  'publicationUrl': _ConfigLabel('Blog address'),
  // The user's own developer app.
  'clientId': _ConfigLabel('Client ID'),
  'clientKey': _ConfigLabel('Client key'),
  'appId': _ConfigLabel('App ID'),
  'redirectUri': _ConfigLabel('Redirect URI'),
  // Where posts go.
  'page_name': _ConfigLabel('Page'),
  'boardName': _ConfigLabel('Board'),
  'blogName': _ConfigLabel('Blog'),
  'collectionTitle': _ConfigLabel('Blog'),
  'publicationTitle': _ConfigLabel('Blog'),
  'alias': _ConfigLabel('Blog alias', only: {'writefreely'}),
  'channelName': _ConfigLabel('Channel'),
  'channelId': _ConfigLabel('Channel ID', only: {'youtube', 'odysee'}),
  'defaultSubreddit': _ConfigLabel('Default subreddit'),
  'roomName': _ConfigLabel('Room'),
  'roomAlias': _ConfigLabel('Room address'),
  'roomId': _ConfigLabel('Room ID'),
  'chatTitle': _ConfigLabel('Channel or group'),
  'chatUsername': _ConfigLabel('Channel or group username'),
  'webhookName': _ConfigLabel('Webhook'),
  'botUsername': _ConfigLabel('Bot'),
  'anonymous': _ConfigLabel('Posts anonymously', only: {'writefreely'}),
  // Who the account is, where the handle does not say it.
  'npub': _ConfigLabel('Public key (npub)'),
  'did': _ConfigLabel('Account ID (DID)'),
};

/// Config keys that record how the account signed in, and the values in
/// words. A value not listed here is an internal code and is left out.
const Set<String> _signInMethodKeys = {'authMode', 'authMethod', 'tokenSource', 'token_source'};
const Map<String, String> _signInMethods = {
  'oauth2': 'Browser sign-in (OAuth 2.0)',
  'oauth1': 'OAuth 1.0a keys',
  'oauth': 'Browser sign-in',
  'dashboard': 'Access token pasted from the developer dashboard',
  'pasted': 'Access token pasted from the developer dashboard',
  'token': 'Access token',
  'password': 'Password',
  'miauth': 'Browser sign-in (MiAuth)',
  'indieauth': 'Browser sign-in (IndieAuth)',
};

/// [value] as text, or null when it is not something to show (a map, a list
/// of objects, an empty string). [field] decides booleans, lists and choices.
String? _formatValue(Object? value, {ConnectField? field}) {
  String? capitalise(String s) => s.isEmpty ? null : '${s[0].toUpperCase()}${s.substring(1)}';
  switch (value) {
    case null:
      return null;
    case bool b:
      return b ? 'Yes' : 'No';
    case num n:
      return '$n';
    case String s:
      final t = s.trim();
      if (t.isEmpty) return null;
      if (field?.kind == FieldKind.boolean) return t == 'true' ? 'Yes' : (t == 'false' ? 'No' : t);
      if (field?.kind == FieldKind.select) return capitalise(t);
      return t;
    case List<Object?> l:
      if (l.isEmpty || l.any((e) => e is! String && e is! num)) return null;
      return l.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).join(field?.kind == FieldKind.multiline ? '\n' : ', ');
    default:
      return null;
  }
}

/// The non-secret setup of [account], labelled, in the connect form's order:
/// first every config key that is a field of the form (the account's own way
/// of connecting first, then the platform's other ways, so its wording wins),
/// then the reviewed extras in [_configLabels], then how it signed in. A
/// value [SecretGuard] flags is left out.
List<ConnectionDetail> connectionDetails(ConnectedAccount account, PlatformAdapter? adapter, {Map<String, String> secrets = const {}}) {
  final guard = SecretGuard(secrets);
  final specs = adapter?.connectSpecs ?? const <ConnectSpec>[];
  final fields = <String, ConnectField>{};
  for (final s in [...specs.where((s) => s.tier == account.tier), ...specs.where((s) => s.tier != account.tier)]) {
    for (final f in s.fields) {
      if (!f.secret) fields.putIfAbsent(f.key, () => f);
    }
  }

  final out = <ConnectionDetail>[];
  void add(String label, String? value) {
    if (value == null || guard.reveals(value)) return;
    out.add(ConnectionDetail(label, value));
  }

  for (final f in fields.values) {
    if (account.config.containsKey(f.key)) add(cleanFieldLabel(f.label), _formatValue(account.config[f.key], field: f));
  }
  for (final e in _configLabels.entries) {
    final only = e.value.only;
    if (fields.containsKey(e.key) || (only != null && !only.contains(account.platformId))) continue;
    add(e.value.label, _formatValue(account.config[e.key]));
  }
  for (final k in _signInMethodKeys) {
    if (fields.containsKey(k)) continue;
    final method = _signInMethods['${account.config[k] ?? ''}'.trim()];
    if (method != null) {
      add('Sign-in method', method);
      break;
    }
  }
  return out;
}

/// When the sign-in in [secrets] runs out and whether it renews, or null
/// when no expiry is stored (most keys and passwords never run out on a set
/// date). Reads [OAuthTokens.keyExpiresAt] and the presence (never the value)
/// of a refresh token, an app password or a renewal timestamp.
SignInExpiry? signInExpiry(Map<String, String> secrets, {required DateTime now}) {
  final expiresAt = DateTime.tryParse(secrets[OAuthTokens.keyExpiresAt] ?? '');
  if (expiresAt == null) return null;
  bool has(String k) => (secrets[k] ?? '').isNotEmpty;
  final refreshEnds = DateTime.tryParse(secrets['refresh_expires_at'] ?? '');
  final refresh = has(OAuthTokens.keyRefreshToken) && (refreshEnds == null || now.isBefore(refreshEnds));
  // Bluesky signs in again with the app password when its session ends.
  final password = has('app_password') && has(OAuthTokens.keyAccessToken);
  final selfRenewing = _selfRenewingMarkers.any(has);
  final expired = !now.isBefore(expiresAt);
  return SignInExpiry(
    expiresAt: expiresAt,
    expired: expired,
    renewsAutomatically: refresh || password || (!expired && selfRenewing),
  );
}

/// [e] in words; [when] writes a date and time.
String signInText(SignInExpiry e, String Function(DateTime) when) {
  final at = when(e.expiresAt);
  if (e.needsReconnecting) return 'Ran out on $at. Needs reconnecting.';
  if (e.expired) return 'Ran out on $at. Renews automatically before the next post.';
  return e.renewsAutomatically ? 'Valid until $at. Renews automatically.' : 'Valid until $at. Then needs reconnecting.';
}

/// The adapter a demo account stands in for, so questions about the real
/// platform (does it replace its keys on renewal?) get the real answer.
PlatformAdapter? _realAdapter(PlatformAdapter? a) => a is DemoAdapter ? a.inner : a;

/// [AccountConnection] for [account] from its config and [secrets] (which
/// are read for names, the expiry date and [SecretGuard], never copied).
AccountConnection describeAccountConnection(
  ConnectedAccount account, {
  PlatformAdapter? adapter,
  Map<String, String> secrets = const {},
  required DateTime now,
}) {
  final network = adapter?.descriptor.name ?? account.platformId;
  final real = _realAdapter(adapter);
  return AccountConnection(
    network: network,
    tier: account.tier,
    method: connectionMethodText(account.tier, network),
    details: connectionDetails(account, adapter, secrets: secrets),
    signIn: signInExpiry(secrets, now: now),
    storedKeys: storedKeyLabels(secrets, adapter),
    connectedAt: account.createdAt,
    keysRotate: account.tier != PlatformTier.handoff && (real?.rotatesRefreshTokensFor(account) ?? false),
    demo: account.config['demo'] == true,
  );
}

/// "Keys on this device" in one line, for the copied text.
String storedKeysLine(AccountConnection c, KeysTravel travel) {
  if (c.storedKeys.isNotEmpty) return '${c.storedKeys.join(', ')} (${keysTravelLabel(travel)})';
  if (c.demo) return 'None (demo account)';
  return c.needsKeys ? 'None stored on this device' : 'None needed';
}

/// The setup of [account] as plain text, to paste next to the same list
/// from another device: no key, password or token, only what the
/// Connection section shows.
String connectionSetupText(ConnectedAccount account, AccountConnection c, {required KeysTravel travel, required String Function(DateTime) when}) {
  final handle = account.handle;
  final who = handle == null || handle == account.displayName ? account.displayName : '${account.displayName} ($handle)';
  return [
    '${c.network}: $who',
    'How it posts: ${c.method}',
    for (final d in c.details) '${d.label}: ${d.value.replaceAll('\n', ', ')}',
    if (c.signIn != null) 'Sign-in: ${signInText(c.signIn!, when)}',
    'Keys on this device: ${storedKeysLine(c, travel)}',
    'Connected: ${when(c.connectedAt)}',
  ].join('\n');
}

/// [AccountConnection] for one account, read when its Connection section is
/// open. autoDispose: every opening reads the keychain again (a renewed
/// sign-in shows its new date), and nothing is kept once it is closed. The
/// secrets map lives only inside this function.
final accountConnectionProvider = FutureProvider.autoDispose.family<AccountConnection?, String>((ref, accountId) async {
  final account = ref.watch(accountByIdProvider(accountId));
  if (account == null) return null;
  final s = ref.watch(servicesProvider);
  final secrets = await s.secrets.read(accountId) ?? const <String, String>{};
  return describeAccountConnection(account, adapter: s.registry.byId(account.platformId), secrets: secrets, now: DateTime.now());
});

/// Every account's [connectionSetupText], in [accounts]' order, separated by
/// blank lines: "Copy all setups" on the Accounts page.
Future<String> allConnectionSetupsText(
  List<ConnectedAccount> accounts, {
  required SecretStore secrets,
  required AdapterRegistry registry,
  required KeysTravel travel,
  required String Function(DateTime) when,
  DateTime? now,
}) async {
  final at = now ?? DateTime.now();
  final parts = <String>[];
  for (final a in accounts) {
    final c = describeAccountConnection(a, adapter: registry.byId(a.platformId), secrets: await secrets.read(a.id) ?? const {}, now: at);
    parts.add(connectionSetupText(a, c, travel: travel, when: when));
  }
  return parts.join('\n\n');
}
