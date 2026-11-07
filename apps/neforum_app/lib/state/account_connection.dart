import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../platform/device_name.dart';
import '../platform/env.dart';
import 'cloud_sync.dart';
import 'demo.dart';
import 'providers.dart';

// 1.3.5: what the Connection section of an account card shows, so the user
// can read each account's setup on two devices and see what differs (the way
// Settings > Media hosting already shows the media host's setup).
//
// The one rule that matters: no secret value ever reaches this file's output,
// not even partly. The secrets map goes in so the section can say WHICH keys
// are stored and when the sign-in ends; what comes out holds labels, dates
// and non-secret config only, and every config value is checked against the
// stored keys first ([SecretGuard]).

/// One labelled, non-secret line of an account's setup, such as
/// "Server address: https://mastodon.social".
@immutable
class ConnectionDetail {
  const ConnectionDetail(this.label, this.value, {this.withheld = false});

  /// A row whose value [SecretGuard] withheld: [value] is [kWithheldValue],
  /// or [kStoredKeyValue] when the value is a stored key itself ([isKey]).
  const ConnectionDetail.withheld(this.label, {bool isKey = false})
      : value = isKey ? kStoredKeyValue : kWithheldValue,
        withheld = true;

  final String label;

  /// May hold line breaks (a list such as Nostr relays, one per line).
  final String value;
  final bool withheld;

  @override
  String toString() => '$label: $value';
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
    required this.needsKeys,
    this.noKeysReason,
    this.signIn,
    this.keysRotate = false,
    this.demo = false,
    this.keysUnreadable = false,
  });

  /// The platform's name ("Mastodon").
  final String network;

  /// How it posts, in plain words ([connectionMethodText]).
  final String method;
  final PlatformTier tier;

  /// Server, the user's own app, where posts go, options: see [connectionDetails].
  final List<ConnectionDetail> details;

  /// Where the stored sign-in stands. Null with no keys to judge, or when this
  /// way of connecting has no sign-in ([SignInPolicy.hasConnection]).
  final SignInLifetime? signIn;

  /// The keys this device holds for the account, by friendly label, in a
  /// stable order.
  final List<String> storedKeys;

  /// This way of connecting stores keys ([connectionStoresKeys]), so having
  /// none here means they never reached this device.
  final bool needsKeys;

  /// Why an account that [needsKeys] not has none, in a few words ("it posts
  /// through the LBRY app on this device"). Null when it needs keys.
  final String? noKeysReason;

  /// When the account was connected ([ConnectedAccount.createdAt]).
  final DateTime connectedAt;

  /// The platform replaces its keys on every renewal (X and Tumblr with OAuth
  /// 2.0, DeviantArt, TikTok, Pixelfed: [PlatformAdapter.rotatesRefreshTokensFor]), so without
  /// sync a copy on another device stops working.
  final bool keysRotate;

  /// A demo-workspace account (it has no keys at all).
  final bool demo;

  /// The keychain refused to answer for this account (locked, or access
  /// denied): what it holds is unknown, so no details or keys are listed.
  final bool keysUnreadable;

  /// Keys are expected but this device has none.
  bool get keysMissing => storedKeys.isEmpty && needsKeys && !demo && !keysUnreadable;
}

/// How an account on [tier] posts to [network], in plain words.
String connectionMethodText(PlatformTier tier, String network) => switch (tier) {
      PlatformTier.openApi => 'Automatically, through the open $network API',
      PlatformTier.byokApi => 'Automatically, through the official $network API and your own developer app',
      PlatformTier.handoff => 'Hand-off: NEFORUM prepares the post and opens $network, you tap Post',
      PlatformTier.webSession => 'Through the $network website you are signed into (experimental)',
    };

/// Whether [account]'s way of connecting leaves keys behind, read from the
/// adapter's own connect form: a secret field, or a browser sign-in (OAuth,
/// MiAuth, IndieAuth), which always ends with a token. A hand-off needs no
/// keys, and neither does Odysee's Auto, which posts through the LBRY app on
/// this device and stores nothing (`OdyseeAdapter.connect`). An account
/// whose platform this build does not know is assumed to need them.
bool connectionStoresKeys(ConnectedAccount account, PlatformAdapter? adapter) {
  if (account.tier == PlatformTier.handoff) return false;
  if (adapter == null) return true;
  final specs = adapter.connectSpecs.where((s) => s.tier == account.tier);
  if (specs.isEmpty) return true;
  return specs.any((s) => s.usesBrowser || s.fields.any((f) => f.secret));
}

/// Why a way of connecting that stores no keys needs none, by platform; the
/// fallback covers any other.
const Map<String, String> _noKeysReasons = {
  'odysee': 'it posts through the LBRY app on this device',
};

