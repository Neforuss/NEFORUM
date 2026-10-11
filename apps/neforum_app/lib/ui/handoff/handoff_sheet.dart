import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../brand/platform_brand.dart';
import '../../platform/env.dart';
import '../../platform/ui_bridge.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/layout.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/surfaces.dart';

/// Shows the hand-off sheet (bottom sheet on phones, dialog elsewhere).
Future<HandoffChoice> showHandoffSheet(
  BuildContext context, {
  required HandoffPlan plan,
  required Post post,
  required ConnectedAccount account,
  required PostVariant variant,
}) async {
  final sheet = HandoffSheet(plan: plan, post: post, account: account, variant: variant);
  final HandoffChoice? r;
  if (context.isCompact) {
    r = await showModalBottomSheet<HandoffChoice>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => sheet);
  } else {
    r = await showDialog<HandoffChoice>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760), child: sheet),
      ),
    );
  }
  return r ?? HandoffChoice.later;
}

class HandoffSheet extends ConsumerStatefulWidget {
  const HandoffSheet({super.key, required this.plan, required this.post, required this.account, required this.variant});

  final HandoffPlan plan;
  final Post post;
  final ConnectedAccount account;
  final PostVariant variant;

  @override
  ConsumerState<HandoffSheet> createState() => _HandoffSheetState();
}

class _HandoffSheetState extends ConsumerState<HandoffSheet> {
  bool _copied = false;
  bool _launched = false;

  HandoffPlan get plan => widget.plan;

  String get _text => plan.clipboardText ?? plan.shareText ?? widget.variant.text;

