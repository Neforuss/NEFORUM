import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'document_model.dart';
import 'text_normalization.dart';

/// Values per character in [PdfPageContent.chars]: code point, left, top,
/// right, bottom (points, from the top-left corner of the page), font size,
/// font weight (-1 unknown) and flags ([kPdfSpaceBefore],
/// [kPdfUndecodable]).
const int kPdfCharStride = 8;

/// Flag: white space came before this character in the page's text.
const int kPdfSpaceBefore = 1;

/// Flag: the font has no Unicode mapping for this character.
const int kPdfUndecodable = 2;

/// One PDF page as PDFium reported it: its characters with their boxes, and
/// the pictures cut out of it.
@immutable
class PdfPageContent {
  const PdfPageContent({
    required this.index,
    required this.width,
    required this.height,
    required this.chars,
    this.figures = const [],
    this.imageCoverage = 0,
  });

  /// From 0.
  final int index;
  final double width;
  final double height;

  /// [kPdfCharStride] values per visible character, in content order.
  final Float64List chars;
  final List<PdfFigure> figures;

  /// Share of the page covered by its largest picture (a scanned page is
  /// one picture covering it all).
  final double imageCoverage;

  int get charCount => chars.length ~/ kPdfCharStride;
}

/// A picture on a PDF page: a photo (image object) or a drawing (vector
/// paths such as a chart), rendered from the page.
@immutable
class PdfFigure {
  const PdfFigure({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.bytes,
    required this.mimeType,
    required this.fingerprint,
    this.altText,
  });

  /// Points from the top-left corner of the page.
  final double left, top, right, bottom;
  final Uint8List bytes;
  final String mimeType;

  /// Same picture, same fingerprint: a logo repeated on every page.
  final int fingerprint;

  /// From the Tagged PDF structure (the Figure's /Alt), when there is one.
  final String? altText;

  double get width => right - left;
  double get height => bottom - top;
}

/// Turns the pages of a PDF into a document: lines from characters, blocks
/// from lines, columns and reading order by recursive XY-cut, running
/// headers, footers and page numbers dropped, words broken at line ends put
/// back together, captions made into picture descriptions, and each picture
/// placed after the block it belongs with.
IngestedDocument layoutPdfPages(List<PdfPageContent> pages) => _PdfLayout(pages).run();

// ---------------------------------------------------------------------------

class _Char {
  _Char(this.code, this.l, this.t, this.r, this.b, this.size, this.weight, this.flags, this.seq);
  final int code;
  final double l, t, r, b, size, weight;
  final int flags;
  final int seq;
  double get cy => (t + b) / 2;
  double get h => b - t;
  bool get spaceBefore => flags & kPdfSpaceBefore != 0;
}

class _Box {
  _Box(this.l, this.t, this.r, this.b);
  double l, t, r, b;
  double get w => r - l;
  double get h => b - t;
  double get area => math.max(0, w) * math.max(0, h);
  double overlapX(_Box o) => math.min(r, o.r) - math.max(l, o.l);
  double overlapY(_Box o) => math.min(b, o.b) - math.max(t, o.t);
  void include(_Box o) {
    l = math.min(l, o.l);
    t = math.min(t, o.t);
    r = math.max(r, o.r);
    b = math.max(b, o.b);
  }
}

class _Line extends _Box {
  _Line(super.l, super.t, super.r, super.b, this.text, this.size, this.bold, this.page);
  final String text;
  final double size;
  final bool bold;
  final int page;
}

class _Block extends _Box {
  _Block(_Line first, this.page)
      : lines = [first],
        size = first.size,
        super(first.l, first.t, first.r, first.b);
  final List<_Line> lines;
  final int page;
  double size;
  bool heading = false;
  int level = 1;
  String? _text;

  String get text => _text ??= normalizeParagraph(joinWrappedLines(lines.map((l) => l.text)));
  set text(String v) => _text = v;
  bool get bold => lines.every((l) => l.bold);
  int get words => text.split(' ').where((w) => w.isNotEmpty).length;