String _noKeysReason(ConnectedAccount account) => account.tier == PlatformTier.handoff
    ? 'hand-off opens the app or website, where you are signed in'
    : _noKeysReasons[account.platformId] ?? 'this way of posting uses no keys';

/// "Keys on this device" when the list is empty, as the section says it.
String noStoredKeysText(AccountConnection c) {
  if (c.keysUnreadable) return "Could not read this account's keys on this device.";
  if (c.demo) return 'None: this is a demo account.';
  if (c.keysMissing) return 'None stored on this device. Reconnect the account here, or bring its keys over with Sync or Move to another device.';
  return 'None needed: ${c.noKeysReason ?? 'this way of posting uses no keys'}.';
}

// ---------------------------------------------------------------------------
// Secrets: which are keys, what they are called, and the guard.
// ---------------------------------------------------------------------------

/// Secret-store entries that are bookkeeping about a key, not a key: when it
/// runs out, what kind it is, what it may do, when it was last renewed.
/// They are not listed as stored keys and their values are never shown; the
/// two expiry dates are read, and only as dates. They are left out of
/// [SecretGuard] because they hold no secret (a date, "Bearer").
const Set<String> kSecretBookkeepingKeys = {
  OAuthTokens.keyExpiresAt,
  OAuthTokens.keyTokenType,
  OAuthTokens.keyScope,
  StoredSecretKeys.refreshExpiresAt,
  StoredSecretKeys.tokenIssuedAt,
  StoredSecretKeys.refreshedAt,
  StoredSecretKeys.userTokenExpiresAt,
  StoredSecretKeys.openId,
  StoredSecretKeys.expiresAtSource,
  StoredSecretKeys.refreshExpiresSource,
  StoredSecretKeys.lastRenewedAt,
};

/// Friendly names for the secret-store keys the adapters write. Checked
/// before the connect form's own label because the standard OAuth keys are
/// written by browser sign-ins too: Threads' form calls its token field
/// "Access token from the User Token Generator", which would be wrong for a
/// token that came from signing in.
///
/// Names core exports are its own constants ([StoredSecretKeys], the OAuth
/// helpers). The rest are written as literals inside one adapter each and
/// only choose a label here: if one were renamed, the key would still be
/// listed, under its connect form label or its name in words.
const Map<String, String> kSecretKeyLabels = {
  OAuthTokens.keyAccessToken: 'Access token',
  // Accounts connected before 1.0 kept the token as `jwt` (Lemmy) or
  // `token` (Misskey); core still reads both.
  'jwt': 'Access token',
  'token': 'Access token',
  OAuthTokens.keyRefreshToken: 'Refresh token',
  OAuth1Credentials.keyConsumerKey: 'Consumer key (API key)',
  OAuth1Credentials.keyConsumerSecret: 'Consumer secret (API key secret)',
  OAuth1Credentials.keyToken: 'OAuth 1.0a access token',
  OAuth1Credentials.keyTokenSecret: 'OAuth 1.0a access token secret',
  'client_id': 'Client ID', // Mastodon's registered app.
  StoredSecretKeys.clientSecret: 'Client secret',
  StoredSecretKeys.appSecret: 'App secret',
  StoredSecretKeys.consumerSecret: 'Consumer secret',
  StoredSecretKeys.appPassword: 'App password',
  'admin_api_key': 'Admin API key', // Ghost.
  'bot_token': 'Bot token', // Telegram.
  'webhook_url': 'Webhook URL', // Discord.
  StoredSecretKeys.userAccessToken: 'User access token',
  StoredSecretKeys.privateKey: 'Private key',
  'password': 'Password',
  StoredSecretKeys.sessionId: 'Session',
};

/// Hosts whose key addresses (webhooks) begin the same way for every user,
/// and the leading path segments they share. Listed one by one: an address
/// on any other host counts in full.
const Map<String, Set<String>> _publicAddressPrefixes = {
  'discord.com': {'api', 'v9', 'v10', 'webhooks'},
  'discordapp.com': {'api', 'v9', 'v10', 'webhooks'},
  'ptb.discord.com': {'api', 'v9', 'v10', 'webhooks'},
  'canary.discord.com': {'api', 'v9', 'v10', 'webhooks'},
};

/// What a detail shows instead of a value [SecretGuard] withholds, so the
/// row stays (and two devices can see it is there) without the value.
const String kWithheldValue = 'Not shown: it shares characters with a stored key';

/// What a detail shows when its value is one of the stored keys itself (a
/// Tumblr account connected with OAuth 1.0a keeps its consumer key in its
/// config and with its keys).
const String kStoredKeyValue = 'Not shown: it is one of the stored keys';

