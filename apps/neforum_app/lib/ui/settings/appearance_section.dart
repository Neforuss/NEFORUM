import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/env.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../theme/tokens.dart';
import '../../theme/zoom.dart';
import '../../widgets/color_wheel.dart';
import 'setting_row.dart';

class AppearanceSettingsSection extends ConsumerWidget {
  const AppearanceSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    // Large text on a phone: segment labels without icons, so they fit.
    final icons = !context.isCompact || MediaQuery.textScalerOf(context).scale(10) <= 11;
    Icon? icon(IconData data) => icons ? Icon(data, size: 18) : null;
    return SettingsSection(title: 'Appearance', icon: Icons.palette_outlined, children: [
      SettingRow(
        title: 'Theme',
        stackOnCompact: true,
        trailing: SegmentedButton<ThemeMode>(
          segments: [
            ButtonSegment(value: ThemeMode.system, label: const Text('System'), icon: icon(Icons.brightness_auto_outlined)),
            ButtonSegment(value: ThemeMode.light, label: const Text('Light'), icon: icon(Icons.light_mode_outlined)),
            ButtonSegment(value: ThemeMode.dark, label: const Text('Dark'), icon: icon(Icons.dark_mode_outlined)),
          ],
          selected: {s.themeMode},
          onSelectionChanged: (v) => n.update((x) => x.copyWith(themeMode: v.first)),
          showSelectedIcon: false,
        ),
      ),
      SettingRow(
        title: 'Accent color',
        description: 'Used for highlights and the main button.',
        stackOnCompact: true,
        trailing: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          for (final a in AccentChoice.presets)
            _Swatch(
              tooltip: a.label,
              color: context.nf.isDark ? a.dark : a.light,
              selected: s.accent == a,
              onTap: () => n.update((x) => x.copyWith(accent: a)),
            ),
          _Swatch(
            tooltip: s.customAccentColor == null ? 'Choose your own color' : 'Your color (${hexColor(s.customAccentColor!)})',
            color: s.customAccentColor == null ? null : Color(s.customAccentColor!),
            selected: s.accent == AccentChoice.custom,
            onTap: () async {
              final picked = await showDialog<int>(context: context, builder: (_) => CustomAccentDialog(initial: s.customAccentColor));
              if (picked != null) await n.update((x) => x.copyWith(accent: AccentChoice.custom, customAccentColor: picked));
            },
          ),
        ]),
      ),
      SettingChoice<NavigationChromeStyle>(
        title: 'Navigation bar',
        description: 'The sidebar, the rail beside the page and the tab bar on phones.',
        value: s.navigationChrome,
        options: const [
          (NavigationChromeStyle.brand, 'NEFORUM purple', 'Deep purple in both themes.'),
          (NavigationChromeStyle.theme, 'Match the theme', 'Light in the light theme, dark in the dark theme.'),
          (NavigationChromeStyle.accent, 'Your accent color', 'The accent color chosen above.'),
        ],
        onChanged: (v) => n.update((x) => x.copyWith(navigationChrome: v)),
      ),
      SettingRow(
        title: 'Corners',
        description: 'Square makes every corner sharp: cards, buttons, menus and pictures.',
        stackOnCompact: true,
        trailing: SegmentedButton<CornerStyle>(
          segments: [
            ButtonSegment(value: CornerStyle.rounded, label: const Text('Rounded'), icon: icon(Icons.rounded_corner_rounded)),
            ButtonSegment(value: CornerStyle.square, label: const Text('Square'), icon: icon(Icons.crop_square_rounded)),
          ],
          selected: {s.cornerStyle},
          onSelectionChanged: (v) => n.update((x) => x.copyWith(cornerStyle: v.first)),
          showSelectedIcon: false,
        ),
      ),
      SettingRow(
        title: 'Density',
        description: 'Compact puts less space around things, so more fits on the screen.',
        stackOnCompact: true,
        trailing: SegmentedButton<InterfaceDensity>(
          segments: const [
            ButtonSegment(value: InterfaceDensity.comfortable, label: Text('Comfortable')),
            ButtonSegment(value: InterfaceDensity.compact, label: Text('Compact')),
          ],
          selected: {s.interfaceDensity},
          onSelectionChanged: (v) => n.update((x) => x.copyWith(interfaceDensity: v.first)),
          showSelectedIcon: false,
        ),
      ),
      if (Env.isMobile) const _TextSize(),
      SettingSwitch(
        title: 'Compact previews',
        description: 'Smaller preview cards in the composer, so more of them fit on the screen.',
        value: s.compactPreviews,
        onChanged: (v) => n.update((x) => x.copyWith(compactPreviews: v)),
      ),
      if (Env.isDesktop) const _Zoom(),
    ]);
  }
}

