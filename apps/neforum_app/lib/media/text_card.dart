import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart' show Bidi;
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../brand/neforum_logo.dart';
import '../state/settings.dart' show TextCardAlignment;
import '../theme/tokens.dart';
import 'aligned_text.dart';
import 'caption_fonts.dart';
import 'card_design.dart';
import 'emoji_text.dart';
import 'photo_composite.dart';
import 'render_parameters.dart';
import 'text_card_background.dart';
import 'text_card_style.dart';

export 'text_card_style.dart';

/// NEFORUM text cards: a text-only post rendered as an image for platforms
/// that refuse posts without one (Instagram, Pinterest, TikTok photo posts,
/// Snapchat).
///
/// By default every card has the same signature so people recognise it
/// anywhere: a purple rule along the top with a yellow tab, the words set
/// large (in Inter, or Times New Roman or Arial, see [TextCardFont], or since
/// 1.3.1 any installed or imported font, see [CaptionFont]) on plain black or
/// white, and a footer with the NEFORUM
/// mark, the wordmark and the author. The signature is optional per network
/// (Settings > Text cards, or per post under the preview): a plain card keeps
/// only the words and the author, and the author's @handle is optional too.
/// The words can be aligned five ways ([TextCardAlignment]) and set over a
/// photo instead of a plain colour ([TextCardBackground]). Since 1.3.5 the
/// words' size, colour, line spacing and place, the card's colour and
/// margins, and the @handle's words, size, place and colour can be set too
/// ([TextCardStyle]); untouched, a card is drawn exactly as before.
///
/// Every choice a card was made with is recorded in its
/// [MediaAttachment.renderParameters] ([textCardRenderParameters]); cards made
/// before 1.2.0 carry their theme, font, signature and safe area as markers in
/// the file name, which the readers below still understand.
enum TextCardTheme {
  dark('White on black', Color(0xFF000000), Color(0xFFFFFFFF)),
  light('Black on white', Color(0xFFFFFFFF), Color(0xFF000000));

  const TextCardTheme(this.label, this.background, this.foreground);
  final String label;
  final Color background;
  final Color foreground;
}

/// Typeface for a card's words. The NEFORUM wordmark in the signature always
/// keeps its own font.
///
/// TikTok Sans ships with NEFORUM (SIL Open Font License). Instagram Sans is
/// Instagram's own and not freely licensed: it is used when installed on the
/// device, otherwise the closest common sans. Times New Roman and Arial come
/// with Windows, macOS and iOS; elsewhere the closest installed face is used
/// (Liberation or Noto on Linux and Android).
enum TextCardFont {
  original('NEFORUM (Inter)', Fonts.body, [], FontWeight.w600, -0.012),

  /// Picks each network's own font: TikTok Sans on TikTok, Instagram Sans on
  /// Instagram, NEFORUM's elsewhere (see [resolve]).
  platform("Each network's own", Fonts.body, [], FontWeight.w600, -0.012),
  tiktokSans('TikTok Sans', 'TikTok Sans', [Fonts.body], FontWeight.w700, -0.01, [FontVariation('wght', 700)]),
  // No plain "Helvetica": on Windows that name can match a condensed face.
  instagramSans('Instagram Sans', 'Instagram Sans', ['Instagram Sans Headline', 'Helvetica Neue', 'Arial', 'Roboto'],
      FontWeight.w700, -0.01),
  timesNewRoman('Times New Roman', 'Times New Roman', ['Times', 'Liberation Serif', 'Tinos', 'Noto Serif', 'serif'], FontWeight.w400, 0),
  arial('Arial', 'Arial', ['Helvetica', 'Liberation Sans', 'Arimo', 'Roboto', 'sans-serif'], FontWeight.w700, 0);

  const TextCardFont(this.label, this.family, this.fallback, this.weight, this.tracking, [this.variations = const []]);
  final String label;
  final String family;
  final List<String> fallback;
  final FontWeight weight;

  /// Letter spacing as a fraction of the font size.
  final double tracking;

  /// Axis settings for variable fonts (TikTok Sans).
  final List<FontVariation> variations;

  /// How a card made with this font is marked in its file name and path.
  String get marker => this == original ? '' : 'font-$name';

  /// The font actually drawn on [platformId]: [platform] becomes that
  /// network's own; every other choice is itself.
  TextCardFont resolve(String? platformId) => this != platform
      ? this
      : switch (platformId) {
          'tiktok' => tiktokSans,
          'instagram' => instagramSans,
          _ => original,
        };

  TextStyle style({required double fontSize, double? height, Color? color}) => TextStyle(
        fontFamily: family,
        fontFamilyFallback: [...fallback, ...kCaptionFontFallbacks],
        fontWeight: weight,
        fontVariations: variations,
        fontSize: fontSize,
        height: height,
        letterSpacing: tracking * fontSize,
        color: color,
      );
}

/// Room a network's own buttons and captions take over a full-screen (9:16)
/// photo or card, in pixels at 1080 wide: words are kept out of it so they
/// are not hidden. TikTok: the search bar on top, the like/comment/share
/// column on the right, the name, caption and sound at the bottom.
EdgeInsets fullScreenSafeArea(String platformId) => switch (platformId) {
      'tiktok' => const EdgeInsets.fromLTRB(0, 240, 150, 440),
      'instagram' => const EdgeInsets.fromLTRB(0, 220, 120, 360),
      'snapchat' => const EdgeInsets.fromLTRB(0, 200, 0, 320),
      _ => EdgeInsets.zero,
    };

/// Pixel size of the card: each platform's preferred portrait frame, or the
/// full-screen 9:16 frame for a [story].
Size textCardSize(String platformId, {bool story = false}) => story
    ? const Size(1080, 1920)
    : switch (platformId) {
        'instagram' => const Size(1080, 1350),
        'pinterest' => const Size(1000, 1500),
        'tiktok' || 'snapchat' => const Size(1080, 1920),
        _ => const Size(1080, 1080),
      };

