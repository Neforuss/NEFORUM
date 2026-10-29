import 'package:flutter/foundation.dart';

import '../state/settings.dart' show TextCardAlignment;
import 'caption_fonts.dart';
import 'text_card.dart' show TextCardFont;

// One card designer for text cards and audio cards (1.3.1): a layered card
// spec ([CardDesign]) that the renderer (card_renderer.dart) draws at any
// network's size and the editor (ui/compose/card_designer_sheet.dart) edits.
//
// Every measurement is in pixels on a 1080-pixel-wide card and scales with
// the card; positions are fractions of the card's frame (the card less its
// margin and the network's safe area), so one design fits a square post, a
// 4:5 portrait and a 9:16 story alike. A design is plain data: it is kept as
// JSON in Settings (the defaults), in the composer and in the render
// parameters of every card drawn with it. Reading is lenient: a missing or
// out-of-range value takes its default, so designs written by later versions
// still open.

/// Which card a design is for.
enum CardKind {
  /// A text-only post as a picture ([TextCardFont] cards, 1.0.5).
  text('Text card'),

  /// The still picture of a sound file's video (audio_card.dart).
  audio('Audio card');

  const CardKind(this.label);
  final String label;
}

/// What fills the card behind everything else.
enum CardFillKind {
  solid('Colour'),
  linear('Linear gradient'),
  radial('Radial gradient'),

  /// The card's photo: a text card's background photo, an audio card's
  /// cover art.
  image('Photo');

  const CardFillKind(this.label);
  final String label;
}

/// A repeating pattern laid over the fill.
enum CardPattern {
  none('None'),
  stripes('Stripes'),
  dots('Dots'),
  grid('Grid');

  const CardPattern(this.label);
  final String label;
}

/// The outline of the cover art (or photo) layer.
enum CardCoverShape {
  square('Square'),
  rounded('Rounded'),
  circle('Circle'),

  /// A black record with the cover as its label and a hole in the middle.
  vinyl('Vinyl record');

  const CardCoverShape(this.label);
  final String label;
}

/// How the sound's levels are drawn.
enum CardWaveformStyle {
  bars('Bars'),
  line('Line'),
  mirrored('Mirrored'),
  dots('Dots');

  const CardWaveformStyle(this.label);
  final String label;
}

/// What a text block says.
enum CardBlockRole {
  /// A text card's words: the post as written for the network.
  postText('Post text'),

  /// The account's @handle.
  handle('@handle'),

  /// The NEFORUM mark and wordmark.
  signature('NEFORUM signature'),

  /// An audio card's track title.
  title('Title'),
  artist('Artist'),

  /// "Album · 2024".
  albumYear('Album and year'),

  /// Words the user types into the block itself ([CardTextBlock.text]).
  custom('Your own words');

  const CardBlockRole(this.label);
  final String label;

  /// The roles a card of [kind] offers.
  static List<CardBlockRole> of(CardKind kind) => kind == CardKind.text
      ? const [postText, handle, signature, custom]
      : const [title, artist, albumYear, handle, signature, custom];
}

/// A point on the frame's 3 x 3 grid: an element's same point goes there.
enum CardAnchor {
  topLeft('Top left'),
  topCenter('Top'),
  topRight('Top right'),
  centerLeft('Left'),
  center('Middle'),
  centerRight('Right'),
  bottomLeft('Bottom left'),
  bottomCenter('Bottom'),
  bottomRight('Bottom right');

  const CardAnchor(this.label);
  final String label;

  /// 0 (left), 0.5 or 1 (right).
  double get x => (index % 3) / 2;

  /// 0 (top), 0.5 or 1 (bottom).
  double get y => (index ~/ 3) / 2;
}

