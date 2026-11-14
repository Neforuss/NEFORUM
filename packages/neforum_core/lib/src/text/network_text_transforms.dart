import '../characters/kaomoji.dart';
import '../model/platform_descriptor.dart';

/// How a Markdown network reads its text.
enum MarkdownDialect {
  /// Plain text: nothing to protect.
  none,

  /// CommonMark and its relatives (Reddit, Lemmy, DEV, Hashnode, WriteFreely,
  /// Micropub servers, EmDash) and Discord's Markdown: a backslash before any ASCII
  /// punctuation character shows that character as it is.
  commonMark,

  /// NEFORUM's own small Markdown for Telegram and Matrix
  /// (`chatMarkdownToHtml`), which knows the kaomoji itself and leaves them
  /// alone; with "plain" formatting it is not used at all.
  chat,

  /// Misskey's MFM. It has no backslash escapes: a kaomoji with a character
  /// MFM uses for markup (`m(_ _)m` is an italic space there, two backticks
  /// make code) goes in `<plain>`, MFM's "show as it is".
  mfm,
}

/// What NEFORUM changes in a draft's text for one network, at adaptation time
/// ([VariantResolver]); never when the user inserts a character, so the draft
/// keeps exactly what was typed or picked.
///
/// The rules (one module, so a network that changes its handling changes one
/// place, and test/text/network_text_transforms_test.dart catches it):
/// - Never normalize: no NFC, no NFKC. ① Ⓐ 𝐁 ｆ go out as they are.
/// - Markdown networks get the curated kaomoji ([kKaomojiGroups]) escaped, so
///   `¯\_(ツ)_/¯` shows with its arm instead of losing it to italics. Only the
///   kaomoji: Markdown the user wrote stays Markdown.
/// - Variation selectors (U+FE0F), joined emoji (ZWJ sequences) and skin
///   tones are left alone: no network in the registry is proven to show them
///   wrongly, and each removal would need a test against that network.
abstract final class NetworkTextTransforms {
  /// The Markdown networks by id. A network with `supportsMarkdown` missing
  /// here is read as [MarkdownDialect.commonMark]; a test fails until it is
  /// listed, so the choice is made on purpose.
  static const Map<String, MarkdownDialect> dialects = {
    'reddit': MarkdownDialect.commonMark,
    'lemmy': MarkdownDialect.commonMark,
    'devto': MarkdownDialect.commonMark,
    'hashnode': MarkdownDialect.commonMark,
    'writefreely': MarkdownDialect.commonMark,
    'micropub': MarkdownDialect.commonMark,
    'discord': MarkdownDialect.commonMark,
    // EmDash: NEFORUM's Markdown to Portable Text (portable_text.dart) takes
    // CommonMark's backslash escapes before ASCII punctuation.
    'emdash': MarkdownDialect.commonMark,
    'telegram': MarkdownDialect.chat,
    'matrix': MarkdownDialect.chat,
    'misskey': MarkdownDialect.mfm,
  };

  static MarkdownDialect dialectOf(PlatformDescriptor d) => d.text.supportsMarkdown ? dialects[d.id] ?? MarkdownDialect.commonMark : MarkdownDialect.none;

  /// [text] as [d] gets it.
  static String adapt(String text, PlatformDescriptor d) => switch (dialectOf(d)) {
        MarkdownDialect.commonMark => escapeKaomojiForCommonMark(text),
        MarkdownDialect.mfm => plainKaomojiForMfm(text),
        MarkdownDialect.none || MarkdownDialect.chat => text,
      };

  /// The characters MFM builds markup from: code, bold, italic, strike,
  /// functions, math, custom emoji, tags and links.
  static final RegExp _mfmMarkupCharacter = RegExp(r'[`_*~$\\:<>\[\]]');

