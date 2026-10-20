import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:share_plus/share_plus.dart';

import '../../brand/platform_brand.dart';
import '../../platform/env.dart';
import '../../state/device_transfer.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import '../accounts/guide_sheet.dart';
import 'setting_row.dart';

/// Settings > Data & privacy > Move to another device: Export and Import, and
/// after a Move, the card that removes the moved accounts here.
class MoveDeviceRows extends ConsumerWidget {
  const MoveDeviceRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(servicesProvider);
    final settings = ref.watch(settingsProvider);
    final available = !s.demo && !Env.isWeb;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (settings.movedAccountIds.isNotEmpty) _MovedCard(settings: settings),
      SettingRow(
        title: 'Move to another device',
        description: available
            ? 'One encrypted file with your accounts and their keys, media hosts, settings and drafts, locked with a passphrase. '
                'Carry it to your phone or computer yourself (USB, LocalSend, Nearby Share, AirDrop): no cloud, no server.'
            : 'Not available in the demo workspace.',
        trailing: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          OutlinedButton.icon(
            onPressed: available ? () => showDialog<void>(context: context, builder: (_) => const _ExportDialog()) : null,
            icon: const Icon(Icons.upload_file_rounded, size: 18),
            label: const Text('Export…'),
          ),
          OutlinedButton.icon(
            onPressed: available ? () => importDeviceBackup(context, ref) : null,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Import…'),
          ),
          TextButton(onPressed: () => showGuideSheet(context, 'backup', asset: 'backup.md'), child: const Text('How it works')),
        ]),
        stackOnCompact: true,
      ),
    ]);
  }
}

/// After a Move: the accounts are off here until the user confirms the other
/// device has them, then removes them (or takes them back).
class _MovedCard extends ConsumerWidget {
  const _MovedCard({required this.settings});
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final n = settings.movedAccountIds.length;
    final when = settings.movedAt == null ? '' : ' on ${DateFormat.yMMMd().format(settings.movedAt!.toLocal())}';
    Future<void> finish({required bool remove}) async {
      final s = ref.read(servicesProvider);
      for (final id in settings.movedAccountIds) {
        final a = await s.accounts.get(id);
        if (a == null) continue;
        if (remove) {
          await s.secrets.delete(id);
          await s.accounts.delete(id);
        } else {
          await s.accounts.upsert(a.copyWith(enabled: true));
        }
      }
      await ref.read(settingsProvider.notifier).update((x) => x.copyWith(clearMoved: true));
      if (context.mounted) {
        showToast(context, remove ? 'Removed $n moved ${n == 1 ? 'account' : 'accounts'} from this device' : 'The accounts are back on here',
            icon: Icons.check_rounded);
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.xl, Space.md),
      child: NfCard(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.move_up_rounded, color: nf.accent),
            const SizedBox(width: Space.sm),
            Expanded(child: Text('Moved $n ${n == 1 ? 'account' : 'accounts'}$when', style: context.text.titleSmall)),
          ]),
          const SizedBox(height: Space.xs),
          Text(
            'They are switched off here so nothing posts twice. Once the other device has imported them, remove them here.',
            style: context.text.bodySmall?.copyWith(color: nf.textMuted),
          ),
          const SizedBox(height: Space.md),
          Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
            FilledButton(onPressed: () => finish(remove: true), child: const Text('Remove them here')),
            TextButton(onPressed: () => finish(remove: false), child: const Text('Use them here again')),
          ]),
        ]),
      ),
    );
  }
}

class _ExportDialog extends ConsumerStatefulWidget {
  const _ExportDialog();

