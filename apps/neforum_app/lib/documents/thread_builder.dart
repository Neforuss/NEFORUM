import 'package:flutter/foundation.dart';

import 'document_model.dart';

/// One part of a thread made from a document.
@immutable
class DocumentThreadPart {
  const DocumentThreadPart(this.text, this.images);

  /// Paragraphs joined with blank lines.
  final String text;

  /// The pictures that go with this part, in reading order.
  final List<DocumentImage> images;
}

/// A document laid out as thread parts.
@immutable
class DocumentThread {
  const DocumentThread(this.parts);
  final List<DocumentThreadPart> parts;

  int get imageCount => parts.fold(0, (n, p) => n + p.images.length);
}

/// Packs [document] into thread parts at paragraph boundaries.
///
/// - A heading starts a new part, and its first paragraph stays with it.
/// - Paragraphs join the current part while it stays within [partLength]
///   characters; a paragraph that alone is longer gets a part of its own
///   (each network splits it further by its own limit when posting).
/// - Each picture goes in the part that holds the block it sits beside (the
///   block before it in [IngestedDocument.blocks]), however many there are:
///   each network splits a part's pictures by its own limits when the post
///   goes out (1.3.4), into further posts right after that part on X,
///   Bluesky and Mastodon, one carousel where they fit. With
///   [maxImagesPerPart] a part holds at most that many and the rest move on
///   to the next part; when no part follows, they get a part of their own
///   whose text is their descriptions.
DocumentThread buildDocumentThread(IngestedDocument document, {int partLength = 500, int? maxImagesPerPart}) {
  final cap = maxImagesPerPart ?? 1 << 30;
  final parts = <DocumentThreadPart>[];
  final units = <String>[];
  final images = <DocumentImage>[];
  final carried = <DocumentImage>[];
  var length = 0;
  var headingOnly = false;
  var lastWasListItem = false;

  void takeCarried() {
    while (carried.isNotEmpty && images.length < cap) {
      images.add(carried.removeAt(0));
    }
  }

  void close() {
    if (units.isEmpty && images.isEmpty) return;
    parts.add(DocumentThreadPart(units.join(''), List.unmodifiable(images)));
    units.clear();
    images.clear();
    length = 0;
    headingOnly = false;
    lastWasListItem = false;
  }

  void add(String text, {bool listItem = false}) {
    final separator = units.isEmpty ? '' : (listItem && lastWasListItem ? '\n' : '\n\n');
    units.add('$separator$text');
    length += separator.length + text.length;
    lastWasListItem = listItem;
    takeCarried();
  }

  for (final block in document.blocks) {
    switch (block) {
      case DocumentHeading(:final text):
        if (text.trim().isEmpty) continue;
        if (units.isNotEmpty) close();
        add(text);
        headingOnly = true;
      case DocumentParagraph(:final text, :final listItem):
        if (text.trim().isEmpty) continue;
        final separator = units.isEmpty ? 0 : (listItem && lastWasListItem ? 1 : 2);
        if (units.isNotEmpty && !headingOnly && length + separator + text.length > partLength) close();
        add(text, listItem: listItem);
        headingOnly = false;
      case DocumentImage():
        if (images.length < cap && carried.isEmpty) {
          images.add(block);
        } else {
          carried.add(block);
        }
    }
  }
  close();
  // Pictures left over after the last part: parts of their own.
  while (carried.isNotEmpty) {
    takeCarried();
    final described = [
      for (final i in images)
        if ((i.altText ?? '').trim().isNotEmpty) i.altText!.trim(),
    ];
    units.add(described.isEmpty ? '(continued)' : described.join('\n'));
    close();
  }
  return DocumentThread(List.unmodifiable(parts));
}
