import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../platform/background_images.dart';
import '../../platform/env.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../theme/tokens.dart';
import '../../theme/zoom.dart';
import '../../widgets/color_wheel.dart';
import '../../widgets/layout.dart' show showToast;
import '../../widgets/selection_marks.dart' show swatchCheck;
import '../shell/app_backdrop.dart' show isDecodablePicture;
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
        trailing: Wrap(spacing: Space.sm, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final a in AccentChoice.presets)
            _Swatch(
              tooltip: a.label,
              color: context.nf.isDark ? a.dark : a.light,
              selected: s.accent == a,
              onTap: () => n.update((x) => x.copyWith(accent: a)),
            ),
          // 1.4.3: colours. The color picked before, one tap away.
          if (s.customAccentColor case final own?)
            _Swatch(
              tooltip: 'Your color (${hexColor(own)})',
              color: Color(own),
              selected: s.accent == AccentChoice.custom,
              onTap: () => n.update((x) => x.copyWith(accent: AccentChoice.custom)),
            ),
          // 1.4.3: colours. Any color, on the wheel.
          _CustomColorButton(
            key: const Key('accent-custom-color'),
            onPressed: () async {
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
          (NavigationChromeStyle.custom, 'Your own color', 'Any color, picked on the color wheel. Labels stay readable.'),
          (NavigationChromeStyle.transparent, 'See-through', 'Your background picture, or the page, shows through. Labels stay readable.'),
        ],
        onChanged: (v) async {
          // 1.4.3: colours. Your own color asks for the color first.
          if (v == NavigationChromeStyle.custom && s.navigationChromeColor == null) {
            final picked = await pickNavigationChromeColor(context, null);
            if (picked != null) await n.update((x) => x.copyWith(navigationChrome: v, navigationChromeColor: picked));
            return;
          }
          await n.update((x) => x.copyWith(navigationChrome: v));
        },
      ),
      if (s.navigationChrome == NavigationChromeStyle.custom) const _CustomNavigationColor(),
      if (s.navigationChrome == NavigationChromeStyle.transparent) const _SeeThroughNavigation(),
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
      const _Background(),
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

/// 1.4.3: colours. The way to any color: a named button with the color
/// wheel's palette, so it is never a guess which swatch opens the wheel.
class _CustomColorButton extends StatelessWidget {
  const _CustomColorButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: onPressed,
        icon: const _WheelMark(),
        label: const Text('Custom color…'),
      );
}

/// A small color wheel, the mark of "Custom color…".
class _WheelMark extends StatelessWidget {
  const _WheelMark();

  @override
  Widget build(BuildContext context) => Container(
        width: 18,
        height: 18,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(colors: [
            Color(0xFFFF0000), Color(0xFFFFFF00), Color(0xFF00FF00), Color(0xFF00FFFF), //
            Color(0xFF0000FF), Color(0xFFFF00FF), Color(0xFFFF0000),
          ]),
        ),
      );
}

/// A round color swatch (square with square corners), with a check while
/// selected.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.tooltip, required this.color, required this.selected, required this.onTap});

  final String tooltip;
  final Color color;
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
              decoration: BoxDecoration(color: fill, shape: Radii.circleShape, border: Border.all(color: nf.borderStrong.withValues(alpha: 0.6))),
              child: selected ? swatchCheck(fill) : null,
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

/// Picks the user's own accent color: a preset swatch, the color wheel or a
/// hex code, with a preview of the button and link text it makes. Returns
/// the ARGB color, or null when cancelled.
class CustomAccentDialog extends StatelessWidget {
  const CustomAccentDialog({super.key, this.initial});

  final int? initial;

  /// Starting points; any color works, NEFORUM adjusts it for contrast.
  static const presets = <int>[
    0xFF7D00FF, 0xFF5B3CC4, 0xFF3F51B5, 0xFF1677FF, 0xFF0288D1, 0xFF00838F, //
    0xFF0F9F6E, 0xFF2E7D32, 0xFF7CB342, 0xFFF9A825, 0xFFC77800, 0xFFEF6C00, //
    0xFFF2542D, 0xFFD32F2F, 0xFFD6338A, 0xFF8E24AA, 0xFF6D4C41, 0xFF546E7A, //
  ];

