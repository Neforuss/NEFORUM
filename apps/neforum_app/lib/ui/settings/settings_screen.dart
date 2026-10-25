import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/env.dart';
import '../../state/providers.dart';
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
import 'setting_row.dart';
import 'sync_section.dart';
import 'text_cards_section.dart';
import 'workspace_section.dart';

/// One entry of the Settings page. [title] is the section's own
/// `SettingsSection` title: it names the section in the table of contents and
/// in the list of folded sections.
typedef _Section = ({String title, IconData icon, Widget body});

/// Settings, grouped into sections that fold away. Where the page is wide
/// enough, a table of contents stays beside them and marks the section in
/// view; on narrower pages a bar of section chips stays above them, with a
/// "Jump to" list.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  /// Page width from which the table of contents fits beside the sections.
  static const double tableOfContentsMinWidth = 840;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const double _tocWidth = 200;
  static const double _maxWidth = 1120;

  final _keys = <String, GlobalKey>{};
  final _chipKeys = <String, GlobalKey>{};
  final _scroll = ScrollController();
  final _chipScroll = ScrollController();

  /// Titles in page order, from the last build.
  List<String> _titles = const [];

  /// The section in view.
  String? _current;

  /// The section a jump is scrolling to; the scroll position does not change
  /// [_current] until the jump has finished.
  String? _jumpTarget;

  GlobalKey _key(String title) => _keys.putIfAbsent(title, GlobalKey.new);
  GlobalKey _chipKey(String title) => _chipKeys.putIfAbsent(title, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateCurrent());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _chipScroll.dispose();
    super.dispose();
  }

  void _onScroll() => _updateCurrent();

  /// The section in view is the last one whose top has passed the upper part
  /// of the page; at the very end of the page, the last section.
  void _updateCurrent() {
    if (!mounted || _jumpTarget != null || !_scroll.hasClients || _titles.isEmpty) return;
    final position = _scroll.position;
    final line = position.pixels + math.min(160.0, position.viewportDimension * 0.3);
    var found = _titles.first;
    for (final title in _titles) {
      final box = _keys[title]?.currentContext?.findRenderObject();
      if (box == null || !box.attached) continue;
      if (RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset > line) break;
      found = title;
    }
    if (position.maxScrollExtent > 0 && position.pixels >= position.maxScrollExtent - 1) found = _titles.last;
    if (found == _current) return;
    setState(() => _current = found);
    _revealChip(found);
  }

  /// Scrolls the chip bar (narrow pages) so [title]'s chip shows.
  void _revealChip(String title) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chip = _chipKeys[title]?.currentContext;
      if (chip != null && chip.mounted) Scrollable.ensureVisible(chip, alignment: 0.5, duration: Motion.medium, curve: Motion.standard);
    });
  }

  /// Opens [title] if it is folded and scrolls to it.
  Future<void> _jumpTo(String title) async {
    if (ref.read(settingsProvider).collapsedSettingsSections.contains(title)) _setCollapsed({title}, false);
    setState(() {
      _current = title;
      _jumpTarget = title;
    });
    _revealChip(title);
    // Wait for the section to be laid out open.
    await WidgetsBinding.instance.endOfFrame;
    final target = _keys[title]?.currentContext;
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(target, duration: Motion.slow, curve: Motion.standard, alignment: 0.02);
    }
    if (mounted && _jumpTarget == title) _jumpTarget = null;
  }

  void _toggle(String title) {
    final collapsed = ref.read(settingsProvider).collapsedSettingsSections.contains(title);
    _setCollapsed({title}, !collapsed);
  }

  /// Folds ([collapse]) or opens the sections named in [titles]; the choice
  /// is kept for the next launch.
  void _setCollapsed(Set<String> titles, bool collapse) {
    ref.read(settingsProvider.notifier).update((s) {
      final next = {...s.collapsedSettingsSections};
      collapse ? next.addAll(titles) : next.removeAll(titles);
      return s.copyWith(collapsedSettingsSections: next.toList());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateCurrent());
  }

  void _expandAll() => _setCollapsed(_titles.toSet(), false);
  void _collapseAll() => _setCollapsed(_titles.toSet(), true);

  Future<void> _openJumpSheet(List<_Section> sections) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _JumpSheet(
        sections: sections,
        current: _current ?? sections.first.title,
        onExpandAll: _expandAll,
        onCollapseAll: _collapseAll,
      ),
    );
    if (picked != null && mounted) await _jumpTo(picked);
  }

  @override
  Widget build(BuildContext context) {
    final collapsed = ref.watch(settingsProvider.select((s) => s.collapsedSettingsSections)).toSet();
    final sections = <_Section>[
      (title: 'Appearance', icon: Icons.palette_outlined, body: const AppearanceSettingsSection()),
      (title: 'Posting', icon: Icons.send_outlined, body: const PostingSettingsSection()),
      (title: 'Scheduling', icon: Icons.event_available_outlined, body: const SchedulingSettingsSection()),
      (title: 'Text cards', icon: Icons.text_fields_rounded, body: const TextCardSettingsSection()),
      (title: 'Artwork', icon: Icons.brush_outlined, body: const ArtworkSettingsSection()),
      (title: 'Activity and history', icon: Icons.history_rounded, body: const ActivitySettingsSection()),
      (title: 'Media hosting', icon: Icons.cloud_upload_outlined, body: const MediaHostSection()),
      if (Env.isDesktop) (title: 'Desktop', icon: Icons.desktop_windows_outlined, body: const DesktopSettingsSection()),
      if (Env.isDesktop) (title: 'Browser extension', icon: Icons.extension_outlined, body: const BrowserExtensionSection()),
      (title: 'Notifications', icon: Icons.notifications_none_rounded, body: const NotificationSettingsSection()),
      (title: 'Sync', icon: Icons.sync_rounded, body: const SyncSection()),
      (title: 'Workspace', icon: Icons.science_outlined, body: const WorkspaceSettingsSection()),
      (title: 'Data & privacy', icon: Icons.shield_outlined, body: const DataSettingsSection()),
      (title: 'About', icon: Icons.info_outline_rounded, body: const AboutSettingsSection()),
    ];
    _titles = [for (final s in sections) s.title];
    final current = _current ?? _titles.first;

    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const PageHeader(eyebrow: 'Settings', title: 'Make NEFORUM yours'),
      const SizedBox(height: Space.x3),
      for (final s in sections) ...[
        KeyedSubtree(key: _key(s.title), child: s.body),
        SizedBox(height: collapsed.contains(s.title) ? Space.lg : Space.x3),
      ],
    ]);

    return SettingsSectionScope(
      collapsed: collapsed,
      onToggle: _toggle,
      child: LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth >= SettingsScreen.tableOfContentsMinWidth) {
          // The table of contents sits over the page's left column, outside
          // the scrolling content, so it stays where it is.
          final gutters = PageBody.gutters(context);
          final available = constraints.maxWidth - gutters.horizontal;
          final left = gutters.left + math.max(0.0, (available - _maxWidth) / 2);
          return Stack(children: [
            PageBody(controller: _scroll, maxWidth: _maxWidth, children: [
              Padding(padding: const EdgeInsets.only(left: _tocWidth + Space.x3), child: content),
            ]),
            Positioned(
              left: left,
              top: 0,
              bottom: 0,
              width: _tocWidth,
              child: _ForwardScroll(
                to: _scroll,
                child: _TableOfContents(
                  sections: sections,
                  current: current,
                  collapsed: collapsed,
                  onJump: _jumpTo,
                  onExpandAll: _expandAll,
                  onCollapseAll: _collapseAll,
                ),
              ),
            ),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _SectionBar(
            sections: sections,
            current: current,
            chipKey: _chipKey,
            controller: _chipScroll,
            onJump: _jumpTo,
            onOpenList: () => _openJumpSheet(sections),
          ),
          Expanded(child: PageBody(controller: _scroll, maxWidth: 880, children: [content])),
        ]);
      }),
    );
  }
}

