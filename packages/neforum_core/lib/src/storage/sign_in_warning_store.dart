import 'dart:async';

import 'package:meta/meta.dart';

import '../model/sign_in_lifetime.dart';
import '../util/logger.dart';
import 'sign_in_status_store.dart';

/// Which warning schedule applies to a date.
enum SignInWarningCase {
  /// Nothing stored can renew it: the person has to sign in again.
  mustReconnect,

  /// A post, or Renew now, moves the date.
  renewsWhenPosting,

  /// A date the vendor announced. Nothing moves it.
  hardDeadline,
}

/// Days before the date a warning goes out, largest first. 0 is the end itself.
const Map<SignInWarningCase, List<int>> kSignInWarningDays = {
  SignInWarningCase.mustReconnect: [14, 7, 3, 1, 0],
  SignInWarningCase.renewsWhenPosting: [7, 1, 0],
  SignInWarningCase.hardDeadline: [60, 30, 14, 7, 3, 1, 0],
};

/// The banner shows from this many days before a date, whatever the case.
const int kSignInBannerDays = 14;

/// At most this many sign-in warnings wait with the phone's OS.
const int kMaxPendingSignInWarnings = 20;

/// At most this many notifications of any kind wait with the phone's OS.
/// Post reminders come first: iOS keeps only 64 and drops the rest silently.
const int kMaxPendingNotifications = 60;

/// Warnings go out at this local hour on their day.
const int kSignInWarningHour = 10;

/// What a refused sign-in counts as in [SignInWarningStep.days].
const int kSignInRefusedStage = -1;

SignInWarningCase signInWarningCaseOf(SignInStatus s) => s.isHardDeadline
    ? SignInWarningCase.hardDeadline
    : (s.renewsItself ? SignInWarningCase.renewsWhenPosting : SignInWarningCase.mustReconnect);

/// [t]'s calendar day on this device: "2026-12-04".
String signInDayKey(DateTime t) {
  final l = t.toLocal();
  return '${l.year.toString().padLeft(4, '0')}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
}

DateTime _dayOfKey(String key) => DateTime.tryParse('${key}T00:00:00Z') ?? DateTime.utc(1970);

/// Calendar days from [now] to [end] on this device: 0 today, 1 tomorrow,
/// negative once the day has gone. Never hours / 24, so a clock change or a
/// late evening does not lose a day.
int signInDaysLeft(DateTime end, DateTime now) => _dayOfKey(signInDayKey(end)).difference(_dayOfKey(signInDayKey(now))).inDays;

/// When the warning [days] before [expiresAt] is due: 10:00 local on its day,
/// and the end itself at the moment of the end.
DateTime signInWarningMoment(DateTime expiresAt, int days) {
  if (days == 0) return expiresAt;
  final l = expiresAt.toLocal();
  return DateTime(l.year, l.month, l.day - days, kSignInWarningHour);
}

/// One warning for one account's date.
@immutable
class SignInWarningStep {
  const SignInWarningStep({required this.accountId, required this.days, required this.kind, required this.moment, this.expiresAt});

  final String accountId;

  /// Days before the date, 0 at the end, [kSignInRefusedStage] for a refusal.
  final int days;
  final SignInWarningCase kind;

  /// When it is due. Past for one going out now.
  final DateTime moment;

  /// Null for a refused sign-in with no date.
  final DateTime? expiresAt;

  bool get refused => days == kSignInRefusedStage;

  /// Stable for this account, date and threshold, so planning it twice
  /// replaces rather than adds.
  String get key => 'signin:$accountId:${expiresAt == null ? 'none' : signInDayKey(expiresAt!)}:$days';
}

/// What the warnings record about one date of one account.
class SignInWarningRecord {
  SignInWarningRecord({required this.day, required this.firstKnownAt, Set<int>? fired, Map<int, DateTime>? planned, this.bannerClosedAt})
      : fired = fired ?? {},
        planned = planned ?? {};

  factory SignInWarningRecord.fromJson(Map<String, dynamic> j) => SignInWarningRecord(
        day: j['day'] as String,
        firstKnownAt: DateTime.parse(j['firstKnownAt'] as String),
        fired: {for (final v in (j['fired'] as List? ?? const [])) v as int},
        planned: {for (final e in (j['planned'] as Map? ?? const {}).entries) int.parse(e.key as String): DateTime.parse(e.value as String)},
        bannerClosedAt: j['bannerClosedAt'] as int?,
      );

