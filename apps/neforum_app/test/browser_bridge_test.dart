// The local server the NEFORUM browser extension talks to
// (extensions/browser/PROTOCOL.md), exercised over real HTTP on 127.0.0.1.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/browser_bridge.dart';
import 'package:neforum_app/platform/browser_bridge_io.dart' show IoBrowserBridge, isPortRefused, parseStartMenuInternet;
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/platform/ui_bridge.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/handoff/handoff_sheet.dart';
import 'package:neforum_app/ui/settings/browser_extension_section.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// flutter_test answers every HttpClient request with 400; these tests need
/// the real client to reach the real server.
class _RealHttp extends HttpOverrides {}

HttpClient _client() => HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());

class _Response {
  _Response(this.status, this.headers, this.bytes);
  final int status;
  final HttpHeaders headers;
  final List<int> bytes;
  Map<String, dynamic> get json => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}

/// Calls the bridge on [port]. Checks that no response ever carries CORS
/// headers.
Future<_Response> _call(HttpClient client, int port, String method, String path, {String? token, Object? body, String? host, String? origin}) async {
  final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
  if (host != null) req.headers.set(HttpHeaders.hostHeader, host);
  if (origin != null) req.headers.set('origin', origin);
  if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  if (body != null) {
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
  }
  final res = await req.close();
  final bytes = await res.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
  final cors = <String>[];
  res.headers.forEach((name, _) {
    if (name.toLowerCase().startsWith('access-control-')) cors.add(name);
  });
  expect(cors, isEmpty, reason: '$method $path must not send CORS headers');
  return _Response(res.statusCode, res.headers, bytes);
}

/// A port nothing listens on right now.
Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// Settings and media in memory; accounts and posts in [dataDir] (outside
/// the demo).
class _MemoryStorage implements AppStorage {
  _MemoryStorage([Uint8List? media, this.dataDir]) : _mediaBytes = media ?? Uint8List(0);
  final Uint8List _mediaBytes;
  final Map<String, Object> _json = {};
  @override
  final String? dataDir;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => _mediaBytes;
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => const SizedBox();
}

