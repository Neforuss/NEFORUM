import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/article_mode.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/surfaces.dart';
import '../activity/time_format.dart';
import 'article_media_chooser.dart';
import 'emoji_insert.dart';
import 'schedule_sheet.dart';

/// 1.4.4: articles. The fields a blog keeps beside the article: title and
/// subtitle in plain sight; cover, excerpt, address (slug), tags, canonical
/// URL, "Publish as" and the schedule under "Article details". The title,
/// tags and schedule are the post's own (every network uses them); the rest
/// is the article's.
class ArticleFieldsPanel extends ConsumerStatefulWidget {
  const ArticleFieldsPanel({super.key});

  @override
  ConsumerState<ArticleFieldsPanel> createState() => _ArticleFieldsPanelState();
}

class _ArticleFieldsPanelState extends ConsumerState<ArticleFieldsPanel> {
  late final TextEditingController _title;
  late final TextEditingController _subtitle;
  late final TextEditingController _excerpt;
  late final TextEditingController _slug;
  late final TextEditingController _canonical;
  final TextEditingController _tag = TextEditingController();
  bool? _open;

  @override
  void initState() {
    super.initState();
    final c = ref.read(composerProvider);
    final doc = c.article ?? const ArticleDocument();
    _title = TextEditingController(text: c.title ?? '');
    _subtitle = TextEditingController(text: doc.subtitle ?? '');
    _excerpt = TextEditingController(text: doc.excerpt ?? '');
    _slug = TextEditingController(text: doc.slug ?? '');
    _canonical = TextEditingController(text: doc.canonicalUrl ?? '');
  }

