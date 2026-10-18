import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/neforum_logo.dart';
import '../../platform/desktop.dart';
import '../../platform/env.dart';
import '../../platform/notifications.dart';
import '../../platform/ui_bridge.dart';
import '../../state/composer.dart';
import '../../state/composer_draft.dart';
import '../../state/providers.dart';
import '../../state/scheduler.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/buttons.dart';
import '../handoff/handoff_sheet.dart';
import '../root.dart';
import '../router.dart';
import 'paste_code_dialog.dart';

/// Adaptive frame around the five sections: sidebar on wide windows, an
/// icon rail on medium ones, a bottom bar on phones.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  StreamSubscription<NotificationIntent>? _intentSub;

  @override
  void initState() {
    super.initState();
    UiBridge.instance = _ShellUiBridge();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(schedulerProvider).start();
      _intentSub = NotificationService.instance.intents.listen(_onIntent);
      final launch = NotificationService.instance.launchIntent;
      if (launch != null) {
        NotificationService.instance.launchIntent = null;
        _onIntent(launch);
      }
      DesktopIntegration.instance.initTray(_onTray);
    });
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    super.dispose();
  }

  void _go(AppSection s) {
    final i = AppSection.values.indexOf(s);
    widget.shell.goBranch(i, initialLocation: i == widget.shell.currentIndex);
  }

  Future<void> _onIntent(NotificationIntent intent) async {
    await DesktopIntegration.instance.showWindow();
    if (!mounted) return;
    switch (intent) {
      case OpenPostIntent(:final postId):
        context.go('${AppSection.activity.path}/post/$postId');
      case RunHandoffIntent(:final postId, :final accountId):
        context.go('${AppSection.activity.path}/post/$postId');
        await ref.read(postActionsProvider).runHandoff(postId, accountId);
      case PublishDueIntent(:final postId):
        context.go('${AppSection.activity.path}/post/$postId');
        await ref.read(postActionsProvider).publishExisting(postId, retryFailed: false);
    }
  }

  Future<void> _onTray(TrayAction a) async {
    switch (a) {
      case TrayAction.show:
        await DesktopIntegration.instance.showWindow();
      case TrayAction.compose:
        await DesktopIntegration.instance.showWindow();
        ref.read(composerProvider.notifier).reset();
        _go(AppSection.compose);
      case TrayAction.publishDue:
        await ref.read(schedulerProvider).runDue(interactive: true);
      case TrayAction.quit:
        await DesktopIntegration.instance.quit();
    }
  }

  void _newPost() {
    ref.read(composerProvider.notifier).reset();
    _go(AppSection.compose);
  }

  @override
  Widget build(BuildContext context) {
    final w = context.width;
    final nf = context.nf;
    // Keeps the post being written across restarts.
    ref.watch(composerDraftKeeperProvider);
    final demo = ref.watch(isDemoProvider);
    final scheduled = ref.watch(scheduledPostsProvider).length;
    final attention = ref.watch(needsAttentionProvider).length;
    final badges = <AppSection, int>{AppSection.queue: scheduled, AppSection.activity: attention};
    final current = AppSection.values[widget.shell.currentIndex];

    final body = Column(children: [
      if (demo) const _DemoBanner(),
      Expanded(child: widget.shell),
    ]);

    if (w < Breakpoints.compact) {
      return Scaffold(
        backgroundColor: nf.bg,
        body: SafeArea(bottom: false, child: body),
        bottomNavigationBar: ColoredBox(
          color: nf.chrome,
          child: NavigationBar(
            selectedIndex: widget.shell.currentIndex,
            onDestinationSelected: (i) => _go(AppSection.values[i]),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: [
              for (final s in AppSection.values)
                NavigationDestination(
                  icon: _badged(Icon(s.icon), badges[s] ?? 0, s == AppSection.activity),
                  selectedIcon: _badged(Icon(s.selectedIcon), badges[s] ?? 0, s == AppSection.activity),
                  label: s.label,
                ),
            ],
          ),
        ),
      );
    }

    final expanded = w >= Breakpoints.expanded;
    return Scaffold(
      backgroundColor: nf.bg,
      body: SafeArea(
        child: Row(children: [
          expanded
              ? _Sidebar(current: current, badges: badges, onSelect: _go, onNewPost: _newPost)
              : _Rail(current: current, badges: badges, onSelect: _go, onNewPost: _newPost),
          Expanded(child: body),
        ]),
      ),
    );
  }

  Widget _badged(Widget icon, int count, bool urgent) {
    if (count == 0) return icon;
    return Badge(
      label: Text('$count'),
      backgroundColor: urgent ? context.nf.highlight : context.nf.onChrome,
      textColor: context.nf.onHighlight,
      child: icon,
    );
  }
}

