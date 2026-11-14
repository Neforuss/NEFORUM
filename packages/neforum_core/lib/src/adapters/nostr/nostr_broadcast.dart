import 'dart:async';

import 'package:meta/meta.dart';

import '../../util/logger.dart';
import 'nostr_event.dart';
import 'nostr_relay.dart';

/// How long each step of sending a note to relays may take.
///
/// A relay's `OK` can come late when it is busy, and a relay can store the
/// note without ever saying `OK`. So a silent relay is not a failure: after
/// [ok] the publisher asks every silent relay for the note by its id (a
/// `REQ`), sends it again after each of [retryDelays], and calls the note
/// failed only when no relay has it.
@immutable
class NostrRelayTimings {
  const NostrRelayTimings({
    this.connect = const Duration(seconds: 8),
    this.connectGrace = const Duration(seconds: 3),
    this.ok = const Duration(seconds: 20),
    this.retryOk = const Duration(seconds: 10),
    this.lookup = const Duration(seconds: 8),
    this.retryDelays = const [Duration(seconds: 2), Duration(seconds: 5)],
    this.settle = const Duration(seconds: 2),
    this.progressEvery = const Duration(seconds: 5),
    this.auth = const Duration(seconds: 10),
  });

  /// For one relay's WebSocket to open.
  final Duration connect;

  /// Once one relay is open, how long the others still connecting get before
  /// the note goes out. A relay that opens later still gets the note when it
  /// is sent again.
  final Duration connectGrace;

  /// The first wait for an `OK`.
  final Duration ok;

  /// The wait for an `OK` after sending the note again.
  final Duration retryOk;

  /// For a relay to answer the `REQ` that asks whether it has the note.
  final Duration lookup;

  /// The pauses before each new send. Its length is how many times the note
  /// is sent again.
  final List<Duration> retryDelays;

  /// Once one relay accepted, how long the others get to answer before the
  /// publish moves on. Their answers only go to the log.
  final Duration settle;

  /// How often a wait says how long it has been waiting.
  final Duration progressEvery;

  /// For a NIP-42 sign-in to be confirmed.
  final Duration auth;
}

/// The open connections to the relays of one publish.
class RelayPool {
  RelayPool({required this.connector, required this.timings, required this.signAuth, required this.log});

  final RelayConnector connector;
  final NostrRelayTimings timings;
  final AuthEventSigner signAuth;
  final Logger log;

  final List<String> _order = [];
  final Map<String, RelaySession> _sessions = {};
  final Map<String, RelayAck> _failures = {};
  bool _closed = false;

  /// The relays of this publish, in the account's order.
  List<String> get relays => List.unmodifiable(_order);

  /// Open sessions, in the account's order.
  List<RelaySession> get live => [
        for (final r in _order)
          if (_sessions[r] case final s? when !s.isClosed) s,
      ];

  /// Why each relay without a session could not be opened.
  List<RelayAck> get openFailures => [
        for (final r in _order)
          if (_failures[r] case final f? when _sessions[r] == null) f,
      ];

  RelaySession? sessionOf(String relay) => _sessions[relay];

  /// Opens every relay at once. Completes once each one has opened or failed,
  /// or [NostrRelayTimings.connectGrace] after the first one opened: a relay
  /// still connecting then joins the pool when it opens.
  Future<void> openAll(List<String> relays) {
    final ready = Completer<void>();
    Timer? grace;
    void finish() {
      grace?.cancel();
      if (!ready.isCompleted) ready.complete();
    }

    var left = relays.length;
    if (left == 0) finish();
    for (final relay in relays) {
      if (!_order.contains(relay)) _order.add(relay);
      unawaited(_open(relay).then((opened) {
        if (--left == 0) return finish();
        if (opened && grace == null && !ready.isCompleted) grace = Timer(timings.connectGrace, finish);
      }));
    }
    return ready.future;
  }

  /// Opens [relay] again, after its connection was lost. Null when it fails.
  Future<RelaySession?> reopen(String relay) async {
    final current = _sessions[relay];
    if (current != null && !current.isClosed) return current;
    if (_closed) return null;
    await _open(relay);
    final s = _sessions[relay];
    return s != null && !s.isClosed ? s : null;
  }

  Future<bool> _open(String relay) async {
    final o = await RelaySession.open(relay, connector, timeout: timings.connect, signAuth: signAuth, log: log, authTimeout: timings.auth);
    final s = o.session;
    if (s == null) {
      _failures[relay] = o.failure!;
      log.warn('Nostr relay ${o.failure}');
      return false;
    }
    if (_closed) {
      // Opened after the publish ended: nobody is left to use or close it.
      unawaited(closeQuietly(s));
      return false;
    }
    final old = _sessions[relay];
    _sessions[relay] = s;
    _failures.remove(relay);
    if (old != null) unawaited(closeQuietly(old));
    return true;
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait(_sessions.values.map(closeQuietly));
  }

