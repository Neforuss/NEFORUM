/// Text clean-up shared by every document reader.
library;

/// Typographic ligatures and their letters (U+FB00 to U+FB06).
const Map<String, String> _ligatures = {
  'ﬀ': 'ff',
  'ﬁ': 'fi',
  'ﬂ': 'fl',
  'ﬃ': 'ffi',
  'ﬄ': 'ffl',
  'ﬅ': 'st',
  'ﬆ': 'st',
};

final RegExp _ligature = RegExp('[ﬀ-ﬆ]');

/// Zero-width characters, soft hyphens and byte-order marks, which carry
/// nothing a post needs.
final RegExp _invisible = RegExp('[­​‌‍⁠﻿]');

/// Spaces of every width, tabs included, but not line breaks.
final RegExp _spaces = RegExp('[ \t   -   　]+');

/// [text] with ligatures spelled out ("ﬁ" becomes "fi").
String expandLigatures(String text) => text.contains(_ligature) ? text.replaceAllMapped(_ligature, (m) => _ligatures[m[0]]!) : text;

/// One paragraph's text, tidied: ligatures spelled out, invisible
/// characters gone, runs of spaces made one, every line trimmed, and blank
/// lines removed (a paragraph never holds an empty line, which would split
/// it into two parts later). Line breaks inside the paragraph stay.
String normalizeParagraph(String text) {
  final cleaned = expandLigatures(text).replaceAll(_invisible, '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return cleaned
      .split('\n')
      .map((l) => l.replaceAll(_spaces, ' ').trim())
      .where((l) => l.isNotEmpty)
      .join('\n');
}

/// [text] as one line: every run of white space, line breaks included,
/// becomes one space.
String singleLine(String text) => normalizeParagraph(text).replaceAll('\n', ' ');

/// Joins the lines of a paragraph that was broken into lines for layout (a
/// PDF, a hard-wrapped text file). A word broken with a hyphen at the end
/// of a line ("inter-" + "national") is put back together when the next
/// line goes on in lower case; any other line break becomes a space.
String joinWrappedLines(Iterable<String> lines) {
  final out = StringBuffer();
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (out.isEmpty) {
      out.write(line);
      continue;
    }
    final soFar = out.toString();
    if (_endsWithBrokenWord(soFar) && _startsLowerCase(line)) {
      // Drop the hyphen: the word continues.
      out
        ..clear()
        ..write(soFar.substring(0, soFar.length - 1))
        ..write(line);
    } else if (soFar.endsWith('­')) {
      out
        ..clear()
        ..write(soFar.substring(0, soFar.length - 1))
        ..write(line);
    } else {
      out
        ..write(' ')
        ..write(line);
    }
  }
  return out.toString();
}

/// Ends with a letter and a hyphen (ASCII, hyphen U+2010 or soft hyphen).
bool _endsWithBrokenWord(String s) {
  if (s.length < 2) return false;
  final last = s[s.length - 1];
  if (last != '-' && last != '‐') return false;
  return RegExp(r'\p{L}', unicode: true).hasMatch(s[s.length - 2]);
}

bool _startsLowerCase(String s) => RegExp(r'^\p{Ll}', unicode: true).hasMatch(s);

/// The words of [text], for comparing what was read with what was written.
List<String> wordsOf(String text) => [
      for (final w in singleLine(text).split(' '))
        if (w.isNotEmpty) w,
    ];
