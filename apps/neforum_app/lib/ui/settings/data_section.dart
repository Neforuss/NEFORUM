import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../media/caption_fonts.dart' show downloadedFontsProvider;
import '../../media/font_catalog.dart';
import '../../platform/env.dart';
import '../../platform/media_library.dart';
import '../../state/composer.dart';
import '../../state/composer_draft.dart';
import '../../state/font_downloads.dart';
import '../../state/media_host_config.dart';
import '../../state/providers.dart';
import '../../state/publish_result_notices.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import '../compose/font_download_sheet.dart' show kFontDownloadDisclosure;
import 'move_device.dart';
import 'setting_row.dart';

class DataSettingsSection extends ConsumerStatefulWidget {
  const DataSettingsSection({super.key});

  @override
  ConsumerState<DataSettingsSection> createState() => _DataSettingsSectionState();
}

class _DataSettingsSectionState extends ConsumerState<DataSettingsSection> {
  int? _mediaBytes;

  @override
  void initState() {
    super.initState();
    ref.read(servicesProvider).media.totalBytes().then((v) {
      if (mounted) setState(() => _mediaBytes = v);
    });
  }

  Future<void> _export() async {
    final s = ref.read(servicesProvider);
    final data = {
      'app': 'NEFORUM',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'note': 'Accounts are exported without keys or tokens.',
      'accounts': [for (final a in await s.accounts.all()) a.toJson()],
      'posts': [for (final p in await s.posts.all()) p.toJson()],
    };
    final json = const JsonEncoder.withIndent('  ').convert(data);
    final bytes = Uint8List.fromList(utf8.encode(json));
    if (!mounted) return;
    if (Env.isWeb) {
      await Clipboard.setData(ClipboardData(text: json));
      if (mounted) showToast(context, 'Export copied to the clipboard', icon: Icons.check_rounded);
    } else if (Env.isMobile) {
      await SharePlus.instance.share(ShareParams(files: [XFile.fromData(bytes, mimeType: 'application/json', name: 'neforum-export.json')], fileNameOverrides: const ['neforum-export.json']));
    } else {
      final where = await FilePicker.saveFile(dialogTitle: 'Export NEFORUM data', fileName: 'neforum-export.json', bytes: bytes);
      if (where != null && mounted) showToast(context, 'Exported', icon: Icons.check_rounded);
    }
  }

