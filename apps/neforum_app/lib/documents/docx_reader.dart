import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'document_images.dart';
import 'document_model.dart';
import 'text_normalization.dart';

/// Reads a Word document (.docx): the paragraphs, headings and list items
/// of `word/document.xml` in order, with each picture (`w:drawing` →
/// `a:blip r:embed`, or an older VML `v:imagedata r:id`) looked up in
/// `word/_rels/document.xml.rels` and read from `word/media`. A picture's
/// description is its `wp:docPr descr`, else the caption next to it.
IngestedDocument readDocx(Uint8List bytes) => _DocxReader(bytes).read();

class _DocxReader {
  _DocxReader(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on Object {
      throw const DocumentReadException('This Word file is damaged: it is not a ZIP package.');
    }
    for (final f in archive.files) {
      if (f.isFile) _files[f.name] = f;
    }
  }

  final Map<String, ArchiveFile> _files = {};
  final Map<String, String> _relationships = {};
  final Map<String, _Style> _styles = {};
  final Map<String, Map<int, String>> _numberFormats = {};
  final Map<String, int> _counters = {};
  final List<DocumentBlock> _blocks = [];

  /// Indexes in [_blocks] of caption paragraphs.
  final Set<int> _captions = {};
  int _skippedImages = 0;
  int _externalImages = 0;
  int _tables = 0;

  Uint8List? _file(String name) => _files[name]?.content;

  XmlDocument? _xml(String name) {
    final data = _file(name);
    if (data == null) return null;
    try {
      return XmlDocument.parse(utf8.decode(data, allowMalformed: true));
    } on XmlException {
      return null;
    }
  }

