// The character catalog as the app ships it (assets/characters), read from
// disk for the tests.
import 'dart:convert';
import 'dart:io';

import 'package:markdown/markdown.dart' as md;
import 'package:neforum_core/neforum_core.dart';

/// What a reader sees of CommonMark [source]: rendered, tags dropped, entities
/// read back. With [gfm], GitHub's extensions (strikethrough, tables) too.
String renderedCommonMark(String source, {bool gfm = false}) =>
    visibleText(md.markdownToHtml(source, extensionSet: gfm ? md.ExtensionSet.gitHubFlavored : md.ExtensionSet.commonMark));

/// The text of [html] as a reader sees it.
String visibleText(String html) => html
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .trim();

Map<String, Object?> catalogJson(String name) => jsonDecode(File('assets/characters/$name').readAsStringSync()) as Map<String, Object?>;

BundledCharacterCatalog? _catalog;

/// The bundled catalog, read once per test file.
BundledCharacterCatalog get bundledCatalog => _catalog ??= BundledCharacterCatalog.fromJson(
      symbols: catalogJson('symbols.json'),
      textStyles: catalogJson('text_styles.json'),
      keywords: catalogJson('keywords.json'),
    );

/// A vendored Unicode file, with line ends as Unicode publishes them.
String unicodeFixture(String name) => File('test/fixtures/unicode/$name').readAsStringSync().replaceAll('\r\n', '\n');
