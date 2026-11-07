/// Client to server at a set rate, a 1 Mbit/s uplink in small. The server's
/// receive buffer stays empty, so when it closes its kernel sends a true FIN
/// and the RST only comes back when the next segment arrives. FIN is relayed as
/// FIN and RST as RST. [outage] stops forwarding for a while.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'fake_mastodon.dart' show abortive;

class PacedProxy {
  PacedProxy._(this._server, this._target, this.rate, this.outage);

  static Future<PacedProxy> start(int targetPort, {int rate = 125000, (Duration, Duration)? outage}) async {
    final p = PacedProxy._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), targetPort, rate, outage);
    p._server.listen(p._accept);
    return p;
  }

  final ServerSocket _server;
  final int _target;
  final int rate;
  final (Duration start, Duration length)? outage;

  int get port => _server.port;
  Future<void> close() => _server.close();

  Future<void> _accept(Socket client) async {
    client.setOption(SocketOption.tcpNoDelay, true);
    // Keeps what the proxy holds small, as a slow uplink would.
    try {
      client.setRawOption(RawSocketOption.fromInt(RawSocketOption.levelSocket, 0x1002, 16 * 1024));
    } on Object {
      // Only a smaller head start is lost.
    }
    final Socket server;
    try {
      server = await Socket.connect(InternetAddress.loopbackIPv4, _target);
    } on Object {
      client.destroy();
      return;
    }
    unawaited(server.done.catchError((Object _) => server));
    unawaited(client.done.catchError((Object _) => client));

    var uplinkDead = false;
    void killClient() {
      abortive(client);
      client.destroy();
    }

    // Client to server, paced.
    final began = Stopwatch()..start();
    var sent = 0;
    late final StreamSubscription<Uint8List> up;
    up = client.listen((d) async {
      up.pause();
      final o = outage;
      if (o != null) {
        final (start, length) = o;
        final at = began.elapsed;
        if (at >= start && at < start + length) await Future<void>.delayed(start + length - at);
      }
      for (var i = 0; i < d.length && !uplinkDead; i += 4096) {
        final end = i + 4096 < d.length ? i + 4096 : d.length;
        try {
          server.add(Uint8List.sublistView(d, i, end));
          await server.flush();
        } on Object {
          uplinkDead = true;
          killClient();
          return;
        }
        sent += end - i;
        final want = Duration(microseconds: sent * 1000000 ~/ rate);
        if (want > began.elapsed) await Future<void>.delayed(want - began.elapsed);
      }
      if (!uplinkDead) up.resume();
    }, onError: (Object _) {
      abortive(server);
      server.destroy();
    }, onDone: () => unawaited(server.close().catchError((Object _) => server)), cancelOnError: true);

    // Server to client, as it comes.
    server.listen(client.add, onError: (Object _) {
      uplinkDead = true;
      killClient();
    }, onDone: () {
      // FIN from the server: FIN to the client. The RST follows when the
      // paced side next writes to the server.
      unawaited(client.close().catchError((Object _) => client));
    }, cancelOnError: true);
  }
}