  static Future<void> closeQuietly(RelaySession s) async {
    try {
      await s.close();
    } on Object {
      // Best effort.
    }
  }
}

/// Where one event stands on all relays, once [RelayBroadcast.send] is done.
@immutable
class BroadcastOutcome {
  const BroadcastOutcome({required this.accepted, required this.others, required this.definite});

  /// The relays that have the note: they said `OK`, or sent it back when
  /// asked for its id. In the order they confirmed.
  final List<RelayAck> accepted;

  /// The last word of every other relay the note went to.
  final List<RelayAck> others;

  /// When nothing accepted: true when no relay can have the note, because each
  /// one refused it or was asked and does not have it. False means the note
  /// may be live on a relay that never answered.
  final bool definite;

  bool get success => accepted.isNotEmpty;
}

/// One relay's state for the event being sent.
class _RelayState {
  _RelayState(this.session);

  RelaySession session;

  /// The relay's answer: an OK either way, or a lost connection.
  RelayAck? answer;

  /// What the last check (`REQ` for the id) said.
  RelayLookupStatus? lookup;

  bool get accepted => answer?.accepted ?? false;

  /// The relay accepted or refused for good. A lost connection is not final:
  /// the note is sent again on a new one.
  bool get settled => answer != null && answer!.status != RelayAckStatus.connectionError;

  bool get definitelyWithout => (answer?.status == RelayAckStatus.rejected) || (!settled && lookup == RelayLookupStatus.missing);
}

/// Sends events to the relays of a [RelayPool] and makes sure of the outcome:
/// success as soon as one relay has the note, and a failure only when none can
/// have it (or the outcome stays unknown).
class RelayBroadcast {
  RelayBroadcast({
    required this.pool,
    required this.timings,
    required this.log,
    required this.progress,
    required this.sleep,
    this.checkCancelled,
  });

  final RelayPool pool;
  final NostrRelayTimings timings;
  final Logger log;

  /// Tells the person what is happening.
  final void Function(String message) progress;

  /// Pauses between sends; ends early (throws) when the run is cancelled.
  final Future<void> Function(Duration d) sleep;

  /// Throws when the run was cancelled.
  final void Function()? checkCancelled;

  /// Sends [event] to every open relay. [what] names it in progress messages
  /// ("the note", "part 2 of 3").
  Future<BroadcastOutcome> send(NostrEvent event, {String what = 'the note'}) async {
    final run = _Run(event);
    if (pool.live.isEmpty) {
      // Every connection dropped since the last part: open them again.
      await Future.wait(pool.relays.map(pool.reopen));
      checkCancelled?.call();
    }
    for (final s in pool.live) {
      _sendOn(run, s);
    }
    if (run.states.isEmpty) return BroadcastOutcome(accepted: const [], others: pool.openFailures, definite: true);

    await _waitFor(run, () => run.anyAccepted || run.states.values.every((s) => s.answer != null), timings.ok, what);
    for (var round = 0; !run.anyAccepted; round++) {
      final open = [
        for (final e in run.states.entries)
          if (!e.value.settled) e.key,
      ];
      if (open.isEmpty) break;
      progress('No relay has confirmed $what yet. Checking whether a relay has it');
      await _check(run, open);
      checkCancelled?.call();
      if (run.anyAccepted || round == timings.retryDelays.length) break;

      await sleep(timings.retryDelays[round]);
      checkCancelled?.call();
      final tries = timings.retryDelays.length + 1;
      progress('Sending $what again (try ${round + 2} of $tries)');
      final again = [
        for (final e in run.states.entries)
          if (!e.value.settled) e.key,
      ];
      final sessions = await Future.wait(again.map(pool.reopen));
      checkCancelled?.call();
      for (final s in sessions) {
        if (s != null) _sendOn(run, s);
      }
      // A relay that opened after the first send gets the note now.
      for (final s in pool.live) {
        if (!run.states.containsKey(s.relay)) _sendOn(run, s);
      }
      await _waitFor(run, () => run.anyAccepted || run.states.values.every((s) => s.answer != null), timings.retryOk, what);
    }
    if (run.anyAccepted) {
      // The others get a moment so the log can say where the note is.
      await _waitFor(run, () => run.states.values.every((s) => s.answer != null), timings.settle, null);
    }
    return _outcome(run);
  }

