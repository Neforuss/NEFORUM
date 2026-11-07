/// Runs the real client (MastodonAdapter, NeforumHttp, package:http IOClient)
/// against a local fake server through real sockets and each way a connection
/// can end. See README.md. Manual lane, Windows only.
///
///   dart run tool/upload_fault_matrix/run_matrix.dart [--repeat N] [--only a,b]
///       [--certs DIR] [--toxiproxy PATH] [--out FILE]
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/io_client.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_adapter.dart';

import 'fake_mastodon.dart';
import 'paced_proxy.dart';
import 'toxiproxy.dart';

const _mb = 1024 * 1024;

/// Bytes/s through the paced proxy. Faster than the 1 Mbit/s the bug was seen
/// on, to keep a run short: which error appears depends on the client still
/// writing when the far side closes, not on the rate.
const _rate = 2 * 1000 * 1000;

/// Dart cannot set a listening socket's SO_RCVBUF, and without that Windows
/// lets a sender get about 2.7 MB ahead on loopback (measured). The file has to
/// be well over that, or the client has finished writing when the close comes.
const _fileBytes = 8 * _mb;
const _jargon = ['errno', 'ClientException', 'SocketException', 'OS Error', 'Write failed', 'TimeoutException'];

/// How a run must end for the scenario to pass.
class Expected {
  const Expected.success({required this.mediaPosts, this.statusPosts = 1}) : success = true, message = null, plainRefusal = false;
  const Expected.failure(this.message, {required this.mediaPosts, this.plainRefusal = false}) : success = false, statusPosts = 0;

  final bool success;

  /// Text the final error must contain.
  final String? message;

  /// Exact count of media POSTs at the server, or null when a fault can stop
  /// a request reaching it.
  final int? mediaPosts;
  final int statusPosts;

  /// The server's own refusal arrived, so there is no upload trace to expect.
  final bool plainRefusal;
}

class Scenario {
  const Scenario(
    this.name,
    this.plan,
    this.expected, {
    this.paced = true,
    this.outage,
    this.fileBytes = _fileBytes,
    this.media = 1,
    this.publishes = 1,
    this.stall = const Duration(seconds: 30),
    this.base = const Duration(seconds: 30),
    this.imageLimit,
  });

  final String name;
  final FaultPlan plan;
  final Expected expected;
  final bool paced;
  final (Duration, Duration)? outage;
  final int fileBytes;
  final int media;
  final int publishes;
  final Duration stall;
  final Duration base;
  final int? imageLimit;
}

/// Fails media POST number 1 only.
FaultPlan _firstUpload(Fault f) => (media, status) => media == 1 ? f : const Serve();

/// Fails every media POST.
FaultPlan _everyUpload(Fault f) => (media, status) => media != null ? f : const Serve();

final _scenarios = <Scenario>[
  Scenario('control', (m, s) => const Serve(), const Expected.success(mediaPosts: 1)),
  // A fault on the first try: the upload is sent again, and one post results.
  Scenario('close_clean_once', _firstUpload(const CloseClean(128 * 1024)), const Expected.success(mediaPosts: 2)),
  Scenario('fin_then_rst_once', _firstUpload(const FinThenRst(128 * 1024)), const Expected.success(mediaPosts: 2)),
  Scenario('reset_once', _firstUpload(const Reset(128 * 1024)), const Expected.success(mediaPosts: 2)),
  Scenario('nginx_413_linger_lost_once', _firstUpload(const TooLargeThenLinger(128 * 1024, Duration(milliseconds: 200))), const Expected.success(mediaPosts: 2)),
  Scenario(
    'uplink_outage_body_timeout_once',
    _firstUpload(const BodyTimeout(64 * 1024, Duration(seconds: 2))),
    const Expected.success(mediaPosts: 2),
    outage: (const Duration(seconds: 1), const Duration(seconds: 4)),
  ),
  // Far over the file size elsewhere: the two sockets on each side of the proxy
  // can take in more than 8 MiB between them, and then nothing has stalled.
  Scenario(
    'stall_once',
    (m, s) => m == 1 ? const StopReading(64 * 1024) : const Serve(),
    const Expected.success(mediaPosts: 2),
    fileBytes: 32 * _mb,
    stall: const Duration(seconds: 3),
    paced: false,
  ),
  Scenario('no_answer_once', _firstUpload(const NoAnswer()), const Expected.success(mediaPosts: 2), fileBytes: _mb ~/ 2, base: const Duration(seconds: 2)),
  Scenario(
    'keepalive_reused_then_fin_rst',
    (m, s) => switch (m) {
      1 => const Serve(keepAlive: true),
      2 => const FinThenRst(0),
      _ => const Serve(),
    },
    const Expected.success(mediaPosts: 3),
    media: 2,
  ),
  Scenario(
    'second_image_cut_all_tries_then_resume',
    (m, s) => m != null && m >= 2 && m <= 4 ? const CloseClean(128 * 1024) : const Serve(),
    const Expected.success(mediaPosts: 5),
    media: 2,
    publishes: 2,
  ),
  // The answer to the post itself is lost: the key makes the retry return it.
  Scenario(
    'status_answer_lost',
    (m, s) => m == null && s == 1 ? const LoseStatusAnswer() : const Serve(),
    const Expected.success(mediaPosts: 1, statusPosts: 2),
    fileBytes: _mb ~/ 2,
  ),
  // Faults that never clear: a plain error, and no post.
  Scenario('always_cut', _everyUpload(const CloseClean(128 * 1024)), const Expected.failure('was cut off (tried 3 times). Nothing was posted.', mediaPosts: 3)),
  Scenario('always_reset', _everyUpload(const Reset(128 * 1024)), const Expected.failure('was cut off (tried 3 times). Nothing was posted.', mediaPosts: 3)),
  // nginx's lingering_close lets the sender finish: dart:io then hands over the
  // 413, and the plain refusal stands with no retry.
  Scenario(
    'nginx_413_long_linger_answer_arrives',
    _everyUpload(const TooLargeThenLinger(128 * 1024, Duration(seconds: 5))),
    const Expected.failure('larger than the server accepts', mediaPosts: 1, plainRefusal: true),
  ),
  Scenario(
    'always_413_over_limit',
    _everyUpload(const TooLargeThenLinger(128 * 1024, Duration(milliseconds: 200))),
    const Expected.failure('takes images up to 1 MB, and this one is 8 MB. Nothing was posted.', mediaPosts: 3),
    imageLimit: _mb,
  ),
  Scenario(
    'always_413_under_limit',
    _everyUpload(const TooLargeThenLinger(128 * 1024, Duration(milliseconds: 200))),
    const Expected.failure('was cut off (tried 3 times). Nothing was posted.', mediaPosts: 3),
    imageLimit: 16 * _mb,
  ),
  Scenario(
    'always_stall',
    _everyUpload(const StopReading(64 * 1024)),
    const Expected.failure('for 2 s (tried 3 times). Nothing was posted.', mediaPosts: 3),
    fileBytes: 32 * _mb,
    stall: const Duration(seconds: 2),
    paced: false,
  ),
];

