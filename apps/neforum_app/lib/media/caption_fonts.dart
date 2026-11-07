import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../platform/env.dart';
import '../platform/storage.dart';
import '../state/providers.dart';
import '../state/render_warnings.dart';
import '../theme/tokens.dart';
import 'font_catalog.dart';
import 'font_files.dart';
import 'font_installer.dart' show listDownloadedFonts;
import 'font_storage_web.dart' if (dart.library.io) 'font_storage_io.dart' as files;

// Fonts for the caption written on photos and for text cards (1.3.1) beyond
// the built-in ones (TextCardFont): any font installed on the computer, or a
// font file the user imported (phones have no list of installed fonts). The chosen font is loaded
// into the engine under a stable name ([CaptionFont.alias]) with FontLoader,
// so the saved picture is drawn in exactly that font. A font that is not on
// this device (a style made on another computer) leaves the caption in the
// built-in font, and the user is told once.

/// A font chosen for the caption: its family name, and where it was found,
/// the installed file ([path]) or an imported one ([fileId], a file in
/// NEFORUM's `fonts` folder). Kept in the caption style's JSON.
@immutable
class CaptionFont {
  const CaptionFont({required this.family, this.path, this.fileId, this.source});

  /// Null when [j] holds no family name.
  static CaptionFont? tryParse(Object? j) {
    if (j is! Map) return null;
    final family = j['family'], path = j['path'], fileId = j['fileId'];
    if (family is! String || family.trim().isEmpty) return null;
    return CaptionFont(
      family: family.trim(),
      path: path is String && path.isNotEmpty ? path : null,
      fileId: fileId is String && fileId.isNotEmpty ? fileId : null,
      source: CatalogFontSource.tryParse(j['source']),
    );
  }

  final String family;

  /// The installed font file it was picked from.
  final String? path;

  /// The imported font file it was picked from (a name in the `fonts`
  /// folder of NEFORUM's data).
  final String? fileId;

  /// 1.4: the font list's name for it, when it was downloaded. A device
  /// without the font can offer to fetch the same one.
  final CatalogFontSource? source;

  bool get isImported => fileId != null;

  /// The name the font is loaded under: the same for a family wherever its
  /// file is, so a style drawn on two devices names the same font.
  String get alias => 'NEFORUM font: $family';

  Map<String, dynamic> toJson() => {
        'family': family,
        if (path != null) 'path': path,
        if (fileId != null) 'fileId': fileId,
        if (source != null) 'source': source!.toJson(),
      };

  @override
  bool operator ==(Object other) => other is CaptionFont && other.family == family && other.path == path && other.fileId == fileId && other.source == source;

  @override
  int get hashCode => Object.hash(family, path, fileId, source);

  @override
  String toString() => 'CaptionFont($family)';
}

/// Fonts that draw what a chosen font lacks (emoji, other scripts), after
/// the built-in caption font: Windows, Apple and Noto names; the engine skips
/// the ones a device does not have and then falls back to the system's own.
const List<String> kCaptionFontFallbacks = [
  'Segoe UI Emoji',
  'Apple Color Emoji',
  'Noto Color Emoji',
  'Segoe UI Symbol',
  'Noto Sans',
  'Noto Sans CJK SC',
  'Microsoft YaHei',
  'PingFang SC',
  Fonts.body,
];

// ---------------------------------------------------------------------------
// Fonts loaded into the engine
// ---------------------------------------------------------------------------

final Set<String> _registered = {};

/// Changes each time a caption font finishes loading: painters repaint on it,
/// since the same style then draws differently.
final ValueNotifier<int> captionFontsRevision = ValueNotifier<int>(0);

/// The family name to draw [font] with, once it is loaded; null while it is
/// not (the caption then uses the built-in font).
String? registeredCaptionFontAlias(CaptionFont? font) => font != null && _registered.contains(font.alias) ? font.alias : null;

