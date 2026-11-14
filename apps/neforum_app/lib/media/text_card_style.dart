import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color, Size;

import 'text_card_background.dart' show TextCardBackground, TextCardTextColor, TextCardTextPosition;

/// 1.4.3: the shape of a classic text card. [automatic] is each network's
/// own frame, as cards always had (4:5 on Instagram, 9:16 on TikTok, square
/// elsewhere); the others are one shape for every network that shows it
/// whole. A network that cannot take the shape (TikTok's and the stories'
/// full-screen 9:16 frame) gets its own frame with the card inside it, never
/// a card cut to fit ([textCardFrameSize]).
enum TextCardShape {
  automatic("Network's own", null),
  square('Square 1:1', Size(1080, 1080)),
  landscape('Landscape 16:9', Size(1920, 1080)),

  /// The widest shape Instagram, Facebook and LinkedIn show without cutting
  /// it.
  wide('Landscape 1.91:1', Size(1910, 1000));

  const TextCardShape(this.label, this.size);
  final String label;

  /// The card's pixel size; null for each network's own.
  final Size? size;

  /// Width / height; null for each network's own.
  double? get aspect => size == null ? null : size!.width / size!.height;
}

/// 1.4.3: how a classic card is laid out.
enum TextCardLayout {
  /// The words on the whole card, as cards always were.
  full('Full card'),

  /// The words on a card with rounded corners, set in regular weight with
  /// room around them, on a slightly darker (or lighter) shade of the card's
  /// colour or on the background photo: the look of a quote shared as a
  /// picture.
  panel('Quote card');

  const TextCardLayout(this.label);
  final String label;
}

// 1.3.5: the classic text card's style, the "more editing power" of the text
// card editor: one value carried from the composer through the previews'
// stand-ins and the saved cards' render parameters to the painter, so what the
// master editor shows is exactly what every network receives.

/// Where a card's @handle sits: a corner, or the middle of the top or bottom
/// edge (1.3.5, as on Instagram's text posts).
enum TextCardHandlePosition {
  /// As cards had it before 1.3.5: at the bottom right beside the NEFORUM
  /// signature, at the bottom left on a plain card.
  automatic('Automatic'),
  bottomLeft('Bottom left'),
  bottomCenter('Bottom centre'),
  bottomRight('Bottom right'),
  topLeft('Top left'),
  topCenter('Top centre'),
  topRight('Top right');

  const TextCardHandlePosition(this.label);
  final String label;

  /// The place this choice puts the handle in on a card with ([branded]) or
  /// without the signature: [automatic] becomes the corner it always was.
  TextCardHandlePosition resolve({required bool branded}) =>
      this != automatic ? this : (branded ? bottomRight : bottomLeft);

  /// Above the words (on a resolved position).
  bool get isTop => this == topLeft || this == topCenter || this == topRight;

  /// Lined up on the right edge (on a resolved position).
  bool get isRight => this == bottomRight || this == topRight;

  /// In the middle of its edge (on a resolved position).
  bool get isCentre => this == bottomCenter || this == topCenter;
}

/// Where a classic card's words sit: the style's place, else (on a post
/// whose background photo chose one before 1.3.5) the photo's, else the
/// middle. The master editor and the background photo's "Words" controls
/// both show and set this one value ([TextCardStyle.textPosition]).
TextCardTextPosition textCardWordsPosition(TextCardStyle style, TextCardBackground? background) =>
    style.textPosition ?? background?.textPosition ?? TextCardTextPosition.center;

/// The words' own colour on a classic card (opaque ARGB): the style's, else
/// the white or black a background photo chose before 1.3.5; null for the
/// theme's colour, or over a photo white or black, whichever reads
/// ("Automatic"). One value for the master editor and the background photo's
/// "Words" controls ([TextCardStyle.textColor]).
int? textCardWordsColour(TextCardStyle style, TextCardBackground? background) =>
    style.textColor ??
    switch (background?.textColor) {
      TextCardTextColor.white => 0xFFFFFFFF,
      TextCardTextColor.black => 0xFF000000,
      _ => null,
    };

