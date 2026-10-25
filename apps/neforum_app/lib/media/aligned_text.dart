import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/settings.dart' show TextCardAlignment;

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
  AlignedText(this.text, {required this.style, required this.alignment, required this.direction, this.maxLines});

  final String text;
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

  /// Lays the words out within [maxWidth]. With [fill], or a justified or
  /// distributed alignment, the block is [maxWidth] wide; otherwise it is as
  /// wide as its longest line.
  void layout(double maxWidth, {bool fill = false}) {
    _disposeLines();
    _painter?.dispose();
    final full = fill || alignment.fillsWidth;
    _painter = TextPainter(
      text: TextSpan(text: text, style: style),
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

  TextPainter _line(String s, double extraSpacing) => TextPainter(
        text: TextSpan(text: s, style: style.copyWith(letterSpacing: (style.letterSpacing ?? 0) + extraSpacing)),
        textDirection: direction,
        maxLines: 1,
      )..layout();

  void _distribute(double width) {
    final metrics = _p.computeLineMetrics();
    for (var i = 0; i < metrics.length; i++) {
      final m = metrics[i];
      final at = _p.getPositionForOffset(Offset(m.left + m.width / 2, m.baseline - m.ascent / 2));
      final range = _p.getLineBoundary(at);
      var words = text.substring(math.max(0, range.start), math.min(text.length, range.end)).trim();
      if (i == metrics.length - 1 && _p.didExceedMaxLines) words = _withEllipsis(words, width);
      if (words.isEmpty) continue;
      final natural = _line(words, 0);
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
      _lines.add((_line(words, extra), Offset(-(tracking + extra) / 2, top)));
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
