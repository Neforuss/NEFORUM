import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../platform/env.dart';
import '../../state/composer.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/surfaces.dart';
import 'article_blocks.dart';
import 'article_fields.dart';
import 'article_media_chooser.dart';
import 'emoji_insert.dart';
import 'media_tray.dart';

// 1.4.4: articles. The composer's Article mode: the article as a list of
// blocks (paragraphs, headings, photos, galleries, videos, sound, embeds,
// quotes, lists, code, dividers), each its own field, in the order they are
// read. Blocks are added from "Add block" (after the block being edited),
// moved by their handle or from their menu, and removed from their menu.
// Words carry marks as Markdown (**bold**, *italic*, `code`, [words](link)),
// shown as they are typed and set with the format bar or the keyboard.
//
// Plain Flutter widgets, not a rich text library: every block is a native
// text field (the platform's input methods, spell check, screen readers and
// keyboard all work as in the rest of NEFORUM), and the editor holds the
// article's own blocks, so nothing is converted on the way in or out.

/// The article editor (Article mode): the article's fields, its blocks and
/// the post's files.
class ArticleEditor extends ConsumerStatefulWidget {
  const ArticleEditor({super.key});

  @override
  ConsumerState<ArticleEditor> createState() => _ArticleEditorState();
}

/// The menu entries of "Add block".
enum _NewBlock {
  paragraph('Paragraph', Icons.notes_rounded),
  heading('Heading', Icons.title_rounded),
  image('Photo', Icons.image_outlined),
  gallery('Gallery', Icons.collections_outlined),
  video('Video', Icons.movie_outlined),
  audio('Sound', Icons.graphic_eq_rounded),
  embed('Embed (YouTube, a post, a link)', Icons.smart_display_outlined),
  quote('Quote', Icons.format_quote_rounded),
  list('List', Icons.format_list_bulleted_rounded),
  numbered('Numbered list', Icons.format_list_numbered_rounded),
  code('Code', Icons.code_rounded),
  divider('Divider', Icons.horizontal_rule_rounded);

