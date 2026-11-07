import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../media/caption_fonts.dart';
import '../../media/font_catalog.dart';
import '../../platform/media_library.dart' show formatBytes;
import '../../state/font_downloads.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart' show showToast;

/// Exactly who is contacted and what they learn, in the one-time question and
/// in Settings > Data and privacy.
const String kFontDownloadDisclosure =
    'NEFORUM can find free fonts in a public list and download them to this device. To do that it contacts api.fontsource.org and cdn.jsdelivr.net. '
    'They see your IP address and the font names you look up, never your posts, accounts or keys. No key or account is needed. '
    'A font stays on this device with its licence, and works with no network from then on.';

/// Asks once whether this device may contact the font services. True when it
/// may. "Not now" decides nothing: the question comes back next time, and
/// until then nothing goes out.
Future<bool> ensureFontDownloadConsent(BuildContext context, WidgetRef ref) async {
  final notifier = ref.read(fontDownloadsProvider.notifier);
  if (!notifier.available) return false;
  switch (ref.read(settingsProvider).fontDownloads) {
    case FontDownloadMode.on:
      return true;
    case FontDownloadMode.off:
      return false;
    case FontDownloadMode.ask:
      break;
  }
  final allow = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.font_download_outlined),
      title: const Text('Find more fonts?'),
      content: const SingleChildScrollView(
        child: Text('$kFontDownloadDisclosure\n\nFonts in the list have open licences. You can turn this off any time in Settings > Data and privacy.'),
      ),
      actions: [
        TextButton(key: const Key('font-consent-not-now'), onPressed: () => Navigator.of(c).pop(false), child: const Text('Not now')),
        FilledButton(key: const Key('font-consent-allow'), onPressed: () => Navigator.of(c).pop(true), child: const Text('Allow')),
      ],
    ),
  );
  if (allow != true) return false;
  await notifier.setMode(FontDownloadMode.on);
  return true;
}

/// Words on a button that downloads [font]: its size when the device that chose
/// it recorded one. Nothing goes out to work this out.
String fontDownloadLabel(CaptionFont font) {
  final size = font.source?.sizeBytes;
  return size == null ? 'Download ${font.family}' : 'Download ${font.family} (${formatBytes(size)})';
}

/// Whether [font] can be offered for download on this device.
bool canOfferFontDownload(WidgetRef ref, CaptionFont? font) =>
    font?.source != null && ref.read(fontDownloadsProvider.notifier).available && ref.read(settingsProvider).fontDownloads != FontDownloadMode.off;

/// The whole of a one-tap download: the question if it was never asked, the
/// size if it is a big one, the download, and any problem in plain words.
/// Returns the font when it is ready to use.
Future<CaptionFont?> downloadFontWithPrompts(BuildContext context, WidgetRef ref, {required String id, required String family}) async {
  // Read now: the widget behind [ref] may be gone when the download ends.
  final notifier = ref.read(fontDownloadsProvider.notifier);
  if (!await ensureFontDownloadConsent(context, ref)) return null;
  try {
    final plan = await notifier.plan(id);
    if (plan.isLarge) {
      if (!context.mounted) return null;
      final known = plan.knownLargeBytes;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Download ${plan.detail.family}?'),
          content: Text(known == null
              ? '${plan.detail.family} covers a large script, so this download can be well over ${formatBytes(kLargeFontBytes)}.'
              : '${plan.detail.family} covers a large script, so this download is about ${formatBytes(known)}.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
            FilledButton(key: const Key('font-large-confirm'), onPressed: () => Navigator.of(c).pop(true), child: const Text('Download')),
          ],
        ),
      );
      if (ok != true) return null;
    }
    final font = await notifier.install(plan);
    if (font != null && context.mounted) showToast(context, '${font.family} is ready to use', icon: Icons.check_rounded);
    return font;
  } on FontDownloadException catch (e) {
    if (context.mounted) showToast(context, e.message, icon: Icons.error_outline_rounded);
    return null;
  }
}

/// Lets the user pick more weights of [font] than the two an install takes.
Future<void> showAddFontWeightsDialog(BuildContext context, WidgetRef ref, DownloadedFont font) async {
  final notifier = ref.read(fontDownloadsProvider.notifier);
  final FontFamilyDetail detail;
  try {
    detail = await notifier.detail(font.id);
  } on FontDownloadException catch (e) {
    if (context.mounted) showToast(context, e.message, icon: Icons.error_outline_rounded);
    return;
  }
  if (!context.mounted) return;
  final have = font.weights.toSet();
  final more = [for (final w in detail.weights) if (!have.contains(w)) w];
  if (more.isEmpty) {
    showToast(context, '${font.family} has no more weights', icon: Icons.info_outline_rounded);
    return;
  }
  final chosen = await showDialog<Set<int>>(context: context, builder: (_) => _AddWeightsDialog(family: font.family, weights: more));
  if (chosen == null || chosen.isEmpty) return;
  try {
    await notifier.addWeights(font, detail, chosen);
    if (context.mounted) showToast(context, '${font.family} has more weights now', icon: Icons.check_rounded);
  } on FontDownloadException catch (e) {
    if (context.mounted) showToast(context, e.message, icon: Icons.error_outline_rounded);
  }
}

class _AddWeightsDialog extends StatefulWidget {
  const _AddWeightsDialog({required this.family, required this.weights});
  final String family;
  final List<int> weights;

  @override
  State<_AddWeightsDialog> createState() => _AddWeightsDialogState();
}

class _AddWeightsDialogState extends State<_AddWeightsDialog> {
  final Set<int> _chosen = {};

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('More weights of ${widget.family}'),
        content: SizedBox(
          width: 320,
          child: ListView(shrinkWrap: true, children: [
            for (final w in widget.weights)
              CheckboxListTile(
                key: Key('font-weight-$w'),
                value: _chosen.contains(w),
                title: Text('$w'),
                contentPadding: EdgeInsets.zero,
                onChanged: (v) => setState(() => v == true ? _chosen.add(w) : _chosen.remove(w)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            key: const Key('font-weights-add'),
            onPressed: _chosen.isEmpty ? null : () => Navigator.of(context).pop(_chosen),
            child: const Text('Download'),
          ),
        ],
      );
}

/// Shows the licence text kept with [font].
Future<void> showFontLicenseDialog(BuildContext context, WidgetRef ref, DownloadedFont font) async {
  final text = await ref.read(fontDownloadsProvider.notifier).licenseOf(font);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('${font.family}: ${fontLicenseLabel(font.license)}'),
      content: SizedBox(width: 480, child: SingleChildScrollView(child: SelectableText(text ?? 'The licence text could not be read.'))),
      actions: [TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Close'))],
    ),
  );
}

/// One tap to fetch a font this device is missing, under the line that says it
/// is missing. Nothing where it cannot be offered: downloads turned off, or a
/// font that did not come from the font list.
class MissingFontDownloadButton extends ConsumerWidget {
  const MissingFontDownloadButton({super.key, required this.font});
  final CaptionFont font;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(settingsProvider.select((s) => s.fontDownloads));
    final source = font.source;
    if (source == null || !canOfferFontDownload(ref, font)) return const SizedBox.shrink();
    final busy =ref.watch(fontDownloadsProvider.select((s) => s.installs.containsKey(source.id)));
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          key: const Key('font-missing-download'),
          onPressed: busy ? null : () => downloadFontWithPrompts(context, ref, id: source.id, family: font.family),
          icon: const Icon(Icons.download_rounded, size: 18),
          label: Text(busy ? 'Downloading ${font.family}…' : fontDownloadLabel(font), overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}
