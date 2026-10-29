// tool/make_latest_json.dart: latest.json from a release's SHA256SUMS, and
// that the app's update check reads what it writes.

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/update_check.dart';

import '../tool/make_latest_json.dart';

String _hex(int i) => i.toRadixString(16).padLeft(2, '0') * 32;

/// Every file CI's release job publishes (.github/workflows/build.yml).
const _releaseFiles = [
  'NEFORUM-Setup-1.3.0.exe',
  'neforum-windows.zip',
  'NEFORUM-macOS.dmg',
  'NEFORUM-macOS-apple-silicon.dmg',
  'NEFORUM-macOS-intel.dmg',
  'neforum-macos.zip',
  'neforum-macos-apple-silicon.zip',
  'neforum-macos-intel.zip',
  'neforum-android.apk',
  'neforum-android-arm64.apk',
  'neforum-android-armv7.apk',
  'neforum-android-x86_64.apk',
  'neforum-ios-unsigned.ipa',
  'neforum-linux-x64.tar.gz',
  'neforum-linux-arm64.tar.gz',
  'NEFORUM-x86_64.AppImage',
  'NEFORUM-aarch64.AppImage',
  'neforum-extension-chrome-1.1.1.zip',
  'neforum-extension-firefox-1.1.1.xpi',
];

void main() {
  test('every release download gets its own key; other files none', () {
    final keys = {for (final f in _releaseFiles) f: downloadKey(f)};
    expect(keys.values.whereType<String>().toSet(), hasLength(_releaseFiles.length), reason: '$keys');
    expect(keys['NEFORUM-Setup-1.3.0.exe'], 'windows-installer');
    expect(keys['NEFORUM-x86_64.AppImage'], 'linux-x64-appimage');
    expect(keys['NEFORUM-aarch64.AppImage'], 'linux-arm64-appimage');
    expect(keys['neforum-linux-x64.tar.gz'], 'linux-x64-tarball');
    expect(keys['neforum-extension-firefox-1.1.1.xpi'], 'extension-firefox');
    expect(downloadKey('neforum-extension-firefox-1.1.1.zip'), 'extension-firefox');
    for (final other in ['SHA256SUMS', 'latest.json', 'NEFORUM-Setup-1.3.0.exe.intoto.jsonl', 'notes.md']) {
      expect(downloadKey(other), isNull, reason: other);
    }
  });

  test('reads sha256sum output in text and binary mode', () {
    final sums = parseSha256Sums('${_hex(1)}  neforum-windows.zip\n${_hex(2).toUpperCase()} *NEFORUM-Setup-1.3.0.exe\n\n${_hex(3)}  ./SHA256SUMS\n');
    expect(sums, {'neforum-windows.zip': _hex(1), 'NEFORUM-Setup-1.3.0.exe': _hex(2), 'SHA256SUMS': _hex(3)});
    expect(() => parseSha256Sums('abc  file'), throwsFormatException);
  });

  test('builds latest.json that the update check accepts', () {
    var i = 0;
    final sums = {for (final f in [..._releaseFiles, 'latest.json']) f: _hex(++i)};
    final json = buildLatestJson(
      version: '1.3.0',
      sums: sums,
      baseUrl: 'https://github.com/Neforuss/NEFORUM/releases/download/v1.3.0/',
      notes: '<!-- Release notes generated using configuration -->\r\n## What changed\r\n* Linux builds\r\n',
      published: DateTime.utc(2026, 11, 2, 10),
    );
    expect(json['published'], '2026-11-02T10:00:00.000Z');
    expect(json['notes'], '## What changed\n* Linux builds');
    expect(json['critical'], isFalse);

    final release = LatestRelease.fromJson(json);
    expect(release.version, '1.3.0');
    expect(release.downloads, hasLength(_releaseFiles.length), reason: 'latest.json itself is not a download');
    expect(release.downloads['windows-installer']!.url, 'https://github.com/Neforuss/NEFORUM/releases/download/v1.3.0/NEFORUM-Setup-1.3.0.exe');
    expect(release.downloads['windows-installer']!.sha256, sums['NEFORUM-Setup-1.3.0.exe']);
  });

  test('critical releases, long notes, and refusals', () {
    final json = buildLatestJson(version: '1.3.1', sums: const {}, baseUrl: 'https://example.org/d', notes: 'x' * 9000, critical: true);
    expect(json['critical'], isTrue);
    expect((json['notes']! as String).length, maximumNotesLength);
    expect(() => buildLatestJson(version: 'v1.3.0', sums: const {}, baseUrl: 'https://example.org'), throwsFormatException);
    expect(() => buildLatestJson(version: '1.3.0', sums: const {}, baseUrl: 'http://example.org'), throwsFormatException);
    expect(
      () => buildLatestJson(version: '1.3.0', sums: {'neforum-extension-firefox-1.1.1.zip': _hex(1), 'neforum-extension-firefox-1.1.1.xpi': _hex(2)}, baseUrl: 'https://example.org'),
      throwsFormatException,
      reason: 'one file per key: CI must not publish both the unsigned zip and the signed xpi',
    );
  });
}
