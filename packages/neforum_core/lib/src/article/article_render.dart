import 'package:meta/meta.dart';

import '../model/article.dart';
import '../model/media.dart';
import '../model/paragraph_media.dart';
import '../model/validation.dart';
import '../text/url_detector.dart';

/// What happened to a block or field of an article on one network.
enum ArticleRenderOutcome {
  /// Not sent at all.
  dropped,

  /// Sent in another form (a gallery as photos one after the other, an embed
  /// as a link, a caption as a line of text).
  degraded,
}

/// One block or field a network cannot carry as written. [blockId] is the
/// block's id ([ArticleBlock.id], [ArticleDocument.coverId] for the cover);
/// [field] names an article field instead (`subtitle`, `excerpt`, `slug`,
/// `canonicalUrl`, `status`).
@immutable
class ArticleRenderIssue {
  const ArticleRenderIssue({
    required this.outcome,
    required this.code,
    required this.message,
    this.blockId,
    this.field,
  });

  final ArticleRenderOutcome outcome;

  /// Stable, for tests and the UI: `media_unavailable`, `gallery_as_images`...
  final String code;

  /// One plain sentence for the user, naming the network.
  final String message;
  final String? blockId;
  final String? field;

  bool get isDropped => outcome == ArticleRenderOutcome.dropped;

  @override
  bool operator ==(Object other) =>
      other is ArticleRenderIssue &&
      other.outcome == outcome &&
      other.code == code &&
      other.message == message &&
      other.blockId == blockId &&
      other.field == field;

  @override
  int get hashCode => Object.hash(outcome, code, message, blockId, field);

  @override
  String toString() => 'ArticleRenderIssue(${outcome.name} $code ${blockId ?? field ?? ''}: $message)';
}

/// What a network will not carry of an article, block by block: shown
/// before posting so nothing is lost without the user knowing. Empty when
/// the article goes out whole.
@immutable
class ArticleRenderReport {
  const ArticleRenderReport(this.issues);

  static const ArticleRenderReport empty = ArticleRenderReport([]);

  final List<ArticleRenderIssue> issues;

  bool get isLossless => issues.isEmpty;
  Iterable<ArticleRenderIssue> get dropped => issues.where((i) => i.outcome == ArticleRenderOutcome.dropped);
  Iterable<ArticleRenderIssue> get degraded => issues.where((i) => i.outcome == ArticleRenderOutcome.degraded);

  /// The issues about block [id].
  Iterable<ArticleRenderIssue> forBlock(String id) => issues.where((i) => i.blockId == id);

  /// The report as the variant's checks: a dropped block is a warning, a
  /// degraded one an info. Field `article`.
  List<ValidationIssue> toValidationIssues() => [
        for (final i in issues)
          i.isDropped
              ? ValidationIssue.warning('article.${i.code}', i.message, field: 'article')
              : ValidationIssue.info('article.${i.code}', i.message, field: 'article'),
      ];
}

/// A rendered article: the network's own [output] and what it could not
/// carry ([report]).
@immutable
class ArticleRender<T> {
  const ArticleRender(this.output, this.report);

  final T output;
  final ArticleRenderReport report;
}

/// One file of the article as it is on the network: uploaded (its address
/// and the network's id for it) or put on the media host.
@immutable
class ArticleAsset {
  const ArticleAsset(this.media, {required this.url, this.remoteId, this.extra = const {}});

  /// The file that was sent (the post's file, or the copy made for the
  /// network from it).
  final MediaAttachment media;

  /// Where the network serves it.
  final String url;

  /// The network's id for it: a WordPress media id, an EmDash media id, a
  /// Tumblr upload identifier, an X media id. Null when there is none.
  final Object? remoteId;

  /// Anything else the network gave back that its format repeats (EmDash:
  /// width, height, blurhash...).
  final Map<String, Object?> extra;
}

/// The uploaded files of an article, found by the id the article names them
/// with ([ArticleMediaRef.mediaId]): the file itself or a copy made from it.
@immutable
class ArticleAssets {
  const ArticleAssets(this.items);

  /// Assets for [media] at made-up addresses (`https://media.invalid/<id>`),
  /// for a report before anything is uploaded ([ArticleRenderer.report]).
  factory ArticleAssets.placeholders(List<MediaAttachment> media) => ArticleAssets([
        for (var i = 0; i < media.length; i++)
          ArticleAsset(media[i], url: 'https://media.invalid/${Uri.encodeComponent(media[i].id)}', remoteId: i + 1, extra: const {}),
      ]);

  static const ArticleAssets none = ArticleAssets([]);

  final List<ArticleAsset> items;

  /// The asset for [mediaId], or null when the network does not get it.
  ArticleAsset? find(String mediaId) =>
      items.where((a) => a.media.id == mediaId).firstOrNull ?? items.where((a) => ParagraphMedia.names(mediaId, a.media)).firstOrNull;
}

/// Collects a render's issues; shared by the serializers.
class ArticleReportBuilder {
  ArticleReportBuilder(this.network);

  /// The network's name, as messages show it.
  final String network;
  final List<ArticleRenderIssue> _issues = [];