/// A round accent swatch (square with square corners). [color] null shows
/// the "choose a color" palette.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.tooltip, required this.color, required this.selected, required this.onTap});

  final String tooltip;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final fill = color;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        child: InkWell(
          customBorder: Radii.circleBorder,
          onTap: onTap,
          child: AnimatedContainer(
            duration: Motion.fast,
            width: 30,
            height: 30,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(shape: Radii.circleShape, border: Border.all(color: selected ? nf.text : Colors.transparent, width: 2)),
            child: Container(
              decoration: BoxDecoration(
                color: fill,
                gradient: fill == null ? const SweepGradient(colors: [Color(0xFFF2542D), Color(0xFFC77800), Color(0xFF0F9F6E), Color(0xFF1677FF), Color(0xFF7D00FF), Color(0xFFD6338A), Color(0xFFF2542D)]) : null,
                shape: Radii.circleShape,
              ),
              child: selected
                  ? Icon(Icons.check_rounded, size: 14, color: fill == null ? Colors.white : readableOn(fill))
                  : (fill == null ? const Icon(Icons.add_rounded, size: 14, color: Colors.white) : null),
            ),
          ),
        ),
      ),
    );
  }
}

/// `#RRGGBB` of an ARGB color.
String hexColor(int argb) => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// An opaque ARGB color from `#RRGGBB` or `#RGB` (the `#` is optional), or
/// null when [input] is not one.
int? parseHexColor(String input) {
  var hex = input.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (!RegExp(r'^([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').hasMatch(hex)) return null;
  if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
  return 0xFF000000 | int.parse(hex, radix: 16);
}

/// Picks the user's own accent color: a preset swatch or a hex code. Returns
/// the ARGB color, or null when cancelled.
class CustomAccentDialog extends StatefulWidget {
  const CustomAccentDialog({super.key, this.initial});

  final int? initial;

  /// Starting points; any color works, NEFORUM adjusts it for contrast.
  static const presets = <int>[
    0xFF7D00FF, 0xFF5B3CC4, 0xFF3F51B5, 0xFF1677FF, 0xFF0288D1, 0xFF00838F, //
    0xFF0F9F6E, 0xFF2E7D32, 0xFF7CB342, 0xFFF9A825, 0xFFC77800, 0xFFEF6C00, //
    0xFFF2542D, 0xFFD32F2F, 0xFFD6338A, 0xFF8E24AA, 0xFF6D4C41, 0xFF546E7A, //
  ];

  @override
  State<CustomAccentDialog> createState() => _CustomAccentDialogState();
}

class _CustomAccentDialogState extends State<CustomAccentDialog> {
  late int? _color = widget.initial;
  late final _hex = TextEditingController(text: widget.initial == null ? '' : hexColor(widget.initial!));
  String? _error;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  /// A swatch or the color wheel: the hex field follows.
  void _pick(int color) => setState(() {
        _color = color;
        _error = null;
        final hex = hexColor(color);
        _hex.value = TextEditingValue(text: hex, selection: TextSelection.collapsed(offset: hex.length));
      });

