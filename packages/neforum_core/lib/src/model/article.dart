import 'package:meta/meta.dart';

import '../text/portable_text.dart';
import 'media.dart';
import 'paragraph_media.dart';

// 1.4.4: the article document. A blog post written as ordered blocks
// (paragraphs, headings, photos, galleries, videos, sound, embeds, quotes,
// lists, code, dividers) instead of one plain text, kept on the post
// ([Post.article]) next to the short text the social networks get.
//
// Blog networks ([PlatformDescriptor.articleFormat]) get the document turned
// into their own format by lib/src/article/; the social networks keep the
// post's text and media. A post without a document goes out exactly as before.
//
// The title, tags and schedule are not repeated here: they stay on the post
// (Post.title, Post.tags, Post.scheduledAt and each target's own time), so the
// short version and the article never disagree on them.

/// The format a network takes an article in. One serializer each
/// (lib/src/article/article_renderer.dart).
enum ArticleFormat {
  /// WordPress block editor markup (Gutenberg block comments).
  gutenberg,

  /// Ghost Admin API HTML (`?source=html`), with Ghost's card markup.
  ghostHtml,

  /// EmDash Portable Text.
  portableText,

  /// DEV (Forem) `body_markdown`.
  devtoMarkdown,

  /// Hashnode `contentMarkdown`.
  hashnodeMarkdown,

  /// WriteFreely / Write.as Markdown body.
  writeFreelyMarkdown,

  /// Micropub JSON `content: [{html}]`.
  micropubHtml,

  /// Tumblr Neue Post Format content blocks.
  tumblrNpf,

  /// Clean HTML (and Markdown) on the clipboard for a hand-off (Substack).
  handoffHtml,

  /// X Articles `content_state` (DraftJS-style blocks and entities).
  xArticle,
}

/// Inline emphasis on a stretch of text.
enum ArticleMark { bold, italic, code }

/// What kind of block an [ArticleBlock] is.
enum ArticleBlockType { paragraph, heading, image, gallery, video, audio, embed, quote, list, code, divider, unknown }

/// "Publish as" for the article: published, or a draft on the blog. Null on
/// [ArticleDocument.status]: as each account is set.
enum ArticleStatus { published, draft }

/// A run of text with the same marks and link. [text] may hold `\n` (a line
/// break inside the block).
@immutable
class ArticleSpan {
  const ArticleSpan(this.text, {this.marks = const {}, this.link});

  factory ArticleSpan.fromJson(Map<String, dynamic> json) => ArticleSpan(
        json['text'] as String? ?? '',
        marks: {
          for (final m in json['marks'] as List? ?? const [])
            if (ArticleMark.values.asNameMap()[m] case final mark?) mark,
        },
        link: json['link'] as String?,
      );

  final String text;
  final Set<ArticleMark> marks;

  /// The address the text links to; null: no link.
  final String? link;

  bool get bold => marks.contains(ArticleMark.bold);
  bool get italic => marks.contains(ArticleMark.italic);
  bool get code => marks.contains(ArticleMark.code);
  bool get isPlain => marks.isEmpty && link == null;

  Map<String, dynamic> toJson() => {
        'text': text,
        if (marks.isNotEmpty) 'marks': [for (final m in ArticleMark.values) if (marks.contains(m)) m.name],
        if (link != null) 'link': link,
      };

  @override
  bool operator ==(Object other) =>
      other is ArticleSpan && other.text == text && other.link == link && other.marks.length == marks.length && other.marks.containsAll(marks);

  @override
  int get hashCode => Object.hash(text, link, Object.hashAllUnordered(marks));

  @override
  String toString() => 'ArticleSpan(${marks.map((m) => m.name).join('+')}${link == null ? '' : ' -> $link'} "$text")';
}

/// The plain text of [spans], marks and links left out.
String articleSpansText(List<ArticleSpan> spans) => spans.map((s) => s.text).join();

/// One draft file placed in the article ([MediaAttachment] of the post, by
/// id), with its caption, alt text and credit.
@immutable
class ArticleMediaRef {
  const ArticleMediaRef(this.mediaId, {this.caption, this.altText, this.credit});

  factory ArticleMediaRef.fromJson(Map<String, dynamic> json) => ArticleMediaRef(
        json['mediaId'] as String,
        caption: json['caption'] as String?,
        altText: json['altText'] as String?,
        credit: json['credit'] as String?,
      );

  /// The id of the post's file ([MediaAttachment.id]). A copy NEFORUM made
  /// from it for a network (a fitted photo, [MediaAttachment.derivedFrom])
  /// stands for it.
  final String mediaId;

  /// Shown under the file.
  final String? caption;

  /// The description for people who cannot see the photo. Null: the file's
  /// own ([MediaAttachment.altText]).
  final String? altText;

  /// Who made it ("Photo: Jane Doe"). Networks without a credit field show it
  /// after the caption.
  final String? credit;

