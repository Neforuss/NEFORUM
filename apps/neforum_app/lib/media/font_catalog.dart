import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart' show Clock, systemClock;

import '../platform/storage.dart';

// The list of free fonts NEFORUM can download (1.4): Fontsource's index for
// search and licences, its static TTF files through pinned jsDelivr URLs. No
// key and no account. Nothing here runs unless the user turned font downloads
// on ([FontDownloadMode]); a font file never travels between devices, only the
// [CatalogFontSource] naming it does.

/// Settings > Data and privacy: whether this device may contact the font list.
enum FontDownloadMode {
  /// Not decided yet: NEFORUM asks the first time the user looks for a font.
  /// No network until then.
  ask,

  /// The user allowed it. Still only when they open the font list.
  on,

  /// The user turned it off: no list, no offers.
  off,
}

/// The only provider so far; kept in the JSON so that another could be added.
const String kFontProviderFontsource = 'fontsource';

/// The file in the data folder that keeps the font list.
const String kFontCatalogFile = 'font-catalog.json';

/// The list is read again only when the user opens it and it is older than this.
const Duration kFontCatalogMaxAge = Duration(days: 14);

/// The only User-Agent font requests send. Fixed and without a version: Dart's
/// default would tell the two services which Dart, and so roughly which
/// NEFORUM, is asking.
const String kFontDownloadUserAgent = 'NEFORUM fonts';

/// Licences a downloaded font may have. Anything else is hidden, not shown.
const Set<String> kAllowedFontLicenses = {'ofl-1.1', 'apache-2.0', 'ufl-1.0', 'cc0-1.0', 'unlicense', 'mit'};

/// Icon sets and symbol fonts are not fonts to write in.
const Set<String> kHiddenFontCategories = {'icons', 'other'};

/// Color emoji fonts: COLRv1 draws blank on Windows, and emoji are the system's.
const Set<String> kHiddenFontIds = {'noto-color-emoji', 'noto-emoji'};

/// The largest font file, whole install and list NEFORUM accepts.
const int kMaxFontFileBytes = 30 * 1024 * 1024;
const int kMaxFontInstallBytes = 60 * 1024 * 1024;
const int kMaxFontInstallFiles = 60;
const int kMaxFontCatalogBytes = 8 * 1024 * 1024;
const int kMaxFontDetailBytes = 2 * 1024 * 1024;
const int kMaxFontLicenseBytes = 1024 * 1024;

/// Over this, the user sees the size before the download starts.
const int kLargeFontBytes = 5 * 1024 * 1024;

/// Subsets that make a font big: these are the only ones sized ahead.
const Set<String> kLargeFontSubsets = {'japanese', 'korean', 'chinese-simplified', 'chinese-traditional', 'chinese-hongkong'};

final RegExp _fontId = RegExp(r'^[a-z0-9][a-z0-9-]{0,99}$');
final RegExp _fontVersion = RegExp(r'^\d{1,6}\.\d{1,6}\.\d{1,6}$');
final RegExp _fontSubset = RegExp(r'^[a-z][a-z0-9-]{0,49}$');
final RegExp _fontFileName = RegExp(r'^[a-z][a-z0-9-]{0,49}-\d{3}-normal\.ttf$');
final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// Whether [license] is one of [kAllowedFontLicenses], whatever its case.
bool isAllowedFontLicense(String license) => kAllowedFontLicenses.contains(license.trim().toLowerCase());

/// Where the list and the files are. Tests and the profile-build test point it
/// at a local server.
@immutable
class FontEndpoints {
  const FontEndpoints({
    this.api = 'https://api.fontsource.org/v1/fonts',
    this.files = 'https://cdn.jsdelivr.net/fontsource/fonts',
    this.packages = 'https://cdn.jsdelivr.net/npm/@fontsource',
  });

  final String api, files, packages;

  Uri list() => Uri.parse(api);
  Uri detail(String id) => Uri.parse('$api/$id');

  /// A file of an exact version: never changes once published.
  Uri file(String id, String version, String name) => Uri.parse('$files/$id@$version/$name');

  /// A sample file, of whichever version is current.
  Uri preview(String id, String name) => Uri.parse('$files/$id@latest/$name');

