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

  /// A link ends at a space, a delimiter or a text direction mark: an address
  /// never holds one, and right-to-left writers often have them around links.
  static final RegExp _scheme = RegExp(
    r'''(?<![\w@/])(https?://[^\s<>"'`‎‏‪-‮⁦-⁩]+)''',
    caseSensitive: false,
  );

  /// Longest part of a host name between dots (RFC 1035), in its ASCII form.
  static const int _maxLabel = 63;

  /// Whether every part of the host in the link [url] fits the limit a real
  /// host name has, measuring non-ASCII parts in their `xn--` form. Past it the
  /// text is not an address anywhere, so it counts and shows as plain words.
  static bool _hostFits(String url) {
    var host = url.substring(url.indexOf('://') + 3);
    final end = host.indexOf(RegExp(r'[/?#]'));
    if (end >= 0) host = host.substring(0, end);
    host = host.substring(host.lastIndexOf('@') + 1);
    final port = host.lastIndexOf(':');
    if (port >= 0) host = host.substring(0, port);
    return host.split('.').every((label) => _asciiLength(label) <= _maxLabel);
  }

  static int _asciiLength(String label) {
    final ascii = label.runes.every((r) => r < 0x80);
    return ascii ? label.length : 4 + punycodeLength(label.toLowerCase());
  }

  /// Length of the Punycode form (RFC 3492) of [input], without `xn--`.
  @visibleForTesting
  static int punycodeLength(String input) {
    const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
    final runes = input.runes.toList();
    final basic = runes.where((r) => r < 0x80).length;
    var out = basic == 0 ? 0 : basic + 1;
    var n = 128, delta = 0, bias = 72, handled = basic;

    int adapt(int d, int points, bool first) {
      var x = first ? d ~/ damp : d ~/ 2;
      x += x ~/ points;
      var k = 0;
      while (x > ((base - tMin) * tMax) ~/ 2) {
        x ~/= base - tMin;
        k += base;
      }
      return k + ((base - tMin + 1) * x) ~/ (x + skew);
    }

    while (handled < runes.length) {
      final next = runes.where((r) => r >= n).reduce((a, b) => a < b ? a : b);
      delta += (next - n) * (handled + 1);
      n = next;
      for (final r in runes) {
        if (r < n) delta++;
        if (r != n) continue;
        var q = delta;
        for (var k = base;; k += base) {
          final t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias);
          if (q < t) break;
          out++;
          q = (q - t) ~/ (base - t);
        }
        out++;
        bias = adapt(delta, handled + 1, handled == basic);
        delta = 0;
        handled++;
      }
      delta++;
      n++;
    }
    return out;
  }

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
      final url = text.substring(trimmed.$1, trimmed.$2);
      if (_hostFits(url)) out.add(UrlMatch(start: trimmed.$1, end: trimmed.$2, text: url, hasScheme: true));
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
