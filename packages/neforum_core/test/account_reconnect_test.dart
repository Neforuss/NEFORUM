import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import 'support/test_context.dart';

// 1.4.3: one-tap Reconnect. The stored keys first, then the browser with the
// saved app keys; the person types nothing.

/// A platform whose browser sign-in needs a Client ID and secret, like most
/// developer-app platforms. Records what each sign-in was given.
class _BrowserAdapter extends PlatformAdapter {
  final connects = <Map<String, String>>[];
  final disconnected = <String>[];
  Object? connectError;
  String signsInAs = 'robin';

  @override
  SignInPolicy signInPolicyFor(ConnectedAccount account) => const SignInPolicy(limit: SignInLimit.undocumented, renewal: SignInRenewal.onUse);

  @override
  PlatformDescriptor get descriptor => const PlatformDescriptor(
        id: 'fake',
        name: 'Fake',
        tiers: {PlatformTier.byokApi, PlatformTier.handoff},
        defaultTier: PlatformTier.byokApi,
        text: TextRules(maxLength: 500),
        media: MediaRules(),
        accountRequirements: '',
        apiCostSummary: '',
        serverSideScheduling: false,
      );

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(tier: PlatformTier.byokApi, usesBrowser: true, fields: [
          ConnectField(key: 'client_id', label: 'Client ID'),
          ConnectField(key: 'client_secret', label: 'Client secret', kind: FieldKind.password, secret: true),
          ConnectField(key: 'access_token', label: 'Or paste an access token', kind: FieldKind.password, secret: true, required: false),
          ConnectField(key: 'password', label: 'Account password', kind: FieldKind.password, secret: true, required: false),
        ]),
        ConnectSpec(tier: PlatformTier.handoff),
      ];

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    connects.add(input);
    final e = connectError;
    if (e != null) throw e;
    await ctx.requireBroker().authorize(Uri.parse('https://fake.example.test/authorize'), ctx.requireBroker().chooseRedirectUri());
    return ConnectResult(
      account: ConnectedAccount(
        id: 'fake-$signsInAs',
        platformId: 'fake',
        tier: tier,
        displayName: 'Robin Renamed',
        handle: '@$signsInAs',
        createdAt: testNow,
        config: {'clientId': input['client_id'], 'userId': signsInAs},
      ),
      secrets: {'access_token': 'new-access', 'refresh_token': 'new-refresh', 'client_secret': input['client_secret']!},
    );
  }

  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async => disconnected.add(account.id);

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async =>
      PublishResult.ok(remoteId: '1');
}

class _CountingBroker extends FakeAuthBroker {
  int opened = 0;

  @override
  Future<Uri> authorize(Uri authorizationUrl, Uri redirectUri, {Duration timeout = const Duration(minutes: 5)}) {
    opened++;
    return super.authorize(authorizationUrl, redirectUri, timeout: timeout);
  }
}

