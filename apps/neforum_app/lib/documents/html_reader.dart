import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'document_images.dart';
import 'document_model.dart';
import 'text_normalization.dart';

/// Finds the bytes of a picture an HTML page refers to (`src` of an `img`),
/// or null when it cannot be found or may not be fetched.
typedef HtmlImageLoader = Uint8List? Function(String src);

/// Reads an HTML or XHTML page into [DocumentBlock]s: headings, paragraphs,
/// list items and pictures in document order.
///
/// - A picture inside a paragraph follows that paragraph; a `figure`'s
///   `figcaption` becomes the picture's description when the `img` has no
///   `alt`, and is not repeated as a paragraph.
/// - Links to web pages keep their address after the link text.
/// - Tables become one paragraph per row, cells separated by " | ".
/// - Scripts, styles, navigation (an EPUB's table of contents), forms and
///   embedded players are left out.
///
/// One reader can read several pages in turn (the chapters of a book); the
/// blocks and warnings add up.
class HtmlBlockReader {
  HtmlImageLoader _loadImage = _noImages;

  static Uint8List? _noImages(String src) => null;

  final List<DocumentBlock> _blocks = [];
  final List<String> _warnings = [];
  final StringBuffer _text = StringBuffer();
  final List<DocumentImage> _pendingImages = [];
  bool _listItem = false;
  int _skippedImages = 0;
  int _tables = 0;
  int _media = 0;
  String? _title;

  /// What [read] could not use, for the user.
  List<String> get warnings => [
        ..._warnings,
        if (_skippedImages > 0) '$_skippedImages picture${_skippedImages == 1 ? ' was' : 's were'} left out (missing, on the web, or in a format that cannot be posted)',
        if (_tables > 0) '$_tables table${_tables == 1 ? ' was' : 's were'} turned into plain text',
        if (_media > 0) '$_media video or sound clip${_media == 1 ? ' was' : 's were'} left out',
      ];

  /// The page's `<title>`, once read.
  String? get title => _title;

  /// Every block read so far.
  List<DocumentBlock> get blocks => List.unmodifiable(_blocks);

  /// Reads the page [source], whose pictures [loadImage] finds, after the
  /// pages read before.
  void read(String source, {required HtmlImageLoader loadImage}) {
    _loadImage = loadImage;
    final document = html_parser.parse(source);
    final t = document.querySelector('title')?.text.trim();
    if (t != null && t.isNotEmpty) _title ??= singleLine(t);
    final body = document.body;
    if (body != null) _walk(body);
    _flush();
    _emitPending();
  }

  static const _skipped = {'script', 'style', 'head', 'nav', 'noscript', 'template', 'iframe', 'object', 'embed', 'form', 'button', 'select', 'textarea', 'input', 'canvas'};
  static const _blockLevel = {
    'p', 'div', 'section', 'article', 'main', 'header', 'footer', 'aside', 'blockquote', 'pre', 'address', 'center', 'dl', 'dd', 'dt', //
    'ul', 'ol', 'hr', 'body', 'html',
  };

