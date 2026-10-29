// Writes the PDF fixtures of the document ingest tests from the known content
// in test/documents/fixture_content.dart:
//
//   dart run tool/generate_document_fixtures.dart
//
// The PDFs are written by hand (Helvetica text, flate-compressed RGB pictures
// and a bar chart drawn with paths), so the layout is exactly what the tests
// expect: words wrapped to the column width (long words hyphenated at the end
// of a line), columns, running headers and footers.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../test/documents/fixture_content.dart';

const _out = 'test/fixtures/documents';

void main() {
  Directory(_out).createSync(recursive: true);
  for (final f in pdfFixtures) {
    final bytes = _layout(f);
    File('$_out/${f.file}').writeAsBytesSync(bytes);
    stdout.writeln('${f.file}: ${bytes.length} bytes');
  }
  File('$_out/$scannedFixtureFile').writeAsBytesSync(_scanned());
  stdout.writeln('$scannedFixtureFile written');
}

// ---------------------------------------------------------------------------
// Layout

const double _pageW = 612, _pageH = 792, _margin = 72, _gutter = 24;
const double _bodySize = 11, _leading = 14.3, _paragraphGap = 9;

class _Frame {
  _Frame(this.page, this.x, this.top, this.bottom, this.width);
  final int page;
  final double x, top, bottom, width;
}

Uint8List _layout(FixtureDocument f) {
  final pdf = _PdfWriter();
  final pages = <_Page>[];
  _Page page(int i) {
    while (pages.length <= i) {
      pages.add(_Page());
    }
    return pages[i];
  }

  final bodyTop = f.header == null ? _pageH - _margin : _pageH - _margin - 24;
  final columnW = (_pageW - 2 * _margin - (f.columns - 1) * _gutter) / f.columns;
  var firstTop = bodyTop;
  if (f.title != null) {
    final t = f.title!;
    page(0).text(_margin, bodyTop - t.size, t.size, t.text, bold: true);
    firstTop = bodyTop - t.size - 22;
  }
  // Frames: the columns of each page, as many pages as the text needs.
  final frames = <_Frame>[];
  _Frame frame(int i) {
    while (frames.length <= i) {
      final n = frames.length;
      final p = n ~/ f.columns;
      final c = n % f.columns;
      frames.add(_Frame(p, _margin + c * (columnW + _gutter), p == 0 ? firstTop : bodyTop, _margin + 20, columnW));
    }
    return frames[i];
  }

  var fi = 0;
  var y = frame(0).top;
  void nextFrame() {
    fi++;
    y = frame(fi).top;
  }

  for (final block in f.blocks) {
    switch (block) {
      case FixtureHeading(:final text, :final size):
        if (y - size - 2 * _leading < frame(fi).bottom) nextFrame();
        y -= size;
        page(frame(fi).page).text(frame(fi).x, y, size, text, bold: true);
        y -= _paragraphGap + 4;
      case FixtureParagraph(:final text):
        for (final line in _wrap(text, frame(fi).width, _bodySize)) {
          if (y - _bodySize < frame(fi).bottom) nextFrame();
          y -= _bodySize;
          page(frame(fi).page).text(frame(fi).x, y, _bodySize, line);
          y -= _leading - _bodySize;
        }
        y -= _paragraphGap;
      case FixtureImage():
        final captionLines = block.caption == null ? const <String>[] : _wrap(block.caption!, frame(fi).width, 9);
        final need = block.height + captionLines.length * 12 + 8;
        if (y - need < frame(fi).bottom) nextFrame();
        final x = frame(fi).x;
        final p = page(frame(fi).page);
        if (block.chart) {
          p.chart(x, y - block.height, block.width, block.height);
        } else {
          p.image(pdf, x, y - block.height, block.width, block.height, block.color);
        }
        y -= block.height + 4;
        for (final line in captionLines) {
          y -= 9;
          p.text(x, y, 9, line);
          y -= 3;
        }
        y -= _paragraphGap + 4;
    }
  }
  final count = math.max(f.pages, frames[fi].page + 1);
  for (var i = 0; i < count; i++) {
    final p = page(i);
    if (f.header != null) p.text(_margin, _pageH - _margin + 6, 9, f.header!);
    if (f.logoColor != null) p.image(pdf, _pageW - _margin - 28, _pageH - _margin, 28, 28, f.logoColor!);
    if (f.footer != null) {
      final footer = f.footer!.replaceAll('#', '${i + 1}').replaceAll('%', '$count');
      p.text(_pageW / 2 - _width(footer, 9) / 2, 40, 9, footer);
    }
  }
  return pdf.write(pages);
}

/// Helvetica advance widths (1/1000 em) for ASCII 32 to 126.
const _helvetica = [
  278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, //
  556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
  1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
  667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
  333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
  556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
];

double _width(String s, double size) => s.codeUnits.fold(0.0, (w, c) => w + (c >= 32 && c <= 126 ? _helvetica[c - 32] : 556)) * size / 1000;

/// Greedy line breaking to [width]; a long lower-case word that does not
/// fit is hyphenated when a useful piece fits.
List<String> _wrap(String text, double width, double size) {
  final limit = width * 0.98;
  final lines = <String>[];
  var line = '';
  for (final word in text.split(' ')) {
    final candidate = line.isEmpty ? word : '$line $word';
    if (_width(candidate, size) <= limit) {
      line = candidate;
      continue;
    }
    final letters = RegExp(r'^[a-z]{6,}').firstMatch(word)?.group(0)?.length ?? 0;
    if (letters >= 6 && line.isNotEmpty) {
      // Largest head (at least 3 letters, leaving at least 3) that fits with a hyphen.
      String? rest;
      for (var cut = letters - 3; cut >= 3 && rest == null; cut--) {
        final head = '$line ${word.substring(0, cut)}-';
        if (_width(head, size) <= limit) {
          lines.add(head);
          rest = word.substring(cut);
        }
      }
      if (rest != null) {
        line = rest;
        continue;
      }
    }
    if (line.isNotEmpty) lines.add(line);
    line = word;
  }
  if (line.isNotEmpty) lines.add(line);
  return lines;
}

