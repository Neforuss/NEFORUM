import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart' show Clock, systemClock;

import 'font_catalog.dart';
import 'font_draw_check.dart';
import 'font_files.dart';
import 'font_storage_web.dart' if (dart.library.io) 'font_storage_io.dart' as files;

/// Reads a font's manifests from the data folder.
Future<List<DownloadedFont>> listDownloadedFonts(String? dataDir) async {
  final out = [for (final raw in await files.readCatalogManifests(dataDir)) ?DownloadedFont.tryParse(raw)];
  out.sort((a, b) => a.family.toLowerCase().compareTo(b.family.toLowerCase()));
  return out;
}

/// Downloads fonts into `fonts/catalog`. Every file is checked before anything
/// is kept: a whole plain font file ([isWholeFontFile]), then drawn once
/// ([fontFileDraws]). The folder appears only when all of that passed, with the
/// licence text in it, so a failed download leaves nothing behind.
///
/// Callers ask the user first: nothing in here looks at the setting, and the
/// [FontDownloadsNotifier] in front of it refuses without consent.
class FontInstaller {
  FontInstaller({
    required this.client,
    required this.dataDir,
    this.endpoints = const FontEndpoints(),
    this.clock = systemClock,
    this.drawCheck = fontFileDraws,
  });

  final http.Client client;
  final String? dataDir;
  final FontEndpoints endpoints;
  final Clock clock;

  /// Replaced in tests of what happens after a real draw test.
  final Future<bool> Function(Uint8List bytes) drawCheck;

  /// What the service says about [id].
  Future<FontFamilyDetail> detail(String id) async {
    final bytes = await fetchFontBytes(client, endpoints.detail(id), maxBytes: kMaxFontDetailBytes);
    Object? body;
    try {
      body = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      debugPrint('The answer about the font $id could not be read: ${e.message}');
      throw const FontDownloadException('The font service sent an answer NEFORUM could not read.');
    }
    return FontFamilyDetail.parse(body, expectedId: id);
  }

  /// The download of [id]: its regular and bold in every named subset. The size
  /// of a big subset is read first, so the user can be told.
  Future<FontInstallPlan> plan(String id) async {
    final d = await detail(id);
    final planned = d.filesFor(d.defaultWeights);
    if (planned.isEmpty) throw FontDownloadException('${d.family} is not offered as a file NEFORUM can use.');
    if (planned.length > kMaxFontInstallFiles) throw FontDownloadException('${d.family} comes in too many files for NEFORUM to use.');
    final large = planned.where((f) => kLargeFontSubsets.contains(f.subset)).toList();
    if (large.isEmpty) return FontInstallPlan(detail: d, files: planned);
    var known = 0;
    for (final f in large) {
      final size = await fetchFontFileSize(client, endpoints.file(d.id, d.version, f.fileName));
      if (size == null) return FontInstallPlan(detail: d, files: planned);
      known += size;
    }
    return FontInstallPlan(detail: d, files: planned, knownLargeBytes: known);
  }

  /// Downloads, checks and keeps [plan]; returns the font as it is on disk.
  /// Throws [FontDownloadException] or [FontInstallCancelled], leaving nothing.
  Future<DownloadedFont> install(FontInstallPlan plan, {void Function(FontInstallProgress)? onProgress, FontInstallCancel? cancel}) async {
    final d = plan.detail;
    final kept = await _download(d.id, d.version, d.family, plan.files, onProgress: onProgress, cancel: cancel);
    final subsets = orderSubsets({for (final f in kept.keys) f.subset}, d.defaultSubset);
    if (!kept.keys.any((f) => f.subset == subsets.first)) throw const FontDownloadException(_cannotDraw);

    final license = await fetchFontBytes(client, endpoints.license(d.id, d.version), maxBytes: kMaxFontLicenseBytes, cancel: cancel);
    if (!_looksLikeLicenseText(license)) throw FontDownloadException('The licence of ${d.family} could not be read, so it was not installed.');

    final font = DownloadedFont(
      id: d.id,
      version: d.version,
      family: d.family,
      category: d.category,
      license: d.license,
      installedAt: clock(),
      subsets: subsets,
      files: await _describe(kept),
    );
    final older = [for (final f in await listDownloadedFonts(dataDir)) if (f.id == d.id) f.folder];
    await files.saveCatalogFont(
      dataDir,
      font.folder,
      {
        for (final e in kept.entries) e.key.fileName: e.value,
        kFontLicenseFile: license,
        kFontManifestFile: Uint8List.fromList(utf8.encode(jsonEncode(font.toJson()))),
      },
      replacing: older,
    );
    debugPrint('Downloaded the font ${font.folder}: ${font.files.length} files, ${font.totalBytes} bytes, ${font.subsets.length} subsets');
    return font;
  }

