// The rest of the upload fix: typed failures, wording, file-level resume, the
// refusal probe, and which adapters may re-send. The tests in
// upload_interrupted_test.dart run against the code before the fix as well;
// these use its new API.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/art/pixelfed_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_a/ghost_api.dart';
import 'package:neforum_core/src/adapters/bluesky/bluesky_api.dart';
import 'package:neforum_core/src/adapters/chat/matrix_api.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_adapter.dart';
import 'package:neforum_core/src/adapters/misskey/misskey_api.dart';
import 'package:neforum_core/src/adapters/pinterest/pinterest_api.dart';
import 'package:test/test.dart';

import '../support/fault_client.dart';
import '../support/test_context.dart';

final _big = Uint8List(1024 * 1024);
const _instance = 'mastodon.example';

MediaAttachment _image(String id) =>
    MediaAttachment(id: id, path: '$id.jpg', mimeType: 'image/jpeg', sizeBytes: 64, width: 10, height: 10, altText: 'alt', fileName: '$id.jpg');

ConnectedAccount _account([String platformId = 'mastodon']) => ConnectedAccount(
      id: 'a',
      platformId: platformId,
      tier: PlatformTier.openApi,
      displayName: 't',
      createdAt: DateTime.utc(2026, 11, 6),
      config: const {'instance': 'https://$_instance', 'domain': _instance, 'software': 'mastodon', 'maxCharacters': 500, 'maxMediaAttachments': 4},
    );
const _secrets = {'client_id': 'c', 'client_secret': 's', 'access_token': 't', 'token_type': 'Bearer'};

AdapterContext _ctx(http.Client c, {Uint8List? bytes, NeforumHttp? net, DateTime Function()? now}) => AdapterContext(
      http: net ?? NeforumHttp(client: c),
      log: Logger('t', sink: (l, a, m, [e]) {}),
      clock: now ?? () => DateTime.utc(2026, 11, 6),
      readMedia: (m) async => bytes ?? _big,
    );

bool _isStatus(String line) => line.endsWith('/statuses');
bool _isMedia(String line) => line.contains('/media');

void _expectPlain(String text) {
  for (final word in transportJargon) {
    expect(text, isNot(contains(word)));
  }
}

