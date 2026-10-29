import '../model/audio_tags.dart';

/// The post text NEFORUM writes from a track's details unless the user
/// changed it: "Artist – Title (Album, 2024)", where the bracket and each
/// missing detail drop out.
const String kDefaultAudioTextTemplate = '{artist} – {title} ({album}, {year})';

/// The tokens an audio text template understands, in the order the editor
/// offers them.
const List<String> audioTextTokens = ['title', 'artist', 'album', 'albumArtist', 'year', 'genre', 'track'];

/// [template] with every `{token}` ([audioTextTokens]) replaced by the
/// detail from [tags]. Details the track does not have drop out cleanly:
///
/// * the text between two details belongs to the second one, so
///   "{artist} – {title}" is just the title when there is no artist; text
///   before a line break ends the first one's line instead, and every line
///   keeps its own text;
/// * text before the first detail and after the last stays only while some
///   detail is left;
/// * a bracketed part, "( … )" or "[ … ]", drops out with its brackets (and
///   the space before them) when it has no detail left: "{title} ({album},
///   {year})" is "Title (2024)" without an album and "Title" without both.
///
/// Unknown `{words}` stay as written. The result is trimmed.
String renderAudioText(String template, AudioTags tags) {
  final nodes = _Parser(template).parse();
  return (_render(nodes, tags) ?? '').trim();
}

/// The value of one token, or null when the track does not have it.
String? audioTextTokenValue(String token, AudioTags tags) {
  String? s(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
  return switch (token) {
    'title' => s(tags.title),
    'artist' => s(tags.artist),
    'album' => s(tags.album),
    'albumArtist' => s(tags.albumArtist),
    'year' => (tags.year ?? int.tryParse(tags.date?.split('-').first ?? ''))?.toString(),
    'genre' => s(tags.genre),
    'track' => tags.trackNumber?.toString(),
    _ => null,
  };
}

sealed class _Node {
  const _Node();
}

class _Literal extends _Node {
  const _Literal(this.text);
  final String text;
}

class _Token extends _Node {
  const _Token(this.name);
  final String name;
}

class _Group extends _Node {
  const _Group(this.open, this.children, this.close);
  final String open;
  final List<_Node> children;
  final String close;
}

/// Renders a sequence; null when it has details and none of them is set.
/// A sequence without details renders as its text.
String? _render(List<_Node> nodes, AudioTags tags) {
  final slots = <int>[];
  final values = <int, String>{};
  for (var i = 0; i < nodes.length; i++) {
    final n = nodes[i];
    if (n is _Literal) continue;
    slots.add(i);
    final v = switch (n) {
      _Token(:final name) => audioTextTokenValue(name, tags),
      _Group(:final open, :final children, :final close) => switch (_render(children, tags)) { final inner? => '$open$inner$close', null => null },
      _Literal() => null,
    };
    if (v != null && v.isNotEmpty) values[i] = v;
  }
  String literals(int from, int to) => [for (var i = from; i < to; i++) if (nodes[i] case _Literal(:final text)) text].join();
  if (slots.isEmpty) return literals(0, nodes.length);
  if (values.isEmpty) return null;
  final out = StringBuffer(literals(0, slots.first));
  var first = true;
  for (var k = 0; k < slots.length; k++) {
    final i = slots[k];
    final v = values[i];
    if (v == null) continue;
    // The text between two details belongs to the second one, except what
    // stands before a line break: that ends the first one's line.
    if (k > 0) {
      final gap = literals(slots[k - 1] + 1, i);
      final lineBreak = gap.indexOf('\n');
      if (!first) {
        out.write(lineBreak < 0 ? gap : gap.substring(lineBreak));
      } else if (lineBreak >= 0) {
        // The first detail left on a later line keeps that line's own text.
        out.write(gap.substring(lineBreak + 1));
      }
    }
    out.write(v);
    if (k < slots.length - 1) {
      final gap = literals(i + 1, slots[k + 1]);
      final lineBreak = gap.indexOf('\n');
      if (lineBreak > 0) out.write(gap.substring(0, lineBreak));
    }
    first = false;
  }
  out.write(literals(slots.last + 1, nodes.length));
  return out.toString();
}

class _Parser {
  _Parser(this.source);
  final String source;
  int _at = 0;

  static const _pairs = {'(': ')', '[': ']'};
  static final _token = RegExp(r'\{([A-Za-z]+)\}');

  List<_Node> parse() => _sequence(null);

  List<_Node> _sequence(String? close) {
    final nodes = <_Node>[];
    final text = StringBuffer();
    void flush() {
      if (text.isEmpty) return;
      nodes.add(_Literal(text.toString()));
      text.clear();
    }

    while (_at < source.length) {
      final c = source[_at];
      if (close != null && c == close) {
        _at++;
        flush();
        return nodes;
      }
      final match = _token.matchAsPrefix(source, _at);
      if (match != null && audioTextTokens.contains(match.group(1))) {
        flush();
        nodes.add(_Token(match.group(1)!));
        _at = match.end;
        continue;
      }
      final pairClose = _pairs[c];
      if (pairClose != null && source.indexOf(pairClose, _at + 1) > 0) {
        final start = _at;
        _at++;
        final children = _sequence(pairClose);
        final hasDetail = children.any((n) => n is! _Literal);
        if (!hasDetail) {
          // Plain bracketed words ("(live)") are text.
          text.write(source.substring(start, _at));
          continue;
        }
        // The space before an opening bracket goes with the bracket.
        final s = text.toString();
        final space = s.endsWith(' ') ? ' ' : '';
        text
          ..clear()
          ..write(s.substring(0, s.length - space.length));
        flush();
        nodes.add(_Group('$space$c', children, pairClose));
        continue;
      }
      text.write(c);
      _at++;
    }
    flush();
    return nodes;
  }
}