/// Withholds any text that shares [run] (4) or more characters in a row with
/// a stored key, so no part of a secret, not even its last 4 characters, can
/// reach the screen or the clipboard.
///
/// Why a guard on top of choosing which config keys to show: some config
/// values are cut from a secret by design. Telegram's bot id is the start of
/// the bot token, Ghost's key id the start of the Admin API key, a Discord
/// thread id sits inside the webhook address, and a Tumblr account connected
/// with OAuth 1.0a keeps its consumer key both in its config and with its
/// keys. The guard makes all of those, and any added later, structurally
/// unable to show.
///
/// A key that is a web address (a Discord webhook) counts by every part
/// that can carry a secret: its host, any user name and password before the
/// host, every path segment, every query value and the fragment. Only its
/// scheme and the query parameter names are left out, and, for the hosts in
/// [_publicAddressPrefixes], the host and the leading path segments every
/// user's address shares ("https://discord.com/api/webhooks/"), which the
/// platform prints in its documentation: matching those would hide every
/// web address on the card while protecting nothing.
///
/// It errs on the side of hiding: a value that shares 4 characters in a row
/// with a key is replaced by [kWithheldValue] (for random tokens that is
/// rare: the odds that a 30-character address shares 4 characters with a
/// 43-character token are about 1 in 10 000). Keys shorter than [run] are
/// not matched: 3 characters identify nothing.
class SecretGuard {
  SecretGuard(Map<String, String> secrets, {this.run = 4}) {
    for (final e in secrets.entries) {
      if (kSecretBookkeepingKeys.contains(e.key)) continue;
      if (e.value.trim().isNotEmpty) _whole.add(e.value.trim());
      for (final part in secretParts(e.value)) {
        for (var i = 0; i + run <= part.length; i++) {
          _windows.add(part.substring(i, i + run));
        }
      }
    }
  }

  final int run;
  final Set<String> _windows = {};
  final Set<String> _whole = {};

  /// Whether [text] is one of the stored keys itself, whole (not just
  /// sharing characters with one).
  bool isKey(String text) => _whole.contains(text.trim());

  /// The values of a query or fragment as written ("a=1&b=2" -> "1", "2"),
  /// still percent-encoded.
  static Iterable<String> _rawValues(String q) => q.split('&').map((p) => p.contains('=') ? p.substring(p.indexOf('=') + 1) : p);

  /// The parts of [value] that are secret: all of it, except for a web
  /// address (see [SecretGuard]). Each part of an address counts both decoded
  /// and as written, so a value holding the encoded form ("tok%2Fen") is
  /// caught as well as the decoded one ("tok/en").
  static List<String> secretParts(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) return [value];
    final public = _publicAddressPrefixes[uri.host.toLowerCase()];
    final segments = uri.pathSegments;
    final rawSegments = uri.path.split('/').where((s) => s.isNotEmpty).toList();
    int publicStart(List<String> s) {
      var skip = 0;
      while (public != null && skip < s.length && public.contains(s[skip].toLowerCase())) {
        skip++;
      }
      return skip;
    }

