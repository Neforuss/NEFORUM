import '../audio/audio_publishing.dart' show AudioTagsOfAttachment;
import '../model/article.dart';
import 'article_render.dart';

/// The most image blocks in one Tumblr post (npf-spec.md, "Post Content
/// Limits": "The maximum number of image blocks allowed in a single post is
/// 30").
const int npfMaxImages = 30;

/// The longest text block, in code points.
const int npfMaxTextCodePoints = 4096;

/// [doc] as Tumblr Neue Post Format: `{content: [...], layout: [...]}` for
/// `POST /v2/blog/{blog}/posts`.
///
/// * The [title] is a `heading1` text block and the subtitle a `heading2`
///   one; the cover is the first image (Tumblr has no cover).
/// * Text blocks per line, with `bold`, `italic` and `link` formatting at
///   code-point offsets; headings 1-2 are `heading1`, 3-6 `heading2`; list
///   items `unordered-list-item` / `ordered-list-item`; quotes `quote`.
/// * Images are `image` blocks (`media` is an array) with `alt_text` and
///   `caption`; videos are `video` blocks (`media` is one object). Each file
///   is a multipart part named by its identifier: [ArticleAsset.remoteId].
/// * A gallery's photos are image blocks shown side by side, three at most
///   per row, through a `rows` layout that names every block (npf-spec.md:
///   a rows layout "should contain references to all content block
///   indices", and a row of several blocks holds only images).
/// * An embed is a `link` block (Tumblr makes its card from the address).
///
/// Tumblr has no inline code, code block, divider, sound upload or caption
/// on a video: code is plain monospaced `chat` text, a divider a `* * *`
/// line, a sound file a link to it on the media host, a video caption a
/// line under it; each is reported. Images past [npfMaxImages] are left
/// out, reported.
ArticleRender<Map<String, Object?>> renderNpf(ArticleDocument doc, ArticleAssets assets,
    {String? title, String network = 'Tumblr', String? excerptOverride}) {
  final r = ArticleReportBuilder(network);
  const ArticleFieldSupport(cover: false, coverInBody: true, subtitle: true, excerpt: false, canonicalUrl: true)
      .reportFields(doc, r, excerptOverride: excerptOverride);
  final content = <Map<String, Object?>>[];
  final rows = <List<int>>[];
  var images = 0;

  void single(Map<String, Object?> block) {
    rows.add([content.length]);
    content.add(block);
  }

  void text(List<ArticleSpan> spans, {String? subtype, String? blockId}) {
    for (final line in _lines(articleAutolinked(spans))) {
      if (articleSpansText(line).trim().isEmpty) continue;
      for (final b in _textBlocks(line, subtype, r, blockId)) {
        single(b);
      }
    }
  }

  Map<String, Object?>? image(ArticleMediaRef ref, ArticleAsset a, String blockId) {
    if (images >= npfMaxImages) {
      r.dropped('too_many_images', '$network takes $npfMaxImages photos per post; this one is left out', blockId: blockId);
      return null;
    }
    images++;
    final alt = ref.altFor(a.media);
    return {
      'type': 'image',
      'media': [_media(a)],
      if (alt.isNotEmpty) 'alt_text': alt.length > 4096 ? alt.substring(0, 4096) : alt,
      if (ref.hasCaptionLine) 'caption': ref.captionLine,
    };
  }

  final t = articleText(title);
  if (t != null) single(_plain(t, 'heading1'));
  final sub = articleText(doc.subtitle);
  if (sub != null) single(_plain(sub, 'heading2'));
  final cover = doc.cover;
  if (cover != null) {
    final a = assets.find(cover.mediaId);
    if (a == null || !a.media.isImage) {
      r.dropped('media_unavailable', '$network does not get the cover image\'s file, so the article has no cover there',
          blockId: ArticleDocument.coverId);
    } else if (image(cover, a, ArticleDocument.coverId) case final block?) {
      single(block);
    }
  }

  for (final b in doc.blocks) {
    switch (b) {
      case ArticleParagraph(:final spans):
        text(spans, blockId: b.id);
      case ArticleHeading(:final spans):
        text(spans, subtype: b.safeLevel <= 2 ? 'heading1' : 'heading2', blockId: b.id);
      case ArticleQuote(:final spans, :final citation):
        text(spans, subtype: 'quote', blockId: b.id);
        final cite = articleText(citation);
        if (cite != null) text([ArticleSpan(cite, marks: const {ArticleMark.italic})], blockId: b.id);
      case ArticleList(:final items, :final ordered, :final start):
        if (ordered && start != 1) {
          r.degraded('list_start', '$network numbers every list from 1; this list started at $start', blockId: b.id);
        }
        for (final item in items) {
          text(item.map((s) => ArticleSpan(s.text.replaceAll('\n', ' '), marks: s.marks, link: s.link)).toList(),
              subtype: ordered ? 'ordered-list-item' : 'unordered-list-item', blockId: b.id);
        }
      case ArticleCode(:final code):
        r.degraded('code_as_text', '$network has no code blocks; the code is monospaced text, without its empty lines', blockId: b.id);
        for (final line in code.split('\n')) {
          if (line.trim().isEmpty) continue;
          for (final chunk in _chunks(line)) {
            single(_plain(chunk, 'chat'));
          }
        }
      case ArticleDivider():
        r.degraded('divider_as_text', '$network has no dividers; a line of * * * stands for it', blockId: b.id);
        single(_plain('* * *', null));
      case ArticleImage(:final media):
        final a = assets.find(media.mediaId);
        if (a == null || !a.media.isImage) {
          r.mediaUnavailable(b);
          continue;
        }
        if (image(media, a, b.id) case final block?) single(block);
      case ArticleGallery(:final items, :final caption):
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
        final indexes = <int>[];
        for (final (ref, a) in got) {
          final block = image(ref, a, b.id);
          if (block == null) continue;
          indexes.add(content.length);
          content.add(block);
        }
        for (var i = 0; i < indexes.length; i += 3) {
          rows.add(indexes.sublist(i, i + 3 > indexes.length ? indexes.length : i + 3));
        }
        final cap = articleText(caption);
        if (cap != null) {
          r.degraded('gallery_caption_as_text', '$network galleries have no caption of their own; it goes in a line under the photos',
              blockId: b.id);
          text([ArticleSpan(cap, marks: const {ArticleMark.italic})], blockId: b.id);
        }
      case ArticleVideo(:final media):
        final a = assets.find(media.mediaId);
        if (a == null || !a.media.isVideo) {
          r.mediaUnavailable(b);
          continue;
        }
        single({'type': 'video', 'media': _media(a)});
        if (media.hasCaptionLine) {
          r.degraded('video_caption_as_text', '$network videos have no caption; it goes in a line under the video', blockId: b.id);
          text([ArticleSpan(media.captionLine, marks: const {ArticleMark.italic})], blockId: b.id);
        }
      case ArticleAudio(:final media):
        final a = assets.find(media.mediaId);
        if (a == null || !a.media.isAudio || a.url.isEmpty) {
          r.mediaUnavailable(b);
          continue;
        }
        r.degraded('audio_as_link', '$network gets the sound file as a link to it on your media host', blockId: b.id);
        single({
          'type': 'link',
          'url': a.url,
          if (articleText(media.caption) ?? articleText(a.media.audioCaption) case final title?) 'title': title,
        });
      case ArticleEmbed(:final url, :final caption):
        single({'type': 'link', 'url': url.trim(), if (articleText(caption) case final c?) 'title': c});
      case ArticleUnknownBlock():
        r.unknown(b);
    }
  }
  final multi = rows.any((row) => row.length > 1);
  return ArticleRender({
    'content': content,
    if (multi)
      'layout': [
        {
          'type': 'rows',
          'display': [
            for (final row in rows) {'blocks': row},
          ],
        },
      ],
  }, r.build());
}

