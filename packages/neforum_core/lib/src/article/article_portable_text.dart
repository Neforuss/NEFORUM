import '../model/article.dart';
import 'article_render.dart';

/// [doc] as EmDash Portable Text (`emdash/src/content/converters/types.ts`):
/// text blocks (`block` with `normal`, `h1`..`h6`, `blockquote`, `bullet` /
/// `number` list items), `code`, `break` (the divider, as NEFORUM's Markdown
/// converter writes it), `image` (with `alt` and `caption`), `gallery` and
/// `video` (with `caption`). EmDash has no sound block and no embed block for
/// any address, so a sound file is left out and an embed becomes a link;
/// both are reported.
///
/// Every `_key` starts with [keyPrefix] (`emdashKeyPrefix`), the mark a
/// retried post is known by. An asset's [ArticleAsset.remoteId] is the
/// EmDash media id; [ArticleAsset.extra] may hold `width`, `height`,
/// `blurhash` and `dominantColor`, which go on the image as EmDash's admin
/// writes them. The cover is the `featured_image` field (the adapter's).
ArticleRender<List<Map<String, Object?>>> renderPortableText(ArticleDocument doc, ArticleAssets assets,
    {required String keyPrefix, String network = 'EmDash'}) {
  final r = ArticleReportBuilder(network);
  const ArticleFieldSupport().reportFields(doc, r);
  final cover = doc.cover;
  if (cover != null) {
    final a = assets.find(cover.mediaId);
    if (a == null || !a.media.isImage) {
      r.dropped('media_unavailable', '$network does not get the cover image\'s file, so the article has no cover there',
          blockId: ArticleDocument.coverId);
    }
  }
  final out = <Map<String, Object?>>[];
  var n = 0;
  var lists = 0;
  String key() => '$keyPrefix${n++}';
  for (final b in doc.blocks) {
    switch (b) {
      case ArticleParagraph(:final spans):
        if (spans.isEmpty) continue;
        out.add(_textBlock(key(), spans, style: 'normal'));
      case ArticleHeading(:final spans):
        out.add(_textBlock(key(), spans, style: 'h${b.safeLevel}'));
      case ArticleQuote(:final spans, :final citation):
        final cite = articleText(citation);
        out.add(_textBlock(key(), [...spans, if (cite != null) ArticleSpan('\n$cite', marks: const {ArticleMark.italic})], style: 'blockquote'));
      case ArticleList(:final items, :final ordered, :final start):
        final listId = ordered ? '${keyPrefix}l${lists++}' : null;
        for (final item in items) {
          out.add(_textBlock(key(), item, style: 'normal', listItem: ordered ? 'number' : 'bullet', listId: listId, listStart: ordered ? start : null));
        }
      case ArticleCode(:final code, :final language):
        final lang = articleText(language)?.replaceAll(RegExp(r'[^A-Za-z0-9_+#.-]'), '');
        out.add({'_type': 'code', '_key': key(), 'code': code, if (lang != null && lang.isNotEmpty) 'language': lang});
      case ArticleDivider():
        out.add({'_type': 'break', '_key': key(), 'style': 'lineBreak'});
      case ArticleImage(:final media):
        final a = assets.find(media.mediaId);
        if (a == null || !a.media.isImage) {
          r.mediaUnavailable(b);
          continue;
        }
        out.add(_image(key(), media, a));
      case ArticleGallery(:final items):
        final got = <(ArticleMediaRef, ArticleAsset)>[];
        for (final ref in items) {
          final a = assets.find(ref.mediaId);
          if (a != null && a.media.isImage) got.add((ref, a));
        }
        if (got.isEmpty) {
          r.mediaUnavailable(b);
          continue;
        }
        if (got.length < items.length) {
          r.dropped('gallery_partial', '$network does not get ${items.length - got.length} of the photos of this gallery; the others are shown',
              blockId: b.id);
        }
        final k = key();
        final caption = articleText(b.caption);
        if (caption != null) {
          r.degraded('gallery_caption_as_text', '$network galleries have no caption of their own; it goes in a line under the gallery',
              blockId: b.id);
        }
        out.add({
          '_type': 'gallery',
          '_key': k,
          'images': [for (var i = 0; i < got.length; i++) _image('${k}g$i', got[i].$1, got[i].$2)],
        });
        if (caption != null) out.add(_textBlock(key(), [ArticleSpan(caption, marks: const {ArticleMark.italic})], style: 'normal'));
      case ArticleVideo(:final media):
        final a = assets.find(media.mediaId);
        if (a == null || !a.media.isVideo) {
          r.mediaUnavailable(b);
          continue;
        }
        out.add({
          '_type': 'video',
          '_key': key(),
          'asset': {'_ref': '${a.remoteId ?? a.url}', 'url': a.url},
          if (media.hasCaptionLine) 'caption': media.captionLine,
          'width': ?(a.extra['width'] ?? a.media.width),
          'height': ?(a.extra['height'] ?? a.media.height),
        });
      case ArticleAudio():
        if (assets.find(b.media.mediaId) case final a? when a.media.isAudio) {
          r.dropped('no_audio_block', '$network has no sound block; the sound file is left out', blockId: b.id);
        } else {
          r.mediaUnavailable(b);
        }
      case ArticleEmbed(:final url, :final caption):
        r.degraded('embed_as_link', '$network has no embed block for any address; the embed is a link', blockId: b.id);
        final u = url.trim();
        out.add(_textBlock(key(), [ArticleSpan(articleText(caption) ?? u, link: u)], style: 'normal'));
      case ArticleUnknownBlock():
        r.unknown(b);
    }
  }
  return ArticleRender(out, r.build());
}

Map<String, Object?> _image(String key, ArticleMediaRef ref, ArticleAsset a) {
  final alt = ref.altFor(a.media);
  return {
    '_type': 'image',
    '_key': key,
    'asset': {'_ref': '${a.remoteId ?? a.url}', 'url': a.url},
    if (alt.isNotEmpty) 'alt': alt,
    if (ref.hasCaptionLine) 'caption': ref.captionLine,
    'width': ?(a.extra['width'] ?? a.media.width),
    'height': ?(a.extra['height'] ?? a.media.height),
    'blurhash': ?a.extra['blurhash'],
    'dominantColor': ?a.extra['dominantColor'],
  };
}

Map<String, Object?> _textBlock(String key, List<ArticleSpan> spans,
    {required String style, String? listItem, String? listId, int? listStart}) {
  final defs = <Map<String, Object?>>[];
  final defKeys = <String, String>{};
  final children = <Map<String, Object?>>[];
  final linked = articleAutolinked(spans);
  for (var j = 0; j < linked.length; j++) {
    final s = linked[j];
    final marks = <String>[
      if (s.bold) 'strong',
      if (s.italic) 'em',
      if (s.code) 'code',
    ];
    final link = s.link;
    if (link != null) {
      marks.add(defKeys.putIfAbsent(link, () {
        final k = '${key}l${defKeys.length}';
        defs.add({'_type': 'link', '_key': k, 'href': link});
        return k;
      }));
    }
    children.add({'_type': 'span', '_key': '${key}s$j', 'text': s.text, 'marks': marks});
  }
  return {
    '_type': 'block',
    '_key': key,
    'style': style,
    if (listItem != null) 'listItem': listItem,
    if (listItem != null) 'level': 1,
    'listId': ?listId,
    if (listId != null && listStart != null) 'listStart': listStart,
    'markDefs': defs,
    'children': children.isEmpty
        ? [
            {'_type': 'span', '_key': '${key}s0', 'text': '', 'marks': <String>[]},
          ]
        : children,
  };
}