  void add(_Line line) {
    lines.add(line);
    include(line);
    _text = null;
  }
}

class _Figure extends _Box {
  _Figure(this.figure, this.page) : alt = figure.altText, super(figure.left, figure.top, figure.right, figure.bottom);
  final PdfFigure figure;
  final int page;
  String? alt;
  String? number;
}

class _PdfLayout {
  _PdfLayout(this.pages);
  final List<PdfPageContent> pages;
  final List<String> warnings = [];

  IngestedDocument run() {
    final pageLines = [for (final p in pages) _lines(p)];
    _dropRunningLines(pageLines);
    final figures = _figures();
    final bodySize = _bodySize(pageLines);

    final ordered = <Object>[]; // _Block or _Figure in reading order
    for (var i = 0; i < pages.length; i++) {
      final blocks = _blocks(pageLines[i]);
      final pageFigures = figures[i];
      _takeCaptions(blocks, pageFigures);
      ordered.addAll(_readingOrder([...blocks, ...pageFigures]));
    }
    final blocks = ordered.whereType<_Block>().toList();
    _markHeadings(blocks, bodySize);
    final merged = _mergeContinuations(ordered);
    _scanWarnings();
    return IngestedDocument(format: DocumentFormat.pdf, blocks: _anchor(merged), warnings: warnings, pageCount: pages.length);
  }

  // ---- characters to lines ---------------------------------------------

  List<_Line> _lines(PdfPageContent page) {
    final c = page.chars;
    final chars = <_Char>[];
    final figureBoxes = [for (final f in page.figures) _Box(f.left - 1, f.top - 1, f.right + 1, f.bottom + 1)];
    for (var i = 0; i + kPdfCharStride <= c.length; i += kPdfCharStride) {
      final ch = _Char(c[i].toInt(), c[i + 1], c[i + 2], c[i + 3], c[i + 4], c[i + 5], c[i + 6], c[i + 7].toInt(), i ~/ kPdfCharStride);
      if (ch.r <= ch.l || ch.b <= ch.t) continue;
      final cx = (ch.l + ch.r) / 2;
      // Labels inside a chart or words in a photo belong to the picture.
      if (figureBoxes.any((f) => cx > f.l && cx < f.r && ch.cy > f.t && ch.cy < f.b)) continue;
      chars.add(ch);
    }
    if (chars.isEmpty) return [];
    chars.sort((a, b) => a.cy.compareTo(b.cy));

    // Rows: characters whose vertical centres line up.
    final rows = <List<_Char>>[];
    var rowCy = 0.0;
    var rowH = 0.0;
    for (final ch in chars) {
      if (rows.isNotEmpty && (ch.cy - rowCy).abs() <= 0.4 * math.min(rowH, ch.h)) {
        final row = rows.last..add(ch);
        rowCy += (ch.cy - rowCy) / row.length;
        rowH = math.max(rowH, ch.h);
      } else {
        rows.add([ch]);
        rowCy = ch.cy;
        rowH = ch.h;
      }
    }

    // Each row splits into lines at gaps wider than a column gutter.
    final lines = <_Line>[];
    for (final row in rows) {
      row.sort((a, b) => a.l.compareTo(b.l));
      var start = 0;
      for (var i = 1; i <= row.length; i++) {
        final end = i == row.length;
        if (!end) {
          final a = row[i - 1], b = row[i];
          final em = math.max(a.size, b.size);
          final gap = b.l - a.r;
          final sameRun = (b.seq - a.seq).abs() <= 2;
          if (!(gap > 1.2 * em && !(sameRun && gap < 2.5 * em))) continue;
        }
        lines.add(_makeLine(row.sublist(start, i), page.index));
        start = i;
      }
    }
    return lines;
  }

