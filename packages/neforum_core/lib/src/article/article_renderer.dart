import '../model/article.dart';
import '../model/media.dart';
import '../model/platform_descriptor.dart';
import '../model/post_variant.dart';
import 'article_html.dart';
import 'article_markdown.dart';
import 'article_npf.dart';
import 'article_portable_text.dart';
import 'article_render.dart';
import 'article_x.dart';

export 'article_html.dart' show articleEscapeHtml, articleInlineHtml, renderGhostHtml, renderGutenberg, renderSemanticHtml;
export 'article_markdown.dart' show ArticleMarkdownDialect, markdownEscape, markdownInline, renderMarkdown;
export 'article_npf.dart' show npfMaxImages, renderNpf;
export 'article_portable_text.dart' show renderPortableText;
export 'article_render.dart';
export 'article_x.dart' show renderXArticle, xPostUrl;

/// One entry point for every article format: what a network will not carry
/// of an article ([report]) and its native form ([render]).
abstract final class ArticleRenderer {
  /// The fields a hand-off can hand over (all of them, as text the user
  /// pastes: the title and subtitle in their own fields).
  static const ArticleFieldSupport handoffFields = ArticleFieldSupport(subtitle: true, canonicalUrl: true, cover: false, coverInBody: true);

  /// The fields Micropub has a property for: `featured` / `photo`, `summary`,
  /// `mp-slug`, `post-status`.
  static const ArticleFieldSupport micropubFields = ArticleFieldSupport();

  /// What [network] (in [format]) will not carry of [doc] when it gets the
  /// files [media] (the variant's: [PostVariant.media]), before anything is
  /// uploaded. The same serializer the adapter runs, on made-up file
  /// addresses, so the report and the post never disagree.
  ///
  /// [excerptOverride] is the network's own excerpt option when the post set
  /// one (it counts as an excerpt).
  static ArticleRenderReport report(ArticleDocument doc, ArticleFormat format,
          {required List<MediaAttachment> media, required String network, String? excerptOverride}) =>
      render(doc, format, ArticleAssets.placeholders(media), network: network, title: 'Title', excerptOverride: excerptOverride).report;

  /// The report for [v] on [d]: empty when the variant carries no article or
  /// [d] takes none.
  /// A hand-off account ([tier] [PlatformTier.handoff]) gets the hand-off's
  /// report: the article pasted as HTML, files added by hand.
  static ArticleRenderReport reportFor(PostVariant v, PlatformDescriptor d, {PlatformTier? tier}) {
    final doc = v.article;
    final format = tier == PlatformTier.handoff && d.articleFormat != null ? ArticleFormat.handoffHtml : d.articleFormat;
    if (doc == null || format == null) return ArticleRenderReport.empty;
    return report(doc, format, media: v.media, network: d.name, excerptOverride: excerptOption(v.extra, format));
  }

  /// The network's own excerpt option in [extra] ([PostVariant.extra]) for
  /// [format], when set: it counts as the article's excerpt.
  static String? excerptOption(Map<String, dynamic> extra, ArticleFormat format) {
    final key = switch (format) {
      ArticleFormat.devtoMarkdown => 'description',
      ArticleFormat.gutenberg || ArticleFormat.ghostHtml || ArticleFormat.portableText => 'excerpt',
      _ => null,
    };
    final v = key == null ? null : extra[key];
    return v is String ? articleText(v) : null;
  }

  /// [doc] in [format] with the uploaded files [assets]. [title] is used by
  /// the formats that put it in the body (NPF, X); [tags] by WriteFreely.
  /// The output is a String (HTML, Markdown), a `List<Map>` (Portable
  /// Text) or a `Map` (NPF, X).
  static ArticleRender<Object> render(ArticleDocument doc, ArticleFormat format, ArticleAssets assets,
      {required String network, String title = '', List<String> tags = const [], String keyPrefix = 'k', String? excerptOverride}) {
    return switch (format) {
      ArticleFormat.gutenberg => renderGutenberg(doc, assets, network: network),
      ArticleFormat.ghostHtml => renderGhostHtml(doc, assets, network: network, excerptOverride: excerptOverride),
      ArticleFormat.portableText => renderPortableText(doc, assets, keyPrefix: keyPrefix, network: network),
      ArticleFormat.devtoMarkdown =>
        renderMarkdown(doc, assets, dialect: ArticleMarkdownDialect.devto, network: network, excerptOverride: excerptOverride),
      ArticleFormat.hashnodeMarkdown => renderMarkdown(doc, assets, dialect: ArticleMarkdownDialect.hashnode, network: network),
      ArticleFormat.writeFreelyMarkdown => renderMarkdown(doc, assets, dialect: ArticleMarkdownDialect.writeFreely, network: network, tags: tags),
      ArticleFormat.micropubHtml => renderSemanticHtml(doc, assets, network: network, fields: micropubFields),
      ArticleFormat.tumblrNpf => renderNpf(doc, assets, title: title, network: network),
      ArticleFormat.handoffHtml => renderSemanticHtml(doc, assets, network: network, fields: handoffFields, placeholders: true),
      ArticleFormat.xArticle => renderXArticle(doc, assets, title: title, network: network),
    };
  }

  /// [doc] as clean HTML and Markdown for a hand-off (Substack, or any blog
  /// posted by hand): files as "[Photo: ...]" markers where the user adds
  /// them.
  static ({String html, String markdown, ArticleRenderReport report}) handoff(ArticleDocument doc,
      {required String network, List<MediaAttachment> media = const []}) {
    final assets = ArticleAssets.placeholders(media);
    final html = renderSemanticHtml(doc, assets, network: network, fields: handoffFields, placeholders: true);
    String name(ArticleMediaRef ref) => articleText(assets.find(ref.mediaId)?.media.fileName) ?? articleText(ref.caption) ?? 'file';
    final withMarkers = doc.copyWith(clearCover: true, blocks: [
      if (doc.cover case final c?) ArticleParagraph.plain(ArticleDocument.coverId, '[Photo: ${name(c)}]'),
      for (final b in doc.blocks)
        switch (b) {
          ArticleImage(:final media) => ArticleParagraph.plain(b.id, '[Photo: ${name(media)}]'),
          ArticleVideo(:final media) => ArticleParagraph.plain(b.id, '[Video: ${name(media)}]'),
          ArticleAudio(:final media) => ArticleParagraph.plain(b.id, '[Sound: ${name(media)}]'),
          ArticleGallery(:final items) => ArticleParagraph.plain(b.id, items.map((m) => '[Photo: ${name(m)}]').join('\n')),
          _ => b,
        },
    ]);
    final md = renderMarkdown(withMarkers, ArticleAssets.none, dialect: ArticleMarkdownDialect.commonMark, network: network);
    return (html: html.output, markdown: md.output, report: html.report);
  }
}