double _num(Object? v, double fallback, double min, double max) => v is num && v.isFinite ? v.toDouble().clamp(min, max) : fallback;
int _int(Object? v, int fallback, int min, int max) => v is num && v.isFinite ? v.round().clamp(min, max) : fallback;
int _argb(Object? v, int fallback) => v is int ? v & 0xFFFFFFFF : fallback;
bool _bool(Object? v, bool fallback) => v is bool ? v : fallback;
T _enum<T extends Enum>(List<T> values, Object? v, T fallback) => values.asNameMap()[v] ?? fallback;
Map<String, dynamic>? _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : null;

/// The fill, pattern, grain and vignette behind a card's layers.
@immutable
class CardBackground {
  const CardBackground({
    this.kind = CardFillKind.solid,
    this.color = 0xFF000000,
    this.colors = const [0xFF7D00FF, 0xFF000000],
    this.angle = 0,
    this.centerX = 0.5,
    this.centerY = 0.5,
    this.radius = 1,
    this.pattern = CardPattern.none,
    this.patternColor = 0x33FFFFFF,
    this.patternScale = 48,
    this.patternThickness = 6,
    this.patternAngle = 45,
    this.grain = 0,
    this.vignette = 0,
    this.photoBlur = 0,
    this.photoDimming = 0.3,
    this.photoZoom = 1,
    this.photoOffsetX = 0,
    this.photoOffsetY = 0,
  });

  factory CardBackground.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const CardBackground();
    final raw = j['colors'];
    final colors = raw is List ? [for (final c in raw.take(3)) if (c is int) c & 0xFFFFFFFF] : const <int>[];
    return CardBackground(
      kind: _enum(CardFillKind.values, j['kind'], CardFillKind.solid),
      color: _argb(j['color'], 0xFF000000),
      colors: colors.length >= 2 ? colors : const [0xFF7D00FF, 0xFF000000],
      angle: _num(j['angle'], 0, 0, 360),
      centerX: _num(j['centerX'], 0.5, 0, 1),
      centerY: _num(j['centerY'], 0.5, 0, 1),
      radius: _num(j['radius'], 1, 0.2, 2),
      pattern: _enum(CardPattern.values, j['pattern'], CardPattern.none),
      patternColor: _argb(j['patternColor'], 0x33FFFFFF),
      patternScale: _num(j['patternScale'], 48, 8, 240),
      patternThickness: _num(j['patternThickness'], 6, 1, 80),
      patternAngle: _num(j['patternAngle'], 45, 0, 180),
      grain: _num(j['grain'], 0, 0, 1),
      vignette: _num(j['vignette'], 0, 0, 1),
      photoBlur: _num(j['photoBlur'], 0, 0, 30),
      photoDimming: _num(j['photoDimming'], 0.3, 0, 0.8),
      photoZoom: _num(j['photoZoom'], 1, 1, 4),
      photoOffsetX: _num(j['photoOffsetX'], 0, -1, 1),
      photoOffsetY: _num(j['photoOffsetY'], 0, -1, 1),
    );
  }

  final CardFillKind kind;

  /// ARGB of a [CardFillKind.solid] fill, and under a photo that leaves room.
  final int color;

  /// Two or three ARGB stops of a gradient, evenly spaced.
  final List<int> colors;

  /// A linear gradient's direction, clockwise degrees: 0 runs from the top
  /// down, 90 from left to right (as a text card photo's gradient).
  final double angle;

  /// A radial gradient's centre (fractions of the card) and its radius as a
  /// multiple of half the card's diagonal.
  final double centerX;
  final double centerY;
  final double radius;

  final CardPattern pattern;

  /// ARGB; the alpha is how strongly the pattern shows.
  final int patternColor;

  /// Distance between stripes, dots or grid lines, in pixels at 1080 wide.
  final double patternScale;

  /// Stripe and line width, or dot diameter, in pixels at 1080 wide.
  final double patternThickness;

  /// Turn of stripes, in degrees.
  final double patternAngle;

  /// Film grain, 0 to 1.
  final double grain;

  /// Darkening towards the corners, 0 to 1.
  final double vignette;

  /// An audio card's photo (its cover art) as a fill: blur, dimming, zoom and
  /// focal point. A text card's photo has its own, fuller adjustments
  /// (TextCardBackground).
  final double photoBlur;
  final double photoDimming;
  final double photoZoom;
  final double photoOffsetX;
  final double photoOffsetY;

  CardBackground copyWith({
    CardFillKind? kind,
    int? color,
    List<int>? colors,
    double? angle,
    double? centerX,
    double? centerY,
    double? radius,
    CardPattern? pattern,
    int? patternColor,
    double? patternScale,
    double? patternThickness,
    double? patternAngle,
    double? grain,
    double? vignette,
    double? photoBlur,
    double? photoDimming,
    double? photoZoom,
    double? photoOffsetX,
    double? photoOffsetY,
  }) =>
      CardBackground(
        kind: kind ?? this.kind,
        color: color ?? this.color,
        colors: colors ?? this.colors,
        angle: angle ?? this.angle,
        centerX: centerX ?? this.centerX,
        centerY: centerY ?? this.centerY,
        radius: radius ?? this.radius,
        pattern: pattern ?? this.pattern,
        patternColor: patternColor ?? this.patternColor,
        patternScale: patternScale ?? this.patternScale,
        patternThickness: patternThickness ?? this.patternThickness,
        patternAngle: patternAngle ?? this.patternAngle,
        grain: grain ?? this.grain,
        vignette: vignette ?? this.vignette,
        photoBlur: photoBlur ?? this.photoBlur,
        photoDimming: photoDimming ?? this.photoDimming,
        photoZoom: photoZoom ?? this.photoZoom,
        photoOffsetX: photoOffsetX ?? this.photoOffsetX,
        photoOffsetY: photoOffsetY ?? this.photoOffsetY,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'color': color,
        'colors': colors,
        'angle': angle,
        'centerX': centerX,
        'centerY': centerY,
        'radius': radius,
        'pattern': pattern.name,
        'patternColor': patternColor,
        'patternScale': patternScale,
        'patternThickness': patternThickness,
        'patternAngle': patternAngle,
        'grain': grain,
        'vignette': vignette,
        'photoBlur': photoBlur,
        'photoDimming': photoDimming,
        'photoZoom': photoZoom,
        'photoOffsetX': photoOffsetX,
        'photoOffsetY': photoOffsetY,
      };
}

