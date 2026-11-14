import 'dart:async';

import 'package:flutter/painting.dart' show EdgeInsets, Size;
import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/caption_fonts.dart';
import '../media/card_design.dart';
import '../media/card_design_edits.dart' show designWithHandle;
import '../media/render_parameters.dart';
import '../media/text_card.dart';
import '../media/text_card_background.dart';
import 'card_designs.dart';
import 'fitted_photos.dart';
import 'render_warnings.dart';
import 'services.dart';
import 'settings.dart';

/// A photo kept with the post only as the background of its text cards
/// ([TextCardBackground]): generated, listed by no target, never posted.
bool isTextCardBackground(MediaAttachment m) => m.generated && renderKindOf(m) == RenderKind.textCardBackground;

/// A rendered NEFORUM text card (not a card's background photo).
bool isRenderedTextCard(MediaAttachment m) => m.isTextCard && !isTextCardBackground(m);

/// `PostOverrides.extra` key of the photo list (media ids) a text card took
/// the place of on a target that had a list of its own (the photo under the
/// card, or no photos). [attachTextCards] and [withoutTextCards] put the list
/// back, so the target keeps the user's choice when the cards are made again
/// and when the post is edited.
const String kTextCardReplacedMediaIdsKey = 'textCardReplacedMediaIds';

/// `PostOverrides.extra` key, on every target of a post that gives the same
/// text card to every network taking images (not only those that need one):
/// `true`. Absent: cards only where an image is needed, as before 1.3.
const String kTextCardEveryNetworkKey = 'textCardEveryNetwork';

/// `PostOverrides.extra` key, on every target of a post whose text cards are
/// restyled (1.3.5): the [TextCardStyle]'s JSON. Absent: the classic card,
/// or the style the post's cards record. Written beside the cards' own
/// render parameters so a scheduled or background run makes cards that did
/// not exist yet (a network added, cards turned on) with the saved style.
const String kTextCardStyleKey = 'textCardStyle';

/// Whether [post] gives its text card to every network that takes images
/// ([kTextCardEveryNetworkKey]).
bool textCardEveryNetworkOfPost(Post post) => post.targets.any((t) => t.overrides.extra[kTextCardEveryNetworkKey] == true);

/// The style written on [post]'s targets ([kTextCardStyleKey]); null when
/// none is.
TextCardStyle? textCardStyleChoiceOfPost(Post post) {
  for (final t in post.targets) {
    final raw = t.overrides.extra[kTextCardStyleKey];
    if (raw is Map) return TextCardStyle.fromJson(raw);
  }
  return null;
}

/// The style of [post]'s text cards (1.3.5), as the composer keeps it: the
/// one written on its targets, else the one its cards were drawn with
/// ([TextCardStyle.classic] for cards from before 1.3.5); null when the post
/// has neither.
TextCardStyle? textCardStyleOfPost(Post post) {
  final chosen = textCardStyleChoiceOfPost(post);
  if (chosen != null) return chosen;
  for (final m in post.media) {
    if (isRenderedTextCard(m)) return textCardStyleOf(m);
  }
  return null;
}

/// Platform id -> whether the post's text goes along with its card there;
/// only networks where it does not ([kTextCardOnlyKey]) are listed, for the
/// composer when a saved post is edited again.
Map<String, bool> textCardWithTextOfPost(Post post, String? Function(String accountId) platformOf) => {
      for (final t in post.targets)
        if (t.overrides.extra[kTextCardOnlyKey] == true) ?platformOf(t.accountId): false,
    };

/// [post] with the composer's card choices written into its targets, so a
/// scheduled or background run makes the cards the way the post was saved:
/// [everyNetwork] on every target, for each network whose [withText] is
/// false, the card without the post's text, and (1.3.5) a restyled card's
/// [style] ([kTextCardStyleKey]).
Post withTextCardChoices(Post post,
        {required bool everyNetwork,
        required Map<String, bool> withText,
        required String? Function(String accountId) platformOf,
        TextCardStyle style = TextCardStyle.classic}) =>
    post.copyWith(targets: [
      for (final t in post.targets)
        t.copyWith(
          overrides: t.overrides.copyWith(extra: {
            ...withoutTextCardChoices(t.overrides).extra,
            if (everyNetwork) kTextCardEveryNetworkKey: true,
            if (withText[platformOf(t.accountId)] == false) kTextCardOnlyKey: true,
            if (!style.isClassic) kTextCardStyleKey: style.toJson(),
          }),
        ),
    ]);

