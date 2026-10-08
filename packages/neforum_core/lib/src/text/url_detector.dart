import 'package:meta/meta.dart';

/// A URL found in post text. Offsets are UTF-16 code-unit indices into the
/// original string (what Dart's `String` uses).
@immutable
class UrlMatch {
  const UrlMatch({required this.start, required this.end, required this.text, required this.hasScheme});

  final int start;
  final int end;
  final String text;
  final bool hasScheme;

  /// The URL with a scheme, suitable for links/facets.
  String get normalized => hasScheme ? text : 'https://$text';

  int get length => end - start;
}

/// Finds URLs the way platforms do: explicit `http(s)://` links, `www.`
/// links, and bare domains with a common TLD (`example.com/path`), which X,
/// Bluesky and Mastodon all auto-link and count as links.
class UrlDetector {
  UrlDetector._();

  static const _tlds = [
    'com', 'org', 'net', 'edu', 'gov', 'mil', 'int', 'io', 'co', 'ai', 'app', 'dev', 'me',
    'info', 'biz', 'xyz', 'tv', 'fm', 'gg', 'social', 'blog', 'news', 'art', 'design', 'page', 'site',
    'online', 'store', 'shop', 'tech', 'cloud', 'live', 'video', 'studio', 'world', 'zone', 'club',
    'us', 'uk', 'ca', 'au', 'nz', 'de', 'fr', 'es', 'it', 'nl', 'be', 'ch', 'at', 'se', 'no', 'dk',
    'fi', 'pl', 'cz', 'ie', 'pt', 'br', 'mx', 'ar', 'cl', 'jp', 'kr', 'cn', 'tw', 'hk', 'sg', 'in',
    'id', 'ph', 'th', 'vn', 'my', 'ru', 'ua', 'tr', 'il', 'za', 'ng', 'ke', 'eg', 'eu', 'asia',
    'ly', 'to', 'sh', 'is', 'be', 'cc', 'ws', 'st', 'link', 'click', 'lol', 'wtf', 'fyi', 'pub',
    'bsky', 'moe', 'cafe', 'space', 'network', 'systems', 'tools', 'codes', 'run', 'town', 'city',
    'one', 'two', 'red', 'blue', 'pink', 'black', 'rocks', 'wiki', 'science', 'pro', 'name', 'mobi',
  ];

  static final RegExp _scheme = RegExp(
    r'''(?<![\w@/])(https?://[^\s<>"'`]+)''',
    caseSensitive: false,
  );

  static final RegExp _bare = RegExp(
    r'''(?<![\w@./-])((?:www\.)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:'''
    '${_tlds.join('|')}'
    r''')(?::\d{2,5})?(?:/[^\s<>"'`]*)?)(?![\w.-]*@)''',
    caseSensitive: false,
  );

  static const _trailingPunct = {')', '.', ',', ';', ':', '!', '?', '"', "'", ']', '}', '>', '*', '_'};

  static List<UrlMatch> find(String text) {
    final out = <UrlMatch>[];
    for (final m in _scheme.allMatches(text)) {
      final trimmed = _trim(text, m.start, m.end);
      out.add(UrlMatch(start: trimmed.$1, end: trimmed.$2, text: text.substring(trimmed.$1, trimmed.$2), hasScheme: true));
    }
    for (final m in _bare.allMatches(text)) {
      if (out.any((u) => m.start < u.end && m.end > u.start)) continue; // overlaps a scheme URL
      final trimmed = _trim(text, m.start, m.end);
      final s = text.substring(trimmed.$1, trimmed.$2);
      // Reject things like "e.g" / version numbers that slipped through.
      if (!s.contains('.') || RegExp(r'^\d+(\.\d+)+$').hasMatch(s)) continue;
      out.add(UrlMatch(start: trimmed.$1, end: trimmed.$2, text: s, hasScheme: false));
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  /// Strips trailing punctuation and unbalanced closing parens, as linkifiers do.
  static (int, int) _trim(String text, int start, int end) {
    var e = end;
    while (e > start) {
      final ch = text[e - 1];
      if (!_trailingPunct.contains(ch)) break;
      if (ch == ')') {
        final seg = text.substring(start, e);
        final opens = ')'.allMatches(seg).length;
        final closes = '('.allMatches(seg).length;
        if (closes >= opens) break; // balanced, keep it (wikipedia-style links)
      }
      e--;
    }
    return (start, e);
  }
}
