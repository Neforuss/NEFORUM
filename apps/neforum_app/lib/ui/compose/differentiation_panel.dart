import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../state/composer.dart';
import '../../state/differentiation.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/char_ring.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import 'customize_sheet.dart';

/// What a network gets when its version follows the main post: the main text
/// with that network's hashtags and link added, not yet split into a thread.
String baseVersionText(ComposerState c, TargetPreview p, AppSettings settings) {
  final resolver = VariantResolver(ResolverOptions(
    overflow: OverflowStrategy.error,
    threadNumbering: settings.threadNumbering,
    appendHashtags: settings.appendHashtags,
    appendLink: settings.appendLink,
  ));
  final post = c.toPost(id: 'version', status: PostStatus.draft, now: DateTime.now());
  final target = post.targetFor(p.account.id) ?? PostTarget(accountId: p.account.id);
  final plain = target.copyWith(overrides: target.overrides.copyWith(clearText: true));
  return resolver.resolve(post, plain, p.descriptor, account: p.account).text;
}

/// DIFFERENTIATION: under the editor, one editable version per network,
/// all on screen at once, each with that network's conventions and one-tap
/// changes. Versions are the per-account text of the post, so previews,
/// scheduling and publishing use them as they are.
class DifferentiationPanel extends ConsumerWidget {
  const DifferentiationPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final c = ref.watch(composerProvider);
    final previews = ref.watch(composerPreviewsProvider);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(composerProvider.notifier);
    if (previews.isEmpty) return const SizedBox.shrink();
    final own = previews.where((p) => c.overrides[p.account.id]?.text != null).length;

    if (!c.differentiate) {
      return NfCard(
        padding: const EdgeInsets.all(Space.lg),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: nf.accentSoft, borderRadius: Radii.rMd),
            child: Icon(Icons.call_split_rounded, color: nf.accent),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('DIFFERENTIATION', style: context.text.labelSmall?.copyWith(color: nf.accent, letterSpacing: 1.4)),
              const SizedBox(height: 2),
              Text(
                own > 0
                    ? '$own ${own == 1 ? 'network has its own version' : 'networks have their own version'}. Open to see them side by side.'
                    : 'What works on X rarely works on LinkedIn or Instagram. Give each network its own version.',
                style: context.text.bodySmall,
              ),
            ]),
          ),
          const SizedBox(width: Space.md),
          FilledButton.tonalIcon(
            onPressed: () => notifier.setDifferentiate(true),
            icon: const Icon(Icons.call_split_rounded, size: 18),
            label: const Text('Differentiate'),
          ),
        ]),
      );
    }

    Future<void> auto() async {
      if (own > 0) {
        final ok = await confirmDialog(
          context,
          title: 'Rewrite every version?',
          message: 'Auto-differentiate starts each network again from the main post and applies its conventions. '
              'The $own ${own == 1 ? 'version' : 'versions'} you edited will be replaced.',
          confirmLabel: 'Rewrite all',
        );
        if (!ok) return;
      }
      final current = ref.read(composerProvider);
      notifier.setVersionTexts({
        for (final p in previews)
          p.account.id: () {
            final base = baseVersionText(current, p, settings);
            final v = autoVersion(base, p.descriptor);
            return v.trim() == base.trim() ? null : v;
          }(),
      });
    }

    Future<void> close() async {
      if (own > 0) {
        final ok = await confirmDialog(
          context,
          title: 'Use the main post everywhere?',
          message: 'The $own ${own == 1 ? 'version' : 'versions'} you wrote will be discarded.',
          confirmLabel: 'Discard versions',
          destructive: true,
        );
        if (!ok) return;
      }
      notifier.setVersionTexts({for (final p in previews) p.account.id: null});
      notifier.setDifferentiate(false);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('DIFFERENTIATION', style: context.text.labelSmall?.copyWith(color: nf.accent, letterSpacing: 1.4)),
            const SizedBox(height: 2),
            Text('A version for each network', style: context.text.titleLarge),
            const SizedBox(height: 2),
            Text(
              'Versions start as the main post. Edit any of them; the others keep following the main post.',
              style: context.text.bodySmall,
            ),
          ]),
        ),
        IconButton(tooltip: 'Close Differentiation', onPressed: close, icon: const Icon(Icons.close_rounded)),
      ]),
      const SizedBox(height: Space.sm),
      Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
        FilledButton.icon(onPressed: auto, icon: const Icon(Icons.auto_fix_high_rounded, size: 18), label: const Text('Auto-differentiate')),
        if (own > 0)
          OutlinedButton.icon(
            onPressed: () => notifier.setVersionTexts({for (final p in previews) p.account.id: null}),
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('Reset all to the main post'),
          ),
      ]),
      const SizedBox(height: Space.md),
      for (final p in previews) ...[
        _VersionEditor(key: ValueKey('version-${p.account.id}'), preview: p, base: baseVersionText(c, p, settings), own: c.overrides[p.account.id]?.text),
        const SizedBox(height: Space.md),
      ],
    ]);
  }
}

class _VersionEditor extends ConsumerStatefulWidget {
  const _VersionEditor({super.key, required this.preview, required this.base, required this.own});
  final TargetPreview preview;

