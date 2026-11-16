import 'dart:convert';

import '../model/article.dart';
import '../text/url_detector.dart';
import 'article_render.dart';

// HTML serializers of an article: WordPress block markup (Gutenberg), Ghost's
// HTML with its card markup, and plain semantic HTML (Micropub, hand-offs).

/// Escapes text for HTML element content and attribute values.
String articleEscapeHtml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');

/// [text] escaped, its `http(s)://` addresses made links and its line breaks
/// `<br>`.
String _linkified(String text) {
  final lines = text.split('\n');
  return lines.map((line) {
    final buf = StringBuffer();
    var pos = 0;
    for (final u in UrlDetector.find(line).where((u) => u.hasScheme)) {
      if (u.start < pos) continue;
      buf.write(articleEscapeHtml(line.substring(pos, u.start)));
      final href = articleEscapeHtml(u.text);
      buf.write('<a href="$href">$href</a>');
      pos = u.end;
    }
    buf.write(articleEscapeHtml(line.substring(pos)));
    return buf.toString();
  }).join('<br>');
}

String _markedHtml(ArticleSpan s) {
  var t = s.isPlain ? _linkified(s.text) : articleEscapeHtml(s.text).replaceAll('\n', '<br>');
  if (s.code) t = '<code>$t</code>';
  if (s.italic) t = '<em>$t</em>';
  if (s.bold) t = '<strong>$t</strong>';
  return t;
}

/// [spans] as inline HTML: `<strong>`, `<em>`, `<code>`, `<a href>`; text
/// without marks gets its bare addresses linked, as the blogs always did.
String articleInlineHtml(List<ArticleSpan> spans) {
  final out = StringBuffer();
  var i = 0;
  while (i < spans.length) {
    final link = spans[i].link;
    if (link == null) {
      out.write(_markedHtml(spans[i]));
      i++;
      continue;
    }
    final inside = StringBuffer();
    while (i < spans.length && spans[i].link == link) {
      final s = spans[i];
      var t = articleEscapeHtml(s.text).replaceAll('\n', '<br>');
      if (s.code) t = '<code>$t</code>';
      if (s.italic) t = '<em>$t</em>';
      if (s.bold) t = '<strong>$t</strong>';
      inside.write(t);
      i++;
    }
    out.write('<a href="${articleEscapeHtml(link)}">$inside</a>');
  }
  return out.toString();
}

/// The cover's asset, reporting a cover whose file the network does not get.
ArticleAsset? articleCover(ArticleDocument doc, ArticleAssets assets, ArticleReportBuilder r) {
  final cover = doc.cover;
  if (cover == null) return null;
  final asset = assets.find(cover.mediaId);
  if (asset == null) {
    r.dropped('media_unavailable', '${r.network} does not get the cover image\'s file, so the article has no cover there',
        blockId: ArticleDocument.coverId);
  }
  return asset;
}

/// The items of a gallery the network gets, reporting the others.
List<(ArticleMediaRef, ArticleAsset)> articleGalleryItems(ArticleGallery g, ArticleAssets assets, ArticleReportBuilder r) {
  final out = <(ArticleMediaRef, ArticleAsset)>[];
  for (final ref in g.items) {
    final a = assets.find(ref.mediaId);
    if (a != null && a.media.isImage) out.add((ref, a));
  }
  final missing = g.items.length - out.length;
  if (out.isEmpty) {
    r.mediaUnavailable(g);
  } else if (missing > 0) {
    r.dropped('gallery_partial', '${r.network} does not get $missing of the photos of this gallery; the others are shown', blockId: g.id);
  }
  return out;
}

// ------------------------------------------------------------- Gutenberg

/// WordPress block editor markup for [doc]: each block between its
/// `<!-- wp:name {attrs} -->` comments, as the block editor saves it
/// (core/paragraph, core/heading, core/list with core/list-item,
/// core/quote, core/code, core/separator, core/image, core/gallery,
/// core/video, core/audio, core/embed), so the post opens in the editor as
/// blocks, not one Classic block. Uploaded files are found in [assets];
/// their [ArticleAsset.remoteId] is the WordPress media id.
///
/// The cover is not in the content: it is the post's `featured_media`
/// ([articleCover]). Citations, captions and credits are kept; WordPress
/// has every block an article has, so the report only lists files it does
/// not get and the article fields it has no place for (subtitle, canonical
/// URL).
ArticleRender<String> renderGutenberg(ArticleDocument doc, ArticleAssets assets, {String network = 'WordPress'}) {
  final r = ArticleReportBuilder(network);
  const ArticleFieldSupport(canonicalUrl: false).reportFields(doc, r);
  articleCover(doc, assets, r);
  final out = <String>[];
  for (final b in doc.blocks) {
    final s = _gutenbergBlock(b, assets, r);
    if (s != null) out.add(s);
  }
  return ArticleRender(out.join('\n\n'), r.build());
}