  static _Line _makeLine(List<_Char> chars, int page) {
    final text = StringBuffer();
    var l = double.infinity, t = double.infinity, r = -double.infinity, b = -double.infinity;
    final sizes = <double>[];
    var boldCount = 0;
    for (var i = 0; i < chars.length; i++) {
      final ch = chars[i];
      if (i > 0) {
        final prev = chars[i - 1];
        final gap = ch.l - prev.r;
        final adjacent = ch.seq == prev.seq + 1;
        if ((ch.spaceBefore && (adjacent || gap > 0.05 * ch.size)) || gap > 0.18 * math.max(ch.size, prev.size)) text.write(' ');
      }
      text.writeCharCode(ch.code);
      l = math.min(l, ch.l);
      t = math.min(t, ch.t);
      r = math.max(r, ch.r);
      b = math.max(b, ch.b);
      sizes.add(ch.size);
      if (ch.weight >= 600) boldCount++;
    }
    sizes.sort();
    return _Line(l, t, r, b, text.toString(), sizes[sizes.length ~/ 2], boldCount > chars.length * 0.8, page);
  }

  // ---- running headers, footers and page numbers -----------------------

  /// "12", "- 12 -", "Page 3", "3 of 10", "3/10", "xiv".
  static final RegExp _pageNumber = RegExp(
    r'^[\s\-–—]*(page\s*)?(\d+|(?=[ivxlc]+$|[ivxlc]+\s)x{0,3}(ix|iv|v?i{0,3}))(\s*(of|/)\s*\d+)?[\s\-–—]*$',
    caseSensitive: false,
  );

  void _dropRunningLines(List<List<_Line>> pageLines) {
    if (pages.isEmpty) return;
    String key(_Line l) => l.text.toLowerCase().replaceAll(RegExp(r'\d+'), '#').replaceAll(RegExp(r'\s+'), '');
    bool inTop(_Line l) => l.b <= pages[l.page].height * 0.1;
    bool inBottom(_Line l) => l.t >= pages[l.page].height * 0.9;
    final seen = <String, Set<int>>{};
    for (final lines in pageLines) {
      for (final l in lines) {
        if (!inTop(l) && !inBottom(l)) continue;
        seen.putIfAbsent('${inTop(l) ? 'top' : 'bottom'}|${key(l)}', () => {}).add(l.page);
      }
    }
    // Repeated on 40% of the pages, or on three (a chapter's running head).
    final needed = math.max(2, math.min(3, (pages.length * 0.4).ceil()));
    var dropped = 0;
    for (final lines in pageLines) {
      lines.removeWhere((l) {
        if (!inTop(l) && !inBottom(l)) return false;
        final repeated = pages.length >= 2 && (seen['${inTop(l) ? 'top' : 'bottom'}|${key(l)}']?.length ?? 0) >= needed;
        final drop = repeated || _pageNumber.hasMatch(l.text);
        if (drop) dropped++;
        return drop;
      });
    }
    if (dropped > 0) debugPrint('PDF: $dropped running header, footer or page number line(s) left out');
  }

  // ---- pictures ----------------------------------------------------------

  /// The pictures of each page, without decorations repeated on most pages.
  List<List<_Figure>> _figures() {
    final counts = <int, Set<int>>{};
    for (final p in pages) {
      for (final f in p.figures) {
        counts.putIfAbsent(f.fingerprint, () => {}).add(p.index);
      }
    }
    final needed = math.max(2, (pages.length * 0.5).ceil());
    var decorations = 0;
    final out = <List<_Figure>>[];
    for (final p in pages) {
      final kept = <_Figure>[];
      for (final f in p.figures) {
        // A decoration: the same picture on most pages, small or near the
        // top or bottom edge (a logo, a rule), not a photo shown twice.
        final small = f.width * f.height < p.width * p.height * 0.1;
        final atEdge = f.bottom <= p.height * 0.15 || f.top >= p.height * 0.85;
        if (pages.length >= 2 && counts[f.fingerprint]!.length >= needed && (small || atEdge)) {
          decorations++;
          continue;
        }
        kept.add(_Figure(f, p.index));
      }
      out.add(kept);
    }
    if (decorations > 0) debugPrint('PDF: $decorations repeated decoration(s) left out');
    return out;
  }

