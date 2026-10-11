import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../brand/neforum_logo.dart';
import '../../platform/desktop.dart';
import '../../platform/env.dart';
import '../../platform/media_library.dart';
import '../../platform/notifications.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import '../accounts/guide_sheet.dart';
import '../root.dart';
import 'media_host_section.dart';
import 'setting_row.dart';

/// Settings, grouped into sections with a table of contents on wide screens.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _keys = <String, GlobalKey>{};

  GlobalKey _key(String name) => _keys.putIfAbsent(name, GlobalKey.new);

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final sections = <(String, IconData, Widget)>[
      ('Appearance', Icons.palette_outlined, const _Appearance()),
      ('Posting', Icons.send_outlined, const _Posting()),
      ('Media hosting', Icons.cloud_upload_outlined, const MediaHostSection()),
      if (Env.isDesktop) ('Desktop', Icons.desktop_windows_outlined, const _Desktop()),
      ('Notifications', Icons.notifications_none_rounded, const _Notifications()),
      ('Workspace', Icons.science_outlined, const _Workspace()),
      ('Data & privacy', Icons.shield_outlined, const _Data()),
      ('About', Icons.info_outline_rounded, const _About()),
    ];

    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final s in sections) ...[
        KeyedSubtree(key: _key(s.$1), child: s.$3),
        const SizedBox(height: Space.x3),
      ],
    ]);

    final toc = SizedBox(
      width: 200,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('ON THIS PAGE', style: context.text.labelSmall?.copyWith(color: nf.textFaint, letterSpacing: 1.4)),
        const SizedBox(height: Space.md),
        for (final s in sections)
          TextButton.icon(
            onPressed: () {
              final c = _keys[s.$1]?.currentContext;
              if (c != null) Scrollable.ensureVisible(c, duration: Motion.slow, curve: Motion.standard, alignment: 0.02);
            },
            icon: Icon(s.$2, size: 17),
            label: Text(s.$1),
            style: TextButton.styleFrom(foregroundColor: nf.textMuted, alignment: Alignment.centerLeft),
          ),
      ]),
    );

    return PageBody(maxWidth: context.isExpanded ? 1120 : 880, children: [
      const PageHeader(eyebrow: 'Settings', title: 'Make NEFORUM yours'),
      const SizedBox(height: Space.x3),
      if (context.isExpanded)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          toc,
          const SizedBox(width: Space.x3),
          Expanded(child: content),
        ])
      else
        content,
    ]);
  }
}

// ---------------------------------------------------------------------------

class _Appearance extends ConsumerWidget {
  const _Appearance();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSection(title: 'Appearance', icon: Icons.palette_outlined, children: [
      SettingRow(
        title: 'Theme',
        stackOnCompact: true,
        trailing: SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto_outlined, size: 18)),
            ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined, size: 18)),
            ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined, size: 18)),
          ],
          selected: {s.themeMode},
          onSelectionChanged: (v) => n.update((x) => x.copyWith(themeMode: v.first)),
          showSelectedIcon: false,
        ),
      ),
      SettingRow(
        title: 'Accent color',
        description: 'Used for highlights and the main button.',
        stackOnCompact: true,
        trailing: Wrap(spacing: Space.sm, children: [
          for (final a in AccentChoice.values)
            Tooltip(
              message: a.label,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => n.update((x) => x.copyWith(accent: a)),
                child: AnimatedContainer(
                  duration: Motion.fast,
                  width: 30,
                  height: 30,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: s.accent == a ? nf.text : Colors.transparent, width: 2)),
                  child: Container(
                    decoration: BoxDecoration(color: nf.isDark ? a.dark : a.light, shape: BoxShape.circle),
                    child: s.accent == a ? const Icon(Icons.check_rounded, size: 14, color: Colors.white) : null,
                  ),
                ),
              ),
            ),
        ]),
      ),
      SettingSwitch(
        title: 'Compact previews',
        description: 'Smaller preview cards in the composer.',
        value: s.compactPreviews,
        onChanged: (v) => n.update((x) => x.copyWith(compactPreviews: v)),
      ),
    ]);
  }
}

