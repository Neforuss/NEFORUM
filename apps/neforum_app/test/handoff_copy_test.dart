// Hand-off on a computer: photos go onto the clipboard for Ctrl+V, and
// "Copy next" hands out the text, the snippets and each photo in turn.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/platform/clipboard_media.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/handoff/handoff_sheet.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

final Uint8List _png = img.encodePng(img.Image(width: 4, height: 3)..clear(img.ColorRgb8(125, 0, 255)));

class _MemoryStorage implements AppStorage {
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => null;
  @override
  Future<void> writeJson(String name, Object data) async {}
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  /// Photos read, in order: copying a photo starts by reading it.
  final List<String> reads = [];
  @override
  Future<Uint8List> readMedia(String path) async {
    reads.add(path);
    return _png;
  }
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF7D00FF)));
}

MediaAttachment _photo(String id) => MediaAttachment(id: id, path: 'C:/media/$id.png', mimeType: 'image/png', sizeBytes: _png.length, fileName: '$id.png');

void main() {
  test('dibFromRgba writes a bottom-up 32-bit BGRA bitmap', () {
    // 2 x 2: top row red, green; bottom row blue, white.
    final rgba = Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]);
    final dib = ClipboardMedia.dibFromRgba(rgba, 2, 2);
    final h = ByteData.sublistView(dib);
    expect(h.getUint32(0, Endian.little), 40);
    expect(h.getInt32(4, Endian.little), 2);
    expect(h.getInt32(8, Endian.little), 2, reason: 'positive height: rows bottom-up');
    expect(h.getUint16(14, Endian.little), 32);
    expect(h.getUint32(16, Endian.little), 0, reason: 'BI_RGB');
    // First stored row is the bottom one (blue, white), in BGRA order.
    expect(dib.sublist(40, 48), [255, 0, 0, 255, 255, 255, 255, 255]);
    expect(dib.sublist(48, 56), [0, 0, 255, 255, 0, 255, 0, 255]);
  });

  testWidgets('photos copy for pasting; Copy next walks text, snippets and photos', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final copiedImages = <Map<Object?, Object?>>[];
    final copiedText = <String>[];
    // Completed by the next thing that reaches the clipboard. Each tap below
    // copies exactly one thing.
    Completer<void>? copying;
    void noteCopy() {
      copying?.complete();
      copying = null;
    }

    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('neforum/clipboard'), (call) async {
      if (call.method != 'copyImage') return null;
      copiedImages.add(call.arguments as Map<Object?, Object?>);
      noteCopy();
      return true;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText.add((call.arguments as Map)['text'] as String);
        noteCopy();
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('neforum/clipboard'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final storage = _MemoryStorage();
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
    final photos = [_photo('one'), _photo('two')];
    final plan = HandoffPlan(
      platformId: 'youtube_posts',
      instructions: '1. Paste.',
      clipboardText: 'Which logo do you like?',
      shareFiles: photos,
      snippets: const [HandoffSnippet('Image 1 caption', 'Diamond')],
      desktopUrl: 'https://www.youtube.com/@examplechannel/posts',
      preferred: HandoffMethod.manual,
    );
    final account = ConnectedAccount(
        id: 'yp', platformId: 'youtube_posts', tier: PlatformTier.handoff, displayName: 'YouTube Posts', createdAt: DateTime(2026, 10, 12));
    final post = Post(id: 'p1', text: 'Which logo do you like?', createdAt: DateTime(2026, 10, 12), updatedAt: DateTime(2026, 10, 12));
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(
          body: HandoffSheet(plan: plan, post: post, account: account, variant: PostVariant(text: 'Which logo do you like?', media: photos)),
        ),
      ),
    ));
    await tester.pump();

    // One copy button per photo, and the paste hint.
    expect(find.byTooltip('Copy photo 1'), findsOneWidget);
    expect(find.byTooltip('Copy photo 2'), findsOneWidget);
    expect(find.textContaining('then press Ctrl+V in the composer'), findsOneWidget);

    Future<void> tapAndSettle(Finder f) async {
      final copied = await tester.runAsync(() async {
        final copy = Completer<void>();
        copying = copy;
        await tester.tap(f);
        // Decoding and encoding the photo happen off the fake clock, as long
        // as they take: wait for the copy to reach the clipboard, not a set time.
        final reached = await copy.future.then((_) => true).timeout(const Duration(seconds: 20), onTimeout: () => false);
        // What follows the copy is only microtasks: let the sheet note it. (If
        // the sheet ever awaits real work after copying, wait for that here.)
        await pumpEventQueue();
        return reached;
      });
      expect(copied, isNotNull, reason: 'the tap threw: see the error above');
      expect(copied, isTrue, reason: 'nothing was copied');
      await tester.pump();
    }

    List<Object?> photoPaths() => [for (final c in copiedImages) c['path']];

    await tapAndSettle(find.byTooltip('Copy photo 2'));
    expect(copiedImages, hasLength(1));
    expect(copiedImages.single['path'], 'C:/media/two.png');
    expect(copiedImages.single['png'], isA<Uint8List>());
    expect(copiedImages.single['dib'], isA<Uint8List>(), reason: 'Windows also gets a bitmap');
    expect(copiedText, isEmpty);
    // Each tap starts exactly the copies it asks for: a photo copy starts by
    // reading the photo, so one more would show here, not later.
    expect(storage.reads, ['C:/media/two.png']);

    // Copy next: text, caption, photo 1, photo 2, then start again.
    expect(find.text('Copy next: Text'), findsOneWidget);
    await tapAndSettle(find.text('Copy next: Text'));
    expect(copiedText, ['Which logo do you like?']);
    expect(storage.reads, ['C:/media/two.png']);
    await tapAndSettle(find.text('Copy next: Image 1 caption'));
    expect(copiedText, ['Which logo do you like?', 'Diamond']);
    expect(storage.reads, ['C:/media/two.png']);
    await tapAndSettle(find.text('Copy next: Photo 1 of 2'));
    expect(photoPaths(), ['C:/media/two.png', 'C:/media/one.png']);
    expect(storage.reads, ['C:/media/two.png', 'C:/media/one.png']);
    await tapAndSettle(find.text('Copy next: Photo 2 of 2'));
    expect(photoPaths(), ['C:/media/two.png', 'C:/media/one.png', 'C:/media/two.png']);
    expect(storage.reads, ['C:/media/two.png', 'C:/media/one.png', 'C:/media/two.png']);
    expect(copiedText, hasLength(2), reason: 'photos copy no text');
    expect(find.text('All copied. Start again with the text'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
