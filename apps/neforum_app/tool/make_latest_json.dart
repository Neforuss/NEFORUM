// Builds latest.json, the one file NEFORUM's update check reads
// (lib/platform/update_check.dart), from a release's version, its notes and
// its SHA256SUMS:
//
//   dart tool/make_latest_json.dart --version 1.3.0 --sums SHA256SUMS \
//     --notes notes.md --base-url https://github.com/Neforuss/NEFORUM/releases/download/v1.3.0 \
//     [--critical] [--published 2026-11-02T10:00:00Z] --output latest.json
//
// CI's release job runs it and publishes latest.json as a release asset;
// neforus.com then serves a copy at /neforum/latest.json. Pure Dart (dart:
// libraries only), so it runs with a bare Dart SDK and without `pub get`.

import 'dart:convert';
import 'dart:io';

/// The longest notes kept: the banner shows three lines, the dialog the rest.
const int maximumNotesLength = 4000;

/// The latest.json key of a release file, or null for files that are not
/// downloads (SHA256SUMS, latest.json itself, attestations).
String? downloadKey(String fileName) {
  final rules = <RegExp, String Function(Match)>{
    RegExp(r'^NEFORUM-Setup-[\d.]+\.exe$'): (_) => 'windows-installer',
    RegExp(r'^neforum-windows\.zip$'): (_) => 'windows-zip',
    RegExp(r'^NEFORUM-macOS\.dmg$'): (_) => 'macos-universal-dmg',
    RegExp(r'^NEFORUM-macOS-(apple-silicon|intel)\.dmg$'): (m) => 'macos-${m[1]}-dmg',
    RegExp(r'^neforum-macos\.zip$'): (_) => 'macos-universal-zip',
    RegExp(r'^neforum-macos-(apple-silicon|intel)\.zip$'): (m) => 'macos-${m[1]}-zip',
    RegExp(r'^neforum-android\.apk$'): (_) => 'android-universal-apk',
    RegExp(r'^neforum-android-(arm64|armv7|x86_64)\.apk$'): (m) => 'android-${m[1]}-apk',
    RegExp(r'^neforum-ios-unsigned\.ipa$'): (_) => 'ios-unsigned-ipa',
    RegExp(r'^neforum-linux-(x64|arm64)\.tar\.gz$'): (m) => 'linux-${m[1]}-tarball',
    RegExp(r'^NEFORUM-(x86_64|aarch64)\.AppImage$'): (m) => 'linux-${m[1] == 'x86_64' ? 'x64' : 'arm64'}-appimage',
    RegExp(r'^neforum-extension-(chrome|firefox)-[\d.]+\.(zip|xpi)$'): (m) => 'extension-${m[1]}',
  };
  for (final e in rules.entries) {
    final m = e.key.firstMatch(fileName);
    if (m != null) return e.value(m);
  }
  return null;
}

/// File name -> lowercase SHA-256 from `sha256sum` output (`<hex>  <name>`,
/// or `<hex> *<name>` in binary mode). Throws a [FormatException] on a line
/// that is neither.
Map<String, String> parseSha256Sums(String text) {
  final sums = <String, String>{};
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) continue;
    final m = RegExp(r'^([0-9a-fA-F]{64}) [ *](.+)$').firstMatch(line.trimRight());
    if (m == null) throw FormatException('Not a SHA256SUMS line: $line');
    sums[m[2]!.replaceFirst(RegExp(r'^\./'), '')] = m[1]!.toLowerCase();
  }
  return sums;
}

/// Release notes as the banner shows them: HTML comments (which GitHub's
/// generated notes contain) removed, at most [maximumNotesLength] characters.
String cleanNotes(String notes) {
  var s = notes.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '').replaceAll('\r\n', '\n').trim();
  if (s.length > maximumNotesLength) s = '${s.substring(0, maximumNotesLength - 1).trimRight()}…';
  return s;
}

/// latest.json's content.
Map<String, Object?> buildLatestJson({
  required String version,
  required Map<String, String> sums,
  required String baseUrl,
  String notes = '',
  bool critical = false,
  DateTime? published,
}) {
  if (!RegExp(r'^\d+(\.\d+)*$').hasMatch(version)) throw FormatException('Not a release version: $version');
  final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  if (!base.startsWith('https://')) throw FormatException('The download base must be https: $baseUrl');
  final downloads = <String, Map<String, String>>{};
  for (final name in sums.keys.toList()..sort()) {
    final key = downloadKey(name);
    if (key == null) continue;
    if (downloads.containsKey(key)) throw FormatException('Two files for $key: ${downloads[key]!['url']} and $name');
    downloads[key] = {'url': '$base/${Uri.encodeComponent(name)}', 'sha256': sums[name]!};
  }
  return {
    'version': version,
    'published': (published ?? DateTime.now()).toUtc().toIso8601String(),
    'notes': cleanNotes(notes),
    'critical': critical,
    'downloads': downloads,
  };
}

void main(List<String> args) {
  final options = <String, String>{};
  var critical = false;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--critical') {
      critical = true;
    } else if (a.startsWith('--') && i + 1 < args.length) {
      options[a.substring(2)] = args[++i];
    } else {
      stderr.writeln('Unexpected argument: $a');
      exit(64);
    }
  }
  for (final required in ['version', 'sums', 'base-url', 'output']) {
    if (!options.containsKey(required)) {
      stderr.writeln('Missing --$required. Usage: dart tool/make_latest_json.dart --version 1.3.0 --sums SHA256SUMS '
          '--base-url https://github.com/<owner>/<repo>/releases/download/v1.3.0 [--notes notes.md] [--critical] '
          '[--published <ISO 8601>] --output latest.json');
      exit(64);
    }
  }
  final published = options['published'] == null ? null : DateTime.parse(options['published']!);
  final json = buildLatestJson(
    version: options['version']!.replaceFirst(RegExp('^v'), ''),
    sums: parseSha256Sums(File(options['sums']!).readAsStringSync()),
    baseUrl: options['base-url']!,
    notes: options['notes'] == null ? '' : File(options['notes']!).readAsStringSync(),
    critical: critical,
    published: published,
  );
  File(options['output']!).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(json)}\n');
  final downloads = json['downloads']! as Map;
  stdout.writeln('latest.json: ${json['version']}, ${downloads.length} downloads${critical ? ', critical' : ''}');
}