/// 1.4.3: cards. The pixel size of the picture [platformId] gets for a card
/// of [shape]: the card's own size ([TextCardShape.size]) where the network
/// shows it whole, else a frame the network takes with the whole card drawn
/// inside it ([TextCardPainter.cardRect]). Never a card cut to fit.
///
/// - Each network's own shape ([TextCardShape.automatic]) is [textCardSize],
///   as before.
/// - A [story] is always the full-screen 9:16 frame, and so is Snapchat.
///   TikTok is too while Settings fit its photos to the whole frame
///   ([fillsFrame], Settings > Posting); without that TikTok gets the card
///   as it is and shows it whole on black, as it does such photos.
/// - A network whose photo rules refuse the shape ([minAspect] to
///   [maxAspect], width / height, from `PlatformAdapter.photoFit`) gets the
///   nearest shape they take, the card with room added around it, as
///   "Fit photos" adds borders to a photo. Instagram's feed takes 0.8 to
///   1.91, so both landscapes go to it as they are.
Size textCardFrameSize(String platformId,
    {bool story = false, TextCardShape shape = TextCardShape.automatic, bool fillsFrame = true, double? minAspect, double? maxAspect}) {
  final own = textCardSize(platformId, story: story);
  final card = shape.size;
  if (card == null || story) return own;
  final fullScreen = own.width / own.height < 0.62;
  if (fullScreen && (platformId != 'tiktok' || fillsFrame)) return own;
  final r = card.width / card.height;
  if (minAspect != null && r < minAspect - PhotoFit.aspectTolerance) return Size((card.height * minAspect).roundToDouble(), card.height);
  if (maxAspect != null && r > maxAspect + PhotoFit.aspectTolerance) return Size(card.width, (card.width / maxAspect).roundToDouble());
  return card;
}

/// 1.4.3: cards. What [network] gets when its picture ([frame], from
/// [textCardFrameSize]) is not the card's [shape]: "TikTok gets a 9:16
/// picture with your 16:9 card whole inside it". Null when the network gets
/// the card as it is, or the card is each network's own shape.
String? textCardFrameNote(String network, TextCardShape shape, Size frame) {
  final aspect = shape.aspect;
  if (aspect == null || frame.height <= 0) return null;
  final framed = frame.width / frame.height;
  if ((framed - aspect).abs() <= 0.02) return null;
  return '$network gets a ${PhotoFit.ratioLabel(framed)} picture with your ${PhotoFit.ratioLabel(aspect)} card whole inside it';
}

/// The safe area of [platformId]'s card: only full-screen (9:16) cards
/// (TikTok, Snapchat, stories) have the network's buttons over them. [size]
/// (1.4.3) is the card's when it is not the network's own
/// ([textCardFrameSize]).
EdgeInsets textCardSafeArea(String platformId, {bool story = false, Size? size}) {
  final s = size ?? textCardSize(platformId, story: story);
  return s.width / s.height < 0.62 ? fullScreenSafeArea(platformId) : EdgeInsets.zero;
}

/// 1.4.3: cards. The colour around a card drawn inside a larger frame, or
/// around a quote card ([TextCardLayout.panel]) without a background photo:
/// the card's own colour, a little darker for a light card and a little
/// lighter for a dark one, so the card's edge shows without a second
/// colour to choose.
Color textCardSurroundColour(Color card) =>
    card.computeLuminance() > 0.5 ? Color.lerp(card, const Color(0xFF000000), 0.09)! : Color.lerp(card, const Color(0xFFFFFFFF), 0.14)!;

/// The size a card or placeholder [m] was made at; [textCardSize] for cards
/// that do not record it.
Size textCardSizeOf(MediaAttachment m, String platformId) {
  final w = m.width;
  final h = m.height;
  return w != null && h != null && w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : textCardSize(platformId);
}

/// True when the story [v] places on [d] (a Story, or the story of Post +
/// Story) has words and no photo or video of its own: it then gets a 9:16
/// card. A story whose only file is the card's background
/// ([backgroundMediaId]) qualifies too. Call only for accounts that take
/// stories (`PlatformAdapter.supportsStories`).
bool storyQualifiesForTextCard(PlatformDescriptor d, PostVariant v, {String? backgroundMediaId}) {
  if (d.isArtPlatform || !v.placement.includesStory) return false;
  if (d.media.maxImages == 0 || !d.media.imageMimeTypes.contains('image/jpeg')) return false;
  final frames = v.storyFrames;
  final noMedia = frames.isEmpty || (backgroundMediaId != null && frames.length == 1 && frames.single.id == backgroundMediaId);
  return noMedia && v.text.trim().isNotEmpty;
}

/// True when the variant has words and no media and [d] gets a card for it:
/// [d] cannot take a text-only post but accepts a JPEG, or, with
/// [everyNetwork] (the same card on every network, 1.3), [d] takes JPEG
/// images at all. A variant whose only photo is the card's background
/// ([backgroundMediaId], one of the post's own photos) qualifies too: the
/// card takes the photo's place.
///
/// On a network where the card is a choice ([kTextCardChoicePlatforms],
/// YouTube Posts), a words-only post goes as text only when the post says so
/// ([kTextCardChoiceKey] `text`), with a card when it says `card`, and
/// otherwise with a card exactly when the post makes one for another network
/// ([postMakesCard]).
bool qualifiesForTextCard(PlatformDescriptor d, PostVariant v, {String? backgroundMediaId, bool everyNetwork = false, bool postMakesCard = false}) {
  final noMedia = v.media.isEmpty || (backgroundMediaId != null && v.media.length == 1 && v.media.single.id == backgroundMediaId);
  if (!noMedia || v.text.trim().isEmpty) return false;
  if (kTextCardChoicePlatforms.contains(d.id)) {
    if (!acceptsTextCardImages(d)) return false;
    return switch (textCardChoiceOf(v.extra)) {
      TextCardChoice.text => false,
      TextCardChoice.card => true,
      null => everyNetwork || postMakesCard,
    };
  }
  return takesTextCards(d, everyNetwork: everyNetwork);
}

/// Networks where a words-only post can go as text or with the post's text
/// card (1.4.1): YouTube Posts, whose post box takes either.
const Set<String> kTextCardChoicePlatforms = {'youtube_posts'};

