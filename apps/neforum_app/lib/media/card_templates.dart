import '../state/settings.dart' show TextCardAlignment;
import 'card_design.dart';
import 'text_card.dart' show TextCardFont;

/// A starting point in the card designer: a whole [CardDesign] for each kind
/// of card, everything editable afterwards.
class CardTemplate {
  const CardTemplate(this.id, this.name, this.description, this._build);
  final String id;
  final String name;
  final String description;
  final CardDesign Function(CardKind kind) _build;

  /// The design for a card of [kind], marked as made from this template. A
  /// text card shows the cover layer (its photo) and the waveform only where
  /// the template is laid out for them; they stay one switch away.
  CardDesign design(CardKind kind) {
    final d = _build(kind).copyWith(template: id);
    if (kind == CardKind.audio) return d;
    return d.copyWith(
      cover: _textCover.contains(id) ? null : d.cover.copyWith(visible: false),
      waveform: _textWaveform.contains(id) ? null : d.waveform.copyWith(visible: false),
    );
  }

  static const Set<String> _textCover = {'vinyl', 'polaroid'};
  static const Set<String> _textWaveform = {'gradientWave'};
}

/// The designer's templates, in the order it shows them.
final List<CardTemplate> kCardTemplates = [
  CardTemplate('minimal', 'Minimal', 'Dark words on warm white, lots of room', _minimal),
  CardTemplate('boldPoster', 'Bold poster', 'Huge capitals on NEFORUM yellow', _boldPoster),
  CardTemplate('vinyl', 'Vinyl', 'A record with your cover as its label', _vinyl),
  CardTemplate('gradientWave', 'Gradient wave', 'A three-colour gradient and the sound across it', _gradientWave),
  CardTemplate('photoOverlay', 'Photo overlay', 'Your photo or cover, dimmed, words over it', _photoOverlay),
  CardTemplate('newspaper', 'Newspaper', 'Serif type on grainy newsprint', _newspaper),
  CardTemplate('neon', 'Neon', 'Glowing colour on a dark grid', _neon),
  CardTemplate('polaroid', 'Polaroid', 'A tilted instant photo with a caption', _polaroid),
  CardTemplate('sunset', 'Sunset', 'A warm radial glow with soft stripes', _sunset),
  CardTemplate('mono', 'Monospace', 'Terminal green on black, with grain', _mono),
];

/// The template called [id], if any.
CardTemplate? cardTemplateById(String? id) => id == null ? null : kCardTemplates.where((t) => t.id == id).firstOrNull;

/// What to call [d] in a short label: its template's name, or "Custom".
String cardTemplateLabel(CardDesign d) => cardTemplateById(d.template)?.name ?? 'Custom';

// Shorthands for the templates' blocks.

CardTextBlock _postText({
  CardAnchor anchor = CardAnchor.center,
  TextCardFont font = TextCardFont.original,
  double size = 96,
  int weight = 600,
  int color = 0xFFFFFFFF,
  TextCardAlignment alignment = TextCardAlignment.left,
  double maxHeight = 0.72,
  double lineHeight = 1.22,
  double letterSpacing = -0.01,
  bool uppercase = false,
  bool italic = false,
  double shadowBlur = 0,
  int shadowColor = 0x99000000,
  double shadowOffsetY = 0,
}) =>
    CardTextBlock(
      role: CardBlockRole.postText,
      anchor: anchor,
      font: font,
      size: size,
      autoFit: true,
      weight: weight,
      color: color,
      alignment: alignment,
      maxHeight: maxHeight,
      lineHeight: lineHeight,
      letterSpacing: letterSpacing,
      uppercase: uppercase,
      italic: italic,
      shadowBlur: shadowBlur,
      shadowColor: shadowColor,
      shadowOffsetY: shadowOffsetY,
    );

