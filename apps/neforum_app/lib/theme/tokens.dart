import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Spacing scale (4-pt grid). Use these instead of literal numbers so the
/// whole app keeps one rhythm.
abstract final class Space {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double x3 = 32;
  static const double x4 = 40;
  static const double x5 = 48;
  static const double x6 = 64;
}

/// Corner radii.
abstract final class Radii {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;

  static const BorderRadius rXs = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius rSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius rXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius rPill = BorderRadius.all(Radius.circular(pill));
}

/// Motion.
abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration medium = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 420);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;
  static const Curve spring = Curves.easeOutBack;
}

/// Layout breakpoints (logical pixels of the window width).
abstract final class Breakpoints {
  /// Below this: phone layout with bottom navigation.
  static const double compact = 720;

  /// Below this: rail navigation; above: full sidebar + side-by-side panes.
  static const double expanded = 1180;

  /// Max width of reading content (settings, forms).
  static const double readable = 760;
}

/// Font families bundled with the app (all SIL Open Font License).
abstract final class Fonts {
  static const String display = 'Bricolage';
  static const String body = 'Inter';
  static const String mono = 'JetBrainsMono';
}

/// The NEFORUM brand: purple carries it, yellow is the spark (the logo's
/// source point, the main call to action on the navigation chrome,
/// "needs you" highlights). Yellow is never used as text or as the only cue
/// on light surfaces, where it has no contrast; it always sits on purple,
/// on dark surfaces, or as a fill behind [ink] text.
abstract final class Brand {
  static const Color purple = Color(0xFF7D00FF);
  static const Color yellow = Color(0xFFFFFF00);

  /// Deep purple of the navigation chrome (sidebar, rail, bottom bar).
  static const Color night = Color(0xFF16062F);

  /// Near-black with a purple cast: text on yellow.
  static const Color ink = Color(0xFF120424);

  /// The logo tile. Fixed, whatever accent the user picks.
  static const LinearGradient markGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF9426FF), purple, Color(0xFF5C00C4)],
    stops: [0.0, 0.5, 1.0],
  );
}

/// The accent hues the user can pick in Settings → Appearance.
enum AccentChoice {
  neforum('NEFORUM purple', Brand.purple, Color(0xFF9D4DFF)),
  coral('Coral', Color(0xFFF2542D), Color(0xFFFF7A59)),
  ocean('Ocean', Color(0xFF1677FF), Color(0xFF4C9BFF)),
  jade('Jade', Color(0xFF0F9F6E), Color(0xFF2FD39A)),
  magenta('Magenta', Color(0xFFD6338A), Color(0xFFF0629F)),
  amber('Amber', Color(0xFFC77800), Color(0xFFFFB02E));

  const AccentChoice(this.label, this.light, this.dark);
  final String label;

  /// Accent used on light backgrounds, and the fill of accent buttons in
  /// both themes (white text on it passes WCAG AA).
  final Color light;

  /// Accent for text and icons on dark backgrounds (a touch brighter for
  /// contrast).
  final Color dark;
}

/// Semantic colors beyond Material's ColorScheme. Read with
/// `context.nf` (see the extension below).
@immutable
class NfColors extends ThemeExtension<NfColors> {
  const NfColors({
    required this.bg,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.surfaceHover,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.accent,
    required this.accentFill,
    required this.accentSoft,
    required this.onAccent,
    required this.highlight,
    required this.onHighlight,
    required this.chrome,
    required this.chromeRaised,
    required this.onChrome,
    required this.onChromeMuted,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.danger,
    required this.dangerSoft,
    required this.info,
    required this.infoSoft,
    required this.shadow,
    required this.scrim,
    required this.brandGradient,
    required this.isDark,
  });

  /// Window background.
  final Color bg;

  /// Cards, panels.
  final Color surface;

  /// Popovers, menus, a card on top of a card.
  final Color surfaceRaised;

