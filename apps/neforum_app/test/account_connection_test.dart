// 1.3.5: Accounts > Connection. Every account card shows how the account is
// set up (server, own app, targets, sign-in expiry, which keys are stored and
// whether sync carries them) so two devices can be compared, and never shows
// a key, not even part of one.

import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/account_connection.dart';
import 'package:neforum_app/state/cloud_sync.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/accounts/account_card.dart';
import 'package:neforum_app/ui/accounts/connection_section.dart';
import 'package:neforum_app/ui/activity/time_format.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
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

/// Fake secret values: upper-case consonants and digits only, so no
/// lower-case config value, label or demo text can share 6 characters with
/// one by accident, and every one differs from the others.
class _Fakes {
  final Random _r = Random(20261101);
  String next() {
    const abc = 'BCDFGHJKLMNPQRSTVWXZ23456789';
    return 'Q${List.generate(31, (_) => abc[_r.nextInt(abc.length)]).join()}';
  }
}

final DateTime _future = DateTime.utc(2031, 1, 2, 3, 4);
final DateTime _connected = DateTime.utc(2026, 10, 12, 9, 30);

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
      FieldKind.select => '${'$v'[0].toUpperCase()}${'$v'.substring(1)}',
      _ => '$v',
    };

/// One fake account per built-in adapter and per way it connects, its
/// config filled from that way's connect form, its secrets from the form's
/// secret fields plus OAuth tokens.
List<(ConnectedAccount, Map<String, String>, ConnectSpec)> _everyAdapterAccount(_Fakes fakes) => [
      for (final a in builtinAdapters())
        for (final spec in a.connectSpecs)
          (
            ConnectedAccount(
              id: 'fake-${a.id}-${spec.tier.name}',
              platformId: a.id,
              tier: spec.tier,
              displayName: 'fake ${a.id} ${spec.tier.name.toLowerCase()}',
              handle: '@fake-${a.id}',
              createdAt: _connected,
              config: {for (final f in spec.fields) if (!f.secret) f.key: _fakeValue(a, f)},
            ),
            {
              for (final f in spec.fields) if (f.secret) f.key: fakes.next(),
              if (spec.tier != PlatformTier.handoff) ...{
                OAuthTokens.keyAccessToken: fakes.next(),
                OAuthTokens.keyRefreshToken: fakes.next(),
                OAuthTokens.keyExpiresAt: _future.toIso8601String(),
                OAuthTokens.keyTokenType: 'Bearer',
              },
            },
            spec,
          ),
    ];

/// Accounts shaped like real ones where a config value is cut from a key,
/// so only [SecretGuard] stands between the key and the screen.
List<(ConnectedAccount, Map<String, String>)> _guardCases(_Fakes fakes) {
  final consumerKey = fakes.next();
  return [
    // Tumblr with OAuth 1.0a keeps its consumer key in the config (a connect
    // field, "OAuth Consumer Key") AND with its keys.
    (
      ConnectedAccount(
        id: 'guard-tumblr',
        platformId: 'tumblr',
        tier: PlatformTier.byokApi,
        displayName: 'guard tumblr',
        handle: '@guard-tumblr',
        createdAt: _connected,
        config: {'consumerKey': consumerKey, 'blogName': 'guardblog', 'authMode': 'oauth1'},
      ),
      OAuth1Credentials(consumerKey: consumerKey, consumerSecret: fakes.next(), token: fakes.next(), tokenSecret: fakes.next()).toSecrets(),
    ),
    // Telegram's bot id is the start of the bot token.
    (
      ConnectedAccount(
        id: 'guard-telegram',
        platformId: 'telegram',
        tier: PlatformTier.openApi,
        displayName: 'guard telegram',
        createdAt: _connected,
        config: {'botId': 7700112233, 'chatTitle': 'guard channel', 'botUsername': 'guard_bot', 'formatting': 'markdown'},
      ),
      {'bot_token': '7700112233:${fakes.next()}'},
    ),
    // Ghost's key id is the start of the Admin API key.
    (
      ConnectedAccount(
        id: 'guard-ghost',
        platformId: 'ghost',
        tier: PlatformTier.openApi,
        displayName: 'guard ghost',
        createdAt: _connected,
        config: {'apiUrl': 'https://guard-ghost.example', 'keyId': 'k3yidf9e8d7c6b5', 'defaultStatus': 'draft'},
      ),
      {'admin_api_key': 'k3yidf9e8d7c6b5:${fakes.next()}'},
    ),
  ];
}

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

