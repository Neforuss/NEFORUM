import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../state/composer.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/char_ring.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/surfaces.dart';
import 'rich_text.dart';

/// How a platform presents a post; drives the preview layout.
enum PreviewFamily { microblog, visual, forum, chat, blog }

PreviewFamily previewFamilyFor(String platformId) => switch (platformId) {
      'instagram' || 'tiktok' || 'pinterest' || 'youtube' || 'snapchat' => PreviewFamily.visual,
      'reddit' || 'lemmy' => PreviewFamily.forum,
      'telegram' || 'discord' || 'matrix' || 'whatsapp' => PreviewFamily.chat,
      'wordpress' || 'ghost' || 'writefreely' || 'micropub' || 'devto' || 'hashnode' || 'substack' => PreviewFamily.blog,
      _ => PreviewFamily.microblog,
    };

/// Width / height of the media frame on photo-first platforms.
double _visualAspect(String platformId, List<MediaAttachment> media) {
  final video = media.isNotEmpty && media.first.isVideo;
  return switch (platformId) {
    'instagram' => video ? 9 / 16 : 4 / 5,
    'tiktok' || 'snapchat' => 9 / 16,
    'pinterest' => 2 / 3,
    'youtube' => (media.isNotEmpty && (media.first.aspectRatio ?? 1.7) < 1) ? 9 / 16 : 16 / 9,
    _ => 1,
  };
}

/// One network's preview in the composer.
class PreviewCard extends ConsumerWidget {
  const PreviewCard({super.key, required this.preview, required this.onCustomize});

  final TargetPreview preview;
  final VoidCallback onCustomize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final p = preview;
    final d = p.descriptor;
    final v = p.variant;
    final customized = !p.target.overrides.isEmpty;
    final hasErrors = p.issues.hasErrors;
    final family = previewFamilyFor(d.id);
    final rules = d.text;
    final used = rules.maxLength == null ? v.text.characters.length : TextCounter.count(v.text, rules);

    final body = switch (family) {
      PreviewFamily.microblog => _Microblog(p: p),
      PreviewFamily.visual => _Visual(p: p),
      PreviewFamily.forum => _Forum(p: p),
      PreviewFamily.chat => _Chat(p: p),
      PreviewFamily.blog => _Blog(p: p),
    };

    return NfCard(
      padding: EdgeInsets.zero,
      borderColor: hasErrors ? nf.danger.withValues(alpha: 0.7) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.sm, Space.md),
          child: Row(children: [
            PlatformTile(d.id, size: 28),
            const SizedBox(width: Space.sm + 2),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Flexible(child: Text(d.name, overflow: TextOverflow.ellipsis, style: context.text.titleSmall)),
                  const SizedBox(width: Space.sm),
                  TierBadge(p.account.tier),
                  if (customized) ...[
                    const SizedBox(width: Space.xs),
                    const StatusPill('Customized', tone: Tone.accent, dense: true),
                  ],
                ]),
                Text(p.account.handle ?? p.account.displayName, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.textFaint, fontSize: 11.5)),
              ]),
            ),
            CharRing(used: used, max: rules.maxLength, parts: v.isThread ? v.threadParts.length : 1, size: 22),
            const SizedBox(width: Space.xs),
            ToolButton(icon: Icons.tune_rounded, tooltip: 'Customize for ${d.name}', onPressed: onCustomize, size: 34, active: customized),
          ]),
        ),
        Divider(height: 1, color: nf.border),
        Padding(padding: const EdgeInsets.all(Space.md + 2), child: body),
        if (p.issues.isNotEmpty) ...[
          Divider(height: 1, color: nf.border),
          _Issues(issues: p.issues),
        ],
        if (customized)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: Space.sm, bottom: Space.xs),
              child: TextButton.icon(
                onPressed: () => ref.read(composerProvider.notifier).clearOverride(p.account.id),
                icon: const Icon(Icons.restart_alt_rounded, size: 16),
                label: const Text('Use the main post'),
                style: TextButton.styleFrom(foregroundColor: nf.textMuted, textStyle: context.text.labelMedium),
              ),
            ),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Families
// ---------------------------------------------------------------------------

