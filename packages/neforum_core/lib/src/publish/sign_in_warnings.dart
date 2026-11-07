import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../model/sign_in_lifetime.dart';
import '../storage/repositories.dart';
import '../storage/sign_in_status_store.dart';
import '../util/logger.dart';

// When NEFORUM warns that a sign-in is about to end. Everything that decides
// is a pure function of the stored statuses, the ledger of what was already
// said and the time, so each threshold can be walked with an injected clock.
//
// Holds dates, names and flags only. Nothing here ever sees a key.

/// At most this many sign-in notifications wait in the OS at once.
const int kMaxPendingSignInNotifications = 20;

/// At most this many notifications of any kind wait in the OS at once. iOS
/// keeps 64 per app and silently drops the rest. Post reminders go first.
const int kMaxPendingNotifications = 60;

/// How long past its end date this device remembers what it said about an
/// account that has gone quiet. After that nothing could fire for that date.
const Duration kSignInWarningKeptAfterEnd = Duration(days: 30);

/// How a sign-in ends, which decides how often NEFORUM warns.
enum SignInWarningCase {
  /// Nothing NEFORUM holds can extend it.
  mustReconnect,

  /// A post renews it. Only a long quiet spell ends it.
  renewsOnPost,

  /// The vendor announced the end of this way of signing in.
  hardDeadline,
}

/// Days before the end that each case warns at. "Then at the end" is day 0.
const Map<SignInWarningCase, List<int>> kSignInWarningDays = {
  SignInWarningCase.mustReconnect: [14, 7, 3, 1, 0],
  SignInWarningCase.renewsOnPost: [7, 1, 0],
  SignInWarningCase.hardDeadline: [60, 30, 14, 7, 3, 1, 0],
};

SignInWarningCase signInWarningCaseOf(SignInStatus s) => s.isHardDeadline
    ? SignInWarningCase.hardDeadline
    : (s.renewsItself ? SignInWarningCase.renewsOnPost : SignInWarningCase.mustReconnect);

/// When the warning [days] before [expiresAt] fires: 10:00 local on that day,
/// and the moment itself for the end.
DateTime signInWarningMoment(DateTime expiresAt, int days) {
  if (days == 0) return expiresAt;
  final l = expiresAt.toLocal();
  return DateTime(l.year, l.month, l.day - days, 10);
}

/// Whole days on this device's calendar from [from] to [to]. Daylight saving
/// never moves it: counted on calendar dates, not hours.
int signInCalendarDays(DateTime from, DateTime to) {
  final a = from.toLocal(), b = to.toLocal();
  return DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
}

String _dayKey(DateTime t) {
  final l = t.toLocal();
  return '${l.year.toString().padLeft(4, '0')}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
}

/// What this device already said about one account's one end date.
@immutable
class SignInWarningEntry {
  const SignInWarningEntry({required this.expiresAt, required this.firstKnownAt, this.fired = const {}, this.planned = const {}});

  factory SignInWarningEntry.fromJson(Map<String, dynamic> j) => SignInWarningEntry(
        expiresAt: DateTime.parse(j['expiresAt'] as String),
        firstKnownAt: DateTime.parse(j['firstKnownAt'] as String),
        fired: {for (final d in (j['fired'] as List? ?? const [])) d as int},
        planned: {for (final e in (j['planned'] as Map? ?? const {}).entries) int.parse(e.key as String): DateTime.parse(e.value as String)},
      );

  final DateTime expiresAt;

  /// When this device first learned the date.
  final DateTime firstKnownAt;

  /// Thresholds that fired, or that had already passed when the date became
  /// known: all of them are done with.
  final Set<int> fired;

  /// Thresholds handed to the OS, with the moment they were asked for.
  final Map<int, DateTime> planned;

  SignInWarningEntry copyWith({DateTime? expiresAt, Set<int>? fired, Map<int, DateTime>? planned}) =>
      SignInWarningEntry(expiresAt: expiresAt ?? this.expiresAt, firstKnownAt: firstKnownAt, fired: fired ?? this.fired, planned: planned ?? this.planned);

