// Cancel used to leave the sheet on "Cancelling..." until a media host finished its
// file or a poll finished its sleep. Both now stop within a second.

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/instagram/instagram_api.dart';
import 'package:neforum_core/src/adapters/threads/threads_api.dart';
import 'package:neforum_core/src/adapters/youtube/youtube_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

/// Holds every request until it is aborted.
class _HangingClient extends http.BaseClient {
  final aborted = <Uri>[];
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    final trigger = request is http.Abortable ? request.abortTrigger : null;
    if (trigger == null) return Completer<http.StreamedResponse>().future;
    await trigger;
    aborted.add(request.url);
    throw http.RequestAbortedException(request.url);
  }
}

/// Answers each request with what the test says.
class _Answering extends http.BaseClient {
  _Answering(this.answer);

  final http.StreamedResponse Function(http.BaseRequest r) answer;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async => answer(request);
}

http.StreamedResponse _status(int code, [String body = '{}']) => http.StreamedResponse(Stream.value(body.codeUnits), code, headers: jsonHeaders);

/// Runs [work], cancels it after a moment, and returns how long Cancel took to end it
/// and what it ended with.
Future<(Duration, Object?)> _cancelled(CancellationSignal signal, Future<Object?> Function() work) async {
  final done = Completer<Object?>();
  unawaited(work().then(done.complete, onError: (Object e) => done.complete(e)));
  await Future<void>.delayed(const Duration(milliseconds: 50));
  expect(done.isCompleted, isFalse, reason: 'it was still going when Cancel came');
  final clock = Stopwatch()..start();
  signal.cancel();
  final outcome = await done.future.timeout(const Duration(seconds: 5), onTimeout: () => 'still going after 5 s');
  return (clock.elapsed, outcome);
}

const _second = Duration(seconds: 1);

