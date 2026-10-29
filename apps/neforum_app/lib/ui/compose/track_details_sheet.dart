import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/layout.dart';

/// Opens the track details editor for the post's sound file: every detail
/// the file's tags can carry, a cover, and the post text they make. Saving
/// puts the edits in the composer ([ComposerNotifier.setAudioDetails]) and
/// the text template in Settings.
Future<void> showTrackDetailsEditor(BuildContext context) {
  const editor = TrackDetailsEditor();
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

/// One editable text detail of a track.
enum TrackDetail {
  title('Title'),
  artist('Artist'),
  album('Album'),
  albumArtist('Album artist'),
  year('Year'),
  genre('Genre'),
  trackNumber('Track'),
  trackTotal('Total tracks'),
  discNumber('Disc'),
  composer('Composer'),
  comment('Comment'),
  lyrics('Lyrics');

  const TrackDetail(this.label);
  final String label;

  bool get isNumber => this == year || this == trackNumber || this == trackTotal || this == discNumber;

  /// The detail in [t] as the editor shows it ("" when [t] lacks it).
  String of(AudioTags t) => switch (this) {
        title => t.title ?? '',
        artist => t.artist ?? '',
        album => t.album ?? '',
        albumArtist => t.albumArtist ?? '',
        year => '${t.year ?? ''}',
        genre => t.genre ?? '',
        trackNumber => '${t.trackNumber ?? ''}',
        trackTotal => '${t.trackTotal ?? ''}',
        discNumber => '${t.discNumber ?? ''}',
        composer => t.composer ?? '',
        comment => t.comment ?? '',
        lyrics => t.lyrics ?? '',
      };
}

/// Where the cover comes from in the editor.
enum _CoverChoice { file, picked, removed }

/// The user's edits over [file], as [Post.audioDetails] keeps them: only
/// what differs from the file, an empty text or 0 where the user cleared
/// what the file says, and [coverPath] (`''` to remove the file's cover).
/// Null when nothing differs.
AudioTags? trackDetailsEdits(AudioTags file, Map<TrackDetail, String> values, {String? coverPath, String? coverMimeType}) {
  String? text(TrackDetail d) {
    final v = (values[d] ?? '').trim();
    return v == d.of(file).trim() ? null : v;
  }

  int? number(TrackDetail d) {
    final v = (values[d] ?? '').trim();
    if (v == d.of(file)) return null;
    if (v.isEmpty) return 0;
    final n = int.tryParse(v);
    return n == null || n <= 0 ? null : n;
  }

  final edits = AudioTags(
    title: text(TrackDetail.title),
    artist: text(TrackDetail.artist),
    album: text(TrackDetail.album),
    albumArtist: text(TrackDetail.albumArtist),
    year: number(TrackDetail.year),
    genre: text(TrackDetail.genre),
    trackNumber: number(TrackDetail.trackNumber),
    trackTotal: number(TrackDetail.trackTotal),
    discNumber: number(TrackDetail.discNumber),
    composer: text(TrackDetail.composer),
    comment: text(TrackDetail.comment),
    lyrics: text(TrackDetail.lyrics),
    coverPath: coverPath,
    coverMimeType: coverPath == null || coverPath.isEmpty ? null : coverMimeType,
  );
  return edits.isEmpty ? null : edits;
}

/// The editor [showTrackDetailsEditor] opens; public for tests.
class TrackDetailsEditor extends ConsumerStatefulWidget {
  const TrackDetailsEditor({super.key});

  @override
  ConsumerState<TrackDetailsEditor> createState() => _TrackDetailsEditorState();
}

class _TrackDetailsEditorState extends ConsumerState<TrackDetailsEditor> {
  late final AudioTags _file;
  late final Map<TrackDetail, TextEditingController> _fields;
  late final TextEditingController _template;
  late _CoverChoice _cover;
  String? _pickedPath;
  String? _pickedMime;

  @override
  void initState() {
    super.initState();
    final c = ref.read(composerProvider);
    _file = c.audio?.audioTags ?? AudioTags.none;
    final shown = _file.overriddenBy(c.audioDetails);
    _fields = {for (final d in TrackDetail.values) d: TextEditingController(text: d.of(shown))};
    _template = TextEditingController(text: ref.read(settingsProvider).audioTextTemplate);
    final edited = c.audioDetails?.coverPath;
    if (edited == null) {
      _cover = _CoverChoice.file;
    } else if (edited.isEmpty) {
      _cover = _CoverChoice.removed;
    } else {
      _cover = _CoverChoice.picked;
      _pickedPath = edited;
      _pickedMime = c.audioDetails?.coverMimeType;
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _template.dispose();
    super.dispose();
  }

  Map<TrackDetail, String> get _values => {for (final e in _fields.entries) e.key: e.value.text};

  String? get _coverEdit => switch (_cover) {
        _CoverChoice.file => null,
        _CoverChoice.picked => _pickedPath,
        _CoverChoice.removed => _file.hasCover ? '' : null,
      };

  AudioTags? get _edits => trackDetailsEdits(_file, _values, coverPath: _coverEdit, coverMimeType: _pickedMime);

  /// The details as they go out with the current edits.
  AudioTags get _effective => _file.overriddenBy(_edits);

  String? get _coverPath => switch (_cover) {
        _CoverChoice.file => _file.hasCover ? _file.coverPath : null,
        _CoverChoice.picked => _pickedPath,
        _CoverChoice.removed => null,
      };

  void _resetAll() => setState(() {
        for (final d in TrackDetail.values) {
          _fields[d]!.text = d.of(_file);
        }
        _cover = _CoverChoice.file;
      });

  Future<void> _pickCover() async {
    try {
      final files = await FilePicker.pickFiles(dialogTitle: 'Choose a cover picture', type: FileType.custom, allowedExtensions: const ['jpg', 'jpeg', 'png']);
      final f = files.firstOrNull;
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final mime = lookupMimeType(f.name, headerBytes: bytes.length > 16 ? bytes.sublist(0, 16) : bytes) ?? 'image/jpeg';
      if (mime != 'image/jpeg' && mime != 'image/png') {
        if (mounted) showToast(context, 'Choose a JPEG or PNG picture', icon: Icons.info_outline_rounded);
        return;
      }
      final path = await ref.read(servicesProvider).media.saveCover(bytes, mime);
      if (!mounted) return;
      setState(() {
        _cover = _CoverChoice.picked;
        _pickedPath = path;
        _pickedMime = mime;
      });
    } on Object catch (e) {
      if (mounted) showToast(context, 'Could not open the picture: $e', icon: Icons.error_outline_rounded);
    }
  }

  void _save({bool useAsText = false}) {
    final notifier = ref.read(composerProvider.notifier);
    notifier.setAudioDetails(_edits);
    final template = _template.text.trim().isEmpty ? kDefaultAudioTextTemplate : _template.text;
    final settings = ref.read(settingsProvider);
    if (template != settings.audioTextTemplate) {
      ref.read(settingsProvider.notifier).update((x) => x.copyWith(audioTextTemplate: template));
    }
    if (useAsText) notifier.useTrackDetailsAsText(template);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final textEmpty = ref.watch(composerProvider.select((c) => c.text.trim().isEmpty));
    final preview = renderAudioText(_template.text.trim().isEmpty ? kDefaultAudioTextTemplate : _template.text, _effective);
    final hasFileTags = !_file.isEmpty;

    Widget field(TrackDetail d, {int maxLines = 1}) {
      final c = _fields[d]!;
      final own = d.of(_file);
      final fromFile = own.isNotEmpty && c.text.trim() == own.trim();
      final edited = c.text.trim() != own.trim();
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.sm),
        child: TextField(
          key: ValueKey('track-${d.name}'),
          controller: c,
          onChanged: (_) => setState(() {}),
          minLines: maxLines > 1 ? 3 : 1,
          maxLines: maxLines,
          keyboardType: d.isNumber ? TextInputType.number : (maxLines > 1 ? TextInputType.multiline : TextInputType.text),
          decoration: InputDecoration(
            labelText: d.label,
            helperText: fromFile ? 'From the file' : (edited && own.isNotEmpty ? 'Edited · the file says "$own"' : null),
            helperMaxLines: 1,
            helperStyle: context.text.bodySmall?.copyWith(color: fromFile ? nf.textFaint : nf.accent),
            suffixIcon: edited && own.isNotEmpty
                ? IconButton(
                    tooltip: 'Back to the file\'s ${d.label.toLowerCase()}',
                    icon: const Icon(Icons.undo_rounded, size: 18),
                    onPressed: () => setState(() => c.text = own),
                  )
                : null,
          ),
        ),
      );
    }

    Widget pair(TrackDetail a, TrackDetail b, {int flexA = 1, int flexB = 1}) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: flexA, child: field(a)),
          const SizedBox(width: Space.md),
          Expanded(flex: flexB, child: field(b)),
        ]);

    final coverPath = _coverPath;
    final storage = ref.read(servicesProvider).storage;
    final cover = Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      ClipRRect(
        borderRadius: Radii.rSm,
        child: SizedBox(
          width: 88,
          height: 88,
          child: coverPath == null
              ? ColoredBox(color: nf.accentSoft, child: Icon(Icons.album_outlined, size: 36, color: nf.accent))
              : storage.image(coverPath, width: 88, height: 88, cacheWidth: 176),
        ),
      ),
      const SizedBox(width: Space.lg),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Cover', style: context.text.titleSmall),
          Text(
            switch (_cover) {
              _CoverChoice.file => _file.hasCover ? 'From the file' : 'The file has no cover',
              _CoverChoice.picked => 'Your picture',
              _CoverChoice.removed => 'No cover',
            },
            style: context.text.bodySmall?.copyWith(color: nf.textMuted),
          ),
          Wrap(spacing: Space.xs, children: [
            TextButton.icon(onPressed: _pickCover, icon: const Icon(Icons.image_outlined, size: 18), label: const Text('Choose a picture')),
            if (_file.hasCover && _cover != _CoverChoice.file)
              TextButton(onPressed: () => setState(() => _cover = _CoverChoice.file), child: const Text('Use the file\'s cover')),
            if (coverPath != null)
              TextButton(
                onPressed: () => setState(() => _cover = _CoverChoice.removed),
                style: TextButton.styleFrom(foregroundColor: nf.danger),
                child: const Text('Remove'),
              ),
          ]),
        ]),
      ),
    ]);

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.xxl, Space.xs),
        child: Text('Track details', style: context.text.headlineSmall),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
        child: Text(
          hasFileTags
              ? 'Read from the file\'s tags. What you change here goes to every network and into the copies NEFORUM makes; '
                  'your file stays as it is.'
              : 'This file has no tags. What you fill in goes to every network and into the copies NEFORUM makes.',
          style: context.text.bodySmall,
        ),
      ),
      const SizedBox(height: Space.md),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            cover,
            const SizedBox(height: Space.lg),
            field(TrackDetail.title),
            field(TrackDetail.artist),
            pair(TrackDetail.album, TrackDetail.albumArtist),
            pair(TrackDetail.year, TrackDetail.genre, flexB: 2),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: field(TrackDetail.trackNumber)),
              const SizedBox(width: Space.md),
              Expanded(child: field(TrackDetail.trackTotal)),
              const SizedBox(width: Space.md),
              Expanded(child: field(TrackDetail.discNumber)),
            ]),
            field(TrackDetail.composer),
            field(TrackDetail.comment, maxLines: 4),
            field(TrackDetail.lyrics, maxLines: 8),
            const SizedBox(height: Space.sm),
            const SectionHeader('Post text from the details'),
            const SizedBox(height: Space.xs),
            TextField(
              key: const ValueKey('track-template'),
              controller: _template,
              onChanged: (_) => setState(() {}),
              style: monoStyle(context, size: 13),
              decoration: InputDecoration(
                labelText: 'Template',
                helperText: 'Tokens: ${audioTextTokens.map((t) => '{$t}').join(' ')}. Missing details drop out.',
                helperMaxLines: 2,
                suffixIcon: _template.text != kDefaultAudioTextTemplate
                    ? IconButton(
                        tooltip: 'Back to the standard template',
                        icon: const Icon(Icons.undo_rounded, size: 18),
                        onPressed: () => setState(() => _template.text = kDefaultAudioTextTemplate),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: Space.sm),
            _TextPreview(text: preview),
            const SizedBox(height: Space.lg),
          ]),
        ),
      ),
      Divider(height: 1, color: nf.border),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.md, Space.xxl, Space.lg),
        child: Wrap(alignment: WrapAlignment.end, spacing: Space.sm, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (hasFileTags)
            TextButton(onPressed: _resetAll, style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Reset to the file\'s tags')),
          TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
          if (textEmpty && preview.isNotEmpty)
            OutlinedButton(onPressed: () => _save(useAsText: true), child: const Text('Save and use as the text')),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ]),
      ),
    ]);
  }
}

