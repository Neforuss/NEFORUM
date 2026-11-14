import 'package:meta/meta.dart';

// 1.4.3: inline emphasis written the Markdown way in a post's words:
// **bold**, *italic* and ***bold italic***. NEFORUM text cards draw it as
// bold and italic type; networks without Markdown get the words without the
// asterisks when the post's card uses it (kEmphasisMarkupKey in
// variant_resolver.dart).
//
// The rules are deliberately narrow, so ordinary writing is never read as
// emphasis by mistake:
//
// - Only asterisks. Underscores stay as written (handles, file names and
//   snake_case words are full of them).
// - The opening asterisks follow a space, a line start or punctuation, never a
//   letter or digit, and are followed by a character that is not a space; the
//   closing ones are the same number of asterisks, follow a character that is
//   not a space and are not followed by a letter or digit. So `5 * 3 * 2`,
//   `2*3*4`, `a ** b` and a lone `*` stay as they are.
// - Emphasis never spans a blank line (a paragraph break).
// - Inside bold, single asterisks still make italic (`**very *much* so**`).

/// A stretch of words with one emphasis.
@immutable
class EmphasisRun {
  const EmphasisRun(this.text, {this.bold = false, this.italic = false});

  final String text;
  final bool bold;
  final bool italic;

  bool get plain => !bold && !italic;

  @override
  bool operator ==(Object other) => other is EmphasisRun && other.text == text && other.bold == bold && other.italic == italic;

  @override
  int get hashCode => Object.hash(text, bold, italic);

  @override
  String toString() => 'EmphasisRun(${bold ? 'bold ' : ''}${italic ? 'italic ' : ''}"$text")';
}

/// One to three asterisks around words, on the rules above. Group 1 is the
/// asterisks, group 2 the words between them.
final RegExp _delimited = RegExp(
  r'(?<![\p{L}\p{N}_*])(\*{1,3})(?=[^\s*])((?:(?!\n[ \t]*\n)[\s\S])*?[^\s*])\1(?![\p{L}\p{N}_*])',
  unicode: true,
);

/// [text] cut into runs of plain, bold, italic and bold italic words, the
/// asterisks that mark them left out. Adjacent runs never share an emphasis;
/// an empty [text] gives no runs.
List<EmphasisRun> parseEmphasis(String text) {
  final out = <EmphasisRun>[];
  void add(String s, bool bold, bool italic) {
    if (s.isEmpty) return;
    final last = out.isEmpty ? null : out.last;
    if (last != null && last.bold == bold && last.italic == italic) {
      out[out.length - 1] = EmphasisRun(last.text + s, bold: bold, italic: italic);
    } else {
      out.add(EmphasisRun(s, bold: bold, italic: italic));
    }
  }

  void scan(String s, bool bold, bool italic) {
    var at = 0;
    for (final m in _delimited.allMatches(s)) {
      add(s.substring(at, m.start), bold, italic);
      final marks = m.group(1)!.length;
      // Inside, the same kind again adds nothing; the other kind still
      // counts (italic inside bold).
      scan(m.group(2)!, bold || marks >= 2, italic || marks != 2);
      at = m.end;
    }
    add(s.substring(at), bold, italic);
  }

  scan(text, false, false);
  return out;
}

/// [text] without the asterisks that mark emphasis ([parseEmphasis]);
/// every other character stays.
String stripEmphasis(String text) {
  if (!text.contains('*')) return text;
  return parseEmphasis(text).map((r) => r.text).join();
}

/// Whether [text] marks any words bold or italic.
bool hasEmphasis(String text) => text.contains('*') && parseEmphasis(text).any((r) => !r.plain);
