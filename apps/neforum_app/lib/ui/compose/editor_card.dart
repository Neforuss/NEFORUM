import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/char_ring.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import 'media_tray.dart';
import 'poll_sheet.dart';
import 'rich_text.dart';

/// The writing surface: optional title, content warning, the text itself,
/// attachments and the formatting toolbar. Accepts dropped files.
class EditorCard extends ConsumerStatefulWidget {
  const EditorCard({super.key, required this.focusNode});
  final FocusNode focusNode;

  @override
  ConsumerState<EditorCard> createState() => _EditorCardState();
}

class _EditorCardState extends ConsumerState<EditorCard> {
  late final HighlightController _text;
  late final TextEditingController _title;
  late final TextEditingController _cw;
  bool _showTitle = false;
  bool _showCw = false;
  bool _dragging = false;
  int _revision = -1;

  /// The Undo of the last "Clear post".
  _UndoOffer? _undo;

  @override
  void initState() {
    super.initState();
    final c = ref.read(composerProvider);
    _text = HighlightController(text: c.text);
    _title = TextEditingController(text: c.title ?? '');
    _cw = TextEditingController(text: c.contentWarning ?? '');
    _revision = c.revision;
    _showTitle = (c.title ?? '').isNotEmpty;
    _showCw = (c.contentWarning ?? '').isNotEmpty;
  }

  @override
  void dispose() {
    _text.dispose();
    _title.dispose();
    _cw.dispose();
    super.dispose();
  }

