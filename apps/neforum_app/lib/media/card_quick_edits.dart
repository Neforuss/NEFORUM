import '../state/settings.dart' show TextCardAlignment;
import 'caption_fonts.dart';
import 'card_design.dart';
import 'card_templates.dart';
import 'text_card.dart' show TextCardFont, TextCardTheme;
import 'text_card_background.dart' show TextCardTextPosition;

// 1.3.5: the master editor as a quick designer. Each control of "Text card
// for every network" is one edit of the post's text card design, written
// here as plain functions of a design so the control, the saved card and
// the tests share them: the composer applies them to the post's design, or
// to the classic card as a design (classicTextCardDesign) when the post has
// none yet. The words, the @handle and the signature are found by their
// block's role, so the edits work on any template's design too.

/// The text sizes the master editor offers, in pixels at 1080 wide: from
/// well under the classic card's 104 to more than twice it.
const double kQuickWordsSizeMin = 40;
const double kQuickWordsSizeMax = 240;

/// The line spacing it offers, as a multiple of the text size.
const double kQuickLineHeightMin = 0.9;
const double kQuickLineHeightMax = 2.2;

/// The margins it offers, in pixels at 1080 wide.
const double kQuickMarginMin = 0;
const double kQuickMarginMax = 200;

/// The @handle sizes it offers, in pixels at 1080 wide.
const double kQuickHandleSizeMin = 16;
const double kQuickHandleSizeMax = 80;

/// The places the master editor offers the @handle: the corners and the
/// middles of the top and bottom edges.
const List<CardAnchor> kQuickHandleAnchors = [
  CardAnchor.topLeft,
  CardAnchor.topCenter,
  CardAnchor.topRight,
  CardAnchor.bottomLeft,
  CardAnchor.bottomCenter,
  CardAnchor.bottomRight,
];

extension CardQuickEdits on CardDesign {
  int _indexOf(CardBlockRole role) => blocks.indexWhere((b) => b.role == role);
  CardTextBlock? _block(CardBlockRole role) {
    final i = _indexOf(role);
    return i < 0 ? null : blocks[i];
  }

  /// The block of the post's words (the first, when there are more); null
  /// when the design has none.
  CardTextBlock? get wordsBlock => _block(CardBlockRole.postText);

  /// The block of the @handle; null when the design has none.
  CardTextBlock? get handleBlock => _block(CardBlockRole.handle);

  /// The block of the NEFORUM signature; null when the design has none.
  CardTextBlock? get signatureBlock => _block(CardBlockRole.signature);

  /// This design with its words block changed; a design without one gets
  /// the classic card's words first, in front of its other blocks.
  CardDesign withWords(CardTextBlock Function(CardTextBlock b) change) {
    final i = _indexOf(CardBlockRole.postText);
    if (i >= 0) return withBlock(i, change);
    final words = classicTextCardDesign().wordsBlock!.copyWith(color: wordsColor);
    return copyWith(blocks: [change(words), ...blocks]);
  }

  /// This design with its @handle block changed; a design without one
  /// (Vinyl, Neon...) gets the classic card's, in the words' colour.
  CardDesign withHandle(CardTextBlock Function(CardTextBlock b) change) {
    final i = _indexOf(CardBlockRole.handle);
    if (i >= 0) return withBlock(i, change);
    return copyWith(blocks: [...blocks, change(classicHandleBlock(ink: wordsColor))]);
  }

  // The words.

  /// The size the words start at (they shrink to fit when they have to).
  double get wordsSize => wordsBlock?.size ?? kClassicWordsSize;
  CardDesign withWordsSize(double size) => withWords((b) => b.copyWith(size: size.clamp(12.0, 320.0).roundToDouble()));

  /// The words' colour (ARGB); white without a words block.
  int get wordsColor => wordsBlock?.color ?? 0xFFFFFFFF;

  /// The words in [argb] (opaque; each block keeps its own opacity). Blocks
  /// drawn in the words' colour before (the classic card's @handle and
  /// signature) change with them; blocks in a colour of their own (a
  /// template's second colour) keep it.
  CardDesign withWordsColor(int argb) {
    final before = wordsColor & 0xFFFFFF;
    final rgb = argb & 0xFFFFFF;
    final hasWords = wordsBlock != null;
    final d = hasWords ? this : withWords((b) => b);
    return d.copyWith(blocks: [
      for (final b in d.blocks)
        if (b.role == CardBlockRole.postText || (b.color & 0xFFFFFF) == before) b.copyWith(color: (b.color & 0xFF000000) | rgb) else b,
    ]);
  }

