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

/// Signs the NIP-42 AUTH event for a relay challenge.
typedef AuthEventSigner = NostrEvent Function(String relay, String challenge);

/// One open relay connection that can publish events and answer NIP-42
/// AUTH challenges.
class RelaySession {
  RelaySession._(this.relay, this._conn, this._signAuth, this._log) {
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
  }) async {
    try {
      final conn = await connector(Uri.parse(relay)).timeout(timeout);
      return (session: RelaySession._(relay, conn, signAuth, log), failure: null);
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
  late final StreamSubscription<String> _sub;

  final Map<String, Completer<RelayAck>> _pending = {};
  bool _closed = false;
  String? _authEventId;
  bool _authenticated = false;
  Completer<bool>? _authDone;

  bool get isClosed => _closed;

  /// Sends `["EVENT", event]` and waits for the matching OK. When the relay
  /// answers `auth-required:` the event is re-sent once after NIP-42 AUTH.
  Future<RelayAck> publish(NostrEvent event, Duration timeout) async {
    var ack = await _sendAndWait(event, timeout);
    if (!ack.accepted && ack.prefix == 'auth-required' && !_closed) {
      if (await _waitAuthenticated(timeout)) ack = await _sendAndWait(event, timeout);
    }
    return ack;
  }

  Future<void> close() async {
    _closed = true;
    _failPending('connection closed');
    await _sub.cancel();
    await _conn.close();
  }

  Future<RelayAck> _sendAndWait(NostrEvent event, Duration timeout) async {
    if (_closed) return RelayAck(relay, RelayAckStatus.connectionError, 'connection closed');
    final completer = Completer<RelayAck>();
    _pending[event.id] = completer;
    try {
      _conn.send(jsonEncode(['EVENT', event.toJson()]));
    } on Object catch (e) {
      _pending.remove(event.id);
      return RelayAck(relay, RelayAckStatus.connectionError, 'send failed: $e');
    }
    try {
      return await completer.future.timeout(timeout,
          onTimeout: () => RelayAck(relay, RelayAckStatus.timeout, 'no OK within ${timeout.inSeconds}s'));
    } finally {
      _pending.remove(event.id);
    }
  }

  Future<bool> _waitAuthenticated(Duration timeout) {
    if (_authenticated) return Future.value(true);
    final c = _authDone ??= Completer<bool>();
    return c.future.timeout(timeout, onTimeout: () => false);
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
      case 'NOTICE' when decoded.length >= 2:
        _log.info('$relay NOTICE: ${decoded[1]}');
      default:
        break;
    }
  }

  void _onOk(String id, bool ok, String message) {
    if (id == _authEventId) {
      _authenticated = ok;
      if (!ok) _log.warn('$relay rejected NIP-42 AUTH: $message');
      final c = _authDone;
      if (c != null && !c.isCompleted) c.complete(ok);
      _authDone = null;
      return;
    }
    final c = _pending[id];
    if (c == null || c.isCompleted) return;
    // NIP-01: "duplicate:" means the relay already has the event.
    final accepted = ok || message.toLowerCase().startsWith('duplicate:');
    c.complete(RelayAck(relay, accepted ? RelayAckStatus.accepted : RelayAckStatus.rejected, message));
  }

  void _onAuthChallenge(String challenge) {
    try {
      final auth = _signAuth(relay, challenge);
      _authEventId = auth.id;
      _authenticated = false;
      _conn.send(jsonEncode(['AUTH', auth.toJson()]));
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
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(RelayAck(relay, RelayAckStatus.connectionError, message));
    }
    final a = _authDone;
    if (a != null && !a.isCompleted) a.complete(false);
  }
}