  /// When the main fields are replaced (load, reset, clear post, restore),
  /// resync controllers. Thread part changes do not get here
  /// ([ComposerState.revision]).
  void _syncFrom(ComposerState c) {
    if (c.revision == _revision) return;
    _revision = c.revision;
    _text.value = TextEditingValue(text: c.text, selection: TextSelection.collapsed(offset: c.text.length));
    _title.text = c.title ?? '';
    _cw.text = c.contentWarning ?? '';
    setState(() {
      _showTitle = (c.title ?? '').isNotEmpty;
      _showCw = (c.contentWarning ?? '').isNotEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    ref.listen(composerProvider.select((c) => c.revision), (_, _) => _syncFrom(ref.read(composerProvider)));
    ref.listen(composerProvider, (_, next) => _undo?.review(next));
    final c = ref.watch(composerProvider);
    final notifier = ref.read(composerProvider.notifier);
    final previews = ref.watch(composerPreviewsProvider);
    final titleUseful = previews.any((p) => p.descriptor.text.titleSupported);
    final cwUseful = previews.any((p) => p.descriptor.text.supportsContentWarning);
    // Artwork always has a title: it becomes the work's title on art sites.
    final showTitle = _showTitle || (titleUseful && (c.isArtwork || previews.any((p) => p.descriptor.text.titleRequired)));
    final pollNetworks = [for (final p in previews) if (p.descriptor.polls != null) p.descriptor];

    final card = NfCard(
      padding: EdgeInsets.zero,
      borderColor: _dragging ? nf.accent : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_showCw)
          Container(
            color: nf.warningSoft,
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.sm, Space.xs),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: nf.warning),
              const SizedBox(width: Space.sm),
              Expanded(
                child: TextField(
                  controller: _cw,
                  onChanged: notifier.setContentWarning,
                  style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(
                    hintText: 'Content warning (shown before the post, where supported)',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: Space.md),
                  ),
                ),
              ),
              ToolButton(
                icon: Icons.close_rounded,
                tooltip: 'Remove content warning',
                size: 32,
                onPressed: () => setState(() {
                  _showCw = false;
                  _cw.clear();
                  notifier.setContentWarning(null);
                }),
              ),
            ]),
          ),
        if (showTitle)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xl, Space.lg, Space.xl, 0),
            child: TextField(
              controller: _title,
              onChanged: notifier.setTitle,
              style: context.text.titleLarge?.copyWith(fontSize: 20),
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                hintText: 'Title (for Reddit, YouTube, blogs…)',
                hintStyle: context.text.titleLarge?.copyWith(fontSize: 20, color: nf.textFaint),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.md, Space.sm),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: _text,
                focusNode: widget.focusNode,
                onChanged: notifier.setText,
                minLines: context.isCompact ? 5 : 7,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                style: context.text.bodyLarge?.copyWith(fontSize: 17, height: 1.55),
                decoration: InputDecoration(
                  hintText: "What's happening? Write once, NEFORUM adapts it for every network.",
                  hintStyle: context.text.bodyLarge?.copyWith(fontSize: 17, color: nf.textFaint, height: 1.55),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            const SizedBox(width: Space.xs),
            // Always laid out, so the text does not reflow when it appears.
            Visibility(
              visible: _hasContent(c),
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: ToolButton(icon: Icons.close_rounded, tooltip: 'Clear post', size: 32, onPressed: _clearPost),
            ),
          ]),
        ),
        if (c.link != null || c.tags.isNotEmpty || c.poll != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.sm),
            child: Wrap(spacing: Space.xs + 2, runSpacing: Space.xs + 2, children: [
              if (c.link != null)
                _MetaChip(
                  icon: Icons.link_rounded,
                  label: _prettyLink(c.link!),
                  tone: nf.info,
                  onTap: () => _editLink(context),
                  onRemove: () => notifier.setLink(''),
                ),
              if (c.poll != null)
                _MetaChip(
                  icon: c.poll!.isQuiz ? Icons.quiz_outlined : Icons.poll_outlined,
                  label: '${c.poll!.isQuiz ? 'Quiz' : (c.poll!.imageOptions ? 'Image poll' : 'Poll')} · ${c.poll!.cleanOptions.length} answers'
                      '${pollNetworks.isEmpty ? ' · no network takes polls' : ''}',
                  tone: pollNetworks.isEmpty ? nf.warning : nf.accent,
                  onTap: () => _editPoll(context, pollNetworks),
                  onRemove: () => notifier.setPoll(null),
                ),
              for (final t in c.tags)
                _MetaChip(
                  icon: Icons.tag_rounded,
                  label: t,
                  tone: nf.accent,
                  onTap: () => _editTags(context),
                  onRemove: () => notifier.setTags(c.tags.where((x) => x != t).toList()),
                ),
            ]),
          ),
        if (c.media.isNotEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.lg, Space.sm),
            child: MediaTray(),
          ),
        Divider(height: 1, color: nf.border),
        _Toolbar(
          onMedia: () => pickAndAttachMedia(context, ref),
          onLink: () => _editLink(context),
          onTags: () => _editTags(context),
          onCw: cwUseful || _showCw ? () => setState(() => _showCw = !_showCw) : null,
          cwActive: _showCw,
          onTitle: titleUseful || _showTitle ? () => setState(() => _showTitle = !_showTitle) : null,
          titleActive: showTitle,
          onPoll: pollNetworks.isNotEmpty || c.poll != null ? () => _editPoll(context, pollNetworks) : null,
          pollActive: c.poll != null,
          pollTooltip: pollNetworks.isEmpty ? 'Poll or quiz' : 'Poll or quiz for ${pollNetworks.map((d) => d.name).toSet().join(', ')}',
        ),
      ]),
    );

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) async {
        setState(() => _dragging = false);
        await attachDroppedFiles(context, ref, d.files);
      },
      child: Stack(children: [
        // Ctrl+V / ⌘V attaches a pasted picture or copied files; anything else
        // pastes as text, as usual.
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
            const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _paste,
          },
          child: card,
        ),
        if (_dragging)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: nf.accentSoft.withValues(alpha: 0.92),
                  borderRadius: Radii.rLg,
                  border: Border.all(color: nf.accent, width: 2),
                ),
                alignment: Alignment.center,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.file_download_outlined, size: 36, color: nf.accent),
                  const SizedBox(height: Space.sm),
                  Text('Drop to attach', style: context.text.titleLarge?.copyWith(color: nf.accent)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  /// Something "Clear post" would remove.
  static bool _hasContent(ComposerState c) =>
      !c.isEmpty || c.additionalParts.isNotEmpty || c.poll != null || c.contentWarning != null || c.tags.isNotEmpty || c.overrides.isNotEmpty;

  /// Empties the whole post (targets stay). Undo brings it back until
  /// anything else changes.
  void _clearPost() {
    final notifier = ref.read(composerProvider.notifier);
    final before = ref.read(composerProvider);
    notifier.clearPost();
    final cleared = ref.read(composerProvider);
    _undo = _UndoOffer.show(context, 'Post cleared', Icons.delete_sweep_outlined,
        applies: (c) => identical(c, cleared), undo: () => notifier.undoClearPost(before, cleared));
  }

  Future<void> _paste() async {
    final focused = primaryFocus?.context;
    if (await pasteMedia(context, ref)) return;
    // Not a picture: the text field's own paste.
    if (focused != null && focused.mounted) {
      Actions.maybeInvoke(focused, const PasteTextIntent(SelectionChangedCause.keyboard));
    }
  }

  static String _prettyLink(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return url;
    final path = u.path.length > 1 ? (u.path.length > 24 ? '${u.path.substring(0, 24)}…' : u.path) : '';
    return '${u.host.replaceFirst('www.', '')}$path';
  }

  Future<void> _editLink(BuildContext context) async {
    final current = ref.read(composerProvider).link ?? '';
    final result = await showDialog<String>(context: context, builder: (_) => _LinkDialog(initial: current));
    if (result != null) ref.read(composerProvider.notifier).setLink(result);
  }

  Future<void> _editPoll(BuildContext context, List<PlatformDescriptor> networks) async {
    final c = ref.read(composerProvider);
    final rules = networks.map((d) => d.polls).whereType<PollRules>().firstOrNull ??
        const PollRules(maxOptions: 4, optionMaxLength: 65, quizzes: true, quizOptionMaxLength: 80, quizExplanationMaxLength: 500);
    final names = networks.map((d) => d.name).toSet();
    final result = await showPollEditor(
      context,
      initial: c.poll,
      rules: rules,
      networks: names.isEmpty ? 'networks that take polls' : names.join(', '),
      imageCount: c.media.where((m) => m.isImage).length,
    );
    if (result == null) return;
    ref.read(composerProvider.notifier).setPoll(identical(result, kRemovePoll) ? null : result);
  }

  Future<void> _editTags(BuildContext context) async {
    final current = ref.read(composerProvider).tags;
    final result = await showDialog<List<String>>(context: context, builder: (_) => _TagsDialog(initial: current));
    if (result != null) ref.read(composerProvider.notifier).setTags(result);
  }
}

