import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../media/caption_fonts.dart';
import '../../media/caption_style.dart';
import '../../media/font_catalog.dart';
import '../../media/text_card.dart';
import '../../platform/env.dart';
import '../../state/font_downloads.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart' show showToast;
import 'font_download_sheet.dart';

/// A font chosen in the picker: a built-in [font], or an installed or
/// imported [customFont] (drawn instead of [font] where it is on the device).
@immutable
class FontChoice {
  const FontChoice(this.font, [this.customFont]);
  final TextCardFont font;
  final CaptionFont? customFont;

  @override
  bool operator ==(Object other) => other is FontChoice && other.font == font && other.customFont == customFont;

  @override
  int get hashCode => Object.hash(font, customFont);
}

/// Opens the font picker for the caption written on photos ([showFontChoiceSheet]).
/// Returns [style] with the chosen font, or null when nothing was chosen.
Future<CaptionStyle?> showFontPickerSheet(BuildContext context, {required CaptionStyle style, required String platformId}) async {
  final choice = await showFontChoiceSheet(context, current: FontChoice(style.font, style.customFont), platformId: platformId);
  if (choice == null) return null;
  final custom = choice.customFont;
  return custom == null ? style.copyWith(font: choice.font, clearCustomFont: true) : style.copyWith(customFont: custom);
}

/// Opens the font picker: the built-in fonts, the fonts the user imported and
/// the fonts installed on this computer, each name drawn in its own font,
/// with a search field and "Import a font file…". Used for the caption on
/// photos and (1.3.1) for text cards and their blocks. Returns the choice, or
/// null when nothing was chosen. [platformId] is the network whose own font
/// [TextCardFont.platform] stands for.
Future<FontChoice?> showFontChoiceSheet(BuildContext context,
    {required FontChoice current, required String platformId, String title = 'Caption font'}) {
  final sheet = FontPickerSheet(current: current, platformId: platformId, title: title);
  if (context.isCompact) {
    return showModalBottomSheet<FontChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.88, child: sheet),
    );
  }
  return showDialog<FontChoice>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760), child: sheet),
    ),
  );
}

/// One line of the picker: a section title, a built-in font or a font file.
sealed class _Entry {
  const _Entry();
}

class _Header extends _Entry {
  const _Header(this.title);
  final String title;
}

class _BuiltIn extends _Entry {
  const _BuiltIn(this.font);
  final TextCardFont font;
}

class _Custom extends _Entry {
  const _Custom(this.font, {required this.detail});
  final CaptionFont font;
  final String detail;
}

/// A font already downloaded from the font list.
class _Downloaded extends _Entry {
  const _Downloaded(this.downloaded);
  final DownloadedFont downloaded;
}

/// A font of the list, not on this device yet.
class _Catalog extends _Entry {
  const _Catalog(this.entry);
  final FontCatalogEntry entry;
}

/// The current style's font: from the list, not on this device.
class _Missing extends _Entry {
  const _Missing(this.font);
  final CaptionFont font;
}

/// The filters and what the list's state is, under the Download title.
class _CatalogStatus extends _Entry {
  const _CatalogStatus();
}

/// Scripts the Download section can be narrowed to: (subset, words).
const List<(String, String)> _scripts = [
  ('latin', 'Latin'),
  ('cyrillic', 'Cyrillic'),
  ('greek', 'Greek'),
  ('arabic', 'Arabic'),
  ('hebrew', 'Hebrew'),
  ('devanagari', 'Devanagari'),
  ('thai', 'Thai'),
  ('vietnamese', 'Vietnamese'),
  ('japanese', 'Japanese'),
  ('korean', 'Korean'),
  ('chinese-simplified', 'Chinese (simplified)'),
  ('chinese-traditional', 'Chinese (traditional)'),
];

/// Kinds the Download section can be narrowed to.
const List<String> _categories = ['sans-serif', 'serif', 'display', 'handwriting', 'monospace'];

/// A row's preview waits this long after it appears, and for scrolling to stop.
const Duration _previewDelay = Duration(milliseconds: 300);

class FontPickerSheet extends ConsumerStatefulWidget {
  const FontPickerSheet({super.key, required this.current, required this.platformId, this.title = 'Caption font'});
  final FontChoice current;
  final String platformId;
  final String title;

  @override
  ConsumerState<FontPickerSheet> createState() => _FontPickerSheetState();
}

class _FontPickerSheetState extends ConsumerState<FontPickerSheet> {
  final _search = TextEditingController();
  bool _importing = false;

