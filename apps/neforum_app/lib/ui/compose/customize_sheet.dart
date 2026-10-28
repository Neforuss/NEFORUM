import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../platform/env.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/char_ring.dart';
import '../../widgets/media_thumb.dart';

/// Platform-specific knobs adapters read from `PostOverrides.extra`.
class _Extra {
  const _Extra(this.key, this.label, {this.hint, this.options, this.optionLabels, this.defaultLabel = 'Default', this.boolean = false, this.help});
  final String key;
  final String label;
  final String? hint;
  final List<String>? options;

  /// Words to show for [options] (otherwise the raw values, in mono).
  final Map<String, String>? optionLabels;
  final String defaultLabel;
  final bool boolean;
  final String? help;
}

const Map<String, List<_Extra>> _extrasByPlatform = {
  'reddit': [
    _Extra('subreddit', 'Subreddit', hint: 'e.g. selfhosted (without r/)'),
    _Extra('flair_id', 'Flair ID', hint: 'Optional; some subreddits require one'),
    _Extra('nsfw', 'Mark as NSFW', boolean: true),
    _Extra('spoiler', 'Mark as spoiler', boolean: true),
  ],
  'lemmy': [_Extra('community', 'Community', hint: 'e.g. selfhosted@lemmy.world')],
  'pinterest': [_Extra('board', 'Board', hint: 'Board name or ID')],
  'youtube': [_Extra('privacyStatus', 'Visibility', options: ['public', 'unlisted', 'private'])],
  'tiktok': [
    _Extra('privacyLevel', 'Who can watch',
        options: ['PUBLIC_TO_EVERYONE', 'MUTUAL_FOLLOW_FRIENDS', 'FOLLOWER_OF_CREATOR', 'SELF_ONLY'],
        help: 'Apps TikTok has not audited can only post privately (SELF_ONLY).'),
  ],
  'tumblr': [
    _Extra('tumblrPostType', 'Post type',
        options: ['quote', 'chat', 'audio'],
        optionLabels: {'quote': 'Quote', 'chat': 'Chat', 'audio': 'Audio (a SoundCloud, Spotify or Bandcamp link)'},
        defaultLabel: 'Automatic (text, photo, video or link)',
        help: 'Quote: the text is the quote. Chat: one line per speaker, like "Alex: hi". Audio: the post\'s link is the track.'),
    _Extra('tumblrQuoteSource', 'Quote source', hint: 'Who said it (for quote posts; otherwise the title is used)'),
    _Extra('state', 'Publish as', options: ['published', 'queue', 'draft']),
  ],
  'discord': [
    _Extra(kMentionEveryoneKey, 'Mention @everyone',
        boolean: true,
        help: 'The first message starts with @everyone, which notifies everyone in the channel. '
            'The default is in Settings > Posting.'),
  ],
};

/// Post / Story / Post + Story for a network that takes stories
/// (`PlatformAdapter.supportsStories`).
class PlacementSelector extends StatelessWidget {
  const PlacementSelector({super.key, required this.value, required this.onChanged});
  final PostPlacement value;
  final ValueChanged<PostPlacement> onChanged;

  static IconData _icon(PostPlacement p) => switch (p) {
        PostPlacement.feed => Icons.grid_view_rounded,
        PostPlacement.story => Icons.amp_stories_outlined,
        PostPlacement.feedAndStory => Icons.library_add_outlined,
      };

  @override
  Widget build(BuildContext context) => SegmentedButton<PostPlacement>(
        segments: [
          for (final p in PostPlacement.values)
            ButtonSegment(value: p, label: Text(p.label, maxLines: 1, overflow: TextOverflow.ellipsis), icon: Icon(_icon(p), size: 18)),
        ],
        selected: {value},
        showSelectedIcon: false,
        onSelectionChanged: (s) => onChanged(s.single),
      );
}

Future<void> showCustomizeSheet(BuildContext context, TargetPreview preview) {
  final sheet = CustomizeSheet(preview: preview);
  if (context.isCompact) {
    // Lifted above the keyboard, so the field being typed in stays visible.
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom), child: sheet),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 620, maxHeight: 820), child: sheet),
    ),
  );
}

/// Per-network override editor.
class CustomizeSheet extends ConsumerStatefulWidget {
  const CustomizeSheet({super.key, required this.preview});
  final TargetPreview preview;

  @override
  ConsumerState<CustomizeSheet> createState() => _CustomizeSheetState();
}

class _CustomizeSheetState extends ConsumerState<CustomizeSheet> {
  late final TextEditingController _text;
  late final TextEditingController _title;
  late final TextEditingController _cw;
  late Set<String> _media;
  late PostVisibility? _visibility;
  late final Map<String, Object?> _extra;
  final Map<String, TextEditingController> _extraCtl = {};