  Map<String, dynamic> toJson() => {
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        'firstKnownAt': firstKnownAt.toUtc().toIso8601String(),
        if (fired.isNotEmpty) 'fired': (fired.toList()..sort()),
        if (planned.isNotEmpty) 'planned': {for (final e in planned.entries) '${e.key}': e.value.toUtc().toIso8601String()},
      };
}

/// Everything that keeps a warning from repeating: a file of its own on each
/// device, never synced and never exported.
@immutable
class SignInWarningLedger {
  const SignInWarningLedger({this.entries = const {}, this.refused = const {}, this.bannerClosed = const {}});

  factory SignInWarningLedger.fromJson(Map<String, dynamic> j) {
    final entries = <String, SignInWarningEntry>{};
    for (final e in (j['entries'] as Map? ?? const {}).entries) {
      try {
        entries[e.key as String] = SignInWarningEntry.fromJson(Map<String, dynamic>.from(e.value as Map));
      } on Object {
        // A damaged entry counts as a date first known at the next run.
      }
    }
    final refused = <String, DateTime>{};
    for (final e in (j['refused'] as Map? ?? const {}).entries) {
      final at = e.value is String ? DateTime.tryParse(e.value as String) : null;
      if (at != null) refused[e.key as String] = at;
    }
    return SignInWarningLedger(
      entries: entries,
      refused: refused,
      bannerClosed: {for (final e in (j['bannerClosed'] as Map? ?? const {}).entries) e.key as String: '${e.value}'},
    );
  }

  /// By account id.
  final Map<String, SignInWarningEntry> entries;

  /// By account id: the refusal already announced. Gone once the sign-in works.
  final Map<String, DateTime> refused;

  /// By account id: the [SignInBannerItem.signature] the person closed.
  final Map<String, String> bannerClosed;

  SignInWarningLedger copyWith({Map<String, SignInWarningEntry>? entries, Map<String, DateTime>? refused, Map<String, String>? bannerClosed}) =>
      SignInWarningLedger(entries: entries ?? this.entries, refused: refused ?? this.refused, bannerClosed: bannerClosed ?? this.bannerClosed);

  Map<String, dynamic> toJson() => {
        'entries': {for (final e in entries.entries) e.key: e.value.toJson()},
        'refused': {for (final e in refused.entries) e.key: e.value.toUtc().toIso8601String()},
        'bannerClosed': bannerClosed,
      };
}

/// One notification, shown now or asked of the OS for [at].
@immutable
class SignInWarningNotice {
  const SignInWarningNotice({required this.status, required this.at, required this.daysBefore, required this.key});

  /// [daysBefore] of a notice about a refused sign-in.
  static const int refusedDay = -1;

  final SignInStatus status;
  final DateTime at;

  /// The threshold: 0 is the end itself, [refusedDay] a refusal.
  final int daysBefore;

  /// Stable per account, date and threshold, so asking twice replaces.
  final String key;

  bool get isRefused => daysBefore == refusedDay;
}

/// [SignInWarningNotice.key] for one threshold of one date.
String signInWarningKey(String accountId, DateTime expiresAt, int days) => 'signin:$accountId:${_dayKey(expiresAt)}:$days';

/// What one run decided.
@immutable
class SignInWarningStep {
  const SignInWarningStep({required this.ledger, this.show = const [], this.schedule = const [], this.cancel = const []});
  final SignInWarningLedger ledger;
  final List<SignInWarningNotice> show;
  final List<SignInWarningNotice> schedule;
  final List<String> cancel;
}