CardTextBlock _line(
  CardBlockRole role, {
  CardAnchor anchor = CardAnchor.bottomLeft,
  TextCardFont font = TextCardFont.original,
  double size = 40,
  int weight = 500,
  int color = 0xFFFFFFFF,
  TextCardAlignment alignment = TextCardAlignment.left,
  bool uppercase = false,
  bool italic = false,
  double letterSpacing = 0,
  double gapBefore = 14,
  int maxLines = 2,
  double shadowBlur = 0,
  int shadowColor = 0x99000000,
  String text = '',
}) =>
    CardTextBlock(
      role: role,
      text: text,
      anchor: anchor,
      font: font,
      size: size,
      weight: weight,
      color: color,
      alignment: alignment,
      uppercase: uppercase,
      italic: italic,
      letterSpacing: letterSpacing,
      gapBefore: gapBefore,
      maxLines: maxLines,
      maxHeight: 0.4,
      shadowBlur: shadowBlur,
      shadowColor: shadowColor,
    );

/// Title, artist and album lines of an audio card.
List<CardTextBlock> _track({
  CardAnchor anchor = CardAnchor.bottomLeft,
  TextCardFont font = TextCardFont.original,
  int color = 0xFFFFFFFF,
  int muted = 0xCCFFFFFF,
  int faint = 0x99FFFFFF,
  double titleSize = 80,
  int titleWeight = 800,
  TextCardAlignment alignment = TextCardAlignment.left,
  bool titleUppercase = false,
  bool italic = false,
  double shadowBlur = 0,
}) =>
    [
      _line(CardBlockRole.title,
          anchor: anchor,
          font: font,
          size: titleSize,
          weight: titleWeight,
          color: color,
          alignment: alignment,
          uppercase: titleUppercase,
          italic: italic,
          maxLines: 3,
          letterSpacing: -0.01,
          shadowBlur: shadowBlur),
      _line(CardBlockRole.artist,
          anchor: anchor, font: font, size: titleSize * 0.5, color: muted, alignment: alignment, italic: italic, shadowBlur: shadowBlur),
      _line(CardBlockRole.albumYear,
          anchor: anchor,
          font: font,
          size: titleSize * 0.34,
          weight: 600,
          color: faint,
          alignment: alignment,
          uppercase: true,
          letterSpacing: 0.12,
          gapBefore: 18,
          shadowBlur: shadowBlur),
    ];

CardTextBlock _signature({CardAnchor anchor = CardAnchor.bottomRight, int color = 0xFFFFFFFF, double size = 24}) =>
    CardTextBlock(role: CardBlockRole.signature, anchor: anchor, size: size, weight: 800, color: color, letterSpacing: 0.06);

CardTextBlock _handle({CardAnchor anchor = CardAnchor.bottomLeft, int color = 0x99FFFFFF, TextCardFont font = TextCardFont.original, double size = 28}) =>
    _line(CardBlockRole.handle, anchor: anchor, font: font, size: size, color: color, maxLines: 1);

CardDesign _minimal(CardKind kind) {
  const ink = 0xFF16141A;
  return CardDesign(
    kind: kind,
    background: const CardBackground(color: 0xFFF7F4EE),
    cover: const CardCoverLayer(visible: true, size: 0.55, anchor: CardAnchor.topLeft, shape: CardCoverShape.rounded, cornerRadius: 0.04, shadow: 0.22),
    waveform: const CardWaveformLayer(
        visible: true, style: CardWaveformStyle.line, color: ink, opacity: 0.35, thickness: 3, height: 0.06, anchor: CardAnchor.centerLeft, offsetY: 0.14),
    blocks: kind == CardKind.text
        ? [
            _postText(anchor: CardAnchor.centerLeft, color: ink, size: 92),
            _handle(color: 0x9916141A),
            _signature(color: ink),
          ]
        : _track(color: ink, muted: 0xB316141A, faint: 0x8016141A, titleSize: 76),
  );
}

