import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium_bindings;
import 'package:pdfrx/pdfrx.dart';

import 'document_model.dart';
import 'pdf_layout.dart';

/// Reads a PDF with PDFium. Every PDFium call runs on pdfrx's PDFium worker
/// isolate (one page at a time, so [onProgress] can report), and the layout
/// analysis runs on an isolate of its own: nothing heavy runs on the UI
/// isolate.
Future<IngestedDocument> readPdf(Uint8List bytes, {void Function(int done, int total)? onProgress}) async {
  await _initialize();
  final functions = PdfrxEntryFunctions.instance;
  final opened = await functions.compute(_openDocument, bytes);
  if (opened.error != null) throw DocumentReadException(opened.error!);
  final pages = <PdfPageContent>[];
  try {
    for (var i = 0; i < opened.pages; i++) {
      onProgress?.call(i, opened.pages);
      pages.add(await functions.compute(_readPage, (document: opened.document, index: i)));
    }
    onProgress?.call(opened.pages, opened.pages);
  } finally {
    await functions.compute(_closeDocument, (document: opened.document, buffer: opened.buffer));
  }
  // A top-level function, so nothing else of this call is sent along.
  return compute(layoutPdfPages, pages);
}

bool _initialized = false;

Future<void> _initialize() async {
  if (_initialized) return;
  try {
    await pdfrxFlutterInitialize();
  } on Object {
    // Without path_provider (tests, a background isolate): a temporary
    // folder for PDFium's font cache.
    Pdfrx.cacheDirectoryPath ??= Directory.systemTemp.path;
    await PdfrxEntryFunctions.instance.init();
  }
  _initialized = true;
}

// ---------------------------------------------------------------------------
// Everything below runs on the PDFium worker isolate.

pdfium_bindings.PDFium? _pdfiumInstance;
pdfium_bindings.PDFium get _pdfium => _pdfiumInstance ??= pdfium_bindings.getPdfium();

const int _objectPath = 2;
const int _objectImage = 3;
const int _objectShading = 4;
const int _objectForm = 5;

/// PDFium's error for a document that needs a password.
const int _errorPassword = 4;

({int document, int buffer, int pages, String? error}) _openDocument(Uint8List bytes) {
  final pdfium = _pdfium;
  final buffer = malloc<Uint8>(math.max(1, bytes.length));
  buffer.asTypedList(bytes.length).setAll(0, bytes);
  final document = pdfium.FPDF_LoadMemDocument64(buffer.cast(), bytes.length, nullptr);
  if (document == nullptr) {
    final error = pdfium.FPDF_GetLastError();
    malloc.free(buffer);
    return (
      document: 0,
      buffer: 0,
      pages: 0,
      error: error == _errorPassword
          ? 'This PDF is protected by a password. Open it in a PDF reader, save a copy without the password, and try again.'
          : 'This PDF is damaged or is not a PDF file.',
    );
  }
  return (document: document.address, buffer: buffer.address, pages: pdfium.FPDF_GetPageCount(document), error: null);
}

void _closeDocument(({int document, int buffer}) handles) {
  _pdfium.FPDF_CloseDocument(pdfium_bindings.FPDF_DOCUMENT.fromAddress(handles.document));
  malloc.free(Pointer<Uint8>.fromAddress(handles.buffer));
}

PdfPageContent _readPage(({int document, int index}) request) {
  final pdfium = _pdfium;
  final document = pdfium_bindings.FPDF_DOCUMENT.fromAddress(request.document);
  final page = pdfium.FPDF_LoadPage(document, request.index);
  if (page == nullptr) return PdfPageContent(index: request.index, width: 612, height: 792, chars: Float64List(0));
  final arena = Arena();
  try {
    // The page as displayed: turned by /Rotate and cut to its crop box.
    final width = pdfium.FPDF_GetPageWidthF(page);
    final height = pdfium.FPDF_GetPageHeightF(page);
    final space = _displaySpace(pdfium, page, width, height, arena);
    final chars = _characters(pdfium, page, space, arena);
    final objects = _objects(pdfium, page, space, arena);
    final alts = _figureAltTexts(pdfium, page, arena);
    final figures = _cutFigures(pdfium, page, width, height, objects, chars, alts);
    final pageArea = width * height;
    final coverage = objects.images.fold(0.0, (m, o) => math.max(m, o.box.area / pageArea));
    return PdfPageContent(index: request.index, width: width, height: height, chars: chars, figures: figures, imageCoverage: coverage);
  } finally {
    arena.releaseAll();
    pdfium.FPDF_ClosePage(page);
  }
}