/// [o] without the card choices [withTextCardChoices] writes: what the
/// composer shows as the target's own overrides.
PostOverrides withoutTextCardChoices(PostOverrides o) {
  // 1.3.1: cards. The card designs are the composer's choices too.
  o = withoutCardDesigns(o);
  // 1.4.3: cards. So is the emphasis the card draws ([withCardEmphasis]).
  const keys = [kTextCardEveryNetworkKey, kTextCardOnlyKey, kTextCardStyleKey, kEmphasisMarkupKey];
  return keys.any(o.extra.containsKey) ? o.copyWith(extra: {...o.extra}..removeWhere((k, _) => keys.contains(k))) : o;
}

/// 1.4.3: cards. [post] with [kEmphasisMarkupKey] on every target when
/// [marked] (a text card of the post draws **bold** or *italic* words
/// written in it), so networks without Markdown get those words without the
/// asterisks; without the key otherwise, so every asterisk goes as written.
Post withCardEmphasis(Post post, {required bool marked}) {
  if (post.targets.every((t) => (t.overrides.extra[kEmphasisMarkupKey] == true) == marked)) return post;
  return post.copyWith(targets: [
    for (final t in post.targets)
      t.copyWith(
        overrides: t.overrides.copyWith(
          extra: marked ? {...t.overrides.extra, kEmphasisMarkupKey: true} : ({...t.overrides.extra}..remove(kEmphasisMarkupKey)),
        ),
      ),
  ]);
}

/// 1.4.3: cards. The pixel size of the picture [account]'s network gets for
/// a card of [shape] ([textCardFrameSize]): its own frame for a [story] or
/// for each network's own shape, else the shape where the network's photo
/// rules ([PlatformAdapter.photoFit]) and Settings' "fill the whole frame"
/// let it show whole.
Size textCardFrameFor(PlatformAdapter adapter, ConnectedAccount account, PostVariant variant, AppSettings settings,
    {required bool story, required TextCardShape shape}) {
  final id = account.platformId;
  if (shape.size == null || story) return textCardSize(id, story: story);
  final fit = adapter.photoFit(account, variant);
  return textCardFrameSize(id, shape: shape, fillsFrame: settings.fillsFrame(id), minAspect: fit?.minAspect, maxAspect: fit?.maxAspect);
}

/// The photo list a card took the place of on a target
/// ([kTextCardReplacedMediaIdsKey]); null when the target had no list of its
/// own (every photo).
List<String>? _replacedMediaIds(PostOverrides o) {
  final raw = o.extra[kTextCardReplacedMediaIdsKey];
  return raw is List ? [for (final id in raw) if (id is String) id] : null;
}

/// [o] with its photo list as it was before a card took its place: [own], or
/// every photo when [own] is null.
PostOverrides _withOwnMediaIds(PostOverrides o, List<String>? own) {
  final rest = o.extra.containsKey(kTextCardReplacedMediaIdsKey) ? o.copyWith(extra: {...o.extra}..remove(kTextCardReplacedMediaIdsKey)) : o;
  return own == null ? rest.copyWith(clearMediaIds: true) : rest.copyWith(mediaIds: own);
}

