import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../media/aligned_text.dart';
import '../../media/caption_overlay.dart';
import '../../media/caption_style.dart';
import '../../media/photo_fitter.dart';
import '../../media/text_card.dart';
import '../../state/captioned_photos.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../state/settings.dart' show TextCardAlignment;
import '../../theme/tokens.dart';
import '../../widgets/layout.dart' show showToast;

/// The colours a colour fill would use around the photo at a path; `.$2` =
/// borders above and below.
final photoEdgeColoursProvider = FutureProvider.autoDispose.family<EdgeColours?, (String, bool)>((ref, key) async {
  final storage = ref.read(servicesProvider).storage;
  return edgeColoursOf(await storage.readMedia(key.$1), vertical: key.$2);
});

/// A network's whole frame with the caption in a block above the photo, the
/// way [renderCaptionedPhoto] saves it: the room around the photo filled the
/// way Settings fit photos, under the style's background colour, and the
/// photo scaled to fit below the block (cut to fill it when cropping).
class CaptionBlockFrame extends ConsumerWidget {
  const CaptionBlockFrame({super.key, required this.platformId, required this.photo, required this.text, required this.style, required this.fit});

  final String platformId;

  /// The photo the user attached; null shows a neutral stand-in.
  final MediaAttachment? photo;
  final String text;
  final CaptionStyle style;
  final PhotoFitMode fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storage = ref.read(servicesProvider).storage;
    final font = style.font.resolve(platformId);
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      final aspect = size.width / size.height;
      final safe = captionSafeArea(platformId, aspect);
      final layout = CaptionBlockLayout.measure(text: text, style: style, font: font, frame: size, safe: safe);
      final content = layout.content;
      layout.dispose();
      final u = size.width / 1080;
      final Widget fill;
      if (photo == null) {
        fill = const DecoratedBox(
          decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3A3F58), Color(0xFF7A6A8F)])),
        );
      } else if (fit == PhotoFitMode.color) {
        final edges = ref.watch(photoEdgeColoursProvider((photo!.path, true))).value;
        fill = edges == null
            ? const ColoredBox(color: Colors.black)
            : DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF000000 | edges.start), Color(0xFF000000 | edges.end)],
                  ),
                ),
              );
      } else {
        fill = ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 48 * u, sigmaY: 48 * u, tileMode: TileMode.clamp),
          child: storage.image(photo!.path, fit: BoxFit.cover, cacheWidth: 120),
        );
      }
      return Stack(fit: StackFit.expand, children: [
        fill,
        if (style.background != CaptionBackground.none) ColoredBox(color: style.backgroundFill),
        Positioned.fromRect(
          rect: content,
          child: photo == null
              ? const SizedBox.shrink()
              : storage.image(photo!.path, fit: fit == PhotoFitMode.crop ? BoxFit.cover : BoxFit.contain),
        ),
        CustomPaint(painter: CaptionBlockPainter(text: text, font: font, style: style, safe: safe)),
      ]);
    });
  }
}

/// A photo with its caption as it will be saved, for the caption editor and
/// Settings: written over the photo, or in a block above it in the network's
/// frame. Without a photo, a neutral stand-in.
class CaptionPhotoPreview extends ConsumerWidget {
  const CaptionPhotoPreview({super.key, required this.platformId, required this.photo, required this.text, required this.style, this.storyMode = false});

  final String platformId;
  final MediaAttachment? photo;
  final String text;
  final CaptionStyle style;
  final bool storyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storage = ref.read(servicesProvider).storage;
    final settings = ref.watch(settingsProvider);
    final frame = platformId == 'instagram' && !storyMode ? 4 / 5 : 9 / 16;
    final Widget body;
    final double aspect;
    if (style.placement == CaptionPlacement.blockAbove) {
      aspect = frame;
      body = CaptionBlockFrame(platformId: platformId, photo: photo, text: text, style: style, fit: settings.photoFit);
    } else {
      aspect = photo?.aspectRatio?.clamp(0.5, 1.91).toDouble() ?? frame;
      body = Stack(fit: StackFit.expand, children: [
        if (photo == null)
          const DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3A3F58), Color(0xFF7A6A8F)])),
          )
        else
          storage.image(photo!.path, fit: BoxFit.cover),
        CustomPaint(
          painter: CaptionOverlayPainter(text: text, font: style.font.resolve(platformId), style: style, safe: captionSafeArea(platformId, aspect)),
        ),
      ]);
    }
    return AspectRatio(aspectRatio: aspect, child: ClipRRect(borderRadius: Radii.rMd, child: body));
  }
}