  /// The date, as [signInDayKey].
  String day;

  /// When this device first knew the date: thresholds whose day had gone by
  /// then never fire.
  final DateTime firstKnownAt;

  /// Thresholds that went out, or that were passed over by a later one.
  final Set<int> fired;

  /// Thresholds waiting with the OS, and when. One whose moment has passed was
  /// delivered by the OS with the app closed.
  final Map<int, DateTime> planned;

  /// The stage ([signInBannerStage]) the banner was closed at.
  int? bannerClosedAt;

  Map<String, dynamic> toJson() => {
        'day': day,
        'firstKnownAt': firstKnownAt.toUtc().toIso8601String(),
        'fired': (fired.toList()..sort()),
        if (planned.isNotEmpty) 'planned': {for (final e in planned.entries) '${e.key}': e.value.toUtc().toIso8601String()},
        if (bannerClosedAt != null) 'bannerClosedAt': bannerClosedAt,
      };
}

class SignInWarningEntry {
  SignInWarningEntry({List<SignInWarningRecord>? records, this.refusalNoticed, this.refusalClosed}) : records = records ?? [];

  factory SignInWarningEntry.fromJson(Map<String, dynamic> j) => SignInWarningEntry(
        records: [for (final r in (j['records'] as List? ?? const [])) SignInWarningRecord.fromJson(Map<String, dynamic>.from(r as Map))],
        refusalNoticed: j['refusalNoticed'] == null ? null : DateTime.tryParse(j['refusalNoticed'] as String),
        refusalClosed: j['refusalClosed'] == null ? null : DateTime.tryParse(j['refusalClosed'] as String),
      );

  final List<SignInWarningRecord> records;

  /// The [SignInStatus.lastAuthFailure] already warned about.
  DateTime? refusalNoticed;

  /// The [SignInStatus.lastAuthFailure] the banner was closed for.
  DateTime? refusalClosed;

  /// The record of [day]. A date that moved by a day or less is the same date:
  /// `expires_in` answers differ by seconds, which can cross midnight, and that
  /// must not send the same warning again.
  SignInWarningRecord? recordFor(String day) {
    for (final r in records) {
      if (r.day == day) return r;
    }
    final d = _dayOfKey(day);
    for (final r in records) {
      if (_dayOfKey(r.day).difference(d).inDays.abs() <= 1) return r;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'records': [for (final r in records) r.toJson()],
        if (refusalNoticed != null) 'refusalNoticed': refusalNoticed!.toUtc().toIso8601String(),
        if (refusalClosed != null) 'refusalClosed': refusalClosed!.toUtc().toIso8601String(),
      };
}

/// Which warnings this device has given, per account and date. Holds days and
/// numbers only. Never synced: each device warns for itself.
class SignInWarningLedger {
  SignInWarningLedger([Map<String, SignInWarningEntry>? entries]) : entries = entries ?? {};

  factory SignInWarningLedger.fromJson(Object? data) {
    final out = SignInWarningLedger();
    if (data is! Map) return out;
    for (final e in data.entries) {
      try {
        out.entries[e.key as String] = SignInWarningEntry.fromJson(Map<String, dynamic>.from(e.value as Map));
      } on Object {
        // A damaged entry is left out.
      }
    }
    return out;
  }

  final Map<String, SignInWarningEntry> entries;

  /// Days past their date after which a record is dropped.
  static const int keepDays = 90;

  Map<String, dynamic> toJson() => {for (final e in entries.entries) e.key: e.value.toJson()};
}

/// What [planSignInWarnings] decided.
@immutable
class SignInWarningPlan {
  const SignInWarningPlan({required this.dueNow, required this.ahead});

  /// Goes out now.
  final List<SignInWarningStep> dueNow;

