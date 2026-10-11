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

/// Where Instagram/Threads (API mode) fetch media from.
class MediaHostSection extends ConsumerStatefulWidget {
  const MediaHostSection({super.key});

  @override
  ConsumerState<MediaHostSection> createState() => _MediaHostSectionState();
}

class _MediaHostSectionState extends ConsumerState<MediaHostSection> {
  String? _choice;
  final Map<String, TextEditingController> _c = {};
  final Set<String> _revealed = {};
  bool _busy = false;
  String? _result;
  bool _resultOk = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = ref.read(servicesProvider);
    final settings = ref.read(settingsProvider);
    final values = await mediaHostValues(settings, s.secrets);
    if (!mounted) return;
    setState(() {
      _choice = settings.mediaHostId;
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
    final next = await storeMediaHost(ref.read(settingsProvider), s.secrets, id, _values);
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
          _result = 'Connection works';
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
    final next = await clearMediaHost(ref.read(settingsProvider), s.secrets);
    await ref.read(settingsProvider.notifier).update((_) => next);
    await s.refreshMediaHost();
    ref.read(refreshTickProvider.notifier).bump();
    if (!mounted) return;
    setState(() {
      _choice = null;
      _fill(const {});
      _result = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final settings = ref.watch(settingsProvider);
    final active = settings.mediaHostId == null ? null : mediaHostRegistry.descriptor(settings.mediaHostId!);
    final options = mediaHostOptions();
    final chosen = _choice == null ? null : mediaHostRegistry.descriptor(_choice!);

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
              : StatusPill('${active.name.split(' (').first} · ready', tone: Tone.success, icon: Icons.check_rounded, dense: false),
          stackOnCompact: true,
        ),
        if (!_loaded)
          const Padding(padding: EdgeInsets.all(Space.xl), child: Center(child: CircularProgressIndicator()))
        else
          Padding(
            padding: const EdgeInsets.all(Space.xl),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ResponsiveGrid(minItemWidth: 230, spacing: Space.sm, children: [
                for (final o in options)
                  NfCard(
                    selected: _choice == o.id,
                    onTap: () => setState(() {
                      _choice = o.id;
                      _fill(o.id == settings.mediaHostId ? {...settings.mediaHostConfig} : const {});
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
                Wrap(spacing: Space.sm, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
                  OutlinedButton.icon(onPressed: _busy ? null : _test, icon: const Icon(Icons.network_check_rounded, size: 18), label: const Text('Test connection')),
                  TextButton.icon(
                    onPressed: () => showGuideSheet(context, 'media-hosts', asset: 'media-hosts.md'),
                    icon: const Icon(Icons.menu_book_outlined, size: 18),
                    label: const Text('Guide'),
                  ),
                  if (settings.mediaHostId != null)
                    TextButton(onPressed: _busy ? null : _remove, style: TextButton.styleFrom(foregroundColor: nf.danger), child: const Text('Remove')),
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
              ],
            ]),
          ),
      ],
    );
  }
}