    final fragment = uri.fragment;
    final decodedFragment = Uri.decodeComponent(fragment);
    return {
      if (public == null) uri.host,
      uri.userInfo,
      ...segments.skip(publicStart(segments)),
      ...rawSegments.skip(publicStart(rawSegments)),
      for (final values in uri.queryParametersAll.values) ...values,
      ..._rawValues(uri.query),
      // "#access_token=…&state=…" counts by its values, like a query.
      if (fragment.contains('=')) ...[...Uri.splitQueryString(fragment).values, ..._rawValues(fragment)] else ...[fragment, decodedFragment],
    }.where((s) => s.isNotEmpty).toList();
  }

  /// Whether [text] would show part of a stored key.
  bool reveals(String text) {
    if (_windows.isEmpty) return false;
    for (var i = 0; i + run <= text.length; i++) {
      if (_windows.contains(text.substring(i, i + run))) return true;
    }
    return false;
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
// Config: which keys are shown, under what label, in what order.
// ---------------------------------------------------------------------------

/// The order the details are listed in: where the account lives, the user's
/// own app, where posts go, who it posts as, then options, then how it
/// signed in. The target comes before options such as Formatting.
enum _Group { place, app, target, identity, option, method }

/// A config key the connect form does not ask for but that describes the
/// setup: its label, its [group], [values] in words, and [only] the
/// platforms it is shown for.
@immutable
class _ConfigLabel {
  const _ConfigLabel(this.label, this.group, {this.only, this.values});
  final String label;
  final _Group group;
  final Set<String>? only;
  final Map<String, String>? values;
}

/// Server software names as their projects write them. Anything else is
/// shown as the server reports it.
const Map<String, String> _softwareNames = {
  'mastodon': 'Mastodon',
  'pleroma': 'Pleroma',
  'akkoma': 'Akkoma',
  'gotosocial': 'GoToSocial',
  'friendica': 'Friendica',
  'pixelfed': 'Pixelfed',
  'mitra': 'Mitra',
  'hometown': 'Hometown',
  'glitchsoc': 'glitch-soc',
  'iceshrimp': 'Iceshrimp',
  'sharkey': 'Sharkey',
  'misskey': 'Misskey',
  'firefish': 'Firefish',
  'takahe': 'Takahē',
  'snac': 'snac',
  'wildebeest': 'Wildebeest',
  'bonfire': 'Bonfire',
  'honk': 'honk',
};

/// Config keys shown beyond the connect form's own fields, reviewed one by
/// one against what every built-in adapter's `connect()` stores (1.3.5).
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
///   `remoteAccountId`, `pubkey`, Telegram `chatUsername`);
/// - what the server reported and NEFORUM caches: limits, capability flags,
///   discovered endpoints, scopes, version numbers, lists of other blogs,
///   Pages and languages.
/// The redirect address is filtered apart (see [_registersRedirect]), and
/// Matrix's room is one row built from its three keys ([_matrixRoom]).
const Map<String, _ConfigLabel> _configLabels = {
  'pds': _ConfigLabel('PDS (data server)', _Group.place),
  'software': _ConfigLabel('Server software', _Group.place, values: _softwareNames),
  'base': _ConfigLabel('Forem community', _Group.place, only: {'devto'}),
  'micropubEndpoint': _ConfigLabel('Micropub endpoint', _Group.place),
  'mediaEndpoint': _ConfigLabel('Media endpoint', _Group.place),
  'siteName': _ConfigLabel('Site name', _Group.place),
  'siteTitle': _ConfigLabel('Site name', _Group.place),
  'clientId': _ConfigLabel('Client ID', _Group.app),
  'clientKey': _ConfigLabel('Client key', _Group.app),
  'appId': _ConfigLabel('App ID', _Group.app),
  'redirectUri': _ConfigLabel('Redirect URI', _Group.app),
  'page_name': _ConfigLabel('Page', _Group.target),
  'boardName': _ConfigLabel('Board', _Group.target),
  'blogName': _ConfigLabel('Blog', _Group.target),
  'blogUrl': _ConfigLabel('Blog address', _Group.target),
  'collectionTitle': _ConfigLabel('Blog', _Group.target),
  'collectionUrl': _ConfigLabel('Blog address', _Group.target),
  'publicationTitle': _ConfigLabel('Blog', _Group.target),
  'publicationUrl': _ConfigLabel('Blog address', _Group.target),
  'alias': _ConfigLabel('Blog alias', _Group.target, only: {'writefreely'}),
  'channelName': _ConfigLabel('Channel', _Group.target),
  'channelId': _ConfigLabel('Channel ID', _Group.target, only: {'youtube', 'odysee'}),
  'defaultSubreddit': _ConfigLabel('Default subreddit', _Group.target),
  'chatTitle': _ConfigLabel('Channel or group', _Group.target),
  'webhookName': _ConfigLabel('Webhook', _Group.target),
  'botUsername': _ConfigLabel('Bot', _Group.identity),
  'npub': _ConfigLabel('Public key (npub)', _Group.identity),
  'did': _ConfigLabel('Account ID (DID)', _Group.identity),
  'anonymous': _ConfigLabel('Posts anonymously', _Group.option, only: {'writefreely'}),
};

/// Config keys holding the address the platform sends the browser back to.
const Set<String> _redirectKeys = {'redirectUri', 'redirect_uri'};

/// Platforms where the user registers the redirect address in their own
/// developer app (its connect form's redirect note says so), so both devices
/// must use the one registered. Elsewhere it is NEFORUM's own default
/// (Mastodon and Pixelfed register the app themselves; Google's desktop
/// clients accept any loopback address) and only adds noise.
const Set<String> _registersRedirect = {'x', 'tumblr', 'threads', 'instagram', 'facebook', 'linkedin', 'reddit', 'pinterest', 'tiktok', 'deviantart', 'dribbble', 'flickr'};

/// Choice values in words. A choice not listed is shown as stored.
const Map<String, String> _choiceLabels = {
  'markdown': 'Markdown',
  'html': 'HTML',
  'plain': 'Plain text',
  'publish': 'Published',
  'published': 'Published',
  'draft': 'Draft',
  'pending': 'Pending review',
  'trial': 'Trial',
  'standard': 'Standard',
};

/// [value], a connect form choice, as the section shows it: "html" ->
/// "HTML", "publish" -> "Published"; anything else as stored.
String connectionChoiceLabel(String value) => _choiceLabels[value.trim().toLowerCase()] ?? value.trim();

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

/// The group a connect form field's value belongs to, from what the field
/// asks for.
_Group _fieldGroup(ConnectField f) {
  final key = f.key.toLowerCase();
  if (key.contains('redirect') || key.contains('client') || key.contains('consumer') || key.contains('app_id') || key == 'appid' ||
      key == 'apiversion' || key == 'scopes' || key == 'apikey') {
    return _Group.app;
  }
  if (f.kind == FieldKind.url || f.kind == FieldKind.multiline) return _Group.place;
  if (f.kind == FieldKind.select || f.kind == FieldKind.boolean || f.kind == FieldKind.number || key == 'bid') return _Group.option;
  if (const {'username', 'handle', 'identifier', 'user_id', 'label', 'displayname', 'display_name'}.contains(key)) return _Group.identity;
  return _Group.target;
}

/// [value] as text, or null when it is not something to show (a map, a list
/// of objects, an empty string). [field] decides booleans, lists and choices;
/// [words] names known values.
String? _formatValue(Object? value, {ConnectField? field, Map<String, String>? words}) {
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
      if (field?.kind == FieldKind.select) return connectionChoiceLabel(t);
      return words?[t.toLowerCase()] ?? t;
    case List<Object?> l:
      if (l.isEmpty || l.any((e) => e is! String && e is! num)) return null;
      return l.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).join(field?.kind == FieldKind.multiline ? '\n' : ', ');
    default:
      return null;
  }
}

