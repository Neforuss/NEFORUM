// Hand-off automation: Settings > Browser extension > Post automatically,
// the hand-off sheet that opens the page by itself and moves on once the
// extension posted, scheduled hand-offs posted through the extension while
// NEFORUM runs, the copy queue that advances when the user comes back, and
// sharing straight into the network's app on Android.

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
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/handoff/handoff_sheet.dart';
import 'package:neforum_app/ui/settings/browser_extension_section.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

final Uint8List _png = img.encodePng(img.Image(width: 4, height: 3)..clear(img.ColorRgb8(125, 0, 255)));

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

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  @override
  String? get dataDir => null;
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

/// A bridge on its own port with one paired browser, in services whose
/// settings turn automatic posting on (unless [automatic] is false).
Future<({AppServices services, BrowserBridge bridge, HttpClient client, int port, String token})> _setUp({bool automatic = true}) async {
  BrowserBridge.launcher = const _NoBrowsers();
  final bridge = BrowserBridge.create(secrets: InMemorySecretStore(), ports: const [0]);
  final services = await AppServices.create(demo: true, storage: _MemoryStorage(), browserBridge: bridge);
  await services.startBrowserBridge();
  final port = bridge.status.value.port!;
  final client = _client();
  final code = bridge.startPairing().code;
  final (_, paired) = await _call(client, port, 'POST', '/v1/pair', body: {'code': code, 'browser': 'Chrome'});
  await services.saveSettings(services.settings.copyWith(automaticHandoffPosting: automatic));
  return (services: services, bridge: bridge, client: client, port: port, token: paired!['token'] as String);
}

