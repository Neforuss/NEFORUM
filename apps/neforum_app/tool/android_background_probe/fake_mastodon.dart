// A Mastodon server on this computer, for the Android background posting probe
// (integration_test/android_background_probe.dart and run_probe.sh here). It logs
// every step with its time, and the log is what the CI job asserts from: only a post
// that really reached the server counts.
//
//   dart run tool/android_background_probe/fake_mastodon.dart --port 8787 --log server.log --hold 120
//
// The file stays "processing" for --hold seconds after its upload, which is the real
// 206 answer a video gets. The run lasts that long, and is what Home and the swipe
// happen during. POST /__mark?name=x writes a line from the script into the same log,
// so the order of events is one file's order.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The server. [log] hears one line per step.
class FakeMastodon {
  FakeMastodon({required this.hold, required this.log});

  final Duration hold;
  final void Function(String line) log;
  HttpServer? _server;
  DateTime? _uploadedAt;
  var _statuses = 0;

  int get port => _server!.port;

  Future<void> start({int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    unawaited(server.forEach(_answer));
  }

  Future<void> stop() async => _server?.close(force: true);

  Future<void> _answer(HttpRequest r) async {
    // The body goes first: a server that answers early cuts off the upload.
    final length = await r.fold<int>(0, (sum, piece) => sum + piece.length);
    final path = r.uri.path;
    if (path == '/__mark') {
      log('mark ${r.uri.queryParameters['name']}');
      return _json(r, 200, const {});
    }
    if (r.method == 'POST' && path == '/api/v2/media') {
      _uploadedAt = DateTime.now();
      log('media-created bytes=$length');
      return _json(r, 202, const {'id': 'm1', 'type': 'image', 'url': null});
    }
    if (r.method == 'GET' && path == '/api/v1/media/m1') {
      final at = _uploadedAt;
      if (at == null || DateTime.now().difference(at) < hold) {
        log('media-poll');
        return _json(r, 206, const {'id': 'm1', 'type': 'image', 'url': null});
      }
      log('media-ready');
      return _json(r, 200, const {'id': 'm1', 'type': 'image', 'url': 'https://files.invalid/m1.png'});
    }
    if (r.method == 'POST' && path == '/api/v1/statuses') {
      _statuses++;
      log('status-created n=$_statuses');
      return _json(r, 200, {'id': 's$_statuses', 'url': 'https://social.invalid/@probe/$_statuses', 'uri': 'https://social.invalid/statuses/$_statuses'});
    }
    log('unexpected ${r.method} $path');
    return _json(r, 404, const {'error': 'Not found'});
  }

  Future<void> _json(HttpRequest r, int status, Map<String, Object?> body) async {
    r.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await r.response.close();
  }
}

Future<void> main(List<String> args) async {
  String option(String name, String fallback) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  final sink = File(option('log', 'server.log')).openSync(mode: FileMode.writeOnlyAppend);
  final server = FakeMastodon(
    hold: Duration(seconds: int.parse(option('hold', '120'))),
    log: (line) {
      final text = '${DateTime.now().toUtc().toIso8601String()} $line';
      sink
        ..writeStringSync('$text\n')
        ..flushSync();
      stdout.writeln(text);
    },
  );
  await server.start(port: int.parse(option('port', '8787')));
  stdout.writeln('listening on ${server.port}');
}
