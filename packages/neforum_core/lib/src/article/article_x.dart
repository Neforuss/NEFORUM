import '../model/article.dart';
import '../model/media.dart';
import 'article_render.dart';

/// The status-post address an embed must have to become an embedded post
/// (`post` entity) in an X Article.
final RegExp xPostUrl = RegExp(r'^https?://(?:www\.|mobile\.)?(?:x|twitter)\.com/[A-Za-z0-9_]{1,15}/status(?:es)?/(\d{1,19})(?:[/?#].*)?$');

/// [doc] as the body of `POST /2/articles/draft` (docs.x.com, "Create draft
/// Article"): `{title, content_state: {blocks, entities}, cover_media}`.
///
/// Text blocks are `unstyled`, `header-one` (headings 1-2), `header-two`
/// (3-6), `unordered-list-item`, `ordered-list-item` and `blockquote`, with
/// `bold` and `italic` inline style ranges and `link` entities, at UTF-16
/// offsets (DraftJS counts JavaScript string positions). Photos, galleries,
/// code, dividers and embedded posts are `atomic` blocks (text " ") over an
/// entity: `image` (`media_items` with the X media ids,
/// [ArticleAsset.remoteId], and the `caption`), `markdown` (a fenced code
/// block), `divider`, `post` (`post_id`, for an x.com status address).
///
/// X Articles take no video, sound file, inline code or other embed through
/// the API, and have no subtitle, excerpt, slug or canonical URL: reported.
ArticleRender<Map<String, Object?>> renderXArticle(ArticleDocument doc, ArticleAssets assets, {required String title, String network = 'X'}) {
  final r = ArticleReportBuilder(network);
  const ArticleFieldSupport(excerpt: false, slug: false).reportFields(doc, r);
  final blocks = <Map<String, Object?>>[];
  final entities = <Map<String, Object?>>[];
  var n = 0;
  String key() => 'b${n++}';

  int entity(String type, String mutability, Map<String, Object?> data) {
    entities.add({
      'key': '${entities.length}',
      'value': {'type': type, 'mutability': mutability, 'data': data},
    });
    return entities.length - 1;
  }

  void atomic(String type, String mutability, Map<String, Object?> data) {
    final k = entity(type, mutability, data);
    blocks.add({
      'key': key(),
      'text': ' ',
      'type': 'atomic',
      'inline_style_ranges': const <Object>[],
      'entity_ranges': [
        {'offset': 0, 'length': 1, 'key': k},
      ],
    });
  }

  void text(List<ArticleSpan> spans, String type, String? blockId) {
    final styles = <Map<String, Object?>>[];
    final ranges = <Map<String, Object?>>[];
    final out = StringBuffer();
    var codeSeen = false;
    final linked = articleAutolinked(spans);
    var i = 0;
    while (i < linked.length) {
      final s = linked[i];
      final link = s.link;
      final start = out.length;
      if (link == null) {
        out.write(s.text);
        if (s.bold) styles.add({'offset': start, 'length': s.text.length, 'style': 'bold'});
        if (s.italic) styles.add({'offset': start, 'length': s.text.length, 'style': 'italic'});
        if (s.code) codeSeen = true;
        i++;
        continue;
      }
      // One link entity over the spans that share the address.
      while (i < linked.length && linked[i].link == link) {
        final p = linked[i];
        final at = out.length;
        out.write(p.text);
        if (p.bold) styles.add({'offset': at, 'length': p.text.length, 'style': 'bold'});
        if (p.italic) styles.add({'offset': at, 'length': p.text.length, 'style': 'italic'});
        if (p.code) codeSeen = true;
        i++;
      }
      ranges.add({'offset': start, 'length': out.length - start, 'key': entity('link', 'mutable', {'url': link})});
    }
    if (codeSeen) r.degraded('inline_code', '$network Articles have no inline code; it is plain text', blockId: blockId);
    if (out.isEmpty) return;
    blocks.add({
      'key': key(),
      'text': out.toString(),
      'type': type,
      'inline_style_ranges': styles,
      'entity_ranges': ranges,
    });
  }

  Map<String, Object?>? item(ArticleAsset a) =>
      a.remoteId == null ? null : {'media_category': a.media.kind == MediaKind.gif ? 'tweet_gif' : 'tweet_image', 'media_id': '${a.remoteId}'};

  Map<String, Object?>? coverMedia;
  final cover = doc.cover;
  if (cover != null) {
    final a = assets.find(cover.mediaId);
    if (a == null || !a.media.isImage || item(a) == null) {
      r.dropped('media_unavailable', '$network does not get the cover image\'s file, so the article has no cover there',
          blockId: ArticleDocument.coverId);
    } else {
      coverMedia = item(a);
    }
  }

  for (final b in doc.blocks) {
    switch (b) {
      case ArticleParagraph(:final spans):
        text(spans, 'unstyled', b.id);
      case ArticleHeading(:final spans):
        text(spans, b.safeLevel <= 2 ? 'header-one' : 'header-two', b.id);
      case ArticleQuote(:final spans, :final citation):
        final cite = articleText(citation);
        text([...spans, if (cite != null) ArticleSpan('\n$cite', marks: const {ArticleMark.italic})], 'blockquote', b.id);
      case ArticleList(:final items, :final ordered, :final start):
        if (ordered && start != 1) {
          r.degraded('list_start', '$network numbers every list from 1; this list started at $start', blockId: b.id);
        }
        for (final it in items) {
          text(it, ordered ? 'ordered-list-item' : 'unordered-list-item', b.id);
        }
      case ArticleCode(:final code, :final language):
        final lang = articleText(language)?.replaceAll(RegExp(r'[^A-Za-z0-9_+#.-]'), '') ?? '';
        var longest = 0;
        for (final m in RegExp('`+').allMatches(code)) {
          if (m.end - m.start > longest) longest = m.end - m.start;
        }
        final fence = '`' * (longest < 3 ? 3 : longest + 1);
        atomic('markdown', 'mutable', {'markdown': '$fence$lang\n$code\n$fence'});
      case ArticleDivider():
        atomic('divider', 'immutable', const {});
      case ArticleImage(:final media):
        final a = assets.find(media.mediaId);
        final it = a == null || !a.media.isImage ? null : item(a);
        if (it == null) {
          r.mediaUnavailable(b);
          continue;
        }
        atomic('image', 'immutable', {
          'media_items': [it],
          if (media.hasCaptionLine) 'caption': media.captionLine,
        });
      case ArticleGallery(:final items, :final caption):
        final got = <(ArticleMediaRef, Map<String, Object?>)>[];
        for (final ref in items) {
          final a = assets.find(ref.mediaId);
          final it = a == null || !a.media.isImage ? null : item(a);
          if (it != null) got.add((ref, it));
        }
        if (got.isEmpty) {
          r.mediaUnavailable(b);
          continue;
        }
        if (got.length < items.length) {
          r.dropped('gallery_partial', '$network does not get ${items.length - got.length} of the photos of this gallery; the others are shown',
              blockId: b.id);
        }
        final caps = [articleText(caption), for (final (ref, _) in got) if (ref.hasCaptionLine) ref.captionLine].nonNulls.toList();
        if (got.any((x) => x.$1.hasCaptionLine)) {
          r.degraded('gallery_captions', '$network galleries have one caption; the photos\' own captions are added to it', blockId: b.id);
        }
        atomic('image', 'immutable', {
          'media_items': [for (final (_, it) in got) it],
          if (caps.isNotEmpty) 'caption': caps.join(' · '),
        });
      case ArticleVideo():
        if (assets.find(b.media.mediaId) != null) {
          r.dropped('no_video', '$network Articles take no video through the API; the video is left out', blockId: b.id);
        } else {
          r.mediaUnavailable(b);
        }
      case ArticleAudio():
        r.dropped('no_audio', '$network Articles take no sound file; it is left out', blockId: b.id);
      case ArticleEmbed(:final url, :final caption):
        final u = url.trim();
        final post = xPostUrl.firstMatch(u);
        if (post != null) {
          atomic('post', 'immutable', {'post_id': post.group(1)});
          if (articleText(caption) case final c?) {
            r.degraded('embed_caption_as_text', '$network embedded posts have no caption; it goes in a line under the post', blockId: b.id);
            text([ArticleSpan(c, marks: const {ArticleMark.italic})], 'unstyled', b.id);
          }
        } else {
          r.degraded('embed_as_link', '$network Articles embed only X posts; this embed is a link', blockId: b.id);
          text([ArticleSpan(articleText(caption) ?? u, link: u)], 'unstyled', b.id);
        }
      case ArticleUnknownBlock():
        r.unknown(b);
    }
  }
  return ArticleRender({
    'title': title,
    'content_state': {'blocks': blocks, 'entities': entities},
    'cover_media': ?coverMedia,
  }, r.build());
}