/// Brings [ledger] up to date with [statuses] at [now]: the accounts NEFORUM
/// should warn about, with connections only.
///
/// - Only thresholds still ahead when a date is first known count. "Still
///   ahead" goes by the calendar day, so a threshold on the day the date
///   arrives fires right away if 10:00 has gone by.
/// - A date that moves by less than a day (a server read that differs from the
///   stored date by seconds) is the same date, and nothing repeats. A date that
///   moves further is new: a renewal.
/// - After a device has been off, one notification says the latest thing:
///   every threshold that passed is done with.
/// - [schedulesAhead] (phones): future thresholds go to the OS, soonest first,
///   capped by [kMaxPendingSignInNotifications] and by what [othersPending]
///   leaves of [kMaxPendingNotifications]. A planned threshold whose moment has
///   gone by was shown by the OS, so it is not shown again.
SignInWarningStep advanceSignInWarnings(
  SignInWarningLedger ledger, {
  required Iterable<SignInStatus> statuses,
  required DateTime now,
  required bool schedulesAhead,
  int othersPending = 0,
}) {
  final entries = <String, SignInWarningEntry>{};
  final refused = <String, DateTime>{};
  final show = <SignInWarningNotice>[];
  final cancel = <String>[];
  final future = <SignInWarningNotice>[];
  final byAccount = <String, SignInStatus>{};

  void dropPlanned(String id, SignInWarningEntry e) {
    for (final d in e.planned.keys) {
      cancel.add(signInWarningKey(id, e.expiresAt, d));
    }
  }

  for (final status in statuses) {
    final id = status.accountId;
    byAccount[id] = status;
    // A refusal is said once, until the sign-in works again.
    final failure = status.lastAuthFailure;
    if (failure != null) {
      final noted = ledger.refused[id];
      refused[id] = noted ?? failure;
      if (noted == null) {
        show.add(SignInWarningNotice(status: status, at: now, daysBefore: SignInWarningNotice.refusedDay, key: 'signin:$id:refused'));
      }
    }

    final end = status.expiresAt;
    var entry = ledger.entries[id];
    if (end == null) continue;
    if (entry != null && entry.expiresAt.difference(end).abs() >= const Duration(days: 1)) {
      dropPlanned(id, entry);
      entry = null;
    }
    final days = kSignInWarningDays[signInWarningCaseOf(status)]!;
    if (entry == null) {
      final today = DateTime(now.toLocal().year, now.toLocal().month, now.toLocal().day);
      entry = SignInWarningEntry(
        expiresAt: end,
        firstKnownAt: now,
        fired: {
          for (final d in days)
            if (signInWarningMoment(end, d).toLocal().isBefore(today)) d,
        },
      );
    }
    // A date that moved within a day keeps what was said. What the OS was asked
    // for under the old date's day, at the end's old moment, or for a threshold
    // this case no longer has, is taken back; if its moment went by, the OS
    // showed it and it is done with.
    final planned = {...entry.planned};
    final fired = {...entry.fired};
    final moved = !entry.expiresAt.isAtSameMomentAs(end);
    for (final e in entry.planned.entries) {
      final oldKey = signInWarningKey(id, entry.expiresAt, e.key);
      final sameKey = days.contains(e.key) && oldKey == signInWarningKey(id, end, e.key);
      if (sameKey && !(moved && e.key == 0)) continue;
      planned.remove(e.key);
      if (!e.value.isAfter(now)) {
        fired.add(e.key);
      } else if (!sameKey) {
        cancel.add(oldKey);
      }
    }

    final due = [
      for (final d in days)
        if (!fired.contains(d) && !signInWarningMoment(end, d).isAfter(now)) d,
    ];
    if (due.isNotEmpty) {
      final shownByOs = due.where(planned.containsKey).toList();
      final missed = due.where((d) => !planned.containsKey(d)).toList();
      if (missed.isNotEmpty) {
        final latest = missed.reduce((a, b) => a < b ? a : b);
        final told = shownByOs.isEmpty ? null : shownByOs.reduce((a, b) => a < b ? a : b);
        if (told == null || latest < told) {
          show.add(SignInWarningNotice(status: status, at: now, daysBefore: latest, key: signInWarningKey(id, end, latest)));
        }
      }
      fired.addAll(due);
      due.forEach(planned.remove);
    }
    entries[id] = entry.copyWith(expiresAt: end, fired: fired, planned: planned);
    for (final d in days) {
      if (!fired.contains(d)) {
        future.add(SignInWarningNotice(status: status, at: signInWarningMoment(end, d), daysBefore: d, key: signInWarningKey(id, end, d)));
      }
    }
  }

  // Accounts that are gone, switched off, or now have no connection or no date:
  // nothing waits in the OS for them. What was said stays said, so switching one
  // off and on, or a reconnect that clears its status for a moment, repeats
  // nothing. What the OS was asked for and has shown by now counts as said.
  for (final e in ledger.entries.entries) {
    if (entries.containsKey(e.key)) continue;
    final old = e.value;
    if (!now.isBefore(old.expiresAt.add(kSignInWarningKeptAfterEnd))) continue;
    entries[e.key] = old.copyWith(
      fired: {
        ...old.fired,
        for (final p in old.planned.entries)
          if (!p.value.isAfter(now)) p.key,
      },
      planned: const {},
    );
    for (final p in old.planned.entries) {
      if (p.value.isAfter(now)) cancel.add(signInWarningKey(e.key, old.expiresAt, p.key));
    }
  }

  final schedule = <SignInWarningNotice>[];
  if (schedulesAhead) {
    future.sort((a, b) => a.at.compareTo(b.at));
    final room = (kMaxPendingNotifications - othersPending).clamp(0, kMaxPendingSignInNotifications);
    final keep = future.take(room).toList();
    for (final n in future.skip(room)) {
      final id = n.status.accountId;
      final e = entries[id];
      if (e != null && e.planned.containsKey(n.daysBefore)) {
        cancel.add(n.key);
        entries[id] = e.copyWith(planned: {...e.planned}..remove(n.daysBefore));
      }
    }
    for (final n in keep) {
      final id = n.status.accountId;
      final e = entries[id]!;
      // By the moment: a time read back from the file is UTC, and `!=` would call
      // it different from the same local time and ask the OS again on every run.
      if (!(e.planned[n.daysBefore]?.isAtSameMomentAs(n.at) ?? false)) {
        schedule.add(n);
        entries[id] = e.copyWith(planned: {...e.planned, n.daysBefore: n.at});
      }
    }
  }

  final stillOpen = {for (final e in ledger.bannerClosed.entries) if (byAccount.containsKey(e.key)) e.key: e.value};
  return SignInWarningStep(
    ledger: SignInWarningLedger(entries: entries, refused: refused, bannerClosed: stillOpen),
    show: show,
    schedule: schedule,
    cancel: cancel,
  );
}