  @override
  void dispose() {
    for (final c in [_title, _subtitle, _excerpt, _slug, _canonical, _tag]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Fields changed from outside (a post opened, the composer cleared) are
  /// put back in step; a field being typed in already is.
  void _sync(ComposerState c) {
    final doc = c.article ?? const ArticleDocument();
    void put(TextEditingController t, String? v) {
      if (t.text != (v ?? '')) t.text = v ?? '';
    }

    put(_title, c.title);
    put(_subtitle, doc.subtitle);
    put(_excerpt, doc.excerpt);
    put(_slug, doc.slug);
    put(_canonical, doc.canonicalUrl);
  }

  ArticleDocument get _doc => ref.read(composerProvider).article ?? const ArticleDocument();
  void _set(ArticleDocument doc) => ref.read(composerProvider.notifier).setArticle(doc);

  void _addTags(String raw) {
    final notifier = ref.read(composerProvider.notifier);
    final tags = ref.read(composerProvider).tags;
    final fresh = [
      for (final t in raw.split(RegExp(r'[,\n]')).map((t) => t.trim().replaceFirst(RegExp('^#'), '')))
        if (t.isNotEmpty && !tags.contains(t)) t,
    ];
    if (fresh.isNotEmpty) notifier.setTags([...tags, ...fresh]);
    _tag.clear();
  }

  Future<void> _chooseCover() async {
    final current = _doc.cover;
    final ids = await showArticleMediaChooser(context, kind: ArticleMediaKind.photo, title: 'Choose the cover photo');
    if (ids == null || ids.isEmpty || !mounted) return;
    final doc = _doc;
    _set(doc.copyWith(cover: ArticleMediaRef(ids.first, caption: current?.caption, credit: current?.credit)));
  }

  Future<void> _schedule() async {
    final when = await showScheduleSheet(context, initial: ref.read(composerProvider).scheduledAt);
    if (when == null || !mounted) return;
    ref.read(composerProvider.notifier).setSchedule(when == kClearSchedule ? null : when);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(composerProvider, (_, next) => _sync(next));
    final nf = context.nf;
    final t = context.text;
    final c = ref.watch(composerProvider);
    final doc = c.article ?? const ArticleDocument();
    final notifier = ref.read(composerProvider.notifier);
    final compact = context.isCompact;
    final open = _open ?? !compact;
    final cover = doc.cover == null ? null : c.media.where((m) => m.id == doc.cover!.mediaId).firstOrNull;
    final autoSlug = slugFromTitle(c.title ?? '');
    InputDecoration bare(String hint, TextStyle? style) => InputDecoration(
          hintText: hint,
          hintStyle: style?.copyWith(color: nf.textFaint),
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          isDense: true,
        );

    final summary = [
      if (cover != null) 'cover',
      if ((doc.excerpt ?? '').trim().isNotEmpty) 'excerpt',
      if (c.tags.isNotEmpty) '${c.tags.length} ${c.tags.length == 1 ? 'tag' : 'tags'}',
      if (doc.isDraft) 'draft',
      if (c.scheduledAt != null) 'scheduled',
    ];

    return NfCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xl, Space.lg, Space.xl, Space.xs),
          child: EmojiTargetField(
            controller: _title,
            onChanged: notifier.setTitle,
            child: TextField(
              key: const ValueKey('article-title'),
              controller: _title,
              onChanged: notifier.setTitle,
              style: t.headlineSmall,
              textInputAction: TextInputAction.next,
              decoration: bare('Title', t.headlineSmall),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xl, Space.xs, Space.xl, Space.md),
          child: TextField(
            key: const ValueKey('article-subtitle'),
            controller: _subtitle,
            style: t.titleMedium?.copyWith(color: nf.textMuted),
            decoration: bare('Subtitle (optional)', t.titleMedium),
            onChanged: (v) => _set(v.trim().isEmpty ? _doc.copyWith(clearSubtitle: true) : _doc.copyWith(subtitle: v)),
          ),
        ),
        Divider(height: 1, color: nf.border),
        InkWell(
          key: const ValueKey('article-details-toggle'),
          onTap: () => setState(() => _open = !open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md),
            child: Row(children: [
              Icon(Icons.tune_rounded, size: 18, color: nf.textMuted),
              const SizedBox(width: Space.sm),
              Text('Article details', style: t.labelLarge),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(summary.isEmpty ? 'Cover, excerpt, address, tags' : summary.join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: nf.textFaint)),
              ),
              Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: nf.textMuted),
            ]),
          ),
        ),
        if (open)
          Padding(
            key: const ValueKey('article-details'),
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // Cover
              Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                if (cover != null)
                  MediaThumb(cover, size: 64, aspect: 1.6, radius: Radii.rSm)
                else
                  Container(
                    width: 64 * 1.6,
                    height: 64,
                    decoration: BoxDecoration(color: nf.surfaceSunken, borderRadius: Radii.rSm),
                    child: Icon(Icons.image_outlined, color: nf.textFaint),
                  ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Cover photo', style: t.labelLarge),
                    Text(cover == null ? 'Shown above the article and in link previews' : (cover.fileName ?? 'Photo'),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: nf.textMuted)),
                  ]),
                ),
                TextButton(key: const ValueKey('article-cover-choose'), onPressed: _chooseCover, child: Text(cover == null ? 'Choose' : 'Change')),
                if (doc.cover != null)
                  ToolButton(
                    key: const ValueKey('article-cover-remove'),
                    icon: Icons.close_rounded,
                    tooltip: 'No cover photo',
                    size: 32,
                    onPressed: () => _set(_doc.copyWith(clearCover: true)),
                  ),
              ]),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('article-excerpt'),
                controller: _excerpt,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Excerpt', helperText: 'A short summary for lists, previews and search results'),
                onChanged: (v) => _set(v.trim().isEmpty ? _doc.copyWith(clearExcerpt: true) : _doc.copyWith(excerpt: v)),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('article-slug'),
                controller: _slug,
                style: monoStyle(context, size: 13),
                decoration: InputDecoration(
                  labelText: 'Address ending (slug)',
                  hintText: autoSlug.isEmpty ? 'made from the title' : autoSlug,
                  helperText: _slug.text.trim().isEmpty ? 'Empty: made from the title${autoSlug.isEmpty ? '' : ' ($autoSlug)'}' : null,
                  suffixIcon: _slug.text.trim().isEmpty && autoSlug.isNotEmpty
                      ? IconButton(
                          tooltip: 'Edit the address made from the title',
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () {
                            _slug.text = autoSlug;
                            _set(_doc.copyWith(slug: autoSlug));
                          },
                        )
                      : null,
                ),
                onChanged: (v) {
                  // Kept as typed (the networks trim it), so the field never jumps.
                  _set(v.trim().isEmpty ? _doc.copyWith(clearSlug: true) : _doc.copyWith(slug: v));
                  setState(() {});
                },
              ),
              const SizedBox(height: Space.md),
              // Tags
              Wrap(spacing: Space.xs + 2, runSpacing: Space.xs + 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                for (final tag in c.tags)
                  InputChip(
                    key: ValueKey('article-tag-$tag'),
                    label: Text(tag),
                    onDeleted: () => notifier.setTags(c.tags.where((x) => x != tag).toList()),
                    deleteButtonTooltipMessage: 'Remove the tag $tag',
                  ),
                SizedBox(
                  width: compact ? double.infinity : 220,
                  child: TextField(
                    key: const ValueKey('article-tag-input'),
                    controller: _tag,
                    decoration: const InputDecoration(labelText: 'Add tags', hintText: 'travel, photography', isDense: true),
                    onChanged: (v) {
                      if (v.contains(',')) _addTags(v);
                    },
                    onSubmitted: _addTags,
                  ),
                ),
              ]),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('article-canonical'),
                controller: _canonical,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Canonical URL (optional)',
                  helperText: 'Where the article first appeared, so search engines credit that page',
                ),
                onChanged: (v) => _set(v.trim().isEmpty ? _doc.copyWith(clearCanonicalUrl: true) : _doc.copyWith(canonicalUrl: v)),
              ),
              const SizedBox(height: Space.lg),
              Text('Publish as', style: t.labelLarge),
              const SizedBox(height: Space.sm),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ArticleStatus?>(
                  key: const ValueKey('article-status'),
                  segments: const [
                    ButtonSegment(value: null, label: Text('As set')),
                    ButtonSegment(value: ArticleStatus.published, label: Text('Published')),
                    ButtonSegment(value: ArticleStatus.draft, label: Text('Draft')),
                  ],
                  selected: {doc.status},
                  onSelectionChanged: (s) => _set(s.first == null ? _doc.copyWith(clearStatus: true) : _doc.copyWith(status: s.first)),
                ),
              ),
              const SizedBox(height: Space.xs),
              Text(
                switch (doc.status) {
                  null => 'Each blog as its account is set.',
                  ArticleStatus.published => 'Published on every blog.',
                  ArticleStatus.draft => 'Saved as a draft on the blogs that keep drafts, to publish there yourself.',
                },
                style: t.bodySmall?.copyWith(color: nf.textMuted),
              ),
              const SizedBox(height: Space.lg),
              Row(children: [
                Icon(Icons.event_outlined, size: 18, color: nf.textMuted),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    c.scheduledAt == null
                        ? 'Goes out when you post'
                        : 'Scheduled for ${TimeFormatting.from(ref.watch(settingsProvider), context).scheduled(c.scheduledAt!)}',
                    style: t.bodyMedium,
                  ),
                ),
                TextButton(key: const ValueKey('article-schedule'), onPressed: _schedule, child: Text(c.scheduledAt == null ? 'Schedule' : 'Change')),
              ]),
            ]),
          ),
      ]),
    );
  }
}
