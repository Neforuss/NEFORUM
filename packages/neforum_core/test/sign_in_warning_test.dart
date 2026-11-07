// U8b: when a sign-in warning goes out, that it goes out once, and Renew now.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/instagram/instagram_adapter.dart';
import 'package:neforum_core/src/adapters/threads/threads_adapter.dart';
import 'package:neforum_core/src/adapters/x/x_adapter.dart';
import 'package:neforum_core/src/adapters/youtube/youtube_adapter.dart';
import 'package:neforum_core/src/adapters/youtube/youtube_api.dart';
import 'package:test/test.dart';

SignInStatus _status(String id, DateTime? end, {bool renews = false, bool deadline = false, DateTime? refused, bool about = false, bool connection = true, SignInLimit limit = SignInLimit.date}) => SignInStatus(
      accountId: id,
      limit: limit,
      source: SignInDateSource.serverReported,
      renewsItself: renews,
      state: end == null ? SignInState.noDate : (renews ? SignInState.renewsUntil : SignInState.endsOn),
      expiresAt: end,
      isHardDeadline: deadline,
      lastAuthFailure: refused,
      about: about,
      hasConnection: connection,
    );

class _Sink implements SignInWarningSink {
  _Sink({this.ahead = false, this.others = 0});
  final bool ahead;
  int others;
  final shown = <SignInWarningNotice>[];
  final pending = <String, DateTime>{};

  @override
  bool get schedulesAhead => ahead;
  @override
  Future<void> show(SignInWarningNotice notice) async => shown.add(notice);
  @override
  Future<int> otherPending() async => others;
  @override
  Future<void> replacePending(List<(SignInWarningNotice, DateTime)> notices) async {
    pending
      ..clear()
      ..addEntries(notices.map((e) => MapEntry(e.$1.key, e.$2)));
  }
}

/// One device: statuses and a ledger. [fresh] is a process start: everything in
/// memory goes, and only what the stores hold stays.
class _Device {
  _Device({SignInWarningSink? sink, SignInWarningStore? store, SignInStatusStore? statuses})
      : sink = sink ?? _Sink(),
        store = store ?? SignInWarningStore.inMemory(),
        statuses = statuses ?? SignInStatusStore.inMemory();

  final SignInWarningSink sink;
  final SignInWarningStore store;
  final SignInStatusStore statuses;
  DateTime now = DateTime(2026, 1, 1, 9);

  SignInWarningCenter fresh({List<String>? logs}) => SignInWarningCenter(
        statuses: statuses,
        store: store,
        sink: sink,
        clock: () => now,
        log: Logger('t', sink: (level, area, message, [error]) => logs?.add(message)),
        describe: (step, s) async => SignInWarningNotice(key: step.key, title: '${step.accountId}:${step.days}', body: '', payload: 'signin:${step.accountId}'),
      );

  Future<void> set(SignInStatus s) => statuses.change(s.accountId, (_) => s);
}

/// Walks a clock an hour at a time from [from] to [to], restarting every
/// [restartEvery] looks, and collects what went out with when.
Future<List<(int, DateTime)>> _walk(_Device d, DateTime from, DateTime to, {int restartEvery = 1}) async {
  final sink = d.sink as _Sink;
  final out = <(int, DateTime)>[];
  var center = d.fresh();
  var looks = 0;
  d.now = from;
  while (!d.now.isAfter(to)) {
    if (++looks % restartEvery == 0) center = d.fresh();
    await center.check();
    while (sink.shown.isNotEmpty) {
      final n = sink.shown.removeAt(0);
      out.add((int.parse(n.title.split(':').last), d.now));
    }
    d.now = d.now.add(const Duration(hours: 1));
  }
  return out;
}

DateTime _day(DateTime end, int before) {
  final l = end.toLocal();
  return DateTime(l.year, l.month, l.day - before);
}

