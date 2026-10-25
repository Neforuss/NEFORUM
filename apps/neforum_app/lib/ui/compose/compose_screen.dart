import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../platform/env.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart';
import '../activity/time_format.dart';
import '../queue/post_menu.dart';
import '../router.dart';
import 'action_bar.dart';
import 'differentiation_panel.dart';
import 'editor_card.dart';
import 'media_tray.dart';
import 'preview_pane.dart';
import 'publish_progress_sheet.dart';
import 'schedule_sheet.dart';
import 'target_picker.dart';

/// Write once, preview everywhere, post.
class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key, this.editPostId});

  /// Opens an existing draft or scheduled post for editing.
  final String? editPostId;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

enum _Pane { write, preview }

class _ComposeScreenState extends ConsumerState<ComposeScreen> with WidgetsBindingObserver {
  final _focus = FocusNode();
  final _previewScroll = ScrollController();
  _Pane _pane = _Pane.write;
  String? _loadedId;
  bool _busy = false;

  /// Phones and tablets: the on-screen keyboard is showing.
  bool _keyboardOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    _previewScroll.dispose();
    super.dispose();
  }

  /// The keyboard opening or closing changes the view's bottom inset. The
  /// app shell's Scaffold takes that inset out of this screen's MediaQuery,
  /// so it is read from the view itself.
  @override
  void didChangeMetrics() {
    if (!mounted || !Env.isMobile) return;
    final open = View.of(context).viewInsets.bottom > 0;
    if (open != _keyboardOpen) setState(() => _keyboardOpen = open);
  }

  /// Takes the cursor out of the text field, which closes the keyboard.
  void _hideKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  void _maybeLoad() {
    final id = widget.editPostId;
    if (id == null || id == _loadedId) return;
    final post = ref.read(postByIdProvider(id));
    if (post == null) return;
    _loadedId = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(composerProvider.notifier).load(post);
    });
  }

  Future<void> _saveDraft() async {
    if (ref.read(composerProvider).isEmpty) {
      showToast(context, 'Nothing to save yet', icon: Icons.info_outline_rounded);
      return;
    }
    try {
      await ref.read(postActionsProvider).saveDraft();
    } on HeldCopiesException catch (e) {
      if (mounted) await showHeldCopiesDialog(context, e);
      return;
    }
    if (!mounted) return;
    ref.read(composerProvider.notifier).reset();
    showToast(context, 'Saved to drafts', icon: Icons.check_circle_rounded, actionLabel: 'View', onAction: () => context.go(AppSection.queue.path));
  }

  Future<void> _schedule() async {
    final current = ref.read(composerProvider).scheduledAt;
    final when = await showScheduleSheet(context, initial: current);
    if (when == null || !mounted) return;
    ref.read(composerProvider.notifier).setSchedule(when == kClearSchedule ? null : when);
  }

  Future<void> _publish() async {
    final settings = ref.read(settingsProvider);
    final c = ref.read(composerProvider);
    final r = ref.read(composerReadinessProvider);
    if (!r.canPublish || c.isEmpty || _busy) return;
    final targets = r.ready + r.handoff;
    if (settings.confirmBeforePosting && c.scheduledAt == null) {
      final ok = await confirmDialog(context, title: 'Post to $targets ${targets == 1 ? 'network' : 'networks'}?', message: 'Your post goes out right away.', confirmLabel: 'Post now');
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final actions = ref.read(postActionsProvider);
      if (c.scheduledAt != null) {
        final when = c.scheduledAt!;
        await actions.schedule();
        if (!mounted) return;
        ref.read(composerProvider.notifier).reset();
        showToast(context, 'Scheduled for ${TimeFormatting.from(settings, context).scheduled(when)}',
            icon: Icons.event_available_rounded, actionLabel: 'View queue', onAction: () => context.go(AppSection.queue.path));
      } else {
        // publishNow empties the composer once the post is saved; the sheet
        // follows the run, and shows why it stopped if it fails.
        final future = actions.publishNow();
        if (mounted) {
          // Shown alongside the run; it watches the live progress.
          // ignore: unawaited_futures
          showPublishProgress(context);
        }
        try {
          await future;
        } on Object catch (e) {
          // The sheet shows the error with a Close button.
          debugPrint('Publishing stopped: $e');
        }
      }
    } on HeldCopiesException catch (e) {
      if (mounted) await showHeldCopiesDialog(context, e);
    } on Object catch (e) {
      if (mounted) showToast(context, 'Could not publish: $e', icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showProblems() {
    if (!context.isExpanded) setState(() => _pane = _Pane.preview);
    if (_previewScroll.hasClients) _previewScroll.animateTo(0, duration: Motion.medium, curve: Motion.standard);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(postByIdProvider(widget.editPostId ?? ''), (_, _) => _maybeLoad());
    _maybeLoad();
    final nf = context.nf;
    final expanded = context.isExpanded;
    final compact = context.isCompact;
    final previews = ref.watch(composerPreviewsProvider);

    final actionBar = ComposerActionBar(
      onSaveDraft: _saveDraft,
      onSchedule: _schedule,
      onPublish: _publish,
      onShowProblems: _showProblems,
      onHideKeyboard: Env.isMobile && _keyboardOpen ? _hideKeyboard : null,
      busy: _busy,
    );

    final write = _WriteColumn(focusNode: _focus, editing: widget.editPostId != null, scrollableTargets: compact);

    final Widget body;
    if (expanded) {
      body = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          flex: 11,
          child: Column(children: [Expanded(child: write), actionBar]),
        ),
        Container(width: 1, color: nf.border),
        SizedBox(
          width: (context.width * 0.34).clamp(380.0, 580.0),
          child: ColoredBox(
            color: nf.surfaceSunken.withValues(alpha: nf.isDark ? 0.5 : 0.6),
            child: PreviewPane(controller: _previewScroll, padding: const EdgeInsets.fromLTRB(Space.xl, Space.x4, Space.xl, Space.xl)),
          ),
        ),
      ]);
    } else {
      body = Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(compact ? Space.lg : Space.xxl, Space.md, compact ? Space.lg : Space.xxl, Space.sm),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<_Pane>(
              segments: [
                const ButtonSegment(value: _Pane.write, label: Text('Write'), icon: Icon(Icons.edit_outlined, size: 18)),
                ButtonSegment(value: _Pane.preview, label: Text('Preview (${previews.length})'), icon: const Icon(Icons.visibility_outlined, size: 18)),
              ],
              selected: {_pane},
              onSelectionChanged: (s) {
                // The keyboard would only cover the previews.
                if (Env.isMobile && s.first == _Pane.preview) _hideKeyboard();
                setState(() => _pane = s.first);
              },
              showSelectedIcon: false,
            ),
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: Motion.medium,
            switchInCurve: Motion.standard,
            child: _pane == _Pane.write
                ? KeyedSubtree(key: const ValueKey('w'), child: write)
                : KeyedSubtree(
                    key: const ValueKey('p'),
                    child: PreviewPane(controller: _previewScroll, showHeader: false, padding: EdgeInsets.fromLTRB(compact ? Space.lg : Space.xxl, Space.sm, compact ? Space.lg : Space.xxl, Space.xl)),
                  ),
          ),
        ),
        actionBar,
      ]);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _publish,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _publish,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _saveDraft,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _saveDraft,
      },
      child: Focus(
        autofocus: false,
        // Phones and tablets: a tap outside the text fields closes the
        // keyboard (text fields, buttons and chips keep their own taps).
        child: Env.isMobile ? GestureDetector(onTap: _hideKeyboard, child: body) : body,
      ),
    );
  }
}

