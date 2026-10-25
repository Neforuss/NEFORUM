// Hand-off automation: Settings > Browser extension > Post automatically,
// the hand-off sheet that opens the page by itself and moves on once the
// extension posted, scheduled hand-offs posted through the extension while
// NEFORUM runs (and stopped by Cancel in Activity), the copy queue that
// advances when the user comes back, and sharing straight into the
// network's app on Android.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/platform/browser_bridge.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/platform/ui_bridge.dart';
import 'package:neforum_app/state/automatic_handoff.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/scheduler.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/handoff/handoff_sheet.dart';
import 'package:neforum_app/ui/settings/browser_extension_section.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

final Uint8List _png = img.encodePng(img.Image(width: 4, height: 3)..clear(img.ColorRgb8(125, 0, 255)));

/// The ids two pages of a site send with their job requests.
const _pageA = 'page0000aaaa1111';
const _pageB = 'page0000bbbb2222';

/// flutter_test answers every HttpClient request with 400; the stand-in
/// extension needs the real client to reach the real bridge.
class _RealHttp extends HttpOverrides {}

HttpClient _client() => HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());

/// Calls the bridge on [port] as the extension would.
Future<(int, Map<String, dynamic>?)> _call(HttpClient client, int port, String method, String path, {String? token, Object? body}) async {
  final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
  req.headers.set('origin', 'chrome-extension://abc');
  if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  if (body != null) {
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
  }
  final res = await req.close();
  final text = await res.transform(utf8.decoder).join();
  return (res.statusCode, text.isEmpty ? null : jsonDecode(text) as Map<String, dynamic>);
}

/// Settings and media in memory; accounts and posts in [dataDir] (outside
/// the demo).
class _MemoryStorage implements AppStorage {
  _MemoryStorage([this.dataDir]);
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
  Future<Uint8List> readMedia(String path) async => _png;
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => const SizedBox();
}

/// No browser installed: pages open in the default browser.
class _NoBrowsers extends BrowserLauncher {
  const _NoBrowsers();
  @override
  Future<List<InstalledBrowser>> list({bool refresh = false}) async => const [];
  @override
  Future<bool> available(String id) async => false;
  @override
  Future<bool> open(String id, Uri url) async => false;
}

MediaAttachment _photo(String id) => MediaAttachment(id: id, path: '/data/user/0/org.neforum/files/media/$id.png', mimeType: 'image/png', sizeBytes: _png.length, fileName: '$id.png');

ConnectedAccount _account(String id, String platformId) =>
    ConnectedAccount(id: id, platformId: platformId, tier: PlatformTier.handoff, displayName: platformId, createdAt: DateTime(2026, 10, 25));

typedef _Env = ({AppServices services, BrowserBridge bridge, HttpClient client, int port, String token, Directory? dir});

/// A bridge on its own port with one paired browser, in services whose
/// settings turn automatic posting on (unless [automatic] is false). Outside
/// the demo (unless [demo]), since the demo never posts automatically; its
/// accounts and posts live in a folder of their own.
Future<_Env> _setUp({bool automatic = true, bool demo = false}) async {
  BrowserBridge.launcher = const _NoBrowsers();
  final bridge = BrowserBridge.create(secrets: InMemorySecretStore(), ports: const [0]);
  final dir = demo ? null : await Directory.systemTemp.createTemp('neforum-automatic-');
  final storage = _MemoryStorage(dir?.path);
  // Settings as a start reads them (saving them outside the demo would
  // reach for the keychain).
  await storage.writeJson('settings.json', AppSettings(automaticHandoffPosting: automatic).toJson());
  final services = await AppServices.create(demo: demo, storage: storage, browserBridge: bridge);
  await services.startBrowserBridge();
  final port = bridge.status.value.port!;
  final client = _client();
  final code = bridge.startPairing().code;
  final (_, paired) = await _call(client, port, 'POST', '/v1/pair', body: {'code': code, 'browser': 'Chrome'});
  return (services: services, bridge: bridge, client: client, port: port, token: paired!['token'] as String, dir: dir);
}

Future<void> _tearDown(_Env env) async {
  env.client.close(force: true);
  await env.bridge.dispose();
  env.services.dispose();
  await env.dir?.delete(recursive: true);
}

