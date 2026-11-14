import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' show EmphasisRun, parseEmphasis;

import '../state/settings.dart' show TextCardAlignment;
import 'emoji_text.dart';

/// Labels and icons for the five alignments, as the composer and Settings
/// show them.
extension TextCardAlignmentLabels on TextCardAlignment {
  String get label => switch (this) {
        TextCardAlignment.left => 'Left',
        TextCardAlignment.center => 'Centre',
        TextCardAlignment.right => 'Right',
        TextCardAlignment.justify => 'Justify',
        TextCardAlignment.distributed => 'Distributed',
      };

  String get description => switch (this) {
        TextCardAlignment.left => 'Lines start at the left edge',
        TextCardAlignment.center => 'Lines are centred',
        TextCardAlignment.right => 'Lines end at the right edge',
        TextCardAlignment.justify => 'Lines fill the width, except the last one',
        TextCardAlignment.distributed => 'Every line fills the width, the last one too',
      };

  IconData get icon => switch (this) {
        TextCardAlignment.left => Icons.format_align_left_rounded,
        TextCardAlignment.center => Icons.format_align_center_rounded,
        TextCardAlignment.right => Icons.format_align_right_rounded,
        TextCardAlignment.justify => Icons.format_align_justify_rounded,
        TextCardAlignment.distributed => Icons.format_textdirection_l_to_r_rounded,
      };

  /// Every line spans the whole width (justified or distributed).
  bool get fillsWidth => this == TextCardAlignment.justify || this == TextCardAlignment.distributed;
}

/// The paragraph alignment for [a]. Left and right follow the writing
/// direction, so right-to-left words with the default alignment start at the
/// right edge, as they did before alignments existed.
TextAlign textAlignOf(TextCardAlignment a) => switch (a) {
      TextCardAlignment.left => TextAlign.start,
      TextCardAlignment.center => TextAlign.center,
      TextCardAlignment.right => TextAlign.end,
      TextCardAlignment.justify => TextAlign.justify,
      TextCardAlignment.distributed => TextAlign.start,
    };

/// Where a block of words sits across the room it has, as a fraction (0 at
/// the left edge, 0.5 centred, 1 at the right edge).
double alignmentAnchor(TextCardAlignment a, TextDirection direction) {
  final rtl = direction == TextDirection.rtl;
  return switch (a) {
    TextCardAlignment.left => rtl ? 1 : 0,
    TextCardAlignment.right => rtl ? 0 : 1,
    _ => 0.5,
  };
}

/// Words laid out with one of the five [TextCardAlignment]s.
///
/// Left, centre, right and justify are the paragraph's own alignments.
/// Distributed has no paragraph equivalent: the words are laid out once to
/// find the lines, then every line (the last one included) is drawn on its own
/// with the letter spacing that makes it fill the width. A line that is a
/// single word is centred instead.
class AlignedText {
  /// With [emphasis] (1.4.3), **bold**, *italic* and ***both*** written in
  /// [words] are drawn in the style it gives for them ([parseEmphasis]), the
  /// asterisks left out; without it every character is drawn as written.
  AlignedText(String words, {required this.style, required this.alignment, required this.direction, this.maxLines, TextStyle Function(EmphasisRun run)? emphasis})
      : _emphasis = emphasis,
        _runs = emphasis == null ? null : _shownRuns(words) {
    text = _runs == null ? _shown(words) : _runs.map((r) => r.text).join();
  }

  /// [words] as drawn: an emoji this device cannot draw is left out, not drawn as
  /// a blank or a "no glyph" tile, and the words are tried in the background for
  /// the next paint (a saved picture tries them first, [EmojiSupport.prepare]).
  static String _shown(String words) {
    EmojiSupport.note(words);
    return EmojiSupport.withoutMissing(words);
  }

  /// [words] in runs of one emphasis each, every run [_shown].
  static List<EmphasisRun> _shownRuns(String words) => [
        for (final r in parseEmphasis(words))
          if (_shown(r.text) case final shown when shown.isNotEmpty) EmphasisRun(shown, bold: r.bold, italic: r.italic),
      ];

  /// The words drawn, without the asterisks that mark emphasis.
  late final String text;
  final TextStyle Function(EmphasisRun run)? _emphasis;
  final List<EmphasisRun>? _runs;
  final TextStyle style;
  final TextCardAlignment alignment;
  final TextDirection direction;

  /// Lines beyond this are cut, the last one ending with an ellipsis.
  final int? maxLines;

  TextPainter? _painter;
  final List<(TextPainter, Offset)> _lines = [];
  double _width = 0;

  TextPainter get _p => _painter ?? (throw StateError('AlignedText.layout was not called'));

  double get width => _width;
  double get height => _p.height;

  /// The words did not all fit in [maxLines].
  bool get didExceedMaxLines => _p.didExceedMaxLines;

  /// Each line as laid out, top to bottom, a blank line between paragraphs
  /// included.
  List<LineMetrics> get lineMetrics => _p.computeLineMetrics();

