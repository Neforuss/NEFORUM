import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../media/aligned_text.dart';
import '../../media/audio_plan.dart' show audioTrackTitle;
import '../../media/caption_fonts.dart';
import '../../media/card_design.dart';
import '../../media/card_templates.dart';
import '../../media/text_card.dart';
import '../../media/text_card_background.dart';
import '../../state/card_designs.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../state/settings.dart' show TextCardAlignment;
import '../../theme/tokens.dart';
import '../../widgets/color_swatch_field.dart';
import '../../widgets/layout.dart' show showToast;
import 'card_background_sheet.dart';
import 'card_design_view.dart';
import 'font_picker_sheet.dart';

/// Whose design the card designer edits.
enum CardDesignerScope {
  /// The post in the composer: its cards, as the edits are made.
  post,

  /// Settings: the design new posts start with.
  defaults,
}

/// Opens the card designer for [kind] cards: a live preview drawn by the
/// saved card's renderer, at a square, portrait, story (or, for audio,
/// landscape) size, with the design's controls in groups: Template,
/// Background, Cover, Waveform, Text and Layout. Undo and redo step through
/// the edits. With [CardDesignerScope.post] it edits the composer's post as
/// the edits are made; with [CardDesignerScope.defaults], Settings.
Future<void> showCardDesignerSheet(BuildContext context, {required CardKind kind, CardDesignerScope scope = CardDesignerScope.post}) {
  final sheet = CardDesignerSheet(kind: kind, scope: scope);
  if (context.isCompact) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.94, child: sheet),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 900), child: sheet),
    ),
  );
}

/// The designer's groups of controls.
enum _Group {
  template('Template', Icons.dashboard_customize_outlined),
  background('Background', Icons.format_color_fill_rounded),
  cover('Cover', Icons.album_outlined),
  waveform('Waveform', Icons.graphic_eq_rounded),
  text('Text', Icons.text_fields_rounded),
  layout('Layout', Icons.grid_view_rounded);

