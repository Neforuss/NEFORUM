import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/settings.dart' show CornerStyle, InterfaceDensity, NavigationChromeStyle;
import 'tokens.dart';

/// Builds the NEFORUM [ThemeData] for one brightness and accent.
///
/// Material 3 widgets are restyled so they read as one calm, editorial
/// system: flat surfaces separated by hairline borders, generous radii,
/// Bricolage Grotesque for display text, Inter for everything else.
///
/// The Appearance settings: [customAccent] (ARGB) is the color of
/// [AccentChoice.custom]; [corners] square sets every radius to 0 (it also
/// sets [Radii.square], which widgets read directly); [chrome] colors the
/// sidebar, rail and bottom bar; [density] compact tightens the spacing.
///
/// [highContrast] (the system's high contrast setting, see
/// `MaterialApp.highContrastTheme`) uses [NfColors.withHighContrast].
ThemeData buildTheme(
  Brightness brightness,
  AccentChoice accent, {
  int? customAccent,
  CornerStyle corners = CornerStyle.rounded,
  NavigationChromeStyle chrome = NavigationChromeStyle.brand,
  InterfaceDensity density = InterfaceDensity.comfortable,
  bool highContrast = false,
}) {
  Radii.square = corners == CornerStyle.square;
  final base = brightness == Brightness.dark ? NfColors.dark(accent, customAccent: customAccent) : NfColors.light(accent, customAccent: customAccent);
  final chromed = switch (chrome) {
    NavigationChromeStyle.brand => base,
    NavigationChromeStyle.theme => base.withThemeChrome(),
    NavigationChromeStyle.accent => base.withAccentChrome(),
  };
  final c = highContrast ? chromed.withHighContrast() : chromed;
  final dense = density == InterfaceDensity.compact;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    primaryContainer: c.accentSoft,
    onPrimaryContainer: c.accent,
    secondary: c.text,
    onSecondary: c.bg,
    secondaryContainer: c.surfaceSunken,
    onSecondaryContainer: c.text,
    tertiary: c.highlight,
    onTertiary: c.onHighlight,
    error: c.danger,
    onError: Colors.white,
    errorContainer: c.dangerSoft,
    onErrorContainer: c.danger,
    surface: c.surface,
    onSurface: c.text,
    onSurfaceVariant: c.textMuted,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surfaceRaised,
    surfaceContainerHighest: c.surfaceSunken,
    outline: c.borderStrong,
    outlineVariant: c.border,
    shadow: c.shadow,
    scrim: c.scrim,
    inverseSurface: c.text,
    onInverseSurface: c.bg,
    inversePrimary: c.accent,
    surfaceTint: Colors.transparent,
  );

  final text = _textTheme(c);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    fontFamily: Fonts.body,
    textTheme: text,
    primaryTextTheme: text,
    extensions: [c],
    visualDensity: dense ? VisualDensity.compact : VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    splashFactory: InkSparkle.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: c.surfaceHover,
    focusColor: c.accent.withValues(alpha: 0.12),
    splashColor: c.accent.withValues(alpha: 0.08),
    dividerColor: c.border,
    disabledColor: c.textFaint,

    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
      systemOverlayStyle: c.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),

    cardTheme: CardThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: Radii.rLg, side: BorderSide(color: c.border)),
      clipBehavior: Clip.antiAlias,
    ),

    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),

    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return c.surfaceSunken;
          return c.accentFill;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return c.textFaint;
          return c.onAccent;
        }),
        overlayColor: WidgetStateProperty.all(Colors.white.withValues(alpha: 0.10)),
        textStyle: WidgetStateProperty.all(text.labelLarge),
        padding: WidgetStateProperty.all(EdgeInsets.symmetric(horizontal: dense ? Space.lg : Space.xl, vertical: dense ? Space.sm + 2 : Space.md + 2)),
        minimumSize: WidgetStateProperty.all(Size(64, dense ? 38 : 44)),
        shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: Radii.rMd)),
        elevation: WidgetStateProperty.all(0),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? c.textFaint : c.text),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? c.surfaceHover : c.surface),
        side: WidgetStateProperty.resolveWith((s) => BorderSide(color: s.contains(WidgetState.hovered) ? c.borderStrong : c.border)),
        overlayColor: WidgetStateProperty.all(c.text.withValues(alpha: 0.04)),
        textStyle: WidgetStateProperty.all(text.labelLarge),
        padding: WidgetStateProperty.all(EdgeInsets.symmetric(horizontal: dense ? Space.md + 2 : Space.lg + 2, vertical: dense ? Space.sm + 2 : Space.md + 2)),
        minimumSize: WidgetStateProperty.all(Size(48, dense ? 38 : 44)),
        shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: Radii.rMd)),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? c.textFaint : c.accent),
        overlayColor: WidgetStateProperty.all(c.accent.withValues(alpha: 0.08)),
        textStyle: WidgetStateProperty.all(text.labelLarge),
        padding: WidgetStateProperty.all(EdgeInsets.symmetric(horizontal: Space.md, vertical: dense ? Space.xs + 2 : Space.sm + 2)),
        shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: Radii.rSm)),
      ),
    ),

    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return c.textFaint;
          if (s.contains(WidgetState.selected)) return c.accent;
          return c.textMuted;
        }),
        overlayColor: WidgetStateProperty.all(c.text.withValues(alpha: 0.06)),
        shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: Radii.rSm)),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surfaceSunken,
      hoverColor: Colors.transparent,
      isDense: dense,
      contentPadding: EdgeInsets.symmetric(horizontal: dense ? Space.md : Space.lg, vertical: dense ? Space.sm + 2 : Space.md + 2),
      hintStyle: text.bodyMedium?.copyWith(color: c.textFaint),
      labelStyle: text.bodyMedium?.copyWith(color: c.textMuted),
      floatingLabelStyle: text.bodySmall?.copyWith(color: c.accent, fontWeight: FontWeight.w600),
      helperStyle: text.bodySmall?.copyWith(color: c.textFaint),
      errorStyle: text.bodySmall?.copyWith(color: c.danger),
      prefixIconColor: c.textFaint,
      suffixIconColor: c.textFaint,
      border: OutlineInputBorder(borderRadius: Radii.rMd, borderSide: BorderSide(color: c.border)),
      enabledBorder: OutlineInputBorder(borderRadius: Radii.rMd, borderSide: BorderSide(color: c.border)),
      focusedBorder: OutlineInputBorder(borderRadius: Radii.rMd, borderSide: BorderSide(color: c.accent, width: 1.6)),
      errorBorder: OutlineInputBorder(borderRadius: Radii.rMd, borderSide: BorderSide(color: c.danger)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: Radii.rMd, borderSide: BorderSide(color: c.danger, width: 1.6)),
      disabledBorder: OutlineInputBorder(borderRadius: Radii.rMd, borderSide: BorderSide(color: c.border.withValues(alpha: 0.5))),
    ),

    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.25),
      selectionHandleColor: c.accent,
    ),

    chipTheme: ChipThemeData(
      backgroundColor: c.surface,
      selectedColor: c.accentSoft,
      disabledColor: c.surfaceSunken,
      side: BorderSide(color: c.border),
      shape: RoundedRectangleBorder(borderRadius: Radii.rPill),
      labelStyle: text.labelMedium?.copyWith(color: c.text),
      secondaryLabelStyle: text.labelMedium?.copyWith(color: c.accent),
      padding: EdgeInsets.symmetric(horizontal: Space.sm, vertical: dense ? Space.xxs : Space.xs),
      checkmarkColor: c.accent,
      showCheckmark: false,
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : c.textMuted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accentFill : c.surfaceSunken),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accentFill : c.borderStrong),
      thumbIcon: WidgetStateProperty.all(null),
    ),

    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accentFill : Colors.transparent),
      checkColor: WidgetStateProperty.all(Colors.white),
      side: BorderSide(color: c.borderStrong, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: Radii.rXs),
    ),

    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.borderStrong),
    ),

    sliderTheme: SliderThemeData(
      activeTrackColor: c.accent,
      inactiveTrackColor: c.surfaceSunken,
      thumbColor: c.accent,
      overlayColor: c.accent.withValues(alpha: 0.12),
      trackHeight: 4,
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.surfaceSunken,
      circularTrackColor: c.surfaceSunken,
      linearMinHeight: 6,
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.surface : c.surfaceSunken),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.text : c.textMuted),
        side: WidgetStateProperty.all(BorderSide(color: c.border)),
        textStyle: WidgetStateProperty.all(text.labelMedium),
        shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: Radii.rSm)),
        padding: WidgetStateProperty.all(EdgeInsets.symmetric(horizontal: Space.md, vertical: dense ? Space.xs : Space.sm)),
      ),
      selectedIcon: const SizedBox.shrink(),
    ),

    listTileTheme: ListTileThemeData(
      iconColor: c.textMuted,
      textColor: c.text,
      titleTextStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      subtitleTextStyle: text.bodySmall?.copyWith(color: c.textMuted),
      contentPadding: EdgeInsets.symmetric(horizontal: dense ? Space.md : Space.lg, vertical: dense ? 0 : Space.xs),
      shape: RoundedRectangleBorder(borderRadius: Radii.rMd),
      minVerticalPadding: dense ? Space.sm : Space.md,
      selectedColor: c.accent,
      selectedTileColor: c.accentSoft,
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: c.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: Radii.rXl, side: BorderSide(color: c.border)),
      titleTextStyle: text.headlineSmall,
      contentTextStyle: text.bodyMedium?.copyWith(color: c.textMuted),
      barrierColor: c.scrim,
      insetPadding: const EdgeInsets.all(Space.xxl),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: c.surfaceRaised,
      modalBarrierColor: c.scrim,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: true,
      dragHandleColor: c.borderStrong,
      dragHandleSize: const Size(40, 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl))),
      clipBehavior: Clip.antiAlias,
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.text,
      contentTextStyle: text.bodyMedium?.copyWith(color: c.bg),
      actionTextColor: c.isDark ? c.accent.withValues(alpha: 1) : c.accent,
      shape: RoundedRectangleBorder(borderRadius: Radii.rMd),
      elevation: 0,
      insetPadding: const EdgeInsets.all(Space.lg),
      width: null,
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.text, borderRadius: Radii.rSm),
      textStyle: text.labelSmall?.copyWith(color: c.bg),
      padding: const EdgeInsets.symmetric(horizontal: Space.sm + 2, vertical: Space.xs + 2),
      waitDuration: const Duration(milliseconds: 450),
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: c.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: Radii.rMd, side: BorderSide(color: c.border)),
      textStyle: text.bodyMedium,
      menuPadding: const EdgeInsets.all(Space.xs),
    ),

    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(c.surfaceRaised),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        elevation: WidgetStateProperty.all(0),
        side: WidgetStateProperty.all(BorderSide(color: c.border)),
        shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: Radii.rMd)),
        padding: WidgetStateProperty.all(const EdgeInsets.all(Space.xs)),
      ),
    ),

    // The phone bottom bar is navigation chrome: deep purple and yellow for
    // the current section by default (see NfColors.chrome).
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.chrome,
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.chromeAccent,
      indicatorShape: Radii.stadium,
      elevation: 0,
      height: dense ? 60 : 68,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => text.labelSmall?.copyWith(
            color: s.contains(WidgetState.selected) ? c.onChrome : c.onChromeMuted,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? c.onChromeAccent : c.onChromeMuted,
            size: 22,
          )),
    ),

    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(c.borderStrong),
      radius: Radius.circular(Radii.corner(8)),
      thickness: WidgetStateProperty.all(6),
      crossAxisMargin: 2,
    ),

    tabBarTheme: TabBarThemeData(
      labelColor: c.text,
      unselectedLabelColor: c.textFaint,
      labelStyle: text.labelLarge,
      unselectedLabelStyle: text.labelLarge,
      indicatorColor: c.accent,
      dividerColor: c.border,
      indicatorSize: TabBarIndicatorSize.label,
      overlayColor: WidgetStateProperty.all(Colors.transparent),
    ),

    datePickerTheme: DatePickerThemeData(
      backgroundColor: c.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: Radii.rXl, side: BorderSide(color: c.border)),
      headerBackgroundColor: c.surfaceRaised,
      headerForegroundColor: c.text,
      dayShape: WidgetStateProperty.all(Radii.circleBorder),
      todayBorder: BorderSide(color: c.accent),
    ),

    timePickerTheme: TimePickerThemeData(
      backgroundColor: c.surfaceRaised,
      shape: RoundedRectangleBorder(borderRadius: Radii.rXl, side: BorderSide(color: c.border)),
      hourMinuteShape: RoundedRectangleBorder(borderRadius: Radii.rMd),
      dayPeriodShape: RoundedRectangleBorder(borderRadius: Radii.rSm),
      dialBackgroundColor: c.surfaceSunken,
    ),

    badgeTheme: BadgeThemeData(backgroundColor: c.highlight, textColor: c.onHighlight),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}

