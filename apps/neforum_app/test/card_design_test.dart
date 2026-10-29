// 1.3.1: the card designer's layered card spec, its renderer and the
// waveform reader: JSON round trips, the templates on both kinds of card as
// golden images (one with an installed font loaded through FontLoader),
// determinism, and WAV/AIFF levels.
//
// Goldens: flutter test test/card_design_test.dart --update-goldens

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/caption_fonts.dart';
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/card_renderer.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/media/font_files.dart';
import 'package:neforum_app/media/photo_pixels.dart';
import 'package:neforum_app/media/render_parameters.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/media/waveform.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/settings.dart';

/// Pixel-exact goldens break on font rasterizing differences between
/// operating systems; this allows a sliver of pixels to differ.
class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

  static const double tolerance = 0.015;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(imageBytes, await getGoldenBytes(golden));
    if (result.passed || result.diffPercent <= tolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

class _NoStorage implements AppStorage {
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => null;
  @override
  Future<void> writeJson(String name, Object data) async {}
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id';
  @override
  Future<Uint8List> readMedia(String path) async => throw StateError('No media');
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => const SizedBox();
}

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
  await family('TikTok Sans', ['assets/fonts/TikTokSans.ttf']);
}

/// A photo with smooth colour bands, as cover art or a background photo.
PhotoPixels _photo(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      rgba[o] = (60 + 150 * x / w).round();
      rgba[o + 1] = (40 + 120 * (0.5 + 0.5 * math.sin(y / 23))).round();
      rgba[o + 2] = (140 + 100 * y / h).round();
      rgba[o + 3] = 255;
    }
  }
  return PhotoPixels(rgba: rgba, width: w, height: h, luminance: 0.4, topColor: 0, bottomColor: 0);
}

const _textWords = {CardBlockRole.postText: 'Small steps every day add up to something nobody expected.', CardBlockRole.handle: '@ana@mastodon.social'};
const _trackWords = {CardBlockRole.title: 'Night Drive', CardBlockRole.artist: 'Ana Lima', CardBlockRole.albumYear: 'First Light · 2026'};

/// A WAV of 16-bit (or 24-bit) PCM: [seconds] of a tone whose loudness
/// follows [envelope] (0 to 1 over the file).
Uint8List _wav({int bits = 16, int channels = 1, double seconds = 1, double Function(double t)? envelope, bool float = false}) {
  const rate = 8000;
  final frames = (rate * seconds).round();
  final bytesPer = bits ~/ 8;
  final data = ByteData(frames * channels * bytesPer);
  for (var i = 0; i < frames; i++) {
    final level = envelope?.call(i / frames) ?? 1;
    final v = math.sin(2 * math.pi * 440 * i / rate) * 0.8 * level;
    for (var c = 0; c < channels; c++) {
      final at = (i * channels + c) * bytesPer;
      if (float) {
        data.setFloat32(at, v, Endian.little);
      } else if (bits == 16) {
        data.setInt16(at, (v * 32767).round(), Endian.little);
      } else {
        final s = (v * 8388607).round() & 0xFFFFFF;
        data
          ..setUint8(at, s & 0xFF)
          ..setUint8(at + 1, s >> 8 & 0xFF)
          ..setUint8(at + 2, s >> 16 & 0xFF);
      }
    }
  }
  final body = data.buffer.asUint8List();
  final b = BytesBuilder()
    ..add('RIFF'.codeUnits)
    ..add((ByteData(4)..setUint32(0, 36 + body.length, Endian.little)).buffer.asUint8List())
    ..add('WAVEfmt '.codeUnits)
    ..add((ByteData(20)
          ..setUint32(0, 16, Endian.little)
          ..setUint16(4, float ? 3 : 1, Endian.little)
          ..setUint16(6, channels, Endian.little)
          ..setUint32(8, rate, Endian.little)
          ..setUint32(12, rate * channels * bytesPer, Endian.little)
          ..setUint16(16, channels * bytesPer, Endian.little)
          ..setUint16(18, bits, Endian.little))
        .buffer
        .asUint8List())
    ..add('data'.codeUnits)
    ..add((ByteData(4)..setUint32(0, body.length, Endian.little)).buffer.asUint8List())
    ..add(body);
  return b.toBytes();
}

