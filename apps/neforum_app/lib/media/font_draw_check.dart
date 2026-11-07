import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show FontLoader;

import 'font_files.dart';

// Whether a font file really draws on this device. The engine accepts files
// and then draws nothing from them, with no error: Noto Color Emoji (COLRv1)
// loads fine and is blank on Windows. So a downloaded font is drawn once,
// offscreen, before it is kept.

var _checks = 0;

const double _cell = 128;
const int _columns = 4;

/// Loads [bytes] under a name used for nothing else (the engine cannot unload
/// a font, so a font that fails must not take a name a style uses) and draws
/// characters this file maps ([fontSampleCodePoints]), so that what is measured
/// is this file and not a fallback font. True when at least half of them left
/// ink; a font may have a few blank glyphs, not mostly blank ones.
Future<bool> fontFileDraws(Uint8List bytes) async {
  final sample = fontSampleCodePoints(bytes);
  if (sample.isEmpty) return false;
  final alias = 'NEFORUM font check ${_checks++}';
  final loader = FontLoader(alias)..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  for (var i = 0; i < sample.length; i++) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: alias, fontSize: 48, textDirection: ui.TextDirection.ltr))
      ..pushStyle(ui.TextStyle(fontFamily: alias, fontSize: 48, color: const ui.Color(0xFF000000)))
      ..addText(String.fromCharCode(sample[i]));
    final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: _cell));
    canvas.drawParagraph(paragraph, ui.Offset((i % _columns) * _cell, (i ~/ _columns) * _cell));
    paragraph.dispose();
  }
  final rows = (sample.length + _columns - 1) ~/ _columns;
  final picture = recorder.endRecording();
  final image = await picture.toImage((_columns * _cell).toInt(), (rows * _cell).toInt());
  picture.dispose();
  try {
    final data = await image.toByteData();
    if (data == null) return false;
    final inked = _inkedCells(data, image.width, sample.length);
    return inked * 2 >= sample.length;
  } finally {
    image.dispose();
  }
}

/// How many of the first [count] cells hold a pixel that is not transparent.
int _inkedCells(ByteData rgba, int width, int count) {
  final seen = <int>{};
  final cell = _cell.toInt();
  final height = rgba.lengthInBytes ~/ (4 * width);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (rgba.getUint8((y * width + x) * 4 + 3) < 32) continue;
      seen.add((y ~/ cell) * _columns + x ~/ cell);
    }
  }
  return seen.where((c) => c < count).length;
}
