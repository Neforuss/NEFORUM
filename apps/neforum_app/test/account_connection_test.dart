// 1.3.5: Accounts > Connection. Every account card shows how the account is
// set up (server, own app, targets, when the sign-in ends, which keys are
// stored and whether sync carries them) so two devices can be compared, and
// never shows a key, not even part of one.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/browser_bridge.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/account_connection.dart';
import 'package:neforum_app/state/cloud_sync.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/accounts/account_card.dart';
import 'package:neforum_app/ui/accounts/connection_section.dart';
import 'package:neforum_app/ui/activity/target_chip.dart';
import 'package:neforum_app/ui/activity/time_format.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/ui/settings/data_section.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  _MemoryStorage(Map<String, Object> settings) : _json = {'settings.json': settings};
  final Map<String, Object> _json;
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}

/// The characters every fake secret is made of: upper-case consonants and
/// digits 2 to 9. Labels, addresses and the demo's own text are lower case,
/// carry vowels, or use 0 and 1, so any 4 of these characters in a row on
/// screen or on the clipboard can only have come from a key.
const String _fakeAlphabet = 'BCDFGHJKLMNPQRSTVWXZ23456789';

class _Fakes {
  final Random _r = Random(20261101);
  String next() => 'Q${List.generate(31, (_) => _fakeAlphabet[_r.nextInt(_fakeAlphabet.length)]).join()}';
}

final DateTime _connected = DateTime.utc(2026, 10, 12, 9, 30);

/// What `signInExpiry` was until 1.4: it knew nothing about the platform, only
/// what is stored. Its cases below are kept as they were, as proof that the
/// model answers the same for a platform with no window and no deadline.
SignInLifetime? signInExpiry(Map<String, String> secrets, {required DateTime now}) {
  final life = deriveSignInLifetime(const SignInPolicy(limit: SignInLimit.undocumented, renewal: SignInRenewal.onUse), secrets, now: now);
  return life.state == SignInState.noDate ? null : life;
}
String _iso(DateTime t) => t.toUtc().toIso8601String();

/// Fails when any of [shown] holds 4 characters in a row of a stored key's
/// secret material (any run of [_fakeAlphabet] characters inside a fake key;
/// the rest of a structured key, such as the "https://discord.com/api/"
/// around a webhook token, is public and shared by every user). Expiry dates
/// are bookkeeping, not secrets, and are only checked whole, as stored.
void _expectNoSecretShown(Iterable<String> shown, Iterable<Map<String, String>> secretMaps) {
  final windows = <String, String>{};
  final dates = <String>{};
  final material = RegExp('[$_fakeAlphabet]{4,}');
  for (final secrets in secretMaps) {
    for (final e in secrets.entries) {
      if (kSecretBookkeepingKeys.contains(e.key)) {
        if (DateTime.tryParse(e.value) != null) dates.add(e.value);
        continue;
      }
      for (final m in material.allMatches(e.value)) {
        final run = m[0]!;
        for (var i = 0; i + 4 <= run.length; i++) {
          windows[run.substring(i, i + 4)] = e.key;
        }
      }
    }
  }
  for (final text in shown) {
    for (var i = 0; i + 4 <= text.length; i++) {
      final key = windows[text.substring(i, i + 4)];
      if (key != null) fail('Shows part of a stored "$key": "$text"');
    }
    for (final d in dates) {
      if (text.contains(d)) fail('Shows a stored expiry as stored: "$text"');
    }
  }
}

/// A plausible value for [f] on [a], all lower case.
Object _fakeValue(PlatformAdapter a, ConnectField f) => switch (f.kind) {
      FieldKind.url => 'https://${a.id.replaceAll('_', '-')}.example/${f.key.toLowerCase()}',
      FieldKind.boolean => true,
      FieldKind.select => f.options!.first,
      FieldKind.number => 7,
      FieldKind.multiline => ['wss://relay-one.example', 'wss://relay-two.example'],
      _ => 'fake-${f.key.toLowerCase()}',
    };

/// What the section shows for [_fakeValue] of [f].
String _shownValue(ConnectField f, Object v) => switch (f.kind) {
      FieldKind.boolean => 'Yes',
      FieldKind.multiline => (v as List<String>).join('\n'),
      FieldKind.select => connectionChoiceLabel('$v'),
      _ => '$v',
    };

/// One account per built-in adapter and per way it connects, its config
/// filled from that way's connect form and its secrets from the form's
/// secret fields (nothing invented): proves every form field shows under its
/// own label. How the adapters really store an account is [_realAccounts].
List<(ConnectedAccount, Map<String, String>, ConnectSpec)> _formAccounts(_Fakes fakes) => [
      for (final a in builtinAdapters())
        for (final spec in a.connectSpecs)
          (
            ConnectedAccount(
              id: 'form-${a.id}-${spec.tier.name}',
              platformId: a.id,
              tier: spec.tier,
              displayName: 'form ${a.id} ${spec.tier.name.toLowerCase()}',
              handle: '@form-${a.id}',
              createdAt: _connected,
              config: {for (final f in spec.fields) if (!f.secret) f.key: _fakeValue(a, f)},
            ),
            {for (final f in spec.fields) if (f.secret) f.key: fakes.next()},
            spec,
          ),
    ];

/// An account the way its adapter's `connect()` stores it (config keys,
/// secret keys, which expiry dates), with what the section must show.
class _Real {
  _Real(this.account, this.secrets, {required this.keys, this.sign, this.soon = false, this.show = const [], this.hide = const [], this.needsKeys = true});
  final ConnectedAccount account;
  final Map<String, String> secrets;
  final List<String> keys;
  final SignInState? sign;
  final bool soon;
  final List<String> show;
  final List<String> hide;
  final bool needsKeys;
}

ConnectedAccount _acct(String platformId, PlatformTier tier, Map<String, dynamic> config, {String? id, String name = 'Robin', String? handle}) =>
    ConnectedAccount(id: id ?? 'real-$platformId-${tier.name}', platformId: platformId, tier: tier, displayName: name, handle: handle, createdAt: _connected, config: config);

