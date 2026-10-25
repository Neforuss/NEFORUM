import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/render_parameters.dart';
import '../media/text_card.dart';
import '../media/text_card_background.dart';
import 'fitted_photos.dart';
import 'services.dart';
import 'settings.dart';

/// A photo kept with the post only as the background of its text cards
/// ([TextCardBackground]): generated, listed by no target, never posted.
bool isTextCardBackground(MediaAttachment m) => m.generated && renderKindOf(m) == RenderKind.textCardBackground;

/// A rendered NEFORUM text card (not a card's background photo).
bool isRenderedTextCard(MediaAttachment m) => m.isTextCard && !isTextCardBackground(m);

/// Gives every target that needs an image but has none (Instagram,
/// Pinterest, TikTok photos, Snapchat) a rendered NEFORUM text card, and
/// removes cards that are no longer needed. Safe to call repeatedly: a
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
/// [isTextCardBackground].
Future<Post> attachTextCards(AppServices s, Post post, AppSettings settings,
    {TextCardTheme? theme,
    TextCardFont? font,
    Map<String, bool> branded = const {},
    TextCardAlignment? alignment,
    Map<String, bool> handle = const {},
    Map<String, dynamic>? background}) async {
  final cards = {for (final m in post.media.where(isRenderedTextCard)) m.id: m};
  final backgrounds = [for (final m in post.media) if (isTextCardBackground(m)) m];
  if (!settings.textCards && cards.isEmpty && backgrounds.isEmpty) return post;
  final style = theme ?? textCardThemeOfPost(post) ?? settings.textCardTheme;
  final face = font ?? textCardFontOfPost(post) ?? settings.textCardFont;
  final align = alignment ?? textCardAlignmentOfPost(post) ?? settings.textCardAlignment;
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
  final ownPhoto = chosenBackground != null && userPhotos.containsKey(chosenBackground.photo.id);
  final resolver = VariantResolver(settings.resolverOptions);
  final made = <String, MediaAttachment>{};
  final used = <String>{};
  TextCardBackdrop? backdrop;
  var backdropTried = false;
  var p = post;

  for (final original in post.targets) {
    final t = p.targetFor(original.accountId)!;
    final own = t.overrides.mediaIds;
    final oldCard = own?.map((id) => cards[id]).whereType<MediaAttachment>().firstOrNull;
    final userIds = own?.where((id) => !cards.containsKey(id)).toList();
    final onlyCards = own != null && own.isNotEmpty && userIds!.isEmpty;
    final base = t.copyWith(overrides: onlyCards ? t.overrides.copyWith(clearMediaIds: true) : t.overrides.copyWith(mediaIds: userIds));
    p = p.withTarget(base);
    if (!settings.textCards) continue;

    final account = await s.accounts.get(t.accountId);
    final adapter = account == null ? null : s.registry.byId(account.platformId);
    if (account == null || adapter == null) continue;
    final d = adapter.descriptorForAccount(account);
    final variant = resolver.resolve(p, base, d, account: account);
    if (!qualifiesForTextCard(d, variant, backgroundMediaId: ownPhoto ? chosenBackground.photo.id : null)) continue;

    if (chosenBackground != null && !backdropTried) {
      backdropTried = true;
      try {
        backdrop = await decodeTextCardBackdrop(await s.media.read(chosenBackground.photo), chosenBackground);
      } on Object catch (e) {
        debugPrint('Could not read the background photo of the text cards: $e');
      }
    }

    final text = textCardText(p, base);
    final size = textCardSize(d.id);
    final byline = account.handle ?? account.displayName;
    final signed = branded[d.id] ?? (oldCard == null ? null : textCardBrandedOf(oldCard)) ?? settings.textCardBranded(d.id);
    final showsHandle = handle[d.id] ?? (oldCard == null ? null : textCardShowsHandleOf(oldCard)) ?? settings.textCardShowsHandle(d.id);
    final safe = textCardSafeArea(d.id);
    final hasSafe = safe != EdgeInsets.zero;
    final params = textCardRenderParameters(
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
    );
    final key = '${size.width}x${size.height}|${stableHash(params.toString())}|$text';
    var card = made[key];
    // A card made before is reused only when it was rendered with exactly
    // these choices, for this network and this @handle; cards from before
    // 1.2.0 carry no parameters and are rendered again.
    card ??= cards.values
        .where((m) =>
            m.width == size.width.round() &&
            m.height == size.height.round() &&
            renderParametersEqual(m.renderParameters, params) &&
            m.altText == textCardAltText(text))
        .firstOrNull;
    if (card == null) {
      try {
        final bytes = await renderTextCardJpeg(
          text: text,
          theme: style,
          size: size,
          byline: showsHandle ? byline : null,
          branded: signed,
          font: face.resolve(d.id),
          safe: safe,
          alignment: align,
          backdrop: backdrop,
        );
        final m = await s.media.importBytes(bytes, fileName: textCardFileName(style, branded: signed, font: face, safe: hasSafe), mimeHint: 'image/jpeg');
        card = MediaAttachment(
          id: m.id,
          path: m.path,
          mimeType: 'image/jpeg',
          sizeBytes: m.sizeBytes,
          width: size.width.round(),
          height: size.height.round(),
          altText: textCardAltText(text),
          fileName: m.fileName,
          generated: true,
          renderParameters: params,
        );
      } on Object catch (e) {
        // Without the card the target fails validation with a clear
        // "needs an image" message, which is the right outcome.
        debugPrint('Could not render a text card for ${d.name}: $e');
        continue;
      }
    }
    made[key] = card;
    used.add(card.id);
    p = p.withTarget(base.copyWith(overrides: base.overrides.copyWith(mediaIds: [card.id])));
  }
  backdrop?.dispose();

  final keep = <String, MediaAttachment>{for (final m in made.values) m.id: m};
  for (final m in cards.values) {
    if (!used.contains(m.id)) await s.media.discard(m);
  }
  // The photo picked only for the cards stays with the post while it is the
  // background; one that was replaced is deleted, unless another post (a
  // duplicate) or one of this post's photos still uses the file.
  final keptBackground = chosenBackground != null && !ownPhoto ? chosenBackground.photo : null;
  final dropped = [for (final m in backgrounds) if (m.id != keptBackground?.id) m];
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
  return p.copyWith(media: [
    ...p.media.where((m) => !m.isTextCard),
    ...keep.values,
    ?keptBackground,
  ]);
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
/// listed again.
Post withoutTextCards(Post post) {
  post = withoutFittedPhotos(post);
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
            return t.copyWith(overrides: onlyCards ? t.overrides.copyWith(clearMediaIds: true) : t.overrides.copyWith(mediaIds: rest));
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
