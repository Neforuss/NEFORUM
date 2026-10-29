// The PDF layout analysis on pages built by hand (no PDFium): ligatures,
// running headers that alternate between odd and even pages, roman page
// numbers, columns that start at different heights.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/documents/document_model.dart';
import 'package:neforum_app/documents/pdf_layout.dart';

/// A page whose lines are (left, top, size, text); every character is half
/// an em wide, words are separated by a space's gap.
PdfPageContent _page(int index, List<(double, double, double, String)> lines) {
  final values = <double>[];
  for (final (left, top, size, text) in lines) {
    var x = left;
    var space = false;
    for (final code in text.runes) {
      if (code == 32) {
        x += size * 0.28;
        space = true;
        continue;
      }
      values.addAll([code.toDouble(), x, top, x + size * 0.5, top + size * 1.15, size, 400, space ? kPdfSpaceBefore.toDouble() : 0]);
      x += size * 0.5;
      space = false;
    }
  }
  return PdfPageContent(index: index, width: 612, height: 792, chars: Float64List.fromList(values));
}

List<String> _texts(IngestedDocument d) => [
      for (final b in d.blocks)
        if (b is DocumentParagraph) b.text else if (b is DocumentHeading) '# ${b.text}',
    ];

void main() {
  test('ligature characters are spelled out', () {
    final d = layoutPdfPages([
      _page(0, [(72, 100, 10, 'The ﬁrst ﬂoor is oﬀ limits.')]),
    ]);
    expect(_texts(d), ['The first floor is off limits.']);
  });

  test('alternating running headers and roman page numbers are left out', () {
    final pages = [
      for (var i = 0; i < 4; i++)
        _page(i, [
          (72, 40, 9, i.isEven ? 'A Field Guide to Ponds' : 'Chapter One: Getting Started'),
          (72, 120, 10, 'Body text on page ${i + 1} stays where it is.'),
          (300, 760, 9, ['i', 'ii', 'iii', 'iv'][i]),
        ]),
    ];
    expect(_texts(layoutPdfPages(pages)), [for (var i = 0; i < 4; i++) 'Body text on page ${i + 1} stays where it is.']);
  });

  test('the left column is read before the right one, even when the right one starts higher', () {
    final d = layoutPdfPages([
      _page(0, [
        (72, 60, 18, 'Title Across'),
        (72, 120, 10, 'Left one starts the story and'),
        (72, 133, 10, 'goes on down the column.'),
        (330, 110, 10, 'Right one ends the story'),
        (330, 123, 10, 'at the bottom of the page.'),
      ]),
    ]);
    expect(_texts(d), ['# Title Across', 'Left one starts the story and goes on down the column.', 'Right one ends the story at the bottom of the page.']);
  });
}