  /// Wells: text fields, media trays, code.
  final Color surfaceSunken;
  final Color surfaceHover;
  final Color border;
  final Color borderStrong;
  final Color text;
  final Color textMuted;
  final Color textFaint;
  /// Accent for text, icons, focus rings.
  final Color accent;

  /// Accent as a fill behind [onAccent] (buttons, switches, badges).
  final Color accentFill;

  /// Tinted backgrounds for selected states and badges.
  final Color accentSoft;
  final Color onAccent;

  /// Brand yellow, as a fill behind [onHighlight].
  final Color highlight;
  final Color onHighlight;

  /// Navigation chrome (sidebar, rail, bottom bar): deep purple in both
  /// themes, with white content and yellow for the current section.
  final Color chrome;

  /// A card or selected row on the chrome.
  final Color chromeRaised;
  final Color onChrome;
  final Color onChromeMuted;
  final Color success;
  final Color successSoft;
  final Color warning;
  final Color warningSoft;
  final Color danger;
  final Color dangerSoft;
  final Color info;
  final Color infoSoft;
  final Color shadow;
  final Color scrim;

  /// The NEFORUM signature gradient (logo, primary call to action).
  final LinearGradient brandGradient;
  final bool isDark;

  static NfColors light(AccentChoice accent) {
    final a = accent.light;
    return NfColors(
      bg: const Color(0xFFF6F4FA),
      surface: const Color(0xFFFFFFFF),
      surfaceRaised: const Color(0xFFFFFFFF),
      surfaceSunken: const Color(0xFFEFEBF6),
      surfaceHover: const Color(0xFFF8F6FC),
      border: const Color(0xFFE4DFEE),
      borderStrong: const Color(0xFFCDC5DD),
      text: const Color(0xFF170B2B),
      textMuted: const Color(0xFF5F5674),
      textFaint: const Color(0xFF8E87A1),
      accent: a,
      accentFill: a,
      accentSoft: Color.alphaBlend(a.withValues(alpha: 0.09), Colors.white),
      onAccent: Colors.white,
      highlight: Brand.yellow,
      onHighlight: Brand.ink,
      chrome: Brand.night,
      chromeRaised: const Color(0xFF241044),
      onChrome: Colors.white,
      onChromeMuted: const Color(0xFFB8ADD0),
      success: const Color(0xFF0E9F62),
      successSoft: const Color(0xFFE3F6EC),
      warning: const Color(0xFFC07A00),
      warningSoft: const Color(0xFFFFF3DC),
      danger: const Color(0xFFDC3A3F),
      dangerSoft: const Color(0xFFFDE8E8),
      info: const Color(0xFF2B74E0),
      infoSoft: const Color(0xFFE5EFFD),
      shadow: const Color(0x1A1C1A14),
      scrim: const Color(0x66101114),
      brandGradient: _gradientFor(a),
      isDark: false,
    );
  }

  static NfColors dark(AccentChoice accent) {
    final a = accent.dark;
    return NfColors(
      bg: const Color(0xFF0D0916),
      surface: const Color(0xFF15101F),
      surfaceRaised: const Color(0xFF1D1729),
      surfaceSunken: const Color(0xFF100C19),
      surfaceHover: const Color(0xFF1B1526),
      border: const Color(0xFF2A2338),
      borderStrong: const Color(0xFF3B3250),
      text: const Color(0xFFF4F1FA),
      textMuted: const Color(0xFFADA5C0),
      textFaint: const Color(0xFF766E8A),
      accent: a,
      accentFill: accent.light,
      accentSoft: Color.alphaBlend(a.withValues(alpha: 0.16), const Color(0xFF15101F)),
      onAccent: Colors.white,
      highlight: Brand.yellow,
      onHighlight: Brand.ink,
      chrome: const Color(0xFF110524),
      chromeRaised: const Color(0xFF211040),
      onChrome: Colors.white,
      onChromeMuted: const Color(0xFFAA9DC6),
      success: const Color(0xFF3DD68C),
      successSoft: const Color(0xFF12291F),
      warning: const Color(0xFFFFB547),
      warningSoft: const Color(0xFF2E2414),
      danger: const Color(0xFFFF6369),
      dangerSoft: const Color(0xFF2E1517),
      info: const Color(0xFF5EA8FF),
      infoSoft: const Color(0xFF13233A),
      shadow: const Color(0x66000000),
      scrim: const Color(0x99000000),
      brandGradient: _gradientFor(accent.light),
      isDark: true,
    );
  }