/// `PostOverrides.extra` key of that choice ([TextCardChoice.name]).
const String kTextCardChoiceKey = 'textCardChoice';

/// A words-only post on a [kTextCardChoicePlatforms] network.
enum TextCardChoice {
  /// With the text card (as an image of the words).
  card,

  /// The words alone.
  text,
}

/// The choice in a target's [extra] knobs; null to follow the post.
TextCardChoice? textCardChoiceOf(Map<String, dynamic> extra) => TextCardChoice.values.asNameMap()[extra[kTextCardChoiceKey]];

/// Whether [d] is a network that gets text cards at all, whatever the post
/// holds: it needs an image and takes a JPEG, or, with [everyNetwork], it
/// takes JPEG images ([acceptsTextCardImages]).
bool takesTextCards(PlatformDescriptor d, {bool everyNetwork = false}) =>
    acceptsTextCardImages(d) && (everyNetwork || d.media.requiresMedia);

/// Whether a card can go to [d] at all: it takes JPEG images
/// ([MediaRules.maxImages] > 0) and is not an art site, which receives the
/// artist's own images only, never a card of words.
bool acceptsTextCardImages(PlatformDescriptor d) =>
    !d.isArtPlatform && d.media.maxImages > 0 && d.media.imageMimeTypes.contains('image/jpeg');

/// The words on the card: the post as written (every part with words in it,
/// joined with blank lines, as networks without threads receive it) or the
/// network's own version, without trailing lines that are only hashtags or
/// links; those belong in the caption.
String textCardText(Post post, PostTarget target) {
  final written = target.overrides.text ??
      [
        for (final p in post.parts)
          if (p.trim().isNotEmpty) p.trimRight(),
      ].join('\n\n');
  return withoutTrailingTagsAndLinks(written);
}

/// [text] without its trailing lines that are only hashtags or links (those
/// belong in the caption); a text that is nothing else keeps its first line.
String withoutTrailingTagsAndLinks(String text) {
  final lines = text.trim().split('\n');
  final tagOrLink = RegExp(r'^(\s*(#[\p{L}\p{N}_]+|https?://\S+)\s*)+$', unicode: true);
  while (lines.length > 1 && (lines.last.trim().isEmpty || tagOrLink.hasMatch(lines.last))) {
    lines.removeLast();
  }
  return lines.join('\n').trim();
}

/// Alt text for a card: the card's own words (platform alt limits are
/// around 1,000 characters), without the asterisks that make some of them
/// bold or italic, and (1.4.3) the [attribution] under them.
String textCardAltText(String text, {String? attribution}) {
  final words = [stripEmphasis(text), ?attribution].join('\n');
  return words.length <= 1000 ? words : '${words.substring(0, 999)}…';
}

/// [safe]: the card keeps clear of a network's buttons ([fullScreenSafeArea]).
/// The name still carries the markers cards had before 1.2.0, which helps
/// people recognise the file; the render parameters are what NEFORUM reads.
String textCardFileName(TextCardTheme theme, {bool branded = true, TextCardFont font = TextCardFont.original, bool safe = false}) =>
    'neforum-text-card-${theme.name}${branded ? '' : '-plain'}${font.marker.isEmpty ? '' : '-${font.marker}'}${safe ? '-safe' : ''}.jpg';

/// Everything a card for [platformId] is rendered with, as recorded in its
/// [MediaAttachment.renderParameters]: two cards with equal parameters (and
/// size) are the same picture. [byline] is the @handle drawn on it (the
/// [style]'s own @handle when it has one), null when it is left out;
/// [textHash] identifies the words ([stableHash]).
Map<String, dynamic> textCardRenderParameters({
  required String platformId,
  required TextCardTheme theme,
  required TextCardFont font,
  required bool branded,
  required TextCardAlignment alignment,
  required bool showsHandle,
  String? byline,
  bool safe = false,
  String? textHash,
  TextCardBackground? background,
  CaptionFont? customFont, // 1.3.1: cards
  bool customFontFallback = false,
  CardDesign? design,
  bool designFontFallback = false,
  TextCardStyle style = TextCardStyle.classic, // 1.3.5: cards
}) =>
    {
      'kind': RenderKind.textCard,
      'platform': platformId,
      'theme': theme.name,
      'font': font.name,
      'branded': branded,
      'alignment': alignment.name,
      'handle': showsHandle,
      if (showsHandle && byline != null) 'byline': byline,
      'safe': safe,
      'textHash': ?textHash,
      if (background != null) 'background': background.toRenderParameters(),
      // 1.3.1: cards. Only when set, so cards in a built-in font keep the
      // parameters they were made with. A card drawn in [font] because the
      // chosen font is not on the device says so, and is made again where
      // the font is.
      if (customFont != null) 'customFont': customFont.toJson(),
      if (customFont != null && customFontFallback) 'customFontFallback': true,
      // 1.3.1: cards. A card drawn from the card designer: the design is the
      // whole look (the choices above stay recorded for when it is turned
      // off). Fonts of its blocks missing here are marked like customFont.
      if (design != null) 'design': design.toJson(),
      if (design != null && designFontFallback) 'designFontFallback': true,
      // 1.3.5: cards. Only when restyled, so an untouched card keeps the
      // parameters 1.3.4 gave it. A designed card records only what it
      // draws of the style, its @handle (the design's blocks set the rest),
      // so a classic restyle it does not show never makes it again.
      if (!(design == null ? style : style.handleOnly).isClassic) 'style': (design == null ? style : style.handleOnly).toJson(),
    };

/// The card designer's design a card (or placeholder) was drawn from
/// (1.3.1); null for the classic card.
CardDesign? textCardDesignOf(MediaAttachment m) => CardDesign.tryParse(textCardParametersOf(m)?['design']);

/// The style a card (or placeholder) was drawn with (1.3.5); [TextCardStyle.classic]
/// for cards made before it or never restyled.
TextCardStyle textCardStyleOf(MediaAttachment m) => TextCardStyle.fromJson(textCardParametersOf(m)?['style']);