void main() {
  group('what a failed request throws', () {
    final url = Uri.parse('https://api.example/bot123:SECRET/send?access_token=SECRET');

    test('a small request: plain words, the system text kept without the address', () async {
      final net = NeforumHttp(client: FaultClient((i, r) => null), maxRetries: 0);
      final e = await net.postForm(url, {'a': 'b'}).then<Object>((_) => fail('should throw'), onError: (Object e) => e);
      expect(e, isA<ConnectionFailed>());
      expect(e, isNot(isA<UploadInterrupted>()));
      expect('$e', 'The connection to api.example failed.');
      expect((e as ConnectionFailed).message, 'The connection to api.example failed.');
      expect(e.details, contains('errno = 10053'));
      expect(e.details, isNot(contains('SECRET')));
      expect(NeforumHttp.isTransportError(e), isTrue);
      expect(e, isA<http.ClientException>(), reason: 'existing `on http.ClientException` handlers keep working');
    });

    test('an upload: the count says handed to the connection, in the details only', () async {
      final net = NeforumHttp(client: FaultClient((i, r) => null), maxRetries: 0);
      final e = await net
          .multipart(url, files: [HttpFilePart(field: 'f', bytes: _big, fileName: 'x', contentType: 'image/jpeg')])
          .then<Object>((_) => fail('should throw'), onError: (Object e) => e) as UploadInterrupted;
      expect(e.message, 'The upload to api.example was cut off.');
      expect(e.message, isNot(contains(RegExp(r'\d'))), reason: 'no byte figure stated as fact');
      expect(e.trace.sentBytes, inInclusiveRange(1, 16 * 1024));
      expect(e.trace.totalBytes, greaterThan(_big.length));
      expect(e.trace.attempts, 1);
      expect(e.trace.wholeBodySent, isFalse);
      expect(e.details, contains('errno = 10053'));
      expect(e.details, contains('of ${e.trace.totalBytes} bytes handed to the connection'));
      expect(e.details, isNot(contains('SECRET')));
    });

    test('a request that times out says so in plain words', () async {
      final net = NeforumHttp(
          client: FaultClient((i, r) => Completer<http.StreamedResponse?>().future), maxRetries: 0, timeout: const Duration(milliseconds: 30));
      final e = await net.get(url).then<Object>((_) => fail('should throw'), onError: (Object e) => e);
      expect(e, isA<TimeoutException>());
      expect('$e', 'api.example did not answer within 0 s.');
      expect(NeforumHttp.transportDetails(e), contains('TimeoutException'));
    });

    test('after a whole upload the answer limit is twice the base', () async {
      final net = NeforumHttp(client: _NoAnswerAfterBody(), timeout: const Duration(milliseconds: 40), maxRetries: 0);
      final e = await net.putBytes(url, _big).then<Object>((_) => fail('should throw'), onError: (Object e) => e);
      expect(e, isA<RequestTimedOut>());
      expect((e as RequestTimedOut).duration, const Duration(milliseconds: 80));
    });

    test('each try counts its own bytes', () async {
      final net = NeforumHttp(client: FaultClient((i, r) => null));
      // Raw bytes, so every try's first piece is a full one.
      final e = await net.putBytes(url, _big, retrySafe: true).then<Object>((_) => fail('should throw'), onError: (Object e) => e) as UploadInterrupted;
      expect(e.trace.attempts, 3);
      expect(e.trace.sentBytes, 16 * 1024, reason: 'the last try alone, not the three added up');
      expect(e.details, contains('${e.trace.sentBytes} of ${e.trace.totalBytes} bytes'));
    });

    test('no log line carries the address past its host, or the whole exception', () async {
      final lines = <String>[];
      final log = Logger('t', sink: (l, a, m, [err]) => lines.add('$m ${err ?? ''}'));
      final upload = HttpFilePart(field: 'f', bytes: _big, fileName: 'x', contentType: 'image/jpeg');
      await expectLater(NeforumHttp(client: FaultClient((i, r) => null), log: log).multipart(url, files: [upload], retrySafe: true), throwsA(isA<UploadInterrupted>()));
      await expectLater(NeforumHttp(client: FaultClient((i, r) => null), log: log, maxRetries: 0).get(url), throwsA(isA<ConnectionFailed>()));
      expect(lines.where((l) => l.contains('attempt 1')), isNotEmpty, reason: 'the debug line about each try ran');
      expect(lines.where((l) => l.contains('giving up')), hasLength(2));
      expect(lines.where((l) => l.contains('SECRET')), isEmpty);
    });

    test('anything that is not a connection problem passes through', () async {
      final net = NeforumHttp(client: FaultClient((i, r) => throw const FormatException('bad')), maxRetries: 0);
      await expectLater(net.get(url), throwsA(isA<FormatException>()));
      expect(NeforumHttp.transportMessage(const FormatException('bad')), contains('bad'));
    });

    test('the helpers never leak jargon, whatever exception reaches them', () {
      expect(NeforumHttp.transportMessage(FakeWriteFailed(url)), 'The connection failed.');
      expect(NeforumHttp.transportMessage(const SocketException('Write failed', osError: OSError('x', 10053))), 'The connection failed.');
      expect(NeforumHttp.transportMessage(TimeoutException('x')), 'The server did not answer in time.');
      expect(NeforumHttp.transportDetails(FakeWriteFailed(url)), contains('10053'));
    });
  });

  group('retrySafe', () {
    final url = Uri.parse('https://mastodon.example/api/v2/media');
    HttpFilePart file(int size) => HttpFilePart(field: 'file', bytes: Uint8List(size), fileName: 'x', contentType: 'image/jpeg');

    test('off by default, at any size: a POST is sent once', () async {
      for (final size in [100, 100 * 1024, 9 * 1024 * 1024]) {
        final c = FaultClient((i, r) => null);
        await expectLater(NeforumHttp(client: c).multipart(url, files: [file(size)]), throwsA(isA<ConnectionFailed>()));
        expect(c.n, 1, reason: '$size bytes');
      }
    });

    test('on: a file over 8 MiB is sent again too', () async {
      final c = FaultClient((i, r) => i < 2 ? null : jsonAnswer({'id': 'm'}));
      final r = await NeforumHttp(client: c).multipart(url, files: [file(9 * 1024 * 1024)], retrySafe: true);
      expect(r.ok, isTrue);
      expect(c.n, 3);
    });

    test('on: three tries in all, then it says how many', () async {
      final c = FaultClient((i, r) => null);
      await expectLater(NeforumHttp(client: c).multipart(url, files: [file(100 * 1024)], retrySafe: true),
          throwsA(isA<UploadInterrupted>().having((e) => e.message, 'message', contains('(tried 3 times)'))));
      expect(c.n, 3);
    });

    test('on: a gateway error is tried again, a refusal is not', () async {
      final c = FaultClient((i, r) => jsonAnswer({}, i == 0 ? 502 : 201));
      expect((await NeforumHttp(client: c).multipart(url, files: [file(10)], retrySafe: true, throwOnError: false)).statusCode, 201);
      final refused = FaultClient((i, r) => jsonAnswer({}, 413));
      expect((await NeforumHttp(client: refused).multipart(url, files: [file(10)], retrySafe: true, throwOnError: false)).statusCode, 413);
      expect(refused.n, 1);
      final quota = FaultClient((i, r) => jsonAnswer({}, 429));
      await NeforumHttp(client: quota).multipart(url, files: [file(10)], retrySafe: true, throwOnError: false);
      expect(quota.n, 1, reason: 'no Retry-After: more tries only spend the quota');
    });

    test('off: a gateway error on a POST is not tried again, it may have been processed', () async {
      final c = FaultClient((i, r) => jsonAnswer({}, 502));
      await NeforumHttp(client: c).multipart(url, files: [file(10)], throwOnError: false);
      expect(c.n, 1);
    });

    test('a stalled upload that is safe to re-send gets a new try, and each try is aborted', () async {
      final c = _Stalling(stallOn: 2);
      final net = NeforumHttp(client: c, uploadStallTimeout: const Duration(milliseconds: 50));
      final r = await net.multipart(url, files: [file(200 * 1024)], retrySafe: true);
      expect(r.ok, isTrue);
      expect(c.n, 3);
      expect(c.aborted, hasLength(2));
    });

    test('cancelling ends the retries', () async {
      final signal = CancellationSignal();
      final c = FaultClient((i, r) {
        signal.cancel();
        return null;
      });
      await expectLater(NeforumHttp(client: c).withCancellation(signal).multipart(url, files: [file(100 * 1024)], retrySafe: true),
          throwsA(isA<OperationCancelledException>()));
      expect(c.n, 1);
    });

    test('only the listed callers may set it, and no platform where the upload is the post', () {
      final users = Directory('lib/src')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart') && f.readAsStringSync().contains('retrySafe: true'))
          .map((f) => f.path.replaceAll(r'\', '/').split('/').last)
          .toSet();
      // A new caller belongs here only with a test that proves its upload
      // cannot make a post. Telegram, Discord and Tumblr never: there the
      // upload request is the post.
      expect(users, {'mastodon_api.dart', 'misskey_api.dart', 'bluesky_api.dart', 'ghost_api.dart', 'matrix_api.dart'});
    });
  });

  group('Mastodon: wording', () {
    test('a stall says nothing could be sent, how often it tried, and that nothing was posted', () async {
      final c = _Stalling(stallOn: 99);
      final net = NeforumHttp(client: c, uploadStallTimeout: const Duration(milliseconds: 40));
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [_image('i')]), _account(), _secrets, _ctx(c, net: net));
      expect(r.error!.message, 'Nothing could be sent to $_instance for 0 s (tried 3 times). Nothing was posted.');
      expect(r.error!.retryable, isTrue);
      expect(r.error!.uploadInterrupted, isTrue);
      expect(r.error!.raw, contains('handed to the connection'));
      expect(c.count(_isMedia), 3);
    });

    test('no answer after the whole file: it may have arrived, nothing was posted', () async {
      final net = _NoAnswerAfterBody();
      final client = NeforumHttp(client: net, timeout: const Duration(milliseconds: 20));
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [_image('i')]), _account(), _secrets, _ctx(net, net: client));
      expect(r.error!.message, contains('$_instance did not answer within 0 s of the upload (tried 3 times).'));
      expect(r.error!.message, contains('The file may have arrived, but nothing was posted.'));
      expect(r.error!.uploadInterrupted, isTrue);
    });

    test('a connection lost on the status itself claims nothing about the post', () async {
      final c = FaultClient((i, r) => r.url.path.endsWith('/statuses') ? null : jsonAnswer({'id': 'm', 'url': 'u'}));
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', sourcePostId: 'p'), _account(), _secrets, _ctx(c));
      expect(r.error!.message, 'The connection to $_instance failed.');
      expect(r.error!.message, isNot(contains('posted')));
      expect(r.error!.uploadInterrupted, isNull);
      expect(r.error!.raw, contains('10053'));
      // Three sends with one key: the server keeps one post.
      expect(c.count(_isStatus), 3);
    });

    test('a thread with live parts says nothing more was posted', () async {
      final c = FaultClient((i, r) => _isMedia(r.url.path) ? null : jsonAnswer({}, 404));
      final v = PostVariant(
          text: '', threadParts: const ['one', 'two'], postedThreadIds: const ['s1'], media: [_image('i')], mediaPartIndexes: const [1], sourcePostId: 'p');
      final r = await MastodonAdapter().publish(v, _account(), _secrets, _ctx(c));
      expect(r.success, isFalse);
      expect(r.error!.message, contains('Nothing more was posted.'));
      expect(r.error!.message, isNot(contains('Nothing was posted')));
    });

    test('the older media address is sent again too', () async {
      var v1 = 0;
      final c = FaultClient((i, r) {
        if (_isStatus(r.url.path)) return jsonAnswer({'id': 's1', 'url': 'https://x/s1'});
        if (r.url.path == '/api/v2/media') return jsonAnswer({}, 404);
        v1++;
        return v1 == 1 ? null : jsonAnswer({'id': 'm', 'url': 'u'});
      });
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [_image('i')]), _account(), _secrets, _ctx(c));
      expect(r.success, isTrue, reason: '${r.error?.message}');
      expect(v1, 2);
      expect(c.count(_isStatus), 1);
    });

    test('details and message stay apart for every wording', () async {
      final c = FaultClient((i, r) => null);
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [_image('i')]), _account(), _secrets, _ctx(c));
      _expectPlain(r.error!.message);
      expect(r.error!.message, 'The upload to $_instance was cut off (tried 3 times). Nothing was posted.');
      expect(r.error!.raw, contains('errno = 10053'));
    });
  });

  group('Mastodon: file-level resume', () {
    FaultClient scripted(bool Function() failMedia) {
      var media = 0;
      return FaultClient((i, r) {
        if (_isStatus(r.url.path)) return jsonAnswer({'id': 's$i', 'url': 'https://x/s$i'});
        media++;
        return failMedia() ? null : jsonAnswer({'id': 'm$media', 'url': 'u'});
      });
    }

    test('a kept id is not used for another post, or for another account', () async {
      var fail = true;
      var count = 0;
      final c = scripted(() {
        count++;
        return fail && count >= 2;
      });
      final adapter = MastodonAdapter();
      final two = [_image('i1'), _image('i2')];
      await adapter.publish(PostVariant(text: 'x', media: two, sourcePostId: 'p'), _account(), _secrets, _ctx(c));
      fail = false;
      final before = c.count(_isMedia);
      final other = await adapter.publish(PostVariant(text: 'y', media: two, sourcePostId: 'other'), _account(), _secrets, _ctx(c));
      expect(other.success, isTrue);
      expect(c.count(_isMedia) - before, 2, reason: 'the server takes each id once');
    });

    test('the same file twice in a thread is two uploads, on a retry as well', () async {
      var fail = true;
      final c = FaultClient((i, r) {
        if (_isStatus(r.url.path)) return jsonAnswer({'id': 's$i', 'url': 'https://x/s$i'});
        final uploads = 1 + i;
        return fail && uploads >= 2 ? null : jsonAnswer({'id': 'm$uploads', 'url': 'u'});
      });
      final adapter = MastodonAdapter();
      final same = _image('same');
      final v = PostVariant(text: '', threadParts: const ['one', 'two'], media: [same, same], mediaPartIndexes: const [0, 1], sourcePostId: 'p');
      final first = await adapter.publish(v, _account(), _secrets, _ctx(c));
      expect(first.success, isFalse, reason: 'the second part never got its copy');
      fail = false;
      final second = await adapter.publish(v, _account(), _secrets, _ctx(c));
      expect(second.success, isTrue, reason: '${second.error?.message}');
      final ids = c.bodies.where((b) => b.contains('status=')).map((b) => Uri.splitQueryString(b)['media_ids[]']).toList();
      expect(ids.toSet(), hasLength(2), reason: 'each part has its own id: $ids');
    });

    test('kept ids run out after 6 hours, by the injected clock', () async {
      var now = DateTime.utc(2026, 11, 6, 12);
      var fail = true;
      var uploads = 0;
      final c = scripted(() {
        uploads++;
        return fail && uploads >= 2;
      });
      final adapter = MastodonAdapter();
      final v = PostVariant(text: 'x', media: [_image('i1'), _image('i2')], sourcePostId: 'p');
      await adapter.publish(v, _account(), _secrets, _ctx(c, now: () => now));
      fail = false;
      now = now.add(const Duration(hours: 6));
      final before = c.count(_isMedia);
      expect((await adapter.publish(v, _account(), _secrets, _ctx(c, now: () => now))).success, isTrue);
      expect(c.count(_isMedia) - before, 2);
    });

    test('a changed alt text or file is uploaded again', () async {
      var fail = true;
      var uploads = 0;
      final c = scripted(() {
        uploads++;
        return fail && uploads >= 2;
      });
      final adapter = MastodonAdapter();
      await adapter.publish(PostVariant(text: 'x', media: [_image('i1'), _image('i2')], sourcePostId: 'p'), _account(), _secrets, _ctx(c));
      fail = false;
      final before = c.count(_isMedia);
      final edited = _image('i1').copyWith(altText: 'better');
      await adapter.publish(PostVariant(text: 'x', media: [edited, _image('i2')], sourcePostId: 'p'), _account(), _secrets, _ctx(c));
      expect(c.count(_isMedia) - before, 2);
    });

    test('kept ids are gone once the server holds the post', () async {
      final when = DateTime.utc(2026, 11, 7);
      var fail = true;
      var uploads = 0;
      final c = FaultClient((i, r) {
        if (_isStatus(r.url.path)) {
          return jsonAnswer({'id': 's', 'scheduled_at': when.toIso8601String(), 'params': <String, Object?>{}});
        }
        uploads++;
        return fail && uploads >= 2 ? null : jsonAnswer({'id': 'm$uploads', 'url': 'u'});
      });
      final adapter = MastodonAdapter();
      final v = PostVariant(text: 'x', media: [_image('i1'), _image('i2')], sourcePostId: 'p', scheduledAt: when);
      await adapter.publish(v, _account(), _secrets, _ctx(c));
      fail = false;
      expect((await adapter.publish(v, _account(), _secrets, _ctx(c))).isHeldByPlatform, isTrue);
      final before = c.count(_isMedia);
      expect((await adapter.publish(v, _account(), _secrets, _ctx(c))).isHeldByPlatform, isTrue);
      expect(c.count(_isMedia) - before, 2, reason: 'nothing kept once the post is with the server');
    });

    test('kept ids are gone once the post is up', () async {
      var fail = true;
      var uploads = 0;
      final c = FaultClient((i, r) {
        if (_isStatus(r.url.path)) return jsonAnswer({'id': 's$i', 'url': 'https://x/s$i'});
        uploads++;
        return fail && uploads >= 2 ? null : jsonAnswer({'id': 'm$uploads', 'url': 'u'});
      });
      final adapter = MastodonAdapter();
      final v = PostVariant(text: 'x', media: [_image('i1'), _image('i2')], sourcePostId: 'p');
      expect((await adapter.publish(v, _account(), _secrets, _ctx(c))).success, isFalse);
      fail = false;
      expect((await adapter.publish(v, _account(), _secrets, _ctx(c))).success, isTrue);
      final before = c.count(_isMedia);
      // The same post again, say the user posts it a second time: each id is
      // spent, and the server takes an id once.
      expect((await adapter.publish(v, _account(), _secrets, _ctx(c))).success, isTrue);
      expect(c.count(_isMedia) - before, 2, reason: 'nothing kept once the post is up');
    });

    test('a real refusal of the status is not retried without kept ids', () async {
      final c = FaultClient((i, r) => _isStatus(r.url.path) ? jsonAnswer({'error': 'Text is too long'}, 422) : jsonAnswer({'id': 'm', 'url': 'u'}));
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [_image('i')], sourcePostId: 'p'), _account(), _secrets, _ctx(c));
      expect(r.success, isFalse);
      expect(c.count(_isStatus), 1);
      expect(c.count(_isMedia), 1);
    });

    test('a stale id is recovered once: a second refusal stands', () async {
      var fail = true;
      var uploads = 0;
      final c = FaultClient((i, r) {
        if (_isStatus(r.url.path)) return jsonAnswer({'error': 'Validation failed'}, 422);
        uploads++;
        return fail && uploads >= 2 ? null : jsonAnswer({'id': 'm$uploads', 'url': 'u'});
      });
      final adapter = MastodonAdapter();
      final v = PostVariant(text: 'x', media: [_image('i1'), _image('i2')], sourcePostId: 'p');
      await adapter.publish(v, _account(), _secrets, _ctx(c));
      fail = false;
      final r = await adapter.publish(v, _account(), _secrets, _ctx(c));
      expect(r.success, isFalse);
      expect(r.error!.kind, PublishErrorKind.validation);
      expect(c.count(_isStatus), 2);
    });

    test('kept files refused after a status that got no answer are not posted again', () async {
      // The first status went through but its answer was lost, three times.
      // Over an hour later the server has forgotten the key and refuses the
      // files, since that post holds them. Uploading them again would post twice.
      var now = DateTime.utc(2026, 11, 6, 12);
      var lost = true;
      var uploads = 0;
      final c = FaultClient((i, r) {
        if (_isStatus(r.url.path)) return lost ? null : jsonAnswer({'error': 'Validation failed: Media not found'}, 422);
        uploads++;
        return jsonAnswer({'id': 'm$uploads', 'url': 'u'});
      });
      final adapter = MastodonAdapter();
      final v = PostVariant(text: 'x', media: [_image('i')], sourcePostId: 'p');
      final first = await adapter.publish(v, _account(), _secrets, _ctx(c, now: () => now));
      expect(first.error!.message, 'The connection to $_instance failed.');
      expect(c.count(_isStatus), 3);
      lost = false;
      now = now.add(const Duration(hours: 2));
      final second = await adapter.publish(v, _account(), _secrets, _ctx(c, now: () => now));
      expect(second.success, isFalse);
      expect(second.error!.retryable, isFalse);
      expect(second.error!.message, contains('may be live already'));
      expect(uploads, 1, reason: 'no new copy of the file');
      expect(c.count(_isStatus), 4, reason: 'no status after the refusal');
    });

    test('recovery that fails after live parts still records them', () async {
      var phase = 0;
      var statuses = 0;
      var uploads = 0;
      final c = FaultClient((i, r) {
        if (_isStatus(r.url.path)) {
          statuses++;
          if (statuses == 1) return jsonAnswer({'id': 's1', 'url': 'https://x/s1'});
          return jsonAnswer({'error': 'Media not found'}, 422);
        }
        if (r.url.path.contains('instance')) return jsonAnswer({}, 404);
        uploads++;
        if (phase == 0 && uploads >= 2) return null;
        if (phase == 2) return null;
        return jsonAnswer({'id': 'm$uploads', 'url': 'u'});
      });
      final adapter = MastodonAdapter();
      final v = PostVariant(
          text: '', threadParts: const ['one', 'two'], media: [_image('i1'), _image('i2')], mediaPartIndexes: const [0, 1], sourcePostId: 'p');
      await adapter.publish(v, _account(), _secrets, _ctx(c));
      phase = 1;
      final second = await adapter.publish(v, _account(), _secrets, _ctx(c, net: NeforumHttp(client: _Switching(c, () => phase = 2))));
      expect(second.success, isFalse);
      expect(second.threadRemoteIds, ['s1'], reason: 'the live part is on record');
      expect(second.resumable, isFalse);
      expect(second.error!.message, startsWith('Part 2 of 2 failed: '));
      expect(second.error!.message, contains('Nothing more was posted. The first 1 part(s) are live'));
      expect(second.error!.uploadInterrupted, isTrue);
      expect(statuses, 2, reason: 'never sent again after the failed recovery');
    });
  });

  group('Mastodon: refusal probe', () {
    test('a real 413 lost to an early close, over real sockets, is reported as too big', () async {
      final server = await _EarlyAnswerServer.start(imageLimit: 1024 * 1024);
      addTearDown(server.close);
      final c = AdapterContext(http: NeforumHttp(client: IOClient()), log: Logger('t', sink: (l, a, m, [e]) {}), readMedia: (m) async => Uint8List(8 * 1024 * 1024));
      final account = ConnectedAccount(
        id: 'a',
        platformId: 'mastodon',
        tier: PlatformTier.openApi,
        displayName: 't',
        createdAt: DateTime.utc(2026, 11, 6),
        config: {'instance': 'http://127.0.0.1:${server.port}', 'domain': '127.0.0.1', 'software': 'mastodon'},
      );
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [_image('i')], sourcePostId: 'p'), account, _secrets, c);
      expect(r.error!.kind, PublishErrorKind.validation);
      expect(r.error!.retryable, isFalse, reason: 'too big stays too big');
      expect(r.error!.message, '127.0.0.1 takes images up to 1 MB, and this one is 8 MB. Nothing was posted.');
      _expectPlain(r.error!.message);
      expect(r.error!.raw, contains('handed to the connection'));
      expect(server.mediaPosts, 3);
      expect(server.statusPosts, 0);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('under the limit it stays a dropped connection, retryable', () async {
      final c = FaultClient((i, r) => r.url.path.contains('instance')
          ? jsonAnswer({'configuration': {'media_attachments': {'image_size_limit': 16 * 1024 * 1024}}})
          : null);
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [_image('i')]), _account(), _secrets, _ctx(c));
      expect(r.error!.kind, PublishErrorKind.network);
      expect(r.error!.message, contains('cut off'));
      expect(c.count((l) => l.contains('instance')), 1);
    });

    test('the probe runs once, only after the last try, with no sign-in', () async {
      final seen = <String>[];
      final c = FaultClient((i, r) {
        seen.add(r.url.path);
        if (r.url.path.contains('instance')) {
          expect(r.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
          return jsonAnswer({}, 500);
        }
        return null;
      });
      await MastodonAdapter().publish(PostVariant(text: 'x', media: [_image('i')]), _account(), _secrets, _ctx(c));
      expect(seen.take(3), everyElement('/api/v2/media'));
      expect(seen.skip(3), everyElement(contains('instance')));
    });

    test('a probe that fails leaves the upload error as it was', () async {
      final c = FaultClient((i, r) => null);
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [_image('i')]), _account(), _secrets, _ctx(c));
      expect(r.error!.kind, PublishErrorKind.network);
      expect(r.error!.message, contains('cut off'));
    });

    test('a server that does not answer the probe costs its time limit, no more', () async {
      expect(MastodonAdapter().limitProbeTimeout, const Duration(seconds: 15));
      final c = FaultClient((i, r) => r.url.path.contains('instance') ? Completer<http.StreamedResponse?>().future : null);
      final adapter = MastodonAdapter(limitProbeTimeout: const Duration(milliseconds: 50));
      final r = await adapter.publish(PostVariant(text: 'x', media: [_image('i')]), _account(), _secrets, _ctx(c));
      expect(r.error!.kind, PublishErrorKind.network);
      expect(r.error!.message, contains('cut off'));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a cancel during the probe stays a cancel, not a cut-off upload', () async {
      final signal = CancellationSignal();
      final c = FaultClient((i, r) {
        if (!r.url.path.contains('instance')) return null;
        signal.cancel();
        return Completer<http.StreamedResponse?>().future;
      });
      final ctx = AdapterContext(
        http: NeforumHttp(client: c),
        log: Logger('t', sink: (l, a, m, [e]) {}),
        clock: () => DateTime.utc(2026, 11, 6),
        readMedia: (m) async => _big,
        cancellation: signal,
      );
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [_image('i')]), _account(), _secrets, ctx);
      expect(c.count((l) => l.contains('instance')), 1);
      expect(r.error!.uploadInterrupted, isNull);
      expect(r.error!.message, isNot(contains('cut off')));
    });

    test('a file too big for a thread with live parts: nothing more was posted', () async {
      final c = FaultClient((i, r) => r.url.path.contains('instance')
          ? jsonAnswer({'configuration': {'media_attachments': {'image_size_limit': 512 * 1024}}})
          : null);
      final v = PostVariant(
          text: '', threadParts: const ['one', 'two'], postedThreadIds: const ['s1'], media: [_image('i')], mediaPartIndexes: const [1], sourcePostId: 'p');
      final r = await MastodonAdapter().publish(v, _account(), _secrets, _ctx(c));
      expect(r.error!.message, '$_instance takes images up to 0.5 MB, and this one is 1 MB. Nothing more was posted.');
    });

    test('a small file that fails is not put down to the size limit', () async {
      final c = FaultClient((i, r) => null);
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [_image('i')]), _account(), _secrets, _ctx(c, bytes: Uint8List(100)));
      expect(r.error!.message, 'The connection to $_instance failed.');
      expect(c.count((l) => l.contains('instance')), 0, reason: 'only a watched upload can have lost an early answer');
    });

    test('a file just over the limit does not read as the same size', () async {
      final c = FaultClient((i, r) => r.url.path.contains('instance')
          ? jsonAnswer({'configuration': {'media_attachments': {'image_size_limit': 16 * 1024 * 1024}}})
          : null);
      final bytes = Uint8List(16 * 1024 * 1024 + 20 * 1024);
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [_image('i')]), _account(), _secrets, _ctx(c, bytes: bytes));
      expect(r.error!.message, '$_instance takes images up to 16 MB, and this one is a little over that. Nothing was posted.');
    });

    test('videos and sound files are held to the video limit', () async {
      final c = FaultClient((i, r) => r.url.path.contains('instance')
          ? jsonAnswer({'configuration': {'media_attachments': {'image_size_limit': 99 * 1024 * 1024, 'video_size_limit': 512 * 1024}}})
          : null);
      final video = MediaAttachment(id: 'v', path: 'v.mp4', mimeType: 'video/mp4', sizeBytes: 64, width: 10, height: 10, durationMs: 1000, fileName: 'v.mp4');
      final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [video]), _account(), _secrets, _ctx(c));
      expect(r.error!.kind, PublishErrorKind.validation);
      expect(r.error!.message, '$_instance takes videos up to 0.5 MB, and this one is 1 MB. Nothing was posted.');
    });
  });

  group('Pixelfed inherits all of it', () {
    test('a cut upload is sent again, the next attempt resumes, one status', () async {
      var fail = true;
      var media = 0;
      final c = FaultClient((i, r) {
        if (_isStatus(r.url.path)) return jsonAnswer({'id': 's1', 'url': 'https://x/s1'});
        if (r.url.path.contains('instance')) return jsonAnswer({}, 404);
        media++;
        return fail && media >= 2 ? null : jsonAnswer({'id': 'm$media', 'url': 'u'});
      });
      final adapter = PixelfedAdapter();
      final v = PostVariant(text: 'x', media: [_image('i1'), _image('i2')], sourcePostId: 'p', artwork: const ArtworkDetails());
      final account = ConnectedAccount(
        id: 'a',
        platformId: 'pixelfed',
        tier: PlatformTier.openApi,
        displayName: 't',
        createdAt: DateTime.utc(2026, 11, 6),
        config: const {'instance': 'https://pixelfed.example', 'domain': 'pixelfed.example', 'software': 'pixelfed'},
      );
      final first = await adapter.publish(v, account, _secrets, _ctx(c));
      expect(first.error!.message, 'The upload to pixelfed.example was cut off (tried 3 times). Nothing was posted.');
      expect(media, 4, reason: 'file 1 once, file 2 three times');
      fail = false;
      expect((await adapter.publish(v, account, _secrets, _ctx(c))).success, isTrue);
      expect(media, 5);
      expect(c.count(_isStatus), 1);
    });
  });

  group('other adapters: a file on the server is not a post', () {
    FaultClient cutOnce(Object Function(http.BaseRequest) ok) => FaultClient((i, r) => i == 0 ? null : jsonAnswer(ok(r)));

    test('Bluesky: a blob is sent again; the post itself is not', () async {
      final c = cutOnce((r) => {'blob': {'ref': 'x'}});
      final api = BlueskyApi(_ctx(c), pds: Uri.parse('https://pds.example'), accessJwt: 't');
      expect(await api.uploadBlob(_big, 'image/jpeg'), {'ref': 'x'});
      expect(c.n, 2);
      final post = FaultClient((i, r) => null);
      await expectLater(BlueskyApi(_ctx(post), pds: Uri.parse('https://pds.example'), accessJwt: 't').createPost('did', {'text': 'x'}), throwsA(isA<ConnectionFailed>()));
      expect(post.n, 1);
    });

    test('Misskey: a Drive file is sent again; the note is not', () async {
      final c = cutOnce((r) => {'id': 'f1'});
      final api = MisskeyApi(Uri.parse('https://misskey.example'), _ctx(c), token: 't');
      expect((await api.uploadDriveFile(bytes: _big, fileName: 'a.jpg', contentType: 'image/jpeg'))['id'], 'f1');
      expect(c.n, 2);
      final note = FaultClient((i, r) => null);
      await expectLater(_ctx(note).http.postJson(Uri.parse('https://misskey.example/api/notes/create'), {'text': 'x'}), throwsA(isA<ConnectionFailed>()));
      expect(note.n, 1);
    });

    test('Ghost: a stored image or file is sent again; the post is not', () async {
      final c = FaultClient((i, r) => i.isEven ? null : jsonAnswer({'images': <Object>[]}));
      final api = GhostApi(Uri.parse('https://blog.example'), _ctx(c), key: const GhostAdminKey('6489d8a1b2c3d4e5f6a7b8c9', '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'));
      expect((await api.uploadImage(_big, fileName: 'a.jpg', contentType: 'image/jpeg')).ok, isTrue);
      expect((await api.uploadMedia(_big, fileName: 'a.mp3', contentType: 'audio/mpeg')).ok, isTrue);
      expect(c.n, 4);
      final post = FaultClient((i, r) => null);
      final postApi = GhostApi(Uri.parse('https://blog.example'), _ctx(post), key: const GhostAdminKey('6489d8a1b2c3d4e5f6a7b8c9', '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'));
      await expectLater(postApi.postJson('posts/', {'posts': <Object>[]}), throwsA(isA<ConnectionFailed>()));
      expect(post.n, 1);
    });

    test('Ghost: a re-send that starts after the first token ran out carries a new one', () async {
      var now = DateTime.utc(2026, 11, 6, 12);
      final exps = <int>[];
      final c = FaultClient((i, r) {
        final token = r.headers['Authorization']!.split(' ').last;
        final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1])))) as Map<String, dynamic>;
        final exp = payload['exp'] as int;
        exps.add(exp);
        // What Ghost does with a token past its end.
        if (exp * 1000 <= now.millisecondsSinceEpoch) return jsonAnswer({'errors': [{'type': 'TokenExpiredError', 'message': 'Token expired'}]}, 401);
        if (i == 0) {
          // A first try that ran longer than a token lives, then dropped.
          now = now.add(ghostTokenLifetime + const Duration(minutes: 1));
          return null;
        }
        return jsonAnswer({'images': <Object>[]});
      });
      final api = GhostApi(Uri.parse('https://blog.example'), _ctx(c, now: () => now), key: const GhostAdminKey('6489d8a1b2c3d4e5f6a7b8c9', '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'));
      expect((await api.uploadImage(_big, fileName: 'a.jpg', contentType: 'image/jpeg')).ok, isTrue);
      expect(c.n, 2);
      expect(exps.last, greaterThan(exps.first));
    });

    test('Matrix: stored media is sent again', () async {
      final c = cutOnce((r) => {'content_uri': 'mxc://x/y'});
      final api = MatrixApi(Uri.parse('https://matrix.example'), _ctx(c), token: 't');
      expect(await api.upload(_big, contentType: 'image/jpeg', fileName: 'a.jpg'), 'mxc://x/y');
      expect(c.n, 2);
    });
  });

  group('Pinterest: the inline image is the post, so it goes by what was sent', () {
    PinterestApi client(NeforumHttp net) =>
        PinterestApi(ctx: AdapterContext(http: net, log: Logger('t', sink: (l, a, m, [e]) {}), readMedia: (m) async => _big), accessToken: 't');
    final body = {'media_source': {'source_type': 'image_base64', 'data': base64Encode(Uint8List(1024 * 1024))}};

    test('a base64 body on a slow link is not held to the plain time limit', () async {
      final c = _SlowReader(const Duration(milliseconds: 15));
      final net = NeforumHttp(client: c, timeout: const Duration(milliseconds: 100), uploadStallTimeout: const Duration(seconds: 5), maxRetries: 0);
      // Far more than the 100 ms the plain path would have allowed.
      final id = await client(net).createPin({'media_source': {'data': base64Encode(Uint8List(120 * 1024))}});
      expect(id, 'pin1');
      expect(c.pieces, greaterThan(8));
    });

    test('cut off before the whole body left: retryable, and no Pin was made', () async {
      final c = FaultClient((i, r) => null);
      final e = await client(NeforumHttp(client: c)).createPin(body).then<AdapterException>((_) => fail('should throw'), onError: (Object e) => e as AdapterException);
      expect(c.n, 1, reason: 'a POST that can post is never re-sent inside one attempt');
      expect(e.error.retryable, isTrue);
      expect(e.error.message, contains('This Pin was not created.'));
      expect(e.error.uploadInterrupted, isTrue);
    });

    test('no answer after the whole body: not retried, it may be live', () async {
      final c = _NoAnswerAfterBody();
      final net = NeforumHttp(client: c, timeout: const Duration(milliseconds: 20));
      final e = await client(net).createPin(body).then<AdapterException>((_) => fail('should throw'), onError: (Object e) => e as AdapterException);
      expect(c.n, 1);
      expect(e.error.retryable, isFalse);
      expect(e.error.message, PublishError.unconfirmedMessage('the network'));
      expect(e.error.outcomeUnknown, isTrue);
      expect(e.error.raw, contains('handed to the connection'));
    });
  });

  group('no errno and no type name reaches a person', () {
    // Every adapter on its own path to the user, with the error users saw.
    final cases = <String, (PlatformAdapter, ConnectedAccount, Map<String, String>, PostVariant)>{
      'mastodon': (MastodonAdapter(), _account(), _secrets, PostVariant(text: 'x', media: [_image('i')])),
      'pixelfed': (
        PixelfedAdapter(),
        fakeAccount('pixelfed', config: const {'instance': 'https://p.example', 'domain': 'p.example', 'software': 'pixelfed'}),
        _secrets,
        PostVariant(text: 'x', media: [_image('i')], artwork: const ArtworkDetails())
      ),
      'pinterest': (
        builtinAdapter('pinterest'),
        fakeAccount('pinterest', tier: PlatformTier.byokApi, config: const {'appId': 'a', 'boardId': '5', 'boardName': 'b', 'username': 'u', 'accessLevel': 'standard'}),
        {'app_secret': 's', 'access_token': 't', 'token_type': 'bearer', 'expires_at': '2036-01-01T00:00:00Z'},
        PostVariant(text: 'x', media: [_image('i')])
      ),
      'bluesky': (
        builtinAdapter('bluesky'),
        fakeAccount('bluesky', config: const {'did': 'did:plc:x', 'handle': 'a.b', 'pds': 'https://pds.example', 'service': 'https://bsky.social'}),
        {'access_token': _jwt, 'refresh_token': 'r', 'token_type': 'Bearer', 'expires_at': '2036-01-01T00:00:00Z', 'app_password': 'p'},
        const PostVariant(text: 'x')
      ),
      'misskey': (
        builtinAdapter('misskey'),
        fakeAccount('misskey', config: const {'instance': 'https://m.example', 'host': 'm.example', 'maxNoteTextLength': 3000}),
        {'access_token': 't', 'token': 't', 'i': 't'},
        const PostVariant(text: 'x')
      ),
      'ghost': (
        builtinAdapter('ghost'),
        fakeAccount('ghost', config: const {'apiUrl': 'https://blog.example', 'site': 'https://blog.example/'}),
        {'admin_api_key': '6489d8a1b2c3d4e5f6a7b8c9:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'},
        const PostVariant(title: 'T', text: 'x')
      ),
      'tumblr': (
        builtinAdapter('tumblr'),
        fakeAccount('tumblr', tier: PlatformTier.byokApi, config: const {'consumerKey': 'k', 'blogName': 'b', 'blogUuid': 't:u', 'username': 'u'}),
        {'consumer_secret': 's', 'access_token': 't', 'token_type': 'bearer', 'expires_at': '2036-01-01T00:00:00Z', 'refresh_token': 'r'},
        const PostVariant(text: 'x')
      ),
      'reddit': (
        builtinAdapter('reddit'),
        fakeAccount('reddit', tier: PlatformTier.byokApi, config: const {'clientId': 'c', 'username': 'a', 'userId': 'b', 'defaultSubreddit': 'test'}),
        {'access_token': 't', 'refresh_token': 'r', 'expires_at': '2036-01-01T00:00:00Z', 'token_type': 'bearer'},
        const PostVariant(title: 'T', text: 'x')
      ),
      'instagram': (
        builtinAdapter('instagram'),
        fakeAccount('instagram', tier: PlatformTier.byokApi, config: const {'igUserId': '1', 'username': 'u'}),
        {'access_token': 't', 'token_type': 'Bearer', 'expires_at': '2036-01-01T00:00:00Z', 'refreshed_at': '2035-12-31T00:00:00Z'},
        PostVariant(text: 'x', media: [_image('i')])
      ),
    };

    for (final MapEntry(key: name, value: (adapter, account, secrets, variant)) in cases.entries) {
      test(name, () async {
        final c = FaultClient((i, r) => null);
        final ctx = AdapterContext(
          http: NeforumHttp(client: c, maxRetries: 0),
          log: Logger('t', sink: (l, a, m, [e]) {}),
          mediaHost: FakeMediaHost(),
          clock: () => DateTime.utc(2026, 11, 6),
          readMedia: (m) async => fakeJpegBytes,
        );
        final r = await adapter.publish(variant, account, secrets, ctx);
        expect(r.success, isFalse);
        expect(r.error!.kind, PublishErrorKind.network, reason: r.error!.message);
        _expectPlain(r.error!.message);
        expect(r.error!.message, isNot(contains('Network error')));
        expect(r.error!.raw, contains('10053'), reason: 'the details box keeps the system text: ${r.error!.message}');
      });
    }

    group('a file that cannot be read', () {
      test('the real reader, a real missing file: plain words, the system text in the details', () async {
        final missing = '${Directory.systemTemp.path}${Platform.pathSeparator}neforum-no-such-file-${DateTime.now().microsecondsSinceEpoch}.jpg';
        final image = MediaAttachment(id: 'i', path: missing, mimeType: 'image/jpeg', sizeBytes: 64, width: 10, height: 10, fileName: 'i.jpg');
        final c = FaultClient((i, r) => fail('nothing to send'));
        final ctx = AdapterContext(http: NeforumHttp(client: c), log: Logger('t', sink: (l, a, m, [e]) {}));
        final r = await MastodonAdapter().publish(PostVariant(text: 'x', media: [image]), _account(), _secrets, ctx);
        expect(r.error!.kind, PublishErrorKind.configuration);
        expect(r.error!.message, 'Could not read i.jpg. Attach it again and retry.');
        expect(r.error!.raw, contains('errno'));
      });

      for (final MapEntry(key: name, value: (adapter, account, secrets, variant)) in cases.entries) {
        test(name, () async {
          final ctx = AdapterContext(
            http: NeforumHttp(client: FaultClient((i, r) => jsonAnswer({'id': 'x', 'data': {'id': 'x'}})), maxRetries: 0),
            log: Logger('t', sink: (l, a, m, [e]) {}),
            mediaHost: FakeMediaHost(),
            clock: () => DateTime.utc(2026, 11, 6),
            readMedia: (m) async => throw PathNotFoundException(m.path, const OSError('The system cannot find the path specified', 3), 'Cannot open file'),
          );
          final error = await adapter
              .publish(variant.copyWith(media: [_image('i')]), account, secrets, ctx)
              .then((r) => r.error!, onError: (Object e) => (e as AdapterException).error);
          _expectPlain(error.message);
          expect(error.message, isNot(contains('PathNotFound')));
          expect(error.message, contains('Could not read i.jpg'));
          expect(error.raw, contains('errno = 3'));
        });
      }

      test('a cancel while reading stays a cancel', () async {
        final ctx = AdapterContext(
          http: NeforumHttp(client: FaultClient((i, r) => fail('nothing to send'))),
          log: Logger('t', sink: (l, a, m, [e]) {}),
          readMedia: (m) async => throw const OperationCancelledException(),
        );
        await expectLater(ctx.readMedia(_image('i')), throwsA(isA<OperationCancelledException>()));
      });

      test('a second file that cannot be read on Flickr keeps one full stop, and says what is up', () async {
        var uploads = 0;
        final account = fakeAccount('flickr', tier: PlatformTier.byokApi, config: const {'userNsid': '1@N01'});
        final ctx = AdapterContext(
          http: NeforumHttp(client: FaultClient((i, r) {
            uploads++;
            return http.StreamedResponse(Stream.value(utf8.encode('<rsp stat="ok"><photoid>1001</photoid></rsp>')), 200);
          })),
          log: Logger('t', sink: (l, a, m, [e]) {}),
          clock: () => DateTime.utc(2026, 11, 6),
          readMedia: (m) async {
            if (m.id == 'j') throw const OSError('The system cannot find the path specified', 3);
            return fakeJpegBytes;
          },
        );
        final r = await builtinAdapter('flickr').publish(
          PostVariant(text: 'x', title: 'T', artwork: const ArtworkDetails(), media: [_image('i'), _image('j')]),
          account,
          const OAuth1Credentials(consumerKey: 'ck', consumerSecret: 'cs', token: 't', tokenSecret: 'ts').toSecrets(),
          ctx,
        );
        expect(uploads, 1);
        expect(
          r.error!.message,
          'File 2 of 2 failed: Could not read j.jpg. Attach it again and retry. The files already uploaded (1001) stay on Flickr; upload the rest yourself.',
        );
      });

      test('no wrapper around another error adds a second full stop', () {
        final doubled = RegExp(r'\$\{(?:err|error)\.message\}\. ');
        final hits = Directory('lib/src/adapters')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart') && doubled.hasMatch(f.readAsStringSync()))
            .map((f) => f.path)
            .toList();
        expect(hits, isEmpty);
      });

      test('no adapter quotes the exception in the message', () {
        final quoting = RegExp(r"(?:Could not read \$\{[^}]*\}|missing or unreadable)[^'\n]*\$");
        final hits = [Directory('lib/src/adapters'), Directory('lib/src/publish')]
            .expand((d) => d.listSync(recursive: true))
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart') && quoting.hasMatch(f.readAsStringSync()))
            .map((f) => f.path)
            .toList();
        expect(hits, isEmpty);
      });
    });

    test('an upload error stays readable on a device that has never heard of the field', () {
      const e = PublishError.network('x', uploadInterrupted: true);
      expect(PublishError.fromJson(e.toJson()).uploadInterrupted, isTrue);
      expect(e.toJson()['kind'], 'network', reason: 'no new enum value in synced models');
      expect(const PublishError.network('y').toJson().containsKey('uploadInterrupted'), isFalse);
      expect(PublishError.fromJson(const {'kind': 'network', 'message': 'old'}).uploadInterrupted, isNull);
    });

    test('thread wording: one full stop, and the flag survives', () {
      const e = PublishError.network('The upload was cut off. Nothing more was posted.', uploadInterrupted: true);
      final wrapped = e.asResumableThread(postedIds: const ['a'], total: 2);
      expect(wrapped.message, 'Part 2 of 2 failed: The upload was cut off. Nothing more was posted. The first 1 part(s) are live; Retry posts the rest of the thread.');
      expect(wrapped.uploadInterrupted, isTrue);
      expect(wrapped.isPartialThread, isTrue);
      final hand = e.asPartialThread(postedIds: const ['a'], total: 2);
      expect(hand.message, contains('Nothing more was posted. Parts already posted'));
      expect(hand.uploadInterrupted, isTrue);
    });
  });
}

