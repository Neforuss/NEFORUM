import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/photo_composite.dart';
import 'package:neforum_app/media/photo_pixels.dart';
import 'package:neforum_app/media/render_parameters.dart';
import 'package:neforum_app/media/text_card_background.dart';
import 'package:neforum_core/neforum_core.dart' show MediaAttachment;

/// FNV-1a over bytes.
String _hash(Uint8List b) {
  var h = 0x811c9dc5;
  for (final c in b) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16);
}

const _pw = 301, _ph = 197;

PhotoPixels _photo() {
  final rgba = Uint8List(_pw * _ph * 4);
  for (var y = 0; y < _ph; y++) {
    for (var x = 0; x < _pw; x++) {
      final o = (y * _pw + x) * 4;
      rgba[o] = (x * 7 + y * 3) & 0xFF;
      rgba[o + 1] = (x * x ~/ 5 + y) & 0xFF;
      rgba[o + 2] = (y * 11 ^ x) & 0xFF;
      rgba[o + 3] = 255;
    }
  }
  return PhotoPixels(rgba: rgba, width: _pw, height: _ph, luminance: 0.5, topColor: 0, bottomColor: 0);
}

Uint8List _words(int w, int h) {
  final words = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    words[i * 4] = 255;
    words[i * 4 + 1] = 255;
    words[i * 4 + 2] = 255;
    words[i * 4 + 3] = (i % 17 == 0) ? 255 : ((i % 5 == 0) ? 128 : 0);
  }
  return words;
}

const _photoAttachment = MediaAttachment(id: 'p1', path: '/p1.jpg', mimeType: 'image/jpeg', sizeBytes: 1);