/// Mouse wheel turns over [child] scroll the page ([to]) when [child] has
/// nothing to scroll itself.
class _ForwardScroll extends StatelessWidget {
  const _ForwardScroll({required this.to, required this.child});

  final ScrollController to;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent || !to.hasClients) return;
          GestureBinding.instance.pointerSignalResolver.register(event, (e) => to.position.pointerScroll((e as PointerScrollEvent).scrollDelta.dy));
        },
        child: child,
      );
}

/// The pinned table of contents of wide pages.
class _TableOfContents extends StatelessWidget {
  const _TableOfContents({
    required this.sections,
    required this.current,
    required this.collapsed,
    required this.onJump,
    required this.onExpandAll,
    required this.onCollapseAll,
  });

  final List<_Section> sections;
  final String current;
  final Set<String> collapsed;
  final ValueChanged<String> onJump;
  final VoidCallback onExpandAll;
  final VoidCallback onCollapseAll;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final anyCollapsed = sections.any((s) => collapsed.contains(s.title));
    final allCollapsed = sections.every((s) => collapsed.contains(s.title));
    final small = TextButton.styleFrom(
      foregroundColor: nf.textMuted,
      textStyle: context.text.labelMedium,
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
      minimumSize: const Size(0, 32),
    );
    return SingleChildScrollView(
      padding: EdgeInsets.only(top: PageBody.topPadding(context), bottom: Space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(left: Space.md),
          child: Text('ON THIS PAGE', style: context.text.labelSmall?.copyWith(color: nf.textFaint, letterSpacing: 1.4)),
        ),
        const SizedBox(height: Space.xs),
        Wrap(children: [
          TextButton(onPressed: anyCollapsed ? onExpandAll : null, style: small, child: const Text('Expand all')),
          TextButton(onPressed: allCollapsed ? null : onCollapseAll, style: small, child: const Text('Collapse all')),
        ]),
        const SizedBox(height: Space.sm),
        for (final s in sections) _TableOfContentsEntry(section: s, current: s.title == current, collapsed: collapsed.contains(s.title), onTap: () => onJump(s.title)),
      ]),
    );
  }
}

