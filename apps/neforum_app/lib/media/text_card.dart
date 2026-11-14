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

/// The safe area of [platformId]'s card: only full-screen (9:16) cards
/// (TikTok, Snapchat, stories) have the network's buttons over them.
EdgeInsets textCardSafeArea(String platformId, {bool story = false}) {
  final s = textCardSize(platformId, story: story);
  return s.width / s.height < 0.62 ? fullScreenSafeArea(platformId) : EdgeInsets.zero;
}

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
/// around 1,000 characters).
String textCardAltText(String text) => text.length <= 1000 ? text : '${text.substring(0, 999)}…';

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
/// card's when [showsHandle]; [style] is the post's [TextCardStyle].
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
    TextCardStyle style = TextCardStyle.classic}) {
  final s = textCardSize(platformId, story: story);
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
      safe: textCardSafeArea(platformId, story: story) != EdgeInsets.zero,
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
  TextStyle _wordsStyle(double fontSize, Color color) {
    final alias = registeredCaptionFontAlias(customFont);
    if (alias == null) return font.style(fontSize: fontSize, height: style.lineSpacing, color: color);
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

  /// The words' colour: the style's, else the photo's text colour, else the
  /// theme's.
  Color get _foreground => style.textColorOr(backdrop?.foreground ?? theme.foreground);

  /// Where everything but the words goes on a card of [size], worked out the
  /// same way for painting and for [measureWords].
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
  }) _geometry(Size size) {
    final u = size.width / 1080;
    final w = size.width;
    final h = size.height;
    final s = style;
    final fg = _foreground;
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

  /// The words set as large as fits in [areaW] x [areaH] (never smaller than
  /// 30 px at 1080 wide), then at the style's size: [fitted] is the size at
  /// 100%, [fs] the size drawn. The caller disposes of [words].
  ({AlignedText words, double fs, double fitted}) _fitWords(double u, double areaW, double areaH, Color fg) {
    final s = style;
    final rtl = Bidi.detectRtlDirectionality(text);
    AlignedText layout(double fs, {int? maxLines}) => AlignedText(
          text,
          style: _wordsStyle(fs, fg),
          alignment: alignment,
          direction: rtl ? TextDirection.rtl : TextDirection.ltr,
          maxLines: maxLines,
        )..layout(areaW, fill: true);

    var fs = 104 * u;
    final minFs = 30 * u;
    var words = layout(fs);
    while (words.height > areaH && fs > minFs) {
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
      while (grown.height > areaH && larger > fitted) {
        grown.dispose();
        larger = math.max(fitted, larger - 4 * u);
        grown = layout(larger);
      }
      words.dispose();
      words = grown;
      fs = larger;
    }
    if (words.height > areaH) {
      final lines = math.max(1, (areaH / (fs * s.lineSpacing)).floor());
      words.dispose();
      words = layout(fs, maxLines: lines);
    }
    return (words: words, fs: fs, fitted: fitted);
  }

  /// 1.3.5: cards. How large the words come out on a card of [size], in
  /// pixels at 1080 wide: [fitted] at the classic 100%, [drawn] at the
  /// style's size. Above 100% the words grow only as far as they fit, so the
  /// editor can say when a larger size changes nothing ("already as large as
  /// fits").
  ({double fitted, double drawn}) measureWords(Size size) {
    final g = _geometry(size);
    var top = g.top;
    if (g.handleOnTop && g.areaW > 40 * g.u) {
      final author = g.handleLaidOut(g.areaW);
      top += author.height + 40 * g.u;
      author.dispose();
    }
    final fit = _fitWords(g.u, g.areaW, math.max(0.0, g.bottom - top), _foreground);
    fit.words.dispose();
    return (fitted: fit.fitted / g.u, drawn: fit.fs / g.u);
  }

  // Every measurement below is the 1.3.4 one with the style's factor applied
  // as a multiplication by 1 (or the same value) for [TextCardStyle.classic],
  // so an untouched card is the same picture, byte for byte
  // (text_card_style_test.dart).
  @override
  void paint(Canvas canvas, Size size) {
    final g = _geometry(size);
    final u = g.u;
    final w = size.width;
    final s = style;
    final fg = _foreground;
    final cardColor = s.backgroundColorOr(theme.background);
    final pad = g.pad;
    final safeRight = g.safeRight;

    if (backdrop != null) {
      backdrop!.paint(canvas, Offset.zero & size, u, cardColor: cardColor);
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
    final position = s.textPosition ?? backdrop?.background.textPosition ?? TextCardTextPosition.center;
    // The middle is worked out as before 1.3, so those cards stay the same.
    final origin = Offset(
        pad,
        position == TextCardTextPosition.center
            ? top + (areaH - words.height) / 2
            : top + math.max(0.0, areaH - words.height) * position.anchor);
    if (backdrop?.background.textBox ?? false) {
      // A soft box behind the words, so they read over a busy photo.
      final box = words.lineBounds.shift(origin).inflate(30 * u);
      final lightWords = fg.computeLuminance() > 0.5;
      canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(24 * u)),
          Paint()..color = lightWords ? const Color(0x8C000000) : const Color(0xB3FFFFFF));
    }
    words.paint(canvas, origin);
    words.dispose();
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
  await EmojiSupport.prepare('$text ${byline == null ? '' : style.bylineFor(byline)}');
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