void main() {
  tearDown(() => BrowserBridge.launcher = const BrowserLauncher());

  test('settings: automatic posting is off by default; X, LinkedIn and Snapchat start left out', () {
    const s = AppSettings();
    expect(s.automaticHandoffPosting, isFalse);
    expect(s.postsHandoffAutomatically('youtube_posts'), isFalse, reason: 'off altogether');
    final on = AppSettings.fromJson(s.copyWith(automaticHandoffPosting: true).toJson());
    expect([for (final id in ['youtube_posts', 'pixiv', 'x', 'linkedin', 'snapchat']) on.postsHandoffAutomatically(id)], [true, true, false, false, false]);
    final withX = AppSettings.fromJson(on.copyWith(automaticHandoffExcludedPlatforms: const ['linkedin', 'snapchat']).toJson());
    expect(withX.postsHandoffAutomatically('x'), isTrue, reason: 'the user may put them back in');
  });

  test('the page automatic posting opens: the full composer, else the composer link, else the page', () {
    HandoffPlan plan({Uri? composer, Uri? intent, String? desktop}) =>
        HandoffPlan(platformId: 'p', instructions: '', composerUrl: composer, webIntent: intent, desktopUrl: desktop);
    expect(automaticHandoffPage(plan(composer: Uri.parse('https://a.example/new'), intent: Uri.parse('https://a.example/intent'))), Uri.parse('https://a.example/new'));
    expect(automaticHandoffPage(plan(intent: Uri.parse('https://a.example/intent'), desktop: 'https://a.example/')), Uri.parse('https://a.example/intent'));
    expect(automaticHandoffPage(plan(intent: Uri.parse('whatsapp://send?text=hi'), desktop: 'https://web.whatsapp.com/')), Uri.parse('https://web.whatsapp.com/'));
    expect(automaticHandoffPage(plan(desktop: 'instagram://')), isNull, reason: 'nothing a browser opens');
  });

  testWidgets('Settings: Post automatically, and the networks it applies to', variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 1)), (tester) async {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final env = (await tester.runAsync(() => _setUp(automatic: false)))!;
    addTearDown(() => env.client.close(force: true));
    await tester.runAsync(() => env.services.accounts.upsert(_account('yp', 'youtube_posts')));

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
    Future<void> showFor(ConnectedAccount account, HandoffPlan plan) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(env.services)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => choice = await showHandoffSheet(context, plan: plan, post: post, account: account, variant: variant),
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
    final served = await extension('GET', '/v1/job?host=www.youtube.com');
    expect(served!['autoPost'], isTrue);
    expect(served['poll'], {'kind': 'poll', 'imageOptions': false, 'options': ['Tea', 'Coffee']});

    await extension('POST', '/v1/job/${job.id}/result', {'status': 'filled', 'text': true, 'media': 0, 'automatic': 'countdown'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Filled in on youtube.com: text. The extension posts it in 3 seconds; Stop on the page keeps it unposted.'), findsOneWidget);
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
    await extension('POST', '/v1/job/${second.id}/result',
        {'status': 'partial', 'text': true, 'media': 0, 'automatic': 'manual', 'message': 'Not everything was filled in. Mark answer 2 as correct yourself.'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Not posted automatically. Not everything was filled in. Mark answer 2 as correct yourself. Finish the post on youtube.com, then click I posted it.'), findsOneWidget);
    expect(find.text('I posted it'), findsOneWidget);
    // Fill in again: by hand from here.
    await tester.tap(find.text('Fill in again'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // the status fades over
    expect(env.bridge.job!.autoPost, isFalse);
    expect(find.textContaining('Not posted automatically'), findsNothing);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(choice, HandoffChoice.later);

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

    await tester.runAsync(env.bridge.dispose);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  test('scheduled hand-offs: posted through the extension while NEFORUM runs; anything else stays waiting', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final env = await _setUp();
    addTearDown(() async {
      env.client.close(force: true);
      await env.bridge.dispose();
    });
    final s = env.services;
    await s.accounts.upsert(_account('yp', 'youtube_posts'));
    await s.accounts.upsert(_account('xa', 'x'));
    final opened = <Uri>[];
    final automatic = AutomaticHandoff(s, firstReport: const Duration(seconds: 5), openDefault: (url) async {
      opened.add(url);
      return true;
    });
    Post due(String id, List<String> accounts) => Post(
          id: id,
          text: 'Scheduled hello',
          createdAt: DateTime(2026, 10, 25),
          updatedAt: DateTime(2026, 10, 25),
          status: PostStatus.partial,
          targets: [for (final a in accounts) PostTarget(accountId: a, status: TargetStatus.awaitingHandoff)],
        );

    /// The extension's side: waits for the job, then reports [results].
    Future<Map<String, dynamic>> extension(List<Map<String, Object>> results) async {
      while (env.bridge.job == null) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final id = env.bridge.job!.id;
      final (_, job) = await _call(env.client, env.port, 'GET', '/v1/job?host=www.youtube.com', token: env.token);
      for (final r in results) {
        await _call(env.client, env.port, 'POST', '/v1/job/$id/result', token: env.token, body: r);
      }
      return job!;
    }

    // Posted: the target is handed off; X is left out by default, so it waits.
    var post = due('s1', ['yp', 'xa']);
    await s.posts.upsert(post);
    final served = extension([
      {'status': 'filled', 'text': true, 'media': 0, 'automatic': 'countdown'},
      {'status': 'filled', 'text': true, 'media': 0, 'automatic': 'countdown', 'posted': 'confirmed'},
    ]);
    post = await automatic.complete(post);
    expect((await served)['autoPost'], isTrue);
    expect(opened, [Uri.parse('https://www.youtube.com/')], reason: 'the default browser (no first choice installed)');
    expect(post.targetFor('yp')!.status, TargetStatus.handedOff);
    expect(post.targetFor('xa')!.status, TargetStatus.awaitingHandoff);
    expect(env.bridge.job, isNull, reason: 'the job is dropped afterwards');

    // Stopped on the page: still waiting, for the notification.
    post = due('s2', ['yp']);
    await s.posts.upsert(post);
    final stopped = extension([
      {'status': 'filled', 'text': true, 'media': 0, 'automatic': 'stopped'},
    ]);
    post = await automatic.complete(post);
    await stopped;
    expect(post.targetFor('yp')!.status, TargetStatus.awaitingHandoff);

    // An interactive run showed the sheet already; automatic posting off does nothing either.
    expect(await automatic.complete(due('s3', ['yp']), unattended: false), isA<Post>());
    await s.saveSettings(s.settings.copyWith(automaticHandoffPosting: false));
    opened.clear();
    final untouched = await automatic.complete(due('s4', ['yp']));
    expect(untouched.targetFor('yp')!.status, TargetStatus.awaitingHandoff);
    expect(opened, isEmpty);
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
