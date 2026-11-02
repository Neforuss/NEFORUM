import '../state/settings.dart' show TextCardAlignment;
import 'card_design.dart';
import 'card_templates.dart' show CardShape, cardTemplateById, kCardTemplateHandleSlots;
import 'text_card.dart' show TextCardFont;
import 'text_card_background.dart' show TextCardTextPosition;
import 'text_card_style.dart' show TextCardHandlePosition;

// 1.3.5: the text card editor's controls on a card designer design. When a
// design draws the post's cards (one picked for the post, or the Settings
// default), the master editor's size, colour, line spacing, place and margin
// controls edit that design itself, so the designer (Design card…), every
// network's card and the saved cards all show one look. The words, the
// @handle and the signature are found by their block's role, so the edits
// work on every template and on designs of the user's own. The classic
// card's own style (TextCardStyle) is left as it is, for when the design is
// turned off.

/// The words' sizes the editor offers on a design, in pixels at 1080 wide.
const double kDesignWordsSizeMin = 24;
const double kDesignWordsSizeMax = 240;

/// The @handle's sizes it offers, in pixels at 1080 wide.
const double kDesignHandleSizeMin = 14;
const double kDesignHandleSizeMax = 96;

/// The margins it offers, in pixels at 1080 wide: never edge to edge (the
/// classic card's floor too); a network's safe area comes on top.
const double kDesignMarginMin = 24;
const double kDesignMarginMax = 240;

/// The line spacings it offers, as a multiple of the words' size.
const double kDesignLineHeightMin = 0.9;
const double kDesignLineHeightMax = 2.2;

/// The @handle places a design offers: the corners and the middles of the
/// top and bottom edges ([TextCardHandlePosition.automatic] is the classic
/// card's own).
const List<TextCardHandlePosition> kDesignHandlePositions = [
  TextCardHandlePosition.bottomLeft,
  TextCardHandlePosition.bottomCenter,
  TextCardHandlePosition.bottomRight,
  TextCardHandlePosition.topLeft,
  TextCardHandlePosition.topCenter,
  TextCardHandlePosition.topRight,
];

/// The anchor a design's @handle goes to for [p]; automatic is the classic
/// card's bottom right.
CardAnchor cardAnchorOfHandlePosition(TextCardHandlePosition p) => switch (p) {
      TextCardHandlePosition.bottomLeft => CardAnchor.bottomLeft,
      TextCardHandlePosition.bottomCenter => CardAnchor.bottomCenter,
      TextCardHandlePosition.topLeft => CardAnchor.topLeft,
      TextCardHandlePosition.topCenter => CardAnchor.topCenter,
      TextCardHandlePosition.topRight => CardAnchor.topRight,
      TextCardHandlePosition.bottomRight || TextCardHandlePosition.automatic => CardAnchor.bottomRight,
    };

/// The words lined up to the side of [anchor]: left, centred or right.
TextCardAlignment cardAlignmentAt(CardAnchor anchor) => switch (anchor.x) {
      0.0 => TextCardAlignment.left,
      1.0 => TextCardAlignment.right,
      _ => TextCardAlignment.center,
    };

/// The design a post's cards are drawn from (1.3.5): [design], with a
/// @handle block added when a @handle is written ([handle]) but the design
/// has none (Gradient wave, Vinyl, Neon, Sunset), so what is typed is on
/// every card. The block goes in the template's declared free slot and is
/// placed clear of its pictures and blocks when drawn
/// ([CardDesignEdits.withHandleBlock]); a design that has one is unchanged.
CardDesign designWithHandle(CardDesign design, String? handle) => handle != null && design.handleBlock == null ? design.withHandleBlock() : design;

extension CardDesignEdits on CardDesign {
  int _index(CardBlockRole role) => blocks.indexWhere((b) => b.role == role);
  CardTextBlock? _block(CardBlockRole role) {
    final i = _index(role);
    return i < 0 ? null : blocks[i];
  }

  /// The block of the post's words (the first); null when the design has
  /// none, and the editor's words controls are then left out.
  CardTextBlock? get wordsBlock => _block(CardBlockRole.postText);

  /// The block of the @handle; null when the design has none (Bold poster,
  /// Vinyl...): the @handle controls add one.
  CardTextBlock? get handleBlock => _block(CardBlockRole.handle);

