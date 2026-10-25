import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/env.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart';
import 'about_section.dart';
import 'activity_section.dart';
import 'appearance_section.dart';
import 'artwork_section.dart';
import 'browser_extension_section.dart';
import 'data_section.dart';
import 'desktop_section.dart';
import 'media_host_section.dart';
import 'notifications_section.dart';
import 'posting_section.dart';
import 'scheduling_section.dart';
import 'sync_section.dart';
import 'text_cards_section.dart';
import 'workspace_section.dart';

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
      ('Appearance', Icons.palette_outlined, const AppearanceSettingsSection()),
      ('Posting', Icons.send_outlined, const PostingSettingsSection()),
      ('Scheduling', Icons.event_available_outlined, const SchedulingSettingsSection()),
      ('Text cards', Icons.text_fields_rounded, const TextCardSettingsSection()),
      ('Artwork', Icons.brush_outlined, const ArtworkSettingsSection()),
      ('Activity and history', Icons.history_rounded, const ActivitySettingsSection()),
      ('Media hosting', Icons.cloud_upload_outlined, const MediaHostSection()),
      if (Env.isDesktop) ('Desktop', Icons.desktop_windows_outlined, const DesktopSettingsSection()),
      if (Env.isDesktop) ('Browser extension', Icons.extension_outlined, const BrowserExtensionSection()),
      ('Notifications', Icons.notifications_none_rounded, const NotificationSettingsSection()),
      ('Sync', Icons.sync_rounded, const SyncSection()),
      ('Workspace', Icons.science_outlined, const WorkspaceSettingsSection()),
      ('Data & privacy', Icons.shield_outlined, const DataSettingsSection()),
      ('About', Icons.info_outline_rounded, const AboutSettingsSection()),
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