  static final RegExp _caption = RegExp(r'^(figure|fig\.?|image|photo|picture|chart|diagram|illustration|plate|exhibit|graph)\s*(\d+[a-z]?|[ivx]+)\b[\s.:\-–—]*', caseSensitive: false);

  /// A caption next to a picture describes it (when the PDF has no /Alt)
  /// and gives it its number; the caption is not repeated as a paragraph.
  void _takeCaptions(List<_Block> blocks, List<_Figure> figures) {
    for (final f in figures) {
      _Block? best;
      var bestDistance = double.infinity;
      for (final b in blocks) {
        final m = _caption.firstMatch(b.text);
        if (m == null || b.words > 80) continue;
        if (b.overlapX(f) < 0.3 * math.min(b.w, f.w)) continue;
        final below = b.t - f.b;
        final above = f.t - b.b;
        final distance = below >= -2 ? below : (above >= -2 ? above : double.infinity);
        if (distance > 3 * b.size || distance >= bestDistance) continue;
        best = b;
        bestDistance = distance;
      }
      if (best == null) continue;
      final m = _caption.firstMatch(best.text)!;
      f.number = m[2]!.toLowerCase();
      final caption = best.text;
      if ((f.alt ?? '').trim().isEmpty) f.alt = caption;
      blocks.remove(best);
    }
  }

  // ---- lines to blocks -----------------------------------------------------

  List<_Block> _blocks(List<_Line> lines) {
    if (lines.isEmpty) return [];
    final sorted = [...lines]..sort((a, b) => a.t != b.t ? a.t.compareTo(b.t) : a.l.compareTo(b.l));
    final typicalGap = _typicalLineGap(sorted);
    final blocks = <_Block>[];
    for (final line in sorted) {
      _Block? best;
      var bestGap = double.infinity;
      for (final block in blocks) {
        final last = block.lines.last;
        final gap = line.t - last.b;
        final limit = math.max(0.45 * line.size, typicalGap + 0.35 * line.size);
        if (gap < -0.5 * line.h || gap > limit) continue;
        if (line.overlapX(block) < 0.3 * math.min(line.w, block.w)) continue;
        if ((line.size - block.size).abs() > 0.15 * block.size) continue;
        if (line.bold != last.bold && (line.size - block.size).abs() > 0.05 * block.size) continue;
        if (gap < bestGap) {
          best = block;
          bestGap = gap;
        }
      }
      if (best != null && !_startsParagraph(line, best)) {
        best.add(line);
      } else {
        blocks.add(_Block(line, line.page));
      }
    }
    return blocks;
  }

  /// A new paragraph begins at [line] although it sits right under [block]:
  /// its first line is indented, or the line before ended the paragraph
  /// short of the right edge with a full stop.
  static bool _startsParagraph(_Line line, _Block block) {
    final last = block.lines.last;
    final em = block.size;
    final lastFull = last.r >= block.r - 2 * em;
    if (line.l - block.l > 0.9 * em && lastFull && block.lines.length >= 2) return true;
    final shortLast = last.r < block.r - 0.25 * block.w;
    if (shortLast && RegExp(r'[.!?:"”’)]$').hasMatch(last.text.trimRight()) && block.lines.length >= 2) return true;
    // A heading line (bold or larger) never continues into body text.
    if (last.bold != line.bold) return true;
    return false;
  }

  /// The most common space between a line and the line under it.
  static double _typicalLineGap(List<_Line> sorted) {
    final bins = <int, int>{};
    for (var i = 0; i < sorted.length; i++) {
      final a = sorted[i];
      for (var j = i + 1; j < sorted.length; j++) {
        final b = sorted[j];
        final gap = b.t - a.b;
        if (gap > 2 * a.size) break;
        if (gap < -0.2 * a.size || a.overlapX(b) < 0.3 * math.min(a.w, b.w)) continue;
        final bin = (gap * 2).round();
        bins[bin] = (bins[bin] ?? 0) + 1;
        break;
      }
    }
    if (bins.isEmpty) return 0;
    final mode = bins.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    return mode / 2;
  }