/// Gives every target that needs an image but has none (Instagram,
/// Pinterest, TikTok photos, Snapchat) a rendered NEFORUM text card, and
/// removes cards that are no longer needed. A post that gives its card to
/// every network ([textCardEveryNetworkOfPost]) gives it to every target that
/// takes images, each at its network's size ([textCardSize]); the card's
/// words are always its alt text. Safe to call repeatedly: a
/// card whose words and every rendering choice still match (its render
/// parameters, [textCardRenderParameters]) is kept.
///
/// Cards are ordinary media files marked [MediaAttachment.generated]; only
/// the targets that list them in their overrides receive them.
///
/// Each choice left null (or empty) here is the one the post's current cards
/// were made with, else the Settings default: [branded] and [handle] per
/// network (platform id), [theme], [font] and [alignment] per post.
/// [background] is the composer's [TextCardBackground] JSON: an empty map for
/// a plain colour, null to keep the post's current one. A background photo
/// that is not one of the post's photos is kept in the post's media, marked
/// [isTextCardBackground]. [customFont] (1.3.1) is an installed or imported
/// font (CaptionFont.toJson; an empty map for the built-in [font]), loaded
/// before the first card is drawn; where it is not on this device the cards
/// use [font], the user is told, and the cards are made again where it is.
/// [design] (1.3.1) is a card designer design (CardDesign.toJson; an empty
/// map for the classic card; null for the post's own, else the Settings
/// default): with one, it is the cards' whole look. [cardStyle] (1.3.5) is the
/// classic card's [TextCardStyle] (null for the post's own, else the classic
/// card); its @handle replaces each network's own on every card that shows
/// the @handle, designed ones included.
Future<Post> attachTextCards(AppServices s, Post post, AppSettings settings,
    {TextCardTheme? theme,
    TextCardFont? font,
    Map<String, bool> branded = const {},
    TextCardAlignment? alignment,
    Map<String, bool> handle = const {},
    Map<String, dynamic>? background,
    Map<String, dynamic>? customFont,
    Map<String, dynamic>? design,
    TextCardStyle? cardStyle}) async {
  final cards = {for (final m in post.media.where(isRenderedTextCard)) m.id: m};
  final backgrounds = [for (final m in post.media) if (isTextCardBackground(m)) m];
  if (!settings.textCards && cards.isEmpty && backgrounds.isEmpty) return withCardEmphasis(post, marked: false);
  final style = theme ?? textCardThemeOfPost(post) ?? settings.textCardTheme;
  final face = font ?? textCardFontOfPost(post) ?? settings.textCardFont;
  final align = alignment ?? textCardAlignmentOfPost(post) ?? settings.textCardAlignment;
  // 1.3.5: cards. No Settings default: a post nobody restyled is classic.
  final look = cardStyle ?? textCardStyleOfPost(post) ?? TextCardStyle.classic;
  // 1.3.1: cards. Loaded once, when the first card needs it.
  final fontChoice = customFont ?? textCardCustomFontOfPost(post);
  final CaptionFont? cardFont = fontChoice != null ? CaptionFont.tryParse(fontChoice) : settings.textCardCustomFontChoice;
  Future<bool>? fontReady;
  Future<bool> fontMissing() async => cardFont != null && !await (fontReady ??= prepareCaptionFontForRender(s.storage, cardFont, usage: 'the text card'));
  // 1.3.1: cards. The card designer's design, its fonts loaded once.
  final CardDesign? designOwn = effectiveCardDesign(design ?? textCardDesignOfPost(post), settings.textCardDesign);
  // 1.3.5: cards. A written @handle gets a block on a design without one.
  final CardDesign? cardDesign = designOwn == null ? null : designWithHandle(designOwn, look.handle);
  Future<bool>? designReady;
  Future<bool> designFontMissing() async =>
      cardDesign != null && !await (designReady ??= prepareCardDesignFonts(s.storage, cardDesign, usage: 'the text card'));
  final backdropChoice = background == null ? _backgroundOfPost(post) : TextCardBackground.tryParse(background);
  final userPhotos = {for (final m in post.media) if (!m.generated) m.id: m};
  // The post's own photo as it is now (alt text, path), or the photo picked
  // only for the cards, kept as a background entry.
  final backdropPhoto = backdropChoice == null
      ? null
      : userPhotos[backdropChoice.photo.id] ??
          MediaAttachment.fromJson({
            ...backdropChoice.photo.toJson(),
            'generated': true,
            'renderParameters': {...backdropChoice.toRenderParameters(), 'kind': RenderKind.textCardBackground},
          });
  final chosenBackground = backdropChoice?.copyWith(photo: backdropPhoto);
  // Worked out here, not in the loop below: Dart 3.13's AOT compiler moved
  // `chosenBackground.photo.id` (read only when it was set) ahead of the loop
  // without its null check, and NEFORUM 1.2.1 crashed on every save of a post
  // without a card background.
  final backgroundPhoto = chosenBackground?.photo;
  final String? ownBackgroundId = backgroundPhoto != null && userPhotos.containsKey(backgroundPhoto.id) ? backgroundPhoto.id : null;
  final ownPhoto = ownBackgroundId != null;
  final everyNetwork = textCardEveryNetworkOfPost(post);
  final resolver = VariantResolver(settings.resolverOptions);
  final made = <String, MediaAttachment>{};
  final used = <String>{};
  TextCardBackdrop? backdrop;
  var backdropTried = false;
  var p = post;
  // 1.4.3: cards. A card made draws bold or italic words written in it.
  var emphasis = false;

  // A target that lists only a card gets back the list the card took the
  // place of (every photo when it had none of its own). The story's own
  // copies are made again below and by attachFittedPhotos.
  PostTarget baseOf(PostTarget t) {
    final own = t.overrides.mediaIds;
    final userIds = own?.where((id) => !cards.containsKey(id)).toList();
    final onlyCards = own != null && own.isNotEmpty && userIds!.isEmpty;
    return t.copyWith(
        overrides: _withOwnMediaIds(t.overrides, onlyCards ? _replacedMediaIds(t.overrides) : userIds).copyWith(clearStoryMediaIds: true));
  }

  // 1.4.1: a network where the card is a choice (YouTube Posts) takes the
  // post's card when another network of the post gets one.
  var postMakesCard = false;
  if (settings.textCards) {
    for (final t in post.targets) {
      final account = await s.accounts.get(t.accountId);
      final adapter = account == null ? null : s.registry.byId(account.platformId);
      if (account == null || adapter == null || kTextCardChoicePlatforms.contains(account.platformId)) continue;
      final d = adapter.descriptorForAccount(account);
      final base = baseOf(t);
      final variant = resolver.resolve(post.withTarget(base), base, d, account: account);
      final placement = adapter.supportsStories(account) ? variant.placement : PostPlacement.feed;
      if ((placement.includesStory && storyQualifiesForTextCard(d, variant, backgroundMediaId: ownBackgroundId)) ||
          (placement != PostPlacement.story && qualifiesForTextCard(d, variant, backgroundMediaId: ownBackgroundId, everyNetwork: everyNetwork))) {
        postMakesCard = true;
        break;
      }
    }
  }

  for (final original in post.targets) {
    final t = p.targetFor(original.accountId)!;
    final own = t.overrides.mediaIds;
    final oldCard = own?.map((id) => cards[id]).whereType<MediaAttachment>().firstOrNull;
    final base = baseOf(t);
    p = p.withTarget(base);
    if (!settings.textCards) continue;

    final account = await s.accounts.get(t.accountId);
    final adapter = account == null ? null : s.registry.byId(account.platformId);
    if (account == null || adapter == null) continue;
    final d = adapter.descriptorForAccount(account);
    final variant = resolver.resolve(p, base, d, account: account);
    // A story (Story, or the story of Post + Story) with words only gets a
    // full-screen 9:16 card; a feed post on an image-only network its own,
    // and with the card on every network, every network that takes images.
    final placement = adapter.supportsStories(account) ? variant.placement : PostPlacement.feed;
    final storyCard = placement.includesStory && storyQualifiesForTextCard(d, variant, backgroundMediaId: ownBackgroundId);
    final feedCard = placement != PostPlacement.story &&
        qualifiesForTextCard(d, variant, backgroundMediaId: ownBackgroundId, everyNetwork: everyNetwork, postMakesCard: postMakesCard);
    if (!storyCard && !feedCard) continue;

    if (chosenBackground != null && backgroundPhoto != null && !backdropTried) {
      backdropTried = true;
      try {
        backdrop = await decodeTextCardBackdrop(await s.media.read(backgroundPhoto), chosenBackground).timeout(kRenderTimeLimit);
      } on TimeoutException {
        reportRenderWarning('Reading the background photo of the text cards took too long, so the cards are plain.');
      } on Object catch (e) {
        debugPrint('Could not read the background photo of the text cards: $e');
      }
    }

    final text = textCardText(p, base);
    // The @handle drawn: the style's own, else this account's.
    final byline = look.bylineFor(account.handle ?? account.displayName);
    final signed = branded[d.id] ?? (oldCard == null ? null : textCardBrandedOf(oldCard)) ?? settings.textCardBranded(d.id);
    final showsHandle = handle[d.id] ?? (oldCard == null ? null : textCardShowsHandleOf(oldCard)) ?? settings.textCardShowsHandle(d.id);

    // The card, full screen for a story; null when it could not be made.
    // 1.4.3: cards. The shape, the attribution and the emphasis are the
    // classic card's; a design draws at each network's own shape.
    final altText = textCardAltText(text, attribution: cardDesign == null ? look.attribution : null);
    Future<MediaAttachment?> cardIn(bool story) async {
      final size = textCardFrameFor(adapter, account, variant, settings, story: story, shape: cardDesign == null ? look.shape : TextCardShape.automatic);
      final safe = textCardSafeArea(d.id, story: story, size: size);
      final hasSafe = safe != EdgeInsets.zero;
      final fallback = await fontMissing();
      final designFallback = await designFontMissing();
      Map<String, dynamic> paramsWith({required bool fontFallback}) => textCardRenderParameters(
        platformId: d.id,
        theme: style,
        font: face,
        branded: signed,
        alignment: align,
        showsHandle: showsHandle,
        byline: byline,
        safe: hasSafe,
        textHash: stableHash(text),
        background: backdrop?.background,
        customFont: cardFont,
        customFontFallback: fontFallback,
        design: cardDesign,
        designFontFallback: designFallback,
        style: look,
      );
      final params = paramsWith(fontFallback: fallback);
      // Without the font here, a card drawn in it on a device that has it is
      // better than one in the built-in font.
      final drawnInFont = fallback ? paramsWith(fontFallback: false) : null;
      final key = '${size.width}x${size.height}|${stableHash(params.toString())}|$text';
      var card = made[key];
      // A card made before is reused only when it was rendered with exactly
      // these choices, for this network and this @handle; cards from before
      // 1.2.0 carry no parameters and are rendered again.
      card ??= cards.values
          .where((m) =>
              m.width == size.width.round() &&
              m.height == size.height.round() &&
              (renderParametersEqual(m.renderParameters, params) || (drawnInFont != null && renderParametersEqual(m.renderParameters, drawnInFont))) &&
              m.altText == altText)
          .firstOrNull;
      if (card == null) {
        try {
          final designed = cardDesign;
          final bytes = await (designed != null
                  ? renderDesignedTextCard(s.storage,
                      design: designed,
                      platformId: d.id,
                      size: size,
                      safe: safe,
                      text: text,
                      byline: showsHandle ? byline : null,
                      signed: signed,
                      backdrop: backdrop)
                  : renderTextCardJpeg(
            text: text,
            theme: style,
            size: size,
            byline: showsHandle ? byline : null,
            branded: signed,
            font: face.resolve(d.id),
            safe: safe,
            alignment: align,
            backdrop: backdrop,
            customFont: fallback ? null : cardFont,
            style: look,
          ))
              .timeout(kRenderTimeLimit);
          final m = await s.media.importBytes(bytes, fileName: textCardFileName(style, branded: signed, font: face, safe: hasSafe), mimeHint: 'image/jpeg');
          card = MediaAttachment(
            id: m.id,
            path: m.path,
            mimeType: 'image/jpeg',
            sizeBytes: m.sizeBytes,
            width: size.width.round(),
            height: size.height.round(),
            altText: altText,
            fileName: m.fileName,
            generated: true,
            renderParameters: params,
          );
        } on TimeoutException {
          // Never let a picture hold the post up.
          reportRenderWarning('The text card for ${d.name} took too long to make, so ${d.name} gets no card.');
          return null;
        } on Object catch (e) {
          // Without the card the target fails validation with a clear
          // "needs an image" message, which is the right outcome.
          debugPrint('Could not render a text card for ${d.name}: $e');
          return null;
        }
      }
      made[key] = card;
      used.add(card.id);
      if (cardDesign == null && hasEmphasis(text)) emphasis = true;
      return card;
    }

    // A Story's only card is the story itself; Post + Story keeps the
    // story's card beside the feed post's media.
    final card = placement == PostPlacement.story ? (storyCard ? await cardIn(true) : null) : (feedCard ? await cardIn(false) : null);
    final storyOnly = placement == PostPlacement.feedAndStory && storyCard ? await cardIn(true) : null;
    var overrides = base.overrides;
    if (card != null) {
      // The target's own photo list (the photo under the card, or none) is
      // kept beside the card, for the next run and for editing the post.
      final replaced = base.overrides.mediaIds;
      final extra = replaced == null ? null : {...base.overrides.extra, kTextCardReplacedMediaIdsKey: replaced};
      overrides = overrides.copyWith(mediaIds: [card.id], extra: extra);
    }
    if (storyOnly != null) overrides = overrides.copyWith(storyMediaIds: [storyOnly.id]);
    p = p.withTarget(base.copyWith(overrides: overrides));
  }
  backdrop?.dispose();

  final keep = <String, MediaAttachment>{for (final m in made.values) m.id: m};
  for (final m in cards.values) {
    if (!used.contains(m.id)) await s.media.discard(m);
  }
  // The photo picked only for the cards stays with the post while it is the
  // background; one that was replaced is deleted, unless another post (a
  // duplicate) or one of this post's photos still uses the file.
  final keptBackground = ownPhoto ? null : backgroundPhoto;
  // Read before the loop (the 1.2.1 AOT crash: a null-guarded field load
  // hoisted out of a loop).
  final keptBackgroundId = keptBackground?.id;
  final dropped = [for (final m in backgrounds) if (m.id != keptBackgroundId) m];
  if (dropped.isNotEmpty) {
    final inUse = {
      for (final m in userPhotos.values) m.path,
      ?keptBackground?.path,
      for (final other in await s.posts.all())
        if (other.id != post.id) ...other.media.map((m) => m.path),
    };
    for (final m in dropped) {
      if (!inUse.contains(m.path)) await s.media.discard(m);
    }
  }
  return withCardEmphasis(
      p.copyWith(media: [
        ...p.media.where((m) => !m.isTextCard),
        ...keep.values,
        ?keptBackground,
      ]),
      marked: emphasis);
}