  /// Only the Download section, so nobody has to scroll past every installed font.
  bool _onlyDownloads = false;
  String? _category;
  String? _script;
  final ValueNotifier<bool> _scrolling = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    // With the user's yes on file, opening the picker reads the list: the saved
    // copy unless it is old. Without it, this does nothing at all.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(fontDownloadsProvider.notifier).openCatalog();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _scrolling.dispose();
    super.dispose();
  }

  Future<void> _findMore() async {
    if (_onlyDownloads) {
      setState(() => _onlyDownloads = false);
      return;
    }
    if (!await ensureFontDownloadConsent(context, ref)) return;
    if (!mounted) return;
    setState(() => _onlyDownloads = true);
    await ref.read(fontDownloadsProvider.notifier).openCatalog();
  }

  Future<void> _download(String id, String family) async {
    final font = await downloadFontWithPrompts(context, ref, id: id, family: family);
    if (font != null && mounted) Navigator.pop(context, FontChoice(widget.current.font, font));
  }

  String _builtInLabel(TextCardFont f) => switch (f) {
        TextCardFont.original => 'Inter',
        TextCardFont.platform => "Each network's own",
        _ => f.label,
      };

  Future<void> _import() async {
    final storage = ref.read(servicesProvider).storage;
    setState(() => _importing = true);
    try {
      // Phones do not know font types by extension: any file, checked below.
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Import a font file',
        type: Env.isMobile ? FileType.any : FileType.custom,
        allowedExtensions: Env.isMobile ? null : const ['ttf', 'otf', 'ttc', 'otc'],
      );
      final f = files.firstOrNull;
      if (f == null) return;
      final font = await importCaptionFont(storage, f.name, await f.readAsBytes());
      ref.invalidate(importedFontsProvider);
      if (mounted) Navigator.pop(context, FontChoice(widget.current.font, font));
    } on FontImportException catch (e) {
      if (mounted) showToast(context, e.message, icon: Icons.info_outline_rounded);
    } on Object catch (e) {
      if (mounted) showToast(context, 'Could not import the font: $e', icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final query = _search.text.trim().toLowerCase();
    bool matches(String name) => query.isEmpty || name.toLowerCase().contains(query);
    final imported = ref.watch(importedFontsProvider).value ?? const <ImportedFont>[];
    final installed = ref.watch(installedFontsProvider);
    final catalog = installed.value ?? InstalledFontCatalog.empty;
    final notifier = ref.read(fontDownloadsProvider.notifier);
    final mode = ref.watch(settingsProvider.select((s) => s.fontDownloads));
    final downloads = ref.watch(fontDownloadsProvider);
    final canDownload = notifier.available && mode != FontDownloadMode.off;
    final allowed = notifier.available && mode == FontDownloadMode.on;
    final downloadedFonts = ref.watch(downloadedFontsProvider).value ?? const <DownloadedFont>[];
    final downloadedIds = {for (final f in downloadedFonts) f.id};

    final builtIn = [for (final f in TextCardFont.values) if (matches(_builtInLabel(f))) _BuiltIn(f)];
    final own = [for (final i in imported) if (matches(i.font.family)) _Custom(i.font, detail: 'Imported')];
    final fetched = [for (final f in downloadedFonts) if (matches(f.family)) _Downloaded(f)];
    final onDevice = [
      for (final e in catalog.families.entries)
        if (matches(e.key))
          _Custom(
            CaptionFont(family: e.key, path: e.value.first.path),
            detail: e.value.length == 1 ? '1 style' : '${e.value.length} styles',
          ),
    ];
    final offered = !allowed
        ? const <_Catalog>[]
        : [
            for (final e in downloads.catalog?.search(query, category: _category, subset: _script) ?? const <FontCatalogEntry>[])
              if (!downloadedIds.contains(e.id)) _Catalog(e),
          ];

    final current = widget.current.customFont;
    final currentSource = current?.source;
    final currentMissing = current != null && currentSource != null && canDownload && !downloadedIds.contains(currentSource.id) && ref.watch(captionFontReadyProvider(current)).value == false;
    final entries = <_Entry>[
      if (currentMissing) ...[const _Header('Not on this device'), _Missing(current)],
      if (!_onlyDownloads) ...[
        if (builtIn.isNotEmpty) ...[const _Header('Built in'), ...builtIn],
        if (own.isNotEmpty) ...[const _Header('Imported'), ...own],
        if (fetched.isNotEmpty) ...[const _Header('Downloaded'), ...fetched],
        if (onDevice.isNotEmpty) ...[const _Header('On this device'), ...onDevice],
      ],
      if (allowed) ...[const _Header('Download'), const _CatalogStatus(), ...offered],
    ];

    bool selected(_Entry e) => switch (e) {
          _BuiltIn(:final font) => current == null && widget.current.font == font,
          _Custom(:final font) => current != null && current.family.toLowerCase() == font.family.toLowerCase(),
          _Downloaded(:final downloaded) => current != null && current.family.toLowerCase() == downloaded.family.toLowerCase(),
          _Header() || _Catalog() || _Missing() || _CatalogStatus() => false,
        };

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.lg, Space.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title, style: context.text.headlineSmall),
          const SizedBox(height: 2),
          Text(
            Env.isDesktop
                ? 'The built-in fonts, the fonts installed on this computer, or a font file you import${canDownload ? ' or download' : ''}.'
                : 'The built-in fonts, or a font file you import (.ttf or .otf)${canDownload ? ' or download' : ''}.',
            style: context.text.bodySmall,
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.sm, Space.xxl, Space.sm),
        child: Row(children: [
          Expanded(
            child: TextField(
              key: const Key('font-search'),
              controller: _search,
              autofocus: Env.isDesktop,
              decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search_rounded, size: 18), hintText: 'Search fonts'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: Space.sm),
          OutlinedButton.icon(
            key: const Key('font-import'),
            onPressed: _importing ? null : _import,
            icon: const Icon(Icons.upload_file_rounded, size: 18),
            label: Text(_importing ? 'Importing…' : (context.isCompact ? 'Import…' : 'Import a font file…')),
          ),
        ]),
      ),
      if (canDownload)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('font-find-more'),
              onPressed: _findMore,
              icon: Icon(_onlyDownloads ? Icons.list_rounded : Icons.travel_explore_rounded, size: 18),
              label: Text(_onlyDownloads ? 'Show all my fonts' : 'Find more fonts'),
            ),
          ),
        ),
      if (installed.isLoading && Env.isDesktop)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
          child: Text('Looking for installed fonts…', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
        ),
      Flexible(
        child: entries.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(Space.xxl),
                child: Text('No font matches “${_search.text.trim()}”.', textAlign: TextAlign.center, style: context.text.bodyMedium),
              )
            : NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n is ScrollStartNotification) _scrolling.value = true;
                  if (n is ScrollEndNotification) _scrolling.value = false;
                  return false;
                },
                child: ListView.builder(
                  // Only the rows on screen are built, so only their fonts load.
                  padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
                  itemCount: entries.length,
                  itemBuilder: (context, i) => switch (entries[i]) {
                    _Header(:final title) => Padding(
                        padding: const EdgeInsets.fromLTRB(Space.sm, Space.lg, Space.sm, Space.xs),
                        child: Text(title, style: context.text.titleSmall?.copyWith(color: nf.textMuted)),
                      ),
                    final _BuiltIn e => _FontRow(
                        label: _builtInLabel(e.font),
                        style: _builtInStyle(e.font.resolve(widget.platformId)),
                        detail: e.font == TextCardFont.platform ? 'TikTok Sans on TikTok, Instagram Sans on Instagram' : null,
                        selected: selected(e),
                        onTap: () => Navigator.pop(context, FontChoice(e.font)),
                      ),
                    final _Custom e => _CustomFontRow(
                        font: e.font,
                        detail: e.detail,
                        selected: selected(e),
                        onTap: () => Navigator.pop(context, FontChoice(widget.current.font, e.font)),
                      ),
                    final _Downloaded e => _CustomFontRow(
                        font: captionFontOf(e.downloaded),
                        detail: '${fontLicenseLabel(e.downloaded.license)} · ${e.downloaded.weights.length == 1 ? '1 weight' : '${e.downloaded.weights.length} weights'}',
                        selected: selected(e),
                        onTap: () => Navigator.pop(context, FontChoice(widget.current.font, captionFontOf(e.downloaded))),
                        trailing: _DownloadedFontMenu(font: e.downloaded, canDownload: allowed),
                      ),
                    final _Catalog e => _CatalogFontRow(
                        key: ValueKey('font-catalog-${e.entry.id}'),
                        entry: e.entry,
                        scrolling: _scrolling,
                        onTap: () => _download(e.entry.id, e.entry.family),
                      ),
                    final _Missing e => _MissingFontRow(
                        font: e.font,
                        onTap: () => _download(e.font.source!.id, e.font.family),
                      ),
                    _CatalogStatus() => _CatalogStatusRow(
                        category: _category,
                        script: _script,
                        onCategory: (c) => setState(() => _category = c),
                        onScript: (s) => setState(() => _script = s),
                        empty: downloads.catalog != null && offered.isEmpty,
                      ),
                  },
                ),
              ),
      ),
      Divider(height: 1, color: nf.border),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.md, Space.xxl, Space.lg),
        child: Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
      ),
    ]);
  }

  static TextStyle _builtInStyle(TextCardFont f) =>
      TextStyle(fontFamily: f.family, fontFamilyFallback: f.fallback, fontWeight: f.weight, fontVariations: f.variations);
}