/// [s] without a leading "@" or "u/", lower case: how a handle is compared.
String _bareHandle(String s) => s.trim().toLowerCase().replaceFirst(RegExp(r'^(@|u/)'), '');

/// The user's part of a handle on a server: "robin" for "@robin@lemmy.example"
/// and "@robin:matrix.example"; null for a handle without a server part
/// ("@robin", "robin.bsky.social", whose dots belong to the domain).
String? _handleLocalPart(String bare) {
  final i = bare.indexOf(RegExp('[@:]'));
  return i <= 0 ? null : bare.substring(0, i);
}

/// Config values that hold a list written as one string with commas
/// (Facebook's permissions): shown as "a, b, c".
const Set<String> _commaListKeys = {'scopes'};

/// Matrix keeps its room as a name, an address and an id. Shown as one row:
/// "News (#news:matrix.example)", else the address, else the id.
String? _matrixRoom(Map<String, dynamic> config) {
  String? s(String k) {
    final v = '${config[k] ?? ''}'.trim();
    return v.isEmpty ? null : v;
  }

  final name = s('roomName'), alias = s('roomAlias'), id = s('roomId');
  if (name != null) return alias == null ? name : '$name ($alias)';
  return alias ?? id;
}

/// The non-secret setup of [account], labelled, grouped as [_Group] orders
/// them (within a group in the connect form's order). Every config key that
/// is a field of the form comes under that field's label (the account's own
/// way of connecting first, then the platform's other ways, so its wording
/// wins); then the reviewed extras in [_configLabels]; then how it signed
/// in.
///
/// A value [SecretGuard] flags keeps its row with [kWithheldValue], so the
/// row does not silently disappear. Left out: a value that only repeats what
/// the card already shows (its handle, the user part of it for a who-it-is
/// row, its display name), and a redirect address the user never registered.
List<ConnectionDetail> connectionDetails(ConnectedAccount account, PlatformAdapter? adapter, {Map<String, String> secrets = const {}}) {
  final guard = SecretGuard(secrets);
  final handle = account.handle == null ? null : _bareHandle(account.handle!);
  final localPart = handle == null ? null : _handleLocalPart(handle);
  final displayName = account.displayName.trim().toLowerCase();
  final specs = adapter?.connectSpecs ?? const <ConnectSpec>[];
  final fields = <String, ConnectField>{};
  for (final s in [...specs.where((s) => s.tier == account.tier), ...specs.where((s) => s.tier != account.tier)]) {
    for (final f in s.fields) {
      if (!f.secret) fields.putIfAbsent(f.key, () => f);
    }
  }

  final grouped = <(_Group, ConnectionDetail)>[];
  void add(_Group group, String label, String? value) {
    if (value == null) return;
    final bare = _bareHandle(value);
    if (handle != null && handle.isNotEmpty && bare == handle) return;
    if (group == _Group.identity && localPart != null && bare == localPart) return;
    if (displayName.isNotEmpty && value.trim().toLowerCase() == displayName) return;
    grouped.add((group, guard.reveals(value) ? ConnectionDetail.withheld(label, isKey: guard.isKey(value)) : ConnectionDetail(label, value)));
  }

  bool hidden(String key) => _redirectKeys.contains(key) && !_registersRedirect.contains(account.platformId);
  String? listed(String key, String? value) =>
      value != null && _commaListKeys.contains(key) ? value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).join(', ') : value;

  for (final f in fields.values) {
    if (!account.config.containsKey(f.key) || hidden(f.key)) continue;
    add(_fieldGroup(f), cleanFieldLabel(f.label), listed(f.key, _formatValue(account.config[f.key], field: f)));
  }
  for (final e in _configLabels.entries) {
    final only = e.value.only;
    if (fields.containsKey(e.key) || hidden(e.key) || (only != null && !only.contains(account.platformId))) continue;
    add(e.value.group, e.value.label, listed(e.key, _formatValue(account.config[e.key], words: e.value.values)));
  }
  if (account.platformId == 'matrix' && !account.config.containsKey('room')) add(_Group.target, 'Room', _matrixRoom(account.config));
  for (final k in _signInMethodKeys) {
    if (fields.containsKey(k)) continue;
    final method = _signInMethods['${account.config[k] ?? ''}'.trim()];
    if (method != null) {
      add(_Group.method, 'Sign-in method', method);
      break;
    }
  }
  // A stable sort: within a group the order above stays.
  final indexed = grouped.indexed.toList()..sort((a, b) => a.$2.$1.index != b.$2.$1.index ? a.$2.$1.index - b.$2.$1.index : a.$1 - b.$1);
  return [for (final (_, (_, d)) in indexed) d];
}

