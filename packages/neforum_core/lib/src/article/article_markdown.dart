import '../audio/audio_publishing.dart' show AudioTagsOfAttachment;
import '../model/article.dart';
import '../text/url_detector.dart';
import 'article_render.dart';

/// The Markdown a network reads, where they differ: how an embed is written
/// and which fields it has.
enum ArticleMarkdownDialect {
  /// DEV (Forem): `{% embed https://... %}` Liquid tags; cover `main_image`,
  /// `canonical_url`, `description` (the excerpt), draft through
  /// `published: false`; no slug.
  devto,

  /// Hashnode: `%[https://...]` embeds; `coverImage`, `subtitle`, `slug`,
  /// `originalArticleURL`; `publishPost` always publishes.
  hashnode,

  /// WriteFreely / Write.as: links for embeds, no cover field (the cover goes
  /// at the top), `slug`; tags as #hashtags at the end of the body.
  writeFreely,

  /// CommonMark with nothing of any network's (the Markdown of a hand-off).
  commonMark,
}

ArticleFieldSupport _fields(ArticleMarkdownDialect d) => switch (d) {
      ArticleMarkdownDialect.devto => const ArticleFieldSupport(slug: false, canonicalUrl: true),
      ArticleMarkdownDialect.hashnode => const ArticleFieldSupport(subtitle: true, excerpt: false, canonicalUrl: true, status: false),
      ArticleMarkdownDialect.writeFreely =>
        const ArticleFieldSupport(cover: false, coverInBody: true, excerpt: false, status: false),
      ArticleMarkdownDialect.commonMark => const ArticleFieldSupport(cover: false, coverInBody: true, slug: false, status: false),
    };

/// Text escaped so Markdown shows it as written: the characters that mark
/// emphasis, code, links and HTML get a backslash, and so does what would
/// start a heading, list or quote at the start of a line.
String markdownEscape(String text) {
  final escaped = text
      .replaceAllMapped(RegExp(r'[\\`*_\[\]<>~|]'), (m) => '\\${m[0]}')
      // "&amp;" written as text stays those five characters.
      .replaceAllMapped(RegExp(r'&(?=#?[A-Za-z0-9]+;)'), (m) => r'\&');
  return escaped
      .split('\n')
      .map((line) => line
          .replaceFirstMapped(RegExp(r'^(\s*)(#|[-+](?:\s|$)|-+\s*$|=+\s*$)'), (m) => '${m[1]}\\${m[2]}')
          .replaceFirstMapped(RegExp(r'^(\s*\d{1,9})([.)])(\s|$)'), (m) => '${m[1]}\\${m[2]}${m[3]}'))
      .join('  \n');
}

String _markedMd(ArticleSpan s) {
  if (s.code) {
    final t = s.text.replaceAll('\n', ' ');
    final fence = t.contains('`') ? '``' : '`';
    final pad = t.startsWith('`') || t.endsWith('`') ? ' ' : '';
    var out = '$fence$pad$t$pad$fence';
    if (s.italic) out = '*$out*';
    if (s.bold) out = '**$out**';
    return out;
  }
  // Emphasis cannot start or end on a space in Markdown: keep those outside.
  final lead = RegExp(r'^\s*').firstMatch(s.text)![0]!;
  final trail = s.text.trim().isEmpty ? '' : RegExp(r'\s*$').firstMatch(s.text)![0]!;
  final core = s.text.substring(lead.length, s.text.length - trail.length);
  if (core.isEmpty) return markdownEscape(s.text);
  var out = markdownEscape(core);
  if (s.italic) out = '*$out*';
  if (s.bold) out = '**$out**';
  return '${markdownEscape(lead)}$out${markdownEscape(trail)}';
}