String _comment(String name, Map<String, Object?> attrs, String inner) {
  final a = attrs.isEmpty ? '' : ' ${jsonEncode(attrs)}';
  return '<!-- wp:$name$a -->\n$inner\n<!-- /wp:$name -->';
}

String _gutenbergParagraph(String html) => _comment('paragraph', const {}, '<p>$html</p>');

String _caption(String text, {String cls = 'wp-element-caption'}) =>
    text.isEmpty ? '' : '<figcaption class="$cls">${articleEscapeHtml(text)}</figcaption>';

String _gutenbergImage(ArticleMediaRef ref, ArticleAsset a) {
  final id = a.remoteId;
  final alt = articleEscapeHtml(ref.altFor(a.media));
  final attrs = <String, Object?>{if (id is int) 'id': id, 'sizeSlug': 'large', 'linkDestination': 'none'};
  final cls = id is int ? ' class="wp-image-$id"' : '';
  return _comment('image', attrs,
      '<figure class="wp-block-image size-large"><img src="${articleEscapeHtml(a.url)}" alt="$alt"$cls/>${_caption(ref.captionLine)}</figure>');
}

String? _gutenbergBlock(ArticleBlock b, ArticleAssets assets, ArticleReportBuilder r) {
  switch (b) {
    case ArticleParagraph(:final spans):
      final html = articleInlineHtml(spans);
      return html.isEmpty ? null : _gutenbergParagraph(html);
    case ArticleHeading(:final spans):
      final level = b.safeLevel;
      return _comment('heading', {if (level != 2) 'level': level}, '<h$level class="wp-block-heading">${articleInlineHtml(spans)}</h$level>');
    case ArticleList(:final items, :final ordered, :final start):
      final tag = ordered ? 'ol' : 'ul';
      final startAttr = ordered && start != 1 ? ' start="$start"' : '';
      final lis = [for (final item in items) _comment('list-item', const {}, '<li>${articleInlineHtml(item)}</li>')].join('\n\n');
      return _comment('list', {if (ordered) 'ordered': true, if (ordered && start != 1) 'start': start},
          '<$tag$startAttr class="wp-block-list">$lis</$tag>');
    case ArticleQuote(:final spans, :final citation):
      final cite = articleText(citation);
      return _comment('quote', const {},
          '<blockquote class="wp-block-quote">${_gutenbergParagraph(articleInlineHtml(spans))}${cite == null ? '' : '<cite>${articleEscapeHtml(cite)}</cite>'}</blockquote>');
    case ArticleCode(:final code, :final language):
      final lang = articleText(language)?.replaceAll(RegExp(r'[^A-Za-z0-9_+#.-]'), '');
      final cls = lang == null || lang.isEmpty ? '' : ' language-$lang';
      return _comment('code', {if (cls.isNotEmpty) 'className': cls.trim()},
          '<pre class="wp-block-code$cls"><code>${articleEscapeHtml(code)}</code></pre>');
    case ArticleDivider():
      return _comment('separator', const {}, '<hr class="wp-block-separator has-alpha-channel-opacity"/>');
    case ArticleImage(:final media):
      final a = assets.find(media.mediaId);
      if (a == null || !a.media.isImage) {
        r.mediaUnavailable(b);
        return null;
      }
      return _gutenbergImage(media, a);
    case ArticleGallery(:final caption):
      final items = articleGalleryItems(b, assets, r);
      if (items.isEmpty) return null;
      final inner = [for (final (ref, a) in items) _gutenbergImage(ref, a)].join('\n\n');
      final cap = articleText(caption);
      return _comment('gallery', const {'linkTo': 'none'},
          '<figure class="wp-block-gallery has-nested-images columns-default is-cropped">$inner${cap == null ? '' : _caption(cap, cls: 'blocks-gallery-caption wp-element-caption')}</figure>');
    case ArticleVideo(:final media):
      final a = assets.find(media.mediaId);
      if (a == null || !a.media.isVideo) {
        r.mediaUnavailable(b);
        return null;
      }
      final id = a.remoteId;
      return _comment('video', {if (id is int) 'id': id},
          '<figure class="wp-block-video"><video controls src="${articleEscapeHtml(a.url)}"></video>${_caption(media.captionLine)}</figure>');
    case ArticleAudio(:final media):
      final a = assets.find(media.mediaId);
      if (a == null || !a.media.isAudio) {
        r.mediaUnavailable(b);
        return null;
      }
      final id = a.remoteId;
      return _comment('audio', {if (id is int) 'id': id},
          '<figure class="wp-block-audio"><audio controls src="${articleEscapeHtml(a.url)}"></audio>${_caption(media.captionLine)}</figure>');
    case ArticleEmbed(:final url, :final caption):
      final u = articleEscapeHtml(url.trim());
      return _comment('embed', {'url': url.trim()},
          '<figure class="wp-block-embed"><div class="wp-block-embed__wrapper">\n$u\n</div>${_caption(articleText(caption) ?? '')}</figure>');
    case ArticleUnknownBlock():
      r.unknown(b);
      return null;
  }
}