/// The contrast ratio of two colours (WCAG): 1 for the same colour, 21 for
/// black and white. Under 3 a card's words are hard to read on it.
double textCardContrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// How a classic text card is set, beyond its theme, font, alignment,
/// signature and background photo: the words' size, colour, line spacing and
/// place top to bottom, the card's colour and margins, and the @handle's
/// words, size, place and colour. Since 1.4.3 also the card's shape
/// ([TextCardShape]), its layout ([TextCardLayout]) and an attribution line
/// under the words.
///
/// [classic] (every field at its default) draws the card exactly as NEFORUM
/// 1.3.4 drew it, and writes nothing ([toJson] is empty): cards made before
/// 1.3.5, and cards nobody restyled, keep the render parameters they were
/// made with and are not made again. Each choice is written only while it
/// differs from its default, like [TextCardBackground]'s.
///
/// The style is the post's, the same on every network's card, as the theme
/// and font are; each network keeps its own shape, safe area, signature and
/// "Show @handle". It is kept as JSON in the composer's draft, on the saved
/// post's targets (`textCardStyle`, so a scheduled run makes the cards the way
/// they were saved even where no card existed yet) and in each card's render
/// parameters.
@immutable
class TextCardStyle {
  const TextCardStyle({
    this.textSize = 1,
    this.textColor,
    this.backgroundColor,
    this.textPosition,
    this.lineSpacing = defaultLineSpacing,
    this.margin = defaultMargin,
    this.handle,
    this.handleSize = 1,
    this.handlePosition = TextCardHandlePosition.automatic,
    this.handleColor,
    this.shape = TextCardShape.automatic, // 1.4.3: cards
    this.layout = TextCardLayout.full, // 1.4.3: cards
    this.attribution, // 1.4.3: cards
  });

  /// Every choice at its default: the card as it always was.
  static const TextCardStyle classic = TextCardStyle();

  static const double minTextSize = 0.5;
  static const double maxTextSize = 2;
  static const double defaultLineSpacing = 1.3;
  static const double minLineSpacing = 0.9;
  static const double maxLineSpacing = 2.2;

  /// Margins in pixels at 1080 wide; 92 is the card's own.
  static const double defaultMargin = 92;
  static const double minMargin = 24;
  static const double maxMargin = 240;
  static const double minHandleSize = 0.6;
  static const double maxHandleSize = 2.5;

  /// Longest @handle kept, in characters: a handle, a name or a short line.
  static const int maxHandleLength = 80;

  /// The words' size against the classic card's, [minTextSize] to
  /// [maxTextSize]. The classic card sets its words as large as fit (104
  /// pixels at 1080 wide at most, 30 at least); below 1 the fitted size is
  /// scaled down by this, above 1 the words grow by it as far as they still
  /// fit, so short words get bigger and long ones are never cut.
  final double textSize;

  /// ARGB of the words (opaque); null for the theme's (or, over a photo, the
  /// background's text colour).
  final int? textColor;

  /// ARGB of the card (opaque); null for the theme's. Over a photo it fills
  /// the room a whole photo leaves.
  final int? backgroundColor;

  /// Where the words sit top to bottom; null keeps the background photo's
  /// choice, else the middle.
  final TextCardTextPosition? textPosition;

  /// Line height as a multiple of the font size, [minLineSpacing] to
  /// [maxLineSpacing]; the card's own is 1.3.
  final double lineSpacing;

  /// Room between the card's edges and the words, the @handle and the
  /// footer, in pixels at 1080 wide ([minMargin] to [maxMargin]).
  final double margin;

  /// Words drawn instead of every network's own @handle; null for each
  /// network's own. Only drawn where the network shows the @handle ("Show
  /// @handle" stays the network's).
  final String? handle;

  /// The @handle's size against the card's own (26 pixels at 1080 wide),
  /// [minHandleSize] to [maxHandleSize].
  final double handleSize;
  final TextCardHandlePosition handlePosition;

  /// ARGB of the @handle (opaque); null for the words' colour, faded.
  final int? handleColor;

