// DOCX, EPUB, Markdown, HTML and plain text read into blocks and threads,
// against documents built here with known paragraphs and pictures in known
// places.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/documents/document_ingest.dart';
import 'package:neforum_app/documents/document_model.dart';
import 'package:neforum_app/documents/text_normalization.dart';
import 'package:neforum_app/documents/thread_builder.dart';

import 'document_test_support.dart';

const _red = 0xD62828, _green = 0x2A9D3F, _blue = 0x1D4ED8, _orange = 0xF77F00;
const _colors = {'red': _red, 'green': _green, 'blue': _blue, 'orange': _orange};

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

List<int> _utf8(String s) => utf8.encode(s);

/// What a block list says, for exact comparisons: "H1 text", "P text",
/// "IMG colour | alt".
List<String> _describe(IngestedDocument d) => [
      for (final b in d.blocks)
        switch (b) {
          DocumentHeading(:final text, :final level) => 'H$level $text',
          DocumentParagraph(:final text) => 'P $text',
          DocumentImage(:final bytes, :final altText) => 'IMG ${nearestColor(middleColor(bytes), _colors)} | ${altText ?? ''}',
        },
    ];

// ---------------------------------------------------------------------------
// DOCX

const _w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" '
    'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
    'xmlns:v="urn:schemas-microsoft-com:vml"';

String _run(String text) => '<w:r><w:t xml:space="preserve">$text</w:t></w:r>';

String _drawing(String rel, {String descr = ''}) => '<w:r><w:drawing><wp:inline><wp:extent cx="100" cy="100"/>'
    '<wp:docPr id="1" name="Picture 1" descr="$descr"/>'
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>'
    '<pic:blipFill><a:blip r:embed="$rel"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>';

String _para(String content, {String? style, String? numId}) =>
    '<w:p>${style == null && numId == null ? '' : '<w:pPr>${style == null ? '' : '<w:pStyle w:val="$style"/>'}'
        '${numId == null ? '' : '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="$numId"/></w:numPr>'}</w:pPr>'}$content</w:p>';

Uint8List _docx() {
  final body = [
    _para(_run('Garden Plan'), style: 'Heading1'),
    _para('${_run('The beds along the south wall get the most sun, ')}${_run('so the tomatoes go there.')}'),
    // A picture inside a paragraph: it follows the paragraph.
    _para('${_run('The old wall was repointed in May.')}${_drawing('rIdRed', descr: 'A red brick wall')}'),
    // Deleted text, field codes and tracked insertions.
    _para('<w:del><w:r><w:delText>Removed words. </w:delText></w:r></w:del>'
        '<w:ins>${_run('Inserted words stay.')}</w:ins>'
        '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> PAGE </w:instrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="separate"/></w:r>${_run(' Field result.')}<w:r><w:fldChar w:fldCharType="end"/></w:r>'),
    // A picture on its own, with its caption under it.
    _para(_drawing('rIdGreen')),
    _para(_run('Figure 2: Green beds in June'), style: 'Caption'),
    _para(_run('Next Steps'), style: 'Heading2'),
    _para(_run('Order the seed potatoes'), numId: '1'),
    _para(_run('Fix the water butt'), numId: '1'),
    // Word's modern drawing with a VML fallback: one picture, not two.
    _para('<mc:AlternateContent><mc:Choice Requires="wps">${_drawing('rIdBlue', descr: 'A blue water butt')}</mc:Choice>'
        '<mc:Fallback><w:r><w:pict><v:shape><v:imagedata r:id="rIdBlue"/></v:shape></w:pict></w:r></mc:Fallback></mc:AlternateContent>'),
    '<w:tbl><w:tr><w:tc>${_para(_run('Bed'))}</w:tc><w:tc>${_para(_run('Crop'))}</w:tc></w:tr>'
        '<w:tr><w:tc>${_para(_run('One'))}</w:tc><w:tc>${_para(_run('Beans'))}</w:tc></w:tr></w:tbl>',
    _para('${_run('A Word drawing that cannot be posted.')}${_drawing('rIdEmf')}'),
    _para('${_run('The last para')}<w:r><w:tab/></w:r>${_run('graph ends here.')}'),
  ].join();
  return _zip({
    '[Content_Types].xml': _utf8('<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'),
    'word/document.xml': _utf8('<?xml version="1.0" encoding="UTF-8"?><w:document $_w><w:body>$body<w:sectPr/></w:body></w:document>'),
    'word/_rels/document.xml.rels': _utf8('<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rIdRed" Type="image" Target="media/image1.png"/>'
        '<Relationship Id="rIdGreen" Type="image" Target="media/image2.png"/>'
        '<Relationship Id="rIdBlue" Type="image" Target="/word/media/image3.png"/>'
        '<Relationship Id="rIdEmf" Type="image" Target="media/image4.emf"/>'
        '</Relationships>'),
    'word/styles.xml': _utf8('<?xml version="1.0"?><w:styles $_w>'
        '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>'
        '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/></w:style>'
        '<w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/></w:style></w:styles>'),
    'word/numbering.xml': _utf8('<?xml version="1.0"?><w:numbering $_w><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>'
        '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>'),
    'word/media/image1.png': solidPng(_red),
    'word/media/image2.png': solidPng(_green),
    'word/media/image3.png': solidPng(_blue),
    'word/media/image4.emf': [1, 0, 0, 0, 0x6C, 0, 0, 0],
    'docProps/core.xml': _utf8('<?xml version="1.0"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>The Garden Plan</dc:title></cp:coreProperties>'),
  });
}