  /// [altText], else [media]'s own alt text, trimmed; empty when neither.
  String altFor(MediaAttachment? media) {
    final own = altText?.trim();
    if (own != null && own.isNotEmpty) return own;
    return (media?.altText ?? '').trim();
  }

  /// The caption and the credit as one line: "Caption · Credit", either
  /// alone, or empty.
  String get captionLine {
    final c = (caption ?? '').trim();
    final r = (credit ?? '').trim();
    if (c.isEmpty) return r;
    if (r.isEmpty) return c;
    return '$c · $r';
  }

  bool get hasCaptionLine => captionLine.isNotEmpty;

  ArticleMediaRef copyWith({String? caption, String? altText, String? credit}) => ArticleMediaRef(
        mediaId,
        caption: caption ?? this.caption,
        altText: altText ?? this.altText,
        credit: credit ?? this.credit,
      );

  Map<String, dynamic> toJson() => {
        'mediaId': mediaId,
        if (caption != null) 'caption': caption,
        if (altText != null) 'altText': altText,
        if (credit != null) 'credit': credit,
      };

  @override
  bool operator ==(Object other) =>
      other is ArticleMediaRef && other.mediaId == mediaId && other.caption == caption && other.altText == altText && other.credit == credit;

  @override
  int get hashCode => Object.hash(mediaId, caption, altText, credit);
}

/// One block of an [ArticleDocument]. Every block has an [id], unique in its
/// document, that per-network choices ([PostOverrides.excludedBlockIds]) and
/// render reports refer to.
@immutable
sealed class ArticleBlock {
  const ArticleBlock(this.id);

  /// A block from its JSON. A type this version does not know is kept as an
  /// [ArticleUnknownBlock], so a document written by a newer NEFORUM survives
  /// a round trip through an older one.
  factory ArticleBlock.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    List<ArticleSpan> spans(Object? raw) => [for (final s in raw as List? ?? const []) ArticleSpan.fromJson(Map<String, dynamic>.from(s as Map))];
    ArticleMediaRef ref(Object? raw) => ArticleMediaRef.fromJson(Map<String, dynamic>.from(raw as Map));
    try {
      return switch (json['type']) {
        'paragraph' => ArticleParagraph(id, spans(json['spans'])),
        'heading' => ArticleHeading(id, spans(json['spans']), level: json['level'] as int? ?? 2),
        'quote' => ArticleQuote(id, spans(json['spans']), citation: json['citation'] as String?),
        'list' => ArticleList(
            id,
            [for (final item in json['items'] as List? ?? const []) spans(item)],
            ordered: json['ordered'] as bool? ?? false,
            start: json['start'] as int? ?? 1,
            marker: json['marker'] as String? ?? '-',
          ),
        'code' => ArticleCode(id, json['code'] as String? ?? '', language: json['language'] as String?),
        'divider' => ArticleDivider(id),
        'image' => ArticleImage(id, ref(json['media'])),
        'gallery' => ArticleGallery(id, [for (final m in json['items'] as List? ?? const []) ref(m)], caption: json['caption'] as String?),
        'video' => ArticleVideo(id, ref(json['media'])),
        'audio' => ArticleAudio(id, ref(json['media'])),
        'embed' => ArticleEmbed(id, json['url'] as String? ?? '', caption: json['caption'] as String?),
        _ => ArticleUnknownBlock(id, json),
      };
    } on TypeError {
      return ArticleUnknownBlock(id, json);
    }
  }

  final String id;

  ArticleBlockType get type;

  /// The draft files the block shows, in order.
  List<ArticleMediaRef> get mediaRefs => const [];

  /// Whether the block is text (paragraph, heading, quote, list, code).
  bool get isText => switch (type) {
        ArticleBlockType.paragraph || ArticleBlockType.heading || ArticleBlockType.quote || ArticleBlockType.list || ArticleBlockType.code => true,
        _ => false,
      };

  Map<String, dynamic> toJson();

  /// "paragraph", "photo", "gallery"...: the block's kind in plain words, for
  /// reports.
  String get noun => switch (type) {
        ArticleBlockType.paragraph => 'paragraph',
        ArticleBlockType.heading => 'heading',
        ArticleBlockType.image => 'photo',
        ArticleBlockType.gallery => 'gallery',
        ArticleBlockType.video => 'video',
        ArticleBlockType.audio => 'sound file',
        ArticleBlockType.embed => 'embed',
        ArticleBlockType.quote => 'quote',
        ArticleBlockType.list => 'list',
        ArticleBlockType.code => 'code block',
        ArticleBlockType.divider => 'divider',
        ArticleBlockType.unknown => 'block',
      };
}

List<Map<String, dynamic>> _spansJson(List<ArticleSpan> spans) => [for (final s in spans) s.toJson()];

bool _sameList<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A paragraph of text.
final class ArticleParagraph extends ArticleBlock {
  const ArticleParagraph(super.id, this.spans);

