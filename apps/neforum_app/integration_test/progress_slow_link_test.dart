// Upload progress on a slow link, through a compiled build: is the bar honest?
//
//   flutter drive --profile -d windows --driver=test_driver/integration_test.dart --target=integration_test/progress_slow_link_test.dart
//
// A Mastodon server on this computer (127.0.0.1, a free port) reads the 3 MiB
// upload about as fast as a 1 Mbit/s uplink delivers it: 16 KiB, then 125 ms. It
// records, with times, how many body bytes it has taken. The post goes through
// the real Mastodon adapter, the real NeforumHttp and PublishService, into the
// app's own publishProgressProvider tracker, and the real progress sheet shows
// it. Nothing leaves this computer; the workspace is a throwaway demo one.
//
// What it holds the screen to (docs/design/publish-progress.md, DESIGN-14 D3):
// only bytes the server confirmed move a number.
// * the post's figure never falls;
// * it stays under 100% until the server has answered the status POST;
// * while uploading it is never more than [_marginPermille] ahead of the share
//   of the body the SERVER has (not the share handed to the connection);
// * while bytes are only handed to the connection (no confirmed position), the
//   row shows no number, its words say it is sending and never that the server
//   has the file, and the post's figure does not move;
// * a stage that cannot be measured (reading, the server's wait, posting) shows
//   no number on the row, and the post's figure does not move during the wait;
// * a time left shows only beside a speed measured from confirmed positions, and
//   no sooner than two 10 s meter windows after the first one.
//
// Locally, the runner's single-instance mutex stops this from starting while a
// NEFORUM is open: in a copy of the repo, under a short path, rename it in
// windows/runner/main.cpp to L"Local\\org.neforum.NEFORUM.integration" first.

// Run output is the evidence, so it prints. Fields, never objects: profile
// builds minify toString.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/publish_progress_sheet.dart';
import 'package:neforum_app/widgets/publish_progress.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// The photo: 3 MiB, JPEG-tagged, incompressible.
const int _fileBytes = 3 * 1024 * 1024;

/// The server takes this much of the body at a time...
const int _piece = 16 * 1024;

/// ...then waits this long: 16 KiB per 125 ms is 128 KiB/s, about 1 Mbit/s.
const Duration _pieceGap = Duration(milliseconds: 125);

/// Polls of the media that answer 206 (still processing) before the 200.
const int _processingPolls = 2;

/// How far the post's figure may run ahead of what the server has, in permille:
/// 1.0 point. Only confirmed bytes move the figure, and the server confirms
/// only what it read, so the model allows 0. The one point is slack for the
/// test's own sampling (the server's count and the screen are read at slightly
/// different moments), not for the bar.
const int _marginPermille = 10;

/// The meter's window (RateMeter's default). A time left needs two in a row.
const Duration _meterWindow = Duration(seconds: 10);

/// Far longer than the run takes (about 35 s); a hang fails the test.
const Duration _limit = Duration(minutes: 4);

/// The Mastodon API calls one post with one photo makes, read slowly.
class _SlowMastodon {
  _SlowMastodon(this.clock);

  final Stopwatch clock;
  final List<String> log = [];
  final List<(int ms, int bytes)> received = [];
  HttpServer? _server;

  int contentLength = -1;
  int bodyBytes = 0;
  int mediaPosts = 0;
  int statusPosts = 0;
  int polls = 0;
  int? statusAnsweredMs;
  final List<String> unexpected = [];

  int get port => _server!.port;
  bool get statusAnswered => statusAnsweredMs != null;

  /// Permille of the media body the server has taken.
  int get permille => contentLength <= 0 ? 0 : bodyBytes * 1000 ~/ contentLength;