/// [e] in words; [when] writes a date and time. Says "when NEFORUM posts"
/// because that is the only time anything renews, "about" for a date worked out
/// from a rule, and "at the latest" where something else can end it first.
String signInText(SignInLifetime e, String Function(DateTime) when) {
  final note = e.note == null ? '' : ' ${e.note}';
  if (e.expiresAt == null) {
    final days = e.disuseWindow?.inDays;
    return switch (e.state) {
      SignInState.renews when e.usesCredential => 'Renews automatically while the app password is valid.',
      SignInState.renews => days == null ? 'Renews when NEFORUM posts. No end date is known.$note' : 'Renews when NEFORUM posts. It ends if nothing renews it for about $days days.$note',
      _ when e.renewsItself && days != null => 'Ends within $days days of its last renewal. The date shows after NEFORUM first renews it.$note',
      _ => switch (e.limit) {
            // The policy's own sentence says what can end it, where that is
            // not simply a revocation. A Nostr key has none at all.
            SignInLimit.none => e.note == null ? 'No end date. Ends only if revoked.' : 'No end date.$note',
            SignInLimit.idleUnknown => 'Ends after idle time.$note',
            SignInLimit.date => 'No date is known yet.$note',
            SignInLimit.undocumented => 'No published end date.$note',
          },
    };
  }
  final latest = e.earlyRevocationPossible ? ' at the latest' : '';
  final on = e.about ? 'about' : 'on';
  final at = '$on ${when(e.expiresAt!)}$latest';
  return switch (e.state) {
    SignInState.renewsUntil when e.about => 'Renews when NEFORUM posts. Unused, it ends $at.$note',
    SignInState.renewsUntil => 'Renews when NEFORUM posts, until ${when(e.expiresAt!)}$latest, then needs reconnecting.$note',
    SignInState.renewsWhenUsed => 'Renews when NEFORUM posts with it. Unused, it ends $at.$note',
    SignInState.ended when e.about => 'It probably ended about ${when(e.expiresAt!)}. If a post is refused, reconnect it.$note',
    SignInState.ended => 'Ended on ${when(e.expiresAt!)}. Needs reconnecting.$note',
    _ => 'Ends $at, then needs reconnecting.$note',
  };
}

/// The adapter a demo account stands in for, so questions about the real
/// platform (does it replace its keys on renewal?) get the real answer.
PlatformAdapter? _realAdapter(PlatformAdapter? a) => a is DemoAdapter ? a.inner : a;