  @override
  ConsumerState<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends ConsumerState<_ExportDialog> {
  BackupMode _mode = BackupMode.copy;
  bool _accounts = true, _hosts = true, _settings = true, _posts = true, _history = false;
  bool _own = false, _saved = false, _busy = false, _hidden = true;
  final String _generated = generatePassphrase();
  final _custom = TextEditingController();
  List<String> _rotating = const [];

  @override
  void initState() {
    super.initState();
    () async {
      final s = ref.read(servicesProvider);
      final names = <String>{};
      for (final a in await s.accounts.all()) {
        if (a.tier == PlatformTier.handoff) continue;
        final adapter = s.registry.byId(a.platformId);
        if (adapter != null && adapter.rotatesRefreshTokens) names.add(adapter.descriptor.name);
      }
      if (mounted) setState(() => _rotating = names.toList()..sort());
    }();
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  String get _passphrase => _own ? _custom.text : _generated;

  bool get _ready {
    if (!(_accounts || _hosts || _settings || _posts || _history)) return false;
    if (_own) return passphraseStrength(_custom.text) != PassphraseStrength.tooShort && _saved;
    return _saved;
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    final s = ref.read(servicesProvider);
    final settings = ref.read(settingsProvider);
    try {
      final options = ExportOptions(mode: _mode, accounts: _accounts, mediaHosts: _hosts, settings: _settings, posts: _posts, history: _history);
      final bytes = await buildDeviceBackup(s, settings, options, _passphrase);
      final name = backupFileName(DateTime.now());
      var done = false;
      if (Env.isMobile) {
        // Never in the share text: only the file goes out.
        final r = await SharePlus.instance.share(ShareParams(files: [XFile.fromData(bytes, mimeType: 'application/octet-stream', name: name)], fileNameOverrides: [name]));
        done = r.status != ShareResultStatus.dismissed;
      } else {
        final where = await FilePicker.saveFile(dialogTitle: 'Save the encrypted NEFORUM backup', fileName: name, bytes: bytes);
        done = where != null;
      }
      if (!done) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      var moved = 0;
      if (_mode == BackupMode.move && _accounts) {
        final ids = <String>[];
        for (final a in await s.accounts.all()) {
          ids.add(a.id);
          if (a.enabled) await s.accounts.upsert(a.copyWith(enabled: false));
        }
        moved = ids.length;
        await ref.read(settingsProvider.notifier).update((x) => x.copyWith(movedAccountIds: ids, movedAt: DateTime.now()));
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      showToast(
        context,
        moved > 0 ? 'Backup saved. $moved ${moved == 1 ? 'account is' : 'accounts are'} switched off here until you finish the move.' : 'Encrypted backup saved',
        icon: Icons.lock_rounded,
      );
    } on Object catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, 'Could not export: $e', icon: Icons.error_outline_rounded);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final strength = passphraseStrength(_custom.text);
    Widget check(String label, bool value, ValueChanged<bool> on, {String? sub}) => CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: value,
          onChanged: _busy ? null : (v) => setState(() => on(v ?? false)),
          title: Text(label),
          subtitle: sub == null ? null : Text(sub, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
        );
    return AlertDialog(
      title: const Text('Move to another device'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<BackupMode>(
              segments: const [
                ButtonSegment(value: BackupMode.copy, label: Text('Copy'), icon: Icon(Icons.copy_all_rounded)),
                ButtonSegment(value: BackupMode.move, label: Text('Move'), icon: Icon(Icons.move_up_rounded)),
              ],
              selected: {_mode},
              onSelectionChanged: _busy ? null : (v) => setState(() => _mode = v.first),
            ),
            const SizedBox(height: Space.xs),
            Text(
              _mode == BackupMode.copy
                  ? 'Both devices keep the accounts.'
                  : 'After saving, the accounts are switched off here (nothing posts twice) until you confirm the other device has them.',
              style: context.text.bodySmall?.copyWith(color: nf.textMuted),
            ),
            if (_rotating.isNotEmpty && _mode == BackupMode.copy && _accounts) ...[
              const SizedBox(height: Space.sm),
              _note(context, Icons.warning_amber_rounded,
                  '${_rotating.join(' and ')} can stay connected on only one device: the first device to renew the sign-in ends the other\'s. '
                  'After copying, reconnect ${_rotating.length == 1 ? 'it' : 'them'} on the device that should keep ${_rotating.length == 1 ? 'it' : 'them'}, or choose Move.'),
            ],
            const SizedBox(height: Space.md),
            Text('Include', style: context.text.titleSmall),
            check('Accounts and their keys', _accounts, (v) => _accounts = v),
            check('Media hosts and their keys', _hosts, (v) => _hosts = v),
            check('Settings', _settings, (v) => _settings = v, sub: 'Not the ones that belong to this device (tray, start at sign-in, browser extension).'),
            check('Drafts and scheduled posts', _posts, (v) => _posts = v,
                sub: 'Scheduled posts arrive as drafts with their time, so only one device posts them. Photos and videos are not included.'),
            check('Published post history', _history, (v) => _history = v),
            const SizedBox(height: Space.md),
            Text('Passphrase', style: context.text.titleSmall),
            const SizedBox(height: Space.xs),
            if (!_own)
              NfWell(
                padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.xs, Space.xs),
                child: Row(children: [
                  Expanded(child: SelectableText(_generated, style: monoStyle(context, size: 15, color: nf.text))),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () => Clipboard.setData(ClipboardData(text: _generated)),
                  ),
                ]),
              )
            else
              TextField(
                controller: _custom,
                obscureText: _hidden,
                enabled: !_busy,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Your passphrase',
                  helperText: switch (strength) {
                    PassphraseStrength.tooShort => 'At least 10 characters (14 or more recommended)',
                    PassphraseStrength.weak => 'Weak: 14 characters or more is much safer',
                    PassphraseStrength.ok => 'Good',
                  },
                  suffixIcon: IconButton(
                    icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _hidden = !_hidden),
                  ),
                ),
              ),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _own = !_own),
              child: Text(_own ? 'Use a generated passphrase instead' : 'Use my own passphrase'),
            ),
            _note(context, Icons.key_rounded,
                'Write the passphrase down or keep it in your password manager. Without it the file cannot be opened, by you or anyone: there is no recovery.'),
            check(_own ? 'I have written my passphrase down' : 'I have written this passphrase down', _saved, (v) => _saved = v),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: _ready && !_busy ? _export : null,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.lock_rounded, size: 18),
          label: Text(_busy ? 'Encrypting…' : 'Encrypt and save'),
        ),
      ],
    );
  }
}