  Future<void> _deleteAll() async {
    final ok = await confirmDialog(
      context,
      title: 'Delete everything?',
      message: 'This removes every account, key, post, draft, scheduled post and downloaded font from this device. Posts already published stay online. This cannot be undone.',
      confirmLabel: 'Delete everything',
      destructive: true,
    );
    if (!ok) return;
    final s = ref.read(servicesProvider);
    // Copies the platforms hold would otherwise still go out.
    var stillHeld = 0;
    for (final p in await s.posts.all()) {
      if (!p.hasHeldTargets) continue;
      stillHeld += (await s.publisher().releaseSchedules(p.id)).failed.length;
    }
    for (final a in await s.accounts.all()) {
      await s.secrets.delete(a.id);
      await s.accounts.delete(a.id);
    }
    await s.signInStatusStore.clear();
    await s.signInWarnings.run();
    await s.signInWarningStore.clear();
    // The post being written goes too, then every post with its
    // notifications, then any media file left over.
    ref.read(composerProvider.notifier).reset();
    await ref.read(composerDraftKeeperProvider)?.keep(ref.read(composerProvider));
    await s.discardPosts(await s.posts.all());
    try {
      await s.deleteUnreferencedMedia(grace: Duration.zero);
    } on Object catch (e) {
      debugPrint('Some media files were kept: $e');
    }
    // Media host keys are keys too: remove both hosts and their secrets.
    var next = await clearMediaHost(ref.read(settingsProvider), s.secrets, slot: MediaHostSlot.fallback);
    next = await clearMediaHost(next, s.secrets);
    await ref.read(settingsProvider.notifier).update((_) => next.copyWith(
          defaultTargetIds: const [],
          emojiRecents: const [],
          emojiSkinTone: 0,
          characterFavourites: const [],
          defaultPlacements: const {},
        ));
    await s.refreshMediaHost();
    // Paired browsers' tokens are keys too (the demo shares the real ones).
    if (!s.demo) await s.browserBridge.forgetAll();
    // Downloaded fonts, their saved list and previews, and the yes to fetching them.
    await ref.read(fontDownloadsProvider.notifier).deleteAll();
    // What finished while nobody was watching names networks.
    await UnseenResults(s.storage).deleteAll();
    if (mounted) {
      showToast(
        context,
        stillHeld > 0 ? 'Everything was deleted. $stillHeld scheduled ${stillHeld == 1 ? 'copy' : 'copies'} could not be removed from the platforms; delete ${stillHeld == 1 ? 'it' : 'them'} there.' : 'Everything was deleted',
        icon: Icons.delete_outline_rounded,
      );
      setState(() => _mediaBytes = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final dir = ref.read(servicesProvider).storage.dataDir;
    return SettingsSection(title: 'Data & privacy', icon: Icons.shield_outlined, children: [
      SettingRow(
        title: 'Everything stays on this device',
        description: 'NEFORUM has no server, no account and no analytics. Your keys and tokens live in the system keychain. Posts go straight from this device to each network. '
            'With Sync on, one encrypted file also sits in the storage you chose.',
      ),
      SettingRow(
        title: 'Data folder',
        below: NfWell(
          padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.xs, Space.xs),
          child: Row(children: [
            Expanded(child: SelectableText(dir ?? 'In memory (web preview)', style: monoStyle(context, size: 12, color: nf.text))),
            if (dir != null)
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_rounded, size: 18),
                onPressed: () => Clipboard.setData(ClipboardData(text: dir)),
              ),
          ]),
        ),
      ),
      SettingRow(title: 'Media library', description: _mediaBytes == null ? 'Measuring…' : '${formatBytes(_mediaBytes!)} of attached photos and videos'),
      if (ref.read(fontDownloadsProvider.notifier).available) const _FontDownloadsRow(),
      const MoveDeviceRows(),
      SettingRow(
        title: 'Export posts',
        description: 'A readable JSON file with your posts and account list, without keys (for your records; it cannot be imported).',
        trailing: OutlinedButton.icon(onPressed: _export, icon: const Icon(Icons.download_rounded, size: 18), label: const Text('Export')),
        stackOnCompact: true,
      ),
      SettingRow(
        title: 'Delete everything',
        description: 'Removes all accounts, keys, posts and downloaded fonts from this device.',
        trailing: OutlinedButton(
          onPressed: _deleteAll,
          style: OutlinedButton.styleFrom(foregroundColor: nf.danger, side: BorderSide(color: nf.danger.withValues(alpha: 0.5))),
          child: const Text('Delete…'),
        ),
        stackOnCompact: true,
      ),
    ]);
  }
}

/// Whether this device may contact the font services, and what it holds.
class _FontDownloadsRow extends ConsumerWidget {
  const _FontDownloadsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s.fontDownloads));
    final fonts = ref.watch(downloadedFontsProvider).value ?? const <DownloadedFont>[];
    final bytes = fonts.fold<int>(0, (a, f) => a + f.totalBytes);
    final held = fonts.isEmpty ? 'No fonts downloaded.' : '${fonts.length == 1 ? '1 font' : '${fonts.length} fonts'} downloaded, ${formatBytes(bytes)}.';
    return SettingSwitch(
      key: const Key('font-downloads-setting'),
      title: 'Find and download fonts',
      description: '$kFontDownloadDisclosure\n$held Fonts already downloaded keep working with this off.',
      value: mode == FontDownloadMode.on,
      onChanged: (v) => ref.read(fontDownloadsProvider.notifier).setMode(v ? FontDownloadMode.on : FontDownloadMode.off),
    );
  }
}
