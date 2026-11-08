/// The same client through Shopify's Toxiproxy, a fault source that is not ours:
/// a check that the local proxy is not flattering the fix. Each toxic runs twice:
/// left on (every try fails, nothing is posted) and taken off after the first
/// failed try (the upload is sent again, and exactly one post results).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'fake_mastodon.dart';
import 'paced_proxy.dart';
import 'run_matrix.dart';

const _api = 'http://127.0.0.1:8474';
const _mb = 1024 * 1024;

/// A toxic as Toxiproxy's API takes it.
class Toxic {
  const Toxic(this.type, this.stream, this.attributes);
  final String type;
  final String stream;
  final Map<String, int> attributes;
  Map<String, Object> get json => {'name': type, 'type': type, 'stream': stream, 'toxicity': 1.0, 'attributes': attributes};
}

const _bandwidth = Toxic('bandwidth', 'upstream', {'rate': 2000}); // KB/s
const _limitData = Toxic('limit_data', 'upstream', {'bytes': 256 * 1024});
const _resetPeer = Toxic('reset_peer', 'upstream', {'timeout': 400});
const _slowClose = Toxic('slow_close', 'downstream', {'delay': 1000});

class _Case {
  const _Case(this.name, this.toxics, {this.fault, this.slow = false, this.pacedInFront = false});
  final String name;

  /// Toxics that come off in the "once" run.
  final List<Toxic> toxics;

  /// Adds the bandwidth toxic for the whole run.
  final bool slow;

  /// The client talks to [PacedProxy], which talks to Toxiproxy. The only way
  /// here to have a sender slower than Toxiproxy reads, see the README.
  final bool pacedInFront;

  /// What the fake server does to the upload, on top of the toxics.
  final Fault? fault;
}

const _cases = [
  _Case('bandwidth', [], slow: true),
  // Toxiproxy alone, at the client's full speed.
  _Case('limit_data', [_limitData]),
  _Case('reset_peer', [_resetPeer]),
  _Case('slow_close+server_close', [_slowClose], fault: CloseClean(128 * 1024)),
  _Case('server_close', [], fault: CloseClean(128 * 1024)),
  _Case('server_fin_then_rst', [], fault: FinThenRst(128 * 1024)),
  _Case('server_413_linger', [], fault: TooLargeThenLinger(128 * 1024, Duration(milliseconds: 200))),
  // Through the bandwidth toxic: the client is ahead of Toxiproxy's reader.
  _Case('bandwidth+limit_data', [_limitData], slow: true),
  _Case('bandwidth+reset_peer', [_resetPeer], slow: true),
  _Case('bandwidth+slow_close+server_close', [_slowClose], slow: true, fault: CloseClean(128 * 1024)),
  _Case('bandwidth+server_close', [], slow: true, fault: CloseClean(128 * 1024)),
  _Case('bandwidth+server_413_linger', [], slow: true, fault: TooLargeThenLinger(128 * 1024, Duration(milliseconds: 200))),
  // A sender slower than Toxiproxy reads, which is what a slow uplink is.
  _Case('paced+limit_data', [_limitData], pacedInFront: true),
  _Case('paced+reset_peer', [_resetPeer], pacedInFront: true),
  _Case('paced+slow_close+server_close', [_slowClose], pacedInFront: true, fault: CloseClean(128 * 1024)),
  _Case('paced+server_close', [], pacedInFront: true, fault: CloseClean(128 * 1024)),
];

class ToxiproxyLane {
  ToxiproxyLane._(this._process, this._http);

  static Future<ToxiproxyLane> start(String path) async {
    final process = await Process.start(path, ['-host', '127.0.0.1', '-port', '8474']);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final lane = ToxiproxyLane._(process, HttpClient());
    for (var i = 0; i < 50; i++) {
      try {
        lane.version = await lane._request('GET', '/version');
        return lane;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    process.kill();
    throw StateError('toxiproxy did not start');
  }

  final Process _process;
  final HttpClient _http;
  String version = '';

  Future<void> stop() async {
    _http.close(force: true);
    _process.kill();
    await _process.exitCode;
  }

  Future<String> _request(String method, String path, [Object? body]) async {
    final r = await _http.openUrl(method, Uri.parse('$_api$path'));
    r.headers.set('User-Agent', 'neforum-fault-matrix');
    if (body != null) r.write(jsonEncode(body));
    final res = await r.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 300) throw StateError('$method $path: ${res.statusCode} $text');
    return text;
  }

  Future<void> _addToxic(Toxic t) => _request('POST', '/proxies/matrix/toxics', t.json);
  Future<void> _removeToxic(Toxic t) => _request('DELETE', '/proxies/matrix/toxics/${t.type}');

  /// A proxy to [target]; returns its port.
  Future<int> _proxy(int target) async {
    try {
      await _request('DELETE', '/proxies/matrix');
    } on StateError {
      // There was none.
    }
    final j = jsonDecode(await _request('POST', '/proxies', {'name': 'matrix', 'listen': '127.0.0.1:0', 'upstream': '127.0.0.1:$target', 'enabled': true}));
    return int.parse(((j as Map)['listen'] as String).split(':').last);
  }

  Future<Row> _one(_Case c, {required bool once}) async {
    final fault = c.fault;
    final plan = fault == null
        ? (int? m, int s) => const Serve() as Fault
        : (int? m, int s) => m != null && (!once || m == 1) ? fault : const Serve();
    final server = await FakeMastodon.start(plan);
    final toxiproxyPort = await _proxy(server.port);
    final paced = c.pacedInFront ? await PacedProxy.start(toxiproxyPort, rate: 2 * 1000 * 1000) : null;
    final port = paced?.port ?? toxiproxyPort;
    if (c.slow) await _addToxic(_bandwidth);
    for (final t in c.toxics) {
      await _addToxic(t);
    }
    // Taken off as soon as the first try has failed: the retry waits 500 ms.
    var cleared = false;
    void clear() {
      if (!once || cleared) return;
      cleared = true;
      for (final t in c.toxics) {
        unawaited(_removeToxic(t));
      }
    }

    final client = Client(Uri.parse('http://127.0.0.1:$port'),
        fileBytes: 8 * _mb, media: 1, stall: const Duration(seconds: 30), answerBase: const Duration(seconds: 30), onFailure: clear);
    final clock = Stopwatch()..start();
    final result = await client.publish();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final fails = c.toxics.isNotEmpty || fault != null;
    final Expected want;
    if (!fails) {
      want = const Expected.success(mediaPosts: 1);
    } else if (once) {
      want = const Expected.success(mediaPosts: null);
    } else {
      want = const Expected.failure(null, mediaPosts: null);
    }
    final wrong = judge(result, want, server);
    if (fails && client.failures.isEmpty) wrong.add('no failed try: the fault did not bite');
    if (fails && !once && client.failures.where((f) => f.contains('/api') || !f.contains('instance')).length < 3) wrong.add('fewer than 3 tries: ${client.failures}');
    await paced?.close();
    final row = Row('toxiproxy ${c.name} ${!fails ? '' : once ? 'once' : 'always'}'.trim(), 'plain', result, server, client.failures, wrong, clock.elapsed);
    await server.close();
    return row;
  }

  Future<List<Row>> run({int repeat = 1, Set<String>? only}) async {
    final rows = <Row>[];
    for (final c in _cases) {
      if (only != null && !only.contains(c.name)) continue;
      final fails = c.toxics.isNotEmpty || c.fault != null;
      for (var i = 0; i < repeat; i++) {
        rows.add(await _one(c, once: false));
        if (fails) rows.add(await _one(c, once: true));
      }
    }
    return rows;
  }
}
