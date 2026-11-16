import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

// 1.4.4: the composer's Article mode. The post is written as an article
// (ArticleDocument, kept as ComposerState.article and saved as Post.article)
// for the blogs, and the social networks get its short version: the post's
// text, files and paragraph links are kept in step with the article
// ([articlePlainFields]) on every change, so everything that reads the post
// text (counters, checks, Automatic only, drafts) works as it always did.
//
// Switching between the plain composer and the article never loses what was
// written: each switch remembers what it left ([ArticleModeMemory]), and
// switching back without changing anything gives it back exactly.

/// The platforms whose accounts make Article mode available: the ones that
/// take an article without being asked ([PlatformDescriptor.articleFormat]
/// set and no [PlatformDescriptor.articleOptionKey], which X Articles need).
bool takesArticle(PlatformDescriptor d) => d.articleFormat != null && d.articleOptionKey == null;

/// What the plain composer held when Article mode started.
@immutable
class PlainComposerSnapshot {
  const PlainComposerSnapshot({
    required this.text,
    required this.additionalParts,
    required this.mediaParts,
    required this.paragraphMedia,
    required this.mediaOrder,
  });

  final String text;
  final List<String> additionalParts;
  final Map<String, int> mediaParts;
  final ParagraphMediaLinks paragraphMedia;

  /// The ids of the attachments, in their order.
  final List<String> mediaOrder;
}

/// What the last switch between the plain composer and the article left
/// behind, so switching back gives it back. In memory only: a restart keeps
/// the post in the mode it was in.
@immutable
class ArticleModeMemory {
  const ArticleModeMemory({this.plain, this.madeArticle, this.article, this.leftText});

  /// Article mode started from this plain post...
  final PlainComposerSnapshot? plain;

  /// ...and made this article of it. Leaving with the article unchanged
  /// puts [plain] back exactly.
  final ArticleDocument? madeArticle;

  /// Article mode was left with this article...
  final ArticleDocument? article;

  /// ...which left this text in the plain composer. Coming back with the
  /// text unchanged puts [article] back exactly (captions, galleries,
  /// subtitle and all).
  final String? leftText;
}

/// The article made from a plain post: [text] (the thread's parts joined),
/// its [media] and [paragraphMedia] ([ArticleDocument.fromPlainText]). With
/// an [earlier] article (the one the user left, whose text has changed
/// since), what the text cannot hold comes along: its subtitle, excerpt,
/// slug, canonical URL, status, cover and each file's caption, alt text and
/// credit.
ArticleDocument articleFromPlain(String text, {required List<MediaAttachment> media, ParagraphMediaLinks paragraphMedia = const {}, ArticleDocument? earlier}) {
  final attached = {for (final m in media) m.id};
  final earlierCover = earlier?.cover;
  final keepCover = earlierCover != null && attached.contains(earlierCover.mediaId);
  var doc = ArticleDocument.fromPlainText(text, media: media, links: paragraphMedia, coverFromFirstImage: !keepCover && earlier?.cover == null);
  if (earlier == null) return doc;
  final refs = {for (final r in earlier.mediaRefs) r.mediaId: r};
  ArticleMediaRef carried(ArticleMediaRef r) {
    final e = refs[r.mediaId];
    return e == null ? r : ArticleMediaRef(r.mediaId, caption: e.caption, altText: e.altText, credit: e.credit);
  }

  doc = doc.copyWith(blocks: [
    for (final b in doc.blocks)
      // The cover is not shown a second time in the text.
      if (!(keepCover && b is ArticleImage && b.media.mediaId == earlierCover.mediaId))
        switch (b) {
          ArticleImage(:final media) => ArticleImage(b.id, carried(media)),
          ArticleVideo(:final media) => ArticleVideo(b.id, carried(media)),
          ArticleAudio(:final media) => ArticleAudio(b.id, carried(media)),
          _ => b,
        },
  ]);
  return ArticleDocument(
    blocks: doc.blocks,
    cover: keepCover ? earlierCover : doc.cover,
    subtitle: earlier.subtitle,
    excerpt: earlier.excerpt,
    slug: earlier.slug,
    canonicalUrl: earlier.canonicalUrl,
    status: earlier.status,
  );
}

/// The plain post fields an article sets: its short version's text, which
/// paragraph each file follows, and the attachments in the article's
/// reading order (cover first) with the files it does not show after them.
({String text, ParagraphMediaLinks paragraphMedia, List<MediaAttachment> media}) articlePlainFields(ArticleDocument doc, List<MediaAttachment> media) {
  final plain = doc.toPlainPost();
  final byId = {for (final m in media) m.id: m};
  final placed = [for (final id in plain.mediaIds) ?byId[id]];
  final placedIds = {for (final m in placed) m.id};
  return (
    text: plain.text,
    paragraphMedia: plain.paragraphMedia,
    media: [...placed, for (final m in media) if (!placedIds.contains(m.id)) m],
  );
}

/// [ids] (a network's left-out blocks) without the ones [doc] no longer has,
/// so a new block never inherits the choice made for a deleted one with the
/// same id.
List<String> presentBlockIds(List<String> ids, ArticleDocument doc) {
  final present = {for (final b in doc.blocks) b.id, if (doc.cover != null) ArticleDocument.coverId};
  return [for (final id in ids) if (present.contains(id)) id];
}

/// The last part of a post's address made from its [title], as the blogs
/// make it: lower case letters and digits joined by hyphens, accents
/// removed, at most 80 characters. Empty when the title has none.
String slugFromTitle(String title) {
  const accents = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'æ': 'ae', 'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', //
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'œ': 'oe', //
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y', 'ß': 'ss',
  };
  final out = StringBuffer();
  var dash = false;
  for (final ch in title.toLowerCase().split('')) {
    final c = accents[ch] ?? ch;
    if (RegExp(r'^[a-z0-9]+$').hasMatch(c)) {
      if (dash && out.isNotEmpty) out.write('-');
      out.write(c);
      dash = false;
    } else {
      dash = true;
    }
  }
  var slug = out.toString();
  if (slug.length > 80) {
    slug = slug.substring(0, 80);
    final cut = slug.lastIndexOf('-');
    if (cut > 40) slug = slug.substring(0, cut);
  }
  return slug;
}