/// The style of the cards already on [post], if any.
TextCardTheme? textCardThemeOfPost(Post post) {
  for (final m in post.media) {
    if (!isRenderedTextCard(m)) continue;
    final t = textCardThemeOf(m);
    if (t != null) return t;
  }
  return null;
}

/// The font of the cards already on [post], if any.
TextCardFont? textCardFontOfPost(Post post) {
  for (final m in post.media) {
    if (isRenderedTextCard(m)) return textCardFontOf(m);
  }
  return null;
}

/// The alignment of the cards already on [post], if any.
TextCardAlignment? textCardAlignmentOfPost(Post post) {
  for (final m in post.media) {
    if (isRenderedTextCard(m)) return textCardAlignmentOf(m);
  }
  return null;
}

/// The installed or imported font of the cards on [post] (1.3.1), as the
/// composer keeps it: CaptionFont.toJson, an empty map for cards in a
/// built-in font, null when the post has no card.
Map<String, dynamic>? textCardCustomFontOfPost(Post post) {
  for (final m in post.media) {
    if (isRenderedTextCard(m)) return textCardCustomFontOf(m)?.toJson() ?? const {};
  }
  return null;
}

/// The card designer's design of the cards on [post] (1.3.1), as the composer
/// keeps it: the design written on the post's targets, else the one its
/// cards were drawn from (an empty map for classic cards); null when the post
/// has neither.
Map<String, dynamic>? textCardDesignOfPost(Post post) {
  final chosen = textCardDesignChoiceOfPost(post);
  if (chosen != null) return chosen;
  for (final m in post.media) {
    if (isRenderedTextCard(m)) return textCardDesignOf(m)?.toJson() ?? const {};
  }
  return null;
}

