// A lost answer on a request that makes a post: the post may be live, so it is
// reported as what it is and nothing posts it again by itself.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/blogs_a/wordpress_adapter.dart';
import 'package:neforum_core/src/adapters/bluesky/bluesky_adapter.dart';
import 'package:neforum_core/src/adapters/chat/discord_adapter.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_adapter.dart';
import 'package:neforum_core/src/adapters/tiktok/tiktok_adapter.dart';
import 'package:neforum_core/src/adapters/youtube/youtube_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

const _keys = {'client_id': 'c', 'client_secret': 's', 'access_token': 't', 'token_type': 'Bearer'};
const _mastodonConfig = <String, dynamic>{
  'instance': 'https://mastodon.example',
  'domain': 'mastodon.example',
  'software': 'mastodon',
  'maxCharacters': 500,
  'maxMediaAttachments': 4,
  'descriptionLimit': 1500,
};

class _Recorder implements CreateRecorder {
  final marks = <String>[];

  @override
  Future<void> begin() async => marks.add('begin');

  @override
  Future<void> end({required bool mayBeLive}) async => marks.add(mayBeLive ? 'end live' : 'end refused');
}

/// Takes [readPieces] pieces of the body (all of it when null), then holds the request
/// until it is aborted.
class _Holding extends http.BaseClient {
  _Holding({this.readPieces, required this.onHeld});

  final int? readPieces;
  final void Function() onHeld;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final hold = readPieces;
    final body = request.finalize();
    if (hold == null) {
      await body.drain<void>();
    } else {
      await body.take(hold).drain<void>();
    }
    onHeld();
    final trigger = request is http.Abortable ? request.abortTrigger : null;
    await trigger;
    throw http.RequestAbortedException(request.url);
  }
}

/// A network with one post call, whose failure the test chooses.
class _Net extends PlatformAdapter {
  int calls = 0;
  Future<Object?> Function()? call;
  PublishJournal? journal;
  Map<String, PublishJournalEntry>? seenDuringCall;
  final _name = 'Net';

  @override
  SignInPolicy signInPolicyFor(ConnectedAccount account) => SignInPolicy.noConnection;

  @override
  PlatformDescriptor get descriptor => PlatformDescriptor(
        id: 'net',
        name: _name,
        tiers: const {PlatformTier.openApi},
        defaultTier: PlatformTier.openApi,
        text: const TextRules(maxLength: 500),
        media: const MediaRules(maxImages: 4),
        accountRequirements: '',
        apiCostSummary: '',
        serverSideScheduling: true,
      );

  @override
  List<ConnectSpec> get connectSpecs => const [];

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) => throw UnimplementedError();

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    await ctx.creating('Posting', () async {
      calls++;
      seenDuringCall = await journal?.entries();
      await call?.call();
    });
    final at = variant.scheduledAt;
    return at != null ? PublishResult.scheduled(remoteId: 'held', scheduledFor: at) : PublishResult.ok(remoteId: 'post-$calls');
  }
}

