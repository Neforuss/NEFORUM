// Builds the NEFORUM browser extension (extensions/browser) for Chrome and
// Firefox:
//
//   dart run tool/build_extension.dart        (from apps/neforum_app)
//
// - assets/browser-extension/chrome and .../firefox: the unpacked extension,
//   bundled with the app so Settings > Browser extension can show the folder
//   for "Load unpacked" (Chrome) and "Load Temporary Add-on" (Firefox).
// - ../../dist/neforum-extension-<browser>-<version>.zip: ready to upload to
//   the Chrome Web Store and to addons.mozilla.org.
//
// The two builds share every file except manifest.json (Chrome runs the
// background as a service worker, Firefox as an event page with a gecko id).

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

void main() {
  final app = Directory.current.path;
  final ext = Directory('$app/../../extensions/browser');
  final src = Directory('${ext.path}/src');
  if (!src.existsSync()) {
    stderr.writeln('extensions/browser/src not found; run from apps/neforum_app');
    exit(1);
  }
  final dist = Directory('$app/../../dist')..createSync(recursive: true);

  for (final browser in ['chrome', 'firefox']) {
    final manifest = File('${ext.path}/manifest.$browser.json').readAsStringSync();
    final version = (jsonDecode(manifest) as Map)['version'] as String;
    final out = Directory('$app/assets/browser-extension/$browser');
    if (out.existsSync()) out.deleteSync(recursive: true);
    out.createSync(recursive: true);

    final archive = Archive();
    void add(String rel, List<int> bytes) {
      final f = File('${out.path}/$rel')..parent.createSync(recursive: true);
      f.writeAsBytesSync(bytes);
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    }

    add('manifest.json', utf8.encode(manifest));
    final files = src.listSync(recursive: true).whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final rel = f.path.substring(src.path.length + 1).replaceAll('\\', '/');
      add(rel, f.readAsBytesSync());
    }
    final zip = File('${dist.path}/neforum-extension-$browser-$version.zip')..writeAsBytesSync(ZipEncoder().encode(archive));
    stdout.writeln('$browser $version: ${files.length + 1} files -> ${out.path}, ${zip.path}');
  }
}
