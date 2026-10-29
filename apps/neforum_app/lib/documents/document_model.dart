import 'package:flutter/foundation.dart';

/// The kinds of document NEFORUM turns into a draft thread.
enum DocumentFormat {
  pdf('PDF', ['pdf']),
  docx('Word document', ['docx']),
  epub('EPUB book', ['epub']),
  markdown('Markdown', ['md', 'markdown']),
  text('Plain text', ['txt']),
  html('Web page', ['html', 'htm', 'xhtml']);

  const DocumentFormat(this.label, this.extensions);

  /// What the user sees ("Word document").
  final String label;

  /// File name extensions, lower case, without the dot.
  final List<String> extensions;

  /// Every extension NEFORUM reads, for pickers and drops.
  static List<String> get allExtensions => [for (final f in values) ...f.extensions];

  /// The format of [fileName] by its extension; null when NEFORUM cannot
  /// read it.
  static DocumentFormat? ofFileName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0) return null;
    final ext = fileName.substring(dot + 1).toLowerCase();
    for (final f in values) {
      if (f.extensions.contains(ext)) return f;
    }
    return null;
  }
}

/// One piece of a document in reading order.
@immutable
sealed class DocumentBlock {
  const DocumentBlock();
}

/// A heading; [level] 1 is the largest.
final class DocumentHeading extends DocumentBlock {
  const DocumentHeading(this.text, {this.level = 1});
  final String text;
  final int level;

  @override
  String toString() => 'DocumentHeading($level, $text)';
}

/// A paragraph of running text. List items are paragraphs with
/// [listItem] set (their bullet or number is part of [text]).
final class DocumentParagraph extends DocumentBlock {
  const DocumentParagraph(this.text, {this.listItem = false});
  final String text;
  final bool listItem;

  @override
  String toString() => 'DocumentParagraph($text)';
}

/// A picture, placed right after the block it belongs with (its anchor).
final class DocumentImage extends DocumentBlock {
  const DocumentImage({required this.bytes, required this.mimeType, this.altText, this.name});

  /// Encoded image (PNG, JPEG, GIF or WebP).
  final Uint8List bytes;
  final String mimeType;

  /// From the document's own description of the picture, else its caption.
  final String? altText;

  /// The picture's own file name in the document, when it has one.
  final String? name;

  @override
  String toString() => 'DocumentImage($mimeType, ${bytes.length} bytes, alt: $altText)';
}

/// A document read into blocks, with what could not be read.
@immutable
class IngestedDocument {
  const IngestedDocument({required this.format, required this.blocks, this.title, this.warnings = const [], this.pageCount});

  final DocumentFormat format;

  /// Headings, paragraphs and pictures in reading order.
  final List<DocumentBlock> blocks;

  /// The document's own title, when it names one.
  final String? title;

  /// Things the user should know: scanned pages without text, pictures in
  /// formats NEFORUM cannot post, skipped tables...
  final List<String> warnings;

  /// Pages of a PDF.
  final int? pageCount;

  Iterable<DocumentImage> get images => blocks.whereType<DocumentImage>();

  /// True when there is no text and no picture.
  bool get isEmpty => blocks.isEmpty;
}

/// Raised when a document cannot be read at all (damaged, encrypted, not
/// the format its name says).
class DocumentReadException implements Exception {
  const DocumentReadException(this.message);
  final String message;
  @override
  String toString() => message;
}