/// Every way of posting through an API, as the adapters' `connect()` and
/// `refreshSecrets()` store it (read from each adapter, 1.3.5). [now] dates
/// the tokens.
List<_Real> _realAccounts(_Fakes f, DateTime now) {
  const loopback = 'http://127.0.0.1:52771/callback';
  Map<String, String> oauth({Duration? expiresIn, bool refresh = false, Duration? refreshIn, String type = 'Bearer', Map<String, String> extra = const {}}) => {
        OAuthTokens.keyAccessToken: f.next(),
        if (refresh) OAuthTokens.keyRefreshToken: f.next(),
        if (expiresIn != null) OAuthTokens.keyExpiresAt: _iso(now.add(expiresIn)),
        OAuthTokens.keyTokenType: type,
        if (refreshIn != null) StoredSecretKeys.refreshExpiresAt: _iso(now.add(refreshIn)),
        ...extra,
      };
  Map<String, String> oauth1() => OAuth1Credentials(consumerKey: f.next(), consumerSecret: f.next(), token: f.next(), tokenSecret: f.next()).toSecrets();
  const oauth1Keys = ['Consumer key (API key)', 'Consumer secret (API key secret)', 'OAuth 1.0a access token', 'OAuth 1.0a access token secret'];
  final tumblrKey = f.next();
  return [
    _Real(
      _acct('mastodon', PlatformTier.openApi, {
        'instance': 'https://mastodon.example', 'domain': 'mastodon.example', 'software': 'mastodon', 'softwareVersion': '4.3.0', 'title': 'Mastodon Example',
        'maxCharacters': 500, 'supportedMimeTypes': ['image/png'], 'apiVersion': 2, 'remoteAccountId': '1093', 'scopes': 'profile write',
        'redirectUri': loopback, 'tokenEndpoint': 'https://mastodon.example/oauth/token',
      }, name: 'Robin (mastodon.example)', handle: '@robin@mastodon.example'),
      oauth(extra: {'client_id': f.next(), StoredSecretKeys.clientSecret: f.next(), OAuthTokens.keyScope: 'profile write'}),
      keys: ['Access token', 'Client ID', 'Client secret'],
      show: ['Server address: https://mastodon.example', 'Server software: Mastodon'],
      hide: ['Redirect URI'],
    ),
    _Real(
      _acct('pixelfed', PlatformTier.openApi, {'instance': 'https://pixelfed.example', 'domain': 'pixelfed.example', 'software': 'pixelfed', 'redirectUri': loopback},
          handle: '@robin@pixelfed.example'),
      oauth(extra: {'client_id': f.next(), StoredSecretKeys.clientSecret: f.next()}),
      keys: ['Access token', 'Client ID', 'Client secret'],
      show: ['Server address: https://pixelfed.example', 'Server software: Pixelfed'],
      hide: ['Redirect URI'],
    ),
    _Real(
      _acct('bluesky', PlatformTier.openApi, {'did': 'did:plc:robin4example', 'handle': 'robin.bsky.example', 'pds': 'https://pds.example.net', 'service': 'https://bsky.social'},
          handle: '@robin.bsky.example'),
      oauth(expiresIn: const Duration(hours: 2), refresh: true, extra: {StoredSecretKeys.appPassword: f.next()}),
      keys: ['Access token', 'Refresh token', 'App password'],
      sign: SignInState.renews,
      show: ['Hosting provider: https://bsky.social', 'PDS (data server): https://pds.example.net', 'Account ID (DID): did:plc:robin4example'],
      hide: ['Handle'],
    ),
    _Real(
      _acct('misskey', PlatformTier.openApi, {
        'instance': 'https://misskey.example', 'host': 'misskey.example', 'authMethod': 'miauth', 'instanceName': 'Misskey Example', 'version': '2024.11.0',
        'maxNoteTextLength': 3000, 'canPublicNote': true, 'uploadableFileTypes': ['image/*'], 'miauth': true, 'userId': 'u1', 'username': 'robin',
      }, handle: '@robin@misskey.example'),
      oauth(type: 'Misskey', extra: {OAuthTokens.keyScope: 'write:notes,write:drive'}),
      keys: ['Access token'],
      show: ['Instance: https://misskey.example', 'Sign-in method: Browser sign-in (MiAuth)'],
    ),
    _Real(
      _acct('nostr', PlatformTier.openApi, {'pubkey': 'a1b2c3d4e5', 'npub': 'npub1robinexample', 'relays': ['wss://relay.one.example', 'wss://relay.two.example']}),
      {StoredSecretKeys.privateKey: f.next()},
      keys: ['Private key'],
      show: ['Relays: wss://relay.one.example\nwss://relay.two.example', 'Public key (npub): npub1robinexample'],
    ),
    _Real(
      _acct('lemmy', PlatformTier.openApi, {
        'instance': 'https://lemmy.example', 'host': 'lemmy.example', 'username': 'robin', 'authMethod': 'password', 'personId': 7, 'siteName': 'Lemmy Example',
        'version': '0.19.5', 'languages': {'en': 37}, 'community': 'technology', 'communityId': 3, 'communityTitle': 'Technology',
      }, handle: '@robin@lemmy.example'),
      oauth(),
      keys: ['Access token'],
      show: ['Instance: https://lemmy.example', 'Site name: Lemmy Example', 'Default community: technology', 'Sign-in method: Password'],
      hide: ['Username or email'],
    ),
    _Real(
      _acct('matrix', PlatformTier.openApi, {
        'homeserver': 'https://matrix.example', 'userId': '@robin:matrix.example', 'deviceId': 'DEVICE', 'roomId': '!room:matrix.example',
        'roomAlias': '#news:matrix.example', 'roomName': 'News', 'authMethod': 'password', 'maxUploadBytes': 52428800, 'formatting': 'markdown',
      }),
      oauth(expiresIn: const Duration(minutes: 5), refresh: true),
      keys: ['Access token', 'Refresh token'],
      sign: SignInState.renews,
      show: ['Homeserver: https://matrix.example', 'Room: News (#news:matrix.example)', 'Formatting: Markdown', 'Sign-in method: Password'],
      hide: ['Room address', 'Room ID'],
    ),
    _Real(
      _acct('x', PlatformTier.byokApi, {'authMode': 'oauth2', 'clientId': 'x-client-id', 'confidentialClient': false, 'userId': '1234'},
          id: 'real-x-oauth2', name: 'Robin (@robinmakes)', handle: '@robinmakes'),
      oauth(expiresIn: const Duration(hours: 2), refresh: true, extra: {OAuthTokens.keyScope: 'tweet.write offline.access'}),
      keys: ['Access token', 'Refresh token'],
      sign: SignInState.renewsUntil, // About 6 months after the last renewal.
      show: ['Client ID: x-client-id', 'Sign-in method: Browser sign-in (OAuth 2.0)'],
    ),
    _Real(
      _acct('x', PlatformTier.byokApi, {'authMode': 'oauth1', 'userId': '1234'}, id: 'real-x-oauth1', name: 'Robin (@robinmakes)', handle: '@robinmakes'),
      oauth1(),
      keys: oauth1Keys,
      sign: SignInState.endsOn, // X retires OAuth 1.0a on 2027-01-31.
      soon: false,
      show: ['Sign-in method: OAuth 1.0a keys'],
    ),
    _Real(
      _acct('threads', PlatformTier.byokApi, {
        'app_id': '1234567', 'redirect_uri': 'https://127.0.0.1:52771/callback', 'token_source': 'oauth', 'user_id': '99', 'username': 'robinmakes',
      }, handle: '@robinmakes'),
      oauth(expiresIn: const Duration(days: 50), extra: {StoredSecretKeys.appSecret: f.next(), StoredSecretKeys.tokenIssuedAt: _iso(now.subtract(const Duration(days: 10)))}),
      keys: ['Access token', 'App secret'],
      sign: SignInState.renewsWhenUsed,
      show: ['Threads app ID: 1234567', 'Redirect URI you registered: https://127.0.0.1:52771/callback', 'Sign-in method: Browser sign-in'],
      hide: ['Threads username'],
    ),
    _Real(
      _acct('facebook', PlatformTier.byokApi, {
        'app_id': '5551234', 'page_id': '777', 'page_name': 'Robin Studio', 'user_id': '42', 'user_name': 'Robin',
        'available_pages': [
          {'id': '778', 'name': 'Other Page'},
        ],
        'scopes': 'pages_manage_posts,pages_read_engagement',
      }, handle: 'Robin Studio'),
      oauth(extra: {StoredSecretKeys.appSecret: f.next(), StoredSecretKeys.userAccessToken: f.next(), StoredSecretKeys.userTokenExpiresAt: _iso(now.add(const Duration(days: 50)))}),
      keys: ['Access token', 'App secret', 'User access token'],
      show: ['App ID: 5551234', 'Permissions: pages_manage_posts, pages_read_engagement'],
      hide: ['Page'],
    ),
    _Real(
      _acct('linkedin', PlatformTier.byokApi, {'clientId': '86clientid', 'apiVersion': '202610', 'sub': 'abc', 'personUrn': 'urn:li:person:abc', 'redirectUri': loopback}),
      oauth(expiresIn: const Duration(days: 40), extra: {StoredSecretKeys.clientSecret: f.next()}),
      keys: ['Access token', 'Client secret'],
      sign: SignInState.endsOn,
      show: ['Client ID: 86clientid', 'LinkedIn API version: 202610', 'Redirect URI: $loopback'],
    ),
    _Real(
      _acct('reddit', PlatformTier.byokApi, {'clientId': 'reddit-client', 'username': 'robin', 'userId': 't2_x', 'defaultSubreddit': 'pics', 'uaPlatform': 'windows'},
          handle: 'u/robin'),
      oauth(expiresIn: const Duration(hours: 1), refresh: true),
      keys: ['Access token', 'Refresh token'],
      sign: SignInState.renews,
      show: ['Client ID: reddit-client', 'Default subreddit: pics'],
      hide: ['Your Reddit username'],
    ),
    _Real(
      _acct('tumblr', PlatformTier.byokApi, {
        'consumerKey': 'tumblr-consumer-key', 'blogName': 'robinblog', 'blogUuid': 't:abc', 'blogUrl': 'https://robinblog.tumblr.example/', 'userName': 'robin',
        'blogNames': ['robinblog', 'other'], 'authMode': 'oauth2', 'redirectUri': loopback,
      }, id: 'real-tumblr-oauth2'),
      oauth(expiresIn: const Duration(minutes: 40), refresh: true, extra: {StoredSecretKeys.consumerSecret: f.next()}),
      keys: ['Access token', 'Refresh token', 'Consumer secret'],
      sign: SignInState.renewsUntil, // About 42 days after the last renewal.
      show: ['OAuth Consumer Key: tumblr-consumer-key', 'Redirect URI: $loopback', 'Blog: robinblog', 'Sign-in method: Browser sign-in (OAuth 2.0)'],
    ),
    // OAuth 1.0a keeps the consumer key in the config AND with the keys:
    // only the guard keeps it off the card.
    _Real(
      _acct('tumblr', PlatformTier.byokApi, {'consumerKey': tumblrKey, 'blogName': 'guardblog', 'authMode': 'oauth1'}, id: 'real-tumblr-oauth1'),
      OAuth1Credentials(consumerKey: tumblrKey, consumerSecret: f.next(), token: f.next(), tokenSecret: f.next()).toSecrets(),
      keys: oauth1Keys,
      show: ['OAuth Consumer Key: $kStoredKeyValue', 'Blog: guardblog', 'Sign-in method: OAuth 1.0a keys'],
    ),
    _Real(
      _acct('instagram', PlatformTier.byokApi, {
        'tokenSource': 'oauth', 'appId': '9876', 'redirectUri': 'https://127.0.0.1:52771/callback', 'igUserId': '1789', 'username': 'robin.makes', 'accountType': 'BUSINESS',
      }, handle: '@robin.makes'),
      oauth(expiresIn: const Duration(days: 55), extra: {StoredSecretKeys.refreshedAt: _iso(now.subtract(const Duration(days: 5)))}),
      keys: ['Access token'],
      sign: SignInState.renewsWhenUsed,
      show: ['App ID: 9876', 'Redirect URI: https://127.0.0.1:52771/callback', 'Sign-in method: Browser sign-in'],
      hide: ['Instagram username'],
    ),
    _Real(
      _acct('tiktok', PlatformTier.byokApi, {'clientKey': 'tiktok-client-key', 'openId': 'oid'}),
      oauth(expiresIn: const Duration(hours: 20), refresh: true, refreshIn: const Duration(days: 4), extra: {StoredSecretKeys.openId: 'oid', StoredSecretKeys.clientSecret: f.next()}),
      keys: ['Access token', 'Refresh token', 'Client secret'],
      sign: SignInState.renewsUntil,
      soon: true,
      show: ['Client key: tiktok-client-key'],
    ),
    // A Google app in "Testing": the refresh token itself ends after 7 days.
    _Real(
      _acct('youtube', PlatformTier.byokApi, {'clientId': 'yt.apps.example', 'channelId': 'UCrobin', 'redirectUri': loopback, 'canDeleteVideos': true}),
      oauth(expiresIn: const Duration(minutes: 50), refresh: true, refreshIn: const Duration(days: 6), extra: {StoredSecretKeys.clientSecret: f.next()}),
      keys: ['Access token', 'Refresh token', 'Client secret'],
      sign: SignInState.renewsUntil,
      soon: true,
      show: ['Client ID: yt.apps.example', 'Channel ID: UCrobin'],
      hide: ['Redirect URI'],
    ),
    _Real(
      _acct('pinterest', PlatformTier.byokApi, {
        'appId': '1500', 'boardId': '88', 'boardName': 'Ideas', 'username': 'robin', 'accountType': 'BUSINESS', 'accessLevel': 'trial',
        'redirectUri': 'http://localhost:52771/callback',
      }),
      oauth(expiresIn: const Duration(days: 30), refresh: true, refreshIn: const Duration(days: 365), extra: {StoredSecretKeys.appSecret: f.next()}),
      keys: ['Access token', 'Refresh token', 'App secret'],
      sign: SignInState.renewsUntil,
      show: ['App ID: 1500', 'Redirect URI: http://localhost:52771/callback', 'Board: Ideas', 'Access level of your app: Trial'],
    ),
    // Posts through the LBRY app on this device: no keys at all.
    _Real(
      _acct('odysee', PlatformTier.openApi, {'daemon': 'http://localhost:5279', 'bid': '0.001', 'channelId': 'c0ffee', 'channelName': '@robin'}, handle: '@robin'),
      const {},
      keys: const [],
      needsKeys: false,
      show: ['LBRY SDK address: http://localhost:5279', 'Channel ID: c0ffee', 'Deposit per upload (LBC): 0.001'],
    ),
    _Real(
      _acct('telegram', PlatformTier.openApi, {
        'chatId': -1002233445566, 'chatType': 'channel', 'chatTitle': 'Robin News', 'chatUsername': 'robinnews', 'botId': 7700112233, 'botUsername': 'robin_bot',
        'formatting': 'markdown',
      }, name: 'Robin News', handle: '@robinnews'),
      {'bot_token': '7700112233:${f.next()}'},
      keys: ['Bot token'],
      show: ['Bot: robin_bot', 'Formatting: Markdown'],
      hide: ['Channel or group', 'Channel or group username'],
    ),
    _Real(
      _acct('discord', PlatformTier.openApi, {
        'webhookId': '1180000000000000001', 'webhookName': 'neforum hook', 'channelId': '1170000000000000003', 'guildId': '1160000000000000004',
        'threadId': '1190000000000000002', 'username': 'Robin', 'forum': false,
      }, name: 'neforum hook (Discord webhook)'),
      {'webhook_url': 'https://discord.com/api/webhooks/1180000000000000001/${f.next()}?thread_id=1190000000000000002'},
      keys: ['Webhook URL'],
      show: ['Webhook: neforum hook', 'Post as: Robin', 'Forum or media channel: No'],
    ),
    _Real(
      _acct('wordpress', PlatformTier.openApi, {
        'site': 'https://blog.example', 'home': 'https://blog.example', 'restBase': 'https://blog.example/wp-json/', 'username': 'robin', 'siteName': 'Robin Blog',
        'userId': 1, 'canPublish': true, 'canUpload': true, 'canManageTerms': true, 'defaultStatus': 'publish',
      }, name: 'Robin (Robin Blog)', handle: 'robin'),
      {StoredSecretKeys.appPassword: f.next()},
      keys: ['App password'],
      show: ['Site address: https://blog.example', 'Site name: Robin Blog', 'Publish as: Published'],
      hide: ['WordPress username'],
    ),
    _Real(
      _acct('ghost', PlatformTier.openApi, {
        'apiUrl': 'https://ghost.example', 'site': 'https://ghost.example', 'siteTitle': 'Robin Writes', 'keyId': 'k3yidf9e8d7c6b5', 'version': '5.0', 'defaultStatus': 'draft',
      }),
      {'admin_api_key': 'k3yidf9e8d7c6b5:${f.next()}'},
      keys: ['Admin API key'],
      show: ['API URL: https://ghost.example', 'Site address: https://ghost.example', 'Site name: Robin Writes', 'Publish as: Draft'],
    ),
    _Real(
      _acct('writefreely', PlatformTier.openApi, {
        'instance': 'https://write.example', 'username': 'robin', 'alias': 'robinwrites', 'collectionUrl': 'https://write.example/robinwrites/',
        'collectionTitle': 'Robin Writes', 'snapAs': true,
      }),
      oauth(type: 'Token'),
      keys: ['Access token'],
      show: ['Server: https://write.example', 'Blog: Robin Writes', 'Blog alias: robinwrites', 'Upload images to Snap.as: Yes'],
    ),
    _Real(
      _acct('micropub', PlatformTier.openApi, {
        'me': 'https://robin.example/', 'micropubEndpoint': 'https://robin.example/micropub', 'mediaEndpoint': 'https://robin.example/media',
        'authMethod': 'indieauth', 'clientId': 'https://neforum.example/', 'authorizationEndpoint': 'https://robin.example/auth',
        'tokenEndpoint': 'https://robin.example/token', 'issuer': 'https://robin.example/', 'microblog': false,
        'syndicateTargets': [
          {'uid': 'x', 'name': 'X'},
        ],
        'destinations': <Object>[], 'postTypes': ['note'],
      }),
      oauth(expiresIn: const Duration(hours: 1), refresh: true),
      keys: ['Access token', 'Refresh token'],
      sign: SignInState.renews,
      show: ['Your site URL (me): https://robin.example/', 'Micropub endpoint: https://robin.example/micropub', 'Client ID: https://neforum.example/',
        'Sign-in method: Browser sign-in (IndieAuth)'],
    ),
    _Real(
      _acct('devto', PlatformTier.openApi, {'base': 'https://dev.example', 'userId': 5, 'username': 'robin'}),
      oauth(type: 'api-key'),
      keys: ['Access token'],
      show: ['Forem community: https://dev.example'],
    ),
    _Real(
      _acct('hashnode', PlatformTier.byokApi, {
        'publicationId': 'pub1', 'publicationUrl': 'https://robin.hashnode.example', 'publicationTitle': 'Robin Notes', 'username': 'robin', 'userId': 'u1',
      }),
      oauth(type: 'PAT'),
      keys: ['Access token'],
      show: ['Blog: Robin Notes', 'Blog address: https://robin.hashnode.example'],
    ),
    _Real(
      _acct('deviantart', PlatformTier.byokApi, {'clientId': '12345', 'redirectUri': loopback, 'userId': 'u-1'}),
      oauth(expiresIn: const Duration(hours: 1), refresh: true, extra: {StoredSecretKeys.clientSecret: f.next()}),
      keys: ['Access token', 'Refresh token', 'Client secret'],
      sign: SignInState.renewsUntil, // About 3 months after the last renewal.
      show: ['Client ID: 12345', 'Redirect URI: $loopback'],
    ),
    _Real(
      _acct('dribbble', PlatformTier.byokApi, {'clientId': 'dribbble-client', 'redirectUri': loopback, 'canUploadShot': true}),
      oauth(),
      keys: ['Access token'],
      show: ['Client ID: dribbble-client', 'Redirect URI: $loopback'],
    ),
    _Real(
      _acct('flickr', PlatformTier.byokApi, {'userNsid': '123@N01', 'username': 'robin'}),
      oauth1(),
      keys: oauth1Keys,
    ),
    _Real(
      _acct('inkbunny', PlatformTier.openApi, {'username': 'robin', 'userId': '77'}, handle: '@robin'),
      {StoredSecretKeys.sessionId: f.next()},
      keys: ['Session'],
      hide: ['Username'],
    ),
  ];
}

