// 1.4.3: media for each part of a thread, at phone width, through the real
// composer widgets: every part has its own "Add media" and its own tray to
// swipe through; media stays with its part when parts move or go; the
// Settings choice switches between that and one tray for the post without
// losing anything; and the networks that put media in every post of a thread
// (X, Bluesky, Mastodon, Misskey) get each part's media on that part.

import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/editor_card.dart';
import 'package:neforum_app/ui/compose/media_tray.dart';
import 'package:neforum_app/ui/settings/posting_section.dart';
import 'package:neforum_app/widgets/buttons.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// Settings and drafts in memory; pictures drawn as plain boxes.
class _MemoryStorage implements AppStorage {
  final Map<String, Object> json = {
    'settings.json': {'onboarded': true, 'updateCheck': 'off'},
  };
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
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF808080)));
}

MediaAttachment _image(String id) => MediaAttachment(
      id: id,
      path: 'mem://$id.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: 2048,
      width: 1200,
      height: 1000,
      altText: 'Photo $id',
      fileName: '$id.jpg',
    );

ConnectedAccount _account(String platformId) => ConnectedAccount(
      id: 'acct-$platformId',
      platformId: platformId,
      tier: PlatformTier.openApi,
      displayName: platformId,
      createdAt: DateTime.utc(2026, 10, 1),
    );

/// The networks whose every thread post carries media, and one that keeps it
/// all on the first post.
const _perPartNetworks = ['x', 'bluesky', 'mastodon', 'misskey'];

class _Harness {
  late ProviderContainer container;
  final FocusNode focus = FocusNode();

  /// What the stand-in picker hands out, one call at a time.
  final List<List<MediaAttachment>> picks = [];
  int pickerCalls = 0;

  ComposerState get c => container.read(composerProvider);
  ComposerNotifier get n => container.read(composerProvider.notifier);

  Future<void> setLayout(ThreadMediaLayout layout) =>
      container.read(settingsProvider.notifier).update((s) => s.copyWith(threadMediaLayout: layout));
}

/// The composer's editors on a phone-sized page (390 x 844), on real
/// services with a stand-in picker.
Future<_Harness> _pump(WidgetTester t, {List<String> networks = _perPartNetworks}) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final s = (await t.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
  final h = _Harness();
  addTearDown(h.focus.dispose);
  final accounts = [for (final n in networks) _account(n)];
  await t.pumpWidget(ProviderScope(
    overrides: [
      servicesProvider.overrideWithValue(s),
      isDemoProvider.overrideWithValue(false),
      accountsProvider.overrideWith((ref) => Stream.value(accounts)),
      mediaPickerProvider.overrideWithValue((context) async {
        h.pickerCalls++;
        return (added: h.picks.isEmpty ? <MediaAttachment>[] : h.picks.removeAt(0), rejected: <String>[]);
      }),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AccentChoice.neforum),
      home: Scaffold(
        body: Builder(builder: (context) {
          h.container = ProviderScope.containerOf(context);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              EditorCard(focusNode: h.focus),
              const ThreadPartEditors(),
            ]),
          );
        }),
      ),
    ),
  ));
  await t.pump(const Duration(milliseconds: 100));
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await t.pump(const Duration(milliseconds: 100));
  h.n.reset(keepTargets: false);
  h.n.selectAccounts([for (final a in accounts) a.id]);
  await t.pump();
  return h;
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 80));
  }
}

Finder _tray(int part) => find.byKey(ValueKey('media-tray-$part'));
final Finder _postTray = find.byKey(const ValueKey('media-tray-post'));

/// The ids shown in a tray, left to right.
List<String> _shown(WidgetTester t, Finder tray) => [
      for (final e in t.widgetList<Padding>(find.descendant(of: tray, matching: find.byType(Padding))))
        if (e.key case ValueKey<String>(:final value) when !value.startsWith('media-tray')) value,
    ];

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await _settle(t);
}