/// Opens the caption editor: the style of the caption written on photos, with
/// a live preview. For a post ([defaults] false) it edits the composer's
/// style and the caption switch for each network; with [defaults] it edits
/// the Settings default that new posts start with.
Future<void> showCaptionEditorSheet(BuildContext context, {String? platformId, bool defaults = false}) {
  final sheet = CaptionEditorSheet(platformId: platformId, defaults: defaults);
  if (context.isCompact) {
    return showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => sheet);
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720, maxHeight: 860), child: sheet),
    ),
  );
}

class CaptionEditorSheet extends ConsumerStatefulWidget {
  const CaptionEditorSheet({super.key, this.platformId, this.defaults = false});

  /// The network whose preview opened the editor; its frame is previewed.
  final String? platformId;
  final bool defaults;

  @override
  ConsumerState<CaptionEditorSheet> createState() => _CaptionEditorSheetState();
}

class _CaptionEditorSheetState extends ConsumerState<CaptionEditorSheet> {
  late CaptionStyle _style;
  late final TextEditingController _words;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _style = widget.defaults ? CaptionStyle.fromJson(settings.captionStyle) : captionStyleFor(ref.read(composerProvider).captionStyle, settings);
    _words = TextEditingController(text: _style.text ?? '');
  }

  @override
  void dispose() {
    _words.dispose();
    super.dispose();
  }

  void _apply(CaptionStyle next) {
    setState(() => _style = next);
    if (widget.defaults) {
      final json = next.copyWith(clearText: true).toJson();
      ref.read(settingsProvider.notifier).update((x) => x.copyWith(captionStyle: json));
    } else {
      ref.read(composerProvider.notifier).setCaptionStyle(next.toJson());
    }
  }

  void _setCaptionOn(String platformId, bool on) {
    ref.read(composerProvider.notifier).setCaptionOnPhoto(platformId, on);
    // Remembered for the network, as the switch under the preview always was.
    ref.read(settingsProvider.notifier).update((x) => x.copyWith(
          captionPhotoPlatforms: on ? {...x.captionPhotoPlatforms, platformId}.toList() : x.captionPhotoPlatforms.where((p) => p != platformId).toList(),
        ));
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final settings = ref.watch(settingsProvider);
    final composer = ref.watch(composerProvider);
    final registry = ref.watch(registryProvider);
    final accounts = ref.watch(accountListProvider);
    final platform = widget.platformId ?? 'tiktok';
    final networks = widget.defaults
        ? const <String>[]
        : [
            for (final id in kCaptionPhotoPlatforms)
              if (id == widget.platformId || accounts.any((a) => a.platformId == id && composer.selected.contains(a.id))) id,
          ];
    final post = composer.toPost(id: 'preview', status: PostStatus.draft, now: DateTime.now());
    final caption = widget.defaults ? '' : captionWords(post, PostTarget(accountId: ''));
    final sample = caption.isEmpty ? 'Your caption, on your photo.' : caption;
    final photo = widget.defaults ? null : composer.media.where((m) => m.kind == MediaKind.image).firstOrNull;
    final storyMode = platform == 'instagram' &&
        accounts.any((a) => a.platformId == 'instagram' && composer.selected.contains(a.id) && composer.overrides[a.id]?.extra['storyMode'] == true);

    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
          child: Text(text, style: context.text.titleSmall),
        );
    Widget swatches(int selected, ValueChanged<int> onPick, {required String what}) => Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          for (final c in kCaptionColors)
            Semantics(
              button: true,
              selected: c == selected,
              label: '$what ${_colorName(c)}',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => onPick(c),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(color: c == selected ? nf.accent : nf.borderStrong, width: c == selected ? 3 : 1),
                  ),
                ),
              ),
            ),
        ]);

    final preview = ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 340, maxWidth: 260),
      child: CaptionPhotoPreview(platformId: platform, photo: photo, text: _style.wordsFor(sample), style: _style, storyMode: storyMode),
    );

    final controls = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      for (final id in networks)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Write the caption on the ${registry.descriptor(id)?.name ?? id} photo', style: context.text.bodyMedium),
          value: captionOnPhotoFor(id, settings, composer.captionOnPhoto),
          onChanged: (on) => _setCaptionOn(id, on),
        ),
      if (!widget.defaults) ...[
        label('Words on the photo'),
        TextField(
          key: const Key('caption-words'),
          controller: _words,
          minLines: 1,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: 'Same as the caption',
            helperText: 'Leave empty to use your caption, without trailing hashtags and links.',
            helperMaxLines: 2,
            suffixIcon: _words.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Use the caption',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () {
                      _words.clear();
                      _apply(_style.copyWith(clearText: true));
                    },
                  ),
          ),
          onChanged: (v) => _apply(v.trim().isEmpty ? _style.copyWith(clearText: true) : _style.copyWith(text: v)),
        ),
      ],
      label('Place'),
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        for (final p in CaptionPlacement.values)
          Tooltip(
            message: p.description,
            child: ChoiceChip(
              key: Key('caption-placement-${p.name}'),
              label: Text(p.label),
              selected: _style.placement == p,
              onSelected: (_) => _apply(_style.copyWith(placement: p)),
            ),
          ),
      ]),
      label('Text size'),
      Row(children: [
        FilterChip(
          key: const Key('caption-size-automatic'),
          label: const Text('Fit automatically'),
          selected: !_style.fixedSize,
          onSelected: (on) => _apply(on ? _style.copyWith(automaticSize: true) : _style.copyWith(textScale: 1)),
        ),
        if (_style.fixedSize)
          Expanded(
            child: Slider(
              value: _style.textScale!,
              min: CaptionStyle.minTextScale,
              max: CaptionStyle.maxTextScale,
              divisions: 20,
              label: '${(_style.textScale! * 100).round()}%',
              onChanged: (v) => _apply(_style.copyWith(textScale: v)),
            ),
          ),
      ]),
      label('Text colour'),
      swatches(_style.textColor, (c) => _apply(_style.copyWith(textColor: c)), what: 'Text'),
      label('Background'),
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        for (final b in CaptionBackground.values)
          ChoiceChip(
            key: Key('caption-background-${b.name}'),
            label: Text(b.label),
            selected: _style.background == b,
            onSelected: (_) => _apply(_style.copyWith(background: b)),
          ),
      ]),
      if (_style.background == CaptionBackground.solid) ...[
        const SizedBox(height: Space.sm),
        swatches(_style.backgroundColor, (c) => _apply(_style.copyWith(backgroundColor: c)), what: 'Background'),
      ],
      if (_style.background != CaptionBackground.none)
        _slider(context, 'Opacity', _style.opacity, 0, 1, '${(_style.opacity * 100).round()}%', (v) => _apply(_style.copyWith(opacity: v))),
      label('Alignment'),
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        for (final a in TextCardAlignment.values)
          Tooltip(
            message: '${a.label}: ${a.description}',
            child: ChoiceChip(
              key: Key('caption-alignment-${a.name}'),
              avatar: Icon(a.icon, size: 16),
              label: Text(a.label),
              selected: _style.alignment == a,
              onSelected: (_) => _apply(_style.copyWith(alignment: a)),
            ),
          ),
      ]),
      label('Font'),
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        for (final f in TextCardFont.values)
          ChoiceChip(
            label: Text(f == TextCardFont.original ? 'Inter' : f.label),
            selected: _style.font == f,
            onSelected: (_) => _apply(_style.copyWith(font: f)),
          ),
      ]),
      const SizedBox(height: Space.md),
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        FilterChip(
          key: const Key('caption-bold'),
          avatar: const Icon(Icons.format_bold_rounded, size: 16),
          label: const Text('Bold'),
          selected: _style.bold,
          onSelected: (v) => _apply(_style.copyWith(bold: v)),
        ),
        FilterChip(
          key: const Key('caption-shadow'),
          avatar: const Icon(Icons.blur_on_rounded, size: 16),
          label: const Text('Shadow'),
          selected: _style.shadow,
          onSelected: (v) => _apply(_style.copyWith(shadow: v)),
        ),
      ]),
      _slider(context, 'Line spacing', _style.lineSpacing, CaptionStyle.minLineSpacing, CaptionStyle.maxLineSpacing,
          _style.lineSpacing.toStringAsFixed(2), (v) => _apply(_style.copyWith(lineSpacing: v))),
      _slider(context, 'Padding', _style.padding, 0, CaptionStyle.maxPadding, '${_style.padding.round()} px',
          (v) => _apply(_style.copyWith(padding: v.roundToDouble()))),
    ]);

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.lg, Space.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.defaults ? 'Default caption style' : 'Caption on photo', style: context.text.headlineSmall),
          const SizedBox(height: 2),
          Text(
            widget.defaults
                ? 'How new posts write the caption on TikTok and Instagram photos. Each post can change it.'
                : 'Your caption, written on the first photo for TikTok and Instagram. It is still posted as text too.',
            style: context.text.bodySmall,
          ),
        ]),
      ),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Space.xxl, Space.sm, Space.xxl, Space.lg),
          child: LayoutBuilder(
            builder: (context, c) => c.maxWidth >= 560
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 220, child: preview),
                    const SizedBox(width: Space.xl),
                    Expanded(child: controls),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Center(child: preview), controls]),
          ),
        ),
      ),
      Divider(height: 1, color: nf.border),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.md, Space.xxl, Space.lg),
        child: Wrap(alignment: WrapAlignment.end, spacing: Space.sm, runSpacing: Space.sm, children: [
          TextButton.icon(
            onPressed: () {
              final base = widget.defaults ? const CaptionStyle() : CaptionStyle.fromJson(settings.captionStyle);
              _words.clear();
              _apply(base);
            },
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: Text(widget.defaults ? 'Reset' : 'Use the default'),
            style: TextButton.styleFrom(foregroundColor: nf.textMuted),
          ),
          if (!widget.defaults)
            OutlinedButton(
              onPressed: () {
                ref.read(settingsProvider.notifier).update((x) => x.copyWith(captionStyle: _style.copyWith(clearText: true).toJson()));
                showToast(context, 'Saved as the default caption style', icon: Icons.check_rounded);
              },
              child: const Text('Save as default'),
            ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ]),
      ),
    ]);
  }

  Widget _slider(BuildContext context, String title, double value, double min, double max, String shown, ValueChanged<double> onChanged) => Padding(
        padding: const EdgeInsets.only(top: Space.sm),
        child: Row(children: [
          SizedBox(width: 96, child: Text(title, style: context.text.bodyMedium)),
          Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, label: shown, onChanged: onChanged)),
          SizedBox(width: 56, child: Text(shown, textAlign: TextAlign.end, style: context.text.bodySmall)),
        ]),
      );

  static String _colorName(int argb) => switch (argb) {
        0xFFFFFFFF => 'white',
        0xFF000000 => 'black',
        0xFFFFFF00 => 'yellow',
        0xFF7D00FF => 'purple',
        0xFFFF3B30 => 'red',
        0xFFFF9500 => 'orange',
        0xFF34C759 => 'green',
        0xFF0A84FF => 'blue',
        0xFFFF2D55 => 'pink',
        _ => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
      };
}