  /// Adds [weights] to [font], of the version it already has, in the subsets it
  /// already has. Returns the font on disk and the bytes of what was added, so
  /// the font can be used at once. A weight the service does not have for a
  /// subset is simply not added there.
  Future<(DownloadedFont, Map<DownloadedFontFile, Uint8List>)> addWeights(DownloadedFont font, FontFamilyDetail detail, Iterable<int> weights,
      {void Function(FontInstallProgress)? onProgress, FontInstallCancel? cancel}) async {
    final have = {for (final f in font.files) f.file};
    final planned = [
      for (final s in font.subsets)
        for (final w in weights)
          if ((detail.available[w]?.contains(s) ?? false) && !have.contains(FontFilePlan(s, w).fileName)) FontFilePlan(s, w),
    ];
    if (font.files.length + planned.length > kMaxFontInstallFiles) throw FontDownloadException('${font.family} would be too many files for NEFORUM to use.');
    if (planned.isEmpty) return (font, const <DownloadedFontFile, Uint8List>{});
    final kept = await _download(font.id, font.version, font.family, planned, onProgress: onProgress, cancel: cancel, alreadyBytes: font.totalBytes);
    final added = await _describe(kept);
    final next = font.copyWith(files: [...font.files, ...added]);
    await files.addCatalogFontFiles(
      dataDir,
      font.folder,
      {for (final e in kept.entries) e.key.fileName: e.value},
      Uint8List.fromList(utf8.encode(jsonEncode(next.toJson()))),
    );
    return (next, {for (final f in added) f: kept[FontFilePlan(f.subset, f.weight)]!});
  }

  static const String _cannotDraw = 'This font cannot be drawn on this device, so it was not installed.';

  /// Fetches [planned] and returns the files that passed. A file that is not a
  /// font stops everything; a subset that draws blank is left out, and when
  /// nothing draws the font is refused.
  Future<Map<FontFilePlan, Uint8List>> _download(String id, String version, String family, List<FontFilePlan> planned,
      {void Function(FontInstallProgress)? onProgress, FontInstallCancel? cancel, int alreadyBytes = 0}) async {
    final fetched = <FontFilePlan, Uint8List>{};
    var total = alreadyBytes;
    onProgress?.call(FontInstallProgress(filesTotal: planned.length, bytes: total));
    for (final f in planned) {
      if (cancel?.cancelled ?? false) throw const FontInstallCancelled();
      final before = total;
      final bytes = await fetchFontBytes(
        client,
        endpoints.file(id, version, f.fileName),
        maxBytes: kMaxFontFileBytes,
        cancel: cancel,
        onBytes: (n) {
          if (before + n > kMaxFontInstallBytes) throw const FontDownloadException('This font is larger than NEFORUM accepts, so it was not downloaded.');
          onProgress?.call(FontInstallProgress(filesDone: fetched.length, filesTotal: planned.length, bytes: before + n));
        },
      );
      total += bytes.length;
      if (!isWholeFontFile(bytes)) {
        debugPrint('Refused ${f.fileName} of $id@$version: not a whole font file (${bytes.length} bytes)');
        throw FontDownloadException('NEFORUM could not use the file it got for $family, so it was not installed.');
      }
      fetched[f] = bytes;
    }
    final kept = <FontFilePlan, Uint8List>{};
    for (final e in fetched.entries) {
      if (cancel?.cancelled ?? false) throw const FontInstallCancelled();
      if (await drawCheck(e.value)) {
        kept[e.key] = e.value;
      } else {
        debugPrint('Left out ${e.key.fileName} of $id@$version: it draws nothing here');
      }
    }
    if (kept.isEmpty) throw const FontDownloadException(_cannotDraw);
    return kept;
  }

  Future<List<DownloadedFontFile>> _describe(Map<FontFilePlan, Uint8List> kept) async => [
        for (final e in kept.entries)
          DownloadedFontFile(
            subset: e.key.subset,
            weight: e.key.weight,
            file: e.key.fileName,
            bytes: e.value.length,
            sha256: await files.sha256OfFontFile(e.value),
          ),
      ];

  /// Licence text, not an error page or an empty answer.
  static bool _looksLikeLicenseText(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true).trimLeft();
    return text.length >= 32 && !text.startsWith('<');
  }
}
