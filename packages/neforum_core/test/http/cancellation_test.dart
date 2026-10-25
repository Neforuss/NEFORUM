import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

/// A client that holds every request until it is aborted, the way a slow
/// upload behaves.
class _HangingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final aborted = <Uri>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (request case http.Abortable(:final abortTrigger?)) {
      await abortTrigger;
      aborted.add(request.url);
      throw http.RequestAbortedException(request.url);
    }
    return Completer<http.StreamedResponse>().future;
  }

  @override
  void close() => closed = true;
}

void main() {
  final url = Uri.parse('https://api.example.test/upload');

  test('cancelling aborts the request in flight', () async {
    final client = _HangingClient();
    final signal = CancellationSignal();
    final net = NeforumHttp(client: client).withCancellation(signal);
    final sent = net.postJson(url, {'a': 1});
    await Future<void>.delayed(Duration.zero);
    expect(client.requests.single, isA<http.Abortable>());
    signal.cancel();
    await expectLater(sent, throwsA(isA<OperationCancelledException>()));
    expect(client.aborted, [url]);
  });

  test('multipart uploads can be aborted too', () async {
    final client = _HangingClient();
    final signal = CancellationSignal();
    final sent = NeforumHttp(client: client).withCancellation(signal).multipart(url, fields: {'a': 'b'});
    await Future<void>.delayed(Duration.zero);
    expect(client.requests.single, isA<http.AbortableMultipartRequest>());
    signal.cancel();
    await expectLater(sent, throwsA(isA<OperationCancelledException>()));
  });

  test('a cancelled signal stops requests before they are sent', () async {
    var calls = 0;
    final signal = CancellationSignal()..cancel();
    final net = NeforumHttp(client: MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    })).withCancellation(signal);
    await expectLater(net.get(url), throwsA(isA<OperationCancelledException>()));
    expect(calls, 0);
  });

  test('a retry pause ends at once when cancelled, and nothing is sent again', () async {
    var calls = 0;
    final signal = CancellationSignal();
    final net = NeforumHttp(
      client: MockClient((_) async {
        calls++;
        return http.Response('busy', 503, headers: {'retry-after': '20'});
      }),
    ).withCancellation(signal);
    final watch = Stopwatch()..start();
    final sent = net.get(url);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    signal.cancel();
    await expectLater(sent, throwsA(isA<OperationCancelledException>()));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(calls, 1);
  });

  test('a client that ignores the abort still stops waiting', () async {
    final signal = CancellationSignal();
    final never = Completer<http.Response>();
    final net = NeforumHttp(client: MockClient((_) => never.future)).withCancellation(signal);
    final sent = net.get(url);
    await Future<void>.delayed(Duration.zero);
    signal.cancel();
    await expectLater(sent, throwsA(isA<OperationCancelledException>()));
  });

  test('a bound copy shares the client and never closes it', () async {
    final client = _HangingClient();
    final base = NeforumHttp(client: client);
    final signal = CancellationSignal();
    final bound = base.withCancellation(signal);
    expect(bound.cancellation, same(signal));
    expect(base.cancellation, isNull);
    expect(base.withCancellation(null), same(base));
    expect(bound.withCancellation(signal), same(bound));
    bound.close();
    expect(client.closed, isFalse);
    base.close();
    expect(client.closed, isTrue);
  });

  test('adapter contexts carry the signal into their HTTP client', () {
    final signal = CancellationSignal();
    final ctx = AdapterContext(http: NeforumHttp(client: _HangingClient()), cancellation: signal);
    expect(ctx.http.cancellation, same(signal));
    expect(ctx.copyWith(log: Logger('other')).cancellation, same(signal));
    expect(ctx.isCancelled, isFalse);
    signal.cancel();
    expect(ctx.isCancelled, isTrue);
    expect(ctx.throwIfCancelled, throwsA(isA<OperationCancelledException>()));
  });
}