void main() {
  tearDown(() => BrowserBridge.launcher = const BrowserLauncher());

  test('settings: automatic posting is off by default; X, LinkedIn and Snapchat start left out; only sites the extension fills in by itself', () {
    const s = AppSettings();
    expect(s.automaticHandoffPosting, isFalse);
    expect(s.postsHandoffAutomatically('youtube_posts'), isFalse, reason: 'off altogether');
    final on = AppSettings.fromJson(s.copyWith(automaticHandoffPosting: true).toJson());
    expect([for (final id in ['youtube_posts', 'pixiv', 'x', 'linkedin', 'snapchat']) on.postsHandoffAutomatically(id)], [true, true, false, false, false]);
    final withX = AppSettings.fromJson(on.copyWith(automaticHandoffExcludedPlatforms: const ['linkedin', 'snapchat']).toJson());
    expect(withX.postsHandoffAutomatically('x'), isTrue, reason: 'the user may put them back in');
    for (final id in ['wordpress', 'ghost', 'devto', 'mastodon', 'misskey', 'telegram', 'lemmy', 'pixelfed']) {
      expect(on.postsHandoffAutomatically(id), isFalse, reason: '$id: the extension does not run on its pages by itself');
    }
  });

  test('every network that posts automatically has a recipe in the extension', () {
    final recipes = File('../../extensions/browser/src/content/recipes.js').readAsStringSync();
    for (final id in kAutomaticPostingPlatforms) {
      expect(RegExp('^    $id: ', multiLine: true).hasMatch(recipes), isTrue, reason: id);
    }
  });

  test('the page automatic posting opens: the full composer, else the composer link, else the page; only one the extension fills in by itself', () {
    HandoffPlan plan(String platformId, {Uri? composer, Uri? intent, String? desktop}) =>
        HandoffPlan(platformId: platformId, instructions: '', composerUrl: composer, webIntent: intent, desktopUrl: desktop);
    expect(automaticHandoffPage(plan('youtube_posts', composer: Uri.parse('https://www.youtube.com/@a/posts'), intent: Uri.parse('https://youtube.com/post'))),
        Uri.parse('https://www.youtube.com/@a/posts'));
    expect(automaticHandoffPage(plan('threads', intent: Uri.parse('https://www.threads.net/intent/post?text=hi'), desktop: 'https://www.threads.net/')),
        Uri.parse('https://www.threads.net/intent/post?text=hi'));
    expect(automaticHandoffPage(plan('whatsapp', intent: Uri.parse('whatsapp://send?text=hi'), desktop: 'https://web.whatsapp.com/')), Uri.parse('https://web.whatsapp.com/'));
    expect(automaticHandoffPage(plan('whatsapp', intent: Uri.parse('https://wa.me/?text=hi'))), Uri.parse('https://wa.me/?text=hi'), reason: 'wa.me goes on to WhatsApp Web');
    expect(automaticHandoffPage(plan('youtube', composer: Uri.parse('https://www.youtube.com/upload'))), Uri.parse('https://www.youtube.com/upload'));
    expect(automaticHandoffPage(plan('instagram', desktop: 'instagram://')), isNull, reason: 'nothing a browser opens');
    // Pages the content scripts do not run on by themselves: nothing would report back.
    expect(automaticHandoffPage(plan('substack', composer: Uri.parse('https://myblog.substack.com/publish/post'))), isNull);
    expect(automaticHandoffPage(plan('wordpress', composer: Uri.parse('https://myblog.wordpress.com/wp-admin/post-new.php'))), isNull);
    expect(automaticHandoffPage(plan('youtube_posts', composer: Uri.parse('http://www.youtube.com/@a/posts'))), isNull, reason: 'https pages only');
  });

  testWidgets('Settings: Post automatically, and the networks it applies to', variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 1)), (tester) async {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final env = (await tester.runAsync(() => _setUp(automatic: false, demo: true)))!;
    addTearDown(() => env.client.close(force: true));
    await tester.runAsync(() async {
      await env.services.accounts.upsert(_account('yp', 'youtube_posts'));
      await env.services.accounts.upsert(_account('wp', 'wordpress'));
    });

    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(env.services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: const Scaffold(body: SingleChildScrollView(child: BrowserExtensionSection())),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(find.text('Post automatically'), findsOneWidget);
    expect(find.text('Networks that post automatically'), findsNothing, reason: 'only once it is on');
    await tester.runAsync(() async {
      await tester.tap(find.text('Post automatically'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(env.services.settings.automaticHandoffPosting, isTrue);
    expect(find.text('Networks that post automatically'), findsOneWidget);
    expect(find.textContaining('The terms of X (Twitter), LinkedIn and Snapchat forbid scripted posting'), findsOneWidget);

    await tester.pump(); // the accounts, read once the row is shown

    FilterChip chip(String id) => tester.widget<FilterChip>(find.byKey(ValueKey('automatic-$id')));
    expect(chip('youtube_posts').selected, isTrue, reason: 'one of the user\'s hand-off networks');
    for (final id in kAutomationRestrictedPlatforms) {
      expect(chip(id).selected, isFalse, reason: '$id starts left out');
    }
    expect(find.byKey(const ValueKey('automatic-wordpress')), findsNothing, reason: 'the extension cannot post a blog by itself');

    // Leave YouTube Posts out; put X in, with a warning.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('automatic-youtube_posts')));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(env.services.settings.postsHandoffAutomatically('youtube_posts'), isFalse);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('automatic-x')));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(env.services.settings.postsHandoffAutomatically('x'), isTrue);
    expect(find.text('X (Twitter) forbids scripted posting: your account may be suspended.'), findsOneWidget);

    await tester.runAsync(env.bridge.dispose);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('hand-off: automatic posting opens the page by itself, the extension posts, the sheet moves on; when it does not post, the hand-off is the user\'s again',
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
    final env = (await tester.runAsync(() => _setUp()))!;
    addTearDown(() => env.client.close(force: true));
    // Read once off the fake clock; the sheet then finds them in memory.
    await tester.runAsync(() => env.services.accounts.all());
    Future<Map<String, dynamic>?> extension(String method, String path, [Object? body]) async {
      final r = await tester.runAsync(() => _call(env.client, env.port, method, path, token: env.token, body: body));
      return r?.$2;
    }

    const url = 'https://www.youtube.com/@examplechannel/posts';
    final plan = HandoffPlan(
      platformId: 'youtube_posts',
      instructions: '1. Press Post.',
      clipboardText: 'Tea or coffee?',
      desktopUrl: url,
      composerUrl: Uri.parse(url),
      preferred: HandoffMethod.manual,
    );
    const variant = PostVariant(text: 'Tea or coffee?', poll: PostPoll(options: ['Tea', 'Coffee']));
    final post = Post(id: 'p1', text: 'Tea or coffee?', createdAt: DateTime(2026, 10, 25), updatedAt: DateTime(2026, 10, 25));
    HandoffChoice? choice;
    Future<void> showFor(ConnectedAccount account, HandoffPlan plan, {Post? of}) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(env.services)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => choice = await showHandoffSheet(context, plan: plan, post: of ?? post, account: account, variant: variant),
                child: const Text('Show'),
              ),
            ),
          ),
        ),
      ));
      choice = null;
      await tester.tap(find.text('Show'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    // Posted automatically: nothing to click.
    await showFor(_account('yp', 'youtube_posts'), plan);
    expect(launched, [url], reason: 'opened by itself');
    final job = env.bridge.job!;
    expect(job.autoPost, isTrue);
    expect(job.details.poll?.options, ['Tea', 'Coffee']);
    expect(find.text('Posting automatically: the NEFORUM extension is filling this in…'), findsOneWidget);
    // While the extension posts, nothing opens or fills the page in a second time.
    expect(find.text('Open YouTube Posts composer'), findsNothing);
    expect(find.text('Fill in again'), findsNothing);
    final served = await extension('GET', '/v1/job?host=www.youtube.com&page=$_pageA');
    expect(served!['autoPost'], isTrue);
    expect(served['poll'], {'kind': 'poll', 'imageOptions': false, 'options': ['Tea', 'Coffee']});
    // Only that page posts it: another tab of the site gets it to fill in.
    expect((await extension('GET', '/v1/job?host=www.youtube.com&page=$_pageB'))!['autoPost'], isFalse);
    expect((await extension('GET', '/v1/job?host=www.youtube.com&page=$_pageA'))!['autoPost'], isTrue, reason: 'it asks again before Post');

    await extension('POST', '/v1/job/${job.id}/result', {'status': 'filled', 'text': true, 'media': 0, 'automatic': 'countdown'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Filled in on youtube.com: text. The extension posts it in 3 seconds; Stop on the page keeps it unposted.'), findsOneWidget);
    expect(find.text('Open YouTube Posts composer'), findsNothing);
    await extension('POST', '/v1/job/${job.id}/result', {'status': 'filled', 'text': true, 'media': 0, 'automatic': 'countdown', 'posted': 'confirmed'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Posted on youtube.com. Marking this hand-off as done…'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(choice, HandoffChoice.posted, reason: 'the run moves on to the next hand-off');
    expect(env.bridge.job, isNull);

    // Not posted on the page: the sheet says why and the hand-off is the user's.
    await showFor(_account('yp', 'youtube_posts'), plan);
    final second = env.bridge.job!;
    expect((await extension('GET', '/v1/job?host=www.youtube.com&page=$_pageA'))!['autoPost'], isTrue);
    await extension('POST', '/v1/job/${second.id}/result',
        {'status': 'partial', 'text': true, 'media': 0, 'automatic': 'manual', 'message': 'Not everything was filled in. Mark answer 2 as correct yourself.'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Not posted automatically. Not everything was filled in. Mark answer 2 as correct yourself. Finish the post on youtube.com, then click I posted it.'), findsOneWidget);
    expect(find.text('I posted it'), findsOneWidget);
    // No page posts it by itself any more, not even a new tab; the job stays for the user's own post.
    expect(env.bridge.job?.id, second.id);
    expect((await extension('GET', '/v1/job?host=www.youtube.com&page=$_pageA'))!['autoPost'], isFalse);
    expect((await extension('GET', '/v1/job?host=www.youtube.com&page=$_pageB'))!['autoPost'], isFalse);
    expect(find.text('Open YouTube Posts composer'), findsOneWidget);
    // Fill in again: by hand from here.
    await tester.tap(find.text('Fill in again'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // the status fades over
    expect(env.bridge.job!.autoPost, isFalse);
    expect(find.textContaining('Not posted automatically'), findsNothing);
    expect(find.text('Open YouTube Posts composer'), findsOneWidget);
    // A page filling in that job by hand is not waited on for a post.
    await extension('GET', '/v1/job?host=www.youtube.com&page=$_pageA');
    await tester.pump();
    await tester.pump(const Duration(minutes: 3));
    expect(find.textContaining('did not report back'), findsNothing);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(choice, HandoffChoice.later);

    // A page still fetching the job gets more time before the sheet gives up.
    await showFor(_account('yp', 'youtube_posts'), plan);
    await tester.pump(const Duration(seconds: 100));
    await extension('GET', '/v1/job?host=www.youtube.com&page=$_pageA');
    await tester.pump();
    await tester.pump(const Duration(seconds: 100));
    expect(find.textContaining('did not report back'), findsNothing, reason: '100 seconds since the page asked');
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('The NEFORUM extension did not report back, so nothing was posted automatically. Check the page, or click Fill in again.'), findsOneWidget);
    expect((await extension('GET', '/v1/job?host=www.youtube.com&page=$_pageA'))!['autoPost'], isFalse, reason: 'a late page does not post');
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    // An extension before 1.1.0 fills in but never posts.
    await showFor(_account('yp', 'youtube_posts'), plan);
    await extension('POST', '/v1/job/${env.bridge.job!.id}/result', {'status': 'filled', 'text': true, 'media': 0});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('your NEFORUM extension is older than 1.1.0 and does not post by itself'), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    // X is left out of automatic posting by default: nothing opens by itself.
    launched.clear();
    final xPlan = HandoffPlan(platformId: 'x', instructions: '1. Post.', clipboardText: 'Hi', webIntent: Uri.parse('https://x.com/intent/tweet?text=Hi'), composerUrl: Uri.parse('https://x.com/intent/tweet?text=Hi'));
    await showFor(_account('xa', 'x'), xPlan);
    expect(launched, isEmpty);
    expect(env.bridge.job, isNull);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    // An earlier automatic attempt pressed Post: it may be up, so the user finishes this one.
    const note = 'Post was pressed on youtube.com, but the post was not seen going up. Check the page before you post it again.';
    final noted = post.copyWith(targets: const [PostTarget(accountId: 'yp', status: TargetStatus.awaitingHandoff, handoffNote: note)]);
    await showFor(_account('yp', 'youtube_posts'), plan, of: noted);
    expect(launched, isEmpty);
    expect(env.bridge.job, isNull);
    expect(find.text(note), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    // Two YouTube Posts accounts: the browser posts as whichever is signed in, so neither posts by itself.
    await tester.runAsync(() async {
      await env.services.accounts.upsert(_account('yp', 'youtube_posts'));
      await env.services.accounts.upsert(_account('yp2', 'youtube_posts'));
    });
    await showFor(_account('yp2', 'youtube_posts'), plan);
    expect(launched, isEmpty);
    expect(env.bridge.job, isNull);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _tearDown(env));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the demo workspace: hand-offs never reach the extension, so its sample posts are not filled in or posted anywhere',
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
    final env = (await tester.runAsync(() => _setUp(demo: true)))!;
    addTearDown(() => env.client.close(force: true));
    expect(env.bridge.canFill, isTrue, reason: 'a paired browser, as outside the demo');
    expect(env.services.settings.automaticHandoffPosting, isTrue);
    expect(env.services.extensionFillsHandoffs, isFalse);

    const url = 'https://www.instagram.com/';
    final plan = HandoffPlan(platformId: 'instagram', instructions: '1. Share.', clipboardText: 'Workshop tour', desktopUrl: url, composerUrl: Uri.parse(url));
    final post = Post(id: 'demo-post-2', text: 'Workshop tour', createdAt: DateTime(2026, 10, 25), updatedAt: DateTime(2026, 10, 25));
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(env.services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(body: HandoffSheet(plan: plan, post: post, account: _account('ig', 'instagram'), variant: const PostVariant(text: 'Workshop tour'))),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(launched, isEmpty, reason: 'nothing opens by itself');
    expect(env.bridge.job, isNull);
    expect(find.textContaining('Get the NEFORUM browser extension'), findsNothing);

    // Opened by hand: the page opens, but the extension gets nothing to fill in.
    await tester.tap(find.text('Open Instagram'));
    await tester.pump();
    await tester.pump();
    expect(launched, [url]);
    expect(env.bridge.job, isNull);

    // Scheduled demo posts are not posted through the extension either.
    final opened = <Uri>[];
    final scheduled = post.copyWith(targets: const [PostTarget(accountId: 'ig', status: TargetStatus.awaitingHandoff)]);
    final after = (await tester.runAsync(() => AutomaticHandoff(env.services, openDefault: (url) async {
          opened.add(url);
          return true;
        }).complete(scheduled)))!;
    expect(opened, isEmpty);
    expect(after.targetFor('ig')!.status, TargetStatus.awaitingHandoff);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _tearDown(env));
    await tester.pump(const Duration(seconds: 5));
  });

  group('scheduled hand-offs', () {
    late _Env env;
    late AppServices s;
    final opened = <Uri>[];

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      env = await _setUp();
      s = env.services;
      opened.clear();
      await s.accounts.upsert(_account('yp', 'youtube_posts'));
      await s.accounts.upsert(_account('xa', 'x'));
    });
    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      await _tearDown(env);
    });

    AutomaticHandoff automatic({Duration firstReport = const Duration(seconds: 5)}) => AutomaticHandoff(s, firstReport: firstReport, openDefault: (url) async {
          opened.add(url);
          return true;
        });

    Future<Post> due(String id, List<String> accounts) async {
      final post = Post(
        id: id,
        text: 'Scheduled hello',
        createdAt: DateTime(2026, 10, 25),
        updatedAt: DateTime(2026, 10, 25),
        status: PostStatus.partial,
        targets: [for (final a in accounts) PostTarget(accountId: a, status: TargetStatus.awaitingHandoff)],
      );
      await s.posts.upsert(post);
      return post;
    }

    /// The extension's side: waits for the job, fetches it as [page], then
    /// reports [results] ([between] runs after the fetch).
    Future<Map<String, dynamic>> extension(List<Map<String, Object>> results, {Future<void> Function(String jobId)? between}) async {
      while (env.bridge.job == null) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final id = env.bridge.job!.id;
      final (_, job) = await _call(env.client, env.port, 'GET', '/v1/job?host=www.youtube.com&page=$_pageA', token: env.token);
      await between?.call(id);
      for (final r in results) {
        await _call(env.client, env.port, 'POST', '/v1/job/$id/result', token: env.token, body: r);
      }
      return job!;
    }

    const filled = {'status': 'filled', 'text': true, 'media': 0};

    test('posted through the extension while NEFORUM runs; X, left out, waits', () async {
      final served = extension([
        {...filled, 'automatic': 'countdown'},
        {...filled, 'automatic': 'countdown', 'posted': 'confirmed'},
      ]);
      final post = await automatic().complete(await due('s1', ['yp', 'xa']));
      expect((await served)['autoPost'], isTrue);
      expect(opened, [Uri.parse('https://www.youtube.com/')], reason: 'the default browser (no first choice installed)');
      expect(post.targetFor('yp')!.status, TargetStatus.handedOff);
      expect(post.targetFor('yp')!.handoffNote, isNull);
      expect(post.targetFor('xa')!.status, TargetStatus.awaitingHandoff);
      expect(env.bridge.job, isNull, reason: 'the job is dropped afterwards');
    });

    test('a page still fetching the job gets more time to report', () async {
      final served = extension([
        {...filled, 'automatic': 'countdown', 'posted': 'confirmed'},
      ], between: (id) async {
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          await _call(env.client, env.port, 'GET', '/v1/job?host=www.youtube.com&page=$_pageA', token: env.token);
        }
      });
      final post = await automatic(firstReport: const Duration(milliseconds: 500)).complete(await due('s2', ['yp']));
      await served;
      expect(post.targetFor('yp')!.status, TargetStatus.handedOff, reason: '750 ms in all, never 500 ms without a sign of the page');
    });

    test('stopped on the page: the job stays a while for a post made there; else the target keeps a note and is not posted automatically again', () async {
      // Stopped, then posted with the panel's Post now.
      var served = extension([
        {...filled, 'automatic': 'stopped'},
        {...filled, 'automatic': 'stopped', 'posted': 'confirmed'},
      ]);
      var post = await automatic().complete(await due('s3', ['yp']));
      await served;
      expect(post.targetFor('yp')!.status, TargetStatus.handedOff);

      // Stopped, and nothing more from the page.
      served = extension([
        {...filled, 'automatic': 'stopped'},
      ], between: (_) async {});
      post = await automatic(firstReport: const Duration(milliseconds: 600)).complete(await due('s4', ['yp']));
      await served;
      final target = post.targetFor('yp')!;
      expect(target.status, TargetStatus.awaitingHandoff);
      expect(target.handoffNote, 'Automatic posting was stopped on youtube.com before Post was pressed. If you posted it there yourself, mark it as posted.');
      expect((await s.posts.get('s4'))!.targetFor('yp')!.handoffNote, target.handoffNote, reason: 'kept with the post');

      opened.clear();
      post = await automatic().complete(post);
      expect(opened, isEmpty, reason: 'it may have been posted by hand: the user finishes it');
    });

    test('Post pressed without a sign it went: the target waits with a note; the notification says what to check', () async {
      final served = extension([
        {...filled, 'automatic': 'countdown'},
        {...filled, 'automatic': 'countdown', 'posted': 'pressed'},
      ]);
      final post = await automatic().complete(await due('s5', ['yp']));
      await served;
      final target = post.targetFor('yp')!;
      expect(target.status, TargetStatus.awaitingHandoff);
      expect(target.handoffNote, 'Post was pressed on youtube.com, but the post was not seen going up. Check the page before you post it again.');
      expect(env.bridge.job, isNull);
    });

    test('Cancel before the hand-off: nothing opens; the hand-off that would have been posted becomes cancelled, X still waits', () async {
      final signal = CancellationSignal()..cancel();
      final post = await automatic().complete(await due('s6', ['yp', 'xa']), cancellation: signal);
      expect(opened, isEmpty);
      expect(post.targetFor('yp')!.status, TargetStatus.cancelled);
      expect(post.targetFor('xa')!.status, TargetStatus.awaitingHandoff);
      expect((await s.posts.get('s6'))!.targetFor('yp')!.status, TargetStatus.cancelled);
    });

    test('Cancel while the page loads: the job goes, so nothing is posted; Cancel during the countdown stops the press', () async {
      // While the page loads.
      final signal = CancellationSignal();
      var served = extension(const [], between: (_) async => signal.cancel());
      var post = await automatic().complete(await due('s7', ['yp']), cancellation: signal);
      await served;
      expect(post.targetFor('yp')!.status, TargetStatus.cancelled);
      expect(env.bridge.job, isNull);

      // During the countdown: the page, asking again before Post, hears that it must not post.
      final counting = CancellationSignal();
      Map<String, dynamic>? before;
      served = extension([], between: (id) async {
        await _call(env.client, env.port, 'POST', '/v1/job/$id/result', token: env.token, body: {...filled, 'automatic': 'countdown'});
        counting.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        (_, before) = await _call(env.client, env.port, 'GET', '/v1/job?host=www.youtube.com&page=$_pageA', token: env.token);
        await _call(env.client, env.port, 'POST', '/v1/job/$id/result', token: env.token, body: {...filled, 'automatic': 'stopped'});
      });
      post = await automatic().complete(await due('s8', ['yp']), cancellation: counting);
      await served;
      expect(before!['autoPost'], isFalse);
      expect(post.targetFor('yp')!.status, TargetStatus.cancelled);

      // A press already under way when Cancel came: what went out counts.
      final late = CancellationSignal();
      served = extension([], between: (id) async {
        await _call(env.client, env.port, 'POST', '/v1/job/$id/result', token: env.token, body: {...filled, 'automatic': 'countdown'});
        late.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await _call(env.client, env.port, 'POST', '/v1/job/$id/result', token: env.token, body: {...filled, 'automatic': 'countdown', 'posted': 'confirmed'});
      });
      post = await automatic().complete(await due('s9', ['yp']), cancellation: late);
      await served;
      expect(post.targetFor('yp')!.status, TargetStatus.handedOff);
    });

    test('two accounts on one network: neither is posted automatically', () async {
      await s.accounts.upsert(_account('yp2', 'youtube_posts'));
      final post = await automatic().complete(await due('s10', ['yp', 'yp2']));
      expect(opened, isEmpty);
      expect([for (final t in post.targets) t.status], [TargetStatus.awaitingHandoff, TargetStatus.awaitingHandoff]);
    });

    test('an interactive run showed the sheet already; automatic posting off does nothing either', () async {
      expect(await automatic().complete(await due('s11', ['yp']), unattended: false), isA<Post>());
      expect(opened, isEmpty);
      final off = await _setUp(automatic: false);
      addTearDown(() => _tearDown(off));
      await off.services.accounts.upsert(_account('yp', 'youtube_posts'));
      final post = Post(
        id: 's12',
        text: 'Scheduled hello',
        createdAt: DateTime(2026, 10, 25),
        updatedAt: DateTime(2026, 10, 25),
        status: PostStatus.partial,
        targets: const [PostTarget(accountId: 'yp', status: TargetStatus.awaitingHandoff)],
      );
      final untouched = await AutomaticHandoff(off.services, openDefault: (url) async {
        opened.add(url);
        return true;
      }).complete(post);
      expect(untouched.targetFor('yp')!.status, TargetStatus.awaitingHandoff);
      expect(opened, isEmpty);
    });

    test('the scheduler passes its run\'s signal on: Cancel in Activity also stops the automatic hand-off that follows', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final launched = <String>[];
      messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), (call) async {
        if (call.method == 'launch') launched.add((call.arguments as Map)['url'] as String);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), null));
      await s.posts.upsert(Post(
        id: 'due1',
        text: 'Scheduled hello',
        createdAt: DateTime(2026, 10, 25),
        updatedAt: DateTime(2026, 10, 25),
        scheduledAt: DateTime.now().subtract(const Duration(minutes: 1)),
        status: PostStatus.scheduled,
        targets: const [PostTarget(accountId: 'yp')],
      ));
      final container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(s)]);
      addTearDown(container.dispose);

      final run = container.read(schedulerProvider).runDue();
      // The page asks for the job; then the user presses Cancel in Activity.
      await extension(const []);
      expect(launched, ['https://www.youtube.com/']);
      expect(container.read(activePublishingProvider), contains('due1'), reason: 'Activity offers Cancel while the hand-off goes');
      container.read(activePublishingProvider.notifier).cancel('due1');
      final done = await run;
      expect(done.single.targetFor('yp')!.status, TargetStatus.cancelled);
      expect(env.bridge.job, isNull, reason: 'no page can post it any more');
      expect(container.read(activePublishingProvider), isEmpty);
    });
  });

  testWidgets('phones: Share goes straight into the network\'s app; on return the next part is copied, photos as pictures',
      variant: TargetPlatformVariant.only(TargetPlatform.android), timeout: const Timeout(Duration(minutes: 1)), (tester) async {
    // Wide enough for the test font, which is wider than any real one.
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shares = <Map<Object?, Object?>>[];
    final images = <Map<Object?, Object?>>[];
    final texts = <String>[];
    var imageOk = true;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('neforum/share'), (call) async {
      shares.add(call.arguments as Map<Object?, Object?>);
      return 'app';
    });
    messenger.setMockMethodCallHandler(const MethodChannel('neforum/clipboard'), (call) async {
      images.add(call.arguments as Map<Object?, Object?>);
      return imageOk;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') texts.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() {
      for (final c in ['neforum/share', 'neforum/clipboard']) {
        messenger.setMockMethodCallHandler(MethodChannel(c), null);
      }
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    final photos = [_photo('one'), _photo('two')];
    final plan = HandoffPlan(
      platformId: 'instagram',
      instructions: '1. Share.\n2. Paste the caption.',
      clipboardText: 'My caption',
      shareFiles: photos,
      snippets: const [HandoffSnippet('Tags', '#art #violet')],
      androidPackage: 'com.instagram.android',
      preferred: HandoffMethod.shareSheet,
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(
          body: HandoffSheet(
            plan: plan,
            post: Post(id: 'p1', text: 'My caption', createdAt: DateTime(2026, 10, 25), updatedAt: DateTime(2026, 10, 25)),
            account: _account('ig', 'instagram'),
            variant: PostVariant(text: 'My caption', media: photos),
          ),
        ),
      ),
    ));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await tester.tap(find.text('Share 2 files to Instagram'));
    await tester.pump();
    await tester.pump();
    expect(shares.single, {
      'package': 'com.instagram.android',
      'paths': [photos[0].path, photos[1].path],
      'mimeTypes': ['image/png', 'image/png'],
      'text': 'My caption',
    });
    expect(texts, ['My caption'], reason: 'the caption is on the clipboard too');
    expect(find.text('Text copied. Paste it in the app, then come back here: the next part is copied for you.'), findsOneWidget);

    Future<void> leaveAndComeBack() async {
      await tester.runAsync(() async {
        for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        // Decoding and encoding a photo happen off the fake clock.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
    }

    await leaveAndComeBack();
    expect(texts.last, '#art #violet');
    expect(find.text('Tags copied. Paste it in the app.'), findsOneWidget);

    await leaveAndComeBack();
    expect(images, hasLength(1));
    expect(images.single.keys.toSet(), {'png'}, reason: 'a phone pastes the picture: no file path, no Windows bitmap');
    expect(find.text('Photo 1 of 2 copied. Paste it in the app.'), findsOneWidget);

    // A photo that cannot be copied is skipped, with a note.
    imageOk = false;
    await leaveAndComeBack();
    expect(find.text('Photo 2 of 2 could not be copied here, so it was skipped. That was the last part: everything has been copied.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('phones: the app is missing, so the share sheet opens; no advancing when the setting is off',
      variant: TargetPlatformVariant.only(TargetPlatform.android), timeout: const Timeout(Duration(minutes: 1)), (tester) async {
    // Wide enough for the test font, which is wider than any real one.
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shares = <Map<Object?, Object?>>[];
    final texts = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('neforum/share'), (call) async {
      shares.add(call.arguments as Map<Object?, Object?>);
      return 'chooser';
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') texts.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('neforum/share'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    await tester.runAsync(() => services.saveSettings(services.settings.copyWith(advanceHandoffOnReturn: false)));
    final plan = HandoffPlan(
      platformId: 'snapchat',
      instructions: '1. Share.',
      clipboardText: 'Caption',
      shareFiles: [_photo('one')],
      snippets: const [HandoffSnippet('Topic', '#art')],
      androidPackage: 'com.snapchat.android',
      preferred: HandoffMethod.shareSheet,
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(
          body: HandoffSheet(
            plan: plan,
            post: Post(id: 'p2', text: 'Caption', createdAt: DateTime(2026, 10, 25), updatedAt: DateTime(2026, 10, 25)),
            account: _account('sc', 'snapchat'),
            variant: PostVariant(text: 'Caption', media: [_photo('one')]),
          ),
        ),
      ),
    ));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.tap(find.text('Share photo to Snapchat'));
    await tester.pump();
    await tester.pump();
    expect(shares.single['package'], 'com.snapchat.android');
    expect(find.textContaining('come back here'), findsNothing, reason: 'advance on return is off');
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect(texts, ['Caption'], reason: 'nothing more was copied');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}