void main() {
  group('the schedule', () {
    test('D13: the three tables', () {
      expect(kSignInWarningDays[SignInWarningCase.mustReconnect], [14, 7, 3, 1, 0]);
      expect(kSignInWarningDays[SignInWarningCase.renewsWhenPosting], [7, 1, 0]);
      expect(kSignInWarningDays[SignInWarningCase.hardDeadline], [60, 30, 14, 7, 3, 1, 0]);
    });

    test('which table: a vendor date, then renewal, then reconnect', () {
      final end = DateTime(2026, 6, 1);
      expect(signInWarningCaseOf(_status('a', end)), SignInWarningCase.mustReconnect);
      expect(signInWarningCaseOf(_status('a', end, renews: true)), SignInWarningCase.renewsWhenPosting);
      expect(signInWarningCaseOf(_status('a', end, renews: true, deadline: true)), SignInWarningCase.hardDeadline);
    });

    for (final (name, renews, deadline, table) in [
      ('must reconnect', false, false, [14, 7, 3, 1, 0]),
      ('renews when posting', true, false, [7, 1, 0]),
      ('vendor deadline', false, true, [60, 30, 14, 7, 3, 1, 0]),
    ]) {
      test('$name: each fires once, on its day at 10:00, and the end at the end; restarting between every look changes nothing', () async {
        final d = _Device();
        final end = DateTime(2026, 6, 20, 15, 30);
        await d.set(_status('acc', end, renews: renews, deadline: deadline));
        final from = DateTime(2026, 3, 1, 9);
        final fired = await _walk(d, from, end.add(const Duration(days: 5)));
        expect([for (final (days, _) in fired) days], table);
        for (final (days, at) in fired) {
          if (days == 0) {
            expect(at.isBefore(end), isFalse);
            expect(at.difference(end), lessThan(const Duration(hours: 1)));
          } else {
            final want = _day(end, days);
            expect((at.year, at.month, at.day), (want.year, want.month, want.day), reason: 'threshold $days');
            expect(at.hour, kSignInWarningHour, reason: 'threshold $days');
          }
        }
      });
    }

    test('never repeats after a restart, with the real file on disk', () async {
      final dir = Directory.systemTemp.createTempSync('nf-warn');
      addTearDown(() => dir.deleteSync(recursive: true));
      final end = DateTime(2026, 6, 20, 15);
      final statuses = JsonFileStore.openSignInStatus(dir.path);
      await statuses.change('acc', (_) => _status('acc', end));
      final sink = _Sink();
      final fires = <String>[];
      var at = DateTime(2026, 6, 1, 9);
      while (at.isBefore(DateTime(2026, 6, 25))) {
        // A new store and centre every look: all that survives is the file.
        final d = _Device(sink: sink, store: JsonFileStore.openSignInWarnings(dir.path), statuses: JsonFileStore.openSignInStatus(dir.path))..now = at;
        await d.fresh().check();
        fires.addAll(sink.shown.map((n) => n.title));
        sink.shown.clear();
        at = at.add(const Duration(hours: 6));
      }
      expect(fires, ['acc:14', 'acc:7', 'acc:3', 'acc:1', 'acc:0']);
      expect(File('${dir.path}/sign-in-warnings.json').existsSync(), isTrue);
    });

    test('only thresholds still ahead when the date is first known', () async {
      final d = _Device();
      final end = DateTime(2026, 6, 20, 15);
      // First known on 15 June, 09:00: 14 and 7 had already gone by.
      d.now = DateTime(2026, 6, 15, 9);
      await d.set(_status('acc', end));
      final fired = await _walk(d, d.now, end.add(const Duration(days: 1)));
      expect([for (final (days, _) in fired) days], [3, 1, 0]);
    });

    test('first known on a threshold day after 10:00: right away, once', () async {
      final d = _Device();
      final end = DateTime(2026, 6, 20, 15);
      d.now = DateTime(2026, 6, 13, 16);
      await d.set(_status('acc', end));
      final center = d.fresh();
      await center.check();
      await center.check();
      expect((d.sink as _Sink).shown.map((n) => n.title), ['acc:7']);
    });

    test('a device off past several: one warning, the nearest, and the others never come', () async {
      final d = _Device();
      final end = DateTime(2026, 6, 20, 15);
      d.now = DateTime(2026, 5, 1, 12);
      await d.set(_status('acc', end));
      await d.fresh().check();
      expect((d.sink as _Sink).shown, isEmpty);
      d.now = DateTime(2026, 6, 18, 12);
      await d.fresh().check();
      expect((d.sink as _Sink).shown.map((n) => n.title), ['acc:3']);
      d.now = DateTime(2026, 6, 18, 18);
      await d.fresh().check();
      expect((d.sink as _Sink).shown.length, 1);
    });

    test('a date that moved by seconds, even over midnight, is the same date: no second warning', () async {
      final d = _Device();
      d.now = DateTime(2026, 6, 1, 9);
      await d.set(_status('acc', DateTime(2026, 6, 20, 23, 59, 50)));
      d.now = DateTime(2026, 6, 6, 11);
      final center = d.fresh();
      await center.check();
      expect((d.sink as _Sink).shown.map((n) => n.title), ['acc:14']);
      await d.set(_status('acc', DateTime(2026, 6, 21, 0, 0, 5)));
      await center.check();
      await d.set(_status('acc', DateTime(2026, 6, 20, 23, 59, 40)));
      await center.check();
      expect((d.sink as _Sink).shown.length, 1);
    });

    test('a renewal to a new date starts its own thresholds, and coming back keeps what was given', () async {
      final d = _Device();
      final first = DateTime(2026, 6, 20, 15), second = DateTime(2026, 8, 19, 15);
      d.now = DateTime(2026, 6, 1, 9);
      await d.set(_status('acc', first, renews: true));
      final center = d.fresh();
      d.now = DateTime(2026, 6, 13, 11);
      await center.check();
      expect((d.sink as _Sink).shown.map((n) => n.title), ['acc:7']);
      await d.set(_status('acc', second, renews: true));
      d.now = DateTime(2026, 8, 12, 11);
      await center.check();
      expect((d.sink as _Sink).shown.map((n) => n.title), ['acc:7', 'acc:7']);
    });

    test('a date long gone is warned about once, however many looks and restarts follow', () async {
      final d = _Device();
      d.now = DateTime(2026, 6, 20, 11);
      await d.set(_status('acc', DateTime(2025, 1, 1)));
      for (var i = 0; i < 4; i++) {
        await d.fresh().check();
        d.now = d.now.add(const Duration(days: 40));
      }
      expect((d.sink as _Sink).shown.map((n) => n.title), ['acc:0']);
    });

    test('a date no account holds any more is forgotten; statuses that could not be read forget nothing', () async {
      final ledger = SignInWarningLedger();
      planSignInWarnings([_status('acc', DateTime(2026, 1, 1))], ledger, DateTime(2026, 1, 2));
      expect(ledger.entries['acc']!.records, hasLength(1));
      planSignInWarnings(const [], ledger, DateTime(2027, 1, 2));
      expect(ledger.entries['acc']!.records, hasLength(1));
      planSignInWarnings([_status('acc', DateTime(2027, 6, 1))], ledger, DateTime(2027, 1, 2));
      expect(ledger.entries['acc']!.records.map((r) => r.day), ['2027-06-01']);
    });

    test('no date, no connection: nothing', () async {
      final d = _Device();
      d.now = DateTime(2026, 6, 20, 11);
      await d.set(_status('a', null));
      await d.set(_status('b', DateTime(2026, 6, 21), connection: false));
      await d.fresh().check();
      expect((d.sink as _Sink).shown, isEmpty);
    });

    test('a refused sign-in warns once per refusal, and not again with its date at the same look', () async {
      final d = _Device();
      d.now = DateTime(2026, 6, 20, 11);
      final refused = DateTime(2026, 6, 20, 10);
      await d.set(_status('acc', DateTime(2026, 6, 20, 9), refused: refused));
      final center = d.fresh();
      await center.check();
      await center.check();
      expect((d.sink as _Sink).shown.map((n) => n.title), ['acc:$kSignInRefusedStage']);
      d.now = DateTime(2026, 6, 22, 11);
      await d.set(_status('acc', DateTime(2026, 6, 20, 9), refused: d.now));
      await center.check();
      expect((d.sink as _Sink).shown.length, 2);
    });

    test('a ledger that cannot be read sends nothing: it would send everything again', () async {
      final sink = _Sink();
      final d = _Device(sink: sink, store: SignInWarningStore(read: () async => throw const FileSystemException('busy'), write: (_) async {}));
      final logs = <String>[];
      d.now = DateTime(2026, 6, 20, 11);
      await d.set(_status('acc', DateTime(2026, 6, 21)));
      await d.fresh(logs: logs).check();
      expect(sink.shown, isEmpty);
      expect(logs.single, contains('FileSystemException'));
    });

    test('recorded before it is sent: a sink that fails costs that warning, not a repeat', () async {
      final d = _Device();
      d.now = DateTime(2026, 6, 19, 11);
      await d.set(_status('acc', DateTime(2026, 6, 20, 15)));
      await d.fresh().check();
      final json = jsonEncode((await d.store.read()).toJson());
      expect(json, contains('"fired"'));
    });

    test('the ledger holds days and numbers, and a log line says how far ahead', () async {
      final d = _Device();
      final logs = <String>[];
      d.now = DateTime(2026, 6, 19, 11);
      await d.set(_status('acc', DateTime(2026, 6, 20, 15)));
      await d.fresh(logs: logs).check();
      expect(logs.single, contains('warned 1 days ahead'));
      final json = (await d.store.read()).toJson() as Map;
      expect(jsonEncode(json), isNot(contains('token')));
    });

    test('a calendar day is not 24 hours: late at night tomorrow is still 1', () {
      expect(signInDaysLeft(DateTime(2026, 6, 21, 0, 30), DateTime(2026, 6, 20, 23, 30)), 1);
      expect(signInDaysLeft(DateTime(2026, 6, 20, 23, 30), DateTime(2026, 6, 20, 0, 30)), 0);
      // Across both clock changes.
      expect(signInDaysLeft(DateTime(2026, 3, 9, 12), DateTime(2026, 3, 7, 12)), 2);
      expect(signInDaysLeft(DateTime(2026, 11, 2, 12), DateTime(2026, 10, 31, 12)), 2);
    });

    test('a moment is 10:00 local across months and years', () {
      final m = signInWarningMoment(DateTime(2027, 1, 2, 3), 14);
      expect((m.year, m.month, m.day, m.hour), (2026, 12, 19, 10));
      expect(signInWarningMoment(DateTime.utc(2027, 1, 31), 0), DateTime.utc(2027, 1, 31));
    });
  });

  group('phones: waiting with the OS', () {
    test('caps: 20 sign-ins, 60 in all, post reminders first', () {
      expect(signInWarningSlots(0), 20);
      expect(signInWarningSlots(39), 20);
      expect(signInWarningSlots(40), 20);
      expect(signInWarningSlots(41), 19);
      expect(signInWarningSlots(59), 1);
      expect(signInWarningSlots(60), 0);
      expect(signInWarningSlots(500), 0);
    });

    test('48 accounts: at most 20 wait, soonest first, and reminders squeeze them', () async {
      for (final others in [0, 45, 59, 60, 80]) {
        final sink = _Sink(ahead: true, others: others);
        final d = _Device(sink: sink);
        d.now = DateTime(2026, 1, 1, 9);
        for (var i = 0; i < 48; i++) {
          await d.set(_status('a$i', DateTime(2026, 3, 1 + i, 15), deadline: i.isEven));
        }
        await d.fresh().check();
        final allowed = signInWarningSlots(others);
        expect(sink.pending.length, allowed, reason: 'with $others others');
        expect(sink.pending.length, lessThanOrEqualTo(kMaxPendingSignInWarnings));
        expect(sink.pending.length + others, lessThanOrEqualTo(others >= 60 ? others : kMaxPendingNotifications));
        final moments = sink.pending.values.toList();
        expect(moments, [...moments]..sort());
        // Nothing nearer was left out for something further.
        if (allowed > 0) {
          final plan = planSignInWarnings(
            [for (final s in (await d.statuses.all()).values) s],
            SignInWarningLedger(),
            d.now,
            schedulesAhead: true,
            slots: 500,
          );
          expect(moments, plan.ahead.take(allowed).map((s) => s.moment).toList());
        }
      }
    });

    test('delivered by the OS with the app closed: not shown again when it opens', () async {
      final sink = _Sink(ahead: true);
      final d = _Device(sink: sink);
      d.now = DateTime(2026, 6, 1, 9);
      await d.set(_status('acc', DateTime(2026, 6, 20, 15)));
      await d.fresh().check();
      expect(sink.pending.values.map((t) => t.toLocal()).toList(), [DateTime(2026, 6, 6, 10), DateTime(2026, 6, 13, 10), DateTime(2026, 6, 17, 10), DateTime(2026, 6, 19, 10), DateTime(2026, 6, 20, 15)]);
      // Opened on the 14th: the OS gave 14 and 7 itself.
      d.now = DateTime(2026, 6, 14, 9);
      await d.fresh().check();
      expect(sink.shown, isEmpty);
      expect(sink.pending.length, 3);
    });

    test('planning twice replaces rather than adds: the keys are stable', () async {
      final sink = _Sink(ahead: true);
      final d = _Device(sink: sink);
      await d.set(_status('acc', DateTime(2026, 6, 20, 15)));
      await d.fresh().check();
      final first = {...sink.pending};
      await d.fresh().check();
      expect(sink.pending, first);
    });

    test('a status change replans: a renewal drops the old date, a removal drops all', () async {
      final sink = _Sink(ahead: true);
      final d = _Device(sink: sink);
      await d.set(_status('acc', DateTime(2026, 6, 20, 15), renews: true));
      final center = d.fresh()..start();
      await Future<void>.delayed(Duration.zero);
      await center.check();
      expect(sink.pending.keys.every((k) => k.contains('2026-06-20')), isTrue);
      await d.set(_status('acc', DateTime(2026, 9, 20, 15), renews: true));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await center.check();
      expect(sink.pending.keys.every((k) => k.contains('2026-09-20')), isTrue);
      await d.statuses.remove('acc');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await center.check();
      expect(sink.pending, isEmpty);
      center.stop();
    });

    test('a desktop never schedules, only looks', () async {
      final sink = _Sink();
      final d = _Device(sink: sink);
      await d.set(_status('acc', DateTime(2026, 6, 20, 15)));
      await d.fresh().check();
      expect(sink.pending, isEmpty);
    });

    test('no sink (the demo): the ledger runs and nothing is sent', () async {
      final store = SignInWarningStore.inMemory();
      final statuses = SignInStatusStore.inMemory();
      await statuses.change('acc', (_) => _status('acc', DateTime(2026, 6, 20)));
      var described = 0;
      final center = SignInWarningCenter(statuses: statuses, store: store, clock: () => DateTime(2026, 6, 19, 12), describe: (a, b) async {
        described++;
        return null;
      });
      await center.check();
      expect(described, 0);
      expect((await store.read()).entries, contains('acc'));
    });
  });

  group('the banner', () {
    final end = DateTime(2026, 6, 20, 15);
    SignInWarningLedger none() => SignInWarningLedger();

    test('at 14 days or fewer, ended or refused; never further off, undated or hand-off', () {
      expect(signInBannerItems([_status('a', end)], none(), DateTime(2026, 6, 5)), isEmpty);
      expect(signInBannerItems([_status('a', end)], none(), DateTime(2026, 6, 6)), hasLength(1));
      expect(signInBannerItems([_status('a', end, renews: true)], none(), DateTime(2026, 6, 6)), hasLength(1), reason: '14 days whatever the case');
      expect(signInBannerItems([_status('a', end)], none(), DateTime(2026, 6, 21)).single.stage, 0);
      expect(signInBannerItems([_status('a', null)], none(), DateTime(2026, 6, 21)), isEmpty);
      expect(signInBannerItems([_status('a', end, connection: false)], none(), DateTime(2026, 6, 21)), isEmpty);
      expect(signInBannerItems([_status('a', null, refused: DateTime(2026, 6, 1))], none(), DateTime(2026, 6, 21)).single.stage, kSignInRefusedStage);
    });

    test('closed until the next threshold, and that one reopens it', () {
      final ledger = none();
      var now = DateTime(2026, 6, 7, 12);
      final items = signInBannerItems([_status('a', end)], ledger, now);
      expect(items.single.closed, isFalse);
      closeSignInBanner(items, ledger, now);
      SignInBannerItem at(DateTime t) => signInBannerItems([_status('a', end)], ledger, t).single;
      expect(at(now).closed, isTrue);
      expect(at(DateTime(2026, 6, 13, 9)).closed, isFalse, reason: '7 days');
      now = DateTime(2026, 6, 13, 9);
      closeSignInBanner(signInBannerItems([_status('a', end)], ledger, now), ledger, now);
      expect(at(DateTime(2026, 6, 16)).closed, isTrue);
      expect(at(DateTime(2026, 6, 17)).closed, isFalse, reason: '3 days');
      closeSignInBanner([at(DateTime(2026, 6, 17))], ledger, now);
      expect(at(DateTime(2026, 6, 19)).closed, isFalse, reason: '1 day');
      closeSignInBanner([at(DateTime(2026, 6, 19))], ledger, now);
      expect(at(DateTime(2026, 6, 21)).closed, isFalse, reason: 'ended');
      closeSignInBanner([at(DateTime(2026, 6, 21))], ledger, now);
      expect(at(DateTime(2026, 7, 21)).closed, isTrue, reason: 'nothing further to say');
    });

    test('a new refusal reopens what the last one closed; closing one account leaves another', () {
      final ledger = none();
      final now = DateTime(2026, 6, 7);
      final one = _status('a', null, refused: DateTime(2026, 6, 1));
      closeSignInBanner(signInBannerItems([one], ledger, now), ledger, now);
      expect(signInBannerItems([one], ledger, now).single.closed, isTrue);
      expect(signInBannerItems([_status('a', null, refused: DateTime(2026, 6, 2))], ledger, now).single.closed, isFalse);
      final other = signInBannerItems([one, _status('b', end)], ledger, now);
      expect({for (final i in other) i.status.accountId: i.closed}, {'a': true, 'b': false});
    });

    test('closed stays closed through looks, even a date long gone or a refusal with no date', () {
      final ledger = none();
      final now = DateTime(2026, 12, 1);
      final gone = _status('gone', DateTime(2026, 1, 1));
      final refused = _status('no', null, refused: DateTime(2026, 11, 1));
      closeSignInBanner(signInBannerItems([gone, refused], ledger, now), ledger, now);
      planSignInWarnings([gone, refused], ledger, now);
      final back = SignInWarningLedger.fromJson(jsonDecode(jsonEncode(ledger.toJson())));
      planSignInWarnings([gone, refused], back, now);
      expect(signInBannerItems([gone, refused], back, now).every((i) => i.closed), isTrue);
    });

    test('soonest first, refused before anything', () {
      final items = signInBannerItems([_status('late', DateTime(2026, 6, 19)), _status('early', DateTime(2026, 6, 10)), _status('no', null, refused: DateTime(2026, 6, 1))], none(), DateTime(2026, 6, 7));
      expect(items.map((i) => i.status.accountId), ['no', 'early', 'late']);
    });

    test('survives a restart through JSON', () {
      final ledger = none();
      final now = DateTime(2026, 6, 7);
      closeSignInBanner(signInBannerItems([_status('a', end)], ledger, now), ledger, now);
      final back = SignInWarningLedger.fromJson(jsonDecode(jsonEncode(ledger.toJson())));
      expect(signInBannerItems([_status('a', end)], back, now).single.closed, isTrue);
    });
  });

  group('Renew now', () {
    final now = DateTime.utc(2026, 6, 1, 12);
    ConnectedAccount acct(String platform, {Map<String, dynamic> config = const {}}) =>
        ConnectedAccount(id: 'acc', platformId: platform, tier: PlatformTier.byokApi, displayName: platform, createdAt: now, config: config);

    PublishService service(AdapterRegistry registry, ConnectedAccount a, InMemorySecretStore keys, http.Client client, {SecretsCoordinator? coordinator, SignInOutcomes? outcomes}) => PublishService(
          registry: registry,
          accounts: InMemoryAccountRepository()..upsert(a),
          posts: InMemoryPostRepository(),
          secrets: keys,
          quota: QuotaTracker(InMemoryQuotaRepository()),
          http: NeforumHttp(client: client, maxRetries: 0),
          secretsCoordinator: coordinator,
          signInOutcomes: outcomes,
          clock: () => now,
          log: Logger('t', sink: (level, area, msg, [err]) {}),
        );

    Map<String, String> tokens({required DateTime end}) => {
          OAuthTokens.keyAccessToken: 'old-access',
          OAuthTokens.keyRefreshToken: 'old-refresh',
          OAuthTokens.keyExpiresAt: end.toIso8601String(),
        };

    test('a token that is not due is renewed anyway, stored, stamped; a non-rotating one skips the coordinator', () async {
      final keys = InMemorySecretStore();
      final a = acct('youtube', config: {YouTubeConfigKeys.clientId: 'cid'});
      await keys.write(a.id, tokens(end: now.add(const Duration(minutes: 50))));
      final coordinator = _Coordinator();
      var calls = 0;
      final s = service(AdapterRegistry([YouTubeAdapter()]), a, keys, MockClient((r) async {
        calls++;
        return http.Response(jsonEncode({'access_token': 'new-access', 'expires_in': 3600}), 200, headers: {'content-type': 'application/json'});
      }), coordinator: coordinator);
      final out = await s.renewSignInNow(a.id);
      expect(out.renewed, isTrue);
      expect(out.error, isNull);
      expect(calls, 1);
      expect(coordinator.calls, 0);
      final stored = (await keys.read(a.id))!;
      expect(stored[OAuthTokens.keyAccessToken], 'new-access');
      expect(stored[StoredSecretKeys.lastRenewedAt], now.toIso8601String());
      expect(DateTime.parse(stored[OAuthTokens.keyExpiresAt]!), now.add(const Duration(hours: 1)));
    });

    test('a rotating network goes through the coordinator, as due, so it takes its turn', () async {
      final keys = InMemorySecretStore();
      final a = acct('x', config: {'authMode': 'oauth2'});
      await keys.write(a.id, tokens(end: now.add(const Duration(minutes: 50))));
      final coordinator = _Coordinator();
      final s = service(AdapterRegistry([XAdapter()]), a, keys, MockClient((r) async => fail('the coordinator decides')), coordinator: coordinator);
      await s.renewSignInNow(a.id);
      expect(coordinator.calls, 1);
      expect(coordinator.wasDue, isTrue, reason: 'keys that still work must take turns too');
    });

    test('an answer with no end keeps the end it had: the moved one is never stored', () async {
      final a = acct('x');
      final end = now.add(const Duration(minutes: 50));
      final out = await _KeepsExpiry().renewSignInNow(a, tokens(end: end), AdapterContext(http: NeforumHttp(client: MockClient((_) async => http.Response('', 500)), maxRetries: 0), clock: () => now));
      expect(out![OAuthTokens.keyExpiresAt], end.toIso8601String());
      expect(out[OAuthTokens.keyAccessToken], 'renewed');
      final none = await _KeepsExpiry().renewSignInNow(a, {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyRefreshToken: 'r'}, AdapterContext(http: NeforumHttp(client: MockClient((_) async => http.Response('', 500)), maxRetries: 0), clock: () => now));
      expect(none!.containsKey(OAuthTokens.keyExpiresAt), isFalse);
    });

    test('nothing to renew with: no call, not renewed, no error', () async {
      final keys = InMemorySecretStore();
      final a = acct('youtube', config: {YouTubeConfigKeys.clientId: 'cid'});
      await keys.write(a.id, {OAuthTokens.keyAccessToken: 'only-access', OAuthTokens.keyExpiresAt: now.add(const Duration(days: 1)).toIso8601String()});
      final s = service(AdapterRegistry([YouTubeAdapter()]), a, keys, MockClient((r) async => fail('no network')));
      final out = await s.renewSignInNow(a.id);
      expect((out.renewed, out.error), (false, null));
    });

    test('a refusal is an error and counts as a refused sign-in; a network failure does not', () async {
      final keys = InMemorySecretStore();
      final a = acct('youtube', config: {YouTubeConfigKeys.clientId: 'cid'});
      await keys.write(a.id, tokens(end: now.add(const Duration(minutes: 50))));
      final outcomes = _Outcomes();
      var s = service(AdapterRegistry([YouTubeAdapter()]), a, keys, MockClient((r) async => http.Response(jsonEncode({'error': 'invalid_grant'}), 400, headers: {'content-type': 'application/json'})), outcomes: outcomes);
      var out = await s.renewSignInNow(a.id);
      expect(out.renewed, isFalse);
      expect(out.error?.kind, PublishErrorKind.auth);
      expect(outcomes.refused, 1);
      s = service(AdapterRegistry([YouTubeAdapter()]), a, keys, MockClient((r) async => http.Response('down', 503)), outcomes: outcomes);
      out = await s.renewSignInNow(a.id);
      expect(out.error?.kind, isNot(PublishErrorKind.auth));
      expect(outcomes.refused, 1);
    });

    test('Threads and Instagram: under 24 hours old Meta refuses, so nothing is asked', () async {
      final ctx = AdapterContext(http: NeforumHttp(client: MockClient((r) async => fail('no network')), maxRetries: 0), clock: () => now);
      final threads = await ThreadsAdapter().renewSignInNow(acct('threads'), {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: now.add(const Duration(days: 50)).toIso8601String(), StoredSecretKeys.tokenIssuedAt: now.subtract(const Duration(hours: 3)).toIso8601String()}, ctx);
      expect(threads, isNull);
      final instagram = await InstagramAdapter().renewSignInNow(acct('instagram'), {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: now.add(const Duration(days: 50)).toIso8601String(), StoredSecretKeys.refreshedAt: now.subtract(const Duration(hours: 3)).toIso8601String()}, ctx);
      expect(instagram, isNull);
    });

    test('Instagram, old enough: renews though its own rule would wait, with its true stamp', () async {
      final calls = <Uri>[];
      final ctx = AdapterContext(http: NeforumHttp(client: MockClient((r) async {
        calls.add(r.url);
        return http.Response(jsonEncode({'access_token': 'fresh', 'expires_in': 5184000}), 200, headers: {'content-type': 'application/json'});
      }), maxRetries: 0), clock: () => now);
      final out = await InstagramAdapter().renewSignInNow(acct('instagram'), {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: now.add(const Duration(days: 58)).toIso8601String(), StoredSecretKeys.refreshedAt: now.subtract(const Duration(days: 2)).toIso8601String()}, ctx);
      expect(calls, hasLength(1));
      expect(out![OAuthTokens.keyAccessToken], 'fresh');
      expect(DateTime.parse(out[StoredSecretKeys.refreshedAt]!), now);
    });
  });

  // What stops a scheduled post missing a network in silence, end to end: the
  // run that fails, the status that records it, the warning that says so.
  group('a post that misses a network is never silent', () {
    final now = DateTime.utc(2026, 6, 1, 12);
    final account = ConnectedAccount(id: 'acc', platformId: 'dead', tier: PlatformTier.openApi, displayName: 'Dead', createdAt: now);

    Future<void> run(_DeadAdapter adapter, Map<String, String> keys) async {
      final accounts = InMemoryAccountRepository();
      await accounts.upsert(account);
      final posts = InMemoryPostRepository();
      final keychain = InMemorySecretStore();
      await keychain.write(account.id, keys);
      final registry = AdapterRegistry([adapter]);
      final statuses = SignInStatusStore.inMemory();
      final tracker = SignInStatusTracker(store: statuses, accounts: accounts, registry: registry, secrets: keychain, clock: () => now);
      await tracker.secretsWritten(account.id, keys);
      await posts.upsert(Post(
        id: 'p',
        text: 'Hello',
        createdAt: now,
        updatedAt: now,
        scheduledAt: now,
        status: PostStatus.scheduled,
        targets: const [PostTarget(accountId: 'acc')],
      ));
      final service = PublishService(
        registry: registry,
        accounts: accounts,
        posts: posts,
        secrets: keychain,
        quota: QuotaTracker(InMemoryQuotaRepository()),
        http: NeforumHttp(client: MockClient((_) async => http.Response('', 500)), maxRetries: 0),
        signInOutcomes: tracker,
        clock: () => now,
        log: Logger('t', sink: (level, area, msg, [err]) {}),
      );
      final done = await service.publish('p', interactive: false, retryFailed: false, dueTargetsOnly: true);
      final target = done.targets.single;
      expect(target.status, TargetStatus.failed, reason: 'never skipped or left waiting');
      expect(target.result?.error?.kind, PublishErrorKind.auth);
      expect(done.status, isNot(PostStatus.published));
      expect(done.status, isNot(PostStatus.scheduled), reason: 'not left looking fine');

      for (var i = 0; i < 20 && (await statuses.get('acc'))?.lastAuthFailure == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect((await statuses.get('acc'))?.lastAuthFailure, isNotNull);

      // Whatever Settings say about results: this is a sign-in warning.
      final sink = _Sink();
      final center = SignInWarningCenter(
        statuses: statuses,
        store: SignInWarningStore.inMemory(),
        sink: sink,
        clock: () => now,
        describe: (step, s) async => SignInWarningNotice(key: step.key, title: step.refused ? 'refused' : '${step.days}', body: '', payload: ''),
      );
      await center.check();
      expect(sink.shown.map((n) => n.title), ['refused']);
      expect(signInBannerItems((await statuses.all()).values, await center.store.read(), now).single.stage, kSignInRefusedStage);
    }

    test('the sign-in ended and nothing can renew it', () async {
      await run(_DeadAdapter(expired: true), {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: now.subtract(const Duration(days: 1)).toIso8601String()});
    });

    test('the sign-in looked fine and the network refused it', () async {
      await run(_DeadAdapter(expired: false), {OAuthTokens.keyAccessToken: 'a'});
    });
  });

  group('every adapter', () {
    test('one that answers readSignIn says so: the page asks before it reads keys', () {
      // readsSignIn gates a keychain read, so an adapter that can read but does
      // not say so would never be read, and one that says so wrongly prompts.
      final dir = Directory('lib/src/adapters');
      final files = dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart') && !f.path.endsWith('platform_adapter.dart'));
      final readers = <String>[];
      for (final f in files) {
        final text = f.readAsStringSync();
        final reads = text.contains('Future<SignInServerRead?> readSignIn(');
        final says = text.contains('bool readsSignIn(');
        expect(reads, says, reason: f.path);
        if (reads) readers.add(f.uri.pathSegments.last);
      }
      expect(readers..sort(), ['bluesky_adapter.dart', 'facebook_adapter.dart', 'lemmy_adapter.dart', 'linkedin_adapter.dart', 'threads_adapter.dart']);
    });

    test('X is never probed: pay-per-use', () {
      final x = builtinRegistry().byId('x')!;
      expect(x.readsSignIn(ConnectedAccount(id: 'a', platformId: 'x', tier: PlatformTier.byokApi, displayName: 'x', createdAt: DateTime(2026))), isFalse);
    });
  });
}

class _DeadAdapter extends PlatformAdapter {
  _DeadAdapter({required this.expired});
  final bool expired;

  @override
  SignInPolicy signInPolicyFor(ConnectedAccount account) => const SignInPolicy(limit: SignInLimit.date, renewal: SignInRenewal.never);
  @override
  PlatformDescriptor get descriptor => const PlatformDescriptor(
        id: 'dead',
        name: 'Dead',
        tiers: {PlatformTier.openApi},
        defaultTier: PlatformTier.openApi,
        text: TextRules(maxLength: 500),
        media: MediaRules(maxImages: 4),
        accountRequirements: '',
        apiCostSummary: '',
      );
  @override
  List<ConnectSpec> get connectSpecs => const [];
  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) => throw UnimplementedError();
  @override
  Future<Map<String, String>?> refreshSecrets(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (expired) throw const AdapterException(PublishError.auth('Your sign-in ended; reconnect the account'));
    return null;
  }

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async => PublishResult.failure(const PublishError.auth('Token revoked'));
}

class _Coordinator implements SecretsCoordinator {
  int calls = 0;
  bool? wasDue;
  @override
  Future<Map<String, String>?> renew(ConnectedAccount account, Map<String, String> current, SecretsRefresh refresh, {bool Function(Map<String, String> secrets)? renewsEarly}) async {
    calls++;
    wasDue = renewsEarly?.call(current);
    return null;
  }
}

class _Outcomes implements SignInOutcomes {
  int refused = 0;
  @override
  Future<void> publishFinished(ConnectedAccount account, {required bool worked, required bool refused, required AdapterContext ctx}) async {
    if (refused) this.refused++;
  }
}

/// A refresh answer with no `expires_in`, merged over what it was handed.
class _KeepsExpiry extends XAdapter {
  @override
  Future<Map<String, String>?> refreshSecrets(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async => {...secrets, OAuthTokens.keyAccessToken: 'renewed'};
}
