import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../media/caption_fonts.dart' show CaptionFont;
import '../../media/photo_pixels.dart';
import '../../media/text_card.dart';
import '../../media/text_card_background.dart';
import '../../platform/env.dart';
import '../../platform/media_library.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../state/settings.dart' show TextCardAlignment;
import '../../theme/tokens.dart';
import '../../widgets/color_swatch_field.dart';
import '../../widgets/layout.dart' show showToast;
import '../../widgets/media_thumb.dart';

/// Longest side a card's background photo is decoded at for the composer's
/// previews; the saved card uses [kBackdropMaxSide].
const int _previewMaxSide = 720;

/// The photo at a path decoded for a card preview, with its brightness.
final cardBackgroundImageProvider = FutureProvider.autoDispose.family<({ui.Image image, double luminance})?, String>((ref, path) async {
  final storage = ref.read(servicesProvider).storage;
  final px = await decodePhotoPixels(await storage.readMedia(path), maxSide: _previewMaxSide);
  if (px == null) return null;
  final image = await previewImageOf(px);
  ref.onDispose(image.dispose);
  return (image: image, luminance: px.luminance);
});

/// [background] ready to paint in a preview; null while its photo loads, or
/// for a plain colour.
TextCardBackdrop? previewBackdrop(WidgetRef ref, TextCardBackground? background) {
  if (background == null) return null;
  final decoded = ref.watch(cardBackgroundImageProvider(background.photo.path)).value;
  return decoded == null ? null : TextCardBackdrop(image: decoded.image, luminance: decoded.luminance, background: background);
}

/// How a card is drawn for one network, for the editor's preview.
@immutable
class CardLook {
  const CardLook({
    required this.platform,
    required this.text,
    required this.theme,
    required this.font,
    required this.branded,
    required this.alignment,
    this.byline,
    this.customFont,
  });
  final PlatformDescriptor platform;
  final String text;
  final TextCardTheme theme;

  /// Not yet resolved for the network.
  final TextCardFont font;
  final bool branded;
  final TextCardAlignment alignment;

  /// The @handle, null when it is left out.
  final String? byline;

  /// 1.3.1: cards. The installed or imported font drawn instead of [font].
  final CaptionFont? customFont;
}

/// Opens the card background editor: a plain colour, or a photo (one of the
/// post's or one picked for the card) with blur, dimming, text colour and a
/// box behind the words. Edits the composer's [ComposerState.textCardBackground]
/// as they are made.
Future<void> showCardBackgroundSheet(BuildContext context, CardLook look) {
  final sheet = CardBackgroundSheet(look: look);
  if (context.isCompact) {
    return showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => sheet);
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680, maxHeight: 860), child: sheet),
    ),
  );
}

class CardBackgroundSheet extends ConsumerStatefulWidget {
  const CardBackgroundSheet({super.key, required this.look});
  final CardLook look;

  @override
  ConsumerState<CardBackgroundSheet> createState() => _CardBackgroundSheetState();
}

class _CardBackgroundSheetState extends ConsumerState<CardBackgroundSheet> {
  /// The last photo chosen, kept while the background is a colour so going
  /// back to Photo restores it.
  TextCardBackground? _last;
  bool _picking = false;
  _Group _group = _Group.photo;

  @override
  void initState() {
    super.initState();
    _last = TextCardBackground.tryParse(ref.read(composerProvider).textCardBackground);
  }

  void _set(TextCardBackground? background) {
    if (background != null) _last = background;
    ref.read(composerProvider.notifier).setTextCardBackground(background?.toJson());
  }

  /// Changes the background as it is now in the composer, not as the last
  /// frame showed it, so quick edits in a row all count.
  void _edit(TextCardBackground Function(TextCardBackground b) change) {
    final now = TextCardBackground.tryParse(ref.read(composerProvider).textCardBackground);
    if (now != null) _set(change(now));
  }