/// The same tone as a 16-bit AIFF ([littleEndian]: an AIFF-C "sowt" file).
Uint8List _aiff({required double Function(double t) envelope, bool littleEndian = false}) {
  const rate = 8000, frames = 8000;
  final data = ByteData(frames * 2);
  for (var i = 0; i < frames; i++) {
    data.setInt16(i * 2, (math.sin(2 * math.pi * 440 * i / rate) * 0.8 * envelope(i / frames) * 32767).round(), littleEndian ? Endian.little : Endian.big);
  }
  final comm = ByteData(littleEndian ? 24 : 18)
    ..setUint16(0, 1)
    ..setUint32(2, frames)
    ..setUint16(6, 16);
  // The sample rate as an 80-bit float: 8000 = 1.953125 x 2^12.
  comm
    ..setUint16(8, 0x400B)
    ..setUint32(10, 0xFA000000);
  if (littleEndian) {
    for (var i = 0; i < 4; i++) {
      comm.setUint8(18 + i, 'sowt'.codeUnitAt(i));
    }
  }
  final ssnd = BytesBuilder()
    ..add(Uint8List(8))
    ..add(data.buffer.asUint8List());
  final chunks = BytesBuilder()
    ..add((littleEndian ? 'AIFC' : 'AIFF').codeUnits)
    ..add('COMM'.codeUnits)
    ..add((ByteData(4)..setUint32(0, comm.lengthInBytes)).buffer.asUint8List())
    ..add(comm.buffer.asUint8List())
    ..add('SSND'.codeUnits)
    ..add((ByteData(4)..setUint32(0, ssnd.length)).buffer.asUint8List())
    ..add(ssnd.toBytes());
  final body = chunks.toBytes();
  return (BytesBuilder()
        ..add('FORM'.codeUnits)
        ..add((ByteData(4)..setUint32(0, body.length)).buffer.asUint8List())
        ..add(body))
      .toBytes();
}

