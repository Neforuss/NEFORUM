import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../util/logger.dart';
import 'nostr_event.dart';

/// A text-frame connection to one relay. Abstracted so tests can replace
/// the WebSocket.
abstract class RelayConnection {
  /// Incoming text frames. Single subscription.
  Stream<String> get messages;

  void send(String message);

  Future<void> close();
}

/// Opens a [RelayConnection]; must complete only once the socket is ready.
typedef RelayConnector = Future<RelayConnection> Function(Uri relay);

/// Default connector: `package:web_socket_channel` (works on IO and web).
Future<RelayConnection> webSocketRelayConnector(Uri relay) async {
  final channel = WebSocketChannel.connect(relay);
  await channel.ready;
  return _WebSocketRelayConnection(channel);
}

class _WebSocketRelayConnection implements RelayConnection {
  _WebSocketRelayConnection(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<String> get messages => _channel.stream.where((m) => m is String).cast<String>();

  @override
  void send(String message) => _channel.sink.add(message);

  @override
  Future<void> close() async {
    try {
      await _channel.sink.close().timeout(const Duration(seconds: 2));
    } on Object {
      // Best effort.
    }
  }
}

/// What a relay said about one event.
///
/// [timeout] is never a relay's answer: the publisher writes it for a relay
/// that stayed silent until the end.
enum RelayAckStatus { accepted, rejected, timeout, connectionError }

/// One relay's verdict on one event.
@immutable
class RelayAck {
  const RelayAck(this.relay, this.status, [this.message = '']);

  final String relay;
  final RelayAckStatus status;

  /// The OK message (or a local description of the failure).
  final String message;

  bool get accepted => status == RelayAckStatus.accepted;

  /// Machine-readable NIP-01 prefix (`rate-limited`, `invalid`, ...), or
  /// empty.
  String get prefix {
    if (status != RelayAckStatus.rejected) return '';
    final i = message.indexOf(':');
    return i <= 0 ? '' : message.substring(0, i).trim().toLowerCase();
  }

  @override
  String toString() => '$relay: ${status.name}${message.isEmpty ? '' : ' ($message)'}';
}

/// What a relay answered to a `REQ`.
@immutable
class RelayQueryResult {
  const RelayQueryResult(this.relay, this.events, {required this.complete, this.message = ''});

  final String relay;

  /// Events whose id matches their content (see [NostrEvent.fromJson]).
  final List<NostrEvent> events;

  /// The relay sent `EOSE`: [events] is everything it has for the filter.
  final bool complete;

  /// Why the answer is not complete (`CLOSED` reason, timeout, lost
  /// connection).
  final String message;
}

/// Whether a relay has one event, asked with a `REQ` for its id.
enum RelayLookupStatus {
  /// The relay sent the event back.
  found,

  /// The relay said `EOSE` without it: it does not have the event.
  missing,

  /// No answer either way (timeout, `CLOSED`, lost connection).
  unknown,
}

/// Signs the NIP-42 AUTH event for a relay challenge.
typedef AuthEventSigner = NostrEvent Function(String relay, String challenge);

/// One event sent on a session, and the relay's answer to it.
class _Outgoing {
  _Outgoing(this.event);

  final NostrEvent event;
  final Completer<RelayAck> answer = Completer<RelayAck>();
  final Stopwatch since = Stopwatch()..start();
  bool authRetried = false;
}

/// One open `REQ`.
class _Subscription {
  _Subscription(this.filter);

  final Map<String, Object?> filter;
  final List<NostrEvent> events = [];
  final Completer<RelayQueryResult> done = Completer<RelayQueryResult>();
  bool authRetried = false;
}

/// One open relay connection that can publish events, ask for events and
/// answer NIP-42 AUTH challenges.
///
/// The answer to an event ([answerFor]) has no deadline of its own: an `OK`
/// that comes late still counts. The caller decides how long to wait.
class RelaySession {
  RelaySession._(this.relay, this._conn, this._signAuth, this._log, this._authTimeout) {
    _sub = _conn.messages.listen(_onMessage, onError: _onError, onDone: _onDone);
  }

  /// Connects to [relay]. Returns a [RelayAck] with
  /// [RelayAckStatus.connectionError] instead of throwing.
  static Future<({RelaySession? session, RelayAck? failure})> open(
    String relay,
    RelayConnector connector, {
    required Duration timeout,
    required AuthEventSigner signAuth,
    required Logger log,
    Duration authTimeout = const Duration(seconds: 10),
  }) async {
    try {
      final conn = await connector(Uri.parse(relay)).timeout(timeout);
      return (session: RelaySession._(relay, conn, signAuth, log, authTimeout), failure: null);
    } on TimeoutException {
      return (session: null, failure: RelayAck(relay, RelayAckStatus.connectionError, 'connection timed out'));
    } on Object catch (e) {
      return (session: null, failure: RelayAck(relay, RelayAckStatus.connectionError, 'could not connect: $e'));
    }
  }