CardDesign _boldPoster(CardKind kind) => CardDesign(
      kind: kind,
      margin: 64,
      background: const CardBackground(color: 0xFFFFFF00, pattern: CardPattern.dots, patternColor: 0x1A000000, patternScale: 28, patternThickness: 6),
      cover: const CardCoverLayer(visible: true, size: 0.46, anchor: CardAnchor.topRight, shape: CardCoverShape.square, rotation: 4, shadow: 0.3),
      waveform: const CardWaveformLayer(
          visible: true, style: CardWaveformStyle.bars, color: 0xFF000000, thickness: 10, bars: 20, height: 0.12, width: 0.42, anchor: CardAnchor.topLeft),
      blocks: kind == CardKind.text
          ? [
              _postText(font: TextCardFont.tiktokSans, size: 150, weight: 900, color: 0xFF000000, uppercase: true, lineHeight: 0.98, letterSpacing: -0.02),
              _handle(color: 0xFF000000, size: 30),
              _signature(color: 0xFF000000),
            ]
          : _track(font: TextCardFont.tiktokSans, color: 0xFF000000, muted: 0xCC000000, faint: 0x99000000, titleSize: 120, titleWeight: 900, titleUppercase: true),
    );

CardDesign _vinyl(CardKind kind) => CardDesign(
      kind: kind,
      background: const CardBackground(kind: CardFillKind.radial, colors: [0xFF3A1670, 0xFF0B0812], centerY: 0.38, radius: 1.1, grain: 0.12),
      cover: CardCoverLayer(
          visible: true,
          size: kind == CardKind.text ? 0.56 : 0.8,
          anchor: CardAnchor.topCenter,
          shape: CardCoverShape.vinyl,
          shadow: 0.6,
          shadowBlur: 50,
          shadowOffsetY: 24),
      blocks: kind == CardKind.text
          ? [
              _postText(anchor: CardAnchor.bottomCenter, alignment: TextCardAlignment.center, size: 72, maxHeight: 0.36),
              _signature(anchor: CardAnchor.topLeft, size: 22),
            ]
          : _track(anchor: CardAnchor.bottomCenter, alignment: TextCardAlignment.center, titleSize: 64, titleWeight: 700),
    );

CardDesign _gradientWave(CardKind kind) => CardDesign(
      kind: kind,
      background: const CardBackground(kind: CardFillKind.linear, colors: [0xFF7D00FF, 0xFFFF2D55, 0xFFFF9500], angle: 135),
      cover: const CardCoverLayer(visible: true, size: 0.34, anchor: CardAnchor.topRight, shape: CardCoverShape.circle, borderWidth: 8, shadow: 0.3),
      waveform: CardWaveformLayer(
          visible: true,
          style: CardWaveformStyle.mirrored,
          color: 0xFFFFFFFF,
          opacity: kind == CardKind.text ? 0.45 : 0.9,
          thickness: 9,
          bars: 72,
          height: kind == CardKind.text ? 0.14 : 0.24,
          anchor: kind == CardKind.text ? CardAnchor.bottomCenter : CardAnchor.center,
          offsetY: kind == CardKind.text ? 0 : 0.06),
      blocks: kind == CardKind.text
          ? [
              _postText(anchor: CardAnchor.topLeft, size: 100, weight: 800, maxHeight: 0.7),
              _signature(anchor: CardAnchor.bottomRight, size: 22),
            ]
          : _track(anchor: CardAnchor.topLeft, titleSize: 84),
    );

CardDesign _photoOverlay(CardKind kind) => CardDesign(
      kind: kind,
      background: const CardBackground(kind: CardFillKind.image, color: 0xFF111111, vignette: 0.45, photoDimming: 0.42, photoBlur: 0),
      waveform: const CardWaveformLayer(visible: true, style: CardWaveformStyle.bars, color: 0xFFFFFFFF, opacity: 0.75, thickness: 6, bars: 80, height: 0.07, anchor: CardAnchor.topCenter),
      blocks: kind == CardKind.text
          ? [
              _postText(anchor: CardAnchor.bottomLeft, size: 88, weight: 700, maxHeight: 0.62, shadowBlur: 18, shadowColor: 0xB3000000, shadowOffsetY: 2),
              _handle(anchor: CardAnchor.topLeft, color: 0xE6FFFFFF),
              _signature(anchor: CardAnchor.topRight, size: 22),
            ]
          : _track(shadowBlur: 16),
    );

