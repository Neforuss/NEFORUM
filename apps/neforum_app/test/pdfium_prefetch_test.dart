// tool/prefetch_pdfium.sh puts PDFium where pdfium_dart's build hook looks
// before it downloads (CI, after a GitHub download outage failed the v1.4.2
// tag run). The script relies on the hook's own source: this checks that the
// installed pdfium_dart still reads that way, so an upgrade that moves the
// library or drops the skip shows up here instead of as a silent no-op.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String hook;
  late String script;

  setUpAll(() {
    // The package config the script reads too (flutter test cannot resolve
    // package: URIs through Isolate).
    final configFile = File('.dart_tool/package_config.json');
    final config = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
    final entry = (config['packages'] as List).cast<Map<String, dynamic>>().firstWhere((p) => p['name'] == 'pdfium_dart');
    final root = configFile.absolute.uri.resolve(entry['rootUri'] as String);
    final dir = root.path.endsWith('/') ? root : Uri.parse('$root/');
    hook = File.fromUri(dir.resolve('hook/build.dart')).readAsStringSync();
    script = File('tool/prefetch_pdfium.sh').readAsStringSync();
  });

  test('the package config lists pdfium_dart the way the script finds it (rootUri right after the name)', () {
    final text = File('.dart_tool/package_config.json').readAsStringSync();
    expect(RegExp(r'"name": "pdfium_dart",\s*\n\s*"rootUri": "[^"]+"').hasMatch(text), isTrue);
  });

  test('the hook names its release in a constant the script can read', () {
    final release = RegExp(r"^const _pdfiumRelease = '([^']+)';$", multiLine: true).firstMatch(hook);
    expect(release, isNotNull);
    expect(release!.group(1), contains('%2F'), reason: 'the script turns %2F into / for the tag and _ for the folder');
    expect(hook, contains("_pdfiumRelease.replaceAll('%2F', '_')"));
  });

  test('the hook skips its download when the library is already in the shared output', () {
    expect(hook, contains('input.outputDirectoryShared.resolve('));
    expect(hook, contains(r"'$outputSubdir/${target.archivePlatform}-${target.archiveArch}/${target.libraryFileName}'"));
    expect(hook, contains('if (await output.exists()) return;'));
  });

  test('the archive paths and file names are the ones the script extracts', () {
    for (final (inside, name) in [
      ('lib/libpdfium.so', 'libpdfium.so'),
      ('lib/libpdfium.dylib', 'libpdfium.dylib'),
      ('bin/pdfium.dll', 'pdfium.dll'),
    ]) {
      expect(hook, contains("archiveLibraryPath: '$inside'"));
      expect(hook, contains("libraryFileName: '$name'"));
      expect(script, contains('inside=$inside'));
    }
    expect(hook, contains("'https://github.com/bblanchon/pdfium-binaries/releases/download/'"));
    expect(script, contains('--repo bblanchon/pdfium-binaries'));
    expect(script, contains('.dart_tool/hooks_runner/shared/pdfium_dart/build/'));
  });
}