  // ---- headings ------------------------------------------------------------

  static double _bodySize(List<List<_Line>> pageLines) {
    final weight = <int, int>{};
    for (final lines in pageLines) {
      for (final l in lines) {
        final key = (l.size * 2).round();
        weight[key] = (weight[key] ?? 0) + l.text.length;
      }
    }
    if (weight.isEmpty) return 10;
    return weight.entries.reduce((a, b) => b.value > a.value ? b : a).key / 2;
  }

  static void _markHeadings(List<_Block> blocks, double bodySize) {
    final sizes = <int>{};
    for (final b in blocks) {
      if (b.words == 0 || b.words > 20 || b.lines.length > 3) continue;
      final larger = b.size >= bodySize * 1.15;
      final boldLine = b.bold && b.lines.length == 1 && b.size >= bodySize * 0.95 && !b.text.endsWith('.');
      if (larger || boldLine) {
        b.heading = true;
        if (larger) sizes.add((b.size * 2).round());
      }
    }
    final ranked = sizes.toList()..sort((a, b) => b.compareTo(a));
    for (final b in blocks.where((b) => b.heading)) {
      final rank = ranked.indexOf((b.size * 2).round());
      b.level = math.min(6, rank < 0 ? ranked.length + 1 : rank + 1);
    }
  }

  // ---- reading order -------------------------------------------------------

  /// Recursive XY-cut: split at the widest gap between columns when there
  /// is one, else at the widest gap between rows; read left before right
  /// and top before bottom.
  static List<_Box> _readingOrder(List<_Box> items) {
    if (items.length <= 1) return items;
    final xCut = _widestGap(items, vertical: true);
    if (xCut != null && xCut.width >= 6) {
      final left = items.where((i) => (i.l + i.r) / 2 < xCut.at).toList();
      final right = items.where((i) => (i.l + i.r) / 2 >= xCut.at).toList();
      if (left.isNotEmpty && right.isNotEmpty) return [..._readingOrder(left), ..._readingOrder(right)];
    }
    final yCut = _widestGap(items, vertical: false);
    if (yCut != null) {
      final top = items.where((i) => (i.t + i.b) / 2 < yCut.at).toList();
      final bottom = items.where((i) => (i.t + i.b) / 2 >= yCut.at).toList();
      if (top.isNotEmpty && bottom.isNotEmpty) return [..._readingOrder(top), ..._readingOrder(bottom)];
    }
    return [...items]..sort((a, b) => (a.t - b.t).abs() > 2 ? a.t.compareTo(b.t) : a.l.compareTo(b.l));
  }

  /// The widest empty band across all [items] (a gap in their projection on
  /// the x axis when [vertical], else on the y axis).
  static ({double at, double width})? _widestGap(List<_Box> items, {required bool vertical}) {
    final spans = [for (final i in items) vertical ? (i.l, i.r) : (i.t, i.b)]..sort((a, b) => a.$1.compareTo(b.$1));
    ({double at, double width})? best;
    var reach = spans.first.$2;
    for (final s in spans.skip(1)) {
      if (s.$1 > reach) {
        final width = s.$1 - reach;
        if (best == null || width > best.width) best = (at: (reach + s.$1) / 2, width: width);
      }
      reach = math.max(reach, s.$2);
    }
    return best;
  }

  // ---- paragraphs across columns and pages -------------------------------

  /// A paragraph that runs on into the next column or page (no full stop at
  /// the end, a lower-case word at the start) becomes one block again.
  static List<Object> _mergeContinuations(List<Object> ordered) {
    final out = <Object>[];
    _Block? lastText;
    for (final item in ordered) {
      if (item is _Block && !item.heading && lastText != null && !lastText.heading) {
        final newColumn = item.page != lastText.page || item.t < lastText.t;
        final open = !RegExp(r'[.!?:;"”’)\]]$').hasMatch(lastText.text);
        if (newColumn && open && RegExp(r'^\p{Ll}', unicode: true).hasMatch(item.text)) {
          lastText.text = normalizeParagraph(joinWrappedLines([lastText.text, item.text]));
          continue;
        }
      }
      out.add(item);
      if (item is _Block) lastText = item;
    }
    return out;
  }