/// The cover art (an audio card) or photo (a text card) as a framed layer.
@immutable
class CardCoverLayer {
  const CardCoverLayer({
    this.visible = false,
    this.size = 0.6,
    this.anchor = CardAnchor.topCenter,
    this.offsetX = 0,
    this.offsetY = 0,
    this.shape = CardCoverShape.rounded,
    this.cornerRadius = 0.06,
    this.borderWidth = 0,
    this.borderColor = 0xFFFFFFFF,
    this.shadow = 0.45,
    this.shadowBlur = 36,
    this.shadowOffsetY = 18,
    this.rotation = 0,
  });

  factory CardCoverLayer.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const CardCoverLayer();
    return CardCoverLayer(
      visible: _bool(j['visible'], false),
      size: _num(j['size'], 0.6, 0.1, 1),
      anchor: _enum(CardAnchor.values, j['anchor'], CardAnchor.topCenter),
      offsetX: _num(j['offsetX'], 0, -1, 1),
      offsetY: _num(j['offsetY'], 0, -1, 1),
      shape: _enum(CardCoverShape.values, j['shape'], CardCoverShape.rounded),
      cornerRadius: _num(j['cornerRadius'], 0.06, 0, 0.5),
      borderWidth: _num(j['borderWidth'], 0, 0, 80),
      borderColor: _argb(j['borderColor'], 0xFFFFFFFF),
      shadow: _num(j['shadow'], 0.45, 0, 1),
      shadowBlur: _num(j['shadowBlur'], 36, 0, 120),
      shadowOffsetY: _num(j['shadowOffsetY'], 18, -120, 120),
      rotation: _num(j['rotation'], 0, -180, 180),
    );
  }

  final bool visible;

  /// The side (or diameter) as a fraction of the frame's shorter side.
  final double size;
  final CardAnchor anchor;

  /// Moves it by a fraction of the frame's width and height.
  final double offsetX;
  final double offsetY;
  final CardCoverShape shape;

  /// A rounded square's corner radius as a fraction of its side.
  final double cornerRadius;

  /// Pixels at 1080 wide; 0 for none.
  final double borderWidth;
  final int borderColor;

  /// Opacity of the shadow, its blur and how far down it falls (pixels at
  /// 1080 wide).
  final double shadow;
  final double shadowBlur;
  final double shadowOffsetY;

  /// Clockwise degrees.
  final double rotation;

  CardCoverLayer copyWith({
    bool? visible,
    double? size,
    CardAnchor? anchor,
    double? offsetX,
    double? offsetY,
    CardCoverShape? shape,
    double? cornerRadius,
    double? borderWidth,
    int? borderColor,
    double? shadow,
    double? shadowBlur,
    double? shadowOffsetY,
    double? rotation,
  }) =>
      CardCoverLayer(
        visible: visible ?? this.visible,
        size: size ?? this.size,
        anchor: anchor ?? this.anchor,
        offsetX: offsetX ?? this.offsetX,
        offsetY: offsetY ?? this.offsetY,
        shape: shape ?? this.shape,
        cornerRadius: cornerRadius ?? this.cornerRadius,
        borderWidth: borderWidth ?? this.borderWidth,
        borderColor: borderColor ?? this.borderColor,
        shadow: shadow ?? this.shadow,
        shadowBlur: shadowBlur ?? this.shadowBlur,
        shadowOffsetY: shadowOffsetY ?? this.shadowOffsetY,
        rotation: rotation ?? this.rotation,
      );

  Map<String, dynamic> toJson() => {
        'visible': visible,
        'size': size,
        'anchor': anchor.name,
        'offsetX': offsetX,
        'offsetY': offsetY,
        'shape': shape.name,
        'cornerRadius': cornerRadius,
        'borderWidth': borderWidth,
        'borderColor': borderColor,
        'shadow': shadow,
        'shadowBlur': shadowBlur,
        'shadowOffsetY': shadowOffsetY,
        'rotation': rotation,
      };
}

