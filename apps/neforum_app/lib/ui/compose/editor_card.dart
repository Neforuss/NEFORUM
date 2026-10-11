import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/char_ring.dart';
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

  /// When the composer state is replaced (load/reset), resync controllers.
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
    final c = ref.watch(composerProvider);
    final notifier = ref.read(composerProvider.notifier);
    final previews = ref.watch(composerPreviewsProvider);
    final titleUseful = previews.any((p) => p.descriptor.text.titleSupported);
    final cwUseful = previews.any((p) => p.descriptor.text.supportsContentWarning);
    final showTitle = _showTitle || (titleUseful && previews.any((p) => p.descriptor.text.titleRequired));
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
          padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.xl, Space.sm),
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
        card,
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
      shape: StadiumBorder(side: BorderSide(color: tone.withValues(alpha: 0.35))),
      child: InkWell(
        customBorder: const StadiumBorder(),
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
