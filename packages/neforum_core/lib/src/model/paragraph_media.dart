import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'media.dart';

/// Paragraph-to-media links of a single long post ([Post.paragraphMedia]):
/// which paragraph of the text refers to which of the post's photos and
/// videos. A paragraph can refer to several; each file belongs to at most one
/// paragraph. Paragraphs are counted from 0 as [splitParagraphs] finds them;
/// files are named by the id of the file the user attached, so a copy made
/// from it ([MediaAttachment.derivedFrom]: a fitted photo, a photo with the
/// caption written on it) stands for it.
///
/// Optional and off by default: an empty map is a post without links, and
/// every network then gets the post exactly as before.
typedef ParagraphMediaLinks = Map<int, List<String>>;

/// One stretch of a post with linked paragraphs, in reading order: the
/// paragraphs up to and including a linked one, then the files that
/// paragraph refers to. The last section may have no files (the paragraphs
/// after the last linked one), and files linked to no paragraph go with the
/// last section.
@immutable
class ParagraphSection {
  const ParagraphSection(this.text, this.media);

  /// The section's words, exactly as written (blank lines between its
  /// paragraphs included). Empty when the section only carries files.
  final String text;

  /// The files that follow [text], in the order the post carries them.
  final List<MediaAttachment> media;

  @override
  String toString() => 'ParagraphSection(${text.length} chars, ${media.length} files)';
}

/// How a network shows a post whose paragraphs are linked to its files
/// ([MediaRules.paragraphMedia]).
enum ParagraphMediaStyle {
  /// The links are not used: the network gets the post as it always did.
  none,

  /// One post whose files follow the paragraphs' order, each linked
  /// paragraph ending with the numbers of its files: "(1/3)", "(2-3/3)"
  /// (Facebook, LinkedIn, Instagram).
  markers,

  /// The post goes out section by section ([ParagraphMedia.sections]), each
  /// paragraph followed by its own files: blocks in one post (Tumblr) or
  /// messages in a row (Telegram, Discord).
  sections,
}

/// The rules of [ParagraphMediaLinks]. Pure functions, no state.
abstract final class ParagraphMedia {
  /// The paragraphs of [text]: the blocks between blank lines, without the
  /// spaces around them; blank-only blocks are left out. A blank line inside
  /// a ``` code block does not end a paragraph.
  static List<String> split(String text) => [for (final s in _spans(text)) text.substring(s.start, s.end)];

  /// Whether file [m] is the file [id] names: the file itself or a copy made
  /// from it.
  static bool names(String id, MediaAttachment m) => m.id == id || m.derivedFrom == id;

  /// [links] as stored: paragraphs in order, each file once (in the first
  /// paragraph that names it), no empty lists. With [paragraphs] the links of
  /// paragraphs past the last one go; with [mediaIds] so do files no longer
  /// attached.
  static ParagraphMediaLinks normalized(ParagraphMediaLinks links, {int? paragraphs, Set<String>? mediaIds}) {
    final seen = <String>{};
    final out = <int, List<String>>{};
    for (final p in links.keys.toList()..sort()) {
      if (p < 0 || (paragraphs != null && p >= paragraphs)) continue;
      final ids = [
        for (final id in links[p]!)
          if ((mediaIds == null || mediaIds.contains(id)) && seen.add(id)) id,
      ];
      if (ids.isNotEmpty) out[p] = ids;
    }
    return out;
  }

  /// [links] from JSON (`{"0": ["id", ...], ...}`); anything else is no links.
  static ParagraphMediaLinks fromJson(Object? raw) {
    if (raw is! Map) return const {};
    final out = <int, List<String>>{};
    for (final e in raw.entries) {
      final p = int.tryParse('${e.key}');
      final ids = e.value;
      if (p == null || ids is! List) continue;
      out[p] = [for (final id in ids) if (id is String && id.isNotEmpty) id];
    }
    return normalized(out);
  }

  /// [links] as JSON: paragraph numbers as text keys.
  static Map<String, List<String>> toJson(ParagraphMediaLinks links) => {for (final e in normalized(links).entries) '${e.key}': e.value};

  /// [links] with paragraph [paragraph] referring to exactly [ids] (in that
  /// order); an empty list removes its links. A file it takes leaves the
  /// paragraph it was linked to before.
  static ParagraphMediaLinks link(ParagraphMediaLinks links, int paragraph, List<String> ids) {
    final taken = ids.toSet();
    return normalized({
      for (final e in links.entries)
        if (e.key != paragraph) e.key: [for (final id in e.value) if (!taken.contains(id)) id],
      if (ids.isNotEmpty) paragraph: ids,
    });
  }

