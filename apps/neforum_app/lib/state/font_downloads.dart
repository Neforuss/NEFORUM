import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart' show Clock, MediaAttachment, PostStatus, systemClock;

import '../media/caption_fonts.dart';
import '../media/font_catalog.dart';
import '../media/font_draw_check.dart';
import '../media/font_files.dart';
import '../media/font_installer.dart';
import '../media/font_storage_web.dart' if (dart.library.io) '../media/font_storage_io.dart' as files;
import 'captioned_photos.dart' show isCaptionedCopy;
import 'fitted_photos.dart' show fitPhotosOfSavedPost;
import 'providers.dart';
import 'services.dart';
import 'text_cards.dart' show attachTextCards, isRenderedTextCard;

/// The client every font request goes through; replaced in tests.
final fontDownloadClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Where the font list and files are; replaced in tests.
final fontEndpointsProvider = Provider<FontEndpoints>((ref) => const FontEndpoints());

/// The time; replaced in tests.
final fontClockProvider = Provider<Clock>((ref) => systemClock);

/// The draw test a downloaded file must pass; replaced where a widget test is
/// about something else.
final fontDrawCheckProvider = Provider<Future<bool> Function(Uint8List)>((ref) => fontFileDraws);

/// What font downloads are doing in this run.
@immutable
class FontDownloadsState {
  const FontDownloadsState({
    this.catalog,
    this.loadingCatalog = false,
    this.catalogProblem,
    this.installs = const {},
    this.previews = const {},
  });

  /// The list, once it was asked for.
  final FontCatalog? catalog;
  final bool loadingCatalog;

  /// Words for why the list could not be read or refreshed.
  final String? catalogProblem;

  /// Family id -> a download under way.
  final Map<String, FontInstallProgress> installs;

  /// Family id -> the engine name its row's preview is loaded under.
  final Map<String, String> previews;

  static const Object _keep = Object();

  FontDownloadsState copyWith({
    FontCatalog? catalog,
    bool? loadingCatalog,
    Object? catalogProblem = _keep,
    Map<String, FontInstallProgress>? installs,
    Map<String, String>? previews,
  }) =>
      FontDownloadsState(
        catalog: catalog ?? this.catalog,
        loadingCatalog: loadingCatalog ?? this.loadingCatalog,
        catalogProblem: identical(catalogProblem, _keep) ? this.catalogProblem : catalogProblem as String?,
        installs: installs ?? this.installs,
        previews: previews ?? this.previews,
      );
}

/// The one way to the font services. Every method that would contact them
/// first checks [allowed], so opening the picker, typing in it or drawing a
/// card can never reach the network before the user said yes. Nothing here
/// starts by itself: not at start-up, not in the background, not while posting.
class FontDownloadsNotifier extends Notifier<FontDownloadsState> {
  final Map<String, FontInstallCancel> _cancels = {};
  final Set<String> _previewsAsked = {};
  late final FontPreviewLimiter _previewLimiter = FontPreviewLimiter(clock: ref.read(fontClockProvider));

  @override
  FontDownloadsState build() => const FontDownloadsState();

  String? get _dataDir => ref.read(servicesProvider).storage.dataDir;

  /// This install can keep fonts at all (the web preview cannot).
  bool get available => _dataDir != null;

  /// The user said yes on this device.
  bool get allowed => available && ref.read(settingsProvider).fontDownloads == FontDownloadMode.on;

  FontInstaller _installer() => FontInstaller(
        client: ref.read(fontDownloadClientProvider),
        dataDir: _dataDir,
        endpoints: ref.read(fontEndpointsProvider),
        clock: ref.read(fontClockProvider),
        drawCheck: ref.read(fontDrawCheckProvider),
      );

  /// The answer to the one-time question, or the switch in Settings.
  Future<void> setMode(FontDownloadMode mode) => ref.read(settingsProvider.notifier).update((x) => x.copyWith(fontDownloads: mode));

