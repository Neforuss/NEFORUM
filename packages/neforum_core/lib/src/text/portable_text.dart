import 'url_detector.dart';

/// Markdown to Portable Text, in the shape EmDash stores and renders
/// (`emdash/src/content/converters/types.ts`, EmDash 1.5).
///
/// Deterministic: the same text and [keyPrefix] always give the same blocks,
/// keys included. Every `_key` starts with [keyPrefix], so a caller can mark a
/// post with it and find that post again.
///
/// What is understood, block by block:
/// * blank lines separate blocks; a single newline is a line break inside the
///   block (`\n` in the span text, which EmDash renders as `<br>`);
/// * `#` to `######` headings (`h1`..`h6`);
/// * `>` quotes (`blockquote`), one block per paragraph of the quote;
/// * `-`, `*`, `+` and `1.` / `1)` list items, nested by indentation, with the
///   first number kept (`listId` and `listStart`);
/// * fenced code (three or more backticks or tildes) as `code` blocks;
/// * `---`, `***` and `___` as a `break` block;
/// * a line that is only `![alt](https://...)` as an `image` block.
///
/// Inside a block: `**strong**`, `__strong__`, `*em*`, `_em_`,
/// `~~strike~~`, `` `code` ``, `[text](url)`, `<https://...>`, bare
/// `https://` addresses and backslash escapes. Links become `link` mark
/// definitions; only http, https, mailto and site-relative (`/...`) targets
/// are linked, anything else stays plain text.
///
/// HTML is never interpreted: `<b>` stays the five characters it is, and
/// EmDash shows them as text. Indented code (four spaces) and setext
/// headings are not Markdown here: social posts indent and underline text
/// for other reasons.
List<Map<String, Object?>> markdownToPortableText(String markdown, {String keyPrefix = 'k'}) =>
    _BlockParser(keyPrefix).parse(markdown);

/// Plain text of Portable Text blocks: one line per text block, code as it
/// is. For checks and previews.
String portableTextPlainText(List<Map<String, Object?>> blocks) {
  final out = <String>[];
  for (final b in blocks) {
    if (b['_type'] == 'block') {
      out.add([for (final c in (b['children'] as List? ?? const [])) (c as Map)['text']].join());
    } else if (b['_type'] == 'code') {
      out.add('${b['code']}');
    }
  }
  return out.join('\n');
}

// ----------------------------------------------------------------- blocks

final RegExp _fenceOpen = RegExp(r'^ {0,3}(`{3,}|~{3,})\s*([^`\s]*)[^`]*$');
final RegExp _heading = RegExp(r'^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$');
final RegExp _thematicBreak = RegExp(r'^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$');
final RegExp _quote = RegExp(r'^ {0,3}>[ ]?(.*)$');
final RegExp _listItem = RegExp(r'^([ \t]*)([-*+]|(\d{1,9})[.)])(?:[ \t]+(.*)|$)');
final RegExp _imageLine = RegExp(r'''^ {0,3}!\[([^\]]*)\]\(\s*<?((?:https?://|/)[^\s>)]+)>?(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)\s*$''');
final RegExp _languageChars = RegExp(r'[^A-Za-z0-9_+#.-]');

/// One open list: where its markers sit, bullet or number, and for a
/// numbered list its id and first number.
class _ListFrame {
  _ListFrame(this.indent, this.kind, this.id, this.start);
  final int indent;
  final String kind;
  final String? id;
  final int start;
}

class _BlockParser {
  _BlockParser(this.prefix);

  final String prefix;
  final List<Map<String, Object?>> _out = [];
  int _blockCount = 0;
  int _listCount = 0;

  String _nextKey() => '$prefix${_blockCount++}';

  List<Map<String, Object?>> parse(String markdown) {
    final lines = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final paragraph = <String>[];
    final lists = <_ListFrame>[];
    // The open list item: its text lines and where it sits.
    List<String>? itemLines;
    var itemLevel = 1;
    var itemKind = 'bullet';
    String? itemListId;
    int? itemStart;

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      _textBlock(paragraph.join('\n'), style: 'normal');
      paragraph.clear();
    }

