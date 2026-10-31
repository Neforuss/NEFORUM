// Runs the 1.3 features that do real work on the device through a compiled
// build: text cards for stories and for every network, edited card
// backgrounds, sound files (a Standard copy and a still-picture video), PDF
// reading through PDFium, a background picture behind the pages, and (1.3.1)
// an audio card drawn from a template with the sound's waveform and a text
// card in a font installed on the computer, found through the font registry,
// and (1.3.3) a sound video's photo fitted whole to 9:16 and the text card's
// master editor. Debug
// tests missed a release-only crash in 1.2.1, so CI runs this in profile mode:
//
//   flutter drive --profile -d windows --driver=test_driver/integration_test.dart --target=integration_test/release_probe_test.dart
//
// Nothing is posted anywhere: the posts are drafts in the demo workspace.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:neforum_app/documents/pdf_reader.dart';
import 'package:neforum_app/documents/thread_builder.dart';
import 'package:neforum_app/media/caption_fonts.dart';
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/media/photo_fitter.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/media/text_card_background.dart';
import 'package:neforum_app/platform/desktop.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/platform/video_compositor.dart';
import 'package:neforum_app/state/audio_renditions.dart';
import 'package:neforum_app/state/card_designs.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/text_cards.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// Far longer than any step takes; a step that hangs fails the test.
const Duration _limit = Duration(seconds: 120);