  const _NewBlock(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _ArticleEditorState extends ConsumerState<ArticleEditor> {
  final Map<String, ArticleMarkupController> _texts = {};
  final Map<String, TextEditingController> _fields = {};
  final Map<String, FocusNode> _focus = {};

  /// The block being edited (or last edited): new blocks go after it.
  String? _active;

  ArticleDocument get _doc => ref.read(composerProvider).article ?? const ArticleDocument();

  @override
  void dispose() {
    for (final c in _texts.values) {
      c.dispose();
    }
    for (final c in _fields.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------- the document

  void _set(ArticleDocument doc) => ref.read(composerProvider.notifier).setArticle(doc);

  void _replace(ArticleBlock b) => _set(_doc.copyWith(blocks: [for (final x in _doc.blocks) x.id == b.id ? b : x]));

  /// Puts [blocks] after block [after] (the active block when null; the end
  /// when there is none).
  void _insert(List<ArticleBlock> blocks, {String? after}) {
    final doc = _doc;
    final anchor = after ?? _active;
    final at = anchor == null ? -1 : doc.blocks.indexWhere((b) => b.id == anchor);
    final list = [...doc.blocks];
    list.insertAll(at < 0 ? list.length : at + 1, blocks);
    _set(doc.copyWith(blocks: list));
  }

  void _remove(String id) {
    final doc = _doc;
    final i = doc.blocks.indexWhere((b) => b.id == id);
    if (i < 0) return;
    _set(doc.withoutBlocks([id]));
    if (_active == id) _active = i > 0 ? doc.blocks[i - 1].id : null;
    // The block before takes the cursor, at its end.
    final before = i > 0 ? doc.blocks[i - 1] : null;
    if (before != null && articleBlockMarkup(before) != null) _focusLater(before.id, atEnd: true);
  }

  void _move(String id, int by) {
    final doc = _doc;
    final i = doc.blocks.indexWhere((b) => b.id == id);
    final to = i + by;
    if (i < 0 || to < 0 || to >= doc.blocks.length) return;
    final list = [...doc.blocks];
    list.insert(to, list.removeAt(i));
    _set(doc.copyWith(blocks: list));
    if (articleBlockMarkup(list[to]) != null) _focusLater(id);
  }

  void _reorder(int from, int to) {
    final list = [..._doc.blocks];
    if (from < 0 || from >= list.length) return;
    list.insert(to.clamp(0, list.length - 1), list.removeAt(from));
    _set(_doc.copyWith(blocks: list));
  }

  /// Adds a block of [kind] after the active block. Photos, galleries,
  /// videos and sound ask for their files first; backing out adds nothing.
  Future<void> _add(_NewBlock kind, {String? after}) async {
    final doc = _doc;
    final anchor = after ?? _active;
    String id(String prefix) => doc.newBlockId(prefix);
    Future<List<String>?> choose(ArticleMediaKind k, {bool multiple = false}) => showArticleMediaChooser(context, kind: k, multiple: multiple);
    final ArticleBlock? block = switch (kind) {
      _NewBlock.paragraph => ArticleParagraph(id('p'), const []),
      _NewBlock.heading => ArticleHeading(id('h'), const []),
      _NewBlock.quote => ArticleQuote(id('q'), const []),
      _NewBlock.list => ArticleList(id('l'), const [[]]),
      _NewBlock.numbered => ArticleList(id('l'), const [[]], ordered: true),
      _NewBlock.code => ArticleCode(id('c'), ''),
      _NewBlock.divider => ArticleDivider(id('d')),
      _NewBlock.embed => ArticleEmbed(id('e'), ''),
      _NewBlock.image => switch (await choose(ArticleMediaKind.photo)) {
          [final m, ...] => ArticleImage(id('m'), ArticleMediaRef(m)),
          _ => null,
        },
      _NewBlock.gallery => switch (await choose(ArticleMediaKind.photo, multiple: true)) {
          final ids? when ids.isNotEmpty => ArticleGallery(id('g'), [for (final m in ids) ArticleMediaRef(m)]),
          _ => null,
        },
      _NewBlock.video => switch (await choose(ArticleMediaKind.video)) {
          [final m, ...] => ArticleVideo(id('v'), ArticleMediaRef(m)),
          _ => null,
        },
      _NewBlock.audio => switch (await choose(ArticleMediaKind.sound)) {
          [final m, ...] => ArticleAudio(id('a'), ArticleMediaRef(m)),
          _ => null,
        },
    };
    if (block == null || !mounted) return;
    _insert([block], after: anchor);
    _active = block.id;
    if (articleBlockMarkup(block) != null || block is ArticleEmbed) _focusLater(block.id);
  }

  // -------------------------------------------------------------- controllers

  ArticleMarkupController _textFor(ArticleBlock b) =>
      _texts.putIfAbsent(b.id, () => ArticleMarkupController(text: articleBlockMarkup(b) ?? '', plain: b is ArticleCode));

  TextEditingController _fieldFor(String key, String? value) => _fields.putIfAbsent(key, () => TextEditingController(text: value ?? ''));

  FocusNode _focusFor(String id) => _focus.putIfAbsent(id, () {
        final node = FocusNode(debugLabel: 'article-block-$id');
        node.onKeyEvent = (_, event) => _onKey(id, event);
        node.addListener(() {
          if (node.hasFocus) _active = id;
        });
        return node;
      });

  /// The article changed (an edit, or from outside: a post opened, a file
  /// removed): fields whose text no longer reads as their block are put
  /// back in step. A field being typed in always reads as its block, so it
  /// is left alone.
  void _sync(ArticleDocument? doc) {
    if (doc == null) return;
    final ids = {for (final b in doc.blocks) b.id};
    for (final b in doc.blocks) {
      final c = _texts[b.id];
      if (c != null) {
        final markup = articleBlockMarkup(b);
        if (markup == null) {
          _disposeLater(_texts.remove(b.id));
        } else if (articleBlockWithMarkup(b, c.text) != b) {
          c.value = TextEditingValue(text: markup, selection: TextSelection.collapsed(offset: markup.length));
        }
      }
      for (final (key, value) in _fieldValues(b)) {
        final f = _fields[key];
        if (f != null && f.text != (value ?? '')) f.text = value ?? '';
      }
    }
    for (final id in _texts.keys.where((id) => !ids.contains(id)).toList()) {
      _disposeLater(_texts.remove(id));
    }
    for (final key in _fields.keys.where((k) => !ids.contains(k.split(':').first)).toList()) {
      _disposeLater(_fields.remove(key));
    }
    for (final id in _focus.keys.where((id) => !ids.contains(id)).toList()) {
      final node = _focus.remove(id)!;
      WidgetsBinding.instance.addPostFrameCallback((_) => node.dispose());
    }
  }

  /// The side fields of [b] (caption, citation...) by field key.
  List<(String, String?)> _fieldValues(ArticleBlock b) => switch (b) {
        ArticleQuote(:final citation) => [('${b.id}:citation', citation)],
        ArticleCode(:final language) => [('${b.id}:language', language)],
        ArticleEmbed(:final url, :final caption) => [('${b.id}:url', url), ('${b.id}:caption', caption)],
        ArticleGallery(:final caption) => [('${b.id}:caption', caption)],
        ArticleImage(:final media) || ArticleVideo(:final media) || ArticleAudio(:final media) => [
            ('${b.id}:caption', media.caption),
            ('${b.id}:credit', media.credit),
          ],
        _ => const [],
      };

  /// A field's controller is let go after the frame that takes the field
  /// away, never while the field may still hold it.
  void _disposeLater(TextEditingController? c) {
    if (c != null) WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
  }

  void _focusLater(String id, {bool atEnd = false, int? offset}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _focus[id];
      final c = _texts[id];
      if (c != null) {
        final at = offset ?? (atEnd ? c.text.length : 0);
        c.selection = TextSelection.collapsed(offset: at.clamp(0, c.text.length));
      }
      node?.requestFocus();
    });
  }

  // ------------------------------------------------------------ text editing

  /// Words typed in block [id]. Two line breaks in a paragraph start a new
  /// paragraph there, as they do in the plain composer.
  void _onText(String id, String text) {
    final b = _doc.blockById(id);
    if (b == null) return;
    if (b is ArticleParagraph && text.contains('\n\n')) {
      final pieces = text.split(RegExp(r'\n\n+'));
      final doc = _doc;
      final fresh = <ArticleBlock>[];
      var probe = doc;
      for (final piece in pieces.skip(1)) {
        final nb = ArticleParagraph(probe.newBlockId('p'), articleInlineFromMarkup(piece));
        fresh.add(nb);
        probe = probe.copyWith(blocks: [...probe.blocks, nb]);
      }
      final first = ArticleParagraph(id, articleInlineFromMarkup(pieces.first));
      final list = [for (final x in doc.blocks) x.id == id ? first : x];
      list.insertAll(list.indexWhere((x) => x.id == id) + 1, fresh);
      _set(doc.copyWith(blocks: list));
      _active = fresh.last.id;
      _focusLater(fresh.last.id);
      return;
    }
    _replace(articleBlockWithMarkup(b, text));
  }

  /// Desktop keys inside a block: Enter starts a new paragraph (Shift+Enter
  /// is a line break), Enter on an empty last list item ends the list, and
  /// Backspace in an empty block removes it.
  KeyEventResult _onKey(String id, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final b = _doc.blockById(id);
    final c = _texts[id];
    if (b == null || c == null) return KeyEventResult.ignored;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace && c.text.isEmpty && _doc.blocks.length > 1) {
      _remove(id);
      return KeyEventResult.handled;
    }
    final enter = key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter;
    if (!enter || shift || !Env.isDesktop) return KeyEventResult.ignored;
    final sel = c.selection;
    final at = sel.isValid ? sel.start : c.text.length;
    switch (b) {
      case ArticleParagraph() || ArticleHeading():
        final before = c.text.substring(0, at);
        final after = c.text.substring(sel.isValid ? sel.end : at);
        final nb = ArticleParagraph(_doc.newBlockId('p'), articleInlineFromMarkup(after));
        _replace(articleBlockWithMarkup(b, before));
        _insert([nb], after: id);
        _active = nb.id;
        _focusLater(nb.id);
        return KeyEventResult.handled;
      case ArticleList():
        if (c.text.endsWith('\n') && at == c.text.length) {
          _replace(articleBlockWithMarkup(b, c.text.substring(0, c.text.length - 1)));
          final nb = ArticleParagraph(_doc.newBlockId('p'), const []);
          _insert([nb], after: id);
          _active = nb.id;
          _focusLater(nb.id);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      default:
        return KeyEventResult.ignored;
    }
  }

  ArticleMarkupController? get _activeText => _active == null ? null : _texts[_active];

  void _mark(String marker) {
    final c = _activeText;
    if (c == null || _doc.blockById(_active!) is ArticleCode) return;
    toggleArticleMark(c, marker);
    _onText(_active!, c.text);
    _focus[_active]?.requestFocus();
  }

  Future<void> _link() async {
    final id = _active;
    final c = _activeText;
    if (id == null || c == null || _doc.blockById(id) is ArticleCode) return;
    final selection = c.selection;
    final url = await showArticleLinkDialog(context);
    if (url == null || !mounted) return;
    if (selection.isValid) c.selection = selection;
    insertArticleLink(c, url);
    _onText(id, c.text);
    _focus[id]?.requestFocus();
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    ref.listen(composerProvider.select((c) => c.article), (_, next) => _sync(next));
    final nf = context.nf;
    final doc = ref.watch(composerProvider.select((c) => c.article)) ?? const ArticleDocument();
    final media = ref.watch(composerProvider.select((c) => c.media));
    final mac = Env.isMacOS;
    SingleActivator key(LogicalKeyboardKey k, {bool shift = false, bool alt = false}) =>
        SingleActivator(k, control: !mac, meta: mac, shift: shift, alt: alt);

    final blocks = ReorderableListView.builder(
      key: const ValueKey('article-blocks'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: doc.blocks.length,
      onReorderItem: _reorder,
      proxyDecorator: (child, _, _) => Material(color: Colors.transparent, child: child),
      itemBuilder: (context, i) {
        final b = doc.blocks[i];
        return _BlockRow(
          key: ValueKey('article-block-${b.id}'),
          index: i,
          count: doc.blocks.length,
          block: b,
          body: _body(b, media, single: doc.blocks.length == 1),
          onMoveUp: i == 0 ? null : () => _move(b.id, -1),
          onMoveDown: i == doc.blocks.length - 1 ? null : () => _move(b.id, 1),
          onRemove: () => _remove(b.id),
          onAddBelow: (kind) => _add(kind, after: b.id),
          onTurnInto: articleBlockMarkup(b) == null
              ? null
              : (type, {bool ordered = false}) {
                  _disposeLater(_texts.remove(b.id));
                  _replace(articleBlockConverted(b, type, ordered: ordered));
                },
        );
      },
    );

    final editor = NfCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _FormatBar(onMark: _mark, onLink: _link, onAdd: _add),
        Divider(height: 1, color: nf.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xs, Space.sm, Space.sm, Space.sm),
          child: doc.blocks.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Text('Your article is empty. Add a paragraph, a heading or a photo to start.',
                      style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
                )
              : blocks,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
          child: Align(alignment: Alignment.centerLeft, child: _AddBlockButton(onAdd: (k) => _add(k, after: doc.blocks.lastOrNull?.id))),
        ),
      ]),
    );