    void flushItem() {
      final lines = itemLines;
      if (lines == null) return;
      _textBlock(lines.join('\n'), style: 'normal', listItem: itemKind, level: itemLevel, listId: itemListId, listStart: itemStart);
      itemLines = null;
    }

    void endLists() {
      flushItem();
      lists.clear();
    }

    var i = 0;
    while (i < lines.length) {
      final line = lines[i].trimRight();

      final fence = _fenceOpen.firstMatch(line);
      if (fence != null) {
        flushParagraph();
        endLists();
        final marker = fence.group(1)!;
        final code = <String>[];
        i++;
        while (i < lines.length) {
          final l = lines[i];
          final t = l.trim();
          if (t.length >= marker.length && t.startsWith(marker[0] * marker.length) && t.replaceAll(marker[0], '').isEmpty) {
            i++;
            break;
          }
          code.add(l);
          i++;
        }
        final language = fence.group(2)!.replaceAll(_languageChars, '');
        _out.add({
          '_type': 'code',
          '_key': _nextKey(),
          'code': code.join('\n'),
          if (language.isNotEmpty) 'language': language,
        });
        continue;
      }

      if (line.trim().isEmpty) {
        flushParagraph();
        // A blank line inside a list ends the item; an indented line after it
        // still belongs to the list, anything else ends it.
        if (itemLines != null || lists.isNotEmpty) {
          flushItem();
          var j = i + 1;
          while (j < lines.length && lines[j].trim().isEmpty) {
            j++;
          }
          if (j >= lines.length || (!_listItem.hasMatch(lines[j]) && _indentOf(lines[j]) == 0)) lists.clear();
        }
        i++;
        continue;
      }

      final item = _listItem.firstMatch(line);
      final number = item?.group(3) == null ? null : int.tryParse(item!.group(3)!);
      // Inside a paragraph only a bullet or a list that starts at 1 begins a
      // list: "born in\n1984. It was" stays one paragraph.
      final interrupts = paragraph.isEmpty || number == null || number == 1;
      if (item != null && interrupts && !_thematicBreak.hasMatch(line)) {
        flushParagraph();
        flushItem();
        final indent = _indentOf(item.group(1)!);
        final kind = number == null ? 'bullet' : 'number';
        while (lists.isNotEmpty && lists.last.indent > indent) {
          lists.removeLast();
        }
        // Another kind of marker at the same depth starts a new list.
        if (lists.isNotEmpty && lists.last.indent == indent && lists.last.kind != kind) lists.removeLast();
        if (lists.isEmpty || lists.last.indent < indent) {
          final id = kind == 'number' ? '${prefix}l${_listCount++}' : null;
          lists.add(_ListFrame(indent, kind, id, number ?? 1));
        }
        final frame = lists.last;
        itemLevel = lists.length;
        itemKind = frame.kind;
        itemListId = frame.id;
        itemStart = frame.id == null ? null : frame.start;
        itemLines = [item.group(4) ?? ''];
        i++;
        continue;
      }

      if (_thematicBreak.hasMatch(line)) {
        flushParagraph();
        endLists();
        _out.add({'_type': 'break', '_key': _nextKey(), 'style': 'lineBreak'});
        i++;
        continue;
      }

      final heading = _heading.firstMatch(line);
      if (heading != null) {
        flushParagraph();
        endLists();
        _textBlock((heading.group(2) ?? '').trim(), style: 'h${heading.group(1)!.length}');
        i++;
        continue;
      }

      if (_quote.hasMatch(line)) {
        flushParagraph();
        endLists();
        final quoted = <String>[];
        while (i < lines.length) {
          final m = _quote.firstMatch(lines[i].trimRight());
          if (m == null) break;
          quoted.add(m.group(1)!);
          i++;
        }
        for (final part in quoted.join('\n').split(RegExp(r'\n[ \t]*\n+'))) {
          _textBlock(part.trim(), style: 'blockquote');
        }
        continue;
      }

      final image = _imageLine.firstMatch(line);
      if (image != null) {
        flushParagraph();
        endLists();
        final url = image.group(2)!;
        final alt = image.group(1)!.trim();
        _out.add({
          '_type': 'image',
          '_key': _nextKey(),
          'asset': {'_ref': url, 'url': url},
          if (alt.isNotEmpty) 'alt': alt,
        });
        i++;
        continue;
      }

      // Text: the next line of an open list item, or of a paragraph.
      final open = itemLines;
      if (open != null) {
        open.add(line.trimLeft());
      } else {
        if (lists.isNotEmpty) lists.clear();
        paragraph.add(line.trimLeft());
      }
      i++;
    }
    flushParagraph();
    endLists();
    return _out;
  }

  void _textBlock(String text, {required String style, String? listItem, int? level, String? listId, int? listStart}) {
    final key = _nextKey();
    final inline = _InlineParser(key).parse(text);
    if (inline.children.isEmpty && listItem == null) {
      _blockCount--;
      return;
    }
    _out.add({
      '_type': 'block',
      '_key': key,
      'style': style,
      if (listItem != null) 'listItem': listItem,
      if (listItem != null) 'level': level ?? 1,
      'listId': ?listId,
      if (listId != null && listStart != null) 'listStart': listStart,
      'markDefs': inline.markDefs,
      'children': inline.children.isEmpty ? [_span('${key}s0', '', const [])] : inline.children,
    });
  }
}