void main() {
  group('AdapterContext.creating', () {
    final recorder = _Recorder();
    setUp(recorder.marks.clear);
    AdapterContext ctx({void Function(ProgressEvent)? onEvent, CancellationSignal? cancellation, PublishPauseSignal? pause}) => AdapterContext(
          http: NeforumHttp(client: MockClient((_) async => http.Response('', 200))),
          networkName: 'Net',
          createRecorder: recorder,
          onEvent: onEvent,
          cancellation: cancellation,
          pause: pause,
        );

    test('a lost answer: not retryable, says what to do, keeps the system\'s words for the details box', () async {
      final e = await ctx().creating('Posting', () async => throw http.ClientException('Connection closed before full header was received')).then<AdapterException>((_) => fail('should throw'), onError: (Object e) => e as AdapterException);
      expect(e.error.outcomeUnknown, isTrue);
      expect(e.error.retryable, isFalse);
      expect(e.error.kind, PublishErrorKind.network);
      expect(e.error.message, 'NEFORUM could not confirm this. Check Net before retrying.');
      expect(e.error.raw, contains('Connection closed'));
      expect(recorder.marks, ['begin', 'end live']);
    });

    test('a timeout with no answer is the same', () async {
      final e = await ctx().creating('Posting', () async => throw TimeoutException('late')).then<AdapterException>((_) => fail('should throw'), onError: (Object e) => e as AdapterException);
      expect(e.error.outcomeUnknown, isTrue);
    });

    test('an answer is an answer: a refusal stays what it is', () async {
      final refused = HttpFailure(NeforumResponse(422, const {}, Uint8List(0), Uri.parse('https://x.test/')));
      await expectLater(ctx().creating('Posting', () async => throw refused), throwsA(same(refused)));
      expect(recorder.marks, ['begin', 'end refused']);
    });

    test('a response with an error status counts as refused, not as posted', () async {
      final events = <ProgressEvent>[];
      final r = NeforumResponse(500, const {}, Uint8List(0), Uri.parse('https://x.test/'));
      await ctx(onEvent: events.add).creating('Posting', () async => r);
      expect(recorder.marks, ['begin', 'end refused']);
      expect(events.where((e) => e.stepDone != null), isEmpty);
    });

    test('a request that never got out is an ordinary failure: nothing can be live', () async {
      const offline = SocketException('Failed host lookup', osError: OSError('No such host', 11001));
      await expectLater(ctx().creating('Posting', () async => throw offline), throwsA(same(offline)));
      const refused = SocketException('Connection refused', osError: OSError('refused', 10061));
      await expectLater(ctx().creating('Posting', () async => throw refused), throwsA(same(refused)));
      expect(recorder.marks.where((m) => m == 'end live'), isEmpty);
    });

    test('the same through the real client: the words and the flag', () async {
      final net = NeforumHttp(client: MockClient((_) async => throw const SocketException('Failed host lookup', osError: OSError('x', 11001))), maxRetries: 0);
      final c = AdapterContext(http: net, networkName: 'Net');
      await expectLater(c.creating('Posting', () => c.http.postJson(Uri.parse('https://x.test/'), {})), throwsA(isA<ConnectionFailed>().having((e) => e.neverSent, 'neverSent', isTrue)));
    });

    test('a write that fails on a live connection may have reached the server', () async {
      const reset = SocketException('Write failed', osError: OSError('reset', 10054));
      final e = await ctx().creating('Posting', () async => throw reset).then<AdapterException>((_) => fail('should throw'), onError: (Object e) => e as AdapterException);
      expect(e.error.outcomeUnknown, isTrue);
    });

    test('with a real dedupe key the error goes on as it is', () async {
      final lost = http.ClientException('Connection closed');
      await expectLater(ctx().creating('Posting', () async => throw lost, idempotent: true), throwsA(same(lost)));
    });

    test('anything that is not the network stays a bug', () async {
      await expectLater(ctx().creating('Posting', () async => throw StateError('bug')), throwsStateError);
    });

    test('Cancel during the request: the post may be live, so it says so', () async {
      final signal = CancellationSignal();
      final e = await ctx(cancellation: signal).creating('Posting', () async {
        signal.cancel();
        throw const OperationCancelledException();
      }).then<AdapterException>((_) => fail('should throw'), onError: (Object e) => e as AdapterException);
      expect(e.error.kind, PublishErrorKind.cancelled);
      expect(e.error.outcomeUnknown, isTrue);
    });

    group('Cancel during an upload that is the post', () {
      Future<Object?> cancelAfter(http.Client client, CancellationSignal signal) async {
        final c = AdapterContext(http: NeforumHttp(client: client, maxRetries: 0), networkName: 'Net', createRecorder: recorder, cancellation: signal);
        return c
            .creating('Uploading', () => c.http.putBytes(Uri.parse('https://x.test/'), Uint8List(256 * 1024), method: 'POST'), uploads: true)
            .then<Object?>((v) => v, onError: (Object e) => e);
      }

      test('with its body only partly sent: nothing can be live, so it is a plain cancel', () async {
        final signal = CancellationSignal();
        final e = await cancelAfter(_Holding(readPieces: 2, onHeld: signal.cancel), signal);
        expect(e, isA<OperationCancelledException>().having((c) => c.notSent, 'notSent', isTrue));
        expect(recorder.marks, ['begin', 'end refused']);
      });

      test('with its whole body sent: the post may be live, so it says so', () async {
        final signal = CancellationSignal();
        final e = await cancelAfter(_Holding(onHeld: signal.cancel), signal);
        expect(e, isA<AdapterException>().having((x) => x.error.outcomeUnknown, 'outcomeUnknown', isTrue));
        expect((e as AdapterException).error.kind, PublishErrorKind.cancelled);
        expect(recorder.marks, ['begin', 'end live']);
      });
    });

    test('Cancel before it starts: no request, nothing unknown', () async {
      final signal = CancellationSignal()..cancel();
      var called = false;
      await expectLater(ctx(cancellation: signal).creating('Posting', () async => called = true), throwsA(isA<OperationCancelledException>()));
      expect(called, isFalse);
      expect(recorder.marks, isEmpty);
    });

    test('the mark goes down before the request goes out', () async {
      await ctx().creating('Posting', () async => recorder.marks.add('call'));
      expect(recorder.marks, ['begin', 'call', 'end live']);
    });

    test('a pause blocks a new call, not a running upload, and resuming lets it go', () async {
      final pause = PublishPauseSignal()..pause();
      final c = ctx(pause: pause);
      var called = false;
      final run = c.creating('Posting', () async => called = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(called, isFalse);
      expect(recorder.marks, isEmpty, reason: 'not even on record as under way');
      pause.resume();
      await run;
      expect(called, isTrue);
    });

    test('Cancel ends a pause', () async {
      final pause = PublishPauseSignal()..pause();
      final signal = CancellationSignal();
      var called = false;
      final run = ctx(pause: pause, cancellation: signal).creating('Posting', () async => called = true);
      signal.cancel();
      await expectLater(run, throwsA(isA<OperationCancelledException>()));
      expect(called, isFalse);
    });

    test('an upload that is the post keeps counting its bytes', () async {
      final events = <ProgressEvent>[];
      final c = AdapterContext(http: NeforumHttp(client: MockClient((_) async => http.Response('', 200))), onEvent: events.add);
      c.uploading(fakeImage(), 'Uploading');
      await c.creating('Uploading', () => c.http.putBytes(Uri.parse('https://x.test/'), Uint8List(100), method: 'POST'), uploads: true);
      expect(events.map((e) => e.stage), contains(ProgressStage.uploading));
      final counted = events.where((e) => e.position != null).single;
      expect((counted.slot, counted.position), ('img1', 100));
      expect(events.last.stage, ProgressStage.posting);
    });

    test('a status after the upload does not count toward the file', () async {
      final events = <ProgressEvent>[];
      final c = AdapterContext(http: NeforumHttp(client: MockClient((_) async => http.Response('', 200))), onEvent: events.add);
      c.uploading(fakeImage(), 'Uploading');
      await c.creating('Posting', () => c.http.putBytes(Uri.parse('https://x.test/'), Uint8List(100), method: 'POST'));
      expect(events.where((e) => e.position != null), isEmpty);
    });
  });

  group('through PublishService', () {
    late InMemoryAccountRepository accounts;
    late InMemoryPostRepository posts;
    late PublishJournal journal;
    late Map<String, Object?> disk;
    late DateTime now;

    PublishService service(PlatformAdapter adapter) => PublishService(
          registry: AdapterRegistry([adapter]),
          accounts: accounts,
          posts: posts,
          secrets: InMemorySecretStore(),
          quota: QuotaTracker(InMemoryQuotaRepository()),
          http: NeforumHttp(client: MockClient((_) async => http.Response('', 500)), maxRetries: 0),
          journal: journal,
          clock: () => now,
          options: const PublishOptions(retryBackoffBase: Duration.zero),
          log: Logger('test', sink: (l, a, m, [e]) {}),
        );

    setUp(() async {
      now = testNow;
      accounts = InMemoryAccountRepository();
      posts = InMemoryPostRepository();
      disk = {};
      journal = PublishJournal(
        read: () async => disk['journal'],
        // Through JSON, as the file is.
        write: (data) async => disk['journal'] = jsonDecode(jsonEncode(data)),
        clock: () => now,
      );
      await accounts.upsert(fakeAccount('net', id: 'a'));
      await posts.upsert(Post(id: 'p1', text: 'Hello', createdAt: testNow, updatedAt: testNow, targets: const [PostTarget(accountId: 'a')]));
    });

    test('a lost answer fails the target, and no later run posts it again', () async {
      final net = _Net()..call = () async => throw http.ClientException('Connection closed');
      final done = await service(net).publish('p1');
      final t = done.targets.single;
      expect(t.status, TargetStatus.failed);
      expect(t.result!.error!.outcomeUnknown, isTrue);
      expect(t.result!.error!.message, 'NEFORUM could not confirm this. Check Net before retrying.');
      expect(net.calls, 1);

      // The scheduler's runs, and a background isolate's.
      now = now.add(const Duration(days: 1));
      await service(net).publish('p1', retryFailed: false, dueTargetsOnly: true);
      await service(net).publish('p1', interactive: false, retryFailed: false, dueTargetsOnly: true);
      expect(net.calls, 1, reason: 'never auto-retried');
    });

    test('compare a failure that proves nothing went out: that one comes back for its retry', () async {
      final net = _Net()..call = () async => throw const SocketException('Failed host lookup', osError: OSError('x', 11001));
      final done = await service(net).publish('p1');
      expect(done.targets.single.status, TargetStatus.pending);
    });

    test('survives a kill: the journal has the mark while the request is under way', () async {
      final net = _Net()..journal = journal;
      await service(net).publish('p1');
      final during = net.seenDuringCall!['p1']!;
      expect(during.inFlightCreate, 'a');
      expect(during.outcomeUnknownAccounts, {'a'});
      expect(await journal.entries(), isEmpty, reason: 'a saved outcome takes the run off the record');
    });

    test('the mark stays through the heartbeat, and in the file it is what the design says', () async {
      await journal.record('p1');
      await journal.beginCreate('p1', 'a');
      await journal.record('p1');
      expect((await journal.entries())['p1']!.inFlightCreate, 'a');
      expect(((disk['journal']! as Map)['p1'] as Map)['inFlightCreate'], {'accountId': 'a'});
    });

    test('a refused answer clears it; a good one stays until the result is saved', () async {
      await journal.record('p1');
      await journal.beginCreate('p1', 'a');
      await journal.endCreate('p1', 'a', mayBeLive: false);
      expect((await journal.entries())['p1']!.outcomeUnknownAccounts, isEmpty);
      await journal.beginCreate('p1', 'a');
      await journal.endCreate('p1', 'a', mayBeLive: true);
      final after = (await journal.entries())['p1']!;
      expect(after.inFlightCreate, isNull);
      expect(after.createdUnsaved, {'a'}, reason: 'a kill here must not read as "not posted"');
      await journal.clearCreate('p1');
      expect((await journal.entries())['p1']!.outcomeUnknownAccounts, isEmpty);
    });

    test('a save that failed and a run that went on: both posts stay on record', () async {
      await journal.record('p1');
      await journal.beginCreate('p1', 'a');
      await journal.endCreate('p1', 'a', mayBeLive: true);
      await journal.beginCreate('p1', 'b');
      await journal.endCreate('p1', 'b', mayBeLive: true);
      await journal.record('p1');
      expect((await journal.entries())['p1']!.outcomeUnknownAccounts, {'a', 'b'}, reason: 'read back through the file');
    });

    test('an older journal entry reads as no mark', () {
      final e = PublishJournalEntry.fromJson('p1', {'owner': 'o', 'startedAt': '2026-01-01T00:00:00Z', 'heartbeatAt': '2026-01-01T00:00:00Z'});
      expect(e.outcomeUnknownAccounts, isEmpty);
      expect(e.toJson().keys, isNot(contains('inFlightCreate')));
    });

    test('Cancel during the request keeps the warning on the cancelled target', () async {
      final signal = CancellationSignal();
      final net = _Net()
        ..call = () async {
          signal.cancel();
          throw const OperationCancelledException();
        };
      final done = await service(net).publish('p1', cancellation: signal);
      final t = done.targets.single;
      expect(t.status, TargetStatus.cancelled);
      expect(t.result!.error!.outcomeUnknown, isTrue);
      expect(t.result!.error!.message, contains('could not confirm'));
    });

    test('a schedule handed over with a lost answer does not also stay on this device', () async {
      final at = testNow.add(const Duration(hours: 2));
      await posts.upsert(Post(id: 'p1', text: 'Hello', createdAt: testNow, updatedAt: testNow, scheduledAt: at, status: PostStatus.scheduled, targets: const [PostTarget(accountId: 'a')]));
      final net = _Net()..call = () async => throw http.ClientException('Connection closed');
      final done = await service(net).delegateSchedules('p1');
      expect(done.targets.single.status, TargetStatus.failed);
      expect(done.targets.single.result!.error!.outcomeUnknown, isTrue);
      expect(done.targets.single.result!.error!.message, contains('Check Net before retrying'));
    });

    test('each finished stage leaves one local line, with its time and bytes and nothing else', () async {
      final lines = <String>[];
      final net = _Net();
      final s = PublishService(
        registry: AdapterRegistry([net]),
        accounts: accounts,
        posts: posts,
        secrets: InMemorySecretStore(),
        quota: QuotaTracker(InMemoryQuotaRepository()),
        http: NeforumHttp(client: MockClient((_) async => http.Response('', 200)), maxRetries: 0),
        clock: () => now,
        log: Logger('test', sink: (l, a, m, [e]) => lines.add(m)),
      );
      await s.publish('p1', onEvent: (_, e) {});
      expect(lines.where((l) => l.startsWith('Stage ')), ['Stage posting: 0 ms, 0 bytes'], reason: 'the renewal is the service\'s own event, not the adapter\'s');
    });

    test('a stage that sent bytes says how many, and how long it took', () async {
      final lines = <String>[];
      var at = testNow;
      final c = AdapterContext(
        http: NeforumHttp(client: MockClient((_) async => http.Response('', 200))),
        clock: () => at,
        log: Logger('t', sink: (l, a, m, [e]) => lines.add(m)),
        onEvent: (_) {},
      );
      c.uploading(fakeImage(), 'Uploading');
      at = at.add(const Duration(seconds: 3));
      await c.http.putBytes(Uri.parse('https://x.test/'), Uint8List(100), method: 'POST');
      c.serverWait('Processing');
      expect(lines, contains('Stage uploading: 3000 ms, 100 bytes'));
      expect(lines.where((l) => l.startsWith('Stage ')), hasLength(1));
    });

    test('a pause holds a run\'s post and lets the rest of the run be', () async {
      final pause = PublishPauseSignal()..pause();
      final net = _Net();
      final run = service(net).publish('p1', pause: pause);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(net.calls, 0);
      pause.resume();
      expect((await run).targets.single.status, TargetStatus.published);
    });
  });

  group('model', () {
    test('omitted from JSON when null, and read back', () {
      const plain = PublishError.network('x');
      expect(plain.toJson().keys, isNot(contains('outcomeUnknown')));
      const unknown = PublishError(kind: PublishErrorKind.network, message: 'm', outcomeUnknown: true);
      expect(PublishError.fromJson(unknown.toJson()).outcomeUnknown, isTrue);
      expect(PublishError.fromJson(plain.toJson()).outcomeUnknown, isNull);
    });

    test('it survives being wrapped for a thread', () {
      const unknown = PublishError(kind: PublishErrorKind.network, message: 'm', outcomeUnknown: true);
      expect(unknown.asResumableThread(postedIds: const ['a'], total: 2).outcomeUnknown, isTrue);
      expect(unknown.asPartialThread(postedIds: const ['a'], total: 2).outcomeUnknown, isTrue);
    });

    test('a kind stays a kind a 1.3.5 device can read', () {
      const unknown = PublishError(kind: PublishErrorKind.network, message: 'm', outcomeUnknown: true);
      expect(PublishErrorKind.values.map((k) => k.name), contains(unknown.toJson()['kind']));
    });
  });

  group('real adapters', () {
    final lost = http.ClientException('Connection closed before full header was received');

    test('Mastodon is exempt: a keyed status sent again is the same post', () async {
      var calls = 0;
      final ctx = testContext(handler: (r) async {
        calls++;
        throw lost;
      });
      final r = await MastodonAdapter(clock: () => testNow).publish(const PostVariant(text: 'x'), fakeAccount('mastodon', config: _mastodonConfig), _keys, ctx).then((v) => v, onError: (Object e) => PublishResult.failure(PublishError.network('$e')));
      expect(calls, 1);
      expect(r.error?.outcomeUnknown, isNot(isTrue));
    });

    test('Mastodon: a keyed thread that loses part 2 can finish, retryable by its key', () async {
      var statuses = 0;
      final ctx = testContext(handler: (r) async {
        statuses++;
        if (statuses == 2) throw lost;
        return http.Response(jsonEncode({'id': 's$statuses', 'url': 'https://m/$statuses'}), 200, headers: jsonHeaders);
      });
      final r = await MastodonAdapter(clock: () => testNow).publish(const PostVariant(text: 'a', threadParts: ['a', 'b']), fakeAccount('mastodon', config: _mastodonConfig), _keys, ctx);
      expect(r.threadRemoteIds, ['s1']);
      expect(r.error?.outcomeUnknown, isNot(isTrue));
    });

    test('Bluesky: a thread keeps its live posts and warns about the lost one', () async {
      var creates = 0;
      final ctx = testContext(handler: (r) async {
        if (r.url.path.endsWith('createRecord')) {
          creates++;
          if (creates == 2) throw lost;
          return http.Response(jsonEncode({'uri': 'at://d/app.bsky.feed.post/$creates', 'cid': 'c$creates'}), 200, headers: jsonHeaders);
        }
        return http.Response('{}', 200, headers: jsonHeaders);
      });
      final account = fakeAccount('bluesky', config: const {'did': 'did:plc:abc', 'pds': 'https://pds.example', 'handle': 'a.example'});
      final r = await BlueskyAdapter().publish(const PostVariant(text: 'a', threadParts: ['a', 'b']), account, const {'access_token': 'x', 'refresh_token': 'y', 'accessJwt': 'x', 'refreshJwt': 'y'}, ctx);
      expect(r.success, isFalse, reason: '${r.error}');
      expect(r.error!.outcomeUnknown, isTrue, reason: '${r.error}');
      expect(r.threadRemoteIds, hasLength(1));
      expect(creates, 2);
    });

    test('Discord: the upload is the message, so a lost answer on it is unknown too', () async {
      var calls = 0;
      final ctx = testContext(handler: (r) async {
        calls++;
        throw lost;
      });
      final account = fakeAccount('discord', tier: PlatformTier.byokApi, config: const {'guildId': 'g', 'channelId': 'c'});
      final r = await DiscordAdapter().publish(PostVariant(text: 'x', media: [fakeImage()]), account, const {'webhook_url': 'https://discord.com/api/webhooks/123456/abcdefghijklmnopqrstuvwxyz'}, ctx);
      expect(r.success, isFalse);
      expect(r.error!.outcomeUnknown, isTrue, reason: '${r.error}');
      expect(calls, 1);
    });

    test('WordPress: through its own error guard', () async {
      final ctx = testContext(handler: (r) async => throw lost);
      final account = fakeAccount('wordpress', config: const {'restBase': 'https://blog.example/wp-json/', 'username': 'u', 'site': 'https://blog.example'});
      final r = await WordPressAdapter().publish(const PostVariant(text: 'x', title: 'T'), account, const {'app_password': 'p', 'username': 'u', 'application_password': 'p'}, ctx);
      expect(r.success, isFalse);
      expect(r.error!.outcomeUnknown, isTrue, reason: '${r.error}');
    });

    group('TikTok, once it has the post', () {
      final account = fakeAccount('tiktok', tier: PlatformTier.byokApi, config: const {'clientKey': 'ck', 'openId': 'o'});
      final keys = {'access_token': 't', 'refresh_token': 'r', 'token_type': 'Bearer', 'expires_at': testNow.add(const Duration(days: 1)).toUtc().toIso8601String()};
      final variant = PostVariant(text: 'x', media: [fakeImage()]);
      http.Response ok(http.Request r) => http.Response(
          jsonEncode({
            'data': {'publish_id': 'pub1', 'privacy_level_options': ['SELF_ONLY'], 'creator_username': 'u'},
            'error': {'code': 'ok'},
          }),
          200,
          headers: jsonHeaders);
      bool isStatus(http.Request r) => r.url.path.contains('/status/fetch');

      test('a status it cannot read is unknown, not a failure to retry', () async {
        final ctx = testContext(mediaHost: FakeMediaHost(), handler: (r) async => isStatus(r) ? throw lost : ok(r));
        final r = await TikTokAdapter(pollInterval: Duration.zero).publish(variant, account, keys, ctx);
        expect(r.error!.outcomeUnknown, isTrue, reason: '${r.error}');
        expect(r.error!.retryable, isFalse);
      });

      test('a status refused by the server is unknown too: the post is still made', () async {
        final ctx = testContext(mediaHost: FakeMediaHost(), handler: (r) async => isStatus(r) ? http.Response('{}', 503, headers: jsonHeaders) : ok(r));
        final r = await TikTokAdapter(pollInterval: Duration.zero).publish(variant, account, keys, ctx);
        expect(r.error!.outcomeUnknown, isTrue, reason: '${r.error}');
        expect(r.error!.retryable, isFalse);
      });

      test('a real FAILED from TikTok stays what it is', () async {
        final ctx = testContext(
          mediaHost: FakeMediaHost(),
          handler: (r) async => isStatus(r)
              ? http.Response(jsonEncode({'data': {'status': 'FAILED', 'fail_reason': 'file_format_check_failed'}, 'error': {'code': 'ok'}}), 200, headers: jsonHeaders)
              : ok(r),
        );
        final r = await TikTokAdapter(pollInterval: Duration.zero).publish(variant, account, keys, ctx);
        expect(r.error!.outcomeUnknown, isNot(isTrue), reason: '${r.error}');
      });

      test('Cancel during the wait says the post may be live', () async {
        final signal = CancellationSignal();
        final ctx = AdapterContext(
          http: NeforumHttp(client: MockClient((r) async => ok(r)), maxRetries: 0),
          mediaHost: FakeMediaHost(),
          clock: () => testNow,
          readMedia: (_) async => fakeJpegBytes,
          cancellation: signal,
          networkName: 'TikTok',
          onEvent: (e) {
            if (e.stage == ProgressStage.serverProcessing) signal.cancel();
          },
        );
        final r = await TikTokAdapter(pollInterval: const Duration(minutes: 1)).publish(variant, account, keys, ctx).timeout(const Duration(seconds: 1));
        expect(r.error!.kind, PublishErrorKind.cancelled);
        expect(r.error!.outcomeUnknown, isTrue);
      });
    });

    test('YouTube: a lost answer it could not ask about is unknown, one it could ask about is not', () async {
      final account = fakeAccount('youtube', tier: PlatformTier.byokApi, config: const {'clientId': 'c'});
      const keys = {'access_token': 'a', 'token_type': 'Bearer'};
      final variant = PostVariant(text: 'x', title: 'T', media: [fakeVideo()]);
      final never = testContext(handler: (r) async {
        if (r.method == 'POST') return http.Response('', 200, headers: {'location': 'https://upload.example/s'});
        throw lost;
      });
      final unknown = await YouTubeAdapter(resumeDelay: Duration.zero).publish(variant, account, keys, never);
      expect(unknown.error!.outcomeUnknown, isTrue, reason: '${unknown.error}');

      var puts = 0;
      final asked = testContext(handler: (r) async {
        if (r.method == 'POST') return http.Response('', 200, headers: {'location': 'https://upload.example/s'});
        puts++;
        if (puts == 1) throw lost;
        return http.Response(jsonEncode({'id': 'v1', 'status': {'privacyStatus': 'public'}}), 200, headers: jsonHeaders);
      });
      final fine = await YouTubeAdapter(resumeDelay: Duration.zero).publish(variant, account, keys, asked);
      expect(fine.success, isTrue, reason: '${fine.error}');
      expect(fine.remoteId, 'v1');
    });
  });
}
