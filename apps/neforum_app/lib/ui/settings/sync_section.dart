import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../platform/env.dart';
import '../../platform/files_app_folder.dart';
import '../../platform/folder_access.dart';
import '../../state/cloud_sync.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import '../accounts/guide_sheet.dart';
import 'setting_row.dart';

/// Settings > Sync: one encrypted file in the user's own storage that every
/// device reads and writes, KeePassXC style.
class SyncSection extends ConsumerWidget {
  const SyncSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(servicesProvider);
    final settings = ref.watch(settingsProvider);
    final available = !s.demo && !Env.isWeb;
    final provider = syncProviderById(settings.syncProviderId);
    return SettingsSection(
      title: 'Sync',
      icon: Icons.sync_rounded,
      subtitle: 'The same accounts, keys, posts and settings on every device, through storage you already have.',
      children: [
        if (!settings.syncOn)
          SettingRow(
            title: 'Sync between devices',
            description: available
                ? 'NEFORUM keeps one encrypted file in a folder your cloud app syncs (OneDrive, Google Drive, Dropbox, iCloud Drive, '
                    'Syncthing and more), on a WebDAV server (Nextcloud, Koofr, pCloud, a NAS...) or in an S3 bucket. Each device '
                    'reads and writes it. The storage only ever sees the encrypted file; there is no NEFORUM server.'
                : 'Not available in the demo workspace.',
            trailing: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
              FilledButton.icon(
                onPressed: available ? () => showDialog<void>(context: context, builder: (_) => const SyncSetupDialog()) : null,
                icon: const Icon(Icons.sync_rounded, size: 18),
                label: const Text('Set up…'),
              ),
              TextButton(onPressed: () => showGuideSheet(context, 'sync', asset: 'sync.md'), child: const Text('How it works')),
            ]),
            stackOnCompact: true,
          )
        else
          ValueListenableBuilder<CloudSyncStatus>(
            valueListenable: s.cloudSync.status,
            builder: (context, st, _) => _OnRows(settings: settings, provider: provider, status: st),
          ),
      ],
    );
  }
}

class _OnRows extends ConsumerWidget {
  const _OnRows({required this.settings, required this.provider, required this.status});
  final AppSettings settings;
  final SyncProvider? provider;
  final CloudSyncStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final s = ref.read(servicesProvider);
    final where = switch (provider?.kind) {
      SyncBackendKind.folder => settings.syncConfig['folder'] ?? '',
      SyncBackendKind.webdav => settings.syncConfig['url'] ?? '',
      SyncBackendKind.s3 => '${settings.syncConfig['bucket'] ?? ''} at ${Uri.tryParse(settings.syncConfig['endpoint'] ?? '')?.host ?? ''}',
      null => '',
    };
    final last = status.lastSyncAt == null ? null : DateFormat.jm().format(status.lastSyncAt!.toLocal());
    final line = switch (status.phase) {
      CloudSyncPhase.syncing => 'Syncing…',
      CloudSyncPhase.error => status.message ?? 'Sync failed.',
      CloudSyncPhase.ok => last == null ? 'On.' : 'Up to date (synced at $last).',
      CloudSyncPhase.off => 'Starting…',
    };
    Future<void> turnOff() async {
      final sure = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Turn off sync on this device?'),
          content: const Text(
              'This device keeps everything it has and stops reading and writing the sync file. The file and your other devices are not changed.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Turn off')),
          ],
        ),
      );
      if (sure != true) return;
      await s.secrets.delete(kSyncSecretsKey);
      await s.storage.writeJson('sync-state.json', const <String, dynamic>{});
      await ref.read(settingsProvider.notifier).update((x) => x.copyWith(clearSync: true));
      if (context.mounted) showToast(context, 'Sync is off on this device', icon: Icons.sync_disabled_rounded);
    }

    final others = status.devices.entries.where((e) => e.key != status.deviceId).toList()
      ..sort((a, b) => b.value.seenAt.compareTo(a.value.seenAt));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingRow(
        title: 'Syncing with ${provider?.name ?? 'your storage'}',
        description: '$line${where.isEmpty ? '' : '\n$where'}',
        trailing: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          OutlinedButton.icon(
            onPressed: status.phase == CloudSyncPhase.syncing ? null : () => s.cloudSync.syncNow(),
            icon: const Icon(Icons.sync_rounded, size: 18),
            label: const Text('Sync now'),
          ),
          TextButton(onPressed: () => showDialog<void>(context: context, builder: (_) => const SyncSetupDialog()), child: const Text('Change…')),
          TextButton(onPressed: turnOff, child: const Text('Turn off')),
          TextButton(onPressed: () => showGuideSheet(context, 'sync', asset: 'sync.md'), child: const Text('How it works')),
        ]),
        stackOnCompact: true,
      ),
      if (others.isNotEmpty)
        SettingRow(
          title: 'Other devices',
          below: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final d in others)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${d.value.label.isEmpty ? d.value.platform : d.value.label} · NEFORUM ${d.value.appVersion} · last seen ${DateFormat.yMMMd().add_jm().format(d.value.seenAt.toLocal())}',
                  style: context.text.bodySmall?.copyWith(color: nf.textMuted),
                ),
              ),
          ]),
        ),
    ]);
  }
}