  void _typed(String text) => setState(() {
        final parsed = parseHexColor(text);
        _error = parsed == null && text.trim().isNotEmpty ? 'Use six hex digits, like #7D00FF.' : null;
        if (parsed != null) _color = parsed;
      });

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final color = _color;
    final shades = color == null ? null : accentShadesOf(Color(color));
    // The readability adjustment changed what the preview shows.
    final adjusted = color != null &&
        shades != null &&
        (shades.light.toARGB32() != (color | 0xFF000000) || (nf.isDark && shades.dark.toARGB32() != (color | 0xFF000000)));
    final wheel = ColorWheel(
      color: Color(color ?? CustomAccentDialog.presets.first),
      diameter: context.isCompact ? 180 : 164,
      onChanged: (c) => _pick(c.toARGB32()),
    );
    final details = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _hex,
        decoration: InputDecoration(labelText: 'Hex color', hintText: '#7D00FF', errorText: _error),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')), LengthLimitingTextInputFormatter(7)],
        onChanged: _typed,
      ),
      if (shades != null) ...[
        const SizedBox(height: Space.lg),
        Wrap(spacing: Space.lg, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
            decoration: BoxDecoration(color: shades.light, borderRadius: Radii.rSm),
            child: Text('Button', style: context.text.labelLarge?.copyWith(color: Colors.white)),
          ),
          Text('Link text', style: context.text.labelLarge?.copyWith(color: nf.isDark ? shades.dark : shades.light)),
        ]),
        if (adjusted) ...[
          const SizedBox(height: Space.sm),
          Text('Adjusted a little so text on it and beside it stays readable.', style: context.text.bodySmall),
        ],
      ],
    ]);
    return AlertDialog(
      title: const Text('Your accent color'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pick a color on the wheel or below it, or type its hex code. NEFORUM adjusts it where needed so text stays readable.',
                style: context.text.bodySmall),
            const SizedBox(height: Space.lg),
            Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
              for (final p in CustomAccentDialog.presets)
                _Swatch(tooltip: hexColor(p), color: Color(p), selected: color == p, onTap: () => _pick(p)),
            ]),
            const SizedBox(height: Space.lg),
            if (context.isCompact) ...[
              Center(child: wheel),
              const SizedBox(height: Space.md),
              details,
            ] else
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                wheel,
                const SizedBox(width: Space.lg),
                Expanded(child: Padding(padding: const EdgeInsets.only(top: ColorWheel.margin), child: details)),
              ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
        FilledButton(onPressed: color == null ? null : () => Navigator.pop(context, color), child: const Text('Use this color')),
      ],
    );
  }
}

/// Phones and tablets: NEFORUM's text size on top of the device's own.
class _TextSize extends ConsumerWidget {
  const _TextSize();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(settingsProvider.select((s) => s.mobileTextScale));
    final n = ref.read(settingsProvider.notifier);
    return SettingRow(
      title: 'Text size',
      description: 'Makes text bigger or smaller in NEFORUM, on top of the text size set on this device.',
      below: Row(children: [
        Expanded(
          child: Slider(
            value: scale,
            min: 0.85,
            max: 1.5,
            divisions: 13,
            label: zoomLabel(scale),
            semanticFormatterCallback: zoomLabel,
            // Whole 5% steps, so 100% is exactly 1.
            onChanged: (v) => n.update((x) => x.copyWith(mobileTextScale: validTextScale((v * 20).round() / 20))),
          ),
        ),
        SizedBox(width: 52, child: Text(zoomLabel(scale), textAlign: TextAlign.center, style: context.text.titleSmall)),
        TextButton(onPressed: scale == 1 ? null : () => n.update((x) => x.copyWith(mobileTextScale: 1)), child: const Text('Reset')),
      ]),
    );
  }
}

/// Desktop only: the same steps as Ctrl + / Ctrl − (⌘ on a Mac).
class _Zoom extends ConsumerWidget {
  const _Zoom();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zoom = ref.watch(settingsProvider.select((s) => s.uiZoom));
    final n = ref.read(settingsProvider.notifier);
    final key = Env.isMacOS ? '⌘' : 'Ctrl';
    return SettingRow(
      title: 'Zoom',
      description: 'Makes everything bigger or smaller on this computer. Shortcuts: $key + to zoom in, $key − to zoom out, '
          '$key 0 for 100%, or hold $key and turn the mouse wheel.',
      stackOnCompact: true,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: 'Zoom out',
          onPressed: zoom > kZoomLevels.first ? () => n.update((x) => x.copyWith(uiZoom: zoomOut(x.uiZoom))) : null,
          icon: const Icon(Icons.remove_rounded),
        ),
        SizedBox(width: 56, child: Text(zoomLabel(zoom), textAlign: TextAlign.center, style: context.text.titleSmall)),
        IconButton(
          tooltip: 'Zoom in',
          onPressed: zoom < kZoomLevels.last ? () => n.update((x) => x.copyWith(uiZoom: zoomIn(x.uiZoom))) : null,
          icon: const Icon(Icons.add_rounded),
        ),
        const SizedBox(width: Space.sm),
        TextButton(onPressed: zoom == 1 ? null : () => n.update((x) => x.copyWith(uiZoom: 1)), child: const Text('Reset')),
      ]),
    );
  }
}