    return CallbackShortcuts(
      bindings: {
        key(LogicalKeyboardKey.keyB): () => _mark('**'),
        key(LogicalKeyboardKey.keyI): () => _mark('*'),
        key(LogicalKeyboardKey.keyE): () => _mark('`'),
        key(LogicalKeyboardKey.keyK): _link,
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true, shift: true): () {
          if (_active != null) _move(_active!, -1);
        },
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true, shift: true): () {
          if (_active != null) _move(_active!, 1);
        },
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const ArticleFieldsPanel(),
        const SizedBox(height: Space.lg),
        editor,
        const SizedBox(height: Space.lg),
        const _ArticleFiles(),
      ]),
    );
  }

  /// The editing body of block [b].
  Widget _body(ArticleBlock b, List<MediaAttachment> media, {required bool single}) {
    final nf = context.nf;
    final t = context.text;
    InputDecoration bare(String hint, {TextStyle? style}) => InputDecoration(
          hintText: hint,
          hintStyle: (style ?? t.bodyLarge)?.copyWith(color: nf.textFaint),
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: Space.sm),
          isDense: true,
        );
    InputDecoration small(String label) => InputDecoration(labelText: label, isDense: true);

    Widget text(ArticleBlock b, {required String hint, TextStyle? style, int? maxLines, int minLines = 1}) {
      final c = _textFor(b);
      final node = _focusFor(b.id);
      return EmojiTargetField(
        controller: c,
        focusNode: node,
        onChanged: (v) => _onText(b.id, v),
        child: TextField(
          key: ValueKey('article-text-${b.id}'),
          controller: c,
          focusNode: node,
          onChanged: (v) => _onText(b.id, v),
          maxLines: maxLines,
          minLines: minLines,
          keyboardType: maxLines == 1 ? TextInputType.text : TextInputType.multiline,
          textInputAction: maxLines == 1 ? TextInputAction.next : TextInputAction.newline,
          style: style ?? t.bodyLarge?.copyWith(fontSize: 17, height: 1.55),
          decoration: bare(hint, style: style),
        ),
      );
    }

    Widget field(ArticleBlock b, String name, String? value, String label, ArticleBlock Function(String? v) apply, {bool mono = false}) {
      final c = _fieldFor('${b.id}:$name', value);
      return TextField(
        key: ValueKey('article-$name-${b.id}'),
        controller: c,
        style: mono ? monoStyle(context, size: 13) : t.bodyMedium,
        decoration: small(label),
        onChanged: (v) => _replace(apply(v.isEmpty ? null : v)),
      );
    }

    switch (b) {
      case ArticleParagraph():
        return text(b, hint: single ? 'Start writing your article…' : 'Paragraph');
      case ArticleHeading(:final level):
        final style = switch (level) {
          <= 2 => t.headlineSmall,
          3 => t.titleLarge,
          _ => t.titleMedium,
        };
        return Row(children: [
          _LevelButton(level: level, onChanged: (l) => _replace(ArticleHeading(b.id, b.spans, level: l))),
          const SizedBox(width: Space.sm),
          Expanded(child: text(b, hint: 'Heading', style: style, maxLines: 1)),
        ]);
      case ArticleQuote(:final citation):
        return Container(
          padding: const EdgeInsets.only(left: Space.md),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: nf.accent, width: 3))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            text(b, hint: 'Quote', style: t.bodyLarge?.copyWith(fontSize: 17, height: 1.5, fontStyle: FontStyle.italic)),
            field(b, 'citation', citation, 'Who said it (optional)', (v) => ArticleQuote(b.id, b.spans, citation: v)),
            const SizedBox(height: Space.xs),
          ]),
        );
      case ArticleList(:final ordered):
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: ToolButton(
              key: ValueKey('article-list-kind-${b.id}'),
              icon: ordered ? Icons.format_list_numbered_rounded : Icons.format_list_bulleted_rounded,
              tooltip: ordered ? 'Numbered list (tap for bullets)' : 'Bulleted list (tap for numbers)',
              size: 32,
              onPressed: () => _replace(ArticleList(b.id, b.items, ordered: !ordered, marker: b.marker)),
            ),
          ),
          const SizedBox(width: Space.sm),
          Expanded(child: text(b, hint: 'One item per line')),
        ]);
      case ArticleCode(:final language):
        return NfWell(
          padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.md, Space.sm),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            text(b, hint: 'Code', style: monoStyle(context, size: 13.5), minLines: 2),
            field(b, 'language', language, 'Language (optional, for example dart)', (v) => ArticleCode(b.id, b.code, language: v?.trim()), mono: true),
          ]),
        );
      case ArticleDivider():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.md),
          child: Row(children: [
            Expanded(child: Divider(color: nf.hairline)),
            Padding(padding: const EdgeInsets.symmetric(horizontal: Space.sm), child: Text('Divider', style: t.labelSmall?.copyWith(color: nf.textFaint))),
            Expanded(child: Divider(color: nf.hairline)),
          ]),
        );
      case ArticleEmbed(:final url, :final caption):
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            key: ValueKey('article-url-${b.id}'),
            controller: _fieldFor('${b.id}:url', url),
            focusNode: _focusFor(b.id),
            keyboardType: TextInputType.url,
            style: monoStyle(context, size: 13),
            decoration: small('Address of the video, post or page'),
            onChanged: (v) => _replace(ArticleEmbed(b.id, v.trim(), caption: caption)),
          ),
          field(b, 'caption', caption, 'Caption (optional)', (v) => ArticleEmbed(b.id, url, caption: v)),
          Padding(
            padding: const EdgeInsets.only(top: Space.xs, bottom: Space.sm),
            child: Text('Shown as a player or card where the blog can, as a link elsewhere.', style: t.bodySmall?.copyWith(color: nf.textFaint)),
          ),
        ]);
      case ArticleImage(media: final ref):
        return _MediaBody(
          block: b,
          refs: [ref],
          media: media,
          kind: ArticleMediaKind.photo,
          caption: field(b, 'caption', ref.caption, 'Caption (optional)', (v) => ArticleImage(b.id, _withCaption(ref, v))),
          credit: field(b, 'credit', ref.credit, 'Credit (optional)', (v) => ArticleImage(b.id, _withCredit(ref, v))),
          onChange: (ids) => _replace(ArticleImage(b.id, ArticleMediaRef(ids.first, caption: ref.caption, credit: ref.credit))),
        );
      case ArticleVideo(media: final ref):
        return _MediaBody(
          block: b,
          refs: [ref],
          media: media,
          kind: ArticleMediaKind.video,
          caption: field(b, 'caption', ref.caption, 'Caption (optional)', (v) => ArticleVideo(b.id, _withCaption(ref, v))),
          credit: field(b, 'credit', ref.credit, 'Credit (optional)', (v) => ArticleVideo(b.id, _withCredit(ref, v))),
          onChange: (ids) => _replace(ArticleVideo(b.id, ArticleMediaRef(ids.first, caption: ref.caption, credit: ref.credit))),
        );
      case ArticleAudio(media: final ref):
        return _MediaBody(
          block: b,
          refs: [ref],
          media: media,
          kind: ArticleMediaKind.sound,
          caption: field(b, 'caption', ref.caption, 'Caption (optional)', (v) => ArticleAudio(b.id, _withCaption(ref, v))),
          credit: field(b, 'credit', ref.credit, 'Credit (optional)', (v) => ArticleAudio(b.id, _withCredit(ref, v))),
          onChange: (ids) => _replace(ArticleAudio(b.id, ArticleMediaRef(ids.first, caption: ref.caption, credit: ref.credit))),
        );
      case ArticleGallery(:final items, :final caption):
        return _MediaBody(
          block: b,
          refs: items,
          media: media,
          kind: ArticleMediaKind.photo,
          multiple: true,
          caption: field(b, 'caption', caption, 'Caption of the gallery (optional)', (v) => ArticleGallery(b.id, items, caption: v)),
          onChange: (ids) {
            final old = {for (final r in items) r.mediaId: r};
            final next = [for (final id in ids) old[id] ?? ArticleMediaRef(id)];
            if (next.isEmpty) {
              _remove(b.id);
            } else {
              _replace(ArticleGallery(b.id, next, caption: caption));
            }
          },
        );
      case ArticleUnknownBlock():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.sm),
          child: Text('A block made by a newer NEFORUM. It is kept, but not sent until NEFORUM is updated.',
              style: t.bodySmall?.copyWith(color: nf.textMuted)),
        );
    }
  }

  static ArticleMediaRef _withCaption(ArticleMediaRef r, String? caption) =>
      ArticleMediaRef(r.mediaId, caption: caption, altText: r.altText, credit: r.credit);

  static ArticleMediaRef _withCredit(ArticleMediaRef r, String? credit) =>
      ArticleMediaRef(r.mediaId, caption: r.caption, altText: r.altText, credit: credit);
}