/// A font file's row: its name drawn in its own font once that is loaded
/// (watching [captionFontReadyProvider] starts the loading), in the
/// interface's font until then.
class _CustomFontRow extends ConsumerWidget {
  const _CustomFontRow({required this.font, required this.detail, required this.selected, required this.onTap, this.trailing});
  final CaptionFont font;
  final String detail;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(captionFontReadyProvider(font));
    final loaded = ready.value ?? false;
    return _FontRow(
      label: font.family,
      style: loaded ? TextStyle(fontFamily: font.alias, fontFamilyFallback: [...captionFontSubsetAliases(font), Fonts.body]) : const TextStyle(fontFamily: Fonts.body),
      detail: ready.hasValue && !loaded ? '$detail · cannot be read' : detail,
      selected: selected,
      onTap: onTap,
      trailing: trailing,
    );
  }
}

/// The actions on a downloaded font's row.
class _DownloadedFontMenu extends ConsumerWidget {
  const _DownloadedFontMenu({required this.font, required this.canDownload});
  final DownloadedFont font;
  final bool canDownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(fontDownloadsProvider.select((s) => s.installs[font.id]));
    if (progress != null) {
      return Padding(
        padding: const EdgeInsets.all(Space.md),
        child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, value: progress.fraction)),
      );
    }
    return PopupMenuButton<String>(
      key: Key('font-menu-${font.id}'),
      tooltip: 'More about ${font.family}',
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      onSelected: (action) async {
        switch (action) {
          case 'weights':
            await showAddFontWeightsDialog(context, ref, font);
          case 'licence':
            await showFontLicenseDialog(context, ref, font);
          case 'remove':
            await ref.read(fontDownloadsProvider.notifier).remove(font);
        }
      },
      itemBuilder: (_) => [
        if (canDownload) const PopupMenuItem(value: 'weights', child: Text('Add more weights…')),
        const PopupMenuItem(value: 'licence', child: Text('Licence')),
        const PopupMenuItem(value: 'remove', child: Text('Remove from this device')),
      ],
    );
  }
}