  const _Group(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The preview sizes the designer offers.
enum _Frame {
  square('Square', 'bluesky', Size(1080, 1080)),
  portrait('4:5', 'instagram', Size(1080, 1350)),
  story('9:16 story', 'tiktok', Size(1080, 1920)),
  landscape('16:9', 'youtube', Size(1920, 1080));

  const _Frame(this.label, this.platformId, this.size);
  final String label;
  final String platformId;
  final Size size;
}

/// A sample track for the Settings default's preview.
const AudioTags _sampleTags = AudioTags(title: 'Night Drive', artist: 'Your Name', album: 'First Light', year: 2026);
const MediaAttachment _sampleSound = MediaAttachment(id: 'sample', path: 'sample.mp3', mimeType: 'audio/mpeg', sizeBytes: 3141592, fileName: 'Night Drive.mp3');

class CardDesignerSheet extends ConsumerStatefulWidget {
  const CardDesignerSheet({super.key, required this.kind, required this.scope});
  final CardKind kind;
  final CardDesignerScope scope;

  @override
  ConsumerState<CardDesignerSheet> createState() => _CardDesignerSheetState();
}

class _CardDesignerSheetState extends ConsumerState<CardDesignerSheet> {
  /// Every state of the design, the current one at [_at]; null is the
  /// classic card.
  final List<CardDesign?> _history = [];
  int _at = 0;
  DateTime _lastEdit = DateTime(2000);
  _Group _group = _Group.template;
  late _Frame _frame;

  /// The block (index) the Text group edits; the element the Layout group
  /// moves: -2 the cover, -1 the waveform, else a block.
  int _block = 0;
  int _element = -2;

  CardKind get _kind => widget.kind;
  bool get _post => widget.scope == CardDesignerScope.post;
  CardDesign? get _design => _history[_at];

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    final c = ref.read(composerProvider);
    final CardDesign? start = !_post
        ? CardDesign.tryParse(_kind == CardKind.text ? settings.textCardDesign : settings.audioCardDesign)
        : (_kind == CardKind.text ? c.textDesign(settings) : c.audioDesign(settings));
    _history.add(start);
    _frame = _kind == CardKind.audio ? _Frame.square : _Frame.portrait;
    if (_post && _kind == CardKind.text) {
      final first = ref.read(composerPreviewsProvider).where((p) => isTextCardPlaceholder(p.variant.media.firstOrNull ?? _none)).firstOrNull;
      _frame = switch (first == null ? null : textCardSize(first.descriptor.id)) {
        Size(:final width, :final height) when height > width * 1.6 => _Frame.story,
        Size(:final width, :final height) when height > width => _Frame.portrait,
        Size() => _Frame.square,
        null => _Frame.portrait,
      };
    }
  }

  static const MediaAttachment _none = MediaAttachment(id: '', path: '', mimeType: '', sizeBytes: 0);

  /// Makes [next] the design, writing it where this designer edits. Edits in
  /// quick succession (a slider being dragged) are one undo step.
  void _apply(CardDesign? next) {
    final now = DateTime.now();
    final merge = now.difference(_lastEdit) < const Duration(milliseconds: 600) && _at > 0;
    _lastEdit = now;
    setState(() {
      _history.removeRange(_at + 1, _history.length);
      if (merge) {
        _history[_at] = next;
      } else {
        _history.add(next);
        _at = _history.length - 1;
      }
    });
    _write(next);
  }

  void _edit(CardDesign Function(CardDesign d) change) {
    final d = _design;
    if (d != null) _apply(change(d));
  }

  void _step(int by) {
    setState(() => _at = (_at + by).clamp(0, _history.length - 1));
    _lastEdit = DateTime(2000);
    _write(_design);
  }

  void _write(CardDesign? d) {
    if (_post) {
      final n = ref.read(composerProvider.notifier);
      _kind == CardKind.text ? n.setTextCardDesign(d) : n.setAudioCardDesign(d);
    } else {
      final json = d?.toJson() ?? const <String, dynamic>{};
      ref.read(settingsProvider.notifier).update((x) => _kind == CardKind.text ? x.copyWith(textCardDesign: json) : x.copyWith(audioCardDesign: json));
    }
  }

  // -------------------------------------------------------------------------
  // The preview
  // -------------------------------------------------------------------------

  CardPreviewRequest? _request(CardDesign design) {
    final settings = ref.watch(settingsProvider);
    final c = ref.watch(composerProvider);
    final frame = _frame;
    final safe = frame.size.width / frame.size.height < 0.62 ? fullScreenSafeArea(frame.platformId) : EdgeInsets.zero;
    if (_kind == CardKind.text) {
      final accounts = ref.watch(accountListProvider);
      final account = accounts.where((a) => c.selected.contains(a.id)).firstOrNull;
      final words = _post ? c.joinedParts.trim() : '';
      return CardPreviewRequest.text(
        design: design,
        platformId: frame.platformId,
        size: frame.size,
        safe: safe,
        text: words.isEmpty ? 'One app, one message, every platform.' : words,
        byline: account?.handle ?? account?.displayName ?? '@you',
        signed: settings.textCardBranded(frame.platformId),
        background: _post ? TextCardBackground.tryParse(c.textCardBackground) : null,
      );
    }
    final sound = _post ? c.audio : null;
    final tags = sound == null ? _sampleTags : (sound.audioTags ?? AudioTags.none);
    final photo = c.media.where((m) => m.kind == MediaKind.image && !m.generated).firstOrNull;
    return CardPreviewRequest.audio(
      design: design,
      platformId: frame.platformId,
      size: frame.size,
      safe: safe,
      texts: audioCardTexts(tags, fallbackTitle: sound == null ? 'Night Drive' : audioTrackTitle(sound, postTitle: c.title)),
      coverPath: tags.coverPath ?? (_post ? photo?.path : null),
      sound: sound ?? _sampleSound,
    );
  }

  Widget _preview(BuildContext context) {
    final nf = context.nf;
    final design = _design;
    final Widget card;
    if (design == null) {
      card = AspectRatio(
        aspectRatio: _frame.size.width / _frame.size.height,
        child: Container(
          decoration: BoxDecoration(color: nf.surfaceSunken, borderRadius: Radii.rMd),
          padding: const EdgeInsets.all(Space.lg),
          alignment: Alignment.center,
          child: Text(
            _kind == CardKind.text
                ? 'The classic NEFORUM card. Pick a template to design your own.'
                : 'The classic audio card. Pick a template to design your own.',
            textAlign: TextAlign.center,
            style: context.text.bodySmall,
          ),
        ),
      );
    } else {
      card = ClipRRect(
        borderRadius: Radii.rMd,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(borderRadius: Radii.rMd, border: Border.all(color: nf.border)),
          child: CardDesignView(key: const Key('card-designer-preview'), request: _request(design)!),
        ),
      );
    }
    final frames = [_Frame.square, _Frame.portrait, _Frame.story, if (_kind == CardKind.audio) _Frame.landscape];
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ConstrainedBox(constraints: const BoxConstraints(maxHeight: 420), child: Center(child: card)),
      const SizedBox(height: Space.sm),
      Wrap(alignment: WrapAlignment.center, spacing: Space.xs, runSpacing: Space.xs, children: [
        for (final f in frames)
          ChoiceChip(
            key: Key('card-designer-frame-${f.name}'),
            label: Text(f.label),
            selected: _frame == f,
            onSelected: (_) => setState(() => _frame = f),
          ),
      ]),
      const SizedBox(height: Space.xs),
      Text('Drawn exactly as it is saved. Each network gets it at its own size.',
          textAlign: TextAlign.center, style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
    ]);
  }

  // -------------------------------------------------------------------------
  // Controls
  // -------------------------------------------------------------------------

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
        child: Text(text, style: context.text.titleSmall),
      );

  Widget _slider(BuildContext context, String title, double value, double min, double max, String shown, ValueChanged<double> onChanged, {Key? key}) =>
      Padding(
        padding: const EdgeInsets.only(top: Space.xs),
        child: Row(children: [
          SizedBox(width: 104, child: Text(title, style: context.text.bodyMedium)),
          Expanded(child: Slider(key: key, value: value.clamp(min, max), min: min, max: max, label: shown, onChanged: onChanged)),
          SizedBox(width: 52, child: Text(shown, textAlign: TextAlign.end, style: context.text.bodySmall)),
        ]),
      );

  Widget _switch(BuildContext context, String title, bool value, ValueChanged<bool> onChanged, {Key? key, String? subtitle}) => SwitchListTile(
        key: key,
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(title, style: context.text.bodyMedium),
        subtitle: subtitle == null ? null : Text(subtitle, style: context.text.bodySmall),
        value: value,
        onChanged: onChanged,
      );

  /// Every colour in the designer: swatches, the colour wheel and hex.
  Widget _color(String label, int argb, ValueChanged<int> onChanged) => Padding(
        padding: const EdgeInsets.only(top: Space.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(width: 104, child: Text(label, style: context.text.bodyMedium)),
          Expanded(child: ColorSwatchField(value: argb, onChanged: (c) => onChanged(c | (argb & 0xFF000000 == 0 ? 0xFF000000 : argb & 0xFF000000)), label: label)),
        ]),
      );

  /// A see-through colour: the colour, and how opaque it is.
  List<Widget> _colorWithOpacity(BuildContext context, String label, int argb, ValueChanged<int> onChanged) => [
        _color(label, argb | 0xFF000000, (c) => onChanged((argb & 0xFF000000) | (c & 0xFFFFFF))),
        _slider(context, 'Opacity', (argb >>> 24) / 255, 0, 1, '${((argb >>> 24) / 255 * 100).round()}%',
            (v) => onChanged(((v * 255).round() << 24) | (argb & 0xFFFFFF))),
      ];

  Widget _chips<T>(List<T> values, T selected, String Function(T v) label, ValueChanged<T> onSelected, {String keyPrefix = ''}) =>
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        for (final v in values)
          ChoiceChip(
            key: keyPrefix.isEmpty ? null : Key('$keyPrefix-${v is Enum ? v.name : v}'),
            label: Text(label(v)),
            selected: v == selected,
            onSelected: (_) => onSelected(v),
          ),
      ]);

  String _px(double v) => v.round().toString();
  String _pct(double v) => '${(v * 100).round()}%';
  double _r(double v, [int places = 2]) {
    final f = places == 0 ? 1 : (places == 1 ? 10 : 100);
    return (v * f).round() / f;
  }

  Widget _needsDesign(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('The classic card has no layers to edit.', style: context.text.bodyMedium),
          const SizedBox(height: Space.sm),
          OutlinedButton.icon(
            key: const Key('card-designer-start'),
            onPressed: () {
              _apply(kCardTemplates.first.design(_kind));
              setState(() => _group = _Group.background);
            },
            icon: const Icon(Icons.auto_awesome_outlined, size: 18),
            label: Text('Start from ${kCardTemplates.first.name}'),
          ),
        ]),
      );

  List<Widget> _templateControls(BuildContext context) {
    final nf = context.nf;
    final presets = [
      for (final raw in ref.watch(settingsProvider).cardPresets)
        if (CardPreset.tryParse(raw) case final p? when p.design.kind == _kind) p,
    ];
    Widget tile({required Key key, required String name, required String description, required bool selected, required VoidCallback onTap, CardDesign? design}) {
      final request = design == null ? null : _request(design);
      return Semantics(
        button: true,
        selected: selected,
        label: name,
        child: InkWell(
          key: key,
          borderRadius: Radii.rMd,
          onTap: onTap,
          child: Container(
            width: 132,
            padding: const EdgeInsets.all(Space.xs),
            decoration: BoxDecoration(borderRadius: Radii.rMd, border: Border.all(color: selected ? nf.accent : nf.border, width: selected ? 2 : 1)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              ClipRRect(
                borderRadius: Radii.rSm,
                child: request == null
                    ? AspectRatio(
                        aspectRatio: 4 / 5,
                        child: ColoredBox(
                          color: const Color(0xFF000000),
                          child: Center(child: Text('NEFORUM', style: TextStyle(fontFamily: Fonts.display, fontWeight: FontWeight.w800, fontSize: 13, color: Brand.yellow))),
                        ),
                      )
                    : CardDesignView(
                        // A small copy, quick to draw: thumbnails only show the look.
                        request: _thumbnail(request),
                        delay: Duration.zero,
                      ),
              ),
              const SizedBox(height: Space.xs),
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelMedium),
              Text(description, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.textFaint, fontSize: 11)),
            ]),
          ),
        ),
      );
    }

    final current = _design;
    return [
      _label(context, 'Templates'),
      Text('Start from one, then change anything.', style: context.text.bodySmall),
      const SizedBox(height: Space.sm),
      Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
        tile(
          key: const Key('card-template-classic'),
          name: 'Classic',
          description: _kind == CardKind.text ? 'The NEFORUM card' : 'The NEFORUM audio card',
          selected: current == null,
          onTap: () => _apply(null),
        ),
        for (final t in kCardTemplates)
          tile(
            key: Key('card-template-${t.id}'),
            name: t.name,
            description: t.description,
            selected: current?.template == t.id,
            onTap: () => _apply(t.design(_kind)),
            design: t.design(_kind),
          ),
      ]),
      _label(context, 'Your presets'),
      if (presets.isEmpty) Text('Save a design you like to use it again.', style: context.text.bodySmall),
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        for (final p in presets)
          InputChip(
            key: Key('card-preset-${p.name}'),
            label: Text(p.name),
            onPressed: () => _apply(p.design),
            onDeleted: () => ref.read(settingsProvider.notifier).update((x) => x.copyWith(cardPresets: [
                  for (final raw in x.cardPresets)
                    if (CardPreset.tryParse(raw) case final q? when !(q.name == p.name && q.design.kind == _kind)) raw,
                ])),
          ),
      ]),
      const SizedBox(height: Space.sm),
      OutlinedButton.icon(
        key: const Key('card-preset-save'),
        onPressed: current == null ? null : () => _savePreset(current),
        icon: const Icon(Icons.bookmark_add_outlined, size: 18),
        label: const Text('Save as preset…'),
      ),
    ];
  }

  /// [r] drawn at a fifth of its size for a template's thumbnail.
  CardPreviewRequest _thumbnail(CardPreviewRequest r) {
    final small = Size((r.size.width / 4).roundToDouble(), (r.size.height / 4).roundToDouble());
    return r.texts == null
        ? CardPreviewRequest.text(
            design: r.design, platformId: r.platformId, size: small, safe: r.safe, text: r.text ?? '', byline: r.byline, signed: r.signed, background: r.background)
        : CardPreviewRequest.audio(design: r.design, platformId: r.platformId, size: small, safe: r.safe, texts: r.texts!, coverPath: r.coverPath, sound: r.sound);
  }

  Future<void> _savePreset(CardDesign design) async {
    final saved = await showDialog<String>(context: context, builder: (_) => _PresetNameDialog(initial: cardTemplateById(design.template)?.name ?? ''));
    final label = saved?.trim() ?? '';
    if (label.isEmpty) return;
    ref.read(settingsProvider.notifier).update((x) => x.copyWith(cardPresets: [
          for (final raw in x.cardPresets)
            if (CardPreset.tryParse(raw) case final q? when !(q.name == label && q.design.kind == _kind)) raw,
          CardPreset(name: label, design: design).toJson(),
        ]));
    if (mounted) showToast(context, 'Saved “$label”', icon: Icons.bookmark_added_outlined);
  }

  List<Widget> _backgroundControls(BuildContext context, CardDesign d) {
    final b = d.background;
    void set(CardBackground Function(CardBackground b) change) => _edit((x) => x.copyWith(background: change(x.background)));
    return [
      _label(context, 'Fill'),
      _chips(CardFillKind.values, b.kind, (k) => k.label, (k) => set((x) => x.copyWith(kind: k)), keyPrefix: 'card-fill'),
      if (b.kind == CardFillKind.solid) _color('Colour', b.color, (c) => set((x) => x.copyWith(color: c))),
      if (b.kind == CardFillKind.linear || b.kind == CardFillKind.radial) ...[
        for (var i = 0; i < b.colors.length; i++)
          _color('Colour ${i + 1}', b.colors[i], (c) => set((x) => x.copyWith(colors: [for (var k = 0; k < x.colors.length; k++) k == i ? c : x.colors[k]]))),
        _switch(context, 'Three colours', b.colors.length == 3,
            (on) => set((x) => x.copyWith(colors: on ? [x.colors[0], x.colors[1], x.colors.length > 2 ? x.colors[2] : 0xFF000000] : x.colors.take(2).toList())),
            key: const Key('card-gradient-three')),
        if (b.kind == CardFillKind.linear)
          _slider(context, 'Angle', b.angle, 0, 360, '${b.angle.round()}°', (v) => set((x) => x.copyWith(angle: (v / 5).round() * 5.0)),
              key: const Key('card-gradient-angle')),
        if (b.kind == CardFillKind.radial) ...[
          _slider(context, 'Centre across', b.centerX, 0, 1, _pct(b.centerX), (v) => set((x) => x.copyWith(centerX: _r(v)))),
          _slider(context, 'Centre down', b.centerY, 0, 1, _pct(b.centerY), (v) => set((x) => x.copyWith(centerY: _r(v)))),
          _slider(context, 'Radius', b.radius, 0.2, 2, _pct(b.radius), (v) => set((x) => x.copyWith(radius: _r(v)))),
        ],
      ],
      if (b.kind == CardFillKind.image) ...[
        if (_kind == CardKind.text) ...[
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text(
                _post
                    ? 'The card\'s background photo, with its placement, colours, blur, dimming, tint and gradient.'
                    : 'Each post\'s card background photo. Without one, the card is the colour below.',
                style: context.text.bodySmall),
          ),
          if (_post)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: OutlinedButton.icon(
                key: const Key('card-designer-photo'),
                onPressed: _openPhotoEditor,
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('Choose and adjust the photo…'),
              ),
            ),
        ] else ...[
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text('The track\'s cover art, or the post\'s photo. Without either, the card is the colour below.', style: context.text.bodySmall),
          ),
          _slider(context, 'Blur', b.photoBlur, 0, 30, _px(b.photoBlur), (v) => set((x) => x.copyWith(photoBlur: v.roundToDouble()))),
          _slider(context, 'Dimming', b.photoDimming, 0, 0.8, _pct(b.photoDimming), (v) => set((x) => x.copyWith(photoDimming: _r(v)))),
          _slider(context, 'Zoom', b.photoZoom, 1, 4, '${b.photoZoom.toStringAsFixed(1)}×', (v) => set((x) => x.copyWith(photoZoom: _r(v, 1)))),
          _slider(context, 'Across', b.photoOffsetX, -1, 1, _pct(b.photoOffsetX), (v) => set((x) => x.copyWith(photoOffsetX: _r(v)))),
          _slider(context, 'Down', b.photoOffsetY, -1, 1, _pct(b.photoOffsetY), (v) => set((x) => x.copyWith(photoOffsetY: _r(v)))),
        ],
        _color('Colour', b.color, (c) => set((x) => x.copyWith(color: c))),
      ],
      _label(context, 'Pattern'),
      _chips(CardPattern.values, b.pattern, (p) => p.label, (p) => set((x) => x.copyWith(pattern: p)), keyPrefix: 'card-pattern'),
      if (b.pattern != CardPattern.none) ...[
        ..._colorWithOpacity(context, 'Pattern', b.patternColor, (c) => set((x) => x.copyWith(patternColor: c))),
        _slider(context, 'Spacing', b.patternScale, 8, 240, _px(b.patternScale), (v) => set((x) => x.copyWith(patternScale: v.roundToDouble()))),
        _slider(context, b.pattern == CardPattern.dots ? 'Dot size' : 'Thickness', b.patternThickness, 1, 80, _px(b.patternThickness),
            (v) => set((x) => x.copyWith(patternThickness: v.roundToDouble()))),
        if (b.pattern == CardPattern.stripes)
          _slider(context, 'Angle', b.patternAngle, 0, 180, '${b.patternAngle.round()}°', (v) => set((x) => x.copyWith(patternAngle: (v / 5).round() * 5.0))),
      ],
      _label(context, 'Finish'),
      _slider(context, 'Grain', b.grain, 0, 1, _pct(b.grain), (v) => set((x) => x.copyWith(grain: _r(v))), key: const Key('card-grain')),
      _slider(context, 'Vignette', b.vignette, 0, 1, _pct(b.vignette), (v) => set((x) => x.copyWith(vignette: _r(v))), key: const Key('card-vignette')),
    ];
  }

  void _openPhotoEditor() {
    final c = ref.read(composerProvider);
    final settings = ref.read(settingsProvider);
    final platform = ref.read(registryProvider).descriptor(_frame.platformId) ?? ref.read(registryProvider).descriptor('instagram');
    if (platform == null) return;
    showCardBackgroundSheet(
      context,
      CardLook(
        platform: platform,
        text: c.joinedParts,
        theme: c.textCardTheme ?? settings.textCardTheme,
        font: c.textCardFont ?? settings.textCardFont,
        branded: settings.textCardBranded(platform.id),
        alignment: c.textCardAlignment ?? settings.textCardAlignment,
        customFont: c.cardCustomFont(settings),
      ),
    );
  }

  List<Widget> _coverControls(BuildContext context, CardDesign d) {
    final c = d.cover;
    void set(CardCoverLayer Function(CardCoverLayer c) change) => _edit((x) => x.copyWith(cover: change(x.cover)));
    return [
      _switch(context, _kind == CardKind.text ? 'Show the photo as a framed picture' : 'Show the cover art', c.visible, (v) => set((x) => x.copyWith(visible: v)),
          key: const Key('card-cover-visible'),
          subtitle: _kind == CardKind.text
              ? 'The card\'s background photo, framed. A record shows even without one.'
              : 'The track\'s cover art, else the post\'s photo. A record shows even without one.'),
      if (c.visible) ...[
        _label(context, 'Shape'),
        _chips(CardCoverShape.values, c.shape, (s) => s.label, (s) => set((x) => x.copyWith(shape: s)), keyPrefix: 'card-cover-shape'),
        _slider(context, 'Size', c.size, 0.1, 1, _pct(c.size), (v) => set((x) => x.copyWith(size: _r(v))), key: const Key('card-cover-size')),
        if (c.shape == CardCoverShape.rounded)
          _slider(context, 'Corners', c.cornerRadius, 0, 0.5, _pct(c.cornerRadius), (v) => set((x) => x.copyWith(cornerRadius: _r(v)))),
        _slider(context, 'Rotation', c.rotation, -180, 180, '${c.rotation.round()}°', (v) => set((x) => x.copyWith(rotation: v.roundToDouble())),
            key: const Key('card-cover-rotation')),
        _label(context, 'Border'),
        _slider(context, 'Width', c.borderWidth, 0, 80, _px(c.borderWidth), (v) => set((x) => x.copyWith(borderWidth: v.roundToDouble()))),
        if (c.borderWidth > 0) _color('Colour', c.borderColor, (v) => set((x) => x.copyWith(borderColor: v))),
        _label(context, 'Shadow'),
        _slider(context, 'Strength', c.shadow, 0, 1, _pct(c.shadow), (v) => set((x) => x.copyWith(shadow: _r(v)))),
        _slider(context, 'Softness', c.shadowBlur, 0, 120, _px(c.shadowBlur), (v) => set((x) => x.copyWith(shadowBlur: v.roundToDouble()))),
        _slider(context, 'Drop', c.shadowOffsetY, -120, 120, _px(c.shadowOffsetY), (v) => set((x) => x.copyWith(shadowOffsetY: v.roundToDouble()))),
        const SizedBox(height: Space.sm),
        Text('Move it in Layout.', style: context.text.bodySmall),
      ],
    ];
  }

  List<Widget> _waveformControls(BuildContext context, CardDesign d) {
    final w = d.waveform;
    void set(CardWaveformLayer Function(CardWaveformLayer w) change) => _edit((x) => x.copyWith(waveform: change(x.waveform)));
    final sound = _post ? ref.watch(composerProvider).audio : null;
    final measured = sound != null && measuresWaveformOf(sound.mimeType);
    return [
      _switch(context, 'Show the waveform', w.visible, (v) => set((x) => x.copyWith(visible: v)),
          key: const Key('card-waveform-visible'),
          subtitle: _kind == CardKind.text
              ? 'A decorative wave, shaped by your words.'
              : sound == null
                  ? 'Measured from WAV and AIFF files; a decorative wave for other formats.'
                  : measured
                      ? 'Measured from ${sound.fileName ?? 'the sound file'}.'
                      : 'Decorative: NEFORUM measures WAV and AIFF files, and draws a wave shaped by this file for other formats.'),
      if (w.visible) ...[
        _label(context, 'Style'),
        _chips(CardWaveformStyle.values, w.style, (s) => s.label, (s) => set((x) => x.copyWith(style: s)), keyPrefix: 'card-waveform-style'),
        ..._colorWithOpacity(context, 'Colour', (w.color & 0xFFFFFF) | ((w.opacity * 255).round() << 24),
            (c) => set((x) => x.copyWith(color: c | 0xFF000000, opacity: _r((c >>> 24) / 255)))),
        _slider(context, 'Thickness', w.thickness, 1, 60, _px(w.thickness), (v) => set((x) => x.copyWith(thickness: v.roundToDouble()))),
        _slider(context, 'Bars', w.bars.toDouble(), 8, 256, '${w.bars}', (v) => set((x) => x.copyWith(bars: v.round())), key: const Key('card-waveform-bars')),
        _slider(context, 'Height', w.height, 0.03, 0.8, _pct(w.height), (v) => set((x) => x.copyWith(height: _r(v)))),
        _slider(context, 'Width', w.width, 0.1, 1, _pct(w.width), (v) => set((x) => x.copyWith(width: _r(v)))),
        const SizedBox(height: Space.sm),
        Text('Move it in Layout.', style: context.text.bodySmall),
      ],
    ];
  }

  String _blockName(CardDesign d, int i) {
    final b = d.blocks[i];
    final same = d.blocks.where((x) => x.role == b.role).length;
    if (b.role == CardBlockRole.custom && b.text.trim().isNotEmpty) {
      final t = b.text.trim();
      return t.length > 16 ? '${t.substring(0, 15)}…' : t;
    }
    return same > 1 ? '${b.role.label} ${d.blocks.take(i + 1).where((x) => x.role == b.role).length}' : b.role.label;
  }

  List<Widget> _textControls(BuildContext context, CardDesign d) {
    final nf = context.nf;
    final index = d.blocks.isEmpty ? -1 : _block.clamp(0, d.blocks.length - 1);
    void set(CardTextBlock Function(CardTextBlock b) change) => _edit((x) => x.withBlock(index, change));
    final chips = Wrap(spacing: Space.xs, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (var i = 0; i < d.blocks.length; i++)
        ChoiceChip(
          key: Key('card-block-$i'),
          label: Text(_blockName(d, i)),
          avatar: d.blocks[i].visible ? null : Icon(Icons.visibility_off_outlined, size: 14, color: nf.textFaint),
          selected: i == index,
          onSelected: (_) => setState(() => _block = i),
        ),
      PopupMenuButton<CardBlockRole>(
        key: const Key('card-block-add'),
        tooltip: 'Add a text block',
        onSelected: (role) {
          final last = d.blocks.isEmpty ? null : d.blocks.last;
          _apply(d.copyWith(blocks: [
            ...d.blocks,
            CardTextBlock(
              role: role,
              text: role == CardBlockRole.custom ? 'Your words' : '',
              anchor: last?.anchor ?? CardAnchor.bottomLeft,
              color: last?.color ?? 0xFFFFFFFF,
              size: role == CardBlockRole.postText ? 80 : 40,
              autoFit: role == CardBlockRole.postText,
            ),
          ]));
          setState(() => _block = d.blocks.length);
        },
        itemBuilder: (_) => [for (final r in CardBlockRole.of(_kind)) PopupMenuItem(value: r, child: Text(r.label))],
        child: Padding(
          padding: const EdgeInsets.all(Space.xs),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add_rounded, size: 18, color: nf.accent),
            const SizedBox(width: 2),
            Text('Add', style: context.text.labelMedium?.copyWith(color: nf.accent)),
          ]),
        ),
      ),
    ]);
    if (index < 0) return [_label(context, 'Text blocks'), chips];
    final b = d.blocks[index];
    final weights = [for (var w = 100; w <= 900; w += 100) w];
    return [
      _label(context, 'Text blocks'),
      chips,
      _switch(context, 'Show this block', b.visible, (v) => set((x) => x.copyWith(visible: v)), key: const Key('card-block-visible')),
      if (b.role == CardBlockRole.custom)
        Padding(
          padding: const EdgeInsets.only(top: Space.xs),
          child: TextFormField(
            key: Key('card-block-text-$index'),
            initialValue: b.text,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Words', isDense: true),
            onChanged: (v) => set((x) => x.copyWith(text: v)),
          ),
        ),
      _label(context, 'Font'),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('card-block-font'),
            onPressed: () async {
              final choice = await showFontChoiceSheet(context,
                  current: FontChoice(b.font, b.customFont), platformId: _frame.platformId, title: '${b.role.label} font');
              if (choice == null) return;
              final custom = choice.customFont;
              set((x) => custom == null ? x.copyWith(font: choice.font, clearCustomFont: true) : x.copyWith(customFont: custom));
            },
            icon: const Icon(Icons.font_download_outlined, size: 18),
            label: Text(b.customFont?.family ?? b.font.label, overflow: TextOverflow.ellipsis),
          ),
        ),
      ]),
      if (b.customFont != null && ref.watch(captionFontReadyProvider(b.customFont)).value == false)
        Padding(
          padding: const EdgeInsets.only(top: Space.xs),
          child: Text('${b.customFont!.family} is not on this device, so ${b.font.label} is drawn instead.',
              style: context.text.bodySmall?.copyWith(color: nf.warning)),
        ),
      _slider(context, 'Size', b.size, 12, 320, _px(b.size), (v) => set((x) => x.copyWith(size: v.roundToDouble())), key: const Key('card-block-size')),
      _switch(context, 'Shrink to fit', b.autoFit, (v) => set((x) => x.copyWith(autoFit: v)),
          key: const Key('card-block-autofit'), subtitle: 'Long words get smaller instead of being cut.'),
      _slider(context, 'Weight', b.weight.toDouble(), 100, 900, '${b.weight}', (v) => set((x) => x.copyWith(weight: weights.reduce((a, c) => (c - v).abs() < (a - v).abs() ? c : a))),
          key: const Key('card-block-weight')),
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        FilterChip(key: const Key('card-block-italic'), label: const Text('Italic'), selected: b.italic, onSelected: (v) => set((x) => x.copyWith(italic: v))),
        FilterChip(
            key: const Key('card-block-uppercase'), label: const Text('Capitals'), selected: b.uppercase, onSelected: (v) => set((x) => x.copyWith(uppercase: v))),
      ]),
      _slider(context, 'Letter spacing', b.letterSpacing, -0.1, 0.5, (b.letterSpacing * 100).round().toString(),
          (v) => set((x) => x.copyWith(letterSpacing: _r(v)))),
      _slider(context, 'Line height', b.lineHeight, 0.8, 2.5, b.lineHeight.toStringAsFixed(2), (v) => set((x) => x.copyWith(lineHeight: _r(v)))),
      _label(context, 'Alignment'),
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        for (final a in TextCardAlignment.values)
          Tooltip(
            message: a.description,
            child: ChoiceChip(
              key: Key('card-block-alignment-${a.name}'),
              avatar: Icon(a.icon, size: 16),
              label: Text(a.label),
              selected: b.alignment == a,
              onSelected: (_) => set((x) => x.copyWith(alignment: a)),
            ),
          ),
      ]),
      _label(context, 'Colour'),
      ..._colorWithOpacity(context, 'Words', b.color, (c) => set((x) => x.copyWith(color: c))),
      _label(context, 'Outline'),
      _slider(context, 'Width', b.outlineWidth, 0, 24, _px(b.outlineWidth), (v) => set((x) => x.copyWith(outlineWidth: v.roundToDouble())),
          key: const Key('card-block-outline')),
      if (b.outlineWidth > 0) _color('Colour', b.outlineColor, (c) => set((x) => x.copyWith(outlineColor: c))),
      _label(context, 'Shadow'),
      _slider(context, 'Softness', b.shadowBlur, 0, 60, _px(b.shadowBlur), (v) => set((x) => x.copyWith(shadowBlur: v.roundToDouble())),
          key: const Key('card-block-shadow')),
      _slider(context, 'Drop', b.shadowOffsetY, -40, 40, _px(b.shadowOffsetY), (v) => set((x) => x.copyWith(shadowOffsetY: v.roundToDouble()))),
      if (b.shadowBlur > 0 || b.shadowOffsetY != 0) ..._colorWithOpacity(context, 'Shadow', b.shadowColor, (c) => set((x) => x.copyWith(shadowColor: c))),
      _label(context, 'Room'),
      _slider(context, 'Most lines', b.maxLines.toDouble(), 0, 20, b.maxLines == 0 ? 'Any' : '${b.maxLines}', (v) => set((x) => x.copyWith(maxLines: v.round()))),
      _slider(context, 'Most height', b.maxHeight, 0.05, 1, _pct(b.maxHeight), (v) => set((x) => x.copyWith(maxHeight: _r(v)))),
      _slider(context, 'Gap above', b.gapBefore, 0, 200, _px(b.gapBefore), (v) => set((x) => x.copyWith(gapBefore: v.roundToDouble()))),
      const SizedBox(height: Space.sm),
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        OutlinedButton.icon(
          onPressed: index == 0
              ? null
              : () {
                  final blocks = [...d.blocks]..insert(index - 1, d.blocks[index]);
                  blocks.removeAt(index + 1);
                  _apply(d.copyWith(blocks: blocks));
                  setState(() => _block = index - 1);
                },
          icon: const Icon(Icons.arrow_upward_rounded, size: 18),
          label: const Text('Earlier'),
        ),
        OutlinedButton.icon(
          onPressed: index >= d.blocks.length - 1
              ? null
              : () {
                  final blocks = [...d.blocks]..removeAt(index);
                  blocks.insert(index + 1, d.blocks[index]);
                  _apply(d.copyWith(blocks: blocks));
                  setState(() => _block = index + 1);
                },
          icon: const Icon(Icons.arrow_downward_rounded, size: 18),
          label: const Text('Later'),
        ),
        TextButton.icon(
          key: const Key('card-block-remove'),
          onPressed: () {
            _apply(d.copyWith(blocks: [...d.blocks]..removeAt(index)));
            setState(() => _block = (index - 1).clamp(0, 999));
          },
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
          label: const Text('Remove'),
          style: TextButton.styleFrom(foregroundColor: nf.danger),
        ),
      ]),
    ];
  }

  Widget _anchorGrid(BuildContext context, CardAnchor value, ValueChanged<CardAnchor> onChanged) {
    final nf = context.nf;
    return SizedBox(
      width: 3 * 40 + 2 * Space.xs,
      child: Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
        for (final a in CardAnchor.values)
          Tooltip(
            message: a.label,
            child: InkWell(
              key: Key('card-anchor-${a.name}'),
              borderRadius: Radii.rXs,
              onTap: () => onChanged(a),
              child: Container(
                width: 40,
                height: 32,
                decoration: BoxDecoration(
                  color: a == value ? nf.accentSoft : null,
                  borderRadius: Radii.rXs,
                  border: Border.all(color: a == value ? nf.accent : nf.border),
                ),
                alignment: Alignment(a.x * 2 - 1, a.y * 2 - 1) * 0.6,
                child: Container(width: 8, height: 8, decoration: BoxDecoration(color: a == value ? nf.accent : nf.textFaint, shape: Radii.circleShape)),
              ),
            ),
          ),
      ]),
    );
  }

  List<Widget> _layoutControls(BuildContext context, CardDesign d) {
    final elements = <int, String>{
      if (d.cover.visible) -2: _kind == CardKind.text ? 'Photo' : 'Cover',
      if (d.waveform.visible) -1: 'Waveform',
      for (var i = 0; i < d.blocks.length; i++) i: _blockName(d, i),
    };
    final element = elements.containsKey(_element) ? _element : (elements.keys.firstOrNull ?? -3);
    late final CardAnchor anchor;
    late final double offsetX, offsetY;
    double? width;
    late final void Function({CardAnchor? anchor, double? offsetX, double? offsetY, double? width}) set;
    if (element == -2) {
      (anchor, offsetX, offsetY) = (d.cover.anchor, d.cover.offsetX, d.cover.offsetY);
      set = ({anchor, offsetX, offsetY, width}) => _edit((x) => x.copyWith(cover: x.cover.copyWith(anchor: anchor, offsetX: offsetX, offsetY: offsetY)));
    } else if (element == -1) {
      (anchor, offsetX, offsetY, width) = (d.waveform.anchor, d.waveform.offsetX, d.waveform.offsetY, d.waveform.width);
      set = ({anchor, offsetX, offsetY, width}) =>
          _edit((x) => x.copyWith(waveform: x.waveform.copyWith(anchor: anchor, offsetX: offsetX, offsetY: offsetY, width: width)));
    } else if (element >= 0) {
      final b = d.blocks[element];
      (anchor, offsetX, offsetY, width) = (b.anchor, b.offsetX, b.offsetY, b.width);
      set = ({anchor, offsetX, offsetY, width}) =>
          _edit((x) => x.withBlock(element, (b) => b.copyWith(anchor: anchor, offsetX: offsetX, offsetY: offsetY, width: width)));
    }
    return [
      _label(context, 'Margin'),
      _slider(context, 'Margin', d.margin, 0, 240, _px(d.margin), (v) => _edit((x) => x.copyWith(margin: v.roundToDouble())), key: const Key('card-margin')),
      Text('Room around everything. Full-screen stories also keep clear of the network\'s buttons.', style: context.text.bodySmall),
      if (element >= -2) ...[
        _label(context, 'Place'),
        _chips(elements.keys.toList(), element, (k) => elements[k]!, (k) => setState(() => _element = k), keyPrefix: 'card-layout-element'),
        const SizedBox(height: Space.md),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _anchorGrid(context, anchor, (a) => set(anchor: a)),
          const SizedBox(width: Space.lg),
          Expanded(
            child: Text(
              element >= 0 ? 'Blocks at the same spot stack in their order. Change it in Text.' : 'Where it sits in the card.',
              style: context.text.bodySmall,
            ),
          ),
        ]),
        _slider(context, 'Across', offsetX, -1, 1, _pct(offsetX), (v) => set(offsetX: _r(v)), key: const Key('card-layout-x')),
        _slider(context, 'Down', offsetY, -1, 1, _pct(offsetY), (v) => set(offsetY: _r(v)), key: const Key('card-layout-y')),
        if (width != null) _slider(context, 'Width', width, element >= 0 ? 0.2 : 0.1, 1, _pct(width), (v) => set(width: _r(v))),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final d = _design;
    final groups = [for (final g in _Group.values) g];
    final chips = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final g in groups)
            Padding(
              padding: const EdgeInsets.only(right: Space.xs),
              child: ChoiceChip(
                key: Key('card-designer-group-${g.name}'),
                avatar: Icon(g.icon, size: 16),
                label: Text(g.label),
                selected: _group == g,
                onSelected: (_) => setState(() => _group = g),
              ),
            ),
        ]),
      );
    final controls = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (_group == _Group.template)
        ..._templateControls(context)
      else if (d == null)
        _needsDesign(context)
      else
        ...switch (_group) {
          _Group.background => _backgroundControls(context, d),
          _Group.cover => _coverControls(context, d),
          _Group.waveform => _waveformControls(context, d),
          _Group.text => _textControls(context, d),
          _Group.layout => _layoutControls(context, d),
          _Group.template => const <Widget>[],
        },
    ]);

    final title = _kind == CardKind.text ? 'Design the text card' : 'Design the audio card';
    final subtitle = _post
        ? (_kind == CardKind.text ? 'For every text card of this post.' : 'The picture of this post\'s sound file, on networks that take only video.')
        : 'What new posts start with. Each post can change it.';
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.lg, Space.sm),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: context.text.headlineSmall),
              const SizedBox(height: 2),
              Text(subtitle, style: context.text.bodySmall),
            ]),
          ),
          IconButton(key: const Key('card-designer-undo'), tooltip: 'Undo', onPressed: _at > 0 ? () => _step(-1) : null, icon: const Icon(Icons.undo_rounded)),
          IconButton(
              key: const Key('card-designer-redo'),
              tooltip: 'Redo',
              onPressed: _at < _history.length - 1 ? () => _step(1) : null,
              icon: const Icon(Icons.redo_rounded)),
        ]),
      ),
      Flexible(
        child: LayoutBuilder(
          builder: (context, box) => box.maxWidth >= 760
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 340,
                    child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(Space.xxl, Space.sm, Space.md, Space.lg), child: _preview(context)),
                  ),
                  // The groups stay in view while their controls scroll.
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Padding(padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.xxl, 0), child: chips),
                      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.xxl, Space.lg), child: controls)),
                    ]),
                  ),
                ])
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.lg),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_preview(context), const SizedBox(height: Space.md), chips, controls]),
                ),
        ),
      ),
      Divider(height: 1, color: nf.border),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.md, Space.xxl, Space.lg),
        child: Wrap(alignment: WrapAlignment.end, spacing: Space.sm, runSpacing: Space.sm, children: [
          if (d?.template != null)
            TextButton.icon(
              key: const Key('card-designer-reset'),
              onPressed: () => _apply(cardTemplateById(d!.template)?.design(_kind)),
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Back to the template'),
              style: TextButton.styleFrom(foregroundColor: nf.textMuted),
            ),
          if (_post)
            OutlinedButton(
              key: const Key('card-designer-default'),
              onPressed: () {
                final json = d?.toJson() ?? const <String, dynamic>{};
                ref.read(settingsProvider.notifier).update((x) => _kind == CardKind.text ? x.copyWith(textCardDesign: json) : x.copyWith(audioCardDesign: json));
                showToast(context, 'New posts start with this design', icon: Icons.check_rounded);
              },
              child: const Text('Use for new posts'),
            ),
          FilledButton(key: const Key('card-designer-done'), onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ]),
      ),
    ]);
  }
}

/// Asks for a preset's name; the dialog owns its text field's controller, so
/// it lives as long as the dialog's closing animation.
class _PresetNameDialog extends StatefulWidget {
  const _PresetNameDialog({required this.initial});
  final String initial;

  @override
  State<_PresetNameDialog> createState() => _PresetNameDialogState();
}

class _PresetNameDialogState extends State<_PresetNameDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Save as preset'),
        content: TextField(
          key: const Key('card-preset-name'),
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, _name.text), child: const Text('Save')),
        ],
      );
}