// --------------------------------------------------------------------------
// Pieces
// --------------------------------------------------------------------------

/// One block: its handle, its body and its menu.
class _BlockRow extends StatelessWidget {
  const _BlockRow({
    super.key,
    required this.index,
    required this.count,
    required this.block,
    required this.body,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
    required this.onAddBelow,
    required this.onTurnInto,
  });

  final int index;
  final int count;
  final ArticleBlock block;
  final Widget body;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onRemove;
  final void Function(_NewBlock kind) onAddBelow;
  final void Function(ArticleBlockType type, {bool ordered})? onTurnInto;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final name = articleBlockTypeName(block.type);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xxs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ReorderableDragStartListener(
          index: index,
          child: Tooltip(
            message: 'Drag to move this ${name.toLowerCase()}',
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Semantics(
                label: '$name ${index + 1} of $count. Drag to move.',
                child: SizedBox(
                  width: 28,
                  height: 40,
                  child: Icon(Icons.drag_indicator_rounded, size: 18, color: nf.textFaint),
                ),
              ),
            ),
          ),
        ),
        Expanded(child: body),
        PopupMenuButton<String>(
          key: ValueKey('article-block-menu-${block.id}'),
          tooltip: '$name options',
          icon: Icon(Icons.more_vert_rounded, size: 18, color: nf.textMuted),
          onSelected: (v) {
            switch (v) {
              case 'up':
                onMoveUp?.call();
              case 'down':
                onMoveDown?.call();
              case 'remove':
                onRemove();
              case 'numbered':
                onTurnInto?.call(ArticleBlockType.list, ordered: true);
              default:
                if (v.startsWith('add:')) {
                  onAddBelow(_NewBlock.values.byName(v.substring(4)));
                } else if (v.startsWith('into:')) {
                  onTurnInto?.call(ArticleBlockType.values.byName(v.substring(5)));
                }
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(value: 'up', enabled: onMoveUp != null, child: const _MenuRow(Icons.arrow_upward_rounded, 'Move up')),
            PopupMenuItem(value: 'down', enabled: onMoveDown != null, child: const _MenuRow(Icons.arrow_downward_rounded, 'Move down')),
            const PopupMenuDivider(),
            for (final k in _NewBlock.values) PopupMenuItem(value: 'add:${k.name}', child: _MenuRow(k.icon, 'Add ${k.label.toLowerCase()} below')),
            if (onTurnInto != null) ...[
              const PopupMenuDivider(),
              for (final type in articleTextTypes)
                if (type != block.type || type == ArticleBlockType.list)
                  PopupMenuItem(
                    value: type == ArticleBlockType.list && block is ArticleList && !(block as ArticleList).ordered ? 'numbered' : 'into:${type.name}',
                    child: _MenuRow(
                      articleBlockIcon(type),
                      type == ArticleBlockType.list && block is ArticleList
                          ? ((block as ArticleList).ordered ? 'Turn into a bulleted list' : 'Turn into a numbered list')
                          : 'Turn into ${articleBlockTypeName(type).toLowerCase()}',
                    ),
                  ),
            ],
            const PopupMenuDivider(),
            PopupMenuItem(value: 'remove', child: _MenuRow(Icons.delete_outline_rounded, 'Remove this ${name.toLowerCase()}', color: nf.danger)),
          ],
        ),
      ]),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label, {this.color});
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 18, color: color ?? context.nf.textMuted),
        const SizedBox(width: Space.md),
        Flexible(child: Text(label, style: color == null ? null : TextStyle(color: color))),
      ]);
}

