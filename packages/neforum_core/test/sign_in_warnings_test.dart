// D13: the warning schedule, walked with an injected clock. Each threshold
// fires once, on the right day, and never again after a restart. Phone plans
// stay within the caps. No key reaches a notification, the ledger or the log.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/instagram/instagram_adapter.dart';
import 'package:test/test.dart';

class _Sink implements SignInWarningSink {
  _Sink(this.clock, {this.others = 0});
  final DateTime Function() clock;
  int others;
  final shown = <(DateTime, SignInWarningNotice)>[];
  final scheduled = <String, SignInWarningNotice>{};
  final cancelled = <String>[];
  @override
  Future<void> show(SignInWarningNotice notice) async => shown.add((clock(), notice));
  @override
  Future<void> schedule(SignInWarningNotice notice) async => scheduled[notice.key] = notice;
  @override
  Future<void> cancel(String key) async {
    cancelled.add(key);
    scheduled.remove(key);
  }

  @override
  Future<int> othersPending() async => others;
}

/// The ledger as a file would keep it: every read is a JSON round trip, so a
/// new store over the same data is a restart.
class _Disk {
  String? text;
  SignInWarningStore open() => SignInWarningStore(
        read: () async => text == null ? null : jsonDecode(text!),
        write: (d) async => text = jsonEncode(d),
      );
}

ConnectedAccount _account(String id, {String platform = 'linkedin', bool enabled = true}) =>
    ConnectedAccount(id: id, platformId: platform, tier: PlatformTier.byokApi, displayName: id, handle: '@$id', createdAt: DateTime.utc(2026), enabled: enabled);

SignInStatus _status(
  String id,
  DateTime? end, {
  bool renews = false,
  bool deadline = false,
  bool about = false,
  bool early = false,
  DateTime? refused,
}) =>
    SignInStatus(
      accountId: id,
      limit: SignInLimit.date,
      source: SignInDateSource.serverReported,
      renewsItself: renews,
      state: SignInState.endsOn,
      expiresAt: end,
      isHardDeadline: deadline,
      about: about,
      earlyRevocationPossible: early,
      lastAuthFailure: refused,
    );

/// [days] before [end] at 10:00 local.
DateTime _at(DateTime end, int days) => days == 0 ? end : DateTime(end.year, end.month, end.day - days, 10);

class _World {
  _World(this.now, {bool schedulesAhead = false, int others = 0}) : _ahead = schedulesAhead {
    sink = _Sink(() => now, others: others);
    open();
  }
  DateTime now;
  final bool _ahead;
  final disk = _Disk();
  final accounts = InMemoryAccountRepository();
  final statuses = SignInStatusStore.inMemory();
  late _Sink sink;
  late SignInWarningService service;

  /// A new process over the same files.
  void open() {
    service = SignInWarningService(store: disk.open(), statuses: statuses, accounts: accounts, sink: sink, schedulesAhead: _ahead, clock: () => now);
  }

  Future<void> add(SignInStatus s, {bool enabled = true}) async {
    await accounts.upsert(_account(s.accountId, enabled: enabled));
    await statuses.change(s.accountId, (_) => s);
  }

  /// Walks to [end] hour by hour, restarting every 13 hours.
  Future<void> walkTo(DateTime end) async {
    var i = 0;
    while (now.isBefore(end)) {
      now = now.add(const Duration(hours: 1));
      if (++i % 13 == 0) open();
      await service.run();
    }
  }

  List<int> get firedDays => [for (final s in sink.shown) s.$2.daysBefore];
}

