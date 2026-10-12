import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../platform/media_library.dart';
import '../../state/media_host_config.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import '../accounts/guide_sheet.dart';
import '../accounts/markdown_style.dart';
import 'setting_row.dart';

/// Where Instagram/Threads (API mode) fetch media from, plus an optional
/// fallback host for when the main one can't store a file.
class MediaHostSection extends ConsumerStatefulWidget {
  const MediaHostSection({super.key});

  @override
  ConsumerState<MediaHostSection> createState() => _MediaHostSectionState();
}

class _MediaHostSectionState extends ConsumerState<MediaHostSection> {
  bool _addingFallback = false;

  static String _short(MediaHostDescriptor d) => d.name.split(' (').first;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final active = settings.mediaHostId == null ? null : mediaHostRegistry.descriptor(settings.mediaHostId!);
    final fallback = settings.fallbackMediaHostId == null ? null : mediaHostRegistry.descriptor(settings.fallbackMediaHostId!);
    final lastFallback = ref.read(servicesProvider).lastMediaHostFallback;

    return SettingsSection(
      title: 'Media hosting',
      icon: Icons.cloud_upload_outlined,
      subtitle: 'Only needed for Instagram and Threads in API mode.',
      children: [
        SettingRow(
          title: 'Why this exists',
          description: 'Instagram and Threads cannot receive uploads: they fetch photos and videos from a public web address. '
              'NEFORUM can put your media on a host you choose for a few minutes, then remove it where the host allows.',
          trailing: active == null
              ? const StatusPill('Not set up', dense: false)
              : StatusPill('${_short(active)} · ready', tone: Tone.success, icon: Icons.check_rounded, dense: false),
          stackOnCompact: true,
        ),
        const _HostEditor(slot: MediaHostSlot.main),
        if (active != null) ...[
          SettingRow(
            title: 'Fallback host',
            description: 'If ${_short(active)} can\'t store a file (for example because its server is down), NEFORUM tries this '
                'host instead, so the post still goes out. Choose one from a different provider: Litterbox and Catbox are run '
                'by the same people.',
            trailing: fallback == null
                ? const StatusPill('None', dense: false)
                : StatusPill('${_short(fallback)} · ready', tone: Tone.success, icon: Icons.check_rounded, dense: false),
            stackOnCompact: true,
          ),
          ValueListenableBuilder(
            valueListenable: lastFallback,
            builder: (context, last, _) => last == null || fallback == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.xl, 0),
                    child: NfWell(
                      padding: const EdgeInsets.all(Space.md),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.swap_horiz_rounded, size: 18, color: context.nf.warning),
                        const SizedBox(width: Space.sm),
                        Expanded(
                          child: SelectableText(
                            'The fallback stepped in at ${TimeOfDay.fromDateTime(last.at).format(context)}. ${last.message}',
                            style: context.text.bodySmall,
                          ),
                        ),
                      ]),
                    ),
                  ),
          ),
          if (fallback != null || _addingFallback)
            // Rebuilt when the main host changes: the choices depend on it.
            _HostEditor(key: ValueKey('fallback-${settings.mediaHostId}'), slot: MediaHostSlot.fallback)
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.xl, Space.xl),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => _addingFallback = true),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add a fallback host'),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// Picks and configures the host for one [slot]: cards, fields, Save, Test.
class _HostEditor extends ConsumerStatefulWidget {
  const _HostEditor({super.key, required this.slot});
  final MediaHostSlot slot;

  @override
  ConsumerState<_HostEditor> createState() => _HostEditorState();
}

class _HostEditorState extends ConsumerState<_HostEditor> {
  String? _choice;
  final Map<String, TextEditingController> _c = {};
  final Set<String> _revealed = {};
  bool _busy = false;
  String? _result;
  bool _resultOk = false;
  bool _loaded = false;