class _Microblog extends StatelessWidget {
  const _Microblog({required this.p});
  final TargetPreview p;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final v = p.variant;
    final parts = v.isThread ? v.threadParts : [v.text];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < parts.length; i++)
        // Thread connector painted behind the row (MediaGrid uses
        // LayoutBuilder, which cannot run inside IntrinsicHeight).
        Stack(children: [
          if (i < parts.length - 1)
            Positioned(left: 17, top: 40, bottom: 4, child: Container(width: 2, color: nf.border)),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AccountAvatar(p.account, size: 36, showBadge: false),
            const SizedBox(width: Space.md),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(bottom: i < parts.length - 1 ? Space.lg : 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(p.account.displayName, overflow: TextOverflow.ellipsis, style: context.text.labelLarge)),
                    const SizedBox(width: Space.xs + 2),
                    Text('· now', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
                    if (parts.length > 1) ...[
                      const Spacer(),
                      Text('${i + 1}/${parts.length}', style: monoStyle(context, size: 11, color: nf.textFaint)),
                    ],
                  ]),
                  if (i == 0 && v.contentWarning != null) _CwBar(text: v.contentWarning!),
                  const SizedBox(height: 3),
                  _PostText(parts[i], empty: v.media.isEmpty),
                  if (i == 0 && v.media.isNotEmpty) ...[
                    const SizedBox(height: Space.sm + 2),
                    MediaGrid(media: v.media),
                  ],
                  if (i == 0 && v.media.isEmpty && v.link != null) ...[
                    const SizedBox(height: Space.sm + 2),
                    _LinkCard(url: v.link!),
                  ],
                ]),
              ),
            ),
          ]),
        ]),
    ]);
  }
}

class _Visual extends StatelessWidget {
  const _Visual({required this.p});
  final TargetPreview p;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final v = p.variant;
    final aspect = _visualAspect(p.descriptor.id, v.media);
    return LayoutBuilder(builder: (context, c) {
      final maxW = aspect < 1 ? (c.maxWidth * 0.62).clamp(160.0, 300.0) : c.maxWidth;
      final w = maxW.toDouble();
      final h = w / aspect;
      final frame = v.media.isEmpty
          ? Container(
              width: w,
              height: h,
              decoration: BoxDecoration(color: nf.surfaceSunken, borderRadius: Radii.rMd, border: Border.all(color: nf.border)),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.add_photo_alternate_outlined, color: nf.textFaint, size: 30),
                const SizedBox(height: Space.sm),
                Text(
                  p.descriptor.media.requiresMedia ? '${p.descriptor.name} needs a photo or video' : 'Add a photo or video',
                  textAlign: TextAlign.center,
                  style: context.text.bodySmall?.copyWith(color: nf.textFaint),
                ),
              ]),
            )
          : Stack(children: [
              MediaThumb(v.media.first, size: h, aspect: aspect, radius: Radii.rMd),
              if (v.media.length > 1)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: Radii.rPill),
                    child: Text('1/${v.media.length}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ),
            ]);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: frame),
        const SizedBox(height: Space.sm + 2),
        if ((v.title ?? '').isNotEmpty) ...[
          Text(v.title!, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.titleSmall),
          const SizedBox(height: 2),
        ],
        RichText(
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
            style: context.text.bodyMedium,
            children: [
              TextSpan(text: '${p.account.handle?.replaceFirst('@', '') ?? p.account.displayName}  ', style: context.text.labelLarge),
              ...highlightSpans(v.text, context.text.bodyMedium!, nf),
            ],
          ),
        ),
      ]);
    });
  }
}