class _Posting extends ConsumerWidget {
  const _Posting();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSection(title: 'Posting', icon: Icons.send_outlined, subtitle: 'How NEFORUM adapts one post for many networks.', children: [
      SettingChoice<OverflowStrategy>(
        title: 'When a post is too long for a network',
        value: s.overflow,
        onChanged: (v) => n.update((x) => x.copyWith(overflow: v)),
        options: const [
          (OverflowStrategy.threadOrError, 'Split into a thread, or ask me to shorten it', 'Recommended. Networks without threads ask you to customize the text.'),
          (OverflowStrategy.threadOrTruncate, 'Split into a thread, or shorten it with …', 'Never blocks posting.'),
          (OverflowStrategy.truncate, 'Always shorten it with …', 'Never makes threads.'),
          (OverflowStrategy.error, 'Never change my text', 'You customize the text for networks where it does not fit.'),
        ],
      ),
      SettingSwitch(title: 'Number thread parts', description: 'Adds (1/3), (2/3)… to each part.', value: s.threadNumbering, onChanged: (v) => n.update((x) => x.copyWith(threadNumbering: v))),
      SettingSwitch(title: 'Add my hashtags to the text', description: 'Where the network has no separate tags field.', value: s.appendHashtags, onChanged: (v) => n.update((x) => x.copyWith(appendHashtags: v))),
      SettingSwitch(title: 'Add my link to the text', description: 'Where the network has no link field and the link is not in the text yet.', value: s.appendLink, onChanged: (v) => n.update((x) => x.copyWith(appendLink: v))),
      SettingSwitch(
        title: 'Hand off when an API limit is reached',
        description: 'If an account runs out of quota, NEFORUM opens the app for you instead of failing.',
        value: s.fallbackToHandoff,
        onChanged: (v) => n.update((x) => x.copyWith(fallbackToHandoff: v)),
      ),
      SettingSwitch(title: 'Ask before posting', value: s.confirmBeforePosting, onChanged: (v) => n.update((x) => x.copyWith(confirmBeforePosting: v))),
      SettingRow(
        title: 'Default visibility',
        description: 'For networks that support it.',
        trailing: DropdownButton<PostVisibility>(
          value: s.defaultVisibility,
          underline: const SizedBox.shrink(),
          borderRadius: Radii.rMd,
          items: const [
            DropdownMenuItem(value: PostVisibility.public, child: Text('Public')),
            DropdownMenuItem(value: PostVisibility.unlisted, child: Text('Unlisted')),
            DropdownMenuItem(value: PostVisibility.followers, child: Text('Followers only')),
            DropdownMenuItem(value: PostVisibility.private, child: Text('Private')),
          ],
          onChanged: (v) {
            if (v != null) n.update((x) => x.copyWith(defaultVisibility: v));
          },
        ),
      ),
    ]);
  }
}

class _Desktop extends ConsumerStatefulWidget {
  const _Desktop();

  @override
  ConsumerState<_Desktop> createState() => _DesktopState();
}

class _DesktopState extends ConsumerState<_Desktop> {
  bool? _login;

  @override
  void initState() {
    super.initState();
    DesktopIntegration.instance.isLaunchAtLoginEnabled().then((v) {
      if (mounted) setState(() => _login = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final supported = DesktopIntegration.instance.launchAtLoginSupported;
    return SettingsSection(title: 'Desktop', icon: Icons.desktop_windows_outlined, subtitle: 'Scheduled posts go out while NEFORUM is running.', children: [
      SettingSwitch(
        title: 'Start NEFORUM when I sign in',
        description: supported ? 'Starts minimized in the tray.' : 'Not available on this system.',
        value: _login ?? s.startAtLogin,
        onChanged: !supported
            ? null
            : (v) async {
                final ok = await DesktopIntegration.instance.setLaunchAtLogin(v);
                if (!mounted) return;
                if (ok) {
                  setState(() => _login = v);
                  await n.update((x) => x.copyWith(startAtLogin: v));
                } else {
                  showToast(this.context, 'Could not change the startup setting', icon: Icons.error_outline_rounded);
                }
              },
      ),
      SettingSwitch(
        title: 'Keep running in the tray when I close the window',
        description: 'Recommended: scheduled posts only go out while NEFORUM runs.',
        value: s.minimizeToTray,
        onChanged: (v) => n.update((x) => x.copyWith(minimizeToTray: v)),
      ),
    ]);
  }
}

class _Notifications extends ConsumerWidget {
  const _Notifications();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final how = Env.isIOS
        ? 'On iPhone and iPad, a notification at the scheduled time lets you publish with one tap.'
        : Env.isAndroid
            ? 'Android publishes scheduled posts in the background and tells you how it went.'
            : 'Hand-off networks always get a reminder when it is time to post.';
    return SettingsSection(title: 'Notifications', icon: Icons.notifications_none_rounded, children: [
      SettingRow(
        title: 'Allow notifications',
        description: how,
        stackOnCompact: true,
        trailing: OutlinedButton(
          onPressed: () async {
            final ok = await NotificationService.instance.requestPermission();
            if (context.mounted) showToast(context, ok ? 'Notifications are on' : 'Notifications are off; you can enable them in system settings', icon: ok ? Icons.check_rounded : Icons.info_outline_rounded);
          },
          child: const Text('Allow'),
        ),
      ),
      SettingSwitch(
        title: 'Tell me when scheduled posts go out',
        value: s.notifyOnPublish,
        onChanged: (v) => n.update((x) => x.copyWith(notifyOnPublish: v)),
      ),
    ]);
  }
}

class _Workspace extends ConsumerWidget {
  const _Workspace();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final demo = ref.watch(isDemoProvider);
    return SettingsSection(title: 'Workspace', icon: Icons.science_outlined, children: [
      SettingSwitch(
        title: 'Demo workspace',
        description: Env.isWeb
            ? 'The web preview is always a demo. Install NEFORUM to post for real.'
            : 'Sample accounts and posts to explore NEFORUM. Nothing is really posted. Your real accounts come back when you turn it off.',
        value: demo,
        onChanged: Env.isWeb ? null : (v) => NeforumRoot.of(context).setDemo(v),
      ),
    ]);
  }
}

class _Data extends ConsumerStatefulWidget {
  const _Data();