/// The background photo of the cards on [post], as the composer keeps it
/// ([TextCardBackground.toJson]); null for a plain colour.
Map<String, dynamic>? textCardBackgroundOfPost(Post post) => _backgroundOfPost(post)?.toJson();

TextCardBackground? _backgroundOfPost(Post post) {
  final byId = {for (final m in post.media) m.id: m};
  for (final m in post.media) {
    if (!isRenderedTextCard(m)) continue;
    final p = textCardParametersOf(m);
    if (p == null) continue;
    final raw = p['background'];
    return raw is Map ? TextCardBackground.fromRenderParameters(Map<String, dynamic>.from(raw), (id) => byId[id]) : null;
  }
  // Saved while no network needed a card: only the background entry is left,
  // with the choices recorded on it.
  final kept = post.media.where(isTextCardBackground).firstOrNull;
  return kept == null ? null : TextCardBackground.fromRenderParameters(kept.renderParameters, (_) => kept);
}

/// [post] as the composer should show it: generated cards, card backgrounds
/// and fitted photos removed (they are rebuilt on save), the original photos
/// listed again (a target's own list where a card took its place), and no
/// story copies (Post + Story makes them again on save).
Post withoutTextCards(Post post) {
  post = withoutFittedPhotos(post);
  if (post.targets.any((t) => t.overrides.storyMediaIds != null)) {
    post = post.copyWith(targets: [for (final t in post.targets) t.copyWith(overrides: t.overrides.copyWith(clearStoryMediaIds: true))]);
  }
  final ids = {for (final m in post.media.where((m) => m.isTextCard)) m.id};
  if (ids.isEmpty) return post;
  return post.copyWith(
    media: post.media.where((m) => !m.generated).toList(),
    targets: [
      for (final t in post.targets)
        if (t.overrides.mediaIds == null)
          t
        else
          () {
            final rest = t.overrides.mediaIds!.where((id) => !ids.contains(id)).toList();
            final onlyCards = rest.isEmpty && t.overrides.mediaIds!.isNotEmpty;
            return t.copyWith(overrides: _withOwnMediaIds(t.overrides, onlyCards ? _replacedMediaIds(t.overrides) : rest));
          }(),
    ],
  );
}

/// Platform id -> whether its card on [post] carries the signature, for the
/// composer when a saved post is edited again.
Map<String, bool> textCardBrandingOfPost(Post post, String? Function(String accountId) platformOf) =>
    _perNetwork(post, platformOf, textCardBrandedOf);

/// Platform id -> whether its card on [post] shows the @handle, for the
/// composer when a saved post is edited again.
Map<String, bool> textCardHandleOfPost(Post post, String? Function(String accountId) platformOf) =>
    _perNetwork(post, platformOf, textCardShowsHandleOf);

Map<String, bool> _perNetwork(Post post, String? Function(String accountId) platformOf, bool Function(MediaAttachment card) read) {
  final cards = {for (final m in post.media.where(isRenderedTextCard)) m.id: m};
  final out = <String, bool>{};
  for (final t in post.targets) {
    final card = t.overrides.mediaIds?.map((id) => cards[id]).whereType<MediaAttachment>().firstOrNull;
    final platform = platformOf(t.accountId);
    if (card != null && platform != null) out[platform] = read(card);
  }
  return out;
}
