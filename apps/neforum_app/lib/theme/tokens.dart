import 'dart:math' as math;
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

/// Corner radii. With the square corner style (Settings → Appearance →
/// Corners) every radius is 0, pills and avatars included.
///
/// [square] is set by `buildTheme` from the setting. Changing the style
/// builds a new theme, so every widget that reads the theme (all of them, via
/// `context.nf`) rebuilds and picks up the new values. Images NEFORUM
/// generates for posting (text cards, captions) never use these.
abstract final class Radii {
  static bool square = false;

  static double get xs => square ? 0 : 6;
  static double get sm => square ? 0 : 10;
  static double get md => square ? 0 : 14;
  static double get lg => square ? 0 : 20;
  static double get xl => square ? 0 : 28;
  static double get pill => square ? 0 : 999;

  static const BorderRadius _xs = BorderRadius.all(Radius.circular(6));
  static const BorderRadius _sm = BorderRadius.all(Radius.circular(10));
  static const BorderRadius _md = BorderRadius.all(Radius.circular(14));
  static const BorderRadius _lg = BorderRadius.all(Radius.circular(20));
  static const BorderRadius _xl = BorderRadius.all(Radius.circular(28));
  static const BorderRadius _pill = BorderRadius.all(Radius.circular(999));

  static BorderRadius get rXs => square ? BorderRadius.zero : _xs;
  static BorderRadius get rSm => square ? BorderRadius.zero : _sm;
  static BorderRadius get rMd => square ? BorderRadius.zero : _md;
  static BorderRadius get rLg => square ? BorderRadius.zero : _lg;
  static BorderRadius get rXl => square ? BorderRadius.zero : _xl;
  static BorderRadius get rPill => square ? BorderRadius.zero : _pill;

  /// [radius], or 0 with square corners (sizes that scale with a widget).
  static double corner(double radius) => square ? 0 : radius;

  /// `BorderRadius.circular(radius)` that follows the corner style.
  static BorderRadius circular(double radius) => square ? BorderRadius.zero : BorderRadius.circular(radius);

  /// Avatars, round buttons and swatches: circles, or squares with square
  /// corners. Small status dots stay round ([BoxShape.circle]).
  static BoxShape get circleShape => square ? BoxShape.rectangle : BoxShape.circle;

  /// [CircleBorder] that follows the corner style.
  static OutlinedBorder get circleBorder => square ? const RoundedRectangleBorder() : const CircleBorder();

  /// [StadiumBorder] (pill buttons, chips) that follows the corner style.
  static OutlinedBorder get stadium => square ? const RoundedRectangleBorder() : const StadiumBorder();
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
  amber('Amber', Color(0xFFC77800), Color(0xFFFFB02E)),

  /// The user's own color (the `customAccentColor` setting). The shades here
  /// are used only while no color has been chosen.
  custom('Custom', Brand.purple, Color(0xFF9D4DFF));

  const AccentChoice(this.label, this.light, this.dark);
  final String label;

  /// Accent used on light backgrounds, and the fill of accent buttons in
  /// both themes (white text on it passes WCAG AA).
  final Color light;

  /// Accent for text and icons on dark backgrounds (a touch brighter for
  /// contrast).
  final Color dark;

  /// The fixed choices, shown as swatches.
  static List<AccentChoice> get presets => [for (final a in values) if (a != custom) a];

  /// This choice's two shades; [customColor] (ARGB) is used by [custom].
  AccentShades shades([int? customColor]) {
    if (this != custom || customColor == null) return (light: light, dark: dark);
    return accentShadesOf(Color(customColor));
  }
}

/// An accent's two shades, as in [AccentChoice.light] and [AccentChoice.dark].
typedef AccentShades = ({Color light, Color dark});