/// H2, H3 or H4 for a heading.
class _LevelButton extends StatelessWidget {
  const _LevelButton({required this.level, required this.onChanged});
  final int level;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return PopupMenuButton<int>(
      tooltip: 'Heading level',
      initialValue: level,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final l in const [2, 3, 4])
          PopupMenuItem(value: l, child: Text(switch (l) { 2 => 'Heading', 3 => 'Subheading', _ => 'Small heading' })),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
        decoration: BoxDecoration(borderRadius: Radii.rXs, border: Border.all(color: nf.hairline)),
        child: Text('H$level', style: monoStyle(context, size: 12, color: nf.textMuted, weight: FontWeight.w600)),
      ),
    );
  }
}

/// Bold, italic, code and link for the block being edited, and "Add block".
class _FormatBar extends StatelessWidget {
  const _FormatBar({required this.onMark, required this.onLink, required this.onAdd});
  final void Function(String marker) onMark;
  final VoidCallback onLink;
  final Future<void> Function(_NewBlock kind) onAdd;

  @override
  Widget build(BuildContext context) {
    final mod = Env.isMacOS ? '⌘' : 'Ctrl+';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
      child: Row(children: [
        ToolButton(key: const ValueKey('article-bold'), icon: Icons.format_bold_rounded, tooltip: 'Bold (${mod}B)', onPressed: () => onMark('**'), size: 36),
        ToolButton(key: const ValueKey('article-italic'), icon: Icons.format_italic_rounded, tooltip: 'Italic (${mod}I)', onPressed: () => onMark('*'), size: 36),
        ToolButton(key: const ValueKey('article-code'), icon: Icons.code_rounded, tooltip: 'Code (${mod}E)', onPressed: () => onMark('`'), size: 36),
        ToolButton(key: const ValueKey('article-link'), icon: Icons.link_rounded, tooltip: 'Link (${mod}K)', onPressed: onLink, size: 36),
        const Spacer(),
        _AddBlockButton(onAdd: onAdd, compact: true),
      ]),
    );
  }
}