/// The sound's levels drawn across the card.
@immutable
class CardWaveformLayer {
  const CardWaveformLayer({
    this.visible = false,
    this.style = CardWaveformStyle.mirrored,
    this.color = 0xFFFFFF00,
    this.opacity = 1,
    this.thickness = 8,
    this.bars = 64,
    this.height = 0.16,
    this.width = 1,
    this.anchor = CardAnchor.bottomCenter,
    this.offsetX = 0,
    this.offsetY = 0,
  });

  factory CardWaveformLayer.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const CardWaveformLayer();
    return CardWaveformLayer(
      visible: _bool(j['visible'], false),
      style: _enum(CardWaveformStyle.values, j['style'], CardWaveformStyle.mirrored),
      color: _argb(j['color'], 0xFFFFFF00),
      opacity: _num(j['opacity'], 1, 0, 1),
      thickness: _num(j['thickness'], 8, 1, 60),
      bars: _int(j['bars'], 64, 8, 256),
      height: _num(j['height'], 0.16, 0.03, 0.8),
      width: _num(j['width'], 1, 0.1, 1),
      anchor: _enum(CardAnchor.values, j['anchor'], CardAnchor.bottomCenter),
      offsetX: _num(j['offsetX'], 0, -1, 1),
      offsetY: _num(j['offsetY'], 0, -1, 1),
    );
  }

  final bool visible;
  final CardWaveformStyle style;
  final int color;
  final double opacity;

  /// Bar width, line width or dot size, in pixels at 1080 wide.
  final double thickness;

  /// How many bars (or points) across.
  final int bars;

  /// Height and width as fractions of the frame.
  final double height;
  final double width;
  final CardAnchor anchor;
  final double offsetX;
  final double offsetY;

  CardWaveformLayer copyWith({
    bool? visible,
    CardWaveformStyle? style,
    int? color,
    double? opacity,
    double? thickness,
    int? bars,
    double? height,
    double? width,
    CardAnchor? anchor,
    double? offsetX,
    double? offsetY,
  }) =>
      CardWaveformLayer(
        visible: visible ?? this.visible,
        style: style ?? this.style,
        color: color ?? this.color,
        opacity: opacity ?? this.opacity,
        thickness: thickness ?? this.thickness,
        bars: bars ?? this.bars,
        height: height ?? this.height,
        width: width ?? this.width,
        anchor: anchor ?? this.anchor,
        offsetX: offsetX ?? this.offsetX,
        offsetY: offsetY ?? this.offsetY,
      );

  Map<String, dynamic> toJson() => {
        'visible': visible,
        'style': style.name,
        'color': color,
        'opacity': opacity,
        'thickness': thickness,
        'bars': bars,
        'height': height,
        'width': width,
        'anchor': anchor.name,
        'offsetX': offsetX,
        'offsetY': offsetY,
      };
}

