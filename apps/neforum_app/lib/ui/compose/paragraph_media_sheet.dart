import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/media_thumb.dart';

/// 1.4.3: opens the editor of the post's paragraph-to-media links: each
/// paragraph of the text with a link button that shows the post's photos and
/// videos to pick from.
Future<void> showParagraphMediaSheet(BuildContext context) {
  const editor = ParagraphMediaEditor();
  if (context.isCompact) {
    return showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => editor);
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640, maxHeight: 820), child: editor),
    ),
  );
}

/// Under the media tray of a long post with photos or videos: how many
/// paragraphs are linked, and the button to link them.
class ParagraphMediaRow extends ConsumerWidget {
  const ParagraphMediaRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final can = ref.watch(composerProvider.select((c) => c.canLinkParagraphs));
    final linked = ref.watch(composerProvider.select((c) => c.postParagraphMedia.length));
    final thread = ref.watch(composerProvider.select((c) => c.additionalParts.isNotEmpty));
    if (!can && linked == 0) return const SizedBox.shrink();
    return Wrap(spacing: Space.sm, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.view_agenda_outlined, size: 18, color: nf.textMuted),
        const SizedBox(width: Space.xs),
        Text(
          thread
              ? 'Paragraph links are off in a thread'
              : linked == 0
                  ? 'No paragraph linked to a photo or video'
                  : '$linked paragraph${linked == 1 ? '' : 's'} linked to photos or videos',
          style: context.text.labelMedium?.copyWith(color: linked == 0 || thread ? nf.textFaint : nf.text),
        ),
      ]),
      TextButton.icon(
        key: const ValueKey('paragraph-media-button'),
        onPressed: can ? () => showParagraphMediaSheet(context) : null,
        icon: const Icon(Icons.add_link_rounded, size: 18),
        label: Text(linked == 0 ? 'Link paragraphs to media' : 'Edit paragraph links'),
      ),
    ]);
  }
}

/// The editor [showParagraphMediaSheet] opens; public for tests.
class ParagraphMediaEditor extends ConsumerStatefulWidget {
  const ParagraphMediaEditor({super.key});

  @override
  ConsumerState<ParagraphMediaEditor> createState() => _ParagraphMediaEditorState();
}

class _ParagraphMediaEditorState extends ConsumerState<ParagraphMediaEditor> {
  /// The paragraph whose link button is open, showing the media to pick.
  int? _open;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final c = ref.watch(composerProvider);
    final notifier = ref.read(composerProvider.notifier);
    final paragraphs = c.paragraphs;
    final media = c.linkableMedia;
    final links = c.postParagraphMedia;
    final byId = {for (final m in media) m.id: m};

    Widget paragraph(int i) {
      final own = [for (final id in links[i] ?? const <String>[]) ?byId[id]];
      final open = _open == i;
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.md),
        child: Container(
          key: ValueKey('paragraph-$i'),
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: open ? nf.accentSoft : nf.surfaceSunken,
            borderRadius: Radii.rSm,
            border: Border.all(color: open ? nf.accent : nf.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${i + 1}', style: monoStyle(context, size: 12, color: nf.textMuted)),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(paragraphs[i], maxLines: 3, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium),
              ),
              const SizedBox(width: Space.xs),
              ToolButton(
                key: ValueKey('paragraph-link-$i'),
                icon: open ? Icons.check_rounded : Icons.add_link_rounded,
                tooltip: open ? 'Done' : 'Link photos and videos to paragraph ${i + 1}',
                active: own.isNotEmpty || open,
                badge: own.isEmpty ? null : '${own.length}',
                size: 34,
                onPressed: () => setState(() => _open = open ? null : i),
              ),
            ]),
            if (!open && own.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
                for (final m in own) MediaThumb(m, size: 44, showAltTag: false),
              ]),
            ],
            if (open) ...[
              const SizedBox(height: Space.sm),
              Text('Tap the photos and videos this paragraph is about.', style: context.text.bodySmall),
              const SizedBox(height: Space.sm),
              Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
                for (final m in media)
                  _PickTile(
                    key: ValueKey('paragraph-$i-pick-${m.id}'),
                    media: m,
                    selected: links[i]?.contains(m.id) ?? false,
                    elsewhere: switch (ParagraphMedia.paragraphOf(links, m.id)) {
                      final p? when p != i => p,
                      _ => null,
                    },
                    onTap: () => notifier.toggleParagraphMedia(i, m.id),
                  ),
              ]),
            ],
          ]),
        ),
      );
    }

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xl, Space.lg, Space.sm, Space.xs),
        child: Row(children: [
          Expanded(child: Text('Link paragraphs to media', style: context.text.titleLarge)),
          ToolButton(icon: Icons.close_rounded, tooltip: 'Close', size: 34, onPressed: () => Navigator.of(context).maybePop()),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.md),
        child: Text(
          'Telegram, Discord and Tumblr show each paragraph with its own photos and videos. Facebook, LinkedIn and Instagram '
          'put them in the order of the paragraphs and number them in the text, and an Instagram story writes each '
          'paragraph on its photo when the caption goes on photos. Files you do not link go at the end.',
          style: context.text.bodySmall,
        ),
      ),
      Flexible(
        child: paragraphs.length < 2 || media.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: Text('Write two paragraphs or more (separated by an empty line) and attach a photo or video to link them.',
                    style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
              )
            : ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.sm),
                children: [for (var i = 0; i < paragraphs.length; i++) paragraph(i)],
              ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
        child: Row(children: [
          if (links.isNotEmpty)
            TextButton(
              key: const ValueKey('paragraph-media-clear'),
              onPressed: notifier.clearParagraphMedia,
              style: TextButton.styleFrom(foregroundColor: nf.textMuted),
              child: const Text('Remove all links'),
            ),
          const Spacer(),
          FilledButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Done')),
        ]),
      ),
    ]);
  }
}

/// One photo or video to pick for a paragraph: checked when it is linked to
/// it, with the number of the paragraph it is linked to otherwise.
class _PickTile extends StatelessWidget {
  const _PickTile({super.key, required this.media, required this.selected, required this.elsewhere, required this.onTap});

  final MediaAttachment media;
  final bool selected;

  /// The paragraph (from 0) it is linked to instead; picking it moves it.
  final int? elsewhere;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Semantics(
      button: true,
      selected: selected,
      label: '${media.isVideo ? 'Video' : 'Photo'} ${media.fileName ?? ''}${elsewhere == null ? '' : ', linked to paragraph ${elsewhere! + 1}'}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: context.motion(Motion.fast),
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: Radii.rSm,
              border: Border.all(color: selected ? nf.accent : Colors.transparent, width: 2),
            ),
            child: Stack(children: [
              Opacity(opacity: elsewhere != null && !selected ? 0.55 : 1, child: MediaThumb(media, size: 72, showAltTag: false)),
              if (selected)
                Positioned(
                  right: 4,
                  top: 4,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(color: nf.accentFill, shape: Radii.circleShape),
                    child: const Icon(Icons.check_rounded, size: 14, color: Colors.white),
                  ),
                ),
              if (elsewhere != null && !selected)
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), borderRadius: Radii.rXs),
                    child: Text('¶ ${elsewhere! + 1}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