  /// Waits with the OS, soonest first, within the caps. Empty on a desktop.
  final List<SignInWarningStep> ahead;
}

/// How many sign-in warnings may wait with the OS while [otherPending] other
/// notifications do.
int signInWarningSlots(int otherPending) {
  final room = kMaxPendingNotifications - otherPending;
  return room <= 0 ? 0 : (room < kMaxPendingSignInWarnings ? room : kMaxPendingSignInWarnings);
}

/// Works out what is due, and records it in [ledger]. Pure but for changing
/// [ledger].
///
/// A threshold fires once. If several have come due since the last look (the
/// device was off), only the nearest goes out and the others count as given:
/// three warnings at once say nothing more than one. With [schedulesAhead]
/// (phones) up to [slots] future ones are handed to the OS, soonest first; one
/// handed over earlier whose moment has passed was delivered, and is not shown
/// again. Dropped future ones are planned at a later look, as room appears.
SignInWarningPlan planSignInWarnings(
  Iterable<SignInStatus> statuses,
  SignInWarningLedger ledger,
  DateTime now, {
  bool schedulesAhead = false,
  int slots = kMaxPendingSignInWarnings,
}) {
  final dueNow = <SignInWarningStep>[];
  final ahead = <(SignInWarningRecord, SignInWarningStep)>[];
  final today = signInDayKey(now);

  for (final s in statuses) {
    if (!s.hasConnection) continue;
    final known = ledger.entries[s.accountId];
    var refusedNow = false;
    final failure = s.lastAuthFailure;
    if (failure != null && !_sameMoment(known?.refusalNoticed, failure)) {
      (ledger.entries[s.accountId] ??= SignInWarningEntry()).refusalNoticed = failure;
      refusedNow = true;
      dueNow.add(SignInWarningStep(accountId: s.accountId, days: kSignInRefusedStage, kind: signInWarningCaseOf(s), moment: failure, expiresAt: s.expiresAt));
    }
    final end = s.expiresAt;
    if (end == null) continue;
    final entry = ledger.entries[s.accountId] ??= SignInWarningEntry();
    final day = signInDayKey(end);
    final record = entry.recordFor(day) ?? (SignInWarningRecord(day: day, firstKnownAt: now)..let(entry.records.add));
    record.day = day;
    final firstKnown = signInDayKey(record.firstKnownAt);
    final kind = signInWarningCaseOf(s);

    final dueHere = <SignInWarningStep>[];
    for (final days in kSignInWarningDays[kind]!) {
      if (record.fired.contains(days)) continue;
      final moment = signInWarningMoment(end, days);
      // The end itself always counts, however late it is first known.
      if (days != 0 && signInDayKey(moment).compareTo(firstKnown) < 0) continue;
      final handedOver = record.planned[days];
      if (handedOver != null && !handedOver.isAfter(now)) {
        record.fired.add(days);
        record.planned.remove(days);
        continue;
      }
      final step = SignInWarningStep(accountId: s.accountId, days: days, kind: kind, moment: moment, expiresAt: end);
      if (!moment.isAfter(now)) {
        dueHere.add(step);
      } else if (schedulesAhead) {
        ahead.add((record, step));
      }
    }
    record.planned.clear();
    if (dueHere.isNotEmpty) {
      // The list runs from far to near, so the last is the nearest.
      for (final step in dueHere) {
        record.fired.add(step.days);
      }
      if (!refusedNow) dueNow.add(dueHere.last);
    }
  }

  ahead.sort((a, b) => a.$2.moment.compareTo(b.$2.moment));
  final kept = ahead.take(slots).toList();
  for (final (record, step) in kept) {
    record.planned[step.days] = step.moment;
  }

  // Dates long gone that nothing refers to any more. A date still on an account
  // stays however old, or its end would be warned about again at every look.
  // No statuses at all may mean a file that could not be read, so nothing goes.
  final current = {for (final s in statuses) if (s.expiresAt != null) s.accountId: signInDayKey(s.expiresAt!)};
  if (current.isNotEmpty) {
    final todayDate = _dayOfKey(today);
    for (final e in ledger.entries.entries) {
      e.value.records.removeWhere((r) => r.day != current[e.key] && todayDate.difference(_dayOfKey(r.day)).inDays > SignInWarningLedger.keepDays);
    }
    ledger.entries.removeWhere((_, e) => e.records.isEmpty && e.refusalNoticed == null && e.refusalClosed == null);
  }

  return SignInWarningPlan(dueNow: dueNow, ahead: [for (final (_, step) in kept) step]);
}

bool _sameMoment(DateTime? a, DateTime? b) => a != null && b != null && a.isAtSameMomentAs(b);

extension _Let<T> on T {
  void let(void Function(T) f) => f(this);
}

// ---------------------------------------------------------------------------
// The banner.
// ---------------------------------------------------------------------------

/// How far [s] has come at [now], or null while it is not banner-worthy: the
/// smallest threshold reached, 0 when ended, [kSignInRefusedStage] when refused.
int? signInBannerStage(SignInStatus s, DateTime now) {
  if (!s.hasConnection) return null;
  if (s.lastAuthFailure != null) return kSignInRefusedStage;
  final end = s.expiresAt;
  if (end == null) return null;
  if (s.hasEnded(now)) return 0;
  final left = signInDaysLeft(end, now);
  if (left > kSignInBannerDays) return null;
  final stops = {kSignInBannerDays, ...kSignInWarningDays[signInWarningCaseOf(s)]!}.toList()..sort();
  return stops.firstWhere((t) => t > 0 && left <= t, orElse: () => 1);
}

/// One account the banner speaks of.
@immutable
class SignInBannerItem {
  const SignInBannerItem({required this.status, required this.stage, required this.closed});
  final SignInStatus status;
  final int stage;