  /// The licence text of an exact version.
  Uri license(String id, String version) => Uri.parse('$packages/$id@$version/LICENSE');
}

/// What a font style names so that another device can fetch the same font:
/// `inter@5.3.0` from Fontsource. Travels in the style's JSON; never a path.
@immutable
class CatalogFontSource {
  const CatalogFontSource({required this.id, required this.version, this.provider = kFontProviderFontsource, this.sizeBytes});

  /// Null when [j] is not a source NEFORUM can use. This JSON comes from a
  /// synced file: the id and version end up in paths and URLs.
  static CatalogFontSource? tryParse(Object? j) {
    if (j is! Map) return null;
    final provider = j['provider'], id = j['id'], version = j['version'], size = j['bytes'];
    if (provider != kFontProviderFontsource || id is! String || version is! String) return null;
    if (!_fontId.hasMatch(id) || !_fontVersion.hasMatch(version)) return null;
    return CatalogFontSource(id: id, version: version, sizeBytes: size is int && size > 0 ? size : null);
  }

  final String provider, id, version;

  /// The size of the install it was made from: lets another device say
  /// "Download Inter (480 KB)" before contacting anyone.
  final int? sizeBytes;

  Map<String, dynamic> toJson() => {'provider': provider, 'id': id, 'version': version, 'bytes': ?sizeBytes};

  @override
  bool operator ==(Object other) => other is CatalogFontSource && other.provider == provider && other.id == id && other.version == version;

  @override
  int get hashCode => Object.hash(provider, id, version);
}

/// One family of the font list.
@immutable
class FontCatalogEntry {
  const FontCatalogEntry({
    required this.id,
    required this.family,
    required this.category,
    required this.license,
    required this.subsets,
    required this.weights,
    required this.defaultSubset,
  });

  /// Null for a row NEFORUM does not show: an unknown licence, an icon set, a
  /// color emoji font, no upright style, or a row it cannot read.
  static FontCatalogEntry? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], family = j['family'], category = j['category'], license = j['license'];
    if (id is! String || family is! String || category is! String || license is! String) return null;
    if (!_fontId.hasMatch(id) || family.trim().isEmpty) return null;
    if (kHiddenFontIds.contains(id) || kHiddenFontCategories.contains(category) || !isAllowedFontLicense(license)) return null;
    final styles = j['styles'];
    if (styles is List && !styles.contains('normal')) return null;
    final subsets = [for (final s in (j['subsets'] as List? ?? const [])) if (s is String && _fontSubset.hasMatch(s)) s];
    final weights = [for (final w in (j['weights'] as List? ?? const [])) if (w is int && w >= 100 && w <= 900) w];
    if (subsets.isEmpty || weights.isEmpty) return null;
    final def = j['defSubset'];
    return FontCatalogEntry(
      id: id,
      family: family.trim(),
      category: category,
      license: license,
      subsets: subsets,
      weights: weights,
      defaultSubset: def is String && subsets.contains(def) ? def : subsets.first,
    );
  }

  final String id, family, category, license, defaultSubset;
  final List<String> subsets;
  final List<int> weights;

  /// The one file a row's preview loads.
  String get previewFile {
    final subset = subsets.contains('latin') ? 'latin' : defaultSubset;
    return '$subset-${nearestFontWeight(weights, 400)}-normal.ttf';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'family': family,
        'category': category,
        'license': license,
        'subsets': subsets,
        'weights': weights,
        'defSubset': defaultSubset,
      };
}

/// The weight of [weights] closest to [wanted]; on a tie, the lighter.
int nearestFontWeight(Iterable<int> weights, int wanted) {
  final sorted = weights.toList()..sort();
  var best = sorted.first;
  for (final w in sorted) {
    if ((w - wanted).abs() < (best - wanted).abs()) best = w;
  }
  return best;
}

/// The font list as last read.
@immutable
class FontCatalog {
  const FontCatalog({required this.fetchedAt, required this.entries});

