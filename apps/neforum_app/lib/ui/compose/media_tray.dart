import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../platform/clipboard_media.dart';
import '../../platform/env.dart';
import '../../platform/media_library.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/surfaces.dart';

/// Opens the platform picker and attaches the chosen photos/videos.
Future<void> pickAndAttachMedia(BuildContext context, WidgetRef ref) async {
  final library = ref.read(servicesProvider).media;
  final notifier = ref.read(composerProvider.notifier);
  final added = <MediaAttachment>[];
  final rejected = <String>[];
  try {
    if (Env.isMobile) {
      final files = await ImagePicker().pickMultipleMedia(limit: 20);
      for (final f in files) {
        try {
          added.add(await library.importXFile(f));
        } on UnsupportedMediaException {
          rejected.add(f.name);
        }
      }
    } else {
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Attach photos or videos',
        type: FileType.custom,
        allowedExtensions: MediaLibrary.supportedExtensions,
      );
      for (final f in files) {
        try {
          added.add(await library.importBytes(await f.readAsBytes(), fileName: f.name));
        } on UnsupportedMediaException {
          rejected.add(f.name);
        }
      }
    }
  } on Object catch (e) {
    if (context.mounted) showToast(context, 'Could not open the picker: $e', icon: Icons.error_outline_rounded);
    return;
  }
  notifier.addMedia(added);
  if (rejected.isNotEmpty && context.mounted) {
    showToast(context, '${rejected.length} file(s) skipped: only images and videos can be attached', icon: Icons.info_outline_rounded);
  }
}

/// Attaches files dropped onto the editor.
Future<void> attachDroppedFiles(BuildContext context, WidgetRef ref, List<XFile> files) async {
  final library = ref.read(servicesProvider).media;
  final added = <MediaAttachment>[];
  var rejected = 0;
  for (final f in files) {
    try {
      added.add(await library.importXFile(f));
    } on UnsupportedMediaException {
      rejected++;
    } on Object {
      rejected++;
    }
  }
  ref.read(composerProvider.notifier).addMedia(added);
  if (rejected > 0 && context.mounted) {
    showToast(context, '$rejected file(s) skipped: only images and videos can be attached', icon: Icons.info_outline_rounded);
  }
}

/// Ctrl+V / ⌘V in the composer: attaches a pasted picture (a screenshot,
/// "Copy image" in a browser) or photos and videos copied in Explorer or
/// Finder. Returns false when the clipboard holds none, so the paste goes on
/// as text.
Future<bool> pasteMedia(BuildContext context, WidgetRef ref) async {
  final pasted = await ClipboardMedia.readImage();
  if (pasted == null) return false;
  final library = ref.read(servicesProvider).media;
  if (pasted.files.isNotEmpty) {
    final media = [
      for (final p in pasted.files)
        if (MediaLibrary.supportedExtensions.contains(p.split('.').last.toLowerCase())) p,
    ];
    if (media.isEmpty) return false;
    if (!context.mounted) return true;
    await attachDroppedFiles(context, ref, [for (final p in media) XFile(p)]);
    return true;
  }
  final png = pasted.png;
  if (png == null) return false;
  try {
    final stamp = DateFormat('yyyy-MM-dd HH.mm.ss').format(DateTime.now());
    ref.read(composerProvider.notifier).addMedia([await library.importBytes(png, fileName: 'Pasted image $stamp.png', mimeHint: 'image/png')]);
  } on Object catch (e) {
    if (context.mounted) showToast(context, 'Could not attach the pasted image: $e', icon: Icons.error_outline_rounded);
  }
  return true;
}

/// Horizontal, reorderable strip of attachments with remove and alt-text
/// controls, plus an "Add" tile.
class MediaTray extends ConsumerWidget {
  const MediaTray({super.key});

  static const double _size = 104;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = ref.watch(composerProvider.select((c) => c.media));
    final notifier = ref.read(composerProvider.notifier);
    if (media.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: _size + 8,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        buildDefaultDragHandles: false,
        itemCount: media.length,
        onReorderItem: notifier.moveMedia,
        proxyDecorator: (child, _, _) => Material(color: Colors.transparent, child: child),
        footer: Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: _AddTile(size: _size, onTap: () => pickAndAttachMedia(context, ref)),
        ),
        itemBuilder: (context, i) {
          final m = media[i];
          return Padding(
            key: ValueKey(m.id),
            padding: const EdgeInsets.fromLTRB(0, 4, Space.sm, 4),
            child: ReorderableDragStartListener(
              index: i,
              child: _MediaItem(media: m, size: _size, onRemove: () => notifier.removeMedia(m.id)),
            ),
          );
        },
      ),
    );
  }
}