/// A font of the list. Its name is drawn in its own font once a small sample
/// file is here, which is asked for only if the row stays on screen with the
/// list at rest ([_previewDelay]): a fast scroll loads nothing.
class _CatalogFontRow extends ConsumerStatefulWidget {
  const _CatalogFontRow({super.key, required this.entry, required this.scrolling, required this.onTap});
  final FontCatalogEntry entry;
  final ValueListenable<bool> scrolling;
  final VoidCallback onTap;

  @override
  ConsumerState<_CatalogFontRow> createState() => _CatalogFontRowState();
}

class _CatalogFontRowState extends ConsumerState<_CatalogFontRow> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  void _arm() {
    _timer = Timer(_previewDelay, () {
      if (!mounted) return;
      if (widget.scrolling.value) {
        _arm();
      } else {
        ref.read(fontDownloadsProvider.notifier).requestPreview(widget.entry);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final e = widget.entry;
    final alias = ref.watch(fontDownloadsProvider.select((s) => s.previews[e.id]));
    final progress = ref.watch(fontDownloadsProvider.select((s) => s.installs[e.id]));
    return _FontRow(
      label: e.family,
      style: alias == null ? const TextStyle(fontFamily: Fonts.body) : TextStyle(fontFamily: alias, fontFamilyFallback: const [Fonts.body]),
      detail: progress == null
          ? '${fontLicenseLabel(e.license)} · ${fontCategoryLabel(e.category)}'
          : (progress.filesTotal == 0 ? 'Starting…' : 'Downloading ${progress.filesDone} of ${progress.filesTotal} files'),
      semanticsLabel: 'Download ${e.family}, ${fontLicenseLabel(e.license)}, ${fontCategoryLabel(e.category)}',
      selected: false,
      onTap: progress == null ? widget.onTap : () {},
      trailing: progress == null
          ? Padding(
              padding: const EdgeInsets.all(Space.md),
              child: Icon(Icons.download_rounded, size: 20, color: nf.textMuted),
            )
          : IconButton(
              key: Key('font-cancel-${e.id}'),
              tooltip: 'Stop downloading',
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () => ref.read(fontDownloadsProvider.notifier).cancelInstall(e.id),
            ),
    );
  }
}

/// The style's font, from the list and not on this device: one tap to fetch it.
class _MissingFontRow extends ConsumerWidget {
  const _MissingFontRow({required this.font, required this.onTap});
  final CaptionFont font;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(fontDownloadsProvider.select((s) => s.installs.containsKey(font.source!.id)));
    return _FontRow(
      key: const Key('font-picker-missing'),
      label: font.family,
      style: const TextStyle(fontFamily: Fonts.body),
      detail: busy ? 'Downloading…' : fontDownloadLabel(font),
      selected: false,
      onTap: busy ? () {} : onTap,
      trailing: const Padding(padding: EdgeInsets.all(Space.md), child: Icon(Icons.download_rounded, size: 20)),
    );
  }
}

/// Under the Download title: what the list's state is, and the two filters.
class _CatalogStatusRow extends ConsumerWidget {
  const _CatalogStatusRow({required this.category, required this.script, required this.onCategory, required this.onScript, required this.empty});
  final String? category;
  final String? script;
  final ValueChanged<String?> onCategory;
  final ValueChanged<String?> onScript;
  final bool empty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final loading = ref.watch(fontDownloadsProvider.select((s) => s.loadingCatalog));
    final problem = ref.watch(fontDownloadsProvider.select((s) => s.catalogProblem));
    final hasList = ref.watch(fontDownloadsProvider.select((s) => s.catalog != null));
    final small = context.text.bodySmall?.copyWith(color: nf.textFaint);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Free fonts from Fontsource, with open licences. Tap one to download it.', style: small),
        if (loading) Padding(padding: const EdgeInsets.only(top: Space.xs), child: Text('Getting the font list…', style: small)),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Row(children: [
              Expanded(child: Text(problem, key: const Key('font-catalog-problem'), style: context.text.bodySmall?.copyWith(color: nf.warning))),
              TextButton(
                key: const Key('font-catalog-retry'),
                onPressed: loading ? null : () => ref.read(fontDownloadsProvider.notifier).openCatalog(refresh: true),
                child: const Text('Try again'),
              ),
            ]),
          ),
        if (hasList)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
              _FilterMenu(
                filterKey: const Key('font-filter-category'),
                label: category == null ? 'Any kind' : fontCategoryLabel(category!),
                options: [for (final c in _categories) (c, fontCategoryLabel(c))],
                anyLabel: 'Any kind',
                onSelected: onCategory,
              ),
              _FilterMenu(
                filterKey: const Key('font-filter-script'),
                label: script == null ? 'Any script' : _scripts.firstWhere((s) => s.$1 == script).$2,
                options: _scripts,
                anyLabel: 'Any script',
                onSelected: onScript,
              ),
            ]),
          ),
        if (empty) Padding(padding: const EdgeInsets.only(top: Space.sm), child: Text('No font in the list matches.', style: small)),
      ]),
    );
  }
}

