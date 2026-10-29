// PDFs read with PDFium (pdfrx) against fixtures with known content
// (test/documents/fixture_content.dart, written by
// tool/generate_document_fixtures.dart): every word in order, every picture
// once and in the right part, nothing from running headers or footers.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/documents/document_model.dart';
import 'package:neforum_app/documents/pdf_reader.dart';
import 'package:neforum_app/documents/thread_builder.dart';

import 'document_test_support.dart';
import 'fixture_content.dart';

Future<IngestedDocument> _read(String file) => readPdf(File('test/fixtures/documents/$file').readAsBytesSync());

void main() {
  // Turned pages and pages inside a bleed read exactly like the plain ones.
  for (final fixture in [...pdfFixtures, ...pageBoxFixtures]) {
    group(fixture.file, () {
      late IngestedDocument document;
      late DocumentThread thread;
      setUpAll(() async {
        document = await _read(fixture.file);
        thread = buildDocumentThread(document, partLength: 280);
      });

      test('every word, in reading order (zero word-level diff)', () {
        final diff = wordDiff(fixture.words, documentWords(document));
        expect(diff, isEmpty, reason: 'differences: ${diff.join(' ')}\n\nread: ${documentWords(document).join(' ')}');
      });

      test('paragraphs and headings as written, across columns and pages', () {
        final expected = [
          if (fixture.title != null) 'H ${fixture.title!.text}',
          for (final b in fixture.blocks)
            if (b is FixtureHeading) 'H ${b.text}' else if (b is FixtureParagraph) 'P ${b.text}',
        ];
        final actual = [
          for (final b in document.blocks)
            if (b is DocumentHeading) 'H ${b.text}' else if (b is DocumentParagraph) 'P ${b.text}',
        ];
        expect(actual, expected);
      });

      test('every picture exactly once, in the part holding its paragraph, described by its caption', () {
        final colours = {
          for (final i in fixture.images)
            if (!i.chart) i.name: i.color,
        };
        final images = document.images.toList();
        expect(images, hasLength(fixture.images.length));
        final seen = <String>[];
        for (final image in images) {
          final name = image.mimeType == 'image/png' ? 'chart' : nearestColor(middleColor(image.bytes), colours);
          seen.add(name);
          final expected = fixture.images.firstWhere((i) => i.name == name);
          expect(partOfImage(thread, image), partWith(thread, expected.anchorPhrase), reason: '$name belongs with "${expected.anchorPhrase}"');
          if (expected.caption != null) expect(image.altText, expected.caption);
        }
        expect(seen..sort(), [for (final i in fixture.images) i.name]..sort());
        expect(thread.imageCount, fixture.images.length);
      });

      test('no running header, footer or page number', () {
        final words = documentWords(document).join(' ');
        if (fixture.header != null) expect(words, isNot(contains(fixture.header!)));
        if (fixture.footer != null) expect(words, isNot(contains(RegExp(r'Page \d+ of \d+'))));
        for (final part in thread.parts) {
          expect(part.text, isNot(contains('Bulletin')));
        }
      });

      test('headings start parts', () {
        for (final h in fixture.blocks.whereType<FixtureHeading>()) {
          final i = partWith(thread, h.text);
          expect(i, isNonNegative, reason: h.text);
          expect(thread.parts[i].text, startsWith(h.text));
        }
      });
    });
  }

  test('a scanned PDF says it has no text layer', () async {
    final document = await _read(scannedFixtureFile);
    expect(document.blocks.whereType<DocumentParagraph>(), isEmpty);
    expect(document.warnings.single, contains('no text layer'));
  });

  test('a damaged PDF is refused clearly', () async {
    expect(readPdf(Uint8List.fromList(List.filled(64, 65))), throwsA(isA<DocumentReadException>()));
  });
}