/// A signed-looking JWT that is far from expired, for Bluesky's session check.
final String _jwt = () {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'exp': 2100000000, 'sub': 'did:plc:x'})}.sig';
}();

PlatformAdapter builtinAdapter(String id) => builtinAdapters().firstWhere((a) => a.descriptor.id == id);

/// Takes one piece of the first [stallOn] requests, then never asks for more.
class _Stalling extends FaultClient {
  _Stalling({required this.stallOn}) : super((i, r) => null);
  final int stallOn;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    if (r case http.Abortable(:final abortTrigger?)) unawaited(abortTrigger.then((_) => aborted.add(r.url)));
    final i = n++;
    trail.add('${r.method} ${r.url.path}');
    if (r.url.path.contains('instance')) return jsonAnswer({}, 404);
    if (i >= stallOn) {
      await r.finalize().drain<void>();
      return jsonAnswer({'id': 'm', 'url': 'u'});
    }
    late StreamSubscription<List<int>> sub;
    sub = r.finalize().listen((_) => sub.pause());
    return Completer<http.StreamedResponse>().future;
  }
}

/// Takes the whole body, then stays silent.
class _NoAnswerAfterBody extends FaultClient {
  _NoAnswerAfterBody() : super((i, r) => null);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    if (r case http.Abortable(:final abortTrigger?)) unawaited(abortTrigger.then((_) => aborted.add(r.url)));
    n++;
    trail.add('${r.method} ${r.url.path}');
    if (r.url.path.contains('instance')) return jsonAnswer({}, 404);
    await r.finalize().drain<void>();
    return Completer<http.StreamedResponse>().future;
  }
}