/// The Undo toast of a change to the post. It goes after a few seconds, and
/// at once when the change can no longer be undone, so it never offers to
/// put back an old state.
class _UndoOffer {
  _UndoOffer._(this._messenger, this._applies);
  final ScaffoldMessengerState _messenger;

  /// Whether a composer state still allows the undo.
  final bool Function(ComposerState c) _applies;
  bool _open = true;

  /// Shows [message] with Undo, which runs [undo]. Null without a messenger
  /// to show it in.
  static _UndoOffer? show(BuildContext context, String message, IconData icon,
      {required bool Function(ComposerState c) applies, required VoidCallback undo}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return null;
    final offer = _UndoOffer._(messenger, applies);
    final toast = showToast(context, message, icon: icon, actionLabel: 'Undo', persist: false, onAction: () {
      offer._open = false;
      undo();
    });
    toast?.closed.then((_) => offer._open = false);
    return offer;
  }

  /// Takes the toast away once [c] no longer allows the undo.
  void review(ComposerState c) {
    if (!_open || _applies(c)) return;
    _open = false;
    _messenger.hideCurrentSnackBar();
  }
}

/// The text field and focus of one thread part after the first.
class _PartField {
  final TextEditingController controller = TextEditingController();
  final FocusNode focus = FocusNode();

  void dispose() {
    controller.dispose();
    focus.dispose();
  }
}

/// THREAD: one editor per part after the first ([ComposerState.additionalParts]),
/// each with its own character count and a remove control, and "Add to
/// thread" under the last part. Networks with threads post each part as a
/// reply; the others get the parts joined.
class ThreadPartEditors extends ConsumerStatefulWidget {
  const ThreadPartEditors({super.key});

  @override
  ConsumerState<ThreadPartEditors> createState() => _ThreadPartEditorsState();
}

class _ThreadPartEditorsState extends ConsumerState<ThreadPartEditors> {
  final List<_PartField> _parts = [];
  int _revision = -1;

  /// The Undo of the last part removed.
  _UndoOffer? _undo;