class _FilterMenu extends StatelessWidget {
  const _FilterMenu({required this.filterKey, required this.label, required this.options, required this.anyLabel, required this.onSelected});
  final Key filterKey;
  final String label;
  final List<(String, String)> options;
  final String anyLabel;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        key: filterKey,
        tooltip: label,
        position: PopupMenuPosition.under,
        // '' stands for no filter: a menu cannot select null.
        onSelected: (v) => onSelected(v.isEmpty ? null : v),
        itemBuilder: (_) => [
          PopupMenuItem(value: '', child: Text(anyLabel)),
          for (final (value, words) in options) PopupMenuItem(value: value, child: Text(words)),
        ],
        child: Chip(label: Text(label), avatar: const Icon(Icons.arrow_drop_down_rounded, size: 18)),
      );
}

class _FontRow extends StatelessWidget {
  const _FontRow({super.key, required this.label, required this.style, required this.selected, required this.onTap, this.detail, this.trailing, this.semanticsLabel});
  final String label;
  final TextStyle style;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  /// Beside the row, not part of what it does when tapped.
  final Widget? trailing;

  /// What a screen reader says, when it is more than the name.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final row = Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel ?? label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: Radii.rSm,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.sm),
          decoration: BoxDecoration(color: selected ? nf.accentSoft : null, borderRadius: Radii.rSm),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style.copyWith(fontSize: 20, height: 1.25, color: nf.text)),
                if (detail != null) Text(detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
              ]),
            ),
            if (selected) Icon(Icons.check_rounded, size: 20, color: nf.accent),
          ]),
        ),
      ),
    );
    if (trailing == null) return row;
    return Row(children: [Expanded(child: row), trailing!]);
  }
}
