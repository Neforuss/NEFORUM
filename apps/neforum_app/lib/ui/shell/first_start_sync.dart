import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../platform/env.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/surfaces.dart';
import '../settings/move_device.dart';
import '../settings/sync_section.dart';

/// 1.4.4: the answers to "Do you already use NEFORUM on another device?".
enum SyncOfferChoice {
  /// Settings > Sync > Set up, on Google Drive, directly.
  googleDrive,

  /// The same, on a folder a cloud app syncs (the Files app on phones).
  folder,

  /// The same, on a WebDAV server.
  webdav,

  /// The same, on S3-compatible storage.
  s3,

  /// Settings > Data & privacy > Move to another device > Import.
  transferFile,

  /// "No, I'm new": nothing opens.
  newUser,
}

/// The kind of storage each sync shortcut opens Set up on.
SyncBackendKind? syncOfferStorage(SyncOfferChoice c) => switch (c) {
      SyncOfferChoice.googleDrive => SyncBackendKind.googleDrive,
      SyncOfferChoice.folder => SyncBackendKind.folder,
      SyncOfferChoice.webdav => SyncBackendKind.webdav,
      SyncOfferChoice.s3 => SyncBackendKind.s3,
      SyncOfferChoice.transferFile || SyncOfferChoice.newUser => null,
    };

/// Whether the first start asks about joining a sync: on a real workspace
/// that is a new install (no accounts, sync off) and that has not answered
/// yet. One answer is final on this install; Settings > Sync stays.
bool shouldOfferSyncAtFirstStart({
  required bool demo,
  required bool web,
  required bool syncOn,
  required bool hasAccounts,
  required DateTime? answeredAt,
}) =>
    !demo && !web && !syncOn && !hasAccounts && answeredAt == null;

/// Widget tests that start the whole app for something else turn this off
/// (test/flutter_test_config.dart), so the question does not cover their
/// screens; the question's own tests turn it back on.
@visibleForTesting
bool debugOfferSyncAtFirstStart = true;

/// 1.4.4: the first of the first-start questions, before notifications,
/// since it decides whether the accounts arrive from another device. A
/// shortcut opens its join flow and this returns once that flow closes, so
/// the next question never stacks on it. Any answer (closing it included)
/// is recorded when given: a NEFORUM closed on this screen asks again.
Future<void> offerSyncOnFirstStart(BuildContext context, WidgetRef ref) async {
  if (!debugOfferSyncAtFirstStart) return;
  if (ref.read(isDemoProvider) || Env.isWeb) return;
  final List<ConnectedAccount> accounts;
  try {
    // A slow read must not look like an empty workspace.
    accounts = await ref.read(accountsProvider.future);
  } on Object {
    return;
  }
  if (!context.mounted) return;
  final settings = ref.read(settingsProvider);
  if (!shouldOfferSyncAtFirstStart(
    demo: ref.read(isDemoProvider),
    web: Env.isWeb,
    syncOn: settings.syncOn,
    hasAccounts: accounts.isNotEmpty,
    answeredAt: settings.syncOfferAnsweredAt,
  )) {
    return;
  }
  final choice = await showSyncOffer(context) ?? SyncOfferChoice.newUser;
  final now = DateTime.now();
  await ref.read(settingsProvider.notifier).update((x) => x.copyWith(syncOfferAnsweredAt: now));
  if (!context.mounted) return;
  await openSyncOfferChoice(context, ref, choice);
}

/// Opens the join flow [choice] stands for, and returns when it closes.
Future<void> openSyncOfferChoice(BuildContext context, WidgetRef ref, SyncOfferChoice choice) async {
  final kind = syncOfferStorage(choice);
  if (kind != null) {
    await showDialog<void>(context: context, builder: (_) => SyncSetupDialog(only: kind));
  } else if (choice == SyncOfferChoice.transferFile) {
    await importDeviceBackup(context, ref);
  }
}

/// The question: a bottom sheet on phones, a dialog on wide windows. `null`
/// when closed without an answer.
Future<SyncOfferChoice?> showSyncOffer(BuildContext context) {
  if (context.isCompact) {
    return showModalBottomSheet<SyncOfferChoice>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => const SyncOffer());
  }
  return showDialog<SyncOfferChoice>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: const SyncOffer()),
    ),
  );
}

/// "Do you already use NEFORUM on another device?" with a way in for each
/// kind of sync storage and for a transfer file, or "No, I'm new".
class SyncOffer extends StatelessWidget {
  const SyncOffer({super.key});

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final folder = Env.isIOS
        ? ('iCloud Drive or the Files app', 'The sync file in iCloud Drive or a cloud app.')
        : Env.isAndroid
            ? ('A cloud app or a synced folder', 'The sync file in a cloud app, or a folder a sync app keeps in step.')
            : ('A folder your cloud app syncs', 'OneDrive, Dropbox, iCloud Drive, Syncthing and more.');
    // The ways in scroll; "No, I'm new" stays in view under them, so the
    // answer most people give is never below the fold of a phone.
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xxl, Space.xxl, Space.sm),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Align(alignment: Alignment.centerLeft, child: Icon(Icons.devices_rounded, size: 32, color: nf.accent)),
            const SizedBox(height: Space.md),
            Text('Do you already use NEFORUM on another device?', style: context.text.headlineSmall),
            const SizedBox(height: Space.sm),
            Text(
              'Join your sync and this device gets the same accounts, keys, posts and settings. Pick where your other devices keep the sync file.',
              style: context.text.bodyMedium,
            ),
            const SizedBox(height: Space.lg),
            const _Choice(SyncOfferChoice.googleDrive, Icons.add_to_drive_rounded, 'Google Drive, directly',
                'NEFORUM signs in to Google Drive with your own Google Cloud key.'),
            _Choice(SyncOfferChoice.folder, Icons.folder_open_rounded, folder.$1, folder.$2),
            const _Choice(SyncOfferChoice.webdav, Icons.dns_outlined, 'WebDAV', 'Nextcloud, Koofr, pCloud, a NAS and more.'),
            const _Choice(SyncOfferChoice.s3, Icons.storage_rounded, 'S3-compatible storage', 'A bucket at Cloudflare R2, Backblaze B2, Wasabi and more.'),
            const _Choice(SyncOfferChoice.transferFile, Icons.download_rounded, 'A transfer file',
                'The encrypted file you exported with Move to another device, without sync.'),
            const SizedBox(height: Space.xs),
            Text('You can join later in Settings > Sync.', style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
          ]),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xs, Space.lg, Space.lg),
        child: Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: () => Navigator.of(context).pop(SyncOfferChoice.newUser), child: const Text("No, I'm new to NEFORUM")),
        ),
      ),
    ]);
  }
}

class _Choice extends StatelessWidget {
  const _Choice(this.choice, this.icon, this.title, this.subtitle);
  final SyncOfferChoice choice;
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Semantics(
        button: true,
        child: NfCard(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md),
          onTap: () => Navigator.of(context).pop(choice),
          child: Row(children: [
            Icon(icon, size: 22, color: nf.accent),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: context.text.titleSmall),
                Text(subtitle, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: nf.textMuted),
          ]),
        ),
      ),
    );
  }
}