  /// A paragraph of plain [text].
  ArticleParagraph.plain(String id, String text) : this(id, [ArticleSpan(text)]);

  final List<ArticleSpan> spans;

  @override
  ArticleBlockType get type => ArticleBlockType.paragraph;

  String get text => articleSpansText(spans);

  @override
  Map<String, dynamic> toJson() => {'id': id, 'type': 'paragraph', 'spans': _spansJson(spans)};

  @override
  bool operator ==(Object other) => other is ArticleParagraph && other.id == id && _sameList(other.spans, spans);

  @override
  int get hashCode => Object.hash(id, Object.hashAll(spans));
}

/// A heading. The editor offers levels 2 to 4 (the title is level 1); text
/// brought in from the plain composer keeps the level it was written with,
/// 1 to 6.
final class ArticleHeading extends ArticleBlock {
  const ArticleHeading(super.id, this.spans, {this.level = 2});

  final List<ArticleSpan> spans;
  final int level;

  @override
  ArticleBlockType get type => ArticleBlockType.heading;

  String get text => articleSpansText(spans);

  /// [level] kept between 1 and 6.
  int get safeLevel => level.clamp(1, 6);

  @override
  Map<String, dynamic> toJson() => {'id': id, 'type': 'heading', 'level': level, 'spans': _spansJson(spans)};

  @override
  bool operator ==(Object other) => other is ArticleHeading && other.id == id && other.level == level && _sameList(other.spans, spans);

  @override
  int get hashCode => Object.hash(id, level, Object.hashAll(spans));
}

/// A quotation, with who said it.
final class ArticleQuote extends ArticleBlock {
  const ArticleQuote(super.id, this.spans, {this.citation});

  final List<ArticleSpan> spans;
  final String? citation;

  @override
  ArticleBlockType get type => ArticleBlockType.quote;

  String get text => articleSpansText(spans);

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'quote',
        'spans': _spansJson(spans),
        if (citation != null) 'citation': citation,
      };

  @override
  bool operator ==(Object other) => other is ArticleQuote && other.id == id && other.citation == citation && _sameList(other.spans, spans);

  @override
  int get hashCode => Object.hash(id, citation, Object.hashAll(spans));
}

/// A bulleted or numbered list (one level).
final class ArticleList extends ArticleBlock {
  const ArticleList(super.id, this.items, {this.ordered = false, this.start = 1, this.marker = '-'});

  /// The items, each a run of spans.
  final List<List<ArticleSpan>> items;
  final bool ordered;

  /// The number of the first item of a numbered list.
  final int start;

  /// The bullet a list from the plain composer was written with (`-`, `*` or
  /// `+`), so turning the document back into text gives the same text.
  final String marker;

