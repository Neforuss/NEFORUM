import 'package:flutter/material.dart';

import 'tokens.dart';

/// 1.4.3: clear selected state. How every chip, segment, pill and swatch
/// shows that it is on, the same way everywhere: a solid fill in
/// [NfSelection.selectedFill] with white content and a check mark, against
/// the surface color when it is off.
///
/// The selected fill keeps at least 3:1 (WCAG non-text contrast) against
/// every surface a control sits on (page, card, sheet, well) and white text
/// at least 4.5:1 on it, in both themes and with any accent, the user's own
/// color included. So on and off differ at a glance, not by a faint tint.
extension NfSelection on NfColors {
  /// The fill of a selected control: the accent, shaded where needed.
  Color get selectedFill => _selectedFills[this] ??= selectedFillFor(accentFill, isDark: isDark);

  /// Text, icons and the check mark on [selectedFill].
  Color get onSelectedFill => Colors.white;

  /// The border of a control that is off: strong enough to show its edge.
  Color get unselectedBorder => borderStrong;
}

final Expando<Color> _selectedFills = Expando('selectedFill');

/// The brightest surface a selectable control sits on in the dark theme
/// (sheets and dialogs).
const Color _darkRaisedSurface = Color(0xFF1D1729);

/// The light theme's darkest surface (wells, the unselected segments).
const Color _lightSunkenSurface = Color(0xFFEFEBF6);

/// The selected fill for an accent's [accentFill].
///
/// First darkened, if needed, until white text on it passes WCAG AA (4.5:1)
/// ([accentShadesOf]): some preset accents, Ocean and Amber, are a little
/// light for it. In the light theme that fill then stands well over 3:1 off
/// every light surface. In the dark theme it can be too dark to tell from
/// the dark surfaces (the brand purple is 2.1:1), so it is lightened just
/// until it reaches 3:1 on the brightest of them: white text still reads on
/// it, because 3:1 there is reached well below the luminance where white
/// drops under 4.5:1.
Color selectedFillFor(Color accentFill, {required bool isDark}) {
  final fill = accentShadesOf(accentFill).light;
  final against = isDark ? _darkRaisedSurface : _lightSunkenSurface;
  if (contrastRatio(fill, against) >= 3.05) return fill;
  // Toward white when the surface is dark, toward black when it is light.
  final toward = isDark ? Colors.white : Colors.black;
  var low = 0.0, high = 1.0;
  for (var i = 0; i < 24; i++) {
    final mid = (low + high) / 2;
    if (contrastRatio(Color.lerp(fill, toward, mid)!, against) >= 3.05) {
      high = mid;
    } else {
      low = mid;
    }
  }
  return Color.lerp(fill, toward, high)!;
}

/// Chips (FilterChip, ChoiceChip, InputChip, ActionChip): off is the surface
/// with a visible border, on is the [NfSelection.selectedFill] with white
/// text and a check mark. A chip with an avatar gets the check over it, so
/// chips whose avatar only illustrates the label leave it out while selected
/// (`avatar: selected ? null : icon`), and the check takes its place.
ChipThemeData selectionChipTheme(NfColors c, TextTheme text, {required bool dense}) {
  final fill = c.selectedFill;
  // The three colors, not one `color` property: a chip that sets its own
  // background (the composer's schedule chip) keeps it. A selected chip
  // that is disabled keeps the fill, so it still reads as on.
  return ChipThemeData(
    backgroundColor: c.surface,
    selectedColor: fill,
    disabledColor: c.surfaceSunken,
    side: WidgetStateBorderSide.resolveWith((s) {
      if (s.contains(WidgetState.selected)) return BorderSide(color: fill);
      return BorderSide(color: s.contains(WidgetState.disabled) ? c.border : c.unselectedBorder);
    }),
    shape: RoundedRectangleBorder(borderRadius: Radii.rPill),
    labelStyle: text.labelMedium?.copyWith(
      color: WidgetStateColor.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return c.onSelectedFill;
        return s.contains(WidgetState.disabled) ? c.textFaint : c.text;
      }),
    ),
    secondaryLabelStyle: text.labelMedium?.copyWith(color: c.onSelectedFill),
    padding: EdgeInsets.symmetric(horizontal: Space.sm, vertical: dense ? Space.xxs : Space.xs),
    checkmarkColor: c.onSelectedFill,
    showCheckmark: true,
  );
}

/// Segmented buttons: the chosen segment in the [NfSelection.selectedFill]
/// with white text, the others on the surface.
SegmentedButtonThemeData selectionSegmentedButtonTheme(NfColors c, TextTheme text, {required bool dense}) {
  final fill = c.selectedFill;
  final disabledFill = Color.alphaBlend(fill.withValues(alpha: 0.45), c.surface);
  return SegmentedButtonThemeData(
    style: ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((s) {
        final selected = s.contains(WidgetState.selected), disabled = s.contains(WidgetState.disabled);
        if (selected) return disabled ? disabledFill : fill;
        return disabled ? c.surfaceSunken : c.surface;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return c.onSelectedFill;
        return s.contains(WidgetState.disabled) ? c.textFaint : c.textMuted;
      }),
      iconColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return c.onSelectedFill;
        return s.contains(WidgetState.disabled) ? c.textFaint : c.textMuted;
      }),
      overlayColor: WidgetStateProperty.resolveWith((s) => (s.contains(WidgetState.selected) ? c.onSelectedFill : c.text).withValues(alpha: 0.08)),
      side: WidgetStateProperty.resolveWith((s) => BorderSide(color: s.contains(WidgetState.disabled) ? c.border : c.unselectedBorder)),
      textStyle: WidgetStateProperty.all(text.labelMedium),
      shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: Radii.rSm)),
      padding: WidgetStateProperty.all(EdgeInsets.symmetric(horizontal: Space.md, vertical: dense ? Space.xs : Space.sm)),
    ),
    selectedIcon: const SizedBox.shrink(),
  );
}