  @override
  Widget build(BuildContext context) => ColorChoiceDialog(
        title: 'Your accent color',
        description: 'Pick a color on the wheel or below it, or type its hex code. NEFORUM adjusts it where needed so text stays readable.',
        initial: initial,
        preview: (context, color) {
          final nf = context.nf;
          final shades = accentShadesOf(Color(color));
          // The readability adjustment changed what the preview shows.
          final adjusted = shades.light.toARGB32() != (color | 0xFF000000) || (nf.isDark && shades.dark.toARGB32() != (color | 0xFF000000));
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
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
          ]);
        },
      );
}

/// 1.4.3: colours. Picks the color of the navigation bar for "Your own
/// color": the wheel, swatches or a hex code, with a preview of the bar and
/// its labels. Returns the ARGB color, or null when cancelled.
Future<int?> pickNavigationChromeColor(BuildContext context, int? current) => showDialog<int>(
      context: context,
      builder: (_) => ColorChoiceDialog(
        title: 'Navigation bar color',
        description: 'Pick a color on the wheel or below it, or type its hex code. NEFORUM darkens it where needed so the labels stay readable.',
        initial: current,
        presets: const [0xFF16062F, ...CustomAccentDialog.presets, 0xFF000000, 0xFFFFFFFF],
        preview: (context, color) {
          final c = context.nf.withColorChrome(Color(color));
          return _ChromePreview(
            fill: c.chrome,
            text: c.onChrome,
            muted: c.onChromeMuted,
            selectedFill: c.chromeAccent,
            onSelected: c.onChromeAccent,
            adjusted: c.chrome.toARGB32() != (color | 0xFF000000),
          );
        },
      ),
    );

/// 1.4.3: colours. Picks the tint of the see-through navigation bar. Returns
/// the ARGB color, [ColorChoiceDialog.reset] for the page color again, or
/// null when cancelled.
Future<int?> pickNavigationChromeTint(BuildContext context, int? current) => showDialog<int>(
      context: context,
      builder: (_) => ColorChoiceDialog(
        title: 'See-through tint',
        description: 'The color over what shows through the navigation bar, in place of the page color. NEFORUM softens it where '
            'needed so the labels stay readable.',
        initial: current,
        resetLabel: current == null ? null : 'Use the page color',
        preview: (context, color) {
          final nf = context.nf;
          final tint = nf.seeThroughTint(Color(color));
          return _ChromePreview(
            fill: tint,
            text: nf.text,
            muted: nf.textMuted,
            selectedFill: nf.accentFill,
            onSelected: readableOn(nf.accentFill),
            adjusted: tint.toARGB32() != (color | 0xFF000000),
          );
        },
      ),
    );

/// A strip of navigation bar in [fill]: the current section on its
/// [selectedFill], and two more in [text] and [muted].
class _ChromePreview extends StatelessWidget {
  const _ChromePreview({required this.fill, required this.text, required this.muted, required this.selectedFill, required this.onSelected, required this.adjusted});

  final Color fill;
  final Color text;
  final Color muted;
  final Color selectedFill;
  final Color onSelected;
  final bool adjusted;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final label = context.text.labelMedium;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        key: const Key('chrome-preview'),
        padding: const EdgeInsets.all(Space.sm),
        decoration: BoxDecoration(color: fill, borderRadius: Radii.rSm, border: Border.all(color: nf.border)),
        child: Wrap(spacing: Space.md, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
            decoration: BoxDecoration(color: selectedFill, borderRadius: Radii.rPill),
            child: Text('Compose', style: label?.copyWith(color: onSelected)),
          ),
          Text('Queue', style: label?.copyWith(color: text)),
          Text('Activity', style: label?.copyWith(color: muted)),
        ]),
      ),
      if (adjusted) ...[
        const SizedBox(height: Space.sm),
        Text('Adjusted a little so the labels stay readable.', style: context.text.bodySmall),
      ],
    ]);
  }
}