  /// Where the words sit, top to bottom.
  TextCardTextPosition get wordsPosition => switch (wordsBlock?.anchor.y) {
        0.0 => TextCardTextPosition.top,
        1.0 => TextCardTextPosition.bottom,
        _ => TextCardTextPosition.center,
      };

  /// The words at the top, in the middle or at the bottom (moved by no
  /// offset), keeping clear of the @handle and the signature
  /// ([CardDesign.keepClear]) wherever they go.
  CardDesign withWordsPosition(TextCardTextPosition position) {
    final row = switch (position) {
      TextCardTextPosition.top => 0,
      TextCardTextPosition.center => 1,
      TextCardTextPosition.bottom => 2,
    };
    return withWords((b) => b.copyWith(anchor: CardAnchor.values[row * 3 + b.anchor.index % 3], offsetY: 0)).copyWith(keepClear: true);
  }

  /// The words' line spacing, a multiple of their size.
  double get wordsLineHeight => wordsBlock?.lineHeight ?? kClassicLineHeight;
  CardDesign withWordsLineHeight(double lineHeight) => withWords((b) => b.copyWith(lineHeight: (lineHeight.clamp(0.8, 2.5) * 100).round() / 100));

  /// The words in [font] (a built-in one, with its own weight and spacing).
  CardDesign withWordsFont(TextCardFont font) =>
      withWords((b) => b.copyWith(font: font, clearCustomFont: true, weight: font.weight.value, letterSpacing: font.tracking));

  /// The words in an installed or imported [font], at its regular weight.
  CardDesign withWordsCustomFont(CaptionFont font) => withWords((b) => b.copyWith(customFont: font, weight: 400, letterSpacing: 0));

  /// The words lined up by [alignment].
  CardDesign withWordsAlignment(TextCardAlignment alignment) => withWords((b) => b.copyWith(alignment: alignment));

  // The card.

  /// The background's colour: its plain colour, a gradient's first stop, or
  /// the colour under a photo.
  int get backgroundColor => background.kind == CardFillKind.linear || background.kind == CardFillKind.radial ? background.colors.first : background.color;

  /// Whether the background is the post's photo.
  bool get backgroundIsPhoto => background.kind == CardFillKind.image;

  /// A plain [argb] background, in place of a gradient or photo; a pattern,
  /// grain or vignette stays over it.
  CardDesign withBackgroundColor(int argb) => copyWith(background: background.copyWith(kind: CardFillKind.solid, color: argb | 0xFF000000));

  /// [theme]'s colours: its words on its background.
  CardDesign withTheme(TextCardTheme theme) => withWordsColor(theme.foreground.toARGB32()).withBackgroundColor(theme.background.toARGB32());

  /// Whether the words and background are [theme]'s.
  bool hasTheme(TextCardTheme theme) =>
      !backgroundIsPhoto && (wordsColor & 0xFFFFFF) == (theme.foreground.toARGB32() & 0xFFFFFF) && (backgroundColor & 0xFFFFFF) == (theme.background.toARGB32() & 0xFFFFFF);

  /// Room around everything, in pixels at 1080 wide.
  CardDesign withQuickMargin(double margin) => copyWith(margin: margin.clamp(0.0, 240.0).roundToDouble());

  // The @handle.

  /// The @handle's size.
  double get handleSize => handleBlock?.size ?? kClassicHandleSize;
  CardDesign withHandleSize(double size) => withHandle((b) => b.copyWith(size: size.clamp(12.0, 320.0).roundToDouble()));

  /// Where the @handle sits.
  CardAnchor get handleAnchor => handleBlock?.anchor ?? CardAnchor.bottomRight;

  /// The @handle at [anchor], lined up to that side and moved by no offset,
  /// the words keeping clear of it ([CardDesign.keepClear]). Put where the
  /// signature is, the two trade places rather than stack.
  CardDesign withHandleAnchor(CardAnchor anchor) {
    final from = handleAnchor;
    var d = withHandle((b) => b.copyWith(anchor: anchor, offsetX: 0, offsetY: 0, alignment: cardAlignmentAt(anchor)));
    final s = d._indexOf(CardBlockRole.signature);
    if (s >= 0 && from != anchor && d.blocks[s].anchor == anchor) {
      d = d.withBlock(s, (b) => b.copyWith(anchor: from, offsetX: 0, offsetY: 0, alignment: cardAlignmentAt(from)));
    }
    return d.copyWith(keepClear: true);
  }
}
