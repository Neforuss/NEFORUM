/// A client that takes each request's body the way a socket does and can cut
/// the connection part way through, as Windows reports it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// What package:http throws on Windows: a ClientException that is also a
/// SocketException, with the text users reported.
class FakeWriteFailed extends http.ClientException implements SocketException {
  FakeWriteFailed(Uri uri) : super('Write failed', uri);
  @override
  InternetAddress? get address => null;
  @override
  OSError? get osError => const OSError('An established connection was aborted by the software in your host machine', 10053);
  @override
  int? get port => 51122;
  @override
  String toString() =>
      'ClientException with SocketException: Write failed (OS Error: ${osError!.message}, errno = 10053), address = host, port = 51122, uri=$uri';
}

/// The answer to request number `n`. Null cuts the request after its first
/// piece.
typedef FaultAnswer = FutureOr<http.StreamedResponse?> Function(int n, http.BaseRequest request);

class FaultClient extends http.BaseClient {
  FaultClient(this.answer);

  final FaultAnswer answer;
  final trail = <String>[];
  final bodies = <String>[];
  final aborted = <Uri>[];
  var n = 0;

  int count(bool Function(String line) test) => trail.where(test).length;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    if (r case http.Abortable(:final abortTrigger?)) unawaited(abortTrigger.then((_) => aborted.add(r.url)));
    final i = n++;
    trail.add('${r.method} ${r.url.path}');
    final a = await answer(i, r);
    final body = BytesBuilder(copy: false);
    await for (final piece in r.finalize()) {
      body.add(piece);
      if (a == null) throw FakeWriteFailed(r.url);
    }
    bodies.add(utf8.decode(body.takeBytes(), allowMalformed: true));
    return a!;
  }
}

http.StreamedResponse jsonAnswer(Object o, [int status = 200]) => http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(o))),
      status,
      headers: {'content-type': 'application/json'},
    );

/// Words that must never reach a person, wherever a connection problem shows.
const transportJargon = ['errno', 'ClientException', 'SocketException', 'OS Error', 'Write failed', 'host machine', 'TimeoutException'];