/// Choose the storage, fill in where the file is, and the passphrase.
class SyncSetupDialog extends ConsumerStatefulWidget {
  const SyncSetupDialog({super.key});

  @override
  ConsumerState<SyncSetupDialog> createState() => _SyncSetupDialogState();
}

class _SyncSetupDialogState extends ConsumerState<SyncSetupDialog> {
  SyncProvider? _provider;
  final _fields = <String, TextEditingController>{};
  final _passphrase = TextEditingController();
  String? _folder;

  /// The picked location's bookmark (phones and tablets), and whether it is
  /// the sync file itself rather than its folder.
  String? _bookmark;
  bool _isFile = false;
  bool _hidden = true, _saved = false, _busy = false;
  String? _error;
  String? _progress;

  TextEditingController _c(String key) => _fields.putIfAbsent(key, TextEditingController.new);

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    final current = syncProviderById(settings.syncProviderId);
    if (current != null) {
      _pick(current);
      for (final e in settings.syncConfig.entries) {
        if (e.key == 'folder' && current.kind == SyncBackendKind.folder) {
          _folder = e.value;
        } else if (e.key == 'bookmark') {
          _bookmark = e.value;
        } else if (e.key == 'target') {
          _isFile = e.value == 'file';
        } else {
          _c(e.key).text = e.value;
        }
      }
      () async {
        final secret = await ref.read(servicesProvider).secrets.read(kSyncSecretsKey) ?? const {};
        if (!mounted) return;
        setState(() {
          _passphrase.text = secret['passphrase'] ?? '';
          _c('password').text = secret['password'] ?? '';
          _c('secretAccessKey').text = secret['secretAccessKey'] ?? '';
          _saved = _passphrase.text.isNotEmpty;
        });
      }();
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _passphrase.dispose();
    super.dispose();
  }

  void _pick(SyncProvider p) {
    setState(() {
      _provider = p;
      _error = null;
      if (p.kind == SyncBackendKind.webdav && _c('url').text.isEmpty) _c('url').text = p.urlTemplate ?? '';
      if (p.kind == SyncBackendKind.s3) {
        if (_c('endpoint').text.isEmpty) _c('endpoint').text = p.urlTemplate ?? '';
        if (_c('region').text.isEmpty && p.region != null) _c('region').text = p.region!;
        if (_c('folder').text.isEmpty) _c('folder').text = 'neforum';
      }
    });
  }