// ---------------------------------------------------------------------------
// EPUB

Uint8List _epub() {
  String page(String body) => '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>c</title></head><body>$body</body></html>';
  return _zip({
    'mimetype': _utf8('application/epub+zip'),
    'META-INF/container.xml': _utf8('<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'),
    'OEBPS/content.opf': _utf8('<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>River Walks</dc:title></metadata>'
        '<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
        '<item id="c2" href="text/chapter%202.xhtml" media-type="application/xhtml+xml"/>'
        '<item id="c1" href="text/chapter1.xhtml" media-type="application/xhtml+xml"/>'
        '<item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>'
        '<item id="i1" href="images/orange.png" media-type="image/png"/><item id="i2" href="images/blue.png" media-type="image/png"/></manifest>'
        // The spine, not the manifest, gives the order.
        '<spine><itemref idref="c1"/><itemref idref="c2"/><itemref idref="notes" linear="no"/></spine></package>'),
    'OEBPS/nav.xhtml': _utf8(page('<nav><ol><li>Contents</li></ol></nav>')),
    'OEBPS/text/chapter1.xhtml': _utf8(page('<h1>Along the River</h1><p>The path follows the river for <em>three</em> miles.</p>'
        '<p>At the weir the water is loud.<img src="../images/orange.png" alt="An orange buoy"/></p>'
        '<figure><img src="../images/blue.png"/><figcaption>The blue bridge at dusk</figcaption></figure>'
        '<p>Past the bridge the path climbs.</p>')),
    'OEBPS/text/chapter 2.xhtml': _utf8(page('<h2>Practical Notes</h2><ul><li>Bring water</li><li>Wear boots</li></ul>'
        '<p>Maps are at <a href="https://example.org/maps">the visitor centre</a>.</p>'
        '<p><img src="https://example.org/remote.png" alt="never fetched"/></p>')),
    'OEBPS/text/notes.xhtml': _utf8(page('<p>Not in the reading order.</p>')),
    'OEBPS/images/orange.png': solidPng(_orange),
    'OEBPS/images/blue.png': solidPng(_blue),
  });
}

