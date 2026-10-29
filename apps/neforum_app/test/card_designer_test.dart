// 1.3.1: the card designer in the app: designed text cards saved, previewed
// and published from the same renderer (parity: the preview's bytes are the
// saved card's), the designer opened from every network's card, from the
// sound file's options and from Settings, presets, undo and redo.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/caption_fonts.dart';
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/media/font_files.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/media/text_card_background.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/card_designs.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/text_cards.dart';
import 'package:neforum_app/ui/compose/card_design_view.dart';
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

/// Storage on disk that notes every file read whole.
class _CountingStorage implements AppStorage {
  _CountingStorage(this._inner);
  final AppStorage _inner;
  final List<String> readWhole = [];
  @override
  String? get dataDir => _inner.dataDir;
  @override
  Future<Map<String, dynamic>?> readJson(String name) => _inner.readJson(name);
  @override
  Future<void> writeJson(String name, Object data) => _inner.writeJson(name, data);
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) => _inner.saveMedia(id, extension, bytes);
  @override
  Future<Uint8List> readMedia(String path) {
    readWhole.add(path);
    return _inner.readMedia(path);
  }

  @override
  Future<void> deleteMedia(String path) => _inner.deleteMedia(path);
  @override
  Future<int> mediaBytes() => _inner.mediaBytes();
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      _inner.image(path, fit: fit, width: width, height: height, cacheWidth: cacheWidth);
}

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
}

/// Half a second of a 440 Hz tone, loud then quiet, as a 16-bit mono WAV.
Uint8List _toneWav() {
  const rate = 8000;
  final samples = Int16List(rate ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = (math.sin(2 * math.pi * 440 * i / rate) * (i < samples.length / 2 ? 20000 : 4000)).round();
  }
  final data = samples.buffer.asUint8List();
  return (BytesBuilder()
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
        ..add(data))
      .toBytes();
}