/// The post text the template makes, as it will read.
class _TextPreview extends StatelessWidget {
  const _TextPreview({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(color: nf.surfaceSunken, borderRadius: Radii.rSm, border: Border.all(color: nf.border)),
      child: Text(
        text.isEmpty ? 'Fill in a title or an artist to see the text' : text,
        key: const ValueKey('track-preview'),
        style: context.text.bodyMedium?.copyWith(color: text.isEmpty ? nf.textFaint : nf.text),
      ),
    );
  }
}

/// Under the media tray of a post with a sound file: the track as it goes
/// out ("Artist – Title"), a button to the details, and "Use track details
/// as the text" while the post has no text.
class TrackDetailsRow extends ConsumerWidget {
  const TrackDetailsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final tags = ref.watch(composerProvider.select((c) => c.effectiveAudioTags));
    if (tags == null) return const SizedBox.shrink();
    final textEmpty = ref.watch(composerProvider.select((c) => c.text.trim().isEmpty));
    final template = ref.watch(settingsProvider.select((s) => s.audioTextTemplate));
    final name = tags.artistAndTitle;
    final edited = ref.watch(composerProvider.select((c) => c.audioDetails != null));
    return Wrap(spacing: Space.sm, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.album_outlined, size: 18, color: nf.textMuted),
        const SizedBox(width: Space.xs),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Text(
            name ?? 'No track details',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.labelMedium?.copyWith(color: name == null ? nf.textFaint : nf.text),
          ),
        ),
        if (edited) ...[
          const SizedBox(width: Space.xs),
          Text('· edited', style: context.text.labelSmall?.copyWith(color: nf.textMuted)),
        ],
      ]),
      TextButton.icon(
        key: const ValueKey('track-details-button'),
        onPressed: () => showTrackDetailsEditor(context),
        icon: const Icon(Icons.edit_note_rounded, size: 18),
        label: Text(name == null ? 'Add track details' : 'Track details'),
      ),
      if (textEmpty && renderAudioText(template, tags).isNotEmpty)
        TextButton.icon(
          key: const ValueKey('track-use-as-text'),
          onPressed: () => ref.read(composerProvider.notifier).useTrackDetailsAsText(template),
          icon: const Icon(Icons.short_text_rounded, size: 18),
          label: const Text('Use track details as the text'),
        ),
    ]);
  }
}
