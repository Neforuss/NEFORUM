import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

/// A client that reads each request's body with [receive], the way a socket
/// takes it: slowly, all at once, or not at all.
class _ReadingClient extends http.BaseClient {
  _ReadingClient(this.receive);

  final Future<http.StreamedResponse> Function(http.BaseRequest request, Stream<List<int>> body) receive;
  final aborted = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(abortTrigger.then((_) => aborted.add(request.url)));
    }
    return receive(request, request.finalize());
  }
}

http.StreamedResponse _ok(List<int> echo) => http.StreamedResponse(Stream.value(echo), 200);

void main() {
  final url = Uri.parse('https://upload.example.test/media');
  // 1 MiB: over the 64 KiB from which bodies are watched, 64 pieces.
  final file = Uint8List.fromList(List.generate(1024 * 1024, (i) => i % 251));

  test('a slow upload that keeps moving finishes, however long it takes in all', () async {
    final received = <int>[];
    final client = _ReadingClient((request, body) async {
      await for (final piece in body) {
        received.addAll(piece);
        // 64 pieces x 10 ms: four times the stall limit in all.
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return _ok(const [123]);
    });
    final net = NeforumHttp(client: client, uploadStallTimeout: const Duration(milliseconds: 160));
    final res = await net.putBytes(url, file);
    expect(res.statusCode, 200);
    expect(received, file, reason: 'every byte, in order');
    expect(client.aborted, isEmpty);
  });

  test('pieces are taken one at a time, as the connection asks for them', () async {
    var largest = 0;
    var pieces = 0;
    final client = _ReadingClient((request, body) async {
      await for (final piece in body) {
        pieces++;
        if (piece.length > largest) largest = piece.length;
      }
      return _ok(const []);
    });
    await NeforumHttp(client: client).multipart(url, files: [
      HttpFilePart(field: 'file', bytes: file, fileName: 'track.mp3', contentType: 'audio/mpeg'),
    ]);
    expect(largest, lessThanOrEqualTo(16 * 1024));
    expect(pieces, greaterThanOrEqualTo(64));
  });

  test('an upload that stops moving fails after the stall limit and is aborted', () async {
    final client = _ReadingClient((request, body) {
      final hold = Completer<http.StreamedResponse>();
      // Takes one piece, then never asks for more.
      late StreamSubscription<List<int>> sub;
      sub = body.listen((_) => sub.pause());
      return hold.future;
    });
    // One attempt: a PUT this size would otherwise be tried again twice.
    final net = NeforumHttp(client: client, maxRetries: 0, uploadStallTimeout: const Duration(milliseconds: 150));
    final watch = Stopwatch()..start();
    await expectLater(net.putBytes(url, file), throwsA(isA<TimeoutException>()));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    await Future<void>.delayed(Duration.zero);
    expect(client.aborted, [url]);
  });

  test('no answer after the whole file went out fails after twice the base timeout', () async {
    final client = _ReadingClient((request, body) async {
      await body.drain<void>();
      return Completer<http.StreamedResponse>().future;
    });
    final net = NeforumHttp(client: client, timeout: const Duration(milliseconds: 100), uploadStallTimeout: const Duration(seconds: 30));
    final watch = Stopwatch()..start();
    await expectLater(
        net.putBytes(url, file), throwsA(isA<TimeoutException>().having((e) => e.message, 'message', contains('did not answer'))));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('small bodies keep the plain request and its timeout', () async {
    http.BaseRequest? seen;
    final client = _ReadingClient((request, body) async {
      seen = request;
      await body.drain<void>();
      return _ok(const []);
    });
    await NeforumHttp(client: client).putBytes(url, Uint8List(1000));
    expect(seen, isA<http.AbortableRequest>());
  });

  test('the numbers: 64 KiB is the line, 60 s the stall limit', () async {
    expect(NeforumHttp.watchedBodyThreshold, 64 * 1024);
    expect(NeforumHttp().uploadStallTimeout, const Duration(seconds: 60));
    final seen = <http.BaseRequest>[];
    final client = _ReadingClient((request, body) async {
      seen.add(request);
      await body.drain<void>();
      return _ok(const []);
    });
    final net = NeforumHttp(client: client);
    await net.putBytes(url, Uint8List(64 * 1024));
    await net.putBytes(url, Uint8List(64 * 1024 + 1));
    expect(seen.first, isA<http.AbortableRequest>(), reason: 'exactly at the line: plain');
    expect(seen.last, isNot(isA<http.AbortableRequest>()), reason: 'one byte over: watched');
  });

  test('a JSON body over the line is watched and counted, and keeps its type and bytes', () async {
    final body = {'data': 'x' * (128 * 1024)};
    final got = <int>[];
    var pieces = 0;
    http.BaseRequest? seen;
    final client = _ReadingClient((request, stream) async {
      seen = request;
      await for (final piece in stream) {
        pieces++;
        got.addAll(piece);
      }
      return _ok(const []);
    });
    await NeforumHttp(client: client).postJson(url, body);
    expect(seen, isNot(isA<http.AbortableRequest>()));
    expect(pieces, greaterThanOrEqualTo(8));
    expect(jsonDecode(utf8.decode(got)), body);
    expect(seen!.headers['content-type'], 'application/json; charset=utf-8');
    expect(seen!.contentLength, got.length);
  });

  test('a small JSON body and a form are sent as before', () async {
    final seen = <http.Request>[];
    final net = NeforumHttp(client: MockClient((r) async {
      seen.add(r);
      return http.Response('', 200);
    }));
    await net.postJson(url, {'a': 1});
    await net.postJson(url, {'a': 1}, headers: {'Content-Type': 'application/json'});
    await net.postJson(url, {'a': 1}, headers: {'Content-Type': 'application/vnd.api+json; charset=utf-8'});
    await net.postForm(url, {'a': 'b c'});
    expect(seen[0].headers['content-type'], 'application/json; charset=utf-8');
    expect(seen[1].headers['content-type'], 'application/json; charset=utf-8');
    expect(seen[2].headers['content-type'], 'application/vnd.api+json; charset=utf-8');
    expect(seen[0].body, '{"a":1}');
    expect(seen[3].headers['content-type'], 'application/x-www-form-urlencoded');
    expect(seen[3].body, 'a=b+c');
  });

  test('a form over the line is watched too', () async {
    http.BaseRequest? seen;
    final client = _ReadingClient((request, body) async {
      seen = request;
      await body.drain<void>();
      return _ok(const []);
    });
    await NeforumHttp(client: client).postForm(url, {'a': 'x' * (70 * 1024)});
    expect(seen, isNot(isA<http.AbortableRequest>()));
    expect(seen!.headers['content-type'], 'application/x-www-form-urlencoded');
  });

  test('a timeout on an answer aborts the watched request', () async {
    final client = _ReadingClient((request, body) async {
      await body.drain<void>();
      return Completer<http.StreamedResponse>().future;
    });
    final net = NeforumHttp(client: client, maxRetries: 0, timeout: const Duration(milliseconds: 50));
    await expectLater(net.putBytes(url, Uint8List(70 * 1024)), throwsA(isA<TimeoutException>()));
    await Future<void>.delayed(Duration.zero);
    expect(client.aborted, [url]);
  });
}