class _MediaItem extends ConsumerStatefulWidget {
  const _MediaItem({required this.media, required this.size, required this.onRemove});
  final MediaAttachment media;
  final double size;
  final VoidCallback onRemove;

  @override
  ConsumerState<_MediaItem> createState() => _MediaItemState();
}

class _MediaItemState extends ConsumerState<_MediaItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.media;
    final hasAlt = (m.altText ?? '').isNotEmpty;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.grab,
      child: Stack(children: [
        MediaThumb(m, size: widget.size, showAltTag: false),
        Positioned(
          right: 5,
          top: 5,
          child: _RoundIcon(icon: Icons.close_rounded, tooltip: 'Remove', onTap: widget.onRemove),
        ),
        Positioned(
          left: 5,
          bottom: 5,
          child: AnimatedOpacity(
            duration: Motion.fast,
            opacity: hasAlt || _hover || !Env.isDesktop ? 1 : 0.85,
            child: _AltButton(
              hasAlt: hasAlt,
              onTap: () async {
                final alt = await showAltTextDialog(context, m);
                if (alt != null) ref.read(composerProvider.notifier).setAltText(m.id, alt);
              },
            ),
          ),
        ),
      ]),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), shape: BoxShape.circle),
              child: Icon(icon, size: 15, color: Colors.white),
            ),
          ),
        ),
      );
}

class _AltButton extends StatelessWidget {
  const _AltButton({required this.hasAlt, required this.onTap});
  final bool hasAlt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Tooltip(
      message: hasAlt ? 'Edit description' : 'Add a description for people using screen readers',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
            decoration: BoxDecoration(
              color: hasAlt ? Colors.black.withValues(alpha: 0.62) : nf.warning,
              borderRadius: Radii.rXs,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(hasAlt ? Icons.check_rounded : Icons.add_rounded, size: 11, color: hasAlt ? Colors.white : Colors.black),
              const SizedBox(width: 2),
              Text('ALT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: hasAlt ? Colors.white : Colors.black)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.size, required this.onTap});
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Tooltip(
      message: 'Add photos or videos',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: NfWell(
              dashed: true,
              radius: BorderRadius.circular(size * 0.14),
              padding: EdgeInsets.zero,
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.add_photo_alternate_outlined, color: nf.textMuted, size: 24),
                  const SizedBox(height: Space.xs),
                  Text('Add', style: context.text.labelSmall?.copyWith(color: nf.textMuted)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Alt-text editor with a large preview. Returns the new text, or null when
/// cancelled.
Future<String?> showAltTextDialog(BuildContext context, MediaAttachment media) {
  return showDialog<String>(context: context, builder: (_) => _AltDialog(media: media));
}

class _AltDialog extends StatefulWidget {
  const _AltDialog({required this.media});
  final MediaAttachment media;

  @override
  State<_AltDialog> createState() => _AltDialogState();
}

class _AltDialogState extends State<_AltDialog> {
  late final _c = TextEditingController(text: widget.media.altText ?? '');
  static const _max = 1500;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final len = _c.text.characters.length;
    final wide = !context.isCompact;
    final preview = MediaThumb(widget.media, size: wide ? 260 : 200, aspect: widget.media.aspectRatio?.clamp(0.6, 1.8), fit: BoxFit.contain);
    final form = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Describe this ${widget.media.isVideo ? 'video' : 'image'}', style: context.text.headlineSmall),
      const SizedBox(height: Space.xs),
      Text(
        'Alt text helps people who use screen readers. Say what matters: who or what is shown, any text in it, and why it is there.',
        style: context.text.bodySmall,
      ),
      const SizedBox(height: Space.lg),
      TextField(
        controller: _c,
        autofocus: true,
        minLines: 4,
        maxLines: 8,
        maxLength: _max,
        buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(hintText: 'e.g. A wooden workbench with a vintage lathe under warm light'),
      ),
      const SizedBox(height: Space.xs),
      Align(
        alignment: Alignment.centerRight,
        child: Text('$len / $_max', style: monoStyle(context, size: 11.5, color: len > _max * 0.9 ? nf.warning : nf.textFaint)),
      ),
    ]);
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(Space.xxl, Space.xxl, Space.xxl, Space.md),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 720 : 420),
        child: SingleChildScrollView(
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  preview,
                  const SizedBox(width: Space.xxl),
                  Expanded(child: form),
                ])
              : Column(mainAxisSize: MainAxisSize.min, children: [Center(child: preview), const SizedBox(height: Space.lg), form]),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(Space.xxl, 0, Space.xxl, Space.xl),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: nf.textMuted),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context, _c.text.trim()), child: const Text('Save')),
      ],
    );
  }
}