  /// 1.4.3: cards. The card's shape on every network that shows it whole;
  /// [TextCardShape.automatic] for each network's own.
  final TextCardShape shape;

  /// 1.4.3: cards. The whole card, or a quote card ([TextCardLayout.panel]).
  final TextCardLayout layout;

  /// 1.4.3: cards. A line under the words, in bold, such as "- Ada
  /// Lovelace": who said or wrote them. Null for none. Drawn as typed,
  /// lined up with the words, after a paragraph's space.
  final String? attribution;

  /// Longest attribution kept, in characters.
  static const int maxAttributionLength = 80;

  bool get isClassic => this == classic;

  /// Only the @handle's words: what applies to a card drawn from a card
  /// designer design, whose own blocks set everything else. A designed
  /// card's render parameters record only this, so a change it does not
  /// show never makes it again.
  TextCardStyle get handleOnly => handle == null ? classic : TextCardStyle(handle: handle);

  /// The words or the card have a colour of their own, not the theme's.
  bool get hasCardColours => textColor != null || backgroundColor != null;

  /// The @handle drawn on a network whose own is [own]: [handle] when set.
  String bylineFor(String own) => handle ?? own;

  /// [textColor] as a colour, or [fallback].
  Color textColorOr(Color fallback) => textColor == null ? fallback : Color(textColor!);

  /// [backgroundColor] as a colour, or [fallback].
  Color backgroundColorOr(Color fallback) => backgroundColor == null ? fallback : Color(backgroundColor!);

  /// A typed @handle as it is kept: trimmed, at most [maxHandleLength]
  /// characters, null when nothing is left.
  static String? cleanHandle(String? typed) => _clean(typed, maxHandleLength);

  /// A typed attribution as it is kept (1.4.3): one line, trimmed, at most
  /// [maxAttributionLength] characters, null when nothing is left.
  static String? cleanAttribution(String? typed) => _clean(typed?.replaceAll(RegExp(r'\s*\n\s*'), ' '), maxAttributionLength);

  static String? _clean(String? typed, int max) {
    final t = typed?.trim() ?? '';
    if (t.isEmpty) return null;
    final runes = t.runes;
    return runes.length <= max ? t : String.fromCharCodes(runes.take(max)).trimRight();
  }

  TextCardStyle copyWith({
    double? textSize,
    int? textColor,
    int? backgroundColor,
    TextCardTextPosition? textPosition,
    double? lineSpacing,
    double? margin,
    String? handle,
    double? handleSize,
    TextCardHandlePosition? handlePosition,
    int? handleColor,
    TextCardShape? shape, // 1.4.3: cards
    TextCardLayout? layout, // 1.4.3: cards
    String? attribution, // 1.4.3: cards
    bool clearTextColor = false,
    bool clearBackgroundColor = false,
    bool clearTextPosition = false,
    bool clearHandle = false,
    bool clearHandleColor = false,
    bool clearAttribution = false, // 1.4.3: cards
  }) =>
      TextCardStyle(
        shape: shape ?? this.shape,
        layout: layout ?? this.layout,
        attribution: clearAttribution ? null : (attribution == null ? this.attribution : cleanAttribution(attribution)),
        textSize: (textSize ?? this.textSize).clamp(minTextSize, maxTextSize),
        textColor: clearTextColor ? null : _opaque(textColor) ?? this.textColor,
        backgroundColor: clearBackgroundColor ? null : _opaque(backgroundColor) ?? this.backgroundColor,
        textPosition: clearTextPosition ? null : textPosition ?? this.textPosition,
        lineSpacing: (lineSpacing ?? this.lineSpacing).clamp(minLineSpacing, maxLineSpacing),
        margin: (margin ?? this.margin).clamp(minMargin, maxMargin),
        handle: clearHandle ? null : (handle == null ? this.handle : cleanHandle(handle)),
        handleSize: (handleSize ?? this.handleSize).clamp(minHandleSize, maxHandleSize),
        handlePosition: handlePosition ?? this.handlePosition,
        handleColor: clearHandleColor ? null : _opaque(handleColor) ?? this.handleColor,
      );