void main() {
  setUpAll(_loadFonts);
  setUp(() {
    debugResetCaptionFonts();
    debugResetWaveforms();
    debugInstalledFontCatalog = InstalledFontCatalog.fromEntries([
      {'path': File('assets/fonts/JetBrainsMono-Regular.ttf').absolute.path, 'faces': [const FontFace(family: 'JetBrains Mono').toJson()]},
    ]);
  });
  tearDown(debugResetCaptionFonts);

  Future<(AppServices, ProviderContainer)> boot(WidgetTester tester, {double height = 1400}) async {
    tester.view.physicalSize = Size(1440, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
    await tester.pump(const Duration(milliseconds: 300));
    return (services, ProviderScope.containerOf(tester.element(find.byType(MaterialApp))));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Toasts (a saved preset) time out after a few seconds.
    await tester.pump(const Duration(seconds: 6));
  }

  group('parity: the preview is the saved card', () {
    testWidgets('a designed text card, plain and over a photo, has the preview\'s bytes for every network', (tester) async {
      final (s, c) = await boot(tester);
      final accounts = c.read(accountListProvider);
      final ig = accounts.firstWhere((a) => a.platformId == 'instagram');
      final bluesky = accounts.firstWhere((a) => a.platformId == 'bluesky');
      final photo = (await tester.runAsync(() => s.media.importBytes(
          img.encodeJpg(img.Image(width: 320, height: 240)..clear(img.ColorRgb8(40, 120, 200)), quality: 90),
          fileName: 'bg.jpg',
          mimeHint: 'image/jpeg')))!;
      final now = DateTime(2026, 10, 29);
      for (final (template, background) in [
        ('gradientWave', null),
        ('photoOverlay', TextCardBackground(photo: photo, blur: 4, dimming: 0.3, zoom: 1.3, vignette: 0.3)),
      ]) {
        final design = cardTemplateById(template)!.design(CardKind.text);
        var post = Post(
          id: 'p-$template',
          text: 'Parity, byte for byte.',
          targets: [PostTarget(accountId: ig.id), PostTarget(accountId: bluesky.id)],
          createdAt: now,
          updatedAt: now,
        );
        post = withTextCardChoices(post, everyNetwork: true, withText: const {}, platformOf: (id) => accounts.firstWhere((a) => a.id == id).platformId);
        post = withCardDesigns(post, text: design.toJson());
        post = (await tester.runAsync(() => attachTextCards(s, post, s.settings, background: background?.toJson() ?? const {})))!;
        for (final a in [ig, bluesky]) {
          final card = post.media.firstWhere((m) => m.id == post.targetFor(a.id)!.overrides.mediaIds!.single);
          expect(textCardDesignOf(card)?.template, template, reason: '${a.platformId}: the design is recorded');
          final saved = (await tester.runAsync(() => s.media.read(card)))!;
          final preview = (await tester.runAsync(() => CardPreviewRequest.text(
                design: design,
                platformId: a.platformId,
                size: textCardSize(a.platformId),
                safe: textCardSafeArea(a.platformId),
                text: textCardText(post, post.targetFor(a.id)!),
                byline: a.handle ?? a.displayName,
                signed: s.settings.textCardBranded(a.platformId),
                background: background,
              ).render(s.storage)))!;
          expect(preview, saved, reason: '$template on ${a.platformId}');
        }
        // Published later from the saved post: the design comes from its
        // targets and the cards are reused.
        final again = (await tester.runAsync(() => attachTextCards(s, post, s.settings)))!;
        for (final t in post.targets) {
          expect(again.targetFor(t.accountId)!.overrides.mediaIds, t.overrides.mediaIds, reason: '$template reused');
        }
      }
      await finish(tester);
    });

    testWidgets('an audio card\'s preview draws what the saved video picture is drawn from', (tester) async {
      final (s, _) = await boot(tester);
      final tone = (await tester.runAsync(() => s.media.importBytes(_toneWav(), fileName: 'tone.wav', mimeHint: 'audio/wav')))!;
      final cover = (await tester.runAsync(() => s.media.importBytes(
          img.encodeJpg(img.Image(width: 200, height: 200)..clear(img.ColorRgb8(220, 60, 90)), quality: 90),
          fileName: 'cover.jpg',
          mimeHint: 'image/jpeg')))!;
      final design = cardTemplateById('vinyl')!.design(CardKind.audio).copyWith(
            waveform: const CardWaveformLayer(visible: true, anchor: CardAnchor.topCenter),
          );
      const tags = AudioTags(title: 'Night Drive', artist: 'Ana Lima', album: 'First Light', year: 2026);
      final texts = audioCardTexts(tags, fallbackTitle: 'tone');
      expect(texts[CardBlockRole.albumYear], 'First Light · 2026');
      final levels = (await tester.runAsync(() => waveformOfSound(s.storage, tone)))!;
      expect(levels.measured, isTrue, reason: 'a WAV is measured');
      expect(levels.levels.first, greaterThan(levels.levels.last * 3), reason: 'loud, then quiet');
      final preview = (await tester.runAsync(() => CardPreviewRequest.audio(
            design: design,
            platformId: 'bluesky',
            size: const Size(540, 540),
            texts: texts,
            coverPath: cover.path,
            sound: tone,
          ).render(s.storage)))!;
      final direct = (await tester.runAsync(() async => renderDesignedAudioCard(s.storage,
          design: design,
          platformId: 'bluesky',
          size: const Size(540, 540),
          texts: texts,
          cover: await decodeCardPicture(s.storage, cover.path),
          waveform: await waveformOfSound(s.storage, tone),
          png: false)))!;
      expect(preview, direct);
      final mp3 = MediaAttachment(id: 'm', path: 'x.mp3', mimeType: 'audio/mpeg', sizeBytes: 1234, fileName: 'x.mp3');
      final decorative = (await tester.runAsync(() => waveformOfSound(s.storage, mp3)))!;
      expect(decorative.measured, isFalse, reason: 'compressed: decorative');
      await finish(tester);
    });
  });

  test('a WAV on disk is measured in parts, never read whole', () async {
    final dir = await Directory.systemTemp.createTemp('neforum-waveform');
    addTearDown(() => dir.delete(recursive: true));
    final storage = _CountingStorage(await openAppStorage(overrideDir: dir.path));
    final file = File('${dir.path}${Platform.pathSeparator}tone.wav')..writeAsBytesSync(_toneWav());
    final tone = MediaAttachment(id: 'tone', path: file.path, mimeType: 'audio/wav', sizeBytes: file.lengthSync(), fileName: 'tone.wav');
    final levels = await waveformOfSound(storage, tone);
    expect(levels.measured, isTrue);
    expect(levels.levels.first, greaterThan(levels.levels.last * 3), reason: 'loud, then quiet');
    expect(storage.readWhole, isEmpty);
  });

  group('the designer in the composer', () {
    testWidgets('opens from any network\'s card, edits the post live, undoes and redoes, saves a preset and a default', (tester) async {
      final (s, c) = await boot(tester, height: 2400);
      // Loaded for real first: file reads do not finish inside the test's
      // fake clock, where the previews would start the loading.
      final mono = CaptionFont(family: 'JetBrains Mono', path: File('assets/fonts/JetBrainsMono-Regular.ttf').absolute.path);
      expect((await tester.runAsync(() => prepareCaptionFont(s.storage, mono)))!, isTrue);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final accounts = c.read(accountListProvider);
      final ig = accounts.firstWhere((a) => a.platformId == 'instagram');
      final bluesky = accounts.firstWhere((a) => a.platformId == 'bluesky');
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), 'Designed for every network.');
      c.read(composerProvider.notifier)
        ..selectAccounts([ig.id, bluesky.id])
        ..setTextCardEveryNetwork(true);
      await settle(tester);

      // Bluesky's card has the designer too, not only Instagram's.
      final blueskyDesign = find.descendant(of: find.byKey(const ValueKey('text-card-style-bluesky')), matching: find.byKey(const Key('text-card-design')));
      await tester.ensureVisible(blueskyDesign);
      await tester.tap(blueskyDesign);
      await settle(tester);
      expect(find.text('Design the text card'), findsOneWidget);
      for (final g in ['template', 'background', 'cover', 'waveform', 'text', 'layout']) {
        expect(find.byKey(Key('card-designer-group-$g')), findsOneWidget, reason: g);
      }

      await tester.tap(find.byKey(const Key('card-template-neon')));
      await settle(tester);
      expect(CardDesign.tryParse(c.read(composerProvider).textCardDesign)?.template, 'neon');
      for (final p in c.read(composerPreviewsProvider)) {
        expect(textCardDesignOf(p.variant.media.single)?.template, 'neon', reason: '${p.descriptor.id} previews the design');
      }

      await tester.tap(find.byKey(const Key('card-designer-undo')));
      await settle(tester);
      expect(c.read(composerProvider).textCardDesign, isEmpty, reason: 'back to the classic card');
      await tester.tap(find.byKey(const Key('card-designer-redo')));
      await settle(tester);
      expect(CardDesign.tryParse(c.read(composerProvider).textCardDesign)?.template, 'neon');

      // Background: a linear gradient with a third colour.
      await tester.tap(find.byKey(const Key('card-designer-group-background')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('card-fill-linear')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('card-gradient-three')));
      await settle(tester);
      var design = CardDesign.tryParse(c.read(composerProvider).textCardDesign)!;
      expect((design.background.kind, design.background.colors.length), (CardFillKind.linear, 3));

      // Text: the post text in an installed font, from the font picker.
      await tester.tap(find.byKey(const Key('card-designer-group-text')));
      await settle(tester);
      await tester.ensureVisible(find.byKey(const Key('card-block-font')));
      await tester.tap(find.byKey(const Key('card-block-font')));
      await settle(tester);
      expect(find.text('Post text font'), findsOneWidget);
      await tester.tap(find.text('JetBrains Mono'));
      await settle(tester);
      design = CardDesign.tryParse(c.read(composerProvider).textCardDesign)!;
      expect(design.blocks.first.customFont?.family, 'JetBrains Mono');
      await tester.ensureVisible(find.byKey(const Key('card-block-uppercase')));
      await tester.tap(find.byKey(const Key('card-block-uppercase')));
      await settle(tester);
      expect(CardDesign.tryParse(c.read(composerProvider).textCardDesign)!.blocks.first.uppercase, isTrue);

      // Layout: the post text to the top left.
      await tester.tap(find.byKey(const Key('card-designer-group-layout')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('card-layout-element-0')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('card-anchor-topLeft')));
      await settle(tester);
      expect(CardDesign.tryParse(c.read(composerProvider).textCardDesign)!.blocks.first.anchor, CardAnchor.topLeft);

      // A preset, and the default for new posts.
      await tester.tap(find.byKey(const Key('card-designer-group-template')));
      await settle(tester);
      await tester.ensureVisible(find.byKey(const Key('card-preset-save')));
      await tester.tap(find.byKey(const Key('card-preset-save')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('card-preset-name')), 'Glow');
      await tester.tap(find.text('Save').last);
      await settle(tester);
      expect(CardPreset.tryParse(c.read(settingsProvider).cardPresets.single)?.name, 'Glow');
      await tester.tap(find.byKey(const Key('card-designer-default')));
      await settle(tester);
      expect(CardDesign.tryParse(c.read(settingsProvider).textCardDesign)?.template, 'neon');
      await tester.tap(find.byKey(const Key('card-designer-done')));
      await settle(tester);

      // The previews draw it with the saved card's renderer, at each size.
      for (final id in ['instagram', 'bluesky']) {
        expect(find.descendant(of: find.byKey(ValueKey('text-card-preview-$id')), matching: find.byType(CardDesignView)), findsOneWidget, reason: id);
      }

      // Saved: the design is on the targets, read back when edited, and not
      // shown as a customization.
      final now = DateTime(2026, 10, 29);
      final saved = withCardDesigns(
          Post(id: 'p-d', text: 'x', targets: [PostTarget(accountId: ig.id)], createdAt: now, updatedAt: now),
          text: c.read(composerProvider).textCardDesign);
      expect(CardDesign.tryParse(textCardDesignChoiceOfPost(saved))?.template, 'neon');
      expect(withoutTextCardChoices(saved.targets.single.overrides).isEmpty, isTrue);
      c.read(composerProvider.notifier).load(saved);
      expect(CardDesign.tryParse(c.read(composerProvider).textCardDesign)?.blocks.first.customFont?.family, 'JetBrains Mono');
      expect(c.read(composerProvider).overrides, isEmpty);
      expect(s.settings.textCardDesign, isNotEmpty);
      await finish(tester);
    });

    testWidgets('the sound file\'s options open the audio card designer', (tester) async {
      final (s, c) = await boot(tester, height: 1600);
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final tone = (await tester.runAsync(() => s.media.importBytes(_toneWav(), fileName: 'tone.wav', mimeHint: 'audio/wav')))!;
      final bluesky = c.read(accountListProvider).firstWhere((a) => a.platformId == 'bluesky');
      c.read(composerProvider.notifier)
        ..addMedia([tone])
        ..selectAccounts([bluesky.id]);
      await settle(tester);
      await tester.ensureVisible(find.byKey(const Key('audio-card-design')));
      await tester.tap(find.byKey(const Key('audio-card-design')));
      await settle(tester);
      expect(find.text('Design the audio card'), findsOneWidget);
      expect(find.byKey(const Key('card-designer-frame-landscape')), findsOneWidget, reason: 'YouTube\'s 16:9 frame');
      await tester.tap(find.byKey(const Key('card-template-vinyl')));
      await settle(tester);
      expect(CardDesign.tryParse(c.read(composerProvider).audioCardDesign)?.kind, CardKind.audio);
      await tester.tap(find.byKey(const Key('card-designer-group-waveform')));
      await settle(tester);
      expect(find.textContaining('Measured from tone.wav'), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-designer-done')));
      await settle(tester);
      await finish(tester);
    });
  });

  testWidgets('Settings > Text cards designs the defaults of both kinds', (tester) async {
    final (_, c) = await boot(tester, height: 2400);
    c.read(routerProvider).go('/settings');
    await settle(tester);
    await tester.ensureVisible(find.byKey(const Key('text-card-design-setting')));
    await tester.tap(find.byKey(const Key('text-card-design-setting')));
    await settle(tester);
    expect(find.text('What new posts start with. Each post can change it.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('card-template-polaroid')));
    await settle(tester);
    expect(CardDesign.tryParse(c.read(settingsProvider).textCardDesign)?.template, 'polaroid');
    await tester.tap(find.byKey(const Key('card-designer-done')));
    await settle(tester);

    await tester.ensureVisible(find.byKey(const Key('audio-card-design-setting')));
    await tester.tap(find.byKey(const Key('audio-card-design-setting')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('card-template-gradientWave')));
    await settle(tester);
    final audio = CardDesign.tryParse(c.read(settingsProvider).audioCardDesign)!;
    expect((audio.kind, audio.template), (CardKind.audio, 'gradientWave'));
    await tester.tap(find.byKey(const Key('card-designer-done')));
    await settle(tester);
    await finish(tester);
  });
}
