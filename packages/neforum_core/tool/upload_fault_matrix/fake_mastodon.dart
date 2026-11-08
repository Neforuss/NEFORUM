/// A local stand-in for a Mastodon server with exact control over how it ends
/// a connection. Loopback only. Windows only: [abortive] sets the Winsock form
/// of SO_LINGER.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What the server does with one request.
sealed class Fault {
  const Fault();
}

/// Reads the body and answers, keeping the connection open when [keepAlive].
class Serve extends Fault {
  const Serve({this.keepAlive = false});
  final bool keepAlive;
}

/// After [after] body bytes, closes the socket: FIN, then the kernel's RST when
/// the next data arrives. What most servers do when they give up on a request.
class CloseClean extends Fault {
  const CloseClean(this.after);
  final int after;
}

/// After [after] body bytes, FIN, then an explicit RST [gap] later.
class FinThenRst extends Fault {
  const FinThenRst(this.after, {this.gap = const Duration(milliseconds: 50)});
  final int after;
  final Duration gap;
}

/// After [after] body bytes, an explicit RST.
class Reset extends Fault {
  const Reset(this.after);
  final int after;
}

/// After [after] body bytes, 413 and FIN, then reads and ignores for [linger]:
/// nginx over `client_max_body_size`, with `lingering_close`.
class TooLargeThenLinger extends Fault {
  const TooLargeThenLinger(this.after, this.linger);
  final int after;
  final Duration linger;
}

/// After [after] body bytes, closes once no data came for [limit]: nginx's
/// `client_body_timeout`.
class BodyTimeout extends Fault {
  const BodyTimeout(this.after, this.limit);
  final int after;
  final Duration limit;
}

/// After [after] body bytes, stops reading and waits for the client to leave.
class StopReading extends Fault {
  const StopReading(this.after);
  final int after;
}

/// Reads the whole body, then says nothing until the client leaves.
class NoAnswer extends Fault {
  const NoAnswer();
}

/// Makes the post, then cuts the connection before the answer.
class LoseStatusAnswer extends Fault {
  const LoseStatusAnswer();
}

/// Decides what happens to media POST number [media] (from 1), or to a status
/// POST when [media] is null.
typedef FaultPlan = Fault Function(int? media, int status);

class FakeMastodon {
  FakeMastodon._(this._plan, this.imageLimit);

  static Future<FakeMastodon> start(FaultPlan plan, {int? imageLimit, SecurityContext? tls}) async {
    final s = FakeMastodon._(plan, imageLimit);
    final Stream<Socket> incoming;
    if (tls == null) {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      s._close = server.close;
      s.port = server.port;
      incoming = server;
    } else {
      final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, tls);
      s._close = server.close;
      s.port = server.port;
      incoming = server;
    }
    incoming.listen(s._serve, onError: (Object _) {});
    return s;
  }

  final FaultPlan _plan;
  final int? imageLimit;
  late final Future<void> Function() _close;
  late final int port;

  var mediaPosts = 0;
  var statusPosts = 0;
  final statusKeys = <String?>[];

  /// Posts that exist on the server. The key is honoured as Mastodon does: a
  /// second POST with a known key returns the first post.
  final _posts = <String, String>{};
  int get createdPosts => _posts.length;

  /// Cuts everything the server still holds open.
  final _open = <Socket>{};
  Future<void> close() async {
    await _close();
    for (final s in _open) {
      s.destroy();
    }
  }

  void _serve(Socket socket) {
    _open.add(socket);
    unawaited(socket.done.catchError((Object _) => socket).whenComplete(() => _open.remove(socket)));
    _Connection(this, socket).start();
  }

  String _createPost(String? key) {
    final k = key ?? 'no-key-${_posts.length}';
    return _posts.putIfAbsent(k, () => '${_posts.length + 1}');
  }
}

/// Turns on SO_LINGER with a zero timeout, so that closing sends RST.
void abortive(Socket s) {
  try {
    s.setRawOption(RawSocketOption(RawSocketOption.levelSocket, 0x0080, Uint8List.fromList(const [1, 0, 0, 0])));
  } on Object {
    // A TLS socket may refuse: it then closes the ordinary way.
  }
}

class _Connection {
  _Connection(this.server, this.socket);
  final FakeMastodon server;
  final Socket socket;

  late final StreamSubscription<Uint8List> _sub;
  final _head = BytesBuilder();
  Timer? _idle;