/// [spans] as inline Markdown: `**bold**`, `*italic*`, `` `code` ``,
/// `[words](address)`; literal text escaped; a line break as two spaces and
/// a newline.
String markdownInline(List<ArticleSpan> spans) {
  final out = StringBuffer();
  var i = 0;
  while (i < spans.length) {
    final link = spans[i].link;
    if (link == null) {
      out.write(spans[i].isPlain ? _plainWithAutolinks(spans[i].text) : _markedMd(spans[i]));
      i++;
      continue;
    }
    final words = StringBuffer();
    final plain = StringBuffer();
    while (i < spans.length && spans[i].link == link) {
      words.write(_markedMd(spans[i]));
      plain.write(spans[i].text);
      i++;
    }
    final dest = link.contains(RegExp(r'[\s()<>]')) ? '<${link.replaceAll('>', '%3E').replaceAll(' ', '%20')}>' : link;
    out.write(plain.toString() == link && !link.contains(RegExp(r'[\s<>]')) ? '<$link>' : '[$words]($dest)');
  }
  return out.toString();
}

/// Plain [text] escaped, its `http(s)://` addresses written as `<...>`
/// autolinks so no escape lands inside an address.
String _plainWithAutolinks(String text) {
  final out = StringBuffer();
  var pos = 0;
  for (final u in UrlDetector.find(text).where((u) => u.hasScheme)) {
    if (u.start < pos || u.text.contains(RegExp(r'[\s<>]'))) continue;
    out
      ..write(markdownEscape(text.substring(pos, u.start)))
      ..write('<${u.text}>');
    pos = u.end;
  }
  out.write(markdownEscape(text.substring(pos)));
  return out.toString();
}

/// A code fence longer than any run of backticks in [code].
String _fence(String code) {
  var longest = 0;
  for (final m in RegExp('`+').allMatches(code)) {
    if (m.end - m.start > longest) longest = m.end - m.start;
  }
  return '`' * (longest < 3 ? 3 : longest + 1);
}

