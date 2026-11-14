import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../platform/env.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/char_ring.dart';
import '../../widgets/layout.dart' show showToast;
import '../../widgets/media_thumb.dart';
import 'emoji_insert.dart';

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

  /// The options this account can set ([PlatformAdapter.postOptionsFor]),
  /// drawn from their declarations in core.
  late final List<PostOption> _options;

  /// "Keep these for every post from this account".
  bool _remember = false;
  bool _showMore = false;

  TargetPreview get p => widget.preview;
  PostOverrides get o => p.target.overrides;

  /// The main post's text as this sheet shows it: the unsplit words for a
  /// thread (every part the user wrote, joined), else what the network gets.
  String _mainText(ComposerState c) => p.variant.isThread ? c.joinedParts : p.variant.text;

  /// The options the account remembers (`postDefaults`), under their
  /// declared keys.
  Map<String, dynamic> get _accountDefaults =>
      canonicalOptionKeys(p.descriptor.options, (_account.config['postDefaults'] as Map?)?.cast<String, dynamic>() ?? const {});

  /// The stored account as it is now, not the preview's copy of it.
  ConnectedAccount get _account => ref.read(accountListProvider).where((a) => a.id == p.account.id).firstOrNull ?? p.account;

  /// What [opt] is when this post makes no choice: the Settings default
  /// where there is one, else the account's remembered value, else the
  /// network's own default.
  Object? _baseline(PostOption opt) {
    if (opt.key == kMentionEveryoneKey && p.descriptor.id == 'discord') return ref.read(settingsProvider).discordMentionEveryone;
    return opt.coerce(_accountDefaults[opt.key]) ?? opt.defaultValue;
  }

  /// This post's own value of [opt], or null.
  Object? _own(PostOption opt) => opt.coerce(opt.valueIn(_extra.cast<String, dynamic>()));

  @override
  void initState() {
    super.initState();
    final c = ref.read(composerProvider);
    _text = TextEditingController(text: o.text ?? _mainText(c));
    _title = TextEditingController(text: o.title ?? c.title ?? '');
    _cw = TextEditingController(text: o.contentWarning ?? c.contentWarning ?? '');
    _media = (o.mediaIds ?? c.media.map((m) => m.id)).toSet();
    _visibility = o.visibility;
    // An option saved under an older key shows (and is saved) as the declared one.
    _extra = {...canonicalOptionKeys(p.descriptor.options, o.extra)};
    final adapter = ref.read(registryProvider).byId(p.account.platformId);
    _options = adapter?.postOptionsFor(p.account) ?? p.descriptor.userOptionsFor(p.account.tier);
    for (final opt in _options) {
      if (opt.kind == PostOptionKind.text || opt.kind == PostOptionKind.number) {
        _extraCtl[opt.key] = TextEditingController(text: '${_own(opt) ?? ''}');
      }
    }
    // Folded options this post already uses are shown.
    _showMore = _options.any((opt) => opt.surface == PostOptionSurface.more && _own(opt) != null);
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
      extra[e.key] = e.value.text;
    }
    // Only choices that differ from the default are kept, under their
    // declared key.
    final known = c.media.map((m) => m.id).toSet();
    for (final opt in _options) {
      for (final alias in opt.aliases) {
        extra.remove(alias);
      }
      var v = opt.coerce(extra[opt.key]);
      if (v is List) v = v.where(known.contains).toList();
      if (v == null || (v is List && v.isEmpty) || v == _baseline(opt)) {
        extra.remove(opt.key);
      } else {
        extra[opt.key] = v;
      }
    }
    if (_remember) _rememberForAccount(extra);
    extra.removeWhere((k, v) => v == null || (v == false && p.descriptor.option(k) == null));
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

  /// The options that can be kept for the account ([PostOptionScope]).
  List<PostOption> get _rememberable => [for (final opt in _options) if (opt.scope != PostOptionScope.post) opt];

  /// Which options "Keep these" saves: up to three by name, then a count.
  String _rememberSummary() {
    final names = _rememberable.map((opt) => opt.label).toList();
    final shown = names.length <= 3 ? names.join(', ') : '${names.take(3).join(', ')} and ${names.length - 3} more';
    return 'Saves $shown as the account\'s default for new posts. Each post can still change them.';
  }

  /// Writes this sheet's values of [_rememberable] into the account's
  /// remembered options (`postDefaults`, which every post from the account
  /// starts from), and takes them out of this post's own [extra]: the post
  /// now gets them from the account.
  void _rememberForAccount(Map<String, Object?> extra) {
    final defaults = {..._accountDefaults};
    for (final opt in _rememberable) {
      final value = extra.containsKey(opt.key) ? opt.coerce(extra[opt.key]) : _baseline(opt);
      opt.aliases.forEach(defaults.remove);
      if (value == null || value == opt.defaultValue) {
        defaults.remove(opt.key);
      } else {
        defaults[opt.key] = value;
      }
      extra.remove(opt.key);
    }
    final account = _account;
    final config = {...account.config, 'postDefaults': defaults};
    if (defaults.isEmpty) config.remove('postDefaults');
    unawaited(ref.read(servicesProvider).accounts.upsert(account.copyWith(config: config)));
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final d = p.descriptor;
    final c = ref.watch(composerProvider);
    final rules = d.text;
    final used = rules.maxLength == null ? _text.text.characters.length : TextCounter.count(_text.text, rules);
    final upFront = [for (final opt in _options) if (opt.surface == PostOptionSurface.main) opt];
    final more = [for (final opt in _options) if (opt.surface == PostOptionSurface.more) opt];
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
          const EmojiButton(),
          const SizedBox(width: Space.xs),
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
              EmojiTargetField(
                controller: _title,
                onChanged: (_) => setState(() {}),
                child: TextField(controller: _title, decoration: InputDecoration(labelText: 'Title', counterText: rules.titleMax == null ? null : '${_title.text.length}/${rules.titleMax}'), onChanged: (_) => setState(() {})),
              ),
              const SizedBox(height: Space.md),
            ],
            Stack(children: [
              EmojiTargetField(
                controller: _text,
                onChanged: (_) => setState(() {}),
                isDefault: true,
                child: TextField(
                  controller: _text,
                  minLines: 5,
                  maxLines: 12,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'Text', alignLabelWithHint: true, contentPadding: EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.x4, Space.lg)),
                ),
              ),
              Positioned(right: 10, bottom: 10, child: CharRing(used: used, max: rules.maxLength, size: 22)),
            ]),
            if (rules.supportsContentWarning) ...[
              const SizedBox(height: Space.md),
              EmojiTargetField(
                controller: _cw,
                child: TextField(controller: _cw, decoration: const InputDecoration(labelText: 'Content warning', prefixIcon: Icon(Icons.warning_amber_rounded))),
              ),
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
            if (upFront.isNotEmpty || more.isNotEmpty) ...[
              const SizedBox(height: Space.xl),
              Text('${d.name} options', style: context.text.titleSmall),
              const SizedBox(height: Space.sm),
              for (final opt in upFront) _optionRow(opt, c),
              if (more.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('more-options'),
                    onPressed: () => setState(() => _showMore = !_showMore),
                    icon: Icon(_showMore ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
                    label: Text(_showMore ? 'Fewer options' : 'More options (${more.length})'),
                  ),
                ),
                AnimatedSize(
                  duration: context.motion(Motion.fast),
                  alignment: Alignment.topCenter,
                  child: _showMore
                      ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final opt in more) _optionRow(opt, c)])
                      : const SizedBox(width: double.infinity),
                ),
              ],
              if (_rememberable.isNotEmpty)
                CheckboxListTile(
                  key: const Key('remember-options'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _remember,
                  onChanged: (v) => setState(() => _remember = v ?? false),
                  title: Text('Keep these for every ${d.name} post from this account', style: context.text.bodyMedium),
                  subtitle: Text(_rememberSummary(), style: context.text.bodySmall),
                ),
            ],
            if (d.id == 'youtube') _thumbnailField(),
          ]),
        ),
      ),
      Divider(height: 1, color: nf.border),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.md, Space.xxl, Space.lg),
        child: Row(children: [
          if (!o.copyWith(clearScheduledAt: true).isEmpty)
            TextButton.icon(
              onPressed: () {
                // The network's own time is part of the schedule: it stays.
                final at = o.scheduledAt;
                final notifier = ref.read(composerProvider.notifier);
                if (at == null) {
                  notifier.clearOverride(p.account.id);
                } else {
                  notifier.setOverride(p.account.id, PostOverrides(scheduledAt: at));
                }
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

  /// The custom thumbnail of a YouTube video upload (1.4.1): a JPEG or PNG
  /// kept with the post and set right after the upload.
  MediaAttachment? get _thumbnail {
    final raw = _extra[YouTubeAdapter.thumbnailKey];
    return raw is Map ? MediaAttachment.fromJson(Map<String, dynamic>.from(raw)) : null;
  }

  Future<void> _pickThumbnail() async {
    try {
      final files = await FilePicker.pickFiles(dialogTitle: 'Choose the video\'s thumbnail', type: FileType.custom, allowedExtensions: const ['jpg', 'jpeg', 'png']);
      final f = files.firstOrNull;
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final mime = lookupMimeType(f.name, headerBytes: bytes.length > 16 ? bytes.sublist(0, 16) : bytes) ?? '';
      if (!YouTubeAdapter.thumbnailMimeTypes.contains(mime)) {
        if (mounted) showToast(context, 'YouTube takes a JPEG or PNG thumbnail', icon: Icons.info_outline_rounded);
        return;
      }
      final made = await ref.read(servicesProvider).media.importBytes(bytes, fileName: f.name, mimeHint: mime);
      if (!mounted) return;
      setState(() => _extra[YouTubeAdapter.thumbnailKey] = made.toJson());
    } on Object catch (e) {
      if (mounted) showToast(context, 'Could not open the picture: $e', icon: Icons.error_outline_rounded);
    }
  }

  Widget _thumbnailField() {
    final nf = context.nf;
    final thumb = _thumbnail;
    final size = thumb == null ? null : '${(thumb.sizeBytes / 1000000).toStringAsFixed(1)} MB';
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Thumbnail', style: context.text.titleSmall),
        const SizedBox(height: Space.xs),
        Text(
          'Your own picture for the video, instead of a frame YouTube picks: JPEG or PNG, 1280 x 720 and under 2 MB '
          'is what YouTube asks for. It needs a verified channel; if YouTube refuses it, the video still goes and NEFORUM says why.',
          style: context.text.bodySmall,
        ),
        const SizedBox(height: Space.sm),
        Row(children: [
          if (thumb != null) ...[
            ClipRRect(borderRadius: Radii.rSm, child: SizedBox(width: 128, height: 72, child: MediaThumb(thumb, size: 72, aspect: 16 / 9))),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                [thumb.fileName ?? 'Thumbnail', if (thumb.width != null) '${thumb.width} x ${thumb.height}', ?size].join(' · '),
                style: context.text.bodySmall?.copyWith(color: nf.textMuted),
              ),
            ),
          ] else
            const Spacer(),
          if (thumb != null)
            TextButton(onPressed: () => setState(() => _extra.remove(YouTubeAdapter.thumbnailKey)), child: const Text('Remove')),
          OutlinedButton.icon(
            key: const Key('youtube-thumbnail'),
            onPressed: _pickThumbnail,
            icon: const Icon(Icons.image_outlined, size: 18),
            label: Text(thumb == null ? 'Choose thumbnail' : 'Change'),
          ),
        ]),
      ]),
    );
  }
  /// One declared option: its control, and who can use it when not everyone
  /// can ([PostOption.gate]).
  Widget _optionRow(PostOption opt, ComposerState c) {
    final nf = context.nf;
    return Padding(
      key: ValueKey('option-${opt.key}'),
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _optionField(opt, c),
        if (opt.gate != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline_rounded, size: 14, color: nf.textMuted),
              const SizedBox(width: Space.xs),
              Expanded(child: Text(opt.gate!, style: context.text.bodySmall?.copyWith(color: nf.textMuted))),
            ]),
          ),
      ]),
    );
  }

  Widget _optionField(PostOption opt, ComposerState c) {
    switch (opt.kind) {
      case PostOptionKind.toggle:
        final value = _own(opt) ?? _baseline(opt);
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(opt.label, style: context.text.bodyMedium),
          subtitle: opt.help == null ? null : Text(opt.help!, style: context.text.bodySmall),
          value: value is bool && value,
          onChanged: (v) => setState(() => _extra[opt.key] = v),
        );
      case PostOptionKind.choice:
        final current = _own(opt) as String?;
        final remembered = opt.coerce(_accountDefaults[opt.key]) as String?;
        // No choice of the post's own: the account's remembered one, else the network's default.
        final unset = remembered != null ? 'This account\'s default: ${opt.labelOf(remembered)}' : opt.defaultLabel ?? 'Not set';
        return DropdownButtonFormField<String?>(
          key: ValueKey('choice-${opt.key}-$current'),
          initialValue: current,
          isExpanded: true,
          decoration: InputDecoration(labelText: opt.label, helperText: opt.help, helperMaxLines: 3),
          items: [
            DropdownMenuItem(value: null, child: Text(unset, overflow: TextOverflow.ellipsis)),
            for (final choice in opt.choices) DropdownMenuItem(value: choice.value, child: Text(choice.label, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _extra[opt.key] = v),
        );
      case PostOptionKind.text:
      case PostOptionKind.number:
        final remembered = _accountDefaults[opt.key];
        final number = opt.kind == PostOptionKind.number;
        return TextField(
          controller: _extraCtl[opt.key],
          keyboardType: number ? TextInputType.number : null,
          inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
          decoration: InputDecoration(
            labelText: opt.label,
            // The account's remembered value is what an empty field means.
            hintText: remembered != null ? '$remembered' : opt.hint,
            helperText: opt.help,
            helperMaxLines: 3,
          ),
        );
      case PostOptionKind.mediaSelection:
        return _mediaSelectionField(opt, c);
    }
  }

  /// Some of the post's photos and videos, picked by tapping them.
  Widget _mediaSelectionField(PostOption opt, ComposerState c) {
    final nf = context.nf;
    final chosen = {...((_own(opt) as List?)?.cast<String>() ?? const <String>[])};
    final media = [for (final m in c.media) if (!m.generated && !m.isAudio && _media.contains(m.id)) m];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(opt.label, style: context.text.bodyMedium),
      if (opt.help != null) Text(opt.help!, style: context.text.bodySmall),
      const SizedBox(height: Space.sm),
      if (media.isEmpty)
        Text('This post has no photos or videos for ${p.descriptor.name}.', style: context.text.bodySmall?.copyWith(color: nf.textFaint))
      else
        Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          for (final m in media)
            Semantics(
              selected: chosen.contains(m.id),
              button: true,
              label: '${opt.label}: ${m.fileName ?? m.noun}',
              child: GestureDetector(
                key: ValueKey('${opt.key}-${m.id}'),
                onTap: () => setState(() {
                  chosen.contains(m.id) ? chosen.remove(m.id) : chosen.add(m.id);
                  _extra[opt.key] = [for (final x in media) if (chosen.contains(x.id)) x.id];
                }),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Stack(children: [
                    ClipRRect(
                      borderRadius: Radii.rSm,
                      child: ImageFiltered(
                        enabled: chosen.contains(m.id),
                        imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                        child: MediaThumb(m, size: 56),
                      ),
                    ),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Icon(
                        chosen.contains(m.id) ? Icons.visibility_off_rounded : Icons.radio_button_unchecked_rounded,
                        size: 18,
                        color: chosen.contains(m.id) ? nf.accent : Colors.white,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
        ]),
    ]);
  }

  static String _placementHelp(PostPlacement p, String network) => switch (p) {
        PostPlacement.feed => 'A regular $network post with your caption.',
        PostPlacement.story =>
          'A story: each photo or video becomes a frame, words only become a 9:16 text card. A story has no caption field: with Caption on photo, your caption is written on its photo.',
        PostPlacement.feedAndStory =>
          'The post with your caption, and the same photos or videos as a story (9:16) on the same account. A story has no caption field: with Caption on photo, the story\'s photo gets your caption written on it too (Settings > Posting).',
      };

  static String _visLabel(PostVisibility v) => switch (v) {
        PostVisibility.public => 'Public',
        PostVisibility.unlisted => 'Unlisted',
        PostVisibility.followers => 'Followers only',
        PostVisibility.private => 'Private',
      };
}