/// The @handle drawn on a card (or a composer stand-in that records it,
/// 1.3.5); null when it is left out or not recorded.
String? textCardBylineOf(MediaAttachment m) => textCardParametersOf(m)?['byline'] as String?;

/// The installed or imported font a card (or placeholder) was made with
/// (1.3.1); null for a built-in font ([textCardFontOf]).
CaptionFont? textCardCustomFontOf(MediaAttachment m) => CaptionFont.tryParse(textCardParametersOf(m)?['customFont']);

/// The render parameters of a card (or placeholder) made since 1.2.0; null
/// for older cards, whose choices are read from the file name.
Map<String, dynamic>? textCardParametersOf(MediaAttachment m) {
  final p = m.renderParameters;
  return p != null && p['kind'] == RenderKind.textCard ? p : null;
}

/// Whether a generated card was laid out clear of a network's buttons.
bool textCardSafeOf(MediaAttachment m) {
  final p = textCardParametersOf(m);
  if (p != null) return p['safe'] == true;
  return (m.fileName ?? '').contains('-safe');
}

/// Path prefix of the composer's stand-in for a card that is rendered when
/// the post is saved.
const String kTextCardPlaceholder = 'textcard:';

bool isTextCardPlaceholder(MediaAttachment m) => m.path.startsWith(kTextCardPlaceholder);

/// What the composer's previews and checks see in place of the real card.
/// [byline] (1.3.5) is the @handle the card will show, recorded like a saved
/// card's when [showsHandle]; [style] is the post's [TextCardStyle]. [size]
/// (1.4.3) is the picture's when the card's shape is not the network's own
/// ([textCardFrameSize]).
MediaAttachment textCardPlaceholder(String platformId, TextCardTheme theme,
    {bool branded = true,
    TextCardFont font = TextCardFont.original,
    TextCardAlignment alignment = TextCardAlignment.left,
    bool showsHandle = true,
    TextCardBackground? background,
    bool story = false,
    CaptionFont? customFont,
    CardDesign? design,
    String? byline,
    TextCardStyle style = TextCardStyle.classic,
    Size? size}) {
  final s = size ?? textCardSize(platformId, story: story);
  return MediaAttachment(
    id: story ? 'textcard-$platformId-story' : 'textcard-$platformId',
    path: '$kTextCardPlaceholder${theme.name}${branded ? '' : ':plain'}${font.marker.isEmpty ? '' : ':${font.marker}'}',
    mimeType: 'image/jpeg',
    sizeBytes: 0,
    width: s.width.round(),
    height: s.height.round(),
    fileName: textCardFileName(theme, branded: branded, font: font),
    generated: true,
    renderParameters: textCardRenderParameters(
      platformId: platformId,
      theme: theme,
      font: font,
      branded: branded,
      alignment: alignment,
      showsHandle: showsHandle,
      byline: byline,
      safe: textCardSafeArea(platformId, story: story, size: s) != EdgeInsets.zero,
      background: background,
      customFont: customFont,
      design: design,
      style: style,
    ),
  );
}

/// Whether a generated card (or placeholder) carries the NEFORUM signature.
bool textCardBrandedOf(MediaAttachment m) {
  final p = textCardParametersOf(m);
  if (p != null) return p['branded'] != false;
  return !(m.path.contains(':plain') || (m.fileName ?? '').contains('-plain'));
}

/// The font a generated card (or placeholder) was made with.
TextCardFont textCardFontOf(MediaAttachment m) {
  final p = textCardParametersOf(m);
  if (p != null) return TextCardFont.values.asNameMap()[p['font']] ?? TextCardFont.original;
  final name = '${m.fileName ?? ''} ${m.path}';
  for (final f in TextCardFont.values) {
    if (f.marker.isNotEmpty && name.contains(f.marker)) return f;
  }
  return TextCardFont.original;
}

/// The theme a generated card (or placeholder) was made with.
TextCardTheme? textCardThemeOf(MediaAttachment m) {
  final p = textCardParametersOf(m);
  if (p != null) return TextCardTheme.values.asNameMap()[p['theme']];
  final name = '${m.fileName ?? ''} ${m.path}';
  for (final t in TextCardTheme.values) {
    if (name.contains('text-card-${t.name}') || name.contains('$kTextCardPlaceholder${t.name}')) return t;
  }
  return null;
}

/// The alignment a card (or placeholder) was made with. Cards made before
/// 1.2.0 were left-aligned.
TextCardAlignment textCardAlignmentOf(MediaAttachment m) =>
    TextCardAlignment.values.asNameMap()[textCardParametersOf(m)?['alignment']] ?? TextCardAlignment.left;

/// Whether a card (or placeholder) shows the account's @handle. Cards made
/// before 1.2.0 always did.
bool textCardShowsHandleOf(MediaAttachment m) => textCardParametersOf(m)?['handle'] != false;

/// The network a card was made for; null for cards made before 1.2.0.
String? textCardPlatformOf(MediaAttachment m) => textCardParametersOf(m)?['platform'] as String?;

/// Paints a card at any size; all measurements scale with the width, so
/// the composer preview and the 1080-pixel export look the same.
class TextCardPainter extends CustomPainter {
  /// Repaints when an installed or imported font finishes loading
  /// ([captionFontsRevision]).
  TextCardPainter(
      {required this.text,
      required this.theme,
      this.byline,
      this.branded = true,
      this.font = TextCardFont.original,
      this.safe = EdgeInsets.zero,
      this.alignment = TextCardAlignment.left,
      this.backdrop,
      this.customFont,
      this.style = TextCardStyle.classic})
      : super(repaint: captionFontsRevision);

  final String text;
  final TextCardTheme theme;

  /// Typeface of the words.
  final TextCardFont font;

  /// 1.3.1: cards. A font installed on the device or imported, drawn instead
  /// of [font] once it is loaded ([registeredCaptionFontAlias]); where it is
  /// missing, [font] is drawn.
  final CaptionFont? customFont;

