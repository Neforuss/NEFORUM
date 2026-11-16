import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/selection_marks.dart';
import 'media_tray.dart';

/// What kind of file an article block or field shows.
enum ArticleMediaKind {
  photo('photo', 'photos'),
  video('video', 'videos'),
  sound('sound file', 'sound files');

  const ArticleMediaKind(this.one, this.many);
  final String one;
  final String many;

  bool accepts(MediaAttachment m) => !m.generated &&
      switch (this) {
        ArticleMediaKind.photo => m.isImage,
        ArticleMediaKind.video => m.isVideo,
        ArticleMediaKind.sound => m.isAudio,
      };
}

/// 1.4.4: articles. Lets the user pick [kind] files for an article block or
/// its cover: from the post's own files (the media tray), or new ones from
/// the device, which are attached to the post. [multiple] for a gallery.
/// [selected] starts ticked. Returns the chosen media ids in the order they
/// were ticked; null when the user backs out.
Future<List<String>?> showArticleMediaChooser(BuildContext context,
    {required ArticleMediaKind kind, bool multiple = false, List<String> selected = const [], String? title}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ArticleMediaChooser(kind: kind, multiple: multiple, initial: selected, title: title),
  );
}

class _ArticleMediaChooser extends ConsumerStatefulWidget {
  const _ArticleMediaChooser({required this.kind, required this.multiple, required this.initial, this.title});
  final ArticleMediaKind kind;
  final bool multiple;
  final List<String> initial;
  final String? title;

  @override
  ConsumerState<_ArticleMediaChooser> createState() => _ArticleMediaChooserState();
}

class _ArticleMediaChooserState extends ConsumerState<_ArticleMediaChooser> {
  late final List<String> _picked = [...widget.initial];

  Future<void> _addNew() async {
    final MediaPick? pick;
    try {
      pick = await ref.read(mediaPickerProvider)(context);
    } on Object catch (e) {
      if (mounted) showToast(context, 'Could not open the picker: $e', icon: Icons.error_outline_rounded);
      return;
    }
    if (pick == null || !mounted) return;
    ref.read(composerProvider.notifier).addMedia(pick.added);
    final fitting = [for (final m in pick.added) if (widget.kind.accepts(m)) m.id];
    if (fitting.length < pick.added.length || pick.rejected.isNotEmpty) {
      showToast(context, 'Added to the post. Only ${widget.kind.many} can go in this block.', icon: Icons.info_outline_rounded);
    }
    if (fitting.isEmpty) return;
    if (!widget.multiple) {
      Navigator.pop(context, [fitting.first]);
      return;
    }
    setState(() => _picked.addAll(fitting.where((id) => !_picked.contains(id))));
  }

  void _tap(String id) {
    if (!widget.multiple) {
      Navigator.pop(context, [id]);
      return;
    }
    setState(() => _picked.contains(id) ? _picked.remove(id) : _picked.add(id));
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final files = [for (final m in ref.watch(composerProvider.select((c) => c.media))) if (widget.kind.accepts(m)) m];
    final width = MediaQuery.sizeOf(context).width;
    final tile = width < Breakpoints.compact ? (width - Space.lg * 2 - Space.sm * 2) / 3 : 112.0;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.title ?? (widget.multiple ? 'Choose ${widget.kind.many}' : 'Choose a ${widget.kind.one}'), style: context.text.titleMedium),
            const SizedBox(height: Space.xs),
            Text(
              files.isEmpty
                  ? 'This post has no ${widget.kind.many} yet. Add one from this device.'
                  : 'From this post\'s files, or add new ones from this device.',
              style: context.text.bodySmall?.copyWith(color: nf.textMuted),
            ),
            const SizedBox(height: Space.md),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
                  for (final m in files)
                    Semantics(
                      key: ValueKey('article-media-choice-${m.id}'),
                      button: true,
                      selected: _picked.contains(m.id),
                      label: m.fileName ?? widget.kind.one,
                      child: InkWell(
                        onTap: () => _tap(m.id),
                        borderRadius: Radii.rMd,
                        child: SelectionBadged(
                          selected: _picked.contains(m.id),
                          child: MediaThumb(m, size: tile, radius: Radii.rMd),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: Space.md),
            Row(children: [
              OutlinedButton.icon(
                key: const ValueKey('article-media-add-new'),
                onPressed: _addNew,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                label: const Text('Add from this device'),
              ),
              const Spacer(),
              if (widget.multiple)
                FilledButton(
                  key: const ValueKey('article-media-use'),
                  onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked),
                  child: Text(_picked.isEmpty ? 'Use' : 'Use ${_picked.length}'),
                ),
            ]),
          ]),
        ),
      ),
    );
  }
}
