import 'emoji_tables.dart';

/// Which grapheme clusters are emoji. One answer for the X counter and for the
/// text card painters, from Unicode's own data ([kEmojiBaseRanges]).
class EmojiClusters {
  EmojiClusters._();

  static const int _zwj = 0x200D;
  static const int _vs16 = 0xFE0F;
  static const int _keycap = 0x20E3;

  static bool _inRanges(List<int> ranges, int r) {
    var lo = 0, hi = ranges.length ~/ 2 - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (r < ranges[mid * 2]) {
        hi = mid - 1;
      } else if (r > ranges[mid * 2 + 1]) {
        lo = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  static bool _isRegionalIndicator(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;
  static bool _isKeycapBase(int r) => r == 0x23 || r == 0x2A || (r >= 0x30 && r <= 0x39);
  static bool _isSkinTone(int r) => r >= 0x1F3FB && r <= 0x1F3FF;
  static bool _isTag(int r) => r >= 0xE0020 && r <= 0xE007F;

  /// An emoji sequence can start with [r]. The pictographic blocks count whole,
  /// so an emoji newer than the table still counts.
  static bool isBase(int r) => (r >= 0x1F000 && r <= 0x1FAFF) || _inRanges(kEmojiBaseRanges, r);

  /// [cluster] (one grapheme cluster) is a sequence of more than one code point
  /// that makes one emoji: a keycap, a flag, or an emoji base followed by a
  /// variation selector, skin tone, joiner or tag. A joiner or variation selector
  /// after anything else (Sinhala and Malayalam write them in ordinary words)
  /// does not make an emoji.
  static bool isSequence(String cluster) {
    final runes = cluster.runes.toList();
    if (runes.length < 2 || runes.last == _zwj) return false;
    final first = runes.first;
    if (_isKeycapBase(first)) return runes.contains(_keycap);
    if (_isRegionalIndicator(first)) return runes.length == 2 && _isRegionalIndicator(runes[1]);
    if (!isBase(first)) return false;
    return runes.skip(1).any((r) => r == _zwj || r == _vs16 || r == _keycap || _isSkinTone(r) || _isTag(r));
  }

  /// [cluster] shows as an emoji picture by default: a sequence, or one code
  /// point Unicode gives emoji presentation. A digit or a plain U+2764 stays text.
  static bool showsAsEmoji(String cluster) {
    final runes = cluster.runes;
    if (runes.isEmpty) return false;
    if (runes.length > 1) return isSequence(cluster);
    final r = runes.first;
    return _inRanges(kEmojiPresentationRanges, r) || (r >= 0x1F90C && r <= 0x1F9FF) || (r >= 0x1FA70 && r <= 0x1FAFF);
  }

  /// Whether [text] can hold an emoji at all, quickly: anything below U+00A9 is
  /// text, except a keycap, which needs U+20E3 too.
  static bool mayHoldEmoji(String text) {
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) >= 0xA9) return true;
    }
    return false;
  }
}
