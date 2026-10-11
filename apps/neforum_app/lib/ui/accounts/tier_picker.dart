import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/surfaces.dart';

/// Step 2: choose how NEFORUM should reach the platform.
class TierPicker extends StatefulWidget {
  const TierPicker({super.key, required this.descriptor, required this.onPick});
  final PlatformDescriptor descriptor;
  final ValueChanged<PlatformTier> onPick;

  @override
  State<TierPicker> createState() => _TierPickerState();
}

class _TierPickerState extends State<TierPicker> {
  late PlatformTier _tier = widget.descriptor.defaultTier;

  static const _order = [PlatformTier.openApi, PlatformTier.byokApi, PlatformTier.handoff, PlatformTier.webSession];

  static String _headline(PlatformTier t) => switch (t) {
        PlatformTier.openApi => 'Post automatically',
        PlatformTier.byokApi => 'Use your own developer keys',
        PlatformTier.handoff => 'Hand off to the app',
        PlatformTier.webSession => 'Drive the website (experimental)',
      };

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final d = widget.descriptor;
    final tiers = _order.where(d.supportsTier).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final t in tiers) ...[
        NfCard(
          selected: _tier == t,
          onTap: () => setState(() => _tier = t),
          padding: const EdgeInsets.all(Space.lg),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: AnimatedSwitcher(
                duration: Motion.fast,
                child: Icon(
                  _tier == t ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  key: ValueKey(_tier == t),
                  color: _tier == t ? nf.accent : nf.textFaint,
                ),
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: Space.sm, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(_headline(t), style: context.text.titleMedium),
                  TierBadge(t),
                  if (t == d.defaultTier) const StatusPill('Recommended', tone: Tone.accent, icon: Icons.star_rounded, dense: true),
                ]),
                const SizedBox(height: Space.xs + 2),
                Text(tierDescription(t), style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
                if (t != PlatformTier.handoff) ...[
                  const SizedBox(height: Space.md),
                  _Fact(icon: Icons.person_outline_rounded, text: d.accountRequirements),
                  _Fact(icon: Icons.payments_outlined, text: d.apiCostSummary),
                  for (final q in d.defaultQuotas.where((q) => q.appliesToTier == null || q.appliesToTier == t).take(3))
                    _Fact(icon: Icons.speed_rounded, text: '${q.limit} per ${_window(q.window)}: ${q.note}'),
                ] else ...[
                  const SizedBox(height: Space.md),
                  const _Fact(icon: Icons.verified_user_outlined, text: 'No keys, no business account, no review. Works with your normal account.'),
                  const _Fact(icon: Icons.touch_app_outlined, text: 'Each post needs one tap from you in the app, so it cannot be fully automatic.'),
                ],
              ]),
            ),
          ]),
        ),
        const SizedBox(height: Space.md),
      ],
      const SizedBox(height: Space.sm),
      Align(
        alignment: Alignment.centerRight,
        child: PrimaryAction(label: 'Continue', icon: Icons.arrow_forward_rounded, onPressed: () => widget.onPick(_tier)),
      ),
    ]);
  }

  static String _window(Duration w) {
    if (w.inDays >= 28) return 'month';
    if (w.inDays >= 1) return w.inDays == 1 ? 'day' : '${w.inDays} days';
    if (w.inHours >= 1) return w.inHours == 1 ? 'hour' : '${w.inHours} hours';
    return '${w.inMinutes} min';
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xs + 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: nf.textFaint),
        const SizedBox(width: Space.sm),
        Expanded(child: Text(text, style: context.text.bodySmall)),
      ]),
    );
  }
}