  void _note(String line) {
    final text = '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(3)}s server $line';
    log.add(text);
    print(text);
  }

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(server.forEach(_answer));
  }

  Future<void> stop() async => _server?.close(force: true);

  Future<void> _answer(HttpRequest r) async {
    final path = r.uri.path;
    if (r.method == 'POST' && path == '/api/v2/media') {
      mediaPosts++;
      contentLength = r.contentLength;
      bodyBytes = 0;
      _note('media POST begins, Content-Length $contentLength');
      // Read the body the way a slow uplink delivers it: a piece, then a pause.
      await for (final chunk in r) {
        for (var start = 0; start < chunk.length; start += _piece) {
          final end = math.min(start + _piece, chunk.length);
          bodyBytes += end - start;
          received.add((clock.elapsedMilliseconds, bodyBytes));
          await Future<void>.delayed(_pieceGap);
        }
      }
      _note('media body complete, $bodyBytes bytes; answering 202 (processing)');
      return _json(r, 202, const {'id': 'm1', 'type': 'image', 'url': null});
    }
    if (r.method == 'GET' && path == '/api/v1/media/m1') {
      await r.drain<void>();
      polls++;
      if (polls <= _processingPolls) {
        _note('media poll $polls: 206');
        return _json(r, 206, const {'id': 'm1', 'type': 'image', 'url': null});
      }
      _note('media poll $polls: 200');
      return _json(r, 200, const {'id': 'm1', 'type': 'image', 'url': 'http://127.0.0.1/m1.jpg'});
    }
    if (r.method == 'POST' && path == '/api/v1/statuses') {
      await r.drain<void>();
      statusPosts++;
      // Before the answer is written: the client cannot know of it any sooner.
      statusAnsweredMs = clock.elapsedMilliseconds;
      _note('status POST $statusPosts answered 200');
      return _json(r, 200, {'id': 's$statusPosts', 'url': 'http://127.0.0.1/@probe/s$statusPosts', 'uri': 'http://127.0.0.1/statuses/s$statusPosts'});
    }
    await r.drain<void>();
    unexpected.add('${r.method} $path');
    _note('unexpected ${r.method} $path: 404');
    return _json(r, 404, const {'error': 'Not found'});
  }

  Future<void> _json(HttpRequest r, int status, Map<String, Object?> body) async {
    r.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await r.response.close();
  }
}

/// One look at the run, from the tracker (every published figure) or from the
/// screen (one frame).
class _Sample {
  _Sample({
    required this.ms,
    required this.source,
    required this.serverBytes,
    required this.serverPermille,
    required this.statusAnswered,
    required this.postPermille,
    required this.stage,
    required this.targetPermille,
    required this.position,
    required this.confirmedPosition,
    required this.slotTotal,
    required this.etaSeconds,
    required this.bytesPerSecond,
    required this.outcome,
    this.postText,
    this.postBar,
    this.rowLine,
    this.rowPercent,
  });

  final int ms;

  /// 'tracker' or 'screen'.
  final String source;
  final int serverBytes;
  final int serverPermille;
  final bool statusAnswered;
  final int? postPermille;
  final String stage;
  final int? targetPermille;
  final int? position;
  final int? confirmedPosition;
  final int? slotTotal;
  final int? etaSeconds;
  final int? bytesPerSecond;
  final String? outcome;
  final String? postText;
  final double? postBar;
  final String? rowLine;
  final String? rowPercent;

  /// The media POST has no answer yet: the upload stage, whatever the count says.
  /// A count that reached the total early does not end the upload for the server.
  bool get uploading => stage == ProgressStage.uploading.name && outcome == null;

  /// Bytes are on the way and the server has confirmed none of them: the row
  /// has words and elapsed time, no number.
  bool get handedOnly => uploading && position != null && (confirmedPosition ?? 0) <= 0;

  /// The server confirmed part of the open upload: the one time in the upload
  /// the row may show a number.
  bool get confirmedSome => uploading && (confirmedPosition ?? 0) > 0;