/// Reads a piece every [pause], then answers as Pinterest does.
class _SlowReader extends http.BaseClient {
  _SlowReader(this.pause);
  final Duration pause;
  var pieces = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    await for (final _ in r.finalize()) {
      pieces++;
      await Future<void>.delayed(pause);
    }
    return jsonAnswer({'id': 'pin1'});
  }
}

/// Passes requests on, calling [onStatus] after the first status POST.
class _Switching extends http.BaseClient {
  _Switching(this.inner, this.onStatus);
  final FaultClient inner;
  final void Function() onStatus;
  var statuses = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    final res = await inner.send(r);
    if (r.url.path.endsWith('/statuses') && ++statuses == 2) onStatus();
    return res;
  }
}

/// A server that answers 413 early and closes while the client is still
/// sending, as nginx does with a body over `client_max_body_size`.
class _EarlyAnswerServer {
  _EarlyAnswerServer._(this._server, this.imageLimit);

  static Future<_EarlyAnswerServer> start({required int imageLimit}) async {
    final s = _EarlyAnswerServer._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), imageLimit);
    s._server.listen(s._serve);
    return s;
  }

  final ServerSocket _server;
  final int imageLimit;
  var mediaPosts = 0;
  var statusPosts = 0;

  int get port => _server.port;
  Future<void> close() => _server.close();

  void _serve(Socket s) {
    final head = BytesBuilder();
    var done = false;
    s.listen((d) async {
      if (done) return;
      head.add(d);
      final text = latin1.decode(head.toBytes());
      if (!text.contains('\r\n\r\n')) return;
      if (text.startsWith('GET /api/v2/instance')) {
        done = true;
        final b = jsonEncode({'configuration': {'media_attachments': {'image_size_limit': imageLimit}}});
        s.write('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${b.length}\r\nConnection: close\r\n\r\n$b');
        await s.flush();
        await s.close();
      } else if (text.startsWith('POST /api/v2/media')) {
        done = true;
        mediaPosts++;
        const b = '{"error":"file too large"}';
        s.write('HTTP/1.1 413 Payload Too Large\r\nContent-Type: application/json\r\nContent-Length: ${b.length}\r\nConnection: close\r\n\r\n$b');
        await s.flush();
        s.destroy();
      } else if (text.startsWith('POST /api/v1/statuses')) {
        done = true;
        statusPosts++;
        s.destroy();
      } else {
        done = true;
        s.destroy();
      }
    }, onError: (_) {}, cancelOnError: true);
  }
}