class _TableOfContentsEntry extends StatelessWidget {
  const _TableOfContentsEntry({required this.section, required this.current, required this.collapsed, required this.onTap});

  final _Section section;
  final bool current;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Semantics(
      selected: current,
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(section.icon, size: 17),
        label: Row(children: [
          Expanded(child: Text(section.title, overflow: TextOverflow.ellipsis)),
          if (collapsed) Tooltip(message: 'Collapsed', child: Icon(Icons.chevron_right_rounded, size: 16, color: nf.textFaint)),
        ]),
        style: TextButton.styleFrom(
          foregroundColor: current ? nf.accent : nf.textMuted,
          backgroundColor: current ? nf.accentSoft : null,
          textStyle: context.text.labelLarge?.copyWith(fontWeight: current ? FontWeight.w700 : FontWeight.w500),
          alignment: Alignment.centerLeft,
        ),
      ),
    );
  }
}

/// The pinned bar of narrow pages: a chip per section, the one in view
/// marked, and "Jump to" for the full list.
class _SectionBar extends StatelessWidget {
  const _SectionBar({
    required this.sections,
    required this.current,
    required this.chipKey,
    required this.controller,
    required this.onJump,
    required this.onOpenList,
  });

  final List<_Section> sections;
  final String current;
  final GlobalKey Function(String title) chipKey;
  final ScrollController controller;
  final ValueChanged<String> onJump;
  final VoidCallback onOpenList;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final gutter = PageBody.gutters(context).left;
    return DecoratedBox(
      decoration: BoxDecoration(color: nf.bg, border: Border(bottom: BorderSide(color: nf.border))),
      child: Row(children: [
        Expanded(
          child: SingleChildScrollView(
            controller: controller,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(gutter, Space.sm, Space.sm, Space.sm),
            child: Row(children: [
              for (final s in sections)
                Padding(
                  padding: const EdgeInsets.only(right: Space.sm),
                  child: ChoiceChip(
                    key: chipKey(s.title),
                    label: Text(s.title),
                    selected: s.title == current,
                    onSelected: (_) => onJump(s.title),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    side: BorderSide(color: s.title == current ? nf.accent : nf.border),
                    labelStyle: context.text.labelMedium?.copyWith(
                      color: s.title == current ? nf.accent : nf.textMuted,
                      fontWeight: s.title == current ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
            ]),
          ),
        ),
        Container(width: 1, height: 24, color: nf.border),
        Padding(
          padding: EdgeInsets.only(left: Space.xs, right: gutter - Space.sm),
          child: TextButton.icon(onPressed: onOpenList, icon: const Icon(Icons.toc_rounded, size: 18), label: const Text('Jump to')),
        ),
      ]),
    );
  }
}

/// "Jump to": every section, the one in view marked. Returns the picked
/// title.
class _JumpSheet extends ConsumerWidget {
  const _JumpSheet({required this.sections, required this.current, required this.onExpandAll, required this.onCollapseAll});

  final List<_Section> sections;
  final String current;
  final VoidCallback onExpandAll;
  final VoidCallback onCollapseAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final collapsed = ref.watch(settingsProvider.select((s) => s.collapsedSettingsSections)).toSet();
    final anyCollapsed = sections.any((s) => collapsed.contains(s.title));
    final allCollapsed = sections.every((s) => collapsed.contains(s.title));
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.lg, Space.xs),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Space.sm,
              children: [
                Text('Jump to', style: context.text.titleLarge),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  TextButton(onPressed: anyCollapsed ? onExpandAll : null, child: const Text('Expand all')),
                  TextButton(onPressed: allCollapsed ? null : onCollapseAll, child: const Text('Collapse all')),
                ]),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(Space.sm, 0, Space.sm, Space.lg),
              children: [
                for (final s in sections)
                  ListTile(
                    leading: Icon(s.icon, size: 20),
                    title: Text(s.title),
                    subtitle: collapsed.contains(s.title) ? const Text('Collapsed') : null,
                    selected: s.title == current,
                    trailing: s.title == current ? Icon(Icons.check_rounded, color: nf.accent) : null,
                    onTap: () => Navigator.of(context).pop(s.title),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