  void _sendOn(_Run run, RelaySession session) {
    final state = run.states[session.relay];
    if (state == null) {
      run.states[session.relay] = _RelayState(session);
    } else if (state.session != session) {
      state
        ..session = session
        ..answer = null;
    } else if (state.answer != null) {
      // Lost on this very session: nothing more can come over it.
      return;
    }
    session.send(run.event);
    unawaited(session.answerFor(run.event.id).then((ack) {
      final current = run.states[session.relay];
      if (current == null || current.session != session) return;
      current.answer = ack;
      if (ack.accepted && !run.confirmedOrder.contains(session.relay)) run.confirmedOrder.add(session.relay);
      run.wake();
    }));
  }

  /// Asks each relay in [relays] whether it has the note. A relay whose
  /// connection dropped is opened again first. Stops early when one relay
  /// confirms in the meantime.
  Future<void> _check(_Run run, List<String> relays) async {
    Future<void> one(String relay) async {
      final state = run.states[relay]!;
      var session = state.session;
      if (session.isClosed) {
        final reopened = await pool.reopen(relay);
        if (reopened == null) {
          state.lookup = RelayLookupStatus.unknown;
          return;
        }
        session = reopened;
      }
      final found = await session.lookup(run.event.id, timings.lookup);
      if (run.states[relay] != state) return;
      state.lookup = found;
      if (found == RelayLookupStatus.found && !state.accepted) {
        log.info('Nostr relay $relay has the note although it sent no OK');
        state.answer = RelayAck(relay, RelayAckStatus.accepted, 'no OK, but it has the note');
        if (!run.confirmedOrder.contains(relay)) run.confirmedOrder.add(relay);
        run.wake();
      }
    }

    final all = Future.wait(relays.map(one));
    await _waitUntilDone(run, all);
  }

  Future<void> _waitUntilDone(_Run run, Future<void> work) async {
    var done = false;
    unawaited(work.then<void>((_) {}, onError: (Object e) => log.warn('Nostr relay check failed', e)).whenComplete(() {
      done = true;
      run.wake();
    }));
    while (!done && !run.anyAccepted) {
      await run.changed;
    }
  }

  /// Waits until [done] holds or [limit] passes. While it waits, says every
  /// [NostrRelayTimings.progressEvery] how long it has been waiting for
  /// [what] (silent when [what] is null).
  Future<void> _waitFor(_Run run, bool Function() done, Duration limit, String? what) async {
    if (done()) return;
    var over = false;
    final deadline = Timer(limit, () {
      over = true;
      run.wake();
    });
    Timer? ticker;
    if (what != null && timings.progressEvery > Duration.zero) {
      ticker = Timer.periodic(timings.progressEvery, (t) {
        final secs = (timings.progressEvery * t.tick).inSeconds;
        progress('Waiting for the relays to confirm $what ($secs s)');
      });
    }
    try {
      while (!over && !done()) {
        await run.changed;
      }
    } finally {
      deadline.cancel();
      ticker?.cancel();
    }
  }

  BroadcastOutcome _outcome(_Run run) {
    final accepted = [
      for (final r in run.confirmedOrder) run.states[r]!.answer!,
    ];
    final others = <RelayAck>[];
    for (final e in run.states.entries) {
      final s = e.value;
      if (s.accepted) continue;
      final answer = s.answer;
      if (answer != null && answer.status == RelayAckStatus.rejected) {
        others.add(answer);
        continue;
      }
      final notice = s.session.lastNotice;
      final checked = switch (s.lookup) {
        RelayLookupStatus.missing => 'checked: it does not have the note',
        RelayLookupStatus.unknown => 'no answer when asked for the note',
        _ => null,
      };
      final said = [
        if (answer != null) answer.message else 'no OK',
        ?checked,
        if (notice != null && notice.isNotEmpty) 'NOTICE: $notice',
      ].join('; ');
      // A relay that answered the check was reached: only its OK is missing.
      final status = s.lookup == RelayLookupStatus.missing ? RelayAckStatus.timeout : (answer?.status ?? RelayAckStatus.timeout);
      others.add(RelayAck(e.key, status, said));
    }
    final definite = accepted.isEmpty && run.states.values.every((s) => s.definitelyWithout);
    return BroadcastOutcome(accepted: accepted, others: others, definite: definite);
  }
}

/// The state of one [RelayBroadcast.send].
class _Run {
  _Run(this.event);

  final NostrEvent event;
  final Map<String, _RelayState> states = {};
  final List<String> confirmedOrder = [];
  Completer<void> _changed = Completer<void>();

  bool get anyAccepted => confirmedOrder.isNotEmpty;

  /// Completes at the next change (an answer, a check, a deadline).
  Future<void> get changed => _changed.future;

  void wake() {
    final c = _changed;
    _changed = Completer<void>();
    c.complete();
  }
}