/// One client: the real adapter and HTTP stack over a real connection.
class Client {
  Client(this.base, {required this.fileBytes, required this.media, required this.stall, required this.answerBase, this.badCertOk = false, this.onFailure});

  final Uri base;
  final int fileBytes;
  final int media;
  final Duration stall;
  final Duration answerBase;
  final bool badCertOk;
  final void Function()? onFailure;
  final MastodonAdapter adapter = MastodonAdapter();

  /// The system's text for each failed try, in order.
  final failures = <String>[];

  Future<PublishResult> publish() async {
    final io = HttpClient();
    if (badCertOk) io.badCertificateCallback = (cert, host, port) => host == 'localhost';
    final client = IOClient(io);
    final log = Logger('matrix', sink: (level, area, message, [error]) {
      if (message.startsWith('Network error calling')) {
        failures.add(message);
        onFailure?.call();
      }
    });
    final net = NeforumHttp(client: client, uploadStallTimeout: stall, timeout: answerBase, log: log);
    final ctx = AdapterContext(http: net, log: log, readMedia: (m) async => Uint8List(fileBytes));
    final account = ConnectedAccount(
      id: 'matrix',
      platformId: 'mastodon',
      tier: PlatformTier.openApi,
      displayName: 'matrix',
      createdAt: DateTime.now().toUtc(),
      config: {'instance': base.toString(), 'domain': base.host, 'software': 'mastodon', 'maxCharacters': 500, 'maxMediaAttachments': 4},
    );
    final variant = PostVariant(
      text: 'fault matrix',
      sourcePostId: 'post',
      media: [
        for (var i = 0; i < media; i++)
          MediaAttachment(id: 'm$i', path: 'm$i.jpg', mimeType: 'image/jpeg', sizeBytes: 64, width: 10, height: 10, altText: 'alt', fileName: 'm$i.jpg'),
      ],
    );
    const secrets = {'client_id': 'c', 'client_secret': 's', 'access_token': 't', 'token_type': 'Bearer'};
    try {
      return await adapter.publish(variant, account, secrets, ctx);
    } finally {
      client.close();
    }
  }
}

/// The errno of each failed try, as a list such as `10053,10053,10054`.
String errnos(List<String> failures) {
  String of(String f) {
    final m = RegExp(r'errno = (\d+)').firstMatch(f);
    if (m != null) return m.group(1)!;
    if (f.contains('TimeoutException')) return 'timeout';
    return RegExp(r'Connection closed[^;,)]*').firstMatch(f)?.group(0) ?? 'other';
  }

  return failures.map(of).join(',');
}

