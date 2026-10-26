// Writes captions on photos and renders text cards through the real desktop
// engine, the way Save draft does. On Windows these once never finished
// (NEFORUM 1.2.0 stopped responding): the photo went through the GPU and was
// read back. Linux widget tests never take that path, so this runs here.
//
//   flutter test integration_test/captions_test.dart -d windows
//
// Nothing is posted anywhere: the posts are drafts in the demo workspace.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:neforum_app/media/caption_style.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/media/text_card_background.dart';
import 'package:neforum_app/platform/desktop.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/captioned_photos.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/text_cards.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// Far longer than a render takes; a render that hangs fails the test
/// instead of stalling CI.
const Duration _limit = Duration(seconds: 90);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captions on photos and text cards on the real desktop engine', (tester) async {
    final dir = await Directory.systemTemp.createTemp('neforum-captions-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file open; the OS cleans temp later.
      }
    });

    Future<void> pumpFor(int ms) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await DesktopIntegration.instance.initWindow();
    final storage = await openAppStorage(overrideDir: dir.path);
    final services = await AppServices.create(demo: true, storage: storage);
    await tester.pumpWidget(NeforumRoot(initial: services));
    await pumpFor(2000);
    final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first));
    final s = c.read(servicesProvider);
    final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');

    // A 4:3 photo with detail: Instagram takes 4:5 to 1.91:1, so it is not
    // fitted, and a block above puts it in a 4:5 frame.
    final source = img.Image(width: 1600, height: 1200);
    for (final p in source) {
      p
        ..r = 40 + (p.x * 180 ~/ source.width)
        ..g = 60 + (p.y * 150 ~/ source.height)
        ..b = 120 + (80 * math.sin(p.x / 37)).round();
    }
    final photo = await s.media.importBytes(img.encodeJpg(source, quality: 90), fileName: 'windows test.jpg', mimeHint: 'image/jpeg');

    /// Saves a draft of the photo post for Instagram with the caption on the
    /// photo in [style], and checks the captioned copy in the media folder.
    Future<void> saveCaptioned(String label, CaptionStyle style, PhotoFitMode fit) async {
      c.read(settingsProvider.notifier).update((x) => x.copyWith(photoFit: fit));
      final composer = c.read(composerProvider.notifier)..reset();
      composer
        ..setText('Windows test: $label. The caption goes on the photo for Instagram.')
        ..addMedia([photo])
        ..selectAccounts([ig.id])
        ..setCaptionOnPhoto('instagram', true)
        ..setCaptionStyle(style.toJson());
      await pumpFor(300);

      final watch = Stopwatch()..start();
      final post = await c.read(postActionsProvider).saveDraft().timeout(_limit, onTimeout: () => fail('$label: Save draft did not finish'));
      watch.stop();
      debugPrint('$label: saved in ${watch.elapsedMilliseconds} ms');
      await pumpFor(300);

      final copy = post.media.singleWhere(isCaptionedCopy, orElse: () => fail('$label: no captioned copy'));
      expect(post.targetFor(ig.id)!.overrides.mediaIds!.first, copy.id, reason: '$label: Instagram gets the captioned copy');
      expect(copy.fileName, endsWith('(captioned).jpg'));
      expect(copy.path, startsWith(storage.dataDir!));
      final decoded = img.decodeJpg(File(copy.path).readAsBytesSync())!;
      expect((decoded.width, decoded.height), (copy.width, copy.height), reason: label);
      if (style.placement == CaptionPlacement.blockAbove) {
        expect((decoded.width, decoded.height), (1080, 1350), reason: '$label: the whole 4:5 frame');
      } else {
        // Written on the photo as fitted for Instagram (4:5, borders added).
        expect((decoded.width, decoded.height), (1600, 2000), reason: '$label: the fitted photo keeps its size');
      }
      // Opaque and not washed out: the photo's colours survive somewhere.
      final centre = decoded.getPixel(decoded.width ~/ 2, decoded.height - decoded.height ~/ 5);
      expect(centre.r + centre.g + centre.b, inInclusiveRange(60, 700), reason: '$label: the photo shows (not blank)');
    }

    await saveCaptioned('on the photo', const CaptionStyle(), PhotoFitMode.pad);
    for (final fit in [PhotoFitMode.pad, PhotoFitMode.color, PhotoFitMode.crop]) {
      await saveCaptioned('block above, ${fit.name}', const CaptionStyle(placement: CaptionPlacement.blockAbove), fit);
    }

    // Text cards: words only, then over a background photo.
    for (final background in [null, TextCardBackground(photo: photo)]) {
      final label = background == null ? 'plain text card' : 'text card over a photo';
      final composer = c.read(composerProvider.notifier)..reset();
      composer
        ..setText('Windows test: $label for Instagram.')
        ..selectAccounts([ig.id])
        ..setTextCardBackground(background?.toJson());
      await pumpFor(300);
      final post = await c.read(postActionsProvider).saveDraft().timeout(_limit, onTimeout: () => fail('$label: Save draft did not finish'));
      final card = post.media.singleWhere(isRenderedTextCard, orElse: () => fail('$label: no card'));
      final decoded = img.decodeJpg(File(card.path).readAsBytesSync())!;
      expect((decoded.width, decoded.height), (textCardSize('instagram').width.round(), textCardSize('instagram').height.round()), reason: label);
      if (background != null) expect(card.renderParameters!['background']['mediaId'], photo.id);
    }
    await pumpFor(500);
  });
}
