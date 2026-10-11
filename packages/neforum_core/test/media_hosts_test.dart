import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/media_hosts/media_host_support.dart' show checkSize;
import 'package:test/test.dart';

import 'support/test_context.dart';

/// Records requests and answers them with [respond].
class Recorder {
  Recorder(this.respond);
  final http.Response Function(http.Request r, int index) respond;
  final List<http.Request> calls = [];

  NeforumHttp get client => NeforumHttp(
      client: MockClient((r) async {
        calls.add(r);
        return respond(r, calls.length - 1);
      }),
      maxRetries: 0);
}

DateTime awsExampleDate = DateTime.utc(2013, 5, 24);

const awsSigner = SigV4Signer(
  accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
  secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
  region: 'us-east-1',
);

void main() {
  group('SigV4 (AWS S3 documentation examples)', () {
    test('GET object with Range header', () {
      final s = awsSigner.sign(
        method: 'GET',
        uri: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
        now: awsExampleDate,
        headers: {'range': 'bytes=0-9'},
      );
      expect(
          s.canonicalRequest,
          'GET\n/test.txt\n\nhost:examplebucket.s3.amazonaws.com\nrange:bytes=0-9\n'
          'x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n'
          'x-amz-date:20130524T000000Z\n\nhost;range;x-amz-content-sha256;x-amz-date\n'
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(
          s.stringToSign,
          'AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n'
          '7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972');
      expect(s.signature, 'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41');
      expect(
          s.authorization,
          'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,'
          'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,'
          'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41');
    });

    test(r'PUT object test$file.text with a signed payload', () {
      final body = utf8.encode('Welcome to Amazon S3.');
      final s = awsSigner.sign(
        method: 'PUT',
        uri: Uri.parse(r'https://examplebucket.s3.amazonaws.com/test$file.text'),
        now: awsExampleDate,
        headers: {'date': 'Fri, 24 May 2013 00:00:00 GMT', 'x-amz-storage-class': 'REDUCED_REDUNDANCY'},
        payloadHash: sha256Hex(body),
      );
      expect(sha256Hex(body), '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072');
      expect(s.canonicalRequest, startsWith('PUT\n/test%24file.text\n\ndate:Fri, 24 May 2013 00:00:00 GMT\n'));
      expect(s.signature, '98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd');
    });

    test('presigned GET URL', () {
      final url = awsSigner.presign(
        method: 'GET',
        uri: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
        now: awsExampleDate,
        expires: const Duration(hours: 24),
      );
      expect(url.queryParameters['X-Amz-Credential'], 'AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request');
      expect(url.queryParameters['X-Amz-Expires'], '86400');
      expect(url.queryParameters['X-Amz-SignedHeaders'], 'host');
      expect(url.queryParameters['X-Amz-Signature'], 'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404');
      expect(url.toString(), contains('X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request'));
    });

    test('URI encoding and host header', () {
      expect(SigV4Signer.uriEncode('a b/c~d_e.f-g*'), 'a%20b%2Fc~d_e.f-g%2A');
      expect(SigV4Signer.hostHeader(Uri.parse('http://minio.local:9000/b/k')), 'minio.local:9000');
      expect(SigV4Signer.hostHeader(Uri.parse('https://x.example.com:443/k')), 'x.example.com');
      expect(SigV4Signer.formatAmzDate(DateTime.utc(2026, 1, 2, 3, 4, 5)), '20260102T030405Z');
    });
  });

  group('S3CompatibleMediaHost', () {
    final bytes = Uint8List.fromList(fakeJpegBytes);

    S3CompatibleMediaHost r2(Recorder rec, {String? publicBase = 'https://media.example.com'}) =>
        S3CompatibleMediaHost.fromConfig({
          'endpoint': 'https://acc123.r2.cloudflarestorage.com',
          'bucket': 'posts',
          'accessKeyId': 'AKID',
          'secretAccessKey': 'SECRET',
          if (publicBase != null) 'publicBaseUrl': '$publicBase/',
          'pathPrefix': '/neforum/',
        }, rec.client, clock: () => testNow, newId: () => 'abc123');

    test('region and addressing inference', () {
      final rec = Recorder((r, i) => http.Response('', 200));
      expect(r2(rec).region, 'auto');
      expect(r2(rec).usesVirtualHost, isFalse);
      expect(r2(rec).objectUri('neforum/x.jpg').toString(),
          'https://acc123.r2.cloudflarestorage.com/posts/neforum/x.jpg');
      final aws = S3CompatibleMediaHost(
          http: rec.client,
          endpoint: Uri.parse('https://s3.eu-central-1.amazonaws.com'),
          bucket: 'my-bucket',
          accessKeyId: 'a',
          secretAccessKey: 'b');
      expect(aws.region, 'eu-central-1');
      expect(aws.objectUri('k.jpg').toString(), 'https://my-bucket.s3.eu-central-1.amazonaws.com/k.jpg');
      final b2 = S3CompatibleMediaHost(
          http: rec.client,
          endpoint: Uri.parse('https://s3.us-west-004.backblazeb2.com'),
          bucket: 'dotted.bucket',
          accessKeyId: 'a',
          secretAccessKey: 'b');
      expect(b2.region, 'us-west-004');
      expect(b2.usesVirtualHost, isFalse, reason: 'dots in bucket names break virtual-host TLS');
      final minio = S3CompatibleMediaHost(
          http: rec.client,
          endpoint: Uri.parse('http://nas.local:9000'),
          bucket: 'media',
          accessKeyId: 'a',
          secretAccessKey: 'b');
      expect(minio.region, 'us-east-1');
      expect(minio.objectUri('k.png').toString(), 'http://nas.local:9000/media/k.png');
    });

    test('upload sends a SigV4-signed PUT and returns the public URL', () async {
      final rec = Recorder((r, i) => http.Response('', 200));
      final host = r2(rec);
      final hosted = await host.upload(fakeImage(), bytes);

      expect(rec.calls, hasLength(1));
      final put = rec.calls.single;
      expect(put.method, 'PUT');
      expect(put.url.toString(), 'https://acc123.r2.cloudflarestorage.com/posts/neforum/abc123.jpg');
      expect(put.bodyBytes, bytes);
      expect(put.headers['content-type'], 'image/jpeg');
      expect(put.headers['x-amz-date'], '20261007T120000Z');
      expect(put.headers['x-amz-content-sha256'], sha256Hex(bytes));

      const signer = SigV4Signer(accessKeyId: 'AKID', secretAccessKey: 'SECRET', region: 'auto');
      final expected = signer.sign(
          method: 'PUT',
          uri: put.url,
          now: testNow,
          headers: {'content-type': 'image/jpeg'},
          payloadHash: sha256Hex(bytes));
      expect(expected.canonicalRequest, contains('host:acc123.r2.cloudflarestorage.com\n'));
      expect(put.headers['authorization'], expected.authorization);
      expect(
          put.headers['authorization'],
          startsWith('AWS4-HMAC-SHA256 Credential=AKID/20261007/auto/s3/aws4_request,'
              'SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date,Signature='));

      expect(hosted.url.toString(), 'https://media.example.com/neforum/abc123.jpg');
      expect(hosted.deleteHandle, 'neforum/abc123.jpg');
      expect(hosted.hostId, 's3');
    });

    test('without a public base URL a presigned GET link is returned', () async {
      final rec = Recorder((r, i) => http.Response('', 200));
      final hosted = await r2(rec, publicBase: null).upload(fakeImage(), bytes, ttl: const Duration(hours: 2));
      expect(hosted.url.path, '/posts/neforum/abc123.jpg');
      expect(hosted.url.queryParameters['X-Amz-Expires'], '7200');
      expect(hosted.url.queryParameters['X-Amz-Signature'], hasLength(64));
      expect(hosted.expiresAt, testNow.add(const Duration(hours: 2)));
    });

    test('presigned links are capped at 7 days', () async {
      final rec = Recorder((r, i) => http.Response('', 200));
      final hosted = await r2(rec, publicBase: null).upload(fakeImage(), bytes, ttl: const Duration(days: 30));
      expect(hosted.url.queryParameters['X-Amz-Expires'], '604800');
    });

    test('delete sends a signed DELETE and tolerates 404', () async {
      final rec = Recorder((r, i) => http.Response('', i == 0 ? 204 : 404));
      final host = r2(rec);
      final hosted = HostedMedia(hostId: 's3', url: Uri.parse('https://media.example.com/neforum/abc123.jpg'),
          deleteHandle: 'neforum/abc123.jpg');
      await host.delete(hosted);
      await host.delete(hosted);
      expect(rec.calls.map((c) => c.method), ['DELETE', 'DELETE']);
      expect(rec.calls.first.url.toString(), 'https://acc123.r2.cloudflarestorage.com/posts/neforum/abc123.jpg');
      expect(rec.calls.first.headers['x-amz-content-sha256'], emptyPayloadHash);
      expect(rec.calls.first.headers['authorization'], contains('SignedHeaders=host;x-amz-content-sha256;x-amz-date'));
    });

    test('S3 XML errors become readable MediaHostExceptions', () async {
      final rec = Recorder((r, i) => http.Response(
          '<?xml version="1.0"?><Error><Code>SignatureDoesNotMatch</Code><Message>nope</Message></Error>', 403));
      await expectLater(
          r2(rec).upload(fakeImage(), bytes),
          throwsA(isA<MediaHostException>()
              .having((e) => e.message, 'message', allOf(contains('HTTP 403'), contains('secret access key')))
              .having((e) => e.hostId, 'hostId', 's3')));
    });

    test('verify does PUT, GET public URL, DELETE', () async {
      final rec = Recorder((r, i) => http.Response('', 200));
      await r2(rec).verify();
      expect(rec.calls.map((c) => '${c.method} ${c.url}'), [
        'PUT https://acc123.r2.cloudflarestorage.com/posts/neforum/abc123.txt',
        'GET https://media.example.com/neforum/abc123.txt',
        'DELETE https://acc123.r2.cloudflarestorage.com/posts/neforum/abc123.txt',
      ]);
      expect(rec.calls.first.headers['content-type'], 'text/plain');
    });

    test('verify reports a non-public bucket and still deletes the probe', () async {
      final rec = Recorder((r, i) => http.Response('', r.method == 'GET' ? 403 : 200));
      await expectLater(r2(rec).verify(), throwsA(isA<MediaHostException>()
          .having((e) => e.message, 'message', contains('publicly readable'))));
      expect(rec.calls.last.method, 'DELETE');
    });

    test('the shared size check rejects files over maxBytes', () {
      final rec = Recorder((r, i) => http.Response('', 200));
      expect(() => checkSize(r2(rec), fakeVideo(), 6 * 1000 * 1000 * 1000),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message', contains('5.0 GB'))));
      expect(() => checkSize(CatboxMediaHost.litterbox(http: rec.client), fakeVideo(), 1000 * 1000 * 1000 + 1),
          throwsA(isA<MediaHostException>()));
    });
  });

  group('WebDavMediaHost', () {
    final bytes = Uint8List.fromList(fakeJpegBytes);
    final auth = 'Basic ${base64Encode(utf8.encode('alice:app-pass'))}';

    WebDavMediaHost nextcloud(Recorder rec, {String? linkStyle}) => WebDavMediaHost.fromConfig({
          'webdavUrl': 'https://cloud.example.com/remote.php/dav/files/alice/NEFORUM',
          'username': 'alice',
          'password': 'app-pass',
          if (linkStyle != null) 'linkStyle': linkStyle,
        }, rec.client, clock: () => testNow, newId: () => 'f00d');

    http.Response ocsOk() => http.Response(
        jsonEncode({
          'ocs': {
            'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
            'data': {'id': 42, 'share_type': 3, 'token': 'TOKEN1', 'url': 'https://cloud.example.com/s/TOKEN1'},
          }
        }),
        200,
        headers: jsonHeaders);

    test('Nextcloud: PUT with Basic auth, then OCS public link share', () async {
      final rec = Recorder((r, i) => i == 0 ? http.Response('', 201) : ocsOk());
      final host = nextcloud(rec);
      expect(host.serverBase.toString(), 'https://cloud.example.com');
      expect(host.userFolderPath, '/NEFORUM');

      final hosted = await host.upload(fakeImage(), bytes, ttl: const Duration(hours: 24));

      final put = rec.calls[0];
      expect(put.method, 'PUT');
      expect(put.url.toString(), 'https://cloud.example.com/remote.php/dav/files/alice/NEFORUM/f00d.jpg');
      expect(put.headers['authorization'], auth);
      expect(put.headers['content-type'], 'image/jpeg');
      expect(put.bodyBytes, bytes);

      final share = rec.calls[1];
      expect(share.method, 'POST');
      expect(share.url.toString(), 'https://cloud.example.com/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json');
      expect(share.headers['ocs-apirequest'], 'true');
      expect(share.headers['authorization'], auth);
      expect(bodyOf(share), {'path': '/NEFORUM/f00d.jpg', 'shareType': '3', 'permissions': '1', 'expireDate': '2026-10-09'});

      expect(hosted.url.toString(), 'https://cloud.example.com/s/TOKEN1/download');
      expect(jsonDecode(hosted.deleteHandle!), {
        'file': 'https://cloud.example.com/remote.php/dav/files/alice/NEFORUM/f00d.jpg',
        'share': '42',
      });
    });

    test('Nextcloud "dav" link style', () async {
      final rec = Recorder((r, i) => i == 0 ? http.Response('', 201) : ocsOk());
      final hosted = await nextcloud(rec, linkStyle: 'dav').upload(fakeImage(), bytes);
      expect(hosted.url.toString(), 'https://cloud.example.com/public.php/dav/files/TOKEN1');
      expect(bodyOf(rec.calls[1]).containsKey('expireDate'), isFalse);
    });

    test('missing folder is created with MKCOL and the PUT retried', () async {
      final rec = Recorder((r, i) => switch (i) {
            0 => http.Response('', 409),
            1 => http.Response('', 201),
            2 => http.Response('', 201),
            _ => ocsOk(),
          });
      await nextcloud(rec).upload(fakeImage(), bytes);
      expect(rec.calls.map((c) => c.method), ['PUT', 'MKCOL', 'PUT', 'POST']);
      expect(rec.calls[1].url.toString(), 'https://cloud.example.com/remote.php/dav/files/alice/NEFORUM/');
    });

    test('delete removes the share, then the file', () async {
      final rec = Recorder((r, i) => http.Response('', i == 0 ? 200 : 204));
      final hosted = HostedMedia(
          hostId: 'webdav',
          url: Uri.parse('https://cloud.example.com/s/TOKEN1/download'),
          deleteHandle: jsonEncode({'file': 'https://cloud.example.com/remote.php/dav/files/alice/NEFORUM/f00d.jpg', 'share': '42'}));
      await nextcloud(rec).delete(hosted);
      expect(rec.calls.map((c) => '${c.method} ${c.url}'), [
        'DELETE https://cloud.example.com/ocs/v2.php/apps/files_sharing/api/v1/shares/42?format=json',
        'DELETE https://cloud.example.com/remote.php/dav/files/alice/NEFORUM/f00d.jpg',
      ]);
      expect(rec.calls.first.headers['ocs-apirequest'], 'true');
    });

    test('a failed share removes the uploaded file and reports the OCS message', () async {
      final rec = Recorder((r, i) => switch (i) {
            0 => http.Response('', 201),
            1 => http.Response(
                jsonEncode({
                  'ocs': {
                    'meta': {'status': 'failure', 'statuscode': 403, 'message': 'Public link sharing is disabled'},
                    'data': <Object>[],
                  }
                }),
                403,
                headers: jsonHeaders),
            _ => http.Response('', 204),
          });
      await expectLater(nextcloud(rec).upload(fakeImage(), bytes),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message', contains('Public link sharing is disabled'))));
      expect(rec.calls.last.method, 'DELETE');
    });

    test('wrong app password -> clear message', () async {
      final rec = Recorder((r, i) => http.Response('', 401));
      await expectLater(nextcloud(rec).upload(fakeImage(), bytes),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message', contains('app password'))));
    });

    test('generic WebDAV uses the public URL template and needs no OCS', () async {
      final rec = Recorder((r, i) => http.Response('', 201));
      final host = WebDavMediaHost.fromConfig({
        'webdavUrl': 'https://dav.example.org/media/',
        'username': 'bob',
        'password': 'pw',
        'publicUrlTemplate': 'https://files.example.org/media/{name}',
      }, rec.client, newId: () => 'beef');
      final hosted = await host.upload(fakeVideo(), bytes);
      expect(rec.calls.single.url.toString(), 'https://dav.example.org/media/beef.mp4');
      expect(rec.calls.single.headers['content-type'], 'video/mp4');
      expect(hosted.url.toString(), 'https://files.example.org/media/beef.mp4');
    });

    test('generic WebDAV without a template is a configuration error', () {
      expect(
          () => WebDavMediaHost.fromConfig(
              {'webdavUrl': 'https://dav.example.org/media', 'username': 'bob', 'password': 'pw'},
              NeforumHttp(client: MockClient((r) async => http.Response('', 200)))),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message', contains('Public URL template'))));
    });
  });

  group('CatboxMediaHost', () {
    final bytes = Uint8List.fromList(fakeJpegBytes);

    test('litterbox upload: endpoint and form fields', () async {
      final rec = Recorder((r, i) => http.Response('https://litter.catbox.moe/ab12cd.jpg', 200));
      final host = CatboxMediaHost.litterboxFromConfig(const {}, rec.client, clock: () => testNow);
      final hosted = await host.upload(fakeImage(), bytes);
      final req = rec.calls.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), 'https://litterbox.catbox.moe/resources/internals/api.php');
      expect(multipartFieldsOf(req), {'reqtype': 'fileupload', 'time': '1h', 'fileToUpload': '<img1.jpg>'});
      expect(req.headers['user-agent'], startsWith('NEFORUM/'));
      expect(hosted.url.toString(), 'https://litter.catbox.moe/ab12cd.jpg');
      expect(hosted.deleteHandle, isNull);
      expect(hosted.expiresAt, testNow.add(const Duration(hours: 1)));
    });

    test('litterbox picks a longer time when the caller needs it', () async {
      final rec = Recorder((r, i) => http.Response('https://litter.catbox.moe/x.mp4\n', 200));
      final host = CatboxMediaHost.litterbox(http: rec.client);
      await host.upload(fakeVideo(), bytes, ttl: const Duration(hours: 24));
      expect(multipartFieldsOf(rec.calls.single)['time'], '24h');
      expect(host.timeFor(const Duration(days: 9)), LitterboxTime.hours72);
      expect(CatboxMediaHost.litterbox(http: rec.client, minimumTime: LitterboxTime.hours12)
          .timeFor(const Duration(minutes: 5)), LitterboxTime.hours12);
    });

    test('invalid litterbox time is rejected', () {
      expect(() => CatboxMediaHost.litterboxFromConfig({'time': '2h'}, NeforumHttp()),
          throwsA(isA<MediaHostException>()));
    });

    test('catbox upload with userhash, then deletefiles', () async {
      final rec = Recorder((r, i) => http.Response(i == 0 ? 'https://files.catbox.moe/q1w2e3.jpg' : 'Files successfully deleted.', 200));
      final host = CatboxMediaHost.catboxFromConfig({'userhash': 'HASH'}, rec.client);
      final hosted = await host.upload(fakeImage(), bytes);
      expect(rec.calls[0].url.toString(), 'https://catbox.moe/user/api.php');
      expect(multipartFieldsOf(rec.calls[0]), {'reqtype': 'fileupload', 'userhash': 'HASH', 'fileToUpload': '<img1.jpg>'});
      expect(hosted.deleteHandle, 'q1w2e3.jpg');

      await host.delete(hosted);
      expect(rec.calls[1].url.toString(), 'https://catbox.moe/user/api.php');
      expect(multipartFieldsOf(rec.calls[1]), {'reqtype': 'deletefiles', 'userhash': 'HASH', 'files': 'q1w2e3.jpg'});
    });

    test('anonymous catbox uploads cannot be deleted (no request)', () async {
      final rec = Recorder((r, i) => http.Response('https://files.catbox.moe/q1w2e3.jpg', 200));
      final host = CatboxMediaHost.catbox(http: rec.client);
      final hosted = await host.upload(fakeImage(), bytes);
      expect(multipartFieldsOf(rec.calls.single).containsKey('userhash'), isFalse);
      await host.delete(hosted);
      expect(rec.calls, hasLength(1));
    });

    test('non-URL response body is an error', () async {
      final rec = Recorder((r, i) => http.Response('No files given', 412));
      await expectLater(CatboxMediaHost.catbox(http: rec.client).upload(fakeImage(), bytes),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message', contains('No files given'))));
    });

    test('size limits from the catbox docs are enforced before uploading', () async {
      final rec = Recorder((r, i) => fail('no request expected'));
      final catbox = CatboxMediaHost.catbox(http: rec.client);
      expect(catbox.maxBytes, 200 * 1000 * 1000);
      expect(CatboxMediaHost.litterbox(http: rec.client).maxBytes, 1000 * 1000 * 1000);
      final bigGif = Uint8List(21 * 1000 * 1000);
      await expectLater(catbox.upload(fakeImage(mimeType: 'image/gif'), bigGif),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message', contains('20 MB'))));
      expect(rec.calls, isEmpty);
    });
  });

  group('ManualUrlMediaHost', () {
    test('asks the user to paste a link', () async {
      await expectLater(const ManualUrlMediaHost().upload(fakeImage(), Uint8List(0)),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message', contains('Paste a public https link'))));
    });

    test('returns a pasted https link and rejects http', () async {
      const host = ManualUrlMediaHost(urls: {'img1': 'https://me.example/p.jpg', 'img2': 'http://me.example/p.jpg'});
      expect((await host.upload(fakeImage(), Uint8List(0))).url.toString(), 'https://me.example/p.jpg');
      await expectLater(host.upload(fakeImage(id: 'img2'), Uint8List(0)), throwsA(isA<MediaHostException>()));
    });
  });

  group('MediaHostRegistry', () {
    final registry = MediaHostRegistry.builtIn();
    final httpClient = NeforumHttp(client: MockClient((r) async => http.Response('', 200)));

    test('lists the built-in hosts, litterbox first as the default', () {
      expect(registry.descriptors.map((d) => d.id), ['litterbox', 's3', 'webdav', 'catbox', 'manual']);
      expect(MediaHostRegistry.defaultHostId, 'litterbox');
      expect(registry.descriptor('litterbox')!.temporary, isTrue);
      expect(registry.descriptor('s3')!.secretFields.map((f) => f.key), ['secretAccessKey']);
      expect(registry.descriptor('webdav')!.secretFields.map((f) => f.key), ['password']);
    });

    test('create builds configured hosts', () {
      expect(registry.create('litterbox', const {}, httpClient), isA<CatboxMediaHost>());
      expect(registry.create('manual', const {}, httpClient), isA<ManualUrlMediaHost>());
      final s3 = registry.create('s3', {
        'endpoint': 's3.us-west-004.backblazeb2.com',
        'bucket': 'b',
        'accessKeyId': 'k',
        'secretAccessKey': 's',
      }, httpClient);
      expect(s3, isA<S3CompatibleMediaHost>());
      expect((s3 as S3CompatibleMediaHost).endpoint.toString(), 'https://s3.us-west-004.backblazeb2.com');
    });

    test('missing required fields and unknown ids are reported', () {
      expect(registry.missingFields('s3', {'bucket': 'b'}), ['Endpoint', 'Access key ID', 'Secret access key']);
      expect(() => registry.create('s3', {'bucket': 'b'}, httpClient),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message', contains('"Endpoint"'))));
      expect(() => registry.create('imgur', const {}, httpClient), throwsA(isA<MediaHostException>()));
    });

    test('split separates keychain values from settings values', () {
      final parts = registry.split('s3', {'bucket': 'b', 'secretAccessKey': 's'});
      expect(parts.plain, {'bucket': 'b'});
      expect(parts.secrets, {'secretAccessKey': 's'});
    });
  });
}