int _indentOf(String s) {
  var n = 0;
  for (final c in s.codeUnits) {
    if (c == 0x20) {
      n++;
    } else if (c == 0x09) {
      n += 4;
    } else {
      break;
    }
  }
  return n;
}

Map<String, Object?> _span(String key, String text, List<String> marks) => {'_type': 'span', '_key': key, 'text': text, 'marks': marks};

// ----------------------------------------------------------------- inline

class _Inline {
  _Inline(this.children, this.markDefs);
  final List<Map<String, Object?>> children;
  final List<Map<String, Object?>> markDefs;
}

class _Segment {
  _Segment(this.text, this.marks);
  String text;
  final List<String> marks;
}

final RegExp _punctuation = RegExp(r'[\p{P}\p{S}]', unicode: true);
final RegExp _whitespace = RegExp(r'\s');
final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
const String _escapable = r'!"#$%&' "'" r'()*+,-./:;<=>?@[\]^_`{|}~';

class _InlineParser {
  _InlineParser(this.blockKey);

  final String blockKey;
  final List<Map<String, Object?>> _markDefs = [];
  final Map<String, String> _linkKeys = {};

  _Inline parse(String text) {
    final segments = <_Segment>[];
    _parse(text, const [], false, segments);
    // Adjacent pieces with the same marks are one span.
    final merged = <_Segment>[];
    for (final s in segments) {
      if (s.text.isEmpty) continue;
      if (merged.isNotEmpty && _sameMarks(merged.last.marks, s.marks)) {
        merged.last.text += s.text;
      } else {
        merged.add(_Segment(s.text, s.marks));
      }
    }
    return _Inline([for (var j = 0; j < merged.length; j++) _span('${blockKey}s$j', merged[j].text, merged[j].marks)], _markDefs);
  }

