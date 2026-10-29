import 'package:flutter/material.dart';

import '../state/settings.dart' show TextCardAlignment;
import 'caption_fonts.dart';
import 'text_card.dart';

/// Where the caption goes on a photo.
enum CaptionPlacement {
  top('Top', 'On the photo, near the top'),
  middle('Middle', 'On the photo, in the middle'),
  bottom('Bottom', 'On the photo, near the bottom'),

  /// A band across the top of the network's whole frame (TikTok 9:16,
  /// Instagram 4:5 or 9:16 for stories), as tall as the words need, with the
  /// photo scaled to fit below it.
  blockAbove('Block above', 'In a band above the photo, which is scaled to fit below it');

  const CaptionPlacement(this.label, this.description);
  final String label;
  final String description;

  /// Written over the photo (not in a block above it).
  bool get isOverlay => this != blockAbove;
}

/// What is behind the caption's words.
enum CaptionBackground {
  none('None'),
  translucentDark('Dark'),
  translucentLight('Light'),
  solid('Colour');

  const CaptionBackground(this.label);
  final String label;
}

/// Colours offered for the caption's words and background (ARGB).
const List<int> kCaptionColors = [
  0xFFFFFFFF,
  0xFF000000,
  0xFFFFFF00,
  0xFF7D00FF,
  0xFFFF3B30,
  0xFFFF9500,
  0xFF34C759,
  0xFF0A84FF,
  0xFFFF2D55,
];

/// How the caption is written on a photo: the words (the caption itself
/// unless [text] is set), where they go, their size, colour, background,
/// alignment and font. Kept as JSON in Settings (the default) and in the
/// composer (this post's own), and recorded in the render parameters of every
/// captioned photo, so the same picture can be made again.
///
/// Sizes are in pixels on a 1080-pixel-wide picture and scale with it.
@immutable
class CaptionStyle {
  const CaptionStyle({
    this.text,
    this.placement = CaptionPlacement.bottom,
    this.textScale,
    this.textColor = 0xFFFFFFFF,
    this.background = CaptionBackground.translucentDark,
    this.backgroundColor = 0xFF000000,
    this.opacity = 0.65,
    this.alignment = TextCardAlignment.center,
    this.font = TextCardFont.platform,
    this.bold = false,
    this.shadow = false,
    this.lineSpacing = 1.22,
    this.padding = 30,
    this.customFont, // 1.3: cards
  });

  /// Reads the JSON of [toJson]; anything missing or out of range takes the
  /// default.
  factory CaptionStyle.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const CaptionStyle();
    double? number(String key, double min, double max) {
      final v = j[key];
      return v is num && v.isFinite ? v.toDouble().clamp(min, max) : null;
    }