/// Phones and tablets: a downward drag on the write column closes the
/// keyboard, as a swipe down on it does in other apps. Flutter receives no
/// touches on the keyboard itself, so this is the nearest equivalent.
/// Upward drags only scroll.
class _DragDownHidesKeyboard extends StatelessWidget {
  const _DragDownHidesKeyboard({required this.child});
  final Widget child;

  bool _onScroll(ScrollNotification n) {
    // Only the column's own scroll view, not the sideways lists in it.
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final drag = switch (n) {
      ScrollUpdateNotification(:final dragDetails) => dragDetails,
      // At the top of the page a downward drag cannot scroll any further.
      OverscrollNotification(:final dragDetails) => dragDetails,
      _ => null,
    };
    final focus = FocusManager.instance.primaryFocus;
    if (drag != null && drag.delta.dy > 0 && focus != null && focus is! FocusScopeNode) focus.unfocus();
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollNotification>(onNotification: _onScroll, child: child);
}

class _WriteColumn extends ConsumerWidget {
  const _WriteColumn({required this.focusNode, required this.editing, required this.scrollableTargets});
  final FocusNode focusNode;
  final bool editing;
  final bool scrollableTargets;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final c = ref.watch(composerProvider);
    final editingPost = c.editingPostId == null ? null : ref.watch(postByIdProvider(c.editingPostId!));
    final title = editingPost == null
        ? 'New post'
        : editingPost.status == PostStatus.scheduled
            ? 'Edit scheduled post'
            : 'Edit draft';
    final compact = context.isCompact;