Widget _note(BuildContext context, IconData icon, String text) {
  final nf = context.nf;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.xs),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 18, color: nf.textMuted),
      const SizedBox(width: Space.sm),
      Expanded(child: Text(text, style: context.text.bodySmall?.copyWith(color: nf.textMuted))),
    ]),
  );
}

/// Import: pick the file, type the passphrase, preview, import.
Future<void> importDeviceBackup(BuildContext context, WidgetRef ref) async {
  final List<PlatformFile> files;
  try {
    // Any type: Android's extension filters are unreliable; the magic bytes
    // decide.
    files = await FilePicker.pickFiles(dialogTitle: 'Open a NEFORUM backup', type: FileType.any);
  } on Object catch (e) {
    if (context.mounted) showToast(context, 'Could not open the picker: $e', icon: Icons.error_outline_rounded);
    return;
  }
  if (files.isEmpty) return;
  final bytes = await files.first.readAsBytes();
  if (!context.mounted) return;
  if (!looksLikeBackup(bytes)) {
    showToast(context, 'That is not a NEFORUM backup file', icon: Icons.error_outline_rounded);
    return;
  }
  final payload = await showDialog<BackupPayload>(context: context, builder: (_) => _PassphraseDialog(bytes: bytes));
  if (payload == null || !context.mounted) return;
  await showDialog<void>(context: context, builder: (_) => _ImportPreview(payload: payload));
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({required this.bytes});
  final Uint8List bytes;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _field = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payload = await openDeviceBackup(widget.bytes, _field.text);
      if (mounted) Navigator.of(context).pop(payload);
    } on BackupException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not open the backup: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Open the backup'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: _field,
              autofocus: true,
              obscureText: true,
              enabled: !_busy,
              onSubmitted: (_) => _busy ? null : _open(),
              decoration: InputDecoration(labelText: 'Passphrase', errorText: _error),
            ),
            if (_busy) ...[
              const SizedBox(height: Space.md),
              const LinearProgressIndicator(),
              const SizedBox(height: Space.xs),
              Text('Unlocking: this takes a moment on purpose.', style: context.text.bodySmall),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _open, child: const Text('Open')),
        ],
      );
}

class _ImportPreview extends ConsumerStatefulWidget {
  const _ImportPreview({required this.payload});
  final BackupPayload payload;

  @override
  ConsumerState<_ImportPreview> createState() => _ImportPreviewState();
}

class _ImportPreviewState extends ConsumerState<_ImportPreview> {
  List<ImportCandidate>? _candidates;
  final Set<String> _selected = {};
  final Map<String, ImportChoice> _choices = {};
  bool _hosts = true, _settings = true, _posts = true, _busy = false;