/// Plain alias -> the aliases of a downloaded font's other subsets, in order.
final Map<String, List<String>> _subsetAliases = {};

/// The other files of a downloaded [font], to put first in the fallback list:
/// a downloaded font comes as one file per script, and the engine draws only
/// the first file it gets for a family and style. So each script has a family
/// name of its own. Empty for any other font.
List<String> captionFontSubsetAliases(CaptionFont? font) {
  final all = font == null ? null : _subsetAliases[font.alias];
  return all == null ? const [] : [for (final a in all) if (_registered.contains(a)) a];
}

/// Marks [font] as loaded without loading anything, for tests.
@visibleForTesting
void debugMarkCaptionFontRegistered(CaptionFont font, {bool registered = true}) {
  registered ? _registered.add(font.alias) : _registered.remove(font.alias);
  captionFontsRevision.value++;
}

/// Forgets every loaded font and notice, for tests.
@visibleForTesting
void debugResetCaptionFonts() {
  _registered.clear();
  _subsetAliases.clear();
  _reportedMissing.clear();
  _loading.clear();
  _catalog = null;
  debugInstalledFontCatalog = null;
}

/// Loads [faces] (font files of one face each) into the engine as [alias].
Future<void> _register(String alias, List<Uint8List> faces) async {
  final loader = FontLoader(alias);
  for (final f in faces) {
    loader.addFont(Future.value(ByteData.sublistView(f)));
  }
  await loader.load();
  _registered.add(alias);
  captionFontsRevision.value++;
}

// ---------------------------------------------------------------------------
// Installed fonts
// ---------------------------------------------------------------------------

/// One face of a font file on this device.
@immutable
class FontSource {
  const FontSource(this.path, this.face);
  final String path;
  final FontFace face;
}

/// The fonts installed on this device, by family.
@immutable
class InstalledFontCatalog {
  const InstalledFontCatalog(this.families);

  /// From scan entries (`{path, size, modified, faces}`).
  factory InstalledFontCatalog.fromEntries(Iterable<Map<String, dynamic>> entries) {
    final byFamily = <String, List<FontSource>>{};
    for (final e in entries) {
      final path = e['path'], faces = e['faces'];
      if (path is! String || faces is! List) continue;
      for (final raw in faces) {
        final face = FontFace.tryParse(raw);
        if (face != null) (byFamily[face.family] ??= []).add(FontSource(path, face));
      }
    }
    final names = byFamily.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return InstalledFontCatalog({for (final n in names) n: byFamily[n]!});
  }

  static const InstalledFontCatalog empty = InstalledFontCatalog({});

  /// Family name -> its faces, sorted by name.
  final Map<String, List<FontSource>> families;