    final page = PageBody(
      maxWidth: 780,
      bottomPadding: Space.xxl,
      // A short post can still be dragged down to close the keyboard.
      physics: Env.isMobile ? const AlwaysScrollableScrollPhysics() : null,
      children: [
        if (!compact || editingPost != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.xl),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('COMPOSE', style: context.text.labelSmall?.copyWith(color: nf.accent, letterSpacing: 1.6)),
                  const SizedBox(height: Space.xs + 2),
                  Text(title, style: compact ? context.text.headlineLarge : context.text.displaySmall),
                ]),
              ),
              if (editingPost != null)
                TextButton.icon(
                  onPressed: () {
                    ref.read(composerProvider.notifier).reset();
                    context.go(AppSection.compose.path);
                  },
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Discard changes'),
                  style: TextButton.styleFrom(foregroundColor: nf.textMuted),
                ),
            ]),
          ),
        TargetPicker(scrollable: scrollableTargets),
        const SizedBox(height: Space.lg),
        EditorCard(focusNode: focusNode),
        const ThreadPartEditors(),
        if (!c.isEmpty) ...[
          const SizedBox(height: Space.lg),
          const DifferentiationPanel(),
        ],
        if (c.isEmpty && c.additionalParts.isEmpty) ...[
          const SizedBox(height: Space.lg),
          _Starters(onFocus: focusNode.requestFocus),
        ],
      ],
    );
    return Env.isMobile ? _DragDownHidesKeyboard(child: page) : page;
  }
}

class _Starters extends ConsumerWidget {
  const _Starters({required this.onFocus});
  final VoidCallback onFocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    Widget chip(IconData icon, String label, VoidCallback onTap) => ActionChip(
          avatar: Icon(icon, size: 16, color: nf.textMuted),
          label: Text(label),
          onPressed: onTap,
          labelStyle: context.text.labelMedium?.copyWith(color: nf.textMuted),
        );
    return Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
      chip(Icons.add_photo_alternate_outlined, 'Post a photo', () => pickAndAttachMedia(context, ref)),
      chip(Icons.link_rounded, 'Share a link', () {
        ref.read(composerProvider.notifier).prefill('Worth a read: ');
        onFocus();
      }),
      // Adds the second part; the cursor goes to the first, which is still
      // empty while these starters show.
      chip(Icons.forum_outlined, 'Start a thread', () {
        ref.read(composerProvider.notifier).addPart();
        onFocus();
      }),
    ]);
  }
}
