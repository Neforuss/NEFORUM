// The real thing: a real adapter, the real client and TLS, against a local server
// that reads slowly. The bar may only say what counted bytes allow, may not fall, and
// may not reach 100 before the server has answered.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/io_client.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_adapter.dart';
import 'package:test/test.dart';

import '../support/loopback_tls.dart';
import '../support/test_context.dart';

const _fileBytes = 6 * 1024 * 1024;

void main() {
  test('through TLS on loopback, throttled: never falls, never ahead of the count, never 100 before the answer', () async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(loopbackCertificatePem))
      ..usePrivateKeyBytes(utf8.encode(loopbackKeyPem));
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    var serverGot = 0;
    var answered = false;
    server.listen((request) async {
      if (request.uri.path.contains('/media')) {
        await for (final chunk in request) {
          serverGot += chunk.length;
          // About 8 MiB/s: a second or so, in many pieces.
          await Future<void>.delayed(Duration(microseconds: chunk.length ~/ 8));
        }
        answered = true;
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'id': 'm1', 'url': 'https://example.test/m1'}));
        await request.response.close();
        return;
      }
      await request.drain<void>();
      answered = true;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'id': 's1', 'url': 'https://example.test/s1'}));
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final host = '127.0.0.1:${server.port}';
    final account = ConnectedAccount(
      id: 'a1',
      platformId: 'mastodon',
      tier: PlatformTier.openApi,
      displayName: 'Loopback',
      createdAt: testNow,
      config: {'instance': 'https://$host', 'domain': host, 'software': 'mastodon', 'maxCharacters': 500, 'maxMediaAttachments': 4, 'descriptionLimit': 1500},
    );
    final image = MediaAttachment(id: 'photo', path: 'mem://photo', mimeType: 'image/jpeg', sizeBytes: _fileBytes, width: 100, height: 100, altText: 'x', fileName: 'p.jpg');
    final post = Post(
      id: 'post1',
      text: 'hello',
      media: [image],
      targets: const [PostTarget(accountId: 'a1')],
      createdAt: testNow,
      updatedAt: testNow,
    );
    final accounts = InMemoryAccountRepository();
    await accounts.upsert(account);
    final posts = InMemoryPostRepository();
    await posts.upsert(post);
    final secrets = InMemorySecretStore();
    await secrets.write('a1', const {'client_id': 'c', 'client_secret': 's', 'access_token': 't', 'token_type': 'Bearer'});

    final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
    final net = NeforumHttp(client: IOClient(client), log: Logger('t', sink: (l, a, m, [e]) {}));
    addTearDown(net.close);
    final service = PublishService(
      registry: AdapterRegistry([MastodonAdapter()]),
      accounts: accounts,
      posts: posts,
      secrets: secrets,
      quota: QuotaTracker(InMemoryQuotaRepository()),
      http: net,
      log: Logger('t', sink: (l, a, m, [e]) {}),
      readMedia: (_) async => Uint8List(_fileBytes),
    );

    final figures = <int>[];
    var counted = 0;
    var observations = 0;
    final progress = PublishProgressTracker(
      postId: 'post1',
      interval: Duration.zero,
      onChange: (p) {
        observations++;
        final last = figures.isEmpty ? 0 : figures.last;
        expect(p.permille, greaterThanOrEqualTo(last), reason: 'the bar never falls');
        figures.add(p.permille);
        if (!answered) expect(p.permille, lessThan(1000), reason: 'never 100 before the server answered');
        expect(p.permille, lessThanOrEqualTo(kPermilleCapUntilOutcome + (p.finished ? 10 : 0)));
        // Before the wait and the post: at most the upload's 70% of what was counted.
        final target = p.targets.single;
        if (target.stage == ProgressStage.uploading && !p.finished) {
          final allowed = 700 * counted ~/ target.slotTotal.orOne;
          expect(p.permille, lessThanOrEqualTo(allowed + 1), reason: 'never ahead of the counted bytes');
        }
      },
    );

    final done = await service.publish(
      'post1',
      onPlan: progress.plan,
      onEvent: (id, e) {
        if (e.position != null) counted = e.position!;
        progress.event(id, e);
      },
      onOutcome: progress.outcome,
    );

    expect(done.targets.single.status, TargetStatus.published);
    expect(serverGot, greaterThan(_fileBytes), reason: 'the whole file reached the server, with its multipart boundaries');
    expect(observations, greaterThan(50), reason: 'the bar moved with the bytes, in many steps');
    expect(figures.toSet().length, greaterThan(20));
    expect(figures.last, 1000);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

extension on int? {
  int get orOne {
    final v = this;
    return v == null || v <= 0 ? 1 : v;
  }
}