/// One second of a 440 Hz tone as a 16-bit mono WAV.
Uint8List _toneWav() {
  const rate = 44100;
  final samples = Int16List(rate);
  for (var i = 0; i < rate; i++) {
    samples[i] = (math.sin(2 * math.pi * 440 * i / rate) * 12000).round();
  }
  final data = samples.buffer.asUint8List();
  final b = BytesBuilder()
    ..add('RIFF'.codeUnits)
    ..add((ByteData(4)..setUint32(0, 36 + data.length, Endian.little)).buffer.asUint8List())
    ..add('WAVEfmt '.codeUnits)
    ..add((ByteData(20)
          ..setUint32(0, 16, Endian.little)
          ..setUint16(4, 1, Endian.little)
          ..setUint16(6, 1, Endian.little)
          ..setUint32(8, rate, Endian.little)
          ..setUint32(12, rate * 2, Endian.little)
          ..setUint16(16, 2, Endian.little)
          ..setUint16(18, 16, Endian.little))
        .buffer
        .asUint8List())
    ..add('data'.codeUnits)
    ..add((ByteData(4)..setUint32(0, data.length, Endian.little)).buffer.asUint8List())
    ..add(data);
  return b.toBytes();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('1.3 features on the real desktop engine', (tester) async {
    final dir = await Directory.systemTemp.createTemp('neforum-probe-');
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
    final accounts = c.read(accountListProvider);
    ConnectedAccount account(String platformId) =>
        accounts.firstWhere((a) => a.platformId == platformId, orElse: () => fail('The demo has no $platformId account'));
    final ig = account('instagram');
    final bluesky = account('bluesky');

    final source = img.Image(width: 1600, height: 1200);
    for (final p in source) {
      p
        ..r = 40 + (p.x * 180 ~/ source.width)
        ..g = 60 + (p.y * 150 ~/ source.height)
        ..b = 120 + (80 * math.sin(p.x / 37)).round();
    }
    final photo = await s.media.importBytes(img.encodeJpg(source, quality: 90), fileName: 'probe photo.jpg', mimeHint: 'image/jpeg');

    // 1. Words only, the same card on every network, Instagram as Post +
    //    Story, over an edited background photo.
    final composer = c.read(composerProvider.notifier)..reset();
    composer
      ..setText('Release probe: one card on every network, and a story for Instagram.')
      ..selectAccounts([ig.id, bluesky.id])
      ..setTextCardEveryNetwork(true)
      ..setOverride(ig.id, const PostOverrides(extra: {kPlacementKey: 'feedAndStory'}))
      ..setTextCardBackground(TextCardBackground(
        photo: photo,
        zoom: 1.6,
        offsetX: 0.3,
        quarterTurns: 1,
        flipHorizontal: true,
        brightness: 0.1,
        contrast: 0.2,
        saturation: -0.3,
        tintColor: 0xFF7D00FF,
        tintStrength: 0.3,
        gradientStrength: 0.5,
        vignette: 0.4,
        textPosition: TextCardTextPosition.bottom,
      ).toJson());
    await pumpFor(300);
    var post = await c.read(postActionsProvider).saveDraft().timeout(_limit, onTimeout: () => fail('Save draft with cards did not finish'));
    await pumpFor(300);
    final cards = {for (final m in post.media.where(isRenderedTextCard)) m.id: m};
    expect(cards, isNotEmpty, reason: 'cards were rendered');
    for (final a in [ig, bluesky]) {
      final ids = post.targetFor(a.id)!.overrides.mediaIds ?? const [];
      expect(ids.where(cards.containsKey), isNotEmpty, reason: '${a.platformId} gets a card');
    }
    final storyIds = post.targetFor(ig.id)!.overrides.storyMediaIds ?? const [];
    expect(storyIds, hasLength(1), reason: 'the Instagram story has its own card');
    final story = cards[storyIds.single] ?? fail('the story card is not among the cards');
    final storyJpeg = img.decodeJpg(File(story.path).readAsBytesSync())!;
    expect(storyJpeg.height / storyJpeg.width, closeTo(16 / 9, 0.01), reason: 'the story card is 9:16');
    debugPrint('cards: ${cards.length}, story ${storyJpeg.width}x${storyJpeg.height}');

    // 2. A sound file: a Standard copy where sound is taken, a still-picture
    //    video for Bluesky, when this device can make them.
    final tone = await s.media.importBytes(_toneWav(), fileName: 'probe tone.wav', mimeHint: 'audio/wav');
    expect(tone.isAudio, isTrue);
    expect(tone.durationMs, inInclusiveRange(990, 1010));
    final canEncode = await VideoCompositor.instance.isSupported();
    c.read(composerProvider.notifier)
      ..reset()
      ..setText('Release probe: a sound file.')
      ..addMedia([tone])
      ..selectAccounts([bluesky.id])
      ..setAudioQuality(AudioQuality.standard);
    await pumpFor(300);
    post = await c.read(postActionsProvider).saveDraft().timeout(_limit, onTimeout: () => fail('Save draft with a sound file did not finish'));
    await pumpFor(300);
    final renditions = post.media.where(isAudioRendition).toList();
    debugPrint('compositor: $canEncode, renditions: ${[for (final m in renditions) '${m.mimeType} ${m.sizeBytes}']}');
    if (canEncode) {
      final video = renditions.where((m) => m.isVideo).firstOrNull ?? fail('no still-picture video for Bluesky');
      expect(File(video.path).lengthSync(), greaterThan(1000));
      expect(post.targetFor(bluesky.id)!.overrides.mediaIds, contains(video.id));
    }

    // 3. A PDF read through PDFium in this build: two columns, in order.
    final fixture = File('test/fixtures/documents/two_columns.pdf');
    expect(fixture.existsSync(), isTrue, reason: 'run from apps/neforum_app (${Directory.current.path})');
    final document = await readPdf(fixture.readAsBytesSync()).timeout(_limit);
    final thread = buildDocumentThread(document);
    expect(document.blocks, isNotEmpty);
    expect(thread.parts, isNotEmpty);
    debugPrint('PDF: ${document.pageCount} pages, ${document.blocks.length} blocks, ${thread.parts.length} parts');

    // 4. 1.3.1: an audio card from a template, with the waveform measured from
    //    the WAV, drawn on the CPU compositor in this build; and a sound
    //    video whose picture is that design, when the device can make one.
    final vinyl = cardTemplateById('vinyl')!.design(CardKind.audio).copyWith(
          waveform: const CardWaveformLayer(visible: true, style: CardWaveformStyle.mirrored, anchor: CardAnchor.topCenter, height: 0.12),
        );
    final levels = await waveformOfSound(s.storage, tone).timeout(_limit);
    expect(levels.measured, isTrue, reason: 'a WAV is measured');
    expect(levels.levels.reduce(math.max), closeTo(1, 1e-9));
    final audioPng = await renderDesignedAudioCard(s.storage,
            design: vinyl,
            platformId: 'bluesky',
            size: const Size(1080, 1080),
            texts: audioCardTexts(const AudioTags(title: 'Probe tone', artist: 'NEFORUM', album: 'Release probe', year: 2026), fallbackTitle: 'tone'),
            cover: await decodeCardPicture(s.storage, photo.path),
            waveform: levels)
        .timeout(_limit, onTimeout: () => fail('The designed audio card did not finish'));
    final audioCard = img.decodePng(audioPng)!;
    expect((audioCard.width, audioCard.height), (1080, 1080));
    final corner = audioCard.getPixel(4, 4), middle = audioCard.getPixel(540, 400);
    expect(corner == middle, isFalse, reason: 'the record over the background');
    c.read(composerProvider.notifier)
      ..reset()
      ..setText('Release probe: a designed audio card.')
      ..addMedia([tone])
      ..selectAccounts([bluesky.id])
      ..setAudioCardDesign(vinyl);
    await pumpFor(300);
    post = await c.read(postActionsProvider).saveDraft().timeout(_limit, onTimeout: () => fail('Save draft with a designed audio card did not finish'));
    await pumpFor(300);
    if (canEncode) {
      final video = post.media.where((m) => isAudioRendition(m) && m.isVideo).firstOrNull ?? fail('no designed video for Bluesky');
      expect(video.renderParameters?['design'], isNotNull, reason: 'the picture is the design');
      expect(File(video.path).lengthSync(), greaterThan(1000));
    }
    debugPrint('audio card: ${audioPng.length} bytes, waveform measured: ${levels.measured}');

    // 5. 1.3.1: a text card in a font installed on this computer, found by
    //    family through the installed-font registry (Comic Sans MS where it is
    //    there), loaded with FontLoader before the card is drawn.
    final catalog = await loadInstalledFonts(s.storage).timeout(_limit);
    final family = catalog.facesOf('Comic Sans MS').isNotEmpty
        ? 'Comic Sans MS'
        : catalog.families.keys.firstWhere((f) => f.isNotEmpty, orElse: () => '');
    debugPrint('installed font families: ${catalog.families.length}, using: $family');
    if (family.isNotEmpty) {
      final font = CaptionFont(family: family, path: catalog.facesOf(family).first.path);
      c.read(composerProvider.notifier)
        ..reset()
        ..setText('Release probe: a text card in $family.')
        ..selectAccounts([ig.id])
        ..setTextCardCustomFont(font);
      await pumpFor(300);
      post = await c.read(postActionsProvider).saveDraft().timeout(_limit, onTimeout: () => fail('Save draft with an installed font did not finish'));
      await pumpFor(300);
      final card = post.media.where(isRenderedTextCard).firstOrNull ?? fail('no text card in $family');
      expect(textCardCustomFontOf(card)?.family, family);
      expect(card.renderParameters?['customFontFallback'], isNull, reason: '$family was loaded');
      expect(registeredCaptionFontAlias(font), font.alias);
      // The same font in a designed card's block.
      final designed = cardTemplateById('neon')!.design(CardKind.text).withBlock(0, (b) => b.copyWith(customFont: font));
      c.read(composerProvider.notifier).setTextCardDesign(designed);
      await pumpFor(300);
      post = await c.read(postActionsProvider).saveDraft().timeout(_limit, onTimeout: () => fail('Save draft with a designed card did not finish'));
      await pumpFor(300);
      final designedCard = post.media.where(isRenderedTextCard).firstOrNull ?? fail('no designed text card');
      expect(textCardDesignOf(designedCard)?.blocks.first.customFont?.family, family);
      expect(designedCard.renderParameters?['designFontFallback'], isNull);
      final jpeg = img.decodeJpg(File(designedCard.path).readAsBytesSync())!;
      expect((jpeg.width, jpeg.height), (1080, 1350));
    }

    // 7. 1.3.3: a sound video's picture shown whole in a 9:16 frame (the
    //    photo's sides kept, the room filled with its colours), and the text
    //    card's master editor in the composer, setting every network at once.
    final framed = img.decodePng((await framePhotoPng(img.encodeJpg(source, quality: 90), width: 1080, height: 1920, mode: PhotoFitMode.color)
        .timeout(_limit, onTimeout: () => fail('Fitting a photo to a 9:16 frame did not finish')))!)!;
    expect((framed.width, framed.height), (1080, 1920));
    final leftEdge = framed.getPixel(2, 960), rightEdge = framed.getPixel(1077, 960);
    // Red runs from 40 at the photo's left edge to 220 at its right: cut to
    // 9:16, the frame's edges would be about 92 and 168.
    expect(leftEdge.r, lessThan(70), reason: 'the photo\'s left edge is in the frame');
    expect(rightEdge.r, greaterThan(190), reason: 'the photo\'s right edge is in the frame');
    c.read(composerProvider.notifier)
      ..reset()
      ..setText('Release probe: a sound file for Instagram.')
      ..addMedia([photo, tone])
      ..selectAccounts([ig.id])
      ..setAudioQuality(AudioQuality.standard);
    await pumpFor(300);
    post = await c.read(postActionsProvider).saveDraft().timeout(_limit, onTimeout: () => fail('Save draft with a sound file for Instagram did not finish'));
    await pumpFor(300);
    if (canEncode) {
      final video = post.media.where((m) => isAudioRendition(m) && m.isVideo).firstOrNull ?? fail('no still-picture video for Instagram');
      expect((video.width, video.height), (1080, 1920));
      expect(video.renderParameters?['fit'], s.settings.photoFit.name, reason: 'the photo is fitted, not cut');
    }
    c.read(routerProvider).go('/compose');
    c.read(composerProvider.notifier)
      ..reset()
      ..setText('Release probe: one card editor for every network.')
      ..selectAccounts([ig.id, bluesky.id])
      ..setTextCardEveryNetwork(true)
      ..setTextCardBranded('bluesky', false);
    await pumpFor(1500);
    expect(find.byKey(const Key('text-card-master')), findsOneWidget, reason: 'two networks get a card');
    await tester.ensureVisible(find.byKey(const Key('text-card-match')));
    await tester.tap(find.byKey(const Key('text-card-match')));
    await pumpFor(800);
    expect(c.read(composerProvider).textCardBranded['bluesky'], isTrue, reason: 'Make them match');
    expect(tester.takeException(), isNull);

    // 6. A background picture behind the pages, blurred.
    final backdrop = File('${dir.path}${Platform.pathSeparator}backdrop.png')..writeAsBytesSync(img.encodePng(source));
    c.read(settingsProvider.notifier).update((x) => x.copyWith(backgroundImagePath: backdrop.path, backgroundBlur: 20));
    await pumpFor(1500);
    expect(tester.takeException(), isNull);
    c.read(settingsProvider.notifier).update((x) => x.copyWith(clearBackgroundImage: true));
    await pumpFor(500);
  });
}