// ----------------------------------------------------------------- Ghost

/// Ghost Admin API HTML (`POST posts/?source=html`) for [doc]. Ghost turns
/// it into its editor's cards: `<figure class="kg-card kg-image-card">` an
/// image card with its caption, `kg-gallery-card` a gallery, `<pre><code>` a
/// code card, `<hr>` a divider, `<blockquote>` a quote. Sound files go in an
/// HTML card (Ghost's HTML import drops an `<audio>` it does not know), with
/// [audioHtml] from the adapter. An embed becomes a link (Ghost makes embed
/// cards only from its own editor), reported.
///
/// The cover is the post's `feature_image` ([articleCover]); with no
/// excerpt, the subtitle becomes `custom_excerpt`, which Ghost shows under
/// the title.
ArticleRender<String> renderGhostHtml(ArticleDocument doc, ArticleAssets assets,
    {String network = 'Ghost', String Function(ArticleMediaRef ref, ArticleAsset asset)? audioHtml, String? excerptOverride}) {
  final r = ArticleReportBuilder(network);
  const ArticleFieldSupport(canonicalUrl: true, subtitleAsExcerpt: true).reportFields(doc, r, excerptOverride: excerptOverride);
  articleCover(doc, assets, r);
  final out = <String>[];
  for (final b in doc.blocks) {
    final s = _ghostBlock(b, assets, r, audioHtml);
    if (s != null && s.isNotEmpty) out.add(s);
  }
  return ArticleRender(out.join('\n'), r.build());
}

String _ghostImage(ArticleMediaRef ref, ArticleAsset a) {
  final cap = ref.captionLine;
  final size = [
    if (a.media.width != null) ' width="${a.media.width}"',
    if (a.media.height != null) ' height="${a.media.height}"',
  ].join();
  return '<figure class="kg-card kg-image-card${cap.isEmpty ? '' : ' kg-card-hascaption'}">'
      '<img src="${articleEscapeHtml(a.url)}" class="kg-image" alt="${articleEscapeHtml(ref.altFor(a.media))}" loading="lazy"$size>'
      '${cap.isEmpty ? '' : '<figcaption>${articleEscapeHtml(cap)}</figcaption>'}</figure>';
}