void main() {
  group('defaults compose byte for byte what 1.2 made', () {
    // Recorded with the compositor of 1.2.3 (commit f06838c), before the 1.3
    // background options existed: (width, height, blur, dimming) -> JPEG
    // length and FNV-1a hash.
    final baseline = {
      (216, 270, 12.0, 0.35): (66893, 'ed38dc14'),
      (120, 120, 0.0, 0.0): (20582, '12db61b5'),
      (180, 320, 30.0, 0.8): (51152, 'd93b7d8a'),
    };
    for (final MapEntry(key: (w, h, blur, dim), value: (length, hash)) in baseline.entries) {
      test('$w x $h, blur $blur, dimming $dim', () {
        final photo = _photo();
        final words = _words(w, h);
        final plain = composeTextCard(TextCardComposeJob(photo: photo, words: words, width: w, height: h, blur: blur, dimming: dim));
        expect((plain.length, _hash(plain)), (length, hash));
        // A 1.3 background left at its defaults, on either card colour.
        for (final card in const [Color(0xFF000000), Color(0xFFFFFFFF)]) {
          final job = TextCardComposeJob.forBackground(
            photo: photo,
            words: words,
            width: w,
            height: h,
            background: TextCardBackground(photo: _photoAttachment, blur: blur, dimming: dim),
            cardColor: card,
          );
          final out = composeTextCard(job);
          expect((out.length, _hash(out)), (length, hash));
        }
      });
    }
  });

  group('render parameters', () {
    test('a card made before 1.3 reads back to the same parameters', () {
      final old = {'mediaId': 'p1', 'blur': 20, 'dimming': 0.5, 'textColor': 'white', 'textBox': true};
      final b = TextCardBackground.fromRenderParameters(old, (_) => _photoAttachment)!;
      expect(b.zoom, 1);
      expect(b.fit, TextCardBackgroundFit.cover);
      expect(b.textPosition, TextCardTextPosition.center);
      expect(b.colorMatrix, isNull);
      expect(b.gradientColors, isNull);
      expect(renderParametersEqual(b.toRenderParameters(), old), isTrue);
    });

    test('composer JSON from 1.2 still parses', () {
      final b = TextCardBackground.tryParse({'photo': _photoAttachment.toJson(), 'blur': 12, 'dimming': 0.35, 'textColor': 'automatic', 'textBox': false})!;
      expect(b.toRenderParameters().keys.toSet(), {'mediaId', 'blur', 'dimming', 'textColor', 'textBox'});
    });

    test('every new choice round-trips, out-of-range values are clamped', () {
      const b = TextCardBackground(
        photo: _photoAttachment,
        offsetX: -0.5,
        offsetY: 0.25,
        zoom: 2.5,
        fit: TextCardBackgroundFit.contain,
        quarterTurns: 3,
        flipHorizontal: true,
        brightness: 0.2,
        contrast: -0.3,
        saturation: 0.4,
        tintColor: 0xFF00FF00,
        tintStrength: 0.5,
        gradientStart: 0xFFFF0000,
        gradientEnd: 0xFF0000FF,
        gradientAngle: 90,
        gradientStrength: 0.7,
        vignette: 0.6,
        textPosition: TextCardTextPosition.bottom,
      );
      final back = TextCardBackground.tryParse(b.toJson())!;
      expect(renderParametersEqual(back.toJson(), b.toJson()), isTrue);
      expect(renderParametersEqual(back.toRenderParameters(), b.toRenderParameters()), isTrue);
      final wild = TextCardBackground.tryParse({'photo': _photoAttachment.toJson(), 'zoom': 9, 'offsetX': -7, 'quarterTurns': 6, 'vignette': 3})!;
      expect((wild.zoom, wild.offsetX, wild.quarterTurns, wild.vignette), (TextCardBackground.maxZoom, -1.0, 2, 1.0));
    });

    test('colours without strength stay out of the render parameters', () {
      const b = TextCardBackground(photo: _photoAttachment, tintColor: 0xFF00FF00, gradientStart: 0xFFFF0000);
      expect(b.toRenderParameters().containsKey('tintColor'), isFalse);
      expect(b.toRenderParameters().containsKey('gradientStart'), isFalse);
      expect(b.toJson()['tintColor'], 0xFF00FF00);
      expect(b.withDefaultEffects().toRenderParameters().length, 5);
    });
  });

  group('compositor', () {
    test('photoPlacement at its defaults is the centred cover', () {
      final c = coverSource(_pw, _ph, 100, 160);
      final p = photoPlacement(_pw, _ph, 100, 160);
      expect((p.sx, p.sy, p.sw, p.sh, p.dx, p.dy, p.dw, p.dh), (c.x, c.y, c.w, c.h, 0.0, 0.0, 100.0, 160.0));
    });

    test('contain fits the whole photo and the focal point moves it', () {
      final p = photoPlacement(200, 100, 100, 100, contain: true);
      expect((p.sx, p.sy, p.sw, p.sh), (0.0, 0.0, 200.0, 100.0));
      expect((p.dx, p.dy, p.dw, p.dh), (0.0, 25.0, 100.0, 50.0));
      final top = photoPlacement(200, 100, 100, 100, contain: true, offsetY: -1);
      expect(top.dy, 0);
      final zoomed = photoPlacement(200, 100, 100, 100, zoom: 2, offsetX: 1);
      // Cover scale 1, doubled: 400 x 200 shown, the right edge in view.
      expect(zoomed.sx + zoomed.sw, closeTo(200, 1e-9));
      expect(zoomed.sw, closeTo(50, 1e-9));
    });

    test('orientRgba turns clockwise and mirrors', () {
      // 2 x 1: red, green.
      final px = Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255]);
      final (cw, w, h) = orientRgba(px, 2, 1, quarterTurns: 1);
      expect((w, h), (1, 2));
      expect(cw.sublist(0, 4), [255, 0, 0, 255]); // red on top
      final (flipped, _, _) = orientRgba(px, 2, 1, flip: true);
      expect(flipped.sublist(0, 4), [0, 255, 0, 255]);
      final (ccw, _, _) = orientRgba(px, 2, 1, quarterTurns: 3);
      expect(ccw.sublist(0, 4), [0, 255, 0, 255]); // green on top
    });

    test('black and white makes every pixel grey', () {
      final m = const TextCardBackground(photo: _photoAttachment, blackAndWhite: true).colorMatrix!;
      final out = applyColorMatrix(_photo().rgba, m);
      for (var o = 0; o < out.length; o += 4 * 97) {
        expect(out[o], out[o + 1]);
        expect(out[o + 1], out[o + 2]);
      }
    });

    test('a whole photo is letterboxed with the card colour', () {
      final frame = RgbFrame(40, 80)..placePhoto(_photo().rgba, _pw, _ph, contain: true, fillRgb: 0xFFFFFF);
      expect(frame.rgb.sublist(0, 3), [255, 255, 255]);
      final last = frame.rgb.length - 3;
      expect(frame.rgb.sublist(last), [255, 255, 255]);
    });

    test('every option is deterministic and changes the picture', () {
      const w = 108, h = 135;
      final photo = _photo();
      final words = _words(w, h);
      Uint8List render(TextCardBackground b) => composeTextCard(
          TextCardComposeJob.forBackground(photo: photo, words: words, width: w, height: h, background: b, cardColor: const Color(0xFF000000)));
      final plain = _hash(render(const TextCardBackground(photo: _photoAttachment)));
      final options = <String, TextCardBackground>{
        'pan': const TextCardBackground(photo: _photoAttachment, offsetX: 0.8),
        'zoom': const TextCardBackground(photo: _photoAttachment, zoom: 2),
        'contain': const TextCardBackground(photo: _photoAttachment, fit: TextCardBackgroundFit.contain),
        'turn': const TextCardBackground(photo: _photoAttachment, quarterTurns: 1),
        'flip': const TextCardBackground(photo: _photoAttachment, flipHorizontal: true),
        'brightness': const TextCardBackground(photo: _photoAttachment, brightness: 0.3),
        'contrast': const TextCardBackground(photo: _photoAttachment, contrast: 0.5),
        'saturation': const TextCardBackground(photo: _photoAttachment, saturation: -0.6),
        'black and white': const TextCardBackground(photo: _photoAttachment, blackAndWhite: true),
        'tint': const TextCardBackground(photo: _photoAttachment, tintStrength: 0.5),
        'gradient': const TextCardBackground(photo: _photoAttachment, gradientStrength: 0.8, gradientAngle: 45),
        'vignette': const TextCardBackground(photo: _photoAttachment, vignette: 0.9),
      };
      for (final MapEntry(key: name, value: b) in options.entries) {
        final first = _hash(render(b));
        expect(first, isNot(plain), reason: name);
        expect(_hash(render(b)), first, reason: '$name twice');
      }
    });
  });
}