CardDesign _newspaper(CardKind kind) {
  const ink = 0xFF1B1B1B;
  return CardDesign(
    kind: kind,
    background: const CardBackground(color: 0xFFF1ECE2, grain: 0.28, vignette: 0.15),
    cover: const CardCoverLayer(visible: true, size: 0.46, anchor: CardAnchor.center, offsetY: -0.06, shape: CardCoverShape.square, shadow: 0, borderWidth: 3, borderColor: ink),
    blocks: [
      _line(CardBlockRole.custom,
          text: 'The Daily Post', anchor: CardAnchor.topCenter, font: TextCardFont.timesNewRoman, size: 40, weight: 700, color: ink,
          alignment: TextCardAlignment.center, uppercase: true, letterSpacing: 0.18, maxLines: 1),
      if (kind == CardKind.text) ...[
        _postText(font: TextCardFont.timesNewRoman, color: ink, size: 92, weight: 700, alignment: TextCardAlignment.justify, letterSpacing: 0, maxHeight: 0.7),
        _handle(anchor: CardAnchor.bottomCenter, color: 0xB31B1B1B, font: TextCardFont.timesNewRoman, size: 30).copyWith(italic: true, alignment: TextCardAlignment.center),
      ] else
        ..._track(anchor: CardAnchor.bottomCenter, font: TextCardFont.timesNewRoman, color: ink, muted: 0xCC1B1B1B, faint: 0x991B1B1B, titleSize: 72, titleWeight: 700, alignment: TextCardAlignment.center),
    ],
  );
}

CardDesign _neon(CardKind kind) {
  const pink = 0xFFFF4DF0, cyan = 0xFF35F3FF;
  return CardDesign(
    kind: kind,
    background: const CardBackground(color: 0xFF07020F, pattern: CardPattern.grid, patternColor: 0x26FF2DD5, patternScale: 64, patternThickness: 2, vignette: 0.55),
    cover: const CardCoverLayer(visible: true, size: 0.46, anchor: CardAnchor.topCenter, shape: CardCoverShape.circle, borderWidth: 6, borderColor: cyan, shadow: 0.5),
    waveform: const CardWaveformLayer(visible: true, style: CardWaveformStyle.line, color: cyan, thickness: 5, bars: 120, height: 0.12, anchor: CardAnchor.center, offsetY: 0.1),
    blocks: kind == CardKind.text
        ? [
            _postText(color: pink, size: 96, weight: 700, alignment: TextCardAlignment.center, shadowBlur: 28, shadowColor: 0xFFFF00E5),
            _signature(anchor: CardAnchor.bottomCenter, color: cyan, size: 22),
          ]
        : [
            _line(CardBlockRole.title, anchor: CardAnchor.bottomCenter, size: 76, weight: 800, color: pink, alignment: TextCardAlignment.center, maxLines: 3, shadowBlur: 26, shadowColor: 0xFFFF00E5),
            _line(CardBlockRole.artist, anchor: CardAnchor.bottomCenter, size: 40, color: cyan, alignment: TextCardAlignment.center, shadowBlur: 18, shadowColor: 0xFF00B7FF),
            _line(CardBlockRole.albumYear, anchor: CardAnchor.bottomCenter, size: 26, weight: 600, color: 0xB335F3FF, alignment: TextCardAlignment.center, uppercase: true, letterSpacing: 0.14),
          ],
  );
}

