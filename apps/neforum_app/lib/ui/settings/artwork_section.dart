import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/providers.dart';
import '../compose/target_picker.dart' show adultRatingDescription;
import 'setting_row.dart';

/// Defaults for artwork posts to art portfolio sites.
class ArtworkSettingsSection extends ConsumerWidget {
  const ArtworkSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    const subtitle = 'Defaults for posts to art sites. Turn on Artwork under Post to when you write one.';
    return SettingsSection(title: 'Artwork', icon: Icons.brush_outlined, subtitle: subtitle, children: [
      SettingChoice<ArtworkMaturity>(
        title: 'Rating of new artwork',
        value: s.artworkMaturity,
        onChanged: (v) => n.update((x) => x.copyWith(artworkMaturity: v)),
        options: const [
          (ArtworkMaturity.general, 'General', 'Suitable for everyone.'),
          (ArtworkMaturity.mature, 'Mature', 'Suggestive themes, mild nudity or violence.'),
          (ArtworkMaturity.adult, 'Adult', adultRatingDescription),
        ],
      ),
      SettingSwitch(
        title: 'Ask sites not to use my work for AI training',
        description: 'Sets the NoAI option where a site has one (DeviantArt, ArtStation).',
        value: s.artworkDisallowAiTraining,
        onChanged: (v) => n.update((x) => x.copyWith(artworkDisallowAiTraining: v)),
      ),
    ]);
  }
}