  @override
  void initState() {
    super.initState();
    final c = ref.read(composerProvider);
    _revision = c.revision;
    for (final text in c.additionalParts) {
      _parts.add(_PartField()..controller.text = text);
    }
  }

  @override
  void dispose() {
    for (final p in _parts) {
      p.dispose();
    }
    super.dispose();
  }

  /// When the composer state is replaced (load, reset, undo) or a part is
  /// added elsewhere ("Start a thread"), resync the fields with its parts.
  void _syncFrom(ComposerState c) {
    if (c.revision == _revision && c.additionalParts.length == _parts.length) return;
    _revision = c.revision;
    final texts = c.additionalParts;
    while (_parts.length > texts.length) {
      _retire(_parts.removeLast());
    }
    while (_parts.length < texts.length) {
      _parts.add(_PartField());
    }
    for (var i = 0; i < texts.length; i++) {
      if (_parts[i].controller.text != texts[i]) {
        _parts[i].controller.value = TextEditingValue(text: texts[i], selection: TextSelection.collapsed(offset: texts[i].length));
      }
    }
    setState(() {});
  }

  /// Disposes [p] once its field has left the tree.
  void _retire(_PartField p) => WidgetsBinding.instance.addPostFrameCallback((_) => p.dispose());

  /// Adds a part at the end and moves the cursor into it.
  void _add() {
    final index = ref.read(composerProvider.notifier).addPart();
    // The part's field exists from the next frame on.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && index - 1 < _parts.length) _parts[index - 1].focus.requestFocus();
    });
  }

  /// Removes part [index] (1 or more). Undo puts it back where it was and
  /// keeps what was written since, until the post is replaced.
  void _remove(int index) {
    final notifier = ref.read(composerProvider.notifier);
    final text = ref.read(composerProvider).additionalParts[index - 1];
    // Drop this part's own field, so the fields after it keep their focus.
    _retire(_parts.removeAt(index - 1));
    notifier.removePart(index);
    setState(() {});
    final revision = ref.read(composerProvider).revision;
    _undo = _UndoOffer.show(context, 'Part ${index + 1} removed', Icons.delete_outline_rounded,
        applies: (c) => c.revision == revision, undo: () => _putBack(notifier, index, text, revision));
  }

  /// Undo of [_remove]: part [index] comes back with [text], unless the post
  /// was replaced after [revision].
  void _putBack(ComposerNotifier notifier, int index, String text, int revision) {
    if (mounted && ref.read(composerProvider).revision == revision) {
      // Its own field goes back first, so the fields after it keep their
      // focus.
      _parts.insert((index - 1).clamp(0, _parts.length), _PartField()..controller.text = text);
      setState(() {});
    }
    notifier.undoRemovePart(index, text, revision: revision);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(composerProvider.select((c) => (c.revision, c.additionalParts.length)), (_, _) {
      final c = ref.read(composerProvider);
      _undo?.review(c);
      _syncFrom(c);
    });
    final c = ref.watch(composerProvider);
    final count = c.additionalParts.length;
    final showAdd = count > 0 || !c.isEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < count && i < _parts.length; i++) ...[
        const _ThreadConnector(),
        _PartEditor(
          key: ObjectKey(_parts[i]),
          index: i + 1,
          field: _parts[i],
          onChanged: (v) => ref.read(composerProvider.notifier).setPart(i + 1, v),
          onRemove: () => _remove(i + 1),
        ),
      ],
      if (showAdd)
        Padding(
          padding: const EdgeInsets.only(top: Space.sm),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add to thread'),
              style: TextButton.styleFrom(foregroundColor: context.nf.textMuted),
            ),
          ),
        ),
    ]);
  }
}

/// The line that joins the parts of a thread.
class _ThreadConnector extends StatelessWidget {
  const _ThreadConnector();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: Space.xl + 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(width: 2, height: Space.md, color: context.nf.borderStrong),
        ),
      );
}

