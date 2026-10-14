import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../brand/platform_brand.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import 'markdown_style.dart';

/// Shows the bundled setup guide for [platformId] (`docs/platforms/<id>.md`),
/// or another bundled guide when [platformId] is not a platform (for example
/// `media-hosts` for `docs/media-hosts.md`).
Future<void> showGuideSheet(BuildContext context, String platformId, {String? asset}) {
  final sheet = GuideSheet(platformId: platformId, asset: asset);
  if (context.isCompact) {
    return showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => FractionallySizedBox(heightFactor: 0.92, child: sheet));
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 780, maxHeight: 860), child: sheet),
    ),
  );
}

class GuideSheet extends ConsumerWidget {
  const GuideSheet({super.key, required this.platformId, this.asset});
  final String platformId;

  /// Override the asset name (e.g. 'media-hosts.md').
  final String? asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final d = ref.watch(registryProvider).descriptor(platformId);
    final name = d?.name ?? platformId;
    final file = asset ?? '$platformId.md';
    final platformGuide = asset == null && d != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.md, Space.md),
        child: Row(children: [
          if (platformGuide) ...[PlatformTile(platformId, size: 36), const SizedBox(width: Space.md)],
          Expanded(child: Text(platformGuide ? '$name setup guide' : 'Guide', style: context.text.headlineSmall)),
          IconButton(onPressed: () => Navigator.pop(context), tooltip: 'Close', icon: const Icon(Icons.close_rounded)),
        ]),
      ),
      Divider(height: 1, color: nf.border),
      Expanded(
        child: FutureBuilder<String>(
          future: rootBundle.loadString('assets/docs/$file'),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snap.hasError || (snap.data ?? '').isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(Space.xxl),
                child: Text(
                  platformGuide ? 'The setup guide for $name is in docs/platforms/$file in the NEFORUM repository.' : 'This guide is $file in the docs folder of the NEFORUM repository.',
                  style: context.text.bodyMedium,
                ),
              );
            }
            return _GuideBody(markdown: snap.data!);
          },
        ),
      ),
    ]);
  }
}

/// The guide text with its own scroll controller: a Scrollbar without one
/// uses the PrimaryScrollController, which desktop scroll views do not attach
/// to, and fails as soon as the guide scrolls.
class _GuideBody extends StatefulWidget {
  const _GuideBody({required this.markdown});
  final String markdown;

  @override
  State<_GuideBody> createState() => _GuideBodyState();
}

class _GuideBodyState extends State<_GuideBody> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(Space.xxl, Space.lg, Space.xxl, Space.x4),
          child: NfMarkdown(widget.markdown, selectable: true),
        ),
      );
}