  // ---- scanned pages -------------------------------------------------------

  void _scanWarnings() {
    final scanned = [
      for (final p in pages)
        if (p.charCount < 10 && p.imageCoverage >= 0.5) p.index + 1,
    ];
    final empty = pages.every((p) => p.charCount < 10);
    if (scanned.isNotEmpty && scanned.length == pages.length) {
      warnings.add('This PDF has no text layer: its pages are scanned pictures. NEFORUM cannot read words from pictures (there is no text recognition), '
          'so there is nothing to make a thread from.');
    } else if (scanned.isNotEmpty) {
      warnings.add('${scanned.length == 1 ? 'Page ${scanned.single} is a scanned picture' : 'Pages ${scanned.join(', ')} are scanned pictures'} '
          'without a text layer; ${scanned.length == 1 ? 'its' : 'their'} words are left out.');
    } else if (empty) {
      warnings.add('This PDF has no text to read.');
    }
    var undecodable = 0;
    var total = 0;
    for (final p in pages) {
      for (var i = 7; i < p.chars.length; i += kPdfCharStride) {
        total++;
        if (p.chars[i].toInt() & kPdfUndecodable != 0) undecodable++;
      }
    }
    if (total > 0 && undecodable > total * 0.2) {
      warnings.add('Some of the text uses fonts without a character map, so parts of it may read as nonsense; check the parts before posting.');
    }
  }

  // ---- placing pictures --------------------------------------------------

  /// Text blocks in reading order, each followed by the pictures anchored to
  /// it: the paragraph that mentions the picture's number ("Figure 2") wins,
  /// else the block before the picture in reading order, else the one after.
  List<DocumentBlock> _anchor(List<Object> ordered) {
    final texts = ordered.whereType<_Block>().toList();
    final anchored = <_Block, List<_Figure>>{};
    final loose = <_Figure>[];
    for (var i = 0; i < ordered.length; i++) {
      final f = ordered[i];
      if (f is! _Figure) continue;
      _Block? anchor;
      final number = f.number;
      if (number != null) {
        final mention = RegExp('\\b(figure|fig\\.?|image|photo|picture|chart|diagram|illustration|plate|exhibit|graph)\\s*${RegExp.escape(number)}\\b', caseSensitive: false);
        anchor = texts.where((t) => !t.heading && mention.hasMatch(t.text)).firstOrNull;
      }
      if (anchor == null) {
        for (var j = i - 1; j >= 0 && anchor == null; j--) {
          if (ordered[j] case final _Block b) anchor = b;
        }
        for (var j = i + 1; j < ordered.length && anchor == null; j++) {
          if (ordered[j] case final _Block b) anchor = b;
        }
      }
      if (anchor == null) {
        loose.add(f);
      } else {
        anchored.putIfAbsent(anchor, () => []).add(f);
      }
    }
    final out = <DocumentBlock>[for (final f in loose) _image(f)];
    for (final t in texts) {
      final text = t.text;
      // Nothing but numbers: the page column of a table of contents.
      final numbersOnly = RegExp(r'^[\d\s.,]+$').hasMatch(text);
      if (text.isEmpty || (numbersOnly && (anchored[t]?.isEmpty ?? true))) continue;
      out.add(t.heading ? DocumentHeading(singleLine(text), level: t.level) : DocumentParagraph(text));
      for (final f in anchored[t] ?? const <_Figure>[]) {
        out.add(_image(f));
      }
    }
    return out;
  }

  static DocumentImage _image(_Figure f) {
    final alt = f.alt == null ? null : singleLine(f.alt!);
    return DocumentImage(bytes: f.figure.bytes, mimeType: f.figure.mimeType, altText: alt == null || alt.isEmpty ? null : alt, name: 'Page ${f.page + 1} picture');
  }
}