  IngestedDocument read() {
    final document = _xml('word/document.xml');
    if (document == null) throw const DocumentReadException('This Word file has no readable word/document.xml.');
    _readRelationships();
    _readStyles();
    _readNumbering();
    final body = document.descendants.whereType<XmlElement>().firstWhere((e) => e.name.local == 'body', orElse: () => document.rootElement);
    _container(body);
    final blocks = _attachCaptions();
    final title = _xml('docProps/core.xml')
        ?.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'title')
        .map((e) => singleLine(e.innerText))
        .where((t) => t.isNotEmpty)
        .firstOrNull;
    return IngestedDocument(
      format: DocumentFormat.docx,
      blocks: blocks,
      title: title,
      warnings: [
        if (_skippedImages > 0)
          '$_skippedImages picture${_skippedImages == 1 ? ' is' : 's are'} in a format that cannot be posted (such as a Word drawing) and ${_skippedImages == 1 ? 'was' : 'were'} left out',
        if (_externalImages > 0) '$_externalImages linked picture${_externalImages == 1 ? ' was' : 's were'} left out: they are not inside the file',
        if (_tables > 0) '$_tables table${_tables == 1 ? ' was' : 's were'} turned into plain text',
      ],
    );
  }

  void _readRelationships() {
    final rels = _xml('word/_rels/document.xml.rels');
    if (rels == null) return;
    for (final r in rels.descendants.whereType<XmlElement>().where((e) => e.name.local == 'Relationship')) {
      final id = r.getAttribute('Id');
      final target = r.getAttribute('Target');
      if (id == null || target == null) continue;
      if (r.getAttribute('TargetMode') == 'External') {
        _relationships[id] = '';
        continue;
      }
      _relationships[id] = target.startsWith('/') ? target.substring(1) : p.posix.normalize(p.posix.join('word', target));
    }
  }

  void _readStyles() {
    final styles = _xml('word/styles.xml');
    if (styles == null) return;
    for (final s in styles.descendants.whereType<XmlElement>().where((e) => e.name.local == 'style')) {
      final id = _attr(s, 'styleId');
      if (id == null) continue;
      final name = _child(s, 'name')?.let((n) => _attr(n, 'val')) ?? '';
      final outline = _child(s, 'pPr')?.let((pPr) => _child(pPr, 'outlineLvl'))?.let((o) => int.tryParse(_attr(o, 'val') ?? ''));
      final basedOn = _child(s, 'basedOn')?.let((b) => _attr(b, 'val'));
      _styles[id] = _Style(name.toLowerCase(), outline, basedOn);
    }
  }

  void _readNumbering() {
    final numbering = _xml('word/numbering.xml');
    if (numbering == null) return;
    final abstract = <String, Map<int, String>>{};
    for (final a in numbering.descendants.whereType<XmlElement>().where((e) => e.name.local == 'abstractNum')) {
      final id = _attr(a, 'abstractNumId');
      if (id == null) continue;
      abstract[id] = {
        for (final lvl in a.childElements.where((e) => e.name.local == 'lvl'))
          int.tryParse(_attr(lvl, 'ilvl') ?? '') ?? 0: _child(lvl, 'numFmt')?.let((f) => _attr(f, 'val')) ?? 'bullet',
      };
    }
    for (final n in numbering.descendants.whereType<XmlElement>().where((e) => e.name.local == 'num')) {
      final id = _attr(n, 'numId');
      final a = _child(n, 'abstractNumId')?.let((x) => _attr(x, 'val'));
      if (id != null && a != null && abstract[a] != null) _numberFormats[id] = abstract[a]!;
    }
  }

  /// The heading level of style [id] (following basedOn), or null.
  int? _headingLevel(String? id, [int depth = 0]) {
    if (id == null || depth > 8) return null;
    final s = _styles[id];
    final m = RegExp(r'^heading\s*(\d)$').firstMatch(s?.name ?? '') ?? RegExp(r'^Heading(\d)$').firstMatch(id);
    if (m != null) return int.parse(m[1]!);
    if (s?.name == 'title' || id == 'Title') return 1;
    if (s?.name == 'subtitle' || id == 'Subtitle') return 2;
    if (s?.outlineLevel case final o? when o < 9) return o + 1;
    return _headingLevel(s?.basedOn, depth + 1);
  }

  bool _isCaptionStyle(String? id) => id != null && ((_styles[id]?.name ?? '') == 'caption' || id == 'Caption');

  /// The children of the body, a table cell or a content control.
  void _container(XmlElement node) {
    for (final e in node.childElements) {
      switch (e.name.local) {
        case 'p':
          _paragraph(e);
        case 'tbl':
          _table(e);
        case 'sdt':
          final content = _child(e, 'sdtContent');
          if (content != null) _container(content);
        case 'customXml' || 'smartTag':
          _container(e);
      }
    }
  }

  void _paragraph(XmlElement para) {
    final pPr = _child(para, 'pPr');
    final styleId = pPr?.let((x) => _child(x, 'pStyle'))?.let((s) => _attr(s, 'val'));
    final outline = pPr?.let((x) => _child(x, 'outlineLvl'))?.let((o) => int.tryParse(_attr(o, 'val') ?? ''));
    final level = _headingLevel(styleId) ?? (outline != null && outline < 9 ? outline + 1 : null);
    final text = StringBuffer();
    final images = <DocumentImage>[];
    _runs(para, text, images);
    var words = normalizeParagraph(text.toString());
    if (words.isNotEmpty) {
      if (level != null) {
        _blocks.add(DocumentHeading(singleLine(words), level: level));
      } else {
        final numPr = pPr?.let((x) => _child(x, 'numPr'));
        if (numPr != null) words = '${_listMarker(numPr)} $words';
        if (_isCaptionStyle(styleId)) _captions.add(_blocks.length);
        _blocks.add(DocumentParagraph(words, listItem: numPr != null));
      }
    }
    _blocks.addAll(images);
  }

  String _listMarker(XmlElement numPr) {
    final numId = _child(numPr, 'numId')?.let((n) => _attr(n, 'val')) ?? '';
    final level = int.tryParse(_child(numPr, 'ilvl')?.let((n) => _attr(n, 'val')) ?? '') ?? 0;
    final format = _numberFormats[numId]?[level] ?? 'bullet';
    if (format == 'bullet' || format == 'none') return '•';
    final key = '$numId/$level';
    final n = (_counters[key] ?? 0) + 1;
    _counters[key] = n;
    // Deeper levels start again under a new item of this level.
    _counters.removeWhere((k, _) => k.startsWith('$numId/') && (int.tryParse(k.split('/').last) ?? 0) > level);
    return switch (format) {
      'lowerLetter' => '${String.fromCharCode(96 + ((n - 1) % 26) + 1)}.',
      'upperLetter' => '${String.fromCharCode(64 + ((n - 1) % 26) + 1)}.',
      _ => '$n.',
    };
  }

  /// Text and pictures of a paragraph's content, in order.
  void _runs(XmlElement node, StringBuffer text, List<DocumentImage> images) {
    for (final e in node.childElements) {
      switch (e.name.local) {
        case 't':
          text.write(e.innerText);
        case 'tab' when e.parentElement?.name.local == 'r':
          text.write(' ');
        case 'br' || 'cr':
          if (_attr(e, 'type') != 'page' && _attr(e, 'type') != 'column') text.write('\n');
        case 'noBreakHyphen':
          text.write('-');
        case 'del' || 'delText' || 'instrText' || 'pPr' || 'rPr' || 'footnoteReference' || 'endnoteReference' || 'commentReference':
          break;
        case 'drawing':
          _drawing(e, images);
        case 'pict' || 'object':
          for (final data in e.descendants.whereType<XmlElement>().where((x) => x.name.local == 'imagedata')) {
            _image(_attr(data, 'id'), _attr(data, 'title'), images);
          }
        case 'AlternateContent':
          // Word writes a modern version (Choice) and a fallback; read one.
          final choice = _child(e, 'Choice');
          final chosen = choice ?? _child(e, 'Fallback');
          if (chosen != null) _runs(chosen, text, images);
        case 'txbxContent':
          break; // text boxes float beside the text; left out
        default:
          _runs(e, text, images);
      }
    }
  }

  void _drawing(XmlElement drawing, List<DocumentImage> images) {
    final docPr = drawing.descendants.whereType<XmlElement>().where((x) => x.name.local == 'docPr').firstOrNull;
    final description = docPr?.let((d) => _attr(d, 'descr'))?.trim();
    final title = docPr?.let((d) => _attr(d, 'title'))?.trim();
    final blips = drawing.descendants.whereType<XmlElement>().where((x) => x.name.local == 'blip');
    for (final blip in blips) {
      _image(_attr(blip, 'embed') ?? _attr(blip, 'link'), (description ?? '').isNotEmpty ? description : title, images);
    }
  }

  void _image(String? relationshipId, String? alt, List<DocumentImage> images) {
    if (relationshipId == null) return;
    final target = _relationships[relationshipId];
    if (target == null) return;
    if (target.isEmpty) {
      _externalImages++;
      return;
    }
    final data = _file(target);
    final postable = data == null ? null : postableImage(data);
    if (postable == null) {
      _skippedImages++;
      return;
    }
    final description = alt == null ? '' : singleLine(alt);
    images.add(DocumentImage(
      bytes: postable.bytes,
      mimeType: postable.mimeType,
      altText: description.isEmpty ? null : description,
      name: p.posix.basename(target),
    ));
  }

  void _table(XmlElement table) {
    _tables++;
    for (final row in table.childElements.where((e) => e.name.local == 'tr')) {
      final cells = <String>[];
      final images = <DocumentImage>[];
      for (final cell in row.childElements.where((e) => e.name.local == 'tc')) {
        final text = StringBuffer();
        for (final para in cell.descendants.whereType<XmlElement>().where((e) => e.name.local == 'p')) {
          if (text.isNotEmpty) text.write(' ');
          _runs(para, text, images);
        }
        final words = singleLine(text.toString());
        if (words.isNotEmpty) cells.add(words);
      }
      if (cells.isNotEmpty) _blocks.add(DocumentParagraph(cells.join(' | ')));
      _blocks.addAll(images);
    }
  }

  /// "Figure 2:", "Fig. 3 -", "Photo 1." (a number and a separator, so "Figure
  /// 2 shows..." in a sentence is not taken for a caption).
  static final RegExp _captionPattern = RegExp(r'^(figure|fig\.?|image|picture|photo|chart|diagram|illustration)\s*\d+\s*[:.\-–—]', caseSensitive: false);

  /// A caption next to a picture (a paragraph in the Caption style, or one
  /// starting "Figure 2") describes that picture when it has no
  /// description, and is then not repeated as a paragraph.
  List<DocumentBlock> _attachCaptions() {
    final out = List<DocumentBlock?>.of(_blocks);
    for (var i = 0; i < out.length; i++) {
      final block = out[i];
      if (block is! DocumentParagraph) continue;
      final isCaption = _captions.contains(i) || (_captionPattern.hasMatch(block.text) && block.text.length <= 300);
      if (!isCaption) continue;
      for (final j in [i - 1, i + 1]) {
        if (j < 0 || j >= out.length) continue;
        final neighbour = out[j];
        if (neighbour is DocumentImage) {
          if ((neighbour.altText ?? '').isEmpty) {
            out[j] = DocumentImage(bytes: neighbour.bytes, mimeType: neighbour.mimeType, altText: block.text, name: neighbour.name);
          }
          out[i] = null;
          break;
        }
      }
    }
    return [for (final b in out) ?b];
  }
}

class _Style {
  const _Style(this.name, this.outlineLevel, this.basedOn);
  final String name;
  final int? outlineLevel;
  final String? basedOn;
}

String? _attr(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

XmlElement? _child(XmlElement e, String local) {
  for (final c in e.childElements) {
    if (c.name.local == local) return c;
  }
  return null;
}

extension<T extends Object> on T {
  R? let<R>(R? Function(T) f) => f(this);
}
