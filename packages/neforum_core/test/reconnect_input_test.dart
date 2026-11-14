import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import 'support/test_context.dart';

// 1.4.3: one-tap Reconnect fills the connect form from what the first sign-in
// stored. Each case is an account as that platform's connect() stores it (read
// from the adapter), and the answers a browser sign-in again needs.

const _loopback = 'http://127.0.0.1:52771/callback';

/// The tokens every sign-in leaves, which a reconnect must never hand back.
const _tokens = {
  'access_token': 'AT-secret-value',
  'refresh_token': 'RT-secret-value',
  'expires_at': '2026-10-07T14:00:00.000Z',
};

typedef _Case = ({PlatformTier tier, Map<String, dynamic> config, Map<String, String> secrets, Map<String, String>? want});

final Map<String, _Case> _cases = {
  'x': (
    tier: PlatformTier.byokApi,
    config: {'authMode': 'oauth2', 'clientId': 'x-client', 'confidentialClient': true, 'userId': '42'},
    secrets: {..._tokens, 'client_secret': 'x-secret'},
    want: {'client_id': 'x-client', 'client_secret': 'x-secret'},
  ),
  'tumblr': (
    tier: PlatformTier.byokApi,
    config: {'authMode': 'oauth2', 'redirectUri': _loopback, 'consumerKey': 'tumblr-key', 'blogName': 'myblog', 'blogNames': ['myblog', 'other']},
    secrets: {..._tokens, 'consumer_secret': 'tumblr-secret'},
    want: {'consumerKey': 'tumblr-key', 'consumerSecret': 'tumblr-secret', 'blog': 'myblog'},
  ),
  'linkedin': (
    tier: PlatformTier.byokApi,
    config: {'clientId': 'li-client', 'apiVersion': '202510', 'sub': 'abc', 'personUrn': 'urn:li:person:abc', 'redirectUri': _loopback},
    secrets: {..._tokens, 'client_secret': 'li-secret'},
    want: {'clientId': 'li-client', 'clientSecret': 'li-secret', 'apiVersion': '202510'},
  ),
  'pinterest': (
    tier: PlatformTier.byokApi,
    config: {'appId': 'pin-app', 'boardId': 'board-1', 'boardName': 'Recipes', 'username': 'robin', 'accessLevel': 'standard', 'redirectUri': _loopback},
    secrets: {..._tokens, 'app_secret': 'pin-secret'},
    want: {'appId': 'pin-app', 'appSecret': 'pin-secret', 'board': 'board-1', 'accessLevel': 'standard', 'redirectHost': '127.0.0.1'},
  ),
  'reddit': (
    tier: PlatformTier.byokApi,
    config: {'clientId': 'reddit-client', 'username': 'robin', 'userId': 't2_1', 'defaultSubreddit': 'test', 'uaPlatform': 'windows'},
    secrets: _tokens,
    want: {'client_id': 'reddit-client', 'default_subreddit': 'test'},
  ),
  'threads': (
    tier: PlatformTier.byokApi,
    config: {'app_id': 'threads-app', 'redirect_uri': 'https://example.org/threads/callback', 'token_source': 'oauth', 'user_id': '7', 'username': 'robin'},
    secrets: {..._tokens, 'app_secret': 'threads-secret', 'token_issued_at': '2026-10-01T00:00:00.000Z'},
    want: {'app_id': 'threads-app', 'app_secret': 'threads-secret', 'redirect_uri': 'https://example.org/threads/callback'},
  ),
  // The browser sign-in needs the app secret, which is not kept.
  'instagram': (
    tier: PlatformTier.byokApi,
    config: {'tokenSource': 'oauth', 'appId': 'ig-app', 'redirectUri': 'https://example.org/ig', 'igUserId': '9', 'username': 'robin'},
    secrets: _tokens,
    want: null,
  ),
  'facebook': (
    tier: PlatformTier.byokApi,
    config: {'app_id': '1234567', 'page_id': 'page-1', 'page_name': 'Bakery', 'scopes': 'pages_show_list,pages_manage_posts', 'available_pages': <Object>[]},
    secrets: {..._tokens, 'app_secret': 'fb-secret', 'user_access_token': 'UAT-secret-value'},
    want: {'app_id': '1234567', 'app_secret': 'fb-secret', 'page': 'page-1', 'scopes': 'pages_show_list,pages_manage_posts'},
  ),
  'tiktok': (
    tier: PlatformTier.byokApi,
    config: {'clientKey': 'tt-key', 'openId': 'open-1'},
    secrets: {..._tokens, 'client_secret': 'tt-secret'},
    want: {'client_key': 'tt-key', 'client_secret': 'tt-secret'},
  ),
  'youtube': (
    tier: PlatformTier.byokApi,
    config: {'clientId': 'yt-client.apps.googleusercontent.com', 'channelId': 'UC1', 'redirectUri': _loopback, 'canDeleteVideos': true},
    secrets: {..._tokens, 'client_secret': 'yt-secret'},
    want: {'client_id': 'yt-client.apps.googleusercontent.com', 'client_secret': 'yt-secret'},
  ),
  'mastodon': (
    tier: PlatformTier.openApi,
    config: {'instance': 'https://mastodon.example', 'domain': 'mastodon.example', 'software': 'mastodon', 'redirectUri': _loopback, 'scopes': 'profile write'},
    secrets: {..._tokens, 'client_id': 'm-client', 'client_secret': 'm-secret'},
    want: {'instance': 'https://mastodon.example', 'client_id': 'm-client', 'client_secret': 'm-secret'},
  ),
  'pixelfed': (
    tier: PlatformTier.openApi,
    config: {'instance': 'https://pixelfed.example', 'domain': 'pixelfed.example', 'software': 'pixelfed', 'redirectUri': _loopback},
    secrets: {..._tokens, 'client_id': 'p-client', 'client_secret': 'p-secret'},
    want: {'instance': 'https://pixelfed.example', 'client_id': 'p-client', 'client_secret': 'p-secret'},
  ),
  'misskey': (
    tier: PlatformTier.openApi,
    config: {'instance': 'https://misskey.example', 'authMethod': 'miauth', 'userId': 'u1', 'username': 'robin'},
    secrets: _tokens,
    want: {'instance': 'https://misskey.example'},
  ),
  'deviantart': (
    tier: PlatformTier.byokApi,
    config: {'clientId': 'da-client', 'redirectUri': _loopback, 'userId': 'u1'},
    secrets: {..._tokens, 'client_secret': 'da-secret'},
    want: {'clientId': 'da-client', 'clientSecret': 'da-secret'},
  ),
  // Dribbble's client secret is used once and not kept.
  'dribbble': (
    tier: PlatformTier.byokApi,
    config: {'clientId': 'dr-client', 'redirectUri': _loopback, 'canUploadShot': true},
    secrets: _tokens,
    want: null,
  ),
  'flickr': (
    tier: PlatformTier.byokApi,
    config: {'userNsid': '1@N0', 'username': 'robin'},
    secrets: {'oauth1_consumer_key': 'fl-key', 'oauth1_consumer_secret': 'fl-secret', 'oauth1_token': 'FT-secret-value', 'oauth1_token_secret': 'FTS-secret-value'},
    want: {'apiKey': 'fl-key', 'apiSecret': 'fl-secret'},
  ),
  'micropub': (
    tier: PlatformTier.openApi,
    config: {'me': 'https://blog.example/', 'micropubEndpoint': 'https://blog.example/micropub', 'authMethod': 'indieauth', 'clientId': 'https://neforum.example/'},
    secrets: _tokens,
    want: {'me': 'https://blog.example/', 'clientId': 'https://neforum.example/'},
  ),
  // The application password is never handed back: the browser makes a new one.
  'wordpress': (
    tier: PlatformTier.openApi,
    config: {'site': 'https://blog.example', 'home': 'https://blog.example', 'username': 'robin', 'siteName': 'Blog', 'defaultStatus': 'draft'},
    secrets: {'app_password': 'abcd efgh ijkl mnop'},
    want: {'site': 'https://blog.example', 'username': 'robin', 'defaultStatus': 'draft'},
  ),
};