  void _walk(dom.Node node, {bool pre = false, int? listCounter}) {
    if (node is dom.Text) {
      final data = pre ? node.data : node.data.replaceAll(RegExp(r'\s+'), ' ');
      _text.write(data);
      return;
    }
    if (node is! dom.Element) return;
    final name = node.localName ?? '';
    if (_skipped.contains(name)) return;
    if (name == 'video' || name == 'audio') {
      _media++;
      return;
    }
    switch (name) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        _flush();
        final text = singleLine(node.text);
        if (text.isNotEmpty) _blocks.add(DocumentHeading(text, level: int.parse(name.substring(1))));
        _imagesIn(node, null);
        _emitPending();
        return;
      case 'br':
        _text.write('\n');
        return;
      case 'img':
        _image(node.attributes['src'], node.attributes['alt']);
        return;
      case 'image': // inside an SVG (EPUB covers)
        _image(node.attributes['xlink:href'] ?? node.attributes['href'], null);
        return;
      case 'svg':
        for (final i in node.querySelectorAll('image')) {
          _image(i.attributes['xlink:href'] ?? i.attributes['href'], null);
        }
        return;
      case 'figure':
        _flush();
        final caption = node.querySelector('figcaption');
        final captionText = caption == null ? null : singleLine(caption.text);
        final before = _blocks.length;
        _imagesIn(node, captionText);
        _emitPending();
        if (_blocks.length == before && captionText != null && captionText.isNotEmpty) {
          // A figure without a usable picture: keep its words.
          _blocks.add(DocumentParagraph(captionText));
        }
        // Text in the figure besides the caption (rare) is kept.
        for (final child in node.nodes) {
          if (child is dom.Element && (child.localName == 'figcaption' || child.localName == 'img' || child.localName == 'picture' || child.localName == 'svg')) {
            continue;
          }
          _walk(child, pre: pre);
        }
        _flush();
        return;
      case 'table':
        _flush();
        _tables++;
        for (final row in node.querySelectorAll('tr')) {
          final cells = [
            for (final c in row.children)
              if (c.localName == 'td' || c.localName == 'th') singleLine(c.text),
          ].where((c) => c.isNotEmpty).toList();
          if (cells.isNotEmpty) _blocks.add(DocumentParagraph(cells.join(' | ')));
          _imagesIn(row, null);
          _emitPending();
        }
        return;
      case 'li':
        _flush();
        final marker = listCounter == null ? '•' : '$listCounter.';
        _text.write('$marker ');
        _listItem = true;
        for (final child in node.nodes) {
          if (child is dom.Element && (child.localName == 'ul' || child.localName == 'ol')) {
            _flush();
            _walk(child, pre: pre);
          } else {
            _walk(child, pre: pre);
          }
        }
        _flush();
        return;
      case 'ol':
        _flush();
        var n = int.tryParse(node.attributes['start'] ?? '') ?? 1;
        for (final child in node.nodes) {
          if (child is dom.Element && child.localName == 'li') {
            _walk(child, pre: pre, listCounter: n++);
          } else {
            _walk(child, pre: pre);
          }
        }
        _flush();
        return;
      case 'a':
        final before = _text.length;
        for (final child in node.nodes) {
          _walk(child, pre: pre);
        }
        final href = node.attributes['href']?.trim() ?? '';
        final shown = _text.toString().substring(before).trim();
        if ((href.startsWith('http://') || href.startsWith('https://')) && shown.isNotEmpty && !shown.contains(href) && !href.contains(shown)) {
          _text.write(' ($href)');
        }
        return;
    }
    final block = _blockLevel.contains(name);
    if (block) _flush();
    for (final child in node.nodes) {
      _walk(child, pre: pre || name == 'pre');
    }
    if (block) _flush();
  }

  /// Every picture inside [node], described by [caption] when it has no alt
  /// text of its own.
  void _imagesIn(dom.Element node, String? caption) {
    for (final e in node.querySelectorAll('img, image')) {
      if (e.localName == 'img') {
        final alt = e.attributes['alt'];
        _image(e.attributes['src'], (alt == null || alt.trim().isEmpty) ? caption : alt);
      } else {
        _image(e.attributes['xlink:href'] ?? e.attributes['href'], caption);
      }
    }
  }

  void _image(String? src, String? alt) {
    final s = src?.trim() ?? '';
    if (s.isEmpty) return;
    Uint8List? bytes;
    String? name;
    if (s.startsWith('data:')) {
      bytes = _dataUri(s);
    } else {
      try {
        bytes = _loadImage(s);
      } on Object {
        bytes = null;
      }
      name = Uri.tryParse(s)?.pathSegments.lastOrNull;
    }
    final postable = bytes == null ? null : postableImage(bytes);
    if (postable == null) {
      _skippedImages++;
      return;
    }
    final description = alt == null ? null : singleLine(alt);
    final image = DocumentImage(
      bytes: postable.bytes,
      mimeType: postable.mimeType,
      altText: description == null || description.isEmpty ? null : description,
      name: name,
    );
    if (_text.toString().trim().isEmpty) {
      _blocks.add(image);
    } else {
      // Inside a paragraph: it follows the paragraph.
      _pendingImages.add(image);
    }
  }

  static Uint8List? _dataUri(String uri) {
    try {
      return UriData.parse(uri).contentAsBytes();
    } on FormatException {
      final comma = uri.indexOf(',');
      if (comma < 0 || !uri.substring(0, comma).endsWith(';base64')) return null;
      try {
        return base64.decode(uri.substring(comma + 1).replaceAll(RegExp(r'\s'), ''));
      } on FormatException {
        return null;
      }
    }
  }

  /// Ends the paragraph being collected, if it has words.
  void _flush() {
    final text = normalizeParagraph(_text.toString());
    _text.clear();
    // A list item holding only a nested list leaves just its marker.
    if (text.isNotEmpty && !(_listItem && RegExp(r'^(•|\d+\.)$').hasMatch(text))) {
      _blocks.add(DocumentParagraph(text, listItem: _listItem));
    }
    _listItem = false;
    _emitPending();
  }

  void _emitPending() {
    if (_pendingImages.isEmpty) return;
    _blocks.addAll(_pendingImages);
    _pendingImages.clear();
  }
}
