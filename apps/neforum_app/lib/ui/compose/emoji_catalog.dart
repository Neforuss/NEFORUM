import 'package:flutter/foundation.dart' hide Category;
import 'package:unicode_emojis/unicode_emojis.dart';

import '../../media/emoji_text.dart';

/// Most recent emoji kept per device.
const int kEmojiRecentsMax = 32;

/// [recents] with [picked] first, each once, cut to [kEmojiRecentsMax].
List<String> withRecentEmoji(List<String> recents, String picked) => [
      picked,
      for (final e in recents)
        if (e != picked) e,
    ].take(kEmojiRecentsMax).toList();

/// The skin tone code point of [tone] (1 to 5); null for the default yellow.
int? skinToneCodePoint(int tone) => tone >= 1 && tone <= 5 ? 0x1F3FA + tone : null;

/// What goes into the text for [e] at [tone]: the variation with that one tone,
/// or the emoji itself when it has none.
String emojiAtTone(Emoji e, int tone) {
  final modifier = skinToneCodePoint(tone);
  final variations = e.skinVariations;
  if (modifier == null || variations == null) return e.emoji;
  for (final v in variations) {
    final tones = v.emoji.runes.where((r) => r >= 0x1F3FB && r <= 0x1F3FF);
    if (tones.isNotEmpty && tones.every((r) => r == modifier)) return v.emoji;
  }
  return e.emoji;
}

List<Emoji>? _all;

/// Every current emoji, in Unicode's order.
List<Emoji> get allEmoji => _all ??= [
      for (final e in UnicodeEmojis.allEmojis)
        if (e.obsoletedBy == null) e,
    ]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

/// The emoji of [category], in Unicode's order.
List<Emoji> emojiOf(Category category) => [
      for (final e in allEmoji)
        if (e.category == category) e,
    ];

/// The emoji whose picture is [glyph], whatever its skin tone.
Emoji? emojiByGlyph(String glyph) {
  for (final e in allEmoji) {
    if (e.emoji == glyph) return e;
    for (final v in e.skinVariations ?? const <Emoji>[]) {
      if (v.emoji == glyph) return e;
    }
  }
  return null;
}

/// How well [query] (lower case, one word) fits [e]: lower is better, null for
/// no fit. A short name exactly, then the start of a word, then anywhere; the
/// category last, so "flag" lists flags after the emoji named for it.
int? _fit(Emoji e, String word) {
  if (e.shortNames.contains(word) || e.text?.toLowerCase() == word) return 0;
  final names = [e.name, ...e.shortNames.map((s) => s.replaceAll('_', ' '))];
  if (names.any((n) => n == word)) return 0;
  final start = RegExp('(^|[ -])${RegExp.escape(word)}');
  if (names.any(start.hasMatch)) return 1;
  if (names.any((n) => n.contains(word))) return 2;
  if (e.subcategory.toLowerCase().contains(word) || e.category.description.toLowerCase().contains(word)) return 3;
  return null;
}

/// The emoji fitting every word of [query], best fit first, Unicode's order
/// within a fit. Runs over the whole list in a few milliseconds, with no network.
List<Emoji> searchEmoji(String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const [];
  final hits = <(int, Emoji)>[];
  for (final e in allEmoji) {
    var total = 0;
    var fits = true;
    for (final w in words) {
      final f = _fit(e, w);
      if (f == null) {
        fits = false;
        break;
      }
      total += f;
    }
    if (fits) hits.add((total, e));
  }
  mergeSort(hits, compare: (a, b) => a.$1.compareTo(b.$1));
  return [for (final h in hits) h.$2];
}

/// Which emoji this device's fonts draw. The emoji of one Emoji version arrive
/// together in a system font, so one tried per version answers for its version.
@immutable
class EmojiDeviceSupport {
  const EmojiDeviceSupport({required this.hiddenVersions, required this.flagsInPieces, required this.anyFont});

  /// Before anything was tried: only what every system since 2019 draws.
  static const EmojiDeviceSupport assumed = EmojiDeviceSupport(hiddenVersions: null, flagsInPieces: false, anyFont: true);

  /// Emoji versions (`addedIn`) this device does not draw whole; null until
  /// tried.
  final Set<String>? hiddenVersions;

  /// Flags come out as two letters, on Windows.
  final bool flagsInPieces;

  /// The device has an emoji font at all.
  final bool anyFont;

  /// Whether [e] draws here. Flags always stay, where there is an emoji font at
  /// all: with none, every one would be a box.
  bool draws(Emoji e) {
    if (!anyFont) return false;
    if (e.category == Category.flags) return true;
    final hidden = hiddenVersions;
    if (hidden == null) return (double.tryParse(e.addedIn) ?? 99) <= 12.1;
    return !hidden.contains(e.addedIn);
  }
}

Future<EmojiDeviceSupport>? _support;

/// Forgets what was tried, for tests.
@visibleForTesting
void debugResetEmojiDeviceSupport() => _support = null;

/// What this device draws, tried once per run off screen.
Future<EmojiDeviceSupport> emojiDeviceSupport() => _support ??= _trySupport();

Future<EmojiDeviceSupport> _trySupport() async {
  final firstOfVersion = <String, Emoji>{};
  for (final e in allEmoji) {
    if (e.category != Category.flags) firstOfVersion.putIfAbsent(e.addedIn, () => e);
  }
  final hidden = <String>{};
  for (final entry in firstOfVersion.entries) {
    if (await EmojiSupport.probe(entry.value.emoji) != EmojiDraw.whole) hidden.add(entry.key);
  }
  final anyFont = await EmojiSupport.probe('\u{1F600}') != EmojiDraw.missing;
  final flag = await EmojiSupport.probe('\u{1F1FA}\u{1F1F8}');
  return EmojiDeviceSupport(hiddenVersions: anyFont ? hidden : const {}, flagsInPieces: flag != EmojiDraw.whole, anyFont: anyFont);
}