  // The request being read.
  String? _line;
  String? _key;
  int _length = 0;
  int _read = 0;
  Fault? _fault;
  var _finished = false;

  void start() {
    _sub = socket.listen(_onData, onError: (Object _) => _end(), onDone: _end, cancelOnError: true);
  }

  void _end() {
    _idle?.cancel();
    socket.destroy();
  }

  void _onData(Uint8List data) {
    if (_finished) return;
    if (_line == null) {
      _head.add(data);
      final all = _head.toBytes();
      final at = _headerEnd(all);
      if (at < 0) return;
      _begin(latin1.decode(Uint8List.sublistView(all, 0, at)));
      _read = all.length - at - 4;
      _head.clear();
    } else {
      _read += data.length;
    }
    _advance();
  }

  static int _headerEnd(Uint8List b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
    }
    return -1;
  }

  void _begin(String head) {
    final lines = head.split('\r\n');
    _line = lines.first;
    _length = 0;
    _key = null;
    for (final h in lines.skip(1)) {
      final c = h.indexOf(':');
      if (c < 0) continue;
      final name = h.substring(0, c).toLowerCase();
      final value = h.substring(c + 1).trim();
      if (name == 'content-length') _length = int.parse(value);
      if (name == 'idempotency-key') _key = value;
    }
    if (_line!.contains('/media')) {
      server.mediaPosts++;
      _fault = server._plan(server.mediaPosts, server.statusPosts);
    } else if (_line!.contains('/statuses')) {
      server.statusPosts++;
      server.statusKeys.add(_key);
      _fault = server._plan(null, server.statusPosts);
    } else {
      _fault = const Serve();
    }
  }

  void _advance() {
    final f = _fault;
    switch (f) {
      case CloseClean(:final after) when _read >= after:
        _finished = true;
        socket.destroy();
      case FinThenRst(:final after, :final gap) when _read >= after:
        _finished = true;
        unawaited(socket.close().catchError((Object _) => socket));
        Timer(gap, () {
          abortive(socket);
          socket.destroy();
        });
      case Reset(:final after) when _read >= after:
        _finished = true;
        abortive(socket);
        socket.destroy();
      case TooLargeThenLinger(:final after, :final linger) when _read >= after:
        _finished = true;
        unawaited(_answer(413, const {'error': 'file too large'}, keepAlive: false, then: () => Timer(linger, socket.destroy)));
      case BodyTimeout(:final after, :final limit) when _read >= after:
        _idle?.cancel();
        _idle = Timer(limit, () {
          _finished = true;
          socket.destroy();
        });
      case StopReading(:final after) when _read >= after:
        _sub.pause();
      case Serve(:final keepAlive) when _read >= _length:
        _respond(keepAlive);
      case NoAnswer() when _read >= _length:
        _finished = true;
      case LoseStatusAnswer() when _read >= _length:
        _finished = true;
        server._createPost(_key);
        socket.destroy();
      default:
        break;
    }
  }

  void _respond(bool keepAlive) {
    final line = _line!;
    final Object body;
    if (line.contains('/statuses')) {
      final id = server._createPost(_key);
      body = {'id': id, 'url': 'https://fake.invalid/$id'};
    } else if (line.contains('/media')) {
      body = {'id': 'm${server.mediaPosts}', 'url': 'https://fake.invalid/m${server.mediaPosts}'};
    } else if (line.contains('/instance')) {
      body = {
        'configuration': {
          'media_attachments': {if (server.imageLimit != null) 'image_size_limit': server.imageLimit},
        },
      };
    } else {
      unawaited(_answer(404, const {'error': 'not found'}, keepAlive: keepAlive));
      return;
    }
    unawaited(_answer(200, body, keepAlive: keepAlive));
  }

  Future<void> _answer(int status, Object body, {required bool keepAlive, void Function()? then}) async {
    final b = utf8.encode(jsonEncode(body));
    try {
      socket.add(utf8.encode(
          'HTTP/1.1 $status X\r\nContent-Type: application/json\r\nContent-Length: ${b.length}\r\nConnection: ${keepAlive ? 'keep-alive' : 'close'}\r\n\r\n'));
      socket.add(b);
      await socket.flush();
      if (keepAlive) {
        _line = null;
        _read = 0;
        _fault = null;
        return;
      }
      await socket.close();
      if (status == 200) _finished = true;
      then?.call();
    } on Object {
      _end();
    }
  }
}
