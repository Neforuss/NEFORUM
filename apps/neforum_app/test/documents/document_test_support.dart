// Helpers for the document ingest tests: pictures of known colours and a
// word-level diff.

import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:neforum_app/documents/document_model.dart';
import 'package:neforum_app/documents/text_normalization.dart';
import 'package:neforum_app/documents/thread_builder.dart';

/// A small PNG of one colour (0xRRGGBB).
Uint8List solidPng(int color, {int width = 32, int height = 24}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8((color >> 16) & 0xFF, (color >> 8) & 0xFF, color & 0xFF));
  return Uint8List.fromList(img.encodePng(image));
}

/// The average colour of the middle of an encoded picture, as 0xRRGGBB.
int middleColor(Uint8List bytes) {
  final image = img.decodeImage(bytes)!;
  var r = 0, g = 0, b = 0, n = 0;
  for (var y = image.height ~/ 3; y < image.height * 2 ~/ 3; y++) {
    for (var x = image.width ~/ 3; x < image.width * 2 ~/ 3; x++) {
      final p = image.getPixel(x, y);
      r += p.r.toInt();
      g += p.g.toInt();
      b += p.b.toInt();
      n++;
    }
  }
  return ((r ~/ n) << 16) | ((g ~/ n) << 8) | (b ~/ n);
}

/// Of [candidates] (name → 0xRRGGBB), the one closest to [color].
String nearestColor(int color, Map<String, int> candidates) {
  int d(int a, int b) {
    final dr = ((a >> 16) & 0xFF) - ((b >> 16) & 0xFF);
    final dg = ((a >> 8) & 0xFF) - ((b >> 8) & 0xFF);
    final db = (a & 0xFF) - (b & 0xFF);
    return dr * dr + dg * dg + db * db;
  }

  return candidates.entries.reduce((x, y) => d(color, x.value) <= d(color, y.value) ? x : y).key;
}

/// Every word of the text of [document] (headings and paragraphs), in order.
List<String> documentWords(IngestedDocument document) => [
      for (final b in document.blocks)
        ...switch (b) {
          DocumentHeading(:final text) => wordsOf(text),
          DocumentParagraph(:final text) => wordsOf(text),
          DocumentImage() => const <String>[],
        },
    ];

/// The words that differ between [expected] and [actual]: an edit script of
/// a longest-common-subsequence diff, as "-word" (missing) and "+word"
/// (extra). Empty when the two are the same.
List<String> wordDiff(List<String> expected, List<String> actual) {
  final n = expected.length, m = actual.length;
  final lcs = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = expected[i] == actual[j] ? lcs[i + 1][j + 1] + 1 : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final out = <String>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (expected[i] == actual[j]) {
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.add('-${expected[i++]}');
    } else {
      out.add('+${actual[j++]}');
    }
  }
  while (i < n) {
    out.add('-${expected[i++]}');
  }
  while (j < m) {
    out.add('+${actual[j++]}');
  }
  return out;
}

/// The index of the thread part whose text holds [phrase] (white space
/// ignored), or -1.
int partWith(DocumentThread thread, String phrase) {
  final wanted = wordsOf(phrase).join(' ');
  for (var i = 0; i < thread.parts.length; i++) {
    if (wordsOf(thread.parts[i].text).join(' ').contains(wanted)) return i;
  }
  return -1;
}

/// The index of the part that holds [image], or -1.
int partOfImage(DocumentThread thread, DocumentImage image) {
  for (var i = 0; i < thread.parts.length; i++) {
    if (thread.parts[i].images.contains(image)) return i;
  }
  return -1;
}