  @override
  ConsumerState<_Data> createState() => _DataState();
}

class _DataState extends ConsumerState<_Data> {
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
      message: 'This removes every account, key, post, draft and scheduled post from this device. Posts already published stay online. This cannot be undone.',
      confirmLabel: 'Delete everything',
      destructive: true,
    );
    if (!ok) return;
    final s = ref.read(servicesProvider);
    for (final a in await s.accounts.all()) {
      await s.secrets.delete(a.id);
      await s.accounts.delete(a.id);
    }
    for (final p in await s.posts.all()) {
      for (final m in p.media) {
        await s.media.discard(m);
      }
      await s.posts.delete(p.id);
    }
    await ref.read(settingsProvider.notifier).update((x) => x.copyWith(defaultTargetIds: const []));
    if (mounted) {
      showToast(context, 'Everything was deleted', icon: Icons.delete_outline_rounded);
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
        description: 'NEFORUM has no server, no account and no analytics. Your keys and tokens live in the system keychain. Posts go straight from this device to each network.',
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
      SettingRow(
        title: 'Export posts',
        description: 'A JSON file with your posts and account list (without keys).',
        trailing: OutlinedButton.icon(onPressed: _export, icon: const Icon(Icons.download_rounded, size: 18), label: const Text('Export')),
        stackOnCompact: true,
      ),
      SettingRow(
        title: 'Delete everything',
        description: 'Removes all accounts, keys and posts from this device.',
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

class _About extends StatelessWidget {
  const _About();

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    Future<void> open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    return SettingsSection(title: 'About', icon: Icons.info_outline_rounded, children: [
      Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const NeforumWordmark(size: 40, showTagline: true),
          const SizedBox(height: Space.lg),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snap) => Text(
              'Version ${snap.data?.version ?? '0.1.0'} · ${Env.platformName}',
              style: monoStyle(context, size: 12.5),
            ),
          ),
          const SizedBox(height: Space.sm),
          Text('Free and open-source software under the GNU General Public License v3.', style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
          const SizedBox(height: Space.lg),
          Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
            OutlinedButton.icon(onPressed: () => open('https://github.com/neforum-app/neforum'), icon: const Icon(Icons.code_rounded, size: 18), label: const Text('Source code')),
            OutlinedButton.icon(onPressed: () => showGuideSheet(context, 'platforms', asset: 'platforms.md'), icon: const Icon(Icons.table_chart_outlined, size: 18), label: const Text('Platform guide')),
            OutlinedButton.icon(onPressed: () => open('https://github.com/neforum-app/neforum/issues'), icon: const Icon(Icons.bug_report_outlined, size: 18), label: const Text('Report a problem')),
          ]),
          const SizedBox(height: Space.xl),
          Text('Credits', style: context.text.titleSmall),
          const SizedBox(height: Space.xs),
          Text(
            'Fonts: Inter, Bricolage Grotesque and JetBrains Mono (SIL Open Font License). Platform logos: Font Awesome Brands (CC BY 4.0); trademarks belong to their owners. Icons: Material Symbols (Apache 2.0).',
            style: context.text.bodySmall,
          ),
        ]),
      ),
    ]);
  }
}
