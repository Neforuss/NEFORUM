import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../platform/browser_bridge.dart';
import '../../platform/env.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import '../accounts/guide_sheet.dart';
import '../activity/time_format.dart';
import 'setting_row.dart';

/// Settings > Browser extension (desktop): the local bridge the NEFORUM
/// extension fills hand-offs from, pairing, paired browsers and the bundled
/// extension files.
class BrowserExtensionSection extends ConsumerStatefulWidget {
  const BrowserExtensionSection({super.key});

  @override
  ConsumerState<BrowserExtensionSection> createState() => _BrowserExtensionSectionState();
}

class _BrowserExtensionSectionState extends ConsumerState<BrowserExtensionSection> {
  late BrowserBridge _bridge;
  Timer? _tick;

  /// The code on screen; null when none (or after Cancel).
  PairingCode? _shown;
  int _pairedBefore = 0;

  /// The browsers installed on this computer, for "Opens in".
  List<InstalledBrowser> _installed = const [];

  @override
  void initState() {
    super.initState();
    _bridge = ref.read(servicesProvider).browserBridge;
    _bridge.pairing.addListener(_onPairing);
    // Looked up again each time, so a browser installed since shows up.
    unawaited(_loadInstalled(refresh: true));
  }

  Future<void> _loadInstalled({bool refresh = false}) async {
    final list = await BrowserBridge.installedBrowsers(refresh: refresh);
    if (mounted) setState(() => _installed = list);
  }

  /// A paired browser's name as the user knows it: its program's name.
  static String _nameOf(PairedBrowser b) => b.appName ?? b.label;

  Future<void> _setProgram(PairedBrowser b, InstalledBrowser program) async {
    await _bridge.setProgram(b.token, program);
    if (mounted) showToast(context, 'Hand-offs for this browser open in ${program.name}', icon: Icons.check_circle_rounded);
  }

