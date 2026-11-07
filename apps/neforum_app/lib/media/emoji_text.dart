import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' show EmojiClusters;
import 'package:unicode_emojis/unicode_emojis.dart' show UnicodeEmojis;

import '../state/render_warnings.dart';
import 'caption_fonts.dart' show captionFontsRevision;

// Emoji on pictures NEFORUM draws. Fallback order cannot draw a colour heart:
// Inter has its own U+2764, so it wins over any emoji font after it. So every
// emoji is its own run, whose first font is the emoji font. And a device that
// has no glyph for an emoji would draw the primary font's "no glyph" tile into
// the published picture, so each emoji is tried off screen first: one this device
// cannot draw is left out of the picture, and the user is told.

/// The colour emoji fonts of Windows, Apple systems, and Android and Linux; the
/// engine skips the ones a device does not have.
const List<String> kEmojiFontFamilies = ['Segoe UI Emoji', 'Apple Color Emoji', 'Noto Color Emoji'];

/// [base], for an emoji: the emoji font first, then what [base] would use. The
/// emoji font has one weight and no italics, so nothing is synthesized on it.
TextStyle emojiStyleOf(TextStyle base) => base.copyWith(
      fontFamily: kEmojiFontFamilies.first,
      fontFamilyFallback: [
        ...kEmojiFontFamilies.skip(1),
        if (base.fontFamily != null) base.fontFamily!,
        ...?base.fontFamilyFallback,
      ],
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
      fontVariations: const [],
    );

/// [text] as a span in [style], with each emoji in the emoji font. Text with no
/// emoji gets the plain span it always had, so such a card stays the same
/// picture, byte for byte. Emoji this device cannot draw are left out, unless
/// [dropMissing] is false (a text field has to keep every character).
TextSpan emojiSpan(String text, TextStyle style, {bool dropMissing = true}) {
  final shown = dropMissing ? EmojiSupport.withoutMissing(text) : text;
  final children = emojiRuns(shown, style);
  if (children == null) return TextSpan(text: shown, style: style);
  return TextSpan(style: style, children: children);
}

/// [text] split into plain runs and emoji runs; null when it holds no emoji.
/// The runs have no style of their own but the emoji font, so they take their
/// parent span's.
List<TextSpan>? emojiRuns(String text, TextStyle style) {
  if (!EmojiClusters.mayHoldEmoji(text)) return null;
  final emoji = emojiStyleOf(style);
  final out = <TextSpan>[];
  final plain = StringBuffer();
  final glyphs = StringBuffer();
  void flushPlain() {
    if (plain.isEmpty) return;
    out.add(TextSpan(text: plain.toString()));
    plain.clear();
  }

  void flushGlyphs() {
    if (glyphs.isEmpty) return;
    out.add(TextSpan(text: glyphs.toString(), style: emoji));
    glyphs.clear();
  }

  for (final c in text.characters) {
    if (EmojiClusters.showsAsEmoji(c)) {
      flushPlain();
      glyphs.write(c);
    } else {
      flushGlyphs();
      plain.write(c);
    }
  }
  if (out.isEmpty && glyphs.isEmpty) return null;
  flushPlain();
  flushGlyphs();
  return out;
}

/// How this device draws an emoji.
enum EmojiDraw {
  /// One picture.
  whole,

  /// In pieces: a flag as two letters, a joined emoji as the emoji it joins.
  parts,

  /// Not at all: a blank, or the font's "no glyph" tile.
  missing,
}

/// What this device's fonts can draw, tried off screen once per emoji per run.
class EmojiSupport {
  EmojiSupport._();

  static final Map<String, EmojiDraw> _known = {};
  static final Set<String> _noted = {};
  static final Set<String> _reported = {};
  static Future<_Drawn>? _noGlyph;
  static Future<bool>? _hasColour;

  /// Replaces the off-screen drawing, for tests: `flutter test` has no real
  /// fonts unless a test loads them.
  @visibleForTesting
  static EmojiDraw Function(String cluster)? debugProbe;

  /// Forgets everything tried, for tests.
  @visibleForTesting
  static void debugReset() {
    _known.clear();
    _noted.clear();
    _reported.clear();
    _noGlyph = null;
    _hasColour = null;
    debugProbe = null;
  }

  /// What is known about [cluster] so far.
  static EmojiDraw? known(String cluster) => _known[cluster];

  static Iterable<String> _clustersOf(String text) =>
      EmojiClusters.mayHoldEmoji(text) ? text.characters.where(EmojiClusters.showsAsEmoji) : const [];

  /// [text] without the emoji known to be missing here.
  static String withoutMissing(String text) {
    if (_known.isEmpty || !EmojiClusters.mayHoldEmoji(text)) return text;
    if (!_clustersOf(text).any((c) => _known[c] == EmojiDraw.missing)) return text;
    return text.characters.where((c) => _known[c] != EmojiDraw.missing).join();
  }

  /// Finds out how [cluster] draws; the answer is kept for this run.
  static Future<EmojiDraw> probe(String cluster) async {
    final known = _known[cluster];
    if (known != null) return known;
    final override = debugProbe;
    return _known[cluster] = override != null ? override(cluster) : await _classify(cluster);
  }

