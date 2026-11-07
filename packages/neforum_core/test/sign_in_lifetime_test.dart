// U8a: the sign-in model, per-account status, and the fix for each adapter.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/art/deviantart_adapter.dart';
import 'package:neforum_core/src/adapters/art/pixelfed_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_b/micropub_adapter.dart';
import 'package:neforum_core/src/adapters/bluesky/bluesky_adapter.dart';
import 'package:neforum_core/src/adapters/chat/matrix_adapter.dart';
import 'package:neforum_core/src/adapters/chat/telegram_api.dart';
import 'package:neforum_core/src/adapters/facebook/facebook_adapter.dart';
import 'package:neforum_core/src/adapters/lemmy/lemmy_adapter.dart';
import 'package:neforum_core/src/adapters/linkedin/linkedin_adapter.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_adapter.dart';
import 'package:neforum_core/src/adapters/pinterest/pinterest_adapter.dart';
import 'package:neforum_core/src/adapters/threads/threads_adapter.dart';
import 'package:neforum_core/src/adapters/threads/threads_api.dart';
import 'package:neforum_core/src/adapters/tiktok/tiktok_adapter.dart';
import 'package:neforum_core/src/adapters/x/x_adapter.dart';
import 'package:neforum_core/src/auth/jwt.dart';
import 'package:test/test.dart';

final _now = DateTime.utc(2026, 11, 6, 12);
String _iso(DateTime t) => t.toUtc().toIso8601String();

ConnectedAccount _acct(String platform, PlatformTier tier, {Map<String, dynamic> config = const {}, String? id}) =>
    ConnectedAccount(id: id ?? 'acc-$platform', platformId: platform, tier: tier, displayName: platform, createdAt: _now, config: config);

/// An [AdapterContext] over [handler], counting nothing else.
AdapterContext _ctx(Future<http.Response> Function(http.Request r) handler, {Logger? log}) =>
    AdapterContext(http: NeforumHttp(client: MockClient(handler), maxRetries: 0), clock: () => _now, log: log);

final _noNetwork = _ctx((r) async => fail('no network expected: ${r.url.host}'));

/// A JWT with [payload]; the signature is not read.
String _jwt(Map<String, Object?> payload) => 'e30.${base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '')}.sig';