  /// Permille of the body handed to the connection.
  int? get sentPermille => position == null || slotTotal == null || slotTotal! <= 0 ? null : position! * 1000 ~/ slotTotal!;

  /// Permille of the body the server confirmed to the client.
  int? get confirmedPermille => confirmedPosition == null || slotTotal == null || slotTotal! <= 0 ? null : confirmedPosition! * 1000 ~/ slotTotal!;
}

String _pct(int? permille) => permille == null ? '-' : '${permille ~/ 10}.${permille % 10}%';

String _row(_Sample s) => [
      (s.ms / 1000).toStringAsFixed(1).padLeft(6),
      '${s.serverBytes}'.padLeft(8),
      _pct(s.serverPermille).padLeft(6),
      _pct(s.sentPermille).padLeft(6),
      _pct(s.confirmedPermille).padLeft(6),
      '${s.position == null ? '-' : ((s.position! - s.serverBytes) ~/ 1024)}'.padLeft(6),
      (s.postText ?? '-').padLeft(5),
      _pct(s.postPermille).padLeft(6),
      (s.rowPercent ?? '-').padLeft(5),
      (s.etaSeconds == null ? '-' : '${s.etaSeconds}s').padLeft(5),
      s.outcome ?? s.stage,
      s.rowLine ?? '',
    ].join(' | ');