/// The map from PDF user space, where PDFium reports character boxes and
/// object bounds, to the page as it is displayed and rendered (origin top
/// left, y down): turned by the page's /Rotate and shifted by its crop box,
/// which `FPDF_GetPageWidthF` and `FPDF_RenderPageBitmap` already apply.
class _DisplaySpace {
  const _DisplaySpace(this.a, this.b, this.c, this.d, this.e, this.f);

  /// No rotation and a crop box at the origin: only y is flipped.
  const _DisplaySpace.flipped(double height) : this(1, 0, 0, -1, 0, height);

  /// x' = a x + c y + e, y' = b x + d y + f.
  final double a, b, c, d, e, f;

  /// The displayed box of the user-space rectangle [left], [bottom],
  /// [right], [top] (exact for quarter turns).
  _Rect box(double left, double bottom, double right, double top) {
    var l = double.infinity, t = double.infinity, r = double.negativeInfinity, bt = double.negativeInfinity;
    for (final (x, y) in [(left, bottom), (right, bottom), (left, top), (right, top)]) {
      final dx = a * x + c * y + e;
      final dy = b * x + d * y + f;
      l = math.min(l, dx);
      r = math.max(r, dx);
      t = math.min(t, dy);
      bt = math.max(bt, dy);
    }
    return _Rect(l, t, r, bt);
  }
}

/// [_DisplaySpace] of [page] from PDFium's own page-to-device map, which
/// FPDF_RenderPageBitmap draws with: three points mapped at 16 device units
/// per point (the map returns whole units) give the affine map.
_DisplaySpace _displaySpace(pdfium_bindings.PDFium pdfium, pdfium_bindings.FPDF_PAGE page, double width, double height, Arena arena) {
  const unitsPerPoint = 16;
  final sizeX = math.max(1, (width * unitsPerPoint).round());
  final sizeY = math.max(1, (height * unitsPerPoint).round());
  final dx = arena<Int>(), dy = arena<Int>();
  (double, double)? map(double x, double y) {
    if (pdfium.FPDF_PageToDevice(page, 0, 0, sizeX, sizeY, 0, x, y, dx, dy) == 0) return null;
    return (dx.value * width / sizeX, dy.value * height / sizeY);
  }

  const span = 1000.0;
  final origin = map(0, 0), alongX = map(span, 0), alongY = map(0, span);
  if (origin == null || alongX == null || alongY == null) return _DisplaySpace.flipped(height);
  return _DisplaySpace(
    (alongX.$1 - origin.$1) / span,
    (alongX.$2 - origin.$2) / span,
    (alongY.$1 - origin.$1) / span,
    (alongY.$2 - origin.$2) / span,
    origin.$1,
    origin.$2,
  );
}

bool _isSpace(int code) => code <= 32 || code == 0xA0 || (code >= 0x2000 && code <= 0x200B) || code == 0x3000 || code == 0xFEFF || code == 0xFFFE;