/// [AccountConnection] for [account] from its config and [secrets] (which
/// are read for names, the expiry dates and [SecretGuard], never copied).
///
/// [keysUnreadable]: the keychain refused to answer for this account. Its
/// details are left out too, since [SecretGuard] cannot check them against
/// keys it could not read (the account card says the same).
///
/// [serverRead]: what the platform last said about this sign-in
/// ([SignInStatus.serverRead]). It goes into the date here as it does in the
/// status file, so the section and the closed card never disagree.
AccountConnection describeAccountConnection(
  ConnectedAccount account, {
  PlatformAdapter? adapter,
  Map<String, String> secrets = const {},
  required DateTime now,
  bool keysUnreadable = false,
  SignInServerRead? serverRead,
}) {
  final network = adapter?.descriptor.name ?? account.platformId;
  final real = _realAdapter(adapter);
  final needsKeys = connectionStoresKeys(account, real);
  return AccountConnection(
    network: network,
    tier: account.tier,
    method: connectionMethodText(account.tier, network),
    details: keysUnreadable ? const [] : connectionDetails(account, adapter, secrets: secrets),
    signIn: keysUnreadable || secrets.isEmpty || !(real?.signInPolicyFor(account).hasConnection ?? false)
        ? null
        : deriveSignInLifetime(real!.signInPolicyFor(account), secrets, now: now, serverRead: serverRead),
    storedKeys: keysUnreadable ? const [] : storedKeyLabels(secrets, adapter),
    needsKeys: needsKeys,
    noKeysReason: needsKeys ? null : _noKeysReason(account),
    connectedAt: account.createdAt,
    keysRotate: account.tier != PlatformTier.handoff && (real?.rotatesRefreshTokensFor(account) ?? false),
    demo: account.config['demo'] == true,
    keysUnreadable: keysUnreadable,
  );
}

/// The account as the copied setup names it: its display name, then its
/// handle unless the name already holds it. X stores "Robin (@robin)" and
/// Mastodon "Alice (mastodon.social)" as display names; these read "Robin
/// (@robin)" and "Alice (@alice@mastodon.social)", never the handle twice.
String connectionAccountName(ConnectedAccount account) {
  final name = account.displayName.trim();
  final handle = account.handle?.trim() ?? '';
  if (handle.isEmpty || name.toLowerCase().contains(handle.toLowerCase())) return name;
  final m = RegExp(r'^(.*\S)\s*\(([^()]+)\)$').firstMatch(name);
  if (m != null && handle.toLowerCase().contains(m[2]!.trim().toLowerCase())) return '${m[1]} ($handle)';
  return '$name ($handle)';
}