  Future<void> _chooseFolder([PickMode mode = PickMode.folder]) async {
    if (Env.isMobile) {
      try {
        final picked = await FilesAppFolder.pick(mode);
        if (picked != null && mounted) {
          setState(() {
            _folder = picked.name;
            _bookmark = picked.bookmark;
            _isFile = picked.isFile;
            _error = null;
          });
        }
      } on PlatformException catch (e) {
        if (mounted) setState(() => _error = e.message ?? 'Could not open the file picker.');
      }
      return;
    }
    final path = await FilePicker.getDirectoryPath(dialogTitle: 'Choose the folder ${_provider?.name ?? 'your cloud app'} syncs');
    if (path != null && mounted) setState(() => _folder = path);
  }

  Map<String, String> get _config {
    final p = _provider!;
    String t(String k) => _c(k).text.trim();
    return switch (p.kind) {
      SyncBackendKind.folder => {
          'folder': ?_folder,
          if (Env.isMobile) 'bookmark': ?_bookmark,
          if (Env.isMobile && _isFile) 'target': 'file',
        },
      SyncBackendKind.webdav => {'url': t('url'), 'username': t('username')},
      SyncBackendKind.s3 => {
          'endpoint': t('endpoint'),
          if (t('region').isNotEmpty) 'region': t('region'),
          'bucket': t('bucket'),
          if (t('folder').isNotEmpty) 'folder': t('folder'),
          'accessKeyId': t('accessKeyId'),
          if (t('addressing').isNotEmpty) 'addressing': t('addressing'),
        },
    };
  }

  Map<String, String> get _secrets => {
        'passphrase': _passphrase.text,
        if (_provider?.kind == SyncBackendKind.webdav) 'password': _c('password').text,
        if (_provider?.kind == SyncBackendKind.s3) 'secretAccessKey': _c('secretAccessKey').text.trim(),
      };

  String? _missing() {
    final p = _provider;
    if (p == null) return 'Choose where the sync file goes.';
    final c = _config;
    switch (p.kind) {
      case SyncBackendKind.folder:
        if (c['folder'] == null || (Env.isMobile && c['bookmark'] == null)) return Env.isMobile ? 'Choose a folder or the sync file.' : 'Choose the folder.';
      case SyncBackendKind.webdav:
        final u = Uri.tryParse(c['url'] ?? '');
        if (u == null || !u.hasScheme || u.host.isEmpty || (c['url'] ?? '').contains('<')) return 'Fill in the WebDAV address (replace the <parts>).';
        if ((c['username'] ?? '').isEmpty || _c('password').text.isEmpty) return 'Fill in the username and password.';
      case SyncBackendKind.s3:
        final u = Uri.tryParse(c['endpoint'] ?? '');
        if (u == null || !u.hasScheme || u.host.isEmpty || (c['endpoint'] ?? '').contains('<')) return 'Fill in the endpoint (replace the <parts>).';
        if ((c['bucket'] ?? '').isEmpty || (c['accessKeyId'] ?? '').isEmpty || _c('secretAccessKey').text.trim().isEmpty) {
          return 'Fill in the bucket and the access key with its secret.';
        }
    }
    if (passphraseStrength(_passphrase.text) == PassphraseStrength.tooShort) return 'The passphrase needs at least 10 characters.';
    if (!_saved) return 'Confirm that you wrote the passphrase down.';
    return null;
  }

