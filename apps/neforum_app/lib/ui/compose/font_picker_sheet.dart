import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../media/caption_fonts.dart';
import '../../media/caption_style.dart';
import '../../media/text_card.dart';
import '../../platform/env.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart' show showToast;

/// Opens the font picker for the caption written on photos: the built-in
/// fonts, the fonts the user imported and the fonts installed on this
/// computer, each name drawn in its own font, with a search field and
/// "Import a font file…". Returns [style] with the chosen font, or null when
/// nothing was chosen. [platformId] is the network whose own font
/// [TextCardFont.platform] stands for.
Future<CaptionStyle?> showFontPickerSheet(BuildContext context, {required CaptionStyle style, required String platformId}) {
  final sheet = FontPickerSheet(style: style, platformId: platformId);
  if (context.isCompact) {
    return showModalBottomSheet<CaptionStyle>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.88, child: sheet),
    );
  }
  return showDialog<CaptionStyle>(
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

class FontPickerSheet extends ConsumerStatefulWidget {
  const FontPickerSheet({super.key, required this.style, required this.platformId});
  final CaptionStyle style;
  final String platformId;

  @override
  ConsumerState<FontPickerSheet> createState() => _FontPickerSheetState();
}

class _FontPickerSheetState extends ConsumerState<FontPickerSheet> {
  final _search = TextEditingController();
  bool _importing = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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
      if (mounted) Navigator.pop(context, widget.style.copyWith(customFont: font));
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

    final builtIn = [for (final f in TextCardFont.values) if (matches(_builtInLabel(f))) _BuiltIn(f)];
    final own = [for (final i in imported) if (matches(i.font.family)) _Custom(i.font, detail: 'Imported')];
    final onDevice = [
      for (final e in catalog.families.entries)
        if (matches(e.key))
          _Custom(
            CaptionFont(family: e.key, path: e.value.first.path),
            detail: e.value.length == 1 ? '1 style' : '${e.value.length} styles',
          ),
    ];
    final entries = <_Entry>[
      if (builtIn.isNotEmpty) ...[const _Header('Built in'), ...builtIn],
      if (own.isNotEmpty) ...[const _Header('Imported'), ...own],
      if (onDevice.isNotEmpty) ...[const _Header('On this device'), ...onDevice],
    ];

    final current = widget.style.customFont;
    bool selected(_Entry e) => switch (e) {
          _BuiltIn(:final font) => current == null && widget.style.font == font,
          _Custom(:final font) => current != null && current.family.toLowerCase() == font.family.toLowerCase(),
          _Header() => false,
        };

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.lg, Space.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Caption font', style: context.text.headlineSmall),
          const SizedBox(height: 2),
          Text(
            Env.isDesktop
                ? 'The built-in fonts, the fonts installed on this computer, or a font file you import.'
                : 'The built-in fonts, or a font file you import (.ttf or .otf).',
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
            label: Text(_importing ? 'Importing…' : 'Import a font file…'),
          ),
        ]),
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
            : ListView.builder(
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
                      onTap: () => Navigator.pop(context, widget.style.copyWith(font: e.font, clearCustomFont: true)),
                    ),
                  final _Custom e => _CustomFontRow(
                      font: e.font,
                      detail: e.detail,
                      selected: selected(e),
                      onTap: () => Navigator.pop(context, widget.style.copyWith(customFont: e.font)),
                    ),
                },
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
  const _CustomFontRow({required this.font, required this.detail, required this.selected, required this.onTap});
  final CaptionFont font;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(captionFontReadyProvider(font));
    final loaded = ready.value ?? false;
    return _FontRow(
      label: font.family,
      style: loaded ? TextStyle(fontFamily: font.alias, fontFamilyFallback: const [Fonts.body]) : const TextStyle(fontFamily: Fonts.body),
      detail: ready.hasValue && !loaded ? '$detail · cannot be read' : detail,
      selected: selected,
      onTap: onTap,
    );
  }
}

class _FontRow extends StatelessWidget {
  const _FontRow({required this.label, required this.style, required this.selected, required this.onTap, this.detail});
  final String label;
  final TextStyle style;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
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
  }
}