  /// The block of the NEFORUM signature, if any.
  CardTextBlock? get signatureBlock => _block(CardBlockRole.signature);

  CardDesign _withWords(CardTextBlock Function(CardTextBlock b) change) {
    final i = _index(CardBlockRole.postText);
    return i < 0 ? this : withBlock(i, change);
  }

  // The words.

  /// The size the words start at, in pixels at 1080 wide (a block that fits
  /// itself shrinks from it to fit).
  double get wordsSize => wordsBlock?.size ?? 96;
  CardDesign withWordsSize(double size) => _withWords((b) => b.copyWith(size: size.clamp(kDesignWordsSizeMin, kDesignWordsSizeMax).roundToDouble()));

  /// The words' colour (ARGB).
  int get wordsColor => wordsBlock?.color ?? 0xFFFFFFFF;

  /// The words in [argb] (each block keeps its own opacity). Blocks drawn in
  /// the words' colour (a template's @handle or signature, often fainter)
  /// change with them; blocks in a colour of their own keep it.
  CardDesign withWordsColor(int argb) {
    if (wordsBlock == null) return this;
    final before = wordsColor & 0xFFFFFF;
    final rgb = argb & 0xFFFFFF;
    return copyWith(blocks: [
      for (final b in blocks)
        if (b.role == CardBlockRole.postText || (b.color & 0xFFFFFF) == before) b.copyWith(color: (b.color & 0xFF000000) | rgb) else b,
    ]);
  }

  /// The words' line spacing, a multiple of their size.
  double get wordsLineHeight => wordsBlock?.lineHeight ?? 1.25;
  CardDesign withWordsLineHeight(double lineHeight) =>
      _withWords((b) => b.copyWith(lineHeight: (lineHeight.clamp(kDesignLineHeightMin, kDesignLineHeightMax) * 100).round() / 100));

  /// Where the words sit, top to bottom.
  TextCardTextPosition get wordsPosition => switch (wordsBlock?.anchor.y) {
        0.0 => TextCardTextPosition.top,
        1.0 => TextCardTextPosition.bottom,
        _ => TextCardTextPosition.center,
      };

  /// The words at the top, in the middle or at the bottom ([position]),
  /// placed by the editor ([CardDesign.placeWords]): when a card is drawn
  /// they go in the band of the frame their row names that no picture of
  /// the template (the record or framed photo when drawn, the waveform) and
  /// no other block crosses: the topmost such band for Top, the lowest for
  /// Bottom, the tallest for Middle (centred in it), and they are fitted to
  /// that band once. Moved by no offset, with the template's room. The
  /// template's own blocks are not touched: they stay where it puts them.
  CardDesign withWordsPosition(TextCardTextPosition position) {
    final words = wordsBlock;
    if (words == null) return this;
    final row = switch (position) {
      TextCardTextPosition.top => 0,
      TextCardTextPosition.center => 1,
      TextCardTextPosition.bottom => 2,
    };
    // The template's own room for the words (a design changed by an
    // earlier 1.3.5 build may have had it cut for a cover).
    final room = cardTemplateById(template ?? '')?.design(kind).wordsBlock?.maxHeight ?? words.maxHeight;
    return _withWords((b) => b.copyWith(anchor: CardAnchor.values[row * 3 + words.anchor.index % 3], offsetY: 0, maxHeight: room)).copyWith(placeWords: true);
  }

  // The card.

  /// Whether the card has a colour of its own to change: not a photo.
  bool get cardColorEditable => background.kind != CardFillKind.image;

  /// The card's colour: its plain colour, or a gradient's first stop.
  int get cardColor => background.kind == CardFillKind.linear || background.kind == CardFillKind.radial ? background.colors.first : background.color;

  /// A plain [argb] card, in place of a gradient; a pattern, grain or
  /// vignette stays over it.
  CardDesign withCardColor(int argb) => copyWith(background: background.copyWith(kind: CardFillKind.solid, color: argb | 0xFF000000));

  /// Room around everything, in pixels at 1080 wide.
  CardDesign withMargin(double margin) => copyWith(margin: margin.clamp(kDesignMarginMin, kDesignMarginMax).roundToDouble());

  // The @handle.

