import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

// 1.4.4: articles. What the article editor and the previews share: how a
// block is named and drawn as an icon, its text as the editor shows it
// (Markdown marks: **bold**, *italic*, `code`, [words](address)), and the
// field controller that shows those marks while the user types.

/// The icon of a block type.
IconData articleBlockIcon(ArticleBlockType type) => switch (type) {
      ArticleBlockType.paragraph => Icons.notes_rounded,
      ArticleBlockType.heading => Icons.title_rounded,
      ArticleBlockType.image => Icons.image_outlined,
      ArticleBlockType.gallery => Icons.collections_outlined,
      ArticleBlockType.video => Icons.movie_outlined,
      ArticleBlockType.audio => Icons.graphic_eq_rounded,
      ArticleBlockType.embed => Icons.smart_display_outlined,
      ArticleBlockType.quote => Icons.format_quote_rounded,
      ArticleBlockType.list => Icons.format_list_bulleted_rounded,
      ArticleBlockType.code => Icons.code_rounded,
      ArticleBlockType.divider => Icons.horizontal_rule_rounded,
      ArticleBlockType.unknown => Icons.help_outline_rounded,
    };

/// The name of a block type, as menus show it.
String articleBlockTypeName(ArticleBlockType type) => switch (type) {
      ArticleBlockType.paragraph => 'Paragraph',
      ArticleBlockType.heading => 'Heading',
      ArticleBlockType.image => 'Photo',
      ArticleBlockType.gallery => 'Gallery',
      ArticleBlockType.video => 'Video',
      ArticleBlockType.audio => 'Sound',
      ArticleBlockType.embed => 'Embed',
      ArticleBlockType.quote => 'Quote',
      ArticleBlockType.list => 'List',
      ArticleBlockType.code => 'Code',
      ArticleBlockType.divider => 'Divider',
      ArticleBlockType.unknown => 'Unknown block',
    };

/// One line naming [b] for lists of blocks ("Heading: Why it matters",
/// "Gallery: 3 photos"). [media] names files by their file name.
String articleBlockLabel(ArticleBlock b, {List<MediaAttachment> media = const []}) {
  String words(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 48 ? '${one.substring(0, 47)}…' : one;
  }

  String file(ArticleMediaRef r) {
    final caption = (r.caption ?? '').trim();
    if (caption.isNotEmpty) return words(caption);
    return media.where((m) => m.id == r.mediaId).firstOrNull?.fileName ?? 'a file';
  }

  String named(String what, String detail) => detail.isEmpty ? what : '$what: $detail';
  return switch (b) {
    ArticleParagraph(:final text) => named('Paragraph', words(text)),
    ArticleHeading(:final text) => named('Heading', words(text)),
    ArticleQuote(:final text) => named('Quote', words(text)),
    ArticleList(:final items, :final ordered) => '${ordered ? 'Numbered list' : 'List'}: ${items.length} ${items.length == 1 ? 'item' : 'items'}',
    ArticleCode(:final language) => named('Code', language ?? ''),
    ArticleDivider() => 'Divider',
    ArticleImage(:final media) => named('Photo', file(media)),
    ArticleGallery(:final items) => 'Gallery: ${items.length} ${items.length == 1 ? 'photo' : 'photos'}',
    ArticleVideo(:final media) => named('Video', file(media)),
    ArticleAudio(:final media) => named('Sound', file(media)),
    ArticleEmbed(:final url) => named('Embed', Uri.tryParse(url)?.host.replaceFirst('www.', '') ?? url),
    ArticleUnknownBlock() => 'A block from a newer NEFORUM',
  };
}

/// The text of a text block as the editor shows it; null for blocks without
/// one (files, dividers, embeds).
String? articleBlockMarkup(ArticleBlock b) => switch (b) {
      ArticleParagraph(:final spans) || ArticleHeading(:final spans) || ArticleQuote(:final spans) => composerInline(spans),
      ArticleList(:final items) => items.map(composerInline).join('\n'),
      ArticleCode(:final code) => code,
      _ => null,
    };

/// [b] with its text replaced by [markup] as the editor shows it (see
/// [articleBlockMarkup]); [b] itself for blocks without text.
ArticleBlock articleBlockWithMarkup(ArticleBlock b, String markup) => switch (b) {
      ArticleParagraph() => ArticleParagraph(b.id, articleInlineFromMarkup(markup)),
      ArticleHeading(:final level) => ArticleHeading(b.id, articleInlineFromMarkup(markup.replaceAll('\n', ' ')), level: level),
      ArticleQuote(:final citation) => ArticleQuote(b.id, articleInlineFromMarkup(markup), citation: citation),
      ArticleList(:final ordered, :final start, :final marker) =>
        ArticleList(b.id, [for (final line in markup.split('\n')) articleInlineFromMarkup(line)], ordered: ordered, start: start, marker: marker),
      ArticleCode(:final language) => ArticleCode(b.id, markup, language: language),
      _ => b,
    };

/// The blocks a text block can be turned into, keeping its words.
const List<ArticleBlockType> articleTextTypes = [
  ArticleBlockType.paragraph,
  ArticleBlockType.heading,
  ArticleBlockType.quote,
  ArticleBlockType.list,
  ArticleBlockType.code,
];

/// [b] (a text block) turned into a block of [type], with the same id and
/// words ([ordered] for a list).
ArticleBlock articleBlockConverted(ArticleBlock b, ArticleBlockType type, {bool ordered = false}) {
  final markup = articleBlockMarkup(b) ?? '';
  return switch (type) {
    ArticleBlockType.heading => ArticleHeading(b.id, articleInlineFromMarkup(markup.replaceAll('\n', ' ')), level: b is ArticleHeading ? b.level : 2),
    ArticleBlockType.quote => ArticleQuote(b.id, articleInlineFromMarkup(markup), citation: b is ArticleQuote ? b.citation : null),
    ArticleBlockType.list => ArticleList(b.id, [for (final l in markup.split('\n')) articleInlineFromMarkup(l)], ordered: ordered),
    ArticleBlockType.code => ArticleCode(b.id, markup),
    _ => ArticleParagraph(b.id, articleInlineFromMarkup(markup)),
  };
}