void main() {
  group('each threshold fires once, on its day', () {
    final cases = <String, (SignInStatus Function(DateTime), List<int>)>{
      'you must reconnect': ((end) => _status('a', end), [14, 7, 3, 1, 0]),
      'renews when NEFORUM posts': ((end) => _status('a', end, renews: true), [7, 1, 0]),
      'a hard deadline': ((end) => _status('a', end, deadline: true), [60, 30, 14, 7, 3, 1, 0]),
    };
    cases.forEach((name, c) {
      test(name, () async {
        final end = DateTime(2027, 3, 20, 15);
        final w = _World(DateTime(2027, 1, 2, 0, 30));
        await w.add(c.$1(end));
        await w.walkTo(end.add(const Duration(days: 3)));
        expect(w.firedDays, c.$2);
        for (final (at, notice) in w.sink.shown) {
          final want = _at(end, notice.daysBefore);
          // Checked hourly: on the right day, within the hour after its moment.
          expect(at.isBefore(want), isFalse, reason: 'too early: $at for ${notice.daysBefore}');
          expect(at.difference(want).inMinutes, lessThanOrEqualTo(60), reason: 'too late: $at for ${notice.daysBefore}');
        }
      });
    });

    test('the moment is 10:00 local on that calendar day, across a clock change', () {
      expect(signInWarningMoment(DateTime(2027, 3, 30, 8), 14), DateTime(2027, 3, 16, 10));
      expect(signInWarningMoment(DateTime(2027, 11, 2, 23, 30), 7), DateTime(2027, 10, 26, 10));
      expect(signInCalendarDays(DateTime(2027, 3, 13, 23), DateTime(2027, 3, 14, 1)), 1);
    });

    test('a restart at every pass repeats nothing, reading the ledger from a real file', () async {
      final dir = Directory.systemTemp.createTempSync('nf_warn');
      addTearDown(() => dir.deleteSync(recursive: true));
      final end = DateTime(2027, 3, 20, 15);
      var now = DateTime(2027, 3, 6, 9);
      final accounts = InMemoryAccountRepository();
      await accounts.upsert(_account('a'));
      final statuses = SignInStatusStore.inMemory();
      await statuses.change('a', (_) => _status('a', end));
      final sink = _Sink(() => now);
      Future<void> pass() => SignInWarningService(store: JsonFileStore.openSignInWarnings(dir.path), statuses: statuses, accounts: accounts, sink: sink, schedulesAhead: false, clock: () => now).run();

      await pass();
      expect(sink.shown, isEmpty, reason: 'before 10:00');
      now = DateTime(2027, 3, 6, 10);
      await pass();
      await pass();
      now = DateTime(2027, 3, 6, 23);
      await pass();
      expect([for (final s in sink.shown) s.$2.daysBefore], [14]);
      expect(File('${dir.path}/sign-in-warnings.json').existsSync(), isTrue);
    });
  });

  group('only thresholds still ahead when the date is first known', () {
    test('a date first known 5 days out skips 14 and 7', () async {
      final end = DateTime(2027, 3, 20, 15);
      final w = _World(DateTime(2027, 3, 15, 8));
      await w.add(_status('a', end));
      await w.walkTo(end.add(const Duration(days: 1)));
      expect(w.firedDays, [3, 1, 0]);
    });

    test('a threshold on the day the date arrives fires right away if 10:00 has gone', () async {
      final end = DateTime(2027, 3, 20, 15);
      final w = _World(DateTime(2027, 3, 13, 14));
      await w.add(_status('a', end));
      await w.service.run();
      expect(w.firedDays, [7]);
    });

    test('a date that passed before it was known fires nothing but the banner', () async {
      final w = _World(DateTime(2027, 3, 21, 14));
      final end = DateTime(2027, 3, 20, 15);
      await w.add(_status('a', end));
      await w.service.run();
      expect(w.firedDays, isEmpty);
      expect(signInBannerItems([_status('a', end)], w.now).single.ended, isTrue);
    });

    test('a device off for days says the latest thing once', () async {
      final end = DateTime(2027, 3, 20, 15);
      final w = _World(DateTime(2027, 3, 1, 9));
      await w.add(_status('a', end));
      await w.service.run();
      w.now = DateTime(2027, 3, 18, 12);
      w.open();
      await w.service.run();
      expect(w.firedDays, [3]);
      await w.service.run();
      expect(w.firedDays, [3]);
    });
  });

  group('a date that moves', () {
    test('by seconds, as a server read differs from the stored date, repeats nothing', () async {
      final end = DateTime(2027, 3, 20, 15);
      final w = _World(DateTime(2027, 3, 13, 11));
      await w.add(_status('a', end));
      await w.service.run();
      expect(w.firedDays, [7]);
      await w.statuses.change('a', (_) => _status('a', end.add(const Duration(seconds: 40))));
      await w.service.run();
      expect(w.firedDays, [7]);
    });

    test('a renewal is a new date: its thresholds count again', () async {
      final end = DateTime(2027, 3, 20, 15);
      final w = _World(DateTime(2027, 3, 13, 11));
      await w.add(_status('a', end, renews: true));
      await w.service.run();
      expect(w.firedDays, [7]);
      final later = DateTime(2027, 9, 20, 15);
      await w.statuses.change('a', (_) => _status('a', later, renews: true));
      await w.walkTo(DateTime(2027, 9, 13, 11));
      expect(w.firedDays, [7, 7]);
      expect(w.sink.shown.last.$2.key, contains('2027-09-20'));
    });
  });

  group('who is left out', () {
    test('a switched-off account and one with no connection fire nothing', () async {
      final end = DateTime(2027, 3, 20, 15);
      final w = _World(DateTime(2027, 3, 13, 11));
      await w.add(_status('off', end), enabled: false);
      await w.accounts.upsert(_account('hand'));
      await w.statuses.change('hand', (_) => SignInStatus(accountId: 'hand', limit: SignInLimit.none, source: SignInDateSource.unknown, renewsItself: false, state: SignInState.noDate, expiresAt: end, hasConnection: false));
      await w.service.run();
      expect(w.firedDays, isEmpty);
    });

    test('a status for an account that is gone fires nothing', () async {
      final w = _World(DateTime(2027, 3, 13, 11));
      await w.statuses.change('gone', (_) => _status('gone', DateTime(2027, 3, 20, 15)));
      await w.service.run();
      expect(w.firedDays, isEmpty);
    });
  });

  group('a refused sign-in', () {
    test('says so once until it works again, then can say so again', () async {
      final w = _World(DateTime(2027, 3, 13, 11));
      await w.add(_status('a', null, refused: DateTime(2027, 3, 13, 10)));
      await w.service.run();
      await w.statuses.change('a', (_) => _status('a', null, refused: DateTime(2027, 3, 13, 12)));
      w.open();
      await w.service.run();
      expect(w.firedDays, [SignInWarningNotice.refusedDay]);
      await w.statuses.change('a', (_) => _status('a', null));
      await w.service.run();
      await w.statuses.change('a', (_) => _status('a', null, refused: DateTime(2027, 3, 14)));
      await w.service.run();
      expect(w.firedDays, [SignInWarningNotice.refusedDay, SignInWarningNotice.refusedDay]);
    });
  });

  group('phones plan ahead (D13 caps)', () {
    Future<_World> fleet(int count, {int others = 0}) async {
      final w = _World(DateTime(2027, 1, 2, 9), schedulesAhead: true, others: others);
      for (var i = 0; i < count; i++) {
        await w.add(_status('a$i', DateTime(2027, 3, 1 + i, 15)));
      }
      return w;
    }

    test('at most 20 sign-in notifications wait, soonest first', () async {
      final w = await fleet(10);
      await w.service.run();
      expect(w.sink.scheduled, hasLength(kMaxPendingSignInNotifications));
      final moments = [for (final n in w.sink.scheduled.values) n.at]..sort();
      final all = <DateTime>[
        for (var i = 0; i < 10; i++)
          for (final d in const [14, 7, 3, 1, 0]) _at(DateTime(2027, 3, 1 + i, 15), d),
      ]..sort();
      expect(moments, all.take(kMaxPendingSignInNotifications).toList());
    });

    test('reminders go first: at most 60 wait in all', () async {
      final w = await fleet(10, others: 55);
      await w.service.run();
      expect(w.sink.scheduled, hasLength(5));
    });

    test('with 60 or more reminders no sign-in notification waits', () async {
      final w = await fleet(10, others: 64);
      await w.service.run();
      expect(w.sink.scheduled, isEmpty);
    });

    test('a new reminder takes the room back at the next run', () async {
      final w = await fleet(10, others: 40);
      await w.service.run();
      expect(w.sink.scheduled, hasLength(20));
      w.sink.others = 50;
      await w.service.run();
      expect(w.sink.scheduled, hasLength(10));
      expect(w.sink.cancelled, hasLength(10));
    });

    test('what the OS showed is not shown again, and what it was never asked for is', () async {
      final end = DateTime(2027, 3, 20, 15);
      final w = _World(DateTime(2027, 1, 2, 9), schedulesAhead: true);
      await w.add(_status('a', end));
      await w.service.run();
      expect(w.sink.scheduled.length, 5);
      // The app was not running through day 14: the OS showed it.
      w.now = DateTime(2027, 3, 6, 11);
      w.open();
      await w.service.run();
      expect(w.firedDays, isEmpty);

      // Over the cap, day 1 was never handed over, and the app opens that day.
      final x = _World(DateTime(2027, 3, 18, 9), schedulesAhead: true, others: 60);
      await x.add(_status('b', end));
      await x.service.run();
      expect(x.sink.scheduled, isEmpty);
      x.now = DateTime(2027, 3, 19, 11);
      x.open();
      await x.service.run();
      expect(x.firedDays, [1]);
    });

    test('a renewal cancels what was planned for the old date', () async {
      final end = DateTime(2027, 3, 20, 15);
      final w = _World(DateTime(2027, 1, 2, 9), schedulesAhead: true);
      await w.add(_status('a', end, renews: true));
      await w.service.run();
      final old = w.sink.scheduled.keys.toSet();
      expect(old, hasLength(3));
      await w.statuses.change('a', (_) => _status('a', DateTime(2027, 9, 20, 15), renews: true));
      await w.service.run();
      expect(w.sink.cancelled.toSet(), old);
      expect(w.sink.scheduled.keys.where(old.contains), isEmpty);
      expect(w.sink.scheduled, hasLength(3));
    });

    test('a disconnected account leaves nothing waiting', () async {
      final w = _World(DateTime(2027, 1, 2, 9), schedulesAhead: true);
      await w.add(_status('a', DateTime(2027, 3, 20, 15)));
      await w.service.run();
      await w.accounts.delete('a');
      await w.service.run();
      expect(w.sink.scheduled, isEmpty);
    });
  });

  group('the banner', () {
    final now = DateTime(2027, 3, 6, 9);
    test('covers 14 days or fewer, ended and refused, most urgent first', () {
      final items = signInBannerItems([
        _status('far', DateTime(2027, 3, 21, 9)),
        _status('edge', DateTime(2027, 3, 20, 9)),
        _status('ended', DateTime(2027, 3, 5, 9)),
        _status('refused', null, refused: DateTime(2027, 3, 5)),
        _status('none', null),
      ], now);
      expect({for (final i in items) i.status.accountId}, {'edge', 'ended', 'refused'});
      expect(items.last.status.accountId, 'edge');
    });

    test('closed, it stays closed until the next threshold', () {
      final end = DateTime(2027, 3, 20, 15);
      final s = _status('a', end);
      final first = signInBannerItems([s], DateTime(2027, 3, 6, 11));
      final closed = {'a': first.single.signature};
      expect(openSignInBannerItems(first, closed), isEmpty);
      // Later that week: still the 14-day threshold.
      expect(openSignInBannerItems(signInBannerItems([s], DateTime(2027, 3, 12, 11)), closed), isEmpty);
      // The 7-day one has come.
      expect(openSignInBannerItems(signInBannerItems([s], DateTime(2027, 3, 13, 11)), closed), hasLength(1));
      // And the end.
      expect(openSignInBannerItems(signInBannerItems([s], DateTime(2027, 3, 21, 11)), closed), hasLength(1));
    });

    test('closing survives a restart, and an account that left is forgotten', () {
      final j = jsonDecode(jsonEncode(const SignInWarningLedger(bannerClosed: {'a': 'x|7', 'gone': 'y|7'}).toJson())) as Map<String, dynamic>;
      final back = SignInWarningLedger.fromJson(j);
      expect(back.bannerClosed['a'], 'x|7');
      final step = advanceSignInWarnings(back, statuses: [_status('a', null)], now: now, schedulesAhead: false);
      expect(step.ledger.bannerClosed, {'a': 'x|7'});
    });
  });

  group('the words', () {
    String day(DateTime t) => '${t.year}-${t.month}-${t.day}';
    ({String title, String body}) text(SignInStatus s, int days, DateTime now) => signInWarningText(
          SignInWarningNotice(status: s, at: now, daysBefore: days, key: 'k'),
          network: 'LinkedIn',
          handle: '@robin',
          now: now,
          when: day,
        );

    test('a date with early revocation is never bare, an estimate says about', () {
      final end = DateTime(2027, 3, 20, 15);
      final now = DateTime(2027, 3, 17, 10);
      expect(text(_status('a', end, early: true), 3, now).body, contains('on 2027-3-20 at the latest'));
      expect(text(_status('a', end, early: true, about: true, renews: true), 3, now).body, contains('about 2027-3-20 at the latest'));
      expect(text(_status('a', end), 3, now).body, isNot(contains('at the latest')));
    });

    test('says how long is really left, in each case', () {
      final end = DateTime(2027, 3, 20, 15);
      expect(text(_status('a', end), 3, DateTime(2027, 3, 17, 10)).title, 'LinkedIn sign-in ends in 3 days');
      expect(text(_status('a', end), 1, DateTime(2027, 3, 19, 10)).title, 'LinkedIn sign-in ends tomorrow');
      // A late run never overstates.
      expect(text(_status('a', end), 3, DateTime(2027, 3, 20, 9)).title, 'LinkedIn sign-in ends today');
      expect(text(_status('a', end, renews: true), 7, DateTime(2027, 3, 13, 10)).title, 'LinkedIn sign-in ends in 7 days unless you post');
      expect(text(_status('a', end, deadline: true), 60, DateTime(2027, 1, 19, 10)).title, 'LinkedIn keys stop working in 60 days');
      expect(text(_status('a', end), 0, end).title, 'LinkedIn sign-in ended');
      expect(text(_status('a', end, about: true, renews: true), 0, end).title, 'LinkedIn sign-in has probably ended');
      expect(text(_status('a', null, refused: end), SignInWarningNotice.refusedDay, end).title, 'LinkedIn refused the sign-in');
    });
  });

  group('secret guard', () {
    const secretValues = ['SECRETACCESSTOKEN', 'SECRETREFRESH', 'SECRETCLIENT'];
    test('no key reaches a notification, the warnings file, the status file or the log', () async {
      final now = DateTime.utc(2027, 3, 13, 11);
      final accounts = InMemoryAccountRepository();
      final account = ConnectedAccount(id: 'li', platformId: 'linkedin', tier: PlatformTier.byokApi, displayName: 'Robin', handle: '@robin', createdAt: DateTime.utc(2026));
      await accounts.upsert(account);
      final lines = <String>[];
      final log = Logger('t', sink: (level, area, message, [error]) => lines.add('$message $error'));
      final statuses = SignInStatusStore.inMemory();
      final tracker = SignInStatusTracker(store: statuses, accounts: accounts, registry: builtinRegistry(), secrets: InMemorySecretStore(), clock: () => now, log: log);
      final secrets = SignInStatusSecretStore(InMemorySecretStore(), tracker, log: log);
      await secrets.write('li', {
        OAuthTokens.keyAccessToken: secretValues[0],
        OAuthTokens.keyRefreshToken: secretValues[1],
        'client_secret': secretValues[2],
        OAuthTokens.keyExpiresAt: now.add(const Duration(days: 7)).toIso8601String(),
      });
      final disk = _Disk();
      final sink = _Sink(() => now);
      final service = SignInWarningService(store: disk.open(), statuses: statuses, accounts: accounts, sink: sink, schedulesAhead: true, clock: () => now, log: log);
      await service.run();
      await tracker.publishFinished(account, worked: false, refused: true, ctx: AdapterContext(http: NeforumHttp(client: MockClient((_) async => http.Response('{}', 500))), clock: () => now, log: log));
      await service.run();

      final words = <String>[
        ...lines,
        disk.text ?? '',
        jsonEncode({for (final e in (await statuses.all()).entries) e.key: e.value.toJson()}),
        for (final n in [...sink.scheduled.values, ...sink.shown.map((s) => s.$2)]) ...[
          signInWarningText(n, network: 'LinkedIn', handle: account.handle, now: now, when: (t) => t.toIso8601String()).title,
          signInWarningText(n, network: 'LinkedIn', handle: account.handle, now: now, when: (t) => t.toIso8601String()).body,
        ],
      ].join('\n');
      expect(sink.shown.length + sink.scheduled.length, greaterThan(0));
      for (final v in secretValues) {
        expect(words, isNot(contains(v)));
      }
    });
  });

  group('Renew now', () {
    final now = DateTime.utc(2027, 3, 13, 11);

    PublishService service(InMemoryAccountRepository accounts, SecretStore secrets, AdapterRegistry registry, http.Client client, {SecretsCoordinator? coordinator, SignInOutcomes? outcomes}) => PublishService(
          registry: registry,
          accounts: accounts,
          posts: InMemoryPostRepository(),
          secrets: secrets,
          quota: QuotaTracker(InMemoryQuotaRepository()),
          http: NeforumHttp(client: client),
          secretsCoordinator: coordinator,
          signInOutcomes: outcomes,
          clock: () => now,
        );

    Future<(InMemoryAccountRepository, InMemorySecretStore)> stored(ConnectedAccount a, Map<String, String> keys) async {
      final accounts = InMemoryAccountRepository();
      await accounts.upsert(a);
      final secrets = InMemorySecretStore();
      await secrets.write(a.id, keys);
      return (accounts, secrets);
    }

    test('renews a token with time left, stamps it, and stores the new date', () async {
      final a = ConnectedAccount(id: 'r', platformId: 'reddit', tier: PlatformTier.byokApi, displayName: 'r', createdAt: DateTime.utc(2026), config: const {'clientId': 'c'});
      final (accounts, secrets) = await stored(a, {OAuthTokens.keyAccessToken: 'old', OAuthTokens.keyRefreshToken: 'rt', OAuthTokens.keyExpiresAt: now.add(const Duration(minutes: 50)).toIso8601String()});
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response(jsonEncode({'access_token': 'new', 'expires_in': 3600, 'token_type': 'bearer'}), 200, headers: {'content-type': 'application/json'});
      });
      final out = await service(accounts, secrets, builtinRegistry(), client).renewSignIn('r');
      expect(out.renewed, isTrue);
      expect(calls, 1);
      final keys = (await secrets.read('r'))!;
      expect(keys[OAuthTokens.keyAccessToken], 'new');
      expect(keys[SignInSecretKeys.lastRenewedAt], isNotNull);
      expect(DateTime.parse(keys[OAuthTokens.keyExpiresAt]!).isAfter(now), isTrue, reason: 'the forced date never reaches the store');
    });

    test('an answer with no expiry drops the date instead of keeping the forced one', () async {
      final adapter = _NoDateAdapter();
      final a = ConnectedAccount(id: 'n', platformId: adapter.descriptor.id, tier: PlatformTier.byokApi, displayName: 'n', createdAt: DateTime.utc(2026));
      final (accounts, secrets) = await stored(a, {OAuthTokens.keyAccessToken: 'old', OAuthTokens.keyRefreshToken: 'rt', OAuthTokens.keyExpiresAt: now.add(const Duration(days: 1)).toIso8601String()});
      final out = await service(accounts, secrets, AdapterRegistry([adapter]), MockClient((_) async => http.Response('', 500))).renewSignIn('n');
      expect(out.renewed, isTrue);
      expect((await secrets.read('n'))!.containsKey(OAuthTokens.keyExpiresAt), isFalse);
    });

    test('a rotating platform goes through the coordinator, even with time left', () async {
      final adapter = _NoDateAdapter(rotates: true);
      final a = ConnectedAccount(id: 'n', platformId: adapter.descriptor.id, tier: PlatformTier.byokApi, displayName: 'n', createdAt: DateTime.utc(2026));
      final (accounts, secrets) = await stored(a, {OAuthTokens.keyAccessToken: 'old', OAuthTokens.keyRefreshToken: 'rt', OAuthTokens.keyExpiresAt: now.add(const Duration(days: 1)).toIso8601String()});
      final coordinator = _Coordinator();
      await service(accounts, secrets, AdapterRegistry([adapter]), MockClient((_) async => http.Response('', 500)), coordinator: coordinator).renewSignIn('n');
      expect(coordinator.calls, 1);
      expect(coordinator.saidEarly, isTrue, reason: 'it takes its turn like a due renewal');
    });

    test('a refused renewal counts as a refused sign-in; a network failure does not', () async {
      final a = ConnectedAccount(id: 'r', platformId: 'reddit', tier: PlatformTier.byokApi, displayName: 'r', createdAt: DateTime.utc(2026), config: const {'clientId': 'c'});
      final (accounts, secrets) = await stored(a, {OAuthTokens.keyAccessToken: 'old', OAuthTokens.keyRefreshToken: 'rt', OAuthTokens.keyExpiresAt: now.add(const Duration(minutes: 50)).toIso8601String()});
      final outcomes = _Outcomes();
      final refused = await service(accounts, secrets, builtinRegistry(), MockClient((_) async => http.Response('{"error":"invalid_grant"}', 400)), outcomes: outcomes).renewSignIn('r');
      expect(refused.renewed, isFalse);
      expect(refused.error?.kind, PublishErrorKind.auth);
      expect(outcomes.refused, 1);
      final failed = await service(accounts, secrets, builtinRegistry(), MockClient((_) async => http.Response('nope', 503)), outcomes: outcomes).renewSignIn('r');
      expect(failed.error?.kind, isNot(PublishErrorKind.auth));
      expect(outcomes.refused, 1);
      expect((await secrets.read('r'))![OAuthTokens.keyAccessToken], 'old');
    });

    test('nothing to renew leaves the keys alone', () async {
      final a = ConnectedAccount(id: 'm', platformId: 'misskey', tier: PlatformTier.openApi, displayName: 'm', createdAt: DateTime.utc(2026));
      final (accounts, secrets) = await stored(a, {OAuthTokens.keyAccessToken: 'tok'});
      final out = await service(accounts, secrets, builtinRegistry(), MockClient((_) async => throw StateError('no network'))).renewSignIn('m');
      expect(out.renewed, isFalse);
      expect(out.error, isNull);
      expect((await secrets.read('m'))!.keys, [OAuthTokens.keyAccessToken]);
    });

    test('Threads and Instagram renew their own way: a run-out date would mean the end', () async {
      final adapter = InstagramAdapter();
      final ctx = AdapterContext(http: NeforumHttp(client: MockClient((_) async => http.Response(jsonEncode({'access_token': 'new', 'expires_in': 5184000}), 200))), clock: () => now);
      final a = ConnectedAccount(id: 'i', platformId: 'instagram', tier: PlatformTier.byokApi, displayName: 'i', createdAt: DateTime.utc(2026));
      // Younger than Instagram's 24 hours: it would refuse, so nothing is asked.
      expect(await adapter.renewSignInNow(a, {OAuthTokens.keyAccessToken: 'tok', OAuthTokens.keyExpiresAt: now.add(const Duration(days: 50)).toIso8601String(), InstagramAdapter.keyRefreshedAt: now.subtract(const Duration(hours: 2)).toIso8601String()}, ctx), isNull);
      final fresh = await adapter.renewSignInNow(a, {OAuthTokens.keyAccessToken: 'tok', OAuthTokens.keyExpiresAt: now.add(const Duration(days: 50)).toIso8601String(), InstagramAdapter.keyRefreshedAt: now.subtract(const Duration(days: 2)).toIso8601String()}, ctx);
      expect(fresh?[OAuthTokens.keyAccessToken], 'new');
    });
  });

  group('Check now', () {
    test('is offered exactly where a read has an answer, and never for X', () {
      final canRead = <String>{};
      for (final adapter in builtinAdapters()) {
        for (final tier in PlatformTier.values) {
          final a = ConnectedAccount(id: 'x', platformId: adapter.descriptor.id, tier: tier, displayName: 'x', createdAt: DateTime.utc(2026));
          if (adapter.canReadSignIn(a)) canRead.add(adapter.descriptor.id);
        }
      }
      expect(canRead, {'facebook', 'threads', 'linkedin', 'bluesky', 'lemmy'});
    });

    test('a hand-off account of those networks is not offered it', () {
      for (final id in const ['facebook', 'threads', 'linkedin', 'bluesky', 'lemmy']) {
        final adapter = builtinRegistry().require(id);
        final a = ConnectedAccount(id: 'x', platformId: id, tier: PlatformTier.handoff, displayName: 'x', createdAt: DateTime.utc(2026));
        expect(adapter.canReadSignIn(a), isFalse, reason: id);
      }
    });
  });

  test('a damaged warnings file counts as nothing said yet', () async {
    final store = SignInWarningStore(read: () async => {'entries': {'a': {'expiresAt': 3}}, 'refused': {'b': 4}}, write: (_) async {});
    final l = await store.read();
    expect(l.entries, isEmpty);
    expect(l.refused, isEmpty);
    final bad = SignInWarningStore(read: () async => throw StateError('locked'), write: (_) async {});
    expect((await bad.read()).entries, isEmpty);
  });
}