class _Forum extends StatelessWidget {
  const _Forum({required this.p});
  final TargetPreview p;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final v = p.variant;
    final community = (v.extra['subreddit'] ?? v.extra['community'] ?? p.account.config['defaultSubreddit'] ?? p.account.config['community'] ?? '') as Object;
    final where = community.toString().isEmpty
        ? (p.descriptor.id == 'reddit' ? 'r/ (pick a subreddit)' : 'Pick a community')
        : (p.descriptor.id == 'reddit' ? 'r/${community.toString().replaceFirst(RegExp(r'^r/'), '')}' : '!$community');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 20, height: 20, decoration: BoxDecoration(color: brandFor(p.descriptor.id).color, shape: BoxShape.circle)),
        const SizedBox(width: Space.sm),
        Flexible(child: Text(where, overflow: TextOverflow.ellipsis, style: context.text.labelMedium)),
        Text('  · ${p.account.handle ?? p.account.displayName}', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
      ]),
      const SizedBox(height: Space.sm),
      Text(
        (v.title ?? '').isEmpty ? 'Untitled post' : v.title!,
        style: context.text.titleMedium?.copyWith(fontSize: 16.5, color: (v.title ?? '').isEmpty ? nf.textFaint : nf.text),
      ),
      if (v.media.isNotEmpty) ...[
        const SizedBox(height: Space.sm),
        MediaGrid(media: v.media),
      ] else if (v.link != null) ...[
        const SizedBox(height: Space.sm),
        _LinkCard(url: v.link!),
      ],
      if (v.text.trim().isNotEmpty) ...[
        const SizedBox(height: Space.sm),
        _PostText(v.text, maxLines: 6),
      ],
    ]);
  }
}

class _Chat extends StatelessWidget {
  const _Chat({required this.p});
  final TargetPreview p;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final v = p.variant;
    final brand = brandFor(p.descriptor.id).colorFor(Theme.of(context).brightness);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AccountAvatar(p.account, size: 32, showBadge: false),
      const SizedBox(width: Space.sm + 2),
      Flexible(
        child: Container(
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: Color.alphaBlend(brand.withValues(alpha: nf.isDark ? 0.16 : 0.07), nf.surfaceSunken),
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(Radii.lg),
              bottomLeft: Radius.circular(Radii.lg),
              bottomRight: Radius.circular(Radii.lg),
              topLeft: Radius.circular(Radii.xs),
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(p.account.displayName, style: context.text.labelMedium?.copyWith(color: brand)),
            if (v.media.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              MediaGrid(media: v.media, maxHeight: 220),
            ],
            const SizedBox(height: Space.xs),
            _PostText(v.isThread ? v.threadParts.join('\n\n') : v.text, empty: v.media.isEmpty),
            const SizedBox(height: Space.xs),
            Align(alignment: Alignment.centerRight, child: Text('now', style: context.text.bodySmall?.copyWith(color: nf.textFaint, fontSize: 10.5))),
          ]),
        ),
      ),
    ]);
  }
}

class _Blog extends StatelessWidget {
  const _Blog({required this.p});
  final TargetPreview p;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final v = p.variant;
    final title = (v.title ?? '').isNotEmpty ? v.title! : (v.text.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => 'Untitled'));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (v.media.isNotEmpty) ...[
        LayoutBuilder(builder: (context, c) => MediaThumb(v.media.first, size: c.maxWidth / 2.2, aspect: 2.2, radius: Radii.rMd)),
        const SizedBox(height: Space.md),
      ],
      Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.headlineSmall?.copyWith(fontSize: 19)),
      const SizedBox(height: Space.xs),
      Text('By ${p.account.displayName} · ${_readingTime(v.text)} min read', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
      const SizedBox(height: Space.sm),
      Text(v.text.trim().isEmpty ? 'Start writing…' : v.text, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
      if (v.tags.isNotEmpty) ...[
        const SizedBox(height: Space.sm + 2),
        Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
          for (final t in v.tags.take(6)) StatusPill(t, dense: true),
        ]),
      ],
    ]);
  }

  static int _readingTime(String text) => (text.split(RegExp(r'\s+')).length / 220).ceil().clamp(1, 999);
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _PostText extends StatelessWidget {
  const _PostText(this.text, {this.maxLines, this.empty = true});
  final String text;
  final int? maxLines;

  /// Show a placeholder when the text is empty (only if nothing else shows).
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    if (text.trim().isEmpty) {
      return empty ? Text('Your words appear here', style: context.text.bodyMedium?.copyWith(color: nf.textFaint)) : const SizedBox.shrink();
    }
    final style = context.text.bodyMedium!.copyWith(height: 1.45);
    return RichText(
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
      text: TextSpan(style: style, children: highlightSpans(text, style, nf)),
    );
  }
}

