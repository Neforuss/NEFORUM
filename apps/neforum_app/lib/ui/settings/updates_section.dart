import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../platform/env.dart';
import '../../platform/update_check.dart';
import '../../state/providers.dart';
import '../../state/update_checks.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart';
import '../activity/time_format.dart';
import 'setting_row.dart';

/// Exactly what an update check sends and receives, in the one-time question
/// and in Settings > Updates.
const String kUpdateCheckDisclosure =
    'NEFORUM downloads one small file from neforus.com (latest.json) with the newest version number and its notes, '
    'and compares it with this version on your device. The request carries no version, device, operating system, '
    'account or identifier, and no cookies; like any web request, it shows neforus.com your IP address. '
    'Nothing is downloaded or installed by itself.';

/// Asks once whether NEFORUM may check for updates (first start, and the
/// first start after an update from 1.2). Closing the dialog counts as No.
Future<void> askAboutUpdateChecks(BuildContext context, WidgetRef ref) async {
  final automatic = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.system_update_alt_rounded),
      title: const Text('Check for updates?'),
      content: const SingleChildScrollView(
        child: Text('NEFORUM can look for a newer version once a day, at a random time while it runs.\n\n'
            '$kUpdateCheckDisclosure\n\nYou can change this any time in Settings > Updates.'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text("Don't check")),
        FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Check once a day')),
      ],
    ),
  );
  await ref.read(updateCheckProvider.notifier).setMode(automatic == true ? UpdateCheckMode.automatic : UpdateCheckMode.off);
}

/// Opens the download page in the browser.
Future<void> openDownloadPage() => launchUrl(Uri.parse(kDownloadPageUrl), mode: LaunchMode.externalApplication);

class UpdateSettingsSection extends ConsumerWidget {
  const UpdateSettingsSection({super.key});

  Future<void> _checkNow(BuildContext context, WidgetRef ref) async {
    try {
      final latest = await ref.read(updateCheckProvider.notifier).checkNow();
      if (!context.mounted || latest == null) return;
      showToast(
        context,
        latest.isNewerThan(kAppVersion) ? 'NEFORUM ${latest.version} is available' : 'NEFORUM is up to date',
        icon: latest.isNewerThan(kAppVersion) ? Icons.system_update_alt_rounded : Icons.check_rounded,
      );
    } on Object catch (e) {
      if (context.mounted) showToast(context, 'Could not check for updates: $e', icon: Icons.error_outline_rounded);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final status = ref.watch(updateCheckProvider);
    final available = status.available;
    final checked = s.updateCheckedAt;
    return SettingsSection(title: 'Updates', icon: Icons.system_update_alt_rounded, subtitle: 'NEFORUM never installs anything by itself.', children: [
      SettingSwitch(
        title: 'Check for updates automatically',
        description: 'At most once a day, at a random time while NEFORUM runs. $kUpdateCheckDisclosure',
        value: s.updateCheck == UpdateCheckMode.automatic,
        onChanged: (v) => ref.read(updateCheckProvider.notifier).setMode(v ? UpdateCheckMode.automatic : UpdateCheckMode.off),
      ),
      SettingRow(
        title: available == null ? 'Version $kAppVersion' : 'NEFORUM ${available.version} is available',
        description: checked == null ? 'Never checked.' : 'Last checked ${TimeFormatting.from(s, context).moment(checked)}.',
        stackOnCompact: true,
        trailing: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          if (available != null)
            FilledButton.icon(onPressed: openDownloadPage, icon: const Icon(Icons.open_in_new_rounded, size: 18), label: const Text('Download')),
          OutlinedButton(
            onPressed: status.checking ? null : () => _checkNow(context, ref),
            child: Text(status.checking ? 'Checking…' : 'Check now'),
          ),
        ]),
      ),
    ]);
  }
}

/// A newer version is out: over every screen until closed. A critical one
/// (a security fix, lost posts) is warning-coloured and comes back at every
/// start until NEFORUM is updated.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final status = ref.watch(updateCheckProvider);
    final release = status.available;
    if (release == null || !status.showsBanner(settings) || ref.watch(isDemoProvider)) return const SizedBox.shrink();
    final nf = context.nf;
    final critical = release.critical;
    final notes = release.notes;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
      decoration: BoxDecoration(
        color: critical ? nf.warningSoft : nf.accentSoft,
        border: Border(bottom: BorderSide(color: critical ? nf.warning : nf.border, width: critical ? 2 : 1)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(critical ? Icons.warning_amber_rounded : Icons.system_update_alt_rounded, size: 18, color: critical ? nf.warning : nf.accent),
        ),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              critical ? 'Important update: NEFORUM ${release.version} fixes a serious problem' : 'NEFORUM ${release.version} is available',
              style: context.text.labelLarge?.copyWith(color: nf.text, fontWeight: FontWeight.w700),
            ),
            if (notes.isNotEmpty)
              Text(notes, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.text)),
          ]),
        ),
        const SizedBox(width: Space.sm),
        Wrap(spacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (notes.isNotEmpty)
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (c) => AlertDialog(
                  title: Text('NEFORUM ${release.version}'),
                  content: SingleChildScrollView(child: SelectableText(notes)),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Close')),
                    FilledButton(onPressed: openDownloadPage, child: const Text('Download')),
                  ],
                ),
              ),
              child: const Text('Notes'),
            ),
          FilledButton(onPressed: openDownloadPage, child: const Text('Download')),
          IconButton(
            tooltip: critical ? 'Hide until the next start' : 'Hide for this version',
            onPressed: () => ref.read(updateCheckProvider.notifier).dismiss(),
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ]),
      ]),
    );
  }
}