void main() {
  group('migration: 1.3.5 stored secrets', () {
    const neutral = SignInPolicy(limit: SignInLimit.undocumented, renewal: SignInRenewal.onUse);

    test('no new keys read as source unknown and still show the date', () {
      final end = _now.add(const Duration(days: 40));
      final linkedIn = deriveSignInLifetime(SignInPolicies.linkedIn, {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: _iso(end)}, now: _now);
      expect((linkedIn.source, linkedIn.expiresAt, linkedIn.state), (SignInDateSource.unknown, end, SignInState.endsOn));
      final tiktok = deriveSignInLifetime(SignInPolicies.tikTok, {OAuthTokens.keyRefreshToken: 'r', StoredSecretKeys.refreshExpiresAt: _iso(end)}, now: _now);
      expect((tiktok.source, tiktok.expiresAt, tiktok.state), (SignInDateSource.unknown, end, SignInState.renewsUntil));
    });

    test('a window with no stamp estimates from the access token, source unknown, about', () {
      final access = _now.add(const Duration(hours: 1));
      final x = deriveSignInLifetime(SignInPolicies.xOAuth2, {OAuthTokens.keyRefreshToken: 'r', OAuthTokens.keyExpiresAt: _iso(access)}, now: _now);
      expect((x.source, x.about, x.expiresAt), (SignInDateSource.unknown, true, access.add(const Duration(days: 183))));
    });

    test('an unknown source name reads as unknown: a newer value cannot break an older device', () {
      expect(SignInDateSource.parse('fromTheFuture'), SignInDateSource.unknown);
      expect(SignInDateSource.parse(null), SignInDateSource.unknown);
      expect(SignInLimit.parse('fromTheFuture'), SignInLimit.undocumented);
    });

    test('no policy with no connection ever gets a state beyond no date', () {
      expect(deriveSignInLifetime(SignInPolicy.noConnection, {OAuthTokens.keyExpiresAt: _iso(_now)}, now: _now).state, SignInState.noDate);
      expect(deriveSignInLifetime(neutral, const {}, now: _now).state, SignInState.noDate);
    });
  });

  group('the model', () {
    test('a disuse window gives last renewal + window, about', () {
      final renewed = _now.subtract(const Duration(days: 2));
      final tumblr = deriveSignInLifetime(SignInPolicies.tumblrOAuth2, {
        OAuthTokens.keyRefreshToken: 'r',
        OAuthTokens.keyExpiresAt: _iso(renewed.add(const Duration(minutes: 42))),
        StoredSecretKeys.lastRenewedAt: _iso(renewed),
      }, now: _now);
      expect((tumblr.state, tumblr.source, tumblr.about, tumblr.renewsItself), (SignInState.renewsUntil, SignInDateSource.computed, true, true));
      expect(tumblr.expiresAt, renewed.add(const Duration(days: 42)));
    });

    test('a window that has passed says it ended, as an estimate', () {
      final renewed = _now.subtract(const Duration(days: 200));
      final x = deriveSignInLifetime(SignInPolicies.xOAuth2, {OAuthTokens.keyRefreshToken: 'r', StoredSecretKeys.lastRenewedAt: _iso(renewed)}, now: _now);
      expect((x.state, x.about), (SignInState.ended, true));
    });

    test('M12: a pasted Instagram token: a date within 60 days once stamped, a rule before that', () {
      final stamped = deriveSignInLifetime(SignInPolicies.instagram, {OAuthTokens.keyAccessToken: 'a', StoredSecretKeys.lastRenewedAt: _iso(_now)}, now: _now);
      expect((stamped.state, stamped.expiresAt, stamped.about), (SignInState.renewsWhenUsed, _now.add(const Duration(days: 60)), true));
      final old = deriveSignInLifetime(SignInPolicies.instagram, {OAuthTokens.keyAccessToken: 'a', StoredSecretKeys.refreshedAt: _iso(_now)}, now: _now);
      expect((old.expiresAt, old.source), (_now.add(const Duration(days: 60)), SignInDateSource.unknown), reason: 'stored by 1.3.5');
      final bare = deriveSignInLifetime(SignInPolicies.instagram, {OAuthTokens.keyAccessToken: 'a'}, now: _now);
      expect((bare.state, bare.expiresAt, bare.renewsItself, bare.disuseWindow), (SignInState.noDate, null, true, const Duration(days: 60)));
    });

    test('a date from the server beats a policy of no limit', () {
      final end = _now.add(const Duration(days: 30));
      final mitra = deriveSignInLifetime(SignInPolicies.mastodonNoLimit, {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: _iso(end), StoredSecretKeys.expiresAtSource: 'serverReported'}, now: _now);
      expect((mitra.state, mitra.expiresAt, mitra.source), (SignInState.endsOn, end, SignInDateSource.serverReported));
    });

    test('Inkbunny: no date, and the limit says why', () {
      final l = deriveSignInLifetime(SignInPolicies.inkbunnyPolicy, {StoredSecretKeys.sessionId: 's'}, now: _now);
      expect((l.state, l.limit, l.expiresAt, l.renewsItself), (SignInState.noDate, SignInLimit.idleUnknown, null, false));
    });

    test('a server read beats what is stored, unless a later renewal made it stale', () {
      final stored = _now.add(const Duration(days: 40));
      final said = _now.add(const Duration(days: 10));
      final secrets = {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: _iso(stored), StoredSecretKeys.lastRenewedAt: _iso(_now)};
      final fresh = deriveSignInLifetime(SignInPolicies.linkedIn, secrets, now: _now, serverRead: SignInServerRead(readAt: _now, expiresAt: said));
      expect((fresh.expiresAt, fresh.source, fresh.about), (said, SignInDateSource.serverReported, false));
      final stale = deriveSignInLifetime(SignInPolicies.linkedIn, secrets, now: _now, serverRead: SignInServerRead(readAt: _now.subtract(const Duration(minutes: 1)), expiresAt: said));
      expect(stale.expiresAt, stored, reason: 'it described the token before this one');
    });

    test('the earliest of a token end and a data access end counts', () {
      final a = _now.add(const Duration(days: 50)), b = _now.add(const Duration(days: 20));
      expect(SignInServerRead(readAt: _now, expiresAt: a, dataAccessExpiresAt: b).earliestEnd, b);
      expect(SignInServerRead(readAt: _now, expiresAt: b, dataAccessExpiresAt: a).earliestEnd, b);
      expect(SignInServerRead(readAt: _now, dataAccessExpiresAt: a).earliestEnd, a);
    });

    test('X keys: the deadline shows, then ended; it never renews', () {
      final policy = SignInPolicies.xKeys;
      final secrets = OAuth1Credentials(consumerKey: 'k', consumerSecret: 's', token: 't', tokenSecret: 'x').toSecrets();
      final before = deriveSignInLifetime(policy, secrets, now: _now);
      expect((before.state, before.expiresAt, before.isHardDeadline, before.renewsItself, before.earlyRevocationPossible, before.about), (SignInState.endsOn, DateTime.utc(2027, 1, 31), true, false, true, false));
      expect(before.endsSoon, isFalse);
      expect(deriveSignInLifetime(policy, secrets, now: DateTime.utc(2027, 1, 20)).endsSoon, isTrue);
      expect(deriveSignInLifetime(policy, secrets, now: DateTime.utc(2027, 1, 31)).state, SignInState.ended);
      final oauth2 = deriveSignInLifetime(SignInPolicies.xOAuth2, {OAuthTokens.keyRefreshToken: 'r'}, now: DateTime.utc(2027, 2, 1));
      expect(oauth2.isHardDeadline, isFalse, reason: 'browser sign-in goes on');
    });
  });

  group('stamps', () {
    test('a new sign-in records when it was made and that its dates came from the server', () {
      final out = stampNewSignIn({OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: _iso(_now), StoredSecretKeys.refreshExpiresAt: _iso(_now)}, now: _now);
      expect(out[StoredSecretKeys.lastRenewedAt], _iso(_now));
      expect(out[StoredSecretKeys.expiresAtSource], 'serverReported');
      expect(out[StoredSecretKeys.refreshExpiresSource], 'serverReported');
    });

    test('no keys stay no keys: hand-off stores nothing', () {
      expect(stampNewSignIn(const {}, now: _now), isEmpty);
    });

    test('a date the adapter worked out stays marked; a date that did not change keeps its source', () {
      final before = {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: _iso(_now)};
      final same = stampSignInRenewal(before, {...before, OAuthTokens.keyAccessToken: 'b'}, now: _now);
      expect(same.containsKey(StoredSecretKeys.expiresAtSource), isFalse, reason: 'still unknown: this renewal did not date it');
      final computed = stampSignInRenewal(before, {
        ...before,
        StoredSecretKeys.refreshExpiresAt: _iso(_now),
        StoredSecretKeys.refreshExpiresSource: 'computed',
      }, now: _now);
      expect(computed[StoredSecretKeys.refreshExpiresSource], 'computed');
    });

    test('a date that went away takes its source with it', () {
      final before = {OAuthTokens.keyExpiresAt: _iso(_now), StoredSecretKeys.expiresAtSource: 'serverReported'};
      final out = stampSignInRenewal(before, {OAuthTokens.keyAccessToken: 'b', StoredSecretKeys.expiresAtSource: 'serverReported'}, now: _now);
      expect(out.containsKey(StoredSecretKeys.expiresAtSource), isFalse);
    });

    test('the constants are one set of names', () {
      expect(StoredSecretKeys.refreshExpiresAt, SignInSecretKeys.refreshExpiresAt);
      expect(StoredSecretKeys.tokenIssuedAt, SignInSecretKeys.tokenIssuedAt);
      expect(StoredSecretKeys.refreshedAt, SignInSecretKeys.refreshedAt);
      expect(StoredSecretKeys.appPassword, SignInSecretKeys.appPassword);
    });
  });

  group('Lemmy', () {
    Future<http.Response> site(http.Request r, void Function(Map<String, dynamic>) onLogin, String jwt) async {
      final p = r.url.path;
      if (p.endsWith('/user/login')) {
        onLogin(jsonDecode(r.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'jwt': jwt}), 200);
      }
      if (p.endsWith('/site')) {
        return http.Response(
            jsonEncode({
              'version': '0.19.21',
              'site_view': {
                'site': {'name': 'L'},
                'local_site': {'id': 1},
              },
              'my_user': {
                'local_user_view': {
                  'person': {'id': 7, 'name': 'robin', 'actor_id': 'https://lemmy.example/u/robin'},
                },
              },
              'all_languages': <Object>[],
            }),
            200);
      }
      return http.Response('{}', 200);
    }

    Future<ConnectResult> connect(String jwt, void Function(Map<String, dynamic>) onLogin) =>
        LemmyAdapter().connect(PlatformTier.openApi, {'instance': 'lemmy.example', 'username': 'robin', 'password': 'pw'}, _ctx((r) => site(r, onLogin, jwt)));

    test('the login body asks to stay logged in', () async {
      Map<String, dynamic>? body;
      await connect(_jwt({'sub': '7'}), (b) => body = b);
      expect(body!['stay_logged_in'], isTrue);
      expect(body!['username_or_email'], 'robin');
    });

    test('a 0.19 JWT has no exp: no date', () async {
      final r = await connect(_jwt({'sub': '7', 'iss': 'lemmy.example'}), (_) {});
      expect(r.secrets.containsKey(OAuthTokens.keyExpiresAt), isFalse);
    });

    test('MAX_UTC means no date, not the year 262142', () async {
      // DateTime::<Utc>::MAX_UTC.timestamp() in chrono.
      final jwt = _jwt({'sub': '7', 'exp': 8210266876799});
      final r = await connect(jwt, (_) {});
      expect(r.secrets.containsKey(OAuthTokens.keyExpiresAt), isFalse);
      expect(jwtSignInEnd(jwt, now: _now), isNull);
      expect(await LemmyAdapter().readSignIn(_acct('lemmy', PlatformTier.openApi), {OAuthTokens.keyAccessToken: jwt}, _noNetwork), isNull);
    });

    test('an exp past what a date can hold is no date, not a crash', () {
      expect(jwtExpiry(_jwt({'exp': 99999999999999999})), isNull);
    });

    test('a one-week exp is a server date, read with no network', () async {
      final end = _now.add(const Duration(days: 7));
      final jwt = _jwt({'sub': '7', 'exp': end.millisecondsSinceEpoch ~/ 1000});
      final r = await connect(jwt, (_) {});
      expect(DateTime.parse(r.secrets[OAuthTokens.keyExpiresAt]!), end);
      final read = await LemmyAdapter().readSignIn(_acct('lemmy', PlatformTier.openApi), {OAuthTokens.keyAccessToken: jwt}, _noNetwork);
      expect(read!.expiresAt, end);
      final life = deriveSignInLifetime(SignInPolicies.lemmyPolicy, {OAuthTokens.keyAccessToken: jwt}, now: _now, serverRead: read);
      expect((life.state, life.source, life.earlyRevocationPossible), (SignInState.endsOn, SignInDateSource.serverReported, true));
    });
  });

  test('Matrix: a password sign-in does not ask for a refresh token', () async {
    Map<String, dynamic>? login;
    await MatrixAdapter().connect(PlatformTier.openApi, {'homeserver': 'https://matrix.example', 'user_id': '@robin:matrix.example', 'password': 'pw', 'room': '!r:matrix.example'}, _ctx((r) async {
      if (r.url.path.endsWith('/versions')) return http.Response(jsonEncode({'versions': ['v1.11']}), 200);
      if (r.url.path.contains('.well-known')) return http.Response('', 404);
      if (r.method == 'GET' && r.url.path.endsWith('/login')) {
        return http.Response(jsonEncode({'flows': [{'type': 'm.login.password'}]}), 200);
      }
      if (r.method == 'POST' && r.url.path.endsWith('/login')) {
        login = jsonDecode(r.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'access_token': 't', 'user_id': '@robin:matrix.example', 'device_id': 'D'}), 200);
      }
      return http.Response('{}', 200);
    })).catchError((Object _) => ConnectResult(account: _acct('matrix', PlatformTier.openApi)));
    expect(login, isNotNull);
    expect(login!.containsKey('refresh_token'), isFalse);
  });

  group('DeviantArt', () {
    final account = _acct('deviantart', PlatformTier.byokApi, config: {'clientId': '12345'});

    test('a renewal writes a computed end, 3 months on, and the model reads it as about', () async {
      final out = await DeviantArtAdapter().refreshSecrets(account, {
        OAuthTokens.keyAccessToken: 'old',
        OAuthTokens.keyRefreshToken: 'r',
        OAuthTokens.keyExpiresAt: _iso(_now.subtract(const Duration(hours: 1))),
      }, _ctx((r) async => http.Response(jsonEncode({'access_token': 'new', 'refresh_token': 'r2', 'expires_in': 3600}), 200)));
      expect(DateTime.parse(out![StoredSecretKeys.refreshExpiresAt]!), _now.add(const Duration(days: 90)));
      expect(out[StoredSecretKeys.refreshExpiresSource], 'computed');
      final life = deriveSignInLifetime(SignInPolicies.deviantArtPolicy, stampSignInRenewal(const {}, out, now: _now), now: _now);
      expect((life.state, life.source, life.about, life.renewsItself), (SignInState.renewsUntil, SignInDateSource.computed, true, true));
    });

    test('the card can no longer say it renews for ever: an old account gets the window', () {
      final life = deriveSignInLifetime(SignInPolicies.deviantArtPolicy, {OAuthTokens.keyRefreshToken: 'r', OAuthTokens.keyExpiresAt: _iso(_now)}, now: _now);
      expect((life.expiresAt, life.about), (_now.add(const Duration(days: 90)), true));
    });
  });

  group('Micropub', () {
    final account = _acct('micropub', PlatformTier.openApi, config: {'tokenEndpoint': 'https://site.example/token', 'authMethod': 'indieauth'});
    final stale = {OAuthTokens.keyAccessToken: 'old', OAuthTokens.keyRefreshToken: 'r', OAuthTokens.keyExpiresAt: _iso(_now.subtract(const Duration(hours: 1)))};

    test('a refresh with no expires_in drops the stale date', () async {
      final out = await MicropubAdapter().refreshSecrets(account, stale, _ctx((r) async => http.Response(jsonEncode({'access_token': 'new'}), 200)));
      expect(out!.containsKey(OAuthTokens.keyExpiresAt), isFalse);
      expect(OAuthTokens.fromSecrets(out)!.isExpired(now: _now), isFalse, reason: 'it would read as expired for ever');
    });

    test('a refresh with expires_in keeps a date', () async {
      final out = await MicropubAdapter().refreshSecrets(account, stale, _ctx((r) async => http.Response(jsonEncode({'access_token': 'new', 'expires_in': 3600}), 200)));
      expect(DateTime.parse(out![OAuthTokens.keyExpiresAt]!), _now.add(const Duration(hours: 1)));
    });
  });

  group('Pixelfed', () {
    final account = _acct('pixelfed', PlatformTier.openApi, config: {'instance': 'https://pix.example', 'software': 'pixelfed'});
    Map<String, String> tokens(Duration left) =>
        {OAuthTokens.keyAccessToken: 'old', OAuthTokens.keyRefreshToken: 'r', 'client_id': 'c', OAuthTokens.keyExpiresAt: _iso(_now.add(left))};

    test('renews early, on any post within 30 days of the access end', () async {
      var calls = 0;
      final ctx = _ctx((r) async {
        calls++;
        return http.Response(jsonEncode({'access_token': 'new', 'refresh_token': 'r2', 'expires_in': 31536000}), 200);
      });
      final out = await PixelfedAdapter().refreshSecrets(account, tokens(const Duration(days: 29)), ctx);
      expect(calls, 1);
      expect(out![OAuthTokens.keyRefreshToken], 'r2');
      expect(await PixelfedAdapter().refreshSecrets(account, tokens(const Duration(days: 31)), ctx), isNull, reason: 'not yet');
      expect(calls, 1);
    });

    test('an early renewal that fails leaves the working token posting', () async {
      for (final answer in [http.Response('{"error":"invalid_grant"}', 400), http.Response('down', 503)]) {
        final out = await PixelfedAdapter().refreshSecrets(account, tokens(const Duration(days: 5)), _ctx((r) async => answer));
        expect(out, isNull, reason: '${answer.statusCode}');
      }
    });

    test('a token already dead still fails as it did', () async {
      expect(
        () => PixelfedAdapter().refreshSecrets(account, tokens(const Duration(days: -1)), _ctx((r) async => http.Response('{"error":"invalid_grant"}', 400))),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)),
      );
    });

    test('rotation is declared, so two devices take turns', () {
      expect(PixelfedAdapter().rotatesRefreshTokensFor(account), isTrue);
    });

    test('plain Mastodon does not rotate and does not renew early', () async {
      expect(MastodonAdapter().rotatesRefreshTokensFor(_acct('mastodon', PlatformTier.openApi)), isFalse);
      expect(await MastodonAdapter().refreshSecrets(account, tokens(const Duration(days: 5)), _noNetwork), isNull);
    });
  });

  group('TikTok', () {
    final account = _acct('tiktok', PlatformTier.byokApi, config: {'clientKey': 'ck'});

    test('rotation is declared, so a sync coordinator takes the renewal', () async {
      expect(TikTokAdapter().rotatesRefreshTokensFor(account), isTrue);
      expect(TikTokAdapter().rotatesRefreshTokensFor(_acct('tiktok', PlatformTier.handoff)), isFalse);
      final secrets = InMemorySecretStore();
      await secrets.write(account.id, {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyRefreshToken: 'r', OAuthTokens.keyExpiresAt: _iso(_now.subtract(const Duration(hours: 1))), 'client_secret': 's'});
      final accounts = InMemoryAccountRepository();
      await accounts.upsert(account);
      final coordinator = _CountingCoordinator();
      final posts = InMemoryPostRepository();
      final service = PublishService(
        registry: AdapterRegistry([_TikTokNoChecks()]),
        accounts: accounts,
        posts: posts,
        secrets: secrets,
        quota: QuotaTracker(InMemoryQuotaRepository()),
        http: NeforumHttp(client: MockClient((r) async => http.Response('{}', 200)), maxRetries: 0),
        secretsCoordinator: coordinator,
        clock: () => _now,
      );
      final post = Post(
        id: 'p',
        text: 'hello',
        status: PostStatus.scheduled,
        targets: [PostTarget(accountId: account.id)],
        createdAt: _now,
        updatedAt: _now,
      );
      await posts.upsert(post);
      await service.publish('p');
      expect(coordinator.renewals, 1);
    });
  });

  group('Pinterest', () {
    final account = _acct('pinterest', PlatformTier.byokApi, config: {'appId': '1500'});
    Map<String, String> tokens({required Duration accessLeft, DateTime? renewed}) => {
          OAuthTokens.keyAccessToken: 'old',
          OAuthTokens.keyRefreshToken: 'r',
          'app_secret': 's',
          OAuthTokens.keyExpiresAt: _iso(_now.add(accessLeft)),
          if (renewed != null) StoredSecretKeys.lastRenewedAt: _iso(renewed),
        };
    http.Response ok({Map<String, Object?> extra = const {}}) => http.Response(jsonEncode({'access_token': 'new', 'refresh_token': 'r2', 'expires_in': 2592000, ...extra}), 200);

    test('a post renews once the last renewal is older than 7 days, not only near the end', () async {
      var calls = 0;
      final ctx = _ctx((r) async {
        calls++;
        return ok(extra: {'refresh_token_expires_in': 5184000});
      });
      final out = await PinterestAdapter().refreshSecrets(account, tokens(accessLeft: const Duration(days: 22), renewed: _now.subtract(const Duration(days: 8))), ctx);
      expect(calls, 1, reason: 'day 8 of 30: the old rule waited for the last 3 days');
      expect(DateTime.parse(out![StoredSecretKeys.refreshExpiresAt]!), _now.add(const Duration(days: 60)));
      expect(out[StoredSecretKeys.refreshExpiresSource], 'serverReported');
    });

    test('a renewal 6 days old, far from the end, renews nothing', () async {
      expect(await PinterestAdapter().refreshSecrets(account, tokens(accessLeft: const Duration(days: 24), renewed: _now.subtract(const Duration(days: 6))), _noNetwork), isNull);
    });

    test('with no stamp the age comes from the access token', () async {
      expect(await PinterestAdapter().refreshSecrets(account, tokens(accessLeft: const Duration(days: 28)), _noNetwork), isNull, reason: '2 days old');
      var calls = 0;
      await PinterestAdapter().refreshSecrets(account, tokens(accessLeft: const Duration(days: 20)), _ctx((r) async {
        calls++;
        return ok();
      }));
      expect(calls, 1, reason: '10 days old');
    });

    test('an early renewal that fails never costs the post', () async {
      for (final answer in [http.Response('{"error":"invalid_grant"}', 400), http.Response('down', 503)]) {
        final out = await PinterestAdapter().refreshSecrets(account, tokens(accessLeft: const Duration(days: 20), renewed: _now.subtract(const Duration(days: 10))), _ctx((r) async => answer));
        expect(out, isNull);
      }
    });

    test('a due renewal that is refused still asks to reconnect', () async {
      expect(
        () => PinterestAdapter().refreshSecrets(account, tokens(accessLeft: const Duration(days: 1), renewed: _now.subtract(const Duration(days: 29))), _ctx((r) async => http.Response('{"error":"invalid_grant"}', 400))),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth).having((e) => e.error.message, 'message', contains('60 days after its last renewal'))),
      );
    });

    test('a response with no refresh date gets the documented 60, marked worked out, not the old date', () async {
      final out = await PinterestAdapter().refreshSecrets(account, {
        ...tokens(accessLeft: const Duration(days: 1), renewed: _now.subtract(const Duration(days: 29))),
        StoredSecretKeys.refreshExpiresAt: _iso(_now.add(const Duration(days: 2))),
      }, _ctx((r) async => ok()));
      expect(DateTime.parse(out![StoredSecretKeys.refreshExpiresAt]!), _now.add(const Duration(days: 60)));
      expect(out[StoredSecretKeys.refreshExpiresSource], 'computed');
    });
  });

  group('Facebook, Threads and LinkedIn read the real date', () {
    final fb = _acct('facebook', PlatformTier.byokApi, config: {'app_id': '5551234', 'page_id': '777'});
    final fbKeys = {OAuthTokens.keyAccessToken: 'PAGETOKEN', 'app_secret': 'APPSECRET'};
    int secs(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

    test('Facebook: debug_token with the app token', () async {
      Uri? asked;
      final end = _now.add(const Duration(days: 45));
      final read = await FacebookAdapter().readSignIn(fb, fbKeys, _ctx((r) async {
        asked = r.url;
        return http.Response(jsonEncode({'data': {'is_valid': true, 'expires_at': secs(end), 'data_access_expires_at': secs(_now.add(const Duration(days: 2)))}}), 200);
      }));
      expect(asked!.path, endsWith('/debug_token'));
      expect(asked!.queryParameters['input_token'], 'PAGETOKEN');
      expect(asked!.queryParameters['access_token'], '5551234|APPSECRET');
      expect(read!.expiresAt, end);
      expect(read.dataAccessExpiresAt, isNull, reason: 'what it means on a Page token is not documented: it raises no date');
      expect(read.isValid, isTrue);
    });

    test('Facebook: expires_at 0 gives no date, is_valid false is reported', () async {
      final read = await FacebookAdapter().readSignIn(fb, fbKeys, _ctx((r) async => http.Response(jsonEncode({'data': {'is_valid': false, 'expires_at': 0}}), 200)));
      expect(read!.expiresAt, isNull);
      expect(read.isValid, isFalse);
    });

    test('Facebook: no answer, an error answer or a missing secret read as nothing', () async {
      expect(await FacebookAdapter().readSignIn(fb, fbKeys, _ctx((r) async => http.Response('{"error":{}}', 400))), isNull);
      expect(await FacebookAdapter().readSignIn(fb, fbKeys, _ctx((r) async => throw http.ClientException('no route'))), isNull);
      expect(await FacebookAdapter().readSignIn(fb, {OAuthTokens.keyAccessToken: 'x'}, _noNetwork), isNull);
    });

    test('M15: a new Facebook sign-in keeps neither the user token nor its date', () {
      // Read from the source: the connect path is covered in facebook_test.
      final source = File('lib/src/adapters/facebook/facebook_adapter.dart').readAsStringSync();
      expect(source, isNot(contains('secUserToken: userTokens')));
      expect(source, isNot(contains('secUserTokenExpiresAt: userTokens')));
    });

    test('Threads: data_access_expires_at counts, earliest first', () async {
      final token = _now.add(const Duration(days: 60)), data = _now.add(const Duration(days: 20));
      final account = _acct('threads', PlatformTier.byokApi);
      final read = await ThreadsAdapter().readSignIn(account, {OAuthTokens.keyAccessToken: 'TOK'}, _ctx((r) async {
        expect(r.url.path, endsWith('/debug_token'));
        return http.Response(jsonEncode({'data': {'is_valid': true, 'expires_at': secs(token), 'data_access_expires_at': secs(data), 'issued_at': secs(_now)}}), 200);
      }));
      expect((read!.expiresAt, read.dataAccessExpiresAt, read.earliestEnd), (token, data, data));
      final life = deriveSignInLifetime(SignInPolicies.threads, {OAuthTokens.keyAccessToken: 'TOK', OAuthTokens.keyExpiresAt: _iso(token)}, now: _now, serverRead: read);
      expect((life.expiresAt, life.state, life.source, life.earlyRevocationPossible), (data, SignInState.renewsWhenUsed, SignInDateSource.serverReported, true));
    });

    test('ThreadsTokenInfo reads the field, and 0 as no date', () {
      expect(ThreadsTokenInfo.fromJson({'data_access_expires_at': 0}).dataAccessExpiresAt, isNull);
      expect(ThreadsTokenInfo.fromJson({'data_access_expires_at': 1800000000}).dataAccessExpiresAt, DateTime.fromMillisecondsSinceEpoch(1800000000000, isUtc: true));
    });

    final li = _acct('linkedin', PlatformTier.byokApi, config: {'clientId': '86clientid'});
    final liKeys = {OAuthTokens.keyAccessToken: 'TOK', 'client_secret': 'SEC'};

    test('LinkedIn: introspectToken with the client id and secret', () async {
      final end = _now.add(const Duration(days: 33));
      late http.Request sent;
      final read = await LinkedInAdapter().readSignIn(li, liKeys, _ctx((r) async {
        sent = r;
        return http.Response(jsonEncode({'active': true, 'status': 'active', 'expires_at': secs(end), 'scope': 'w_member_social'}), 200);
      }));
      expect(sent.method, 'POST');
      expect(sent.url.toString(), 'https://www.linkedin.com/oauth/v2/introspectToken');
      expect(sent.bodyFields, {'client_id': '86clientid', 'client_secret': 'SEC', 'token': 'TOK'});
      expect((read!.expiresAt, read.isValid), (end, true));
    });

    test('LinkedIn: a revoked token reads as not valid', () async {
      final read = await LinkedInAdapter().readSignIn(li, liKeys, _ctx((r) async => http.Response(jsonEncode({'active': false, 'status': 'revoked'}), 200)));
      expect(read!.isValid, isFalse);
    });

    test('M17: a partner refresh token gets its fixed year once, and a renewal does not move it', () async {
      final keys = {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyRefreshToken: 'r', 'client_secret': 's', OAuthTokens.keyExpiresAt: _iso(_now.subtract(const Duration(hours: 1)))};
      final ctx = _ctx((r) async => http.Response(jsonEncode({'access_token': 'new', 'refresh_token': 'r', 'expires_in': 5184000, 'refresh_token_expires_in': 525600}), 200));
      final first = await LinkedInAdapter().refreshSecrets(li, keys, ctx);
      expect(DateTime.parse(first![StoredSecretKeys.refreshExpiresAt]!), _now.add(const Duration(days: 365)));
      expect(first[StoredSecretKeys.refreshExpiresSource], 'computed');
      final fixed = _iso(_now.add(const Duration(days: 100)));
      final second = await LinkedInAdapter().refreshSecrets(li, {...keys, StoredSecretKeys.refreshExpiresAt: fixed}, ctx);
      expect(second![StoredSecretKeys.refreshExpiresAt], fixed);
    });

    test('M17: a partner sign-in gets its year at connect too; a self-serve one does not', () {
      final source = File('lib/src/adapters/linkedin/linkedin_adapter.dart').readAsStringSync();
      expect(source, contains('secrets: _withPartnerRefreshEnd(tokens.toSecrets('));
    });

    test('X is never probed', () async {
      expect(await XAdapter().readSignIn(_acct('x', PlatformTier.byokApi), {OAuthTokens.keyAccessToken: 'a'}, _noNetwork), isNull);
    });

    test('Bluesky: the JWT dates the session only, with no network', () async {
      final end = _now.add(const Duration(hours: 2));
      final read = await BlueskyAdapter().readSignIn(_acct('bluesky', PlatformTier.openApi), {OAuthTokens.keyAccessToken: _jwt({'exp': secs(end)})}, _noNetwork);
      expect((read!.accessExpiresAt, read.earliestEnd), (end, null));
    });
  });

  group('not allowed is not expired', () {
    test('the field survives JSON, stays off when unset, and an older reader ignores it', () {
      const e = PublishError.auth('no rights', notAllowed: true);
      final json = e.toJson();
      expect(json['kind'], 'auth', reason: 'no new enum value: 1.3.5 reads synced posts with values.byName');
      expect(PublishError.fromJson(json).notAllowed, isTrue);
      expect(const PublishError.auth('expired').toJson().containsKey('notAllowed'), isFalse);
      expect(PublishError.fromJson(const PublishError.auth('expired').toJson()).notAllowed, isNull);
    });

    test('partial threads keep it', () {
      const e = PublishError.auth('no rights', notAllowed: true);
      expect(e.asPartialThread(postedIds: ['1'], total: 2).notAllowed, isTrue);
      expect(e.asResumableThread(postedIds: ['1'], total: 2).notAllowed, isTrue);
    });

    test('refusesSignIn: only a real refusal counts', () {
      expect(refusesSignIn(const PublishError.auth('expired')), isTrue);
      expect(refusesSignIn(const PublishError.auth('no rights', notAllowed: true)), isFalse);
      expect(refusesSignIn(const PublishError.network('down')), isFalse);
      expect(refusesSignIn(null), isFalse);
    });

    Future<ConnectedAccount> runWith(PublishError error, {SignInOutcomes? outcomes}) async {
      final account = _acct('tiktok', PlatformTier.byokApi, config: {'clientKey': 'ck'});
      final accounts = InMemoryAccountRepository();
      await accounts.upsert(account);
      final posts = InMemoryPostRepository();
      final secrets = InMemorySecretStore();
      await secrets.write(account.id, {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: _iso(_now.add(const Duration(days: 1)))});
      await posts.upsert(Post(id: 'p', text: 'hello', status: PostStatus.scheduled, targets: [PostTarget(accountId: account.id)], createdAt: _now, updatedAt: _now));
      await PublishService(
        registry: AdapterRegistry([_TikTokNoChecks(error)]),
        accounts: accounts,
        posts: posts,
        secrets: secrets,
        quota: QuotaTracker(InMemoryQuotaRepository()),
        http: NeforumHttp(client: MockClient((r) async => http.Response('{}', 200)), maxRetries: 0),
        signInOutcomes: outcomes,
        clock: () => _now,
      ).publish('p');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      return (await accounts.get(account.id))!;
    }

    test('the card asks to reconnect only for a real refusal', () async {
      expect((await runWith(const PublishError.auth('expired'))).lastError, 'expired');
      expect((await runWith(const PublishError.auth('no rights', notAllowed: true))).lastError, isNull);
    });

    test('the status notes a real refusal only', () async {
      final seen = <String>[];
      final o = _RecordingOutcomes(seen);
      await runWith(const PublishError.auth('expired'), outcomes: o);
      await runWith(const PublishError.auth('no rights', notAllowed: true), outcomes: o);
      await runWith(const PublishError.network('down'), outcomes: o);
      expect(seen, ['refused']);
    });

    test('the listed sites say so', () {
      expect(mapTelegramErrorForTest(403, 'Forbidden: bot is not a member of the channel chat').notAllowed, isTrue);
      expect(mapTelegramErrorForTest(401, 'Unauthorized').notAllowed, isNull);
    });
  });

  group('SignInStatusTracker', () {
    late InMemoryAccountRepository accounts;
    late SignInStatusStore store;
    late SignInStatusTracker tracker;
    late InMemorySecretStore keychain;
    late SignInStatusSecretStore decorated;
    late List<String> logs;
    var clock = _now;

    setUp(() async {
      clock = _now;
      accounts = InMemoryAccountRepository();
      store = SignInStatusStore.inMemory();
      keychain = InMemorySecretStore();
      logs = [];
      tracker = SignInStatusTracker(
        store: store,
        accounts: accounts,
        registry: builtinRegistry(),
        secrets: keychain,
        clock: () => clock,
        log: Logger('t', sink: (level, area, message, [error]) => logs.add('$message $error')),
      );
      decorated = SignInStatusSecretStore(keychain, tracker);
    });

    test('a write of an account\'s keys updates its status; an entry that is no account is left alone', () async {
      final a = _acct('linkedin', PlatformTier.byokApi);
      await accounts.upsert(a);
      final end = _now.add(const Duration(days: 40));
      await decorated.write(a.id, {OAuthTokens.keyAccessToken: 'SECRETVALUE', OAuthTokens.keyExpiresAt: _iso(end)});
      final s = (await store.get(a.id))!;
      expect((s.expiresAt, s.source, s.limit, s.renewsItself, s.earlyRevocationPossible), (end, SignInDateSource.unknown, SignInLimit.date, false, true));
      await decorated.write('sync-password', {'password': 'x'});
      expect(await store.get('sync-password'), isNull);
      expect(await keychain.read('sync-password'), isNotNull);
    });

    test('delete removes it', () async {
      final a = _acct('linkedin', PlatformTier.byokApi);
      await accounts.upsert(a);
      await decorated.write(a.id, {OAuthTokens.keyAccessToken: 'x'});
      await decorated.delete(a.id);
      expect(await store.get(a.id), isNull);
      expect(await keychain.read(a.id), isNull);
    });

    test('a status that cannot be written never fails the write of the keys', () async {
      final broken = SignInStatusStore(read: () async => null, write: (_) async => throw const FileSystemException('locked'));
      final t = SignInStatusTracker(store: broken, accounts: accounts, registry: builtinRegistry(), secrets: keychain, clock: () => clock);
      final a = _acct('linkedin', PlatformTier.byokApi);
      await accounts.upsert(a);
      await SignInStatusSecretStore(keychain, t).write(a.id, {OAuthTokens.keyAccessToken: 'x'});
      expect(await keychain.read(a.id), isNotNull);
    });

    test('a post confirms; a refusal is noted; a later post clears it; a renewal clears it too', () async {
      final a = _acct('linkedin', PlatformTier.byokApi);
      await accounts.upsert(a);
      await decorated.write(a.id, {OAuthTokens.keyAccessToken: 'x', StoredSecretKeys.lastRenewedAt: _iso(_now)});
      await tracker.publishFinished(a, worked: true, refused: false, ctx: _noNetworkUnlessLinkedIn());
      expect((await store.get(a.id))!.lastConfirmedAt, _now);
      clock = _now.add(const Duration(hours: 1));
      await tracker.publishFinished(a, worked: false, refused: true, ctx: _noNetworkUnlessLinkedIn());
      var s = (await store.get(a.id))!;
      expect((s.lastConfirmedAt, s.lastAuthFailure), (_now, clock));
      clock = _now.add(const Duration(hours: 2));
      await tracker.publishFinished(a, worked: true, refused: false, ctx: _noNetworkUnlessLinkedIn());
      expect((await store.get(a.id))!.lastAuthFailure, isNull);
      await tracker.publishFinished(a, worked: false, refused: true, ctx: _noNetworkUnlessLinkedIn());
      await decorated.write(a.id, {OAuthTokens.keyAccessToken: 'y', StoredSecretKeys.lastRenewedAt: _iso(clock)});
      s = (await store.get(a.id))!;
      expect(s.lastAuthFailure, isNull, reason: 'a renewal proves the new keys');
      expect(s.lastConfirmedAt, _now.add(const Duration(hours: 2)), reason: 'what is known stays');
    });

    test('a real read happens at most once a day per account, and at connect', () async {
      final a = _acct('linkedin', PlatformTier.byokApi, config: {'clientId': 'c'});
      await accounts.upsert(a);
      final keys = {OAuthTokens.keyAccessToken: 'x', 'client_secret': 's'};
      await keychain.write(a.id, keys);
      var reads = 0;
      final end = _now.add(const Duration(days: 20));
      final ctx = _ctx((r) async {
        reads++;
        return http.Response(jsonEncode({'active': true, 'expires_at': end.millisecondsSinceEpoch ~/ 1000}), 200);
      });
      final s = await tracker.accountConnected(a, keys, ctx);
      expect((reads, s!.expiresAt, s.source), (1, end, SignInDateSource.serverReported));
      await tracker.publishFinished(a, worked: true, refused: false, ctx: ctx);
      await tracker.readFromServer(a, ctx);
      expect(reads, 1, reason: 'the same day');
      clock = _now.add(const Duration(hours: 25));
      await tracker.publishFinished(a, worked: true, refused: false, ctx: ctx);
      expect(reads, 2);
      await tracker.readFromServer(a, ctx, force: true);
      expect(reads, 3, reason: 'Check now');
    });

    test('a platform that says the token is dead is noted as a failure', () async {
      final a = _acct('linkedin', PlatformTier.byokApi, config: {'clientId': 'c'});
      await accounts.upsert(a);
      final s = await tracker.readFromServer(a, _ctx((r) async => http.Response(jsonEncode({'active': false}), 200)), secrets: {OAuthTokens.keyAccessToken: 'x', 'client_secret': 's'});
      expect(s!.lastAuthFailure, _now);
    });

    test('a read survives a restart, and goes stale with the next renewal', () async {
      final a = _acct('linkedin', PlatformTier.byokApi, config: {'clientId': 'c'});
      await accounts.upsert(a);
      final said = _now.add(const Duration(days: 20));
      await tracker.readFromServer(a, _ctx((r) async => http.Response(jsonEncode({'active': true, 'expires_at': said.millisecondsSinceEpoch ~/ 1000}), 200)), secrets: {OAuthTokens.keyAccessToken: 'x', 'client_secret': 's'});
      final raw = jsonDecode(jsonEncode((await store.get(a.id))!.toJson())) as Map<String, dynamic>;
      expect(SignInStatus.fromJson(a.id, raw).serverRead!.expiresAt, said);
      clock = _now.add(const Duration(hours: 1));
      final renewedEnd = clock.add(const Duration(days: 60));
      await decorated.write(a.id, {OAuthTokens.keyAccessToken: 'y', OAuthTokens.keyExpiresAt: _iso(renewedEnd), StoredSecretKeys.lastRenewedAt: _iso(clock)});
      expect((await store.get(a.id))!.expiresAt, renewedEnd);
    });

    test('seedMissing fills accounts with no status, once, and skips hand-off', () async {
      final a = _acct('linkedin', PlatformTier.byokApi);
      final h = _acct('cara', PlatformTier.handoff);
      await accounts.upsert(a);
      await accounts.upsert(h);
      final end = _now.add(const Duration(days: 5));
      await keychain.write(a.id, {OAuthTokens.keyAccessToken: 'x', OAuthTokens.keyExpiresAt: _iso(end)});
      await tracker.seedMissing();
      expect((await store.get(a.id))!.expiresAt, end);
      expect(await store.get(h.id), isNull);
    });

    test('a keychain that will not answer stops the seeding at one wait', () async {
      var asked = 0;
      final stuck = _HangingStore(() => asked++);
      final t = SignInStatusTracker(store: store, accounts: accounts, registry: builtinRegistry(), secrets: stuck, clock: () => clock);
      await accounts.upsert(_acct('linkedin', PlatformTier.byokApi));
      await accounts.upsert(_acct('reddit', PlatformTier.byokApi));
      await t.seedMissing(timeout: const Duration(milliseconds: 20));
      expect(asked, 1);
    });

    group('secret guard', () {
      const secretValues = ['SECRETaccess1', 'SECRETrefresh2', 'SECRETclient3', 'SECRETapppw4', 'SECRETsession5', 'SECRETjwt6'];
      final all = <String, String>{
        OAuthTokens.keyAccessToken: secretValues[0],
        OAuthTokens.keyRefreshToken: secretValues[1],
        'client_secret': secretValues[2],
        'app_secret': secretValues[2],
        StoredSecretKeys.appPassword: secretValues[3],
        StoredSecretKeys.sessionId: secretValues[4],
        'jwt': secretValues[5],
        OAuthTokens.keyExpiresAt: _iso(_now.add(const Duration(days: 9))),
        StoredSecretKeys.refreshExpiresAt: _iso(_now.add(const Duration(days: 19))),
      };

      void expectClean(String text, String where) {
        for (final s in secretValues) {
          expect(text, isNot(contains(s)), reason: where);
          expect(text, isNot(contains(s.substring(6))), reason: '$where: part of one');
        }
      }

      test('no secret value reaches the status file or the log, on every adapter and path', () async {
        final file = <String>[];
        final captured = SignInStatusStore(read: () async => file.isEmpty ? null : jsonDecode(file.last), write: (d) async => file.add(jsonEncode(d)));
        final t = SignInStatusTracker(
          store: captured,
          accounts: accounts,
          registry: builtinRegistry(),
          secrets: keychain,
          clock: () => clock,
          log: Logger('guard', sink: (level, area, message, [error]) => logs.add('$message $error')),
        );
        final d = SignInStatusSecretStore(keychain, t);
        for (final adapter in builtinAdapters()) {
          for (final spec in adapter.connectSpecs) {
            final a = ConnectedAccount(id: 'g-${adapter.id}-${spec.tier.name}', platformId: adapter.id, tier: spec.tier, displayName: 'g', createdAt: _now, config: const {'clientId': 'c', 'app_id': '555', 'appId': '555'});
            await accounts.upsert(a);
            await d.write(a.id, all);
            // The network answers with an error quoting what it was sent, as a
            // bad proxy does, then with nothing usable.
            await t.readFromServer(a, _ctx((r) async => http.Response('{"echo":"${r.url}${r.body}"}', 500)), force: true);
            await t.readFromServer(a, _ctx((r) async => throw http.ClientException('failed', r.url)), force: true);
            await t.publishFinished(a, worked: true, refused: false, ctx: _ctx((r) async => http.Response('{}', 200)));
            await t.publishFinished(a, worked: false, refused: true, ctx: _ctx((r) async => http.Response('{}', 200)));
            await d.delete(a.id);
            await d.write(a.id, {...all}..remove(StoredSecretKeys.appPassword));
          }
        }
        expect(file, isNotEmpty);
        expectClean(file.join('\n'), 'the status file');
        expectClean(logs.join('\n'), 'the log');
        expect(logs.where((l) => l.contains(' ends ')), isNotEmpty, reason: 'the trace is there');
      });

      test('the guard would catch one', () {
        expect(() => expectClean('token SECRETaccess1', 'x'), throwsA(isA<TestFailure>()));
      });

      test('the HTTP log carries no query and no exception text', () async {
        final seen = <String>[];
        final log = Logger('http', sink: (level, area, message, [error]) => seen.add('$message $error'));
        final http0 = NeforumHttp(client: MockClient((r) async => throw http.ClientException('boom', r.url)), log: log, maxRetries: 1);
        await expectLater(http0.get(Uri.parse('https://graph.example/debug_token?input_token=SECRETaccess1')), throwsA(anything));
        expect(seen, isNotEmpty);
        expectClean(seen.join('\n'), 'the HTTP log');
      });

      test('the file holds only the listed fields', () async {
        final a = _acct('linkedin', PlatformTier.byokApi, config: {'clientId': 'c'});
        await accounts.upsert(a);
        await decorated.write(a.id, all);
        await tracker.readFromServer(a, _ctx((r) async => http.Response(jsonEncode({'active': true, 'expires_at': 1800000000}), 200)), secrets: all, force: true);
        await tracker.publishFinished(a, worked: true, refused: false, ctx: _noNetwork);
        final json = (await store.get(a.id))!.toJson();
        expect(json.keys.toSet().difference(const {
          'limit', 'source', 'renewsItself', 'state', 'expiresAt', 'lastConfirmedAt', 'lastAuthFailure', 'lastRenewedAt', 'about',
          'earlyRevocationPossible', 'unverified', 'isHardDeadline', 'usesCredential', 'hasConnection', 'serverRead', 'serverReadAt', 'note',
        }), isEmpty);
      });
    });
  });

  group('file store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('nf-sign-in'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('sign-in-status.json survives a restart and is a file of its own', () async {
      final a = JsonFileStore.openSignInStatus(dir.path);
      final end = _now.add(const Duration(days: 3));
      await a.change('x', (_) => SignInStatus(accountId: 'x', limit: SignInLimit.date, source: SignInDateSource.computed, renewsItself: true, state: SignInState.renewsUntil, expiresAt: end, about: true));
      final b = JsonFileStore.openSignInStatus(dir.path);
      final s = (await b.get('x'))!;
      expect((s.expiresAt, s.source, s.about, s.endsSoon(_now), s.hasEnded(_now)), (end, SignInDateSource.computed, true, true, false));
      expect(File('${dir.path}/sign-in-status.json').existsSync(), isTrue);
      await b.clear();
      expect(await JsonFileStore.openSignInStatus(dir.path).all(), isEmpty);
    });

    test('a damaged file counts as no entries', () async {
      File('${dir.path}/sign-in-status.json').writeAsStringSync('{not json');
      expect(await JsonFileStore.openSignInStatus(dir.path).all(), isEmpty);
      File('${dir.path}/sign-in-status.json').writeAsStringSync('{"x": {"state": 3}, "y": {"limit": "date"}}');
      final all = await JsonFileStore.openSignInStatus(dir.path).all();
      expect(all['y']!.limit, SignInLimit.date);
    });

    test('a change notifies', () async {
      final s = SignInStatusStore.inMemory();
      final fired = s.changes.first;
      await s.change('x', (_) => const SignInStatus(accountId: 'x', limit: SignInLimit.none, source: SignInDateSource.unknown, renewsItself: false, state: SignInState.noDate));
      await fired;
      s.dispose();
    });
  });
}

