import 'dart:typed_data';

import 'document_model.dart';

/// The web preview has no PDFium.
Future<IngestedDocument> readPdf(Uint8List bytes, {void Function(int done, int total)? onProgress}) async =>
    throw const DocumentReadException('PDF files can be read in the NEFORUM app, not in the web preview.');