/// Page transitions with no motion: the new page is simply there. For the
/// system's reduce motion setting ([withReducedMotion]).
class ImmediatePageTransitionsBuilder extends PageTransitionsBuilder {
  const ImmediatePageTransitionsBuilder();

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) =>
      child;
}

/// [theme] without page transitions, for when the system asks for less
/// motion (`MediaQuery.disableAnimations`).
ThemeData withReducedMotion(ThemeData theme) => theme.copyWith(pageTransitionsTheme: _immediateTransitions);

final PageTransitionsTheme _immediateTransitions = PageTransitionsTheme(builders: {
  for (final platform in TargetPlatform.values) platform: const ImmediatePageTransitionsBuilder(),
});

TextTheme _textTheme(NfColors c) {
  TextStyle display(double size, FontWeight w, {double ls = -0.5, double h = 1.08}) => TextStyle(
        fontFamily: Fonts.display,
        fontSize: size,
        fontWeight: w,
        letterSpacing: ls,
        height: h,
        color: c.text,
      );
  TextStyle body(double size, FontWeight w, {double ls = 0, double h = 1.45, Color? color}) => TextStyle(
        fontFamily: Fonts.body,
        fontSize: size,
        fontWeight: w,
        letterSpacing: ls,
        height: h,
        color: color ?? c.text,
      );
  return TextTheme(
    displayLarge: display(56, FontWeight.w800, ls: -1.6, h: 1.0),
    displayMedium: display(44, FontWeight.w800, ls: -1.2, h: 1.02),
    displaySmall: display(34, FontWeight.w700, ls: -0.8),
    headlineLarge: display(30, FontWeight.w700, ls: -0.6),
    headlineMedium: display(25, FontWeight.w700, ls: -0.4),
    headlineSmall: display(21, FontWeight.w700, ls: -0.3, h: 1.15),
    titleLarge: display(18, FontWeight.w700, ls: -0.2, h: 1.2),
    titleMedium: body(15, FontWeight.w600, ls: -0.1, h: 1.3),
    titleSmall: body(13.5, FontWeight.w600, h: 1.3),
    bodyLarge: body(15.5, FontWeight.w400, h: 1.5),
    bodyMedium: body(14, FontWeight.w400, h: 1.45),
    bodySmall: body(12.5, FontWeight.w400, h: 1.4, color: c.textMuted),
    labelLarge: body(14, FontWeight.w600, ls: 0.1, h: 1.2),
    labelMedium: body(12.5, FontWeight.w600, ls: 0.1, h: 1.2),
    labelSmall: body(11, FontWeight.w600, ls: 0.4, h: 1.2),
  );
}

/// Monospace style for counters, tokens and code.
TextStyle monoStyle(BuildContext context, {double size = 12.5, Color? color, FontWeight weight = FontWeight.w400}) =>
    TextStyle(
      fontFamily: Fonts.mono,
      fontSize: size,
      fontWeight: weight,
      color: color ?? context.nf.textMuted,
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.3,
    );