  /// For a picture about to be saved: tries every emoji in [text], and tells the
  /// user about any that cannot be drawn as it should. [usage] says what uses it
  /// ("the text card"). Never throws, and a failed try counts as drawable.
  static Future<void> prepare(String text, {String usage = 'the text card'}) async {
    for (final c in _clustersOf(text).toSet()) {
      EmojiDraw draw;
      try {
        draw = await probe(c).timeout(const Duration(seconds: 5));
      } on Object catch (e) {
        debugPrint('Could not try an emoji: $e');
        continue;
      }
      if (draw == EmojiDraw.whole || !_reported.add('$c|$usage')) continue;
      final name = _nameOf(c);
      reportRenderWarning(draw == EmojiDraw.missing
          ? 'This device cannot draw the emoji $name, so $usage leaves it out. The text of the post keeps it.'
          : 'This device draws the emoji $name in pieces, and $usage shows it that way. The text of the post keeps it whole.');
    }
  }

  /// For a live preview, which cannot wait: tries [text]'s emoji in the
  /// background and repaints when one turns out not to draw.
  static void note(String text) {
    if (!EmojiClusters.mayHoldEmoji(text)) return;
    final fresh = _clustersOf(text).where((c) => !_known.containsKey(c) && _noted.add(c)).toList();
    if (fresh.isEmpty) return;
    unawaited(() async {
      var changed = false;
      for (final c in fresh) {
        try {
          if (await probe(c) != EmojiDraw.whole) changed = true;
        } on Object catch (e) {
          debugPrint('Could not try an emoji: $e');
        }
      }
      if (changed) captionFontsRevision.value++;
    }());
  }

  static String _nameOf(String cluster) {
    final bare = cluster.replaceAll('️', '');
    for (final e in UnicodeEmojis.allEmojis) {
      if (e.emoji.replaceAll('️', '') == bare) return '"${e.name}"';
      for (final v in e.skinVariations ?? const []) {
        if (v.emoji.replaceAll('️', '') == bare) return '"${e.name}"';
      }
    }
    return 'U+${cluster.runes.first.toRadixString(16).toUpperCase()}';
  }

  static const double _size = 48;

  static Future<_Drawn> _draw(String text) async {
    const width = 240, height = 96;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontFamily: kEmojiFontFamilies.first, fontFamilyFallback: kEmojiFontFamilies.skip(1).toList(), fontSize: _size, height: 1.2, color: const Color(0xFF000000)),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    painter.paint(canvas, const Offset(8, 8));
    final measured = painter.width;
    painter.dispose();
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    image.dispose();
    return _Drawn(data!.buffer.asUint8List(), measured);
  }

  /// A code point no font has, and whose picture is therefore the "no glyph" one.
  static Future<_Drawn> get _noGlyphDrawn => _noGlyph ??= _draw('\u{1FFFD}');

  static Future<bool> get _deviceHasColour => _hasColour ??= _draw('\u{1F600}').then((d) => d.coloured > 40);

  static bool _isFlag(String cluster) {
    final first = cluster.runes.first;
    return (first >= 0x1F1E6 && first <= 0x1F1FF) || cluster.runes.any((r) => r >= 0xE0020 && r <= 0xE007F);
  }

  static Future<EmojiDraw> _classify(String cluster) async {
    final drawn = await _draw(cluster);
    final blank = await _noGlyphDrawn;
    if (drawn.ink == 0 || listEquals(drawn.pixels, blank.pixels)) return EmojiDraw.missing;
    final colour = drawn.coloured > 40;
    if (_isFlag(cluster)) return colour && drawn.width <= _size * 1.7 ? EmojiDraw.whole : EmojiDraw.parts;
    // A real picture in the emoji planes is always in colour where the device
    // has a colour font; a one-colour one is a fallback font's stand-in tile.
    if (!colour && cluster.runes.first >= 0x1F000 && await _deviceHasColour) return EmojiDraw.missing;
    final runes = cluster.runes.toList();
    if (drawn.width <= _size * 1.7) return EmojiDraw.whole;
    // Joined emoji that came apart: a part with no glyph would be a tile.
    for (final r in runes) {
      if (r < 0x2190 || r == 0xFE0F || r == 0x200D || (r >= 0x1F3FB && r <= 0x1F3FF)) continue;
      final part = await _draw(String.fromCharCode(r));
      if (part.ink == 0 || listEquals(part.pixels, blank.pixels)) return EmojiDraw.missing;
    }
    return EmojiDraw.parts;
  }
}

class _Drawn {
  _Drawn(this.pixels, this.width);
  final Uint8List pixels;
  final double width;

  int get ink {
    var n = 0;
    for (var i = 3; i < pixels.length; i += 4) {
      if (pixels[i] > 40) n++;
    }
    return n;
  }

  int get coloured {
    var n = 0;
    for (var i = 0; i < pixels.length; i += 4) {
      if (pixels[i + 3] <= 40) continue;
      final r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
      final hi = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final lo = r < g ? (r < b ? r : b) : (g < b ? g : b);
      if (hi - lo > 40) n++;
    }
    return n;
  }
}