Future<(ProviderContainer, AppServices)> _pumpAccounts(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  Map<String, Object> settings = const {},
  List<(ConnectedAccount, Map<String, String>)> accounts = const [],
  bool keepDemoAccounts = true,
  SecretStore Function(AppServices s)? secretStore,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = (await tester.runAsync(() async {
    final s = await AppServices.create(demo: true, storage: _MemoryStorage({'themeMode': 'light', ...settings}));
    if (!keepDemoAccounts) {
      for (final a in await s.accounts.all()) {
        await s.accounts.delete(a.id);
      }
    }
    for (final (a, secrets) in accounts) {
      await s.accounts.upsert(a);
      if (secrets.isNotEmpty) await s.secrets.write(a.id, secrets);
    }
    return s;
  }))!;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      servicesProvider.overrideWithValue(services),
      connectionDeviceLabelProvider.overrideWithValue('Test device'),
      if (secretStore != null) connectionSecretsProvider.overrideWithValue(secretStore(services)),
    ],
    child: const NeforumApp(),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  container.read(routerProvider).go('/accounts');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return (container, services);
}

/// A keychain prompt nobody answers: every read waits forever.
class _HangingSecretStore extends SecretStore {
  int reads = 0;
  @override
  Future<Map<String, String>?> read(String accountId) {
    reads++;
    return Completer<Map<String, String>?>().future;
  }

  @override
  Future<void> write(String accountId, Map<String, String> secrets) async {}
  @override
  Future<void> delete(String accountId) async {}
}

/// A keychain that answers only once [open] is called, or never when [hang].
class _GatedSecretStore extends SecretStore {
  late SecretStore inner;
  final Completer<void> _gate = Completer<void>();
  bool hang = false;
  int reads = 0;
  void open() => _gate.complete();
  @override
  Future<Map<String, String>?> read(String accountId) async {
    reads++;
    if (hang) return Completer<Map<String, String>?>().future;
    await _gate.future;
    return inner.read(accountId);
  }

  @override
  Future<void> write(String accountId, Map<String, String> secrets) => inner.write(accountId, secrets);
  @override
  Future<void> delete(String accountId) => inner.delete(accountId);
}

/// A keychain that refuses to answer for some accounts, as a locked macOS
/// keychain or a failing Windows Credential Manager does.
class _FailingSecretStore extends SecretStore {
  _FailingSecretStore(this.inner, this.failFor);
  final SecretStore inner;
  final Set<String> failFor;
  @override
  Future<Map<String, String>?> read(String accountId) async =>
      failFor.contains(accountId) ? throw StateError('keychain locked: SECRETINERROR') : inner.read(accountId);
  @override
  Future<void> write(String accountId, Map<String, String> secrets) => inner.write(accountId, secrets);
  @override
  Future<void> delete(String accountId) => inner.delete(accountId);
}

Finder _card(String accountId) => find.byWidgetPredicate((w) => w is AccountCard && w.account.id == accountId);