  /// Reads the list for the picker: the saved copy, read again only when it is
  /// old ([kFontCatalogMaxAge]) or [refresh] asks. Keeps the old copy on
  /// failure and says so.
  Future<void> openCatalog({bool refresh = false}) async {
    if (!allowed || state.loadingCatalog) return;
    state = state.copyWith(loadingCatalog: true);
    try {
      final result = await loadFontCatalog(
        ref.read(servicesProvider).storage,
        ref.read(fontDownloadClientProvider),
        endpoints: ref.read(fontEndpointsProvider),
        clock: ref.read(fontClockProvider),
        refresh: refresh,
      );
      if (!ref.mounted) return;
      state = state.copyWith(
        catalog: result.catalog,
        loadingCatalog: false,
        catalogProblem: result.refreshFailed ? 'Could not read the font list again, so this is the saved one.' : null,
      );
    } on FontDownloadException catch (e) {
      if (ref.mounted) state = state.copyWith(loadingCatalog: false, catalogProblem: e.message);
    }
  }

  /// What downloading [id] would take. Throws [FontDownloadException].
  Future<FontInstallPlan> plan(String id) {
    _requireConsent();
    return _installer().plan(id);
  }

  /// The family's weights and files, for "Add more weights".
  Future<FontFamilyDetail> detail(String id) {
    _requireConsent();
    return _installer().detail(id);
  }

  void _requireConsent() {
    if (!allowed) throw StateError('Font downloads are not allowed on this device');
  }

  void _progress(String id, FontInstallProgress p) {
    if (ref.mounted) state = state.copyWith(installs: {...state.installs, id: p});
  }

  void _finished(String id) {
    _cancels.remove(id);
    if (ref.mounted) state = state.copyWith(installs: {...state.installs}..remove(id));
  }

  /// Downloads and keeps [plan], and loads the font so that it draws at once.
  /// Returns the font to choose. Runs on when the picker closes. Throws
  /// [FontDownloadException]; returns null when cancelled.
  Future<CaptionFont?> install(FontInstallPlan plan) async {
    _requireConsent();
    final id = plan.detail.id;
    if (state.installs.containsKey(id)) return null;
    final cancel = _cancels[id] = FontInstallCancel();
    // Read now: the workspace can change while this runs.
    final services = ref.read(servicesProvider);
    final installer = _installer();
    _progress(id, FontInstallProgress(filesTotal: plan.files.length));
    try {
      final downloaded = await installer.install(plan, cancel: cancel, onProgress: (p) => _progress(id, p));
      forgetDownloadedFont(downloaded.family);
      final font = captionFontOf(downloaded);
      await prepareCaptionFont(services.storage, font);
      _fontsChanged();
      await remakePicturesDrawnWithout(services, downloaded.family);
      return font;
    } on FontInstallCancelled {
      return null;
    } finally {
      _finished(id);
    }
  }

  /// Stops the download of [id] at its next chunk.
  void cancelInstall(String id) => _cancels[id]?.cancelled = true;

  /// Adds [weights] to [font]; they draw at once. Throws [FontDownloadException].
  Future<void> addWeights(DownloadedFont font, FontFamilyDetail detail, Iterable<int> weights) async {
    _requireConsent();
    if (state.installs.containsKey(font.id)) return;
    final cancel = _cancels[font.id] = FontInstallCancel();
    final installer = _installer();
    try {
      final (next, added) = await installer.addWeights(font, detail, weights, cancel: cancel, onProgress: (p) => _progress(font.id, p));
      await registerAddedFontWeights(next, added);
      _fontsChanged();
    } on FontInstallCancelled {
      return;
    } finally {
      _finished(font.id);
    }
  }

  /// Removes one downloaded font: what used it draws the default font again.
  Future<void> remove(DownloadedFont font) async {
    await files.deleteCatalogFont(_dataDir, font.folder);
    forgetDownloadedFont(font.family);
    _fontsChanged();
  }

  /// The licence text kept with [font].
  Future<String?> licenseOf(DownloadedFont font) => files.readCatalogFontLicense(_dataDir, font.folder);

