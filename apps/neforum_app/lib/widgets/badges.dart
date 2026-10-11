import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart';

import '../theme/tokens.dart';

enum Tone { neutral, accent, success, warning, danger, info }

extension ToneColors on Tone {
  Color fg(NfColors nf) => switch (this) {
        Tone.neutral => nf.textMuted,
        Tone.accent => nf.accent,
        Tone.success => nf.success,
        Tone.warning => nf.warning,
        Tone.danger => nf.danger,
        Tone.info => nf.info,
      };

  Color bg(NfColors nf) => switch (this) {
        Tone.neutral => nf.surfaceSunken,
        Tone.accent => nf.accentSoft,
        Tone.success => nf.successSoft,
        Tone.warning => nf.warningSoft,
        Tone.danger => nf.dangerSoft,
        Tone.info => nf.infoSoft,
      };
}

/// Small rounded status label: `● Published`, `Scheduled`, `Needs you`.
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.tone = Tone.neutral, this.icon, this.dot = false, this.dense = false});

  final String label;
  final Tone tone;
  final IconData? icon;
  final bool dot;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final fg = tone.fg(nf);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 9, vertical: dense ? 2.5 : 4),
      decoration: BoxDecoration(color: tone.bg(nf), borderRadius: Radii.rPill),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot) ...[
          Container(width: 6, height: 6, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
          SizedBox(width: dense ? 5 : 6),
        ] else if (icon != null) ...[
          Icon(icon, size: dense ? 12 : 13, color: fg),
          SizedBox(width: dense ? 4 : 5),
        ],
        Text(label, style: context.text.labelSmall?.copyWith(color: fg, fontSize: dense ? 10.5 : 11.5, letterSpacing: 0.2)),
      ]),
    );
  }
}

/// How an account publishes, as a pill.
class TierBadge extends StatelessWidget {
  const TierBadge(this.tier, {super.key, this.dense = true});
  final PlatformTier tier;
  final bool dense;

  @override
  Widget build(BuildContext context) => StatusPill(
        tierShortLabel(tier),
        tone: tierTone(tier),
        icon: tierIcon(tier),
        dense: dense,
      );
}

String tierShortLabel(PlatformTier t) => switch (t) {
      PlatformTier.openApi => 'Auto',
      PlatformTier.byokApi => 'Your keys',
      PlatformTier.handoff => 'Hand-off',
      PlatformTier.webSession => 'Web session',
    };

String tierDescription(PlatformTier t) => switch (t) {
      PlatformTier.openApi => 'Posts automatically through the platform\'s open API. Nothing to pay, no review.',
      PlatformTier.byokApi => 'Posts automatically through the official API using a developer app you create. Subject to the platform\'s quota.',
      PlatformTier.handoff => 'NEFORUM prepares the post, copies the text and opens the app or website. You tap Post. Works with any account.',
      PlatformTier.webSession => 'Experimental: drives the website you are signed into. May break or break terms of service.',
    };

Tone tierTone(PlatformTier t) => switch (t) {
      PlatformTier.openApi => Tone.success,
      PlatformTier.byokApi => Tone.info,
      PlatformTier.handoff => Tone.warning,
      PlatformTier.webSession => Tone.danger,
    };

IconData tierIcon(PlatformTier t) => switch (t) {
      PlatformTier.openApi => Icons.bolt_rounded,
      PlatformTier.byokApi => Icons.key_rounded,
      PlatformTier.handoff => Icons.ios_share_rounded,
      PlatformTier.webSession => Icons.science_outlined,
    };

/// Labels and tones for post and target status.
(String, Tone, IconData) postStatusStyle(PostStatus s) => switch (s) {
      PostStatus.draft => ('Draft', Tone.neutral, Icons.edit_note_rounded),
      PostStatus.scheduled => ('Scheduled', Tone.accent, Icons.schedule_rounded),
      PostStatus.publishing => ('Publishing', Tone.info, Icons.sync_rounded),
      PostStatus.published => ('Published', Tone.success, Icons.check_circle_rounded),
      PostStatus.partial => ('Needs you', Tone.warning, Icons.pending_actions_rounded),
      PostStatus.failed => ('Failed', Tone.danger, Icons.error_rounded),
      PostStatus.cancelled => ('Cancelled', Tone.neutral, Icons.block_rounded),
    };

(String, Tone, IconData) targetStatusStyle(TargetStatus s) => switch (s) {
      TargetStatus.pending => ('Queued', Tone.neutral, Icons.more_horiz_rounded),
      TargetStatus.publishing => ('Posting', Tone.info, Icons.sync_rounded),
      TargetStatus.published => ('Live', Tone.success, Icons.check_rounded),
      TargetStatus.failed => ('Failed', Tone.danger, Icons.close_rounded),
      TargetStatus.awaitingHandoff => ('Tap to post', Tone.warning, Icons.touch_app_rounded),
      TargetStatus.handedOff => ('Handed off', Tone.success, Icons.ios_share_rounded),
      TargetStatus.skipped => ('Skipped', Tone.neutral, Icons.remove_rounded),
      TargetStatus.heldByPlatform => ('Held by platform', Tone.accent, Icons.cloud_done_rounded),
    };