  MediaHostSlot get _slot => widget.slot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = ref.read(servicesProvider);
    final settings = ref.read(settingsProvider);
    final values = await mediaHostValues(settings, s.secrets, slot: _slot);
    if (!mounted) return;
    setState(() {
      _choice = _slot.idIn(settings);
      _fill(values);
      _loaded = true;
    });
  }

  void _fill(Map<String, String> values) {
    for (final c in _c.values) {
      c.dispose();
    }
    _c.clear();
    final d = _choice == null ? null : mediaHostRegistry.descriptor(_choice!);
    for (final f in d?.fields ?? const <MediaHostField>[]) {
      _c[f.key] = TextEditingController(text: values[f.key] ?? '');
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _values => {for (final e in _c.entries) if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim()};

  Future<void> _save() async {
    final id = _choice;
    if (id == null) return;
    final missing = mediaHostRegistry.missingFields(id, _values);
    if (missing.isNotEmpty) {
      setState(() {
        _result = 'Fill in ${missing.join(', ')}';
        _resultOk = false;
      });
      return;
    }
    setState(() => _busy = true);
    final s = ref.read(servicesProvider);
    final next = await storeMediaHost(ref.read(settingsProvider), s.secrets, id, _values, slot: _slot);
    await ref.read(settingsProvider.notifier).update((_) => next);
    await s.refreshMediaHost();
    ref.read(refreshTickProvider.notifier).bump();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = 'Saved';
      _resultOk = true;
    });
  }

  Future<void> _test() async {
    final id = _choice;
    if (id == null) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final host = createMediaHostFrom(id, _values, ref.read(servicesProvider).http);
      await host.verify();
      if (mounted) {
        setState(() {
          _result = verifySuccessMessage(host);
          _resultOk = true;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _result = e is MediaHostException ? e.message : '$e';
          _resultOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final s = ref.read(servicesProvider);
    final before = ref.read(settingsProvider);
    final promoted = _slot == MediaHostSlot.main ? before.fallbackMediaHostId : null;
    final next = await clearMediaHost(before, s.secrets, slot: _slot);
    await ref.read(settingsProvider.notifier).update((_) => next);
    await s.refreshMediaHost();
    ref.read(refreshTickProvider.notifier).bump();
    if (!mounted) return;
    // Removing the main host promotes the fallback: show its settings here.
    await _load();
    if (!mounted) return;
    setState(() {
      final name = promoted == null ? null : mediaHostRegistry.descriptor(promoted)?.name.split(' (').first;
      _result = name == null ? null : 'Removed. $name, the fallback, is now the main host.';
      _resultOk = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final settings = ref.watch(settingsProvider);
    final options = _slot == MediaHostSlot.main ? mediaHostOptions() : fallbackOptions(settings.mediaHostId);
    final chosen = _choice == null ? null : mediaHostRegistry.descriptor(_choice!);
    final saved = _slot.idIn(settings);

    if (!_loaded) return const Padding(padding: EdgeInsets.all(Space.xl), child: Center(child: CircularProgressIndicator()));
    return Padding(
      padding: const EdgeInsets.all(Space.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ResponsiveGrid(minItemWidth: 230, spacing: Space.sm, children: [
          for (final o in options)
            NfCard(
              selected: _choice == o.id,
              onTap: () => setState(() {
                _choice = o.id;
                _fill(o.id == saved ? {..._slot.configIn(settings)} : const {});
                _result = null;
              }),
              padding: const EdgeInsets.all(Space.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(o.name, style: context.text.labelLarge),
                const SizedBox(height: Space.xs),
                Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
                  if (o.temporary) const StatusPill('Temporary links', tone: Tone.info, dense: true),
                  if (!o.needsAccount) const StatusPill('No account', tone: Tone.success, dense: true),
                  if (o.thirdParty) const StatusPill('Third party', tone: Tone.warning, dense: true),
                  if (o.maxBytes != null) StatusPill('Up to ${formatBytes(o.maxBytes!)}', dense: true),
                ]),
                const SizedBox(height: Space.xs + 2),
                Text(o.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(fontSize: 11.5)),
              ]),
            ),
        ]),
        if (chosen != null) ...[
          const SizedBox(height: Space.lg),
          if (chosen.thirdParty)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.md),
              child: Text('Files go to a service you do not control. Do not use it for anything private.', style: context.text.bodySmall?.copyWith(color: nf.warning)),
            ),
          for (final f in chosen.fields) ...[
            TextField(
              controller: _c[f.key],
              obscureText: f.secret && !_revealed.contains(f.key),
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: f.required ? f.label : '${f.label} (optional)',
                hintText: f.placeholder,
                prefixIcon: f.secret ? const Icon(Icons.key_rounded, size: 20) : null,
                suffixIcon: f.secret
                    ? IconButton(
                        tooltip: _revealed.contains(f.key) ? 'Hide' : 'Show',
                        icon: Icon(_revealed.contains(f.key) ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
                        onPressed: () => setState(() => _revealed.contains(f.key) ? _revealed.remove(f.key) : _revealed.add(f.key)),
                      )
                    : null,
              ),
            ),
            if (f.help != null) Padding(padding: const EdgeInsets.only(top: Space.xs, left: Space.xs), child: NfMarkdown(f.help!, small: true)),
            const SizedBox(height: Space.md),
          ],
        ],
        Wrap(spacing: Space.sm, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (chosen != null) ...[
            FilledButton(onPressed: _busy ? null : _save, child: Text(_slot == MediaHostSlot.main ? 'Save' : 'Save fallback')),
            OutlinedButton.icon(onPressed: _busy ? null : _test, icon: const Icon(Icons.network_check_rounded, size: 18), label: const Text('Test connection')),
            TextButton.icon(
              onPressed: () => showGuideSheet(context, 'media-hosts', asset: 'media-hosts.md'),
              icon: const Icon(Icons.menu_book_outlined, size: 18),
              label: const Text('Guide'),
            ),
          ],
          if (saved != null)
            TextButton(
              onPressed: _busy ? null : _remove,
              style: TextButton.styleFrom(foregroundColor: nf.danger),
              child: Text(_slot == MediaHostSlot.main ? 'Remove' : 'Remove fallback'),
            ),
          if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          if (_result != null)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(_resultOk ? Icons.check_circle_rounded : Icons.error_outline_rounded, size: 16, color: _resultOk ? nf.success : nf.danger),
              const SizedBox(width: Space.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Text(_result!, style: context.text.bodySmall?.copyWith(color: _resultOk ? nf.success : nf.danger)),
              ),
            ]),
        ]),
      ]),
    );
  }
}