/// One line of the banner: a sign-in at 14 days or fewer, ended, or refused.
@immutable
class SignInBannerItem {
  const SignInBannerItem({required this.status, required this.signature, required this.daysLeft, required this.ended, required this.refused});
  final SignInStatus status;

  /// Changes at each threshold: what the person closed comes back with the next.
  final String signature;

  /// Calendar days to the end. Null with no date (a refusal).
  final int? daysLeft;
  final bool ended;
  final bool refused;
}

/// Days within which a sign-in reaches the banner.
const int kSignInBannerDays = 14;

/// What the banner covers at [now], most urgent first.
List<SignInBannerItem> signInBannerItems(Iterable<SignInStatus> statuses, DateTime now) {
  final out = <SignInBannerItem>[];
  for (final s in statuses) {
    final end = s.expiresAt;
    final refused = s.lastAuthFailure != null;
    final ended = s.hasEnded(now);
    final left = end == null ? null : signInCalendarDays(now, end);
    if (!refused && !ended && (left == null || left > kSignInBannerDays)) continue;
    // The latest threshold that has come. Inside the banner's 14 days there is
    // always one: the banner's own first day counts as a threshold.
    String step;
    if (refused) {
      step = 'refused';
    } else if (ended) {
      step = '0';
    } else {
      final passed = kSignInWarningDays[signInWarningCaseOf(s)]!.where((d) => !signInWarningMoment(end!, d).isAfter(now));
      step = passed.isEmpty ? '$kSignInBannerDays' : '${passed.reduce((a, b) => a < b ? a : b)}';
    }
    out.add(SignInBannerItem(status: s, signature: '${end == null ? 'none' : _dayKey(end)}|$step', daysLeft: left, ended: ended, refused: refused));
  }
  int rank(SignInBannerItem i) => i.refused || i.ended ? -1 : (i.daysLeft ?? 0);
  out.sort((a, b) => rank(a).compareTo(rank(b)));
  return out;
}

