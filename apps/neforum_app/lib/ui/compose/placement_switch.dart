import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../theme/tokens.dart';

/// 1.4.3: Post / Story / Post + Story, right on the preview of a network that
/// takes stories (`PlatformAdapter.supportsStories`): the current choice is
/// filled in the accent with a check, and one line under it says what goes
/// out. The composer remembers the choice for the account's next posts.
class PlacementSwitch extends StatelessWidget {
  const PlacementSwitch({super.key, required this.accountId, required this.network, required this.value, required this.onChanged});

  /// The account whose post this places; it names the control's keys
  /// (`placement-<id>`, `placement-summary-<id>`).
  final String accountId;

  /// The network's name, for the tooltips.
  final String network;
  final PostPlacement value;
  final ValueChanged<PostPlacement> onChanged;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      SegmentedButton<PostPlacement>(
        key: Key('placement-$accountId'),
        segments: [
          for (final p in PostPlacement.values)
            ButtonSegment(
              value: p,
              label: Text(p.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              tooltip: placementHelp(p, network),
            ),
        ],
        selected: {value},
        showSelectedIcon: true,
        selectedIcon: const Icon(Icons.check_rounded, size: 16),
        expandedInsets: EdgeInsets.zero,
        // The fill, text, check and edges are the app's clear selected state
        // (selectionSegmentedButtonTheme, lib/theme/selection_theme.dart).
        style: ButtonStyle(
          textStyle: WidgetStateProperty.resolveWith(
            (s) => context.text.labelMedium?.copyWith(fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500),
          ),
          padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs)),
          visualDensity: VisualDensity.compact,
        ),
        onSelectionChanged: (s) => onChanged(s.single),
      ),
      const SizedBox(height: Space.xs),
      Text(placementSummary(value), key: Key('placement-summary-$accountId'), style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
    ]);
  }
}

/// One line under [PlacementSwitch]: what goes out with [p].
String placementSummary(PostPlacement p) => switch (p) {
      PostPlacement.feed => 'A regular post with your caption.',
      PostPlacement.story => 'A story only: 9:16, without a caption.',
      PostPlacement.feedAndStory => 'The post with your caption, and the same photos or videos as a story.',
    };

/// The longer explanation of [p] on [network], shown as a segment's tooltip.
String placementHelp(PostPlacement p, String network) => switch (p) {
      PostPlacement.feed => 'A regular $network post with your caption.',
      PostPlacement.story =>
        'A story: each photo or video becomes a frame, words only become a 9:16 text card. A story has no caption field: with Caption on photo, your caption is written on its photo.',
      PostPlacement.feedAndStory =>
        'The post with your caption, and the same photos or videos as a story (9:16) on the same account. A story has no caption field: with Caption on photo, the story\'s photo gets your caption written on it too (Settings > Posting).',
    };