/// Scrolls [target] to the middle of the page, clear of the tab bar, taps
/// it, and lets the section finish opening (its keys load, it grows), so the
/// next target is where the next tap looks for it.
Future<void> _tap(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _open(WidgetTester tester, String accountId) => _tap(tester, find.descendant(of: _card(accountId), matching: find.text('Connection')));

/// Every string the widget tree shows or would read out: text, rich text,
/// field contents, tooltips and semantics labels.
List<String> _shownStrings(WidgetTester tester) {
  final out = <String>[];
  for (final e in find.byWidgetPredicate((_) => true, skipOffstage: false).evaluate()) {
    switch (e.widget) {
      case RichText w:
        out.add(w.text.toPlainText());
      case Text w:
        out.add(w.data ?? w.textSpan?.toPlainText() ?? '');
      case EditableText w:
        out.add(w.controller.text);
      case Tooltip w:
        out.addAll([w.message ?? '', w.richMessage?.toPlainText() ?? '']);
      case Semantics w:
        out.addAll([w.properties.label ?? '', w.properties.value ?? '', w.properties.hint ?? '', w.properties.tooltip ?? '']);
    }
  }
  return out.where((s) => s.isNotEmpty).toList();
}

/// Captures what the app puts on the clipboard.
List<String> _captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

ConnectedAccount _account(String platformId, PlatformTier tier, Map<String, dynamic> config, {String id = 'acct'}) =>
    ConnectedAccount(id: id, platformId: platformId, tier: tier, displayName: 'Someone', handle: '@someone', createdAt: _connected, config: config);

PlatformAdapter _adapter(String id) => builtinRegistry().require(id);

void main() {
  final now = DateTime.utc(2026, 11, 1, 12);
  String when(DateTime t) => '${t.day}/${t.month}/${t.year}';

  group('labels', () {
    test('a config key that is a connect field is shown under the field label, without the form hint', () {
      final details = connectionDetails(
        _account('mastodon', PlatformTier.openApi, {'instance': 'https://mastodon.example', 'client_id': 'own-client', 'maxCharacters': 500}),
        _adapter('mastodon'),
      );
      expect(details.map((d) => '$d'), ['Server address: https://mastodon.example', 'Client ID: own-client']);
      expect(cleanFieldLabel('Client ID (advanced, optional)'), 'Client ID');
      expect(cleanFieldLabel('Redirect URI (advanced)'), 'Redirect URI');
      expect(cleanFieldLabel('Two-factor code (if enabled)'), 'Two-factor code');
      expect(cleanFieldLabel('Private key (nsec)'), 'Private key (nsec)', reason: 'a parenthesis that names the thing stays');
      expect(cleanFieldLabel('Media server (NIP-96)'), 'Media server (NIP-96)');
    });

    test('keys the form does not ask for come from the reviewed list; caches, ids and limits are left out', () {
      final misskey = connectionDetails(
        _account('misskey', PlatformTier.openApi, {
          'instance': 'https://misskey.example',
          'host': 'misskey.example',
          'authMethod': 'miauth',
          'maxNoteTextLength': 3000,
          'uploadableFileTypes': ['image/*'],
          'canPublicNote': true,
          'userId': 'u1',
          'demo': true,
        }),
        _adapter('misskey'),
      );
      expect(misskey.map((d) => '$d'), ['Instance: https://misskey.example', 'Sign-in method: Browser sign-in (MiAuth)']);
      final matrix = connectionDetails(_account('matrix', PlatformTier.openApi, {'homeserver': 'https://m.example', 'authMethod': 'something-new'}), _adapter('matrix'));
      expect(matrix.map((d) => '$d'), ['Homeserver: https://m.example'], reason: 'an unknown sign-in code is left out');
    });

    test('finding 4: a choice reads as words, never capitalised letter by letter', () {
      expect(connectionChoiceLabel('html'), 'HTML');
      expect(connectionChoiceLabel('markdown'), 'Markdown');
      expect(connectionChoiceLabel('plain'), 'Plain text');
      expect(connectionChoiceLabel('publish'), 'Published');
      expect(connectionChoiceLabel('pending'), 'Pending review');
      expect(connectionChoiceLabel('127.0.0.1'), '127.0.0.1', reason: 'an unlisted choice stays as stored');
      final telegram = connectionDetails(_account('telegram', PlatformTier.openApi, {'chatTitle': 'News', 'formatting': 'html'}), _adapter('telegram'));
      expect(telegram.map((d) => '$d'), ['Channel or group: News', 'Formatting: HTML']);
      final wordpress = connectionDetails(_account('wordpress', PlatformTier.openApi, {'defaultStatus': 'publish'}), _adapter('wordpress'));
      expect(wordpress.map((d) => '$d'), ['Publish as: Published']);
    });

    test('finding 6: no self-registered redirect, proper server software names, no repeat of the handle, targets before options', () {
      final mastodon = connectionDetails(
          _account('mastodon', PlatformTier.openApi, {'instance': 'https://m.example', 'software': 'gotosocial', 'redirectUri': 'http://127.0.0.1:52771/callback'}),
          _adapter('mastodon'));
      expect(mastodon.map((d) => '$d'), ['Server address: https://m.example', 'Server software: GoToSocial']);
      final linkedin = connectionDetails(_account('linkedin', PlatformTier.byokApi, {'redirectUri': 'http://127.0.0.1:52771/callback'}), _adapter('linkedin'));
      expect(linkedin.map((d) => '$d'), ['Redirect URI: http://127.0.0.1:52771/callback'], reason: 'LinkedIn makes the user register it');
      final bluesky = connectionDetails(_account('bluesky', PlatformTier.openApi, {'service': 'https://bsky.example', 'handle': 'someone'}), _adapter('bluesky'));
      expect(bluesky.map((d) => d.label), ['Hosting provider'], reason: 'the handle is already on the card');
      // Form fields used to come first, so Formatting led the Channel.
      final telegram = connectionDetails(_account('telegram', PlatformTier.openApi, {'formatting': 'markdown', 'botUsername': 'bot', 'chatTitle': 'News'}), _adapter('telegram'));
      expect(telegram.map((d) => d.label), ['Channel or group', 'Bot', 'Formatting']);
    });

    test('a platform-limited label is not used on other platforms', () {
      final discord = connectionDetails(_account('discord', PlatformTier.openApi, {'channelId': '111', 'guildId': '222'}), _adapter('discord'));
      expect(discord, isEmpty, reason: 'Discord ids are not shown');
    });
  });

  group('keys', () {
    test('stored keys get friendly labels in a stable order; bookkeeping and empty entries are not keys', () {
      final labels = storedKeyLabels({
        OAuthTokens.keyExpiresAt: _iso(now),
        OAuthTokens.keyTokenType: 'Bearer',
        OAuthTokens.keyScope: 'write',
        StoredSecretKeys.clientSecret: 'x' * 10,
        OAuthTokens.keyRefreshToken: 'y' * 10,
        OAuthTokens.keyAccessToken: 'z' * 10,
        StoredSecretKeys.appPassword: '',
        StoredSecretKeys.tokenIssuedAt: _iso(now),
        'some_new_key': 'w' * 10,
      }, _adapter('x'));
      expect(labels, ['Access token', 'Refresh token', 'Client secret', 'Some new key']);
    });

    test('a key no label covers is named by its connect field, else by its name in words', () {
      expect(storedKeyLabels({'oauthTokenSecret': 'v' * 10}, _adapter('tumblr')), ['OAuth Token Secret']);
      expect(humanizeKey(StoredSecretKeys.userAccessToken), 'User access token');
      expect(humanizeKey('apiKey'), 'Api key');
    });

    test('finding 3: the guard withholds any 4 characters in a row of a key, a last-4 included', () {
      final guard = SecretGuard({OAuthTokens.keyAccessToken: 'QWXZ7788KLMN4321', 'expires_at': '2031-01-02'});
      expect(guard.reveals('****4321'), isTrue, reason: 'a last-4');
      expect(guard.reveals('ends in 4321'), isTrue);
      expect(guard.reveals('QWXZ'), isTrue, reason: 'a first-4');
      expect(guard.reveals('432'), isFalse, reason: '3 characters identify nothing');
      expect(guard.reveals('2031-01-02'), isFalse, reason: 'bookkeeping is not a secret');
    });

    test('finding 3: a web address key counts by its ids and token, not by the address every user shares', () {
      final guard = SecretGuard({'webhook_url': 'https://discord.com/api/webhooks/987654/TOKENVALUE9?thread_id=1190002'});
      expect(guard.reveals('https://discord.com/channels'), isFalse);
      expect(guard.reveals('webhooks'), isFalse);
      expect(guard.reveals('thread 1190002'), isTrue, reason: 'a thread id cut from the webhook address');
      expect(guard.reveals('…UE9'), isFalse);
      expect(guard.reveals('…LUE9'), isTrue);
      expect(SecretGuard.secretParts('https://discord.com/api/webhooks/987654/TOKENVALUE9?thread_id=1190002'), ['987654', 'TOKENVALUE9', '1190002']);
      expect(SecretGuard.secretParts('plain-secret'), ['plain-secret']);
    });

    test('finding 3: the leak check catches a last-4 put into the copied setup', () {
      final real = _realAccounts(_Fakes(), now).firstWhere((r) => r.account.platformId == 'mastodon');
      final c = describeAccountConnection(real.account, adapter: _adapter('mastodon'), secrets: real.secrets, now: now);
      final copied = connectionSetupText(real.account, c, travel: KeysTravel.synced);
      _expectNoSecretShown([copied], [real.secrets]);
      final token = real.secrets[OAuthTokens.keyAccessToken]!;
      final leaked = '$copied\nToken: ****${token.substring(token.length - 4)}';
      expect(() => _expectNoSecretShown([leaked], [real.secrets]), throwsA(isA<TestFailure>()));
    });
  });

  group('sign-in', () {
    final soon = _iso(now.add(const Duration(days: 30)));
    final past = _iso(now.subtract(const Duration(days: 3)));

    test('nothing stored about an expiry or a renewal: nothing to show', () {
      expect(signInExpiry({OAuthTokens.keyAccessToken: 'a'}, now: now), isNull);
      expect(signInExpiry({OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: 'not a date'}, now: now), isNull);
    });

    test('finding 2: a refresh token without an end of its own says when it renews, with no access-token time', () {
      for (final access in [_iso(now.add(const Duration(minutes: 90))), past]) {
        final e = signInExpiry({OAuthTokens.keyExpiresAt: access, OAuthTokens.keyRefreshToken: 'r'}, now: now)!;
        expect((e.state, e.endsAt, e.needsReconnecting), (SignInState.renews, null, false));
        expect(signInText(e, when), 'Renews when NEFORUM posts. No end date is known.', reason: 'no changing time, no "Ran out"');
      }
      expect(signInExpiry({OAuthTokens.keyAccessToken: 'a', StoredSecretKeys.appPassword: 'p', OAuthTokens.keyExpiresAt: past}, now: now)!.state, SignInState.renews,
          reason: 'Bluesky signs in again with its app password');
    });

    test('finding 2: a refresh token that ends itself shows the date the sign-in really ends, as a warning when close', () {
      final youtube = signInExpiry({
        OAuthTokens.keyExpiresAt: _iso(now.add(const Duration(minutes: 50))),
        OAuthTokens.keyRefreshToken: 'r',
        StoredSecretKeys.refreshExpiresAt: _iso(now.add(const Duration(days: 6))),
      }, now: now)!;
      expect((youtube.state, youtube.endsAt, youtube.endsSoon), (SignInState.renewsUntil, now.add(const Duration(days: 6)), true));
      expect(signInText(youtube, when), 'Renews when NEFORUM posts, until 7/11/2026, then needs reconnecting.');
      final pinterest = signInExpiry({OAuthTokens.keyRefreshToken: 'r', StoredSecretKeys.refreshExpiresAt: _iso(now.add(const Duration(days: 365)))}, now: now)!;
      expect((pinterest.state, pinterest.endsSoon), (SignInState.renewsUntil, false));
    });

    test('a refresh token that ran out itself leaves only the access token', () {
      final ended = signInExpiry({OAuthTokens.keyExpiresAt: past, OAuthTokens.keyRefreshToken: 'r', StoredSecretKeys.refreshExpiresAt: past}, now: now)!;
      expect((ended.state, ended.needsReconnecting), (SignInState.ended, true));
      expect(signInText(ended, when), 'Ended on 29/10/2026. Needs reconnecting.');
      final left = signInExpiry({OAuthTokens.keyExpiresAt: soon, OAuthTokens.keyRefreshToken: 'r', StoredSecretKeys.refreshExpiresAt: past}, now: now)!;
      expect(left.state, SignInState.endsOn);
    });

    test('without a refresh token: ends on the date, then needs reconnecting', () {
      final ahead = signInExpiry({OAuthTokens.keyExpiresAt: soon, OAuthTokens.keyAccessToken: 'a'}, now: now)!;
      expect((ahead.state, ahead.endsSoon), (SignInState.endsOn, false));
      expect(signInText(ahead, when), 'Ends on 1/12/2026, then needs reconnecting.');
      final close = signInExpiry({OAuthTokens.keyExpiresAt: _iso(now.add(const Duration(days: 9))), OAuthTokens.keyAccessToken: 'a'}, now: now)!;
      expect(close.endsSoon, isTrue);
      final behind = signInExpiry({OAuthTokens.keyExpiresAt: past, OAuthTokens.keyAccessToken: 'a'}, now: now)!;
      expect(behind.needsReconnecting, isTrue);
    });

    test('a token that renews itself (Threads, Instagram) renews when used, and ends if it is not', () {
      final ahead = signInExpiry({OAuthTokens.keyExpiresAt: soon, StoredSecretKeys.tokenIssuedAt: past}, now: now)!;
      expect(ahead.state, SignInState.renewsWhenUsed);
      expect(signInText(ahead, when), 'Renews when NEFORUM posts with it. Unused, it ends on 1/12/2026.');
      expect(signInExpiry({OAuthTokens.keyExpiresAt: past, StoredSecretKeys.refreshedAt: past}, now: now)!.needsReconnecting, isTrue);
    });
  });

  group('sign-in text (1.4)', () {
    SignInLifetime life(SignInPolicy p, Map<String, String> s, {DateTime? at}) => deriveSignInLifetime(p, s, now: at ?? now);
    final ahead = now.add(const Duration(days: 30));

    test('a date that something else can end first reads "at the latest"', () {
      expect(signInText(life(SignInPolicies.linkedIn, {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: _iso(ahead)}), when),
          'Ends on 1/12/2026 at the latest, then needs reconnecting. Reconnect before it ends to skip the consent screen.');
      expect(signInText(life(SignInPolicies.threads, {OAuthTokens.keyExpiresAt: _iso(ahead), StoredSecretKeys.tokenIssuedAt: _iso(now)}), when),
          'Renews when NEFORUM posts with it. Unused, it ends on 1/12/2026 at the latest.');
      expect(signInText(life(SignInPolicies.tikTok, {OAuthTokens.keyRefreshToken: 'r', StoredSecretKeys.refreshExpiresAt: _iso(ahead)}), when), contains('until 1/12/2026 at the latest'));
    });

    test('M4: a sign-in that ends when idle says about when, where it said "Renews automatically"', () {
      final renewed = {OAuthTokens.keyRefreshToken: 'r', StoredSecretKeys.lastRenewedAt: _iso(now)};
      expect(signInText(life(SignInPolicies.tumblrOAuth2, renewed), when), 'Renews when NEFORUM posts. Unused, it ends about 13/12/2026 at the latest.');
      expect(signInText(life(SignInPolicies.xOAuth2, renewed), when), contains('Unused, it ends about 3/5/2027 at the latest'));
      expect(signInText(life(SignInPolicies.youTube, renewed), when), contains('If your Google app is still in Testing'), reason: 'M5: said plainly, since the date may not reach NEFORUM');
      expect(signInText(life(SignInPolicies.xOAuth2, {OAuthTokens.keyRefreshToken: 'r'}), when), 'Renews when NEFORUM posts. It ends if nothing renews it for about 183 days.');
      expect(signInText(life(SignInPolicies.xOAuth2, renewed, at: now.add(const Duration(days: 200))), when), startsWith('It probably ended about 3/5/2027.'));
    });

    test('M12: a pasted token with no date yet says so', () {
      expect(signInText(life(SignInPolicies.instagram, {OAuthTokens.keyAccessToken: 'a'}), when), 'Ends within 60 days of its last renewal. The date shows after NEFORUM first renews it.');
    });

    test('X keys say the deadline and what to do; Tumblr and Flickr keys do not', () {
      final keys = OAuth1Credentials(consumerKey: 'k', consumerSecret: 's', token: 't', tokenSecret: 'x').toSecrets();
      expect(signInText(life(SignInPolicies.xKeys, keys), when), 'Ends on 31/1/2027 at the latest, then needs reconnecting. X stops accepting these keys on that date. Reconnect by browser sign-in before then.');
      expect(signInText(life(SignInPolicies.tumblrKeys, keys), when), 'No published end date.');
      expect(signInText(life(SignInPolicies.flickrPolicy, keys), when), 'No published end date.');
    });

    test('no limit: says only what can really end it', () {
      expect(signInText(life(SignInPolicies.nostrPolicy, {'nsec': 'k'}), when), 'No end date. A key does not expire.', reason: 'a Nostr key cannot be revoked');
      expect(signInText(life(SignInPolicies.lemmyPolicy, {OAuthTokens.keyAccessToken: 'a'}), when), 'No end date. Logging out or a new password ends it.');
      expect(signInText(life(SignInPolicies.facebook, {OAuthTokens.keyAccessToken: 'a'}), when), 'No end date. Meta can still end it: a password change, a removed app, or a Meta app left unused for 90 days.');
    });

    test('what the platform last said goes into the Connection section and the copied setup', () async {
      final account = _acct('lemmy', PlatformTier.openApi, const {'instance': 'https://lemmy.example'});
      final secrets = {OAuthTokens.keyAccessToken: 'a'};
      final read = SignInServerRead(readAt: now, expiresAt: ahead);
      final without = describeAccountConnection(account, adapter: _adapter('lemmy'), secrets: secrets, now: now);
      expect(without.signIn!.expiresAt, isNull, reason: 'nothing read yet');
      final c = describeAccountConnection(account, adapter: _adapter('lemmy'), secrets: secrets, now: now, serverRead: read);
      expect((c.signIn!.expiresAt, c.signIn!.source), (ahead, SignInDateSource.serverReported));
      expect(signInText(c.signIn!, when), 'Ends on 1/12/2026 at the latest, then needs reconnecting. Logging out or a new password ends it.');
      final store = InMemorySecretStore();
      await store.write(account.id, secrets);
      final status = SignInStatus(accountId: account.id, limit: SignInLimit.none, source: SignInDateSource.serverReported, renewsItself: false, state: SignInState.endsOn, serverRead: read);
      final all = await allConnectionSetupsText([account], secrets: store, registry: builtinRegistry(), travel: KeysTravel.thisDeviceOnly, deviceLabel: 'Test device', now: now, statuses: {account.id: status});
      expect(all.text, contains('at the latest'));
      expect(all.text, contains(connectionCopyMoment(ahead)));
    });

    testWidgets('the open section reads the status file: a one week Lemmy login from before 1.4 shows its date', (tester) async {
      final account = _acct('lemmy', PlatformTier.openApi, const {'instance': 'https://lemmy.example'}, id: 'section-lemmy');
      final end = DateTime.now().toUtc().add(const Duration(days: 5));
      await tester.runAsync(() async {
        final s = await AppServices.create(demo: true, storage: _MemoryStorage(const {}), browserBridge: BrowserBridge.create(secrets: InMemorySecretStore(), ports: const [0]));
        addTearDown(s.dispose);
        await s.accounts.upsert(account);
        await s.secrets.write(account.id, {OAuthTokens.keyAccessToken: 'a'});
        await s.signInStatusStore.change(account.id, (c) => SignInStatus(accountId: account.id, limit: SignInLimit.none, source: SignInDateSource.serverReported, renewsItself: false, state: SignInState.endsOn, expiresAt: end, serverRead: SignInServerRead(readAt: DateTime.now().toUtc(), expiresAt: end)));
        final container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(s)]);
        addTearDown(container.dispose);
        final keep = container.listen(accountConnectionProvider(account.id), (_, _) {});
        addTearDown(keep.close);
        final accounts = container.listen(accountsProvider, (_, _) {});
        addTearDown(accounts.close);
        await container.read(accountsProvider.future);
        final c = await container.read(accountConnectionProvider(account.id).future);
        expect(c!.signIn!.expiresAt, end);
      });
    });

    test('no date: no limit, no published limit and idle time are three different things', () {
      expect(signInText(life(SignInPolicies.mastodonNoLimit, {OAuthTokens.keyAccessToken: 'a'}), when), 'No end date. Ends only if revoked.');
      expect(signInText(life(SignInPolicies.telegramPolicy, {'bot_token': 'b'}), when), 'No published end date.');
      expect(signInText(life(SignInPolicies.inkbunnyPolicy, {StoredSecretKeys.sessionId: 's'}), when), 'Ends after idle time. Inkbunny ends the session after several days without use. No date can be known.');
      expect(signInText(life(SignInPolicies.mastodonOtherServer, {OAuthTokens.keyAccessToken: 'a'}), when), 'No published end date. Your server decides.');
      expect(signInText(life(SignInPolicies.blueskyPolicy, {OAuthTokens.keyAccessToken: 'a', StoredSecretKeys.appPassword: 'p'}), when), 'Renews automatically while the app password is valid.');
    });

    test('a date from the server on a no-limit platform reads as a date: Mitra', () {
      final account = _acct('mastodon', PlatformTier.openApi, {'software': 'mitra'});
      final c = describeAccountConnection(account, adapter: _adapter('mastodon'), secrets: {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: _iso(ahead)}, now: now);
      expect((c.signIn!.state, c.signIn!.expiresAt), (SignInState.endsOn, ahead));
    });

    test('no row with no sign-in: hand-off, the LBRY app, no keys, an unreadable keychain', () {
      final secrets = {OAuthTokens.keyAccessToken: 'a'};
      expect(describeAccountConnection(_acct('x', PlatformTier.handoff, const {}), adapter: _adapter('x'), secrets: secrets, now: now).signIn, isNull);
      expect(describeAccountConnection(_acct('odysee', PlatformTier.openApi, const {}), adapter: _adapter('odysee'), secrets: secrets, now: now).signIn, isNull);
      expect(describeAccountConnection(_acct('x', PlatformTier.byokApi, const {}), adapter: _adapter('x'), now: now).signIn, isNull);
      expect(describeAccountConnection(_acct('x', PlatformTier.byokApi, const {}), adapter: _adapter('x'), secrets: secrets, now: now, keysUnreadable: true).signIn, isNull);
      expect(describeAccountConnection(_acct('telegram', PlatformTier.openApi, const {}), adapter: _adapter('telegram'), secrets: {'bot_token': 'b'}, now: now).signIn, isNotNull);
    });

    test('the new bookkeeping keys are not listed as keys and not fed to the guard', () {
      final secrets = {
        OAuthTokens.keyAccessToken: 'QQQQQQQQ',
        StoredSecretKeys.expiresAtSource: 'serverReported',
        StoredSecretKeys.refreshExpiresSource: 'computed',
        StoredSecretKeys.lastRenewedAt: _iso(now),
      };
      expect(storedKeyLabels(secrets, null), ['Access token']);
      expect(SecretGuard(secrets).reveals('serverReported and computed'), isFalse);
      expect(kSecretBookkeepingKeys, containsAll([StoredSecretKeys.expiresAtSource, StoredSecretKeys.refreshExpiresSource, StoredSecretKeys.lastRenewedAt]));
    });

    test('advice: not allowed does not say the sign-in expired', () {
      expect(targetErrorAdvice(const PublishError.auth('expired')), contains('expired or was revoked'));
      expect(targetErrorAdvice(const PublishError.auth('no rights', notAllowed: true)), isNot(contains('expired')));
      expect(targetErrorAdvice(const PublishError.auth('no rights', notAllowed: true)), contains('does not allow this'));
      expect(targetErrorAdvice(const PublishError.auth('no rights', notAllowed: true)), isNot(contains('sign-in works')), reason: 'a bare 403 does not prove that');
    });
  });

  group('sign-in status in the app (1.4)', () {
    testWidgets('every write through the services updates the status, and it shows no key', (tester) async {
      await tester.runAsync(() async {
        final storage = _MemoryStorage(const {});
        final s = await AppServices.create(demo: true, storage: storage, browserBridge: BrowserBridge.create(secrets: InMemorySecretStore(), ports: const [0]));
        addTearDown(s.dispose);
        final account = _acct('linkedin', PlatformTier.byokApi, {'clientId': 'c'}, id: 'status-linkedin');
        await s.accounts.upsert(account);
        final end = DateTime.now().toUtc().add(const Duration(days: 30));
        const secret = 'QZXCVBNMLKJHGFDSQ';
        await s.secrets.write(account.id, stampNewSignIn({OAuthTokens.keyAccessToken: secret, OAuthTokens.keyExpiresAt: _iso(end)}, now: DateTime.now()));
        final status = (await s.signInStatusStore.get(account.id))!;
        expect((status.expiresAt, status.source, status.earlyRevocationPossible), (end, SignInDateSource.serverReported, true));
        expect(jsonEncode(status.toJson()), isNot(contains(secret)));
        // The publisher reports back through the same tracker.
        expect(s.publisher().signInOutcomes, same(s.signInStatus));
      });
    });

    testWidgets('Delete everything empties the status file, including what no account owns any more', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(() async {
        final s = await AppServices.create(demo: true, storage: _MemoryStorage({'themeMode': 'light'}));
        final account = _acct('linkedin', PlatformTier.byokApi, {'clientId': 'c'}, id: 'status-delete');
        await s.accounts.upsert(account);
        await s.secrets.write(account.id, {OAuthTokens.keyAccessToken: 'QZXCVBNMLKJHGFDSQ', OAuthTokens.keyExpiresAt: _iso(DateTime.now().add(const Duration(days: 9)))});
        await s.signInStatusStore.change('left-behind', (_) => const SignInStatus(accountId: 'left-behind', limit: SignInLimit.none, source: SignInDateSource.unknown, renewsItself: false, state: SignInState.noDate));
        expect((await s.signInStatusStore.all()).keys, containsAll(['status-delete', 'left-behind']));
        await s.signInWarnings.run();
        await s.signInWarningStore.update((l) => l.copyWith(bannerClosed: {'status-delete': 'x'}));
        expect((await s.signInWarningStore.read()).entries.keys, contains('status-delete'));
        return s;
      }))!;
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(s)],
        child: MaterialApp(theme: buildTheme(Brightness.light, AccentChoice.neforum), home: const Scaffold(body: SingleChildScrollView(child: DataSettingsSection()))),
      ));
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Delete\u2026'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Delete everything').last);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      }
      expect(await tester.runAsync(() => s.signInStatusStore.all()), isEmpty);
      final ledger = (await tester.runAsync(() => s.signInWarningStore.read()))!;
      expect(ledger.entries, isEmpty, reason: 'what was said about a sign-in goes too');
      expect(ledger.bannerClosed, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('signInStatusesProvider follows the store', (tester) async {
      await tester.runAsync(() async {
        final s = await AppServices.create(demo: true, storage: _MemoryStorage(const {}), browserBridge: BrowserBridge.create(secrets: InMemorySecretStore(), ports: const [0]));
        addTearDown(s.dispose);
        final container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(s)]);
        addTearDown(container.dispose);
        final seen = <Map<String, SignInStatus>>[];
        final sub = container.listen(signInStatusesProvider, (_, next) {
          if (next.hasValue) seen.add(next.value!);
        }, fireImmediately: true);
        addTearDown(sub.close);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await s.signInStatusStore.change('a', (_) => const SignInStatus(accountId: 'a', limit: SignInLimit.none, source: SignInDateSource.unknown, renewsItself: false, state: SignInState.noDate));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(seen.last.keys, contains('a'));
      });
    });

    test('the guide is in the app and matches docs/', () {
      expect(File('assets/docs/sign-in-lifetimes.md').readAsStringSync(), File('../../docs/sign-in-lifetimes.md').readAsStringSync(), reason: 'run dart run tool/sync_docs.dart');
    });
  });

  test('sync: Synced when it is on, a warning when its last run failed, else only on this device', () {
    expect(keysTravelFor(settingsSyncOn: false, phase: CloudSyncPhase.ok), KeysTravel.thisDeviceOnly);
    expect(keysTravelFor(settingsSyncOn: true, phase: CloudSyncPhase.ok), KeysTravel.synced);
    expect(keysTravelFor(settingsSyncOn: true, phase: CloudSyncPhase.syncing), KeysTravel.synced);
    expect(keysTravelFor(settingsSyncOn: true, phase: CloudSyncPhase.off), KeysTravel.synced, reason: 'starting up');
    expect(keysTravelFor(settingsSyncOn: true, phase: CloudSyncPhase.error), KeysTravel.syncNotWorking);
    expect(keysTravelLabel(KeysTravel.synced), 'Synced');
    expect(keysTravelLabel(KeysTravel.thisDeviceOnly), 'Only on this device');
  });

  test('finding 5: the copied name never repeats the handle', () {
    ConnectedAccount named(String name, String? handle) =>
        ConnectedAccount(id: 'n', platformId: 'x', tier: PlatformTier.byokApi, displayName: name, handle: handle, createdAt: _connected);
    expect(connectionAccountName(named('Robin (@robinmakes)', '@robinmakes')), 'Robin (@robinmakes)');
    expect(connectionAccountName(named('Robin (mastodon.example)', '@robin@mastodon.example')), 'Robin (@robin@mastodon.example)');
    expect(connectionAccountName(named('@robin.rivera', '@robin.rivera')), '@robin.rivera');
    expect(connectionAccountName(named('Someone', '@someone')), 'Someone (@someone)');
    expect(connectionAccountName(named('Robin Studio (Brand)', '@studio')), 'Robin Studio (Brand) (@studio)', reason: 'a parenthesis that is not the handle stays');
    expect(connectionAccountName(named('Instagram (hand-off)', null)), 'Instagram (hand-off)');
  });

  test('finding 1: whether a way of connecting stores keys comes from its connect form, not its tier', () {
    final odysee = _acct('odysee', PlatformTier.openApi, {'daemon': 'http://localhost:5279'});
    expect(connectionStoresKeys(odysee, _adapter('odysee')), isFalse);
    expect(connectionStoresKeys(_acct('reddit', PlatformTier.byokApi, {}), _adapter('reddit')), isTrue, reason: 'browser sign-in, no secret field');
    expect(connectionStoresKeys(_acct('telegram', PlatformTier.openApi, {}), _adapter('telegram')), isTrue);
    expect(connectionStoresKeys(_acct('instagram', PlatformTier.handoff, {}), _adapter('instagram')), isFalse);
    final c = describeAccountConnection(odysee, adapter: _adapter('odysee'), now: now);
    expect((c.needsKeys, c.keysMissing), (false, false));
    expect(noStoredKeysText(c), 'None needed: it posts through the LBRY app on this device.');
    expect(storedKeysLine(c, KeysTravel.thisDeviceOnly), 'None needed');
  });

  test('the realistic accounts cover every way of posting through an API, and agree with the adapters on keys', () {
    final real = _realAccounts(_Fakes(), now);
    final covered = {for (final r in real) '${r.account.platformId}/${r.account.tier.name}'};
    for (final a in builtinAdapters()) {
      for (final spec in a.connectSpecs.where((s) => s.tier != PlatformTier.handoff)) {
        expect(covered, contains('${a.id}/${spec.tier.name}'), reason: 'add a realistic account for ${a.id} (${spec.tier.name})');
      }
    }
    for (final r in real) {
      expect(connectionStoresKeys(r.account, _adapter(r.account.platformId)), r.secrets.isNotEmpty, reason: r.account.id);
    }
  });

  test('every way of posting through an API, stored as its adapter stores it, reads right and shows no key', () {
    for (final r in _realAccounts(_Fakes(), now)) {
      final id = r.account.id;
      final c = describeAccountConnection(r.account, adapter: _adapter(r.account.platformId), secrets: r.secrets, now: now);
      final lines = c.details.map((d) => '$d').toList();
      expect(c.storedKeys, r.keys, reason: id);
      expect(c.needsKeys, r.needsKeys, reason: id);
      expect(c.keysMissing, isFalse, reason: id);
      expect(c.signIn?.state == SignInState.noDate ? null : c.signIn?.state, r.sign, reason: id);
      expect(c.signIn?.endsSoon ?? false, r.soon, reason: id);
      expect(lines, containsAll(r.show), reason: id);
      for (final label in r.hide) {
        expect(c.details.map((d) => d.label), isNot(contains(label)), reason: '$id: $label');
      }
      final handle = r.account.handle;
      if (handle != null) {
        expect(c.details.map((d) => d.value.toLowerCase()), isNot(contains(handle.replaceFirst(RegExp('^(@|u/)'), '').toLowerCase())), reason: '$id repeats its handle');
      }
      final text = connectionSetupText(r.account, c, travel: KeysTravel.thisDeviceOnly);
      expect(text, isNot(contains('None stored')), reason: id);
      _expectNoSecretShown([...lines, ...c.storedKeys, text], [r.secrets]);
    }
  });

  test('every built-in adapter, every way it connects: each form field shows under its own label, no key shows', () {
    final cases = _formAccounts(_Fakes());
    expect(cases.length, greaterThan(builtinAdapters().length));
    for (final (account, secrets, spec) in cases) {
      final adapter = _adapter(account.platformId);
      final c = describeAccountConnection(account, adapter: adapter, secrets: secrets, now: now);
      final shown = {for (final d in c.details) d.label: d.value};
      for (final f in spec.fields.where((f) => !f.secret)) {
        final label = cleanFieldLabel(f.label);
        expect(shown[label], _shownValue(f, account.config[f.key] as Object), reason: '${account.id}: ${f.key} as "$label"');
      }
      for (final f in spec.fields.where((f) => f.secret)) {
        expect(c.storedKeys, contains(kSecretKeyLabels[f.key] ?? cleanFieldLabel(f.label)), reason: '${account.id}: ${f.key}');
      }
      expect(c.method, connectionMethodText(spec.tier, adapter.descriptor.name));
      _expectNoSecretShown([...shown.values, ...c.storedKeys, connectionSetupText(account, c, travel: KeysTravel.thisDeviceOnly)], [secrets]);
    }
  });

  test('the copied setup lists what the section shows and no key', () {
    final fakes = _Fakes();
    final secrets = {OAuthTokens.keyAccessToken: fakes.next(), OAuthTokens.keyRefreshToken: fakes.next(), OAuthTokens.keyExpiresAt: _iso(now.add(const Duration(hours: 1)))};
    final account = _account('mastodon', PlatformTier.openApi, {'instance': 'https://mastodon.example', 'software': 'mastodon'});
    final c = describeAccountConnection(account, adapter: _adapter('mastodon'), secrets: secrets, now: now);
    final text = connectionSetupText(account, c, travel: KeysTravel.synced);
    expect(text, '''
Mastodon: Someone (@someone)
How it posts: Automatically, through the open Mastodon API
Server address: https://mastodon.example
Server software: Mastodon
Sign-in: Renews when NEFORUM posts. No end date is known.
Keys on this device: Access token, Refresh token (Synced)
Connected: 2026-10-12''');
    _expectNoSecretShown([text], [secrets]);
  });

  test('the in-app guides for a second device say where to see an account\'s setup', () {
    for (final guide in ['assets/docs/sync.md', 'assets/docs/backup.md']) {
      final text = File(guide).readAsStringSync();
      expect(text, contains('go to **Accounts** and open **Connection**'), reason: guide);
      expect(text, contains('**Copy all setups**'), reason: guide);
      expect(File('../../docs/${guide.split('/').last}').readAsStringSync(), text, reason: 'run dart run tool/sync_docs.dart');
    }
  });

  group('round 2', () {
    /// [a] as a device in another time zone holds it: the same instants, a
    /// different offset.
    ConnectedAccount inZone(ConnectedAccount a, Duration offset) => ConnectedAccount(
          id: a.id,
          platformId: a.platformId,
          tier: a.tier,
          displayName: a.displayName,
          handle: a.handle,
          createdAt: offset == Duration.zero ? a.createdAt.toUtc() : a.createdAt.toLocal(),
          config: a.config,
        );
    Map<String, String> datesWithOffset(Map<String, String> s, Duration offset) => {
          for (final e in s.entries)
            e.key: switch (DateTime.tryParse(e.value)) {
              final DateTime t when kSecretBookkeepingKeys.contains(e.key) =>
                '${t.toUtc().add(offset).toIso8601String().replaceFirst('Z', '')}+${offset.inHours.toString().padLeft(2, '0')}:00',
              _ => e.value,
            },
        };

    test('finding 2: copied dates are UTC ISO 8601, whatever the offset they were stored with', () {
      final instant = DateTime.parse('2026-10-13T01:30:00+05:00');
      expect(connectionCopyDate(instant), '2026-10-12', reason: 'the day in UTC, not the local day');
      expect(connectionCopyDate(instant.toLocal()), '2026-10-12');
      expect(connectionCopyMoment(instant), '2026-10-12T20:30Z');
      expect(connectionCopyMoment(instant.toLocal()), '2026-10-12T20:30Z');
      expect(connectionCopyHeader('Test device', instant), 'Setup copied from Test device on ${connectionLocalDate(instant)}');
      // Either side of midnight UTC: a day taken from the device's own clock
      // would land on the wrong side on any device not set to UTC.
      for (final (stored, day, moment) in [
        ('2026-10-12T23:59:00Z', '2026-10-12', '2026-10-12T23:59Z'),
        ('2026-10-13T00:01:00Z', '2026-10-13', '2026-10-13T00:01Z'),
        ('2026-10-13T01:01:00+02:00', '2026-10-12', '2026-10-12T23:01Z'),
        ('2026-10-12T20:01:00-05:00', '2026-10-13', '2026-10-13T01:01Z'),
      ]) {
        final t = DateTime.parse(stored);
        for (final view in [t, t.toLocal(), t.toUtc()]) {
          expect((connectionCopyDate(view), connectionCopyMoment(view)), (day, moment), reason: '$stored as $view');
        }
      }
    });

    test('finding 2: two devices in different time zones copy identical account blocks', () {
      for (final r in _realAccounts(_Fakes(), now)) {
        String copy(Duration offset) {
          final a = inZone(r.account, offset);
          final s = datesWithOffset(r.secrets, offset);
          return connectionSetupText(a, describeAccountConnection(a, adapter: _adapter(a.platformId), secrets: s, now: now), travel: KeysTravel.synced);
        }

        final utc = copy(Duration.zero), east = copy(const Duration(hours: 5));
        expect(east, utc, reason: r.account.id);
        expect(utc, isNot(matches(RegExp(r'\b(AM|PM)\b'))), reason: r.account.id);
        expect(utc, contains('Connected: 2026-10-12'), reason: r.account.id);
      }
    });

    test('finding 3: Copy all setups survives a keychain that will not answer, and says which', () async {
      final real = _realAccounts(_Fakes(), now);
      final mastodon = real.firstWhere((r) => r.account.platformId == 'mastodon');
      final telegram = real.firstWhere((r) => r.account.platformId == 'telegram');
      final store = InMemorySecretStore();
      await store.write(mastodon.account.id, mastodon.secrets);
      await store.write(telegram.account.id, telegram.secrets);
      final result = await allConnectionSetupsText(
        [mastodon.account, telegram.account],
        secrets: _FailingSecretStore(store, {telegram.account.id}),
        registry: builtinRegistry(),
        travel: KeysTravel.thisDeviceOnly,
        deviceLabel: 'Test device',
        now: now,
      );
      final blocks = result.text.split('\n\n');
      expect(result.unreadable, 1);
      expect(blocks, hasLength(3));
      expect(blocks[0], 'Setup copied from Test device on ${connectionLocalDate(now)}');
      expect(blocks[1], contains('Keys on this device: Access token, Client ID, Client secret (Only on this device)'));
      expect(blocks[2], startsWith('Telegram: Robin News (@robinnews)'));
      expect(blocks[2], contains('Keys on this device: Could not be read on this device'));
      expect(blocks[2], isNot(contains('Bot:')), reason: 'without its keys the guard cannot check the details, so they are left out');
      expect(result.text, isNot(contains('SECRETINERROR')), reason: 'never the error text');
      _expectNoSecretShown([result.text], [mastodon.secrets, telegram.secrets]);
    });

    test('finding 4: every part of a key address that can carry a secret counts', () {
      expect(SecretGuard({'webhook_url': 'https://discord.com/api/webhooks/123/abcdefghijklmnopqrstuvwxyz'}).reveals('ends wxyz'), isTrue,
          reason: 'a token segment without a digit');
      expect(SecretGuard({'url': 'https://robin:SuperSecretPass@dav.example/x'}).reveals('…Pass'), isTrue, reason: 'a password before the host');
      expect(SecretGuard({'url': 'https://app.example/cb#access_token=tokenvaluexyz&state=s'}).reveals('…uexy'), isTrue, reason: 'a token in the fragment');
      expect(SecretGuard({'url': 'https://hooks.example/in?key=onlylettersinthisone'}).reveals('thisone'), isTrue, reason: 'a query value without a digit');
      expect(SecretGuard({'url': 'https://secret-tenant.example/hook'}).reveals('secret-tenant'), isTrue, reason: 'an unknown host counts in full');
      final discord = SecretGuard({'webhook_url': 'https://discord.com/api/webhooks/123456/TOKENVALUE'});
      expect(discord.reveals('https://discord.com/channels/1'), isFalse, reason: 'the start every Discord webhook shares');
      expect(discord.reveals('webhooks'), isFalse);
      expect(SecretGuard.secretParts('https://robin:pw12@dav.example/a/bb?x=1#frag'), ['dav.example', 'robin:pw12', 'a', 'bb', '1', 'frag']);
      expect(SecretGuard.secretParts('https://discord.com/api/v10/webhooks/9/T'), ['9', 'T']);
    });

    test('finding 5: a withheld value keeps its row and says why', () {
      final account = _acct('facebook', PlatformTier.byokApi, {'app_id': '1234567890', 'page_name': 'Studio'});
      final secrets = {OAuthTokens.keyAccessToken: 'QQQQQQQQ', StoredSecretKeys.appSecret: 'ab7890cd'};
      final c = describeAccountConnection(account, adapter: _adapter('facebook'), secrets: secrets, now: now);
      final appId = c.details.firstWhere((d) => d.label == 'App ID');
      expect((appId.value, appId.withheld), (kWithheldValue, true));
      expect(c.details.map((d) => '$d'), contains('Page: Studio'));
      final text = connectionSetupText(account, c, travel: KeysTravel.synced);
      expect(text, contains('App ID: Not shown: it shares characters with a stored key'));
      expect(text, isNot(contains('1234567890')));
    });

    test('finding 6: the keychain names come from core\'s own constants', () {
      expect(kSecretBookkeepingKeys,
          containsAll([StoredSecretKeys.refreshExpiresAt, StoredSecretKeys.tokenIssuedAt, StoredSecretKeys.refreshedAt, StoredSecretKeys.userTokenExpiresAt, StoredSecretKeys.openId]));
      final until = signInExpiry({OAuthTokens.keyRefreshToken: 'r', StoredSecretKeys.refreshExpiresAt: _iso(now.add(const Duration(days: 3)))}, now: now)!;
      expect(until.state, SignInState.renewsUntil);
      final used = signInExpiry({OAuthTokens.keyExpiresAt: _iso(now.add(const Duration(days: 3))), StoredSecretKeys.refreshedAt: _iso(now)}, now: now)!;
      expect(used.state, SignInState.renewsWhenUsed);
      expect(storedKeyLabels({StoredSecretKeys.appPassword: 'x', StoredSecretKeys.sessionId: 'y', StoredSecretKeys.privateKey: 'z', StoredSecretKeys.consumerSecret: 'w'}, null),
          ['Consumer secret', 'App password', 'Private key', 'Session']);
    });

    test('finding 7: nothing the card shows is repeated, one Room row, spaced permissions, named legacy keys', () {
      final lemmy = connectionDetails(
          _acct('lemmy', PlatformTier.openApi, {'instance': 'https://lemmy.example', 'username': 'robin', 'community': 'robin'},
              name: 'Robin Rivera', handle: '@robin@lemmy.example'),
          _adapter('lemmy'));
      expect(lemmy.map((d) => '$d'), ['Instance: https://lemmy.example', 'Default community: robin'], reason: 'the handle\'s user part is dropped only from who-it-is rows');
      final telegram = connectionDetails(_acct('telegram', PlatformTier.openApi, {'chatTitle': 'Robin News', 'formatting': 'plain'}, name: 'Robin News'), _adapter('telegram'));
      expect(telegram.map((d) => '$d'), ['Formatting: Plain text'], reason: 'the channel title is the card\'s name');
      List<String> room(Map<String, dynamic> c) => connectionDetails(_acct('matrix', PlatformTier.openApi, c), _adapter('matrix')).map((d) => '$d').toList();
      expect(room({'roomName': 'News', 'roomAlias': '#news:m.example', 'roomId': '!abc:m.example'}), ['Room: News (#news:m.example)']);
      expect(room({'roomAlias': '#news:m.example', 'roomId': '!abc:m.example'}), ['Room: #news:m.example']);
      expect(room({'roomId': '!abc:m.example'}), ['Room: !abc:m.example']);
      final facebook = connectionDetails(_acct('facebook', PlatformTier.byokApi, {'scopes': 'pages_manage_posts,pages_show_list, business_management'}), _adapter('facebook'));
      expect(facebook.map((d) => '$d'), ['Permissions: pages_manage_posts, pages_show_list, business_management']);
      expect(storedKeyLabels({'jwt': 'x' * 8}, _adapter('lemmy')), ['Access token']);
      expect(storedKeyLabels({'token': 'y' * 8}, _adapter('misskey')), ['Access token']);
    });
  });

  group('round 3', () {
    test('item 1: a value that is a stored key says so; one that only shares characters says that', () {
      final tumblr = _realAccounts(_Fakes(), now).firstWhere((r) => r.account.id == 'real-tumblr-oauth1');
      final c = describeAccountConnection(tumblr.account, adapter: _adapter('tumblr'), secrets: tumblr.secrets, now: now);
      expect(c.details.firstWhere((d) => d.label == 'OAuth Consumer Key').value, kStoredKeyValue);
      final partial = connectionDetails(_acct('facebook', PlatformTier.byokApi, {'app_id': '1234567890'}), _adapter('facebook'),
          secrets: {StoredSecretKeys.appSecret: 'ab7890cd'});
      expect(partial.single.value, kWithheldValue);
      final guard = SecretGuard({'k': 'QWXZ7788'});
      expect((guard.isKey('QWXZ7788'), guard.isKey(' QWXZ7788 '), guard.isKey('QWXZ778')), (true, true, false));
    });

    test('item 2: a key address counts as written too, so its encoded form is caught', () {
      final path = SecretGuard({'webhook_url': 'https://hooks.example/in/tok%2Fen%2Fvalue'});
      expect(path.reveals('tok%2Fen'), isTrue, reason: 'the encoded path segment');
      expect(path.reveals('en/value'), isTrue, reason: 'the decoded path segment');
      final query = SecretGuard({'url': 'https://hooks.example/in?key=ab%20cd%26ef'});
      expect(query.reveals('…%26ef'), isTrue, reason: 'the encoded query value');
      expect(query.reveals('cd&ef'), isTrue, reason: 'the decoded query value');
      final fragment = SecretGuard({'url': 'https://app.example/cb#tok%2Fen'});
      expect((fragment.reveals('k%2F'), fragment.reveals('ok/e')), (true, true));
      expect(SecretGuard({'webhook_url': 'https://discord.com/api/webhooks/123456/TOKEN'}).reveals('webhooks'), isFalse,
          reason: 'the public Discord start stays public in its written form too');
    });

    test('item 3: a keychain that does not answer times out once and marks the rest unread', () async {
      final real = _realAccounts(_Fakes(), now);
      final accounts = [for (final r in real.take(3)) r.account];
      final store = _HangingSecretStore();
      final result = await allConnectionSetupsText(accounts,
          secrets: store, registry: builtinRegistry(), travel: KeysTravel.synced, deviceLabel: 'Test device', now: now, readTimeout: const Duration(milliseconds: 50));
      expect((result.timedOut, result.unreadable, store.reads), (true, 3, 1), reason: 'one wait, not one per account');
      expect('Keys on this device: Could not be read on this device'.allMatches(result.text), hasLength(3));
    });

    test('item 4: the header names the device\'s own day; the account blocks stay in UTC', () {
      final instant = DateTime.parse('2026-10-13T03:00:00Z');
      final local = instant.toLocal();
      expect(connectionLocalDate(instant), '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}');
      expect(connectionCopyHeader('Test device', instant), 'Setup copied from Test device on ${connectionLocalDate(instant)}');
      expect(connectionCopyDate(instant), '2026-10-13', reason: 'blocks keep the UTC day, the same on every device');
    });
  });

  group('on the Accounts page', () {
    tearDown(() => AccountConnectionSection.debugStartOpen = false);

    testWidgets('round 3, item 3: Copy all setups is disabled while it copies, and a stuck keychain times out with a clear message', (tester) async {
      final copied = _captureClipboard(tester);
      final mastodon = _realAccounts(_Fakes(), DateTime.now()).firstWhere((r) => r.account.platformId == 'mastodon');
      final gate = _GatedSecretStore();
      await _pumpAccounts(tester, accounts: [(mastodon.account, mastodon.secrets)], keepDemoAccounts: false, secretStore: (s) => gate..inner = s.secrets);
      OutlinedButton button() => tester.widget<OutlinedButton>(find.ancestor(of: find.text('Copy all setups'), matching: find.byType(OutlinedButton)));

      await _tap(tester, find.text('Copy all setups'));
      expect(button().onPressed, isNull, reason: 'disabled while the keychain is read');
      await tester.tap(find.text('Copy all setups'), warnIfMissed: false);
      await tester.pump();
      gate.open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(copied, hasLength(1), reason: 'a second tap did not copy again');
      expect(gate.reads, 1);
      expect(button().onPressed, isNotNull);

      // A prompt nobody answers: the copy gives up after its timeout.
      gate.hang = true;
      await _tap(tester, find.text('Copy all setups'));
      await tester.pump(const Duration(seconds: 16));
      // The earlier toast animates away before the new one shows.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.textContaining('The keychain did not answer'), findsOneWidget);
      expect(copied, hasLength(2));
      expect(copied.last, contains('Keys on this device: Could not be read on this device'));
      expect(button().onPressed, isNotNull);
      await _unmount(tester);
    });

    testWidgets('round 2, finding 2: 12-hour and 24-hour devices copy the same setup; each screen keeps its own clock', (tester) async {
      final copied = _captureClipboard(tester);
      final youtube = _realAccounts(_Fakes(), DateTime.now()).firstWhere((r) => r.account.platformId == 'youtube');
      final id = youtube.account.id;
      final screens = <String>[];
      for (final clock in ['twelveHour', 'twentyFourHour']) {
        await _pumpAccounts(tester, settings: {'clockFormat': clock}, accounts: [(youtube.account, youtube.secrets)], keepDemoAccounts: false);
        await _open(tester, id);
        screens.add(tester.widget<Text>(find.descendant(of: _card(id), matching: find.textContaining('Renews when NEFORUM posts, until'))).data!);
        await _tap(tester, find.descendant(of: _card(id), matching: find.text('Copy setup')));
        await _unmount(tester);
      }
      expect(copied, hasLength(2));
      expect(copied[0], copied[1]);
      expect(copied[0], matches(RegExp(r'Sign-in: Renews when NEFORUM posts, until \d{4}-\d\d-\d\dT\d\d:\d\dZ at the latest, then needs reconnecting\.')));
      expect(copied[0], contains('\nConnected: 2026-10-12'));
      expect(screens[0], isNot(screens[1]), reason: 'on screen, each device writes its own clock');
    });

    testWidgets('round 2, finding 3: Copy all setups says which keys could not be read, and still copies', (tester) async {
      final copied = _captureClipboard(tester);
      final real = _realAccounts(_Fakes(), DateTime.now());
      final mastodon = real.firstWhere((r) => r.account.platformId == 'mastodon');
      final telegram = real.firstWhere((r) => r.account.platformId == 'telegram');
      await _pumpAccounts(tester,
          accounts: [(mastodon.account, mastodon.secrets), (telegram.account, telegram.secrets)],
          keepDemoAccounts: false,
          secretStore: (s) => _FailingSecretStore(s.secrets, {telegram.account.id}));
      await _tap(tester, find.text('Copy all setups'));
      expect(find.text('Setups of 2 accounts copied, without keys or passwords. The keys of 1 account could not be read on this device.'), findsOneWidget);
      expect(copied.single, contains('Keys on this device: Could not be read on this device'));
      expect(copied.single, isNot(contains('SECRETINERROR')));
      await _open(tester, telegram.account.id);
      expect(find.descendant(of: _card(telegram.account.id), matching: find.text("Could not read this account's keys on this device.")), findsOneWidget);
      _expectNoSecretShown([..._shownStrings(tester), ...copied], [mastodon.secrets, telegram.secrets]);
      expect(_shownStrings(tester).where((s) => s.contains('SECRETINERROR')), isEmpty);
      await _unmount(tester);
    });

    testWidgets('closed by default; one tap opens the setup; Copy setup copies it without keys; the header names the account', (tester) async {
      final semantics = tester.ensureSemantics();
      final copied = _captureClipboard(tester);
      final fakes = _Fakes();
      final secrets = {
        OAuthTokens.keyAccessToken: fakes.next(),
        OAuthTokens.keyRefreshToken: fakes.next(),
        OAuthTokens.keyExpiresAt: _iso(DateTime.now().add(const Duration(hours: 2))),
        'client_id': fakes.next(),
        StoredSecretKeys.clientSecret: fakes.next(),
      };
      final account = _account('mastodon', PlatformTier.openApi, {'instance': 'https://mastodon.example', 'client_id': 'own-client-id'}, id: 'm1');
      await _pumpAccounts(tester, accounts: [(account, secrets)], keepDemoAccounts: false);

      final card = _card('m1');
      // Finding 9: a screen reader hears whose connection it is.
      expect(find.bySemanticsLabel('Connection for @someone on Mastodon'), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Server address')), findsNothing, reason: 'closed by default');

      await _open(tester, 'm1');
      for (final t in [
        'Network',
        'Mastodon',
        'How it posts',
        'Automatically, through the open Mastodon API',
        'Server address',
        'https://mastodon.example',
        'Client ID',
        'own-client-id',
        'Sign-in',
        'Renews when NEFORUM posts. No end date is known. Your server decides.',
        'Keys on this device',
        'Access token: stored',
        'Refresh token: stored',
        'Client ID: stored',
        'Client secret: stored',
        'Only on this device',
        'Connected',
        'Copy setup',
      ]) {
        expect(find.descendant(of: card, matching: find.text(t)), findsWidgets, reason: t);
      }
      expect(find.descendant(of: card, matching: find.byType(SelectionArea)), findsOneWidget, reason: 'the setup can be selected and copied');

      await _tap(tester, find.descendant(of: card, matching: find.text('Copy setup')));
      expect(copied, hasLength(1));
      expect(copied.single, startsWith('Setup copied from Test device on ${connectionLocalDate(DateTime.now())}\n\nMastodon: Someone (@someone)\nHow it posts: '));
      expect(copied.single, contains('\nConnected: 2026-10-12'));
      expect(copied.single, contains('Keys on this device: Access token, Refresh token, Client ID, Client secret (Only on this device)'));
      expect(find.text('Setup copied, without keys or passwords'), findsOneWidget);
      _expectNoSecretShown([..._shownStrings(tester), ...copied], [secrets]);

      await _open(tester, 'm1');
      expect(find.descendant(of: card, matching: find.text('Server address')), findsNothing, reason: 'a second tap closes it');
      semantics.dispose();
      await _unmount(tester);
    });

    testWidgets('finding 1: an Odysee card says it needs no keys instead of asking to reconnect', (tester) async {
      final odysee = _realAccounts(_Fakes(), DateTime.now()).firstWhere((r) => r.account.platformId == 'odysee');
      await _pumpAccounts(tester, accounts: [(odysee.account, odysee.secrets)], keepDemoAccounts: false);
      await _open(tester, odysee.account.id);
      final card = _card(odysee.account.id);
      expect(find.descendant(of: card, matching: find.text('None needed: it posts through the LBRY app on this device.')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('None stored')), findsNothing);
      await _unmount(tester);
    });

    testWidgets('finding 2: a sign-in that ends soon says when, and a short token does not show its time', (tester) async {
      final real = _realAccounts(_Fakes(), DateTime.now());
      final youtube = real.firstWhere((r) => r.account.platformId == 'youtube');
      final x = real.firstWhere((r) => r.account.id == 'real-x-oauth2');
      await _pumpAccounts(tester, accounts: [(youtube.account, youtube.secrets), (x.account, x.secrets)], keepDemoAccounts: false);
      await _open(tester, youtube.account.id);
      await _open(tester, x.account.id);
      expect(find.descendant(of: _card(youtube.account.id), matching: find.textContaining(RegExp(r'^Renews when NEFORUM posts, until .+ at the latest, then needs reconnecting\. If your Google app is still in Testing, Google ends the sign-in every 7 days\.$'))),
          findsOneWidget);
      expect(find.descendant(of: _card(x.account.id), matching: find.textContaining(RegExp(r'^Renews when NEFORUM posts\. Unused, it ends about .+ at the latest\.$'))), findsOneWidget, reason: 'never the two-hour token\'s time');
      await _unmount(tester);
    });

    testWidgets('Synced when sync is on, a warning when it failed; the X caveat only without sync', (tester) async {
      final x = _realAccounts(_Fakes(), DateTime.now()).firstWhere((r) => r.account.id == 'real-x-oauth2');
      final (_, services) = await _pumpAccounts(tester,
          settings: {'syncProviderId': 'webdav', 'syncConfig': <String, String>{'url': 'https://dav.example/neforum', 'username': 'someone'}},
          accounts: [(x.account, x.secrets)],
          keepDemoAccounts: false);
      final card = _card(x.account.id);
      await _open(tester, x.account.id);
      expect(find.descendant(of: card, matching: find.text('Synced')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('can stay connected on only one device')), findsNothing);

      services.cloudSync.status.value = const CloudSyncStatus(CloudSyncPhase.error, message: 'Down');
      await tester.pump();
      expect(find.descendant(of: card, matching: find.text('Sync is not working')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('can stay connected on only one device')), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('hand-off and key-less accounts say why there are no keys', (tester) async {
      final handoff = _account('instagram', PlatformTier.handoff, {'username': 'someone-else'}, id: 'h1');
      final missing = _account('bluesky', PlatformTier.openApi, {'service': 'https://bsky.example'}, id: 'b1');
      await _pumpAccounts(tester, accounts: [(handoff, const {}), (missing, const {})], keepDemoAccounts: false);
      await _open(tester, 'h1');
      await _open(tester, 'b1');
      expect(find.descendant(of: _card('h1'), matching: find.textContaining('None needed: hand-off opens')), findsOneWidget);
      expect(find.descendant(of: _card('h1'), matching: find.text('Instagram username')), findsOneWidget);
      expect(find.descendant(of: _card('b1'), matching: find.textContaining('None stored on this device')), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('the card keeps its toggles, menu and reconnect banner', (tester) async {
      final account = _account('mastodon', PlatformTier.openApi, {'instance': 'https://mastodon.example'}, id: 'm2').copyWith(lastError: 'Token revoked');
      final (c, _) = await _pumpAccounts(tester, accounts: [(account, {OAuthTokens.keyAccessToken: _Fakes().next()})], keepDemoAccounts: false);
      final card = _card('m2');
      await _open(tester, 'm2');
      expect(find.descendant(of: card, matching: find.textContaining('Needs reconnecting: Token revoked')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Reconnect')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.byTooltip('More')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Include in new posts')), findsOneWidget);
      await _tap(tester, find.descendant(of: card, matching: find.text('Enabled')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(c.read(accountByIdProvider('m2'))?.enabled, isFalse);
      expect(find.descendant(of: card, matching: find.text('Server address')), findsOneWidget, reason: 'still open after a toggle');
      await _unmount(tester);
    });

    testWidgets("1.4.3: the card's Reconnect is one prominent button; in the demo it shows the connect flow", (tester) async {
      final account = _account('mastodon', PlatformTier.openApi, {'instance': 'https://mastodon.example'}, id: 'm3').copyWith(lastError: 'Token revoked');
      final (c, _) = await _pumpAccounts(tester, accounts: [(account, {OAuthTokens.keyAccessToken: _Fakes().next()})], keepDemoAccounts: false);
      final button = find.byKey(const ValueKey('reconnect-m3'));
      expect(button, findsOneWidget);
      expect(tester.widget(button), isA<FilledButton>());
      await _tap(tester, button);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(c.read(routerProvider).state.uri.toString(), '/accounts/add?platform=mastodon');
      await _unmount(tester);
    });

    // Every account of every adapter, open at once (debugStartOpen: one
    // layout instead of one tap and layout per card; the tap itself is
    // covered above), on a phone and on a wide window.
    for (final size in const [Size(360, 800), Size(1440, 900)]) {
      testWidgets('every account of every adapter, open at ${size.width.toInt()} px: no overflow, no key on screen or clipboard', (tester) async {
        AccountConnectionSection.debugStartOpen = true;
        final copied = _captureClipboard(tester);
        final fakes = _Fakes();
        final real = _realAccounts(fakes, DateTime.now());
        final accounts = [for (final (a, s, _) in _formAccounts(fakes)) (a, s), for (final r in real) (r.account, r.secrets)];
        final (c, _) = await _pumpAccounts(tester, size: size, accounts: accounts);
        await tester.pump(const Duration(milliseconds: 300));
        final cards = find.byType(AccountCard).evaluate().length;
        expect(cards, c.read(accountListProvider).length);
        expect(find.text('Copy setup'), findsNWidgets(cards), reason: 'every section open and loaded');
        expect(tester.takeException(), isNull);
        for (final r in real) {
          expect(find.descendant(of: _card(r.account.id), matching: find.textContaining('None stored')), findsNothing, reason: r.account.id);
        }

        await _tap(tester, find.text('Copy all setups'));
        expect(copied, hasLength(1));
        for (final a in c.read(accountListProvider)) {
          expect(copied.single, contains(connectionAccountName(a)), reason: a.id);
        }
        _expectNoSecretShown([..._shownStrings(tester), ...copied], [for (final (_, s) in accounts) s]);
        await _unmount(tester);
      });
    }
  });

  testWidgets('connectionWhen writes day, month, year and time', (tester) async {
    late String text;
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue((await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage({'clockFormat': 'twentyFourHour'}))))!)],
      child: MaterialApp(home: Consumer(builder: (context, ref, _) {
        text = connectionWhen(DateTime(2026, 10, 24, 14, 5), TimeFormatting.of(context, ref));
        return const SizedBox();
      })),
    ));
    expect(text, '24 Oct 2026, 14:05');
  });
}