  /// The primary call-to-action fill: the accent with a little depth
  /// (lighter top-left, deeper bottom-right). White text passes AA on all of it.
  static LinearGradient _gradientFor(Color accent) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color.lerp(accent, Colors.white, 0.14)!, accent, Color.lerp(accent, Colors.black, 0.24)!],
        stops: const [0.0, 0.5, 1.0],
      );

  @override
  NfColors copyWith({Color? accent}) => this;

  @override
  NfColors lerp(ThemeExtension<NfColors>? other, double t) {
    if (other is! NfColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return NfColors(
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surfaceRaised: l(surfaceRaised, other.surfaceRaised),
      surfaceSunken: l(surfaceSunken, other.surfaceSunken),
      surfaceHover: l(surfaceHover, other.surfaceHover),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      text: l(text, other.text),
      textMuted: l(textMuted, other.textMuted),
      textFaint: l(textFaint, other.textFaint),
      accent: l(accent, other.accent),
      accentFill: l(accentFill, other.accentFill),
      accentSoft: l(accentSoft, other.accentSoft),
      onAccent: l(onAccent, other.onAccent),
      highlight: l(highlight, other.highlight),
      onHighlight: l(onHighlight, other.onHighlight),
      chrome: l(chrome, other.chrome),
      chromeRaised: l(chromeRaised, other.chromeRaised),
      onChrome: l(onChrome, other.onChrome),
      onChromeMuted: l(onChromeMuted, other.onChromeMuted),
      success: l(success, other.success),
      successSoft: l(successSoft, other.successSoft),
      warning: l(warning, other.warning),
      warningSoft: l(warningSoft, other.warningSoft),
      danger: l(danger, other.danger),
      dangerSoft: l(dangerSoft, other.dangerSoft),
      info: l(info, other.info),
      infoSoft: l(infoSoft, other.infoSoft),
      shadow: l(shadow, other.shadow),
      scrim: l(scrim, other.scrim),
      brandGradient: LinearGradient.lerp(brandGradient, other.brandGradient, t)!,
      isDark: t < 0.5 ? isDark : other.isDark,
    );
  }

  /// Soft elevation used by raised surfaces (popovers, floating bars).
  List<BoxShadow> get elevation1 => [
        BoxShadow(color: shadow, blurRadius: 18, offset: const Offset(0, 6), spreadRadius: -6),
      ];

  List<BoxShadow> get elevation2 => [
        BoxShadow(color: shadow, blurRadius: 40, offset: const Offset(0, 18), spreadRadius: -12),
        BoxShadow(color: shadow.withValues(alpha: shadow.a * 0.5), blurRadius: 6, offset: const Offset(0, 2)),
      ];

  /// A colored glow under the primary button.
  List<BoxShadow> glow(Color c, {double strength = 1}) => [
        BoxShadow(
          color: c.withValues(alpha: (isDark ? 0.45 : 0.30) * strength),
          blurRadius: 24 * strength,
          offset: const Offset(0, 8),
          spreadRadius: -6,
        ),
      ];
}

extension NfThemeX on BuildContext {
  NfColors get nf => Theme.of(this).extension<NfColors>()!;
  TextTheme get text => Theme.of(this).textTheme;
  double get width => MediaQuery.sizeOf(this).width;
  bool get isCompact => width < Breakpoints.compact;
  bool get isExpanded => width >= Breakpoints.expanded;
}

/// Linear interpolation helper for animated values.
double lerp(double a, double b, double t) => lerpDouble(a, b, t)!;