Float64List _characters(pdfium_bindings.PDFium pdfium, pdfium_bindings.FPDF_PAGE page, _DisplaySpace space, Arena arena) {
  final text = pdfium.FPDFText_LoadPage(page);
  if (text == nullptr) return Float64List(0);
  try {
    final count = pdfium.FPDFText_CountChars(text);
    final out = <double>[];
    final rect = arena<pdfium_bindings.FS_RECTF>();
    final l = arena<Double>(), r = arena<Double>(), b = arena<Double>(), t = arena<Double>();
    var spaceBefore = false;
    for (var i = 0; i < count; i++) {
      var code = pdfium.FPDFText_GetUnicode(text, i);
      // PDFium reports a hyphen at the end of a line as U+0002 (or a soft
      // hyphen); keep it as a hyphen so the broken word can be joined.
      if (code == 0x02 || code == 0xAD || code == 0xFFFE) code = 0x2D;
      if (_isSpace(code)) {
        spaceBefore = true;
        continue;
      }
      double left, top, right, bottom;
      if (pdfium.FPDFText_GetLooseCharBox(text, i, rect) != 0 && rect.ref.right > rect.ref.left && rect.ref.top > rect.ref.bottom) {
        left = rect.ref.left;
        right = rect.ref.right;
        top = rect.ref.top;
        bottom = rect.ref.bottom;
      } else if (pdfium.FPDFText_GetCharBox(text, i, l, r, b, t) != 0) {
        left = l.value;
        right = r.value;
        top = t.value;
        bottom = b.value;
      } else {
        continue;
      }
      var flags = spaceBefore ? kPdfSpaceBefore : 0;
      if (pdfium.FPDFText_HasUnicodeMapError(text, i) == 1) flags |= kPdfUndecodable;
      final box = space.box(left, bottom, right, top);
      out
        ..add(code.toDouble())
        ..add(box.l)
        ..add(box.t)
        ..add(box.r)
        ..add(box.b)
        ..add(pdfium.FPDFText_GetFontSize(text, i))
        ..add(pdfium.FPDFText_GetFontWeight(text, i).toDouble())
        ..add(flags.toDouble());
      spaceBefore = false;
    }
    return Float64List.fromList(out);
  } finally {
    pdfium.FPDFText_ClosePage(text);
  }
}

class _Rect {
  _Rect(this.l, this.t, this.r, this.b);
  double l, t, r, b;
  double get w => r - l;
  double get h => b - t;
  double get area => math.max(0, w) * math.max(0, h);
  bool touches(_Rect o, double margin) => l - margin <= o.r && o.l - margin <= r && t - margin <= o.b && o.t - margin <= b;
  void include(_Rect o) {
    l = math.min(l, o.l);
    t = math.min(t, o.t);
    r = math.max(r, o.r);
    b = math.max(b, o.b);
  }
}

class _PageObject {
  _PageObject(this.box, this.markedContentId);
  final _Rect box;
  final int markedContentId;
}

typedef _Objects = ({List<_PageObject> images, List<_Rect> drawings});

_Objects _objects(pdfium_bindings.PDFium pdfium, pdfium_bindings.FPDF_PAGE page, _DisplaySpace space, Arena arena) {
  final images = <_PageObject>[];
  final drawings = <_Rect>[];
  final l = arena<Float>(), b = arena<Float>(), r = arena<Float>(), t = arena<Float>();
  _Rect? bounds(pdfium_bindings.FPDF_PAGEOBJECT o) {
    if (pdfium.FPDFPageObj_GetBounds(o, l, b, r, t) == 0) return null;
    return space.box(l.value, b.value, r.value, t.value);
  }

  /// Whether a form XObject holds a picture (searched a few levels deep).
  bool holdsImage(pdfium_bindings.FPDF_PAGEOBJECT form, int depth) {
    final n = pdfium.FPDFFormObj_CountObjects(form);
    for (var i = 0; i < n; i++) {
      final child = pdfium.FPDFFormObj_GetObject(form, i);
      final type = pdfium.FPDFPageObj_GetType(child);
      if (type == _objectImage) return true;
      if (type == _objectForm && depth < 4 && holdsImage(child, depth + 1)) return true;
    }
    return false;
  }

  final count = pdfium.FPDFPage_CountObjects(page);
  for (var i = 0; i < count; i++) {
    final o = pdfium.FPDFPage_GetObject(page, i);
    final type = pdfium.FPDFPageObj_GetType(o);
    final box = bounds(o);
    if (box == null) continue;
    switch (type) {
      case _objectImage:
        images.add(_PageObject(box, pdfium.FPDFPageObj_GetMarkedContentID(o)));
      case _objectForm:
        if (holdsImage(o, 0)) {
          images.add(_PageObject(box, pdfium.FPDFPageObj_GetMarkedContentID(o)));
        } else if (pdfium.FPDFFormObj_CountObjects(o) > 0) {
          drawings.add(box);
        }
      case _objectPath || _objectShading:
        drawings.add(box);
    }
  }
  return (images: images, drawings: drawings);
}

