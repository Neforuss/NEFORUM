// Shared by the seamless mode tests and the screens smoke test: what of a
// rendered screen still draws an outline that seamless mode takes away.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/widgets/surfaces.dart';

/// The first [AnimatedContainer] under [e], depth first: the box an [NfCard]
/// draws.
AnimatedContainer? _ownBox(Element e) {
  AnimatedContainer? found;
  void visit(Element child) {
    if (found != null) return;
    if (child.widget is AnimatedContainer) {
      found = child.widget as AnimatedContainer;
      return;
    }
    child.visitChildren(visit);
  }

  e.visitChildren(visit);
  return found;
}

/// Whether any side of [decoration]'s border shows (a color with opacity and a
/// width above 0).
bool outlineShows(Decoration? decoration) {
  if (decoration is! BoxDecoration) return false;
  final border = decoration.border;
  if (border is! Border) return false;
  return [border.top, border.right, border.bottom, border.left].any((s) => s.style != BorderStyle.none && s.width > 0 && s.color.a > 0);
}

/// Every [NfCard] on screen that is neither selected nor given its own
/// [NfCard.borderColor] and still shows an outline, described for a failure
/// message.
List<String> visibleCardOutlines(WidgetTester tester) => [
      for (final e in find.byType(NfCard).evaluate())
        if (e.widget case NfCard(selected: false, borderColor: null))
          if (outlineShows(_ownBox(e)?.decoration)) 'NfCard at ${tester.getRect(find.byElementPredicate((x) => x == e)).topLeft}',
    ];

/// The boxes painted in the navigation chrome's color (the sidebar, the rail
/// and the phone tab bar) that draw a line along their edge. Small boxes
/// in the same color (with the theme chrome, the surface color: a dot on a
/// timeline) are not the chrome.
List<String> visibleChromeEdges(WidgetTester tester, NfColors nf) {
  final edges = <String>[];
  for (final e in find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).color == nf.chrome).evaluate()) {
    final rect = tester.getRect(find.byElementPredicate((x) => x == e));
    if (rect.shortestSide < 56) continue;
    if (outlineShows((e.widget as Container).decoration)) edges.add('chrome at $rect');
  }
  return edges;
}