/// One block of words on a card. Blocks at the same [anchor] stack in the
/// order they are listed (downwards from a top anchor, upwards from a bottom
/// one, around the middle otherwise).
@immutable
class CardTextBlock {
  const CardTextBlock({
    required this.role,
    this.text = '',
    this.visible = true,
    this.anchor = CardAnchor.center,
    this.offsetX = 0,
    this.offsetY = 0,
    this.width = 1,
    this.maxHeight = 1,
    this.font = TextCardFont.original,
    this.customFont,
    this.size = 64,
    this.autoFit = false,
    this.weight = 600,
    this.italic = false,
    this.letterSpacing = 0,
    this.lineHeight = 1.25,
    this.color = 0xFFFFFFFF,
    this.outlineWidth = 0,
    this.outlineColor = 0xFF000000,
    this.shadowBlur = 0,
    this.shadowOffsetY = 0,
    this.shadowColor = 0x99000000,
    this.alignment = TextCardAlignment.left,
    this.uppercase = false,
    this.maxLines = 0,
    this.gapBefore = 20,
  });

  factory CardTextBlock.fromJson(Map<String, dynamic> j) => CardTextBlock(
        role: _enum(CardBlockRole.values, j['role'], CardBlockRole.custom),
        text: j['text'] is String ? j['text'] as String : '',
        visible: _bool(j['visible'], true),
        anchor: _enum(CardAnchor.values, j['anchor'], CardAnchor.center),
        offsetX: _num(j['offsetX'], 0, -1, 1),
        offsetY: _num(j['offsetY'], 0, -1, 1),
        width: _num(j['width'], 1, 0.2, 1),
        maxHeight: _num(j['maxHeight'], 1, 0.05, 1),
        font: _enum(TextCardFont.values, j['font'], TextCardFont.original),
        customFont: CaptionFont.tryParse(j['customFont']),
        size: _num(j['size'], 64, 12, 320),
        autoFit: _bool(j['autoFit'], false),
        weight: (_int(j['weight'], 600, 100, 900) / 100).round() * 100,
        italic: _bool(j['italic'], false),
        letterSpacing: _num(j['letterSpacing'], 0, -0.1, 0.5),
        lineHeight: _num(j['lineHeight'], 1.25, 0.8, 2.5),
        color: _argb(j['color'], 0xFFFFFFFF),
        outlineWidth: _num(j['outlineWidth'], 0, 0, 24),
        outlineColor: _argb(j['outlineColor'], 0xFF000000),
        shadowBlur: _num(j['shadowBlur'], 0, 0, 60),
        shadowOffsetY: _num(j['shadowOffsetY'], 0, -40, 40),
        shadowColor: _argb(j['shadowColor'], 0x99000000),
        alignment: _enum(TextCardAlignment.values, j['alignment'], TextCardAlignment.left),
        uppercase: _bool(j['uppercase'], false),
        maxLines: _int(j['maxLines'], 0, 0, 40),
        gapBefore: _num(j['gapBefore'], 20, 0, 200),
      );

