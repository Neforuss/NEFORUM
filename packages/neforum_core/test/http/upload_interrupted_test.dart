// The fix for "Write failed", errno 10053 on a Mastodon upload. Uses only API
// that exists before the fix, so that this file can be run against 9f62fea: 6
// of its 7 tests fail there, all but the one marked GUARD.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_adapter.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_api.dart';
import 'package:test/test.dart';

/// What package:http throws on Windows: a ClientException that is also a
/// SocketException, with the text the user reported.
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

typedef Answer = http.StreamedResponse? Function(int n, http.BaseRequest r);

/// Takes the body like a socket. A null answer cuts the request after the first piece.
class Scripted extends http.BaseClient {
  Scripted(this.answer);
  final Answer answer;
  final trail = <String>[];
  final bodies = <String>[];
  final aborted = <Uri>[];
  var n = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    if (r case http.Abortable(:final abortTrigger?)) unawaited(abortTrigger.then((_) => aborted.add(r.url)));
    final i = n++;
    trail.add('${r.method} ${r.url.path}');
    final a = answer(i, r);
    final body = BytesBuilder(copy: false);
    await for (final piece in r.finalize()) {
      body.add(piece);
      if (a == null) throw FakeWriteFailed(r.url);
    }
    bodies.add(utf8.decode(body.takeBytes(), allowMalformed: true));
    return a!;
  }
}

http.StreamedResponse json(Object o, [int status = 200]) => http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(o))),
      status,
      headers: {'content-type': 'application/json'},
    );

MediaAttachment image(String id) =>
    MediaAttachment(id: id, path: '$id.jpg', mimeType: 'image/jpeg', sizeBytes: 64, width: 10, height: 10, altText: 'alt', fileName: '$id.jpg');

final account = ConnectedAccount(
  id: 'a',
  platformId: 'mastodon',
  tier: PlatformTier.openApi,
  displayName: 't',
  createdAt: DateTime.utc(2026, 11, 6),
  config: const {'instance': 'https://mastodon.example', 'domain': 'mastodon.example', 'software': 'mastodon', 'maxCharacters': 500, 'maxMediaAttachments': 4},
);
const secrets = {'client_id': 'c', 'client_secret': 's', 'access_token': 't', 'token_type': 'Bearer'};

AdapterContext ctx(http.Client c, Uint8List bytes, {Duration? timeout}) => AdapterContext(
      http: NeforumHttp(client: c, timeout: timeout ?? const Duration(seconds: 60)),
      log: Logger('t', sink: (l, a, m, [e]) {}),
      readMedia: (m) async => bytes,
    );