/// The editor of thread part [index] (1 or more; the first part is the main
/// editor).
class _PartEditor extends ConsumerWidget {
  const _PartEditor({super.key, required this.index, required this.field, required this.onChanged, required this.onRemove});
  final int index;
  final _PartField field;
  final ValueChanged<String> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final c = ref.watch(composerProvider);
    final text = index - 1 < c.additionalParts.length ? c.additionalParts[index - 1] : '';
    final budget = _partBudget(text, ref);
    return NfCard(
      padding: const EdgeInsets.fromLTRB(Space.xl, Space.sm, Space.md, Space.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.subdirectory_arrow_right_rounded, size: 16, color: nf.textFaint),
          const SizedBox(width: Space.xs),
          Expanded(child: Text('Part ${index + 1}', style: context.text.labelMedium?.copyWith(color: nf.textMuted))),
          CharRing(used: budget.used, max: budget.max, parts: budget.parts, size: 20, alwaysShowCount: true),
          const SizedBox(width: Space.xs),
          ToolButton(icon: Icons.close_rounded, tooltip: 'Remove part ${index + 1}', size: 32, onPressed: onRemove),
        ]),
        TextField(
          controller: field.controller,
          focusNode: field.focus,
          onChanged: onChanged,
          minLines: 2,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: context.text.bodyLarge?.copyWith(fontSize: 17, height: 1.55),
          decoration: InputDecoration(
            hintText: 'Continue the thread',
            hintStyle: context.text.bodyLarge?.copyWith(fontSize: 17, color: nf.textFaint, height: 1.55),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ]),
    );
  }

  /// Characters of this part against the tightest network that posts it on
  /// its own (a network with threads, without a version of its own), with
  /// the ` (i/n)` numbering it will get. Without such a network: the plain
  /// count.
  static ({int used, int? max, int parts}) _partBudget(String text, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    ({int used, int? max, int parts}) best = (used: text.characters.length, max: null, parts: 1);
    var bestRatio = -1.0;
    for (final p in ref.watch(composerPreviewsProvider)) {
      final rules = p.descriptor.text;
      final max = rules.maxLength;
      if (max == null || !rules.supportsThreads || !p.account.tier.isAutomatic || p.target.overrides.text != null) continue;
      final suffix = settings.threadNumbering && p.variant.isThread ? TextSplitter.suffixLength(p.variant.threadParts.length) : 0;
      final used = TextCounter.count(text.trimRight(), rules) + suffix;
      final ratio = used / max;
      if (ratio <= bestRatio) continue;
      bestRatio = ratio;
      final splits = settings.overflow == OverflowStrategy.threadOrError || settings.overflow == OverflowStrategy.threadOrTruncate;
      // Too long: split into at least two posts (only the numbering may be
      // what does not fit).
      final pieces = used > max && splits ? TextSplitter.split(text.trimRight(), rules, numbering: false).length : 1;
      best = (used: used, max: max, parts: used > max && splits && pieces < 2 ? 2 : pieces);
    }
    return best;
  }
}

class _Toolbar extends ConsumerWidget {
  const _Toolbar({
    required this.onMedia,
    required this.onLink,
    required this.onTags,
    required this.onCw,
    required this.cwActive,
    required this.onTitle,
    required this.titleActive,
    this.onPoll,
    this.pollActive = false,
    this.pollTooltip = 'Poll or quiz',
  });

  final VoidCallback onMedia;
  final VoidCallback onLink;
  final VoidCallback onTags;
  final VoidCallback? onCw;
  final bool cwActive;
  final VoidCallback? onTitle;
  final bool titleActive;
  final VoidCallback? onPoll;
  final bool pollActive;
  final String pollTooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(composerProvider);
    final notifier = ref.read(composerProvider.notifier);
    final settings = ref.watch(settingsProvider);
    final everyNetwork = c.cardOnEveryNetwork(settings);
    final s = context.isCompact ? 34.0 : 38.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm + 2, vertical: Space.xs + 2),
      child: Row(children: [
        // Tools scroll sideways on narrow screens; the budget stays put.
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              ToolButton(
                icon: Icons.add_photo_alternate_outlined,
                tooltip: 'Add photos or videos',
                onPressed: onMedia,
                size: s,
                badge: c.media.isEmpty ? null : '${c.media.length}',
              ),
              ToolButton(icon: Icons.link_rounded, tooltip: 'Add a link', onPressed: onLink, active: c.link != null, size: s),
              ToolButton(icon: Icons.tag_rounded, tooltip: 'Hashtags', onPressed: onTags, active: c.tags.isNotEmpty, size: s),
              if (onCw != null) ToolButton(icon: Icons.warning_amber_rounded, tooltip: 'Content warning', onPressed: onCw, active: cwActive, size: s),
              if (onTitle != null) ToolButton(icon: Icons.title_rounded, tooltip: 'Title', onPressed: onTitle, active: titleActive, size: s),
              if (onPoll != null) ToolButton(icon: Icons.poll_outlined, tooltip: pollTooltip, onPressed: onPoll, active: pollActive, size: s),
              if (settings.textCards && c.media.isEmpty && !c.isArtwork)
                ToolButton(
                  key: const Key('text-card-every-network'),
                  icon: Icons.style_outlined,
                  tooltip: everyNetwork
                      ? 'The text card goes to every network that takes images: tap to use it only where an image is needed'
                      : 'Use the text card on every network',
                  onPressed: () => notifier.setTextCardEveryNetwork(!everyNetwork),
                  active: everyNetwork,
                  size: s,
                ),
              _VisibilityButton(value: c.visibility, onChanged: notifier.setVisibility),
            ]),
          ),
        ),
        const BudgetIndicator(),
      ]),
    );
  }
}

