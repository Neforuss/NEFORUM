// Scratch: PNGs and numbers. Never committed.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/ui/compose/account_selection_grid.dart';
import 'package:neforum_app/ui/compose/action_bar.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/compose/target_picker.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

final out = Platform.environment['SHOT_OUT'] ?? '.';

class _M implements AppStorage {
  final Map<String, Object> json = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => json[name] = data;
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
    final l = FontLoader(name);
    for (final f in files) {
      l.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await l.load();
  }

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-SemiBold.ttf', 'assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
  await family('MaterialIcons', [r'C:\Users\theli\scoop\apps\flutter\current\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf']);
}

const _n = ['mastodon', 'bluesky', 'x', 'threads', 'instagram', 'facebook', 'linkedin', 'tiktok', 'youtube', 'pinterest', 'reddit', 'tumblr', 'telegram', 'discord', 'nostr', 'lemmy', 'wordpress', 'substack', 'snapchat', 'whatsapp', 'matrix'];

ConnectedAccount _a(String p, {String? id, String? handle, String? name, bool enabled = true}) =>
    ConnectedAccount(id: id ?? 'acct-$p', platformId: p, tier: builtinRegistry().descriptor(p)!.defaultTier, displayName: name ?? p, handle: handle, createdAt: DateTime.utc(2026, 10, 1), enabled: enabled);
List<ConnectedAccount> _21() => [for (final p in _n) _a(p)];
final _ed = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);

Future<ProviderContainer> _boot(WidgetTester t, List<ConnectedAccount> accounts, {Size size = const Size(360, 640), double scale = 1}) async {
  t.view.physicalSize = size * 2;
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final store = _M()..json['settings.json'] = {'updateCheck': 'off'};
  final services = (await t.runAsync(() => AppServices.create(demo: true, storage: store)))!;
  await t.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services), isDemoProvider.overrideWithValue(false), accountsProvider.overrideWith((ref) => Stream.value(accounts))], child: const NeforumApp()));
  await t.pump(const Duration(milliseconds: 300));
  final c = ProviderScope.containerOf(t.element(find.byType(MaterialApp)));
  if (scale != 1) await t.runAsync(() => c.read(settingsProvider.notifier).update((s) => s.copyWith(mobileTextScale: scale)));
  c.read(routerProvider).go('/compose');
  await t.pump();
  c.read(composerProvider.notifier).reset(keepTargets: false);
  await _s(t);
  return c;
}

Future<void> _s(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _end(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump(const Duration(seconds: 1));
}

Future<void> _shot(WidgetTester t, String name) async {
  await t.pump(const Duration(milliseconds: 400));
  final image = await captureImage(t.element(find.byType(MaterialApp)));
  final bytes = await t.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
  File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
  final bar = t.getRect(find.byType(ComposerActionBar)).top;
  final cells = t.elementList(find.byType(AccountCell)).map((e) => (e.renderObject! as RenderBox));
  final above = cells.where((b) => b.localToGlobal(Offset.zero).dy + b.size.height <= bar).length;
  debugPrint('SHOT $name: cells ${cells.length} above $above, bar $bar, field top ${_ed.evaluate().isEmpty ? '-' : t.getRect(_ed).top}, picker ${t.getRect(find.byType(TargetPicker))}');
}

void main() {
  setUpAll(_fonts);
  for (final (name, scale, b) in const [('default', 1.0, Brightness.light), ('text-1.5', 1.5, Brightness.light), ('dark', 1.0, Brightness.dark), ('dark-1.5', 1.5, Brightness.dark)]) {
    testWidgets('tiles $name', (t) async {
      t.platformDispatcher.platformBrightnessTestValue = b;
      addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
      final a = _21();
      a[15] = _a('lemmy', enabled: false);
      final c = await _boot(t, a, scale: scale);
      for (final id in const ['acct-threads', 'acct-reddit', 'acct-nostr']) {
        c.read(composerProvider.notifier).toggleAccount(id);
      }
      await _s(t);
      await _shot(t, 'fix-$name');
      await _end(t);
    });
  }
  final sets = <String, List<ConnectedAccount>>{
    'three-art': [..._21().take(18), _a('behance'), _a('cara'), _a('artstation')],
    'three-twice': [..._21().take(18), _a('mastodon', id: 'm2', handle: '@ben@social.example'), _a('bluesky', id: 'b2', handle: 'ben.bsky.social'), _a('x', id: 'x2', handle: '@ben')],
    'same-handle': [
      _a('matrix', id: 'r1', handle: '@ana:matrix.org', name: 'Family (@ana:matrix.org)'),
      _a('matrix', id: 'r2', handle: '@ana:matrix.org', name: 'Work (@ana:matrix.org)'),
      _a('wordpress', id: 's1', handle: 'julien', name: 'Julien (Cooking)'),
      _a('wordpress', id: 's2', handle: 'julien', name: 'Julien (Travel)'),
      _a('bluesky', id: 'a', handle: 'julien-barbier.bsky.social'),
      _a('bluesky', id: 'b', handle: 'julien-barbier.neforum.example'),
    ],
    'one-network': [for (var i = 0; i < 21; i++) _a('mastodon', id: 'm$i', handle: '@user$i@social.example')],
    'twelve': _21().take(12).toList(),
  };
  for (final e in sets.entries) {
    for (final scale in const [1.0, 1.5]) {
      testWidgets('set ${e.key} $scale', (t) async {
        await _boot(t, e.value, scale: scale);
        await _shot(t, 'fix-${e.key}-x$scale');
        await _end(t);
      });
    }
  }
  testWidgets('names on a tall phone', (t) async {
    final c = await _boot(t, _21(), size: const Size(360, 800));
    c.read(composerProvider.notifier).toggleAccount('acct-threads');
    await _s(t);
    await _shot(t, 'fix-tall-names');
    await _end(t);
  });
  for (final scale in const [1.0, 1.5]) {
    testWidgets('artwork $scale', (t) async {
      final c = await _boot(t, [_a('mastodon'), _a('behance'), _a('cara')], scale: scale);
      c.read(composerProvider.notifier).setArtwork(const ArtworkDetails());
      await _s(t);
      await _shot(t, 'fix-artwork-x$scale');
      await _end(t);
    });
  }
  testWidgets('fold with everything', (t) async {
    final b = [..._21().take(3), _a('threads', enabled: false), ..._21().skip(4).take(14), _a('behance'), _a('cara')];
    final c = await _boot(t, b);
    c.read(composerProvider.notifier).selectAccounts(const ['acct-mastodon', 'acct-bluesky', 'acct-x']);
    await _s(t);
    await t.tap(find.byKey(kTargetFoldKey));
    await _s(t);
    await _shot(t, 'fix-fold-only');
    await _end(t);
  });
}