  /// [links] without the file [id] (it was removed from the post).
  static ParagraphMediaLinks withoutMedia(ParagraphMediaLinks links, String id) => normalized({
        for (final e in links.entries) e.key: [for (final x in e.value) if (x != id) x],
      });

  /// The paragraph [id] is linked to, or null.
  static int? paragraphOf(ParagraphMediaLinks links, String id) {
    for (final e in links.entries) {
      if (e.value.contains(id)) return e.key;
    }
    return null;
  }

  /// [links] moved along with an edit of the text from [before] to [after],
  /// so a link stays with its paragraph while the user types: paragraphs
  /// that did not change keep their links wherever they moved, a changed
  /// paragraph keeps its own, one split in two keeps them on the piece that
  /// shares the most words with it, two merged into one share theirs, and a
  /// deleted paragraph's links go.
  static ParagraphMediaLinks remap(String before, String after, ParagraphMediaLinks links) {
    if (links.isEmpty || before == after) return links;
    final a = split(before);
    final b = split(after);
    var pre = 0;
    while (pre < a.length && pre < b.length && a[pre] == b[pre]) {
      pre++;
    }
    var suf = 0;
    while (suf < a.length - pre && suf < b.length - pre && a[a.length - 1 - suf] == b[b.length - 1 - suf]) {
      suf++;
    }
    final aMid = a.length - pre - suf;
    final bMid = b.length - pre - suf;
    final out = <int, List<String>>{};
    void add(int p, List<String> ids) => out.update(p, (x) => [...x, ...ids.where((id) => !x.contains(id))], ifAbsent: () => [...ids]);
    for (final e in links.entries) {
      final i = e.key;
      if (i < 0 || i >= a.length) continue;
      if (i < pre) {
        add(i, e.value);
      } else if (i >= a.length - suf) {
        add(i - a.length + b.length, e.value);
      } else if (bMid > 0) {
        // The changed stretch: the new paragraph most like the old one,
        // else the one at the same place.
        var best = math.min(i - pre, bMid - 1);
        var bestScore = 0;
        for (var j = 0; j < bMid; j++) {
          final score = _likeness(a[i], b[pre + j]);
          if (score > bestScore) {
            best = j;
            bestScore = score;
          }
        }
        if (bestScore == 0 && aMid == bMid) best = i - pre;
        add(pre + best, e.value);
      }
    }
    return normalized(out, paragraphs: b.length);
  }

  /// [media] in the order of the paragraphs: the files linked to the first
  /// paragraph (in the order it names them), then the second's, and so on,
  /// then the files linked to none, in their own order. Without links the
  /// list comes back as it is.
  static List<MediaAttachment> ordered(List<MediaAttachment> media, ParagraphMediaLinks links) {
    if (links.isEmpty || media.length < 2) return media;
    final rest = [...media];
    final out = <MediaAttachment>[];
    for (final p in links.keys.toList()..sort()) {
      for (final id in links[p]!) {
        for (final m in rest.where((m) => names(id, m)).toList()) {
          out.add(m);
          rest.remove(m);
        }
      }
    }
    return out.isEmpty ? media : [...out, ...rest];
  }

  /// [links] narrowed to the files of [media] (by [names]); the paragraphs
  /// whose files are all gone lose their links.
  static ParagraphMediaLinks present(ParagraphMediaLinks links, List<MediaAttachment> media) => normalized({
        for (final e in links.entries) e.key: [for (final id in e.value) if (media.any((m) => names(id, m))) id],
      });

  /// [text] and [media] as the sections a reader goes through: each linked
  /// paragraph closes a section (with the paragraphs before it that are
  /// linked to nothing) and its files follow it. Paragraphs after the last
  /// linked one make a last section; files linked to no paragraph go at the
  /// end of the last section. Without links that [media] has, one section
  /// with everything.
  static List<ParagraphSection> sections(String text, ParagraphMediaLinks links, List<MediaAttachment> media) {
    final spans = _spans(text);
    final active = present(links, media);
    if (active.isEmpty || spans.isEmpty) return [ParagraphSection(text.trim(), media)];
    final rest = [...media];
    final out = <ParagraphSection>[];
    var from = 0;
    for (var p = 0; p < spans.length; p++) {
      final ids = active[p];
      if (ids == null) continue;
      final own = <MediaAttachment>[];
      for (final id in ids) {
        for (final m in rest.where((m) => names(id, m)).toList()) {
          own.add(m);
          rest.remove(m);
        }
      }
      out.add(ParagraphSection(text.substring(spans[from].start, spans[p].end), own));
      from = p + 1;
    }
    if (from < spans.length) out.add(ParagraphSection(text.substring(spans[from].start, spans.last.end), const []));
    if (rest.isNotEmpty) {
      final last = out.removeLast();
      out.add(ParagraphSection(last.text, [...last.media, ...rest]));
    }
    return out;
  }