void main() {
  final bytes = Uint8List(100 * 1024);
  final file = fakeImage(sizeBytes: bytes.length);

  group('a media host upload', () {
    late _HangingClient hanging;
    late CancellationSignal signal;
    late AdapterContext ctx;

    setUp(() {
      hanging = _HangingClient();
      signal = CancellationSignal();
      ctx = AdapterContext(http: NeforumHttp(client: hanging), cancellation: signal);
    });

    Future<void> check(MediaHost host) async {
      final (took, outcome) = await _cancelled(signal, () => host.upload(file, bytes, via: ctx.http));
      expect(took, lessThan(_second));
      expect(outcome, isA<OperationCancelledException>());
      expect(hanging.requests, 1, reason: 'and it did not try again');
    }

    // The host's own client must not be what sends: it knows nothing of the run.
    final unused = NeforumHttp(client: _Answering((_) => throw StateError('the run\'s client must be used')));

    test('Catbox', () => check(CatboxMediaHost.catbox(http: unused)));

    test('S3', () => check(S3CompatibleMediaHost(http: unused, endpoint: Uri.parse('https://s3.example'), bucket: 'b', region: 'r', accessKeyId: 'k', secretAccessKey: 's', publicBaseUrl: Uri.parse('https://cdn.example'))));

    test('WebDAV', () => check(WebDavMediaHost(http: unused, folderUrl: Uri.parse('https://dav.example/f/'), username: 'u', password: 'p', publicUrlTemplate: 'https://dav.example/{name}')));

    test('a fallback host is not tried: the person stopped the run', () async {
      var fallbackUsed = false;
      final host = FallbackMediaHost(
        CatboxMediaHost.catbox(http: unused),
        _RecordingHost(() => fallbackUsed = true),
      );
      final (took, outcome) = await _cancelled(signal, () => host.upload(file, bytes, via: ctx.http));
      expect(took, lessThan(_second));
      expect(outcome, isA<OperationCancelledException>());
      expect(fallbackUsed, isFalse);
    });

    test('the pause before its one retry ends too', () async {
      final answering = _Answering((_) => _status(500));
      final signal = CancellationSignal();
      final c = AdapterContext(http: NeforumHttp(client: answering, maxRetries: 0), cancellation: signal);
      final (took, outcome) = await _cancelled(signal, () => CatboxMediaHost.catbox(http: unused).upload(file, bytes, via: c.http));
      expect(took, lessThan(_second), reason: 'the pause is 3 s');
      expect(outcome, isA<OperationCancelledException>());
    });

    test('bytes through a host are counted', () async {
      final events = <ProgressEvent>[];
      final c = AdapterContext(http: NeforumHttp(client: _Answering((r) {
        r.finalize().drain<void>();
        return http.StreamedResponse(Stream.value('https://files.catbox.moe/x.jpg'.codeUnits), 200);
      })), onEvent: events.add);
      c.uploading(file, 'Uploading');
      await CatboxMediaHost.catbox(http: unused).upload(file, bytes, via: c.http);
      final counted = events.where((e) => e.position != null).toList();
      expect(counted, isNotEmpty);
      expect(counted.last.slot, file.id);
      expect(counted.last.confirmed, isTrue);
    });

    test('without [via] a host uses its own client, as Settings does', () async {
      var used = false;
      final own = NeforumHttp(client: _Answering((r) {
        used = true;
        r.finalize().drain<void>();
        return http.StreamedResponse(Stream.value('https://files.catbox.moe/x.jpg'.codeUnits), 200);
      }));
      await CatboxMediaHost.catbox(http: own).upload(file, bytes);
      expect(used, isTrue);
    });
  });

  group('a poll sleep', () {
    test('ctx.wait ends at once, with no signal it just sleeps', () async {
      final signal = CancellationSignal();
      final ctx = AdapterContext(http: NeforumHttp(client: _HangingClient()), cancellation: signal);
      final (took, outcome) = await _cancelled(signal, () => ctx.wait(const Duration(minutes: 1)));
      expect(took, lessThan(_second));
      expect(outcome, isA<OperationCancelledException>());

      var slept = false;
      await AdapterContext(http: NeforumHttp(client: _HangingClient())).wait(const Duration(minutes: 1), via: (_) async => slept = true);
      expect(slept, isTrue);
    });

    test('a wait counts the request that follows it', () async {
      final events = <ProgressEvent>[];
      final ctx = AdapterContext(http: NeforumHttp(client: _HangingClient()), onEvent: events.add);
      ctx.serverWait('Processing');
      await ctx.wait(Duration.zero);
      await ctx.wait(Duration.zero);
      expect(events.last.waitPolls, 2);
      ctx.posted(1, 1, 'Posted');
      ctx.serverWait('Processing again');
      expect(events.last.waitPolls, 0, reason: 'a new wait counts from nothing');
    });

    test('Threads, a 60 s wait for its container', () async {
      final signal = CancellationSignal();
      final ctx = AdapterContext(http: NeforumHttp(client: _Answering((_) => _status(200, '{"status":"IN_PROGRESS"}'))), cancellation: signal);
      final api = ThreadsApi(ctx.http, 't', delay: (d) => ctx.wait(d));
      final (took, outcome) = await _cancelled(signal, () => api.waitUntilReady('c1', delays: const [Duration(seconds: 60)]));
      expect(took, lessThan(_second));
      expect(outcome, isA<OperationCancelledException>());
    });

    test('Instagram, a 60 s wait for its container', () async {
      final signal = CancellationSignal();
      final ctx = AdapterContext(http: NeforumHttp(client: _Answering((_) => _status(200, '{"status_code":"IN_PROGRESS"}'))), cancellation: signal);
      final api = InstagramApi(ctx, sleep: Future<void>.delayed, pollSchedule: const [Duration(seconds: 60)]);
      final (took, outcome) = await _cancelled(signal, () => api.waitUntilFinished('c1', 't'));
      expect(took, lessThan(_second));
      expect(outcome, isA<OperationCancelledException>());
    });

    test('YouTube, its wait before a resume', () async {
      final signal = CancellationSignal();
      var first = true;
      final ctx = AdapterContext(
        http: NeforumHttp(
            client: _Answering((r) {
              if (r.method == 'POST') return http.StreamedResponse(const Stream.empty(), 200, headers: {'location': 'https://upload.example/s'});
              if (first) {
                first = false;
                throw http.ClientException('Connection closed');
              }
              return _status(200);
            }),
            maxRetries: 0),
        cancellation: signal,
      );
      final upload = YouTubeResumableUpload(ctx: ctx, accessToken: 't', maxResumes: 3, resumeDelay: const Duration(minutes: 1));
      final (took, outcome) = await _cancelled(signal, () => upload.upload(metadata: const {}, bytes: Uint8List(10), mimeType: 'video/mp4'));
      expect(took, lessThan(_second));
      expect(outcome, isA<OperationCancelledException>());
    });
  });
}

class _RecordingHost extends FakeMediaHost {
  _RecordingHost(this.onUse);
  final void Function() onUse;

  @override
  Future<HostedMedia> upload(MediaAttachment media, Uint8List bytes, {Duration? ttl, NeforumHttp? via}) {
    onUse();
    return super.upload(media, bytes, ttl: ttl, via: via);
  }
}
