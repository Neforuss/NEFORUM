import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/media_hosts/media_host_support.dart'
    show bodySnippet, checkSize, decodeHtmlEntities, hostHttpFailure, isTemporaryStatus, looksLikeHtml, mediaHostRetryPause;
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
      expect(S3CompatibleMediaHost.defaultRegionFor(Uri.parse('https://s3.dualstack.ap-south-1.amazonaws.com')),
          'ap-south-1');
      expect(S3CompatibleMediaHost.defaultRegionFor(Uri.parse('https://s3-eu-west-1.amazonaws.com')), 'eu-west-1');
      expect(S3CompatibleMediaHost.defaultRegionFor(Uri.parse('https://s3.amazonaws.com')), 'us-east-1');
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

    test('verify opens the public link and still removes the probe when it fails', () async {
      final ok = Recorder((r, i) => i == 1 ? ocsOk() : http.Response('', i == 0 ? 201 : 200));
      await nextcloud(ok).verify();
      expect(ok.calls.map((c) => '${c.method} ${c.url}'), [
        'PUT https://cloud.example.com/remote.php/dav/files/alice/NEFORUM/f00d.txt',
        'POST https://cloud.example.com/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json',
        'GET https://cloud.example.com/s/TOKEN1/download',
        'DELETE https://cloud.example.com/ocs/v2.php/apps/files_sharing/api/v1/shares/42?format=json',
        'DELETE https://cloud.example.com/remote.php/dav/files/alice/NEFORUM/f00d.txt',
      ]);
      expect(ok.calls[2].headers.containsKey('authorization'), isFalse, reason: 'the public link must work without login');

      final broken = Recorder((r, i) => r.method == 'GET' ? http.Response('', 404) : http.Response('', 201));
      final plain = WebDavMediaHost.fromConfig({
        'webdavUrl': 'https://dav.example.org/media/',
        'username': 'bob',
        'password': 'pw',
        'publicUrlTemplate': 'https://files.example.org/wrong/{name}',
      }, broken.client, newId: () => 'beef');
      await expectLater(plain.verify(),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message', contains('public URL template'))));
      expect(broken.calls.last.method, 'DELETE');
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
    test('without a link or pattern it tells the user what to set', () async {
      await expectLater(const ManualUrlMediaHost().upload(fakeImage(), Uint8List(0)),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message', contains('link pattern'))));
    });

    test('the link pattern from the settings gives every file its public link', () async {
      final host = MediaHostRegistry.builtIn().create(
          'manual', {'urlTemplate': 'https://me.example/media/{name}'}, NeforumHttp(client: MockClient((r) async => fail('no HTTP'))));
      const named = MediaAttachment(
          id: 'x', path: '/photos/a.jpg', mimeType: 'image/jpeg', sizeBytes: 1, fileName: 'Summer 2026.jpg');
      expect((await host.upload(named, Uint8List(0))).url.toString(), 'https://me.example/media/Summer%202026.jpg');
      const unnamed = MediaAttachment(id: 'y', path: r'C:\photos\b.png', mimeType: 'image/png', sizeBytes: 1);
      expect((await host.upload(unnamed, Uint8List(0))).url.toString(), 'https://me.example/media/b.png');
      expect(() => ManualUrlMediaHost.fromConfig({'urlTemplate': 'http://me.example/{name}'}),
          throwsA(isA<MediaHostException>()));
      expect(() => ManualUrlMediaHost.fromConfig({'urlTemplate': 'https://me.example/media/'}),
          throwsA(isA<MediaHostException>()));
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
      expect(registry.create('manual', const {'urlTemplate': 'https://me.example/{name}'}, httpClient),
          isA<ManualUrlMediaHost>());
      expect(registry.missingFields('manual', const {}), ['Link pattern']);
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

  group('Readable host errors, retry once, Test button', () {
    final bytes = Uint8List.fromList(fakeJpegBytes);
    // The body Litterbox really sent on 11 October 2026 (shortened).
    const litterbox500 = '<!doctype html><html lang="en"><meta charset="UTF-8"><meta content="nofollow,noarchive,noindex" '
        'name="robots"><title>500 | Internal Server Error</title><body><h1>Oops</h1></body></html>';
    const readable500 = "Litterbox couldn't store the file: its server answered HTTP 500 (Internal Server Error). "
        "This is a problem on Litterbox's side; try again later or choose another media host in Settings.";

    NeforumResponse resp(int status, String body) =>
        NeforumResponse(status, const {}, Uint8List.fromList(utf8.encode(body)), Uri.parse('https://host.example/api'));

    late List<Duration> waits;
    Future<void> noSleep(Duration d) async => waits.add(d);
    setUp(() => waits = []);

    test('bodySnippet turns an HTML page into its title, or "an error page"', () {
      expect(bodySnippet(resp(500, litterbox500)), '500 | Internal Server Error');
      expect(bodySnippet(resp(502, '<HTML>\r\n<HEAD><TITLE>\n  Service &amp; Status &#8211; down&#x21; &nbsp;</TITLE></HEAD></HTML>')),
          'Service & Status – down!');
      expect(bodySnippet(resp(503, '<!DOCTYPE html><html><body><p>Down for maintenance</p></body></html>')), 'an error page');
      expect(bodySnippet(resp(500, '<html><head><title>   </title></head></html>')), 'an error page');
      expect(bodySnippet(resp(412, '  No files given  ')), 'No files given');
      expect(bodySnippet(resp(500, 'x' * 300)), '${'x' * 200}…');
      const s3Xml = '<?xml version="1.0"?><Error><Code>InternalError</Code></Error>';
      expect(looksLikeHtml(s3Xml), isFalse);
      expect(bodySnippet(resp(500, s3Xml)), s3Xml);
      expect(looksLikeHtml('<?xml version="1.0"?>\n<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0//EN"><html>'), isTrue);
      expect(decodeHtmlEntities('&lt;b&gt; &quot;x&quot; &#39;y&#39; &bogus; &#0; &#xD800;'), '<b> "x" \'y\' &bogus; &#0; &#xD800;');
    });

    test('5xx is blamed on the host, 4xx on the request', () {
      expect(hostHttpFailure('Litterbox', resp(500, litterbox500)), readable500);
      expect(hostHttpFailure('Litterbox', resp(502, '<html><head><title>502 Bad Gateway</title></head></html>')),
          startsWith("Litterbox couldn't store the file: its server answered HTTP 502 (Bad Gateway). This is a problem"));
      expect(hostHttpFailure('Catbox', resp(503, 'Server busy.')),
          startsWith("Catbox couldn't store the file: its server answered HTTP 503 (Service Unavailable): Server busy. "));
      final refused = hostHttpFailure('Catbox', resp(412, 'No files given'));
      expect(refused, startsWith('Catbox refused to store the file: it answered HTTP 412 (Precondition Failed): No files given. '));
      expect(refused, allOf(contains("won't help"), isNot(contains("Catbox's side"))));
      expect(hostHttpFailure('Litterbox', resp(413, '<html><title>413 Request Entity Too Large</title></html>')),
          'Litterbox refused to store the file: it answered HTTP 413 (Request Entity Too Large). '
          'The file is too large for Litterbox.');
      expect([500, 502, 503, 504, 522].every(isTemporaryStatus), isTrue);
      expect([400, 404, 429, 501, 507].any(isTemporaryStatus), isFalse);
    });

    test('Litterbox: HTTP 5xx is retried once and then reported readably', () async {
      final rec = Recorder((r, i) => http.Response(litterbox500, 500, headers: {'content-type': 'text/html'}));
      final host = CatboxMediaHost.litterbox(http: rec.client, retryDelay: noSleep);
      await expectLater(
          host.upload(fakeImage(), bytes),
          throwsA(isA<MediaHostException>()
              .having((e) => e.message, 'message', readable500)
              .having((e) => e.temporary, 'temporary', isTrue)
              .having((e) => e.hostId, 'hostId', 'litterbox')));
      expect(rec.calls, hasLength(2));
      expect(waits, [mediaHostRetryPause]);
    });

    test('Litterbox: a 5xx followed by success uploads normally', () async {
      final rec = Recorder((r, i) => i == 0 ? http.Response(litterbox500, 503) : http.Response('https://litter.catbox.moe/ok.jpg', 200));
      final hosted = await CatboxMediaHost.litterbox(http: rec.client, retryDelay: noSleep).upload(fakeImage(), bytes);
      expect(hosted.url.toString(), 'https://litter.catbox.moe/ok.jpg');
      expect(rec.calls, hasLength(2));
      expect(multipartFieldsOf(rec.calls[1]), multipartFieldsOf(rec.calls[0]), reason: 'the retry sends the same upload');
      expect(waits, [mediaHostRetryPause]);
    });

    test('4xx answers are not retried', () async {
      final rec = Recorder((r, i) => http.Response('<html><title>413 Request Entity Too Large</title></html>', 413));
      await expectLater(
          CatboxMediaHost.catbox(http: rec.client, retryDelay: noSleep).upload(fakeImage(), bytes),
          throwsA(isA<MediaHostException>()
              .having((e) => e.message, 'message', allOf(startsWith('Catbox refused to store the file'), contains('too large')))
              .having((e) => e.temporary, 'temporary', isFalse)));
      expect(rec.calls, hasLength(1));
      expect(waits, isEmpty);
    });

    test('network errors are retried once; a second one is reported as temporary', () async {
      var n = 0;
      NeforumHttp flaky(int failures) => NeforumHttp(
          client: MockClient((r) async {
            if (n++ < failures) throw http.ClientException('Connection reset by peer');
            return http.Response('https://litter.catbox.moe/net.jpg', 200);
          }),
          maxRetries: 0);
      final hosted = await CatboxMediaHost.litterbox(http: flaky(1), retryDelay: noSleep).upload(fakeImage(), bytes);
      expect(hosted.url.toString(), 'https://litter.catbox.moe/net.jpg');
      expect(waits, [mediaHostRetryPause]);

      n = 0;
      await expectLater(
          CatboxMediaHost.litterbox(http: flaky(2), retryDelay: noSleep).upload(fakeImage(), bytes),
          throwsA(isA<MediaHostException>()
              .having((e) => e.message, 'message', allOf(contains('Connection reset by peer'), contains('tried twice')))
              .having((e) => e.temporary, 'temporary', isTrue)));
      expect(n, 2);
    });

    test('S3: a 5xx PUT is retried and explained with the S3 error code', () async {
      final rec = Recorder((r, i) => http.Response(
          '<?xml version="1.0"?><Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>',
          500));
      final host = S3CompatibleMediaHost.fromConfig({
        'endpoint': 'https://acc123.r2.cloudflarestorage.com',
        'bucket': 'posts',
        'accessKeyId': 'AKID',
        'secretAccessKey': 'SECRET',
      }, rec.client, clock: () => testNow, newId: () => 'abc123', retryDelay: noSleep);
      await expectLater(
          host.upload(fakeImage(), bytes),
          throwsA(isA<MediaHostException>()
              .having((e) => e.message, 'message',
                  "Your bucket couldn't store the file: its server answered HTTP 500 (Internal Server Error): InternalError: "
                  "We encountered an internal error. Please try again. This is a problem on the storage provider's side; "
                  'try again later or choose another media host in Settings.')
              .having((e) => e.temporary, 'temporary', isTrue)));
      expect(rec.calls.map((c) => c.method), ['PUT', 'PUT']);
      expect(waits, [mediaHostRetryPause]);
    });

    test('S3: an HTML page from a proxy is reduced to its title', () async {
      final rec = Recorder((r, i) => http.Response('<html><head><title>403 Forbidden</title></head><body>nginx</body></html>', 403));
      final host = S3CompatibleMediaHost(
          http: rec.client,
          endpoint: Uri.parse('https://minio.example.com'),
          bucket: 'b',
          accessKeyId: 'a',
          secretAccessKey: 's',
          retryDelay: noSleep);
      await expectLater(host.upload(fakeImage(), bytes),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message', 'Could not upload the file (HTTP 403): Forbidden')));
      expect(rec.calls, hasLength(1));
    });

    test('WebDAV: a proxy 502 is retried and explained without markup', () async {
      final rec = Recorder((r, i) => http.Response('<html>\r\n<head><title>502 Bad Gateway</title></head>\r\n<body>nginx</body></html>', 502));
      final host = WebDavMediaHost.fromConfig({
        'webdavUrl': 'https://cloud.example.com/remote.php/dav/files/alice/NEFORUM',
        'username': 'alice',
        'password': 'app-pass',
      }, rec.client, newId: () => 'f00d', retryDelay: noSleep);
      await expectLater(
          host.upload(fakeImage(), bytes),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message',
              "Nextcloud couldn't store the file: its server answered HTTP 502 (Bad Gateway). This is a problem on your "
              "server's side; try again later or choose another media host in Settings.")));
      expect(rec.calls.map((c) => c.method), ['PUT', 'PUT']);
    });

    test('Litterbox Test uploads the probe file with time=1h, whatever "Keep files for" says', () async {
      final rec = Recorder((r, i) => http.Response('https://litter.catbox.moe/probe.txt', 200));
      final host = CatboxMediaHost.litterboxFromConfig({'time': '72h'}, rec.client, retryDelay: noSleep);
      await host.verify();
      final req = rec.calls.single;
      expect(req.method, 'POST');
      expect(req.url, CatboxMediaHost.litterboxApi);
      expect(multipartFieldsOf(req), {'reqtype': 'fileupload', 'time': '1h', 'fileToUpload': '<neforum-probe.txt>'});
      expect(verifySuccessMessage(host), allOf(startsWith('Upload works'), contains('1 hour')));
    });

    test('Litterbox Test fails readably when the upload fails', () async {
      final rec = Recorder((r, i) => http.Response(litterbox500, 500));
      await expectLater(CatboxMediaHost.litterbox(http: rec.client, retryDelay: noSleep).verify(),
          throwsA(isA<MediaHostException>().having((e) => e.message, 'message', readable500)));
      expect(rec.calls, hasLength(2));
    });

    test('Catbox Test: upload + delete with a userhash, reachability only without one', () async {
      final withHash = Recorder((r, i) => http.Response(i == 0 ? 'https://files.catbox.moe/pr0be.txt' : 'Files successfully deleted.', 200));
      final account = CatboxMediaHost.catbox(http: withHash.client, userhash: 'HASH', retryDelay: noSleep);
      await account.verify();
      expect(multipartFieldsOf(withHash.calls[0]), {'reqtype': 'fileupload', 'userhash': 'HASH', 'fileToUpload': '<neforum-probe.txt>'});
      expect(multipartFieldsOf(withHash.calls[1]), {'reqtype': 'deletefiles', 'userhash': 'HASH', 'files': 'pr0be.txt'});
      expect(verifySuccessMessage(account), contains('deleted it again'));

      final anon = Recorder((r, i) => http.Response('<!doctype html><title>Catbox</title>', 200));
      final anonymous = CatboxMediaHost.catbox(http: anon.client, retryDelay: noSleep);
      await anonymous.verify();
      expect(anon.calls.map((c) => '${c.method} ${c.url}'), ['GET https://catbox.moe/'], reason: 'no permanent anonymous probe file');
      expect(verifySuccessMessage(anonymous), contains('uploads were not tested'));
    });

    test('hosts without a description keep the generic success text', () {
      expect(verifySuccessMessage(FakeMediaHost()), 'Connection works');
    });
  });
}
