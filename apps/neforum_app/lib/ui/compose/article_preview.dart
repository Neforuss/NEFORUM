import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import 'article_blocks.dart';

// 1.4.4: articles. Under each network's preview: what that network gets of
// the article, before anything is posted. The render report (the same
// serializer the network's adapter runs, ArticleRenderer.reportFor) names
// every block or field it leaves out or changes, and each block (and the
// cover) can be left out for that network alone
// (PostOverrides.excludedBlockIds).

/// The article as network [preview] gets it, with its render report and the
/// choice of blocks for that network.
class ArticlePreviewSection extends ConsumerStatefulWidget {
  const ArticlePreviewSection({super.key, required this.preview});
  final TargetPreview preview;

  @override
  ConsumerState<ArticlePreviewSection> createState() => _ArticlePreviewSectionState();
}

class _ArticlePreviewSectionState extends ConsumerState<ArticlePreviewSection> {
  bool _choosing = false;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final t = context.text;
    final p = widget.preview;
    final d = p.descriptor;
    final v = p.variant;
    final doc = ref.watch(composerProvider.select((c) => c.article)) ?? const ArticleDocument();
    final media = ref.watch(composerProvider.select((c) => c.media));
    final report = ArticleRenderer.reportFor(v, d, tier: p.account.tier);
    final excluded = p.target.overrides.excludedBlockIds.toSet();
    final sent = v.article ?? const ArticleDocument();
    final total = doc.blocks.length + (doc.cover == null ? 0 : 1);
    final going = doc.blocks.where((b) => !excluded.contains(b.id)).length + (doc.cover != null && !excluded.contains(ArticleDocument.coverId) ? 1 : 0);
    final dropped = report.dropped.length;
    final changed = report.degraded.length;
    final handoff = p.account.tier == PlatformTier.handoff;

    String labelOf(ArticleRenderIssue i) {
      if (i.blockId == ArticleDocument.coverId) return 'Cover';
      final b = i.blockId == null ? null : (sent.blockById(i.blockId!) ?? doc.blockById(i.blockId!));
      if (b != null) return articleBlockLabel(b, media: media);
      return switch (i.field) {
        'subtitle' => 'Subtitle',
        'excerpt' => 'Excerpt',
        'slug' => 'Address ending',
        'canonicalUrl' => 'Canonical URL',
        'status' => 'Publish as',
        _ => 'Article',
      };
    }

    void setExcluded(Set<String> ids) => ref.read(composerProvider.notifier).setExcludedBlocks(p.account.id, [
          if (ids.contains(ArticleDocument.coverId)) ArticleDocument.coverId,
          for (final b in doc.blocks)
            if (ids.contains(b.id)) b.id,
        ]);

    Widget row(String id, IconData icon, String label) {
      final on = !excluded.contains(id);
      final issues = report.forBlock(id).toList();
      final worst = issues.any((i) => i.isDropped)
          ? Tone.warning
          : issues.isNotEmpty
              ? Tone.info
              : null;
      return InkWell(
        key: ValueKey('article-include-${p.account.id}-$id'),
        onTap: () => setExcluded(on ? {...excluded, id} : ({...excluded}..remove(id))),
        child: Semantics(
          checked: on,
          label: '$label: ${on ? 'goes to ${d.name}' : 'left out for ${d.name}'}',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xxs),
            child: Row(children: [
              Checkbox(value: on, onChanged: (_) => setExcluded(on ? {...excluded, id} : ({...excluded}..remove(id))), visualDensity: VisualDensity.compact),
              Icon(icon, size: 16, color: on ? nf.textMuted : nf.textFaint),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: on ? nf.text : nf.textFaint, decoration: on ? null : TextDecoration.lineThrough)),
              ),
              if (on && worst != null)
                Tooltip(
                  message: issues.map((i) => i.message).join('\n'),
                  child: Icon(worst == Tone.warning ? Icons.warning_amber_rounded : Icons.info_outline_rounded, size: 15, color: worst.fg(nf)),
                ),
            ]),
          ),
        ),
      );
    }

    return Padding(
      key: ValueKey('article-preview-${p.account.id}'),
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm + 2, Space.md, Space.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.article_outlined, size: 16, color: nf.textMuted),
          const SizedBox(width: Space.xs + 2),
          Expanded(
            child: Text(
              handoff ? 'Article, pasted as formatted text' : 'Article · $going of $total ${total == 1 ? 'block' : 'blocks'}',
              style: t.labelMedium,
            ),
          ),
          if (report.isLossless)
            const StatusPill('Goes out whole', tone: Tone.success, dense: true, icon: Icons.check_rounded)
          else ...[
            if (dropped > 0) StatusPill('$dropped left out', tone: Tone.warning, dense: true),
            if (dropped > 0 && changed > 0) const SizedBox(width: Space.xs),
            if (changed > 0) StatusPill('$changed changed', tone: Tone.info, dense: true),
          ],
        ]),
        if (!report.isLossless) ...[
          const SizedBox(height: Space.sm),
          for (final i in report.issues)
            Padding(
              key: ValueKey('article-report-${p.account.id}-${i.code}-${i.blockId ?? i.field}'),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(i.isDropped ? Icons.remove_circle_outline_rounded : Icons.swap_horiz_rounded, size: 15, color: i.isDropped ? nf.warning : nf.info),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: '${labelOf(i)}. ', style: const TextStyle(fontWeight: FontWeight.w600)),
                      TextSpan(text: i.message),
                    ]),
                    style: t.bodySmall?.copyWith(color: nf.textMuted, fontSize: 12),
                  ),
                ),
              ]),
            ),
        ],
        if (total > 0) ...[
          const SizedBox(height: Space.xs),
          Row(children: [
            TextButton.icon(
              key: ValueKey('article-choose-${p.account.id}'),
              onPressed: () => setState(() => _choosing = !_choosing),
              icon: Icon(_choosing ? Icons.expand_less_rounded : Icons.checklist_rounded, size: 16),
              label: Text(_choosing ? 'Done' : 'Choose what goes to ${d.name}'),
              style: TextButton.styleFrom(foregroundColor: nf.textMuted, textStyle: t.labelMedium, padding: const EdgeInsets.symmetric(horizontal: Space.sm)),
            ),
            const Spacer(),
            if (excluded.isNotEmpty)
              TextButton(
                key: ValueKey('article-include-all-${p.account.id}'),
                onPressed: () => setExcluded(const {}),
                style: TextButton.styleFrom(foregroundColor: nf.textMuted, textStyle: t.labelMedium),
                child: const Text('Everything'),
              ),
          ]),
          if (_choosing)
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (doc.cover != null) row(ArticleDocument.coverId, Icons.image_outlined, 'Cover photo'),
              for (final b in doc.blocks) row(b.id, articleBlockIcon(b.type), articleBlockLabel(b, media: media)),
            ]),
        ],
      ]),
    );
  }
}

/// Under a network that does not get the article while the post is one: what
/// it gets instead. Null when there is nothing to say.
String? articleShortVersionNote(TargetPreview p, {required bool articleMode}) {
  if (!articleMode || p.variant.hasArticle) return null;
  final d = p.descriptor;
  if (p.target.overrides.text != null) return '${d.name} gets the words you wrote for it, not the article.';
  if (d.articleFormat != null && d.articleOptionKey != null && p.account.tier.isAutomatic) {
    final option = d.options.where((o) => o.key == d.articleOptionKey).firstOrNull?.label ?? 'its article option';
    return '${d.name} gets the short version. To send the whole article, turn on "$option" in Customize.';
  }
  return '${d.name} gets the short version: the article\'s words and files as one post.';
}
