import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// Whether a background picture lies behind the pages (Settings >
/// Appearance > Background). Provided by the shell's `AppBackdrop`.
///
/// Over a picture, pages leave their own background transparent, and text
/// right on the page (not on a card) in a color other than [NfColors.text]
/// or [NfColors.textMuted] goes through [legibleOverBackdrop]: the scrim
/// over the picture keeps those two readable.
class BackdropScope extends InheritedWidget {
  const BackdropScope({super.key, required this.active, required super.child});

  final bool active;

  static bool activeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<BackdropScope>()?.active ?? false;

  @override
  bool updateShouldNotify(BackdropScope old) => old.active != active;
}

/// [color] for text right on the page over a background picture: moved
/// toward [NfColors.text] until it stands at least as far from the page
/// color as [NfColors.textMuted] does, so it reads wherever muted text
/// reads. A color that already does is kept.
Color legibleOverBackdrop(Color color, NfColors nf) {
  final muted = nf.textMuted.computeLuminance();
  bool enough(Color c) => nf.isDark ? c.computeLuminance() >= muted : c.computeLuminance() <= muted;
  for (var step = 0; step <= 20; step++) {
    final c = Color.lerp(color, nf.text, step / 20)!;
    if (enough(c)) return c;
  }
  return nf.text;
}