class _VisibilityButton extends StatelessWidget {
  const _VisibilityButton({required this.value, required this.onChanged});
  final PostVisibility value;
  final ValueChanged<PostVisibility> onChanged;

  static (String, IconData, String) _style(PostVisibility v) => switch (v) {
        PostVisibility.public => ('Public', Icons.public_rounded, 'Anyone can see it'),
        PostVisibility.unlisted => ('Unlisted', Icons.lock_open_rounded, 'Public, but kept out of feeds and search where supported'),
        PostVisibility.followers => ('Followers only', Icons.people_alt_outlined, 'Only your followers, where supported'),
        PostVisibility.private => ('Private', Icons.lock_outline_rounded, 'Only you / mentioned people, where supported'),
      };

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final (label, icon, _) = _style(value);
    return PopupMenuButton<PostVisibility>(
      tooltip: 'Visibility: $label',
      initialValue: value,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        for (final v in PostVisibility.values)
          PopupMenuItem(
            value: v,
            child: Row(children: [
              Icon(_style(v).$2, size: 18, color: v == value ? nf.accent : nf.textMuted),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(_style(v).$1, style: context.text.labelLarge),
                  Text(_style(v).$3, style: context.text.bodySmall),
                ]),
              ),
            ]),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.sm),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: value == PostVisibility.public ? nf.textMuted : nf.accent),
          if (!context.isCompact) ...[
            const SizedBox(width: Space.xs),
            Text(label, style: context.text.labelMedium?.copyWith(color: nf.textMuted)),
          ],
          Icon(Icons.expand_more_rounded, size: 16, color: nf.textFaint),
        ]),
      ),
    );
  }
}