/// "Keys on this device" in one line, for the copied text.
String storedKeysLine(AccountConnection c, KeysTravel travel) {
  if (c.keysUnreadable) return 'Could not be read on this device';
  if (c.storedKeys.isNotEmpty) return '${c.storedKeys.join(', ')} (${keysTravelLabel(travel)})';
  if (c.demo) return 'None (demo account)';
  return c.keysMissing ? 'None stored on this device' : 'None needed';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// "2026-10-12": a day in the copied setup, the same on every device
/// whatever its clock format or time zone (the day in UTC).
String connectionCopyDate(DateTime t) {
  final u = t.toUtc();
  return '${u.year.toString().padLeft(4, '0')}-${_two(u.month)}-${_two(u.day)}';
}

/// "2026-11-07T12:00Z" (ISO 8601, UTC, to the minute): when a sign-in ends,
/// in the copied setup, the same on every device.
String connectionCopyMoment(DateTime t) {
  final u = t.toUtc();
  return '${connectionCopyDate(u)}T${_two(u.hour)}:${_two(u.minute)}Z';
}

/// The setup of [account] as plain text, to paste next to the same list
/// from another device: no key, password or token, only what the
/// Connection section shows. Written the same on every device: dates in UTC
/// as ISO 8601 ([connectionCopyDate], [connectionCopyMoment]), never in the
/// device's own clock format or time zone, so two devices that match produce
/// identical blocks. Which device it came from is [connectionCopyHeader]'s job.
String connectionSetupText(ConnectedAccount account, AccountConnection c, {required KeysTravel travel}) {
  return [
    '${c.network}: ${connectionAccountName(account)}',
    'How it posts: ${c.method}',
    for (final d in c.details) '${d.label}: ${d.value.replaceAll('\n', ', ')}',
    if (c.signIn != null) 'Sign-in: ${signInText(c.signIn!, connectionCopyMoment)}',
    'Keys on this device: ${storedKeysLine(c, travel)}',
    'Connected: ${connectionCopyDate(c.connectedAt)}',
  ].join('\n');
}

/// The first line of anything copied from the section, kept apart from the
/// account blocks by a blank line so the blocks compare cleanly:
/// "Setup copied from DESKTOP-AB12 (Windows) on 2026-11-01".
///
/// Its date is the device's own day ([connectionLocalDate]), the day the user
/// copied it: unlike the account blocks it names this device anyway, so it
/// need not match another device's.
String connectionCopyHeader(String deviceLabel, DateTime now) => 'Setup copied from $deviceLabel on ${connectionLocalDate(now)}';

/// "2026-11-01": [t]'s day on this device's clock.
String connectionLocalDate(DateTime t) {
  final l = t.toLocal();
  return '${l.year.toString().padLeft(4, '0')}-${_two(l.month)}-${_two(l.day)}';
}

/// This device as the copied setup names it, the way the sync settings list
/// devices: "DESKTOP-AB12 (Windows)", or just the platform when the host
/// name is unknown.
String connectionDeviceLabel() {
  final host = deviceHostName();
  return host.isEmpty ? Env.platformName : '$host (${Env.platformName})';
}

/// [connectionDeviceLabel], replaceable in tests.
final connectionDeviceLabelProvider = Provider<String>((ref) => connectionDeviceLabel());

/// Where the section reads the keychain from: the app's secret store,
/// replaceable in tests (a store that fails).
final connectionSecretsProvider = Provider<SecretStore>((ref) => ref.watch(servicesProvider).secrets);

/// [AccountConnection] for one account, read when its Connection section is
/// open. autoDispose: every opening reads the keychain again (a renewed
/// sign-in shows its new date), and nothing is kept once it is closed. The
/// secrets map lives only inside this function.
///
/// A failed read is not retried in the background (Riverpod retries by
/// default): a locked keychain can answer with a system prompt, and the
/// section already says it could not read the keys. Closing and opening the
/// section reads again.
final accountConnectionProvider = FutureProvider.autoDispose.family<AccountConnection?, String>(
  (ref, accountId) async {
    final account = ref.watch(accountByIdProvider(accountId));
    if (account == null) return null;
    final registry = ref.watch(registryProvider);
    final statuses = ref.watch(servicesProvider).signInStatusStore;
    final secrets = await ref.watch(connectionSecretsProvider).read(accountId) ?? const <String, String>{};
    final status = await statuses.get(accountId);
    return describeAccountConnection(account, adapter: registry.byId(account.platformId), secrets: secrets, now: DateTime.now(), serverRead: status?.serverRead);
  },
  retry: (_, _) => null,
);

/// Every account's [SignInStatus] on this device, as of the last write, read
/// with no keychain prompt: for closed cards, warnings and the schedule sheet.
/// Empties on Delete everything. A date passes with no write, so ask
/// [SignInStatus.hasEnded] and [SignInStatus.endsSoon] rather than its state.
final signInStatusesProvider = StreamProvider<Map<String, SignInStatus>>((ref) async* {
  final store = ref.watch(servicesProvider).signInStatusStore;
  yield await store.all();
  await for (final _ in store.changes) {
    yield await store.all();
  }
});

/// "Copy all setups" on the Accounts page: [connectionCopyHeader], then
/// every account's [connectionSetupText] in [accounts]' order, separated by
/// blank lines. An account whose keys the keychain will not read still gets
/// its block, saying so ([AccountConnection.keysUnreadable]), and is counted
/// in [unreadable] so the page can tell the user.
///
/// A read that takes longer than [readTimeout] (a keychain prompt nobody
/// answers) sets [timedOut]: that account and every one after it are marked
/// unread without asking the keychain again, so a stuck keychain costs one
/// wait, not one per account.
///
/// [statuses]: this device's [SignInStatus] by account, for what each platform
/// last said, so a block reads as the Connection section does.
Future<({String text, int unreadable, bool timedOut})> allConnectionSetupsText(
  List<ConnectedAccount> accounts, {
  required SecretStore secrets,
  required AdapterRegistry registry,
  required KeysTravel travel,
  required String deviceLabel,
  DateTime? now,
  Duration readTimeout = const Duration(seconds: 15),
  Map<String, SignInStatus> statuses = const {},
}) async {
  final at = now ?? DateTime.now();
  final parts = <String>[connectionCopyHeader(deviceLabel, at)];
  var unreadable = 0;
  var timedOut = false;
  for (final a in accounts) {
    final adapter = registry.byId(a.platformId);
    AccountConnection c;
    try {
      if (timedOut) throw TimeoutException('keychain did not answer');
      c = describeAccountConnection(a, adapter: adapter, secrets: await secrets.read(a.id).timeout(readTimeout) ?? const {}, now: at, serverRead: statuses[a.id]?.serverRead);
    } on Object catch (e) {
      // Never the error itself: it could quote what the keychain returned.
      if (e is TimeoutException) timedOut = true;
      unreadable++;
      c = describeAccountConnection(a, adapter: adapter, now: at, keysUnreadable: true);
    }
    parts.add(connectionSetupText(a, c, travel: travel));
  }
  return (text: parts.join('\n\n'), unreadable: unreadable, timedOut: timedOut);
}