  /// From the service's answer. Throws [FormatException] for anything that
  /// holds no font NEFORUM can show: such an answer never replaces a good list.
  factory FontCatalog.fromFontsource(Object? body, DateTime fetchedAt) {
    if (body is! List) throw const FormatException('The font list is not a list');
    final entries = [for (final row in body) ?FontCatalogEntry.tryParse(row)];
    if (entries.isEmpty) throw const FormatException('The font list holds no usable font');
    return FontCatalog(fetchedAt: fetchedAt, entries: entries);
  }

  /// Null when [j] is not a saved list.
  static FontCatalog? tryFromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final at = DateTime.tryParse('${j['fetchedAt'] ?? ''}');
    final rows = j['rows'];
    if (at == null || rows is! List) return null;
    final entries = [for (final row in rows) ?FontCatalogEntry.tryParse(row)];
    return entries.isEmpty ? null : FontCatalog(fetchedAt: at, entries: entries);
  }

  final DateTime fetchedAt;
  final List<FontCatalogEntry> entries;

  Map<String, dynamic> toJson() => {
        'version': 1,
        'fetchedAt': fetchedAt.toUtc().toIso8601String(),
        'rows': [for (final e in entries) e.toJson()],
      };

  /// Whether it is time to read the list again ([kFontCatalogMaxAge]). A saved
  /// time in the future (a clock put back) counts as old.
  bool isStale(DateTime now) {
    final age = now.difference(fetchedAt);
    return age.isNegative || age > kFontCatalogMaxAge;
  }

  /// The entries whose name holds [query], in [category] and covering [subset]
  /// when those are given.
  List<FontCatalogEntry> search(String query, {String? category, String? subset}) {
    final q = query.trim().toLowerCase();
    return [
      for (final e in entries)
        if ((q.isEmpty || e.family.toLowerCase().contains(q)) && (category == null || e.category == category) && (subset == null || e.subsets.contains(subset))) e,
    ];
  }
}

/// A font request that failed, with words to show the user. No raw error text:
/// the details go to the log.
class FontDownloadException implements Exception {
  const FontDownloadException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The user cancelled a download.
class FontInstallCancelled implements Exception {
  const FontInstallCancelled();
}

/// Set to stop a download at the next chunk.
class FontInstallCancel {
  bool cancelled = false;
}

const String _unreachable = 'NEFORUM could not reach the font service. Check your connection and try again.';

/// GETs [url] whole, at most [maxBytes], stopping at the first chunk over it.
/// No Range requests: jsDelivr answers those with a slice of its compressed
/// copy, which looks like a broken font. Throws [FontDownloadException].
Future<Uint8List> fetchFontBytes(
  http.Client client,
  Uri url, {
  required int maxBytes,
  void Function(int received)? onBytes,
  FontInstallCancel? cancel,
}) async {
  final request = http.Request('GET', url)..headers['User-Agent'] = kFontDownloadUserAgent;
  try {
    final response = await client.send(request).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      debugPrint('Font request answered ${response.statusCode}: $url');
      throw FontDownloadException(response.statusCode == 404 ? 'The font service no longer has this file.' : _unreachable);
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
      if (cancel?.cancelled ?? false) throw const FontInstallCancelled();
      out.add(chunk);
      if (out.length > maxBytes) throw const FontDownloadException('This font is larger than NEFORUM accepts, so it was not downloaded.');
      onBytes?.call(out.length);
    }
    return out.takeBytes();
  } on FontDownloadException {
    rethrow;
  } on FontInstallCancelled {
    rethrow;
  } on Object catch (e) {
    debugPrint('Font request failed for $url: $e');
    throw const FontDownloadException(_unreachable);
  }
}

/// A file's size from jsDelivr's answer to HEAD: its weak ETag starts with the
/// length in hex (`W/"299ea4-..."`), since the answer has no Content-Length.
/// Null when it does not say. Only sizes a question to the user, never a check.
Future<int?> fetchFontFileSize(http.Client client, Uri url) async {
  try {
    final response = await client.head(url, headers: const {'User-Agent': kFontDownloadUserAgent}).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    final etag = RegExp(r'^(?:W/)?"([0-9a-f]+)-').firstMatch(response.headers['etag'] ?? '');
    return etag == null ? null : int.tryParse(etag[1]!, radix: 16);
  } on Object catch (e) {
    debugPrint('Could not size $url: $e');
    return null;
  }
}