  /// "Other program…": a browser Windows doesn't list (a portable one).
  Future<void> _pickProgram(PairedBrowser b) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choose the browser program',
      type: Env.isWindows ? FileType.custom : FileType.any,
      allowedExtensions: Env.isWindows ? const ['exe'] : null,
    );
    final path = picked.singleOrNull?.path;
    if (path == null || !mounted) return;
    var name = p.basenameWithoutExtension(path);
    if (name.isNotEmpty) name = name[0].toUpperCase() + name.substring(1);
    await _setProgram(b, InstalledBrowser(id: path, name: name));
  }

  @override
  void dispose() {
    _bridge.pairing.removeListener(_onPairing);
    _tick?.cancel();
    super.dispose();
  }

  bool get _expired => _shown != null && !_bridge.now().isBefore(_shown!.expiresAt);

  void _pair() {
    _pairedBefore = _bridge.browsers.value.length;
    final code = _bridge.startPairing();
    setState(() => _shown = code);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (_expired) _stopTicking();
    });
  }

  void _stopTicking() {
    _tick?.cancel();
    _tick = null;
  }

  void _cancel() {
    _shown = null;
    _stopTicking();
    _bridge.cancelPairing();
    if (mounted) setState(() {});
  }

  /// The code went away without Cancel: used, expired or tried too often.
  void _onPairing() {
    final shown = _shown;
    if (_bridge.pairing.value != null || shown == null || !mounted) return;
    _shown = null;
    _stopTicking();
    final list = _bridge.browsers.value;
    if (list.length > _pairedBefore) {
      showToast(context, 'Paired with ${list.last.label}', icon: Icons.check_circle_rounded);
    } else if (!_bridge.now().isBefore(shown.expiresAt)) {
      showToast(context, 'The code expired. Make a new one.', icon: Icons.timer_off_outlined);
    } else {
      showToast(context, 'Too many wrong tries, so the code was cancelled. Make a new one.', icon: Icons.error_outline_rounded);
    }
    setState(() {});
  }

  Future<void> _showFiles() async {
    final dir = await BrowserBridge.revealExtensionFiles();
    if (!mounted || dir != null) return;
    showToast(context, 'This copy of NEFORUM has no extension files. The guide says where to get them.', icon: Icons.info_outline_rounded);
  }

  static String _postKeys() => Env.isMacOS ? '⌘+Enter' : 'Ctrl+Enter';

  /// How many different programs the paired browsers are (two Chrome
  /// profiles are one).
  static int _programs(List<PairedBrowser> list) => {for (final b in list) (b.app ?? browserFamily(b.label)).toLowerCase()}.length;

  Future<void> _swap() async {
    await _bridge.swapFirstTwo();
    final first = _bridge.browsers.value.firstOrNull;
    if (mounted && first != null) showToast(context, '${_nameOf(first)} is now your first choice', icon: Icons.swap_vert_rounded);
  }

  Future<void> _remove(PairedBrowser b) async {
    await _bridge.remove(b.token);
    if (mounted) showToast(context, '${_nameOf(b)} can no longer fill in posts. Pair it again to use it.', icon: Icons.link_off_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return ValueListenableBuilder<BrowserBridgeStatus>(
      valueListenable: _bridge.status,
      builder: (context, status, _) => ValueListenableBuilder<List<PairedBrowser>>(
        valueListenable: _bridge.browsers,
        builder: (context, browsers, _) => SettingsSection(
          title: 'Browser extension',
          icon: Icons.extension_outlined,
          subtitle: 'Fills in hand-offs on the website for you. You check the post, then post it.',
          children: [
            SettingSwitch(
              title: 'Let the extension fill in posts',
              description: 'When you open a hand-off, the NEFORUM extension puts the text, photos and videos into the page. Only this computer can connect.',
              value: s.browserExtension,
              onChanged: (v) {
                if (!v) _cancel();
                n.update((x) => x.copyWith(browserExtension: v));
              },
            ),
            SettingRow(title: 'Status', description: _statusText(status, s.browserExtension), trailing: _statusPill(status), stackOnCompact: true),
            SettingRow(
              title: 'Install the extension',
              description: 'Load the bundled extension in Chrome, Edge or Firefox. The guide shows how.',
              below: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
                OutlinedButton.icon(onPressed: _showFiles, icon: const Icon(Icons.folder_open_outlined, size: 18), label: const Text('Show extension files')),
                TextButton.icon(
                  onPressed: () => showGuideSheet(context, 'browser-extension', asset: 'browser-extension.md'),
                  icon: const Icon(Icons.menu_book_outlined, size: 18),
                  label: const Text('Guide'),
                ),
              ]),
            ),
            SettingRow(
              title: 'Pair a browser',
              description: 'In the extension, choose Pair and type the code NEFORUM shows here.',
              stackOnCompact: true,
              trailing: _shown != null
                  ? null
                  : OutlinedButton.icon(onPressed: status.listening ? _pair : null, icon: const Icon(Icons.link_rounded, size: 18), label: const Text('Pair a browser')),
              below: _shown == null ? null : _codePanel(context, _shown!),
            ),
            SettingRow(
              title: 'Paired browsers',
              description: browsers.isEmpty
                  ? 'None yet.'
                  : '${_programs(browsers) > 1 ? 'In order of choice. Hand-offs open in the first one, and only that one fills them in on its own. ' : ''}'
                      '"Opens in" is the program each browser is. Chromium browsers (Chrome, Helium, Vivaldi, Brave...) can look alike, so change it if it is wrong.',
              trailing: _programs(browsers) > 1
                  ? OutlinedButton.icon(onPressed: _swap, icon: const Icon(Icons.swap_vert_rounded, size: 18), label: const Text('Swap'))
                  : null,
              stackOnCompact: true,
              below: browsers.isEmpty
                  ? null
                  : Column(children: [
                      for (var i = 0; i < browsers.length; i++)
                        _BrowserTile(
                          browser: browsers[i],
                          now: _bridge.now(),
                          first: i == 0 && browsers.length > 1,
                          onMakeFirst: i == 0 ? null : () => _bridge.makeFirst(browsers[i].token),
                          onRemove: () => _remove(browsers[i]),
                          installed: _installed,
                          onProgram: (program) => _setProgram(browsers[i], program),
                          onPickProgram: Env.isWindows || Env.isLinux ? () => _pickProgram(browsers[i]) : null,
                        ),
                    ]),
            ),
            SettingSwitch(
              title: 'Open hand-offs in my first-choice browser',
              description: browsers.isEmpty
                  ? 'Once a browser is paired, hand-offs open in it instead of your default browser.'
                  : 'Hand-offs open in ${_nameOf(browsers.first)}${browsers.length > 1 ? ' (the first one above that is installed)' : ''}, not your default browser.',
              value: s.browserOpenInFirst,
              onChanged: (v) => n.update((x) => x.copyWith(browserOpenInFirst: v)),
            ),
            SettingSwitch(
              title: 'Post with ${_postKeys()}',
              description: 'After filling in a page, the extension presses the site\'s Post button when you press ${_postKeys()} '
                  'or its Post now button. Never on its own. Sites may count scripted clicks as automation, so check the post first.',
              value: s.browserQuickPost,
              onChanged: (v) => n.update((x) => x.copyWith(browserQuickPost: v)),
            ),
          ],
        ),
      ),
    );
  }

  static String? _statusText(BrowserBridgeStatus status, bool on) => switch (status.state) {
        BrowserBridgeState.listening => 'Paired browsers can reach NEFORUM. Web pages cannot.',
        BrowserBridgeState.portBusy => 'Ports ${kBrowserBridgePorts.first} to ${kBrowserBridgePorts.last} are all used by other programs. '
            'Close one of them, then turn the extension off and on again.',
        _ => on ? 'Starting…' : 'Hand-offs work as before: copy, open, paste.',
      };

  static Widget _statusPill(BrowserBridgeStatus status) => switch (status.state) {
        BrowserBridgeState.listening => StatusPill('Listening on port ${status.port}', tone: Tone.success, icon: Icons.check_rounded, dense: false),
        BrowserBridgeState.portBusy => const StatusPill('Port busy', tone: Tone.warning, icon: Icons.warning_amber_rounded, dense: false),
        _ => const StatusPill('Off', dense: false),
      };

  Widget _codePanel(BuildContext context, PairingCode code) {
    final nf = context.nf;
    final left = code.expiresAt.difference(_bridge.now());
    final expired = left <= Duration.zero;
    final secs = (left.inMilliseconds / 1000).ceil();
    final mmss = '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
    return NfWell(
      padding: const EdgeInsets.all(Space.lg),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(expired ? 'This code has expired' : 'Your pairing code', style: context.text.labelSmall?.copyWith(color: nf.textFaint)),
            const SizedBox(height: Space.xs),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${code.code.substring(0, 3)} ${code.code.substring(3)}',
                style: monoStyle(context, size: 40, weight: FontWeight.w700, color: expired ? nf.textFaint : nf.text).copyWith(letterSpacing: 4),
              ),
            ),
            const SizedBox(height: Space.xs),
            Text(expired ? 'Make a new one to pair.' : 'Works once, for $mmss more.', style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
          ]),
        ),
        const SizedBox(width: Space.md),
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (expired) ...[FilledButton(onPressed: _pair, child: const Text('New code')), const SizedBox(height: Space.xs)],
          TextButton(onPressed: _cancel, style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
        ]),
      ]),
    );
  }
}

