import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../theme/tokens.dart';

enum EntityKind { link, hashtag, mention }

/// A highlighted range of post text.
class TextEntity {
  const TextEntity(this.start, this.end, this.kind);
  final int start;
  final int end;
  final EntityKind kind;
}

final _hashtag = RegExp(r'(?<![\w#&])#[\p{L}\p{N}_]*[\p{L}_][\p{L}\p{N}_]*', unicode: true);
final _mention = RegExp(r'(?<![\w@/])@[A-Za-z0-9_][A-Za-z0-9_.-]*(?:@[A-Za-z0-9.-]+\.[A-Za-z]{2,})?');

/// Finds links, #hashtags and @mentions (links win on overlap).
List<TextEntity> findEntities(String text) {
  final out = <TextEntity>[
    for (final u in UrlDetector.find(text)) TextEntity(u.start, u.end, EntityKind.link),
  ];
  bool overlaps(int s, int e) => out.any((x) => s < x.end && e > x.start);
  for (final m in _hashtag.allMatches(text)) {
    if (!overlaps(m.start, m.end)) out.add(TextEntity(m.start, m.end, EntityKind.hashtag));
  }
  for (final m in _mention.allMatches(text)) {
    if (!overlaps(m.start, m.end)) out.add(TextEntity(m.start, m.end, EntityKind.mention));
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// Builds styled spans for [text] with entities highlighted.
List<InlineSpan> highlightSpans(String text, TextStyle base, NfColors nf, {Color? linkColor}) {
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final e in findEntities(text)) {
    if (e.start > cursor) spans.add(TextSpan(text: text.substring(cursor, e.start)));
    final style = switch (e.kind) {
      EntityKind.link => base.copyWith(
          color: linkColor ?? nf.info,
          decoration: TextDecoration.underline,
          decorationColor: (linkColor ?? nf.info).withValues(alpha: 0.5),
        ),
      EntityKind.hashtag => base.copyWith(color: linkColor ?? nf.accent, fontWeight: FontWeight.w600),
      EntityKind.mention => base.copyWith(color: linkColor ?? nf.accent, fontWeight: FontWeight.w600),
    };
    spans.add(TextSpan(text: text.substring(e.start, e.end), style: style));
    cursor = e.end;
  }
  if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
  return spans;
}

/// A [TextEditingController] that colours hashtags, mentions and links as
/// the user types. Falls back to plain rendering while an IME is composing
/// so input methods (CJK, emoji keyboards) are never disturbed.
class HighlightController extends TextEditingController {
  HighlightController({super.text});

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final composing = value.composing;
    if (withComposing && composing.isValid && !composing.isCollapsed) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final base = style ?? const TextStyle();
    return TextSpan(style: base, children: highlightSpans(text, base, context.nf));
  }
}