  /// This design with its @handle block changed; a design without one gets
  /// one first ([withHandleBlock]).
  CardDesign _withHandle(CardTextBlock Function(CardTextBlock b) change) {
    final d = handleBlock == null ? withHandleBlock() : this;
    return d.withBlock(d._index(CardBlockRole.handle), change);
  }

  /// This design with a classic-looking @handle (the words' colour, faded,
  /// 28 px, in the words' font) in the template's declared free slot
  /// ([kCardTemplateHandleSlots]: Vinyl top right beside the record, Gradient
  /// wave bottom left, Neon bottom centre, Sunset top left; one slot for
  /// every card shape, so the square entry is the slot); a design of the
  /// user's own gets the bottom corner its signature leaves free. The block
  /// is added on the end and the template's blocks are not touched (1.3.5
  /// round 5: no stacking, no reorder, no signature swap); the renderer then
  /// places it in that edge's free band ([CardDesign.placeHandle]).
  /// Unchanged when it has one.
  CardDesign withHandleBlock() {
    if (handleBlock != null) return this;
    final words = wordsBlock, signature = signatureBlock;
    // The template's declared free slot; for a design of the user's own, a
    // bottom corner the signature leaves free.
    final anchor = kCardTemplateHandleSlots[template]?[CardShape.square] ??
        (signature?.anchor == CardAnchor.bottomRight ? CardAnchor.bottomLeft : CardAnchor.bottomRight);
    final added = CardTextBlock(
      role: CardBlockRole.handle,
      anchor: anchor,
      font: words?.font ?? TextCardFont.original,
      size: 28,
      weight: 500,
      color: (wordsColor & 0xFFFFFF) | 0x9E000000,
      alignment: cardAlignmentAt(anchor),
      maxLines: 1,
      maxHeight: 0.4,
    );
    // Placed by the editor: in the free band of its slot's edge, clear of
    // the pictures and of every block the template has, which stay put.
    return copyWith(blocks: [...blocks, added], placeHandle: true);
  }

  /// The @handle's size, in pixels at 1080 wide.
  double get handleSize => handleBlock?.size ?? 28;
  CardDesign withHandleSize(double size) => _withHandle((b) => b.copyWith(size: size.clamp(kDesignHandleSizeMin, kDesignHandleSizeMax).roundToDouble()));

  /// The @handle's colour (ARGB).
  int get handleColor => handleBlock?.color ?? ((wordsColor & 0xFFFFFF) | 0x9E000000);

  /// The @handle in [argb], as picked (opaque).
  CardDesign withHandleColor(int argb) => _withHandle((b) => b.copyWith(color: argb | 0xFF000000));

  /// The @handle in the words' colour, faded as the classic card's is.
  CardDesign withHandleColorLikeWords() => _withHandle((b) => b.copyWith(color: (wordsColor & 0xFFFFFF) | 0x9E000000));

  /// Where the @handle sits; null when it is not on the top or bottom edge
  /// (a design's own place, which the editor's chips do not name).
  TextCardHandlePosition? get handlePosition {
    final a = handleBlock?.anchor ?? CardAnchor.bottomRight;
    return switch (a) {
      CardAnchor.bottomLeft => TextCardHandlePosition.bottomLeft,
      CardAnchor.bottomCenter => TextCardHandlePosition.bottomCenter,
      CardAnchor.bottomRight => TextCardHandlePosition.bottomRight,
      CardAnchor.topLeft => TextCardHandlePosition.topLeft,
      CardAnchor.topCenter => TextCardHandlePosition.topCenter,
      CardAnchor.topRight => TextCardHandlePosition.topRight,
      _ => null,
    };
  }

  /// The @handle at [position], lined up to that side and moved by no
  /// offset, placed by the editor ([CardDesign.placeHandle]): when a card is
  /// drawn it goes in the free band of that edge (the topmost for a top
  /// place, the lowest for a bottom one), clear of the template's pictures
  /// and of every other block. The template's own blocks (the signature, the
  /// words) are not moved for it.
  CardDesign withHandlePosition(TextCardHandlePosition position) {
    final to = cardAnchorOfHandlePosition(position);
    return _withHandle((b) => b.copyWith(anchor: to, offsetX: 0, offsetY: 0, alignment: cardAlignmentAt(to))).copyWith(placeHandle: true);
  }
}
