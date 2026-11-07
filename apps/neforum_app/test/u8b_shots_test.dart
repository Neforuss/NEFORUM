// TEMPORARY, never committed: renders the evidence PNGs.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/brand/platform_brand.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _S implements AppStorage {
  final Map<String, Object> _json = {'x': 1};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] is Map ? _json[name] as Map<String, dynamic> : null;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}

Future<void> _fonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  final root = Platform.environment['FLUTTER_ROOT'] ?? '';
  final pub = Platform.environment['PUB_CACHE'] ?? '${Platform.environment['LOCALAPPDATA']}\\Pub\\Cache';
  final fa = '$pub/hosted/pub.dev/font_awesome_flutter-11.0.0/lib/fonts';
  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-SemiBold.ttf', 'assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
  await family('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf']);
  await family('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  await family('packages/font_awesome_flutter/FontAwesomeBrands', ['$fa/Font-Awesome-7-Brands-Regular-400.otf']);
  await family('packages/font_awesome_flutter/FontAwesomeSolid', ['$fa/Font-Awesome-7-Free-Solid-900.otf']);
}

SignInStatus st(ConnectedAccount a, Map<String, String> keys, AdapterRegistry r, {DateTime? refused}) {
  final now = DateTime.now();
  final life = deriveSignInLifetime(r.byId(a.platformId)!.signInPolicyFor(a), keys, now: now);
  return SignInStatus.fromLifetime(a.id, life, hasConnection: true, lastAuthFailure: refused, lastConfirmedAt: now.subtract(const Duration(days: 2)));
}

Future<void> shoot(WidgetTester tester, String path, Size size, Brightness b, {double scroll = 0}) async {
  debugDefaultTargetPlatformOverride = size.width > 720 ? TargetPlatform.windows : TargetPlatform.android;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.platformBrightnessTestValue = b;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  final now = DateTime.now();
  String iso(DateTime t) => t.toUtc().toIso8601String();
  String ahead(int days) => iso(now.add(Duration(days: days)));
  final services = (await tester.runAsync(() async {
    final s = await AppServices.create(demo: true, storage: _S());
    for (final a in await s.accounts.all()) {
      await s.accounts.delete(a.id);
    }
    for (final p in await s.posts.all()) {
      await s.posts.delete(p.id);
    }
    await s.signInStatusStore.clear();
    final r = s.registry;
    ConnectedAccount acc(String p, PlatformTier t, String name, String handle, [Map<String, dynamic> c = const {}]) => ConnectedAccount(id: 'a-$p', platformId: p, tier: t, displayName: name, handle: handle, createdAt: now, config: c);
    final list = <(ConnectedAccount, Map<String, String>?)>[
      (acc('linkedin', PlatformTier.byokApi, 'Robin Okafor', 'Robin Okafor'), {'access_token': '-', 'expires_at': ahead(3)}),
      (acc('threads', PlatformTier.byokApi, 'Robin', '@robin.makes'), {'access_token': '-', 'token_issued_at': iso(now.subtract(const Duration(days: 49))), 'expires_at': ahead(11), 'expires_at_source': 'computed'}),
      (acc('tumblr', PlatformTier.byokApi, 'robinmakes', 'robinmakes.tumblr.com'), {'access_token': '-', 'refresh_token': '-', 'last_renewed_at': iso(now.subtract(const Duration(days: 8)))}),
      (acc('youtube', PlatformTier.byokApi, 'Robin Makes', '@robinmakes'), {'access_token': '-', 'refresh_token': '-', 'last_renewed_at': iso(now.subtract(const Duration(days: 20)))}),
      (acc('x', PlatformTier.byokApi, 'Robin', '@robinmakes', {'authMode': 'oauth1'}), {'token': '-'}),
      (acc('mastodon', PlatformTier.openApi, 'Robin', '@robin@fosstodon.org', {'software': 'mastodon'}), {'access_token': '-'}),
      (acc('bluesky', PlatformTier.openApi, 'Robin', '@robin.bsky.social'), {'access_token': '-', 'app_password': '-'}),
      (acc('reddit', PlatformTier.byokApi, 'u/robinmakes', 'u/robinmakes'), {'access_token': '-', 'refresh_token': '-'}),
      (acc('telegram', PlatformTier.openApi, "Robin's Workshop", '@robinsworkshop'), {'bot_token': '-'}),
      (acc('inkbunny', PlatformTier.openApi, 'robin', 'robin'), {'sid': '-'}),
      (acc('instagram', PlatformTier.handoff, 'robin.makes', '@robin.makes'), null),
      (acc('snapchat', PlatformTier.handoff, 'robinmakes', 'robinmakes'), null),
    ];
    for (final (a, keys) in list) {
      await s.accounts.upsert(a);
      if (keys != null) await s.signInStatusStore.change(a.id, (_) => st(a, keys, r));
    }
    await s.posts.upsert(Post(
      id: 'late',
      text: 'After the end date.',
      createdAt: now,
      updatedAt: now,
      scheduledAt: now.add(const Duration(days: 6)),
      status: PostStatus.scheduled,
      targets: const [PostTarget(accountId: 'a-linkedin')],
    ));
    return s;
  }))!;
  await tester.pumpWidget(RepaintBoundary(key: const ValueKey('shot'), child: ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp())));
  await tester.pump(const Duration(milliseconds: 300));
  final context = tester.element(find.byType(MaterialApp));
  await tester.runAsync(() => Future.wait([
        for (final id in platformBrands.keys)
          if (platformIconAsset(id) case final asset?) precacheImage(AssetImage(asset), context),
      ]));
  final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  c.read(routerProvider).go('/accounts/sign-ins');
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 150));
  }
  if (scroll != 0) {
    await tester.drag(find.byType(Scrollable).last, Offset(0, -scroll));
    await tester.pump(const Duration(milliseconds: 500));
  }
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  File(path).writeAsBytesSync(bytes!);
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  setUpAll(_fonts);
  const dir = r'C:\Temp\claude\e9b66b1ef73143eb\58a31c78-c9f1-466a-a3b0-8761e9506077\scratchpad\critique\U8b';
  testWidgets('desktop', (t) => shoot(t, '$dir\\b-desktop.png', const Size(1100, 800), Brightness.light));
  testWidgets('phone', (t) => shoot(t, '$dir\\b-phone.png', const Size(360, 640), Brightness.light));
  testWidgets('desktop tall', (t) => shoot(t, '$dir\\b-desktop-tall.png', const Size(1100, 1500), Brightness.dark));
  testWidgets('phone tall', (t) => shoot(t, '$dir\\b-phone-tall.png', const Size(360, 2100), Brightness.dark));
}