/// A refresh path whose answer names no end.
class _NoDateAdapter extends PlatformAdapter {
  _NoDateAdapter({this.rotates = false});
  final bool rotates;

  @override
  PlatformDescriptor get descriptor => builtinRegistry().require('reddit').descriptor;

  @override
  List<ConnectSpec> get connectSpecs => const [];

  @override
  SignInPolicy signInPolicyFor(ConnectedAccount account) => const SignInPolicy(limit: SignInLimit.undocumented, renewal: SignInRenewal.onUse);

  @override
  bool rotatesRefreshTokensFor(ConnectedAccount account) => rotates;

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) => throw UnimplementedError();

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) => throw UnimplementedError();

  @override
  Future<Map<String, String>?> refreshSecrets(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (!(OAuthTokens.fromSecrets(secrets)?.isExpired(now: ctx.now()) ?? false)) return null;
    return {...secrets, OAuthTokens.keyAccessToken: 'new'};
  }
}

class _Coordinator implements SecretsCoordinator {
  int calls = 0;
  bool? saidEarly;
  @override
  Future<Map<String, String>?> renew(ConnectedAccount account, Map<String, String> current, SecretsRefresh refresh, {bool Function(Map<String, String> secrets)? renewsEarly}) async {
    calls++;
    saidEarly = renewsEarly?.call(current);
    return refresh(current);
  }
}

class _Outcomes implements SignInOutcomes {
  int refused = 0;
  @override
  Future<void> publishFinished(ConnectedAccount account, {required bool worked, required bool refused, required AdapterContext ctx}) async {
    if (refused) this.refused++;
  }
}
