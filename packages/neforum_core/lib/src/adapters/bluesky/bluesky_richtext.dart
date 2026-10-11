import 'dart:convert';

import 'package:characters/characters.dart';

import '../../text/url_detector.dart';

/// Kind of rich-text span Bluesky understands.
enum BlueskySpanKind { link, mention, tag }

/// A link, @mention or #tag found in post text. [start]/[end] are UTF-16
/// indices (Dart string positions); [value] is the URL, the handle (without
/// `@`, lower-cased) or the tag (without `#`).
class BlueskySpan {
  const BlueskySpan(this.kind, this.start, this.end, this.value);
  final BlueskySpanKind kind;
  final int start;
  final int end;
  final String value;

  @override
  String toString() => '${kind.name}($start-$end: $value)';
}

/// Detects links, mentions and hashtags the way the official Bluesky client
/// does, and turns them into `app.bsky.richtext.facet` objects whose
/// `byteStart`/`byteEnd` are UTF-8 byte offsets (as the lexicon requires).
class BlueskyRichText {
  BlueskyRichText._();

  static final RegExp _mention = RegExp(r'(^|[\s(])@([a-zA-Z0-9.-]+)');
  static final RegExp _handle =
      RegExp(r'^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$');

  // Same shape as @atproto/api's tag detection: a tag must contain at least
  // one character that is not a digit, whitespace or punctuation.
  static final RegExp _tag = RegExp(
    r'(^|\s)[#＃]((?!️)[^\s­⁠ ​‌‍⃢]*[^\d\s\p{P}­⁠ ​‌‍⃢]+[^\s­⁠ ​‌‍⃢]*)?',
    unicode: true,
  );
  static final RegExp _trailingPunct = RegExp(r'\p{P}+$', unicode: true);

  /// Maximum tag length from the facet lexicon.
  static const int maxTagGraphemes = 64;
  static const int maxTagBytes = 640;

  /// All spans in [text], sorted by position, never overlapping.
  static List<BlueskySpan> detect(String text) {
    final spans = <BlueskySpan>[
      for (final u in UrlDetector.find(text)) BlueskySpan(BlueskySpanKind.link, u.start, u.end, u.normalized),
    ];
    bool free(int s, int e) => !spans.any((x) => s < x.end && e > x.start);

    for (final m in _mention.allMatches(text)) {
      var handle = m.group(2)!;
      handle = handle.replaceFirst(RegExp(r'[.-]+$'), '');
      if (!handle.contains('.') || !_handle.hasMatch(handle)) continue;
      final start = m.start + m.group(1)!.length;
      final end = start + 1 + handle.length;
      if (free(start, end)) spans.add(BlueskySpan(BlueskySpanKind.mention, start, end, handle.toLowerCase()));
    }

    for (final m in _tag.allMatches(text)) {
      final raw = m.group(2);
      if (raw == null) continue;
      final tag = raw.trim().replaceFirst(_trailingPunct, '');
      if (tag.isEmpty || tag.characters.length > maxTagGraphemes || utf8.encode(tag).length > maxTagBytes) continue;
      final start = m.start + m.group(1)!.length;
      final end = start + 1 + tag.length;
      if (free(start, end)) spans.add(BlueskySpan(BlueskySpanKind.tag, start, end, tag));
    }
    spans.sort((a, b) => a.start.compareTo(b.start));
    return spans;
  }

  /// Handles mentioned in [text] (lower-cased, without `@`).
  static Set<String> mentionedHandles(String text) =>
      detect(text).where((s) => s.kind == BlueskySpanKind.mention).map((s) => s.value).toSet();

  /// Hashtags that are too long to become a tag facet (for validation).
  static List<String> overlongTags(String text) => [
        for (final m in _tag.allMatches(text))
          if (m.group(2) case final raw?)
            if (raw.trim().replaceFirst(_trailingPunct, '').characters.length > maxTagGraphemes) raw,
      ];

  /// Builds the `facets` array for [text]. Mentions whose handle is not in
  /// [didsByHandle] are left as plain text.
  static List<Map<String, dynamic>> facets(String text, {Map<String, String> didsByHandle = const {}}) {
    final out = <Map<String, dynamic>>[];
    for (final s in detect(text)) {
      final Map<String, dynamic> feature;
      switch (s.kind) {
        case BlueskySpanKind.link:
          feature = {r'$type': 'app.bsky.richtext.facet#link', 'uri': s.value};
        case BlueskySpanKind.mention:
          final did = didsByHandle[s.value];
          if (did == null) continue;
          feature = {r'$type': 'app.bsky.richtext.facet#mention', 'did': did};
        case BlueskySpanKind.tag:
          feature = {r'$type': 'app.bsky.richtext.facet#tag', 'tag': s.value};
      }
      out.add({
        'index': {'byteStart': byteOffset(text, s.start), 'byteEnd': byteOffset(text, s.end)},
        'features': [feature],
      });
    }
    return out;
  }

  /// UTF-8 byte offset of the UTF-16 index [utf16Index] in [text].
  static int byteOffset(String text, int utf16Index) => utf8.encode(text.substring(0, utf16Index)).length;
}
