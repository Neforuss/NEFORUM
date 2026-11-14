import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/bluesky/bluesky_adapter.dart';
import 'package:test/test.dart';

import '../adapters/bluesky_test.dart' show Router, blueskyAccount, did, fakeJwt, goodSecrets, jsonRes, pds, sessionJson;
import '../support/test_context.dart';

// 1.4.3, automatic reconnect: which failures show an account as needing a
// reconnect, and which NEFORUM gets past by itself with the keys it holds.

/// What the publish service told the sign-in tracker.
class _Outcomes implements SignInOutcomes {
  final notes = <({bool worked, bool refused})>[];
  int get refused => notes.where((n) => n.refused).length;
  int get worked => notes.where((n) => n.worked).length;

  @override
  Future<void> publishFinished(ConnectedAccount account, {required bool worked, required bool refused, required AdapterContext ctx}) async =>
      notes.add((worked: worked, refused: refused));
}

/// A network with a renewable sign-in. Each renewal and each post takes the
/// next step of [renewals] and [posts]; a renewal is only asked for when the
/// stored token has run out (or a forced renewal says it has).
class _SignInAdapter extends PlatformAdapter {
  final renewals = <Future<Map<String, String>?> Function(Map<String, String> secrets, AdapterContext ctx)>[];
  final posts = <PublishResult Function(Map<String, String> secrets)>[];
  final postedWith = <Map<String, String>>[];
  int renewCalls = 0;

  @override
  SignInPolicy signInPolicyFor(ConnectedAccount account) => const SignInPolicy(limit: SignInLimit.undocumented, renewal: SignInRenewal.onUse);

  @override
  PlatformDescriptor get descriptor => const PlatformDescriptor(
        id: 'fake',
        name: 'Fake',
        tiers: {PlatformTier.openApi},
        defaultTier: PlatformTier.openApi,
        text: TextRules(maxLength: 500, supportsThreads: true),
        media: MediaRules(maxImages: 4),
        accountRequirements: '',
        apiCostSummary: '',
        serverSideScheduling: false,
      );

  @override
  List<ConnectSpec> get connectSpecs => const [];

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) => throw UnimplementedError();

  @override
  Future<Map<String, String>?> refreshSecrets(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens != null && !tokens.isExpired(now: ctx.now())) return null;
    renewCalls++;
    if (renewals.isEmpty) return null;
    return renewals.removeAt(0)(secrets, ctx);
  }

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    postedWith.add(secrets);
    return posts.isEmpty ? PublishResult.ok(remoteId: 'post-${postedWith.length}') : posts.removeAt(0)(secrets);
  }
}

/// X, Tumblr, TikTok, Pixelfed: each renewal retires the old refresh token.
class _RotatingSignInAdapter extends _SignInAdapter {
  @override
  bool rotatesRefreshTokensFor(ConnectedAccount account) => true;
}

Map<String, String> _keys(String access, {required Duration left}) => {
      OAuthTokens.keyAccessToken: access,
      OAuthTokens.keyRefreshToken: 'refresh-$access',
      OAuthTokens.keyExpiresAt: testNow.add(left).toUtc().toIso8601String(),
    };

Future<Map<String, String>?> Function(Map<String, String>, AdapterContext) _renewTo(String access) =>
    (_, _) async => _keys(access, left: const Duration(hours: 2));

Future<Map<String, String>?> Function(Map<String, String>, AdapterContext) _renewFails(PublishError e) => (_, _) async => throw AdapterException(e);

const _revoked = PublishError.auth('Fake refused to renew the sign-in (invalid_grant); reconnect the account', statusCode: 400);
const _offline = PublishError.network('Could not reach Fake to renew the sign-in: connection refused');
const _refusedPost = PublishError.auth('HTTP 401 from fake.example.test/posts', statusCode: 401);