/// The font list: the saved copy while it is fresh, else read again. What it
/// says about a failed refresh is in [FontCatalogResult.refreshFailed].
@immutable
class FontCatalogResult {
  const FontCatalogResult(this.catalog, {this.refreshFailed = false});
  final FontCatalog catalog;
  final bool refreshFailed;
}

/// Reads the list ([kFontCatalogFile] while fresh, else from the service,
/// saving the answer). On failure the old copy stays and says so; with no copy
/// it throws [FontDownloadException].
Future<FontCatalogResult> loadFontCatalog(
  AppStorage storage,
  http.Client client, {
  FontEndpoints endpoints = const FontEndpoints(),
  Clock clock = systemClock,
  bool refresh = false,
}) async {
  FontCatalog? saved;
  try {
    saved = FontCatalog.tryFromJson(await storage.readJson(kFontCatalogFile));
  } on Object catch (e) {
    debugPrint('Could not read the saved font list: $e');
  }
  final now = clock();
  if (saved != null && !refresh && !saved.isStale(now)) return FontCatalogResult(saved);
  try {
    final bytes = await fetchFontBytes(client, endpoints.list(), maxBytes: kMaxFontCatalogBytes);
    final FontCatalog fresh;
    try {
      fresh = FontCatalog.fromFontsource(jsonDecode(utf8.decode(bytes)), now);
    } on FormatException catch (e) {
      debugPrint('The font list could not be read: ${e.message}');
      throw const FontDownloadException('The font service sent a list NEFORUM could not read.');
    }
    await storage.writeJson(kFontCatalogFile, fresh.toJson());
    return FontCatalogResult(fresh);
  } on FontDownloadException {
    if (saved != null) return FontCatalogResult(saved, refreshFailed: true);
    rethrow;
  }
}

/// One file of a family: upright, [weight], [subset].
@immutable
class FontFilePlan {
  const FontFilePlan(this.subset, this.weight);
  final String subset;
  final int weight;

  String get fileName => '$subset-$weight-normal.ttf';

  @override
  bool operator ==(Object other) => other is FontFilePlan && other.subset == subset && other.weight == weight;

  @override
  int get hashCode => Object.hash(subset, weight);

  @override
  String toString() => fileName;
}

/// One family as the service describes it (`/v1/fonts/<id>`).
@immutable
class FontFamilyDetail {
  const FontFamilyDetail({
    required this.id,
    required this.family,
    required this.version,
    required this.category,
    required this.license,
    required this.defaultSubset,
    required this.weights,
    required this.available,
  });

  /// Throws [FontDownloadException] for a family NEFORUM does not offer. A
  /// synced style can name anything, so the list's rules are applied again.
  factory FontFamilyDetail.parse(Object? j, {required String expectedId}) {
    const unreadable = FontDownloadException('The font service sent an answer NEFORUM could not read.');
    if (j is! Map) throw unreadable;
    final id = j['id'], family = j['family'], version = j['npmVersion'], category = j['category'], license = j['license'], variants = j['variants'];
    if (id != expectedId || family is! String || family.trim().isEmpty || version is! String || category is! String || license is! String || variants is! Map) {
      throw unreadable;
    }
    if (!_fontVersion.hasMatch(version)) throw unreadable;
    if (!isAllowedFontLicense(license)) throw FontDownloadException('NEFORUM does not offer ${family.trim()}: its licence is not on the list it accepts.');
    if (kHiddenFontIds.contains(id) || kHiddenFontCategories.contains(category)) throw FontDownloadException('NEFORUM does not offer ${family.trim()}.');
    final available = <int, Set<String>>{};
    for (final v in variants.entries) {
      final weight = int.tryParse('${v.key}');
      final upright = v.value is Map ? (v.value as Map)['normal'] : null;
      if (weight == null || weight < 100 || weight > 900 || upright is! Map) continue;
      final subsets = <String>{};
      for (final s in upright.entries) {
        // Numbered slices are left out: a named subset covers the same script
        // in one file, and a hundred fallback fonts would be slow.
        final name = '${s.key}';
        final urls = s.value is Map ? (s.value as Map)['url'] : null;
        if (_fontSubset.hasMatch(name) && urls is Map && urls['ttf'] is String) subsets.add(name);
      }
      if (subsets.isNotEmpty) available[weight] = subsets;
    }
    if (available.isEmpty) throw FontDownloadException('${family.trim()} is not offered as a file NEFORUM can use.');
    final def = j['defSubset'];
    return FontFamilyDetail(
      id: expectedId,
      family: family.trim(),
      version: version,
      category: category,
      license: license,
      defaultSubset: def is String ? def : '',
      weights: available.keys.toList()..sort(),
      available: available,
    );
  }