  /// The banner was closed at this stage or a later one.
  final bool closed;
}

/// Everything at [kSignInBannerDays] days or fewer, or ended, or refused,
/// soonest first, with whether it is closed until its next threshold.
List<SignInBannerItem> signInBannerItems(Iterable<SignInStatus> statuses, SignInWarningLedger ledger, DateTime now) {
  final out = <SignInBannerItem>[];
  for (final s in statuses) {
    final stage = signInBannerStage(s, now);
    if (stage == null) continue;
    final entry = ledger.entries[s.accountId];
    final bool closed;
    if (stage == kSignInRefusedStage) {
      closed = _sameMoment(entry?.refusalClosed, s.lastAuthFailure);
    } else {
      final at = entry?.recordFor(signInDayKey(s.expiresAt!))?.bannerClosedAt;
      closed = at != null && at <= stage;
    }
    out.add(SignInBannerItem(status: s, stage: stage, closed: closed));
  }
  out.sort((a, b) {
    final byStage = (a.stage == kSignInRefusedStage ? 0 : 1).compareTo(b.stage == kSignInRefusedStage ? 0 : 1);
    if (byStage != 0) return byStage;
    final x = a.status.expiresAt, y = b.status.expiresAt;
    if (x == null || y == null) return x == null ? (y == null ? 0 : -1) : 1;
    return x.compareTo(y);
  });
  return out;
}

/// Marks every item as closed at its present stage.
void closeSignInBanner(Iterable<SignInBannerItem> items, SignInWarningLedger ledger, DateTime now) {
  for (final item in items) {
    final s = item.status;
    final entry = ledger.entries[s.accountId] ??= SignInWarningEntry();
    if (item.stage == kSignInRefusedStage) {
      entry.refusalClosed = s.lastAuthFailure;
      continue;
    }
    final day = signInDayKey(s.expiresAt!);
    final record = entry.recordFor(day) ?? (SignInWarningRecord(day: day, firstKnownAt: now)..let(entry.records.add));
    record.bannerClosedAt = item.stage;
  }
}

// ---------------------------------------------------------------------------
// Storage.
// ---------------------------------------------------------------------------

/// `sign-in-warnings.json`: per device, never synced or exported. Every read
/// goes to the file, since background isolates write it too.
class SignInWarningStore {
  SignInWarningStore({required Future<Object?> Function() read, required Future<void> Function(Object data) write})
      : _read = read,
        _write = write;

  factory SignInWarningStore.inMemory() {
    Object? data;
    return SignInWarningStore(read: () async => data, write: (d) async => data = d);
  }

  final Future<Object?> Function() _read;
  final Future<void> Function(Object data) _write;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Future<void>? _tail;

  /// Fires after every stored change made by this process.
  Stream<void> get changes => _changes.stream;

  /// What the file holds. Throws when it cannot be read: "no record" would send
  /// every warning again. Damaged content counts as no record.
  Future<SignInWarningLedger> read() async => SignInWarningLedger.fromJson(await _read());

