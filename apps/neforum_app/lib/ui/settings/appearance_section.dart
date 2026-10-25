
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/env.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../theme/zoom.dart';
import 'setting_row.dart';

class AppearanceSettingsSection extends ConsumerWidget {
  const AppearanceSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSection(title: 'Appearance', icon: Icons.palette_outlined, children: [
      SettingRow(
        title: 'Theme',
        stackOnCompact: true,
        trailing: SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto_outlined, size: 18)),
            ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined, size: 18)),
            ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined, size: 18)),
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
        trailing: Wrap(spacing: Space.sm, children: [
          for (final a in AccentChoice.values)
            Tooltip(
              message: a.label,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => n.update((x) => x.copyWith(accent: a)),
                child: AnimatedContainer(
                  duration: Motion.fast,
                  width: 30,
                  height: 30,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: s.accent == a ? nf.text : Colors.transparent, width: 2)),
                  child: Container(
                    decoration: BoxDecoration(color: nf.isDark ? a.dark : a.light, shape: BoxShape.circle),
                    child: s.accent == a ? const Icon(Icons.check_rounded, size: 14, color: Colors.white) : null,
                  ),
                ),
              ),
            ),
        ]),
      ),
      SettingSwitch(
        title: 'Compact previews',
        description: 'Smaller preview cards in the composer.',
        value: s.compactPreviews,
        onChanged: (v) => n.update((x) => x.copyWith(compactPreviews: v)),
      ),
      if (Env.isDesktop) const _Zoom(),
    ]);
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
