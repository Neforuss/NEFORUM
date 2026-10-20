// Copies the user-facing setup guides from the repository's docs/ folder into
// the app's assets so they can be shown offline inside NEFORUM.
//
//   dart run tool/sync_docs.dart
//
// Run it before building a release (CI does).

import 'dart:io';

void main() {
  final app = Directory.current.path;
  final repoDocs = Directory('$app/../../docs');
  final out = Directory('$app/assets/docs');
  if (!repoDocs.existsSync()) {
    stderr.writeln('docs/ not found at ${repoDocs.path}; run from apps/neforum_app');
    exit(1);
  }
  out.createSync(recursive: true);
  for (final f in out.listSync().whereType<File>()) {
    if (f.path.endsWith('.md')) f.deleteSync();
  }
  var n = 0;
  void copy(File f, String name) {
    f.copySync('${out.path}/$name');
    n++;
  }

  final platforms = Directory('${repoDocs.path}/platforms');
  if (platforms.existsSync()) {
    for (final f in platforms.listSync().whereType<File>().where((f) => f.path.endsWith('.md'))) {
      copy(f, f.uri.pathSegments.last);
    }
  }
  for (final name in ['media-hosts.md', 'platforms.md', 'meta-privacy-policy.md', 'browser-extension.md', 'backup.md']) {
    final f = File('${repoDocs.path}/$name');
    if (f.existsSync()) copy(f, name);
  }
  stdout.writeln('Copied $n guide(s) into assets/docs');
}