/// The items of [items] still showing, given what the person closed.
List<SignInBannerItem> openSignInBannerItems(List<SignInBannerItem> items, Map<String, String> closed) =>
    [for (final i in items) if (closed[i.status.accountId] != i.signature) i];

/// When a date ends, in words: "on 3 Dec 2026", "about 3 Dec 2026", with "at
/// the latest" where something else can end it first. The one way a date
/// reaches a sentence, so none reads as bare where it must not.
String signInEndWords(SignInStatus s, DateTime end, String Function(DateTime) when) =>
    '${s.about ? 'about' : 'on'} ${signInDateWords(s, end, when)}';

/// [end] with "at the latest" where something else can end it first.
String signInDateWords(SignInStatus s, DateTime end, String Function(DateTime) when) => '${when(end)}${s.earlyRevocationPossible ? ' at the latest' : ''}';

/// What a notification says. Names, the handle and a date: never a key, never
/// the text of a post, and nothing a server sent.
({String title, String body}) signInWarningText(
  SignInWarningNotice n, {
  required String network,
  required String? handle,
  required DateTime now,
  required String Function(DateTime) when,
}) {
  final s = n.status;
  final who = handle == null || handle.isEmpty ? network : '$network ($handle)';
  if (n.isRefused) {
    return (title: '$network refused the sign-in', body: '$who: reconnect it. Posts to it fail until you do.');
  }
  final end = s.expiresAt!;
  final hard = s.isHardDeadline;
  final thing = hard ? '$network keys' : '$network sign-in';
  if (n.daysBefore == 0 || !now.isBefore(end)) {
    if (s.about) return (title: '$thing has probably ended', body: '$who: if a post is refused, reconnect it.');
    return (title: '$thing ended', body: '$who: reconnect it so posts keep going out.');
  }
  // The moment the person reads it, not the threshold it was planned for: a
  // late notification never says more days than are left.
  final from = n.at.isAfter(now) ? n.at : now;
  final left = signInCalendarDays(from, end);
  final phrase = left <= 0 ? 'today' : (left == 1 ? 'tomorrow' : 'in $left days');
  final words = signInEndWords(s, end, when);
  if (hard) return (title: '$thing stop working $phrase', body: '$who: they stop $words. Reconnect by browser sign-in before then.');
  if (s.renewsItself) return (title: '$thing ends $phrase unless you post', body: '$who: a post renews it. With no post it ends $words.');
  return (title: '$thing ends $phrase', body: '$who: it ends $words. Reconnect it before then.');
}

/// Reads and writes [SignInWarningLedger], one change at a time.
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

  /// Fires after every stored change by this process.
  Stream<void> get changes => _changes.stream;

  /// What is stored, for showing. Data that cannot be read counts as nothing said yet.
  Future<SignInWarningLedger> read() async {
    try {
      return await _load();
    } on Object {
      return const SignInWarningLedger();
    }
  }

  /// What is stored. Damaged data counts as nothing said; a file that cannot be
  /// read right now throws, since that says nothing about what is in it.
  Future<SignInWarningLedger> _load() async {
    final Object? data;
    try {
      data = await _read();
    } on FormatException {
      return const SignInWarningLedger();
    }
    if (data is! Map) return const SignInWarningLedger();
    try {
      return SignInWarningLedger.fromJson(Map<String, dynamic>.from(data));
    } on Object {
      return const SignInWarningLedger();
    }
  }

  Future<void> _serial(Future<void> Function() step) {
    final previous = _tail;
    final next = previous == null ? step() : previous.then((_) => step());
    _tail = next.catchError((Object _) {});
    return next;
  }

  /// Applies [change] to what is stored, one at a time. Throws, having stored
  /// nothing, when the file cannot be read: writing over it would forget what
  /// was said, and the warnings would repeat.
  Future<SignInWarningLedger> update(SignInWarningLedger Function(SignInWarningLedger) change) {
    late SignInWarningLedger out;
    return _serial(() async {
      final before = await _load();
      out = change(before);
      // The scheduler's timer runs every 30 seconds and nearly always changes
      // nothing: no write to the disk, and no rebuild of the banner.
      if (jsonEncode(out.toJson()) == jsonEncode(before.toJson())) return;
      await _write(out.toJson());
      if (!_changes.isClosed) _changes.add(null);
    }).then((_) => out);
  }

  /// Forgets everything (Delete everything), readable or not.
  Future<void> clear() => _serial(() async {
        await _write(const SignInWarningLedger().toJson());
        if (!_changes.isClosed) _changes.add(null);
      });

  void dispose() => unawaited(_changes.close());
}