void main() {
  group('DOCX', () {
    test('paragraphs, headings, lists and pictures come out in order, with descriptions', () {
      final d = readDocumentBytes((format: DocumentFormat.docx, bytes: _docx(), folder: null));
      expect(_describe(d), [
        'H1 Garden Plan',
        'P The beds along the south wall get the most sun, so the tomatoes go there.',
        'P The old wall was repointed in May.',
        'IMG red | A red brick wall',
        'P Inserted words stay. Field result.',
        'IMG green | Figure 2: Green beds in June',
        'H2 Next Steps',
        'P 1. Order the seed potatoes',
        'P 2. Fix the water butt',
        'IMG blue | A blue water butt',
        'P Bed | Crop',
        'P One | Beans',
        'P A Word drawing that cannot be posted.',
        'P The last para graph ends here.',
      ]);
      expect(d.title, 'The Garden Plan');
      expect(d.warnings.join(' '), contains('cannot be posted'));
      expect(d.warnings.join(' '), contains('table'));
    });

    test('each picture is once in the part holding its paragraph', () {
      final d = readDocumentBytes((format: DocumentFormat.docx, bytes: _docx(), folder: null));
      final thread = buildDocumentThread(d, partLength: 120);
      expect(thread.imageCount, 3);
      final images = d.images.toList();
      expect(partOfImage(thread, images[0]), partWith(thread, 'The old wall was repointed in May.'));
      expect(partOfImage(thread, images[1]), partWith(thread, 'Inserted words stay.'));
      expect(partOfImage(thread, images[2]), partWith(thread, 'Fix the water butt'));
      // "Next Steps" starts a part.
      expect(thread.parts[partWith(thread, 'Next Steps')].text, startsWith('Next Steps'));
    });

    test('a file that is not a ZIP package is refused clearly', () {
      expect(() => readDocumentBytes((format: DocumentFormat.docx, bytes: Uint8List.fromList(utf8.encode('not a zip')), folder: null)),
          throwsA(isA<DocumentReadException>()));
    });
  });

  group('EPUB', () {
    test('chapters follow the spine; pictures, captions and links are kept; the web is never fetched', () {
      final d = readDocumentBytes((format: DocumentFormat.epub, bytes: _epub(), folder: null));
      expect(_describe(d), [
        'H1 Along the River',
        'P The path follows the river for three miles.',
        'P At the weir the water is loud.',
        'IMG orange | An orange buoy',
        'IMG blue | The blue bridge at dusk',
        'P Past the bridge the path climbs.',
        'H2 Practical Notes',
        'P • Bring water',
        'P • Wear boots',
        'P Maps are at the visitor centre (https://example.org/maps).',
      ]);
      expect(d.title, 'River Walks');
      expect(d.warnings.join(' '), contains('1 picture was left out'));
      final thread = buildDocumentThread(d, partLength: 80);
      final images = d.images.toList();
      expect(partOfImage(thread, images[0]), partWith(thread, 'At the weir the water is loud.'));
      expect(partOfImage(thread, images[1]), partWith(thread, 'At the weir the water is loud.'));
      // The two list items stay together on lines of their own.
      expect(thread.parts.any((p) => p.text.contains('• Bring water\n• Wear boots')), isTrue);
    });
  });

  group('Markdown, HTML and text', () {
    test('Markdown: headings, emphasis, links, lists and a picture next to the file', () {
      final dir = Directory.systemTemp.createTempSync('nf_md');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/pond.png').writeAsBytesSync(solidPng(_green));
      const source = '# Pond Diary\n\nThe frogs came back in **March**, see [the log](https://example.org/log).\n\n'
          '![Frogspawn in the shallows](pond.png)\n\n## Later\n\n- Newts seen\n- Lilies flowering\n';
      final d = readDocumentBytes((format: DocumentFormat.markdown, bytes: Uint8List.fromList(utf8.encode(source)), folder: dir.path));
      expect(_describe(d), [
        'H1 Pond Diary',
        'P The frogs came back in March, see the log (https://example.org/log).',
        'IMG green | Frogspawn in the shallows',
        'H2 Later',
        'P • Newts seen',
        'P • Lilies flowering',
      ]);
      expect(d.title, 'Pond Diary');
    });

    test('HTML: a data: picture is read, scripts and navigation are not', () {
      final png = base64.encode(solidPng(_red));
      final source = '<html><head><title>Page</title><script>alert(1)</script></head><body><nav>Menu</nav>'
          '<h1>Hello</h1><p>First line<br>second line</p><p><img src="data:image/png;base64,$png" alt="Red dot"></p></body></html>';
      final d = readDocumentBytes((format: DocumentFormat.html, bytes: Uint8List.fromList(utf8.encode(source)), folder: null));
      expect(_describe(d), ['H1 Hello', 'P First line\nsecond line', 'IMG red | Red dot']);
      expect(d.title, 'Page');
    });

    test('text: blank lines separate paragraphs; hard-wrapped lines are joined', () {
      const wrapped = 'This paragraph was wrapped by an editor at a fixed width so every line\n'
          'ends near the same column, which is how e-mail and old text files look\n'
          'when they are saved.\n\n'
          'The second paragraph is wrapped the same way, and its lines should also\n'
          'be joined back into one line of text by the reader without any trouble.\n';
      final d = readDocumentBytes((format: DocumentFormat.text, bytes: Uint8List.fromList(utf8.encode(wrapped)), folder: null));
      expect(d.blocks, hasLength(2));
      expect((d.blocks.first as DocumentParagraph).text, startsWith('This paragraph was wrapped by an editor at a fixed width so every line ends'));
      const poem = 'Short line\nAnother line\n\nNew verse';
      final p = readDocumentBytes((format: DocumentFormat.text, bytes: Uint8List.fromList(utf8.encode(poem)), folder: null));
      expect((p.blocks.first as DocumentParagraph).text, 'Short line\nAnother line');
    });
  });

  group('text clean-up', () {
    test('ligatures are spelled out and broken words joined', () {
      expect(normalizeParagraph('The ﬁrst ﬂoor of­fice'), 'The first floor office');
      expect(joinWrappedLines(['an inter-', 'national meeting', 'of Anglo-', 'Saxon scholars']), 'an international meeting of Anglo- Saxon scholars');
    });
  });

  group('thread building', () {
    DocumentImage image(int color, [String? alt]) => DocumentImage(bytes: solidPng(color), mimeType: 'image/png', altText: alt);

    test('headings start parts, paragraphs pack to the length, pictures stay with their paragraph', () {
      final red = image(_red);
      final doc = IngestedDocument(format: DocumentFormat.text, blocks: [
        const DocumentHeading('One'),
        const DocumentParagraph('aaaa aaaa aaaa'),
        const DocumentParagraph('bbbb bbbb bbbb'),
        red,
        const DocumentParagraph('cccc cccc cccc'),
        const DocumentHeading('Two'),
        const DocumentParagraph('dddd'),
      ]);
      // "One" + "aaaa..." is 19 characters; adding "bbbb..." would make 35.
      final t = buildDocumentThread(doc, partLength: 34);
      expect(t.parts.map((p) => p.text), ['One\n\naaaa aaaa aaaa', 'bbbb bbbb bbbb\n\ncccc cccc cccc', 'Two\n\ndddd']);
      expect(t.parts[1].images, [red]);
    });

    test('more than four pictures in a part move on to the next part', () {
      final pictures = [for (var i = 0; i < 6; i++) image(0x101010 * (i + 1), 'Picture ${i + 1}')];
      final doc = IngestedDocument(format: DocumentFormat.text, blocks: [
        const DocumentParagraph('First'),
        ...pictures.take(6),
        const DocumentParagraph('Second, long enough to need a part of its own here'),
      ]);
      final t = buildDocumentThread(doc, partLength: 20);
      expect(t.parts[0].images, pictures.take(4));
      expect(t.parts[1].images, pictures.skip(4));
      expect(t.imageCount, 6);

      // With no part after them, they get a part of their own.
      final tail = buildDocumentThread(IngestedDocument(format: DocumentFormat.text, blocks: [const DocumentParagraph('Only'), ...pictures]));
      expect(tail.parts, hasLength(2));
      expect(tail.parts[1].images, pictures.skip(4));
      expect(tail.parts[1].text, 'Picture 5\nPicture 6');
    });
  });
}