/// Checks one finished run. Returns what is wrong, or an empty list.
List<String> judge(PublishResult result, Expected want, FakeMastodon server) {
  final wrong = <String>[];
  if (result.success != want.success) wrong.add('success ${result.success}, wanted ${want.success}: ${result.error?.message}');
  if (server.statusPosts != want.statusPosts) wrong.add('${server.statusPosts} status POSTs, wanted ${want.statusPosts}');
  if (server.createdPosts != (want.success ? 1 : 0)) wrong.add('${server.createdPosts} posts on the server');
  final wantMedia = want.mediaPosts;
  if (wantMedia != null && server.mediaPosts != wantMedia) wrong.add('${server.mediaPosts} media POSTs, wanted $wantMedia');
  final e = result.error;
  if (e != null) {
    for (final word in _jargon) {
      if (e.message.contains(word)) wrong.add('jargon in the message: ${e.message}');
    }
    final text = want.message;
    if (text != null && !e.message.contains(text)) wrong.add('message "${e.message}", wanted "$text"');
    if (!want.plainRefusal && !(e.raw ?? '').contains('handed to the connection')) wrong.add('no byte count in the details: ${e.raw}');
  }
  return wrong;
}

class Row {
  Row(this.name, this.transport, this.result, this.server, this.failures, this.wrong, this.elapsed);
  final String name;
  final String transport;
  final PublishResult result;
  final FakeMastodon server;
  final List<String> failures;
  final List<String> wrong;
  final Duration elapsed;

  Map<String, Object?> toJson() => {
        'name': name,
        'transport': transport,
        'pass': wrong.isEmpty,
        'seconds': elapsed.inMilliseconds / 1000,
        'success': result.success,
        'kind': result.error?.kind.name,
        'message': result.error?.message,
        'raw': result.error?.raw,
        'errnoPerTry': errnos(failures),
        'writeFailedTries': failures.where((f) => f.contains('Write failed')).length,
        'mediaPosts': server.mediaPosts,
        'statusPosts': server.statusPosts,
        'postsOnServer': server.createdPosts,
        'wrong': wrong,
      };

  String get line {
    final mark = wrong.isEmpty ? 'PASS' : 'FAIL';
    final outcome = result.success ? 'posted' : '${result.error!.kind.name}: ${result.error!.message}';
    return '$mark ${name.padRight(44)} ${transport.padRight(6)} media=${server.mediaPosts} status=${server.statusPosts} posts=${server.createdPosts} '
        'tries[${errnos(failures)}] ${elapsed.inSeconds}s  $outcome${wrong.isEmpty ? '' : '\n     ${wrong.join('\n     ')}'}';
  }
}

Future<Row> runScenario(Scenario s, {SecurityContext? tls}) async {
  final server = await FakeMastodon.start(s.plan, imageLimit: s.imageLimit, tls: tls);
  PacedProxy? proxy;
  var port = server.port;
  if (s.paced) {
    proxy = await PacedProxy.start(server.port, rate: _rate, outage: s.outage);
    port = proxy.port;
  }
  final base = tls == null ? Uri.parse('http://127.0.0.1:$port') : Uri.parse('https://localhost:$port');
  final client = Client(base, fileBytes: s.fileBytes, media: s.media, stall: s.stall, answerBase: s.base, badCertOk: tls != null);
  final clock = Stopwatch()..start();
  var result = await client.publish();
  for (var i = 1; i < s.publishes && !result.success; i++) {
    result = await client.publish();
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
  final wrong = judge(result, s.expected, server);
  final row = Row(s.name, tls == null ? 'plain' : 'tls', result, server, client.failures, wrong, clock.elapsed);
  await proxy?.close();
  await server.close();
  return row;
}

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    stderr.writeln('The fault matrix is Windows only: its errno table and SO_LINGER layout are the Winsock ones.');
    exit(2);
  }
  String? option(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final repeat = int.parse(option('--repeat') ?? '1');
  final only = option('--only')?.split(',').toSet();
  final certs = option('--certs');
  final toxiproxyPath = option('--toxiproxy');
  final out = option('--out');
  SecurityContext? tls;
  if (certs != null) {
    tls = SecurityContext()
      ..useCertificateChain('$certs/cert.pem')
      ..usePrivateKey('$certs/key.pem');
  }

  final rows = <Map<String, Object?>>[];
  var failed = 0;
  void report(String line, Map<String, Object?> json, bool pass) {
    stdout.writeln(line);
    rows.add(json);
    if (!pass) failed++;
  }

  for (final s in _scenarios) {
    if (only != null && !only.contains(s.name)) continue;
    for (var i = 0; i < repeat; i++) {
      final plain = await runScenario(s);
      report(plain.line, plain.toJson(), plain.wrong.isEmpty);
      if (tls != null) {
        final secure = await runScenario(s, tls: tls);
        report(secure.line, secure.toJson(), secure.wrong.isEmpty);
      }
    }
  }

  if (toxiproxyPath != null) {
    final lane = await ToxiproxyLane.start(toxiproxyPath);
    try {
      for (final row in await lane.run(repeat: repeat, only: only)) {
        report(row.line, row.toJson(), row.wrong.isEmpty);
      }
    } finally {
      await lane.stop();
    }
  }

  if (out != null) {
    File(out).writeAsStringSync(rows.map(jsonEncode).join('\n'));
  }
  stdout.writeln('${rows.length - failed} of ${rows.length} passed');
  exit(failed == 0 ? 0 : 1);
}