/// 1.4.3: colours. Any color, for any Appearance setting: preset swatches,
/// the [ColorWheel] with its brightness slider and a hex code, all following
/// each other, with an optional [preview] of the color where it is used.
/// Pops the ARGB color, [reset] for the default again (with a
/// [resetLabel]), or nothing when cancelled.
class ColorChoiceDialog extends StatefulWidget {
  const ColorChoiceDialog({
    super.key,
    required this.title,
    required this.description,
    this.initial,
    this.presets = CustomAccentDialog.presets,
    this.preview,
    this.resetLabel,
  });

  final String title;
  final String description;
  final int? initial;
  final List<int> presets;
  final Widget Function(BuildContext context, int color)? preview;
  final String? resetLabel;

  /// Popped by the [resetLabel] button: never a color, all of which are
  /// opaque.
  static const int reset = 0;

  @override
  State<ColorChoiceDialog> createState() => _ColorChoiceDialogState();
}

class _ColorChoiceDialogState extends State<ColorChoiceDialog> {
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
    final wheel = ColorWheel(
      color: Color(color ?? widget.presets.first),
      diameter: context.isCompact ? 180 : 164,
      onChanged: (c) => _pick(c.toARGB32()),
    );
    final preview = widget.preview;
    final details = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _hex,
        decoration: InputDecoration(labelText: 'Hex color', hintText: '#7D00FF', errorText: _error),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')), LengthLimitingTextInputFormatter(7)],
        onChanged: _typed,
      ),
      if (color != null && preview != null) ...[
        const SizedBox(height: Space.lg),
        preview(context, color),
      ],
    ]);
    final resetLabel = widget.resetLabel;
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.description, style: context.text.bodySmall),
            const SizedBox(height: Space.lg),
            Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
              for (final p in widget.presets)
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
        if (resetLabel != null)
          TextButton(key: const Key('color-choice-reset'), onPressed: () => Navigator.pop(context, ColorChoiceDialog.reset), child: Text(resetLabel)),
        TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
        FilledButton(onPressed: color == null ? null : () => Navigator.pop(context, color), child: const Text('Use this color')),
      ],
    );
  }
}

/// 1.4.3: colours. The color in use, as a swatch beside its name.
class _ColorInUse extends StatelessWidget {
  const _ColorInUse({required this.color, required this.name});

  final Color color;
  final String name;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(color: color, shape: Radii.circleShape, border: Border.all(color: nf.borderStrong)),
      ),
      const SizedBox(width: Space.sm),
      Text(name, style: context.text.labelLarge?.copyWith(color: nf.textMuted)),
    ]);
  }
}

/// 1.4.3: colours. Settings > Appearance > Navigation bar > Your own color:
/// the color, and the way to another one on the wheel.
class _CustomNavigationColor extends ConsumerWidget {
  const _CustomNavigationColor();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = ref.watch(settingsProvider.select((s) => s.navigationChromeColor));
    final n = ref.read(settingsProvider.notifier);
    return SettingRow(
      title: 'Navigation bar color',
      description: 'NEFORUM darkens it a little where the labels need it.',
      stackOnCompact: true,
      trailing: Wrap(spacing: Space.md, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _ColorInUse(color: color == null ? Brand.night : Color(color), name: color == null ? 'NEFORUM purple' : hexColor(color)),
        _CustomColorButton(
          key: const Key('navigation-custom-color'),
          onPressed: () async {
            final picked = await pickNavigationChromeColor(context, color);
            if (picked != null) await n.update((x) => x.copyWith(navigationChromeColor: picked));
          },
        ),
      ]),
    );
  }
}

/// Settings > Appearance > Navigation bar > See-through: how much of the
/// theme's surface color (1.4.3: or a tint of the user's own) covers it, and
/// the frosted-glass blur of the background picture under it (only with a
/// picture: over the plain page a blur shows nothing).
class _SeeThroughNavigation extends ConsumerWidget {
  const _SeeThroughNavigation();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final s = ref.watch(settingsProvider.select((s) => (
          opacity: s.navigationChromeOpacity,
          blur: s.navigationChromeBlur,
          picture: s.backgroundImagePath != null,
          tint: s.navigationChromeTint,
        )));
    final n = ref.read(settingsProvider.notifier);