// ---------------------------------------------------------------------------
// PDF writing

class _Page {
  final StringBuffer content = StringBuffer();
  final Map<String, int> images = {};

  void text(double x, double y, double size, String s, {bool bold = false}) {
    content.writeln('BT /${bold ? 'F2' : 'F1'} ${_n(size)} Tf ${_n(x)} ${_n(y)} Td (${_escape(s)}) Tj ET');
  }

  void image(_PdfWriter pdf, double x, double y, double w, double h, int color) {
    final name = 'Im${images.length + 1}';
    images[name] = pdf.colorImage(color);
    content.writeln('q ${_n(w)} 0 0 ${_n(h)} ${_n(x)} ${_n(y)} cm /$name Do Q');
  }

  /// A bar chart: axes and six bars in two colours.
  void chart(double x, double y, double w, double h) {
    content.writeln('q 0 0 0 RG 1 w ${_n(x)} ${_n(y)} m ${_n(x + w)} ${_n(y)} l S ${_n(x)} ${_n(y)} m ${_n(x)} ${_n(y + h)} l S');
    const heights = [0.35, 0.6, 0.9, 0.75, 0.5, 0.3];
    final bar = w / (heights.length * 2 + 1);
    for (var i = 0; i < heights.length; i++) {
      content.writeln('${i.isEven ? '0.15 0.45 0.75' : '0.9 0.55 0.1'} rg ${_n(x + bar * (1 + 2 * i))} ${_n(y + 1)} ${_n(bar)} ${_n(h * heights[i])} re f');
    }
    content.writeln('Q');
  }
}

String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

String _escape(String s) => s.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');

class _PdfWriter {
  final List<List<int>> _objects = [];

  int add(List<int> body) {
    _objects.add(body);
    return _objects.length;
  }

  int addText(String s) => add(latin1.encode(s));

  int stream(String dict, List<int> data) =>
      add([...latin1.encode('<< $dict /Length ${data.length} >>\nstream\n'), ...data, ...latin1.encode('\nendstream')]);

  final Map<int, int> _colorImages = {};

  /// A 64 x 40 picture of one colour with a darker border, flate-compressed.
  int colorImage(int color) => _colorImages.putIfAbsent(color, () {
        const w = 64, h = 40;
        final r = (color >> 16) & 0xFF, g = (color >> 8) & 0xFF, b = color & 0xFF;
        final pixels = Uint8List(w * h * 3);
        for (var yy = 0; yy < h; yy++) {
          for (var xx = 0; xx < w; xx++) {
            final edge = xx < 2 || yy < 2 || xx >= w - 2 || yy >= h - 2;
            final o = (yy * w + xx) * 3;
            pixels[o] = edge ? r ~/ 2 : r;
            pixels[o + 1] = edge ? g ~/ 2 : g;
            pixels[o + 2] = edge ? b ~/ 2 : b;
          }
        }
        return stream('/Type /XObject /Subtype /Image /Width $w /Height $h /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode',
            zlib.encode(pixels));
      });

  Uint8List write(List<_Page> pages) {
    final font1 = addText('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>');
    final font2 = addText('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>');
    final pagesId = _objects.length + 1 + pages.length * 2;
    final pageIds = <int>[];
    for (final p in pages) {
      final content = stream('', latin1.encode(p.content.toString()));
      final xobjects = p.images.entries.map((e) => '/${e.key} ${e.value} 0 R').join(' ');
      pageIds.add(addText('<< /Type /Page /Parent $pagesId 0 R /MediaBox [0 0 ${_n(_pageW)} ${_n(_pageH)}] /Contents $content 0 R '
          '/Resources << /Font << /F1 $font1 0 R /F2 $font2 0 R >>${xobjects.isEmpty ? '' : ' /XObject << $xobjects >>'} >> >>'));
    }
    final id = addText('<< /Type /Pages /Kids [${pageIds.map((i) => '$i 0 R').join(' ')}] /Count ${pages.length} >>');
    assert(id == pagesId, 'pages object id');
    final catalog = addText('<< /Type /Catalog /Pages $pagesId 0 R >>');
    final out = BytesBuilder()..add(latin1.encode('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n'));
    final offsets = <int>[];
    for (var i = 0; i < _objects.length; i++) {
      offsets.add(out.length);
      out
        ..add(latin1.encode('${i + 1} 0 obj\n'))
        ..add(_objects[i])
        ..add(latin1.encode('\nendobj\n'));
    }
    final xref = out.length;
    out.add(latin1.encode('xref\n0 ${_objects.length + 1}\n0000000000 65535 f \n'));
    for (final o in offsets) {
      out.add(latin1.encode('${o.toString().padLeft(10, '0')} 00000 n \n'));
    }
    out.add(latin1.encode('trailer\n<< /Size ${_objects.length + 1} /Root $catalog 0 R >>\nstartxref\n$xref\n%%EOF\n'));
    return out.toBytes();
  }
}

/// One page covered by a picture and no text: what a scanner makes.
Uint8List _scanned() {
  final pdf = _PdfWriter();
  final page = _Page()..image(pdf, 0, 0, _pageW, _pageH, 0xEEEEEE);
  return pdf.write([page]);
}