void main() {
  late PlatformAdapter adapter;
  late InMemoryAccountRepository accounts;
  late InMemoryPostRepository posts;
  late InMemorySecretStore secrets;
  late _Outcomes outcomes;
  late List<Duration> slept;
  late http.Client network;

  PublishService service() => PublishService(
        registry: AdapterRegistry([adapter]),
        accounts: accounts,
        posts: posts,
        secrets: secrets,
        quota: QuotaTracker(InMemoryQuotaRepository()),
        http: NeforumHttp(client: network, maxRetries: 0),
        signInOutcomes: outcomes,
        clock: () => testNow,
        log: Logger('test', sink: (level, area, msg, [err]) {}),
        sleep: (d) async => slept.add(d),
      );

  Future<PostTarget> publishOnce({String text = 'Hello there'}) async {
    await posts.upsert(Post(id: 'p1', text: text, createdAt: testNow, updatedAt: testNow, targets: const [PostTarget(accountId: 'acct-1')]));
    final p = await service().publish('p1');
    // The sign-in notes are not awaited by the post.
    await pumpEventQueue();
    return p.targets.single;
  }

  setUp(() async {
    adapter = _SignInAdapter();
    accounts = InMemoryAccountRepository();
    posts = InMemoryPostRepository();
    secrets = InMemorySecretStore();
    outcomes = _Outcomes();
    slept = [];
    network = MockClient((_) async => http.Response('', 500));
    await accounts.upsert(fakeAccount('fake'));
  });

  _SignInAdapter fake() => adapter as _SignInAdapter;

  group('an ended token whose renewal fails for a passing reason', () {
    setUp(() async => secrets.write('acct-1', _keys('old', left: const Duration(minutes: -5))));

    test('is renewed again a few seconds later, and the post goes out', () async {
      fake().renewals.addAll([_renewFails(_offline), _renewTo('new')]);
      final t = await publishOnce();
      expect(t.status, TargetStatus.published);
      expect(slept, [const Duration(seconds: 2)]);
      expect(fake().postedWith.single[OAuthTokens.keyAccessToken], 'new');
      expect((await secrets.read('acct-1'))![OAuthTokens.keyAccessToken], 'new');
      expect(outcomes.refused, 0);
    });

    test('never shows the account as disconnected when every try fails', () async {
      fake().renewals.addAll([_renewFails(_offline), _renewFails(_offline), _renewFails(_offline)]);
      final t = await publishOnce();
      expect(slept, [const Duration(seconds: 2), const Duration(seconds: 6)]);
      expect(fake().renewCalls, 3);
      // Waits for the post's own next attempt; nothing asks for a reconnect.
      expect(t.status, TargetStatus.pending);
      expect(t.result!.error!.kind, PublishErrorKind.network);
      expect(refusesSignIn(t.result!.error), isFalse);
      expect(outcomes.refused, 0);
      expect((await accounts.get('acct-1'))!.lastError, isNull);
      expect(fake().postedWith, isEmpty);
    });

    test('an answer NEFORUM cannot read is a passing failure, not a refused sign-in', () async {
      // Before 1.4.3 this counted as a refusal ("Could not refresh credentials").
      fake().renewals.addAll([for (var i = 0; i < 3; i++) (_, _) async => throw const FormatException('<html>maintenance</html>')]);
      final t = await publishOnce();
      expect(t.result!.error!.kind, PublishErrorKind.network);
      expect(t.status, TargetStatus.pending);
      expect(outcomes.refused, 0);
      expect((await accounts.get('acct-1'))!.lastError, isNull);
    });

    test('a token endpoint that timed out (HTTP 408) is a passing failure', () async {
      network = MockClient((_) async => http.Response('timeout', 408));
      fake().renewals.addAll([
        for (var i = 0; i < 3; i++)
          (_, ctx) async {
            await ctx.http.postJson(Uri.parse('https://fake.example.test/token'), {});
            return null;
          },
      ]);
      final t = await publishOnce();
      expect(t.result!.error!.kind, PublishErrorKind.network);
      expect(t.result!.error!.retryable, isTrue);
      expect(outcomes.refused, 0);
    });

    test('a platform that rotates its refresh token is not renewed again at once: the lost answer may have spent it', () async {
      adapter = _RotatingSignInAdapter();
      fake().renewals.addAll([_renewFails(_offline), _renewTo('new')]);
      final t = await publishOnce();
      expect(slept, isEmpty);
      expect(fake().renewCalls, 1);
      expect(t.status, TargetStatus.pending);
      expect(outcomes.refused, 0);
    });

    test('a rate limit on the renewal is not tried again at once', () async {
      fake().renewals.add(_renewFails(const PublishError.quota('Fake is rate limiting sign-in renewals; will retry', statusCode: 429)));
      final t = await publishOnce();
      expect(slept, isEmpty);
      expect(t.result!.error!.kind, PublishErrorKind.quota);
      expect(outcomes.refused, 0);
    });
  });

  test('a renewal the platform refuses shows the account as needing a reconnect, once, with no waits', () async {
    await secrets.write('acct-1', _keys('old', left: const Duration(minutes: -5)));
    fake().renewals.add(_renewFails(_revoked));
    final t = await publishOnce();
    expect(slept, isEmpty);
    expect(fake().renewCalls, 1);
    expect(t.status, TargetStatus.failed);
    expect(refusesSignIn(t.result!.error), isTrue);
    expect(outcomes.refused, 1);
    expect((await accounts.get('acct-1'))!.lastError, contains('reconnect'));
    expect(fake().postedWith, isEmpty);
  });

  group('a post the network refuses while the stored token has time left', () {
    setUp(() async => secrets.write('acct-1', _keys('old', left: const Duration(hours: 1))));

    test('is posted again after one renewal with the stored keys', () async {
      fake()
        ..posts.add((_) => PublishResult.failure(_refusedPost))
        ..renewals.add(_renewTo('new'));
      final t = await publishOnce();
      expect(t.status, TargetStatus.published);
      expect([for (final s in fake().postedWith) s[OAuthTokens.keyAccessToken]], ['old', 'new']);
      expect((await secrets.read('acct-1'))![OAuthTokens.keyAccessToken], 'new');
      expect(outcomes.refused, 0);
      expect(outcomes.worked, 1);
      expect((await accounts.get('acct-1'))!.lastError, isNull);
    });

    test('asks for exactly one reconnect when the renewal is refused too', () async {
      fake()
        ..posts.add((_) => PublishResult.failure(_refusedPost))
        ..renewals.add(_renewFails(_revoked));
      final t = await publishOnce();
      expect(t.status, TargetStatus.failed);
      expect(fake().postedWith, hasLength(1));
      expect(outcomes.refused, 1);
      expect(outcomes.notes, hasLength(1));
      expect((await accounts.get('acct-1'))!.lastError, isNotNull);
    });

    test('waits for its next attempt when the renewal cannot reach the platform', () async {
      fake()
        ..posts.add((_) => PublishResult.failure(_refusedPost))
        ..renewals.addAll([_renewFails(_offline), _renewFails(_offline), _renewFails(_offline)]);
      final t = await publishOnce();
      expect(t.status, TargetStatus.pending);
      expect(t.result!.error!.kind, PublishErrorKind.network);
      expect(outcomes.refused, 0);
      expect((await accounts.get('acct-1'))!.lastError, isNull);
      expect(fake().postedWith, hasLength(1));
    });

    test('keeps the refusal when nothing stored can renew the sign-in', () async {
      fake().posts.add((_) => PublishResult.failure(_refusedPost));
      final t = await publishOnce();
      expect(fake().renewCalls, 1);
      expect(fake().postedWith, hasLength(1));
      expect(t.status, TargetStatus.failed);
      expect(outcomes.refused, 1);
    });

    test('is not tried again once part of a thread is live', () async {
      fake()
        ..posts.add((_) => PublishResult.partialFailure(_refusedPost, remoteId: 'p1', threadRemoteIds: const ['p1']))
        ..renewals.add(_renewTo('new'));
      await publishOnce();
      expect(fake().postedWith, hasLength(1));
      expect(fake().renewCalls, 0);
    });

    test('"not allowed" is not a sign-in to renew', () async {
      fake()
        ..posts.add((_) => PublishResult.failure(const PublishError.auth('HTTP 403', statusCode: 403, notAllowed: true)))
        ..renewals.add(_renewTo('new'));
      await publishOnce();
      expect(fake().renewCalls, 0);
      expect(fake().postedWith, hasLength(1));
      expect(outcomes.refused, 0);
    });
  });

  test('a revoked sign-in is announced once however many posts it refuses', () async {
    await secrets.write('acct-1', _keys('old', left: const Duration(minutes: -5)));
    final store = SignInStatusStore.inMemory();
    final tracker = SignInStatusTracker(store: store, accounts: accounts, registry: AdapterRegistry([adapter]), secrets: secrets, clock: () => testNow);
    var ledger = const SignInWarningLedger();
    var shown = 0;
    for (var run = 0; run < 3; run++) {
      fake().renewals.add(_renewFails(_revoked));
      await posts.upsert(Post(id: 'p$run', text: 'Hello $run', createdAt: testNow, updatedAt: testNow, targets: const [PostTarget(accountId: 'acct-1')]));
      await PublishService(
        registry: AdapterRegistry([adapter]),
        accounts: accounts,
        posts: posts,
        secrets: secrets,
        quota: QuotaTracker(InMemoryQuotaRepository()),
        http: NeforumHttp(client: network, maxRetries: 0),
        signInOutcomes: tracker,
        clock: () => testNow,
        log: Logger('test', sink: (level, area, msg, [err]) {}),
        sleep: (d) async => slept.add(d),
      ).publish('p$run');
      await pumpEventQueue();
      final step = advanceSignInWarnings(ledger, statuses: (await store.all()).values, now: testNow, schedulesAhead: false);
      ledger = step.ledger;
      shown += step.show.where((n) => n.isRefused).length;
    }
    expect(shown, 1);
    expect((await store.get('acct-1'))!.lastAuthFailure, isNotNull);
  });

  test('Bluesky: a dropped session signs in again with the saved app password, and the post goes out', () async {
    adapter = BlueskyAdapter(videoPollInterval: Duration.zero);
    await accounts.upsert(blueskyAccount());
    await secrets.write('acct-1', goodSecrets);
    final newAccess = fakeJwt(testNow.add(const Duration(hours: 3)));
    var posted = 0;
    final router = Router()
      ..on('POST', '/com.atproto.repo.createRecord', (r) {
        posted++;
        // The stored session has time left by its date, but Bluesky dropped it.
        if (r.headers['Authorization'] != 'Bearer $newAccess') return jsonRes({'error': 'ExpiredToken', 'message': 'Token has expired'}, 400);
        return jsonRes({'uri': 'at://$did/app.bsky.feed.post/p1', 'cid': 'cid1'});
      })
      ..on('POST', '/com.atproto.server.refreshSession', (_) => jsonRes({'error': 'ExpiredToken', 'message': 'Token has been revoked'}, 400))
      ..on('POST', '/com.atproto.server.createSession', (_) => jsonRes(sessionJson(access: newAccess, refresh: 'R2')));
    network = MockClient(router.call);

    final t = await publishOnce();

    expect(t.status, TargetStatus.published, reason: '${t.result?.error?.message}');
    expect(posted, 2);
    final login = router.where('createSession').single;
    expect(bodyOf(login)['password'], goodSecrets['app_password']);
    expect(bodyOf(login)['identifier'], did);
    final stored = (await secrets.read('acct-1'))!;
    expect(stored[OAuthTokens.keyAccessToken], newAccess);
    expect(stored['app_password'], goodSecrets['app_password']);
    expect(outcomes.refused, 0);
    expect(router.calls.every((c) => c.url.toString().startsWith(pds) || c.url.host == 'bsky.social'), isTrue);
    expect(jsonEncode(stored), isNot(contains('R1')));
  });
}