    Widget slider(String label, String value, Slider slider) => MergeSemantics(
          child: Row(children: [
            SizedBox(width: 64, child: Text(label, style: context.text.labelLarge?.copyWith(color: nf.textMuted))),
            Expanded(child: slider),
            SizedBox(width: 44, child: Text(value, textAlign: TextAlign.end, style: context.text.titleSmall)),
          ]),
        );

    return SettingRow(
      title: 'See-through navigation',
      description: s.picture
          ? 'Opacity 0% shows all of your background picture. NEFORUM covers it more where the labels need it.'
          : 'Opacity 0% shows the page color. Blur frosts a background picture, when you set one below.',
      below: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        slider(
          'Opacity',
          '${(s.opacity * 100).round()}%',
          Slider(
            value: s.opacity,
            divisions: 20,
            semanticFormatterCallback: (v) => '${(v * 100).round()}%',
            onChanged: (v) => n.update((x) => x.copyWith(navigationChromeOpacity: validNavigationChromeOpacity((v * 20).round() / 20))),
          ),
        ),
        if (s.picture)
          slider(
            'Blur',
            s.blur == 0 ? 'Off' : '${s.blur.round()}',
            Slider(
              value: s.blur,
              max: kMaxNavigationChromeBlur,
              divisions: kMaxNavigationChromeBlur.round(),
              semanticFormatterCallback: (v) => v == 0 ? 'Off' : '${v.round()}',
              onChanged: (v) => n.update((x) => x.copyWith(navigationChromeBlur: validNavigationChromeBlur(v.roundToDouble()))),
            ),
          ),
        // 1.4.3: colours. The tint over what shows through.
        Padding(
          padding: const EdgeInsets.only(top: Space.sm),
          child: Wrap(spacing: Space.md, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(width: 52, child: Text('Tint', style: context.text.labelLarge?.copyWith(color: nf.textMuted))),
            _ColorInUse(
              color: s.tint == null ? nf.surface : nf.seeThroughTint(Color(s.tint!)),
              name: s.tint == null ? 'Page color' : hexColor(s.tint!),
            ),
            _CustomColorButton(
              key: const Key('see-through-custom-color'),
              onPressed: () async {
                final picked = await pickNavigationChromeTint(context, s.tint);
                if (picked == null) return;
                await n.update((x) => picked == ColorChoiceDialog.reset
                    ? x.copyWith(clearNavigationChromeTint: true)
                    : x.copyWith(navigationChromeTint: picked));
              },
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Picture files the background picker offers.
const _kPictureExtensions = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'];

/// Settings > Appearance > Background: none, or a picture of the user's own
/// behind the pages, copied into NEFORUM's data folder, with its blur and
/// dim. On this device only.
class _Background extends ConsumerStatefulWidget {
  const _Background();

  @override
  ConsumerState<_Background> createState() => _BackgroundState();
}

class _BackgroundState extends ConsumerState<_Background> {
  bool _busy = false;

  /// The blur while its slider is dragged: the picture is blurred again
  /// once the slider is let go.
  double? _blur;

  Future<void> _choose() async {
    final dataDir = ref.read(servicesProvider).storage.dataDir;
    setState(() => _busy = true);
    try {
      Uint8List? bytes;
      var name = '';
      if (Env.isMobile) {
        final f = await ImagePicker().pickImage(source: ImageSource.gallery);
        if (f != null) {
          bytes = await f.readAsBytes();
          name = f.name;
        }
      } else {
        final files = await FilePicker.pickFiles(
          dialogTitle: 'Choose a background picture',
          type: FileType.custom,
          allowedExtensions: _kPictureExtensions,
        );
        final f = files.firstOrNull;
        if (f != null) {
          bytes = await f.readAsBytes();
          name = f.name;
        }
      }
      if (bytes == null) return;
      if (!await isDecodablePicture(bytes)) {
        if (mounted) showToast(context, 'Choose a picture (JPEG, PNG, WebP, GIF or BMP)', icon: Icons.info_outline_rounded);
        return;
      }
      // The copy keeps the file's own extension (a HEIC from a phone too).
      final dot = name.lastIndexOf('.');
      final extension = dot < 0 ? '' : name.substring(dot + 1);
      final path = await saveBackgroundImage(dataDir, bytes, RegExp(r'^[A-Za-z0-9]{1,5}$').hasMatch(extension) ? extension : 'img');
      if (path == null) return;
      final previous = ref.read(settingsProvider).backgroundImagePath;
      await ref.read(settingsProvider.notifier).update((x) => x.copyWith(backgroundImagePath: path));
      if (previous != null) await deleteBackgroundImage(dataDir, previous);
    } on Object catch (e) {
      if (mounted) showToast(context, 'Could not use that picture: $e', icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final dataDir = ref.read(servicesProvider).storage.dataDir;
    final previous = ref.read(settingsProvider).backgroundImagePath;
    await ref.read(settingsProvider.notifier).update((x) => x.copyWith(clearBackgroundImage: true));
    if (previous != null) await deleteBackgroundImage(dataDir, previous);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final s = ref.watch(settingsProvider.select((s) => (path: s.backgroundImagePath, blur: s.backgroundBlur, dim: s.backgroundDim)));
    final storage = ref.watch(servicesProvider).storage;
    final supported = backgroundImagesSupported(storage.dataDir);
    final path = s.path;
    final blur = _blur ?? s.blur;
    final n = ref.read(settingsProvider.notifier);

    Widget slider(String label, String value, Slider slider) => MergeSemantics(
          child: Row(children: [
            SizedBox(width: 52, child: Text(label, style: context.text.labelLarge?.copyWith(color: nf.textMuted))),
            Expanded(child: slider),
            SizedBox(width: 44, child: Text(value, textAlign: TextAlign.end, style: context.text.titleSmall)),
          ]),
        );

    return SettingRow(
      title: 'Background',
      description: supported
          ? 'A picture of your own behind the pages, on this device only. NEFORUM dims it as much as text needs to stay readable.'
          : 'A picture behind the pages needs the installed app.',
      stackOnCompact: true,
      enabled: supported,
      trailing: SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('None')),
          ButtonSegment(value: true, label: Text('Image')),
        ],
        selected: {path != null},
        onSelectionChanged: !supported || _busy ? null : (v) => v.first ? _choose() : _remove(),
        showSelectedIcon: false,
      ),
      below: path == null
          ? null
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: Space.sm, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
                ClipRRect(
                  borderRadius: Radii.rSm,
                  child: Semantics(
                    image: true,
                    label: 'The background picture',
                    child: SizedBox(width: 72, height: 48, child: storage.image(path, width: 72, height: 48, cacheWidth: 144)),
                  ),
                ),
                const SizedBox(width: Space.xs),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _choose,
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('Choose another'),
                ),
                TextButton(onPressed: _busy ? null : _remove, child: const Text('Remove')),
              ]),
              const SizedBox(height: Space.md),
              slider(
                'Blur',
                blur == 0 ? 'Off' : '${blur.round()}',
                Slider(
                  value: blur,
                  max: kMaxBackgroundBlur,
                  divisions: kMaxBackgroundBlur.round(),
                  semanticFormatterCallback: (v) => v == 0 ? 'Off' : '${v.round()}',
                  onChanged: (v) => setState(() => _blur = v),
                  onChangeEnd: (v) async {
                    await n.update((x) => x.copyWith(backgroundBlur: validBackgroundBlur(v.roundToDouble())));
                    if (mounted) setState(() => _blur = null);
                  },
                ),
              ),
              slider(
                'Dim',
                '${(s.dim * 100).round()}%',
                Slider(
                  value: s.dim,
                  divisions: 20,
                  semanticFormatterCallback: (v) => '${(v * 100).round()}%',
                  onChanged: (v) => n.update((x) => x.copyWith(backgroundDim: validBackgroundDim((v * 20).round() / 20))),
                ),
              ),
            ]),
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