  final CardBlockRole role;

  /// The words of a [CardBlockRole.custom] block.
  final String text;
  final bool visible;
  final CardAnchor anchor;
  final double offsetX;
  final double offsetY;

  /// The block's width as a fraction of the frame's.
  final double width;

  /// The most of the frame's height the block takes; with [autoFit] the
  /// words shrink to fit it.
  final double maxHeight;

  /// The built-in font, drawn where [customFont] is missing or unset.
  final TextCardFont font;
  final CaptionFont? customFont;

  /// Font size in pixels at 1080 wide: the size the words start at with
  /// [autoFit], which shrinks them (to no less than a third of it) to fit.
  final double size;
  final bool autoFit;

  /// 100 to 900.
  final int weight;
  final bool italic;

  /// As a fraction of the font size.
  final double letterSpacing;

  /// Line height as a multiple of the font size.
  final double lineHeight;
  final int color;

  /// Pixels at 1080 wide; 0 for none.
  final double outlineWidth;
  final int outlineColor;
  final double shadowBlur;
  final double shadowOffsetY;
  final int shadowColor;
  final TextCardAlignment alignment;
  final bool uppercase;

  /// 0 for no limit.
  final int maxLines;

  /// Room above the block when another block at its anchor comes before it,
  /// in pixels at 1080 wide.
  final double gapBefore;

  CardTextBlock copyWith({
    CardBlockRole? role,
    String? text,
    bool? visible,
    CardAnchor? anchor,
    double? offsetX,
    double? offsetY,
    double? width,
    double? maxHeight,
    TextCardFont? font,
    CaptionFont? customFont,
    bool clearCustomFont = false,
    double? size,
    bool? autoFit,
    int? weight,
    bool? italic,
    double? letterSpacing,
    double? lineHeight,
    int? color,
    double? outlineWidth,
    int? outlineColor,
    double? shadowBlur,
    double? shadowOffsetY,
    int? shadowColor,
    TextCardAlignment? alignment,
    bool? uppercase,
    int? maxLines,
    double? gapBefore,
  }) =>
      CardTextBlock(
        role: role ?? this.role,
        text: text ?? this.text,
        visible: visible ?? this.visible,
        anchor: anchor ?? this.anchor,
        offsetX: offsetX ?? this.offsetX,
        offsetY: offsetY ?? this.offsetY,
        width: width ?? this.width,
        maxHeight: maxHeight ?? this.maxHeight,
        font: font ?? this.font,
        customFont: clearCustomFont ? null : (customFont ?? this.customFont),
        size: size ?? this.size,
        autoFit: autoFit ?? this.autoFit,
        weight: weight ?? this.weight,
        italic: italic ?? this.italic,
        letterSpacing: letterSpacing ?? this.letterSpacing,
        lineHeight: lineHeight ?? this.lineHeight,
        color: color ?? this.color,
        outlineWidth: outlineWidth ?? this.outlineWidth,
        outlineColor: outlineColor ?? this.outlineColor,
        shadowBlur: shadowBlur ?? this.shadowBlur,
        shadowOffsetY: shadowOffsetY ?? this.shadowOffsetY,
        shadowColor: shadowColor ?? this.shadowColor,
        alignment: alignment ?? this.alignment,
        uppercase: uppercase ?? this.uppercase,
        maxLines: maxLines ?? this.maxLines,
        gapBefore: gapBefore ?? this.gapBefore,
      );

