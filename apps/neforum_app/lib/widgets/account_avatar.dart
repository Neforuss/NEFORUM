import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart';

import '../brand/platform_brand.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'badges.dart';

/// The account's profile picture with its platform's icon as a small badge in
/// the corner; without a picture, the platform's icon itself.
class AccountAvatar extends StatelessWidget {
  const AccountAvatar(this.account, {super.key, this.size = 40, this.showBadge = true, this.dimmed = false});

  final ConnectedAccount account;
  final double size;
  final bool showBadge;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final brand = brandFor(account.platformId);
    final b = Theme.of(context).brightness;
    final icon = platformIconAsset(account.platformId) != null;
    Widget fallback() => icon ? PlatformTile(account.platformId, size: size, circle: true) : _initialsFace(context, _initials(account.displayName), brand, b);

    Widget face;
    var showBadge = this.showBadge;
    final url = account.avatarUrl;
    if (url != null && url.startsWith('http')) {
      final photo = Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback(),
      );
      face = Radii.square ? ClipRect(child: photo) : ClipOval(child: photo);
    } else {
      face = fallback();
      // The face is already the platform's icon.
      if (icon) showBadge = false;
    }

    final badgeSize = (size * 0.44).clamp(14.0, 22.0);
    Widget out = SizedBox(
      width: size + (showBadge ? badgeSize * 0.18 : 0),
      height: size + (showBadge ? badgeSize * 0.18 : 0),
      child: Stack(clipBehavior: Clip.none, children: [
        face,
        if (showBadge)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(1.6),
              decoration: BoxDecoration(color: nf.surface, borderRadius: Radii.circular(badgeSize * 0.36)),
              child: PlatformTile(account.platformId, size: badgeSize, radius: Radii.corner(badgeSize * 0.3)),
            ),
          ),
      ]),
    );
    if (dimmed) out = Opacity(opacity: 0.4, child: out);
    return out;
  }

  Widget _initialsFace(BuildContext context, String initials, PlatformBrand brand, Brightness b) {
    final base = brand.colorFor(b);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: Radii.circleShape,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(base, Colors.white, 0.18)!, Color.lerp(base, Colors.black, 0.12)!],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          fontFamily: Fonts.display,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.38,
          color: brand.onColor,
          height: 1,
        ),
      ),
    );
  }

  static String _initials(String name) {
    final clean = name.replaceAll(RegExp(r'\(.*?\)'), '').trim();
    final parts = clean.split(RegExp(r'[\s@._-]+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.take(2).toString().toUpperCase();
    return (parts[0].characters.first + parts[1].characters.first).toUpperCase();
  }
}

/// Horizontal usage meter for one quota rule.
class QuotaMeter extends StatelessWidget {
  const QuotaMeter(this.status, {super.key, this.dense = false});
  final QuotaStatus status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final f = status.fraction;
    final color = f >= 1 ? nf.danger : f >= 0.8 ? nf.warning : nf.accent;
    final reset = status.resetsAt;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(
          child: Text(
            _windowLabel(status.rule.window),
            style: (dense ? context.text.labelSmall : context.text.labelMedium)?.copyWith(color: nf.textMuted),
          ),
        ),
        Text('${status.used} / ${status.limit}', style: monoStyle(context, size: dense ? 11 : 12, color: f >= 0.8 ? color : nf.textMuted)),
      ]),
      const SizedBox(height: Space.xs + 2),
      ClipRRect(
        borderRadius: Radii.rPill,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: f),
          duration: Motion.slow,
          curve: Motion.standard,
          builder: (context, v, _) => LinearProgressIndicator(value: v, color: color, minHeight: dense ? 4 : 6, backgroundColor: nf.surfaceSunken),
        ),
      ),
      if (!dense) ...[
        const SizedBox(height: Space.xs + 2),
        Text(
          status.rule.note + (reset != null && status.used > 0 ? ' · frees up ${_relative(reset)}' : ''),
          style: context.text.bodySmall?.copyWith(color: nf.textFaint, fontSize: 11.5),
        ),
      ],
    ]);
  }

  static String _windowLabel(Duration w) {
    if (w.inDays >= 28) return 'This month';
    if (w.inDays >= 1) return w.inDays == 1 ? 'Last 24 hours' : 'Last ${w.inDays} days';
    if (w.inHours >= 1) return 'Last ${w.inHours} h';
    if (w.inMinutes >= 1) return 'Last ${w.inMinutes} min';
    return 'Last ${w.inSeconds} s';
  }

  static String _relative(DateTime t) {
    final d = t.difference(DateTime.now());
    if (d.isNegative) return 'now';
    if (d.inDays >= 1) return 'in ${d.inDays} d';
    if (d.inHours >= 1) return 'in ${d.inHours} h';
    return 'in ${d.inMinutes.clamp(1, 59)} min';
  }
}

/// A row of tiny platform tiles, overlapping slightly, with a "+N" overflow.
class PlatformStack extends StatelessWidget {
  const PlatformStack(this.platformIds, {super.key, this.size = 22, this.max = 6, this.statuses});

  final List<String> platformIds;
  final double size;
  final int max;

  /// Optional per-item status; failed ones get a red ring, waiting amber.
  final List<TargetStatus>? statuses;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final shown = platformIds.take(max).toList();
    final extra = platformIds.length - shown.length;
    final overlap = size * 0.28;
    return SizedBox(
      height: size + 4,
      width: shown.length * (size - overlap) + overlap + 4 + (extra > 0 ? size + 4 : 0),
      child: Stack(children: [
        for (var i = 0; i < shown.length; i++)
          Positioned(
            left: i * (size - overlap),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: _ring(nf, i),
                borderRadius: Radii.circular(size * 0.34),
              ),
              child: PlatformTile(shown[i], size: size, radius: Radii.corner(size * 0.28)),
            ),
          ),
        if (extra > 0)
          Positioned(
            left: shown.length * (size - overlap) + 2,
            child: Container(
              width: size + 2,
              height: size + 4,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: nf.surfaceSunken, borderRadius: Radii.circular(size * 0.34), border: Border.all(color: nf.surface, width: 2)),
              child: Text('+$extra', style: monoStyle(context, size: size * 0.42, weight: FontWeight.w600)),
            ),
          ),
      ]),
    );
  }

  Color _ring(NfColors nf, int i) {
    final s = statuses;
    if (s == null || i >= s.length) return nf.surface;
    return switch (s[i]) {
      TargetStatus.failed => nf.danger,
      TargetStatus.awaitingHandoff => nf.warning,
      _ => nf.surface,
    };
  }
}

/// Visual helper used by account lists: name + handle + tier.
class AccountLabel extends StatelessWidget {
  const AccountLabel(this.account, {super.key, this.showTier = true});
  final ConnectedAccount account;
  final bool showTier;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(account.displayName, overflow: TextOverflow.ellipsis, style: context.text.titleSmall)),
        if (showTier) ...[const SizedBox(width: Space.sm), TierBadge(account.tier)],
      ]),
      if (account.handle != null) ...[
        const SizedBox(height: 2),
        Text(account.handle!, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
      ],
    ]);
  }
}