  Future<void> _copy({bool quiet = false}) async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (!mounted) return;
    setState(() => _copied = true);
    if (!quiet) showToast(context, 'Text copied. Paste it when the composer opens.', icon: Icons.check_circle_rounded);
  }

  Future<void> _openUrl(Uri url) async {
    await _copy(quiet: true);
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    setState(() => _launched = ok || _launched);
    if (!ok) showToast(context, 'Could not open $url', icon: Icons.error_outline_rounded);
  }

  Future<void> _share(BuildContext buttonContext) async {
    // Read the anchor before any await: iPad/macOS need it for the popover.
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    await _copy(quiet: true);
    final media = ref.read(servicesProvider).media;
    final files = <XFile>[];
    for (final m in plan.shareFiles) {
      if (Env.isWeb) {
        files.add(XFile.fromData(await media.read(m), mimeType: m.mimeType, name: m.fileName ?? m.id));
      } else {
        files.add(XFile(m.path, mimeType: m.mimeType, name: m.fileName));
      }
    }
    final r = await SharePlus.instance.share(
      ShareParams(text: files.isEmpty ? (plan.shareText ?? _text) : plan.shareText, files: files.isEmpty ? null : files, sharePositionOrigin: origin),
    );
    if (!mounted) return;
    setState(() => _launched = _launched || r.status == ShareResultStatus.success || r.status == ShareResultStatus.unavailable);
  }

  /// Desktop has no share sheet for files: open the folder so photos can be
  /// dragged into the browser's upload box.
  Future<void> _revealMedia() async {
    final first = plan.shareFiles.firstOrNull;
    if (first == null || Env.isWeb) return;
    await launchUrl(Uri.file(p.dirname(first.path)));
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final d = ref.watch(registryProvider).descriptor(widget.account.platformId);
    final name = d?.name ?? widget.account.platformId;
    final steps = _steps(plan.instructions);
    final appTarget = _appUrl();

    final actions = <Widget>[];
    void addAction(Widget w) => actions.add(
      Padding(
        padding: const EdgeInsets.only(bottom: Space.sm),
        child: w,
      ),
    );

    final shareFirst = plan.preferred == HandoffMethod.shareSheet && Env.hasShareSheet;
    if (shareFirst) {
      addAction(
        Builder(
          builder: (bc) => PrimaryAction(
            label: plan.hasMedia ? 'Share ${plan.shareFiles.length == 1 ? 'photo' : '${plan.shareFiles.length} files'} to $name' : 'Share to $name',
            icon: Icons.ios_share_rounded,
            expand: true,
            onPressed: () => _share(bc),
          ),
        ),
      );
    }
    if (plan.webIntent != null) {
      final w = PrimaryAction(label: 'Open $name composer', icon: Icons.open_in_new_rounded, expand: true, onPressed: () => _openUrl(plan.webIntent!));
      addAction(
        shareFirst
            ? OutlinedButton.icon(
                onPressed: () => _openUrl(plan.webIntent!),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: Text('Open $name composer'),
              )
            : w,
      );
    }
    if (!shareFirst && plan.hasMedia && Env.hasShareSheet) {
      addAction(
        Builder(
          builder: (bc) =>
              OutlinedButton.icon(onPressed: () => _share(bc), icon: const Icon(Icons.ios_share_rounded, size: 18), label: const Text('Share with media')),
        ),
      );
    }
    if (appTarget != null && plan.webIntent == null && !shareFirst) {
      addAction(PrimaryAction(label: 'Open $name', icon: Icons.open_in_new_rounded, expand: true, onPressed: () => _openUrl(appTarget)));
    } else if (appTarget != null && (plan.webIntent == null || shareFirst)) {
      addAction(OutlinedButton.icon(onPressed: () => _openUrl(appTarget), icon: const Icon(Icons.open_in_new_rounded, size: 18), label: Text('Open $name')));
    }
    if (plan.hasMedia && Env.isDesktop) {
      addAction(OutlinedButton.icon(onPressed: _revealMedia, icon: const Icon(Icons.folder_open_rounded, size: 18), label: const Text('Show media files')));
    }

    final footer = Padding(
      padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.xl, Space.lg),
      child: Row(
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context, HandoffChoice.skip),
            style: TextButton.styleFrom(foregroundColor: nf.textMuted),
            child: const Text('Skip'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.pop(context, HandoffChoice.later),
            style: TextButton.styleFrom(foregroundColor: nf.textMuted),
            child: const Text('Later'),
          ),
          const SizedBox(width: Space.sm),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, HandoffChoice.posted),
            style: FilledButton.styleFrom(backgroundColor: _launched ? nf.success : null),
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('I posted it'),
          ),
        ],
      ),
    );

    // Content scrolls; the decision buttons stay pinned at the bottom.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Space.xxl, Space.lg, Space.xxl, Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    PlatformTile(widget.account.platformId, size: 48),
                    const SizedBox(width: Space.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Finish on $name', style: context.text.headlineSmall),
                          const SizedBox(height: 2),
                          Text(widget.account.handle ?? widget.account.displayName, style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
                        ],
                      ),
                    ),
                    const TierBadge(PlatformTier.handoff, dense: false),
                  ],
                ),
                const SizedBox(height: Space.xl),

                // Text to paste.
                NfWell(
                  padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.sm, Space.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 160),
                          child: SingleChildScrollView(child: SelectableText(_text.isEmpty ? '(no text)' : _text, style: context.text.bodyMedium)),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      ToolButton(
                        icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
                        tooltip: _copied ? 'Copied' : 'Copy text',
                        active: _copied,
                        onPressed: _copy,
                      ),
                    ],
                  ),
                ),
                if (plan.hasMedia) ...[
                  const SizedBox(height: Space.md),
                  SizedBox(
                    height: 72,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: plan.shareFiles.length,
                      separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
                      itemBuilder: (_, i) => MediaThumb(plan.shareFiles[i], size: 72),
                    ),
                  ),
                ],
                if (plan.mediaNote != null) ...[
                  const SizedBox(height: Space.md),
                  _Callout(icon: Icons.info_outline_rounded, color: nf.info, text: plan.mediaNote!),
                ],
                const SizedBox(height: Space.xl),
                for (var i = 0; i < steps.length; i++) _Step(index: i + 1, text: steps[i]),
                const SizedBox(height: Space.lg),
                ...actions,
              ],
            ),
          ),
        ),
        Divider(height: 1, color: nf.border),
        footer,
      ],
    );
  }

  Uri? _appUrl() {
    if (Env.isIOS && plan.iosScheme != null) return Uri.tryParse(plan.iosScheme!);
    if (plan.desktopUrl != null) return Uri.tryParse(plan.desktopUrl!);
    return null;
  }

  static List<String> _steps(String instructions) {
    final lines = instructions.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    return [for (final l in lines) l.replaceFirst(RegExp(r'^(\d+[.)]|[-*•])\s*'), '')];
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.index, required this.text});
  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: nf.accentSoft, shape: BoxShape.circle),
            child: Text(
              '$index',
              style: monoStyle(context, size: 12, color: nf.accent, weight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(text.replaceAll('**', ''), style: context.text.bodyMedium),
            ),
          ),
        ],
      ),
    );
  }
}

class _Callout extends StatelessWidget {
  const _Callout({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: nf.isDark ? 0.14 : 0.07), nf.surface),
        borderRadius: Radii.rMd,
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: Space.sm + 2),
          Expanded(
            child: Text(text, style: context.text.bodySmall?.copyWith(color: nf.text)),
          ),
        ],
      ),
    );
  }
}