void main() {
  testWidgets('every part has its own Add media, and each adds to its own part', (t) async {
    final h = await _pump(t);
    h.n.fillThread(['First part', 'Second part', 'Third part'], const [], const {});
    await _settle(t);

    // The first part adds with the editor's media button; the later parts
    // each have their own.
    expect(find.byKey(const ValueKey('part-add-media-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('part-add-media-2')), findsOneWidget);

    h.picks.add([_image('c1'), _image('c2')]);
    await _tap(t, find.byKey(const ValueKey('part-add-media-2')));
    expect(h.c.mediaParts, {'c1': 2, 'c2': 2});
    expect(_shown(t, _tray(2)), ['c1', 'c2']);
    expect(_tray(1), findsNothing);
    expect(_tray(0), findsNothing, reason: 'the first part has no media of its own yet');

    h.picks.add([_image('a1')]);
    await _tap(t, find.byTooltip('Add photos, videos or sound').first);
    expect(h.c.partOfMedia('a1'), 0);
    expect(_shown(t, _tray(0)), ['a1']);

    h.picks.add([_image('b1')]);
    await _tap(t, find.byKey(const ValueKey('part-add-media-1')));
    expect(_shown(t, _tray(1)), ['b1']);

    // The Add tile at the end of a part's tray adds to that part too.
    h.picks.add([_image('c3')]);
    await _tap(t, find.byKey(const ValueKey('media-tray-add-2')));
    expect(_shown(t, _tray(2)), ['c1', 'c2', 'c3']);
    expect(h.pickerCalls, 4);
    expect(_shown(t, _tray(0)), ['a1'], reason: 'nothing leaked into the first part');
    expect(t.takeException(), isNull, reason: 'nothing overflows at phone width');
  });

  testWidgets("a swipe goes through a part's media; a long press reorders it", (t) async {
    final h = await _pump(t);
    final media = [for (var i = 0; i < 6; i++) _image('m$i')];
    h.n.fillThread(['One', 'Two'], media, {for (final m in media) m.id: 1});
    await _settle(t);
    final tray = _tray(1);
    await t.ensureVisible(tray);
    await t.pump();
    final scrollable = find.descendant(of: tray, matching: find.byType(Scrollable)).first;
    final position = t.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0);

    // A sideways drag that starts on a photo scrolls the tray, as on a phone.
    await t.drag(find.byKey(const ValueKey('m1')), const Offset(-200, 0));
    await _settle(t);
    expect(position.pixels, greaterThan(100));
    expect([for (final m in h.c.mediaOfPart(1)) m.id], ['m0', 'm1', 'm2', 'm3', 'm4', 'm5'], reason: 'a swipe never reorders');

    // Long press, then move: the photo moves within its part.
    position.jumpTo(0);
    await _settle(t);
    final first = t.getCenter(find.byKey(const ValueKey('m0')));
    final gesture = await t.startGesture(first);
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(26, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await _settle(t);
    final order = [for (final m in h.c.mediaOfPart(1)) m.id];
    expect(order.first, isNot('m0'), reason: 'the long press picked m0 up and moved it');
    expect(order.toSet(), media.map((m) => m.id).toSet());
    expect(h.c.mediaParts.values.toSet(), {1}, reason: 'everything is still in part 2');
  });

  testWidgets('media stays with its part when parts move or are removed', (t) async {
    final h = await _pump(t);
    h.n.fillThread(['One', 'Two', 'Three'], [_image('a'), _image('b'), _image('c')], const {'a': 0, 'b': 1, 'c': 2});
    await _settle(t);

    // Part 3 moves up: its words and its photo go together.
    await _tap(t, find.byKey(const ValueKey('part-move-up-2')));
    expect([h.c.text, ...h.c.additionalParts], ['One', 'Three', 'Two']);
    expect(_shown(t, _tray(1)), ['c']);
    expect(_shown(t, _tray(2)), ['b']);
    expect(find.widgetWithText(TextField, 'Three'), findsOneWidget, reason: 'the fields show the new order');

    // Part 2 moves up to the top: it becomes the first part, with its photo.
    await _tap(t, find.byKey(const ValueKey('part-move-up-1')));
    expect([h.c.text, ...h.c.additionalParts], ['Three', 'One', 'Two']);
    expect(_shown(t, _tray(0)), ['c']);
    expect(_shown(t, _tray(1)), ['a']);
    expect(find.widgetWithText(TextField, 'Three'), findsOneWidget);

    // The last part cannot move further down.
    final down = t.widget<ToolButton>(find.byKey(const ValueKey('part-move-down-2')));
    expect(down.onPressed, isNull);

    // Removing part 3 hands its photo to part 2; Undo puts both back.
    await _tap(t, find.byTooltip('Remove part 3'));
    expect(h.c.additionalParts, ['One']);
    expect(_shown(t, _tray(1)), ['a', 'b']);
    await t.tap(find.text('Undo'));
    await _settle(t);
    expect(h.c.additionalParts, ['One', 'Two']);
    expect(_shown(t, _tray(1)), ['a']);
    expect(_shown(t, _tray(2)), ['b']);
    expect(h.c.media.map((m) => m.id).toSet(), {'a', 'b', 'c'}, reason: 'nothing was lost');
  });

  testWidgets('the Settings choice switches modes without losing media', (t) async {
    final h = await _pump(t);
    h.n.fillThread(['One', 'Two', 'Three'], [_image('a'), _image('b'), _image('c')], const {'b': 1, 'c': 2});
    await _settle(t);
    expect(_shown(t, _tray(0)), ['a']);
    expect(_shown(t, _tray(1)), ['b']);
    final parts = h.c.mediaParts;

    await h.setLayout(ThreadMediaLayout.singleTray);
    await _settle(t);
    // One tray with everything, a Part chip on each item, and no Add media
    // on the parts.
    expect(_shown(t, _postTray), ['a', 'b', 'c']);
    expect(_tray(1), findsNothing);
    expect(find.byKey(const ValueKey('part-add-media-1')), findsNothing);
    expect(find.descendant(of: _postTray, matching: find.text('Part 3')), findsOneWidget, reason: "c's Part chip");
    expect(h.c.mediaParts, parts, reason: 'switching leaves every photo in its part');

    // Added from the one tray (its Add tile is at the end, a swipe away): it
    // goes with the first part.
    await t.ensureVisible(_postTray);
    await t.drag(_postTray, const Offset(-400, 0));
    await _settle(t);
    h.picks.add([_image('d')]);
    await _tap(t, find.byKey(const ValueKey('media-tray-add-0')));
    expect(h.c.partOfMedia('d'), 0);

    await h.setLayout(ThreadMediaLayout.perPart);
    await _settle(t);
    expect(_postTray, findsNothing);
    expect(_shown(t, _tray(0)), ['a', 'd']);
    expect(_shown(t, _tray(1)), ['b']);
    expect(_shown(t, _tray(2)), ['c']);
  });

  test('the choice is stored, read back, and per part when missing or unknown', () {
    expect(const AppSettings().threadMediaLayout, ThreadMediaLayout.perPart);
    final json = const AppSettings(threadMediaLayout: ThreadMediaLayout.singleTray).toJson();
    expect(json['threadMediaLayout'], 'singleTray');
    expect(AppSettings.fromJson(json).threadMediaLayout, ThreadMediaLayout.singleTray);
    expect(AppSettings.fromJson(const {}).threadMediaLayout, ThreadMediaLayout.perPart);
    expect(AppSettings.fromJson(const {'threadMediaLayout': 'sideways'}).threadMediaLayout, ThreadMediaLayout.perPart);
  });

  testWidgets('Settings > Posting switches the choice', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = (await t.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    late ProviderContainer container;
    await t.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(s), isDemoProvider.overrideWithValue(false)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(
          body: Builder(builder: (context) {
            container = ProviderScope.containerOf(context);
            return const SingleChildScrollView(child: PostingSettingsSection());
          }),
        ),
      ),
    ));
    await _settle(t);
    expect(find.text('Media in a thread'), findsOneWidget);
    await _tap(t, find.text('One media tray for the post'));
    expect(container.read(settingsProvider).threadMediaLayout, ThreadMediaLayout.singleTray);
    await _tap(t, find.text('Media for each part'));
    expect(container.read(settingsProvider).threadMediaLayout, ThreadMediaLayout.perPart);
    expect(t.takeException(), isNull);
  });

  testWidgets('a single post keeps the one tray in either mode', (t) async {
    final h = await _pump(t);
    h.n.addMedia([_image('a')]);
    await _settle(t);
    expect(_shown(t, _postTray), ['a']);
    expect(_tray(0), findsNothing);
    await h.setLayout(ThreadMediaLayout.singleTray);
    await _settle(t);
    expect(_shown(t, _postTray), ['a']);
    expect(_tray(0), findsNothing);
  });

  testWidgets('publish sends each part its own media where every thread post carries media', (t) async {
    final h = await _pump(t, networks: [..._perPartNetworks, 'threads']);
    h.n.fillThread(['First part', 'Second part', 'Third part'], const [], const {});
    await _settle(t);
    h.picks
      ..add([_image('a')])
      ..add([_image('b1'), _image('b2')])
      ..add([_image('c')]);
    await _tap(t, find.byTooltip('Add photos, videos or sound').first);
    await _tap(t, find.byKey(const ValueKey('part-add-media-1')));
    await _tap(t, find.byKey(const ValueKey('part-add-media-2')));

    // The saved post is what the publish run reads.
    final post = h.c.toPost(id: 'p', status: PostStatus.draft, now: DateTime.utc(2026, 11, 13));
    expect(post.mediaParts, {'b1': 1, 'b2': 1, 'c': 2});
    final back = Post.fromJson(post.toJson());
    expect(back.mediaParts, post.mediaParts, reason: 'the stored post keeps the parts');

    final registry = h.container.read(registryProvider);
    const resolver = VariantResolver(ResolverOptions(threadNumbering: false));
    String base(MediaAttachment m) => m.derivedFrom ?? m.id;
    for (final id in _perPartNetworks) {
      final account = _account(id);
      final d = registry.byId(id)!.descriptorForAccount(account);
      expect(d.media.mediaPerThreadPart, isTrue, reason: id);
      final v = resolver.resolve(back, back.targetFor(account.id)!, d, account: account);
      expect(v.threadParts, ['First part', 'Second part', 'Third part'], reason: id);
      expect(v.mediaOfPart(0).map(base), ['a'], reason: id);
      expect(v.mediaOfPart(1).map(base), ['b1', 'b2'], reason: id);
      expect(v.mediaOfPart(2).map(base), ['c'], reason: id);
    }
    // The composer's own previews say the same.
    for (final p in h.container.read(composerPreviewsProvider).where((p) => _perPartNetworks.contains(p.account.platformId))) {
      expect([for (var i = 0; i < 3; i++) p.variant.mediaOfPart(i).map(base).toList()], [
        ['a'],
        ['b1', 'b2'],
        ['c'],
      ], reason: p.account.platformId);
    }

    // A network without media in every thread post gets it all on the first.
    final threads = _account('threads');
    final td = registry.byId('threads')!.descriptorForAccount(threads);
    expect(td.media.mediaPerThreadPart, isFalse);
    final tv = resolver.resolve(back, back.targetFor(threads.id)!, td, account: threads);
    expect(tv.mediaOfPart(0).map(base).toSet(), {'a', 'b1', 'b2', 'c'});
  });
}