    final text = j['text'];
    return CaptionStyle(
      text: text is String && text.trim().isNotEmpty ? text : null,
      placement: CaptionPlacement.values.asNameMap()[j['placement']] ?? CaptionPlacement.bottom,
      textScale: number('textScale', minTextScale, maxTextScale),
      textColor: j['textColor'] is int ? j['textColor'] as int : 0xFFFFFFFF,
      background: CaptionBackground.values.asNameMap()[j['background']] ?? CaptionBackground.translucentDark,
      backgroundColor: j['backgroundColor'] is int ? j['backgroundColor'] as int : 0xFF000000,
      opacity: number('opacity', 0, 1) ?? 0.65,
      alignment: TextCardAlignment.values.asNameMap()[j['alignment']] ?? TextCardAlignment.center,
      font: TextCardFont.values.asNameMap()[j['font']] ?? TextCardFont.platform,
      bold: j['bold'] == true,
      shadow: j['shadow'] == true,
      lineSpacing: number('lineSpacing', minLineSpacing, maxLineSpacing) ?? 1.22,
      padding: number('padding', 0, maxPadding) ?? 30,
      customFont: CaptionFont.tryParse(j['customFont']), // 1.3: cards
    );
  }

  static const double minTextScale = 0.5, maxTextScale = 2.5;
  static const double minLineSpacing = 0.9, maxLineSpacing = 2.2;
  static const double maxPadding = 96;

  /// Words written on the photo instead of the caption; null = the caption.
  final String? text;
  final CaptionPlacement placement;

  /// Null: as large as fits. Otherwise a fixed size, 1 = 60 pixels.
  final double? textScale;

  /// ARGB of the words.
  final int textColor;
  final CaptionBackground background;

  /// ARGB of a [CaptionBackground.solid] background.
  final int backgroundColor;

  /// Opacity of the background, 0 to 1.
  final double opacity;
  final TextCardAlignment alignment;

  /// Not yet resolved for the network ([TextCardFont.resolve]).
  final TextCardFont font;
  final bool bold;
  final bool shadow;

  /// Line height as a multiple of the text size.
  final double lineSpacing;

  /// Room around the words inside their background, in pixels at 1080 wide
  /// (above and below: 60% of it).
  final double padding;

  /// 1.3: cards. A font installed on the device or imported, drawn instead of
  /// [font] once it is loaded ([registeredCaptionFontAlias]). Where it is
  /// missing, [font] is drawn. Null: [font].
  final CaptionFont? customFont;

  /// Sets the words at a fixed size, never shrinking them to fit.
  bool get fixedSize => textScale != null;

  /// The words written on the photo for a post whose caption is [caption].
  String wordsFor(String caption) => (text ?? '').trim().isNotEmpty ? text!.trim() : caption;

  /// The colour behind the words, opacity included; transparent for none.
  Color get backgroundFill => switch (background) {
        CaptionBackground.none => const Color(0x00000000),
        CaptionBackground.translucentDark => Color.fromRGBO(0, 0, 0, opacity),
        CaptionBackground.translucentLight => Color.fromRGBO(255, 255, 255, opacity),
        CaptionBackground.solid => Color(backgroundColor | 0xFF000000).withValues(alpha: opacity),
      };

  /// [backgroundFill] laid over black: the solid colour a video frame is
  /// filled with around and above the video.
  int get opaqueBackgroundArgb => Color.alphaBlend(backgroundFill, const Color(0xFF000000)).toARGB32();

  /// The style of the words at [fontSize] in [resolved] (the network's font
  /// when the choice is [TextCardFont.platform]), for a picture whose
  /// 1080-pixel unit is [unit].
  ///
  /// With a [customFont] that is loaded, the words are in that font, and what
  /// it lacks (emoji, other scripts) in [resolved] and the
  /// [kCaptionFontFallbacks]; until it is loaded (or where it is missing),
  /// in [resolved] alone.
  TextStyle textStyle(TextCardFont resolved, double fontSize, {double unit = 1}) {
    final color = Color(textColor);
    final alias = registeredCaptionFontAlias(customFont);
    final base = alias == null
        ? resolved.style(fontSize: fontSize, height: lineSpacing, color: color)
        : TextStyle(
            fontFamily: alias,
            fontFamilyFallback: [resolved.family, ...resolved.fallback, ...kCaptionFontFallbacks],
            fontWeight: FontWeight.w400,
            fontSize: fontSize,
            height: lineSpacing,
            color: color,
          );
    final darkWords = color.computeLuminance() < 0.4;
    return base.copyWith(
      fontWeight: bold ? FontWeight.w800 : null,
      fontVariations: bold && alias == null && resolved.variations.isNotEmpty ? const [FontVariation('wght', 800)] : null,
      shadows: shadow
          ? [Shadow(color: darkWords ? const Color(0xB3FFFFFF) : const Color(0xB3000000), blurRadius: 10 * unit, offset: Offset(0, 2 * unit))]
          : null,
    );
  }

  CaptionStyle copyWith({
    String? text,
    bool clearText = false,
    CaptionPlacement? placement,
    double? textScale,
    bool automaticSize = false,
    int? textColor,
    CaptionBackground? background,
    int? backgroundColor,
    double? opacity,
    TextCardAlignment? alignment,
    TextCardFont? font,
    bool? bold,
    bool? shadow,
    double? lineSpacing,
    double? padding,
    CaptionFont? customFont, // 1.3: cards
    bool clearCustomFont = false,
  }) =>
      CaptionStyle(
        text: clearText ? null : (text ?? this.text),
        placement: placement ?? this.placement,
        textScale: automaticSize ? null : (textScale ?? this.textScale),
        textColor: textColor ?? this.textColor,
        background: background ?? this.background,
        backgroundColor: backgroundColor ?? this.backgroundColor,
        opacity: opacity ?? this.opacity,
        alignment: alignment ?? this.alignment,
        font: font ?? this.font,
        bold: bold ?? this.bold,
        shadow: shadow ?? this.shadow,
        lineSpacing: lineSpacing ?? this.lineSpacing,
        padding: padding ?? this.padding,
        customFont: clearCustomFont ? null : (customFont ?? this.customFont), // 1.3: cards
      );

  /// Every field, so a recorded rendering never depends on later defaults.
  Map<String, dynamic> toJson() => {
        if (text != null) 'text': text,
        'placement': placement.name,
        if (textScale != null) 'textScale': textScale,
        'textColor': textColor,
        'background': background.name,
        'backgroundColor': backgroundColor,
        'opacity': opacity,
        'alignment': alignment.name,
        'font': font.name,
        'bold': bold,
        'shadow': shadow,
        'lineSpacing': lineSpacing,
        'padding': padding,
        // 1.3: cards. Only when set, so styles without one read as before.
        if (customFont != null) 'customFont': customFont!.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is CaptionStyle &&
      other.text == text &&
      other.placement == placement &&
      other.textScale == textScale &&
      other.textColor == textColor &&
      other.background == background &&
      other.backgroundColor == backgroundColor &&
      other.opacity == opacity &&
      other.alignment == alignment &&
      other.font == font &&
      other.bold == bold &&
      other.shadow == shadow &&
      other.lineSpacing == lineSpacing &&
      other.padding == padding &&
      other.customFont == customFont; // 1.3: cards

  @override
  int get hashCode => Object.hash(text, placement, textScale, textColor, background, backgroundColor, opacity, alignment, font, bold, shadow,
      lineSpacing, padding, customFont); // 1.3: cards
}