  /// The faces of [family], whatever its case; empty when it is not installed.
  List<FontSource> facesOf(String family) {
    final exact = families[family];
    if (exact != null) return exact;
    final lower = family.toLowerCase();
    for (final e in families.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return const [];
  }
}

/// File in the data folder that keeps the last scan, so a file is read again
/// only when it changed.
const String kInstalledFontsCacheFile = 'installed-fonts.json';

Future<InstalledFontCatalog>? _catalog;

/// Replaces the scan of installed fonts, for tests.
@visibleForTesting
InstalledFontCatalog? debugInstalledFontCatalog;

/// The fonts installed on this computer, scanned once per run off the UI
/// isolate; empty on phones and the web.
Future<InstalledFontCatalog> loadInstalledFonts(AppStorage storage, {bool refresh = false}) {
  final override = debugInstalledFontCatalog;
  if (override != null) return Future.value(override);
  if (!Env.isDesktop) return Future.value(InstalledFontCatalog.empty);
  if (refresh) _catalog = null;
  return _catalog ??= _scan(storage);
}

Future<InstalledFontCatalog> _scan(AppStorage storage) async {
  try {
    final cached = await storage.readJson(kInstalledFontsCacheFile);
    final previous = <String, Map<String, dynamic>>{
      for (final e in (cached?['entries'] as List? ?? const []))
        if (e is Map && e['path'] is String) e['path'] as String: Map<String, dynamic>.from(e),
    };
    final entries = await files.scanInstalledFonts(files.FontScanJob(directories: files.installedFontDirectories(), previous: previous));
    unawaited(storage.writeJson(kInstalledFontsCacheFile, {'version': 1, 'entries': entries}).catchError((Object e) {
      debugPrint('Could not keep the list of installed fonts: $e');
    }));
    return InstalledFontCatalog.fromEntries(entries);
  } on Object catch (e) {
    debugPrint('Could not list the installed fonts: $e');
    _catalog = null;
    return InstalledFontCatalog.empty;
  }
}

// ---------------------------------------------------------------------------
// Imported fonts
// ---------------------------------------------------------------------------

/// A font file the user imported, with its first family.
@immutable
class ImportedFont {
  const ImportedFont({required this.font, required this.faces});
  final CaptionFont font;
  final List<FontFace> faces;
}

/// The fonts imported into NEFORUM's `fonts` folder.
Future<List<ImportedFont>> loadImportedFonts(AppStorage storage) async {
  final out = <ImportedFont>[];
  for (final (fileId, path) in await files.listImportedFonts(storage.dataDir)) {
    final faces = await files.readFontFacesOfFile(path);
    final regular = regularFaceOf(faces);
    if (regular == null) continue;
    out.add(ImportedFont(font: CaptionFont(family: regular.family, fileId: fileId), faces: faces));
  }
  out.sort((a, b) => a.font.family.toLowerCase().compareTo(b.font.family.toLowerCase()));
  return out;
}

/// Why a font file could not be imported.
class FontImportException implements Exception {
  const FontImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Keeps the font file [bytes] (named [fileName]) in NEFORUM's `fonts`
/// folder and returns it as a caption font. Throws [FontImportException] for
/// a file that is not a font NEFORUM can read.
Future<CaptionFont> importCaptionFont(AppStorage storage, String fileName, Uint8List bytes) async {
  if (!isFontFilePath(fileName)) throw const FontImportException('Choose a TrueType or OpenType font file (.ttf or .otf)');
  final faces = readFontFacesFromBytes(bytes);
  final regular = regularFaceOf(faces);
  if (regular == null) throw const FontImportException('That file has no font NEFORUM can read');
  final ext = fileName.substring(fileName.lastIndexOf('.') + 1).toLowerCase();
  final fileId = '${const Uuid().v7()}.$ext';
  final path = await files.saveImportedFont(storage.dataDir, fileId, bytes);
  if (path == null) throw const FontImportException('Fonts cannot be imported here');
  return CaptionFont(family: regular.family, fileId: fileId);
}

// ---------------------------------------------------------------------------
// Loading a chosen font
// ---------------------------------------------------------------------------

final Map<String, Future<bool>> _loading = {};

/// Loads [font] into the engine, from its downloaded files, its installed
/// file, its imported file, or (a style made on another device) the same family
/// installed here; true once it can be drawn. False when the font is not on
/// this device: the caption then uses the built-in font. Never throws, and
/// never contacts anyone: a font is only ever downloaded when the user says so.
Future<bool> prepareCaptionFont(AppStorage storage, CaptionFont font) {
  if (_registered.contains(font.alias)) return Future.value(true);
  final key = '${font.alias}|${font.path}|${font.fileId}|${font.source?.id}';
  final running = _loading[key];
  if (running != null) return running;
  final job = _load(storage, font).catchError((Object e) {
    debugPrint('Could not load the font ${font.family}: $e');
    return false;
  });
  _loading[key] = job;
  // Only the attempt in progress is shared: a font installed or imported
  // later is found on the next try.
  unawaited(job.whenComplete(() => _loading.remove(key)));
  return job;
}

Future<bool> _load(AppStorage storage, CaptionFont font) async {
  // A style that names the font list's font: that one, where it is here.
  if (font.source != null && await _loadDownloaded(storage, font)) return true;
  final sources = <FontSource>[];
  Future<void> addFile(String? path) async {
    if (path == null || !await files.fontFileExists(path)) return;
    final faces = await files.readFontFacesOfFile(path);
    final same = faces.where((f) => f.family.toLowerCase() == font.family.toLowerCase()).toList();
    sources.addAll([for (final f in same.isEmpty ? faces : same) FontSource(path, f)]);
  }

  await addFile(font.path);
  if (sources.isEmpty && font.fileId != null) await addFile(files.importedFontPath(storage.dataDir, font.fileId!));
  // The other faces of the family (bold), or the whole family when the file
  // is not here: a style made on another computer.
  final installed = (await loadInstalledFonts(storage)).facesOf(font.family);
  if (sources.isEmpty) {
    sources.addAll(installed);
  } else {
    sources.addAll(installed.where((s) => s.path != font.path));
  }
  // The same family downloaded here: also for a style that lost its source
  // going through a device with 1.3.
  if (sources.isEmpty) return font.source == null && await _loadDownloaded(storage, font);

  FontSource? pick(FontFace? face) => face == null ? null : sources.firstWhere((s) => identical(s.face, face));
  final regular = pick(regularFaceOf(sources.map((s) => s.face)));
  if (regular == null) return false;
  final bold = pick(boldFaceOf(sources.map((s) => s.face)));
  final faces = <Uint8List>[];
  for (final s in [regular, ?(bold == null || identical(bold, regular) ? null : bold)]) {
    final bytes = await files.readFontFaceBytes(s.path, s.face.index);
    if (bytes != null) faces.add(bytes);
  }
  if (faces.isEmpty) return false;
  await _register(font.alias, faces);
  return true;
}

/// Loads the downloaded font [font] names, or the one of the same family:
/// its first subset under [CaptionFont.alias], each other one under a name of
/// its own, all weights of a subset together. False when it is not here or its
/// first subset cannot be read.
Future<bool> _loadDownloaded(AppStorage storage, CaptionFont font) async {
  final dataDir = storage.dataDir;
  if (dataDir == null) return false;
  final all = await listDownloadedFonts(dataDir);
  final id = font.source?.id;
  final lower = font.family.toLowerCase();
  final match = all.where((f) => id != null ? f.id == id : f.family.toLowerCase() == lower).firstOrNull;
  if (match == null) return false;
  final bySubset = <String, List<Uint8List>>{};
  await Future.wait([
    for (final f in match.files)
      files.readCatalogFontFile(dataDir, match.folder, f.file, f.sha256).then((bytes) {
        if (bytes != null) (bySubset[f.subset] ??= []).add(bytes);
      }),
  ]);
  if (bySubset[match.subsets.first] == null) return false;
  await _registerSubsets(font, match, bySubset);
  return true;
}

Future<void> _registerSubsets(CaptionFont font, DownloadedFont downloaded, Map<String, List<Uint8List>> bySubset) async {
  final first = downloaded.subsets.first;
  String aliasOf(String subset) => subset == first ? font.alias : '${font.alias}/$subset';
  _subsetAliases[font.alias] = [for (final s in downloaded.subsets) if (s != first) aliasOf(s)];
  await Future.wait([
    for (final s in downloaded.subsets)
      if (bySubset[s] != null && s != first) _register(aliasOf(s), bySubset[s]!),
  ]);
  // Last: the font counts as loaded only with every script in place.
  if (bySubset[first] != null) await _register(font.alias, bySubset[first]!);
}

/// The font a downloaded font is chosen as.
CaptionFont captionFontOf(DownloadedFont downloaded) => CaptionFont(family: downloaded.family, source: downloaded.source);

/// Adds weights that were just downloaded to a font already in use.
Future<void> registerAddedFontWeights(DownloadedFont downloaded, Map<DownloadedFontFile, Uint8List> added) async {
  final font = captionFontOf(downloaded);
  if (!_registered.contains(font.alias)) return;
  final bySubset = <String, List<Uint8List>>{};
  for (final e in added.entries) {
    (bySubset[e.key.subset] ??= []).add(e.value);
  }
  await _registerSubsets(font, downloaded, bySubset);
}

/// Stops using a downloaded font that was removed: styles naming it draw the
/// built-in font again and offer it once more. The engine keeps the file's
/// glyphs until NEFORUM restarts, under a name no style then uses.
void forgetDownloadedFont(String family) {
  final alias = CaptionFont(family: family).alias;
  _registered.remove(alias);
  for (final a in _subsetAliases.remove(alias) ?? const <String>[]) {
    _registered.remove(a);
  }
  final prefix = '${family.toLowerCase()}|';
  _reportedMissing.removeWhere((k) => k.startsWith(prefix));
  captionFontsRevision.value++;
}

final Set<String> _reportedMissing = {};

/// A picture was drawn without a font the font list has: the app can offer
/// [font] to the user. The picture is already drawn, and nothing waits for this.
@immutable
class MissingFontOffer {
  const MissingFontOffer(this.font, this.usage);
  final CaptionFont font;