  @override
  ArticleBlockType get type => ArticleBlockType.list;

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'list',
        if (ordered) 'ordered': true,
        if (ordered && start != 1) 'start': start,
        if (!ordered && marker != '-') 'marker': marker,
        'items': [for (final item in items) _spansJson(item)],
      };

  @override
  bool operator ==(Object other) {
    if (other is! ArticleList || other.id != id || other.ordered != ordered || other.start != start || other.marker != marker) return false;
    if (other.items.length != items.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (!_sameList(other.items[i], items[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(id, ordered, start, marker, Object.hashAll(items.map(Object.hashAll)));
}

/// Preformatted code.
final class ArticleCode extends ArticleBlock {
  const ArticleCode(super.id, this.code, {this.language});

  final String code;

  /// The language for highlighting (`dart`, `js`); null: none.
  final String? language;

  @override
  ArticleBlockType get type => ArticleBlockType.code;

  @override
  Map<String, dynamic> toJson() => {'id': id, 'type': 'code', 'code': code, if (language != null) 'language': language};

  @override
  bool operator ==(Object other) => other is ArticleCode && other.id == id && other.code == code && other.language == language;

  @override
  int get hashCode => Object.hash(id, code, language);
}

/// A horizontal rule between sections.
final class ArticleDivider extends ArticleBlock {
  const ArticleDivider(super.id);

  @override
  ArticleBlockType get type => ArticleBlockType.divider;

  @override
  Map<String, dynamic> toJson() => {'id': id, 'type': 'divider'};

  @override
  bool operator ==(Object other) => other is ArticleDivider && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// One photo.
final class ArticleImage extends ArticleBlock {
  const ArticleImage(super.id, this.media);

  final ArticleMediaRef media;

  @override
  ArticleBlockType get type => ArticleBlockType.image;

  @override
  List<ArticleMediaRef> get mediaRefs => [media];

  @override
  Map<String, dynamic> toJson() => {'id': id, 'type': 'image', 'media': media.toJson()};

  @override
  bool operator ==(Object other) => other is ArticleImage && other.id == id && other.media == media;

  @override
  int get hashCode => Object.hash(id, media);
}

/// Several photos shown together, with a caption for the whole group.
final class ArticleGallery extends ArticleBlock {
  const ArticleGallery(super.id, this.items, {this.caption});

  final List<ArticleMediaRef> items;
  final String? caption;

  @override
  ArticleBlockType get type => ArticleBlockType.gallery;

  @override
  List<ArticleMediaRef> get mediaRefs => items;

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'gallery',
        'items': [for (final m in items) m.toJson()],
        if (caption != null) 'caption': caption,
      };

  @override
  bool operator ==(Object other) => other is ArticleGallery && other.id == id && other.caption == caption && _sameList(other.items, items);

  @override
  int get hashCode => Object.hash(id, caption, Object.hashAll(items));
}

/// One video file.
final class ArticleVideo extends ArticleBlock {
  const ArticleVideo(super.id, this.media);

  final ArticleMediaRef media;

  @override
  ArticleBlockType get type => ArticleBlockType.video;

  @override
  List<ArticleMediaRef> get mediaRefs => [media];

  @override
  Map<String, dynamic> toJson() => {'id': id, 'type': 'video', 'media': media.toJson()};

  @override
  bool operator ==(Object other) => other is ArticleVideo && other.id == id && other.media == media;

  @override
  int get hashCode => Object.hash(id, media);
}

/// One sound file with a player.
final class ArticleAudio extends ArticleBlock {
  const ArticleAudio(super.id, this.media);

  final ArticleMediaRef media;

  @override
  ArticleBlockType get type => ArticleBlockType.audio;

  @override
  List<ArticleMediaRef> get mediaRefs => [media];

  @override
  Map<String, dynamic> toJson() => {'id': id, 'type': 'audio', 'media': media.toJson()};

  @override
  bool operator ==(Object other) => other is ArticleAudio && other.id == id && other.media == media;

  @override
  int get hashCode => Object.hash(id, media);
}

/// Something from another site shown in place (a YouTube video, a post), by
/// its address.
final class ArticleEmbed extends ArticleBlock {
  const ArticleEmbed(super.id, this.url, {this.caption});

  final String url;
  final String? caption;

  @override
  ArticleBlockType get type => ArticleBlockType.embed;

  @override
  Map<String, dynamic> toJson() => {'id': id, 'type': 'embed', 'url': url, if (caption != null) 'caption': caption};

  @override
  bool operator ==(Object other) => other is ArticleEmbed && other.id == id && other.url == url && other.caption == caption;

  @override
  int get hashCode => Object.hash(id, url, caption);
}

/// A block of a kind this version of NEFORUM does not know (written by a
/// newer one). Kept as it came so it is not lost; never sent anywhere, and
/// every render report says so.
final class ArticleUnknownBlock extends ArticleBlock {
  const ArticleUnknownBlock(super.id, this.raw);

  final Map<String, dynamic> raw;

  @override
  ArticleBlockType get type => ArticleBlockType.unknown;

  @override
  Map<String, dynamic> toJson() => raw;

  @override
  bool operator ==(Object other) => other is ArticleUnknownBlock && other.id == id && other.raw.toString() == raw.toString();

  @override
  int get hashCode => Object.hash(id, raw.toString());
}

/// The short version of an article for networks that take a plain post
/// ([ArticleDocument.toPlainPost]).
typedef ArticlePlainPost = ({String text, List<String> mediaIds, ParagraphMediaLinks paragraphMedia});

/// A blog article: ordered [blocks] plus the fields blogs keep beside the
/// text. See the comment at the top of this file for what stays on the post.
@immutable
class ArticleDocument {
  const ArticleDocument({
    this.blocks = const [],
    this.subtitle,
    this.cover,
    this.excerpt,
    this.slug,
    this.canonicalUrl,
    this.status,
  });

  /// The JSON version this file writes. A newer document still loads (its
  /// unknown blocks are kept as [ArticleUnknownBlock]).
  static const int schemaVersion = 1;

  /// The id that stands for the [cover] in [PostOverrides.excludedBlockIds]
  /// and in render reports.
  static const String coverId = 'cover';

  factory ArticleDocument.fromJson(Map<String, dynamic> json) => ArticleDocument(
        blocks: [for (final b in json['blocks'] as List? ?? const []) ArticleBlock.fromJson(Map<String, dynamic>.from(b as Map))],
        subtitle: json['subtitle'] as String?,
        cover: json['cover'] == null ? null : ArticleMediaRef.fromJson(Map<String, dynamic>.from(json['cover'] as Map)),
        excerpt: json['excerpt'] as String?,
        slug: json['slug'] as String?,
        canonicalUrl: json['canonicalUrl'] as String?,
        status: ArticleStatus.values.asNameMap()[json['status']],
      );

  /// The document a plain-composer post makes ([Post.text] with its media),
  /// for a post that is turned into an article. Nothing is lost:
  /// [toComposerText] gives [text] back (up to the blank lines between
  /// paragraphs, which become one each, and the spaces around a paragraph,
  /// as [ParagraphMedia.split] cuts them), and [mediaIds] the files.
  ///
  /// Each paragraph ([ParagraphMedia.split]) becomes one block, read the way
  /// the blog networks have always read the composer's text: a paragraph
  /// that is one `#` line is a heading, lines that all start with `-`, `*`
  /// or `+` (or `1.`, `2.`...) a list, lines that all start with `>` a
  /// quote, ```` ``` ```` fences a code block, `---` a divider, and
  /// `**bold**`, `*italic*`, `` `code` ``, `[text](https://...)` and bare
  /// addresses inside them are marks and links. A paragraph that would not
  /// come back as written is kept as plain text instead.
  ///
  /// The files ([media], only the user's own: no generated text card or
  /// fitted copy): the first photo linked to no paragraph is the [cover],
  /// as blogs have always made the first photo the featured image (unless
  /// [coverFromFirstImage] is false); files linked to a paragraph
  /// ([links], [Post.paragraphMedia]) follow it; the others go at the end.
  factory ArticleDocument.fromPlainText(String text,
      {List<MediaAttachment> media = const [], ParagraphMediaLinks links = const {}, bool coverFromFirstImage = true}) {
    final own = [for (final m in media) if (!m.generated) m];
    final paragraphs = ParagraphMedia.split(text);
    final active = ParagraphMedia.normalized(links, paragraphs: paragraphs.length, mediaIds: {for (final m in own) m.id});
    final linked = {for (final ids in active.values) ...ids};
    final cover = coverFromFirstImage ? own.where((m) => m.isImage && !linked.contains(m.id)).firstOrNull : null;
    final blocks = <ArticleBlock>[];
    final used = <String>{if (cover != null) cover.id};
    var n = 0;
    ArticleBlock mediaBlock(MediaAttachment m) {
      final id = 'm${n++}';
      final ref = ArticleMediaRef(m.id);
      if (m.isVideo) return ArticleVideo(id, ref);
      if (m.isAudio) return ArticleAudio(id, ref);
      return ArticleImage(id, ref);
    }

    for (var i = 0; i < paragraphs.length; i++) {
      blocks.add(_blockFromParagraph('b$i', paragraphs[i]));
      for (final id in active[i] ?? const <String>[]) {
        final m = own.where((x) => x.id == id).firstOrNull;
        if (m != null && used.add(m.id)) blocks.add(mediaBlock(m));
      }
    }
    for (final m in own) {
      if (used.add(m.id)) blocks.add(mediaBlock(m));
    }
    return ArticleDocument(blocks: blocks, cover: cover == null ? null : ArticleMediaRef(cover.id));
  }

  final List<ArticleBlock> blocks;

  /// A line under the title.
  final String? subtitle;

  /// The cover (featured) image.
  final ArticleMediaRef? cover;

  /// A short summary for lists, previews and search results.
  final String? excerpt;

  /// The last part of the post's address; null: made from the title.
  final String? slug;

  /// Where the article first appeared, so search engines credit that page.
  final String? canonicalUrl;

  /// "Publish as"; null: as each account is set. A network's own "Publish
  /// as" option chosen for the post wins over it.
  final ArticleStatus? status;

  bool get isEmpty => blocks.isEmpty && cover == null;

  /// Whether the article is to be left as a draft on the blogs.
  bool get isDraft => status == ArticleStatus.draft;

  /// The block with [id], or null.
  ArticleBlock? blockById(String id) => blocks.where((b) => b.id == id).firstOrNull;

  /// Every file the article shows, in reading order: the [cover] first,
  /// then each block's. A file placed twice is listed once.
  List<ArticleMediaRef> get mediaRefs {
    final seen = <String>{};
    return [
      for (final ref in [?cover, for (final b in blocks) ...b.mediaRefs])
        if (seen.add(ref.mediaId)) ref,
    ];
  }

  /// The ids of [mediaRefs].
  List<String> get mediaIds => [for (final r in mediaRefs) r.mediaId];

  /// The files of [pool] (the post's media) the article shows, in its
  /// order. A file is found by its id or by the id it was made from
  /// ([MediaAttachment.derivedFrom]), so a network's fitted copy stands for
  /// the photo. Files no longer attached are skipped.
  List<MediaAttachment> mediaIn(List<MediaAttachment> pool) {
    final out = <MediaAttachment>[];
    for (final id in mediaIds) {
      final m = pool.where((x) => x.id == id).firstOrNull ?? pool.where((x) => ParagraphMedia.names(id, x)).firstOrNull;
      if (m != null && !out.contains(m)) out.add(m);
    }
    return out;
  }

  /// This document without the blocks whose ids are in [ids] (a network's
  /// own selection, [PostOverrides.excludedBlockIds]); [coverId] removes the
  /// cover.
  ArticleDocument withoutBlocks(Iterable<String> ids) {
    final drop = ids.toSet();
    if (drop.isEmpty) return this;
    return copyWith(
      blocks: [for (final b in blocks) if (!drop.contains(b.id)) b],
      clearCover: drop.contains(coverId),
    );
  }

  /// This document without file [mediaId] (it was removed from the post): a
  /// block that shows only it goes, a gallery loses it, and so does the
  /// cover.
  ArticleDocument withoutMedia(String mediaId) {
    final out = <ArticleBlock>[];
    for (final b in blocks) {
      switch (b) {
        case ArticleImage(:final media) || ArticleVideo(:final media) || ArticleAudio(:final media) when media.mediaId == mediaId:
          continue;
        case ArticleGallery(:final items, :final caption, :final id) when items.any((m) => m.mediaId == mediaId):
          final rest = [for (final m in items) if (m.mediaId != mediaId) m];
          if (rest.isNotEmpty) out.add(ArticleGallery(id, rest, caption: caption));
        default:
          out.add(b);
      }
    }
    return copyWith(blocks: out, clearCover: cover?.mediaId == mediaId);
  }

  /// A block id not used in this document yet, starting with [prefix].
  String newBlockId([String prefix = 'b']) {
    final used = {for (final b in blocks) b.id, coverId};
    var i = blocks.length;
    while (used.contains('$prefix$i')) {
      i++;
    }
    return '$prefix$i';
  }

  /// Problems that make the document unusable as it is: two blocks with one
  /// id, an empty id, the reserved [coverId] used by a block. Empty when it
  /// is sound.
  List<String> get structuralProblems {
    final seen = <String>{};
    return [
      for (final b in blocks)
        if (b.id.isEmpty)
          'A ${b.noun} has no id'
        else if (b.id == coverId)
          'A ${b.noun} uses the reserved id "$coverId"'
        else if (!seen.add(b.id))
          'Two blocks have the id "${b.id}"',
    ];
  }

  /// The article as the composer's text: what [fromPlainText] reads, so the
  /// two turn into each other without loss. Headings keep their `#`, lists
  /// their markers, marks their asterisks; files are not in it.
  String toComposerText() => [
        for (final b in blocks)
          if (_composerText(b) case final t? when t.isNotEmpty) t,
      ].join('\n\n');

  /// The article as plain words for networks without formatting: no `#`,
  /// asterisks or Markdown links (a link whose words are not its address
  /// shows "words (address)"), lists with `•` and numbers, quotes in
  /// quotation marks with who said it, code as written, a divider as a blank
  /// paragraph break. Files are not in it; captions are not either.
  String toPlainText() => [
        for (final b in blocks)
          if (_plainText(b) case final t? when t.isNotEmpty) t,
      ].join('\n\n');

  /// The short version for a network that takes one plain post: the text
  /// ([toComposerText], or [toPlainText] with [markup] false), the files in
  /// reading order (cover first) and which paragraph each file follows
  /// ([Post.paragraphMedia]), so networks that show paragraphs with their
  /// files keep the article's layout.
  ArticlePlainPost toPlainPost({bool markup = true}) {
    final parts = <String>[];
    final links = <int, List<String>>{};
    for (final b in blocks) {
      final t = markup ? _composerText(b) : _plainText(b);
      if (t != null && t.isNotEmpty) {
        parts.add(t);
        continue;
      }
      if (b.mediaRefs.isEmpty || parts.isEmpty) continue;
      final paragraph = ParagraphMedia.split(parts.join('\n\n')).length - 1;
      final list = links.putIfAbsent(paragraph, () => []);
      for (final r in b.mediaRefs) {
        if (!list.contains(r.mediaId)) list.add(r.mediaId);
      }
    }
    return (
      text: parts.join('\n\n'),
      mediaIds: mediaIds,
      paragraphMedia: ParagraphMedia.normalized(links),
    );
  }

  ArticleDocument copyWith({
    List<ArticleBlock>? blocks,
    String? subtitle,
    ArticleMediaRef? cover,
    String? excerpt,
    String? slug,
    String? canonicalUrl,
    ArticleStatus? status,
    bool clearSubtitle = false,
    bool clearCover = false,
    bool clearExcerpt = false,
    bool clearSlug = false,
    bool clearCanonicalUrl = false,
    bool clearStatus = false,
  }) =>
      ArticleDocument(
        blocks: blocks ?? this.blocks,
        subtitle: clearSubtitle ? null : (subtitle ?? this.subtitle),
        cover: clearCover ? null : (cover ?? this.cover),
        excerpt: clearExcerpt ? null : (excerpt ?? this.excerpt),
        slug: clearSlug ? null : (slug ?? this.slug),
        canonicalUrl: clearCanonicalUrl ? null : (canonicalUrl ?? this.canonicalUrl),
        status: clearStatus ? null : (status ?? this.status),
      );

  Map<String, dynamic> toJson() => {
        'v': schemaVersion,
        'blocks': [for (final b in blocks) b.toJson()],
        if (subtitle != null) 'subtitle': subtitle,
        if (cover != null) 'cover': cover!.toJson(),
        if (excerpt != null) 'excerpt': excerpt,
        if (slug != null) 'slug': slug,
        if (canonicalUrl != null) 'canonicalUrl': canonicalUrl,
        if (status != null) 'status': status!.name,
      };

  @override
  bool operator ==(Object other) =>
      other is ArticleDocument &&
      _sameList(other.blocks, blocks) &&
      other.subtitle == subtitle &&
      other.cover == cover &&
      other.excerpt == excerpt &&
      other.slug == slug &&
      other.canonicalUrl == canonicalUrl &&
      other.status == status;

  @override
  int get hashCode => Object.hash(Object.hashAll(blocks), subtitle, cover, excerpt, slug, canonicalUrl, status);
}

// ------------------------------------------------------- composer text

final RegExp _headingLine = RegExp(r'^(#{1,6}) (\S.*)$');
final RegExp _bulletLine = RegExp(r'^([-*+]) (.*)$');
final RegExp _numberLine = RegExp(r'^(\d{1,9})\. (.*)$');
final RegExp _quoteLine = RegExp(r'^> ?(.*)$');
final RegExp _fence = RegExp(r'^(`{3,}|~{3,})([^`\s]*)$');

/// One paragraph of composer text as a block, or a plain paragraph when the
/// block would not give the paragraph back exactly.
ArticleBlock _blockFromParagraph(String id, String p) {
  final parsed = _tryBlock(id, p);
  if (parsed != null && _composerText(parsed) == p) return parsed;
  return ArticleParagraph.plain(id, p);
}

ArticleBlock? _tryBlock(String id, String p) {
  final lines = p.split('\n').map((l) => l.endsWith('\r') ? l.substring(0, l.length - 1) : l).toList();
  // Code: a fenced paragraph.
  final open = _fence.firstMatch(lines.first);
  if (open != null && lines.length >= 2 && lines.last == open.group(1)) {
    final language = open.group(2)!;
    return ArticleCode(id, lines.sublist(1, lines.length - 1).join('\n'), language: language.isEmpty ? null : language);
  }
  if (lines.length == 1 && p == '---') return ArticleDivider(id);
  if (lines.length == 1) {
    final h = _headingLine.firstMatch(p);
    if (h != null) {
      final spans = _inline(h.group(2)!);
      return spans == null ? null : ArticleHeading(id, spans, level: h.group(1)!.length);
    }
  }
  final bullets = [for (final l in lines) _bulletLine.firstMatch(l)];
  if (bullets.every((m) => m != null) && bullets.map((m) => m!.group(1)).toSet().length == 1) {
    final items = <List<ArticleSpan>>[];
    for (final m in bullets) {
      final spans = _inline(m!.group(2)!);
      if (spans == null) return null;
      items.add(spans);
    }
    return ArticleList(id, items, marker: bullets.first!.group(1)!);
  }
  // A numbered list starts at 1, as inside the paragraphs EmDash reads, so
  // "1984. It was a good year." stays a sentence.
  final numbers = [for (final l in lines) _numberLine.firstMatch(l)];
  if (numbers.every((m) => m != null) && numbers.first!.group(1) == '1') {
    final items = <List<ArticleSpan>>[];
    for (final m in numbers) {
      final spans = _inline(m!.group(2)!);
      if (spans == null) return null;
      items.add(spans);
    }
    return ArticleList(id, items, ordered: true, start: int.parse(numbers.first!.group(1)!));
  }
  final quoted = [for (final l in lines) _quoteLine.firstMatch(l)];
  if (quoted.every((m) => m != null) && lines.every((l) => l.startsWith('> ') || l == '>')) {
    final spans = _inline(quoted.map((m) => m!.group(1)!).join('\n'));
    return spans == null ? null : ArticleQuote(id, spans);
  }
  final spans = _inline(p);
  return spans == null ? null : ArticleParagraph(id, spans);
}

/// Inline Markdown in [text] as spans, read by the same parser EmDash posts
/// use ([markdownToPortableText]); null when it is not one plain run of
/// inline text (it starts a list, holds strikethrough...).
List<ArticleSpan>? _inline(String text) {
  if (text.isEmpty) return const [];
  final blocks = markdownToPortableText(text, keyPrefix: 'x');
  if (blocks.length != 1) return null;
  final b = blocks.single;
  if (b['_type'] != 'block' || b['style'] != 'normal' || b['listItem'] != null) return null;
  final defs = {
    for (final d in b['markDefs'] as List? ?? const [])
      if (d is Map) '${d['_key']}': '${d['href']}',
  };
  final out = <ArticleSpan>[];
  for (final c in b['children'] as List? ?? const []) {
    final child = c as Map;
    final marks = <ArticleMark>{};
    String? link;
    for (final m in child['marks'] as List? ?? const []) {
      switch (m) {
        case 'strong':
          marks.add(ArticleMark.bold);
        case 'em':
          marks.add(ArticleMark.italic);
        case 'code':
          marks.add(ArticleMark.code);
        default:
          final href = defs['$m'];
          if (href == null) return null;
          link = href;
      }
    }
    final s = '${child['text']}';
    if (s.isNotEmpty) out.add(ArticleSpan(s, marks: marks, link: link));
  }
  return out;
}

/// 1.4.4: one block's text as the article editor shows it (`**bold**`,
/// `*italic*`, `` `code` ``, `[words](https://...)`) read back as spans.
/// Lossless: text whose marks would not be written back exactly by
/// [composerInline] is kept as one plain span, as written, so what the user
/// sees in the editor is what goes out. The spaces around the text are kept
/// as plain text.
List<ArticleSpan> articleInlineFromMarkup(String text) {
  if (text.isEmpty) return const [];
  final core = text.trim();
  if (core.isEmpty) return [ArticleSpan(text)];
  final start = text.indexOf(core);
  final lead = text.substring(0, start);
  final trail = text.substring(start + core.length);
  final parsed = _inline(core);
  final body = parsed != null && composerInline(parsed) == core ? parsed : [ArticleSpan(core)];
  return [if (lead.isNotEmpty) ArticleSpan(lead), ...body, if (trail.isNotEmpty) ArticleSpan(trail)];
}

/// [spans] written back the way the composer writes them.
String composerInline(List<ArticleSpan> spans) {
  final out = StringBuffer();
  var i = 0;
  while (i < spans.length) {
    final link = spans[i].link;
    if (link == null) {
      out.write(_marked(spans[i]));
      i++;
      continue;
    }
    // A link over several spans (bold words inside it) is one [..](..).
    var j = i;
    final inside = StringBuffer();
    while (j < spans.length && spans[j].link == link) {
      inside.write(_marked(spans[j]));
      j++;
    }
    final words = inside.toString();
    out.write(words == link ? link : '[$words]($link)');
    i = j;
  }
  return out.toString();
}

String _marked(ArticleSpan s) {
  var t = s.text;
  if (s.code) t = '`$t`';
  if (s.italic) t = '*$t*';
  if (s.bold) t = '**$t**';
  return t;
}

String? _composerText(ArticleBlock b) => switch (b) {
      ArticleParagraph(:final spans) => composerInline(spans),
      ArticleHeading(:final spans) => '${'#' * b.safeLevel} ${composerInline(spans)}',
      ArticleQuote(:final spans, :final citation) => [
          ...composerInline(spans).split('\n').map((l) => l.isEmpty ? '>' : '> $l'),
          if ((citation ?? '').trim().isNotEmpty) '> ${citation!.trim()}',
        ].join('\n'),
      ArticleList(:final items, :final ordered, :final start, :final marker) => [
          for (var i = 0; i < items.length; i++) '${ordered ? '${start + i}.' : marker} ${composerInline(items[i])}',
        ].join('\n'),
      ArticleCode(:final code, :final language) => '${_fenceFor(code)}${language ?? ''}\n$code\n${_fenceFor(code)}',
      ArticleDivider() => '---',
      ArticleEmbed(:final url) => url,
      _ => null,
    };

/// A code fence longer than any run of backticks in [code].
String _fenceFor(String code) {
  var longest = 0;
  for (final m in RegExp('`+').allMatches(code)) {
    if (m.end - m.start > longest) longest = m.end - m.start;
  }
  return '`' * (longest < 3 ? 3 : longest + 1);
}

/// [spans] as plain words: a link whose words are not its address gets the
/// address after them.
String plainInline(List<ArticleSpan> spans) {
  final out = StringBuffer();
  var i = 0;
  while (i < spans.length) {
    final link = spans[i].link;
    if (link == null) {
      out.write(spans[i].text);
      i++;
      continue;
    }
    final words = StringBuffer();
    while (i < spans.length && spans[i].link == link) {
      words.write(spans[i].text);
      i++;
    }
    final w = words.toString();
    out.write(w.trim().isEmpty || w == link ? link : '$w ($link)');
  }
  return out.toString();
}

String? _plainText(ArticleBlock b) => switch (b) {
      ArticleParagraph(:final spans) || ArticleHeading(:final spans) => plainInline(spans),
      ArticleQuote(:final spans, :final citation) => [
          '“${plainInline(spans)}”',
          if ((citation ?? '').trim().isNotEmpty) citation!.trim(),
        ].join('\n'),
      ArticleList(:final items, :final ordered, :final start) => [
          for (var i = 0; i < items.length; i++) '${ordered ? '${start + i}.' : '•'} ${plainInline(items[i])}',
        ].join('\n'),
      ArticleCode(:final code) => code,
      ArticleEmbed(:final url) => url,
      _ => null,
    };