/// t: seconds since the test began. server: body bytes the server has taken.
/// srv: its share of the body. sent: share handed to the connection. conf:
/// share the server confirmed to the client. ahead: KiB handed over that the
/// server has not taken. shown: the post's number on screen ('-' for a tracker
/// row). post: the tracker's figure. row: the network row's number on screen.
/// ETA: the tracker's time left.
const String _header = '     t |   server |    srv |   sent |   conf |  ahead | shown |   post |   row |   ETA | stage | row line';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a 3 MiB photo to Mastodon at 1 Mbit/s: the bar never claims more than the server has', (tester) async {
    final clock = Stopwatch()..start();
    final dir = await Directory.systemTemp.createTemp('neforum-slow-link-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file open; the OS cleans temp later.
      }
    });

    final server = _SlowMastodon(clock);
    await server.start();
    addTearDown(server.stop);
    print('fake Mastodon on 127.0.0.1:${server.port}');

    // A throwaway demo workspace: in-memory accounts, posts and keys. Only the
    // registry differs from the app's publisher(): the demo's adapters are
    // pretend ones, so the real Mastodon adapter is used here.
    final storage = await openAppStorage(overrideDir: dir.path);
    final services = await AppServices.create(demo: true, storage: storage);
    final mastodon = builtinRegistry().byId('mastodon') ?? fail('no Mastodon adapter');
    final host = '127.0.0.1:${server.port}';
    final now = DateTime.now();
    final account = ConnectedAccount(
      id: 'slow-link-mastodon',
      platformId: 'mastodon',
      tier: PlatformTier.openApi,
      displayName: 'Slow link',
      createdAt: now,
      config: {
        'instance': 'http://$host',
        'domain': host,
        'software': 'mastodon',
        'maxCharacters': 500,
        'maxMediaAttachments': 4,
        'descriptionLimit': 1500,
      },
    );
    await services.accounts.upsert(account);
    await services.secrets.write(account.id, const {'client_id': 'c', 'client_secret': 's', 'access_token': 't', 'token_type': 'Bearer'});
    final photo = MediaAttachment(
      id: 'slow-photo',
      path: 'mem://slow-photo',
      mimeType: 'image/jpeg',
      sizeBytes: _fileBytes,
      width: 1600,
      height: 1200,
      altText: 'A test photo',
      fileName: 'slow.jpg',
    );
    final bytes = Uint8List(_fileBytes);
    final random = math.Random(14);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    bytes.setAll(0, const [0xFF, 0xD8, 0xFF, 0xE0]);
    const postId = 'slow-link-post';
    await services.posts.upsert(Post(
      id: postId,
      text: 'Slow link probe',
      media: [photo],
      targets: [PostTarget(accountId: account.id)],
      createdAt: now,
      updatedAt: now,
    ));
    // The client's and the adapter's own log lines, timed, beside the server's.
    void sink(LogLevel level, String area, String message, [Object? error]) =>
        print('${(clock.elapsedMilliseconds / 1000).toStringAsFixed(3)}s $area ${level.name} $message');
    final net = NeforumHttp(log: Logger('http', sink: sink));
    addTearDown(net.close);
    final publisher = PublishService(
      registry: AdapterRegistry([mastodon]),
      accounts: services.accounts,
      posts: services.posts,
      secrets: services.secrets,
      quota: services.quota,
      http: net,
      resolver: VariantResolver(services.settings.resolverOptions),
      options: services.settings.publishOptions,
      journal: services.publishJournal,
      signInOutcomes: services.signInStatus,
      log: Logger('publish', sink: sink),
      readMedia: (m) async => m.id == photo.id ? bytes : fail('unexpected read of ${m.id}'),
    );

    // The sheet the person sees, as the composer opens it.
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => showPublishProgress(context), child: const Text('open')))),
      ),
    ));
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.text('open')));
    container.read(publishRunProvider.notifier).start(postId, [account.id]);
    final figures = container.read(publishProgressProvider.notifier);
    final tracker = figures.begin(postId);
    unawaited(showPublishProgress(tester.element(find.text('open'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final samples = <_Sample>[];
    _Sample sampleOf(String source, PostProgress? p, {String? postText, double? postBar, String? rowLine, String? rowPercent}) {
      final t = p == null || p.targets.isEmpty ? null : p.targets.single;
      return _Sample(
        ms: clock.elapsedMilliseconds,
        source: source,
        serverBytes: server.bodyBytes,
        serverPermille: server.permille,
        statusAnswered: server.statusAnswered,
        postPermille: p?.permille,
        stage: t?.stage?.name ?? 'none',
        targetPermille: t?.permille,
        position: t?.position,
        confirmedPosition: t?.confirmedPosition,
        slotTotal: t?.slotTotal,
        etaSeconds: t?.eta?.inSeconds,
        bytesPerSecond: t?.bytesPerSecond,
        outcome: t?.outcome?.name,
        postText: postText,
        postBar: postBar,
        rowLine: rowLine,
        rowPercent: rowPercent,
      );
    }

    // Every figure the tracker hands the screens.
    final listening = container.listen(publishProgressProvider, (_, runs) {
      final p = runs[postId];
      if (p != null) samples.add(sampleOf('tracker', p));
    });
    addTearDown(listening.close);

    _Sample? screenSample() {
      final live = container.read(publishProgressProvider)[postId];
      final figure = find.byType(PostProgressFigure);
      String? postText;
      double? postBar;
      if (figure.evaluate().isNotEmpty) {
        postText = tester.widget<Text>(find.descendant(of: figure, matching: find.byType(Text)).first).data;
        postBar = tester.widget<LinearProgressIndicator>(find.byKey(PostProgressFigure.barKey)).value;
      }
      final line = find.byType(TargetProgressLine);
      String? rowLine;
      String? rowPercent;
      if (line.evaluate().isNotEmpty) {
        final texts = [for (final t in tester.widgetList<Text>(find.descendant(of: line, matching: find.byType(Text)))) t.data ?? ''];
        rowLine = texts.isEmpty ? null : texts.first;
        rowPercent = texts.skip(1).where((t) => RegExp(r'^\d+%$').hasMatch(t)).firstOrNull;
      }
      if (live == null && postText == null) return null;
      return sampleOf('screen', live, postText: postText, postBar: postBar, rowLine: rowLine, rowPercent: rowPercent);
    }

    final startedMs = clock.elapsedMilliseconds;
    Post? done;
    Object? failure;
    final run = publisher
        .publish(postId, onPlan: tracker.plan, onEvent: tracker.event, onOutcome: tracker.outcome)
        .then<void>((p) {
      done = p;
    }, onError: (Object e) {
      failure = e;
    });
    // The screen, four times a second, until the run is over.
    while (done == null && failure == null) {
      if (clock.elapsedMilliseconds - startedMs > _limit.inMilliseconds) fail('the run did not finish within ${_limit.inMinutes} min');
      await tester.pump(const Duration(milliseconds: 250));
      final s = screenSample();
      if (s != null) samples.add(s);
    }
    await run;
    // The last frame of the run, before the sheet turns into its result.
    await tester.pump();
    final last = screenSample();
    if (last != null) samples.add(last);
    if (failure != null) fail('publish threw ${failure.runtimeType}: $failure');
    container.read(publishRunProvider.notifier).finish(done!);
    figures.end(postId, tracker);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    // ---- The table -------------------------------------------------------
    final tracked = samples.where((s) => s.source == 'tracker').toList();
    final screen = samples.where((s) => s.source == 'screen').toList();
    final firstByte = tracked.where((s) => s.position != null && s.position! > 0).firstOrNull?.ms;
    print('');
    print('SLOW-LINK RESULT');
    print('file $_fileBytes bytes, media body (Content-Length) ${server.contentLength} bytes, '
        'server read ${_piece ~/ 1024} KiB per ${_pieceGap.inMilliseconds} ms '
        '(${(_piece * 8 / _pieceGap.inMilliseconds / 1000).toStringAsFixed(2)} Mbit/s), margin ${_pct(_marginPermille)}');
    print('server calls: media POST ${server.mediaPosts}, polls ${server.polls}, status POST ${server.statusPosts}, unexpected ${server.unexpected}');
    print('samples: ${tracked.length} from the tracker, ${screen.length} from the screen');
    print('SCREEN TABLE (one frame per second, plus every change of stage or row number)');
    print(_header);
    String? lastStage;
    String? lastPercent;
    var lastSecond = -1;
    for (final s in screen) {
      final second = s.ms ~/ 1000;
      final key = '${s.outcome ?? s.stage}|${s.rowLine?.split(' · ').first}';
      if (second != lastSecond || key != lastStage || (s.rowPercent == null) != (lastPercent == null)) {
        print(_row(s));
        lastSecond = second;
      }
      lastStage = key;
      lastPercent = s.rowPercent;
    }
    print('TRACKER TABLE (every figure the tracker published while uploading, 1 in 4)');
    print(_header);
    final uploadingTracked = tracked.where((s) => s.uploading).toList();
    for (var i = 0; i < uploadingTracked.length; i++) {
      if (i % 4 == 0 || i == uploadingTracked.length - 1) print(_row(uploadingTracked[i]));
    }
    for (final s in tracked.where((s) => !s.uploading)) {
      print(_row(s));
    }

    // ---- The checks ------------------------------------------------------
    final problems = <String>[];
    void check(bool ok, String what) {
      if (!ok) problems.add(what);
    }

    // The run worked, once each.
    check(done!.targets.single.status == TargetStatus.published, 'the target was not published: ${done!.targets.single.status.name}');
    check(server.mediaPosts == 1, 'media POSTs: ${server.mediaPosts}');
    check(server.statusPosts == 1, 'status POSTs: ${server.statusPosts}');
    check(server.bodyBytes == server.contentLength && server.contentLength > _fileBytes, 'the server has ${server.bodyBytes} of ${server.contentLength}');

    // 1. Never backward: the tracker's figures and the screen's number and bar.
    int? high;
    for (final s in tracked.where((s) => s.postPermille != null)) {
      if (high != null && s.postPermille! < high) problems.add('tracker figure fell from $high to ${s.postPermille} at ${s.ms} ms');
      high = math.max(high ?? 0, s.postPermille!);
    }
    int? shownHigh;
    double? barHigh;
    for (final s in screen) {
      final shown = s.postText == null ? null : int.tryParse(s.postText!.replaceAll('%', ''));
      if (shown != null) {
        if (shownHigh != null && shown < shownHigh) problems.add('screen number fell from $shownHigh% to $shown% at ${s.ms} ms');
        shownHigh = math.max(shownHigh ?? 0, shown);
      }
      final bar = s.postBar;
      if (bar != null) {
        if (barHigh != null && bar < barHigh) problems.add('screen bar fell from $barHigh to $bar at ${s.ms} ms');
        barHigh = math.max(barHigh ?? 0, bar);
      }
    }

    // 2. Under 100 until the status POST has its answer.
    for (final s in samples) {
      final hundred = (s.postPermille ?? 0) >= 1000 || s.postText == '100%' || (s.postBar ?? 0) >= 1.0;
      if (hundred && !s.statusAnswered) problems.add('${s.source} read 100% at ${s.ms} ms, before the status POST was answered');
    }
    check(samples.any((s) => (s.postPermille ?? 0) == 1000), 'the run never reached 100%');

    // 3. While uploading, never more than the margin ahead of what the server has.
    var worstAhead = -1000;
    var overMargin = 0;
    _Sample? worst;
    for (final s in samples.where((s) => s.uploading && s.postPermille != null)) {
      final ahead = s.postPermille! - s.serverPermille;
      if (ahead > worstAhead) {
        worstAhead = ahead;
        worst = s;
      }
      if (ahead > _marginPermille && ++overMargin <= 5) {
        problems.add('${s.source} at ${s.ms} ms showed ${_pct(s.postPermille)} with the server at ${_pct(s.serverPermille)} '
            '(${s.serverBytes} bytes; ${s.position} handed to the connection)');
      }
    }
    if (overMargin > 5) problems.add('... and ${overMargin - 5} more samples over the margin');
    // The count runs ahead of the server; how far, in bytes, is evidence of why
    // it moves no number.
    var countAheadMax = 0;
    for (final s in samples.where((s) => s.uploading && s.position != null)) {
      countAheadMax = math.max(countAheadMax, s.position! - s.serverBytes);
    }
    // On the screen the number is what the tracker said, rounded down.
    for (final s in screen.where((s) => s.postText != null && s.postPermille != null)) {
      if (s.postText != '${s.postPermille! ~/ 10}%') problems.add('screen showed ${s.postText} for ${s.postPermille}‰ at ${s.ms} ms');
    }

    // 4. No number while bytes are only handed over, and none in a stage with
    // nothing to measure: the row has a number only once the server confirmed
    // part of the open upload.
    final stagesSeen = <String>[];
    for (final s in screen) {
      final stage = s.outcome ?? s.stage;
      if (stagesSeen.isEmpty || stagesSeen.last != stage) stagesSeen.add(stage);
      if (!s.confirmedSome && s.rowPercent != null && s.outcome == null) {
        problems.add('the row showed ${s.rowPercent} during "${s.rowLine}" (${s.stage}) at ${s.ms} ms, with nothing confirmed');
      }
      final line = s.rowLine ?? '';
      if (s.handedOnly && (!line.contains('Sending') || RegExp(r'\b(Sent|has|received)\b').hasMatch(line))) {
        problems.add('while only handed over the row said "$line" at ${s.ms} ms');
      }
    }
    final handedOnScreen = screen.where((s) => s.handedOnly).toList();
    check(handedOnScreen.length >= 10, 'the upload with nothing confirmed was on screen ${handedOnScreen.length} times, too few to judge');
    final handedFigures = {for (final s in samples.where((s) => s.handedOnly)) s.postPermille};
    check(handedFigures.length <= 1, 'the post figure moved while bytes were only handed over: $handedFigures');
    final handedShown = {for (final s in handedOnScreen) s.postText};
    check(handedShown.length <= 1, 'the number on screen moved while bytes were only handed over: $handedShown');
    check(screen.any((s) => s.stage == ProgressStage.serverProcessing.name && s.rowLine != null), 'the server wait was never on screen');
    // During the server's wait the post's figure holds still: no creep.
    final waitFigures = {for (final s in samples.where((s) => s.stage == ProgressStage.serverProcessing.name && s.outcome == null)) s.postPermille};
    check(waitFigures.length <= 1, 'the post figure moved during the server wait: $waitFigures');

    // 5. A time left only beside a speed measured from confirmed positions, and
    // not before two windows.
    int? firstEtaMs;
    for (final s in tracked.where((s) => s.etaSeconds != null || s.bytesPerSecond != null)) {
      firstEtaMs ??= s.ms;
      if (s.etaSeconds != null && s.bytesPerSecond == null) problems.add('a time left with no measured speed at ${s.ms} ms');
      if (!s.confirmedSome) problems.add('a speed or time left with nothing confirmed at ${s.ms} ms (${s.stage})');
    }
    for (final s in screen.where((s) => (s.rowLine ?? '').contains('left to send'))) {
      if (!RegExp(r'/s').hasMatch(s.rowLine!)) problems.add('the row showed a time left with no speed at ${s.ms} ms: ${s.rowLine}');
    }
    if (firstEtaMs != null && firstByte != null && firstEtaMs - firstByte < _meterWindow.inMilliseconds * 2 - 500) {
      problems.add('a time left ${firstEtaMs - firstByte} ms after the first byte, before two meter windows');
    }

    final serverDoneMs = server.received.isEmpty ? null : server.received.last.$1;
    final clientDoneMs = tracked.where((s) => s.position != null && s.slotTotal != null && s.position! >= s.slotTotal!).firstOrNull?.ms;
    final confirmedMs = tracked.where((s) => s.confirmedSome).firstOrNull?.ms;
    print('');
    print('SUMMARY');
    print('stages on screen: ${stagesSeen.join(' > ')}');
    print('first byte ${firstByte ?? '-'} ms; all handed to the connection ${clientDoneMs ?? '-'} ms; server has all ${serverDoneMs ?? '-'} ms; '
        'first confirmed ${confirmedMs ?? '-'} ms; status answered ${server.statusAnsweredMs ?? '-'} ms; '
        '100% first at ${samples.where((s) => (s.postPermille ?? 0) >= 1000).firstOrNull?.ms ?? '-'} ms');
    print('screen frames with bytes only handed over: ${handedOnScreen.length}, number shown in them: ${handedShown.join(', ')}');
    print('count ahead of the server: at most ${countAheadMax ~/ 1024} KiB ($countAheadMax bytes)');
    print('figure ahead of the server while uploading: at most $worstAhead‰ (margin $_marginPermille‰)'
        '${worst == null ? '' : ', at ${worst.ms} ms: shown ${_pct(worst.postPermille)}, server ${_pct(worst.serverPermille)}'}');
    print('first time left: ${firstEtaMs == null ? 'never shown' : '${firstEtaMs - (firstByte ?? 0)} ms after the first byte'}');
    final etas = tracked.where((s) => s.etaSeconds != null).toList();
    if (etas.isNotEmpty) {
      final e = etas.first;
      print('time left when first shown: ${e.etaSeconds} s at ${e.ms} ms, speed ${e.bytesPerSecond} B/s; '
          'the server really finished ${serverDoneMs == null ? '-' : '${(serverDoneMs - e.ms) / 1000} s'} later');
    }
    print('problems: ${problems.length}');
    for (final p in problems.take(40)) {
      print('  PROBLEM $p');
    }
    print(problems.isEmpty ? 'SLOW-LINK VERDICT: PASS' : 'SLOW-LINK VERDICT: FAIL');
    expect(problems, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 6)));
}