  TargetPreview get p => widget.preview;
  PostOverrides get o => p.target.overrides;

  /// The main post's text as this sheet shows it: the unsplit words for a
  /// thread (every part the user wrote, joined), else what the network gets.
  String _mainText(ComposerState c) => p.variant.isThread ? c.joinedParts : p.variant.text;

  /// The value a yes/no option has when this post makes no choice: the
  /// Settings default where there is one, else off.
  bool _defaultOf(String key) => switch (key) {
        kMentionEveryoneKey => ref.read(settingsProvider).discordMentionEveryone,
        _ => false,
      };

  @override
  void initState() {
    super.initState();
    final c = ref.read(composerProvider);
    _text = TextEditingController(text: o.text ?? _mainText(c));
    _title = TextEditingController(text: o.title ?? c.title ?? '');
    _cw = TextEditingController(text: o.contentWarning ?? c.contentWarning ?? '');
    _media = (o.mediaIds ?? c.media.map((m) => m.id)).toSet();
    _visibility = o.visibility;
    _extra = {...o.extra};
    for (final e in _extrasByPlatform[p.descriptor.id] ?? const <_Extra>[]) {
      if (!e.boolean && e.options == null) {
        _extraCtl[e.key] = TextEditingController(text: '${_extra[e.key] ?? ''}');
      }
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _title.dispose();
    _cw.dispose();
    for (final c in _extraCtl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final c = ref.read(composerProvider);
    final extra = {..._extra};
    for (final e in _extraCtl.entries) {
      final v = e.value.text.trim();
      if (v.isEmpty) {
        extra.remove(e.key);
      } else {
        extra[e.key] = v;
      }
    }
    // Only choices that differ from the default are kept.
    extra.removeWhere((k, v) => v == null || v is bool && v == _defaultOf(k));
    final allMedia = c.media.map((m) => m.id).toList();
    final mediaIds = allMedia.where(_media.contains).toList();
    final textChanged = _text.text != _mainText(c);
    final o = PostOverrides(
      text: textChanged ? _text.text : this.o.text,
      title: _title.text.trim().isEmpty || _title.text == (c.title ?? '') ? null : _title.text.trim(),
      mediaIds: mediaIds.length == allMedia.length ? null : mediaIds,
      contentWarning: _cw.text.trim().isEmpty || _cw.text == (c.contentWarning ?? '') ? null : _cw.text.trim(),
      visibility: _visibility,
      extra: extra.cast<String, dynamic>(),
      // Set in the schedule sheet, not here.
      scheduledAt: this.o.scheduledAt,
    );
    final notifier = ref.read(composerProvider.notifier);
    if (o.isEmpty) {
      notifier.clearOverride(p.account.id);
    } else {
      notifier.setOverride(p.account.id, o);
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final d = p.descriptor;
    final c = ref.watch(composerProvider);
    final rules = d.text;
    final used = rules.maxLength == null ? _text.text.characters.length : TextCounter.count(_text.text, rules);
    final extras = _extrasByPlatform[d.id] ?? const <_Extra>[];
    final stories = ref.watch(registryProvider).byId(p.account.platformId)?.supportsStories(p.account) ?? false;

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.lg, Space.md),
        child: Row(children: [
          PlatformTile(d.id, size: 40),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Customize for ${d.name}', style: context.text.headlineSmall),
              Text(p.account.handle ?? p.account.displayName, style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
            ]),
          ),
          TierBadge(p.account.tier),
        ]),
      ),
      Flexible(
        child: SingleChildScrollView(
          keyboardDismissBehavior: Env.isMobile ? ScrollViewKeyboardDismissBehavior.onDrag : ScrollViewKeyboardDismissBehavior.manual,
          padding: const EdgeInsets.fromLTRB(Space.xxl, 0, Space.xxl, Space.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              'Changes here apply only to ${d.name}. Everything else keeps using the main post.',
              style: context.text.bodySmall,
            ),
            const SizedBox(height: Space.lg),
            if (rules.titleSupported) ...[
              TextField(controller: _title, decoration: InputDecoration(labelText: 'Title', counterText: rules.titleMax == null ? null : '${_title.text.length}/${rules.titleMax}'), onChanged: (_) => setState(() {})),
              const SizedBox(height: Space.md),
            ],
            Stack(children: [
              TextField(
                controller: _text,
                minLines: 5,
                maxLines: 12,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Text', alignLabelWithHint: true, contentPadding: EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.x4, Space.lg)),
              ),
              Positioned(right: 10, bottom: 10, child: CharRing(used: used, max: rules.maxLength, size: 22)),
            ]),
            if (rules.supportsContentWarning) ...[
              const SizedBox(height: Space.md),
              TextField(controller: _cw, decoration: const InputDecoration(labelText: 'Content warning', prefixIcon: Icon(Icons.warning_amber_rounded))),
            ],
            if (c.media.isNotEmpty && d.media.supportsAnyMedia) ...[
              const SizedBox(height: Space.lg),
              Text('Media to include', style: context.text.titleSmall),
              const SizedBox(height: Space.sm),
              Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
                for (final m in c.media)
                  GestureDetector(
                    onTap: () => setState(() => _media.contains(m.id) ? _media.remove(m.id) : _media.add(m.id)),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Stack(children: [
                        AnimatedOpacity(duration: Motion.fast, opacity: _media.contains(m.id) ? 1 : 0.35, child: MediaThumb(m, size: 72)),
                        Positioned(
                          right: 4,
                          top: 4,
                          child: Icon(
                            _media.contains(m.id) ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                            size: 20,
                            color: _media.contains(m.id) ? nf.accent : Colors.white,
                          ),
                        ),
                      ]),
                    ),
                  ),
              ]),
            ],
            const SizedBox(height: Space.lg),
            DropdownButtonFormField<PostVisibility?>(
              initialValue: _visibility,
              decoration: const InputDecoration(labelText: 'Visibility'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Same as the main post')),
                for (final v in PostVisibility.values) DropdownMenuItem(value: v, child: Text(_visLabel(v))),
              ],
              onChanged: (v) => setState(() => _visibility = v),
            ),
            if (stories) ...[
              const SizedBox(height: Space.xl),
              Text('Post or story', style: context.text.titleSmall),
              const SizedBox(height: Space.sm),
              PlacementSelector(
                value: placementOfExtra(_extra.cast<String, dynamic>()),
                onChanged: (v) => setState(() {
                  final next = extraWithPlacement(_extra.cast<String, dynamic>(), v);
                  _extra
                    ..clear()
                    ..addAll(next);
                }),
              ),
              const SizedBox(height: Space.xs),
              Text(_placementHelp(placementOfExtra(_extra.cast<String, dynamic>()), d.name), style: context.text.bodySmall),
            ],
            if (extras.isNotEmpty) ...[
              const SizedBox(height: Space.xl),
              Text('${d.name} options', style: context.text.titleSmall),
              const SizedBox(height: Space.sm),
              for (final e in extras) Padding(padding: const EdgeInsets.only(bottom: Space.md), child: _extraField(e)),
            ],
          ]),
        ),
      ),
      Divider(height: 1, color: nf.border),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.md, Space.xxl, Space.lg),
        child: Row(children: [
          if (!o.isEmpty)
            TextButton.icon(
              onPressed: () {
                ref.read(composerProvider.notifier).clearOverride(p.account.id);
                Navigator.pop(context);
              },
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Reset'),
              style: TextButton.styleFrom(foregroundColor: nf.textMuted),
            ),
          const Spacer(),
          TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
          const SizedBox(width: Space.sm),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ]),
      ),
    ]);
  }

  Widget _extraField(_Extra e) {
    final nf = context.nf;
    if (e.boolean) {
      final value = _extra[e.key];
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(e.label, style: context.text.bodyMedium),
        subtitle: e.help == null ? null : Text(e.help!, style: context.text.bodySmall),
        value: value is bool ? value : _defaultOf(e.key),
        onChanged: (v) => setState(() => _extra[e.key] = v),
      );
    }
    if (e.options != null) {
      final current = _extra[e.key] as String?;
      return DropdownButtonFormField<String?>(
        initialValue: e.options!.contains(current) ? current : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: e.label, helperText: e.help, helperMaxLines: 3),
        items: [
          DropdownMenuItem(value: null, child: Text(e.defaultLabel)),
          for (final o in e.options!)
            DropdownMenuItem(
              value: o,
              child: e.optionLabels?[o] != null ? Text(e.optionLabels![o]!, overflow: TextOverflow.ellipsis) : Text(o, style: monoStyle(context, color: nf.text)),
            ),
        ],
        onChanged: (v) => setState(() => _extra[e.key] = v),
      );
    }
    return TextField(
      controller: _extraCtl[e.key],
      decoration: InputDecoration(labelText: e.label, hintText: e.hint, helperText: e.help),
    );
  }

  static String _placementHelp(PostPlacement p, String network) => switch (p) {
        PostPlacement.feed => 'A regular $network post with your caption.',
        PostPlacement.story => 'A story without a caption: each photo or video becomes a frame, words only become a 9:16 text card.',
        PostPlacement.feedAndStory =>
          'The post with your caption, and the same photos or videos as a story (9:16, no caption) on the same account.',
      };

  static String _visLabel(PostVisibility v) => switch (v) {
        PostVisibility.public => 'Public',
        PostVisibility.unlisted => 'Unlisted',
        PostVisibility.followers => 'Followers only',
        PostVisibility.private => 'Private',
      };
}
