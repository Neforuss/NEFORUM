import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'document_model.dart';
import 'html_reader.dart';
import 'text_normalization.dart';

/// Reads an EPUB book: `META-INF/container.xml` names the package (OPF),
/// whose spine lists the chapters (XHTML) in reading order; each chapter is
/// read with [HtmlBlockReader], its pictures taken from the book.
IngestedDocument readEpub(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object {
    throw const DocumentReadException('This EPUB file is damaged: it is not a ZIP package.');
  }
  final files = {for (final f in archive.files) if (f.isFile) f.name: f};
  Uint8List? fileBytes(String name) {
    final f = files[name] ?? files[Uri.decodeFull(name)];
    return f?.content;
  }

  final container = fileBytes('META-INF/container.xml');
  if (container == null) throw const DocumentReadException('This EPUB file has no META-INF/container.xml.');
  final opfPath = _parse(container)
      .findAllElements('rootfile')
      .map((e) => e.getAttribute('full-path'))
      .whereType<String>()
      .firstWhere((path) => path.toLowerCase().endsWith('.opf'), orElse: () => '');
  final opfBytes = opfPath.isEmpty ? null : fileBytes(opfPath);
  if (opfBytes == null) throw const DocumentReadException('This EPUB file does not name its package document.');
  final opf = _parse(opfBytes);
  final opfDir = p.posix.dirname(opfPath);

  final manifest = <String, ({String href, String type})>{};
  for (final item in opf.findAllElements('item')) {
    final id = item.getAttribute('id');
    final href = item.getAttribute('href');
    if (id == null || href == null) continue;
    manifest[id] = (href: _join(opfDir, href), type: item.getAttribute('media-type') ?? '');
  }
  final spine = [
    for (final ref in opf.findAllElements('itemref'))
      if (ref.getAttribute('linear') != 'no' && manifest[ref.getAttribute('idref')] != null) manifest[ref.getAttribute('idref')]!,
  ];
  final title = opf.findAllElements('title', namespace: '*').map((e) => singleLine(e.innerText)).where((t) => t.isNotEmpty).firstOrNull;

  final reader = HtmlBlockReader();
  var chapters = 0;
  for (final item in spine) {
    if (!item.type.contains('html') && !item.href.toLowerCase().endsWith('html') && !item.href.toLowerCase().endsWith('.htm')) continue;
    final data = fileBytes(item.href);
    if (data == null) continue;
    chapters++;
    final dir = p.posix.dirname(item.href);
    reader.read(
      utf8.decode(data, allowMalformed: true),
      loadImage: (src) {
        final uri = Uri.tryParse(src);
        if (uri == null || uri.hasScheme) return null; // never fetched from the web
        return fileBytes(_join(dir, uri.path));
      },
    );
  }
  if (chapters == 0) throw const DocumentReadException('This EPUB file lists no chapters to read.');
  return IngestedDocument(format: DocumentFormat.epub, blocks: reader.blocks, title: title ?? reader.title, warnings: reader.warnings);
}

XmlDocument _parse(Uint8List bytes) {
  try {
    return XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
  } on XmlException catch (e) {
    throw DocumentReadException('This EPUB file is damaged: ${e.message}');
  }
}

/// [href] (relative, maybe with %20) inside the folder [dir] of the book.
String _join(String dir, String href) {
  final path = Uri.decodeFull(href.split('#').first);
  final joined = dir == '.' || dir.isEmpty ? path : p.posix.join(dir, path);
  return p.posix.normalize(joined);
}