Future<ui.Image> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    goldenFileComparator = _TolerantComparator(Uri.parse('${(goldenFileComparator as LocalFileComparator).basedir}card_design_test.dart'));
  });

  group('design JSON', () {
    test('every template of both kinds round-trips', () {
      for (final t in kCardTemplates) {
        for (final kind in CardKind.values) {
          final d = t.design(kind);
          final back = CardDesign.tryParse(d.toJson())!;
          expect(renderParametersEqual(back.toJson(), d.toJson()), isTrue, reason: '${t.id} ${kind.name}');
          expect(back.template, t.id);
          expect(back.blocks, isNotEmpty);
        }
      }
      expect(kCardTemplates.length, greaterThanOrEqualTo(8));
      expect({for (final t in kCardTemplates) t.id}, containsAll(['minimal', 'boldPoster', 'vinyl', 'gradientWave', 'photoOverlay', 'newspaper', 'neon', 'polaroid']));
    });

    test('an empty or foreign map is the classic card; out-of-range values are clamped; unknown ones ignored', () {
      expect(CardDesign.tryParse(const {}), isNull);
      expect(CardDesign.tryParse(const {'kind': 'poster'}), isNull);
      expect(CardDesign.tryParse('text'), isNull);
      final wild = CardDesign.tryParse({
        'kind': 'audio',
        'margin': 9999,
        'future': {'layer': true},
        'background': {'kind': 'hologram', 'grain': 7, 'colors': [1, 2, 3, 4, 5]},
        'cover': {'size': 3, 'rotation': 900, 'shape': 'vinyl'},
        'waveform': {'bars': 9999, 'style': 'line'},
        'blocks': [
          {'role': 'title', 'size': 9000, 'weight': 950, 'letterSpacing': 3, 'customFont': {'family': 'Comic Sans MS', 'path': r'C:\Windows\Fonts\comic.ttf'}},
          {'role': 'nonsense'},
          'not a block',
        ],
      })!;
      expect(wild.margin, 240);
      expect(wild.background.kind, CardFillKind.solid);
      expect(wild.background.grain, 1);
      expect(wild.background.colors, hasLength(3), reason: 'at most three stops');
      expect((wild.cover.size, wild.cover.rotation, wild.cover.shape), (1.0, 180.0, CardCoverShape.vinyl));
      expect(wild.waveform.bars, 256);
      expect(wild.blocks, hasLength(2));
      expect((wild.blocks[0].size, wild.blocks[0].weight, wild.blocks[0].letterSpacing), (320.0, 900, 0.5));
      expect(wild.blocks[0].customFont?.family, 'Comic Sans MS');
      expect(wild.blocks[1].role, CardBlockRole.custom);
      expect(wild.customFonts.single.family, 'Comic Sans MS');
    });

    test('presets and Settings keep designs; Settings without them read as before', () {
      final design = kCardTemplates.first.design(CardKind.text);
      final preset = CardPreset.tryParse(CardPreset(name: 'Mine', design: design).toJson())!;
      expect(preset.name, 'Mine');
      expect(renderParametersEqual(preset.design.toJson(), design.toJson()), isTrue);
      expect(CardPreset.tryParse(const {'name': ' ', 'design': {}}), isNull);

      const old = AppSettings();
      expect(old.toJson().keys.where((k) => k.startsWith('textCardDesign') || k == 'audioCardDesign' || k == 'cardPresets' || k == 'textCardCustomFont'), isEmpty);
      final s = old.copyWith(
        textCardDesign: design.toJson(),
        audioCardDesign: kCardTemplates[2].design(CardKind.audio).toJson(),
        cardPresets: [preset.toJson()],
        textCardCustomFont: const CaptionFont(family: 'Comic Sans MS').toJson(),
      );
      final back = AppSettings.fromJson(s.toJson());
      expect(CardDesign.tryParse(back.textCardDesign)?.template, design.template);
      expect(CardDesign.tryParse(back.audioCardDesign)?.kind, CardKind.audio);
      expect(CardPreset.tryParse(back.cardPresets.single)?.name, 'Mine');
      expect(back.textCardCustomFontChoice?.family, 'Comic Sans MS');
    });

    test('classic cards keep the render parameters they were made with', () {
      final p = textCardPlaceholder('instagram', TextCardTheme.dark);
      expect(p.renderParameters!.keys.toSet(), {'kind', 'platform', 'theme', 'font', 'branded', 'alignment', 'handle', 'safe'});
      final designed = textCardPlaceholder('instagram', TextCardTheme.dark, design: kCardTemplates.first.design(CardKind.text));
      expect(textCardDesignOf(designed)?.template, 'minimal');
      expect(textCardDesignOf(p), isNull);
    });
  });

  group('waveform', () {
    test('measures 16-bit, 24-bit and float WAV, stereo too: loud where the sound is loud', () {
      double ramp(double t) => t;
      for (final (name, bytes) in [
        ('16-bit', _wav(envelope: ramp)),
        ('24-bit', _wav(bits: 24, envelope: ramp)),
        ('float', _wav(bits: 32, float: true, envelope: ramp)),
        ('stereo', _wav(channels: 2, envelope: ramp)),
      ]) {
        final levels = measurePcmWaveform(bytes, bins: 16)!;
        expect(levels, hasLength(16), reason: name);
        expect(levels.last, closeTo(1, 0.01), reason: '$name: the loudest bin is 1');
        expect(levels.first, lessThan(0.15), reason: '$name: quiet at the start');
        for (var i = 1; i < levels.length; i++) {
          expect(levels[i], greaterThanOrEqualTo(levels[i - 1] - 0.05), reason: '$name rises');
        }
      }
    });

    test('measures AIFF and AIFF-C (sowt)', () {
      double dip(double t) => t < 0.5 ? 1 : 0.25;
      for (final little in [false, true]) {
        final levels = measurePcmWaveform(_aiff(envelope: dip, littleEndian: little), bins: 8)!;
        expect(levels.first, closeTo(1, 0.02));
        expect(levels.last, closeTo(0.25, 0.03), reason: little ? 'sowt' : 'aiff');
      }
    });

    test('compressed or broken files are not measured; the decorative shape is the same for the same seed', () {
      expect(measurePcmWaveform(Uint8List.fromList('ID3 not pcm at all'.codeUnits)), isNull);
      expect(measurePcmWaveform(Uint8List(4)), isNull);
      final a = decorativeWaveform(1234), b = decorativeWaveform(1234), c = decorativeWaveform(99);
      expect(a, b);
      expect(a, isNot(c));
      expect(a.reduce(math.max), 1);
      expect(resampleLevels(a, 32), hasLength(32));
    });
  });

  group('renderer', () {
    testWidgets('the same design draws the same bytes; each layer changes the picture', (tester) async {
      final base = kCardTemplates.first.design(CardKind.audio);
      Future<String> draw(CardDesign d) async {
        final bytes = (await tester.runAsync(() => renderCardDesign(
            CardRenderInput(design: d, size: const Size(216, 216), texts: _trackWords, cover: _photo(120, 120), photo: _photo(120, 120), waveform: decorativeWaveform(7)))))!;
        return stableHash(String.fromCharCodes(bytes));
      }

      final plain = await draw(base);
      expect(await draw(base), plain, reason: 'deterministic, grain included');
      final variants = <String, CardDesign>{
        'linear': base.copyWith(background: base.background.copyWith(kind: CardFillKind.linear)),
        'radial': base.copyWith(background: base.background.copyWith(kind: CardFillKind.radial)),
        'photo': base.copyWith(background: base.background.copyWith(kind: CardFillKind.image)),
        'stripes': base.copyWith(background: base.background.copyWith(pattern: CardPattern.stripes)),
        'dots': base.copyWith(background: base.background.copyWith(pattern: CardPattern.dots)),
        'grid': base.copyWith(background: base.background.copyWith(pattern: CardPattern.grid)),
        'grain': base.copyWith(background: base.background.copyWith(grain: 0.5)),
        'circle': base.copyWith(cover: base.cover.copyWith(shape: CardCoverShape.circle)),
        'vinyl': base.copyWith(cover: base.cover.copyWith(shape: CardCoverShape.vinyl)),
        'rotation': base.copyWith(cover: base.cover.copyWith(rotation: 12)),
        'border': base.copyWith(cover: base.cover.copyWith(borderWidth: 20)),
        'bars': base.copyWith(waveform: base.waveform.copyWith(style: CardWaveformStyle.bars)),
        'dots wave': base.copyWith(waveform: base.waveform.copyWith(style: CardWaveformStyle.dots)),
        'outline': base.withBlock(0, (b) => b.copyWith(outlineWidth: 4)),
        'uppercase': base.withBlock(0, (b) => b.copyWith(uppercase: true)),
        'anchor': base.withBlock(0, (b) => b.copyWith(anchor: CardAnchor.topRight)),
      };
      for (final MapEntry(key: name, value: d) in variants.entries) {
        expect(await draw(d), isNot(plain), reason: name);
      }
    });

    testWidgets('text stays inside a full-screen card\'s safe area', (tester) async {
      final design = kCardTemplates.first.design(CardKind.text).withBlock(0, (b) => b.copyWith(anchor: CardAnchor.bottomRight, offsetX: 1, offsetY: 1));
      const size = Size(270, 480);
      final safe = fullScreenSafeArea('tiktok');
      final frame = cardFrameOf(size, safe, design.margin);
      final bytes = (await tester.runAsync(() => renderCardDesign(
          CardRenderInput(design: design, size: size, safe: safe, texts: _textWords),
          png: true)))!;
      final image = img.decodePng(bytes)!;
      final background = image.getPixel(0, 0);
      // Nothing but the background below and to the right of the frame.
      for (var y = frame.bottom.ceil() + 1; y < image.height; y += 3) {
        for (var x = 0; x < image.width; x += 3) {
          final p = image.getPixel(x, y);
          expect((p.r - background.r).abs() + (p.g - background.g).abs() + (p.b - background.b).abs(), lessThan(24), reason: 'at $x, $y');
        }
      }
    });

    group('goldens', () {
      for (final t in kCardTemplates) {
        for (final kind in CardKind.values) {
          testWidgets('${t.name}, ${kind.label.toLowerCase()}', (tester) async {
            final size = kind == CardKind.text ? const Size(270, 338) : const Size(270, 270);
            final bytes = (await tester.runAsync(() => renderCardDesign(
                  CardRenderInput(
                    design: t.design(kind),
                    size: size,
                    platformId: 'instagram',
                    texts: kind == CardKind.text ? _textWords : _trackWords,
                    photo: _photo(240, 240),
                    cover: _photo(240, 240),
                    waveform: decorativeWaveform(42),
                  ),
                  png: true,
                )))!;
            final image = (await tester.runAsync(() => _decode(bytes)))!;
            await expectLater(image, matchesGoldenFile('card_goldens/${t.id}-${kind.name}.png'));
            image.dispose();
          });
        }
      }

      testWidgets('a text block in an installed font, loaded through FontLoader', (tester) async {
        debugResetCaptionFonts();
        addTearDown(debugResetCaptionFonts);
        final mono = File('assets/fonts/JetBrainsMono-Regular.ttf').absolute.path;
        debugInstalledFontCatalog = InstalledFontCatalog.fromEntries([
          {'path': mono, 'faces': [const FontFace(family: 'JetBrains Mono').toJson()]},
        ]);
        // Found by family through the installed-font registry, as on a PC
        // whose font folder has it.
        const font = CaptionFont(family: 'JetBrains Mono', path: '/elsewhere/JetBrainsMono.ttf');
        expect((await tester.runAsync(() => prepareCaptionFont(_NoStorage(), font)))!, isTrue);
        expect(registeredCaptionFontAlias(font), font.alias);
        final design = cardTemplateById('neon')!.design(CardKind.text).withBlock(0, (b) => b.copyWith(customFont: font));
        final bytes = (await tester.runAsync(() => renderCardDesign(
              CardRenderInput(design: design, size: const Size(270, 338), texts: _textWords),
              png: true,
            )))!;
        final image = (await tester.runAsync(() => _decode(bytes)))!;
        await expectLater(image, matchesGoldenFile('card_goldens/installed-font-text.png'));
        image.dispose();
      });
    });
  });
}
