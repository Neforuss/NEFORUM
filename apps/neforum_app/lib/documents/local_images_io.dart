import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Reads pictures a web page or Markdown file names by a relative path from
/// [folder], the file's own folder. Pictures on the web are never fetched.
Uint8List? Function(String src)? localImageLoader(String? folder) {
  if (folder == null) return null;
  return (src) {
    final uri = Uri.tryParse(src);
    if (uri == null || (uri.hasScheme && uri.scheme != 'file')) return null;
    final path = uri.scheme == 'file' ? uri.toFilePath() : p.join(folder, Uri.decodeFull(uri.path));
    final file = File(path);
    return file.existsSync() ? file.readAsBytesSync() : null;
  };
}