  /// The words' style at [fontSize]: [font], or the loaded [customFont] with
  /// [font] and the [kCaptionFontFallbacks] for what it lacks.
  /// On a quote card (1.4.3) the words are set in regular weight, the way a
  /// quote is printed, so that **bold** words stand out.
  TextStyle _wordsStyle(double fontSize, Color color) {
    final alias = registeredCaptionFontAlias(customFont);
    if (alias == null) {
      final words = font.style(fontSize: fontSize, height: style.lineSpacing, color: color);
      return style.layout == TextCardLayout.panel ? _weighted(words, FontWeight.w400) : words;
    }
    return TextStyle(
      fontFamily: alias,
      fontFamilyFallback: [...captionFontSubsetAliases(customFont), font.family, ...font.fallback, ...kCaptionFontFallbacks],
      fontWeight: FontWeight.w400,
      fontSize: fontSize,
      height: style.lineSpacing,
      color: color,
    );
  }

  /// Draw the NEFORUM signature (top rule, mark and wordmark).
  final bool branded;

  /// The network's own @handle, e.g. "@ana@mastodon.social"; null leaves the
  /// @handle out. Where it is drawn, [style]'s own @handle replaces it.
  final String? byline;

  /// 1.3.5: cards. The words' size, colour, line spacing and place, the
  /// card's colour and margins, and the @handle's words, size, place and
  /// colour; [TextCardStyle.classic] draws the card as 1.3.4 did.
  final TextCardStyle style;

  /// Room the network's own buttons take, in pixels at 1080 wide
  /// ([fullScreenSafeArea]): the words and footer stay out of it.
  final EdgeInsets safe;

  /// How the words are lined up.
  final TextCardAlignment alignment;

  /// A photo behind the words instead of the theme's plain colour.
  final TextCardBackdrop? backdrop;

  /// [s] at [weight], a variable font's weight axis too.
  static TextStyle _weighted(TextStyle s, FontWeight weight) => s.fontWeight == weight
      ? s
      : s.copyWith(fontWeight: weight, fontVariations: [
          for (final v in s.fontVariations ?? const <FontVariation>[]) v.axis == 'wght' ? FontVariation('wght', weight.value.toDouble()) : v,
        ]);

  /// 1.4.3: cards. [base] with [run]'s emphasis: bold a clear step heavier
  /// than the words, italic slanted.
  static TextStyle emphasised(TextStyle base, EmphasisRun run) {
    var s = base;
    if (run.bold) {
      final w = (base.fontWeight ?? FontWeight.w400).value;
      s = _weighted(s, w <= 500 ? FontWeight.w700 : (w < 700 ? FontWeight.w800 : FontWeight.w900));
    }
    if (run.italic) s = s.copyWith(fontStyle: FontStyle.italic);
    return s;
  }

  /// The words' colour on a card over [over]: the style's, else the photo's
  /// text colour, else the theme's.
  Color _foregroundOver(TextCardBackdrop? over) => style.textColorOr(over?.foreground ?? theme.foreground);

  /// 1.4.3: cards. Where the card itself goes in a picture of [size], and
  /// how round its corners are; null when the card is the whole picture, as
  /// cards always were. A card is drawn inside the picture when the picture
  /// is not the card's shape (a 16:9 card in TikTok's 9:16 frame,
  /// [textCardFrameSize]) or it is a quote card ([TextCardLayout.panel]):
  /// whole, as large as fits inside the network's [safe] area with room
  /// around it, on [textCardSurroundColour] or the background photo.
  ({Rect rect, double radius})? cardRect(Size size) {
    final s = style;
    final aspect = s.shape.aspect;
    final inset = aspect != null && (size.width / size.height - aspect).abs() > 0.02;
    final panel = s.layout == TextCardLayout.panel;
    if (!inset && !panel) return null;
    final u = math.min(size.width, size.height) / 1080;
    final room = (panel ? s.margin / 2 : 40.0) * u;
    final box = Rect.fromLTRB(safe.left * u + room, safe.top * u + room, size.width - safe.right * u - room, size.height - safe.bottom * u - room);
    var rect = box;
    if (inset && box.width > 0 && box.height > 0) {
      final w = math.min(box.width, box.height * aspect);
      final h = w / aspect;
      rect = Rect.fromCenter(center: box.center, width: w, height: h);
    }
    return (rect: rect, radius: panel ? 40 * math.min(rect.width, rect.height) / 1080 : 0.0);
  }

  /// Where everything but the words goes on a card of [size] with [safe]
  /// and words of [fg], worked out the same way for painting and for
  /// [measureWords]. Measurements scale with the card's shorter side: the
  /// width of every card before 1.4.3, the height of a landscape one.
  ({
    double u,
    double pad,
    double safeRight,
    double rule,
    double markSize,
    double footerY,
    String handle,
    TextCardHandlePosition corner,
    bool handleOnTop,
    String by,
    double bottom,
    double top,
    double areaW,
    TextPainter Function(double room) handleLaidOut,
  }) _geometry(Size size, EdgeInsets safe, Color fg) {
    final u = math.min(size.width, size.height) / 1080;
    final w = size.width;
    final h = size.height;
    final s = style;
    final pad = s.margin * u;
    final safeTop = safe.top * u, safeRight = safe.right * u, safeBottom = safe.bottom * u;
    final rule = branded ? 14 * u : 0.0;
    // The @handle: the style's own words or the network's, in the place the
    // style picks (by default beside the signature, or bottom left).
    final handle = byline == null ? '' : s.bylineFor(byline!).trim();
    final corner = s.handlePosition.resolve(branded: branded);
    final handleOnTop = corner.isTop && handle.isNotEmpty;
    final handleColor = s.handleColor == null ? fg.withValues(alpha: 0.62) : Color(s.handleColor!);
    TextPainter handleLaidOut(double room) => TextPainter(
          text: emojiSpan(handle, TextStyle(fontFamily: Fonts.body, fontWeight: FontWeight.w500, fontSize: 26 * u * s.handleSize, color: handleColor, height: 1.1)),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: room);
    // Footer: mark, wordmark and the @handle; a plain card keeps only the
    // @handle. Its distance from the bottom follows the margins (84 px at the
    // card's own 92).
    final markSize = 60 * u;
    final footerY = h - safeBottom - 84 * u * (s.margin / TextCardStyle.defaultMargin) - markSize;
    final by = handleOnTop ? '' : handle;
    final double bottom;
    if (branded) {
      final dividerY = footerY - 44 * u;
      bottom = dividerY - 56 * u;
    } else {
      bottom = by.isEmpty ? h - pad - safeBottom : footerY - 40 * u;
    }
    return (
      u: u,
      pad: pad,
      safeRight: safeRight,
      rule: rule,
      markSize: markSize,
      footerY: footerY,
      handle: handle,
      corner: corner,
      handleOnTop: handleOnTop,
      by: by,
      bottom: bottom,
      top: rule + pad + safeTop,
      areaW: w - pad * 2 - safeRight,
      handleLaidOut: handleLaidOut,
    );
  }