class _BrowserTile extends StatelessWidget {
  const _BrowserTile({
    required this.browser,
    required this.now,
    required this.onRemove,
    required this.installed,
    required this.onProgram,
    this.onPickProgram,
    this.first = false,
    this.onMakeFirst,
  });
  final PairedBrowser browser;
  final DateTime now;
  final VoidCallback onRemove;

  /// Shows the "First choice" badge.
  final bool first;

  /// Moves this browser to the top (null for the first one).
  final VoidCallback? onMakeFirst;

  /// The installed browsers "Opens in" offers.
  final List<InstalledBrowser> installed;
  final ValueChanged<InstalledBrowser> onProgram;

  /// "Other program…" (null where it is not offered).
  final VoidCallback? onPickProgram;

  static const _other = '\u0000other';

  Widget _opensIn(BuildContext context) {
    final nf = context.nf;
    final current = browser.app;
    final listed = current != null && installed.any((b) => b.id.toLowerCase() == current.toLowerCase());
    final items = <DropdownMenuItem<String>>[
      for (final b in installed) DropdownMenuItem(value: b.id, child: Text(b.name, overflow: TextOverflow.ellipsis)),
      if (current != null && !listed)
        DropdownMenuItem(value: current, child: Text(browser.appName ?? current, overflow: TextOverflow.ellipsis)),
      if (onPickProgram != null) const DropdownMenuItem(value: _other, child: Text('Other program…')),
    ];
    final value = current == null ? null : (listed ? installed.firstWhere((b) => b.id.toLowerCase() == current.toLowerCase()).id : current);
    return Row(children: [
      Text('Opens in ', style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
      Flexible(
        child: DropdownButton<String>(
          key: ValueKey('opens-in-${browser.token}'),
          value: value,
          hint: Text('Choose the browser', style: context.text.bodySmall?.copyWith(color: nf.warning)),
          isDense: true,
          isExpanded: true,
          underline: const SizedBox.shrink(),
          style: context.text.bodySmall?.copyWith(color: nf.text, fontWeight: FontWeight.w600),
          items: items,
          onChanged: (id) {
            if (id == null || id == current) return;
            if (id == _other) return onPickProgram?.call();
            final program = installed.where((b) => b.id == id).firstOrNull;
            if (program != null) onProgram(program);
          },
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final used = relativeTime(browser.lastSeen.toLocal(), now: now.toLocal());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: nf.accentSoft, borderRadius: Radii.rSm),
          child: Icon(Icons.public_rounded, size: 19, color: nf.accent),
        ),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(browser.appName ?? browser.label, style: context.text.titleSmall, overflow: TextOverflow.ellipsis)),
              if (first) ...[const SizedBox(width: Space.sm), const StatusPill('First choice', tone: Tone.success, icon: Icons.star_rounded)],
            ]),
            Text(
              'Paired ${DateFormat('d MMM y').format(browser.createdAt.toLocal())} · Last used ${used == 'now' ? 'just now' : used}',
              style: context.text.bodySmall?.copyWith(color: nf.textMuted),
            ),
            _opensIn(context),
          ]),
        ),
        if (onMakeFirst != null)
          IconButton(onPressed: onMakeFirst, tooltip: 'Make first choice', icon: const Icon(Icons.arrow_upward_rounded, size: 18), color: nf.textMuted),
        TextButton(onPressed: onRemove, style: TextButton.styleFrom(foregroundColor: nf.danger), child: const Text('Remove')),
      ]),
    );
  }
}
