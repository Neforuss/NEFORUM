import 'package:flutter/foundation.dart';

import 'document_model.dart';
import 'docx_reader.dart';
import 'epub_reader.dart';
import 'local_images_web.dart' if (dart.library.io) 'local_images_io.dart';
import 'pdf_reader.dart';
import 'plain_readers.dart';

/// Reads the document [bytes] (a file named [fileName]) off the UI isolate.
/// [folder] is the file's own folder, where a web page or Markdown file
/// finds its pictures. [onProgress] reports pages read (PDF).
///
/// Throws [DocumentReadException] when the file cannot be read.
Future<IngestedDocument> ingestDocument(
  Uint8List bytes, {
  required String fileName,
  String? folder,
  void Function(int done, int total)? onProgress,
}) async {
  final format = DocumentFormat.ofFileName(fileName);
  if (format == null) {
    throw DocumentReadException('NEFORUM cannot read $fileName. It reads ${DocumentFormat.allExtensions.map((e) => '.$e').join(', ')}.');
  }
  if (format == DocumentFormat.pdf) return readPdf(bytes, onProgress: onProgress);
  return compute(readDocumentBytes, (format: format, bytes: bytes, folder: folder));
}

/// Reads a document that is not a PDF; top level so it can run on another
/// isolate.
IngestedDocument readDocumentBytes(({DocumentFormat format, Uint8List bytes, String? folder}) request) {
  final images = localImageLoader(request.folder);
  return switch (request.format) {
    DocumentFormat.docx => readDocx(request.bytes),
    DocumentFormat.epub => readEpub(request.bytes),
    DocumentFormat.markdown => readMarkdown(request.bytes, loadImage: images),
    DocumentFormat.html => readHtml(request.bytes, loadImage: images),
    DocumentFormat.text => readPlainText(request.bytes),
    DocumentFormat.pdf => throw StateError('PDF files are read with readPdf'),
  };
}