String? _ghostBlock(ArticleBlock b, ArticleAssets assets, ArticleReportBuilder r, String Function(ArticleMediaRef, ArticleAsset)? audioHtml) {
  switch (b) {
    case ArticleVideo(:final media):
      final a = assets.find(media.mediaId);
      if (a == null || !a.media.isVideo) {
        r.mediaUnavailable(b);
        return null;
      }
      return '<!--kg-card-begin: html-->\n<figure class="kg-card kg-video-card"><video controls src="${articleEscapeHtml(a.url)}"></video>'
          '${media.hasCaptionLine ? '<figcaption>${articleEscapeHtml(media.captionLine)}</figcaption>' : ''}</figure>\n<!--kg-card-end: html-->';
    case ArticleAudio(:final media):
      final a = assets.find(media.mediaId);
      if (a == null || !a.media.isAudio) {
        r.mediaUnavailable(b);
        return null;
      }
      if (audioHtml != null) return audioHtml(media, a);
      return '<!--kg-card-begin: html-->\n<figure class="kg-card kg-audio-card"><audio controls preload="metadata" src="${articleEscapeHtml(a.url)}"></audio>'
          '${media.hasCaptionLine ? '<figcaption>${articleEscapeHtml(media.captionLine)}</figcaption>' : ''}</figure>\n<!--kg-card-end: html-->';
    case ArticleImage(:final media):
      final a = assets.find(media.mediaId);
      if (a == null || !a.media.isImage) {
        r.mediaUnavailable(b);
        return null;
      }
      return _ghostImage(media, a);
    case ArticleGallery(:final caption):
      final items = articleGalleryItems(b, assets, r);
      if (items.isEmpty) return null;
      final rows = <String>[];
      for (var i = 0; i < items.length; i += 3) {
        final row = items.sublist(i, i + 3 > items.length ? items.length : i + 3);
        rows.add('<div class="kg-gallery-row">${[
          for (final (ref, a) in row)
            '<div class="kg-gallery-image"><img src="${articleEscapeHtml(a.url)}"'
                '${a.media.width != null ? ' width="${a.media.width}"' : ''}${a.media.height != null ? ' height="${a.media.height}"' : ''}'
                ' loading="lazy" alt="${articleEscapeHtml(ref.altFor(a.media))}"></div>',
        ].join()}</div>');
      }
      final captions = [articleText(caption), for (final (ref, _) in items) if (ref.hasCaptionLine) ref.captionLine].nonNulls.toList();
      if (items.any((x) => x.$1.hasCaptionLine)) {
        r.degraded('gallery_captions', '${r.network} galleries have one caption; the photos\' own captions are added to it', blockId: b.id);
      }
      return '<figure class="kg-card kg-gallery-card kg-width-wide"><div class="kg-gallery-container">${rows.join()}</div>'
          '${captions.isEmpty ? '' : '<figcaption>${articleEscapeHtml(captions.join(' · '))}</figcaption>'}</figure>';
    case ArticleEmbed(:final url, :final caption):
      r.degraded('embed_as_link', '${r.network} makes embeds only in its own editor; the embed is sent as a link', blockId: b.id);
      final u = articleEscapeHtml(url.trim());
      final cap = articleText(caption);
      return '<p><a href="$u">${cap == null ? u : articleEscapeHtml(cap)}</a></p>';
    default:
      return semanticHtmlBlock(b, r);
  }
}

// ------------------------------------------------------------- semantic

/// A text block (paragraph, heading, list, quote, code, divider) as plain
/// semantic HTML; null for other blocks.
String? semanticHtmlBlock(ArticleBlock b, ArticleReportBuilder r) {
  switch (b) {
    case ArticleParagraph(:final spans):
      final html = articleInlineHtml(spans);
      return html.isEmpty ? null : '<p>$html</p>';
    case ArticleHeading(:final spans):
      return '<h${b.safeLevel}>${articleInlineHtml(spans)}</h${b.safeLevel}>';
    case ArticleList(:final items, :final ordered, :final start):
      final tag = ordered ? 'ol' : 'ul';
      final startAttr = ordered && start != 1 ? ' start="$start"' : '';
      return '<$tag$startAttr>${[for (final item in items) '<li>${articleInlineHtml(item)}</li>'].join()}</$tag>';
    case ArticleQuote(:final spans, :final citation):
      final cite = articleText(citation);
      return '<blockquote><p>${articleInlineHtml(spans)}${cite == null ? '' : '<br><cite>${articleEscapeHtml(cite)}</cite>'}</p></blockquote>';
    case ArticleCode(:final code, :final language):
      final lang = articleText(language)?.replaceAll(RegExp(r'[^A-Za-z0-9_+#.-]'), '');
      return '<pre><code${lang == null || lang.isEmpty ? '' : ' class="language-$lang"'}>${articleEscapeHtml(code)}</code></pre>';
    case ArticleDivider():
      return '<hr>';
    case ArticleUnknownBlock():
      r.unknown(b);
      return null;
    default:
      return null;
  }
}

