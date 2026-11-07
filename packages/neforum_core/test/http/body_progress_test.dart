// What NeforumHttp says about a request's body.

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/http/transient_io.dart' as io;
import 'package:neforum_core/src/http/transient_stub.dart' as web;
import 'package:test/test.dart';

/// Reads what the connection would read, then answers.
class _ReadingClient extends http.BaseClient {
  _ReadingClient({this.failFirst = 0, this.status = 200});

  int failFirst;
  final int status;
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    final body = request.finalize();
    if (failFirst > 0) {
      failFirst--;
      var seen = 0;
      await for (final piece in body) {
        seen += piece.length;
        if (seen > 32 * 1024) throw http.ClientException('Write failed');
      }
      throw http.ClientException('Write failed');
    }
    await body.drain<void>();
    return http.StreamedResponse(Stream.value(<int>[]), status);
  }
}

void main() {
  final seen = <BodyProgress>[];
  setUp(seen.clear);
  NeforumHttp net(http.Client c) => NeforumHttp(client: c, log: Logger('t', sink: (l, a, m, [e]) {})).bound(observer: seen.add);
  final url = Uri.parse('https://example.test/up');

  test('a watched body reports each piece, then the answer', () async {
    await net(_ReadingClient()).putBytes(url, Uint8List(100 * 1024));
    expect(seen.first.sent, 16 * 1024);
    expect(seen.first.total, 100 * 1024);
    expect(seen.first.answered, isFalse);
    final sends = [for (final p in seen) if (!p.answered) p.sent];
    expect(sends, orderedEquals([...sends]..sort()));
    expect(sends.last, 100 * 1024);
    expect(seen.last.answered, isTrue);
    expect(seen.last.status, 200);
    expect(seen.last.confirmed, isTrue);
  });

  test('a small file reports once, when the answer arrives', () async {
    await net(MockClient((_) async => http.Response('', 200))).putBytes(url, Uint8List(1000));
    expect(seen, hasLength(1));
    expect((seen.single.sent, seen.single.total, seen.single.answered), (1000, 1000, true));
  });

  test('small JSON and form calls are not uploads and say nothing', () async {
    final n = net(MockClient((_) async => http.Response('{}', 200)));
    await n.postJson(url, {'text': 'hello'});
    await n.postForm(url, {'text': 'hello'});
    await n.get(url);
    await n.putBytes(url, Uint8List(0));
    expect(seen, isEmpty);
  });

  test('a JSON body with an image inside is watched and counted', () async {
    await net(_ReadingClient()).postJson(url, {'data': 'x' * (100 * 1024)});
    expect(seen.where((p) => !p.answered), isNotEmpty);
    expect(seen.last.total, greaterThan(100 * 1024));
  });

  test('a multipart body counts its boundaries too', () async {
    await net(_ReadingClient()).multipart(url, fields: {'a': 'b'}, files: [HttpFilePart(field: 'f', bytes: Uint8List(100 * 1024), fileName: 'f', contentType: 'image/png')]);
    expect(seen.last.total, greaterThan(100 * 1024));
    expect(seen.lastWhere((p) => !p.answered).sent, seen.last.total);
  });

  test('a chunk says where it sits in the file', () async {
    await net(_ReadingClient()).putBytes(url, Uint8List(70 * 1024), bodyOffset: 4096, bodyWhole: 1 << 20);
    expect(seen.first.offset, 4096);
    expect(seen.first.whole, 1 << 20);
  });

  test('a retry restarts the count and says which attempt it is', () async {
    await net(_ReadingClient(failFirst: 1)).putBytes(url, Uint8List(100 * 1024), retrySafe: true);
    expect(seen.map((p) => p.attempt).toSet(), {1, 2});
    final second = seen.firstWhere((p) => p.attempt == 2);
    expect(second.sent, 16 * 1024);
  });

  test('an error answer is an answer, and confirms nothing', () async {
    await net(_ReadingClient(status: 413)).putBytes(url, Uint8List(100 * 1024), throwOnError: false);
    expect(seen.last.answered, isTrue);
    expect(seen.last.confirmed, isFalse);
  });

  test('a browser collects the body first, so only there do its pieces count for nothing', () {
    expect(io.bodyPiecesAreCounted, isTrue);
    expect(web.bodyPiecesAreCounted, isFalse);
  });

  test('bound keeps what it is not given', () {
    final signal = CancellationSignal();
    final base = NeforumHttp(client: MockClient((_) async => http.Response('', 200)));
    final a = base.withCancellation(signal);
    void watcher(BodyProgress _) {}
    final b = a.bound(observer: watcher);
    expect(b.cancellation, same(signal));
    expect(b.observer, same(watcher));
    expect(b.bound(), same(b));
    expect(b.withCancellation(CancellationSignal()).observer, same(watcher));
  });

  group('neverReachedServer', () {
    test('a watched body that never went out whole', () async {
      Object? error;
      try {
        await NeforumHttp(client: _ReadingClient(failFirst: 1), maxRetries: 0, log: Logger('t', sink: (l, a, m, [e]) {})).send('POST', url, bytes: Uint8List(100 * 1024));
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<UploadInterrupted>());
      expect(NeforumHttp.neverReachedServer(error!), isTrue);
    });

    test('a lost answer may have reached it', () {
      expect(NeforumHttp.neverReachedServer(http.ClientException('Connection closed')), isFalse);
      expect(NeforumHttp.neverReachedServer(TimeoutException('late')), isFalse);
    });
  });
}
