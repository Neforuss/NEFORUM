// 1.3.4: a photo dump in the composer. Twenty photos go to every network
// split by its own limits (a thread on X, Bluesky and Mastodon, one carousel
// where they fit, a series of posts elsewhere), never dropped, and every
// network's preview shows its posts.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  final Map<String, Uint8List> _media = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async {
    final path = 'mem://$id.$extension';
    _media[path] = bytes;
    return path;
  }

  @override
  Future<Uint8List> readMedia(String path) async => _media[path] ?? (throw StateError('No file at $path'));
  @override
  Future<void> deleteMedia(String path) async => _media.remove(path);
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF777777)));
}

Future<void> _loadFonts() async {
  final loader = FontLoader('Inter');
  for (final f in ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']) {
    loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
  }
  await loader.load();
}

MediaAttachment _photo(int i) => MediaAttachment(
      id: 'holiday-$i',
      path: 'mem://holiday-$i.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: 200000,
      width: 1080,
      height: 1080,
      altText: 'Holiday photo ${i + 1}',
      fileName: 'holiday-$i.jpg',
    );

void main() {
  setUpAll(_loadFonts);

  testWidgets('twenty photos: every network carries all of them within its own limits, and shows its posts', (tester) async {
    tester.view.physicalSize = const Size(1440, 9000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
    await tester.pump(const Duration(milliseconds: 300));
    final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    c.read(routerProvider).go('/compose');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), 'Holiday');
    final photos = [for (var i = 0; i < 20; i++) _photo(i)];
    final accounts = c.read(accountListProvider);
    c.read(composerProvider.notifier)
      ..addMedia(photos)
      ..selectAccounts([for (final a in accounts) a.id]);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    final previews = c.read(composerPreviewsProvider);
    expect(previews, isNotEmpty);
    final report = <String>[];
    for (final p in previews) {
      final d = p.descriptor;
      final v = p.variant;
      final m = d.media;
      final name = '${d.name} (${p.account.tier.name})';
      // The photos this network carries, over all of its posts. Fitted copies
      // stand in for some photos, so count by the photo each one stands for.
      final carried = [...v.media, for (final s in v.seriesPosts) ...s.media]
          .where((x) => x.kind == MediaKind.image && !x.isTextCard)
          .map((x) => x.derivedFrom ?? x.id)
          .toList();
      if (m.maxImages == 0 || (m.maxImages == 0 && m.maxVideos == 0)) {
        report.add('$name: takes no photos');
        continue;
      }
      final dropped = p.issues.where((i) => i.code == 'media.dropped').map((i) => i.message).toList();
      expect(dropped, isEmpty, reason: '$name drops nothing');
      if (p.account.tier.isAutomatic) {
        expect(carried, [for (final x in photos) x.id], reason: '$name carries all 20, in order');
        for (final group in [...v.mediaGroups, for (final s in v.seriesPosts) s.media]) {
          expect(group.length, lessThanOrEqualTo(m.maxImages), reason: '$name: each post within its limit');
        }
        final posts = v.isThread ? v.threadParts.length : 1 + v.seriesPosts.length;
        expect(posts, (20 / m.maxImages).ceil(), reason: '$name: the fewest posts');
        report.add('$name: $posts post(s)');
      } else if (m.maxImages < 20) {
        // A hand-off is one post: the rest are listed, never dropped silently.
        expect(p.issues.map((i) => i.code), contains('media.left_out'), reason: name);
        report.add('$name: hand-off, ${20 - m.maxImages} left out (warned)');
      }
    }
    debugPrint(report.join('\n'));

    // The series shows under the network's preview.
    final series = previews.firstWhere((p) => p.variant.seriesPosts.isNotEmpty, orElse: () => fail('no network got a series'));
    await tester.ensureVisible(find.byKey(ValueKey('series-preview-${series.descriptor.id}')));
    expect(find.descendant(of: find.byKey(ValueKey('series-preview-${series.descriptor.id}')), matching: find.textContaining('one after the other')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