  /// Lays the words out within [maxWidth]. With [fill], or a justified or
  /// distributed alignment, the block is [maxWidth] wide; otherwise it is as
  /// wide as its longest line.
  void layout(double maxWidth, {bool fill = false}) {
    _disposeLines();
    _painter?.dispose();
    final full = fill || alignment.fillsWidth;
    _painter = TextPainter(
      text: _runs == null ? emojiSpan(text, style) : _spanOf(0, text.length, 0),
      textAlign: textAlignOf(alignment),
      textDirection: direction,
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
      textWidthBasis: full ? TextWidthBasis.parent : TextWidthBasis.longestLine,
    )..layout(minWidth: full ? maxWidth : 0, maxWidth: maxWidth);
    _width = full ? maxWidth : _p.width;
    if (alignment == TextCardAlignment.distributed) _distribute(maxWidth);
  }

  /// The rectangle the lines take, relative to the block's top left corner.
  Rect get lineBounds {
    if (alignment == TextCardAlignment.distributed) return Rect.fromLTWH(0, 0, _width, height);
    final metrics = _p.computeLineMetrics();
    if (metrics.isEmpty) return Rect.fromLTWH(0, 0, _width, height);
    final left = metrics.map((m) => m.left).reduce(math.min);
    final right = metrics.map((m) => m.left + m.width).reduce(math.max);
    return Rect.fromLTRB(left, 0, right, height);
  }

  void paint(Canvas canvas, Offset offset) {
    if (alignment != TextCardAlignment.distributed) {
      _p.paint(canvas, offset);
      return;
    }
    for (final (line, at) in _lines) {
      line.paint(canvas, offset + at);
    }
  }

  void dispose() {
    _disposeLines();
    _painter?.dispose();
    _painter = null;
  }

  void _disposeLines() {
    for (final (line, _) in _lines) {
      line.dispose();
    }
    _lines.clear();
  }

  /// [s] on one line, its letters [extraSpacing] further apart. With
  /// emphasis, [from] and [to] say where [s] is in [text], so each part
  /// keeps its bold or italic; without them it is drawn in [style].
  TextPainter _line(String s, double extraSpacing, [int? from, int? to]) => TextPainter(
        text: _runs != null && from != null && to != null
            ? _spanOf(from, to, extraSpacing)
            : emojiSpan(s, style.copyWith(letterSpacing: (style.letterSpacing ?? 0) + extraSpacing)),
        textDirection: direction,
        maxLines: 1,
      )..layout();

  /// [text] from [start] to [end] as spans, each run of words in its
  /// emphasis' style, letters [extraSpacing] further apart (1.4.3).
  TextSpan _spanOf(int start, int end, double extraSpacing) {
    TextStyle spaced(TextStyle s) => extraSpacing == 0 ? s : s.copyWith(letterSpacing: (s.letterSpacing ?? 0) + extraSpacing);
    final children = <InlineSpan>[];
    var at = 0;
    for (final r in _runs!) {
      final from = math.max(at, start), to = math.min(at + r.text.length, end);
      at += r.text.length;
      if (from >= to) continue;
      // Already without the emoji this device cannot draw (_shownRuns).
      children.add(emojiSpan(text.substring(from, to), spaced(r.plain ? style : _emphasis!(r)), dropMissing: false));
    }
    return TextSpan(style: spaced(style), children: children);
  }

  void _distribute(double width) {
    final metrics = _p.computeLineMetrics();
    for (var i = 0; i < metrics.length; i++) {
      final m = metrics[i];
      final at = _p.getPositionForOffset(Offset(m.left + m.width / 2, m.baseline - m.ascent / 2));
      final range = _p.getLineBoundary(at);
      final start = math.max(0, range.start);
      final raw = text.substring(start, math.min(text.length, range.end));
      var words = raw.trim();
      // Where the line's words are in [text], for their emphasis; a line cut
      // with an ellipsis is drawn plain.
      int? from = start + raw.length - raw.trimLeft().length;
      int? to = from + words.length;
      if (i == metrics.length - 1 && _p.didExceedMaxLines) {
        words = _withEllipsis(words, width);
        from = to = null;
      }
      if (words.isEmpty) continue;
      final natural = _line(words, 0, from, to);
      final top = m.baseline - natural.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      final gaps = words.characters.length - 1;
      if (gaps < 1 || !_spreadable(words) || natural.width >= width) {
        _lines.add((natural, Offset((width - natural.width) / 2, top)));
        continue;
      }
      // Letter spacing is added around every character, half before and half
      // after, the first and last ones too: the visible line is the painter's
      // width less one spacing, starting half a spacing in.
      final tracking = style.letterSpacing ?? 0;
      final extra = (width - natural.width + tracking) / gaps;
      natural.dispose();
      _lines.add((_line(words, extra, from, to), Offset(-(tracking + extra) / 2, top)));
    }
  }

  /// [words] shortened until it fits [width] with an ellipsis after it.
  String _withEllipsis(String words, double width) {
    var s = words;
    while (s.isNotEmpty) {
      final probe = _line('$s…', 0);
      final fits = probe.width <= width;
      probe.dispose();
      if (fits) break;
      s = s.characters.skipLast(1).toString();
    }
    return '${s.trimRight()}…';
  }

  /// More than one word, or writing without spaces between words (Chinese,
  /// Japanese, Korean), where every character can move apart.
  static bool _spreadable(String line) => RegExp(r'\s').hasMatch(line) || _cjk.hasMatch(line);

  static final RegExp _cjk = RegExp(r'[　-鿿가-힯豈-﫿＀-￯]');
}
