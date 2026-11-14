import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

// 1.4.3: symbols. Which characters this device's fonts draw, so the character
// panel never offers an empty box. A missing character draws as nothing, or
// as the same "no glyph" box a code point no font has (U+1FFFD) draws as. The
// characters of a group are drawn together, offscreen, in one picture.

/// What is known per character, for the rest of the run.
class GlyphSupport {
  GlyphSupport._();

  static final Map<String, bool> _known = {};

  /// Replaces the offscreen drawing, for tests: `flutter test` has no real
  /// fonts, and its test font draws every character as the same box.
  @visibleForTesting
  static bool Function(String text)? debugProbe;

  @visibleForTesting
  static void debugReset() {
    _known.clear();
    debugProbe = null;
  }

  /// Whether [text] is known to draw; null until tried.
  static bool? known(String text) => _known[text];

  /// Tries every one of [texts] not tried yet, drawn in [style], and answers
  /// for all of them: true where this device draws it. A failed try counts as
  /// drawn, so a broken check never hides the whole panel.
  static Future<Map<String, bool>> probe(Iterable<String> texts, {TextStyle style = const TextStyle(fontSize: 24)}) async {
    final fresh = [for (final t in texts.toSet()) if (!_known.containsKey(t)) t];
    final override = debugProbe;
    if (override != null) {
      for (final t in fresh) {
        _known[t] = override(t);
      }
    } else if (fresh.isNotEmpty) {
      try {
        final drawn = await _drawAll(fresh, style);
        for (var i = 0; i < fresh.length; i++) {
          _known[fresh[i]] = drawn[i];
        }
      } on Object catch (e) {
        debugPrint('Could not try the symbols: $e');
        for (final t in fresh) {
          _known[t] = true;
        }
      }
    }
    return {for (final t in texts) t: _known[t] ?? true};
  }

  static const int _cell = 40;
  static const int _columns = 16;

  /// Cell 0 holds the "no glyph" reference; cell i + 1 holds [texts][i].
  static Future<List<bool>> _drawAll(List<String> texts, TextStyle style) async {
    final all = ['\u{1FFFD}', ...texts];
    final rows = (all.length + _columns - 1) ~/ _columns;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final ink = style.copyWith(fontSize: 24, height: 1, color: const ui.Color(0xFF000000));
    for (var i = 0; i < all.length; i++) {
      final painter = TextPainter(text: TextSpan(text: all[i], style: ink), textDirection: TextDirection.ltr, maxLines: 1)..layout();
      canvas.save();
      canvas.clipRect(ui.Rect.fromLTWH(((i % _columns) * _cell).toDouble(), ((i ~/ _columns) * _cell).toDouble(), _cell.toDouble(), _cell.toDouble()));
      painter.paint(canvas, ui.Offset(((i % _columns) * _cell + 4).toDouble(), ((i ~/ _columns) * _cell + 4).toDouble()));
      canvas.restore();
      painter.dispose();
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(_columns * _cell, rows * _cell);
    picture.dispose();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (data == null) return List.filled(texts.length, true);
      final width = image.width;
      final reference = _cellPixels(data, width, 0);
      return [
        for (var i = 1; i < all.length; i++)
          () {
            final cell = _cellPixels(data, width, i);
            return _hasInk(cell) && !listEquals(cell, reference);
          }(),
      ];
    } finally {
      image.dispose();
    }
  }

  static Uint8List _cellPixels(ByteData rgba, int width, int index) {
    final x0 = (index % _columns) * _cell, y0 = (index ~/ _columns) * _cell;
    final out = Uint8List(_cell * _cell);
    for (var y = 0; y < _cell; y++) {
      for (var x = 0; x < _cell; x++) {
        out[y * _cell + x] = rgba.getUint8(((y0 + y) * width + x0 + x) * 4 + 3);
      }
    }
    return out;
  }

  static bool _hasInk(Uint8List alpha) => alpha.any((a) => a > 40);
}
