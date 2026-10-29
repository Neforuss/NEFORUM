import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:path/path.dart' as p;

import '../../documents/document_ingest.dart';
import '../../documents/document_model.dart';
import '../../documents/thread_builder.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';

/// True for a file NEFORUM turns into a thread (.pdf, .docx, .epub, .md,
/// .txt, .html).
bool isDocumentFile(String name) => DocumentFormat.ofFileName(name) != null;

/// Asks for a document and turns it into a draft thread.
Future<void> pickDocumentForThread(BuildContext context, WidgetRef ref) async {
  final List<PlatformFile> files;
  try {
    files = await FilePicker.pickFiles(
      dialogTitle: 'Make a thread from a document',
      type: FileType.custom,
      allowedExtensions: DocumentFormat.allExtensions,
    );
  } on Object catch (e) {
    if (context.mounted) showToast(context, 'Could not open the picker: $e', icon: Icons.error_outline_rounded);
    return;
  }
  if (files.isEmpty || !context.mounted) return;
  final f = files.first;
  final bytes = await f.readAsBytes();
  if (!context.mounted) return;
  await importDocumentAsThread(context, ref, name: f.name, bytes: bytes, path: f.path);
}

/// A document dropped on the composer.
Future<void> importDroppedDocument(BuildContext context, WidgetRef ref, XFile file) async {
  final bytes = await file.readAsBytes();
  if (!context.mounted) return;
  await importDocumentAsThread(context, ref, name: file.name, bytes: bytes, path: file.path.isEmpty ? null : file.path);
}

/// Reads the document, shows its parts and pictures, and on "Make a thread"
/// fills the composer with them (asking first when the composer already
/// holds a post). Nothing is posted.
Future<void> importDocumentAsThread(BuildContext context, WidgetRef ref, {required String name, required Uint8List bytes, String? path}) async {
  final thread = await showDialog<DocumentThread>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DocumentImportDialog(name: name, bytes: bytes, folder: path == null ? null : p.dirname(path), partLength: documentPartLength(ref)),
  );
  if (thread == null || !context.mounted) return;
  final c = ref.read(composerProvider);
  if (!c.isEmpty || c.additionalParts.isNotEmpty) {
    final ok = await confirmDialog(
      context,
      title: 'Replace the post you are writing?',
      message: 'The ${thread.parts.length} parts of $name take the place of the words and attachments in the composer. '
          'Your networks and schedule stay.',
      confirmLabel: 'Replace',
    );
    if (!ok || !context.mounted) return;
  }
  final library = ref.read(servicesProvider).media;
  final media = <MediaAttachment>[];
  final mediaParts = <String, int>{};
  var failed = 0;
  for (var i = 0; i < thread.parts.length; i++) {
    for (final image in thread.parts[i].images) {
      try {
        var m = await library.importBytes(image.bytes, fileName: _imageFileName(name, media.length + 1, image), mimeHint: image.mimeType);
        final alt = image.altText;
        if (alt != null && alt.isNotEmpty) m = m.copyWith(altText: alt);
        media.add(m);
        if (i > 0) mediaParts[m.id] = i;
      } on Object {
        failed++;
      }
    }
  }
  ref.read(composerProvider.notifier).fillThread([for (final part in thread.parts) part.text], media, mediaParts);
  if (context.mounted) {
    showToast(
      context,
      failed == 0
          ? 'Thread of ${thread.parts.length} parts ready to check'
          : 'Thread of ${thread.parts.length} parts ready; $failed picture${failed == 1 ? '' : 's'} could not be attached',
      icon: Icons.check_circle_outline_rounded,
    );
  }
}

String _imageFileName(String document, int n, DocumentImage image) {
  final base = p.basenameWithoutExtension(document);
  final ext = switch (image.mimeType) {
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => 'png',
  };
  return '$base picture $n.$ext';
}

/// How long a part of a document thread may be: the tightest limit among
/// the selected networks that post threads on their own, so that each part
/// is one post there and its pictures stay beside its words. 500 when no
/// such network is selected.
int documentPartLength(WidgetRef ref) {
  int? tightest;
  for (final preview in ref.read(composerPreviewsProvider)) {
    final rules = preview.descriptor.text;
    final max = rules.maxLength;
    if (max == null || !rules.supportsThreads || !preview.account.tier.isAutomatic) continue;
    // Room for the " (12/34)" numbering.
    final room = max - TextSplitter.suffixLength(99);
    tightest = tightest == null ? room : math.min(tightest, room);
  }
  return math.max(100, tightest ?? 500);
}

