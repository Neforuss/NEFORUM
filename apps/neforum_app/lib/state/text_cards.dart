import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/text_card.dart';
import 'fitted_photos.dart';
import 'services.dart';
import 'settings.dart';

/// Gives every target that needs an image but has none (Instagram,
/// Pinterest, TikTok photos, Snapchat) a rendered NEFORUM text card, and
/// removes cards that are no longer needed. Safe to call repeatedly: a
/// card whose words, style and size still match is kept.
///
/// Cards are ordinary media files marked [MediaAttachment.generated]; only
/// the targets that list them in their overrides receive them.
///
/// [branded] picks the NEFORUM signature per network (platform id); otherwise
/// a target keeps the choice its current card was made with, else the
/// Settings default.
Future<Post> attachTextCards(AppServices s, Post post, AppSettings settings,
    {TextCardTheme? theme, TextCardFont? font, Map<String, bool> branded = const {}}) async {
  final cards = {for (final m in post.media.where((m) => m.isTextCard)) m.id: m};
  if (!settings.textCards && cards.isEmpty) return post;
  final style = theme ?? textCardThemeOfPost(post) ?? settings.textCardTheme;
  final face = font ?? textCardFontOfPost(post) ?? settings.textCardFont;
  final resolver = VariantResolver(settings.resolverOptions);
  final made = <String, MediaAttachment>{};
  final used = <String>{};
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
    if (!qualifiesForTextCard(d, variant)) continue;

    final text = textCardText(p, base);
    final size = textCardSize(d.id);
    final byline = account.handle ?? account.displayName;
    final signed = branded[d.id] ?? (oldCard == null ? null : textCardBrandedOf(oldCard)) ?? settings.textCardBranded(d.id);
    final key = '${size.width}x${size.height}|${style.name}|${face.name}|$signed|$byline|$text';
    var card = made[key];
    card ??= cards.values.where((m) =>
        m.width == size.width.round() &&
        m.height == size.height.round() &&
        textCardThemeOf(m) == style &&
        textCardFontOf(m) == face &&
        textCardBrandedOf(m) == signed &&
        m.altText == textCardAltText(text)).firstOrNull;
    if (card == null) {
      try {
        final bytes = await renderTextCardJpeg(text: text, theme: style, size: size, byline: byline, branded: signed, font: face);
        final m = await s.media.importBytes(bytes, fileName: textCardFileName(style, branded: signed, font: face), mimeHint: 'image/jpeg');
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

  final keep = <String, MediaAttachment>{for (final m in made.values) m.id: m};
  for (final m in cards.values) {
    if (!used.contains(m.id)) await s.media.discard(m);
  }
  return p.copyWith(media: [...p.media.where((m) => !m.isTextCard), ...keep.values]);
}

/// The style of the cards already on [post], if any.
TextCardTheme? textCardThemeOfPost(Post post) {
  for (final m in post.media) {
    if (!m.isTextCard) continue;
    final t = textCardThemeOf(m);
    if (t != null) return t;
  }
  return null;
}

/// The font of the cards already on [post], if any.
TextCardFont? textCardFontOfPost(Post post) {
  for (final m in post.media) {
    if (m.isTextCard) return textCardFontOf(m);
  }
  return null;
}

/// [post] as the composer should show it: generated cards and fitted photos
/// removed (they are rebuilt on save), the original photos listed again.
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
Map<String, bool> textCardBrandingOfPost(Post post, String? Function(String accountId) platformOf) {
  final cards = {for (final m in post.media.where((m) => m.isTextCard)) m.id: m};
  final out = <String, bool>{};
  for (final t in post.targets) {
    final card = t.overrides.mediaIds?.map((id) => cards[id]).whereType<MediaAttachment>().firstOrNull;
    final platform = platformOf(t.accountId);
    if (card != null && platform != null) out[platform] = textCardBrandedOf(card);
  }
  return out;
}