// ---------------------------------------------------------------------------

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.current, required this.badges, required this.onSelect, required this.onNewPost});

  final AppSection current;
  final Map<AppSection, int> badges;
  final ValueChanged<AppSection> onSelect;
  final VoidCallback onNewPost;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final accounts = ref.watch(accountListProvider);
    return Container(
      width: 264,
      color: nf.chrome,
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.xxl, Space.lg, Space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Space.sm),
          child: NeforumWordmark(size: 32, showTagline: true, onChrome: true),
        ),
        const SizedBox(height: Space.x3),
        PrimaryAction(label: 'New post', icon: Icons.add_rounded, onPressed: onNewPost, expand: true, onChrome: true),
        const SizedBox(height: Space.xxl),
        for (final s in AppSection.values) ...[
          _NavItem(
            section: s,
            selected: s == current,
            badge: badges[s] ?? 0,
            urgent: s == AppSection.activity,
            onTap: () => onSelect(s),
          ),
          const SizedBox(height: Space.xxs),
        ],
        const Spacer(),
        if (accounts.isNotEmpty)
          _ConnectedSummary(accounts: accounts, onTap: () => onSelect(AppSection.accounts)),
        const SizedBox(height: Space.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.sm),
          child: Text('v$kAppVersion · Free & open source · GPL-3.0', style: context.text.bodySmall?.copyWith(color: nf.onChromeMuted, fontSize: 11)),
        ),
      ]),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({required this.section, required this.selected, required this.badge, required this.urgent, required this.onTap});

  final AppSection section;
  final bool selected;
  final int badge;
  final bool urgent;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final sel = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          selected: sel,
          label: widget.section.label,
          child: AnimatedContainer(
            duration: Motion.fast,
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            decoration: BoxDecoration(
              color: sel ? nf.chromeRaised : (_hover ? nf.onChrome.withValues(alpha: 0.05) : Colors.transparent),
              borderRadius: Radii.rMd,
            ),
            child: Row(children: [
              AnimatedContainer(
                duration: Motion.fast,
                width: 3,
                height: sel ? 18 : 0,
                margin: const EdgeInsets.only(right: Space.sm),
                decoration: BoxDecoration(color: nf.highlight, borderRadius: Radii.rPill),
              ),
              Icon(sel ? widget.section.selectedIcon : widget.section.icon, size: 20, color: sel ? nf.highlight : nf.onChromeMuted),
              const SizedBox(width: Space.md),
              Expanded(
                child: Text(
                  widget.section.label,
                  style: context.text.labelLarge?.copyWith(
                    color: sel ? nf.onChrome : nf.onChromeMuted,
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (widget.badge > 0)
                Container(
                  constraints: const BoxConstraints(minWidth: 22),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: widget.urgent ? nf.highlight : nf.onChrome.withValues(alpha: sel ? 0.16 : 0.10),
                    borderRadius: Radii.rPill,
                  ),
                  child: Text(
                    '${widget.badge}',
                    textAlign: TextAlign.center,
                    style: context.text.labelSmall?.copyWith(color: widget.urgent ? nf.onHighlight : nf.onChrome, fontWeight: FontWeight.w700),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ConnectedSummary extends StatelessWidget {
  const _ConnectedSummary({required this.accounts, required this.onTap});
  final List<ConnectedAccount> accounts;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final auto = accounts.where((a) => a.tier != PlatformTier.handoff).length;
    final hand = accounts.length - auto;
    return Material(
      color: nf.chromeRaised,
      borderRadius: Radii.rMd,
      child: InkWell(
        borderRadius: Radii.rMd,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            PlatformStack(accounts.map((a) => a.platformId).toList(), size: 22, max: 7),
            const SizedBox(height: Space.sm),
            Text('${accounts.length} connected', style: context.text.labelMedium?.copyWith(color: nf.onChrome)),
            const SizedBox(height: 2),
            Text(
              '$auto automatic${hand > 0 ? ' · $hand hand-off' : ''}',
              style: context.text.bodySmall?.copyWith(color: nf.onChromeMuted, fontSize: 11.5),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.current, required this.badges, required this.onSelect, required this.onNewPost});

  final AppSection current;
  final Map<AppSection, int> badges;
  final ValueChanged<AppSection> onSelect;
  final VoidCallback onNewPost;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Container(
      width: 88,
      color: nf.chrome,
      padding: const EdgeInsets.symmetric(vertical: Space.xl),
      child: Column(children: [
        const NeforumMark(size: 38),
        const SizedBox(height: Space.xxl),
        Tooltip(
          message: 'New post',
          child: GestureDetector(
            onTap: onNewPost,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: nf.highlight, borderRadius: Radii.rLg, boxShadow: nf.glow(nf.highlight, strength: 0.6)),
                child: Icon(Icons.add_rounded, color: nf.onHighlight, size: 26),
              ),
            ),
          ),
        ),
        const SizedBox(height: Space.xxl),
        for (final s in AppSection.values)
          _RailItem(section: s, selected: s == current, badge: badges[s] ?? 0, urgent: s == AppSection.activity, onTap: () => onSelect(s)),
      ]),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({required this.section, required this.selected, required this.badge, required this.urgent, required this.onTap});

  final AppSection section;
  final bool selected;
  final int badge;
  final bool urgent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final icon = Icon(selected ? section.selectedIcon : section.icon, size: 22, color: selected ? nf.onHighlight : nf.onChromeMuted);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.rMd,
        child: SizedBox(
          width: 72,
          child: Column(children: [
            AnimatedContainer(
              duration: Motion.fast,
              width: 52,
              height: 32,
              decoration: BoxDecoration(color: selected ? nf.highlight : Colors.transparent, borderRadius: Radii.rPill),
              child: Center(
                child: badge > 0
                    ? Badge(label: Text('$badge'), backgroundColor: urgent ? nf.highlight : nf.onChrome, textColor: nf.onHighlight, child: icon)
                    : icon,
              ),
            ),
            const SizedBox(height: Space.xs),
            Text(
              section.label,
              style: context.text.labelSmall?.copyWith(color: selected ? nf.onChrome : nf.onChromeMuted, fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
            ),
            const SizedBox(height: Space.xs),
          ]),
        ),
      ),
    );
  }
}

class _DemoBanner extends StatelessWidget {
  const _DemoBanner();

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
      decoration: BoxDecoration(color: nf.warningSoft, border: Border(bottom: BorderSide(color: nf.border))),
      child: Row(children: [
        Icon(Icons.science_rounded, size: 16, color: nf.warning),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Text(
            Env.isWeb
                ? 'Web preview: a demo workspace. Nothing is posted for real. Install the app for Android, iOS, macOS or Windows to post.'
                : 'Demo workspace: sample accounts, nothing is posted for real.',
            style: context.text.bodySmall?.copyWith(color: nf.text),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (!Env.isWeb)
          TextButton(
            onPressed: () => NeforumRoot.of(context).setDemo(false),
            child: const Text('Leave demo'),
          ),
      ]),
    );
  }
}

/// UI implementation of [UiBridge] attached to the root navigator.
class _ShellUiBridge implements UiBridge {
  BuildContext? get _ctx => rootNavigatorKey.currentContext;

  @override
  bool get interactive => _ctx != null;

  @override
  Future<String?> askPaste(Uri authorizationUrl, Uri redirectUri) async {
    final ctx = _ctx;
    if (ctx == null) return null;
    return showPasteCodeDialog(ctx, authorizationUrl: authorizationUrl, redirectUri: redirectUri);
  }

  @override
  Future<HandoffChoice> showHandoff(HandoffPlan plan, {required Post post, required ConnectedAccount account, required PostVariant variant}) async {
    final ctx = _ctx;
    if (ctx == null) return HandoffChoice.later;
    await DesktopIntegration.instance.showWindow();
    if (!ctx.mounted) return HandoffChoice.later;
    return showHandoffSheet(ctx, plan: plan, post: post, account: account, variant: variant);
  }
}