CardDesign _polaroid(CardKind kind) {
  const ink = 0xFF2A2622;
  return CardDesign(
    kind: kind,
    background: const CardBackground(color: 0xFFE7E1D6, grain: 0.14, vignette: 0.2),
    cover: const CardCoverLayer(
        visible: true,
        size: 0.72,
        anchor: CardAnchor.topCenter,
        offsetY: 0.02,
        shape: CardCoverShape.square,
        rotation: -3,
        borderWidth: 30,
        borderColor: 0xFFFFFFFF,
        shadow: 0.35,
        shadowBlur: 44,
        shadowOffsetY: 20),
    blocks: kind == CardKind.text
        ? [
            _postText(anchor: CardAnchor.bottomCenter, font: TextCardFont.timesNewRoman, color: ink, size: 64, weight: 400, italic: true,
                alignment: TextCardAlignment.center, maxHeight: 0.26, letterSpacing: 0),
            _handle(anchor: CardAnchor.bottomCenter, color: 0x992A2622, font: TextCardFont.timesNewRoman).copyWith(alignment: TextCardAlignment.center),
          ]
        : _track(anchor: CardAnchor.bottomCenter, font: TextCardFont.timesNewRoman, color: ink, muted: 0xCC2A2622, faint: 0x992A2622,
            titleSize: 62, titleWeight: 700, alignment: TextCardAlignment.center, italic: true),
  );
}

CardDesign _sunset(CardKind kind) => CardDesign(
      kind: kind,
      background: const CardBackground(
          kind: CardFillKind.radial,
          colors: [0xFFFFD36E, 0xFFFF6A3D, 0xFF5B1A73],
          centerY: 1,
          radius: 1.2,
          pattern: CardPattern.stripes,
          patternColor: 0x14FFFFFF,
          patternScale: 36,
          patternThickness: 10,
          patternAngle: 0),
      cover: const CardCoverLayer(visible: true, size: 0.4, anchor: CardAnchor.topLeft, shape: CardCoverShape.rounded, cornerRadius: 0.12, shadow: 0.35),
      waveform: const CardWaveformLayer(visible: true, style: CardWaveformStyle.dots, color: 0xFFFFFFFF, opacity: 0.8, thickness: 8, bars: 48, height: 0.14, anchor: CardAnchor.topRight, width: 0.45),
      blocks: kind == CardKind.text
          ? [
              _postText(anchor: CardAnchor.bottomLeft, size: 96, weight: 800, maxHeight: 0.66),
              _signature(anchor: CardAnchor.topRight, size: 22),
            ]
          : _track(titleSize: 82),
    );

CardDesign _mono(CardKind kind) {
  const green = 0xFF3DFF8A;
  return CardDesign(
    kind: kind,
    background: const CardBackground(color: 0xFF050805, grain: 0.35, vignette: 0.5, pattern: CardPattern.stripes, patternColor: 0x10FFFFFF, patternScale: 8, patternThickness: 3, patternAngle: 90),
    cover: const CardCoverLayer(visible: true, size: 0.36, anchor: CardAnchor.topRight, shape: CardCoverShape.square, borderWidth: 4, borderColor: green, shadow: 0),
    waveform: const CardWaveformLayer(visible: true, style: CardWaveformStyle.bars, color: green, thickness: 6, bars: 96, height: 0.1, anchor: CardAnchor.bottomCenter, opacity: 0.8),
    blocks: kind == CardKind.text
        ? [
            _line(CardBlockRole.custom, text: '> post', anchor: CardAnchor.topLeft, font: TextCardFont.arial, size: 30, color: 0x993DFF8A, maxLines: 1),
            _postText(anchor: CardAnchor.topLeft, font: TextCardFont.arial, color: green, size: 72, weight: 400, maxHeight: 0.66, letterSpacing: 0.02),
            _handle(color: 0xB33DFF8A, font: TextCardFont.arial),
          ]
        : _track(anchor: CardAnchor.topLeft, font: TextCardFont.arial, color: green, muted: 0xCC3DFF8A, faint: 0x993DFF8A, titleSize: 70, titleWeight: 700),
  );
}
