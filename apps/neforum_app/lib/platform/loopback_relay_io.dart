import 'dart:async';
import 'dart:io';

import 'loopback_relay.dart';

Future<LoopbackRelay> startLoopbackRelay(Uri redirectUri, {required Uri callback}) async {
  final servers = await _bind(redirectUri.host, redirectUri.port);
  return _IoLoopbackRelay(redirectUri, callback, servers);
}

Future<List<HttpServer>> _bind(String host, int port) async {
  try {
    if (host != 'localhost') return [await HttpServer.bind(host, port)];
    // `localhost` can reach this device over 127.0.0.1 or ::1, whichever the
    // browser tries first, so listen on both.
    final servers = [await HttpServer.bind(InternetAddress.loopbackIPv4, port)];
    try {
      servers.add(await HttpServer.bind(InternetAddress.loopbackIPv6, port, v6Only: true));
    } on SocketException {
      // No IPv6 here: browsers then use 127.0.0.1.
    }
    return servers;
  } on SocketException catch (e) {
    throw LoopbackRelayUnavailable(port, errorCode: e.osError?.errorCode);
  }
}

class _IoLoopbackRelay implements LoopbackRelay {
  _IoLoopbackRelay(this.redirectUri, this._callback, List<HttpServer> servers) {
    _listen(servers);
  }

  @override
  final Uri redirectUri;
  final Uri _callback;
  final List<HttpServer> _servers = [];
  final List<StreamSubscription<HttpRequest>> _subs = [];
  Uri? _received;
  bool _closed = false;

  /// The restart under way, if one is.
  Future<void>? _restarting;

  /// How often the relay restarted itself after losing its listener; capped
  /// so a socket that fails straight away cannot keep it busy forever.
  int _selfRestarts = 0;
  static const int _maxSelfRestarts = 3;

  /// Why the listener last failed (the system took it away, or it could not
  /// open again), or null while it never has.
  Object? failure;

  @override
  Uri? get received => _received;

  String get _path => redirectUri.path.isEmpty ? '/' : redirectUri.path;

  void _listen(List<HttpServer> servers) {
    for (final s in servers) {
      _servers.add(s);
      _subs.add(s.listen(_handle, onError: (Object e) => _lost(e), onDone: () => _lost(null)));
    }
  }

  /// The listener reported an error or stopped without [close] or [restart]
  /// asking it to (iOS can take a suspended app's socket away): note why and
  /// listen again, so nothing goes unanswered and no error goes uncaught.
  void _lost(Object? error) {
    if (error != null) failure = error;
    if (_closed || _restarting != null || _selfRestarts >= _maxSelfRestarts) return;
    _selfRestarts++;
    unawaited(restart());
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      if (req.uri.path != _path) {
        res.statusCode = HttpStatus.notFound;
      } else if (req.method != 'GET' && req.method != 'HEAD') {
        res.statusCode = HttpStatus.methodNotAllowed;
        res.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      } else {
        final target = relayTarget(_callback, req.uri.query);
        if (req.uri.query.isNotEmpty) _received = req.uri;
        res.statusCode = HttpStatus.found;
        res.headers
          ..set(HttpHeaders.locationHeader, target.toString())
          ..set(HttpHeaders.cacheControlHeader, 'no-store')
          ..contentType = ContentType.html;
        if (req.method == 'GET') res.write(relayPage(target));
      }
      await res.close();
    } on Object {
      // The browser hung up; there is nobody left to answer.
    }
  }

  @override
  Future<void> restart() {
    if (_closed) return Future<void>.value();
    return _restarting ??= _reopen().whenComplete(() => _restarting = null);
  }

  Future<void> _reopen() async {
    await _stop();
    if (_closed) return;
    final List<HttpServer> servers;
    try {
      servers = await _bind(redirectUri.host, redirectUri.port);
    } on Object catch (e) {
      // Another app took the port meanwhile: the relay stays quiet until the
      // next restart, and an answer it already passed on still counts.
      failure = e;
      return;
    }
    if (_closed) {
      // Closed while opening: let go of the port straight away.
      _servers.addAll(servers);
      await _stop();
      return;
    }
    _listen(servers);
  }

  /// Stops answering and lets go of the port.
  Future<void> _stop() async {
    final subs = [..._subs];
    final servers = [..._servers];
    _subs.clear();
    _servers.clear();
    for (final s in subs) {
      try {
        await s.cancel();
      } on Object catch (e) {
        failure = e;
      }
    }
    for (final s in servers) {
      try {
        await s.close(force: true);
      } on Object catch (e) {
        // A socket the system already took away.
        failure = e;
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _stop();
    // A restart halfway through lets go of what it opens before this ends.
    final restarting = _restarting;
    if (restarting != null) await restarting;
  }
}