Map<String, Object?> _media(ArticleAsset a) => {
      'type': a.media.mimeType,
      'identifier': '${a.remoteId}',
      if (a.media.width != null) 'width': a.media.width,
      if (a.media.height != null) 'height': a.media.height,
    };

Map<String, Object?> _plain(String text, String? subtype) => {'type': 'text', if (subtype != null) 'subtype': subtype, 'text': text};

/// [spans] cut at their line breaks into lines of spans.
List<List<ArticleSpan>> _lines(List<ArticleSpan> spans) {
  final lines = <List<ArticleSpan>>[[]];
  for (final s in spans) {
    final parts = s.text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) lines.add([]);
      if (parts[i].isNotEmpty) lines.last.add(ArticleSpan(parts[i], marks: s.marks, link: s.link));
    }
  }
  return lines;
}

List<String> _chunks(String s) {
  final runes = s.runes.toList();
  if (runes.length <= npfMaxTextCodePoints) return [s];
  return [
    for (var i = 0; i < runes.length; i += npfMaxTextCodePoints)
      String.fromCharCodes(runes.sublist(i, i + npfMaxTextCodePoints > runes.length ? runes.length : i + npfMaxTextCodePoints)),
  ];
}

/// One line of spans as text blocks with formatting (code-point offsets).
/// A line over [npfMaxTextCodePoints] goes in pieces without formatting.
List<Map<String, Object?>> _textBlocks(List<ArticleSpan> line, String? subtype, ArticleReportBuilder r, String? blockId) {
  final text = articleSpansText(line);
  if (text.runes.length > npfMaxTextCodePoints) {
    r.degraded('long_line', '${r.network} takes $npfMaxTextCodePoints characters per block; a long line is cut in pieces without its formatting',
        blockId: blockId);
    return [for (final c in _chunks(text)) _plain(c, subtype)];
  }
  final formatting = <Map<String, Object?>>[];
  var at = 0;
  var codeSeen = false;
  for (final s in line) {
    final len = s.text.runes.length;
    final end = at + len;
    if (s.bold) formatting.add({'start': at, 'end': end, 'type': 'bold'});
    if (s.italic) formatting.add({'start': at, 'end': end, 'type': 'italic'});
    if (s.link != null) formatting.add({'start': at, 'end': end, 'type': 'link', 'url': s.link});
    if (s.code) codeSeen = true;
    at = end;
  }
  if (codeSeen) r.degraded('inline_code', '${r.network} has no inline code; it is plain text', blockId: blockId);
  return [
    {
      'type': 'text',
      if (subtype != null) 'subtype': subtype,
      'text': text,
      if (formatting.isNotEmpty) 'formatting': formatting,
    },
  ];
}