void main() {
  late _BrowserAdapter adapter;
  late InMemoryAccountRepository accounts;
  late InMemorySecretStore secrets;
  late _CountingBroker broker;
  late List<SignInRenewalOutcome> renewals;
  late List<String> renewed;
  late List<String> told;

  final stored = ConnectedAccount(
    id: 'fake-robin',
    platformId: 'fake',
    tier: PlatformTier.byokApi,
    displayName: 'Robin',
    handle: '@robin',
    createdAt: testNow.subtract(const Duration(days: 90)),
    config: const {'clientId': 'my-app', 'userId': 'robin', 'formatting': 'markdown'},
    quotaOverrides: const {'fake.posts': 5},
    enabled: false,
    lastError: 'Fake refused to renew the sign-in (invalid_grant); reconnect the account',
  );
  const keys = {'access_token': 'dead', 'refresh_token': 'revoked', 'client_secret': 'my-secret', 'password': 'never-stored-but-checked'};

  AccountReconnector reconnector() => AccountReconnector(
        registry: AdapterRegistry([adapter]),
        accounts: accounts,
        secrets: secrets,
        renew: (id) async {
          renewed.add(id);
          return renewals.isEmpty ? const SignInRenewalOutcome(renewed: false) : renewals.removeAt(0);
        },
        connected: (a, s) async => told.add(a.id),
        clock: () => testNow,
        log: Logger('test', sink: (level, area, msg, [err]) {}),
      );

  AdapterContext ctx() => AdapterContext(
        http: NeforumHttp(client: MockClient((_) async => http.Response('', 500)), maxRetries: 0),
        broker: broker,
        clock: () => testNow,
        log: Logger('test', sink: (level, area, msg, [err]) {}),
      );

  setUp(() async {
    adapter = _BrowserAdapter();
    accounts = InMemoryAccountRepository();
    secrets = InMemorySecretStore();
    broker = _CountingBroker();
    renewals = [];
    renewed = [];
    told = [];
    await accounts.upsert(stored);
    await secrets.write(stored.id, keys);
  });

  test('keys that still renew by themselves reconnect with no browser', () async {
    renewals.add(const SignInRenewalOutcome(renewed: true));
    final out = await reconnector().reconnect(stored.id, ctx());
    expect(out.result, ReconnectResult.renewed);
    expect(renewed, [stored.id]);
    expect(broker.opened, 0);
    expect(adapter.connects, isEmpty);
    expect((await accounts.get(stored.id))!.lastError, isNull);
  });

  test('a revoked sign-in signs in again through the browser with the saved app keys, nothing typed', () async {
    renewals.add(const SignInRenewalOutcome(renewed: false, error: PublishError.auth('invalid_grant', statusCode: 400)));
    final out = await reconnector().reconnect(stored.id, ctx());

    expect(out.result, ReconnectResult.reconnected);
    expect(broker.opened, 1);
    // The app keys only: never the dead token, never a password.
    expect(adapter.connects.single, {'client_id': 'my-app', 'client_secret': 'my-secret'});

    final account = (await accounts.get(stored.id))!;
    expect(account.lastError, isNull);
    // The same account: its switches, limits and options stay as they were.
    expect(account.enabled, isFalse);
    expect(account.quotaOverrides, {'fake.posts': 5});
    expect(account.createdAt, stored.createdAt);
    expect(account.config['formatting'], 'markdown');
    expect(account.displayName, 'Robin Renamed');

    final now = (await secrets.read(stored.id))!;
    expect(now['access_token'], 'new-access');
    expect(now['client_secret'], 'my-secret');
    expect(now.containsKey('password'), isFalse);
    expect(now[SignInSecretKeys.lastRenewedAt], testNow.toUtc().toIso8601String());
    expect(told, [stored.id]);
  });

  test('a sign-in as another account changes nothing and revokes the stray keys', () async {
    adapter.signsInAs = 'someone-else';
    final out = await reconnector().reconnect(stored.id, ctx());
    expect(out.result, ReconnectResult.otherAccount);
    expect(out.message, contains('@someone-else'));
    expect(out.message, contains('@robin'));
    expect(adapter.disconnected, ['fake-someone-else']);
    expect(await secrets.read(stored.id), keys);
    expect((await accounts.get(stored.id))!.lastError, stored.lastError);
    expect(told, isEmpty);
  });

  test('closing the browser changes nothing', () async {
    adapter.connectError = const AuthCancelled();
    final out = await reconnector().reconnect(stored.id, ctx());
    expect(out.result, ReconnectResult.cancelled);
    expect(await secrets.read(stored.id), keys);
  });

  test('a sign-in the form has to fix opens the form with the reason', () async {
    adapter.connectError = const ConnectException('The client secret was rotated', field: 'client_secret');
    final out = await reconnector().reconnect(stored.id, ctx());
    expect(out.result, ReconnectResult.needsForm);
    expect(out.message, 'The client secret was rotated');
  });

  test('a renewal that cannot reach the platform says so, and opens no browser', () async {
    renewals.add(const SignInRenewalOutcome(renewed: false, error: PublishError.network('offline')));
    final out = await reconnector().reconnect(stored.id, ctx());
    expect(out.result, ReconnectResult.unreachable);
    expect(broker.opened, 0);
    expect(await secrets.read(stored.id), keys);
  });

  test('keys that were pasted open the form: only the person has new ones', () async {
    await accounts.upsert(stored.copyWith(config: {...stored.config, 'tokenSource': 'pasted'}));
    final out = await reconnector().reconnect(stored.id, ctx());
    expect(out.result, ReconnectResult.needsForm);
    expect(adapter.connects, isEmpty);
  });

  test('saved app keys that are missing open the form', () async {
    await secrets.write(stored.id, {'access_token': 'dead'});
    final out = await reconnector().reconnect(stored.id, ctx());
    expect(out.result, ReconnectResult.needsForm);
    expect(adapter.connects, isEmpty);
  });

  test('a hand-off account has nothing to reconnect', () async {
    await accounts.upsert(ConnectedAccount(id: 'h', platformId: 'fake', tier: PlatformTier.handoff, displayName: 'H', createdAt: testNow));
    final out = await reconnector().reconnect('h', ctx());
    expect(out.result, ReconnectResult.needsForm);
    expect(renewed, isEmpty);
  });

  test('with no browser to sign in with, the form opens', () async {
    final out = await reconnector().reconnect(
        stored.id, AdapterContext(http: NeforumHttp(client: MockClient((_) async => http.Response('', 500))), clock: () => testNow));
    expect(out.result, ReconnectResult.needsForm);
  });
}