/// Plain semantic HTML for [doc]: `<figure>` with `<img>`, `<video>` or
/// `<audio>` and a `<figcaption>`, galleries as one figure of photos, embeds
/// as links. For Micropub's `content: [{html}]` (cover: the `featured` and
/// `photo` properties, so [coverInBody] is false there) and for hand-offs,
/// where files are not uploaded: with [placeholders] each file shows as
/// "[Photo: name]" where the user adds it.
ArticleRender<String> renderSemanticHtml(ArticleDocument doc, ArticleAssets assets,
    {required String network, required ArticleFieldSupport fields, bool placeholders = false, bool coverInBody = false, String? excerptOverride}) {
  final r = ArticleReportBuilder(network);
  fields.reportFields(doc, r, excerptOverride: excerptOverride);
  final out = <String>[];
  if (placeholders) {
    r.degraded('media_by_hand', 'Files cannot be handed over with the text; each shows as [Photo: ...] where you add it in $network');
  }
  final cover = doc.cover;
  if (cover != null && (coverInBody || placeholders)) {
    final fig = _semanticFigure(ArticleImage(ArticleDocument.coverId, cover), assets, r, placeholders);
    if (fig != null) out.add(fig);
  } else if (!placeholders) {
    articleCover(doc, assets, r);
  }
  for (final b in doc.blocks) {
    final s = semanticHtmlBlock(b, r) ?? _semanticFigure(b, assets, r, placeholders);
    if (s != null && s.isNotEmpty) out.add(s);
  }
  return ArticleRender(out.join('\n'), r.build());
}

String _placeholder(String kind, ArticleMediaRef ref, ArticleAsset? a) {
  final name = articleText(a?.media.fileName) ?? articleText(ref.caption) ?? ref.mediaId;
  return '[$kind: $name]';
}

String? _semanticFigure(ArticleBlock b, ArticleAssets assets, ArticleReportBuilder r, bool placeholders) {
  String cap(String text) => text.isEmpty ? '' : '<figcaption>${articleEscapeHtml(text)}</figcaption>';
  switch (b) {
    case ArticleImage(:final media) || ArticleVideo(:final media) || ArticleAudio(:final media):
      final a = assets.find(media.mediaId);
      final kind = b is ArticleVideo ? 'Video' : (b is ArticleAudio ? 'Sound' : 'Photo');
      if (placeholders) {
        return '<p>${articleEscapeHtml(_placeholder(kind, media, a))}</p>${media.hasCaptionLine ? '<p><em>${articleEscapeHtml(media.captionLine)}</em></p>' : ''}';
      }
      final ok = a != null && (b is ArticleVideo ? a.media.isVideo : (b is ArticleAudio ? a.media.isAudio : a.media.isImage));
      if (!ok) {
        if (b.id == ArticleDocument.coverId) {
          r.dropped('media_unavailable', '${r.network} does not get the cover image\'s file, so the article has no cover there',
              blockId: ArticleDocument.coverId);
        } else {
          r.mediaUnavailable(b);
        }
        return null;
      }
      final src = articleEscapeHtml(a.url);
      final el = switch (b) {
        ArticleVideo() => '<video controls src="$src"></video>',
        ArticleAudio() => '<audio controls src="$src"></audio>',
        _ => '<img src="$src" alt="${articleEscapeHtml(media.altFor(a.media))}">',
      };
      return '<figure>$el${cap(media.captionLine)}</figure>';
    case ArticleGallery(:final items, :final caption):
      if (placeholders) {
        return [for (final ref in items) '<p>${articleEscapeHtml(_placeholder('Photo', ref, assets.find(ref.mediaId)))}</p>'].join();
      }
      final got = articleGalleryItems(b, assets, r);
      if (got.isEmpty) return null;
      final imgs = [
        for (final (ref, a) in got) '<img src="${articleEscapeHtml(a.url)}" alt="${articleEscapeHtml(ref.altFor(a.media))}">',
      ].join();
      final captions = [articleText(caption), for (final (ref, _) in got) if (ref.hasCaptionLine) ref.captionLine].nonNulls;
      return '<figure>$imgs${cap(captions.join(' · '))}</figure>';
    case ArticleEmbed(:final url, :final caption):
      r.degraded('embed_as_link', '${r.network} gets the embed as a link', blockId: b.id);
      final u = articleEscapeHtml(url.trim());
      final c = articleText(caption);
      return '<p><a href="$u">${c == null ? u : articleEscapeHtml(c)}</a></p>';
    default:
      return null;
  }
}