  /// Applies [step] to the ledger as stored now, one change at a time.
  Future<T> change<T>(T Function(SignInWarningLedger ledger) step) {
    late T out;
    Future<void> apply() async {
      final ledger = await read();
      out = step(ledger);
      await _write(ledger.toJson());
      if (!_changes.isClosed) _changes.add(null);
    }

    final previous = _tail;
    final next = previous == null ? apply() : previous.then((_) => apply());
    _tail = next.catchError((Object _) {});
    return next.then((_) => out);
  }

  /// Forgets everything (Delete everything).
  Future<void> clear() => change((ledger) => ledger.entries.clear());

  void dispose() => unawaited(_changes.close());
}

// ---------------------------------------------------------------------------
// Giving the warnings.
// ---------------------------------------------------------------------------

/// A warning in words. Written by the app, from names and dates only.
@immutable
class SignInWarningNotice {
  const SignInWarningNotice({required this.key, required this.title, required this.body, required this.payload});
  final String key;
  final String title;
  final String body;
  final String payload;
}

/// Where warnings go: the OS's notifications, or a test's list.
abstract class SignInWarningSink {
  /// True on phones, where the app is rarely running: warnings are handed to
  /// the OS ahead of time. False on a desktop, which looks on a timer.
  bool get schedulesAhead;

  Future<void> show(SignInWarningNotice notice);

  /// How many notifications that are not sign-in warnings wait with the OS.
  Future<int> otherPending();

  /// Makes [notices] the sign-in warnings waiting with the OS: any other is
  /// cancelled.
  Future<void> replacePending(List<(SignInWarningNotice, DateTime)> notices);
}

/// Gives each warning once: on start, on the scheduler's timer, and on every
/// status change. Never throws: a warning that cannot be given costs a log line.
class SignInWarningCenter {
  SignInWarningCenter({
    required this.statuses,
    required this.store,
    required this.describe,
    this.sink,
    Clock? clock,
    Logger? log,
  })  : _now = clock ?? systemClock,
        _log = log ?? Logger('sign-in');

  final SignInStatusStore statuses;
  final SignInWarningStore store;

  /// The words for [SignInWarningStep] on a status. Null: no account any more.
  final Future<SignInWarningNotice?> Function(SignInWarningStep step, SignInStatus status) describe;

  /// Null in the demo workspace, which sends nothing: the ledger still runs,
  /// for the banner.
  final SignInWarningSink? sink;
  final Clock _now;
  final Logger _log;

  StreamSubscription<void>? _sub;
  Future<void>? _running;
  bool _again = false;

  /// Follows status changes until [stop], and looks once.
  void start() {
    _sub ??= statuses.changes.listen((_) => unawaited(check()));
    unawaited(check());
  }

  void stop() {
    unawaited(_sub?.cancel());
    _sub = null;
  }

  /// Looks now. Looks that arrive during one become one more after it.
  Future<void> check() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final run = _loop();
    _running = run;
    return run.whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _check();
    } while (_again);
  }

  Future<void> _check() async {
    try {
      final now = _now();
      final all = await statuses.all();
      final out = sink;
      final ahead = out != null && out.schedulesAhead;
      final slots = ahead ? signInWarningSlots(await out.otherPending()) : 0;
      // Recorded first: a warning lost to a crash here is covered by the banner
      // and the card; a warning sent twice cannot be taken back.
      final plan = await store.change((ledger) => planSignInWarnings(all.values, ledger, now, schedulesAhead: ahead, slots: slots));
      if (out == null) return;
      for (final step in plan.dueNow) {
        final status = all[step.accountId];
        final notice = status == null ? null : await describe(step, status);
        if (notice == null) continue;
        await out.show(notice);
        // The trace: compared with a later auth failure in the same log.
        _log.info(step.refused ? 'warned ${step.accountId}: sign-in refused' : 'warned ${step.days} days ahead: ${step.accountId} (${step.kind.name})');
      }
      if (ahead) {
        final pending = <(SignInWarningNotice, DateTime)>[];
        for (final step in plan.ahead) {
          final status = all[step.accountId];
          final notice = status == null ? null : await describe(step, status);
          if (notice != null) pending.add((notice, step.moment));
        }
        await out.replacePending(pending);
      }
    } on Object catch (e) {
      // The type only: nothing here should reach a log but names and dates.
      _log.warn('Could not check the sign-in warnings (${e.runtimeType})');
    }
  }
}