  /// Picks a photo for the card only; it is not attached to the post.
  Future<void> _pick(TextCardBackground? current) async {
    final library = ref.read(servicesProvider).media;
    setState(() => _picking = true);
    try {
      MediaAttachment? picked;
      if (Env.isMobile) {
        final f = await ImagePicker().pickImage(source: ImageSource.gallery);
        if (f != null) picked = await library.importXFile(f);
      } else {
        final files = await FilePicker.pickFiles(
          dialogTitle: 'Choose a photo for the card',
          type: FileType.custom,
          allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
        );
        final f = files.firstOrNull;
        if (f != null) picked = await library.importBytes(await f.readAsBytes(), fileName: f.name);
      }
      if (picked == null) return;
      if (picked.kind != MediaKind.image) {
        await library.discard(picked);
        if (mounted) showToast(context, 'Choose a photo (JPEG, PNG or WebP)', icon: Icons.info_outline_rounded);
        return;
      }
      _set((current ?? _last)?.copyWith(photo: picked) ?? TextCardBackground(photo: picked));
    } on UnsupportedMediaException {
      if (mounted) showToast(context, 'Choose a photo (JPEG, PNG or WebP)', icon: Icons.info_outline_rounded);
    } on Object catch (e) {
      if (mounted) showToast(context, 'Could not open the picker: $e', icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final composer = ref.watch(composerProvider);
    final current = TextCardBackground.tryParse(composer.textCardBackground);
    final look = widget.look;
    final id = look.platform.id;
    final size = textCardSize(id);
    final photos = [
      for (final m in composer.media)
        if (m.kind == MediaKind.image) m,
    ];
    final picked = current ?? _last;
    // A photo picked for the card only, shown next to the post's own.
    final separate = picked != null && !photos.any((m) => m.id == picked.photo.id) ? picked.photo : null;

    Widget thumb(MediaAttachment m) {
      final selected = current?.photo.id == m.id;
      return Semantics(
        button: true,
        selected: selected,
        label: m.fileName ?? 'Photo',
        child: InkWell(
          onTap: () => _set((current ?? _last)?.copyWith(photo: m) ?? TextCardBackground(photo: m)),
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(borderRadius: Radii.rSm, border: Border.all(color: selected ? nf.accent : nf.border, width: selected ? 2 : 1)),
            child: MediaThumb(m, size: 64, showAltTag: false),
          ),
        ),
      );
    }

    final preview = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220, maxHeight: 360),
      child: ClipRRect(
        borderRadius: Radii.rMd,
        child: GestureDetector(
          key: const Key('card-background-preview'),
          // Dragging moves the photo with the finger: its focal point goes
          // the other way.
          onPanUpdate: current == null
              ? null
              : (d) {
                  // About one preview width (200 px) across the whole range.
                  final step = 2 / (200 * current.zoom);
                  double moved(double v, double by) => ((v - by * step).clamp(-1.0, 1.0) * 100).round() / 100;
                  _edit((b) => b.copyWith(offsetX: moved(b.offsetX, d.delta.dx), offsetY: moved(b.offsetY, d.delta.dy)));
                },
          child: TextCardView(
          text: look.text.isEmpty ? 'Your words, over your photo.' : look.text,
          theme: look.theme,
          font: look.font.resolve(id),
          aspect: size.width / size.height,
          byline: look.byline,
          branded: look.branded,
          safe: textCardSafeArea(id),
          alignment: look.alignment,
          backdrop: previewBackdrop(ref, current),
          customFont: look.customFont,
          ),
        ),
      ),
    );