  final String id, family, version, category, license, defaultSubset;
  final List<int> weights;

  /// Weight -> the named subsets with a TTF file.
  final Map<int, Set<String>> available;

  /// What an install takes by default: the weight nearest 400 and, where the
  /// family has one, a bold (600 or more, nearest 700).
  List<int> get defaultWeights {
    final regular = nearestFontWeight(weights, 400);
    final bolds = weights.where((w) => w >= 600 && w != regular);
    return [regular, if (bolds.isNotEmpty) nearestFontWeight(bolds, 700)];
  }

  /// The subset drawn first ([orderSubsets]).
  List<String> subsetsOf(Iterable<int> chosen) => orderSubsets({for (final w in chosen) ...?available[w]}, defaultSubset);

  /// Every file of [chosen] weights, in chain order.
  List<FontFilePlan> filesFor(Iterable<int> chosen) => [
        for (final s in subsetsOf(chosen))
          for (final w in chosen)
            if (available[w]?.contains(s) ?? false) FontFilePlan(s, w),
      ];
}

/// The order subsets are tried in: Latin, then the family's default, then its
/// extension, then the rest by name. Only the first draws under the plain alias.
List<String> orderSubsets(Set<String> subsets, String defaultSubset) {
  int rank(String s) => s == 'latin' ? 0 : (s == defaultSubset ? 1 : (s == 'latin-ext' ? 2 : 3));
  return subsets.toList()
    ..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.compareTo(b);
    });
}

/// A download about to start.
@immutable
class FontInstallPlan {
  const FontInstallPlan({required this.detail, required this.files, this.knownLargeBytes});
  final FontFamilyDetail detail;
  final List<FontFilePlan> files;

  /// The size of the big subsets, when it could be read ([kLargeFontSubsets]).
  final int? knownLargeBytes;

  /// The user sees this before it starts: a file that is known to be big, or
  /// one that usually is and whose size could not be read.
  bool get isLarge {
    if (!files.any((f) => kLargeFontSubsets.contains(f.subset))) return false;
    final known = knownLargeBytes;
    return known == null || known > kLargeFontBytes;
  }
}

/// How far a download has got.
@immutable
class FontInstallProgress {
  const FontInstallProgress({this.filesDone = 0, this.filesTotal = 0, this.bytes = 0});
  final int filesDone, filesTotal, bytes;

  /// Files finished out of all files; null until the list of files is known.
  double? get fraction => filesTotal == 0 ? null : filesDone / filesTotal;
}

/// One file of a downloaded font.
@immutable
class DownloadedFontFile {
  const DownloadedFontFile({required this.subset, required this.weight, required this.file, required this.bytes, required this.sha256});

  static DownloadedFontFile? tryParse(Object? j) {
    if (j is! Map) return null;
    final subset = j['subset'], weight = j['weight'], file = j['file'], bytes = j['bytes'], sha = j['sha256'];
    if (subset is! String || weight is! int || file is! String || bytes is! int || sha is! String) return null;
    if (!_fontFileName.hasMatch(file) || !_sha256Hex.hasMatch(sha) || !_fontSubset.hasMatch(subset)) return null;
    return DownloadedFontFile(subset: subset, weight: weight, file: file, bytes: bytes, sha256: sha);
  }

  final String subset, file, sha256;
  final int weight, bytes;

  Map<String, dynamic> toJson() => {'subset': subset, 'weight': weight, 'file': file, 'bytes': bytes, 'sha256': sha256};
}