  static bool _sameMarks(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String _linkKey(String href) => _linkKeys.putIfAbsent(href, () {
        final key = '${blockKey}m${_markDefs.length}';
        _markDefs.add({'_type': 'link', '_key': key, 'href': href});
        return key;
      });

  void _parse(String s, List<String> marks, bool inLink, List<_Segment> out) {
    final urls = inLink ? const <UrlMatch>[] : UrlDetector.find(s).where((u) => u.hasScheme).toList();
    var urlIndex = 0;
    final buf = StringBuffer();
    void flush() {
      if (buf.isEmpty) return;
      out.add(_Segment(buf.toString(), marks));
      buf.clear();
    }

    var i = 0;
    while (i < s.length) {
      while (urlIndex < urls.length && urls[urlIndex].start < i) {
        urlIndex++;
      }
      final c = s[i];

      // Backslash escapes, and a backslash before a line break.
      if (c == r'\' && i + 1 < s.length) {
        final next = s[i + 1];
        if (_escapable.contains(next) || next == '\n') {
          buf.write(next);
          i += 2;
          continue;
        }
      }

      if (c == '`') {
        final run = _runLength(s, i, '`');
        final close = _findBacktickClose(s, i + run, run);
        if (close >= 0) {
          flush();
          var code = s.substring(i + run, close).replaceAll('\n', ' ');
          if (code.length > 2 && code.startsWith(' ') && code.endsWith(' ') && code.trim().isNotEmpty) {
            code = code.substring(1, code.length - 1);
          }
          out.add(_Segment(code, [...marks, 'code']));
          i = close + run;
        } else {
          buf.write(s.substring(i, i + run));
          i += run;
        }
        continue;
      }

      if (urlIndex < urls.length && urls[urlIndex].start == i) {
        final u = urls[urlIndex];
        flush();
        out.add(_Segment(u.text, [...marks, _linkKey(u.text)]));
        i = u.end;
        continue;
      }

      if (c == '<' && !inLink) {
        final m = RegExp(r'<((?:https?://|mailto:)[^\s<>]+)>').matchAsPrefix(s, i);
        if (m != null) {
          flush();
          final href = m.group(1)!;
          out.add(_Segment(href, [...marks, _linkKey(href)]));
          i = m.end;
          continue;
        }
      }

      if (c == '[' || (c == '!' && i + 1 < s.length && s[i + 1] == '[')) {
        final open = c == '!' ? i + 1 : i;
        final link = _parseLink(s, open);
        if (link != null) {
          flush();
          final (label, href, end) = link;
          final safe = _safeHref(href);
          if (safe == null || inLink) {
            _parse(label, marks, inLink, out);
          } else {
            _parse(label.isEmpty ? href : label, [...marks, _linkKey(safe)], true, out);
          }
          i = end;
          continue;
        }
      }

      if (c == '*' || c == '_' || c == '~') {
        final run = _runLength(s, i, c);
        final end = i + run;
        final needed = c == '~' ? 2 : (run >= 2 ? 2 : 1);
        if ((c != '~' || run == 2) && _canOpen(s, i, end, c)) {
          final close = _findCloser(s, i + needed, c, needed);
          if (close >= 0) {
            flush();
            final mark = c == '~' ? 'strike-through' : (needed == 2 ? 'strong' : 'em');
            _parse(s.substring(i + needed, close), marks.contains(mark) ? marks : [...marks, mark], inLink, out);
            i = close + needed;
            continue;
          }
        }
        // Not emphasis here: one character is text, the rest of the run
        // gets its own chance (`**a*` is `*` then emphasis).
        buf.write(c);
        i++;
        continue;
      }

      buf.write(c);
      i++;
    }
    flush();
  }

  /// The end of the matching emphasis run for an opener of [len] [ch]
  /// characters, as the index of its first closing character; -1 when there
  /// is none. Nested openers of the same character are skipped whole.
  int _findCloser(String s, int from, String ch, int len) {
    var j = from;
    while (j < s.length) {
      final c = s[j];
      if (c == r'\' && j + 1 < s.length) {
        j += 2;
        continue;
      }
      if (c == '`') {
        final run = _runLength(s, j, '`');
        final close = _findBacktickClose(s, j + run, run);
        j = close >= 0 ? close + run : j + run;
        continue;
      }
      if (c == '[') {
        final link = _parseLink(s, j);
        if (link != null) {
          j = link.$3;
          continue;
        }
      }
      if (c == ch) {
        final run = _runLength(s, j, ch);
        final end = j + run;
        if (run >= len && _canClose(s, j, end, ch) && j > from) return j;
        if (_canOpen(s, j, end, ch)) {
          final nested = _findCloser(s, end, ch, ch == '~' ? 2 : (run >= 2 ? 2 : 1));
          if (nested >= 0) {
            j = nested + (ch == '~' ? 2 : (run >= 2 ? 2 : 1));
            continue;
          }
        }
        j = end;
        continue;
      }
      j++;
    }
    return -1;
  }

  static int _runLength(String s, int i, String ch) {
    var j = i;
    while (j < s.length && s[j] == ch) {
      j++;
    }
    return j - i;
  }

  static int _findBacktickClose(String s, int from, int run) {
    var j = from;
    while (j < s.length) {
      if (s[j] == '`') {
        final r = _runLength(s, j, '`');
        if (r == run) return j;
        j += r;
      } else {
        j++;
      }
    }
    return -1;
  }

  static bool _isSpace(String? c) => c == null || _whitespace.hasMatch(c);
  static bool _isPunct(String? c) => c != null && _punctuation.hasMatch(c);

  static bool _leftFlanking(String s, int start, int end) {
    final before = start > 0 ? s[start - 1] : null;
    final after = end < s.length ? s[end] : null;
    if (_isSpace(after)) return false;
    return !_isPunct(after) || _isSpace(before) || _isPunct(before);
  }

  static bool _rightFlanking(String s, int start, int end) {
    final before = start > 0 ? s[start - 1] : null;
    final after = end < s.length ? s[end] : null;
    if (_isSpace(before)) return false;
    return !_isPunct(before) || _isSpace(after) || _isPunct(after);
  }

  static bool _canOpen(String s, int start, int end, String ch) {
    if (!_leftFlanking(s, start, end)) return false;
    if (ch != '_') return true;
    // snake_case: an underscore inside a word opens nothing.
    final before = start > 0 ? s[start - 1] : null;
    return before == null || !_wordChar.hasMatch(before);
  }

  static bool _canClose(String s, int start, int end, String ch) {
    if (!_rightFlanking(s, start, end)) return false;
    if (ch != '_') return true;
    final after = end < s.length ? s[end] : null;
    return after == null || !_wordChar.hasMatch(after);
  }

  /// `[label](href "title")` starting at [open] (the `[`): the label, the
  /// address and the index after the `)`, or null when it is not a link.
  static (String, String, int)? _parseLink(String s, int open) {
    if (open >= s.length || s[open] != '[') return null;
    var depth = 0;
    var j = open;
    var close = -1;
    while (j < s.length) {
      final c = s[j];
      if (c == r'\' && j + 1 < s.length) {
        j += 2;
        continue;
      }
      if (c == '`') {
        final run = _runLength(s, j, '`');
        final end = _findBacktickClose(s, j + run, run);
        j = end >= 0 ? end + run : j + run;
        continue;
      }
      if (c == '[') depth++;
      if (c == ']') {
        depth--;
        if (depth == 0) {
          close = j;
          break;
        }
      }
      j++;
    }
    if (close < 0 || close + 1 >= s.length || s[close + 1] != '(') return null;
    var k = close + 2;
    while (k < s.length && (s[k] == ' ' || s[k] == '\t')) {
      k++;
    }
    final String href;
    if (k < s.length && s[k] == '<') {
      final end = s.indexOf('>', k);
      if (end < 0 || s.substring(k + 1, end).contains('\n')) return null;
      href = s.substring(k + 1, end);
      k = end + 1;
    } else {
      final start = k;
      var parens = 0;
      while (k < s.length) {
        final c = s[k];
        if (_isSpace(c)) break;
        if (c == '(') parens++;
        if (c == ')') {
          if (parens == 0) break;
          parens--;
        }
        k++;
      }
      href = s.substring(start, k);
    }
    while (k < s.length && (s[k] == ' ' || s[k] == '\t')) {
      k++;
    }
    if (k < s.length && (s[k] == '"' || s[k] == "'" || s[k] == '(')) {
      final quote = s[k] == '(' ? ')' : s[k];
      final end = s.indexOf(quote, k + 1);
      if (end < 0) return null;
      k = end + 1;
      while (k < s.length && (s[k] == ' ' || s[k] == '\t')) {
        k++;
      }
    }
    if (k >= s.length || s[k] != ')') return null;
    return (s.substring(open + 1, close), href, k + 1);
  }

  /// [href] when it is safe to link (http, https, mailto or a path on the
  /// same site), otherwise null.
  static String? _safeHref(String href) {
    final h = href.trim();
    if (h.isEmpty) return null;
    if (h.startsWith('/') && !h.startsWith('//')) return h;
    final u = Uri.tryParse(h);
    if (u == null) return null;
    final scheme = u.scheme.toLowerCase();
    if ((scheme == 'http' || scheme == 'https') && u.host.isNotEmpty) return h;
    if (scheme == 'mailto' && u.path.contains('@')) return h;
    return null;
  }
}