  /// Loads the row's preview of [entry]: from the saved copy, else one small
  /// file, at most 20 a minute. Quietly nothing when that is not possible: the
  /// row stays in the interface's font. Asked again by the next row built.
  Future<void> requestPreview(FontCatalogEntry entry) async {
    if (!allowed || state.previews.containsKey(entry.id) || !_previewsAsked.add(entry.id)) return;
    final dataDir = _dataDir;
    var bytes = await files.readFontPreview(dataDir, entry.id);
    if (bytes == null) {
      if (!_previewLimiter.tryStart()) {
        _previewsAsked.remove(entry.id);
        return;
      }
      try {
        bytes = await fetchFontBytes(ref.read(fontDownloadClientProvider), ref.read(fontEndpointsProvider).preview(entry.id, entry.previewFile), maxBytes: kMaxFontFileBytes);
        if (!isWholeFontFile(bytes)) return;
        await files.saveFontPreview(dataDir, entry.id, bytes);
      } on FontDownloadException {
        return;
      }
    }
    if (!isWholeFontFile(bytes)) return;
    final alias = 'NEFORUM font preview: ${entry.id}';
    final loader = FontLoader(alias)..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    if (ref.mounted) state = state.copyWith(previews: {...state.previews, entry.id: alias});
  }

  /// "Delete everything": the fonts, their licences, the saved list and the
  /// previews, and the answer to the one-time question.
  Future<void> deleteAll() async {
    for (final cancel in _cancels.values) {
      cancel.cancelled = true;
    }
    for (final f in await listDownloadedFonts(_dataDir)) {
      forgetDownloadedFont(f.family);
    }
    await files.deleteFontDownloadData(_dataDir);
    _previewsAsked.clear();
    await setMode(FontDownloadMode.ask);
    if (!ref.mounted) return;
    state = const FontDownloadsState();
    _fontsChanged();
  }

  void _fontsChanged() {
    if (!ref.mounted) return;
    ref.invalidate(downloadedFontsProvider);
    // Whether a style's font is here has changed: composer notices, editors.
    ref.invalidate(captionFontReadyProvider);
  }
}

/// Whether [m] is a card or caption that was drawn in the default font because
/// the font [family] was missing.
bool _drawnWithout(MediaAttachment m, String family) {
  final p = m.renderParameters;
  if (p == null) return false;
  bool names(Object? font) => font is Map && '${font['family']}'.toLowerCase() == family.toLowerCase();
  final style = p['style'];
  return (p['customFontFallback'] == true && names(p['customFont'])) ||
      p['designFontFallback'] == true ||
      (p['fontFallback'] == true && style is Map && names(style['customFont']));
}

/// Makes again the cards and captions of saved posts that were drawn without
/// the font [family], now that it is here: the post keeps every choice it was
/// saved with. Only drafts and scheduled posts, and none a platform already
/// holds a copy of. Returns how many posts changed; a post that cannot be made
/// again stays as it is.
Future<int> remakePicturesDrawnWithout(AppServices s, String family) async {
  var remade = 0;
  try {
    for (final post in await s.posts.all()) {
      if ((post.status != PostStatus.draft && post.status != PostStatus.scheduled) || post.hasHeldTargets) continue;
      if (!post.media.any((m) => _drawnWithout(m, family))) continue;
      try {
        if (post.media.any((m) => isRenderedTextCard(m) && _drawnWithout(m, family))) {
          await s.posts.upsert(await attachTextCards(s, post, s.settings));
        }
        if (post.media.any((m) => isCaptionedCopy(m) && _drawnWithout(m, family))) await fitPhotosOfSavedPost(s, post.id);
        remade++;
      } on Object catch (e) {
        debugPrint('Could not make the pictures of ${post.id} again: $e');
      }
    }
  } on Object catch (e) {
    debugPrint('Could not look through the saved posts: $e');
  }
  return remade;
}

final fontDownloadsProvider = NotifierProvider<FontDownloadsNotifier, FontDownloadsState>(FontDownloadsNotifier.new);