/// Alt text of each Figure in the page's structure tree (Tagged PDF), by
/// marked-content id.
Map<int, String> _figureAltTexts(pdfium_bindings.PDFium pdfium, pdfium_bindings.FPDF_PAGE page, Arena arena) {
  final tree = pdfium.FPDF_StructTree_GetForPage(page);
  if (tree == nullptr) return const {};
  final out = <int, String>{};
  String read(int Function(Pointer<Void>, int) call) {
    final size = call(nullptr, 0);
    if (size <= 2) return '';
    final buffer = arena<Uint8>(size);
    call(buffer.cast(), size);
    final units = buffer.cast<Uint16>().asTypedList(size ~/ 2);
    final end = units.indexOf(0);
    return String.fromCharCodes(end < 0 ? units : units.sublist(0, end));
  }

  void visit(pdfium_bindings.FPDF_STRUCTELEMENT e, int depth) {
    if (e == nullptr || depth > 64) return;
    final type = read((buf, len) => pdfium.FPDF_StructElement_GetType(e, buf, len));
    if (type == 'Figure') {
      final alt = read((buf, len) => pdfium.FPDF_StructElement_GetAltText(e, buf, len)).trim();
      if (alt.isNotEmpty) {
        final ids = pdfium.FPDF_StructElement_GetMarkedContentIdCount(e);
        for (var i = 0; i < ids; i++) {
          final id = pdfium.FPDF_StructElement_GetMarkedContentIdAtIndex(e, i);
          if (id >= 0) out[id] = alt;
        }
      }
    }
    final children = pdfium.FPDF_StructElement_CountChildren(e);
    for (var i = 0; i < children; i++) {
      visit(pdfium.FPDF_StructElement_GetChildAtIndex(e, i), depth + 1);
    }
  }

  try {
    final n = pdfium.FPDF_StructTree_CountChildren(tree);
    for (var i = 0; i < n; i++) {
      visit(pdfium.FPDF_StructTree_GetChildAtIndex(tree, i), 0);
    }
  } finally {
    pdfium.FPDF_StructTree_Close(tree);
  }
  return out;
}

/// The page's pictures: photos (image objects, not tiny, not a full-page
/// background) and drawings (clusters of at least three paths covering a
/// real area, such as a chart), merged where they touch, each rendered from
/// the page. A region with much text inside is a box behind text, not a
/// picture.
List<PdfFigure> _cutFigures(
  pdfium_bindings.PDFium pdfium,
  pdfium_bindings.FPDF_PAGE page,
  double width,
  double height,
  _Objects objects,
  Float64List chars,
  Map<int, String> alts,
) {
  final pageArea = width * height;
  final regions = <({_Rect box, bool raster, String? alt})>[];
  for (final o in objects.images) {
    final box = _clip(o.box, width, height);
    if (box.w < 20 || box.h < 20 || box.area < pageArea * 0.004 || box.area > pageArea * 0.9) continue;
    regions.add((box: box, raster: true, alt: alts[o.markedContentId]));
  }
  // Drawings: paths that touch form clusters.
  final clusters = <({_Rect box, int members})>[];
  for (final d in objects.drawings) {
    final box = _clip(d, width, height);
    if (box.area > pageArea * 0.9) continue;
    var merged = (box: _Rect(box.l, box.t, box.r, box.b), members: 1);
    for (var i = clusters.length - 1; i >= 0; i--) {
      if (clusters[i].box.touches(merged.box, 4)) {
        merged.box.include(clusters[i].box);
        merged = (box: merged.box, members: merged.members + clusters[i].members);
        clusters.removeAt(i);
      }
    }
    clusters.add(merged);
  }
  for (final c in clusters) {
    if (c.members < 3 || c.box.w < 60 || c.box.h < 40) continue;
    regions.add((box: c.box, raster: false, alt: null));
  }
  // Merge regions that overlap (a photo inside a drawn frame).
  final merged = <({_Rect box, bool raster, String? alt})>[];
  for (final region in regions) {
    var current = region;
    for (var i = merged.length - 1; i >= 0; i--) {
      if (merged[i].box.touches(current.box, 0)) {
        final other = merged.removeAt(i);
        current.box.include(other.box);
        current = (box: current.box, raster: current.raster || other.raster, alt: current.alt ?? other.alt);
      }
    }
    merged.add(current);
  }
  final out = <PdfFigure>[];
  for (final region in merged) {
    if (_charsInside(chars, region.box) > 150) continue; // a box behind text
    final figure = _render(pdfium, page, width, height, region.box, raster: region.raster, alt: region.alt);
    if (figure != null) out.add(figure);
  }
  out.sort((a, b) => a.top != b.top ? a.top.compareTo(b.top) : a.left.compareTo(b.left));
  return out;
}