ConnectedAccount _account(String platformId, _Case c) => fakeAccount(platformId, tier: c.tier, config: c.config);

void main() {
  final registry = builtinRegistry();

  test('every platform with a browser sign-in has a case here', () {
    final browser = {
      for (final a in builtinAdapters())
        if (a.connectSpecs.any((s) => s.usesBrowser)) a.id,
    };
    expect(_cases.keys.toSet(), browser);
  });

  for (final e in _cases.entries) {
    test('${e.key}: the answers come back from what the sign-in stored', () {
      final c = e.value;
      final got = registry.require(e.key).reconnectInput(_account(e.key, c), c.secrets, redirect: Uri.parse(_loopback));
      expect(got, c.want);
    });

    test('${e.key}: never hands back a token or a password', () {
      final c = e.value;
      final got = registry.require(e.key).reconnectInput(_account(e.key, c), c.secrets, redirect: Uri.parse(_loopback)) ?? const {};
      final secretValues = {
        for (final s in c.secrets.entries)
          if (s.key.contains('token') || s.key.contains('password')) s.value,
      };
      expect(got.values.where(secretValues.contains), isEmpty);
      expect(got.keys.where((k) => k.toLowerCase().contains('token') || k.toLowerCase().contains('password')), isEmpty);
    });
  }

  group('nothing to sign in again with', () {
    test('keys that were pasted rather than signed in for', () {
      for (final (platform, config) in [
        ('x', {'authMode': 'oauth1', 'userId': '42'}),
        ('tumblr', {'authMode': 'oauth1', 'consumerKey': 'k', 'blogName': 'b'}),
        ('threads', {'app_id': 'a', 'token_source': 'pasted'}),
        ('misskey', {'instance': 'https://misskey.example', 'authMethod': 'token'}),
        ('micropub', {'me': 'https://blog.example/', 'authMethod': 'token'}),
      ]) {
        final account = fakeAccount(platform, tier: registry.require(platform).descriptor.defaultTier == PlatformTier.handoff ? PlatformTier.byokApi : registry.require(platform).descriptor.defaultTier, config: config);
        expect(registry.require(platform).reconnectInput(account, {..._tokens, 'client_secret': 's', 'app_secret': 's', 'consumer_secret': 's'}), isNull, reason: platform);
      }
    });

    test('platforms whose keys have no browser sign-in', () {
      for (final (platform, tier) in [('bluesky', PlatformTier.openApi), ('telegram', PlatformTier.openApi), ('discord', PlatformTier.openApi), ('nostr', PlatformTier.openApi)]) {
        final adapter = registry.byId(platform);
        if (adapter == null) continue;
        final account = fakeAccount(platform, tier: adapter.descriptor.tiers.contains(tier) ? tier : adapter.descriptor.defaultTier);
        expect(adapter.reconnectInput(account, {'app_password': 'p', 'bot_token': 't'}), isNull, reason: platform);
      }
    });

    test('a hand-off account', () {
      expect(registry.require('x').reconnectInput(fakeAccount('x', tier: PlatformTier.handoff), _tokens), isNull);
    });

    test('a required answer the sign-in did not keep', () {
      final r = _cases['reddit']!;
      expect(registry.require('reddit').reconnectInput(fakeAccount('reddit', tier: PlatformTier.byokApi, config: {}), r.secrets), isNull);
    });
  });

  group('redirect addresses', () {
    test("this device's loopback or app address is chosen again, an https page the person registered is kept", () {
      final da = _cases['deviantart']!;
      final kept = registry.require('deviantart').reconnectInput(
          fakeAccount('deviantart', tier: PlatformTier.byokApi, config: {...da.config, 'redirectUri': 'https://example.org/da'}), da.secrets);
      expect(kept!['redirectUri'], 'https://example.org/da');
      final mobile = registry.require('deviantart').reconnectInput(
          fakeAccount('deviantart', tier: PlatformTier.byokApi, config: {...da.config, 'redirectUri': 'neforum://callback'}), da.secrets);
      expect(mobile!.containsKey('redirectUri'), isFalse);
    });

    test('Mastodon reuses the app it registered only where the browser comes back to the same address', () {
      final c = _cases['mastodon']!;
      final mastodon = registry.require('mastodon');
      final phone = mastodon.reconnectInput(_account('mastodon', c), c.secrets, redirect: Uri.parse('neforum://callback'));
      expect(phone, {'instance': 'https://mastodon.example'});
      final same = mastodon.reconnectInput(_account('mastodon', c), c.secrets, redirect: Uri.parse(_loopback));
      expect(same, c.want);
    });
  });

  test('X: a sign-in made through the form comes back as the same answers', () async {
    final ctx = testContext(
      broker: FakeAuthBroker(),
      handler: (req) async => req.url.path == '/2/oauth2/token'
          ? http.Response(jsonEncode({'token_type': 'bearer', 'expires_in': 7200, 'access_token': 'at-1', 'refresh_token': 'rt-1'}), 200, headers: jsonHeaders)
          : http.Response(jsonEncode({'data': {'id': '42', 'name': 'Alice', 'username': 'alice'}}), 200, headers: jsonHeaders),
    );
    const typed = {'client_id': 'cid-123', 'client_secret': 'shh'};
    final x = registry.require('x');
    final first = await x.connect(PlatformTier.byokApi, typed, ctx);
    expect(x.reconnectInput(first.account, first.secrets, redirect: Uri.parse(_loopback)), typed);
  });
}