/// A context whose only network is a LinkedIn answer with nothing usable.
AdapterContext _noNetworkUnlessLinkedIn() => _ctx((r) async => http.Response('{}', 200));

class _HangingStore extends SecretStore {
  _HangingStore(this.onRead);
  final void Function() onRead;
  @override
  Future<Map<String, String>?> read(String accountId) {
    onRead();
    return Future<Map<String, String>?>.delayed(const Duration(hours: 1));
  }

  @override
  Future<void> write(String accountId, Map<String, String> secrets) async {}
  @override
  Future<void> delete(String accountId) async {}
}

class _CountingCoordinator implements SecretsCoordinator {
  int renewals = 0;
  @override
  Future<Map<String, String>?> renew(ConnectedAccount account, Map<String, String> current, SecretsRefresh refresh) async {
    renewals++;
    return null;
  }
}

class _TikTokNoChecks extends TikTokAdapter {
  _TikTokNoChecks([this.error]);
  final PublishError? error;
  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) => const [];
  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async =>
      error == null ? PublishResult.ok(remoteId: 'v') : PublishResult.failure(error!);
}

class _RecordingOutcomes implements SignInOutcomes {
  _RecordingOutcomes(this.seen);
  final List<String> seen;
  @override
  Future<void> publishFinished(ConnectedAccount account, {required bool worked, required bool refused, required AdapterContext ctx}) async {
    seen.add(worked ? 'worked' : (refused ? 'refused' : 'neither'));
  }
}

/// Telegram's mapping as the adapter reaches it.
PublishError mapTelegramErrorForTest(int code, String description) => TelegramApiError(method: 'sendMessage', statusCode: code, description: description).toPublishError();