  /// This style with the words and the card back at the theme's colours:
  /// picking a theme ("White on black") means its colours. The @handle's own
  /// colour is a choice of the @handle, and stays.
  TextCardStyle withoutColours() => hasCardColours ? copyWith(clearTextColor: true, clearBackgroundColor: true) : this;

  /// The choices that differ from [classic]; empty for [classic]. The
  /// composer's draft, the post's targets and the cards' render parameters
  /// all keep this.
  Map<String, dynamic> toJson() => {
        if (textSize != 1) 'textSize': textSize,
        'textColor': ?textColor,
        'backgroundColor': ?backgroundColor,
        if (textPosition != null) 'textPosition': textPosition!.name,
        if (lineSpacing != defaultLineSpacing) 'lineSpacing': lineSpacing,
        if (margin != defaultMargin) 'margin': margin,
        'handle': ?handle,
        if (handleSize != 1) 'handleSize': handleSize,
        if (handlePosition != TextCardHandlePosition.automatic) 'handlePosition': handlePosition.name,
        'handleColor': ?handleColor,
        if (shape != TextCardShape.automatic) 'shape': shape.name, // 1.4.3: cards
        if (layout != TextCardLayout.full) 'layout': layout.name, // 1.4.3: cards
        'attribution': ?attribution, // 1.4.3: cards
      };

  /// The style [j] describes; [classic] when it is not a map. Values out of
  /// range are brought into it and unknown ones left at their default, so a
  /// style written by a newer NEFORUM still draws a card.
  static TextCardStyle fromJson(Object? j) {
    if (j is! Map) return classic;
    double number(Object? v, double fallback, double min, double max) => v is num && v.isFinite ? v.toDouble().clamp(min, max) : fallback;
    return TextCardStyle(
      textSize: number(j['textSize'], 1, minTextSize, maxTextSize),
      textColor: _opaque(j['textColor']),
      backgroundColor: _opaque(j['backgroundColor']),
      textPosition: TextCardTextPosition.values.asNameMap()[j['textPosition']],
      lineSpacing: number(j['lineSpacing'], defaultLineSpacing, minLineSpacing, maxLineSpacing),
      margin: number(j['margin'], defaultMargin, minMargin, maxMargin),
      handle: j['handle'] is String ? cleanHandle(j['handle'] as String) : null,
      handleSize: number(j['handleSize'], 1, minHandleSize, maxHandleSize),
      handlePosition: TextCardHandlePosition.values.asNameMap()[j['handlePosition']] ?? TextCardHandlePosition.automatic,
      handleColor: _opaque(j['handleColor']),
      shape: TextCardShape.values.asNameMap()[j['shape']] ?? TextCardShape.automatic, // 1.4.3: cards
      layout: TextCardLayout.values.asNameMap()[j['layout']] ?? TextCardLayout.full, // 1.4.3: cards
      attribution: j['attribution'] is String ? cleanAttribution(j['attribution'] as String) : null, // 1.4.3: cards
    );
  }

  static int? _opaque(Object? v) => v is int ? (v | 0xFF000000) & 0xFFFFFFFF : null;

  @override
  bool operator ==(Object other) =>
      other is TextCardStyle &&
      other.textSize == textSize &&
      other.textColor == textColor &&
      other.backgroundColor == backgroundColor &&
      other.textPosition == textPosition &&
      other.lineSpacing == lineSpacing &&
      other.margin == margin &&
      other.handle == handle &&
      other.handleSize == handleSize &&
      other.handlePosition == handlePosition &&
      other.handleColor == handleColor &&
      other.shape == shape &&
      other.layout == layout &&
      other.attribution == attribution;

  @override
  int get hashCode => Object.hash(
      textSize, textColor, backgroundColor, textPosition, lineSpacing, margin, handle, handleSize, handlePosition, handleColor, shape, layout, attribution);

  @override
  String toString() => 'TextCardStyle(${toJson()})';
}