  /// What used the default font: "the text card", "the caption on the photo".
  final String usage;
}

final StreamController<MissingFontOffer> _missingFontOffers = StreamController<MissingFontOffer>.broadcast();

/// Fonts to offer, for the app to show wherever the user is. Nobody listens in
/// a background run, which only draws in the default font.
Stream<MissingFontOffer> get missingFontOffers => _missingFontOffers.stream;

/// [prepareCaptionFont] for a picture that is being saved: within the render
/// time limit, and when the font is not on this device the user is told once
/// per family and [usage] (each run) that [usage] ("the caption on the
/// photo", "the text card") uses the built-in font. Never waits for a download,
/// so a scheduled post is never held up by a font: one from the font list is
/// only offered ([missingFontOffers]).
Future<bool> prepareCaptionFontForRender(AppStorage storage, CaptionFont font, {String usage = 'the caption on the photo'}) async {
  bool ready;
  try {
    ready = await prepareCaptionFont(storage, font).timeout(kRenderTimeLimit);
  } on TimeoutException {
    ready = false;
  }
  if (!ready && _reportedMissing.add('${font.family.toLowerCase()}|$usage')) {
    if (font.source != null) {
      debugPrint('The font ${font.family} is not on this device, so $usage uses the default font.');
      _missingFontOffers.add(MissingFontOffer(font, usage));
    } else {
      reportRenderWarning('The font ${font.family} is not on this device, so $usage uses the default font. '
          'Install or import ${font.family} here to use it.');
    }
  }
  return ready;
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// The fonts installed on this computer ([loadInstalledFonts]).
final installedFontsProvider = FutureProvider<InstalledFontCatalog>((ref) => loadInstalledFonts(ref.read(servicesProvider).storage));

/// The fonts the user imported ([loadImportedFonts]).
final importedFontsProvider = FutureProvider<List<ImportedFont>>((ref) => loadImportedFonts(ref.read(servicesProvider).storage));

/// The fonts downloaded from the font list ([listDownloadedFonts]).
final downloadedFontsProvider = FutureProvider<List<DownloadedFont>>((ref) => listDownloadedFonts(ref.read(servicesProvider).storage.dataDir));

/// Whether [font] is loaded and drawn ([prepareCaptionFont]); true for no
/// custom font. Watching it starts the loading.
final captionFontReadyProvider = FutureProvider.family<bool, CaptionFont?>((ref, font) {
  if (font == null) return Future.value(true);
  return prepareCaptionFont(ref.read(servicesProvider).storage, font);
});