/// A field that shows the article's inline marks while the user types:
/// `**bold**` in bold, `*italic*` in italics, `` `code` `` in the code font
/// and `[words](address)` as a link, with the marks themselves faint. Every
/// character stays in the field: what is typed is what is read
/// ([articleInlineFromMarkup]). While an input method is composing, the text
/// is drawn plain so it is never disturbed. [plain] fields (code blocks)
/// show no marks.
class ArticleMarkupController extends TextEditingController {
  ArticleMarkupController({super.text, this.plain = false});

  final bool plain;

  static final RegExp _token = RegExp(
    r'(`[^`\n]+`)' // code
    r'|(\[[^\]\n]+\]\([^)\s]+\))' // link
    r'|(\*\*\*[^*\n]+\*\*\*)' // bold italic
    r'|(\*\*[^*\n]+\*\*)' // bold
    r'|((?<!\*)\*[^*\n]+\*(?!\*))', // italic
  );

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final composing = value.composing;
    if (plain || (withComposing && composing.isValid && !composing.isCollapsed)) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    return TextSpan(style: style, children: articleMarkupSpans(text, style ?? const TextStyle(), context));
  }
}

/// [text] with its marks drawn (see [ArticleMarkupController]).
List<InlineSpan> articleMarkupSpans(String text, TextStyle base, BuildContext context) {
  final nf = context.nf;
  final faint = TextStyle(color: nf.textFaint, fontWeight: FontWeight.w400, fontStyle: FontStyle.normal);
  final out = <InlineSpan>[];
  var pos = 0;
  for (final m in ArticleMarkupController._token.allMatches(text)) {
    if (m.start > pos) out.add(TextSpan(text: text.substring(pos, m.start)));
    final t = m.group(0)!;
    if (m.group(1) != null) {
      out
        ..add(TextSpan(text: '`', style: faint))
        ..add(TextSpan(text: t.substring(1, t.length - 1), style: monoStyle(context, size: (base.fontSize ?? 15) * 0.92, color: nf.accent)))
        ..add(TextSpan(text: '`', style: faint));
    } else if (m.group(2) != null) {
      final close = t.indexOf('](');
      out
        ..add(TextSpan(text: '[', style: faint))
        ..add(TextSpan(text: t.substring(1, close), style: TextStyle(color: nf.info, decoration: TextDecoration.underline, decorationColor: nf.info)))
        ..add(TextSpan(text: t.substring(close), style: faint.copyWith(fontSize: (base.fontSize ?? 15) * 0.85)));
    } else {
      final n = m.group(3) != null ? 3 : (m.group(4) != null ? 2 : 1);
      final marks = '*' * n;
      out
        ..add(TextSpan(text: marks, style: faint))
        ..add(TextSpan(
          text: t.substring(n, t.length - n),
          style: TextStyle(fontWeight: n >= 2 ? FontWeight.w700 : null, fontStyle: n != 2 ? FontStyle.italic : null),
        ))
        ..add(TextSpan(text: marks, style: faint));
    }
    pos = m.end;
  }
  if (pos < text.length) out.add(TextSpan(text: text.substring(pos)));
  return out;
}

/// Puts [marker] (`**`, `*` or `` ` ``) around the selection of [c], or
/// takes it away when the selection already has it. With nothing selected
/// the pair goes in at the cursor, with the cursor between.
void toggleArticleMark(TextEditingController c, String marker) {
  final v = c.value;
  var sel = v.selection;
  if (!sel.isValid) sel = TextSelection.collapsed(offset: v.text.length);
  final start = sel.start, end = sel.end;
  final text = v.text;
  final n = marker.length;
  final before = text.substring(0, start);
  final after = text.substring(end);
  final inside = text.substring(start, end);
  // Already marked just outside the selection: unmark.
  if (before.endsWith(marker) && after.startsWith(marker) && !(marker == '*' && before.endsWith('**') && after.startsWith('**') && !before.endsWith('***'))) {
    c.value = TextEditingValue(
      text: before.substring(0, before.length - n) + inside + after.substring(n),
      selection: TextSelection(baseOffset: start - n, extentOffset: end - n),
    );
    return;
  }
  // Marked inside the selection: unmark.
  if (inside.length >= 2 * n && inside.startsWith(marker) && inside.endsWith(marker)) {
    final bare = inside.substring(n, inside.length - n);
    c.value = TextEditingValue(text: before + bare + after, selection: TextSelection(baseOffset: start, extentOffset: start + bare.length));
    return;
  }
  c.value = TextEditingValue(
    text: '$before$marker$inside$marker$after',
    selection: inside.isEmpty ? TextSelection.collapsed(offset: start + n) : TextSelection(baseOffset: start + n, extentOffset: end + n),
  );
}

/// Makes the selection of [c] a link to [url] (`[words](url)`); with nothing
/// selected the bare address goes in (the blogs link bare addresses).
void insertArticleLink(TextEditingController c, String url) {
  final v = c.value;
  var sel = v.selection;
  if (!sel.isValid) sel = TextSelection.collapsed(offset: v.text.length);
  final inside = v.text.substring(sel.start, sel.end);
  final link = inside.trim().isEmpty || inside == url ? url : '[$inside]($url)';
  final text = v.text.replaceRange(sel.start, sel.end, link);
  c.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: sel.start + link.length));
}
