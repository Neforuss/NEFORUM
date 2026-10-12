import 'dart:typed_data';

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import 'support/test_context.dart';

/// A host that stores files, or fails with [failWith], and records calls.
class _Host implements MediaHost {
  _Host(this.id, this.name, {this.failWith, this.maxBytes});

  @override
  final String id;
  @override
  final String name;
  @override
  final int? maxBytes;
  Object? failWith;
  final List<String> uploaded = [];
  final List<HostedMedia> deleted = [];
  int verified = 0;

  @override
  String get description => 'test host';
  @override
  List<MediaHostField> get fields => const [];

  @override
  Future<HostedMedia> upload(MediaAttachment media, Uint8List bytes, {Duration? ttl}) async {
    final f = failWith;
    if (f != null) throw f;
    uploaded.add(media.id);
    return HostedMedia(hostId: id, url: Uri.parse('https://$id.example.test/${media.id}'), deleteHandle: 'key-${media.id}');
  }

  @override
  Future<void> delete(HostedMedia hosted) async => deleted.add(hosted);

  @override
  Future<void> verify() async => verified++;
}

const _outage = MediaHostException(
    "Litterbox couldn't store the file: its server answered HTTP 500 (Internal Server Error). This is a problem on "
    "Litterbox's side; try again later or choose another media host in Settings.",
    hostId: 'litterbox',
    temporary: true);

void main() {
  final bytes = Uint8List(100);
  late _Host main;
  late _Host backup;
  late List<String> reports;
  late FallbackMediaHost host;

  setUp(() {
    main = _Host('litterbox', 'Litterbox');
    backup = _Host('s3', 'My bucket');
    reports = [];
    host = FallbackMediaHost(main, backup, onFallback: reports.add);
  });

  test('the main host is used while it works; the fallback is untouched', () async {
    final h = await host.upload(fakeImage(), bytes);
    expect(h.url.host, 'litterbox.example.test');
    expect(backup.uploaded, isEmpty);
    expect(reports, isEmpty);
    await host.delete(h);
    expect(main.deleted.single.deleteHandle, h.deleteHandle);
  });

  test('when the main host fails, the fallback stores the file and the user is told why', () async {
    main.failWith = _outage;
    final h = await host.upload(fakeImage(id: 'img1'), bytes);
    expect(h.url.host, 's3.example.test');
    expect(backup.uploaded, ['img1']);
    expect(reports.single, startsWith('Litterbox failed, so My bucket stored img1.jpg.'));
    expect(reports.single, contains('HTTP 500'));
  });

  test('files on the fallback are deleted there, even when both hosts are the same kind', () async {
    final a = _Host('s3', 'Bucket A', failWith: _outage);
    final b = _Host('s3', 'Bucket B');
    final twin = FallbackMediaHost(a, b);
    final h = await twin.upload(fakeImage(), bytes);
    expect(h.hostId, 's3${FallbackMediaHost.fallbackMark}');
    await twin.delete(h);
    expect(a.deleted, isEmpty);
    expect(b.deleted.single.hostId, 's3');
    expect(b.deleted.single.deleteHandle, h.deleteHandle);
  });

  test('a file too large for the main host goes straight to the fallback', () async {
    final small = _Host('litterbox', 'Litterbox', maxBytes: 50);
    final big = FallbackMediaHost(small, backup, onFallback: reports.add);
    expect(big.maxBytes, isNull, reason: 'the fallback has no limit');
    await big.upload(fakeImage(id: 'clip'), bytes);
    expect(small.uploaded, isEmpty);
    expect(backup.uploaded, ['clip']);
    expect(reports.single, 'clip.jpg is larger than Litterbox accepts, so My bucket stored it.');
  });

  test('maxBytes is the larger limit of the two hosts', () {
    expect(FallbackMediaHost(_Host('a', 'A', maxBytes: 10), _Host('b', 'B', maxBytes: 30)).maxBytes, 30);
  });

  test('when both fail, one message explains both; an outage on either keeps it retryable', () async {
    main.failWith = _outage;
    backup.failWith = const MediaHostException('Your bucket refused to store the file: it answered HTTP 403 (Forbidden).', hostId: 's3');
    try {
      await host.upload(fakeImage(), bytes);
      fail('expected an exception');
    } on MediaHostException catch (e) {
      expect(e.message, startsWith('Neither media host could store the file. Litterbox couldn'));
      expect(e.message, contains('The fallback, My bucket: Your bucket refused'));
      expect(e.temporary, isTrue);
      expect(e.toPublishError().kind, PublishErrorKind.network);
    }
    expect(reports, isEmpty);
  });

  test('two settings problems are not retryable', () async {
    main.failWith = const MediaHostException('Fill in "Bucket" in the media host settings', hostId: 'litterbox');
    backup.failWith = const MediaHostException('Your bucket refused to store the file: it answered HTTP 403 (Forbidden).', hostId: 's3');
    await expectLater(host.upload(fakeImage(), bytes), throwsA(isA<MediaHostException>().having((e) => e.temporary, 'temporary', isFalse)));
  });

  test('other exceptions from the main host also move on to the fallback', () async {
    main.failWith = const FormatException('unexpected answer');
    final h = await host.upload(fakeImage(), bytes);
    expect(h.url.host, 's3.example.test');
    expect(reports.single, contains('unexpected answer'));
  });

  test('a file the fallback cannot take either keeps the main host\'s error', () async {
    final tiny = FallbackMediaHost(_Host('litterbox', 'Litterbox', failWith: _outage), _Host('s3', 'Tiny', maxBytes: 10));
    await expectLater(tiny.upload(fakeImage(), bytes), throwsA(same(_outage)));
  });

  test('looks like the main host to adapters; verify tests both', () async {
    expect(host.id, 'litterbox');
    expect(host.name, 'Litterbox');
    await host.verify();
    expect(main.verified, 1);
    expect(backup.verified, 1);
    expect(host.verifiedMessage, 'Connection works Fallback: Connection works');
  });
}