/// Fails when any of [shown] holds a stored key or any 6 characters in a row
/// of one. Bookkeeping entries (expiry date, token type) hold no secret and
/// are only checked whole.
void _expectNoSecretShown(Iterable<String> shown, Iterable<Map<String, String>> secretMaps) {
  final windows = <String, String>{};
  final bookkeeping = <String>{};
  for (final secrets in secretMaps) {
    for (final e in secrets.entries) {
      if (kSecretBookkeepingKeys.contains(e.key)) {
        bookkeeping.add(e.value);
        continue;
      }
      for (var i = 0; i + 6 <= e.value.length; i++) {
        windows[e.value.substring(i, i + 6)] = e.key;
      }
    }
  }
  for (final text in shown) {
    for (var i = 0; i + 6 <= text.length; i++) {
      final key = windows[text.substring(i, i + 6)];
      if (key != null) fail('Shows part of a stored "$key": "$text"');
    }
    for (final b in bookkeeping) {
      if (b.length >= 6 && text.contains(b)) fail('Shows a stored bookkeeping value: "$text"');
    }
  }
}

Future<(ProviderContainer, AppServices)> _pumpAccounts(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  Map<String, Object> settings = const {},
  List<(ConnectedAccount, Map<String, String>)> accounts = const [],
  bool keepDemoAccounts = true,
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
  await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
  await tester.pump(const Duration(milliseconds: 300));
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  container.read(routerProvider).go('/accounts');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return (container, services);
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

Future<void> _open(WidgetTester tester, Finder header) => _tap(tester, header);

/// Opens the Connection section of every card on the page.
Future<int> _openAll(WidgetTester tester) async {
  final headers = find.text('Connection');
  final n = headers.evaluate().length;
  for (var i = 0; i < n; i++) {
    await _tap(tester, headers.at(i));
  }
  return n;
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

    test('the account\'s own way of connecting names a key both ways share', () {
      // Lemmy's "Default community" field exists on both forms; Bluesky's
      // handle only on the hand-off form, which still names it for Auto.
      final bluesky = connectionDetails(
        _account('bluesky', PlatformTier.openApi, {'service': 'https://bsky.example', 'pds': 'https://pds.example', 'handle': 'someone.bsky.example', 'did': 'did:plc:abc'}),
        _adapter('bluesky'),
      );
      expect(bluesky.map((d) => '$d'), [
        'Hosting provider: https://bsky.example',
        'Handle: someone.bsky.example',
        'PDS (data server): https://pds.example',
        'Account ID (DID): did:plc:abc',
      ]);
    });

    test('keys the form does not ask for come from the reviewed list; caches, ids and limits are left out', () {
      final facebook = connectionDetails(
        _account('facebook', PlatformTier.byokApi, {
          'app_id': '1234',
          'page_id': '99',
          'page_name': 'Some Page',
          'user_id': '42',
          'available_pages': [
            {'id': '1', 'name': 'Other'},
          ],
          'scopes': 'pages_manage_posts,pages_show_list',
        }),
        _adapter('facebook'),
      );
      expect(facebook.map((d) => '$d'), ['App ID: 1234', 'Permissions: pages_manage_posts,pages_show_list', 'Page: Some Page']);

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
    });

    test('values read as words: choices capitalised, booleans Yes or No, lists one per line, unknown sign-in codes left out', () {
      final discord = connectionDetails(_account('discord', PlatformTier.openApi, {'username': 'Poster', 'forum': true, 'webhookName': 'hook'}), _adapter('discord'));
      expect(discord.map((d) => '$d'), ['Post as: Poster', 'Forum or media channel: Yes', 'Webhook: hook']);

      final nostr = connectionDetails(
          _account('nostr', PlatformTier.openApi, {'relays': ['wss://a.example', 'wss://b.example'], 'npub': 'npub1xyz', 'pubkey': 'abcd'}), _adapter('nostr'));
      expect(nostr.map((d) => '$d'), ['Relays: wss://a.example\nwss://b.example', 'Public key (npub): npub1xyz']);

      final matrix = connectionDetails(_account('matrix', PlatformTier.openApi, {'homeserver': 'https://m.example', 'formatting': 'plain', 'authMethod': 'something-new'}), _adapter('matrix'));
      expect(matrix.map((d) => '$d'), ['Homeserver: https://m.example', 'Formatting: Plain']);
    });

    test('a platform-limited label is not used on other platforms', () {
      final discord = connectionDetails(_account('discord', PlatformTier.openApi, {'channelId': '111', 'guildId': '222'}), _adapter('discord'));
      expect(discord, isEmpty, reason: 'Discord ids are not shown');
      final youtube = connectionDetails(_account('youtube', PlatformTier.byokApi, {'clientId': 'cid.apps.example', 'channelId': 'UCabc'}), _adapter('youtube'));
      expect(youtube.map((d) => '$d'), ['Client ID: cid.apps.example', 'Channel ID: UCabc']);
    });
  });

  group('keys', () {
    test('stored keys get friendly labels in a stable order; bookkeeping and empty entries are not keys', () {
      final labels = storedKeyLabels({
        OAuthTokens.keyExpiresAt: _future.toIso8601String(),
        OAuthTokens.keyTokenType: 'Bearer',
        OAuthTokens.keyScope: 'write',
        'client_secret': 'x' * 10,
        OAuthTokens.keyRefreshToken: 'y' * 10,
        OAuthTokens.keyAccessToken: 'z' * 10,
        'app_password': '',
        'token_issued_at': _future.toIso8601String(),
        'some_new_key': 'w' * 10,
      }, _adapter('x'));
      expect(labels, ['Access token', 'Refresh token', 'Client secret', 'Some new key']);
    });

    test('a key no label covers is named by its connect field, else by its name in words', () {
      expect(storedKeyLabels({'oauthTokenSecret': 'v' * 10}, _adapter('tumblr')), ['OAuth Token Secret']);
      expect(humanizeKey('user_access_token'), 'User access token');
      expect(humanizeKey('apiKey'), 'Api key');
    });

    test('the guard withholds any value sharing 6 characters with a key, and keys shorter than that whole', () {
      final guard = SecretGuard({'webhook_url': 'https://chat.example/api/webhooks/123456/TOKENVALUE?thread_id=987654', 'pin': '4821', 'expires_at': '2031-01-02'});
      expect(guard.reveals('987654'), isTrue, reason: 'a thread id cut from the webhook address');
      expect(guard.reveals('xxTOKENVxx'), isTrue);
      expect(guard.reveals('code 4821'), isTrue);
      expect(guard.reveals('hook name'), isFalse);
      expect(guard.reveals('2031-01-02'), isFalse, reason: 'bookkeeping is not a secret');
    });

    test('a config value cut from a key is never shown, even when it is a connect field', () {
      final fakes = _Fakes();
      for (final (account, secrets) in _guardCases(fakes)) {
        final c = describeAccountConnection(account, adapter: _adapter(account.platformId), secrets: secrets, now: DateTime.utc(2026, 11, 1));
        _expectNoSecretShown([for (final d in c.details) d.value, connectionSetupText(account, c, travel: KeysTravel.synced, when: (t) => '$t')], [secrets]);
      }
      final (tumblr, tumblrSecrets) = _guardCases(_Fakes()).first;
      final c = describeAccountConnection(tumblr, adapter: _adapter('tumblr'), secrets: tumblrSecrets, now: DateTime.utc(2026, 11, 1));
      expect(c.details.map((d) => d.label), isNot(contains('OAuth Consumer Key')));
      expect(c.details.map((d) => '$d'), containsAll(['Blog: guardblog', 'Sign-in method: OAuth 1.0a keys']));
      expect(c.storedKeys, contains('Consumer key (API key)'));
    });
  });

  group('sign-in expiry', () {
    final now = DateTime.utc(2026, 11, 1, 12);
    final soon = now.add(const Duration(days: 30)).toIso8601String();
    final past = now.subtract(const Duration(days: 3)).toIso8601String();

    test('no expiry stored: nothing to show', () {
      expect(signInExpiry({OAuthTokens.keyAccessToken: 'a'}, now: now), isNull);
      expect(signInExpiry({OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: 'not a date'}, now: now), isNull);
    });

    test('a refresh token renews it, before and after it runs out', () {
      final ahead = signInExpiry({OAuthTokens.keyExpiresAt: soon, OAuthTokens.keyRefreshToken: 'r'}, now: now)!;
      expect((ahead.expired, ahead.renewsAutomatically, ahead.needsReconnecting), (false, true, false));
      final behind = signInExpiry({OAuthTokens.keyExpiresAt: past, OAuthTokens.keyRefreshToken: 'r'}, now: now)!;
      expect((behind.expired, behind.renewsAutomatically, behind.needsReconnecting), (true, true, false));
    });

    test('a refresh token that ran out itself cannot renew anything', () {
      final e = signInExpiry({OAuthTokens.keyExpiresAt: past, OAuthTokens.keyRefreshToken: 'r', 'refresh_expires_at': past}, now: now)!;
      expect(e.needsReconnecting, isTrue);
    });

    test('without a refresh token: valid until the date, then needs reconnecting', () {
      final ahead = signInExpiry({OAuthTokens.keyExpiresAt: soon, OAuthTokens.keyAccessToken: 'a'}, now: now)!;
      expect((ahead.renewsAutomatically, ahead.needsReconnecting), (false, false));
      final behind = signInExpiry({OAuthTokens.keyExpiresAt: past, OAuthTokens.keyAccessToken: 'a'}, now: now)!;
      expect(behind.needsReconnecting, isTrue);
    });

    test('a token that renews itself (Threads, Instagram) renews only while it is valid', () {
      final ahead = signInExpiry({OAuthTokens.keyExpiresAt: soon, 'token_issued_at': past}, now: now)!;
      expect(ahead.renewsAutomatically, isTrue);
      final behind = signInExpiry({OAuthTokens.keyExpiresAt: past, 'refreshed_at': past}, now: now)!;
      expect(behind.needsReconnecting, isTrue);
    });

    test('Bluesky signs in again with its app password', () {
      final e = signInExpiry({OAuthTokens.keyExpiresAt: past, OAuthTokens.keyAccessToken: 'a', 'app_password': 'p'}, now: now)!;
      expect(e.needsReconnecting, isFalse);
    });

    test('the wording says the date and what happens next', () {
      String when(DateTime t) => 'WHEN';
      SignInExpiry e({required bool expired, required bool renews}) => SignInExpiry(expiresAt: now, expired: expired, renewsAutomatically: renews);
      expect(signInText(e(expired: false, renews: true), when), 'Valid until WHEN. Renews automatically.');
      expect(signInText(e(expired: false, renews: false), when), 'Valid until WHEN. Then needs reconnecting.');
      expect(signInText(e(expired: true, renews: true), when), 'Ran out on WHEN. Renews automatically before the next post.');
      expect(signInText(e(expired: true, renews: false), when), 'Ran out on WHEN. Needs reconnecting.');
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

  test('every built-in adapter, every way it connects: each form field shows under its own label, no key shows', () {
    final now = DateTime.utc(2026, 11, 1);
    final cases = _everyAdapterAccount(_Fakes());
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
      if (spec.tier != PlatformTier.handoff) {
        expect(c.storedKeys, containsAll(['Access token', 'Refresh token']), reason: account.id);
        expect(c.signIn?.renewsAutomatically, isTrue, reason: account.id);
      } else {
        expect(c.storedKeys, isEmpty, reason: account.id);
      }
      expect(c.method, connectionMethodText(spec.tier, adapter.descriptor.name));
      final text = connectionSetupText(account, c, travel: KeysTravel.thisDeviceOnly, when: (t) => '${t.day}/${t.month}/${t.year}');
      _expectNoSecretShown([...shown.values, ...c.storedKeys, text], [secrets]);
    }
  });

  test('the copied setup lists what the section shows and no key', () {
    final fakes = _Fakes();
    final secrets = {OAuthTokens.keyAccessToken: fakes.next(), OAuthTokens.keyRefreshToken: fakes.next(), OAuthTokens.keyExpiresAt: _future.toIso8601String()};
    final account = _account('mastodon', PlatformTier.openApi, {'instance': 'https://mastodon.example', 'software': 'mastodon'});
    final c = describeAccountConnection(account, adapter: _adapter('mastodon'), secrets: secrets, now: DateTime.utc(2026, 11, 1));
    final text = connectionSetupText(account, c, travel: KeysTravel.synced, when: (t) => t.toUtc().toIso8601String().substring(0, 10));
    expect(text, '''
Mastodon: Someone (@someone)
How it posts: Automatically, through the open Mastodon API
Server address: https://mastodon.example
Server software: mastodon
Sign-in: Valid until 2031-01-02. Renews automatically.
Keys on this device: Access token, Refresh token (Synced)
Connected: 2026-10-12''');
    _expectNoSecretShown([text], [secrets]);
  });

  group('on the Accounts page', () {
    testWidgets('closed by default; one tap opens the setup; Copy setup copies it without keys', (tester) async {
      final copied = _captureClipboard(tester);
      final fakes = _Fakes();
      final secrets = {
        OAuthTokens.keyAccessToken: fakes.next(),
        OAuthTokens.keyRefreshToken: fakes.next(),
        OAuthTokens.keyExpiresAt: _future.toIso8601String(),
        'client_id': fakes.next(),
        'client_secret': fakes.next(),
      };
      final account = _account('mastodon', PlatformTier.openApi, {'instance': 'https://mastodon.example', 'client_id': 'own-client-id'}, id: 'm1');
      await _pumpAccounts(tester, accounts: [(account, secrets)], keepDemoAccounts: false);

      final card = _card('m1');
      expect(find.descendant(of: card, matching: find.text('Connection')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Server address')), findsNothing, reason: 'closed by default');

      await _open(tester, find.descendant(of: card, matching: find.text('Connection')));
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
      expect(find.descendant(of: card, matching: find.textContaining('Renews automatically')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.byType(SelectionArea)), findsOneWidget, reason: 'the setup can be selected and copied');

      await _tap(tester, find.descendant(of: card, matching: find.text('Copy setup')));
      expect(copied, hasLength(1));
      expect(copied.single, startsWith('Mastodon: Someone (@someone)\nHow it posts: '));
      expect(copied.single, contains('Server address: https://mastodon.example'));
      expect(copied.single, contains('Keys on this device: Access token, Refresh token, Client ID, Client secret (Only on this device)'));
      expect(find.text('Setup copied, without keys or passwords'), findsOneWidget);
      _expectNoSecretShown([..._shownStrings(tester), ...copied], [secrets]);

      // A second tap closes it again.
      await _open(tester, find.descendant(of: card, matching: find.text('Connection')));
      expect(find.descendant(of: card, matching: find.text('Server address')), findsNothing);
      await _unmount(tester);
    });

    testWidgets('Synced when sync is on, a warning when it failed; the X caveat only without sync', (tester) async {
      final fakes = _Fakes();
      final x = _account('x', PlatformTier.byokApi, {'clientId': 'x-client', 'authMode': 'oauth2'}, id: 'x1');
      final xSecrets = {OAuthTokens.keyAccessToken: fakes.next(), OAuthTokens.keyRefreshToken: fakes.next()};
      final (_, services) = await _pumpAccounts(tester,
          settings: {'syncProviderId': 'webdav', 'syncConfig': <String, String>{'url': 'https://dav.example/neforum', 'username': 'someone'}},
          accounts: [(x, xSecrets)],
          keepDemoAccounts: false);
      final card = _card('x1');
      await _open(tester, find.descendant(of: card, matching: find.text('Connection')));
      expect(find.descendant(of: card, matching: find.text('Synced')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('can stay connected on only one device')), findsNothing);
      expect(find.descendant(of: card, matching: find.text('Sign-in method')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Browser sign-in (OAuth 2.0)')), findsOneWidget);

      services.cloudSync.status.value = const CloudSyncStatus(CloudSyncPhase.error, message: 'Down');
      await tester.pump();
      expect(find.descendant(of: card, matching: find.text('Sync is not working')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('can stay connected on only one device')), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('hand-off, demo and key-less accounts say why there are no keys', (tester) async {
      final handoff = _account('instagram', PlatformTier.handoff, {'username': 'someone'}, id: 'h1');
      final missing = _account('bluesky', PlatformTier.openApi, {'service': 'https://bsky.example'}, id: 'b1');
      await _pumpAccounts(tester, accounts: [(handoff, const {}), (missing, const {})], keepDemoAccounts: false);
      await _openAll(tester);
      expect(find.descendant(of: _card('h1'), matching: find.textContaining('None needed')), findsOneWidget);
      expect(find.descendant(of: _card('h1'), matching: find.text('Instagram username')), findsOneWidget);
      expect(find.descendant(of: _card('b1'), matching: find.textContaining('None stored on this device')), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('a sign-in that ran out and cannot renew says it needs reconnecting', (tester) async {
      final linkedin = _account('linkedin', PlatformTier.byokApi, {'clientId': 'li-client', 'apiVersion': '202610'}, id: 'l1');
      final secrets = {OAuthTokens.keyAccessToken: _Fakes().next(), OAuthTokens.keyExpiresAt: DateTime.utc(2026, 1, 1).toIso8601String()};
      await _pumpAccounts(tester, accounts: [(linkedin, secrets)], keepDemoAccounts: false);
      await _open(tester, find.descendant(of: _card('l1'), matching: find.text('Connection')));
      expect(find.descendant(of: _card('l1'), matching: find.textContaining('Needs reconnecting.')), findsOneWidget);
      expect(find.descendant(of: _card('l1'), matching: find.text('LinkedIn API version')), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('the card keeps its toggles, menu and reconnect banner', (tester) async {
      final account = _account('mastodon', PlatformTier.openApi, {'instance': 'https://mastodon.example'}, id: 'm2').copyWith(lastError: 'Token revoked');
      final (c, _) = await _pumpAccounts(tester, accounts: [(account, {OAuthTokens.keyAccessToken: _Fakes().next()})], keepDemoAccounts: false);
      final card = _card('m2');
      await _open(tester, find.descendant(of: card, matching: find.text('Connection')));
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

    for (final size in const [Size(360, 800), Size(1440, 900)]) {
      testWidgets('every account of every adapter opens at ${size.width.toInt()} px with no overflow and no key on screen or clipboard', (tester) async {
        final copied = _captureClipboard(tester);
        final fakes = _Fakes();
        final accounts = [for (final (a, s, _) in _everyAdapterAccount(fakes)) (a, s), ..._guardCases(fakes)];
        final (c, _) = await _pumpAccounts(tester, size: size, accounts: accounts);
        final cards = find.byType(AccountCard).evaluate().length;
        expect(cards, c.read(accountListProvider).length);

        final opened = await _openAll(tester);
        expect(opened, cards);
        expect(find.text('Copy setup'), findsNWidgets(cards), reason: 'every section opened and loaded');
        expect(tester.takeException(), isNull);

        await _tap(tester, find.text('Copy all setups'));
        await tester.pump();
        expect(copied, hasLength(1));
        for (final a in c.read(accountListProvider)) {
          expect(copied.single, contains(a.displayName), reason: a.id);
        }

        _expectNoSecretShown([..._shownStrings(tester), ...copied], [for (final (_, s) in accounts) s]);
        await _unmount(tester);
      });
    }
  });

  test('the in-app guides for a second device say where to see an account\'s setup', () {
    for (final guide in ['assets/docs/sync.md', 'assets/docs/backup.md']) {
      final text = File(guide).readAsStringSync();
      expect(text, contains('go to **Accounts** and open **Connection**'), reason: guide);
      expect(text, contains('**Copy all setups**'), reason: guide);
      expect(File('../../docs/${guide.split('/').last}').readAsStringSync(), text, reason: 'run dart run tool/sync_docs.dart');
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