  /// [text] with each curated kaomoji that holds an MFM markup character put
  /// in MFM's `<plain>` tag, outside code.
  static String plainKaomojiForMfm(String text) {
    final spans = [for (final s in kaomojiSpans(text, skipCode: true)) if (_mfmMarkupCharacter.hasMatch(text.substring(s.start, s.end))) s];
    if (spans.isEmpty) return text;
    final out = StringBuffer();
    var cursor = 0;
    for (final s in spans) {
      out
        ..write(text.substring(cursor, s.start))
        ..write('<plain>${text.substring(s.start, s.end)}</plain>');
      cursor = s.end;
    }
    out.write(text.substring(cursor));
    return out.toString();
  }

  /// [text] with a backslash before each ASCII punctuation character of every
  /// curated kaomoji in it, outside code. CommonMark shows `\_` as `_`, so the
  /// network shows the kaomoji exactly; Reddit's `^` and Lemmy's `^` `~` are
  /// covered too.
  static String escapeKaomojiForCommonMark(String text) {
    final spans = kaomojiSpans(text, skipCode: true);
    if (spans.isEmpty) return text;
    final out = StringBuffer();
    var cursor = 0;
    for (final s in spans) {
      out.write(text.substring(cursor, s.start));
      for (final unit in text.substring(s.start, s.end).codeUnits) {
        if (isAsciiPunctuation(unit)) out.write(r'\');
        out.writeCharCode(unit);
      }
      cursor = s.end;
    }
    out.write(text.substring(cursor));
    return out.toString();
  }

  /// Where the curated kaomoji that hold ASCII punctuation sit in [text]:
  /// longest first, never overlapping, in order. With [skipCode], none inside
  /// a fenced block or an inline code span, where a backslash would show.
  static List<({int start, int end})> kaomojiSpans(String text, {bool skipCode = false}) {
    if (!text.codeUnits.any(isAsciiPunctuation)) return const [];
    final taken = <({int start, int end})>[];
    for (final k in _markedKaomoji) {
      var from = 0;
      while (true) {
        final at = text.indexOf(k, from);
        if (at < 0) break;
        if (!taken.any((t) => at < t.end && t.start < at + k.length)) taken.add((start: at, end: at + k.length));
        from = at + 1;
      }
    }
    taken.sort((a, b) => a.start.compareTo(b.start));
    if (!skipCode || taken.isEmpty) return taken;
    // Code is found with the kaomoji blanked out: the backtick in (＃`Д´) and
    // the one in (´｡• ω •｡`) do not make the words between them code.
    final masked = StringBuffer();
    var cursor = 0;
    for (final t in taken) {
      masked
        ..write(text.substring(cursor, t.start))
        ..write('x' * (t.end - t.start));
      cursor = t.end;
    }
    masked.write(text.substring(cursor));
    final code = _codeRanges(masked.toString());
    return [
      for (final t in taken)
        if (!code.any((c) => t.start < c.end && c.start < t.end)) t,
    ];
  }

  /// `! " # $ % & ' ( ) * + , - . / : ; < = > ? @ [ \ ] ^ _ ` { | } ~`.
  static bool isAsciiPunctuation(int u) => (u >= 0x21 && u <= 0x2F) || (u >= 0x3A && u <= 0x40) || (u >= 0x5B && u <= 0x60) || (u >= 0x7B && u <= 0x7E);

  /// The curated kaomoji that hold ASCII punctuation, longest first.
  static final List<String> _markedKaomoji = [
    for (final k in allKaomoji)
      if (k.codeUnits.any(isAsciiPunctuation)) k,
  ]..sort((a, b) => b.length.compareTo(a.length));

  static final RegExp _fence = RegExp(r'```[\s\S]*?(```|$)');
  static final RegExp _inlineCode = RegExp(r'`[^`\n]+`');

  static List<({int start, int end})> _codeRanges(String text) {
    final out = [for (final m in _fence.allMatches(text)) (start: m.start, end: m.end)];
    for (final m in _inlineCode.allMatches(text)) {
      if (!out.any((r) => m.start < r.end && r.start < m.end)) out.add((start: m.start, end: m.end));
    }
    return out;
  }
}