/// Where notices go: the OS in the app, a list in tests.
abstract class SignInWarningSink {
  /// Shows [notice] now.
  Future<void> show(SignInWarningNotice notice);

  /// Asks the OS to show [notice] at its moment.
  Future<void> schedule(SignInWarningNotice notice);

  Future<void> cancel(String key);

  /// How many notifications that are not sign-in warnings wait in the OS.
  Future<int> othersPending();
}

/// Runs [advanceSignInWarnings] against the stores, on the scheduler's timer,
/// on launch and on every status change. What it decided is stored before
/// anything is shown, so a crash loses a notification rather than repeating one.
class SignInWarningService {
  SignInWarningService({
    required this.store,
    required this.statuses,
    required this.accounts,
    required this.sink,
    required this.schedulesAhead,
    Clock? clock,
    Logger? log,
  })  : _now = clock ?? systemClock,
        _log = log ?? Logger('sign-in');

  final SignInWarningStore store;
  final SignInStatusStore statuses;
  final AccountRepository accounts;
  final SignInWarningSink sink;

  /// Phones plan ahead. Desktops are checked on a timer, since unpackaged
  /// Windows builds cannot schedule a notification at all.
  final bool schedulesAhead;
  final Clock _now;
  final Logger _log;
  Future<void>? _tail;
  StreamSubscription<void>? _sub;

  /// Runs now and after every status change, until [stop].
  void start() {
    _sub ??= statuses.changes.listen((_) => unawaited(run()));
    unawaited(run());
  }

  void stop() {
    unawaited(_sub?.cancel());
    _sub = null;
  }

  /// One pass. Runs one at a time, and never throws.
  Future<void> run() {
    final previous = _tail;
    final next = previous == null ? _pass() : previous.then((_) => _pass());
    _tail = next;
    return next;
  }

  Future<void> _pass() async {
    try {
      // A busy file says nothing about the accounts in it: the next pass decides.
      final byId = await statuses.allIfReadable();
      if (byId == null) {
        _log.debug('The sign-in status file could not be read; the warnings wait for the next pass');
        return;
      }
      final wanted = <SignInStatus>[];
      for (final a in await accounts.all()) {
        final s = byId[a.id];
        if (a.enabled && s != null && s.hasConnection) wanted.add(s);
      }
      final others = schedulesAhead ? await sink.othersPending() : 0;
      late SignInWarningStep step;
      await store.update((ledger) {
        step = advanceSignInWarnings(ledger, statuses: wanted, now: _now(), schedulesAhead: schedulesAhead, othersPending: others);
        return step.ledger;
      });
      for (final key in step.cancel) {
        await sink.cancel(key);
      }
      for (final n in step.schedule) {
        await sink.schedule(n);
      }
      for (final n in step.show) {
        await sink.show(n);
        // The trace: how far ahead a warning really went out.
        _log.info(n.isRefused ? 'warned that ${n.status.accountId} was refused' : 'warned ${n.daysBefore} days ahead of the end of ${n.status.accountId}');
      }
    } on Object catch (e) {
      // The type only, as everywhere a sign-in is handled.
      _log.warn('Could not work out the sign-in warnings (${e.runtimeType})');
    }
  }
}