_Rect _clip(_Rect r, double width, double height) =>
    _Rect(math.max(0, r.l), math.max(0, r.t), math.min(width, r.r), math.min(height, r.b));

int _charsInside(Float64List chars, _Rect box) {
  var n = 0;
  for (var i = 0; i + kPdfCharStride <= chars.length; i += kPdfCharStride) {
    final cx = (chars[i + 1] + chars[i + 3]) / 2;
    final cy = (chars[i + 2] + chars[i + 4]) / 2;
    if (cx > box.l && cx < box.r && cy > box.t && cy < box.b) n++;
  }
  return n;
}

PdfFigure? _render(
  pdfium_bindings.PDFium pdfium,
  pdfium_bindings.FPDF_PAGE page,
  double pageWidth,
  double pageHeight,
  _Rect box, {
  required bool raster,
  String? alt,
}) {
  // About 144 dpi, at most 2000 pixels on the long side.
  final scale = math.max(0.5, math.min(2.0, 2000 / math.max(box.w, box.h)));
  final w = (box.w * scale).ceil();
  final h = (box.h * scale).ceil();
  if (w <= 0 || h <= 0) return null;
  final buffer = malloc<Uint8>(w * h * 4);
  try {
    final bitmap = pdfium.FPDFBitmap_CreateEx(w, h, pdfium_bindings.FPDFBitmap_BGRA, buffer.cast(), w * 4);
    if (bitmap == nullptr) return null;
    try {
      pdfium.FPDFBitmap_FillRect(bitmap, 0, 0, w, h, 0xFFFFFFFF);
      pdfium.FPDF_RenderPageBitmap(
        bitmap,
        page,
        (-box.l * scale).round(),
        (-box.t * scale).round(),
        (pageWidth * scale).round(),
        (pageHeight * scale).round(),
        0,
        pdfium_bindings.FPDF_ANNOT | pdfium_bindings.FPDF_REVERSE_BYTE_ORDER,
      );
    } finally {
      pdfium.FPDFBitmap_Destroy(bitmap);
    }
    final rgba = Uint8List.fromList(buffer.asTypedList(w * h * 4));
    final image = img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
    final bytes = raster ? img.encodeJpg(image, quality: 90) : img.encodePng(image);
    return PdfFigure(
      left: box.l,
      top: box.t,
      right: box.r,
      bottom: box.b,
      bytes: bytes,
      mimeType: raster ? 'image/jpeg' : 'image/png',
      fingerprint: _fingerprint(rgba, w, h),
      altText: alt,
    );
  } finally {
    malloc.free(buffer);
  }
}

/// FNV-1a over a coarse sample of the pixels and the size, so the same
/// picture repeated on many pages (a logo) is recognised.
int _fingerprint(Uint8List rgba, int w, int h) {
  var hash = 0x811C9DC5;
  void mix(int v) => hash = ((hash ^ (v & 0xFF)) * 0x01000193) & 0xFFFFFFFF;
  mix(w ~/ 4);
  mix(h ~/ 4);
  final step = math.max(1, (w * h) ~/ 4096);
  for (var p = 0; p < w * h; p += step) {
    mix(rgba[p * 4] >> 3);
    mix(rgba[p * 4 + 1] >> 3);
    mix(rgba[p * 4 + 2] >> 3);
  }
  return hash;
}
