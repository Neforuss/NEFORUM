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