    final controls = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, icon: Icon(Icons.format_color_fill_rounded, size: 18), label: Text('Colour')),
          ButtonSegment(value: true, icon: Icon(Icons.image_outlined, size: 18), label: Text('Photo')),
        ],
        selected: {current != null},
        onSelectionChanged: (s) {
          if (!s.first) {
            _set(null);
          } else if (_last != null) {
            _set(_last);
          } else if (photos.isNotEmpty) {
            _set(TextCardBackground(photo: photos.first));
          } else {
            _pick(null);
          }
        },
      ),
      if (current == null)
        Padding(
          padding: const EdgeInsets.only(top: Space.md),
          child: Text('The card is ${look.theme.label.toLowerCase()}. Choose Photo to set your words over a photo.', style: context.text.bodySmall),
        )
      else ...[
        const SizedBox(height: Space.md),
        SegmentedButton<_Group>(
          key: const Key('card-background-groups'),
          showSelectedIcon: false,
          segments: [for (final g in _Group.values) ButtonSegment(value: g, label: Text(g.label))],
          selected: {_group},
          onSelectionChanged: (s) => setState(() => _group = s.first),
        ),
        ...switch (_group) {
          _Group.photo => _photoControls(context, current, [for (final m in photos) thumb(m), if (separate != null) thumb(separate)]),
          _Group.adjust => _adjustControls(context, current),
          _Group.overlay => _overlayControls(context, current),
          _Group.words => _wordsControls(context, current),
        },
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: Space.md),
            child: TextButton.icon(
              key: const Key('card-background-reset'),
              onPressed: () => _edit((b) => b.withDefaultEffects()),
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Reset placement, adjustments and overlays'),
              style: TextButton.styleFrom(foregroundColor: nf.textMuted),
            ),
          ),
        ),
      ],
    ]);

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.lg, Space.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Card background', style: context.text.headlineSmall),
          const SizedBox(height: 2),
          Text('For every text card of this post.', style: context.text.bodySmall),
        ]),
      ),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Space.xxl, Space.sm, Space.xxl, Space.lg),
          child: LayoutBuilder(
            builder: (context, c) => c.maxWidth >= 520
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 200, child: preview),
                    const SizedBox(width: Space.xl),
                    Expanded(child: controls),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Center(child: preview), const SizedBox(height: Space.md), controls]),
          ),
        ),
      ),
      Divider(height: 1, color: nf.border),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.md, Space.xxl, Space.lg),
        child: Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))),
      ),
    ]);
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
        child: Text(text, style: context.text.titleSmall),
      );

  /// The photo, how it fills the card, zoom, focal point, turning and
  /// mirroring.
  List<Widget> _photoControls(BuildContext context, TextCardBackground current, List<Widget> thumbs) {
    final nf = context.nf;
    String percent(double v) => '${(v * 100).round()}';
    return [
      _label(context, 'Photo'),
      Wrap(spacing: Space.sm, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
        ...thumbs,
        OutlinedButton.icon(
          onPressed: _picking ? null : () => _pick(current),
          icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
          label: Text(_picking ? 'Opening…' : 'Pick a photo'),
        ),
      ]),
      const SizedBox(height: Space.xs),
      Text('The photo is only used inside the card. It is not posted by itself. Drag the preview to move it.',
          style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
      _label(context, 'Fit'),
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        for (final f in TextCardBackgroundFit.values)
          ChoiceChip(
            key: Key('card-background-fit-${f.name}'),
            label: Text(f.label),
            selected: current.fit == f,
            onSelected: (_) => _edit((b) => b.copyWith(fit: f)),
          ),
      ]),
      _slider(context, 'Zoom', current.zoom, 1, TextCardBackground.maxZoom, '${current.zoom.toStringAsFixed(1)}×',
          (v) => _edit((b) => b.copyWith(zoom: (v * 10).round() / 10)),
          key: const Key('card-background-zoom')),
      _slider(context, 'Across', current.offsetX, -1, 1, percent(current.offsetX), (v) => _edit((b) => b.copyWith(offsetX: (v * 100).round() / 100)),
          key: const Key('card-background-offset-x')),
      _slider(context, 'Down', current.offsetY, -1, 1, percent(current.offsetY), (v) => _edit((b) => b.copyWith(offsetY: (v * 100).round() / 100)),
          key: const Key('card-background-offset-y')),
      const SizedBox(height: Space.sm),
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        OutlinedButton.icon(
          key: const Key('card-background-rotate'),
          onPressed: () => _edit((b) => b.copyWith(quarterTurns: b.quarterTurns + 1)),
          icon: const Icon(Icons.rotate_90_degrees_cw_outlined, size: 18),
          label: Text(current.quarterTurns == 0 ? 'Turn' : 'Turned ${current.quarterTurns * 90}°'),
        ),
        FilterChip(
          key: const Key('card-background-flip'),
          avatar: const Icon(Icons.flip_rounded, size: 16),
          label: const Text('Mirror'),
          selected: current.flipHorizontal,
          onSelected: (v) => _edit((b) => b.copyWith(flipHorizontal: v)),
        ),
        if (current.offsetX != 0 || current.offsetY != 0 || current.zoom != 1)
          TextButton(
            onPressed: () => _edit((b) => b.copyWith(offsetX: 0, offsetY: 0, zoom: 1)),
            child: const Text('Centre'),
          ),
      ]),
    ];
  }

  /// Blur, dimming, brightness, contrast, saturation, black and white.
  List<Widget> _adjustControls(BuildContext context, TextCardBackground current) {
    String signed(double v) => '${v > 0 ? '+' : ''}${(v * 100).round()}';
    double hundredths(double v) => (v * 100).round() / 100;
    return [
      _label(context, 'Adjust'),
      _slider(context, 'Blur', current.blur, 0, TextCardBackground.maxBlur, current.blur.round().toString(),
          (v) => _edit((b) => b.copyWith(blur: v.roundToDouble())),
          key: const Key('card-background-blur')),
      _slider(context, 'Dimming', current.dimming, 0, TextCardBackground.maxDimming, '${(current.dimming * 100).round()}%',
          (v) => _edit((b) => b.copyWith(dimming: hundredths(v))),
          key: const Key('card-background-dimming')),
      _slider(context, 'Brightness', current.brightness, -1, 1, signed(current.brightness), (v) => _edit((b) => b.copyWith(brightness: hundredths(v))),
          key: const Key('card-background-brightness')),
      _slider(context, 'Contrast', current.contrast, -1, 1, signed(current.contrast), (v) => _edit((b) => b.copyWith(contrast: hundredths(v))),
          key: const Key('card-background-contrast')),
      if (!current.blackAndWhite)
        _slider(context, 'Saturation', current.saturation, -1, 1, signed(current.saturation), (v) => _edit((b) => b.copyWith(saturation: hundredths(v))),
            key: const Key('card-background-saturation')),
      SwitchListTile(
        key: const Key('card-background-black-and-white'),
        contentPadding: EdgeInsets.zero,
        title: Text('Black and white', style: context.text.bodyMedium),
        value: current.blackAndWhite,
        onChanged: (v) => _edit((b) => b.copyWith(blackAndWhite: v)),
      ),
    ];
  }

  /// A colour tint, a gradient and a vignette.
  List<Widget> _overlayControls(BuildContext context, TextCardBackground current) {
    String percent(double v) => '${(v * 100).round()}%';
    double hundredths(double v) => (v * 100).round() / 100;
    return [
      _label(context, 'Tint'),
      _colorChoice(current.tintColor, (c) => _edit((b) => b.copyWith(tintColor: c, tintStrength: b.tintStrength > 0 ? null : 0.4)), label: 'Tint'),
      _slider(context, 'Strength', current.tintStrength, 0, 1, percent(current.tintStrength), (v) => _edit((b) => b.copyWith(tintStrength: hundredths(v))),
          key: const Key('card-background-tint')),
      _label(context, 'Gradient'),
      _colorChoice(current.gradientStart, (c) => _edit((b) => b.copyWith(gradientStart: c, gradientStrength: b.gradientStrength > 0 ? null : 0.6)),
          label: 'Gradient start'),
      const SizedBox(height: Space.sm),
      _colorChoice(current.gradientEnd, (c) => _edit((b) => b.copyWith(gradientEnd: c, gradientStrength: b.gradientStrength > 0 ? null : 0.6)),
          label: 'Gradient end'),
      _slider(context, 'Angle', current.gradientAngle, 0, 360, '${current.gradientAngle.round()}°',
          (v) => _edit((b) => b.copyWith(gradientAngle: (v / 15).round() * 15.0)),
          key: const Key('card-background-gradient-angle')),
      _slider(context, 'Strength', current.gradientStrength, 0, 1, percent(current.gradientStrength),
          (v) => _edit((b) => b.copyWith(gradientStrength: hundredths(v))),
          key: const Key('card-background-gradient')),
      _label(context, 'Vignette'),
      _slider(context, 'Strength', current.vignette, 0, 1, percent(current.vignette), (v) => _edit((b) => b.copyWith(vignette: hundredths(v))),
          key: const Key('card-background-vignette')),
    ];
  }

  /// Where the words sit, their colour and the box behind them.
  List<Widget> _wordsControls(BuildContext context, TextCardBackground current) => [
        _label(context, 'Position'),
        Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
          for (final p in TextCardTextPosition.values)
            ChoiceChip(
              key: Key('card-background-position-${p.name}'),
              label: Text(p.label),
              selected: current.textPosition == p,
              onSelected: (_) => _edit((b) => b.copyWith(textPosition: p)),
            ),
        ]),
        _label(context, 'Text colour'),
        Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
          for (final c in TextCardTextColor.values)
            ChoiceChip(
              label: Text(c.label),
              selected: current.textColor == c,
              onSelected: (_) => _edit((b) => b.copyWith(textColor: c)),
            ),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Box behind the words', style: context.text.bodyMedium),
          subtitle: Text('Helps the words stand out on a busy photo.', style: context.text.bodySmall),
          value: current.textBox,
          onChanged: (v) => _edit((b) => b.copyWith(textBox: v)),
        ),
      ];

  /// The one place the editor picks a colour. To use the colour wheel
  /// (lib/widgets/color_wheel.dart) instead, change only this method.
  Widget _colorChoice(int value, ValueChanged<int> onChanged, {required String label}) =>
      ColorSwatchField(value: value, onChanged: onChanged, label: label);

  Widget _slider(BuildContext context, String title, double value, double min, double max, String shown, ValueChanged<double> onChanged, {Key? key}) =>
      Padding(
        padding: const EdgeInsets.only(top: Space.sm),
        child: Row(children: [
          SizedBox(width: 88, child: Text(title, style: context.text.bodyMedium)),
          Expanded(child: Slider(key: key, value: value.clamp(min, max), min: min, max: max, label: shown, onChanged: onChanged)),
          SizedBox(width: 48, child: Text(shown, textAlign: TextAlign.end, style: context.text.bodySmall)),
        ]),
      );
}

/// The groups of the background editor's photo controls.
enum _Group {
  photo('Photo'),
  adjust('Adjust'),
  overlay('Overlay'),
  words('Words');

  const _Group(this.label);
  final String label;
}