  /// [text] with the numbers of its files after each linked paragraph:
  /// " (1/3)" for the first of three, " (2-3/3)" for a paragraph that refers
  /// to the second and third, " (1, 3/4)" when they are not next to each
  /// other. Numbers count [media] as the post carries it; a paragraph whose
  /// files are not in [media] gets none. With fewer than two files there is
  /// nothing to tell apart and [text] comes back as it is.
  static String withMarkers(String text, ParagraphMediaLinks links, List<MediaAttachment> media) {
    if (media.length < 2) return text;
    final spans = _spans(text);
    final out = StringBuffer();
    var cursor = 0;
    for (var p = 0; p < spans.length; p++) {
      final ids = links[p];
      if (ids == null) continue;
      final numbers = <int>[
        for (var i = 0; i < media.length; i++)
          if (ids.any((id) => names(id, media[i]))) i + 1,
      ];
      if (numbers.isEmpty) continue;
      out
        ..write(text.substring(cursor, spans[p].end))
        ..write(' (${_ranges(numbers)}/${media.length})');
      cursor = spans[p].end;
    }
    if (cursor == 0) return text;
    out.write(text.substring(cursor));
    return out.toString();
  }

  /// The words that go on the files of [media] when each file carries its
  /// own part of the text (an Instagram story's frames): by the id of the
  /// first file of each section ([sections]), that section's words. The
  /// paragraphs after the last linked one go with the last section that has
  /// files. Files that are not first in their section get no words.
  static Map<String, String> wordsByMedia(String text, ParagraphMediaLinks links, List<MediaAttachment> media) {
    final all = sections(text, links, media);
    if (present(links, media).isEmpty) return const {};
    final out = <String, String>{};
    String? lastId;
    for (final s in all) {
      if (s.media.isEmpty) {
        if (lastId != null && s.text.isNotEmpty) out[lastId] = '${out[lastId]}\n\n${s.text}'.trim();
        continue;
      }
      lastId = s.media.first.id;
      out[lastId] = s.text;
    }
    return {
      for (final e in out.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value,
    };
  }

  /// "1", "2-3", "1, 3-4" for sorted [numbers].
  static String _ranges(List<int> numbers) {
    final parts = <String>[];
    var start = numbers.first;
    var end = start;
    for (final n in numbers.skip(1)) {
      if (n == end + 1) {
        end = n;
        continue;
      }
      parts.add(start == end ? '$start' : '$start-$end');
      start = end = n;
    }
    parts.add(start == end ? '$start' : '$start-$end');
    return parts.join(', ');
  }

  /// How much two paragraphs share: their common start plus their common
  /// end, in characters.
  static int _likeness(String a, String b) {
    final max = math.min(a.length, b.length);
    var pre = 0;
    while (pre < max && a.codeUnitAt(pre) == b.codeUnitAt(pre)) {
      pre++;
    }
    var suf = 0;
    while (suf < max - pre && a.codeUnitAt(a.length - 1 - suf) == b.codeUnitAt(b.length - 1 - suf)) {
      suf++;
    }
    return pre + suf;
  }

  /// Where each paragraph of [text] starts and ends, spaces around it left
  /// out.
  static List<({int start, int end})> _spans(String text) {
    final spans = <({int start, int end})>[];
    var fenced = false;
    int? start;
    var end = 0;
    var offset = 0;
    for (final raw in text.split('\n')) {
      final lineStart = offset;
      offset += raw.length + 1;
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (!fenced && line.trim().isEmpty) {
        if (start != null) spans.add((start: start, end: end));
        start = null;
        continue;
      }
      if ('```'.allMatches(line).length.isOdd) fenced = !fenced;
      final trimmed = line.trimRight();
      if (trimmed.trim().isEmpty) continue;
      start ??= lineStart + (line.length - line.trimLeft().length);
      end = lineStart + trimmed.length;
    }
    if (start != null) spans.add((start: start, end: end));
    return spans;
  }
}