  final String relay;
  final RelayConnection _conn;
  final AuthEventSigner _signAuth;
  final Logger _log;
  final Duration _authTimeout;
  late final StreamSubscription<String> _sub;

  final Map<String, _Outgoing> _outgoing = {};
  final Map<String, _Subscription> _subscriptions = {};
  int _subscriptionCount = 0;
  bool _closed = false;
  String? _authEventId;
  bool _authenticated = false;
  bool _authRefused = false;
  Completer<bool>? _authDone;

  /// The last NOTICE the relay sent: some relays explain a refusal there
  /// instead of in an OK.
  String? lastNotice;

  bool get isClosed => _closed;

  /// Whether [event] was sent on this session.
  bool hasSent(String eventId) => _outgoing.containsKey(eventId);

  /// Sends `["EVENT", event]`. Sending the same event again is safe (relays
  /// dedupe by id) and keeps waiting for the same answer.
  void send(NostrEvent event) {
    final out = _outgoing.putIfAbsent(event.id, () => _Outgoing(event));
    if (out.answer.isCompleted) return;
    if (_closed) {
      out.answer.complete(RelayAck(relay, RelayAckStatus.connectionError, 'connection closed'));
      return;
    }
    if (!_write(['EVENT', event.toJson()])) {
      out.answer.complete(RelayAck(relay, RelayAckStatus.connectionError, 'send failed'));
    }
  }

  /// The relay's answer to [eventId]: its `OK` (accepted or rejected), or a
  /// connection error. When the relay answers `auth-required:`, the session
  /// signs in (NIP-42) and sends the event once more before this completes.
  Future<RelayAck> answerFor(String eventId) {
    final out = _outgoing[eventId];
    if (out == null) throw StateError('$eventId was not sent to $relay');
    return out.answer.future;
  }

  /// Sends `["REQ", id, filter]` and collects events until `EOSE`, `CLOSED`,
  /// a lost connection or [timeout].
  Future<RelayQueryResult> query(Map<String, Object?> filter, Duration timeout) async {
    if (_closed) return RelayQueryResult(relay, const [], complete: false, message: 'connection closed');
    final id = 'neforum-${++_subscriptionCount}';
    final sub = _Subscription(filter);
    _subscriptions[id] = sub;
    if (!_write(['REQ', id, filter])) {
      _subscriptions.remove(id);
      return RelayQueryResult(relay, const [], complete: false, message: 'send failed');
    }
    try {
      return await sub.done.future.timeout(timeout,
          onTimeout: () => RelayQueryResult(relay, List.of(sub.events), complete: false, message: 'no answer within ${_seconds(timeout)}'));
    } finally {
      // CLOSE ends a REQ the relay still holds open; after CLOSED it is gone already.
      if (_subscriptions.remove(id) != null && !_closed) _write(['CLOSE', id]);
    }
  }

  /// Asks the relay whether it has [eventId].
  Future<RelayLookupStatus> lookup(String eventId, Duration timeout) async {
    final r = await query({
      'ids': [eventId],
    }, timeout);
    if (r.events.any((e) => e.id == eventId)) return RelayLookupStatus.found;
    return r.complete ? RelayLookupStatus.missing : RelayLookupStatus.unknown;
  }

  Future<void> close() async {
    _closed = true;
    _failPending('connection closed');
    // Not awaited: a cancel with nothing to wait for hands back a future of
    // the root zone, which a test's fake clock never runs.
    unawaited(_sub.cancel());
    await _conn.close();
  }

  bool _write(List<Object?> frame) {
    try {
      _conn.send(jsonEncode(frame));
      return true;
    } on Object catch (e) {
      _log.warn('$relay: send failed', e);
      return false;
    }
  }

  Future<bool> _waitAuthenticated() {
    if (_authenticated) return Future.value(true);
    if (_closed || _authRefused) return Future.value(false);
    final c = _authDone ??= Completer<bool>();
    return c.future.timeout(_authTimeout, onTimeout: () => false);
  }

