import 'dart:convert';
import 'dart:typed_data';

import 'package:markdown/markdown.dart' as md;

import 'document_model.dart';
import 'html_reader.dart';
import 'text_normalization.dart';

/// Reads a web page saved as a file. Pictures come from files next to it
/// ([loadImage]) or from `data:` addresses; pictures on the web are never
/// downloaded.
IngestedDocument readHtml(Uint8List bytes, {HtmlImageLoader? loadImage}) {
  final reader = HtmlBlockReader()..read(_decode(bytes), loadImage: loadImage ?? _none);
  return IngestedDocument(format: DocumentFormat.html, blocks: reader.blocks, title: reader.title, warnings: reader.warnings);
}

/// Reads Markdown (CommonMark with GitHub tables) by turning it into HTML.
/// `![alt](picture.png)` pictures come from files next to it ([loadImage]).
IngestedDocument readMarkdown(Uint8List bytes, {HtmlImageLoader? loadImage}) {
  final html = md.markdownToHtml(_decode(bytes), extensionSet: md.ExtensionSet.gitHubFlavored);
  final reader = HtmlBlockReader()..read('<html><body>$html</body></html>', loadImage: loadImage ?? _none);
  final title = reader.blocks.whereType<DocumentHeading>().where((h) => h.level == 1).map((h) => h.text).firstOrNull;
  return IngestedDocument(format: DocumentFormat.markdown, blocks: reader.blocks, title: title, warnings: reader.warnings);
}

/// Reads plain text: paragraphs are separated by blank lines. Text wrapped
/// at a fixed width (most lines about as long as the longest) has its lines
/// joined again; otherwise each line break is kept.
IngestedDocument readPlainText(Uint8List bytes) {
  final text = _decode(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final paragraphs = text.split(RegExp(r'\n[ \t]*\n'));
  final lines = text.split('\n').map((l) => l.trimRight()).where((l) => l.trim().isNotEmpty).toList();
  final wrapped = _looksHardWrapped(lines);
  final blocks = <DocumentBlock>[];
  for (final para in paragraphs) {
    final paraLines = para.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (paraLines.isEmpty) continue;
    final joined = wrapped ? joinWrappedLines(paraLines) : paraLines.join('\n');
    final clean = normalizeParagraph(joined);
    if (clean.isNotEmpty) blocks.add(DocumentParagraph(clean));
  }
  return IngestedDocument(format: DocumentFormat.text, blocks: blocks);
}

/// Most lines end near one width (60 to 100 characters), as text wrapped by
/// an editor or an e-mail program does.
bool _looksHardWrapped(List<String> lines) {
  if (lines.length < 4) return false;
  final longest = lines.map((l) => l.length).reduce((a, b) => a > b ? a : b);
  if (longest < 50 || longest > 110) return false;
  final near = lines.where((l) => l.length >= longest * 0.7).length;
  return near >= lines.length * 0.5;
}

String _decode(Uint8List bytes) {
  // UTF-16 with a byte-order mark (Notepad's "Unicode").
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return String.fromCharCodes(Uint16List.view(Uint8List.fromList(bytes.sublist(2, bytes.length - bytes.length % 2)).buffer));
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final codes = <int>[for (var i = 2; i + 1 < bytes.length; i += 2) (bytes[i] << 8) | bytes[i + 1]];
    return String.fromCharCodes(codes);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

Uint8List? _none(String src) => null;