  void dropped(String code, String message, {String? blockId, String? field}) =>
      _add(ArticleRenderIssue(outcome: ArticleRenderOutcome.dropped, code: code, message: message, blockId: blockId, field: field));

  void degraded(String code, String message, {String? blockId, String? field}) =>
      _add(ArticleRenderIssue(outcome: ArticleRenderOutcome.degraded, code: code, message: message, blockId: blockId, field: field));

  /// The same issue twice (a paragraph's every line with inline code) is
  /// reported once.
  void _add(ArticleRenderIssue issue) {
    if (!_issues.contains(issue)) _issues.add(issue);
  }

  /// A block whose file [network] does not get (its type is not taken, it is
  /// over the network's count, or the user left it out for this network).
  void mediaUnavailable(ArticleBlock b) =>
      dropped('media_unavailable', '$network does not get the file of this ${b.noun}, so the ${b.noun} is left out', blockId: b.id);

  /// A block of a kind this version does not know.
  void unknown(ArticleBlock b) =>
      dropped('unknown_block', 'This block was made by a newer NEFORUM and is left out on $network; update NEFORUM to send it', blockId: b.id);

  /// The caption of a file shown as a line of text (Markdown has no
  /// captions).
  void captionAsText(ArticleBlock b) =>
      degraded('caption_as_text', '$network has no captions; the caption goes in a line of text under the ${b.noun}', blockId: b.id);

  ArticleRenderReport build() => ArticleRenderReport(List.unmodifiable(_issues));
}

/// Which article fields a format has a place for. A field the article sets
/// that its format has no place for is reported by [reportFields].
@immutable
class ArticleFieldSupport {
  const ArticleFieldSupport({
    this.cover = true,
    this.subtitle = false,
    this.excerpt = true,
    this.slug = true,
    this.canonicalUrl = false,
    this.status = true,
    this.subtitleAsExcerpt = false,
    this.coverInBody = false,
  });

  final bool cover;
  final bool subtitle;
  final bool excerpt;
  final bool slug;
  final bool canonicalUrl;
  final bool status;

  /// No subtitle field, but the excerpt shows under the title (Ghost): the
  /// subtitle becomes the excerpt when the article has none.
  final bool subtitleAsExcerpt;

  /// No cover field: the cover goes at the top of the body (reported).
  final bool coverInBody;

  /// The fields of [doc] (and the post's per-network [overrides] of them,
  /// which count as set) that [network] cannot carry, into [r].
  void reportFields(ArticleDocument doc, ArticleReportBuilder r, {String? excerptOverride}) {
    final excerpt = (excerptOverride ?? doc.excerpt ?? '').trim();
    final subtitle = (doc.subtitle ?? '').trim();
    if (subtitle.isNotEmpty && !this.subtitle) {
      if (subtitleAsExcerpt && excerpt.isEmpty) {
        r.degraded('subtitle_as_excerpt', '${r.network} has no subtitle; it goes in the excerpt, which shows under the title', field: 'subtitle');
      } else {
        r.dropped('subtitle', '${r.network} has no subtitle field; the subtitle is left out', field: 'subtitle');
      }
    }
    if (excerpt.isNotEmpty && !this.excerpt) {
      r.dropped('excerpt', '${r.network} has no excerpt field; the excerpt is left out', field: 'excerpt');
    }
    if ((doc.slug ?? '').trim().isNotEmpty && !slug) {
      r.dropped('slug', '${r.network} makes the address itself; the slug is left out', field: 'slug');
    }
    if ((doc.canonicalUrl ?? '').trim().isNotEmpty && !canonicalUrl) {
      r.dropped('canonical_url', '${r.network} has no canonical URL field; it is left out', field: 'canonicalUrl');
    }
    if (doc.isDraft && !status) {
      r.degraded('status', '${r.network} has no drafts through its API; the article is published', field: 'status');
    }
    if (doc.cover != null && !cover && coverInBody) {
      r.degraded('cover_in_body', '${r.network} has no cover image; the cover goes at the top of the post', blockId: ArticleDocument.coverId);
    } else if (doc.cover != null && !cover) {
      r.dropped('cover', '${r.network} has no cover image; the cover is left out', blockId: ArticleDocument.coverId);
    }
  }
}

/// [spans] with the bare `http(s)://` addresses of their unmarked text made
/// links (the blogs have always linked them), for formats that keep links
/// as marks (Portable Text, NPF, X Articles).
List<ArticleSpan> articleAutolinked(List<ArticleSpan> spans) {
  final out = <ArticleSpan>[];
  for (final s in spans) {
    if (!s.isPlain) {
      out.add(s);
      continue;
    }
    var pos = 0;
    for (final u in UrlDetector.find(s.text).where((u) => u.hasScheme)) {
      if (u.start < pos) continue;
      if (u.start > pos) out.add(ArticleSpan(s.text.substring(pos, u.start)));
      out.add(ArticleSpan(u.text, link: u.normalized));
      pos = u.end;
    }
    if (pos < s.text.length) out.add(ArticleSpan(s.text.substring(pos)));
  }
  return out;
}

/// The trimmed text of [s], or null when it is empty.
String? articleText(String? s) {
  final t = s?.trim();
  return t == null || t.isEmpty ? null : t;
}