String _imageMd(ArticleMediaRef ref, ArticleAsset a) {
  final alt = ref.altFor(a.media).replaceAll(RegExp(r'[\[\]\n\r]'), ' ').replaceAll(r'\', '').trim();
  final url = a.url.contains(RegExp(r'[\s()]')) ? '<${a.url.replaceAll(' ', '%20')}>' : a.url;
  return '![$alt]($url)';
}

/// [doc] as the Markdown body of a [dialect] network. Files are found in
/// [assets] (on the network or the media host). Markdown has no captions
/// (a caption goes in an italic line under its file), no galleries (photos
/// one after the other) and no sound player (a link to the file); all of it
/// is reported. Videos are never in it: no Markdown network here takes an
/// uploaded video.
///
/// [tags] go at the end as #hashtags for WriteFreely, which takes its tags
/// from the body.
ArticleRender<String> renderMarkdown(ArticleDocument doc, ArticleAssets assets,
    {required ArticleMarkdownDialect dialect, required String network, List<String> tags = const [], String? excerptOverride}) {
  final r = ArticleReportBuilder(network);
  final fields = _fields(dialect);
  fields.reportFields(doc, r, excerptOverride: excerptOverride);
  final out = <String>[];
  final cover = doc.cover;
  if (cover != null && fields.coverInBody) {
    final a = assets.find(cover.mediaId);
    if (a == null || !a.media.isImage) {
      r.dropped('media_unavailable', '$network does not get the cover image\'s file, so the article has no cover there',
          blockId: ArticleDocument.coverId);
    } else {
      out.add(_imageMd(cover, a));
      if (cover.hasCaptionLine) out.add('*${markdownEscape(cover.captionLine)}*');
    }
  } else if (cover != null) {
    final a = assets.find(cover.mediaId);
    if (a == null || !a.media.isImage) {
      r.dropped('media_unavailable', '$network does not get the cover image\'s file, so the article has no cover there',
          blockId: ArticleDocument.coverId);
    }
  }
  for (final b in doc.blocks) {
    final s = _markdownBlock(b, assets, r, dialect);
    if (s != null && s.isNotEmpty) out.add(s);
  }
  if (dialect == ArticleMarkdownDialect.writeFreely) {
    final hashtags = [
      for (final t in tags)
        if (t.replaceAll(RegExp(r'[^\p{L}\p{N}_]', unicode: true), '') case final clean when clean.isNotEmpty) '#$clean',
    ];
    if (hashtags.isNotEmpty) out.add(hashtags.toSet().join(' '));
  }
  return ArticleRender(out.join('\n\n'), r.build());
}

String? _markdownBlock(ArticleBlock b, ArticleAssets assets, ArticleReportBuilder r, ArticleMarkdownDialect dialect) {
  switch (b) {
    case ArticleParagraph(:final spans):
      return markdownInline(spans);
    case ArticleHeading(:final spans):
      return '${'#' * b.safeLevel} ${markdownInline(spans).replaceAll('  \n', ' ')}';
    case ArticleList(:final items, :final ordered, :final start):
      return [
        for (var i = 0; i < items.length; i++)
          '${ordered ? '${start + i}.' : '-'} ${markdownInline(items[i]).replaceAll('  \n', '  \n   ')}',
      ].join('\n');
    case ArticleQuote(:final spans, :final citation):
      final lines = markdownInline(spans).split('\n');
      final cite = articleText(citation);
      return [
        for (final l in lines) '> $l'.trimRight(),
        if (cite != null) ...['>', '> ${markdownEscape(cite)}'],
      ].join('\n');
    case ArticleCode(:final code, :final language):
      final lang = articleText(language)?.replaceAll(RegExp(r'[^A-Za-z0-9_+#.-]'), '') ?? '';
      final f = _fence(code);
      return '$f$lang\n$code\n$f';
    case ArticleDivider():
      return '***';
    case ArticleImage(:final media):
      final a = assets.find(media.mediaId);
      if (a == null || !a.media.isImage) {
        r.mediaUnavailable(b);
        return null;
      }
      if (media.hasCaptionLine) r.captionAsText(b);
      return [_imageMd(media, a), if (media.hasCaptionLine) '*${markdownEscape(media.captionLine)}*'].join('\n\n');
    case ArticleGallery(:final items, :final caption):
      final got = <(ArticleMediaRef, ArticleAsset)>[];
      for (final ref in items) {
        final a = assets.find(ref.mediaId);
        if (a != null && a.media.isImage) got.add((ref, a));
      }
      if (got.isEmpty) {
        r.mediaUnavailable(b);
        return null;
      }
      if (got.length < items.length) {
        r.dropped('gallery_partial', '${r.network} does not get ${items.length - got.length} of the photos of this gallery; the others are shown',
            blockId: b.id);
      }
      r.degraded('gallery_as_images', '${r.network} has no galleries; the photos are shown one after the other', blockId: b.id);
      final caps = [articleText(caption), for (final (ref, _) in got) if (ref.hasCaptionLine) ref.captionLine].nonNulls.toList();
      return [for (final (ref, a) in got) _imageMd(ref, a), if (caps.isNotEmpty) '*${markdownEscape(caps.join(' · '))}*'].join('\n\n');
    case ArticleAudio(:final media):
      final a = assets.find(media.mediaId);
      if (a == null || !a.media.isAudio) {
        r.mediaUnavailable(b);
        return null;
      }
      r.degraded('audio_as_link', '${r.network} has no sound player; the sound file is a link', blockId: b.id);
      final label = articleText(media.caption) ?? articleText(a.media.audioCaption) ?? articleText(a.media.fileName) ?? 'Listen';
      return '[${markdownEscape(label)}](${a.url})${media.hasCaptionLine && articleText(media.credit) != null ? '  \n*${markdownEscape(media.credit!.trim())}*' : ''}';
    case ArticleVideo():
      r.mediaUnavailable(b);
      return null;
    case ArticleEmbed(:final url, :final caption):
      final u = url.trim();
      final cap = articleText(caption);
      final line = switch (dialect) {
        ArticleMarkdownDialect.devto => '{% embed $u %}',
        ArticleMarkdownDialect.hashnode => '%[$u]',
        _ => null,
      };
      if (line == null) {
        r.degraded('embed_as_link', '${r.network} has no embeds; the embed is a link', blockId: b.id);
        return cap == null ? '<$u>' : '[${markdownEscape(cap)}]($u)';
      }
      if (cap != null) r.captionAsText(b);
      return [line, if (cap != null) '*${markdownEscape(cap)}*'].join('\n\n');
    case ArticleUnknownBlock():
      r.unknown(b);
      return null;
  }
}