/// The shades of any [color]: the light shade is darkened until white text on
/// it passes WCAG AA (4.5:1), the dark shade lightened until it passes on the
/// dark theme's cards. Transparency is ignored.
AccentShades accentShadesOf(Color color) {
  final base = color.withValues(alpha: 1);
  Color adjust(Color toward, bool Function(Color) passes) {
    for (var step = 0; step < 25; step++) {
      final c = Color.lerp(base, toward, step / 25)!;
      if (passes(c)) return c;
    }
    return toward;
  }

  return (
    light: adjust(Colors.black, (c) => contrastRatio(c, Colors.white) >= 4.5),
    dark: adjust(Colors.white, (c) => contrastRatio(c, NfColors.darkSurface) >= 4.5),
  );
}

/// WCAG contrast ratio of two opaque colors (1 to 21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// White or [Brand.ink], whichever reads better on [background].
Color readableOn(Color background) =>
    contrastRatio(Colors.white, background) >= contrastRatio(Brand.ink, background) ? Colors.white : Brand.ink;

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
    required this.chromeBorder,
    required this.chromeAccent,
    required this.onChromeAccent,
    required this.chromeSelected,
    required this.chromeUrgent,
    required this.onChromeUrgent,
    required this.chromeActionGradient,
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

  /// Navigation chrome (sidebar, rail, bottom bar). By default deep purple in
  /// both themes, with white content and yellow for the current section;
  /// Settings → Appearance can make it follow the theme ([withThemeChrome])
  /// or the accent ([withAccentChrome]).
  final Color chrome;

  /// A card or selected row on the chrome.
  final Color chromeRaised;
  final Color onChrome;
  final Color onChromeMuted;

  /// The line between the chrome and the page (transparent when the chrome's
  /// own color sets it apart).
  final Color chromeBorder;

  /// Fill marking the current section (rail and bottom bar) and the New post
  /// button on the chrome, behind [onChromeAccent].
  final Color chromeAccent;
  final Color onChromeAccent;

  /// Icon and bar of the current section in the sidebar, on [chromeRaised].
  final Color chromeSelected;

  /// Fill of a count on the chrome that needs the user (Activity's), behind
  /// [onChromeUrgent]: yellow on the brand chrome and on an accent chrome it
  /// stands out from, amber on a chrome in the page colors.
  final Color chromeUrgent;
  final Color onChromeUrgent;

  /// Fill of `PrimaryAction(onChrome: true)`, behind [onChromeAccent].
  final LinearGradient chromeActionGradient;
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

  /// The dark theme's card color, which accents must read on.
  static const Color darkSurface = Color(0xFF15101F);

  /// Yellow call to action on the purple chrome.
  static final LinearGradient _yellowAction = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Brand.yellow, Color.lerp(Brand.yellow, const Color(0xFFFFB800), 0.35)!],
  );

  /// [customAccent] (ARGB) is the user's own color for [AccentChoice.custom].
  static NfColors light(AccentChoice accent, {int? customAccent}) {
    final a = accent.shades(customAccent).light;
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
      chromeBorder: Colors.transparent,
      chromeAccent: Brand.yellow,
      onChromeAccent: Brand.ink,
      chromeSelected: Brand.yellow,
      chromeUrgent: Brand.yellow,
      onChromeUrgent: Brand.ink,
      chromeActionGradient: _yellowAction,
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

  static NfColors dark(AccentChoice accent, {int? customAccent}) {
    final shades = accent.shades(customAccent);
    final a = shades.dark;
    return NfColors(
      bg: const Color(0xFF0D0916),
      surface: darkSurface,
      surfaceRaised: const Color(0xFF1D1729),
      surfaceSunken: const Color(0xFF100C19),
      surfaceHover: const Color(0xFF1B1526),
      border: const Color(0xFF2A2338),
      borderStrong: const Color(0xFF3B3250),
      text: const Color(0xFFF4F1FA),
      textMuted: const Color(0xFFADA5C0),
      textFaint: const Color(0xFF766E8A),
      accent: a,
      accentFill: shades.light,
      accentSoft: Color.alphaBlend(a.withValues(alpha: 0.16), darkSurface),
      onAccent: Colors.white,
      highlight: Brand.yellow,
      onHighlight: Brand.ink,
      chrome: const Color(0xFF110524),
      chromeRaised: const Color(0xFF211040),
      onChrome: Colors.white,
      onChromeMuted: const Color(0xFFAA9DC6),
      chromeBorder: Colors.transparent,
      chromeAccent: Brand.yellow,
      onChromeAccent: Brand.ink,
      chromeSelected: Brand.yellow,
      chromeUrgent: Brand.yellow,
      onChromeUrgent: Brand.ink,
      chromeActionGradient: _yellowAction,
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
      brandGradient: _gradientFor(shades.light),
      isDark: true,
    );
  }

  /// The chrome in the page's own colors: light in the light theme, dark in
  /// the dark theme, set apart by a hairline, with the accent (never yellow,
  /// which has no contrast on light surfaces) for the current section and
  /// the warning amber for counts that need the user.
  NfColors withThemeChrome() => _withChrome(
        chrome: surface,
        chromeRaised: accentSoft,
        onChrome: text,
        onChromeMuted: textMuted,
        chromeBorder: border,
        chromeAccent: accentFill,
        onChromeAccent: readableOn(accentFill),
        chromeSelected: accent,
        chromeUrgent: warning,
        onChromeUrgent: readableOn(warning),
        chromeActionGradient: brandGradient,
      );

  /// The chrome in the accent color (a deeper shade in the dark theme), with
  /// white or ink content, whichever reads better on it. An accent on which
  /// neither passes WCAG AA is darkened until white does.
  NfColors withAccentChrome() {
    var fill = isDark ? Color.lerp(accentFill, Colors.black, 0.3)! : accentFill;
    var content = readableOn(fill);
    if (contrastRatio(content, fill) < 4.5) {
      fill = accentShadesOf(fill).light;
      content = Colors.white;
    }
    // Unselected destinations: the content faded toward the fill, but only as
    // far as WCAG AA (4.5:1) allows. The content itself always passes.
    final faded = Color.alphaBlend(content.withValues(alpha: 0.74), fill);
    var muted = content;
    for (var step = 0; step < 13; step++) {
      final c = Color.lerp(faded, content, step / 13)!;
      if (contrastRatio(c, fill) >= 4.5) {
        muted = c;
        break;
      }
    }
    final yellowStandsOut = contrastRatio(highlight, fill) >= 3;
    return _withChrome(
      chrome: fill,
      chromeRaised: Color.alphaBlend(content.withValues(alpha: 0.14), fill),
      onChrome: content,
      onChromeMuted: muted,
      chromeBorder: Colors.transparent,
      chromeAccent: content,
      onChromeAccent: fill,
      chromeSelected: content,
      chromeUrgent: yellowStandsOut ? highlight : content,
      onChromeUrgent: yellowStandsOut ? onHighlight : fill,
      chromeActionGradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [content, Color.alphaBlend(fill.withValues(alpha: 0.1), content)],
      ),
    );
  }

  /// Stronger text and borders, for the system's high contrast setting:
  /// muted text reaches WCAG AAA (7:1) on the page and on cards, faint text
  /// AA (4.5:1), and borders 3:1, so every edge of a control shows. Status
  /// colors reach AA on their own tints (the pills).
  NfColors withHighContrast() => NfColors(
        bg: bg,
        surface: surface,
        surfaceRaised: surfaceRaised,
        surfaceSunken: surfaceSunken,
        surfaceHover: surfaceHover,
        border: isDark ? const Color(0xFF7A7094) : const Color(0xFF857D99),
        borderStrong: isDark ? const Color(0xFFA49BBD) : const Color(0xFF5B5270),
        text: isDark ? const Color(0xFFFFFFFF) : const Color(0xFF0B0418),
        textMuted: isDark ? const Color(0xFFDCD6E8) : const Color(0xFF3A3150),
        textFaint: isDark ? const Color(0xFFB4ACC8) : const Color(0xFF574E6B),
        accent: accent,
        accentFill: accentFill,
        accentSoft: accentSoft,
        onAccent: onAccent,
        highlight: highlight,
        onHighlight: onHighlight,
        chrome: chrome,
        chromeRaised: chromeRaised,
        onChrome: onChrome,
        onChromeMuted: Color.lerp(onChromeMuted, onChrome, 0.5)!,
        chromeBorder: chromeBorder.a == 0 ? chromeBorder : (isDark ? const Color(0xFF7A7094) : const Color(0xFF857D99)),
        chromeAccent: chromeAccent,
        onChromeAccent: onChromeAccent,
        chromeSelected: chromeSelected,
        chromeUrgent: chromeUrgent,
        onChromeUrgent: onChromeUrgent,
        chromeActionGradient: chromeActionGradient,
        // The dark theme's status colors already pass on their tints.
        success: isDark ? success : const Color(0xFF0A7A4B),
        successSoft: successSoft,
        warning: isDark ? warning : const Color(0xFF8F5A00),
        warningSoft: warningSoft,
        danger: isDark ? danger : const Color(0xFFB3261E),
        dangerSoft: dangerSoft,
        info: isDark ? info : const Color(0xFF1E5BB8),
        infoSoft: infoSoft,
        shadow: shadow,
        scrim: scrim,
        brandGradient: brandGradient,
        isDark: isDark,
      );

  NfColors _withChrome({
    required Color chrome,
    required Color chromeRaised,
    required Color onChrome,
    required Color onChromeMuted,
    required Color chromeBorder,
    required Color chromeAccent,
    required Color onChromeAccent,
    required Color chromeSelected,
    required Color chromeUrgent,
    required Color onChromeUrgent,
    required LinearGradient chromeActionGradient,
  }) =>
      NfColors(
        bg: bg,
        surface: surface,
        surfaceRaised: surfaceRaised,
        surfaceSunken: surfaceSunken,
        surfaceHover: surfaceHover,
        border: border,
        borderStrong: borderStrong,
        text: text,
        textMuted: textMuted,
        textFaint: textFaint,
        accent: accent,
        accentFill: accentFill,
        accentSoft: accentSoft,
        onAccent: onAccent,
        highlight: highlight,
        onHighlight: onHighlight,
        chrome: chrome,
        chromeRaised: chromeRaised,
        onChrome: onChrome,
        onChromeMuted: onChromeMuted,
        chromeBorder: chromeBorder,
        chromeAccent: chromeAccent,
        onChromeAccent: onChromeAccent,
        chromeSelected: chromeSelected,
        chromeUrgent: chromeUrgent,
        onChromeUrgent: onChromeUrgent,
        chromeActionGradient: chromeActionGradient,
        success: success,
        successSoft: successSoft,
        warning: warning,
        warningSoft: warningSoft,
        danger: danger,
        dangerSoft: dangerSoft,
        info: info,
        infoSoft: infoSoft,
        shadow: shadow,
        scrim: scrim,
        brandGradient: brandGradient,
        isDark: isDark,
      );

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
      chromeBorder: l(chromeBorder, other.chromeBorder),
      chromeAccent: l(chromeAccent, other.chromeAccent),
      onChromeAccent: l(onChromeAccent, other.onChromeAccent),
      chromeSelected: l(chromeSelected, other.chromeSelected),
      chromeUrgent: l(chromeUrgent, other.chromeUrgent),
      onChromeUrgent: l(onChromeUrgent, other.onChromeUrgent),
      chromeActionGradient: LinearGradient.lerp(chromeActionGradient, other.chromeActionGradient, t)!,
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

  /// The compact density (Settings → Appearance → Density): tighter spacing.
  bool get denseLayout => Theme.of(this).visualDensity == VisualDensity.compact;

  /// The system asks for less motion (Android "Remove animations", iOS and
  /// macOS "Reduce motion", Windows "Animation effects" off): no page
  /// transitions and no decorative animation.
  bool get reduceMotion => MediaQuery.maybeDisableAnimationsOf(this) ?? false;

  /// [duration], or none when the system asks for less motion.
  Duration motion(Duration duration) => reduceMotion ? Duration.zero : duration;
}

/// Linear interpolation helper for animated values.
double lerp(double a, double b, double t) => lerpDouble(a, b, t)!;