/// Reads a document and previews the thread it makes: the parts in order
/// with their pictures, the number of parts, and what could not be read.
/// Pops with the [DocumentThread] on "Make a thread", or null.
class DocumentImportDialog extends StatefulWidget {
  const DocumentImportDialog({super.key, required this.name, required this.bytes, this.folder, this.partLength = 500});

  final String name;
  final Uint8List bytes;

  /// The document's folder, where web pages and Markdown find pictures.
  final String? folder;
  final int partLength;

  @override
  State<DocumentImportDialog> createState() => _DocumentImportDialogState();
}

class _DocumentImportDialogState extends State<DocumentImportDialog> {
  IngestedDocument? _document;
  DocumentThread? _thread;
  String? _error;
  int _done = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final document = await ingestDocument(
        widget.bytes,
        fileName: widget.name,
        folder: widget.folder,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _document = document;
        _thread = buildDocumentThread(document, partLength: widget.partLength);
      });
    } on DocumentReadException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'NEFORUM could not read ${widget.name}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final thread = _thread;
    final document = _document;
    final compact = context.isCompact;
    final Widget body;
    if (_error != null) {
      body = _Notice(icon: Icons.error_outline_rounded, color: nf.danger, text: _error!);
    } else if (thread == null || document == null) {
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
        const SizedBox(height: Space.md),
        Text(_total == 0 ? 'Reading the document…' : 'Reading page ${math.min(_done + 1, _total)} of $_total…', style: context.text.bodySmall),
      ]);
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          thread.parts.isEmpty
              ? 'Nothing to make a thread from.'
              : '${thread.parts.length} part${thread.parts.length == 1 ? '' : 's'} · ${thread.imageCount} picture${thread.imageCount == 1 ? '' : 's'}'
                  '${document.pageCount == null ? '' : ' · ${document.pageCount} page${document.pageCount == 1 ? '' : 's'}'}',
          style: context.text.titleSmall,
        ),
        const SizedBox(height: Space.xs),
        Text('Nothing is posted: the parts go into the composer, where you can edit them first.', style: context.text.bodySmall),
        for (final w in document.warnings) ...[
          const SizedBox(height: Space.sm),
          _Notice(icon: Icons.info_outline_rounded, color: nf.warning, text: w),
        ],
        const SizedBox(height: Space.md),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: thread.parts.length,
            separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
            itemBuilder: (context, i) => _PartPreview(index: i, part: thread.parts[i]),
          ),
        ),
      ]);
    }
    return AlertDialog(
      insetPadding: EdgeInsets.symmetric(horizontal: compact ? Space.lg : Space.x4, vertical: Space.xxl),
      title: Text('Make a thread from ${widget.name}', maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(width: compact ? double.maxFinite : 620, child: body),
      actionsPadding: const EdgeInsets.fromLTRB(Space.xxl, 0, Space.xxl, Space.xl),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: nf.textMuted),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: thread == null || thread.parts.isEmpty ? null : () => Navigator.pop(context, thread),
          child: const Text('Make a thread'),
        ),
      ],
    );
  }
}

class _PartPreview extends StatelessWidget {
  const _PartPreview({required this.index, required this.part});
  final int index;
  final DocumentThreadPart part;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return NfWell(
      padding: const EdgeInsets.all(Space.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Part ${index + 1}', style: context.text.labelMedium?.copyWith(color: nf.textMuted))),
          Text('${part.text.characters.length} characters', style: monoStyle(context, size: 11, color: nf.textFaint)),
        ]),
        const SizedBox(height: Space.xs),
        Text(part.text, maxLines: 6, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium),
        if (part.images.isNotEmpty) ...[
          const SizedBox(height: Space.sm),
          Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
            for (final image in part.images)
              Tooltip(
                message: image.altText ?? 'No description',
                child: ClipRRect(
                  borderRadius: Radii.rXs,
                  child: Image.memory(image.bytes, width: 64, height: 64, fit: BoxFit.cover, cacheWidth: 128, gaplessPlayback: true),
                ),
              ),
          ]),
        ],
      ]),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: Space.sm),
        Expanded(child: Text(text, style: context.text.bodySmall)),
      ]);
}