  void _onMessage(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      _log.debug('$relay sent non-JSON frame');
      return;
    }
    if (decoded is! List || decoded.isEmpty) return;
    final type = decoded.first;
    switch (type) {
      case 'OK' when decoded.length >= 3:
        _onOk(decoded[1].toString(), decoded[2] == true, decoded.length > 3 ? decoded[3].toString() : '');
      case 'AUTH' when decoded.length >= 2 && decoded[1] is String:
        _onAuthChallenge(decoded[1] as String);
      case 'EVENT' when decoded.length >= 3:
        final sub = _subscriptions[decoded[1].toString()];
        final event = sub == null ? null : NostrEvent.fromJson(decoded[2]);
        if (event != null) sub!.events.add(event);
      case 'EOSE' when decoded.length >= 2:
        final id = decoded[1].toString();
        final sub = _subscriptions[id];
        if (sub != null && !sub.done.isCompleted) sub.done.complete(RelayQueryResult(relay, List.of(sub.events), complete: true));
      case 'CLOSED' when decoded.length >= 2:
        _onClosed(decoded[1].toString(), decoded.length > 2 ? decoded[2].toString() : '');
      case 'NOTICE' when decoded.length >= 2:
        lastNotice = decoded[1].toString();
        _log.info('$relay NOTICE: $lastNotice');
      default:
        break;
    }
  }

  void _onOk(String id, bool ok, String message) {
    if (id == _authEventId) {
      _authenticated = ok;
      _authRefused = !ok;
      if (!ok) _log.warn('$relay rejected NIP-42 AUTH: $message');
      final c = _authDone;
      if (c != null && !c.isCompleted) c.complete(ok);
      _authDone = null;
      return;
    }
    final out = _outgoing[id];
    if (out == null || out.answer.isCompleted) return;
    // NIP-01: "duplicate:" means the relay already has the event.
    final accepted = ok || message.toLowerCase().startsWith('duplicate:');
    final ack = RelayAck(relay, accepted ? RelayAckStatus.accepted : RelayAckStatus.rejected, message);
    if (!accepted && ack.prefix == 'auth-required' && !out.authRetried && !_closed) {
      out.authRetried = true;
      _log.debug('$relay asks for NIP-42 sign-in before it takes the note');
      unawaited(_waitAuthenticated().then((signedIn) {
        if (out.answer.isCompleted) return;
        if (signedIn && !_closed && _write(['EVENT', out.event.toJson()])) return;
        out.answer.complete(ack);
      }));
      return;
    }
    _log.debug('$relay ${accepted ? 'accepted' : 'refused'} ${id.substring(0, 8)} after ${out.since.elapsedMilliseconds} ms');
    out.answer.complete(ack);
  }

  void _onClosed(String id, String message) {
    final sub = _subscriptions[id];
    if (sub == null || sub.done.isCompleted) return;
    if (message.toLowerCase().startsWith('auth-required:') && !sub.authRetried && !_closed) {
      sub.authRetried = true;
      unawaited(_waitAuthenticated().then((signedIn) {
        if (sub.done.isCompleted) return;
        if (signedIn && !_closed && _subscriptions.containsKey(id) && _write(['REQ', id, sub.filter])) return;
        sub.done.complete(RelayQueryResult(relay, List.of(sub.events), complete: false, message: 'closed: $message'));
      }));
      return;
    }
    _subscriptions.remove(id);
    sub.done.complete(RelayQueryResult(relay, List.of(sub.events), complete: false, message: 'closed: $message'));
  }

  void _onAuthChallenge(String challenge) {
    try {
      final auth = _signAuth(relay, challenge);
      _authEventId = auth.id;
      _authenticated = false;
      _authRefused = false;
      _write(['AUTH', auth.toJson()]);
      _log.debug('$relay: answered NIP-42 AUTH challenge');
    } on Object catch (e) {
      _log.warn('$relay: could not answer AUTH challenge', e);
    }
  }

  void _onError(Object error) {
    _log.warn('$relay WebSocket error', error);
    _closed = true;
    _failPending('connection error: $error');
  }

  void _onDone() {
    _closed = true;
    _failPending('connection closed by relay');
  }

  void _failPending(String message) {
    for (final out in _outgoing.values) {
      if (!out.answer.isCompleted) out.answer.complete(RelayAck(relay, RelayAckStatus.connectionError, message));
    }
    for (final sub in _subscriptions.values) {
      if (!sub.done.isCompleted) sub.done.complete(RelayQueryResult(relay, List.of(sub.events), complete: false, message: message));
    }
    final a = _authDone;
    if (a != null && !a.isCompleted) a.complete(false);
  }
}

/// "8 s", "1.5 s": a duration for a log line or message.
String _seconds(Duration d) {
  final ms = d.inMilliseconds;
  if (ms % 1000 == 0) return '${ms ~/ 1000} s';
  return '${(ms / 1000).toStringAsFixed(1)} s';
}