  /// Largest size of the words, in pixels at 1080 on the card's shorter side:
  /// short words are set this large.
  static const double maxWordsSize = 104;

  /// Smallest size of the words: longer words are cut rather than set
  /// smaller.
  static const double minWordsSize = 30;

  /// 1.4.3: cards. The space between the words and the attribution line, as
  /// a share of the words' size (the attribution is set at that size).
  static const double attributionGap = 0.8;

  /// The words set as large as fits in [areaW] x [areaH] (never smaller than
  /// [minWordsSize]), then at the style's size: [fitted] is the size at
  /// 100%, [fs] the size drawn. With an attribution (1.4.3) its line and the
  /// space above it ([gap]) are kept free under the words first. The caller
  /// disposes of [words] and [attribution].
  ({AlignedText words, double fs, double fitted, TextPainter? attribution, double gap}) _fitWords(double u, double areaW, double areaH, Color fg) {
    final s = style;
    final rtl = Bidi.detectRtlDirectionality(text);
    // 1.4.3: cards. **Bold** and *italic* in the words; words without them
    // are laid out exactly as before.
    final marked = hasEmphasis(text);
    AlignedText layout(double fs, {int? maxLines}) => AlignedText(
          text,
          style: _wordsStyle(fs, fg),
          alignment: alignment,
          direction: rtl ? TextDirection.rtl : TextDirection.ltr,
          maxLines: maxLines,
          emphasis: marked ? (run) => emphasised(_wordsStyle(fs, fg), run) : null,
        )..layout(areaW, fill: true);

    // 1.4.3: cards. The attribution, in the words' font, in bold.
    final by = s.attribution;
    TextPainter? attributionAt(double size) {
      if (by == null || areaW <= 0) return null;
      final byRtl = Bidi.detectRtlDirectionality(by);
      return TextPainter(
        text: emojiSpan(by, emphasised(_wordsStyle(size, fg), const EmphasisRun('', bold: true)).copyWith(height: 1.25)),
        textDirection: byRtl ? TextDirection.rtl : TextDirection.ltr,
        textAlign: alignment == TextCardAlignment.center ? TextAlign.center : (alignment == TextCardAlignment.right ? TextAlign.end : TextAlign.start),
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: areaW);
    }

    // The attribution is set at the words' size, [attributionGap] of it
    // under them: the room it takes at each size the words are tried at.
    final reserved = <double, double>{};
    double reserve(double fs) => by == null
        ? 0
        : reserved.putIfAbsent(fs, () {
            final a = attributionAt(fs);
            final h = a == null ? 0.0 : a.height + fs * attributionGap;
            a?.dispose();
            return h;
          });
    bool tooTall(AlignedText words, double fs) => words.height + reserve(fs) > areaH;

    var fs = maxWordsSize * u;
    final minFs = minWordsSize * u;
    var words = layout(fs);
    while (tooTall(words, fs) && fs > minFs) {
      words.dispose();
      fs = math.max(minFs, fs - 4 * u);
      words = layout(fs);
    }
    // 1.3.5: cards. The chosen size against the fitted one: smaller always
    // fits; larger grows only as far as the words still fit.
    final fitted = fs;
    final scale = s.textSize;
    if (scale < 1) {
      words.dispose();
      fs *= scale;
      words = layout(fs);
    } else if (scale > 1) {
      var larger = fs * scale;
      var grown = layout(larger);
      while (tooTall(grown, larger) && larger > fitted) {
        grown.dispose();
        larger = math.max(fitted, larger - 4 * u);
        grown = layout(larger);
      }
      words.dispose();
      words = grown;
      fs = larger;
    }
    if (tooTall(words, fs)) {
      final lines = math.max(1, (math.max(0.0, areaH - reserve(fs)) / (fs * s.lineSpacing)).floor());
      words.dispose();
      words = layout(fs, maxLines: lines);
    }
    return (words: words, fs: fs, fitted: fitted, attribution: attributionAt(fs), gap: by == null ? 0.0 : fs * attributionGap);
  }

  /// 1.4.3: cards. Where the words (laid out [words.height] high) and the
  /// attribution under them go in the room from [top] to [top] + [areaH],
  /// [areaW] wide from [pad]: together, at the style's position, the
  /// attribution lined up with the words.
  ({Offset words, Offset? attribution, double height}) _placeWords(
      double pad, double top, double areaW, double areaH, AlignedText words, TextPainter? attribution, double gap) {
    final height = words.height + (attribution == null ? 0 : gap + attribution.height);
    final position = style.textPosition ?? backdrop?.background.textPosition ?? TextCardTextPosition.center;
    // The middle is worked out as before 1.3, so those cards stay the same.
    final origin = Offset(
        pad, position == TextCardTextPosition.center ? top + (areaH - height) / 2 : top + math.max(0.0, areaH - height) * position.anchor);
    if (attribution == null) return (words: origin, attribution: null, height: height);
    final start = attribution.textDirection == TextDirection.rtl ? 1.0 : 0.0;
    final anchor = switch (alignment) {
      TextCardAlignment.center => 0.5,
      TextCardAlignment.right => 1 - start,
      _ => start,
    };
    return (
      words: origin,
      attribution: Offset(pad + (areaW - attribution.width) * anchor, origin.dy + words.height + gap),
      height: height,
    );
  }