  /// What the network gets from the main post.
  final String base;

  /// The network's own version, when it has one.
  final String? own;

  @override
  ConsumerState<_VersionEditor> createState() => _VersionEditorState();
}

class _VersionEditorState extends ConsumerState<_VersionEditor> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.own ?? widget.base);
  final FocusNode _focus = FocusNode();

  String get _current => widget.own ?? widget.base;

  @override
  void didUpdateWidget(_VersionEditor old) {
    super.didUpdateWidget(old);
    // Follow the main post (or a one-tap change) unless the user is typing here.
    if (!_focus.hasFocus && _ctrl.text != _current) {
      _ctrl.value = TextEditingValue(text: _current, selection: TextSelection.collapsed(offset: _current.length));
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _set(String text) {
    final notifier = ref.read(composerProvider.notifier);
    notifier.setVersionText(widget.preview.account.id, text.trim() == widget.base.trim() ? null : text);
  }

  void _apply(VersionTransform t) {
    final next = applyTransform(t, _ctrl.text, widget.preview.descriptor);
    _ctrl.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: next.length));
    _set(next);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final p = widget.preview;
    final d = p.descriptor;
    final rules = d.text;
    final text = _ctrl.text;
    final used = rules.maxLength == null ? text.characters.length : TextCounter.count(text, rules);
    final over = rules.maxLength != null && used > rules.maxLength!;
    final own = widget.own != null;
    final style = styleFor(d.id);
    final useful = usefulTransforms(text, d);

    return NfCard(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.md, Space.md),
      borderColor: own ? nf.accent.withValues(alpha: 0.6) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          PlatformTile(d.id, size: 26),
          const SizedBox(width: Space.sm + 2),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Flexible(child: Text(d.name, overflow: TextOverflow.ellipsis, style: context.text.titleSmall)),
                const SizedBox(width: Space.sm),
                StatusPill(own ? 'Own version' : 'Main post', tone: own ? Tone.accent : Tone.neutral, dense: true),
              ]),
              Text(p.account.handle ?? p.account.displayName, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.textFaint, fontSize: 11.5)),
            ]),
          ),
          CharRing(used: used, max: rules.maxLength, size: 20, alwaysShowCount: true),
          if (own)
            IconButton(
              tooltip: 'Back to the main post',
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              onPressed: () {
                ref.read(composerProvider.notifier).setVersionText(p.account.id, null);
                _ctrl.text = widget.base;
              },
            ),
          IconButton(
            tooltip: 'More for ${d.name}: title, media, link',
            icon: const Icon(Icons.tune_rounded, size: 18),
            onPressed: () => showCustomizeSheet(context, p),
          ),
        ]),
        const SizedBox(height: Space.xs),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lightbulb_outline_rounded, size: 14, color: nf.textFaint),
          const SizedBox(width: Space.xs + 2),
          Expanded(child: Text(style.tip, style: context.text.bodySmall?.copyWith(color: nf.textMuted, fontSize: 12))),
        ]),
        const SizedBox(height: Space.sm),
        NfWell(
          padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.xs),
          child: TextField(
            controller: _ctrl,
            focusNode: _focus,
            onChanged: (v) {
              setState(() {});
              _set(v);
            },
            minLines: 3,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            style: context.text.bodyMedium?.copyWith(height: 1.5),
            decoration: InputDecoration(
              hintText: 'The ${d.name} version',
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: Space.sm),
            ),
          ),
        ),
        if (over)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Text(
              rules.supportsThreads && p.account.tier.isAutomatic
                  ? 'Longer than ${rules.maxLength}: ${d.name} gets it as a thread.'
                  : 'Longer than ${d.name} allows (${rules.maxLength}). Shorten it or use "${VersionTransform.fit.label}".',
              style: context.text.bodySmall?.copyWith(color: rules.supportsThreads ? nf.textMuted : nf.danger),
            ),
          ),
        if (useful.isNotEmpty) ...[
          const SizedBox(height: Space.sm),
          Wrap(spacing: Space.xs + 2, runSpacing: Space.xs + 2, children: [
            for (final t in useful)
              ActionChip(
                label: Text(t == VersionTransform.fit ? 'Fit to ${rules.maxLength}' : t.label),
                avatar: Icon(_icon(t), size: 15, color: nf.textMuted),
                onPressed: () => _apply(t),
                labelStyle: context.text.labelMedium?.copyWith(color: nf.textMuted),
                visualDensity: VisualDensity.compact,
              ),
          ]),
        ],
      ]),
    );
  }

  static IconData _icon(VersionTransform t) => switch (t) {
        VersionTransform.fit => Icons.content_cut_rounded,
        VersionTransform.hashtagsToEnd => Icons.low_priority_rounded,
        VersionTransform.fewerHashtags => Icons.tag_rounded,
        VersionTransform.noHashtags => Icons.tag_rounded,
        VersionTransform.linkInBio => Icons.person_pin_outlined,
        VersionTransform.noLink => Icons.link_off_rounded,
        VersionTransform.airy => Icons.format_line_spacing_rounded,
      };
}