/// The name of the licence text kept next to a downloaded font's files.
const String kFontLicenseFile = 'LICENSE';

/// The name of the description kept in a downloaded font's folder.
const String kFontManifestFile = 'manifest.json';

/// A font in `fonts/catalog/<id>@<version>/`, as its `manifest.json` says.
@immutable
class DownloadedFont {
  const DownloadedFont({
    required this.id,
    required this.version,
    required this.family,
    required this.category,
    required this.license,
    required this.installedAt,
    required this.subsets,
    required this.files,
  });

  /// Null when [j] is not a manifest NEFORUM can use: the folder is then ignored.
  static DownloadedFont? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], version = j['version'], family = j['family'], category = j['category'], license = j['license'], rawFiles = j['files'], rawSubsets = j['subsets'];
    if (j['provider'] != kFontProviderFontsource || id is! String || version is! String || family is! String || category is! String || license is! String) return null;
    if (!_fontId.hasMatch(id) || !_fontVersion.hasMatch(version) || family.trim().isEmpty || rawFiles is! List || rawSubsets is! List) return null;
    final files = [for (final f in rawFiles) ?DownloadedFontFile.tryParse(f)];
    final subsets = [for (final s in rawSubsets) if (s is String && _fontSubset.hasMatch(s)) s];
    if (files.isEmpty || subsets.isEmpty || !files.any((f) => f.subset == subsets.first)) return null;
    return DownloadedFont(
      id: id,
      version: version,
      family: family.trim(),
      category: category,
      license: license,
      installedAt: DateTime.tryParse('${j['installedAt'] ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0),
      subsets: subsets,
      files: files,
    );
  }

  final String id, version, family, category, license;
  final DateTime installedAt;

  /// In chain order: the first draws under the plain alias.
  final List<String> subsets;
  final List<DownloadedFontFile> files;

  /// The folder under `fonts/catalog`.
  String get folder => '$id@$version';

  int get totalBytes => files.fold(0, (a, f) => a + f.bytes);

  List<int> get weights => ({for (final f in files) f.weight}.toList()..sort());

  CatalogFontSource get source => CatalogFontSource(id: id, version: version, sizeBytes: totalBytes);

  DownloadedFont copyWith({List<DownloadedFontFile>? files}) => DownloadedFont(
        id: id,
        version: version,
        family: family,
        category: category,
        license: license,
        installedAt: installedAt,
        subsets: subsets,
        files: files ?? this.files,
      );

  Map<String, dynamic> toJson() => {
        'schema': 1,
        'provider': kFontProviderFontsource,
        'id': id,
        'version': version,
        'family': family,
        'category': category,
        'license': license,
        'installedAt': installedAt.toUtc().toIso8601String(),
        'subsets': subsets,
        'files': [for (final f in files) f.toJson()],
      };
}

/// Words for a font's category in the picker.
String fontCategoryLabel(String category) => switch (category) {
      'sans-serif' => 'Sans serif',
      'serif' => 'Serif',
      'display' => 'Display',
      'handwriting' => 'Handwriting',
      'monospace' => 'Monospace',
      _ => category,
    };

/// Words for a licence: the short form, readable.
String fontLicenseLabel(String license) => switch (license.trim().toLowerCase()) {
      'ofl-1.1' => 'OFL 1.1',
      'apache-2.0' => 'Apache 2.0',
      'ufl-1.0' => 'Ubuntu Font Licence',
      'cc0-1.0' => 'CC0',
      'unlicense' => 'Unlicense',
      'mit' => 'MIT',
      _ => license,
    };

/// Whether at most [limit] previews may start per [window]: a fast scroll
/// through two thousand families would otherwise look like scraping, which
/// jsDelivr's terms forbid.
class FontPreviewLimiter {
  FontPreviewLimiter({this.limit = 20, this.window = const Duration(minutes: 1), this.clock = systemClock});
  final int limit;
  final Duration window;
  final Clock clock;
  final List<DateTime> _started = [];

  /// True, and counted, when one more may start now.
  bool tryStart() {
    final now = clock();
    _started.removeWhere((t) => now.difference(t) >= window);
    if (_started.length >= limit) return false;
    _started.add(now);
    return true;
  }
}