  /// 1.3.5: cards. How large the words come out on a card of [size], in
  /// pixels at 1080 wide: [fitted] at the classic 100%, [drawn] at the
  /// style's size. Above 100% the words grow only as far as they fit, so the
  /// editor can say when a larger size changes nothing ("already as large as
  /// fits").
  ({double fitted, double drawn}) measureWords(Size size) {
    final m = describe(size);
    return (fitted: m.fitted, drawn: m.drawn);
  }

  /// 1.4.3: cards. How a picture of [size] is laid out, in its own pixels:
  /// where the card goes when it is drawn inside the picture ([card], null
  /// for the whole picture, [cardRadius] its corners), the words' block
  /// ([words], the lines' ink in [lines]) and the attribution under them
  /// ([attribution]), the words' size in pixels ([fontSize]) and, at 1080 on
  /// the card's shorter side, at the classic 100% ([fitted]) and drawn
  /// ([drawn]), and whether words were cut to fit ([cut]). Worked out
  /// exactly as [paint] does.
  ({
    Rect? card,
    double cardRadius,
    double fontSize,
    double fitted,
    double drawn,
    Rect words,
    Rect lines,
    List<LineMetrics> lineMetrics,
    Rect? attribution,
    bool cut,
  }) describe(Size size) {
    final frame = cardRect(size);
    final at = frame?.rect.topLeft ?? Offset.zero;
    final cardSize = frame?.rect.size ?? size;
    final g = _geometry(cardSize, frame == null ? safe : EdgeInsets.zero, _foregroundOver(frame == null ? backdrop : null));
    var top = g.top;
    if (g.handleOnTop && g.areaW > 40 * g.u) {
      final author = g.handleLaidOut(g.areaW);
      top += author.height + 40 * g.u;
      author.dispose();
    }
    final areaH = math.max(0.0, g.bottom - top);
    final fit = _fitWords(g.u, g.areaW, areaH, _foregroundOver(frame == null ? backdrop : null));
    final place = _placeWords(g.pad, top, g.areaW, areaH, fit.words, fit.attribution, fit.gap);
    final out = (
      card: frame?.rect,
      cardRadius: frame?.radius ?? 0.0,
      fontSize: fit.fs,
      fitted: fit.fitted / g.u,
      drawn: fit.fs / g.u,
      words: (place.words & Size(fit.words.width, fit.words.height)).shift(at),
      lines: fit.words.lineBounds.shift(place.words + at),
      lineMetrics: fit.words.lineMetrics,
      attribution: fit.attribution == null ? null : (place.attribution! & fit.attribution!.size).shift(at),
      cut: fit.words.didExceedMaxLines,
    );
    fit.words.dispose();
    fit.attribution?.dispose();
    return out;
  }

  // Every measurement below is the 1.3.4 one with the style's factor applied
  // as a multiplication by 1 (or the same value) for [TextCardStyle.classic],
  // so an untouched card is the same picture, byte for byte
  // (text_card_style_test.dart).
  @override
  void paint(Canvas canvas, Size size) {
    final frame = cardRect(size);
    if (frame == null) {
      _paintCard(canvas, size, safe, backdrop);
      return;
    }
    // 1.4.3: cards. The card inside a larger picture, or a quote card: the
    // photo or the surround colour around it, the card itself drawn whole,
    // on its own colour, clear of the network's buttons.
    final cardColor = style.backgroundColorOr(theme.background);
    if (backdrop != null) {
      backdrop!.paint(canvas, Offset.zero & size, size.width / 1080, cardColor: cardColor);
    } else {
      canvas.drawRect(Offset.zero & size, Paint()..color = textCardSurroundColour(cardColor));
    }
    canvas.save();
    canvas.translate(frame.rect.left, frame.rect.top);
    if (frame.radius > 0) canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & frame.rect.size, Radius.circular(frame.radius)));
    _paintCard(canvas, frame.rect.size, EdgeInsets.zero, null);
    canvas.restore();
  }

  /// The card on a canvas of [size]: [safe] is the network's buttons' room,
  /// [over] the photo behind the words, if any.
  void _paintCard(Canvas canvas, Size size, EdgeInsets safe, TextCardBackdrop? over) {
    final fg = _foregroundOver(over);
    final g = _geometry(size, safe, fg);
    final u = g.u;
    final w = size.width;
    final s = style;
    final cardColor = s.backgroundColorOr(theme.background);
    final pad = g.pad;
    final safeRight = g.safeRight;

    if (over != null) {
      // The photo is placed by the picture's width, as composeTextCard
      // places it in a saved card.
      over.paint(canvas, Offset.zero & size, w / 1080, cardColor: cardColor);
    } else {
      canvas.drawRect(Offset.zero & size, Paint()..color = cardColor);
    }

    final rule = g.rule;
    if (branded) {
      // Signature rule: purple along the top, a yellow tab at the start.
      canvas.drawRect(Rect.fromLTWH(0, 0, w, rule), Paint()..color = Brand.purple);
      canvas.drawRect(Rect.fromLTWH(0, 0, pad + 120 * u, rule), Paint()..color = Brand.yellow);
    }

    final corner = g.corner;
    final handleLaidOut = g.handleLaidOut;
    final markSize = g.markSize;
    final footerY = g.footerY;
    final by = g.by;
    var authorLeft = pad;
    if (branded) {
      paintNeforumMark(canvas, Rect.fromLTWH(pad, footerY, markSize, markSize));
      final word = TextPainter(
        text: TextSpan(
          text: 'NEFORUM',
          style: TextStyle(fontFamily: Fonts.display, fontWeight: FontWeight.w800, fontSize: 30 * u, letterSpacing: 1.6 * u, color: fg, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final wordX = pad + markSize + 20 * u;
      word.paint(canvas, Offset(wordX, footerY + (markSize - word.height) / 2));
      authorLeft = wordX + word.width + 32 * u;
      word.dispose();
    }
    if (by.isNotEmpty) {
      final room = w - pad - safeRight - authorLeft;
      if (room > 40 * u) {
        final author = handleLaidOut(room);
        // On the left it follows the wordmark (a plain card's margin); in
        // the middle it is centred on the card, clear of the wordmark.
        final x = corner.isRight
            ? w - pad - safeRight - author.width
            : corner.isCentre
                ? math.max(authorLeft, pad + (g.areaW - author.width) / 2)
                : authorLeft;
        author.paint(canvas, Offset(x, footerY + (markSize - author.height) / 2));
        author.dispose();
      }
    }
    if (branded) {
      final dividerY = footerY - 44 * u;
      canvas.drawLine(
        Offset(pad, dividerY),
        Offset(w - pad - safeRight, dividerY),
        Paint()
          ..color = fg.withValues(alpha: 0.16)
          ..strokeWidth = 2 * u,
      );
    }
    final bottom = g.bottom;

    // The words: as large as fits, never smaller than 30 px at 1080 wide.
    var top = g.top;
    final areaW = g.areaW;
    if (g.handleOnTop && areaW > 40 * u) {
      // The @handle above the words, inside the margins; the words start
      // under it.
      final author = handleLaidOut(areaW);
      final x = corner.isRight
          ? w - pad - safeRight - author.width
          : corner.isCentre
              ? pad + (areaW - author.width) / 2
              : pad;
      author.paint(canvas, Offset(x, top));
      top += author.height + 40 * u;
      author.dispose();
    }
    final areaH = math.max(0.0, bottom - top);
    final fit = _fitWords(u, areaW, areaH, fg);
    final words = fit.words;
    final attribution = fit.attribution;
    final place = _placeWords(pad, top, areaW, areaH, words, attribution, fit.gap);
    final origin = place.words;
    if (over?.background.textBox ?? false) {
      // A soft box behind the words, so they read over a busy photo.
      var ink = words.lineBounds.shift(origin);
      if (attribution != null) ink = ink.expandToInclude(place.attribution! & attribution.size);
      final box = ink.inflate(30 * u);
      final lightWords = fg.computeLuminance() > 0.5;
      canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(24 * u)),
          Paint()..color = lightWords ? const Color(0x8C000000) : const Color(0xB3FFFFFF));
    }
    words.paint(canvas, origin);
    words.dispose();
    if (attribution != null) {
      attribution.paint(canvas, place.attribution!);
      attribution.dispose();
    }
  }

  @override
  bool shouldRepaint(TextCardPainter old) =>
      old.text != text ||
      old.theme != theme ||
      old.byline != byline ||
      old.branded != branded ||
      old.font != font ||
      old.safe != safe ||
      old.alignment != alignment ||
      old.backdrop != backdrop ||
      old.customFont != customFont ||
      old.style != style;
}