/// "Add block": the menu of every block type.
class _AddBlockButton extends StatelessWidget {
  const _AddBlockButton({required this.onAdd, this.compact = false});
  final Future<void> Function(_NewBlock kind) onAdd;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final k in _NewBlock.values)
          MenuItemButton(
            key: ValueKey('article-add-${k.name}${compact ? '-bar' : ''}'),
            leadingIcon: Icon(k.icon, size: 18),
            onPressed: () => onAdd(k),
            child: Text(k.label),
          ),
      ],
      builder: (context, controller, _) => compact
          ? ToolButton(
              key: const ValueKey('article-add-block-bar'),
              icon: Icons.add_box_outlined,
              tooltip: 'Add a block after this one',
              size: 36,
              onPressed: () => controller.isOpen ? controller.close() : controller.open(),
            )
          : OutlinedButton.icon(
              key: const ValueKey('article-add-block'),
              onPressed: () => controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add block'),
            ),
    );
  }
}

/// The file(s) of a photo, gallery, video or sound block, with its caption,
/// alt text (the file's own, for every network) and credit.
class _MediaBody extends ConsumerWidget {
  const _MediaBody({
    required this.block,
    required this.refs,
    required this.media,
    required this.kind,
    required this.caption,
    required this.onChange,
    this.credit,
    this.multiple = false,
  });

