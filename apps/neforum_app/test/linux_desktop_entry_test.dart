// The Linux .desktop file must pass the oldest desktop-file-validate NEFORUM
// meets: the AppImage catalog's (appimage.github.io) and Ubuntu 22.04's. Keys
// added after Desktop Entry 1.4 (SingleMainWindow came in 1.5) are errors there,
// which failed NEFORUM 1.4.0 in the catalog.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The [Desktop Entry] keys of the Desktop Entry Specification 1.4.
const _knownKeys = {
  'Type', 'Version', 'Name', 'GenericName', 'NoDisplay', 'Comment', 'Icon', 'Hidden', 'OnlyShowIn', 'NotShowIn',
  'DBusActivatable', 'TryExec', 'Exec', 'Path', 'Terminal', 'Actions', 'MimeType', 'Categories', 'Implements',
  'Keywords', 'StartupNotify', 'StartupWMClass', 'URL', 'PrefersNonDefaultGPU',
};

/// The specification's main categories: an entry names exactly one, or it can
/// show up more than once in an application menu.
const _mainCategories = {
  'AudioVideo', 'Audio', 'Video', 'Development', 'Education', 'Game', 'Graphics', 'Network', 'Office', 'Science',
  'Settings', 'System', 'Utility',
};

Map<String, String> _desktopEntry() {
  final file = File('../../packaging/linux/org.neforum.NEFORUM.desktop');
  final entry = <String, String>{};
  var inMain = false;
  for (final raw in file.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[')) {
      inMain = line == '[Desktop Entry]';
      continue;
    }
    if (!inMain) continue;
    final eq = line.indexOf('=');
    expect(eq, greaterThan(0), reason: 'every line is key=value: $line');
    final key = line.substring(0, eq).replaceAll(RegExp(r'\[.*\]$'), '');
    expect(entry.containsKey(key) && !line.substring(0, eq).contains('['), isFalse, reason: '$key is set twice');
    entry[key] = line.substring(eq + 1);
  }
  return entry;
}

void main() {
  test('every key is in Desktop Entry 1.4 or starts with X-', () {
    final unknown = _desktopEntry().keys.where((k) => !_knownKeys.contains(k) && !k.startsWith('X-')).toList();
    expect(unknown, isEmpty, reason: 'older validators reject these');
  });

  test('exactly one main category', () {
    final categories = _desktopEntry()['Categories']!.split(';').where((c) => c.isNotEmpty);
    expect(categories.where(_mainCategories.contains), hasLength(1));
  });

  test('Icon, Categories, Exec and Name are each there once', () {
    final entry = _desktopEntry();
    for (final key in ['Icon', 'Categories', 'Exec', 'Name', 'Type']) {
      expect(entry[key], isNotNull, reason: key);
    }
  });
}