class _CwBar extends StatelessWidget {
  const _CwBar({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Container(
      margin: const EdgeInsets.only(top: Space.xs),
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
      decoration: BoxDecoration(color: nf.warningSoft, borderRadius: Radii.rXs),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, size: 14, color: nf.warning),
        const SizedBox(width: Space.xs),
        Expanded(child: Text(text, style: context.text.labelMedium)),
        Text('Show', style: context.text.labelSmall?.copyWith(color: nf.textMuted)),
      ]),
    );
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final u = Uri.tryParse(url);
    final host = (u?.host ?? url).replaceFirst('www.', '');
    return Container(
      decoration: BoxDecoration(border: Border.all(color: nf.border), borderRadius: Radii.rMd),
      clipBehavior: Clip.antiAlias,
      child: Row(children: [
        Container(width: 64, height: 64, color: nf.surfaceSunken, child: Icon(Icons.link_rounded, color: nf.textFaint)),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(host, style: context.text.labelMedium),
            const SizedBox(height: 2),
            Text(u?.path.isNotEmpty == true ? u!.path : url, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11)),
          ]),
        ),
        const SizedBox(width: Space.md),
      ]),
    );
  }
}

/// 1-4 media laid out the way most social apps do.
class MediaGrid extends StatelessWidget {
  const MediaGrid({super.key, required this.media, this.maxHeight = 280});
  final List<MediaAttachment> media;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      const gap = 3.0;
      final shown = media.take(4).toList();
      final extra = media.length - shown.length;
      Widget cell(MediaAttachment m, double cw, double ch, {String? overlay}) => SizedBox(
            width: cw,
            height: ch,
            child: Stack(children: [
              MediaThumb(m, size: ch, aspect: cw / ch, radius: BorderRadius.zero),
              if (overlay != null)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.5),
                    alignment: Alignment.center,
                    child: Text(overlay, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                ),
            ]),
          );
      final Widget grid;
      switch (shown.length) {
        case 1:
          final a = shown.first.aspectRatio ?? 16 / 9;
          final h = (w / a.clamp(0.75, 2.0)).clamp(120.0, maxHeight);
          grid = cell(shown.first, w, h);
        case 2:
          final h = (w / 2 / 1.0).clamp(100.0, maxHeight * 0.8);
          grid = Row(children: [cell(shown[0], (w - gap) / 2, h), const SizedBox(width: gap), cell(shown[1], (w - gap) / 2, h)]);
        case 3:
          final h = (w * 0.56).clamp(120.0, maxHeight);
          grid = Row(children: [
            cell(shown[0], (w - gap) * 0.6, h),
            const SizedBox(width: gap),
            Column(children: [
              cell(shown[1], (w - gap) * 0.4, (h - gap) / 2),
              const SizedBox(height: gap),
              cell(shown[2], (w - gap) * 0.4, (h - gap) / 2),
            ]),
          ]);
        default:
          final cw = (w - gap) / 2;
          final ch = (cw * 0.62).clamp(70.0, maxHeight / 2);
          grid = Column(children: [
            Row(children: [cell(shown[0], cw, ch), const SizedBox(width: gap), cell(shown[1], cw, ch)]),
            const SizedBox(height: gap),
            Row(children: [cell(shown[2], cw, ch), const SizedBox(width: gap), cell(shown[3], cw, ch, overlay: extra > 0 ? '+$extra' : null)]),
          ]);
      }
      return ClipRRect(borderRadius: Radii.rMd, child: grid);
    });
  }
}

class _Issues extends StatelessWidget {
  const _Issues({required this.issues});
  final List<ValidationIssue> issues;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final sorted = [...issues]..sort((a, b) => a.severity.index.compareTo(b.severity.index));
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final i in sorted.take(5))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(
                switch (i.severity) {
                  IssueSeverity.error => Icons.error_rounded,
                  IssueSeverity.warning => Icons.warning_amber_rounded,
                  IssueSeverity.info => Icons.info_outline_rounded,
                },
                size: 15,
                color: switch (i.severity) {
                  IssueSeverity.error => nf.danger,
                  IssueSeverity.warning => nf.warning,
                  IssueSeverity.info => nf.info,
                },
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  i.message,
                  style: context.text.bodySmall?.copyWith(
                    color: i.severity == IssueSeverity.error ? nf.text : nf.textMuted,
                    fontSize: 12,
                  ),
                ),
              ),
            ]),
          ),
        if (sorted.length > 5)
          Text('+${sorted.length - 5} more', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
      ]),
    );
  }
}
