import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart';

// 1.4.3: symbols. The character panel's data: Unicode symbols, NEFORUM's
// kaomoji and the text style tables, bundled with neforum_core and read once.

/// Where neforum_core's character data sits in the app bundle.
const String kCharacterAssets = 'packages/neforum_core/assets/characters';

/// The catalog, read from the bundle the first time the panel opens. The
/// three files make about 450 kB of JSON; nothing goes over the network.
final characterCatalogProvider = FutureProvider<CharacterCatalog>((ref) async {
  Future<Map<String, Object?>> read(String name) async => jsonDecode(await rootBundle.loadString('$kCharacterAssets/$name')) as Map<String, Object?>;
  return BundledCharacterCatalog.fromJson(
    symbols: await read('symbols.json'),
    textStyles: await read('text_styles.json'),
    keywords: await read('keywords.json'),
  );
});

/// Most favourites kept: more than a panel shows without scrolling, few
/// enough that a synced settings file stays small.
const int kCharacterFavouritesMax = 120;

/// [favourites] with [text] added first, or taken out when it is in already.
List<String> withFavouriteToggled(List<String> favourites, String text) =>
    favourites.contains(text) ? [for (final f in favourites) if (f != text) f] : [text, ...favourites].take(kCharacterFavouritesMax).toList();

var _licenseRegistered = false;

/// Shows the Unicode data's licence in Settings > About > Licenses, beside
/// the packages' own. Called once at start.
void registerCharacterDataLicense() {
  if (_licenseRegistered) return;
  _licenseRegistered = true;
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('$kCharacterAssets/LICENSE-Unicode.txt');
    yield LicenseEntryWithLineBreaks(const ['Unicode Character Database', 'Unicode CLDR'], '$kCharacterDataNotice\n\n$text');
  });
}

/// What NEFORUM takes from Unicode, said above the licence text.
const String kCharacterDataNotice = 'The Symbols and Text styles tabs and the emoji and symbol search words are made from the Unicode Character '
    'Database (Blocks.txt, UnicodeData.txt, NamesList.txt), Unicode\'s code page tables (CP437, CP1252, IBMGRAPH) and the Unicode '
    'CLDR English annotations, by tool/generate_character_catalog.dart in neforum_core. The versions and SHA-256 of each file are '
    'recorded in the data files. Copyright Unicode, Inc. Used under the Unicode License v3, below.';