void main() {
  group('bridge server', () {
    late DateTime now;
    late InMemorySecretStore secrets;
    late BrowserBridge bridge;
    late HttpClient client;
    late int port;

    Future<_Response> call(String method, String path, {String? token, Object? body, String? host, String? origin}) =>
        _call(client, port, method, path, token: token, body: body, host: host, origin: origin);

    /// Pairs a browser and returns its token.
    Future<String> pair([String browser = 'Chrome']) async {
      final code = bridge.startPairing().code;
      final r = await call('POST', '/v1/pair', body: {'code': code, 'browser': browser}, origin: 'chrome-extension://abc');
      expect(r.status, 200);
      return r.json['token'] as String;
    }

    BrowserJob youtubeJob({List<BrowserJobMedia> media = const []}) => bridge.createJob(
          platformId: 'youtube_posts',
          platformName: 'YouTube Posts',
          url: 'https://www.youtube.com/@examplechannel/posts',
          hosts: browserJobHosts(Uri.parse('https://www.youtube.com/@examplechannel/posts')),
          text: 'Which logo do you like?',
          snippets: const [HandoffSnippet('Answer 1', 'Yes')],
          media: media,
          steps: '1. Check the post.\n2. Press Post.',
        )!;

    setUp(() async {
      _launcher = _FakeLauncher();
      BrowserBridge.launcher = _launcher;
      now = DateTime.utc(2026, 10, 12, 10);
      secrets = InMemorySecretStore();
      bridge = BrowserBridge.create(secrets: secrets, clock: () => now, ports: const [0]);
      await bridge.start();
      expect(bridge.status.value.state, BrowserBridgeState.listening);
      port = bridge.status.value.port!;
      client = _client();
    });

    tearDown(() async {
      client.close(force: true);
      await bridge.dispose();
      BrowserBridge.launcher = const BrowserLauncher();
    });

    test('hello says who it is, and whether the token is good', () async {
      var r = await call('GET', '/v1/hello');
      expect(r.status, 200);
      expect(r.json, {'app': 'NEFORUM', 'version': isA<String>(), 'protocol': 1, 'paired': false});
      expect(r.headers.contentType?.mimeType, 'application/json');

      final token = await pair();
      r = await call('GET', '/v1/hello', token: token);
      expect(r.json['paired'], isTrue);
      r = await call('GET', '/v1/hello', token: 'x' * 43);
      expect(r.json['paired'], isFalse);
    });

    test('pairing: the right code gives a 43-character token, once; it is kept in the keychain', () async {
      final code = bridge.startPairing().code;
      expect(code, matches(RegExp(r'^\d{6}$')));
      final r = await call('POST', '/v1/pair', body: {'code': code, 'browser': 'Firefox'}, origin: 'moz-extension://8a7d-uuid');
      expect(r.status, 200);
      final token = r.json['token'] as String;
      expect(token, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(bridge.pairing.value, isNull, reason: 'single use');
      expect(bridge.browsers.value.single.label, 'Firefox');
      expect(bridge.browsers.value.single.createdAt, now);

      final stored = jsonDecode((await secrets.read(kBrowserSecretsKey))!['browsers']!) as List;
      expect(stored.single, containsPair('token', token));
      expect(stored.single, containsPair('label', 'Firefox'));

      final again = await call('POST', '/v1/pair', body: {'code': code, 'browser': 'Firefox'});
      expect(again.status, 403);
      expect(again.json['error'], 'That code is wrong or has expired. Make a new one in NEFORUM.');

      // A new bridge (next app start) loads the paired browser.
      final next = BrowserBridge.create(secrets: secrets, clock: () => now, ports: const [0]);
      await next.start();
      expect(next.browsers.value.single.token, token);
      await next.dispose();
    });

    test('pairing: a wrong code is refused; no code at all is refused', () async {
      var r = await call('POST', '/v1/pair', body: {'code': '123456', 'browser': 'Chrome'});
      expect(r.status, 403, reason: 'no code was made');
      final code = bridge.startPairing().code;
      final wrong = code == '000000' ? '000001' : '000000';
      r = await call('POST', '/v1/pair', body: {'code': wrong, 'browser': 'Chrome'});
      expect(r.status, 403);
      expect(bridge.pairing.value, isNotNull, reason: 'one wrong try does not cancel it');
      r = await call('POST', '/v1/pair', body: {'code': code, 'browser': 'Chrome'});
      expect(r.status, 200);
    });

    test('pairing: the code expires after 5 minutes', () async {
      final code = bridge.startPairing().code;
      now = now.add(const Duration(minutes: 5));
      final r = await call('POST', '/v1/pair', body: {'code': code, 'browser': 'Chrome'});
      expect(r.status, 403);
      expect(bridge.pairing.value, isNull);
      expect(bridge.browsers.value, isEmpty);
    });

    test('pairing: 5 wrong tries cancel the code', () async {
      final code = bridge.startPairing().code;
      final wrong = code == '999999' ? '999998' : '999999';
      for (var i = 0; i < 4; i++) {
        expect((await call('POST', '/v1/pair', body: {'code': wrong})).status, 403);
      }
      expect(bridge.pairing.value, isNotNull, reason: '4 wrong tries leave the code');
      expect((await call('POST', '/v1/pair', body: {'code': wrong})).status, 403);
      expect(bridge.pairing.value, isNull, reason: 'the 5th cancels it');
      expect((await call('POST', '/v1/pair', body: {'code': code})).status, 403);
      expect(bridge.browsers.value, isEmpty);
    });

    test('unpair forgets the token', () async {
      final token = await pair();
      final other = await pair('Microsoft Edge');
      expect((await call('POST', '/v1/unpair', token: token)).status, 204);
      expect(bridge.browsers.value.map((b) => b.label), ['Microsoft Edge']);
      expect((await call('GET', '/v1/job?host=youtube.com', token: token)).status, 401);
      expect((await call('GET', '/v1/hello', token: other)).json['paired'], isTrue);
      final stored = jsonDecode((await secrets.read(kBrowserSecretsKey))!['browsers']!) as List;
      expect(stored, hasLength(1));
    });

    test('paths that need a token answer 401 without one', () async {
      youtubeJob();
      for (final (method, path) in [('POST', '/v1/unpair'), ('GET', '/v1/job?host=youtube.com'), ('GET', '/v1/job/j_x/media/0'), ('POST', '/v1/job/j_x/result')]) {
        final r = await call(method, path);
        expect(r.status, 401, reason: '$method $path');
        expect(r.json['error'], isA<String>());
        expect((await call(method, path, token: 'not-a-token')).status, 401, reason: '$method $path with a bad token');
      }
    });

    test('a Host header other than 127.0.0.1 or localhost is refused (DNS rebinding)', () async {
      final token = await pair();
      for (final host in ['evil.example:$port', 'evil.example', '127.0.0.1:1', '127.0.0.1']) {
        final r = await call('GET', '/v1/hello', host: host, token: token);
        expect(r.status, 403, reason: host);
        expect(r.json['error'], isA<String>());
      }
      expect((await call('GET', '/v1/hello', host: 'localhost:$port')).status, 200);
      expect((await call('GET', '/v1/hello', host: '127.0.0.1:$port')).status, 200);
    });

    test('requests from web pages are refused; the extension\'s are not', () async {
      final token = await pair();
      for (final origin in ['https://example.com', 'http://127.0.0.1:$port', 'null', 'file://']) {
        expect((await call('GET', '/v1/hello', origin: origin)).status, 403, reason: origin);
        expect((await call('POST', '/v1/pair', origin: origin, body: {'code': '123456'})).status, 403, reason: origin);
        expect((await call('GET', '/v1/job?host=youtube.com', origin: origin, token: token)).status, 403, reason: origin);
      }
      for (final origin in ['chrome-extension://abc', 'moz-extension://0b3e4f-uuid', 'safari-web-extension://x']) {
        expect((await call('GET', '/v1/hello', origin: origin, token: token)).json['paired'], isTrue, reason: origin);
        expect((await call('GET', '/v1/job?host=youtube.com', origin: origin, token: token)).status, 204, reason: origin);
      }
    });

    test('job: 204 when none or another site, 200 for its hosts (www. ignored)', () async {
      final token = await pair();
      expect((await call('GET', '/v1/job?host=www.youtube.com', token: token)).status, 204, reason: 'no job yet');
      final job = youtubeJob();
      expect(job.hosts, ['www.youtube.com', 'youtube.com', 'm.youtube.com']);
      expect(job.id, matches(RegExp(r'^j_[0-9a-f]{32}$')));

      for (final host in ['www.youtube.com', 'youtube.com', 'm.youtube.com', 'WWW.YouTube.com']) {
        final r = await call('GET', '/v1/job?host=${Uri.encodeQueryComponent(host)}', token: token);
        expect(r.status, 200, reason: host);
        expect(r.json['id'], job.id);
      }
      for (final host in ['x.com', 'studio.youtube.com', 'youtube.com.evil.example', 'notyoutube.com']) {
        expect((await call('GET', '/v1/job?host=$host', token: token)).status, 204, reason: host);
      }
      expect((await call('GET', '/v1/job', token: token)).status, 400, reason: 'host is required');

      final r = await call('GET', '/v1/job?host=youtube.com', token: token);
      expect(r.json, {
        'id': job.id,
        'platformId': 'youtube_posts',
        'platformName': 'YouTube Posts',
        'url': 'https://www.youtube.com/@examplechannel/posts',
        'hosts': ['www.youtube.com', 'youtube.com', 'm.youtube.com'],
        'text': 'Which logo do you like?',
        'title': null,
        'snippets': [
          {'label': 'Answer 1', 'text': 'Yes'},
        ],
        'media': <Object>[],
        'steps': '1. Check the post.\n2. Press Post.',
        'quickPost': false,
        'autoPost': false,
        'createdAt': '2026-10-12T10:00:00Z',
        'expiresAt': '2026-10-12T10:10:00Z',
        'preferred': true,
      });
    });

    test('preferred: only browsers set to the program the page was opened in fill it in on their own', () async {
      final chrome = await pair('Chrome');
      final firefox = await pair('Firefox');
      // Helium is Chromium too, and its extension may well say "Chrome".
      final helium = await pair('Chrome');
      await pumpEventQueue();
      expect([for (final b in bridge.browsers.value) b.app], [_chrome.id, _firefox.id, _chrome.id], reason: 'guessed at pairing: "Chrome" is Google Chrome');
      await bridge.setProgram(helium, _helium);
      expect(bridge.browsers.value.last.appName, 'Helium');
      Future<Object?> preferred(String token) async => (await call('GET', '/v1/job?host=youtube.com', token: token)).json['preferred'];
      void openedIn(InstalledBrowser? program) =>
          bridge.createJob(platformId: 'youtube_posts', platformName: 'YouTube Posts', url: 'https://www.youtube.com/@a/posts', hosts: const ['www.youtube.com'], text: 'Hi', target: program?.id);

      openedIn(_chrome);
      expect([await preferred(chrome), await preferred(firefox), await preferred(helium)], [true, false, false]);
      openedIn(_helium);
      expect([await preferred(chrome), await preferred(firefox), await preferred(helium)], [false, false, true], reason: 'same chrome.exe name, another program');
      openedIn(_firefox);
      expect([await preferred(chrome), await preferred(firefox), await preferred(helium)], [false, true, false]);
      // Opened in the default browser: any paired browser fills in.
      openedIn(null);
      expect([await preferred(chrome), await preferred(firefox), await preferred(helium)], [true, true, true]);
    });

    test('first choice: the first paired browser whose program can start, in the user\'s order', () async {
      final helium = await pair('Chromium-based browser');
      await pair('Chrome');
      await pumpEventQueue();
      expect(bridge.browsers.value.first.app, isNull, reason: 'no program called Chromium here: the user picks');
      expect((await bridge.firstChoice())!.program, _chrome, reason: 'the Helium one has no program yet');

      await bridge.setProgram(helium, _helium);
      expect((await bridge.firstChoice())!.program, _helium);
      _launcher.gone.add(_helium.id);
      expect((await bridge.firstChoice())!.program, _chrome, reason: 'Helium uninstalled: the next one');
      _launcher.gone.add(_chrome.id);
      expect(await bridge.firstChoice(), isNull);
    });

    test('posted: reported only for jobs that allow posting from the page', () async {
      final token = await pair('Firefox');
      final results = <BrowserFillResult>[];
      final sub = bridge.results.listen(results.add);
      addTearDown(sub.cancel);

      var job = bridge.createJob(platformId: 'tiktok', platformName: 'TikTok', url: 'https://www.tiktok.com/tiktokstudio/upload?tab=photo', hosts: const ['www.tiktok.com'], text: 'Hi', quickPost: true)!;
      expect((await call('GET', '/v1/job?host=www.tiktok.com', token: token)).json['quickPost'], isTrue);
      await call('POST', '/v1/job/${job.id}/result', token: token, body: {'status': 'filled', 'text': true, 'media': 1, 'posted': 'confirmed'});
      await call('POST', '/v1/job/${job.id}/result', token: token, body: {'status': 'filled', 'text': true, 'posted': 'pressed'});
      await call('POST', '/v1/job/${job.id}/result', token: token, body: {'status': 'filled', 'text': true, 'posted': 'maybe'});
      await call('POST', '/v1/job/${job.id}/result', token: token, body: {'status': 'filled', 'text': true});

      job = bridge.createJob(platformId: 'tiktok', platformName: 'TikTok', url: 'https://www.tiktok.com/tiktokstudio/upload?tab=photo', hosts: const ['www.tiktok.com'], text: 'Hi')!;
      await call('POST', '/v1/job/${job.id}/result', token: token, body: {'status': 'filled', 'text': true, 'posted': 'confirmed'});
      await pumpEventQueue();

      expect(results.map((r) => r.posted), [
        BrowserPostState.confirmed,
        BrowserPostState.pressed,
        BrowserPostState.none,
        BrowserPostState.none,
        BrowserPostState.none, // this job did not allow it
      ]);
      expect(results.first.browser, 'Firefox');
    });

    test('priority: make first and swap reorder the browsers and are kept in the keychain', () async {
      await pair('Chrome');
      await pair('Chrome'); // a second Chrome profile
      final firefox = await pair('Firefox');
      List<String> labels() => [for (final b in bridge.browsers.value) b.label];
      await pumpEventQueue();

      // Swap trades Chrome for the next browser that is another program.
      await bridge.swapFirstTwo();
      expect(labels(), ['Firefox', 'Chrome', 'Chrome']);
      await bridge.swapFirstTwo();
      expect(labels().first, 'Chrome');

      await bridge.makeFirst(firefox);
      expect(labels(), ['Firefox', 'Chrome', 'Chrome']);
      await bridge.makeFirst(firefox);
      expect(labels(), ['Firefox', 'Chrome', 'Chrome'], reason: 'already first');
      await pumpEventQueue();
      final stored = jsonDecode((await secrets.read(kBrowserSecretsKey))!['browsers']!) as List;
      expect([for (final b in stored) b['label']], ['Firefox', 'Chrome', 'Chrome']);

      // A new bridge reads the same order.
      final again = BrowserBridge.create(secrets: secrets, clock: () => now, ports: const [0]);
      await again.start();
      addTearDown(again.dispose);
      expect([for (final b in again.browsers.value) b.label], ['Firefox', 'Chrome', 'Chrome']);
    });

    test('job hosts include the known aliases', () {
      expect(browserJobHosts(Uri.parse('https://x.com/intent/post?text=hi')), ['x.com', 'twitter.com', 'mobile.twitter.com']);
      expect(browserJobHosts(Uri.parse('https://www.threads.net/intent/post')), ['www.threads.net', 'threads.com', 'threads.net']);
      expect(browserJobHosts(Uri.parse('https://old.reddit.com/submit')), ['old.reddit.com', 'reddit.com', 'www.reddit.com', 'new.reddit.com']);
      expect(browserJobHosts(Uri.parse('https://myblog.substack.com/publish')), ['myblog.substack.com']);
      expect(browserJobHosts(Uri.parse('https://web.whatsapp.com/send?text=hi')), ['web.whatsapp.com', 'wa.me', 'api.whatsapp.com']);
      // wa.me forwards to api.whatsapp.com, then to WhatsApp Web: the job opened on wa.me must match there.
      final wa = bridge.createJob(platformId: 'whatsapp', platformName: 'WhatsApp', url: 'https://wa.me/?text=hi', hosts: browserJobHosts(Uri.parse('https://wa.me/?text=hi')), text: 'hi')!;
      expect(wa.matchesHost('web.whatsapp.com'), isTrue);
      // youtube.com/upload forwards to YouTube Studio, but only for a video upload.
      final upload = Uri.parse('https://www.youtube.com/upload');
      expect(browserJobHosts(upload, platformId: 'youtube'), contains('studio.youtube.com'));
      expect(browserJobHosts(Uri.parse('https://www.youtube.com/@a/posts'), platformId: 'youtube_posts'), isNot(contains('studio.youtube.com')));
      expect(browserJobHosts(Uri.parse('https://www.pixiv.net/illustration/create'), platformId: 'pixiv'), ['www.pixiv.net', 'pixiv.net']);
    });

    test('job: automatic posting and the fields sites keep apart (thread parts, description, tags, poll, artwork)', () async {
      final token = await pair();
      const variant = PostVariant(
        text: 'Which is the capital?',
        threadParts: ['Which is the capital?', 'Answer below.'],
        tags: ['quiz', 'geography'],
        poll: PostPoll(options: ['Paris', '', 'Lyon'], kind: PollKind.quiz, correctIndex: 2, explanation: ' Lyon is not. '),
        artwork: ArtworkDetails(maturity: ArtworkMaturity.mature, aiGenerated: true),
      );
      bridge.createJob(
        platformId: 'youtube_posts',
        platformName: 'YouTube Posts',
        url: 'https://www.youtube.com/@a/posts',
        hosts: const ['www.youtube.com'],
        text: 'Which is the capital?',
        autoPost: true,
        details: BrowserJobDetails.fromVariant(variant),
      );
      final j = (await call('GET', '/v1/job?host=www.youtube.com&page=page0000aaaa1111', token: token)).json;
      expect(j['autoPost'], isTrue);
      expect(j['parts'], ['Which is the capital?', 'Answer below.']);
      expect(j['description'], 'Which is the capital?');
      expect(j['tags'], ['quiz', 'geography']);
      expect(j['poll'], {
        'kind': 'quiz',
        'imageOptions': false,
        'options': ['Paris', 'Lyon'],
        'correctIndex': 1,
        'explanation': 'Lyon is not.',
      }, reason: 'empty answers dropped; the correct one counted among the rest');
      expect(j['artwork'], {'maturity': 'mature', 'aiGenerated': true, 'disallowAiTraining': true});

      // A single post sends none of these.
      bridge.createJob(platformId: 'x', platformName: 'X', url: 'https://x.com/intent/tweet', hosts: const ['x.com'], text: 'Hi', details: BrowserJobDetails.fromVariant(const PostVariant(text: 'Hi')));
      final single = (await call('GET', '/v1/job?host=x.com', token: token)).json;
      expect(single.keys, isNot(containsAll(['parts', 'tags', 'poll', 'artwork'])));
      expect(single['autoPost'], isFalse);
    });

    test('automatic: its states and posted are taken only from automatic jobs', () async {
      final token = await pair('Firefox');
      final results = <BrowserFillResult>[];
      final sub = bridge.results.listen(results.add);
      addTearDown(sub.cancel);

      // An automatic job need not allow the shortcut to report its post.
      var job = bridge.createJob(platformId: 'tiktok', platformName: 'TikTok', url: 'https://www.tiktok.com/tiktokstudio/upload', hosts: const ['www.tiktok.com'], text: 'Hi', autoPost: true)!;
      expect((await call('GET', '/v1/job?host=www.tiktok.com&page=page0000aaaa1111', token: token)).json['autoPost'], isTrue);
      for (final body in [
        {'status': 'filled', 'text': true, 'automatic': 'countdown'},
        {'status': 'filled', 'text': true, 'automatic': 'countdown', 'posted': 'confirmed'},
        {'status': 'filled', 'text': true, 'automatic': 'stopped'},
        {'status': 'partial', 'text': true, 'automatic': 'manual', 'message': 'Not everything was filled in.'},
        {'status': 'filled', 'automatic': 'soon'},
      ]) {
        await call('POST', '/v1/job/${job.id}/result', token: token, body: body);
      }
      job = bridge.createJob(platformId: 'tiktok', platformName: 'TikTok', url: 'https://www.tiktok.com/tiktokstudio/upload', hosts: const ['www.tiktok.com'], text: 'Hi')!;
      await call('POST', '/v1/job/${job.id}/result', token: token, body: {'status': 'filled', 'automatic': 'countdown', 'posted': 'confirmed'});
      await pumpEventQueue();

      expect([for (final r in results) (r.automatic, r.posted)], [
        (BrowserAutomaticState.countdown, BrowserPostState.none),
        (BrowserAutomaticState.countdown, BrowserPostState.confirmed),
        (BrowserAutomaticState.stopped, BrowserPostState.none),
        (BrowserAutomaticState.manual, BrowserPostState.none),
        (BrowserAutomaticState.none, BrowserPostState.none),
        (BrowserAutomaticState.none, BrowserPostState.none), // neither automatic nor quick post
      ]);
      expect(results[3].message, 'Not everything was filled in.');
    });

    test('automatic: one page posts it, the first of the browser it was opened in to ask; ending automatic posting keeps the job for the user\'s own post', () async {
      final chrome = await pair('Chrome');
      final firefox = await pair('Firefox');
      await pumpEventQueue();
      final results = <BrowserFillResult>[];
      final sub = bridge.results.listen(results.add);
      addTearDown(sub.cancel);
      Future<Object?> autoPost(String token, [String? page]) async =>
          (await call('GET', '/v1/job?host=www.tiktok.com${page == null ? '' : '&page=$page'}', token: token)).json['autoPost'];

      var job = bridge.createJob(platformId: 'tiktok', platformName: 'TikTok', url: 'https://www.tiktok.com/tiktokstudio/upload', hosts: const ['www.tiktok.com'], text: 'Hi', autoPost: true, target: _chrome.id)!;
      expect(await autoPost(firefox, 'page0000ffff0000'), isFalse, reason: 'not the browser it was opened in, and it takes nothing away');
      expect(await autoPost(chrome), isFalse, reason: 'a page that sends no id');
      expect(await autoPost(chrome, 'bad id!'), isFalse);
      expect(await autoPost(chrome, 'page0000aaaa1111'), isTrue, reason: 'the first page to ask');
      expect(await autoPost(chrome, 'page0000bbbb2222'), isFalse, reason: 'another tab of the site only fills it in');
      expect(await autoPost(chrome, 'page0000aaaa1111'), isTrue, reason: 'the same page asking again before Post');

      bridge.endAutomaticPosting('j_not_this_one');
      expect(await autoPost(chrome, 'page0000aaaa1111'), isTrue);
      bridge.endAutomaticPosting(job.id);
      expect(await autoPost(chrome, 'page0000aaaa1111'), isFalse);
      expect(bridge.job?.id, job.id, reason: 'the job stays');
      expect(bridge.job!.autoPost, isTrue, reason: 'the app still knows it was automatic');
      // A post the user makes from the page still counts (the job has no quick post).
      await call('POST', '/v1/job/${job.id}/result', token: chrome, body: {'status': 'filled', 'text': true, 'posted': 'confirmed'});
      await pumpEventQueue();
      expect(results.last.posted, BrowserPostState.confirmed);

      // A new job starts afresh.
      job = bridge.createJob(platformId: 'tiktok', platformName: 'TikTok', url: 'https://www.tiktok.com/tiktokstudio/upload', hosts: const ['www.tiktok.com'], text: 'Hi', autoPost: true)!;
      expect(await autoPost(firefox, 'page0000bbbb2222'), isTrue, reason: 'opened in the default browser: any paired browser may');
      expect(await autoPost(chrome, 'page0000aaaa1111'), isFalse);
    });

    test('automatic: only the page that posts it says how it stands; other pages that send their id only filled it in; a report without an id is from an extension before 1.1.0', () async {
      final token = await pair();
      final results = <BrowserFillResult>[];
      final sub = bridge.results.listen(results.add);
      addTearDown(sub.cancel);
      const posting = 'page0000aaaa1111';
      const other = 'page0000bbbb2222';
      final job = bridge.createJob(platformId: 'tiktok', platformName: 'TikTok', url: 'https://www.tiktok.com/tiktokstudio/upload', hosts: const ['www.tiktok.com'], text: 'Hi', autoPost: true)!;
      await call('GET', '/v1/job?host=www.tiktok.com&page=$posting', token: token);
      await call('GET', '/v1/job?host=www.tiktok.com&page=$other', token: token);
      for (final body in [
        {'status': 'filled', 'text': true, 'automatic': 'countdown', 'page': posting},
        {'status': 'filled', 'text': true, 'page': other}, // another tab's fill
        {'status': 'filled', 'text': true, 'automatic': 'countdown', 'page': other}, // only the posting page says
        {'status': 'filled', 'text': true, 'posted': 'confirmed', 'page': other}, // a post made there counts
        {'status': 'filled', 'text': true, 'page': posting}, // filled in again there at the user's request
        {'status': 'filled', 'text': true}, // no page id: an extension before 1.1.0
        {'status': 'filled', 'text': true, 'page': 'bad id!'},
        {'status': 'filled', 'text': true, 'automatic': 'otherPage'}, // never taken from the extension
      ]) {
        await call('POST', '/v1/job/${job.id}/result', token: token, body: body);
      }
      await pumpEventQueue();
      expect([for (final r in results) (r.automatic, r.posted)], [
        (BrowserAutomaticState.countdown, BrowserPostState.none),
        (BrowserAutomaticState.otherPage, BrowserPostState.none),
        (BrowserAutomaticState.otherPage, BrowserPostState.none),
        (BrowserAutomaticState.otherPage, BrowserPostState.confirmed),
        (BrowserAutomaticState.manual, BrowserPostState.none),
        (BrowserAutomaticState.none, BrowserPostState.none),
        (BrowserAutomaticState.none, BrowserPostState.none),
        (BrowserAutomaticState.none, BrowserPostState.none),
      ]);
    });

    test('served: each fetch of the job or of one of its files says the page is still at work', () async {
      final token = await pair();
      final served = <String>[];
      final sub = bridge.served.listen(served.add);
      addTearDown(sub.cancel);
      final job = youtubeJob(media: [BrowserJobMedia(name: 'a.png', mimeType: 'image/png', size: 3, read: () async => Uint8List(3))]);
      await call('GET', '/v1/job?host=www.youtube.com', token: token);
      await call('GET', '/v1/job/${job.id}/media/0', token: token);
      await call('GET', '/v1/job?host=x.com', token: token);
      await pumpEventQueue();
      expect(served, [job.id, job.id], reason: 'not for another site');
    });

    test('the extension fills in by itself exactly the pages in both manifests', () {
      List<String> matches(String browser) => [
            for (final m in ((jsonDecode(File('../../extensions/browser/manifest.$browser.json').readAsStringSync()) as Map)['content_scripts'] as List).single['matches'] as List)
              (m as String).replaceFirst('https://', '').replaceFirst(RegExp(r'/\*$'), ''),
          ];
      expect(kExtensionPageHosts, matches('chrome'));
      expect(kExtensionPageHosts, matches('firefox'));
      for (final url in ['https://www.youtube.com/@a/posts', 'https://x.com/intent/post?text=hi', 'https://wa.me/?text=hi', 'https://www.pinterest.com/pin-creation-tool/', 'https://uk.pinterest.com/']) {
        expect(extensionFillsPage(Uri.parse(url)), isTrue, reason: url);
      }
      expect(extensionFillsPage(Uri.parse('https://www.youtube.com/upload'), platformId: 'youtube'), isTrue);
      for (final url in ['https://mastodon.social/share?text=hi', 'https://myblog.wordpress.com/wp-admin/post-new.php', 'https://myblog.substack.com/publish', 'https://t.me/share/url?url=x', 'http://x.com/intent/post', 'instagram://']) {
        expect(extensionFillsPage(Uri.parse(url)), isFalse, reason: url);
      }
    });

    test('the extension\'s pages: every site with a host alias of its own is in both manifests', () {
      Map<String, dynamic> manifest(String browser) => jsonDecode(File('../../extensions/browser/manifest.$browser.json').readAsStringSync()) as Map<String, dynamic>;
      final chrome = manifest('chrome');
      final firefox = manifest('firefox');
      expect(firefox['version'], chrome['version']);
      expect(chrome['version'], '1.1.2');
      final matches = [for (final m in (chrome['content_scripts'] as List).single['matches'] as List) m as String];
      expect((firefox['content_scripts'] as List).single['matches'], matches);
      bool matched(String host) => matches.any((m) => m == 'https://$host/*' || (m.startsWith('https://*.') && host.endsWith(m.substring(10, m.length - 2))));
      for (final url in [
        'https://www.behance.net/portfolio/editor',
        'https://www.artstation.com/myartstation/projects/new',
        'https://cara.app/',
        'https://www.pixiv.net/illustration/create',
        'https://itaku.ee/new/images',
        'https://www.newgrounds.com/projects/art/new',
        'https://www.furaffinity.net/submit/',
        'https://www.weasyl.com/submit/visual',
        'https://ko-fi.com/',
        'https://artfol.app/',
        'https://500px.com/',
        'https://dribbble.com/uploads/new',
        'https://www.flickr.com/photos/upload/',
        'https://studio.youtube.com/',
        'https://web.whatsapp.com/',
      ]) {
        final host = Uri.parse(url).host;
        expect(matched(host), isTrue, reason: '$host: the content scripts run there');
      }
    });

    test('only the newest job is served', () async {
      final token = await pair();
      final first = youtubeJob();
      final second = youtubeJob();
      expect(second.id, isNot(first.id));
      expect((await call('GET', '/v1/job?host=youtube.com', token: token)).json['id'], second.id);
      expect((await call('GET', '/v1/job/${first.id}/media/0', token: token)).status, 404);
    });

    test('media: bytes with their content type; 404 for an unknown index or job', () async {
      final token = await pair();
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
      final mp4 = Uint8List.fromList(List<int>.generate(70000, (i) => i % 251));
      var reads = 0;
      final job = youtubeJob(media: [
        BrowserJobMedia(name: 'photo.png', mimeType: 'image/png', size: png.length, read: () async {
          reads++;
          return png;
        }),
        BrowserJobMedia(name: 'clip.mp4', mimeType: 'video/mp4', size: mp4.length, isVideo: true, read: () async => mp4),
      ]);
      expect(reads, 0, reason: 'files are read only when asked for');

      final listed = (await call('GET', '/v1/job?host=youtube.com', token: token)).json['media'];
      expect(listed, [
        {'index': 0, 'name': 'photo.png', 'mimeType': 'image/png', 'size': png.length, 'kind': 'image'},
        {'index': 1, 'name': 'clip.mp4', 'mimeType': 'video/mp4', 'size': mp4.length, 'kind': 'video'},
      ]);

      var r = await call('GET', '/v1/job/${job.id}/media/0', token: token);
      expect(r.status, 200);
      expect(r.headers.contentType?.mimeType, 'image/png');
      expect(r.bytes, png);
      expect(reads, 1);
      r = await call('GET', '/v1/job/${job.id}/media/1', token: token);
      expect(r.headers.contentType?.mimeType, 'video/mp4');
      expect(r.headers.contentLength, mp4.length);
      expect(r.bytes, mp4);

      for (final path in ['/v1/job/${job.id}/media/2', '/v1/job/${job.id}/media/-1', '/v1/job/${job.id}/media/x', '/v1/job/j_nope/media/0']) {
        expect((await call('GET', path, token: token)).status, 404, reason: path);
      }
    });

    test('result: delivered on the stream with the site that asked; the job stays', () async {
      final token = await pair();
      final job = youtubeJob(media: [BrowserJobMedia(name: 'a.jpg', mimeType: 'image/jpeg', size: 3, read: () async => Uint8List(3))]);
      final results = <BrowserFillResult>[];
      final sub = bridge.results.listen(results.add);
      addTearDown(sub.cancel);

      await call('GET', '/v1/job?host=www.youtube.com', token: token);
      var r = await call('POST', '/v1/job/${job.id}/result', token: token, body: {'status': 'filled', 'text': true, 'media': 1, 'message': 'All set'});
      expect(r.status, 204);
      expect(r.bytes, isEmpty);
      await pumpEventQueue();
      expect(results, hasLength(1));
      expect(results.single.jobId, job.id);
      expect(results.single.status, BrowserFillStatus.filled);
      expect(results.single.text, isTrue);
      expect(results.single.media, 1);
      expect(results.single.message, 'All set');
      expect(results.single.host, 'www.youtube.com');

      // Still there: the extension can fill the page in again.
      expect((await call('GET', '/v1/job?host=youtube.com', token: token)).status, 200);

      r = await call('POST', '/v1/job/${job.id}/result', token: token, body: {'status': 'sort of'});
      expect(r.status, 400);
      r = await call('POST', '/v1/job/j_other/result', token: token, body: {'status': 'failed'});
      expect(r.status, 404);
      await pumpEventQueue();
      expect(results, hasLength(1));
    });

    test('a job expires after 10 minutes', () async {
      final token = await pair();
      final job = youtubeJob(media: [BrowserJobMedia(name: 'a.jpg', mimeType: 'image/jpeg', size: 3, read: () async => Uint8List(3))]);
      now = now.add(const Duration(minutes: 9, seconds: 59));
      expect((await call('GET', '/v1/job?host=youtube.com', token: token)).status, 200);
      now = now.add(const Duration(seconds: 1));
      expect((await call('GET', '/v1/job?host=youtube.com', token: token)).status, 204);
      expect((await call('GET', '/v1/job/${job.id}/media/0', token: token)).status, 404);
      expect((await call('POST', '/v1/job/${job.id}/result', token: token, body: {'status': 'filled'})).status, 404);
      expect(bridge.job, isNull);
    });

    test('last used is saved at most once a minute', () async {
      final token = await pair();
      final paired = bridge.browsers.value.single.lastSeen;
      now = now.add(const Duration(seconds: 30));
      await call('GET', '/v1/hello', token: token);
      expect(bridge.browsers.value.single.lastSeen, paired);
      now = now.add(const Duration(seconds: 31));
      await call('GET', '/v1/hello', token: token);
      expect(bridge.browsers.value.single.lastSeen, now);
      await pumpEventQueue();
      final stored = jsonDecode((await secrets.read(kBrowserSecretsKey))!['browsers']!) as List;
      expect(stored.single['lastSeen'], now.toIso8601String());
    });

    test('stop closes the port and drops the job; ports in use are skipped', () async {
      youtubeJob();
      // A second bridge on the same port finds it busy.
      final busy = BrowserBridge.create(secrets: InMemorySecretStore(), clock: () => now, ports: [port]);
      await busy.start();
      expect(busy.status.value.state, BrowserBridgeState.portBusy);
      await busy.dispose();

      await bridge.stop();
      expect(bridge.status.value.state, BrowserBridgeState.off);
      expect(bridge.job, isNull);
      await expectLater(call('GET', '/v1/hello'), throwsA(isA<SocketException>()));
    });
  });

  group('ports', () {
    /// A bridge whose ports in [refused] fail as Windows fails a port Hyper-V
    /// reserved (10013), and those in [inUse] as a port another program uses
    /// (10048); the others really open. [tried] records every port asked for.
    IoBrowserBridge fakeBind(List<int> ports, {Set<int> refused = const {}, Set<int> inUse = const {}, List<int>? tried}) => IoBrowserBridge(
          secrets: InMemorySecretStore(),
          clock: DateTime.now,
          ports: ports,
          version: 'test',
          bind: (address, port) {
            tried?.add(port);
            if (refused.contains(port)) {
              throw SocketException('Failed to create server socket',
                  osError: const OSError('An attempt was made to access a socket in a way forbidden by its access permissions.', 10013), address: address, port: port);
            }
            if (inUse.contains(port)) {
              throw SocketException('Failed to create server socket',
                  osError: const OSError('Only one usage of each socket address (protocol/network address/port) is normally permitted.', 10048), address: address, port: port);
            }
            return HttpServer.bind(address, port);
          },
        );

    test('the 5277x ports come first, then the 4177x ones below Windows\' dynamic range', () {
      expect(kBrowserBridgePorts, [for (var i = 0; i < 8; i++) 52772 + i, for (var i = 0; i < 8; i++) 41772 + i]);
      expect(kBrowserBridgePorts.toSet(), hasLength(kBrowserBridgePorts.length));
      expect(kBrowserBridgePorts.skip(8).every((p) => p < 49152), isTrue, reason: 'Hyper-V reserves ports in 49152 to 65535');
      expect(describePorts(kBrowserBridgePorts), '52772 to 52779 and 41772 to 41779');
      expect(describePorts(const [1, 2, 4, 7, 8]), '1 to 2, 4 and 7 to 8');
      expect(describePorts(const [5]), '5');
      // Extensions before 1.0.1 know only the 5277x ports.
      expect([for (final p in kBrowserBridgePorts) isFallbackPort(p)], [for (var i = 0; i < 16; i++) i >= 8]);
      expect(isFallbackPort(null), isFalse);
      expect(isFallbackPort(50123), isFalse, reason: 'a test\'s own port');
    });

    test('the extension looks on the same ports, in the same order', () {
      final js = File('../../extensions/browser/src/background.js').readAsStringSync();
      final list = RegExp(r'NEFORUM_PORTS \?\? \[([\d,\s]+)\]').firstMatch(js);
      expect(list, isNotNull, reason: 'const PORTS = globalThis.NEFORUM_PORTS ?? [...] in background.js');
      final ports = [for (final s in list!.group(1)!.split(',')) if (s.trim().isNotEmpty) int.parse(s.trim())];
      expect(ports, kBrowserBridgePorts);
    });

    test('access forbidden (10013) and EACCES count as refused; in use does not', () {
      SocketException err(int code) => SocketException('x', osError: OSError('x', code));
      expect(isPortRefused(err(10013)), isTrue);
      expect(isPortRefused(err(13)), isTrue);
      expect(isPortRefused(err(10048)), isFalse);
      expect(isPortRefused(err(98)), isFalse);
      expect(isPortRefused(err(-1)), isFalse);
      expect(isPortRefused(const SocketException('no OS error')), isFalse);
    });

    test('a port Windows refuses (reserved by Hyper-V) is skipped; the bridge listens on the next one', () async {
      final free = await _freePort();
      final tried = <int>[];
      final bridge = fakeBind([52772, 52773, free], refused: {52772, 52773}, tried: tried);
      addTearDown(bridge.dispose);
      await bridge.start();
      expect(bridge.status.value, BrowserBridgeStatus(BrowserBridgeState.listening, port: free));
      expect(tried, [52772, 52773, free]);
      final client = _client();
      addTearDown(() => client.close(force: true));
      expect((await _call(client, free, 'GET', '/v1/hello')).json['app'], 'NEFORUM');
    });

    test('nothing opens: blocked when the system refused a port, busy when all are in use', () async {
      final refused = fakeBind(const [52772, 52773, 41772], refused: {52772, 52773}, inUse: {41772});
      addTearDown(refused.dispose);
      await refused.start();
      expect(refused.status.value.state, BrowserBridgeState.portBlocked);

      final busy = fakeBind(const [52772, 41772], inUse: {52772, 41772});
      addTearDown(busy.dispose);
      await busy.start();
      expect(busy.status.value.state, BrowserBridgeState.portBusy);
    });

    // A port the system really refuses: port 135 is held exclusively by
    // Windows (RPC), which fails with 10013 like a reserved port, and is a
    // privileged port on Linux (EACCES unless root). Skipped where it opens.
    test('a port the system really refuses is skipped', () async {
      const refusedPort = 135;
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, refusedPort);
        await s.close();
        markTestSkipped('port $refusedPort opens here');
        return;
      } on SocketException catch (e) {
        if (!isPortRefused(e)) {
          markTestSkipped('port $refusedPort fails here with ${e.osError}');
          return;
        }
      }
      final free = await _freePort();
      final bridge = BrowserBridge.create(secrets: InMemorySecretStore(), ports: [refusedPort, free]);
      addTearDown(bridge.dispose);
      await bridge.start();
      expect(bridge.status.value, BrowserBridgeStatus(BrowserBridgeState.listening, port: free));

      final blocked = BrowserBridge.create(secrets: InMemorySecretStore(), ports: const [refusedPort]);
      addTearDown(blocked.dispose);
      await blocked.start();
      expect(blocked.status.value.state, BrowserBridgeState.portBlocked);
    });
  });

  test('settings: the browser extension flags survive JSON and default to on', () {
    expect(const AppSettings().browserExtension, isTrue);
    expect(AppSettings.fromJson(const {}).browserExtension, isTrue);
    final off = const AppSettings().copyWith(browserExtension: false);
    expect(off.toJson()['browserExtension'], isFalse);
    expect(AppSettings.fromJson(off.toJson()).browserExtension, isFalse);
    expect(AppSettings.fromJson(off.copyWith(browserExtension: true).toJson()).browserExtension, isTrue);

    expect(AppSettings.fromJson(const {}).browserQuickPost, isTrue);
    expect(AppSettings.fromJson(const {}).browserOpenInFirst, isTrue);
    final s = AppSettings.fromJson(const AppSettings().copyWith(browserQuickPost: false, browserOpenInFirst: false).toJson());
    expect((s.browserQuickPost, s.browserOpenInFirst), (false, false));
  });

  test('browser families: profiles and brands of one browser match', () {
    expect(browserFamily('Chrome'), 'chrome');
    expect(browserFamily('Google Chrome'), 'chrome');
    expect(browserFamily('Microsoft Edge'), 'edge');
    expect(browserFamily('Firefox'), 'firefox');
    expect(browserFamily('Brave'), 'brave');
    expect(browserFamily('Chromium'), 'chromium');
    expect(browserFamily('Chromium-based browser'), 'chromium');
    expect(browserFamily('Helium'), 'helium');
    expect(browserFamily('Browser'), 'browser');
  });

  test('guessing the program: "Chrome" is Google Chrome, never another Chromium browser', () {
    const installed = [_firefox, _chrome, _helium, _edge];
    expect(guessInstalledBrowser('Chrome', installed), _chrome);
    expect(guessInstalledBrowser('Chrome', const [_helium]), isNull, reason: 'Helium is not Chrome, even with chrome.exe');
    expect(guessInstalledBrowser('Firefox', installed), _firefox);
    expect(guessInstalledBrowser('Microsoft Edge', installed), _edge);
    expect(guessInstalledBrowser('Chromium-based browser', installed), isNull, reason: 'the user picks');
  });

  test('Windows: the registered browsers, each with its own program (Helium\'s chrome.exe is not Chrome\'s)', () {
    const out = r'''

HKEY_CURRENT_USER\SOFTWARE\Clients\StartMenuInternet\Helium.OO6APRPCII42OYXWF2EY5HUQ6A
    (Default)    REG_SZ    Helium

HKEY_CURRENT_USER\SOFTWARE\Clients\StartMenuInternet\Helium.OO6APRPCII42OYXWF2EY5HUQ6A\Capabilities
    ApplicationName    REG_SZ    Helium

HKEY_CURRENT_USER\SOFTWARE\Clients\StartMenuInternet\Helium.OO6APRPCII42OYXWF2EY5HUQ6A\DefaultIcon
    (Default)    REG_SZ    C:\Users\me\AppData\Local\imput\Helium\Application\chrome.exe,0

HKEY_CURRENT_USER\SOFTWARE\Clients\StartMenuInternet\Helium.OO6APRPCII42OYXWF2EY5HUQ6A\shell\open\command
    (Default)    REG_SZ    "C:\Users\me\AppData\Local\imput\Helium\Application\chrome.exe"

HKEY_LOCAL_MACHINE\SOFTWARE\Clients\StartMenuInternet\Google Chrome
    (Standard)    REG_SZ    Google Chrome

HKEY_LOCAL_MACHINE\SOFTWARE\Clients\StartMenuInternet\Google Chrome\shell\open\command
    (Standard)    REG_SZ    "C:\Program Files\Google\Chrome\Application\chrome.exe" --flag

HKEY_LOCAL_MACHINE\SOFTWARE\Clients\StartMenuInternet\IEXPLORE.EXE
    (Default)    REG_SZ    Internet Explorer

HKEY_LOCAL_MACHINE\SOFTWARE\Clients\StartMenuInternet\IEXPLORE.EXE\shell\open\command
    (Default)    REG_SZ    C:\Program Files\Internet Explorer\iexplore.exe

HKEY_CURRENT_USER\SOFTWARE\Clients\StartMenuInternet\WebThing
    (Default)    REG_SZ    (value not set)

HKEY_CURRENT_USER\SOFTWARE\Clients\StartMenuInternet\WebThing\shell\open\command
    (Default)    REG_SZ    C:\Apps\WebThing.exe

HKEY_CURRENT_USER\SOFTWARE\Clients\StartMenuInternet\NoCommand
    (Default)    REG_SZ    Broken
''';
    final found = parseStartMenuInternet(out);
    expect([for (final b in found) (b.name, b.id)], [
      ('Helium', r'C:\Users\me\AppData\Local\imput\Helium\Application\chrome.exe'),
      ('Google Chrome', r'C:\Program Files\Google\Chrome\Application\chrome.exe'),
      ('WebThing', r'C:\Apps\WebThing.exe'),
    ]);
  });

  testWidgets('Settings > Browser extension: status, pairing code, paired list', variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 1)), (tester) async {
    // The content width of the narrowest desktop window (420 minus gutters),
    // so overflows fail the test.
    tester.view.physicalSize = const Size(388, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    BrowserBridge.launcher = _FakeLauncher();
    addTearDown(() => BrowserBridge.launcher = const BrowserLauncher());

    // Made off the fake clock: the server answers real requests.
    final bridge = (await tester.runAsync(() async => BrowserBridge.create(secrets: InMemorySecretStore(), ports: const [0])))!;
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage(), browserBridge: bridge)))!;
    await tester.runAsync(services.startBrowserBridge);
    final port = bridge.status.value.port!;

    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: const Scaffold(body: SingleChildScrollView(child: BrowserExtensionSection())),
      ),
    ));
    await tester.pump();

    expect(find.text('Browser extension'), findsOneWidget);
    expect(find.text('Listening on port $port'), findsOneWidget);
    expect(find.text('None yet.'), findsOneWidget);
    expect(find.text('Show extension files'), findsOneWidget);
    expect(find.text('Guide'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Pair a browser'));
    await tester.pump();
    final code = bridge.pairing.value!.code;
    expect(find.text('${code.substring(0, 3)} ${code.substring(3)}'), findsOneWidget);
    expect(find.text('Works once, for 5:00 more.'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    // The extension pairs with that code.
    await tester.runAsync(() async {
      final client = _client();
      final r = await _call(client, port, 'POST', '/v1/pair', body: {'code': code, 'browser': 'Chrome'}, origin: 'chrome-extension://abc');
      expect(r.status, 200);
      client.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Paired with Chrome'), findsOneWidget);
    expect(find.textContaining('Last used just now'), findsOneWidget);
    // "Chrome" was guessed to be Google Chrome; it can be changed.
    final token = bridge.browsers.value.single.token;
    expect(find.text('Opens in '), findsOneWidget);
    expect(find.descendant(of: find.byKey(ValueKey('opens-in-$token')), matching: find.text('Google Chrome')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('opens-in-$token')));
    await tester.pumpAndSettle();
    expect(find.text('Other program…'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Helium').last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(bridge.browsers.value.single.app, _helium.id);
    expect(find.descendant(of: find.byKey(ValueKey('opens-in-$token')), matching: find.text('Helium')), findsOneWidget);
    expect(bridge.browsers.value.single.appName, 'Helium', reason: 'the tile is now called Helium');

    // A new code, cancelled.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Pair a browser'));
    await tester.pump();
    expect(bridge.pairing.value, isNotNull);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(bridge.pairing.value, isNull);

    // Remove.
    await tester.runAsync(() async {
      await tester.tap(find.text('Remove'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(bridge.browsers.value, isEmpty);
    expect(find.text('None yet.'), findsOneWidget);

    await tester.runAsync(bridge.dispose);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Settings > Browser extension: says why when Windows refuses every port', variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 1)), (tester) async {
    tester.view.physicalSize = const Size(388, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    BrowserBridge.launcher = _FakeLauncher();
    addTearDown(() => BrowserBridge.launcher = const BrowserLauncher());

    // Every port reserved (Hyper-V): 10013, "access forbidden".
    final tried = <int>[];
    final bridge = IoBrowserBridge(secrets: InMemorySecretStore(), clock: DateTime.now, ports: kBrowserBridgePorts, version: 'test', bind: (address, port) {
      tried.add(port);
      throw SocketException('Failed to create server socket',
          osError: const OSError('An attempt was made to access a socket in a way forbidden by its access permissions.', 10013), address: address, port: port);
    });
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage(), browserBridge: bridge)))!;
    await tester.runAsync(services.startBrowserBridge);
    expect(tried, kBrowserBridgePorts, reason: 'every port was tried, in order');
    expect(bridge.status.value.state, BrowserBridgeState.portBlocked);

    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: const Scaffold(body: SingleChildScrollView(child: BrowserExtensionSection())),
      ),
    ));
    await tester.pump();

    expect(find.text('Ports blocked'), findsOneWidget);
    expect(find.textContaining('NEFORUM could not open ports 52772 to 52779 and 41772 to 41779: Windows refused them.'), findsOneWidget);
    expect(find.textContaining('Hyper-V (used by WSL, Docker and Windows Sandbox)'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Pair a browser')).onPressed, isNull, reason: 'nothing to pair with');

    await tester.runAsync(bridge.dispose);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('hand-off: Open gives the extension the job, its result shows, Fill in again makes a new one',
      variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 1)), (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final launched = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), (call) async {
      if (call.method == 'launch') launched.add((call.arguments as Map)['url'] as String);
      return true;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    // No browser found: pages open in the default browser, as before.
    BrowserBridge.launcher = _FakeLauncher(installed: const []);
    addTearDown(() => BrowserBridge.launcher = const BrowserLauncher());

    final photoBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 9, 9, 9]);
    final bridge = (await tester.runAsync(() async => BrowserBridge.create(secrets: InMemorySecretStore(), ports: const [0])))!;
    // Outside the demo, which gives the extension nothing.
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('neforum-bridge-')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final services = (await tester.runAsync(() => AppServices.create(demo: false, storage: _MemoryStorage(photoBytes, dir.path), browserBridge: bridge)))!;
    await tester.runAsync(services.startBrowserBridge);
    final port = bridge.status.value.port!;

    final photo = MediaAttachment(id: 'one', path: 'C:/media/one.jpg', mimeType: 'image/jpeg', sizeBytes: photoBytes.length, fileName: 'logo.jpg');
    final plan = HandoffPlan(
      platformId: 'youtube_posts',
      instructions: '1. Paste the text.\n2. Press Post.',
      clipboardText: 'Which logo do you like?',
      shareFiles: [photo],
      snippets: const [HandoffSnippet('Answer 1', 'Diamond')],
      desktopUrl: 'https://www.youtube.com/@examplechannel/posts',
      preferred: HandoffMethod.manual,
    );
    final account = ConnectedAccount(id: 'yp', platformId: 'youtube_posts', tier: PlatformTier.handoff, displayName: 'YouTube Posts', createdAt: DateTime(2026, 10, 12));
    final post = Post(id: 'p1', text: 'Which logo do you like?', createdAt: DateTime(2026, 10, 12), updatedAt: DateTime(2026, 10, 12));
    Future<void> showSheet() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Scaffold(body: HandoffSheet(plan: plan, post: post, account: account, variant: PostVariant(text: 'Which logo do you like?', media: [photo]))),
        ),
      ));
      await tester.pump();
    }

    // Nobody paired yet: just a hint.
    await showSheet();
    expect(find.textContaining('Get the NEFORUM browser extension'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    final client = (await tester.runAsync(() async => _client()))!;
    addTearDown(() => client.close(force: true));
    final token = (await tester.runAsync(() async {
      final code = bridge.startPairing().code;
      return (await _call(client, port, 'POST', '/v1/pair', body: {'code': code, 'browser': 'Chrome'})).json['token'] as String;
    }))!;

    await showSheet();
    expect(find.textContaining('Get the NEFORUM browser extension'), findsNothing);
    expect(find.byTooltip('Copy photo'), findsOneWidget, reason: 'the copy buttons stay');
    expect(find.text('Copy next: Text'), findsOneWidget);

    await tester.tap(find.text('Open YouTube Posts'));
    await tester.pump();
    await tester.pump();
    expect(launched, ['https://www.youtube.com/@examplechannel/posts']);
    final job = bridge.job!;
    expect(job.target, isNull, reason: 'the default browser: any paired browser fills in');
    expect(job.quickPost, isTrue);
    expect(job.platformId, 'youtube_posts');
    expect(job.platformName, 'YouTube Posts');
    expect(job.hosts, ['www.youtube.com', 'youtube.com', 'm.youtube.com']);
    expect(job.text, 'Which logo do you like?');
    expect(job.snippets.single.text, 'Diamond');
    expect(job.steps, plan.instructions);
    expect(find.text('The NEFORUM extension is filling this in…'), findsOneWidget);

    // The extension fetches the job and the photo, fills the page and reports.
    await tester.runAsync(() async {
      final j = await _call(client, port, 'GET', '/v1/job?host=www.youtube.com', token: token, origin: 'chrome-extension://abc');
      expect(j.json['media'], [
        {'index': 0, 'name': 'logo.jpg', 'mimeType': 'image/jpeg', 'size': photoBytes.length, 'kind': 'image'},
      ]);
      final m = await _call(client, port, 'GET', '/v1/job/${job.id}/media/0', token: token, origin: 'chrome-extension://abc');
      expect(m.bytes, photoBytes);
      expect(m.headers.contentType?.mimeType, 'image/jpeg');
      final r = await _call(client, port, 'POST', '/v1/job/${job.id}/result', token: token, origin: 'chrome-extension://abc', body: {'status': 'filled', 'text': true, 'media': 1});
      expect(r.status, 204);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Filled in on youtube.com: text and 1 photo. Check it, then press Ctrl+Enter on the page (or Post).'), findsOneWidget);

    await tester.tap(find.text('Fill in again'));
    await tester.pump();
    expect(bridge.job!.id, isNot(job.id));
    expect(find.text('The NEFORUM extension is filling this in…'), findsOneWidget);

    await tester.runAsync(() async {
      final r = await _call(client, port, 'POST', '/v1/job/${bridge.job!.id}/result', token: token, body: {'status': 'partial', 'text': true, 'media': 0, 'message': 'The photo box did not open'});
      expect(r.status, 204);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Partly filled in on youtube.com: text. The photo box did not open. Do the rest with the steps below.'), findsOneWidget);

    // Closing the sheet drops the job.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(bridge.job, isNull);
    await tester.runAsync(bridge.dispose);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('hand-off: opens in the first-choice browser; a post confirmed from the page finishes the hand-off',
      variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 1)), (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final launched = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), (call) async {
      if (call.method == 'launch') launched.add((call.arguments as Map)['url'] as String);
      return true;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    final launcher = _FakeLauncher();
    BrowserBridge.launcher = launcher;
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      BrowserBridge.launcher = const BrowserLauncher();
    });

    final bridge = (await tester.runAsync(() async => BrowserBridge.create(secrets: InMemorySecretStore(), ports: const [0])))!;
    // Outside the demo, which gives the extension nothing.
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('neforum-bridge-')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final services = (await tester.runAsync(() => AppServices.create(demo: false, storage: _MemoryStorage(null, dir.path), browserBridge: bridge)))!;
    await tester.runAsync(services.startBrowserBridge);
    final port = bridge.status.value.port!;
    final client = (await tester.runAsync(() async => _client()))!;
    addTearDown(() => client.close(force: true));
    Future<String> pairAs(String label) async => (await tester.runAsync(() async {
          final code = bridge.startPairing().code;
          final token = (await _call(client, port, 'POST', '/v1/pair', body: {'code': code, 'browser': label})).json['token'] as String;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return token;
        }))!;
    // Google Chrome and Helium: both extensions say "Chrome".
    final chrome = await pairAs('Chrome');
    final helium = await pairAs('Chrome');
    await tester.runAsync(() async {
      await bridge.setProgram(helium, _helium);
      await bridge.makeFirst(helium);
    });

    const url = 'https://www.youtube.com/@examplechannel/posts';
    final plan = HandoffPlan(platformId: 'youtube_posts', instructions: '1. Press Post.', clipboardText: 'Hello', desktopUrl: url, preferred: HandoffMethod.manual);
    final account = ConnectedAccount(id: 'yp', platformId: 'youtube_posts', tier: PlatformTier.handoff, displayName: 'YouTube Posts', createdAt: DateTime(2026, 10, 12));
    final post = Post(id: 'p1', text: 'Hello', createdAt: DateTime(2026, 10, 12), updatedAt: DateTime(2026, 10, 12));
    HandoffChoice? choice;
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => choice = (await showHandoffSheet(context, plan: plan, post: post, account: account, variant: PostVariant(text: 'Hello'))).choice,
              child: const Text('Show'),
            ),
          ),
        ),
      ),
    ));
    Future<void> open() async {
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Open YouTube Posts'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      await tester.pump();
    }

    await open();
    expect(launcher.opened, [(_helium.id, url)], reason: 'Helium is the first choice, not whatever chrome.exe is');
    expect(launched, isEmpty, reason: 'not the default browser');
    expect(bridge.job!.target, _helium.id);
    expect(find.text('The NEFORUM extension in Helium is filling this in…'), findsOneWidget);

    final jobId = bridge.job!.id;
    await tester.runAsync(() async {
      final c = await _call(client, port, 'GET', '/v1/job?host=www.youtube.com', token: chrome);
      expect(c.json['preferred'], isFalse, reason: 'Google Chrome stays out of it');
      final h = await _call(client, port, 'GET', '/v1/job?host=www.youtube.com', token: helium);
      expect(h.json['preferred'], isTrue);
      expect(h.json['quickPost'], isTrue);
      final r = await _call(client, port, 'POST', '/v1/job/$jobId/result', token: helium, body: {'status': 'filled', 'text': true, 'media': 0, 'posted': 'confirmed'});
      expect(r.status, 204);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Posted on youtube.com. Marking this hand-off as done…'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(choice, HandoffChoice.posted, reason: 'the sheet closed itself as posted');
    expect(bridge.job, isNull);

    // Helium gone: the next one in the order, Google Chrome itself.
    launcher.gone.add(_helium.id);
    await open();
    expect(launcher.opened.last, (_chrome.id, url));
    expect(bridge.job!.target, _chrome.id);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    // None can start: the default browser, and any paired browser fills in.
    launcher.gone.add(_chrome.id);
    await open();
    expect(launched, [url]);
    expect(bridge.job!.target, isNull);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    await tester.runAsync(bridge.dispose);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('hand-off: with a paired browser, Tumblr opens its full composer instead of the text-only share tool',
      variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 1)), (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final launched = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), (call) async {
      if (call.method == 'launch') launched.add((call.arguments as Map)['url'] as String);
      return true;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    final launcher = _FakeLauncher();
    BrowserBridge.launcher = launcher;
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      BrowserBridge.launcher = const BrowserLauncher();
    });

    final bridge = (await tester.runAsync(() async => BrowserBridge.create(secrets: InMemorySecretStore(), ports: const [0])))!;
    // Outside the demo, which gives the extension nothing.
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('neforum-bridge-')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final services = (await tester.runAsync(() => AppServices.create(demo: false, storage: _MemoryStorage(Uint8List(3), dir.path), browserBridge: bridge)))!;
    await tester.runAsync(services.startBrowserBridge);
    final port = bridge.status.value.port!;

    final photo = MediaAttachment(id: 'one', path: 'C:/media/one.jpg', mimeType: 'image/jpeg', sizeBytes: 3, fileName: 'cat.jpg');
    final account = ConnectedAccount(id: 'tb', platformId: 'tumblr', tier: PlatformTier.handoff, displayName: 'Tumblr', createdAt: DateTime(2026, 10, 12));
    final post = Post(id: 'p1', text: 'A cat', createdAt: DateTime(2026, 10, 12), updatedAt: DateTime(2026, 10, 12));
    final variant = PostVariant(text: 'A cat', media: [photo]);
    final plan = services.registry.byId('tumblr')!.buildHandoff(variant, account: account)!;
    Future<void> show() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Scaffold(body: HandoffSheet(plan: plan, post: post, account: account, variant: variant)),
        ),
      ));
      await tester.pump();
    }

    // Nobody paired: the hand-off as before (a new photo post, files dragged in by hand).
    await show();
    expect(find.textContaining('Save media to Downloads'), findsWidgets);
    expect(find.textContaining('the NEFORUM browser extension adds'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    await tester.runAsync(() async {
      final client = _client();
      final code = bridge.startPairing().code;
      await _call(client, port, 'POST', '/v1/pair', body: {'code': code, 'browser': 'Chrome'});
      client.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await show();
    expect(find.text('Tumblr opens a new photo post (sign in if asked), and the NEFORUM browser extension adds your photo and the text.'), findsOneWidget);
    expect(find.textContaining("Tumblr's website cannot take files"), findsNothing, reason: 'the by-hand note is not shown');
    await tester.runAsync(() async {
      await tester.tap(find.text('Open Tumblr composer'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(launcher.opened, [(_chrome.id, 'https://www.tumblr.com/new/photo')]);
    expect(launched, isEmpty);
    expect(bridge.job!.url, 'https://www.tumblr.com/new/photo');
    expect(bridge.job!.hosts, contains('www.tumblr.com'));
    expect(bridge.job!.media.single.name, 'cat.jpg');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(bridge.dispose);
    await tester.pump(const Duration(seconds: 5));
  });
}

// Browsers as Windows lists them; Helium's program is chrome.exe too.
const _chrome = InstalledBrowser(id: r'C:\Program Files\Google\Chrome\Application\chrome.exe', name: 'Google Chrome');
const _helium = InstalledBrowser(id: r'C:\Users\me\AppData\Local\imput\Helium\Application\chrome.exe', name: 'Helium');
const _firefox = InstalledBrowser(id: r'C:\Program Files\Mozilla Firefox\firefox.exe', name: 'Mozilla Firefox');
const _edge = InstalledBrowser(id: r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe', name: 'Microsoft Edge');

late _FakeLauncher _launcher;

/// Pretends [installed] are installed (minus [gone]) and records what it opened.
class _FakeLauncher extends BrowserLauncher {
  _FakeLauncher({this.installed = const [_chrome, _edge, _firefox, _helium]});
  final List<InstalledBrowser> installed;
  final Set<String> gone = {};
  final List<(String, String)> opened = [];

  @override
  Future<List<InstalledBrowser>> list({bool refresh = false}) async => [for (final b in installed) if (!gone.contains(b.id)) b];

  @override
  Future<bool> available(String id) async => installed.any((b) => b.id == id) && !gone.contains(id);

  @override
  Future<bool> open(String id, Uri url) async {
    if (!await available(id)) return false;
    opened.add((id, '$url'));
    return true;
  }
}