  @override
  void initState() {
    super.initState();
    () async {
      final s = ref.read(servicesProvider);
      final c = previewImport(widget.payload, await s.accounts.all(), registry: s.registry);
      if (!mounted) return;
      setState(() {
        _candidates = c;
        _selected.addAll(c.map((x) => x.item.account.id));
        for (final x in c) {
          _choices[x.item.account.id] = x.defaultChoice;
        }
      });
    }();
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    final s = ref.read(servicesProvider);
    final p = widget.payload;
    try {
      final report = await applyBackup(p,
          candidates: _candidates!, accounts: s.accounts, posts: s.posts, secrets: s.secrets, choices: _choices, selected: _selected, importPosts: _posts);
      var settings = ref.read(settingsProvider);
      var hosts = 0;
      if (_settings && p.settings != null) settings = withImportedSettings(settings, p.settings!);
      if (_hosts && p.mediaHosts != null) {
        hosts = mediaHostsIn(p.mediaHosts).length;
        settings = await withImportedMediaHosts(settings, s.secrets, p.mediaHosts!);
      }
      await ref.read(settingsProvider.notifier).update((_) => settings);
      if (hosts > 0) await s.refreshMediaHost();
      if (!mounted) return;
      final parts = [
        if (report.accounts > 0) '${report.accounts} ${report.accounts == 1 ? 'account' : 'accounts'}',
        if (hosts > 0) '$hosts media ${hosts == 1 ? 'host' : 'hosts'}',
        if (_settings && p.settings != null) 'settings',
        if (report.posts > 0) '${report.posts} ${report.posts == 1 ? 'post' : 'posts'}',
      ];
      Navigator.of(context).pop();
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Imported'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(parts.isEmpty ? 'Nothing new was imported.' : 'Imported ${_join(parts)}.'),
            if (report.posts > 0) ...[
              const SizedBox(height: Space.sm),
              const Text('Posts that were scheduled on the other device are drafts here: schedule them again on the device that should post them.'),
            ],
            for (final a in report.attention) ...[const SizedBox(height: Space.sm), Text(a)],
            if (p.mode == BackupMode.move) ...[
              const SizedBox(height: Space.sm),
              const Text('On the other device, open Settings > Data & privacy and choose "Remove them here" to finish the move.'),
            ],
          ]),
          actions: [FilledButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Done'))],
        ),
      );
    } on Object catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, 'Could not import: $e', icon: Icons.error_outline_rounded);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final p = widget.payload;
    final c = _candidates;
    final hostCount = mediaHostsIn(p.mediaHosts).length;
    final registry = ref.read(registryProvider);
    final from = [p.device?.label, if (p.exportedAt != null) DateFormat.yMMMd().format(p.exportedAt!.toLocal())].whereType<String>().join(', ');
    return AlertDialog(
      title: Text(p.mode == BackupMode.move ? 'Import (moved accounts)' : 'Import'),
      content: SizedBox(
        width: 560,
        child: c == null
            ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  if (from.isNotEmpty) Text('From $from', style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
                  const SizedBox(height: Space.sm),
                  Text('Accounts', style: context.text.titleSmall),
                  if (c.isEmpty) const Text('No accounts in this backup.'),
                  for (final x in c)
                    Row(children: [
                      Checkbox(
                        value: _selected.contains(x.item.account.id),
                        onChanged: _busy ? null : (v) => setState(() => v == true ? _selected.add(x.item.account.id) : _selected.remove(x.item.account.id)),
                      ),
                      PlatformTile(x.item.account.platformId, size: 22),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(x.item.account.displayName, overflow: TextOverflow.ellipsis),
                          Text(
                            '${registry.descriptor(x.item.account.platformId)?.name ?? x.item.account.platformId} · ${x.item.account.tier.label}'
                            '${x.rotatesTokens ? ' · stays connected on one device only' : ''}',
                            style: context.text.bodySmall?.copyWith(color: nf.textMuted),
                          ),
                        ]),
                      ),
                      if (x.existing != null)
                        DropdownButton<ImportChoice>(
                          value: _choices[x.item.account.id],
                          onChanged: _busy ? null : (v) => setState(() => _choices[x.item.account.id] = v!),
                          items: const [
                            DropdownMenuItem(value: ImportChoice.replace, child: Text('Replace')),
                            DropdownMenuItem(value: ImportChoice.keep, child: Text('Keep this device\'s')),
                          ],
                        ),
                    ]),
                  const SizedBox(height: Space.md),
                  if (hostCount > 0)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _hosts,
                      onChanged: _busy ? null : (v) => setState(() => _hosts = v ?? false),
                      title: Text('$hostCount media ${hostCount == 1 ? 'host' : 'hosts'} (replaces this device\'s)'),
                    ),
                  if (p.settings != null)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _settings,
                      onChanged: _busy ? null : (v) => setState(() => _settings = v ?? false),
                      title: const Text('Settings'),
                    ),
                  if (p.posts.isNotEmpty)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _posts,
                      onChanged: _busy ? null : (v) => setState(() => _posts = v ?? false),
                      title: Text('${p.posts.length} ${p.posts.length == 1 ? 'post' : 'posts'} (scheduled ones arrive as drafts)'),
                    ),
                  if (p.skipped > 0) Text('${p.skipped} damaged ${p.skipped == 1 ? 'entry was' : 'entries were'} skipped.', style: context.text.bodySmall),
                ]),
              ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: c == null || _busy ? null : _import, child: Text(_busy ? 'Importing…' : 'Import')),
      ],
    );
  }
}

String _join(List<String> parts) => parts.length <= 1 ? parts.join() : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
