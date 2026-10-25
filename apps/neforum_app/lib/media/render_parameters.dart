import 'dart:convert';

import 'package:neforum_core/neforum_core.dart' show MediaAttachment;

/// What a generated file is, as `renderParameters['kind']`
/// ([MediaAttachment.renderParameters]).
abstract final class RenderKind {
  /// A NEFORUM text card.
  static const String textCard = 'textCard';

  /// A photo with the caption written on it, or set in a block above it.
  static const String caption = 'caption';

  /// A photo picked only for the background of the text cards; never posted
  /// by itself.
  static const String textCardBackground = 'textCardBackground';
}

/// The kind of generated file [m] is ([RenderKind]); null for user files and
/// files made before 1.2.0.
String? renderKindOf(MediaAttachment m) => m.renderParameters?['kind'] as String?;

/// Whether two render parameter maps describe the same rendering: the same
/// keys and values, whatever the key order, with 12 and 12.0 counted equal.
bool renderParametersEqual(Object? a, Object? b) => jsonEncode(_canonical(a)) == jsonEncode(_canonical(b));

Object? _canonical(Object? v) {
  if (v is Map) {
    final keys = [for (final k in v.keys) '$k']..sort();
    return {for (final k in keys) k: _canonical(v[k])};
  }
  if (v is List) return [for (final x in v) _canonical(x)];
  if (v is double) {
    if (!v.isFinite) return null;
    final r = (v * 10000).round() / 10000;
    return r == r.roundToDouble() ? r.toInt() : r;
  }
  return v;
}

/// FNV-1a over the UTF-16 code units: the same on every run (unlike
/// String.hashCode), so a saved file is found again.
String stableHash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16);
}