void main() {
  final big = Uint8List(1024 * 1024);
  final host = Uri.parse('https://mastodon.example');

  test('a media upload cut off mid-body is sent again on its own', () async {
    final c = Scripted((i, r) => i == 0 ? null : json({'id': 'm1', 'url': 'u'}));
    final id = await MastodonApi(ctx(c, big), host, accessToken: 't').uploadMedia(image('i'), big);
    expect(id, 'm1');
    expect(c.trail, ['POST /api/v2/media', 'POST /api/v2/media']);
  });

  test('GUARD: a post without an Idempotency-Key is never re-sent after a dropped connection', () async {
    final c = Scripted((i, r) => null);
    await expectLater(ctx(c, big).http.postForm(Uri.parse('https://mastodon.example/api/v1/statuses'), {'status': 'x'}), throwsA(isA<http.ClientException>()));
    expect(c.n, 1);
  });

  test('a cut-off upload is explained in plain words, with the details kept for reports', () async {
    final c = Scripted((i, r) => null);
    final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [image('i')]), account, secrets, ctx(c, big));
    final e = r.error!;
    expect(e.kind, PublishErrorKind.network);
    expect(e.retryable, isTrue);
    expect(e.message, contains('mastodon.example'));
    expect(e.message, contains('cut off'));
    expect(e.message, contains('Nothing was posted'));
    for (final jargon in ['Write failed', 'errno', 'Network error', 'SocketException', 'host machine']) {
      expect(e.message, isNot(contains(jargon)));
    }
    expect(e.raw, contains('10053'), reason: 'the details stay available for reports');
    expect(c.trail.where((t) => t.startsWith('POST')).length, 3, reason: 'one try and two automatic retries');
  });

  test('the next attempt re-sends only the file that did not arrive, and posts once', () async {
    var media = 0;
    var fail = true;
    final c = Scripted((i, r) {
      if (r.url.path.endsWith('/statuses')) return json({'id': 's1', 'url': 'https://x/s1'});
      media++;
      // The second file is cut on every try of the first attempt.
      if (fail && media >= 2) return null;
      return json({'id': 'm$media', 'url': 'u'});
    });
    final adapter = MastodonAdapter();
    final v = PostVariant(text: 'x', media: [image('i1'), image('i2')], sourcePostId: 'p');
    final first = await adapter.publish(v, account, secrets, ctx(c, big));
    expect(first.success, isFalse);
    final before = media;
    fail = false;
    final second = await adapter.publish(v, account, secrets, ctx(c, big));
    expect(second.success, isTrue);
    expect(media - before, 1, reason: 'the first file is on the server already');
    expect(c.trail.where((t) => t.endsWith('/statuses')).length, 1);
    expect(c.bodies.last, contains('media_ids%5B%5D=m1'));
  });

  test('an id the server no longer knows is uploaded again instead of failing the post', () async {
    var media = 0;
    var statuses = 0;
    var fail = true;
    final c = Scripted((i, r) {
      if (r.url.path.endsWith('/statuses')) {
        statuses++;
        return statuses == 1 ? json({'error': 'Validation failed: Media not found'}, 422) : json({'id': 's1', 'url': 'https://x/s1'});
      }
      media++;
      if (fail && media >= 2) return null;
      return json({'id': 'm$media', 'url': 'u'});
    });
    final adapter = MastodonAdapter();
    final v = PostVariant(text: 'x', media: [image('i1'), image('i2')], sourcePostId: 'p');
    await adapter.publish(v, account, secrets, ctx(c, big));
    fail = false;
    final r = await adapter.publish(v, account, secrets, ctx(c, big));
    expect(r.success, isTrue, reason: '${r.error?.message}');
    expect(statuses, 2);
  });

  test('an upload that gets no answer is aborted, also under the old 512 KB line', () async {
    final hold = Completer<http.StreamedResponse>();
    final c = _NoAnswer(hold);
    final net = NeforumHttp(client: c, maxRetries: 0, timeout: const Duration(milliseconds: 100));
    await expectLater(
        net.multipart(Uri.parse('https://mastodon.example/api/v2/media'),
            files: [HttpFilePart(field: 'file', bytes: Uint8List(100 * 1024), fileName: 'x', contentType: 'image/jpeg')]),
        throwsA(anything));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.aborted, isNotEmpty, reason: 'a timed-out request must not go on using the uplink');
  });

  test('real sockets: the server closes (FIN, then RST) mid-upload, the second connection succeeds', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var connections = 0;
    server.listen((s) {
      final me = ++connections;
      var got = 0;
      var total = -1;
      final head = BytesBuilder();
      var done = false;
      s.listen((d) async {
        got += d.length;
        if (total < 0) {
          head.add(d);
          final text = latin1.decode(head.toBytes());
          final end = text.indexOf('\r\n\r\n');
          if (end >= 0) {
            final cl = RegExp(r'content-length: (\d+)', caseSensitive: false).firstMatch(text)!.group(1)!;
            total = end + 4 + int.parse(cl);
          }
        }
        if (done) return;
        if (me == 1 && got >= 64 * 1024) {
          done = true;
          s.destroy(); // Unread data, or later segments: the kernel answers with RST.
        } else if (total > 0 && got >= total) {
          done = true;
          const b = '{"id":"m2","url":"u"}';
          s.write('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${b.length}\r\nConnection: close\r\n\r\n$b');
          await s.flush();
          await s.close();
        }
      }, onError: (_) {});
    });
    final c = AdapterContext(http: NeforumHttp(client: IOClient()), log: Logger('t', sink: (l, a, m, [e]) {}));
    final bytes = Uint8List(8 * 1024 * 1024);
    final id = await MastodonApi(c, Uri.parse('http://127.0.0.1:${server.port}'), accessToken: 't').uploadMedia(image('i'), bytes);
    expect(id, 'm2');
    expect(connections, 2);
  }, timeout: const Timeout(Duration(seconds: 30)));
}

class _NoAnswer extends http.BaseClient {
  _NoAnswer(this.hold);
  final Completer<http.StreamedResponse> hold;
  final aborted = <Uri>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    if (r case http.Abortable(:final abortTrigger?)) unawaited(abortTrigger.then((_) => aborted.add(r.url)));
    await r.finalize().drain<void>();
    return hold.future;
  }
}