  Future<void> _connect() async {
    final missing = _missing();
    if (missing != null) {
      setState(() => _error = missing);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _progress = 'Checking the storage…';
    });
    final s = ref.read(servicesProvider);
    final p = _provider!;
    final config = _config;
    final secrets = _secrets;
    try {
      final trial = ref.read(settingsProvider).copyWith(syncProviderId: p.id, syncConfig: config);
      final backend = buildSyncBackend(trial, secrets, s.http);
      if (backend == null) throw const SyncBackendException('Some details are missing.');
      await backend.check();
      setState(() => _progress = 'Looking for a sync file…');
      final blob = await backend.read();
      if (blob != null) {
        setState(() => _progress = 'Unlocking the sync file: this takes a moment on purpose…');
        final passphrase = secrets['passphrase']!;
        final bytes = blob.bytes;
        await Isolate.run(() async => BackupCipher(passphrase).open(bytes));
      }
      var stored = config;
      if (p.kind == SyncBackendKind.folder && Env.isMacOS) {
        final bookmark = await FolderAccess.remember(config['folder']!);
        if (bookmark != null) stored = {...config, 'bookmark': bookmark};
      }
      await s.secrets.write(kSyncSecretsKey, secrets);
      final before = ref.read(settingsProvider);
      final changedStorage = before.syncProviderId != p.id ||
          before.syncConfig['folder'] != config['folder'] ||
          before.syncConfig['bookmark'] != config['bookmark'];
      if (changedStorage) await s.storage.writeJson('sync-state.json', const <String, dynamic>{});
      await ref.read(settingsProvider.notifier).update((x) => x.copyWith(syncProviderId: p.id, syncConfig: stored));
      if (!mounted) return;
      Navigator.of(context).pop();
      showToast(context, blob == null ? 'Sync is on: the sync file was created' : 'Sync is on: this device joined the sync file', icon: Icons.sync_rounded);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _error = describeSyncError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final p = _provider;
    return AlertDialog(
      title: Text(p == null ? 'Where should the sync file go?' : 'Sync with ${p.name}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (p == null) ..._providerList(context) else ..._form(context, p),
            if (_error != null) ...[
              const SizedBox(height: Space.sm),
              Text(_error!, style: context.text.bodySmall?.copyWith(color: nf.danger)),
            ],
            if (_progress != null) ...[
              const SizedBox(height: Space.md),
              const LinearProgressIndicator(),
              const SizedBox(height: Space.xs),
              Text(_progress!, style: context.text.bodySmall),
            ],
          ]),
        ),
      ),
      actions: [
        if (p != null) TextButton(onPressed: _busy ? null : () => setState(() => _provider = null), child: const Text('Back')),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        if (p != null) FilledButton(onPressed: _busy ? null : _connect, child: Text(_busy ? 'Connecting…' : 'Turn on sync')),
      ],
    );
  }

  List<Widget> _providerList(BuildContext context) {
    final nf = context.nf;
    Widget group(String title, String sub, SyncBackendKind kind) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: Space.md),
          Text(title, style: context.text.titleSmall),
          Text(sub, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
          const SizedBox(height: Space.xs),
          Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
            for (final x in syncProviders.where((x) => x.kind == kind && x.availableOn(ios: Env.isIOS, android: Env.isAndroid)))
              ActionChip(label: Text(x.name), onPressed: () => _pick(x)),
          ]),
        ]);
    return [
      Text('Pick the storage you already use. Use the same one on every device.', style: context.text.bodyMedium),
      if (Env.isDesktop)
        group('A cloud app on this computer', 'NEFORUM writes the file into a folder; your cloud app does the syncing.', SyncBackendKind.folder),
      if (Env.isIOS)
        group('iCloud Drive or a cloud app', 'Pick a folder, or the sync file, in the Files app; iCloud Drive or the cloud app does the syncing.',
            SyncBackendKind.folder),
      if (Env.isAndroid)
        group('A cloud app or a synced folder', 'Pick the sync file in a cloud app, or a folder on this phone that a sync app keeps in step.',
            SyncBackendKind.folder),
      group('WebDAV', 'NEFORUM reaches the server itself. Works on phones too.', SyncBackendKind.webdav),
      group('S3-compatible storage', 'NEFORUM reaches the bucket itself. Works on phones too.', SyncBackendKind.s3),
    ];
  }

  List<Widget> _form(BuildContext context, SyncProvider p) {
    final nf = context.nf;
    Widget field(String key, String label, {String? hint, bool secret = false, bool optional = false}) => Padding(
          padding: const EdgeInsets.only(bottom: Space.sm),
          child: TextField(
            controller: _c(key),
            enabled: !_busy,
            obscureText: secret,
            autocorrect: false,
            decoration: InputDecoration(labelText: optional ? '$label (optional)' : label, helperText: hint),
          ),
        );
    return [
      Text(p.hintFor(ios: Env.isIOS, android: Env.isAndroid), style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
      const SizedBox(height: Space.md),
      if (p.kind == SyncBackendKind.folder && Env.isMobile) ...[
        NfWell(
          padding: const EdgeInsets.all(Space.md),
          child: Text(
            _folder == null ? 'Nothing chosen yet' : (_isFile ? 'Sync file: $_folder' : 'Folder: $_folder'),
            style: monoStyle(context, size: 12, color: _folder == null ? nf.textMuted : nf.text),
          ),
        ),
        const SizedBox(height: Space.sm),
        Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _chooseFolder(PickMode.folder),
            icon: const Icon(Icons.folder_open_rounded, size: 18),
            label: const Text('Choose folder…'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _chooseFolder(PickMode.file),
            icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
            label: const Text('Choose the sync file…'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _chooseFolder(PickMode.create),
            icon: const Icon(Icons.note_add_outlined, size: 18),
            label: const Text('Create the sync file…'),
          ),
        ]),
        const SizedBox(height: Space.xs),
        Text(
          'Grayed out when choosing a folder? That app does not let other apps pick its folders. Choose the sync file there '
          '(NEFORUM.neforumsync, which your computer makes), or create it there if this is your first device.',
          style: context.text.bodySmall?.copyWith(color: nf.textMuted),
        ),
      ],
      if (p.kind == SyncBackendKind.folder && !Env.isMobile)
        NfWell(
          padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.xs, Space.xs),
          child: Row(children: [
            Expanded(child: Text(_folder ?? 'No folder chosen', style: monoStyle(context, size: 12, color: _folder == null ? nf.textMuted : nf.text))),
            TextButton(onPressed: _busy ? null : _chooseFolder, child: const Text('Choose folder…')),
          ]),
        ),
      if (p.kind == SyncBackendKind.webdav) ...[
        field('url', 'WebDAV folder address', hint: 'The file NEFORUM.neforumsync goes in this folder; it is created if missing.'),
        field('username', 'Username'),
        field('password', 'App password', secret: true, hint: 'An app password where the service offers one, not your main password.'),
      ],
      if (p.kind == SyncBackendKind.s3) ...[
        field('endpoint', 'Endpoint'),
        field('region', 'Region', optional: true, hint: 'Leave empty to guess from the endpoint.'),
        field('bucket', 'Bucket', hint: 'A private bucket: the file never needs to be public.'),
        field('folder', 'Folder in the bucket', optional: true),
        field('accessKeyId', 'Access key ID'),
        field('secretAccessKey', 'Secret access key', secret: true),
      ],
      const SizedBox(height: Space.md),
      Text('Sync passphrase', style: context.text.titleSmall),
      const SizedBox(height: Space.xs),
      TextField(
        controller: _passphrase,
        enabled: !_busy,
        obscureText: _hidden,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: 'Passphrase',
          helperText: 'The same on every device. First device: choose one (or generate it). Next devices: type it in.',
          helperMaxLines: 3,
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: 'Generate',
              icon: const Icon(Icons.casino_outlined, size: 18),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _passphrase.text = generatePassphrase();
                        _hidden = false;
                      }),
            ),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy_rounded, size: 18),
              onPressed: () => Clipboard.setData(ClipboardData(text: _passphrase.text)),
            ),
            IconButton(
              tooltip: _hidden ? 'Show' : 'Hide',
              icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
              onPressed: () => setState(() => _hidden = !_hidden),
            ),
          ]),
        ),
      ),
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _saved,
        onChanged: _busy ? null : (v) => setState(() => _saved = v ?? false),
        title: const Text('I have written the passphrase down'),
        subtitle: Text('Without it the sync file cannot be opened, by you or anyone: there is no recovery.',
            style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
      ),
    ];
  }
}