  Map<String, dynamic> toJson() => {
        'role': role.name,
        if (text.isNotEmpty) 'text': text,
        'visible': visible,
        'anchor': anchor.name,
        'offsetX': offsetX,
        'offsetY': offsetY,
        'width': width,
        'maxHeight': maxHeight,
        'font': font.name,
        if (customFont != null) 'customFont': customFont!.toJson(),
        'size': size,
        'autoFit': autoFit,
        'weight': weight,
        'italic': italic,
        'letterSpacing': letterSpacing,
        'lineHeight': lineHeight,
        'color': color,
        'outlineWidth': outlineWidth,
        'outlineColor': outlineColor,
        'shadowBlur': shadowBlur,
        'shadowOffsetY': shadowOffsetY,
        'shadowColor': shadowColor,
        'alignment': alignment.name,
        'uppercase': uppercase,
        'maxLines': maxLines,
        'gapBefore': gapBefore,
      };
}

/// A card's whole design: its background, the cover and waveform layers and
/// its text blocks, drawn in that order.
@immutable
class CardDesign {
  const CardDesign({
    required this.kind,
    this.template,
    this.background = const CardBackground(),
    this.cover = const CardCoverLayer(),
    this.waveform = const CardWaveformLayer(),
    this.blocks = const [],
    this.margin = 80,
  });

  /// Null when [j] is not a design (or is empty: the classic card).
  static CardDesign? tryParse(Object? j) {
    if (j is! Map || j.isEmpty) return null;
    final m = Map<String, dynamic>.from(j);
    final kind = CardKind.values.asNameMap()[m['kind']];
    if (kind == null) return null;
    final raw = m['blocks'];
    return CardDesign(
      kind: kind,
      template: m['template'] is String ? m['template'] as String : null,
      background: CardBackground.fromJson(_map(m['background'])),
      cover: CardCoverLayer.fromJson(_map(m['cover'])),
      waveform: CardWaveformLayer.fromJson(_map(m['waveform'])),
      blocks: raw is List ? [for (final b in raw.take(24)) if (b is Map) CardTextBlock.fromJson(Map<String, dynamic>.from(b))] : const [],
      margin: _num(m['margin'], 80, 0, 240),
    );
  }

  final CardKind kind;

  /// The template it started from ([kCardTemplates]), for the editor.
  final String? template;
  final CardBackground background;
  final CardCoverLayer cover;
  final CardWaveformLayer waveform;
  final List<CardTextBlock> blocks;

  /// Room between the card's edge (or the network's safe area) and its
  /// frame, in pixels at 1080 wide.
  final double margin;

  /// Every installed or imported font its blocks use, once each.
  Set<CaptionFont> get customFonts => {
        for (final b in blocks)
          if (b.visible) ?b.customFont,
      };

  CardDesign copyWith({
    String? template,
    bool clearTemplate = false,
    CardBackground? background,
    CardCoverLayer? cover,
    CardWaveformLayer? waveform,
    List<CardTextBlock>? blocks,
    double? margin,
  }) =>
      CardDesign(
        kind: kind,
        template: clearTemplate ? null : (template ?? this.template),
        background: background ?? this.background,
        cover: cover ?? this.cover,
        waveform: waveform ?? this.waveform,
        blocks: blocks ?? this.blocks,
        margin: margin ?? this.margin,
      );

  /// This design with block [index] changed.
  CardDesign withBlock(int index, CardTextBlock Function(CardTextBlock b) change) =>
      copyWith(blocks: [for (var i = 0; i < blocks.length; i++) i == index ? change(blocks[i]) : blocks[i]]);

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (template != null) 'template': template,
        'background': background.toJson(),
        'cover': cover.toJson(),
        'waveform': waveform.toJson(),
        'blocks': [for (final b in blocks) b.toJson()],
        'margin': margin,
      };
}

/// A design the user saved under a name, for either kind of card.
@immutable
class CardPreset {
  const CardPreset({required this.name, required this.design});

  static CardPreset? tryParse(Object? j) {
    if (j is! Map) return null;
    final name = j['name'];
    final design = CardDesign.tryParse(j['design']);
    if (name is! String || name.trim().isEmpty || design == null) return null;
    return CardPreset(name: name.trim(), design: design);
  }

  final String name;
  final CardDesign design;

  Map<String, dynamic> toJson() => {'name': name, 'design': design.toJson()};
}