  final ArticleBlock block;
  final List<ArticleMediaRef> refs;
  final List<MediaAttachment> media;
  final ArticleMediaKind kind;
  final Widget caption;
  final Widget? credit;
  final bool multiple;
  final ValueChanged<List<String>> onChange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final files = [for (final r in refs) media.where((m) => m.id == r.mediaId).firstOrNull];
    final compact = context.isCompact;
    final size = compact ? 88.0 : 112.0;
    Future<void> change() async {
      final ids = await showArticleMediaChooser(context, kind: kind, multiple: multiple, selected: multiple ? [for (final r in refs) r.mediaId] : const []);
      if (ids != null && ids.isNotEmpty) onChange(ids);
    }

    final thumbs = Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
      for (final (i, m) in files.indexed)
        if (m == null)
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: nf.surfaceSunken, borderRadius: Radii.rMd),
            alignment: Alignment.center,
            child: Text('File removed', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
          )
        else
          Stack(clipBehavior: Clip.none, children: [
            MediaThumb(m, size: size, radius: Radii.rMd),
            if (multiple)
              Positioned(
                right: -6,
                top: -6,
                child: ToolButton(
                  key: ValueKey('article-gallery-remove-${block.id}-$i'),
                  icon: Icons.close_rounded,
                  tooltip: 'Take this photo out of the gallery',
                  size: 26,
                  onPressed: () => onChange([for (final r in refs) if (r.mediaId != m.id) r.mediaId]),
                ),
              ),
          ]),
      SizedBox(
        width: multiple ? size : null,
        height: multiple ? size : null,
        child: OutlinedButton.icon(
          key: ValueKey('article-media-change-${block.id}'),
          onPressed: change,
          icon: Icon(multiple ? Icons.add_rounded : Icons.swap_horiz_rounded, size: 18),
          label: Text(multiple ? 'Photos' : 'Change'),
        ),
      ),
    ]);

    final single = files.length == 1 ? files.first : null;
    final alt = single == null || kind == ArticleMediaKind.sound
        ? null
        : TextButton.icon(
            key: ValueKey('article-alt-${block.id}'),
            onPressed: () async {
              final text = await showAltTextDialog(context, single);
              if (text != null) ref.read(composerProvider.notifier).setAltText(single.id, text);
            },
            icon: Icon((single.altText ?? '').isEmpty ? Icons.add_rounded : Icons.check_rounded, size: 16),
            label: Text((single.altText ?? '').isEmpty ? 'Alt text' : 'Alt text: ${single.altText}', maxLines: 1, overflow: TextOverflow.ellipsis),
            style: TextButton.styleFrom(foregroundColor: (single.altText ?? '').isEmpty ? nf.warning : nf.textMuted),
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        thumbs,
        const SizedBox(height: Space.xs),
        caption,
        ?credit,
        if (alt != null) Align(alignment: Alignment.centerLeft, child: alt),
      ]),
    );
  }
}