/// Live card for previews.
class TextCardView extends StatelessWidget {
  const TextCardView(
      {super.key,
      required this.text,
      required this.theme,
      required this.aspect,
      this.byline,
      this.branded = true,
      this.font = TextCardFont.original,
      this.safe = EdgeInsets.zero,
      this.alignment = TextCardAlignment.left,
      this.backdrop,
      this.customFont,
      this.style = TextCardStyle.classic});

  final String text;
  final TextCardTheme theme;
  final TextCardFont font;
  final CaptionFont? customFont;
  final EdgeInsets safe;

  /// Width / height.
  final double aspect;
  final String? byline;
  final bool branded;
  final TextCardAlignment alignment;
  final TextCardBackdrop? backdrop;

  /// 1.3.5: cards. See [TextCardPainter.style].
  final TextCardStyle style;

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: aspect,
        child: CustomPaint(
          painter: TextCardPainter(
              text: text,
              theme: theme,
              byline: byline,
              branded: branded,
              font: font,
              safe: safe,
              alignment: alignment,
              backdrop: backdrop,
              customFont: customFont,
              style: style),
        ),
      );
}

/// Renders a card to JPEG bytes (Instagram's API only takes JPEG). The engine
/// rasterizes only the words, rule, footer and colours; a background photo
/// ([TextCardBackdrop.pixels]) is composited on the CPU ([composeTextCard]),
/// never as an engine image. [style] (1.3.5) as [TextCardPainter.style]; its
/// card colour also fills the room a whole photo leaves.
Future<Uint8List> renderTextCardJpeg(
    {required String text,
    required TextCardTheme theme,
    required Size size,
    String? byline,
    bool branded = true,
    TextCardFont font = TextCardFont.original,
    EdgeInsets safe = EdgeInsets.zero,
    TextCardAlignment alignment = TextCardAlignment.left,
    TextCardBackdrop? backdrop,
    CaptionFont? customFont,
    TextCardStyle style = TextCardStyle.classic}) async {
  final width = size.width.round();
  final height = size.height.round();
  await EmojiSupport.prepare('$text ${byline == null ? '' : style.bylineFor(byline)} ${style.attribution ?? ''}');
  // A preview's engine image is never drawn here: only the photo's pixels.
  final photo = backdrop?.pixels;
  final words = await rasterizeWordsLayer(width, height, (canvas) {
    TextCardPainter(
      text: text,
      theme: theme,
      byline: byline,
      branded: branded,
      font: font,
      safe: safe,
      alignment: alignment,
      backdrop: photo == null ? null : TextCardBackdrop(pixels: photo, luminance: backdrop!.luminance, background: backdrop.background),
      customFont: customFont,
      style: style,
    ).paint(canvas, size);
  });
  if (photo == null) return compute(encodeRgbaJpeg, (words, width, height));
  return compute(
    composeTextCard,
    TextCardComposeJob.forBackground(
        photo: photo, words: words, width: width, height: height, background: backdrop!.background, cardColor: style.backgroundColorOr(theme.background)),
  );
}

/// JPEG (quality 92) from straight RGBA pixels; run with [compute].
Uint8List encodeRgbaJpeg((Uint8List, int, int) a) {
  final (rgba, width, height) = a;
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodeJpg(image, quality: 92);
}