/// Character budget for the most constrained selected network.
class BudgetIndicator extends ConsumerWidget {
  const BudgetIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final previews = ref.watch(composerPreviewsProvider);
    final rows = <({String name, int used, int max, int parts})>[];
    for (final p in previews) {
      final rules = p.descriptor.text;
      if (rules.maxLength == null) continue;
      rows.add((
        name: p.descriptor.name,
        used: TextCounter.count(p.variant.text, rules),
        max: rules.maxLength!,
        parts: p.variant.isThread ? p.variant.threadParts.length : 1,
      ));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    rows.sort((a, b) => (b.used / b.max).compareTo(a.used / a.max));
    final tight = rows.first;
    final threads = rows.where((r) => r.parts > 1).toList();
    final text = threads.isNotEmpty
        ? '${threads.first.name} → ${threads.first.parts}-part thread'
        : '${tight.name} · ${tight.max - tight.used} left';
    return Tooltip(
      message: [for (final r in rows.take(6)) '${r.name}: ${r.parts > 1 ? '${r.parts} parts' : '${r.max - r.used} of ${r.max} left'}'].join('\n'),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (!context.isCompact) ...[
          Text(text, style: monoStyle(context, size: 11.5, color: nf.textFaint)),
          const SizedBox(width: Space.sm),
        ],
        CharRing(used: tight.used, max: tight.max, parts: threads.isEmpty ? 1 : threads.first.parts, size: 24, showNumber: context.isCompact),
        const SizedBox(width: Space.sm),
      ]),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label, required this.tone, required this.onTap, required this.onRemove});
  final IconData icon;
  final String label;
  final Color tone;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Material(
      color: Color.alphaBlend(tone.withValues(alpha: nf.isDark ? 0.14 : 0.08), nf.surface),
      shape: Radii.stadium.copyWith(side: BorderSide(color: tone.withValues(alpha: 0.35))),
      child: InkWell(
        customBorder: Radii.stadium,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: Space.sm, right: 2, top: 2, bottom: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: tone),
            const SizedBox(width: Space.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(label, overflow: TextOverflow.ellipsis, style: context.text.labelMedium?.copyWith(color: tone)),
            ),
            IconButton(
              onPressed: onRemove,
              tooltip: 'Remove',
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 26, height: 26),
              padding: EdgeInsets.zero,
              icon: Icon(Icons.close_rounded, color: tone),
            ),
          ]),
        ),
      ),
    );
  }
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.initial});
  final String initial;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String? get _normalized {
    var v = _c.text.trim();
    if (v.isEmpty) return '';
    if (!v.contains('://')) v = 'https://$v';
    final u = Uri.tryParse(v);
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https') || !u.host.contains('.')) return null;
    return u.toString();
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final n = _normalized;
    final host = n == null || n.isEmpty ? null : Uri.parse(n).host;
    return AlertDialog(
      title: const Text('Add a link'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'Reddit, Pinterest, Lemmy and blogs use it as the post\'s link. Everywhere else it is added to the text if it is not there yet.',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _c,
            autofocus: true,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (n != null) Navigator.pop(context, n);
            },
            decoration: InputDecoration(
              hintText: 'https://example.org/article',
              prefixIcon: const Icon(Icons.link_rounded),
              errorText: n == null ? 'That does not look like a web address' : null,
            ),
          ),
          if (host != null) ...[
            const SizedBox(height: Space.md),
            Row(children: [
              Icon(Icons.public_rounded, size: 16, color: nf.textFaint),
              const SizedBox(width: Space.sm),
              Text(host, style: monoStyle(context, color: nf.textMuted)),
            ]),
          ],
        ]),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(Space.xxl, 0, Space.xxl, Space.xl),
      actions: [
        if (widget.initial.isNotEmpty)
          TextButton(onPressed: () => Navigator.pop(context, ''), style: TextButton.styleFrom(foregroundColor: nf.danger), child: const Text('Remove')),
        TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
        FilledButton(onPressed: n == null ? null : () => Navigator.pop(context, n), child: const Text('Save')),
      ],
    );
  }
}

class _TagsDialog extends StatefulWidget {
  const _TagsDialog({required this.initial});
  final List<String> initial;

  @override
  State<_TagsDialog> createState() => _TagsDialogState();
}

class _TagsDialogState extends State<_TagsDialog> {
  late final List<String> _tags = [...widget.initial];
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _commit() {
    for (final raw in _c.text.split(RegExp(r'[\s,]+'))) {
      final t = raw.replaceFirst(RegExp(r'^#+'), '').trim();
      if (t.isNotEmpty && !_tags.any((x) => x.toLowerCase() == t.toLowerCase())) _tags.add(t);
    }
    _c.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return AlertDialog(
      title: const Text('Hashtags'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            'Added to the end of the post, or sent as tags where the platform has a tags field (YouTube, Tumblr, blogs).',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _c,
            autofocus: true,
            onChanged: (v) {
              if (v.endsWith(' ') || v.endsWith(',')) _commit();
            },
            onSubmitted: (_) => _commit(),
            decoration: const InputDecoration(hintText: 'Type a tag and press Enter', prefixIcon: Icon(Icons.tag_rounded)),
          ),
          const SizedBox(height: Space.md),
          if (_tags.isEmpty)
            Text('No hashtags yet', style: context.text.bodySmall?.copyWith(color: nf.textFaint))
          else
            Wrap(spacing: Space.xs + 2, runSpacing: Space.xs + 2, children: [
              for (final t in _tags)
                InputChip(
                  label: Text('#$t'),
                  onDeleted: () => setState(() => _tags.remove(t)),
                  deleteIconColor: nf.textMuted,
                ),
            ]),
        ]),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(Space.xxl, 0, Space.xxl, Space.xl),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            _commit();
            Navigator.pop(context, _tags);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