/// The post's files under the article: which ones the article shows, and
/// which go to the social networks only. Remove, add.
class _ArticleFiles extends ConsumerWidget {
  const _ArticleFiles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final media = ref.watch(composerProvider.select((c) => c.media));
    final placed = ref.watch(composerProvider.select((c) => c.article?.mediaIds.toSet() ?? const <String>{}));
    final unplaced = media.where((m) => !placed.contains(m.id)).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text('Files in this post', style: context.text.titleSmall)),
        TextButton.icon(
          key: const ValueKey('article-files-add'),
          onPressed: () => pickAndAttachMedia(context, ref),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Add files'),
        ),
      ]),
      Text(
        media.isEmpty
            ? 'Photos, videos and sound files you add here can be placed anywhere in the article.'
            : unplaced == 0
                ? 'Every file is in the article. The social networks get them with the short version.'
                : '$unplaced ${unplaced == 1 ? 'file is' : 'files are'} not in the article: the blogs leave ${unplaced == 1 ? 'it' : 'them'} out, the social networks get ${unplaced == 1 ? 'it' : 'them'}.',
        style: context.text.bodySmall?.copyWith(color: nf.textMuted),
      ),
      if (media.isNotEmpty) ...[
        const SizedBox(height: Space.sm),
        Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          for (final m in media)
            Column(key: ValueKey('article-file-${m.id}'), mainAxisSize: MainAxisSize.min, children: [
              Stack(clipBehavior: Clip.none, children: [
                Opacity(opacity: placed.contains(m.id) ? 1 : 0.55, child: MediaThumb(m, size: 72, radius: Radii.rSm)),
                Positioned(
                  right: -6,
                  top: -6,
                  child: ToolButton(
                    icon: Icons.close_rounded,
                    tooltip: 'Remove ${m.fileName ?? 'this file'} from the post',
                    size: 24,
                    onPressed: () => ref.read(composerProvider.notifier).removeMedia(m.id),
                  ),
                ),
              ]),
              const SizedBox(height: Space.xxs),
              Text(placed.contains(m.id) ? 'In the article' : 'Social only', style: context.text.labelSmall?.copyWith(color: nf.textFaint)),
            ]),
        ]),
      ],
    ]);
  }
}

/// Asks for a link's address. Null when cancelled.
Future<String?> showArticleLinkDialog(BuildContext context) => showDialog<String>(context: context, builder: (_) => const _LinkDialog());

class _LinkDialog extends StatefulWidget {
  const _LinkDialog();

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _done() {
    var url = _c.text.trim();
    if (url.isEmpty) return;
    if (!url.contains('://') && !url.startsWith('mailto:')) url = 'https://$url';
    Navigator.pop(context, url);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Link'),
        content: SizedBox(
          width: 420,
          child: TextField(
            key: const ValueKey('article-link-url'),
            controller: _c,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Address', hintText: 'https://'),
            onSubmitted: (_) => _done(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('article-link-done'), onPressed: _done, child: const Text('Add link')),
        ],
      );
}
